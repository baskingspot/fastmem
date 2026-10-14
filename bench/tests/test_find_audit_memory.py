"""Actual-byte controls for overlapping spills and static dispatch-slot accesses."""

from pathlib import Path

import pytest

from fastmem_bench.find_audit import Assembly, Elf, clock_calls
from tests.test_find_codegen import assembled_bytes, audited, patch_bytes
from tests.test_find_codegen import portable as portable  # noqa: PLC0414 -- pytest fixture export


@pytest.mark.parametrize("offset", [-24, -23, -16, -15, -9, -8])
def test_clock_spills_use_byte_ranges(offset: int) -> None:
    body = Assembly(f"""00001000 <timed>:
 1000: movq %rsi, -0x10(%rbp)
 1001: movq $0x0, {offset:#x}(%rbp)
 1002: movq -0x10(%rbp), %rbx
 1003: movq 0x8(%rbx), %rax
 1004: callq *0x2c0(%rax)
 1005: movq 0x8(%rbx), %rax
 1006: callq *0x2c0(%rax)
 1007: retq
""").bodies[0x1000]
    assert bool(clock_calls(body, 0x2C0)) == (offset in {-24, -8})


@pytest.mark.parametrize("dest", ["0x8(%rbx)", "0x2c0(%rax)"])
def test_clock_object_writes_drop_identities(dest: str) -> None:
    body = Assembly(f"""00001000 <timed>:
 1000: movq %rsi, %rbx
 1001: movq 0x8(%rbx), %rax
 1002: movq %rdx, {dest}
 1003: movq 0x8(%rbx), %rax
 1004: callq *0x2c0(%rax)
 1005: movq 0x8(%rbx), %rax
 1006: callq *0x2c0(%rax)
 1007: retq
""").bodies[0x1000]
    assert not clock_calls(body, 0x2C0)


@pytest.mark.parametrize("dest", ["[x19, #0x8]", "[x8, #0x2c0]"])
def test_arm_clock_object_writes_drop_identities(dest: str) -> None:
    body = Assembly(f"""00001000 <timed>:
 1000: mov x19, x1
 1004: ldp x0, x8, [x19]
 1008: str x9, {dest}
 100c: ldp x0, x8, [x19]
 1010: ldr x9, [x8, #0x2c0]
 1014: blr x9
 1018: ldp x0, x8, [x19]
 101c: ldr x9, [x8, #0x2c0]
 1020: blr x9
 1024: ret
""").bodies[0x1000]
    assert not clock_calls(body, 0x2C0)


@pytest.mark.parametrize("mutation", ["overlap", "io-store", "vtable-store"])
def test_actual_clock_memory_counterexamples(portable: Path, tmp_path: Path, mutation: str) -> None:
    elf = Elf(portable)
    address = elf.symbol("bench_find.runFastmemDirect")
    if mutation == "overlap":
        prefix = "movq %rsi,-0x10(%rbp)\nmovq $0,-0xf(%rbp)\nmovq -0x10(%rbp),%rbx\n"
    else:
        dest = "8(%rbx)" if mutation == "io-store" else "0x2c0(%rax)"
        prefix = "movq %rsi,%rbx\nmovq 8(%rbx),%rax\nmovq %rdx," + dest + "\n"
    code = assembled_bytes(
        tmp_path,
        prefix + (f"movq 8(%rbx),%rax\ncall *{elf.clock_offset()}(%rax)\n" * 2) + "ret",
        "x86_64-linux-gnu",
    )
    mutant = patch_bytes(portable, tmp_path / "mutant", address, code)
    evidence = audited(mutant, tmp_path / "mutant.asm")
    assert evidence["status"] == "invalid"
    assert evidence["unresolved"]
    assert not any(
        call["caller_address"] == hex(address) for call in evidence["clock_calls_for_manual_review"]
    )


@pytest.mark.parametrize(
    "mutation",
    [
        "absolute",
        "partial",
        "overlap-before",
        "last-byte",
        "address-escape",
        "immediate-comment",
        "segment-absolute",
        "wide-atomic",
        "unbounded-bit-store",
    ],
)
def test_actual_static_slot_counterexamples(portable: Path, tmp_path: Path, mutation: str) -> None:
    elf = Elf(portable)
    slot = elf.symbol("x86_64.dispatch.find_fn")
    address = elf.symbol("bench_find_fastmem")
    if mutation == "absolute":
        source = f"movq $0,{slot:#x}"
    elif mutation == "segment-absolute":
        source = f"movq $0,%ds:{slot:#x}"
    elif mutation == "wide-atomic":
        source = f"cmpxchg16b {slot & ~15:#x}"
    elif mutation == "unbounded-bit-store":
        source = f"btsq %rcx,{slot - 128:#x}"
    elif mutation in {"partial", "last-byte"}:
        offset = 1 if mutation == "partial" else 7
        source = f"movb $0,{slot + offset - address - 7:#x}(%rip)"
    elif mutation == "overlap-before":
        source = f"movq $0,{slot - 4 - address - 11:#x}(%rip)"
    elif mutation == "immediate-comment":
        source = f"movq $-1,{slot - address - 11:#x}(%rip)"
    else:
        source = f"movabsq ${slot:#x},%rax"
    code = assembled_bytes(tmp_path, source + "\nxorl %eax,%eax\nret", "x86_64-linux-gnu")
    mutant = patch_bytes(portable, tmp_path / "mutant", address, code)
    evidence = audited(mutant, tmp_path / "mutant.asm")
    assert evidence["status"] == "invalid"
    assert evidence["unresolved"]
