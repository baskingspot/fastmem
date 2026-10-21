"""Check the x86_64 runtime dispatch of a baseline build (docs/slop/runtime-dispatch.md).

Arguments: the symbol prefix (fastmem_x86_<instance>_), the baseline codegen
probe object, the ABI small limit, then one triple per level:
LEVEL LEVEL_OBJECT COMPTIME_PROBE_OBJECT.

1. Each C-ABI entry handles sizes through the configured ABI limit. Every such size returns
   without a pointer read, a symbol reference, or an AVX instruction. Larger
   sizes load the pointer of the operation and jump through it.
2. The inline classes stay inline up to 128 bytes; larger sizes jump or call
   through the pointer of the same operation.
3. Every level, resolver, and generic entry is a GLOBAL HIDDEN function whose
   name carries the package instance id.
4. The kernels of each level object are instruction-identical to the kernels
   of the comptime build for the same CPU (src/x86_64/codegen.zig probes).
"""

import json
import re
import subprocess
import sys

SMALL_MAX = 128
INLINE_MAX = 128
FIXED_MAX = 256


def run(*args):
    return subprocess.check_output(args, text=True)


class Object:
    def __init__(self, path):
        self.path = path
        sections = {}
        for line in run("llvm-readelf", "-SW", path).splitlines():
            match = re.match(r"\s*\[\s*(\d+)\]\s+(\S+)", line)
            if match:
                sections[int(match[1])] = match[2]
        self.functions = {}
        self.objects = {}
        self.binding = {}
        for line in run("llvm-readelf", "-sW", path).splitlines():
            fields = line.split()
            if len(fields) != 8 or not fields[0].endswith(":"):
                continue
            _, value, size, kind, bind, vis, index, name = fields
            if kind == "FUNC":
                self.functions[name] = (int(value, 16), int(size))
                self.binding[name] = (bind, vis)
            elif kind == "OBJECT" and index.isdigit():
                self.objects[(sections[int(index)], int(value, 16))] = name
        self.owner = {}
        for name, (start, size) in self.functions.items():
            for address in range(start, start + size):
                # Prefer the exported name for aliases.
                if address not in self.owner or not self.owner[address].startswith(("x86_64.", "move.", "set.")):
                    self.owner[address] = name
        self.lines = {}
        current = None
        for line in run("llvm-objdump", "-dr", "--no-show-raw-insn", path).splitlines():
            header = re.match(r"^([0-9a-f]+) <(.+)>:$", line)
            if header:
                current = int(header[1], 16)
                self.lines.setdefault(current, [])
            elif current is not None and line.strip():
                self.lines[current].append(line)

    def body(self, name):
        start, size = self.functions[name]
        result = []
        for line in self.lines[start]:
            # Relocation lines have the same "offset: text" shape.
            inst = re.match(r"^\s*([0-9a-f]+):\s+(.*)$", line)
            if inst:
                address = int(inst[1], 16)
                if address >= start + size:
                    break
                result.append((address, " ".join(inst[2].split("#")[0].split())))
        return result

    def pointer(self, relocation):
        """Name the object that a PC32 load relocation reads."""
        match = re.fullmatch(r"R_X86_64_PC32 (\S+?)([+-]0x[0-9a-f]+)", relocation)
        if not match:
            return None
        return self.objects.get((match[1], int(match[2], 16) + 4))


def require(condition, message):
    if not condition:
        raise SystemExit(f"x86_64 dispatch: {message}")


def instructions(code):
    return [text for _, text in code if not text.startswith("R_X86_64")]


def transfers(obj, code):
    """Pointer names of every indirect jump or call, and every direct call."""
    loads = {}
    indirect = []
    direct = []
    for (_, text), nxt in zip(code, code[1:] + [(0, "")]):
        load = re.fullmatch(r"movq\s+\(%rip\), (%r\w+)", text)
        if load and nxt[1].startswith("R_X86_64"):
            loads[load[1]] = obj.pointer(nxt[1])
        jump = re.fullmatch(r"(jmpq|callq)\s+\*(%r\w+)", text)
        if jump:
            indirect.append(loads.get(jump[2]))
        if re.match(r"callq?\s+[0-9a-f]", text):
            direct.append(text)
    return indirect, direct


