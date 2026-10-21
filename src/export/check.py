"""Inspect linked ELF symbols and branches, then execute the consumer."""

import argparse
import re
import struct
import subprocess

from audit import audit_recursion, split_disassembly, targets
from runtime import linux_runner


def output(*args):
    return subprocess.check_output(args, text=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--arch", required=True)
    parser.add_argument("--division", choices=("yes", "no"))
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--shared", action="store_true")
    parser.add_argument("--disabled", action="store_true")
    parser.add_argument("--ecosystem", action="store_true")
    parser.add_argument("binary")
    args = parser.parse_args()
    binary = args.binary
    with open(binary, "rb") as file:
        raw = file.read()
    assert raw[:6] == b"\x7fELF\x02\x01", "expected little-endian ELF64"
    shoff = struct.unpack_from("<Q", raw, 40)[0]
    shsize, shnum = struct.unpack_from("<HH", raw, 58)
    sections = [struct.unpack_from("<IIQQQQIIQQ", raw, shoff + i * shsize) for i in range(shnum)]
    symbols = {}
    dynamic = set()
    for sec in sections:
        if sec[1] not in (2, 11):
            continue
        strings_sec = sections[sec[6]]
        strings = raw[strings_sec[4] : strings_sec[4] + strings_sec[5]]
        for off in range(sec[4], sec[4] + sec[5], sec[9]):
            name_off, info, other, index, value, size = struct.unpack_from("<IBBHQQ", raw, off)
            name = strings[name_off:].split(b"\0", 1)[0].decode()
            if sec[1] == 11:
                dynamic.add(name)
            else:
                symbols[name] = (value, size, info, other, index)
    entries = set()
    for op in ("memcpy", "memmove", "memset"):
        value, size, info, other, index = symbols[op]
        assert index != 0, (op, "undefined")
        if not args.disabled:
            assert info >> 4 != 2, (op, "weak")
        # LLD localizes hidden symbols in the final link.
        assert other & 3 == 2 or info >> 4 == 0, (op, "not hidden/local")
        assert op not in dynamic, (op, "leaks into .dynsym")
        ptr, _, _, _, ptr_index = symbols["p6_" + op]
        sec = sections[ptr_index]
        address = struct.unpack_from("<Q", raw, sec[4] + ptr - sec[3])[0]
        # DSO pointer values are carried by R_*_RELATIVE addends.
        if args.shared:
            for rel in sections:
                if rel[1] == 4:
                    for off in range(rel[4], rel[4] + rel[5], rel[9]):
                        place, _, addend = struct.unpack_from("<QQq", raw, off)
                        if place == ptr:
                            address = addend
        assert (address == value) != args.disabled, (op, "wrong provider", hex(address), hex(value))
        entries.add(value)
    if args.division is not None:
        assert ("__udivti3" in symbols) == (args.division == "yes"), (
            "division fixture did not control compiler-rt"
        )
    disasm = output("llvm-objdump", "-d", "--no-show-raw-insn", binary)
    functions = split_disassembly(disasm)

    for op in () if args.ecosystem else ("copy", "move", "set"):
        target = symbols["mem" + ("cpy" if op == "copy" else op)][0]
        for prefix in ("p6_", "p6_c_"):
            body = functions[symbols[prefix + op][0]]
            branches = targets(body)
            assert target in branches, (prefix + op, "wrong memory call", body)
            fortified = {
                v[0]
                for k, v in symbols.items()
                if re.fullmatch(r"__(memcpy|memmove|memset)_chk", k)
            }
            assert not fortified.intersection(branches), (prefix + op, "unexpected fortified call")
    if not args.disabled:
        # The x86_64 dispatch stubs jump through pointers, which the audit
        # does not follow. Its level kernels, resolvers, and generic entries
        # are roots too (docs/slop/runtime-dispatch.md).
        roots = {
            value[0]
            for name, value in symbols.items()
            if value[2] & 15 == 2 and re.fullmatch(r"fastmem_x86_\w+", name)
        }
        audit_recursion(functions, symbols, entries, roots)
    ran = False
    if args.run:
        runner = linux_runner(args.arch)
        if runner is None:
            print(f"SKIP runtime {binary}: no compatible Linux runner")
        else:
            subprocess.run(runner + [binary], check=True, timeout=120)
            ran = True
    print(
        f"PASS {binary}: "
        + (
            "opt-out keeps compiler-rt"
            if args.disabled
            else "ABI identity, strong/hidden, no kernel recursion, no dynsym"
            + (", Zig/C call binding" if not args.ecosystem else "")
        )
        + (", runtime Zig/C" if ran else ", static checks only")
    )


if __name__ == "__main__":
    main()
