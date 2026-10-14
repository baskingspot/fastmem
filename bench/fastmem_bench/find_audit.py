"""Address-faithful executable graph and narrow, fail-closed dispatch proofs.

The ELF64 layout and instruction-owner traversal follow src/export/check.py and
src/export/audit.py. These helpers intentionally do not inspect shared libraries.
"""

import re
import struct
from dataclasses import dataclass
from pathlib import Path

HEADER = re.compile(r"^([0-9a-f]+) <(.+)>:$")
INSTRUCTION = re.compile(r"^\s*([0-9a-f]+):\s+([a-z0-9_.]+)\s*(.*?)\s*$")
ARM_AUTH_CALLS = {"blraa", "blrab", "blraaz", "blrabz"}
ARM_AUTH_TAILS = {"braa", "brab", "braaz", "brabz"}
X86_FAR_CALLS = {"lcall", "lcallw", "lcalll", "lcallq"}
X86_FAR_TAILS = {"ljmp", "ljmpw", "ljmpl", "ljmpq"}
CALLS = {"call", "callq", "bl", "blr", *ARM_AUTH_CALLS, *X86_FAR_CALLS}
TAILS = {"jmp", "jmpq", "b", "br", *ARM_AUTH_TAILS, *X86_FAR_TAILS}
BRANCH = re.compile(
    r"l?call[qlw]?|ljmp[qlw]?|j\w+|loop\w*|xbegin|blr?|b(?:c)?(?:\.\w+)?|br|bl?ra[ab]z?|cbn?z|tbn?z"
)
DIRECT = re.compile(r"(?:^|,\s*)(?:0x)?([0-9a-f]+)(?:\s+<([^>]+)>)?$")


@dataclass(frozen=True)
class Instruction:
    address: int
    op: str
    args: str
    text: str

    def target(self) -> int | None:
        if self.op in {"br", "blr", *ARM_AUTH_CALLS, *ARM_AUTH_TAILS} or self.args.startswith("*"):
            return None
        match = DIRECT.search(self.args)
        return int(match[1], 16) if match else None


class Assembly:
    def __init__(self, text: str) -> None:
        self.names: dict[int, str] = {}
        self.bodies: dict[int, list[Instruction]] = {}
        self.owners: dict[int, int] = {}
        current = None
        for line in text.splitlines():
            if match := HEADER.match(line):
                current = int(match[1], 16)
                self.names[current] = match[2]
                self.bodies.setdefault(current, [])
            elif current is not None and (match := INSTRUCTION.match(line)):
                address = int(match[1], 16)
                self.bodies[current].append(Instruction(address, match[2], match[3], line))
                self.owners[address] = current

    def roots(self, names: list[str]) -> list[int]:
        if not set(names) <= set(self.names.values()):
            raise ValueError("Missing search inspection roots")
        # A root name may identify multiple local functions. Never pick the last one.
        return [address for address, name in self.names.items() if name in names]