SMALL_SIZES = range(129)


def trace(obj, name, n, *, allow_direct=False):
    """Follow `name` with RDX = n and unknown pointers, to ret or an indirect jump."""
    code = obj.body(name)
    order = [a for a, t in code if not t.startswith("R_X86_64")]
    at = {a: t for a, t in code if not t.startswith("R_X86_64")}
    following = {a: b for a, b in zip(order, order[1:])}
    # A relocation belongs to the instruction that contains its offset.
    relocs = {}
    for a, t in code:
        if t.startswith("R_X86_64"):
            relocs.setdefault(max(i for i in order if i <= a), []).append(t)
    pc, flags, visited = order[0], None, []
    for _ in range(200):
        insn = at[pc]
        visited.append(insn)
        visited.extend(relocs.get(pc, []))
        nxt = following.get(pc)
        op = insn.split()[0]
        if op.startswith("ret"):
            return visited, "ret"
        if re.fullmatch(r"jmpq?\s+\*%r\w+", insn):
            return visited, "indirect"
        cmp = re.fullmatch(r"cmpq\s+\$(0x[0-9a-f]+|[0-9]+), %rdx", insn)
        if cmp:
            flags = (n == int(cmp[1], 0), n < int(cmp[1], 0))
        elif insn == "testq %rdx, %rdx":
            flags = (n == 0, False)
        elif op.startswith("j"):
            target = int(re.search(r"\b(?:0x)?([0-9a-f]+) <", insn)[1], 16)
            if op != "jmp":
                require(flags is not None, f"{name}/{n}: unknown flags at {insn}")
                equal, below = flags
                take = {"je": equal, "jne": not equal, "jb": below, "jae": not below,
                        "jbe": below or equal, "ja": not below and not equal}.get(op)
                require(take is not None, f"{name}/{n}: unsupported branch {insn}")
            if op == "jmp" or take:
                if target not in at and allow_direct:
                    return visited, obj.owner[target]
                require(target in at, f"{name}/{n} leaves the entry: {insn}")
                pc = target
                continue
        elif re.match(r"\w+\s+.*%rdx$", insn) and not op.startswith(("mov", "cmp", "test")):
            flags = None  # RDX changed.
        pc = nxt
    raise SystemExit(f"x86_64 dispatch: {name}/{n} did not terminate")


def pointer_tables(obj):
    entries = {}
    section = None
    for line in run("llvm-readelf", "-rW", obj.path).splitlines():
        header = re.match(r"Relocation section '([^']+)'", line)
        if header:
            section = header[1]
        fields = line.split()
        if section == ".rela.rodata" and len(fields) == 7 and fields[2] == "R_X86_64_64":
            require(fields[-2:] == ["+", "0"], "dispatch table has a nonzero function offset")
            entries[int(fields[0], 16)] = fields[4]
    return entries


