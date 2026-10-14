"""Mutation fixtures prove the delegation audit follows callees, including tail calls."""

import shutil
import struct
import subprocess
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from fastmem_bench.find_audit import (
    ARM_AUTH_CALLS,
    ARM_AUTH_TAILS,
    Assembly,
    Elf,
    backedges,
    clock_calls,
    guard_call,
)
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
    source = Path(__file__).resolve().parents[2]
    revision = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=source, check=True, capture_output=True, text=True
    ).stdout.strip()
    # Label the merged-source worktree build, rather than an obsolete fixture.
    (destination / "source-revision.txt").write_text(revision + "-find-audit-worktree\n")
    subprocess.run(
        [
            "zig",
            "build",
            "bench-find-bin",
            "-j2",
            "-Dtarget=x86_64-linux-gnu",
            "-Dcpu=x86_64",
            "-Doptimize=ReleaseFast",
            f"-Drev={revision}-find-audit-worktree",
            "--prefix",
            str(destination),
        ],
        cwd=source,
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


def test_real_portable_eight_closures_and_clock_identities(portable: Path, tmp_path: Path) -> None:
    evidence = audited(portable, tmp_path / "executable.asm")
    assert evidence["status"] == "pending-review"
    assert evidence["anti_hoist_status"] == "manual-review-required"
    assert not evidence["delegations"]
    assert not evidence["unresolved"]
    proof = evidence["dispatch_proof"]
    assert len(proof["entries"]) == 8
    assert proof["mask"] == 7
    assert proof["index_bits"] == 64
    assert proof["scale"] == 8
    assert proof["storage_bytes"] == 64
    assert proof["storage_read_only"]
    assert "x86_64.dispatch.find_fn" not in Elf(portable).symbols
    assert (
        (portable.parent.parent / "source-revision.txt")
        .read_text()
        .endswith("-find-audit-worktree\n")
    )
    closure = {f["address"] for f in evidence["followed_functions"]}
    assert all(e["address"] in closure for e in proof["entries"])
    assert sum(f["symbol"] == "find.twoWay" for f in evidence["followed_functions"]) == 7
    assert len(evidence["dispatch_calls"]) == 1
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
        "mask-range",
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
        site = original["dispatch_calls"][0]
        owner = int(site["caller_address"], 16)
        inst = next(i for i in asm.bodies[owner] if hex(i.address) == site["address"])
        operand = "*%r11" if mutation == "unknown-indirect" else "*0x2c0(%rax)"
        replacement = f" {inst.address:x}: callq {operand}"
    elif mutation == "unproven-table":
        owner = int(original["dispatch_proof"]["entry"], 16)
        inst = next(i for i in asm.bodies[owner] if i.op == "jmpq")
        replacement = f" {inst.address:x}: {inst.op} {inst.args.replace(',8)', ',4)')}"
    else:
        owner = int(original["dispatch_proof"]["entry"], 16)
        inst = next(i for i in asm.bodies[owner] if i.op == "andl")
        replacement = f" {inst.address:x}: andl $0xf, %eax"
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


@pytest.mark.parametrize("index", range(8))
def test_real_elf_pointer_mutations_fail_closed(portable: Path, tmp_path: Path, index: int) -> None:
    evidence = audited(portable, tmp_path / "original.asm")
    proof = evidence["dispatch_proof"]
    address = int(proof["table"], 16) + index * 8
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


def assembled_bytes(tmp_path: Path, source: str, target: str) -> bytes:
    if not all(shutil.which(tool) for tool in ("zig", "llvm-objdump")):
        pytest.skip("requires Nix Zig/LLVM tools")
    asm, obj = tmp_path / "negative.s", tmp_path / "negative.o"
    asm.write_text(".text\n.global repro\nrepro:\n" + source + "\n")
    subprocess.run(
        ["zig", "cc", "-target", target, "-c", str(asm), "-o", str(obj)],
        check=True,
        capture_output=True,
        timeout=120,
    )
    elf = Elf(obj)
    text = next(s for s in elf.sections if s[1] == 1 and s[2] & 4)
    return elf.raw[text[4] : text[4] + text[5]]


def patch_bytes(binary: Path, destination: Path, address: int, code: bytes) -> Path:
    elf = Elf(binary)
    section = next(s for s in elf.sections if s[1] == 1 and s[3] <= address < s[3] + s[5])
    offset = section[4] + address - section[3]
    raw = bytearray(elf.raw)
    raw[offset : offset + len(code)] = code
    destination.write_bytes(raw)
    return destination


@pytest.mark.parametrize("op", sorted(ARM_AUTH_CALLS | ARM_AUTH_TAILS))
def test_actual_arm_authenticated_edges_fail_closed(tmp_path: Path, op: str) -> None:
    operand = "x9" if op.endswith("z") else "x9, x10"
    assembled_bytes(tmp_path, f".arch armv8.3-a\n{op} {operand}\nret", "aarch64-linux-gnu")
    text = subprocess.run(
        ["llvm-objdump", "-d", "--no-show-raw-insn", str(tmp_path / "negative.o")],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    asm = Assembly(text)
    inst = asm.bodies[asm.roots(["repro"])[0]][0]
    assert inst.op == op
    assert inst.target() is None
    assert len(scan(text, ["repro"])["unresolved"]) == 1


@pytest.mark.parametrize("op", ["lcallq", "ljmpq"])
def test_actual_x86_far_edges_fail_closed(portable: Path, tmp_path: Path, op: str) -> None:
    elf = Elf(portable)
    address, size, _ = elf.symbols["bench_find_fastmem"][0]
    code = assembled_bytes(tmp_path, f"{op} *(%r9)\nret", "x86_64-linux-gnu")
    assert len(code) <= size
    mutant = patch_bytes(
        portable, tmp_path / "mutant", address, code + b"\x90" * (size - len(code))
    )
    result = audited(mutant, tmp_path / "mutant.asm")
    assert result["status"] == "invalid"
    assert any(item["caller_address"] == hex(address) for item in result["unresolved"])
    assert op in (tmp_path / "mutant.asm").read_text()


@pytest.mark.parametrize("op", ["lcall", "lcallw", "lcalll", "lcallq"])
def test_far_calls_never_receive_clock_exemption(op: str) -> None:
    body = Assembly(f"""00001000 <timed>:
 1000: movq %rsi, %rbx
 1001: movq 0x8(%rbx), %rax
 1002: {op} *0x2c0(%rax)
 1003: movq 0x8(%rbx), %rax
 1004: {op} *0x2c0(%rax)
 1005: retq
""").bodies[0x1000]
    assert not clock_calls(body, 0x2C0)


@pytest.mark.parametrize("op", ["ljmp", "ljmpw", "ljmpl", "ljmpq"])
def test_far_tails_do_not_fall_through_to_clocks(op: str) -> None:
    body = Assembly(f"""00001000 <timed>:
 1000: movq %rsi, %rbx
 1001: {op} *(%r9)
 1002: movq 0x8(%rbx), %rax
 1003: callq *0x2c0(%rax)
 1004: movq 0x8(%rbx), %rax
 1005: callq *0x2c0(%rax)
 1006: retq
""").bodies[0x1000]
    assert not clock_calls(body, 0x2C0)


def test_arm_hbc_conditional_edge_follows_target() -> None:
    evidence = scan(
        """00001000 <root>:
 1000: bc.eq 0x2000 <helper>
00002000 <helper>:
 2000: blr x9
""",
        ["root"],
    )
    assert evidence["followed_callees"] == ["helper", "root"]
    assert evidence["unresolved"][0]["caller"] == "helper"


@pytest.mark.parametrize("mutation", ["index-scale", "xchg-clock"])
def test_actual_portable_byte_counterexamples_fail_closed(
    portable: Path,
    tmp_path: Path,
    mutation: str,
) -> None:
    original = audited(portable, tmp_path / "original.asm")
    elf = Elf(portable)
    asm = Assembly((tmp_path / "original.asm").read_text())
    if mutation == "index-scale":
        owner = int(original["dispatch_proof"]["entry"], 16)
        inst = next(i for i in asm.bodies[owner] if i.op == "jmpq")
        address = inst.address
        source = "jmp " + inst.args.replace(",8)", ",4)")
    else:
        address = elf.symbol("bench_find.runFastmemDirect")
        source = (
            "movq %rsi,%rbx\nxchgq %rbx,%rdx\n"
            f"movq 8(%rbx),%rax\ncall *{elf.clock_offset()}(%rax)\n"
            f"movq 8(%rbx),%rax\ncall *{elf.clock_offset()}(%rax)\nret"
        )
    code = assembled_bytes(tmp_path, source, "x86_64-linux-gnu")
    mutant = patch_bytes(portable, tmp_path / "mutant", address, code)
    result = audited(mutant, tmp_path / "mutant.asm")
    assert result["status"] == "invalid"
    assert result["unresolved"]
    if mutation == "xchg-clock":
        assert "xchgq" in (tmp_path / "mutant.asm").read_text()
        assert not any(
            c["caller_address"] == hex(address) for c in result["clock_calls_for_manual_review"]
        )


@pytest.mark.parametrize(
    "clobber",
    [
        "xchgq %rbx, %rdx",
        "xaddq %rbx, %rdx",
        "cmpxchgq %rdx, %rbx",
        "mulq %rbx",
        "imulq %rbx",
        "divq %rbx",
        "cpuid",
        "xgetbv",
        "movb $0x0, %bl",
        "popq %rbx",
        "mystery %rdx",
        "loop 0x1002",
    ],
)
def test_clock_clobber_families_fail_closed(clobber: str) -> None:
    body = Assembly(f"""00001000 <timed>:
 1000: movq %rsi, %rbx
 1001: {clobber}
 1002: movq 0x8(%rbx), %rax
 1003: callq *0x2c0(%rax)
 1004: movq 0x8(%rbx), %rax
 1005: callq *0x2c0(%rax)
 1006: retq
""").bodies[0x1000]
    assert not clock_calls(body, 0x2C0)


@pytest.mark.parametrize(
    "clobber",
    [
        "ldp x19, x20, [x2]",
        "ldr x9, [x19], #0x8",
        "str x9, [x19, #0x8]!",
        "ldrb w9, [x19], #0x1",
        "bl 0x2000",
    ],
)
def test_arm_multi_destination_writeback_and_call_clobbers(clobber: str) -> None:
    # For BL use caller-saved x1; for writeback/paired loads use x19.
    register = "x1" if clobber.startswith("bl ") else "x19"
    body = Assembly(f"""00001000 <timed>:
 1000: mov {register}, x1
 1004: {clobber}
 1008: ldp x0, x8, [{register}]
 100c: ldr x9, [x8, #0x2c0]
 1010: blr x9
 1014: ldp x0, x8, [{register}]
 1018: ldr x9, [x8, #0x2c0]
 101c: blr x9
 1020: ret
""").bodies[0x1000]
    assert not clock_calls(body, 0x2C0)


def test_unknown_write_drops_spilled_provenance() -> None:
    body = Assembly("""00001000 <timed>:
 1000: movq %rsi, -0x10(%rbp)
 1001: mystery
 1002: movq -0x10(%rbp), %rbx
 1003: movq 0x8(%rbx), %rax
 1004: callq *0x2c0(%rax)
 1005: movq 0x8(%rbx), %rax
 1006: callq *0x2c0(%rax)
""").bodies[0x1000]
    assert not clock_calls(body, 0x2C0)


def test_clock_cfg_loop_join_drops_identity() -> None:
    body = Assembly("""00001000 <timed>:
 1000: movq %rsi, %rbx
 1001: movq 0x8(%rbx), %rax
 1002: callq *0x2c0(%rax)
 1003: je 0x1006
 1004: xchgq %rbx, %rdx
 1005: jmp 0x1003
 1006: movq 0x8(%rbx), %rax
 1007: callq *0x2c0(%rax)
 1008: retq
""").bodies[0x1000]
    assert not clock_calls(body, 0x2C0)


@pytest.mark.parametrize("tail", ["br x9", "braa x9, x10", "braaz x9"])
def test_indirect_tail_does_not_fall_through_to_clocks(tail: str) -> None:
    body = Assembly(f"""00001000 <timed>:
 1000: mov x19, x1
 1004: {tail}
 1008: ldp x0, x8, [x19]
 100c: ldr x9, [x8, #0x2c0]
 1010: blr x9
 1014: ldp x0, x8, [x19]
 1018: ldr x9, [x8, #0x2c0]
 101c: blr x9
""").bodies[0x1000]
    assert not clock_calls(body, 0x2C0)


@pytest.mark.parametrize(
    ("index", "base", "target"),
    [("%rax", "%r8", "%r11"), ("%r10", "%rbx", "%r9"), ("%rdx", "%r11", "%rax")],
)
@pytest.mark.parametrize("layout", ["direct", "scaled", "byte-mask"])
def test_guard_independent_register_allocation(
    index: str, base: str, target: str, layout: str
) -> None:
    low = {"%rax": "%eax", "%r10": "%r10d", "%rdx": "%edx"}[index]
    byte = {"%rax": "%al", "%r10": "%r10b", "%rdx": "%dl"}[index]
    mask = f"andl $0x7, {low}"
    if layout == "byte-mask":
        mask = f"andb $0x7, {byte}\n 1002: movzbl {byte}, {low}"
    access = f"jmpq *({base},{index},8)"
    if layout == "scaled":
        access = (
            f"shlq $0x3, {index}\n 1005: movq ({base},{index}), {target}\n 1006: jmpq *{target}"
        )
    body = Assembly(f"""00001000 <guard>:
 1000: movzbl 0x100(%rip), {low} # 0x3000 <selected>
 1001: {mask}
 1003: nop
 1004: leaq 0x100(%rip), {base} # 0x4000 <table>
 1007: {access}
""").bodies[0x1000]
    # Synthetic addresses must be in execution order for the incoming-range check.
    body = [type(i)(0x1000 + n, i.op, i.args, i.text) for n, i in enumerate(body)]
    proof = guard_call(body, 0x3000, set())
    assert proof["table"] == "0x4000"
    assert proof["mask"] == 7
    for inst in body[1:]:
        with pytest.raises(ValueError, match="bypasses"):
            guard_call(body, 0x3000, {inst.address})


@pytest.mark.parametrize(
    "clobber", ["xchgq %rax, %rdx", "mulq %rbx", "cpuid", "movb $0, %al", "mystery %rdx"]
)
def test_guard_unknown_effects_fail_closed(clobber: str) -> None:
    body = Assembly(f"""00001000 <guard>:
 1000: movzbl 0x100(%rip), %eax # 0x3000 <selected>
 1001: andl $0x7, %eax
 1002: {clobber}
 1003: leaq 0x100(%rip), %r8 # 0x4000 <table>
 1004: jmpq *(%r8,%rax,8)
""").bodies[0x1000]
    with pytest.raises(ValueError, match="guard instruction"):
        guard_call(body, 0x3000, set())
