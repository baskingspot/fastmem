"""Executable-only transitive search audit. Never inspect host glibc instructions."""

import hashlib
import re
import subprocess
from pathlib import Path
from typing import Any

from fastmem_bench.find_audit import (
    BRANCH,
    Assembly,
    Elf,
    backedges,
    clock_calls,
    dispatch_call,
    dispatch_proof,
)

FORBIDDEN = {"memmem", "memchr", "memcmp", "bcmp", "memcpy", "memmove", "memset"}


def _scan(asm: Assembly, roots: list[int], finite: dict[int, list[int]]) -> dict[str, Any]:
    pending = list(roots)
    visited: set[int] = set()
    delegations = []
    unresolved = []
    while pending:
        address = pending.pop()
        owner = asm.owners.get(address)
        if owner is None:
            raise ValueError(f"Missing executable function at {address:#x}")
        if owner in visited:
            continue
        visited.add(owner)
        for instruction in asm.bodies[owner]:
            if not BRANCH.fullmatch(instruction.op):
                continue
            item = {
                "caller": asm.names[owner],
                "caller_address": hex(owner),
                "address": hex(instruction.address),
            }
            label = re.search(r"<([^>]+)>", instruction.args)
            name = re.split(r"[+@]", label[1])[0] if label else None
            target = instruction.target()
            # Both the operand label and destination's actual identity matter.
            target_name = asm.names.get(asm.owners.get(target, -1), "")
            forbidden = next((n for n in (name, target_name) if n in FORBIDDEN), None)
            if forbidden:
                delegations.append({**item, "symbol": forbidden})
            elif target is not None and target in asm.owners:
                pending.append(target)
            elif instruction.address in finite:
                pending.extend(finite[instruction.address])
            else:
                unresolved.append({**item, **({"symbol": name} if name else {})})
    return {
        "checked_roots": [asm.names[a] for a in roots],
        "followed_callees": sorted(asm.names[a] for a in visited),
        "followed_functions": [
            {"address": hex(a), "symbol": asm.names[a]} for a in sorted(visited)
        ],
        "delegations": delegations,
        "unresolved": unresolved,
    }


def scan(assembly: str, roots: list[str]) -> dict[str, Any]:
    asm = Assembly(assembly)
    return _scan(asm, asm.roots(roots), {})


def inspect(  # noqa: C901, PLR0912 — fail-closed proof assembly
    binary: Path, destination: Path, *, kernel_pending: bool = True
) -> dict[str, Any]:
    assembly = subprocess.run(
        ["llvm-objdump", "-d", "--no-show-raw-insn", str(binary)],
        check=True,
        capture_output=True,
        text=True,
        timeout=120,
    ).stdout
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(assembly)
    asm = Assembly(assembly)
    elf = Elf(binary)
    wrapper = elf.symbol("bench_find_fastmem")
    if wrapper not in asm.bodies:
        raise ValueError("Cannot resolve private fastmem wrapper disassembly")
    required = ("bench_find.runFastmemDirect", "bench_find.runIndirect")
    if not all(any(name.startswith(prefix) for name in elf.symbols) for prefix in required):
        raise ValueError("Missing timed search loops")
    fast_loops = [
        a
        for a, n in asm.names.items()
        if n.startswith(("bench_find.runFastmemDirect", "bench_find.runFastmemFixed"))
    ]
    timed_roots = [
        a
        for a, n in asm.names.items()
        if n.startswith(("bench_find.runFastmem", "bench_find.runStd", "bench_find.runIndirect"))
    ]
    indirect = [a for a in timed_roots if asm.names[a].startswith("bench_find.runIndirect")]
    if not indirect or not any(
        i.op in {"blr", "call", "callq"} and i.target() is None
        for a in indirect
        for i in asm.bodies[a]
        if any(lo <= i.address <= hi for lo, hi in backedges(asm.bodies[a]))
    ):
        raise ValueError("Indirect search loop contains no per-iteration indirect call")
    finite: dict[int, list[int]] = {}
    dispatch = None
    dispatch_error = None
    dispatch_sites = []
    if "x86_64.dispatch.find_fn" in elf.symbols:
        try:
            dispatch = dispatch_proof(elf, asm)
        except (ValueError, KeyError) as error:
            dispatch_error = str(error)
        if dispatch:
            targets = [int(e["address"], 16) for e in dispatch["entries"]]
            targets.append(int(dispatch["initial_resolver"], 16))
            slot = int(dispatch["slot"], 16)
            for owner, body in asm.bodies.items():
                for index, instruction in enumerate(body):
                    if dispatch_call(body, index, slot):
                        finite[instruction.address] = targets
                        dispatch_sites.append(
                            {
                                "caller": asm.names[owner],
                                "caller_address": hex(owner),
                                "address": hex(instruction.address),
                                "inside_backedge": any(
                                    lo <= instruction.address <= hi for lo, hi in backedges(body)
                                ),
                            }
                        )
    clocks = []
    clock_offset = elf.clock_offset()
    # Only exact Io-vtable call patterns with argument provenance, outside all
    # backedges, qualify. Unknown indirect searches remain unresolved.
    for owner in fast_loops:
        sites = clock_calls(asm.bodies[owner], clock_offset)
        for address in sites:
            finite[address] = []
            clocks.append(
                {
                    "caller": asm.names[owner],
                    "caller_address": hex(owner),
                    "address": hex(address),
                    "vtable_offset": hex(clock_offset),
                    "identity": "Io.Threaded.now ABI callback",
                    "outside_backedges": True,
                }
            )
    roots = [wrapper, *fast_loops]
    if dispatch:
        roots.extend(int(e["address"], 16) for e in dispatch["entries"])
        roots.append(int(dispatch["initial_resolver"], 16))
    evidence = _scan(asm, roots, finite)
    if dispatch_error:
        evidence["unresolved"].append(
            {"symbol": "x86_64.dispatch.find_fn", "reason": dispatch_error}
        )
    evidence.update(
        {
            "dispatch_proof": dispatch,
            "dispatch_calls": dispatch_sites,
            "clock_calls_for_manual_review": clocks,
            "anti_hoist_status": "manual-review-required",
            "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "wrapper_symbol": "bench_find_fastmem",
            "wrapper_disassembly": asm.names[wrapper],
            "wrapper_address": hex(wrapper),
            "timed_roots": sorted(asm.names[a] for a in timed_roots),
            "status": "invalid"
            if evidence["delegations"] or evidence["unresolved"]
            else ("pending-kernel" if kernel_pending else "pending-review"),
            "kernel_pending": kernel_pending,
            "integration_hook": "Rebuild after integration; inspect(..., kernel_pending=False). "
            "No pending status constitutes acceptance. Clock ABI/placement and finite dispatch are "
            "recorded separately; anti-hoist/result retention still require review of these bytes.",
        }
    )
    return evidence
