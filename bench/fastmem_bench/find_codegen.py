"""Executable-only transitive search audit. Never inspect host glibc instructions."""

import hashlib
import re
import subprocess
from pathlib import Path
from typing import Any

FORBIDDEN = {"memmem", "memchr", "memcmp", "bcmp", "memcpy", "memmove", "memset"}
HEADER = re.compile(r"^[0-9a-f]+ <(.+)>:$")
BRANCH = re.compile(
    r"^\s*([0-9a-f]+):\s+(callq?|j[a-z]+|blr?|b(?:\.[a-z]+)?|br|cbn?z|tbn?z)\s+(.*)"
)


def scan(  # noqa: C901, PLR0912 — transitive branch audit fails closed on unresolved callees
    assembly: str, roots: list[str]
) -> dict[str, Any]:
    bodies: dict[str, list[str]] = {}
    current = ""
    for line in assembly.splitlines():
        if header := HEADER.match(line):
            current = header[1]
            bodies[current] = []
        elif current:
            bodies[current].append(line)
    if not set(roots) <= bodies.keys():
        raise ValueError("Missing search inspection roots")
    pending = list(roots)
    visited: set[str] = set()
    delegations = []
    unresolved = []
    while pending:
        caller = pending.pop()
        if caller in visited:
            continue
        visited.add(caller)
        for line in bodies[caller]:
            branch = BRANCH.match(line)
            if branch is None:
                continue
            target = re.search(r"<([^>]+)>", branch[3])
            if target is None:
                if branch[2] in ("call", "callq", "blr", "br") or (
                    branch[2] in ("jmp", "jmpq") and "*" in branch[3]
                ):
                    unresolved.append({"caller": caller, "address": "0x" + branch[1]})
                continue
            name = re.split(r"[+@]", target[1])[0]
            if name in FORBIDDEN:
                delegations.append({"caller": caller, "symbol": name, "address": "0x" + branch[1]})
            elif name in bodies and name not in visited:
                pending.append(name)
            elif name not in bodies:
                unresolved.append({"caller": caller, "symbol": name, "address": "0x" + branch[1]})
    return {
        "checked_roots": roots,
        "followed_callees": sorted(visited),
        "delegations": delegations,
        "unresolved": unresolved,
    }


def inspect(binary: Path, destination: Path, *, kernel_pending: bool = True) -> dict[str, Any]:
    assembly = subprocess.run(
        ["llvm-objdump", "-d", "--no-show-raw-insn", str(binary)],
        check=True,
        capture_output=True,
        text=True,
        timeout=120,
    ).stdout
    headers = [m[1] for line in assembly.splitlines() if (m := HEADER.match(line))]
    # LLVM can fold identical stdlib/fastmem baseline wrappers into a single address.
    symbols = subprocess.run(
        ["llvm-nm", "--defined-only", str(binary)],
        check=True,
        capture_output=True,
        text=True,
        timeout=60,
    ).stdout
    addresses = {
        parts[-1]: parts[0] for line in symbols.splitlines() if len(parts := line.split()) >= 3
    }
    if "bench_find_fastmem" not in addresses:
        raise ValueError("Missing private fastmem search wrapper")
    aliases = [name for name in headers if addresses.get(name) == addresses["bench_find_fastmem"]]
    if len(aliases) != 1:
        raise ValueError("Cannot resolve private fastmem wrapper disassembly")
    # The wrapper's closure is a pure search graph, unlike the timed loops' clock machinery.
    evidence = scan(assembly, aliases)
    fast_loops = [
        name
        for name in headers
        if name.startswith(("bench_find.runFastmemDirect", "bench_find.runFastmemFixed"))
    ]
    std_loops = [
        name
        for name in headers
        if name.startswith(("bench_find.runStdDirect", "bench_find.runStdFixed"))
    ]
    indirect = [name for name in headers if name.startswith("bench_find.runIndirect")]
    # Identical direct baseline loops can also fold. Accept aliases, but never absent symbols.
    required = ("bench_find.runFastmemDirect", "bench_find.runIndirect")
    if not all(any(name.startswith(prefix) for name in addresses) for prefix in required):
        raise ValueError("Missing timed search loops")
    if not indirect or not re.search(
        r"\b(blr|callq?)\s+(x\d+|\*)",
        "\n".join(line for name in indirect for line in _body(assembly, name)),
    ):
        raise ValueError("Indirect search loop contains no indirect call")
    timed_audit = scan(assembly, fast_loops)
    # The two Io timestamp vtable calls are outside the iteration loop. Keep them
    # explicit for manual codegen review; never silently accept kernel indirection.
    clock_calls = [
        item
        for item in timed_audit["unresolved"]
        if "symbol" not in item and item["caller"] in fast_loops
    ]
    timed_unresolved = [item for item in timed_audit["unresolved"] if item not in clock_calls]
    evidence["delegations"] += timed_audit["delegations"]
    evidence["unresolved"] += timed_unresolved
    evidence["timed_followed_callees"] = timed_audit["followed_callees"]
    evidence["clock_calls_for_manual_review"] = clock_calls
    evidence["anti_hoist_status"] = "manual-review-required"
    # Retain executable disassembly only. No resolved glibc body is requested or downloaded.
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(assembly)
    evidence.update(
        {
            "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "wrapper_symbol": "bench_find_fastmem",
            "wrapper_disassembly": aliases[0],
            "timed_roots": sorted(fast_loops + std_loops + indirect),
            "status": "pending-kernel"
            if kernel_pending
            else (
                "invalid"
                if evidence["delegations"] or evidence["unresolved"]
                else ("pending-review" if clock_calls else "clean")
            ),
            "kernel_pending": kernel_pending,
            "integration_hook": "Rebuild after kernel integration; call "
            "inspect(..., kernel_pending=False). Delegations or unresolved search callees fail. "
            "pending-review requires confirming each recorded clock callback is outside the "
            "iteration loop and that search calls/loads plus checksum remain inside it. "
            "No pending status constitutes codegen acceptance.",
        }
    )
    return evidence


def _body(assembly: str, name: str) -> list[str]:
    selected = False
    lines = []
    for line in assembly.splitlines():
        if header := HEADER.match(line):
            selected = header[1] == name
        elif selected:
            lines.append(line)
    return lines
