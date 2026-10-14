"""Mutation fixtures prove the delegation audit follows callees, including tail calls."""

import shutil
import struct
import subprocess
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from fastmem_bench.find_audit import Assembly, Elf, backedges, clock_calls, selector_returns
from fastmem_bench.find_codegen import inspect, scan


@pytest.mark.parametrize("instruction", ["callq", "jmp", "bl", "b"])
def test_transitive_delegation(instruction: str) -> None:
    assembly = f"""00001000 <root>:
 1000: {instruction} 0x2000 <helper>
00002000 <helper>:
 2000: {instruction} 0x3000 <memcmp@plt>
"""
    evidence = scan(assembly, ["root"])
    assert evidence["followed_callees"] == ["helper", "root"]
    assert evidence["delegations"] == [
        {"caller": "helper", "caller_address": "0x2000", "symbol": "memcmp", "address": "0x2000"}
    ]


@pytest.mark.parametrize(
    "symbol", ["memmem", "memchr", "memcmp", "bcmp", "memcpy", "memmove", "memset"]
)
def test_forbidden_search_and_memory_names(symbol: str) -> None:
    assert scan(f"00001000 <root>:\n 1000: bl 0x2000 <{symbol}>\n", ["root"])["delegations"]


def test_local_loop_and_missing_root() -> None:
    assert not scan("00001000 <root>:\n 1000: b.ne 0x1000 <root+0x4>\n", ["root"])["delegations"]
    with pytest.raises(ValueError, match="Missing"):
        scan("", ["root"])


def test_unknown_indirect_fails_closed() -> None:
    evidence = scan("00001000 <root>:\n 1000: blr x9\n", ["root"])
    assert evidence["unresolved"] == [
        {"caller": "root", "caller_address": "0x1000", "address": "0x1000"}
    ]


def test_duplicate_local_names_preserve_reachable_identity() -> None:
    assembly = """00001000 <root>:
 1000: callq 0x2000 <helper>
00002000 <helper>:
 2000: callq 0x3000 <memcmp@plt>
00004000 <helper>:
 4000: retq
"""
    evidence = scan(assembly, ["root"])
    assert evidence["delegations"][0]["caller_address"] == "0x2000"
    assert {f["address"] for f in evidence["followed_functions"]} == {"0x1000", "0x2000"}
    # A duplicate root name must inspect BOTH identities too.
    assert scan(assembly, ["helper"])["delegations"]


def test_unlabelled_and_interior_branches_follow_addresses() -> None:
    assembly = """00001000 <root>:
 1000: callq 0x2001
00002000 <helper>:
 2000: nop
 2001: callq 0x3000 <memcmp@plt>
"""
    assert scan(assembly, ["root"])["delegations"]
    assert scan("00001000 <root>:\n 1000: callq 0xdead\n", ["root"])["unresolved"]


# These are merged-kernel executable tests, not the old forwarding smoke test.
# All subprocess tools come from the caller's Nix environment.
@pytest.fixture(scope="module")
def portable(tmp_path_factory: pytest.TempPathFactory) -> Path:
    if not all(shutil.which(tool) for tool in ("zig", "llvm-objdump")):
        pytest.skip("requires Nix Zig/LLVM tools")
    destination = tmp_path_factory.mktemp("find-audit-portable")
    subprocess.run(
        [
            "zig",
            "build",
            "bench-find-bin",
            "-j2",
            "-Dtarget=x86_64-linux-gnu",
            "-Dcpu=x86_64",
            "-Doptimize=ReleaseFast",
            "--prefix",
            str(destination),
        ],
        cwd=Path(__file__).resolve().parents[2],
        check=True,
        capture_output=True,
        timeout=1200,
    )
    return destination / "bin/bench-find"


def audited(binary: Path, destination: Path, assembly: str | None = None) -> dict:
    if assembly is None:
        return inspect(binary, destination, kernel_pending=False)
    with patch(
        "fastmem_bench.find_codegen.subprocess.run", return_value=SimpleNamespace(stdout=assembly)
    ):
        return inspect(binary, destination, kernel_pending=False)


def test_real_portable_seven_closures_and_clock_identities(portable: Path, tmp_path: Path) -> None:
    evidence = audited(portable, tmp_path / "executable.asm")
    assert evidence["status"] == "pending-review"
    assert evidence["anti_hoist_status"] == "manual-review-required"
    assert not evidence["delegations"]
    assert not evidence["unresolved"]
    proof = evidence["dispatch_proof"]
    assert len(proof["entries"]) == 7
    assert len(proof["writers"]) == 4
    closure = {f["address"] for f in evidence["followed_functions"]}
    assert all(e["address"] in closure for e in proof["entries"])
    assert sum(f["symbol"] == "find.twoWay" for f in evidence["followed_functions"]) == 7
    assert any(c["inside_backedge"] for c in evidence["dispatch_calls"])
    assert len(evidence["clock_calls_for_manual_review"]) == 20
    clocks = {c["address"] for c in evidence["clock_calls_for_manual_review"]}
    assert not clocks.intersection(c["address"] for c in evidence["dispatch_calls"])