class Elf:
    def __init__(self, path: Path) -> None:
        self.raw = path.read_bytes()
        if self.raw[:6] != b"\x7fELF\x02\x01":
            raise ValueError("Expected little-endian ELF64 search executable")
        shoff = struct.unpack_from("<Q", self.raw, 40)[0]
        shsize, shnum = struct.unpack_from("<HH", self.raw, 58)
        self.sections = [
            struct.unpack_from("<IIQQQQIIQQ", self.raw, shoff + i * shsize) for i in range(shnum)
        ]
        self.symbols: dict[str, list[tuple[int, int, int]]] = {}
        for section in self.sections:
            if section[1] != 2:
                continue
            strings_section = self.sections[section[6]]
            strings = self.raw[strings_section[4] : strings_section[4] + strings_section[5]]
            for offset in range(section[4], section[4] + section[5], section[9]):
                name, info, _, index, value, size = struct.unpack_from("<IBBHQQ", self.raw, offset)
                if index:
                    label = strings[name:].split(b"\0", 1)[0].decode()
                    self.symbols.setdefault(label, []).append((value, size, info & 15))

    def symbol(self, name: str) -> int:
        values = self.symbols.get(name, [])
        if len(values) != 1:
            raise ValueError(f"Missing or ambiguous ELF symbol: {name}")
        return values[0][0]

    def words(self, address: int, count: int) -> tuple[int, ...]:
        sections = [
            s
            for s in self.sections
            if s[1] == 1 and s[2] & 2 and s[3] <= address and address + count * 8 <= s[3] + s[5]
        ]
        if len(sections) != 1:
            raise ValueError("Unproven allocated PROGBITS pointer storage")
        section = sections[0]
        return struct.unpack_from(f"<{count}Q", self.raw, section[4] + address - section[3])

    def protected(self, address: int, size: int) -> None:
        """Prove full file-backed storage in read-only LOAD or page-complete RELRO.

        LLVM places const function pointers in data.rel.ro. GNU_RELRO makes
        those relocation-bearing bytes read-only before executable calls.
        """
        sections = [s for s in self.sections if s[3] <= address and address + size <= s[3] + s[5]]
        if not any(s[1] == 1 and s[2] & 2 for s in sections):
            raise ValueError("Find table is not allocated storage")
        phoff = struct.unpack_from("<Q", self.raw, 32)[0]
        phsize, phnum = struct.unpack_from("<HH", self.raw, 54)
        headers = [
            struct.unpack_from("<IIQQQQQQ", self.raw, phoff + i * phsize) for i in range(phnum)
        ]
        relro = any(
            h[0] == 0x6474E552 and h[3] <= address and address + size <= (h[3] + h[6]) & ~4095
            for h in headers
        )
        covered = False
        for kind, flags, _, virtual, _, filesz, memsz, _ in headers:
            if kind != 1 or virtual >= address + size or address >= virtual + memsz:
                continue
            if flags & 2 and not relro:
                raise ValueError("Find table overlaps unprotected writable LOAD")
            covered |= bool(flags & 4 and virtual <= address and address + size <= virtual + filesz)
        if not covered or (not relro and any(s[2] & 1 for s in sections)):
            raise ValueError("Find table lacks protected storage")
        for section in self.sections:
            if section[1] not in {4, 9} or not section[2] & 2:
                continue
            for offset in range(section[4], section[4] + section[5], section[9]):
                relocated = struct.unpack_from("<Q", self.raw, offset)[0]
                if address - 7 <= relocated < address + size:
                    raise ValueError("Loader relocation overlaps find target words")

    def clock_offset(self) -> int:
        now = self.symbol("Io.Threaded.now")
        offsets = set()
        for values in self.symbols.values():
            for address, size, kind in values:
                # The complete Io vtable is an object, not an accidental pointer
                # elsewhere in rodata. Derive the callback offset from its bytes.
                if kind == 1 and size > 8 and size % 8 == 0:
                    try:
                        words = self.words(address, size // 8)
                    except ValueError:
                        continue
                    offsets.update(i * 8 for i, word in enumerate(words) if word == now)
        if len(offsets) != 1:
            raise ValueError("Cannot establish Io timestamp vtable slot")
        return offsets.pop()


def backedges(body: list[Instruction]) -> list[tuple[int, int]]:
    addresses = {i.address for i in body}
    return [
        (target, i.address)
        for i in body
        if BRANCH.fullmatch(i.op)
        and i.op not in CALLS
        and (target := i.target()) is not None
        and target in addresses
        and target <= i.address
    ]


def _reference(inst: Instruction) -> int | None:
    match = re.search(r"# (0x[0-9a-f]+)\b", inst.args)
    return int(match[1], 16) if match else None


def guard_call(  # noqa: C901, PLR0912, PLR0915 — narrow explicit instruction semantics
    body: list[Instruction], selected: int, incoming_targets: set[int]
) -> dict:
    """Prove a straight-line byte/mask/index/table/tail chain at its actual branch.

    Values describe full-width identities, not just low bits. Every unsupported
    effect fails closed; register copies, zero extension and explicit scaling
    are supported independently of register allocation.
    """
    values: dict[str, tuple[str, int]] = {}
    load = mask = branch = table = None
    for inst in body:
        args = inst.args.split("#", 1)[0].strip()
        if inst.op in {"nop", "nopl", "nopw"}:
            continue
        if branch is not None:
            raise ValueError("Instruction after find guard tail")
        value = None
        dest = ""
        if inst.op in {"movzbl", "movb"} and (m := re.fullmatch(r"[-\w]+\(%rip\), (%\w+)", args)):
            if _reference(inst) != selected:
                raise ValueError("Find guard does not load selected byte")
            load = inst.address
            dest, value = m[1], ("raw", 0)
        elif inst.op == "movzbl" and (m := re.fullmatch(r"(%\w+), (%\w+)", args)):
            source = values.get(_register(m[1]))
            dest = m[2]
            if source == ("raw", 0):
                value = source
            elif source in {("byte-index", 0), ("index", 0)}:
                value = ("index", 0)
        elif inst.op in {"andl", "andq", "andb"} and (
            m := re.fullmatch(r"\$(0x[0-9a-f]+|[0-9]+), (%\w+)", args)
        ):
            dest = m[2]
            if int(m[1], 0) == 7 and values.get(_register(dest)) == ("raw", 0):
                mask = inst.address
                value = ("byte-index" if inst.op == "andb" else "index", 0)
        elif inst.op == "leaq" and (m := re.fullmatch(r"[-\w]+\(%rip\), (%\w+)", args)):
            dest = m[1]
            if (ref := _reference(inst)) is not None:
                value = ("table", ref)
        elif inst.op in {"shll", "shlq"} and (m := re.fullmatch(r"\$0x3, (%\w+)", args)):
            dest = m[1]
            if values.get(_register(dest)) == ("index", 0):
                value = ("scaled", 0)
        elif inst.op in {"leal", "leaq"} and (m := re.fullmatch(r"\(,(%\w+),8\), (%\w+)", args)):
            dest = m[2]
            if values.get(m[1]) == ("index", 0):
                value = ("scaled", 0)
        elif inst.op == "movq" and (m := re.fullmatch(r"(%\w+), (%\w+)", args)):
            dest, value = m[2], values.get(m[1])
        elif inst.op in {"movq", "jmp", "jmpq"}:
            operands = _operands(args)
            operand = operands[0].lstrip("*")
            if m := re.fullmatch(r"\((%\w+),(%\w+)(?:,([1248]))?\)", operand):
                base, index = values.get(m[1]), values.get(m[2])
                scale = int(m[3] or "1")
                if (
                    base is not None
                    and base[0] == "table"
                    and (
                        (index == ("index", 0) and scale == 8)
                        or (index == ("scaled", 0) and scale == 1)
                    )
                ):
                    value = ("entry", base[1])
            elif inst.op in {"jmp", "jmpq"} and re.fullmatch(r"\*%\w+", args):
                value = values.get(args[1:])
            if inst.op == "movq" and len(operands) == 2:
                dest = operands[1]
            elif inst.op in {"jmp", "jmpq"} and value is not None and value[0] == "entry":
                branch, table = inst.address, value[1]
                continue
        if value is None or not re.fullmatch(r"%\w+", dest):
            raise ValueError("Unsupported or unbounded find guard instruction")
        # A 32-bit destination zeroes its upper half. Partial writes are only
        # accepted for raw bytes, never for a purported full-width index/base.
        if (
            value[0] in {"index", "scaled", "table", "entry"}
            and dest != _register(dest)
            and not re.fullmatch(r"%e(?:ax|bx|cx|dx|si|di|bp|sp)|%r\d+d", dest)
        ):
            raise ValueError("Partial-width find index")
        values[_register(dest)] = value
    if load is None or mask is None or branch is None or table is None:
        raise ValueError("Missing bounded find guard tail")
    if incoming_targets.intersection(range(body[0].address + 1, branch + 1)):
        raise ValueError("Incoming branch bypasses find guard entry")
    return {
        "entry": hex(body[0].address),
        "byte_load": hex(load),
        "mask_instruction": hex(mask),
        "mask": 7,
        "index_bits": 64,
        "scale": 8,
        "branch": hex(branch),
        "table": hex(table),
    }


def dispatch_proof(elf: Elf, asm: Assembly) -> dict:
    """Bind the actual bounded call site to protected storage and eight entries."""
    selected = elf.symbol("x86_64.dispatch.selected")
    resolver = elf.symbol("x86_64.dispatch.resolveFind")
    guard = elf.symbol("x86_64.dispatch.dispatchFind")
    incoming = {
        target
        for body in asm.bodies.values()
        for i in body
        if BRANCH.fullmatch(i.op) and (target := i.target()) is not None
    }
    proof = guard_call(asm.bodies[guard], selected, incoming)
    _, guard_size, kind = elf.symbols["x86_64.dispatch.dispatchFind"][0]
    if kind != 2 or guard_size == 0:
        raise ValueError("Unproven find guard function extent")
    if any(guard < target < guard + guard_size for target in incoming):
        raise ValueError("Incoming branch bypasses find guard entry")
    table = int(proof["table"], 16)
    elf.protected(table, 64)
    targets = elf.words(table, 8)
    levels = (
        "generic",
        "x86_64_v3",
        "x86_64_v4",
        "sapphirerapids",
        "graniterapids",
        "znver4",
        "znver5",
    )
    entries = []
    for level, target in zip(levels, targets[:7], strict=True):
        names = [
            name for name in elf.symbols if re.fullmatch(rf"fastmem_find_[0-9a-f]+_{level}", name)
        ]
        if len(names) != 1 or elf.symbol(names[0]) != target or target not in asm.bodies:
            raise ValueError(f"Unproven find table entry: {level}")
        entries.append({"level": level, "symbol": names[0], "address": hex(target)})
    if targets[7] != resolver or resolver not in asm.bodies:
        raise ValueError("Unproven find resolver table entry")
    entries.append(
        {"level": "unresolved", "symbol": "x86_64.dispatch.resolveFind", "address": hex(resolver)}
    )
    return {
        **proof,
        "selected_byte": hex(selected),
        "storage_bytes": 64,
        "storage_read_only": True,
        "entries": entries,
    }


def _register(operand: str) -> str:
    """Canonicalize GPR aliases, including partial writes."""
    for register, aliases in {
        "%rax": ("%eax", "%ax", "%al", "%ah"),
        "%rbx": ("%ebx", "%bx", "%bl", "%bh"),
        "%rcx": ("%ecx", "%cx", "%cl", "%ch"),
        "%rdx": ("%edx", "%dx", "%dl", "%dh"),
        "%rsi": ("%esi", "%si", "%sil"),
        "%rdi": ("%edi", "%di", "%dil"),
        "%rbp": ("%ebp", "%bp", "%bpl"),
        "%rsp": ("%esp", "%sp", "%spl"),
    }.items():
        if operand in aliases:
            return register
    if match := re.fullmatch(r"(%r\d+)[dwb]", operand):
        return match[1]
    if re.fullmatch(r"w\d+", operand):
        return "x" + operand[1:]
    return operand


def _operands(args: str) -> list[str]:
    # Commas within addressing expressions are not operand boundaries.
    return re.split(r",\s*(?![^([]*[)\]])", args) if args else []


def _forget(values: dict[str, str | None], dest: str) -> None:
    dest = _register(dest)
    values.pop(dest, None)
    spill = re.fullmatch(r"(-?0x[0-9a-f]+)\(%rbp\)", dest)
    for key in list(values):
        if "(" not in key:
            continue
        previous = re.fullmatch(r"(-?0x[0-9a-f]+)\(%rbp\)", key)
        if dest in {"%rbp", "%rsp"} or (
            spill is not None
            and previous is not None
            and abs(int(spill[1], 16) - int(previous[1], 16)) < 8
        ):
            values.pop(key)


def _clock_step(inst: Instruction, values: dict[str, str | None], offset: int) -> bool:  # noqa: C901, PLR0911, PLR0912, PLR0915
    """Interpret only explicit supported operand semantics.

    Unknown instructions/operand forms discard ALL identities (including
    spills). Thus multi-destination, implicit and writeback clobbers cannot
    accidentally retain an Io identity. Authenticated calls are never exempt.
    """
    args = inst.args.split("# ", 1)[0].split("//", 1)[0].strip()
    operands = _operands(args)
    if inst.op in CALLS:
        callback = None
        if inst.op == "blr":
            callback = values.get(args)
        elif inst.op in {"call", "callq"} and (
            (match := re.fullmatch(r"\*(0x[0-9a-f]+)\((%\w+)\)", args))
            and int(match[1], 16) == offset
            and values.get(match[2]) == "vtable"
        ):
            callback = "now"
        for register in (
            "%rax",
            "%rcx",
            "%rdx",
            "%rsi",
            "%rdi",
            "%r8",
            "%r9",
            "%r10",
            "%r11",
            *(f"x{n}" for n in range(19)),
            "x30",
        ):
            values.pop(register, None)
        return callback == "now"
    if inst.op.startswith("loop") or inst.op == "xbegin":
        values.clear()
        return False
    if BRANCH.fullmatch(inst.op) or inst.op in {"ret", "retq", "nop", "nopl", "nopw"}:
        return False
    if inst.op == "movq" and len(operands) == 2:
        source, dest = operands
        if "(" in dest and any(
            values.get(register) in {"io", "vtable"} for register in re.findall(r"%\w+", dest)
        ):
            values.clear()
            return False
        value = values.get(source)
        if load := re.fullmatch(r"0x8\((%\w+)\)", source):
            value = "vtable" if values.get(load[1]) == "io" else None
        if re.fullmatch(r"%r\w+|-?0x[0-9a-f]+\(%rbp\)", dest):
            _forget(values, dest)
            if value is not None:
                values[dest] = value
            return False
        # An untracked memory write might alias a tracked spill.
        for key in list(values):
            if "(" in key:
                values.pop(key)
        return False
    if inst.op == "mov" and (m := re.fullmatch(r"(x\d+), (x\d+)", args)):
        value = values.get(m[2])
        _forget(values, m[1])
        if value is not None:
            values[m[1]] = value
        return False
    if inst.op == "ldp" and (
        m := re.fullmatch(r"(x\d+), (x\d+), \[(x\d+|sp)(?:, #?-?0x[0-9a-f]+)?\]", args)
    ):
        value = values.get(m[3])
        _forget(values, m[1])
        _forget(values, m[2])
        if value == "io" and args.endswith("[" + m[3] + "]"):
            values[m[2]] = "vtable"
        return False
    if inst.op == "ldr" and (
        m := re.fullmatch(r"(x\d+), \[(x\d+|sp)(?:, #?(0x[0-9a-f]+))?\]", args)
    ):
        value = values.get(m[2])
        _forget(values, m[1])
        if value == "vtable" and m[3] is not None and int(m[3], 16) == offset:
            values[m[1]] = "now"
        return False
    # Read-only flag operations have no GPR destinations.
    if inst.op in {"cmp", "testq", "testl", "testb", "cmpq", "cmpl", "cmpb"} and len(operands) == 2:
        return False
    # ARM stores without writeback do not write any GPR. Writeback forms,
    # exclusive stores and unrecognized loads fall through to total invalidation.
    if inst.op in {"str", "stp"} and (
        store := re.fullmatch(r"(?:[xw]\d+, ){1,2}\[(x\d+|sp)(?:, #?-?0x[0-9a-f]+)?\]", args)
    ):
        if values.get(store[1]) in {"io", "vtable"}:
            values.clear()
        return False
    # Exact opcode sets, not prefix/last-operand guesses: these forms have
    # one explicit destination and no implicit GPR writes.
    if (
        inst.op
        in {
            "movl",
            "movb",
            "movw",
            "movzbl",
            "leaq",
            "leal",
            "addq",
            "addl",
            "subq",
            "subl",
            "sbbq",
            "sbbl",
            "andq",
            "andl",
            "orq",
            "orl",
            "orb",
            "xorq",
            "xorl",
            "shlq",
            "shll",
            "shrq",
            "shrl",
            "sarq",
            "sarl",
        }
        and len(operands) == 2
    ):
        if re.fullmatch(r"%\w+", operands[1]):
            _forget(values, operands[1])
        else:
            values.clear()
        return False
    if (
        inst.op in {"popq", "setb", "sete", "setne", "incq", "decq", "negq", "notq"}
        and len(operands) == 1
        and re.fullmatch(r"%\w+", operands[0])
    ):
        _forget(values, operands[0])
        if inst.op == "popq":
            _forget(values, "%rsp")
        return False
    if inst.op == "pushq" and len(operands) == 1:
        _forget(values, "%rsp")
        return False
    arm_counts = {"mov": 2, "adrp": 2, "add": 3, "sub": 3, "subs": 3, "csinv": 4}
    if (
        inst.op in arm_counts
        and len(operands) == arm_counts[inst.op]
        and re.fullmatch(r"[xw]\d+|sp", operands[0])
    ):
        _forget(values, operands[0])
        return False
    if inst.op == "ldrb" and re.fullmatch(r"w\d+, \[(?:x\d+|sp)(?:, #?0x[0-9a-f]+)?\]", args):
        _forget(values, operands[0])
        return False
    values.clear()
    return False


def clock_calls(body: list[Instruction], offset: int) -> list[int]:
    """Prove Io-argument provenance across the CFG, not lexical instruction order.

    Join points retain only identities agreed upon by EVERY incoming path.
    Loops converge by dropping unknown identities; calls clobber ABI scratch
    registers. Only timestamp ABI calls outside all backedges are classified.
    """
    positions = {i.address: n for n, i in enumerate(body)}
    incoming: dict[int, dict[str, str | None]] = {0: {"%rsi": "io", "x1": "io"}}
    pending = [0]
    callbacks = {}
    while pending:
        index = pending.pop()
        inst = body[index]
        values = incoming[index].copy()
        callbacks[index] = _clock_step(inst, values, offset)
        successors = []
        if (
            BRANCH.fullmatch(inst.op)
            and inst.op not in CALLS
            and (target := inst.target()) in positions
        ):
            successors.append(positions[target])
        if inst.op not in TAILS | {"ret", "retq"} and index + 1 < len(body):
            successors.append(index + 1)
        for successor in successors:
            previous = incoming.get(successor)
            joined = (
                values
                if previous is None
                else {key: value for key, value in previous.items() if values.get(key) == value}
            )
            if previous != joined:
                incoming[successor] = joined
                pending.append(successor)
    loops = backedges(body)
    calls = [
        body[n].address
        for n, yes in callbacks.items()
        if yes and not any(lo <= body[n].address <= hi for lo, hi in loops)
    ]
    return sorted(calls) if len(calls) == 2 else []