def check_probe(obj):
    evidence = {}
    dis = run("llvm-objdump", "-dr", "--no-show-raw-insn", obj.path)
    require(
        not re.search(r"(?<![\w.])(?:__)?(?:memcpy|memmove|memset)(?=[+@>\s-]|$)", dis),
        "memory symbol reference",
    )
    for op, pointer in (("memcpy", "copy_fn"), ("memmove", "move_fn"), ("memset", "set_fn")):
        entry = f"x86_64.dispatch.{op}"
        abi = {"memcpy": "copy", "memmove": "move", "memset": "set"}[op]
        require(obj.functions[f"probe_abi_{abi}"][0] == obj.functions[entry][0], f"abi.{op} is not the entry")
        paths = {}
        first_stores = {}
        for n in range(SMALL_MAX + 1):
            code, end = trace(obj, entry, n)
            text = [t for t in code if not t.startswith("R_X86_64")]
            require(end == "ret", f"{entry}/{n} does not return in the entry: {end}")
            require(not any(r.startswith("R_X86_64") for r in code), f"{entry}/{n} reads a pointer or a symbol")
            require(not any(re.match(r"(call|jmp)q?\s+\*", t) for t in text), f"{entry}/{n} branches indirectly")
            require("%ymm" not in " ".join(text) and "%zmm" not in " ".join(text), f"{entry}/{n} uses AVX")
            paths[n] = len(text)
            stores = [i + 1 for i, insn in enumerate(text)
                      if re.search(r", [^%]*\([^)]*\)$", insn)]
            first_stores[n] = stores[0] if stores else None
            if n == 0:
                require(not stores and len(text) <= 6, f"{entry}/0 exceeds the tiny-return budget")
            elif n < 4:
                budget = 10 if op != "memset" else 5
                require(stores and stores[0] <= budget, f"{entry}/{n} exceeds the first-store budget")
                require(len(text) <= (14 if op != "memset" else 11), f"{entry}/{n} exceeds the byte-class budget")
            else:
                budgets = (21, 23, 26) if op != "memset" else (20, 25, 22)
                budget = budgets[0 if n < 16 else 1 if n < 64 else 2]
                require(len(text) <= budget, f"{entry}/{n} exceeds the small-class budget")
        # Every decision uses an immediate comparison with unchanged RDX.
        # The boundary points cover every unsigned interval of that tree.
        boundaries = {SMALL_MAX + 1, 4096, 1 << 26, (1 << 64) - 1}
        for insn in instructions(obj.body(entry)):
            match = re.fullmatch(r"cmpq\s+\$(0x[0-9a-f]+|[0-9]+), %rdx", insn)
            if match:
                value = int(match[1], 0)
                boundaries.update(n for n in (value - 1, value, value + 1) if n > SMALL_MAX)
        for n in sorted(boundaries):
            code, end = trace(obj, entry, n)
            indirect, direct = transfers(obj, [(0, t) for t in code])
            require(end == "indirect" and indirect == [f"x86_64.dispatch.{pointer}"] and not direct,
                    f"{entry}/{n} does not jump through {pointer}: {end} {indirect}")
            paths[n] = len([t for t in code if not t.startswith("R_X86_64")])
        evidence[op] = {"instructions_by_size": paths, "first_store_by_size": first_stores}
    for op, pointer in (("copy", "copy_fn"), ("move", "move_fn"), ("set", "set_fn")):
        for n in range(1, FIXED_MAX + 1):
            code = obj.body(f"probe_{op}_{n}")
            text = "\n".join(instructions(code))
            indirect, direct = transfers(obj, code)
            require(not direct, f"fixed {op}/{n} has a direct call")
            if n <= INLINE_MAX:
                require(not re.search(r"\b(?:call\w*|jmp\w*)\b", text), f"fixed {op}/{n} calls out")
                require("%ymm" not in text and "%zmm" not in text, f"fixed {op}/{n} uses AVX in a baseline build")
            else:
                require(indirect == [f"x86_64.dispatch.{pointer}"], f"fixed {op}/{n} does not use {pointer}: {indirect}")
        code = obj.body(f"probeRuntime{op.capitalize()}")
        indirect, direct = transfers(obj, code)
        require(indirect == [f"x86_64.dispatch.{pointer}"], f"runtime {op} large path: {indirect}")
        for n in SMALL_SIZES:
            _, end = trace(obj, f"probeRuntime{op.capitalize()}", n)
            require(end == "ret", f"inline {op}/{n} reaches a bounded pointer")
        for n in (129, 256, 4096, (1 << 64) - 1):
            _, end = trace(obj, f"probeRuntime{op.capitalize()}", n)
            require(end == "indirect", f"inline {op}/{n} misses the bounded pointer")
    names = [f"{PREFIX}{level}_{op}" for level in LEVELS
             for op in ("memmove", "memset", "memmove_above_small", "memset_above_small", "name")]
    names += [f"{PREFIX}{kind}_{op}" for kind in ("resolve", "generic") for op in ("memcpy", "memmove", "memset")]
    for name in names:
        require(obj.binding.get(name) == ("GLOBAL", "HIDDEN"), f"{name} is not GLOBAL HIDDEN: {obj.binding.get(name)}")
    for op in ("memcpy", "memmove", "memset"):
        text = "\n".join(t for _, t in obj.body(f"{PREFIX}resolve_{op}"))
        require("cpuid" in text and "xgetbv" in text, f"resolver {op} does not read CPUID and XCR0")
        # LLVM lowers the three selections to indexed pointer tables.
        tables = pointer_tables(obj)
        for kernel in ("memcpy", "memmove", "memset"):
            base = next((a for a, name in tables.items() if name == f"{PREFIX}generic_{kernel}"), None)
            require(base is not None, f"missing generic {kernel} table entry")
            relocation = ".rodata" + (f"+{base:#x}" if base else "")
            require(f"R_X86_64_32S {relocation}" in text.splitlines(),
                    f"resolver {op} does not read the {kernel} table")
            for i, level in enumerate(LEVELS, 1):
                target = "memset" if kernel == "memset" else "memmove"
                want = f"{PREFIX}{level}_{target}_above_small"
                require(tables.get(base + 8 * i) == want,
                        f"resolver {op} {kernel}/{level} does not install {want}")
    if SMALL_MAX == 64:
        for op in ("memcpy", "memmove", "memset"):
            counts = {}
            for n in range(65, 129):
                code, end = trace(obj, f"{PREFIX}generic_{op}", n, allow_direct=True)
                require(end == "ret", f"generic {op}/{n} leaves its SSE2 class")
                text = "\n".join(code)
                require(not re.search(r"push|pop|call|%[yz]mm|%rsp", text),
                        f"generic {op}/{n} has a frame, call, or AVX instruction")
                require(len(code) <= (17 if op == "memset" else 20),
                        f"generic {op}/{n} exceeds its bounded instruction budget")
                counts[n] = len(code)
            evidence[f"generic_{op}"] = counts
    unexpected = sorted(n for n in obj.functions if n.startswith("fastmem_x86_") and n not in names)
    require(not unexpected, f"dispatch symbols without the instance prefix: {unexpected}")
    return evidence