@pytest.mark.parametrize(
    "mutation",
    [
        "one-level-forbidden",
        "unknown-indirect",
        "search-as-clock",
        "unproven-table",
        "selector-range",
    ],
)
def test_real_portable_disassembly_mutations_fail_closed(
    portable: Path,
    tmp_path: Path,
    mutation: str,
) -> None:
    path = tmp_path / "executable.asm"
    original = audited(portable, path)
    assembly = path.read_text()
    asm = Assembly(assembly)
    if mutation == "one-level-forbidden":
        # Only the FIRST duplicate twoWay is bad; the final generic body is intact.
        owner = next(a for a, name in asm.names.items() if name == "find.twoWay")
        inst = next(i for i in asm.bodies[owner] if i.op == "retq")
        replacement = f" {inst.address:x}: callq 0xdeadbeef <memcmp@plt>"
    elif mutation in {"unknown-indirect", "search-as-clock"}:
        site = next(c for c in original["dispatch_calls"] if c["inside_backedge"])
        owner = int(site["caller_address"], 16)
        inst = next(i for i in asm.bodies[owner] if hex(i.address) == site["address"])
        operand = "*%r11" if mutation == "unknown-indirect" else "*0x2c0(%rax)"
        replacement = f" {inst.address:x}: callq {operand}"
    elif mutation == "unproven-table":
        owner = int(original["dispatch_proof"]["initial_resolver"], 16)
        inst = next(i for i in asm.bodies[owner] if i.args.startswith("(%rax,%rdi), %rax"))
        replacement = f" {inst.address:x}: movq (%rax,%rsi), %rax"
    else:
        owner = int(original["dispatch_proof"]["selector"], 16)
        inst = next(i for i in asm.bodies[owner] if i.op == "movb" and i.args == "$0x6, %al")
        replacement = f" {inst.address:x}: movb $0x7, %al"
    evidence = audited(portable, path, assembly.replace(inst.text, replacement, 1))
    assert evidence["status"] == "invalid"
    if mutation == "one-level-forbidden":
        assert evidence["delegations"][0]["symbol"] == "memcmp"
        assert evidence["delegations"][0]["caller_address"] == hex(owner)
    else:
        assert evidence["unresolved"]
    if mutation == "search-as-clock":
        assert hex(inst.address) not in {
            c["address"] for c in evidence["clock_calls_for_manual_review"]
        }


@pytest.mark.parametrize("mutation", ["slot", "one-level-target"])
def test_real_elf_pointer_mutations_fail_closed(
    portable: Path, tmp_path: Path, mutation: str
) -> None:
    evidence = audited(portable, tmp_path / "original.asm")
    proof = evidence["dispatch_proof"]
    address = int(proof["slot" if mutation == "slot" else "table"], 16)
    if mutation == "one-level-target":
        address += 5 * 8
    elf = Elf(portable)
    section = next(s for s in elf.sections if s[1] == 1 and s[3] <= address < s[3] + s[5])
    raw = bytearray(elf.raw)
    struct.pack_into("<Q", raw, section[4] + address - section[3], 0xDEADBEEF)
    binary = tmp_path / "mutant"
    binary.write_bytes(raw)
    result = audited(binary, tmp_path / "mutant.asm")
    assert result["status"] == "invalid"
    assert result["unresolved"]


def test_clock_shape_inside_loop_is_not_a_clock() -> None:
    body = Assembly("""00001000 <timed>:
 1000: movq %rsi, %rbx
 1001: movq 0x8(%rbx), %rax
 1002: callq *0x2c0(%rax)
 1003: movq 0x8(%rbx), %rax
 1004: callq *0x2c0(%rax)
 1005: jne 0x1003 <timed+0x3>
 1006: movq 0x8(%rbx), %rax
 1007: callq *0x2c0(%rax)
""").bodies[0x1000]
    assert backedges(body) == [(0x1003, 0x1005)]
    assert clock_calls(body, 0x2C0) == [0x1002, 0x1007]
    assert not clock_calls(body, 0x2C8)


def test_unknown_selector_return_fails_closed() -> None:
    body = Assembly("00001000 <selector>:\n 1000: movl (%rdi), %eax\n 1001: retq\n").bodies[0x1000]
    with pytest.raises(ValueError, match="selector return"):
        selector_returns(body)


def test_clock_provenance_requires_every_cfg_path() -> None:
    assembly = """00001000 <timed>:
 1000: movq %rsi, %rbx
 1001: je 0x1004 <timed+0x4>
 1002: movq %rdx, %rbx
 1003: jmp 0x1004 <timed+0x4>
 1004: movq 0x8(%rbx), %rax
 1005: callq *0x2c0(%rax)
 1006: movq 0x8(%rbx), %rax
 1007: callq *0x2c0(%rax)
"""
    assert not clock_calls(Assembly(assembly).bodies[0x1000], 0x2C0)


def test_clock_provenance_rejects_subregister_clobber() -> None:
    assembly = """00001000 <timed>:
 1000: movq %rsi, %rbx
 1001: movb $0x0, %bl
 1002: movq 0x8(%rbx), %rax
 1003: callq *0x2c0(%rax)
 1004: movq 0x8(%rbx), %rax
 1005: callq *0x2c0(%rax)
"""
    assert not clock_calls(Assembly(assembly).bodies[0x1000], 0x2C0)
