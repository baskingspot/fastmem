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
CALLS = {"call", "callq", "bl", "blr", *ARM_AUTH_CALLS}
TAILS = {"jmp", "jmpq", "b", "br", *ARM_AUTH_TAILS}
BRANCH = re.compile(r"callq?|j\w+|loop\w*|xbegin|blr?|b(?:\.\w+)?|br|bl?ra[ab]z?|cbn?z|tbn?z")
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


def slot_register(instruction: Instruction, slot: int) -> str | None:
    match = re.fullmatch(
        r"movq\s+[-\w]+\(%rip\), (%\w+)\s+# (0x[0-9a-f]+) <[^>]+>",
        instruction.op + " " + instruction.args,
    )
    return match[1] if match and int(match[2], 16) == slot else None


def dispatch_call(
    body: list[Instruction], index: int, slot: int, incoming_targets: set[int] | None = None
) -> bool:
    """Prove the branch register comes from this slot in the same basic block."""
    inst = body[index]
    if inst.op not in {"callq", "jmpq", "jmp"} or not re.fullmatch(r"\*%\w+", inst.args):
        return False
    values: dict[str, str | None] = {}
    for instruction in body[:index]:
        if BRANCH.fullmatch(instruction.op):
            values.clear()
        elif register := slot_register(instruction, slot):
            values[register] = f"slot:{instruction.address}"
        else:
            _clock_step(instruction, values, -1)
    source = values.get(inst.args[1:])
    if source is None or not source.startswith("slot:"):
        return False
    load = int(source.partition(":")[2])
    bypass = {i.address for i in body if load < i.address <= inst.address}
    targets = (
        incoming_targets
        if incoming_targets is not None
        else {target for i in body if BRANCH.fullmatch(i.op) and (target := i.target()) is not None}
    )
    return not targets.intersection(bypass)


def selector_returns(body: list[Instruction]) -> set[int]:  # noqa: C901, PLR0912
    """Conservative finite-value CFG interpretation of the selector's AL return.

    Unsupported register writes become unknown. Both conditional paths are
    explored; every return must have a proven finite value within the table.
    """
    positions = {i.address: n for n, i in enumerate(body)}
    pending: list[tuple[int, frozenset[int] | None, frozenset[int] | None]] = [(0, None, None)]
    seen = set()
    returns: set[int] = set()
    while pending:
        index, a, c = pending.pop()
        state = (index, a, c)
        if state in seen:
            continue
        seen.add(state)
        if len(seen) > 10000 or index >= len(body):
            raise ValueError("Unproven selector control flow")
        inst = body[index]
        if inst.op not in {
            "movl",
            "movq",
            "movb",
            "movzbl",
            "movabsq",
            "notl",
            "testl",
            "andl",
            "orl",
            "andb",
            "cmpb",
            "cmpl",
            "cmpq",
            "xorl",
            "leal",
            "btq",
            "sete",
            "cmovel",
            "retq",
            "nopw",
            "nopl",
            "nop",
        } and not inst.op.startswith("j"):
            raise ValueError("Unsupported selector instruction")
        args = inst.args.split("#", 1)[0].strip()
        dest = args.rsplit(", ", 1)[-1]
        if inst.op.startswith("ret"):
            if a is None or not a <= set(range(7)):
                raise ValueError("Unproven seven-level selector return")
            returns.update(a)
            continue
        if BRANCH.fullmatch(inst.op):
            target = inst.target()
            if target not in positions or inst.op.startswith("call"):
                raise ValueError("Unproven selector branch")
            pending.append((positions[target], a, c))
            if inst.op in {"jmp", "jmpq"}:
                continue
        elif dest in {
            "%al",
            "%ax",
            "%eax",
            "%rax",
            "%ecx",
            "%rcx",
            "%cx",
            "%cl",
            "%ch",
        } and not inst.op.startswith(("cmp", "test", "bt")):
            value = None
            if inst.op.startswith("mov") and (m := re.match(r"\$(0x[0-9a-f]+|[0-9]+),", args)):
                value = frozenset({int(m[1], 0)})
            elif inst.op.startswith("xor") and args.split(", ")[0] == dest:
                value = frozenset({0})
            elif inst.op.startswith("set"):
                value = frozenset({0, 1})
            elif inst.op == "leal" and args == "0x2(%rax,%rax,2), %eax" and a is not None:
                value = frozenset(2 + 3 * v for v in a)
            elif (
                inst.op.startswith("cmov")
                and args == "%ecx, %eax"
                and a is not None
                and c is not None
            ):
                value = a | c
            if dest in {"%al", "%ax", "%eax", "%rax"}:
                a = value
            else:
                c = value if dest in {"%ecx", "%rcx"} else None
        pending.append((index + 1, a, c))
    if returns != set(range(7)):
        raise ValueError("Selector does not prove all seven levels")
    return returns


def _reference(inst: Instruction) -> int | None:
    match = re.search(r"# (0x[0-9a-f]+) <", inst.args)
    return int(match[1], 16) if match else None