def canonical(level, name):
    name = re.sub(rf"^{re.escape(PREFIX)}{level}_mem(move|set)$", lambda m: "move.moveKernel" if m[1] == "move" else "set.kernel", name)
    return name.removeprefix("x86_64.")


def normalized(obj, level, entry):
    """Instruction text of `entry` and every function that it branches to."""
    result = {}
    pending = [entry]
    while pending:
        name = pending.pop()
        key = canonical(level, name)
        if key in result:
            continue
        lines = []
        for _, text in obj.body(name):
            if text.startswith("nop"):
                continue

            def target(match):
                address = int(match[1], 16)
                owner = obj.owner[address]
                if owner != name:
                    pending.append(owner)
                # Padding changes when the bounded entry shares a leaf.
                # Compare branch destinations by instruction index, not byte offset.
                body = [(a, t) for a, t in obj.body(owner)
                        if not t.startswith(("nop", "R_X86_64"))]
                index = next(i for i, (a, _) in enumerate(body) if a >= address)
                return f"<{canonical(level, owner)}:i{index}>"

            lines.append(re.sub(r"\b(?:0x)?([0-9a-f]+) <[^>]+>", target, text))
        result[key] = lines
    return result


LEVELS = []
PREFIX = ""
# REP and NT use per level (src/x86_64/tuning.zig and docs/slop/x86_64.md).
_INTEL = {"move": {"rep": True, "nt": True}, "set": {"rep": True, "nt": True}}
_AMD = {"move": {"rep": False, "nt": True}, "set": {"rep": False, "nt": False}}
_NONE = {"move": {"rep": False, "nt": False}, "set": {"rep": False, "nt": False}}
POLICY = {
    "sapphirerapids": _INTEL,
    "graniterapids": _INTEL,
    "znver4": _AMD,
    "znver5": {"move": {"rep": False, "nt": True}, "set": {"rep": False, "nt": False}},  # a07cd08 gates the znver5 no-NT memset
    "x86_64_v3": _NONE,
    "x86_64_v4": _NONE,
}


