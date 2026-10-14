"""Actual-byte controls for overlapping spills and bounded dispatch guards."""

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
        "mask-widen",
        "mask-remove",
        "partial-index",
        "clobber",
        "bypass",
        "cross-owner-bypass",
        "cross-owner-bypass-byte",
        "missing-relro",
        "short-relro",
        "selected-byte",
        "loader-relocation",
    ],
)
def test_actual_guard_counterexamples(  # noqa: C901, PLR0912, PLR0915 — explicit byte counterexamples
    portable: Path, tmp_path: Path, mutation: str
) -> None:
    import struct

    original = audited(portable, tmp_path / "original.asm")
    elf = Elf(portable)
    proof = original["dispatch_proof"]
    guard = int(proof["entry"], 16)
    mask = int(proof["mask_instruction"], 16)
    address = mask
    if mutation in {"missing-relro", "short-relro", "selected-byte", "loader-relocation"}:
        raw = bytearray(elf.raw)
        table = int(proof["table"], 16)
        if mutation in {"missing-relro", "short-relro"}:
            phoff = struct.unpack_from("<Q", raw, 32)[0]
            phsize, phnum = struct.unpack_from("<HH", raw, 54)
            for n in range(phnum):
                offset = phoff + n * phsize
                kind, _, _, virtual, _, _, _, _ = struct.unpack_from("<IIQQQQQQ", raw, offset)
                if kind == 0x6474E552:
                    if mutation == "missing-relro":
                        struct.pack_into("<I", raw, offset, 0)
                    else:
                        struct.pack_into("<Q", raw, offset + 40, table - virtual + 63)
        elif mutation == "loader-relocation":
            relocation = next(s for s in elf.sections if s[1] == 4 and s[2] & 2)
            struct.pack_into("<Q", raw, relocation[4], table)
        else:
            selected = int(proof["selected_byte"], 16)
            section = next(s for s in elf.sections if s[1] == 1 and s[3] <= selected < s[3] + s[5])
            raw[section[4] + selected - section[3]] = 0xFE
        mutant = tmp_path / "mutant"
        mutant.write_bytes(raw)
    else:
        if mutation == "mask-widen":
            source = "andl $15,%eax"
        elif mutation == "mask-remove":
            source = "nop\nnop\nnop"
        elif mutation == "partial-index":
            address = guard
            selected = int(proof["selected_byte"], 16)
            table = int(proof["table"], 16)
            source = (
                f"movb {selected - guard - 6:#x}(%rip),%al\nandb $7,%al\n"
                f"leaq {table - guard - 15:#x}(%rip),%r8\njmp *(%r8,%rax,8)"
            )
        elif mutation == "clobber":
            source = "xchgq %rax,%rdx"
        else:
            address = guard if mutation == "bypass" else elf.symbol("bench_find_fastmem")
            target = (
                int(proof["branch"], 16) + 1 if mutation == "cross-owner-bypass-byte" else mask + 3
            )
            displacement = target - address - 5
            code = b"\xe9" + struct.pack("<i", displacement)
        if mutation not in {"bypass", "cross-owner-bypass", "cross-owner-bypass-byte"}:
            code = assembled_bytes(tmp_path, source, "x86_64-linux-gnu")
            if mutation == "partial-index":
                code += b"\x90" * (elf.symbols["x86_64.dispatch.dispatchFind"][0][1] - len(code))
        mutant = patch_bytes(portable, tmp_path / "mutant", address, code)
    evidence = audited(mutant, tmp_path / "mutant.asm")
    # Even an arbitrary stored byte cannot introduce a ninth executable target.
    assert evidence["status"] == ("pending-review" if mutation == "selected-byte" else "invalid")
    if mutation != "selected-byte":
        assert evidence["unresolved"]