def _installation(  # noqa: C901, PLR0912, PLR0915 — explicit instruction semantics
    body: list[Instruction], index: int, selector: int, slots: set[int], incoming_targets: set[int]
) -> dict[int, int]:
    """Symbolically follow the selector byte through scale, tables and stores.

    This is deliberately a supported straight-line language, not a compiler
    template. Unknown operations and any CFG entry bypass fail closed.
    """
    start = index - 1
    while start >= 0 and not BRANCH.fullmatch(body[start].op):
        start -= 1
    if start < 0 or body[start].op != "callq" or body[start].target() != selector:
        raise ValueError("Unproven find slot writer selector")
    block = body[start + 1 : index + 1]
    if incoming_targets.intersection(j.address for j in block):
        raise ValueError("Branch bypasses find installation proof")
    values = {"%rax": ("byte", 0)}
    stores = {}
    for inst in block:
        args = inst.args.split("#", 1)[0].strip()
        value = None
        if inst.op == "movzbl" and (m := re.fullmatch(r"%al, (%\w+)", args)):
            if values.get("%rax") != ("byte", 0):
                raise ValueError("Unproven selector byte")
            dest, value = m[1], ("index", 0)
        elif inst.op == "shll" and (m := re.fullmatch(r"\$0x3, (%\w+)", args)):
            dest = m[1]
            if values.get(_register(dest)) == ("index", 0):
                value = ("scaled", 0)
        elif inst.op == "leal" and (m := re.fullmatch(r"\(,(%\w+),8\), (%\w+)", args)):
            dest = m[2]
            if values.get(m[1]) == ("index", 0):
                value = ("scaled", 0)
        elif inst.op == "leaq" and (m := re.fullmatch(r"[-\w]+\(%rip\), (%\w+)", args)):
            dest = m[1]
            if (ref := _reference(inst)) is not None:
                value = ("table", ref)
        elif inst.op == "movq" and (m := re.fullmatch(r"\((%\w+),(%\w+)\), (%\w+)", args)):
            dest = m[3]
            left, right = values.get(m[1]), values.get(m[2])
            if left == ("scaled", 0) and right is not None and right[0] == "table":
                value = ("entry", right[1])
            elif right == ("scaled", 0) and left is not None and left[0] == "table":
                value = ("entry", left[1])
        elif inst.op == "movq" and (m := re.fullmatch(r"(%\w+), [-\w]+\(%rip\)", args)):
            ref = _reference(inst)
            source = values.get(m[1])
            if ref not in slots or ref in stores or source is None or source[0] != "entry":
                raise ValueError("Unproven installation store")
            stores[ref] = source[1]
            continue
        elif inst.op == "movq" and (m := re.fullmatch(r"(%\w+), (%\w+)", args)):
            dest, value = m[2], values.get(m[1])
        elif inst.op in {"nop", "nopl", "nopw"}:
            continue
        else:
            raise ValueError("Unsupported find installation instruction")
        if value is None:
            raise ValueError("Unproven find table data flow")
        values[_register(dest)] = value
    if set(stores) != slots or len(set(stores.values())) != len(slots):
        raise ValueError("Unproven memory-table installation")
    return stores


def dispatch_proof(elf: Elf, asm: Assembly) -> dict:
    """Validate the bounded selector, installation data flow and every slot writer."""
    slot = elf.symbol("x86_64.dispatch.find_fn")
    resolver = elf.symbol("x86_64.dispatch.resolveFind")
    if elf.words(slot, 1) != (resolver,):
        raise ValueError("Find slot does not initially name resolveFind")
    selector = elf.symbol("x86_64.cpuid.Info.select")
    selector_returns(asm.bodies[selector])
    slots = {elf.symbol("x86_64.dispatch." + n + "_fn") for n in ("copy", "move", "set", "find")}
    incoming_targets = {
        target
        for body in asm.bodies.values()
        for i in body
        if BRANCH.fullmatch(i.op) and (target := i.target()) is not None
    }
    installations = []
    writers = []
    for owner, body in asm.bodies.items():
        for index, inst in enumerate(body):
            if _reference(inst) != slot or slot_register(inst, slot):
                continue
            if inst.op != "movq" or not re.fullmatch(
                r"%\w+, [-\w]+\(%rip\)", inst.args.split("#", 1)[0].strip()
            ):
                raise ValueError("Unknown find slot access")
            installations.append(_installation(body, index, selector, slots, incoming_targets))
            writers.append(hex(owner))
    if (
        hex(resolver) not in writers
        or not installations
        or any(installation != installations[0] for installation in installations)
    ):
        raise ValueError("Different table or slot in find writer")
    body = asm.bodies[resolver]
    if not any(
        i.op in {"jmp", "jmpq"} and dispatch_call(body, n, slot, incoming_targets)
        for n, i in enumerate(body)
    ):
        raise ValueError("Unproven resolver tail target")
    table = installations[0][slot]
    targets = elf.words(table, 7)
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
    for level, target in zip(levels, targets, strict=True):
        names = [
            name for name in elf.symbols if re.fullmatch(rf"fastmem_find_[0-9a-f]+_{level}", name)
        ]
        if len(names) != 1 or elf.symbol(names[0]) != target or target not in asm.bodies:
            raise ValueError(f"Unproven find table entry: {level}")
        entries.append({"level": level, "symbol": names[0], "address": hex(target)})
    return {
        "slot": hex(slot),
        "initial_resolver": hex(resolver),
        "table": hex(table),
        "selector": hex(selector),
        "entries": entries,
        "writers": writers,
        "installation_tables": {hex(s): hex(t) for s, t in installations[0].items()},
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
    if dest in {"%rbp", "%rsp"}:
        for key in list(values):
            if "(" in key:
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
    if inst.op in {"str", "stp"} and re.fullmatch(
        r"(?:[xw]\d+, ){1,2}\[(?:x\d+|sp)(?:, #?-?0x[0-9a-f]+)?\]", args
    ):
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