def main():
    global PREFIX, SMALL_MAX  # noqa: PLW0603 — one checker invocation, one prefix
    PREFIX = sys.argv[1]
    require(re.fullmatch(r"fastmem_x86_[0-9a-f]{16}_", PREFIX), f"bad symbol prefix {PREFIX}")
    probe = Object(sys.argv[2])
    SMALL_MAX = int(sys.argv[3])
    require(SMALL_MAX in (64, 128), "invalid small limit")
    triples = sys.argv[4:]
    require(len(triples) % 3 == 0 and triples, "expected LEVEL LEVEL_OBJECT PROBE_OBJECT triples")
    LEVELS.extend(triples[0::3])
    evidence = {"stubs": check_probe(probe), "levels": {}}
    for level, level_path, comptime_path in zip(triples[0::3], triples[1::3], triples[2::3]):
        level_obj = Object(level_path)
        comptime_obj = Object(comptime_path)
        move_name = "x86_64.move.moveKernel"
        if move_name not in comptime_obj.functions:
            # Identical copy/move pairs can share the copy entry symbol.
            start, size = comptime_obj.functions["x86_64.move.kernel"]
            require(comptime_obj.functions["probe_abi_move"][0] == start and
                    comptime_obj.functions["probe_abi_copy"][0] == start,
                    f"{level}: missing move entry is not an ABI alias")
            comptime_obj.functions[move_name] = (start, size)
            for address in range(start, start + size):
                comptime_obj.owner[address] = move_name
        counts = {}
        for op in ("move", "set"):
            got = normalized(level_obj, level, f"{PREFIX}{level}_mem{op}")
            want = normalized(comptime_obj, level, f"x86_64.{op}." + ("moveKernel" if op == "move" else "kernel"))
            require(got.keys() == want.keys(), f"{level} {op}: functions {sorted(got)} != {sorted(want)}")
            for key in got:
                require(got[key] == want[key], f"{level} {key}: the level object differs from the -Dcpu={level} build")
            counts[op] = {key: len(lines) for key, lines in sorted(got.items())}
            bounded_name = f"{PREFIX}{level}_mem{op}_above_small"
            bounded_counts = {}
            for n in (SMALL_MAX + 1, 127, 128, 129, 192, 255, 256, 257, 511, 512, 513, 768, 1024, 1025, 4096):
                if n <= SMALL_MAX:
                    continue
                code, end = trace(level_obj, bounded_name, n, allow_direct=True)
                _, full_end = trace(level_obj, f"{PREFIX}{level}_mem{op}", n, allow_direct=True)
                # AVX2 inlines the former mediumKernel, so it can return here.
                require(end == full_end or full_end == f"{op}.mediumKernel",
                        f"{level} bounded {op}/{n}: {end} != {full_end}")
                text = [t for t in code if not t.startswith("R_X86_64")]
                require(not any(re.match(r"(?:testq|cmpq).*%rdx", t) and
                                (t.startswith("testq") or int(re.search(r"\$(0x[0-9a-f]+|[0-9]+)", t)[1], 0) <= SMALL_MAX)
                                for t in text), f"{level} bounded {op}/{n} repeats a small-size test")
                bounded_counts[n] = {"instructions": len(text), "end": end}
            counts[op]["above_small"] = bounded_counts
            # The large policy of tuning.zig, stated independently. No level
            # uses REP for a forward overlap: rep_fwd_gap_min is null in
            # every row, so the REP branch requires a disjoint source.
            text = "\n".join(line for lines in got.values() for line in lines)
            rep = "movsb" if op == "move" else "stosb"
            policy = {"rep": f"rep {rep}" in re.sub(r"\s+", " ", text), "nt": "vmovntdq" in text}
            require(policy == POLICY[level][op], f"{level} {op} large policy {policy} != {POLICY[level][op]}")
            counts[op]["policy"] = policy
        evidence["levels"][level] = counts
    # The comparison is sensitive: two different levels must differ.
    if len(triples) >= 6:
        first = normalized(Object(triples[1]), triples[0], f"{PREFIX}{triples[0]}_memmove")
        other = normalized(Object(triples[5]), triples[0], "x86_64.move.moveKernel")
        require(first != other, f"{triples[0]} matches the {triples[3]} probe: the comparison is blind")
    print(json.dumps({"status": "pass", **evidence}))


if __name__ == "__main__":
    main()
