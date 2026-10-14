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
BRANCH = re.compile(r"callq?|j\w+|loop\w*|xbegin|blr?|b(?:\.\w+)?|br|cbn?z|tbn?z")
DIRECT = re.compile(r"(?:^|,\s*)(?:0x)?([0-9a-f]+)(?:\s+<([^>]+)>)?$")


@dataclass(frozen=True)
class Instruction:
    address: int
    op: str
    args: str
    text: str

    def target(self) -> int | None:
        if self.op in {"br", "blr"} or self.args.startswith("*"):
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
        and i.op not in {"call", "callq", "bl"}
        and (target := i.target()) is not None
        and target in addresses
        and target <= i.address
    ]


def slot_load(instruction: Instruction, slot: int) -> bool:
    match = re.fullmatch(
        r"movq\s+[-\w]+\(%rip\), %rax\s+# (0x[0-9a-f]+) <[^>]+>",
        instruction.op + " " + instruction.args,
    )
    return bool(match and int(match[1], 16) == slot)


def dispatch_call(body: list[Instruction], index: int, slot: int) -> bool:
    """Prove the branch register comes from this slot in the same basic block."""
    if body[index].op not in {"callq", "jmpq", "jmp"} or body[index].args != "*%rax":
        return False
    for instruction in reversed(body[:index]):
        if slot_load(instruction, slot):
            bypass = {
                i.address for i in body if instruction.address < i.address <= body[index].address
            }
            return not any(i.target() in bypass for i in body if BRANCH.fullmatch(i.op))
        if BRANCH.fullmatch(instruction.op) or re.search(
            r"%[re]?ax\b|%al\b|%ah\b", instruction.args
        ):
            return False
    return False


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


def dispatch_proof(elf: Elf, asm: Assembly) -> dict:  # noqa: C901, PLR0912, PLR0915
    """Validate the bounded selector, installation data flow and every slot writer."""
    slot = elf.symbol("x86_64.dispatch.find_fn")
    resolver = elf.symbol("x86_64.dispatch.resolveFind")
    if elf.words(slot, 1) != (resolver,):
        raise ValueError("Find slot does not initially name resolveFind")
    body = asm.bodies[resolver]
    selector = elf.symbol("x86_64.cpuid.Info.select")
    selector_returns(asm.bodies[selector])
    calls = [n for n, i in enumerate(body) if i.op == "callq" and i.target() == selector]
    if len(calls) != 1:
        raise ValueError("Unproven find selector call")
    tail = body[calls[0] + 1 :]
    # Verify the actual data path: AL -> byte index -> pointer-size scale,
    # then the fourth table -> RAX -> find_fn -> indirect tail jump.
    normalized = [i.op + " " + i.args.split("#", 1)[0].strip() for i in tail]
    if normalized[:2] != ["movzbl %al, %eax", "shll $0x3, %eax"]:
        raise ValueError("Unproven find table index")
    if len(tail) != 28:
        raise ValueError("Unrecognized find installation sequence")
    for n, register in zip((2, 4, 6, 8), ("rcx", "rdx", "rsi", "rdi"), strict=True):
        if not re.fullmatch(rf"leaq [-\w]+\(%rip\), %{register}", normalized[n]):
            raise ValueError("Unproven find table base")
        dest = "rax" if n == 8 else register
        if normalized[n + 1] != f"movq (%rax,%{register}), %{dest}":
            raise ValueError("Unproven find table load")
    for n, register, name in (
        (10, "rcx", "copy_fn"),
        (11, "rdx", "move_fn"),
        (12, "rsi", "set_fn"),
    ):
        reference = re.search(r"# (0x[0-9a-f]+) <", tail[n].args)
        if (
            not re.fullmatch(rf"movq %{register}, [-\w]+\(%rip\)", normalized[n])
            or reference is None
            or int(reference[1], 16) != elf.symbol("x86_64.dispatch." + name)
        ):
            raise ValueError("Unproven intervening installation instruction")
    if not re.fullmatch(r"movq %rax, [-\w]+\(%rip\)", normalized[13]):
        raise ValueError("Unproven find slot store")
    reference = re.search(r"# (0x[0-9a-f]+) <", tail[13].args)
    if reference is None or int(reference[1], 16) != slot or not slot_load(tail[14], slot):
        raise ValueError("Wrong find installation slot")
    if not dispatch_call(body, len(body) - 2, slot):
        raise ValueError("Unproven resolver tail target")
    # No bypass may enter the validated installation sequence.
    if any(i.target() in {j.address for j in tail} for i in body if BRANCH.fullmatch(i.op)):
        raise ValueError("Branch bypasses find installation proof")
    table_match = re.search(r"# (0x[0-9a-f]+) <", tail[8].args)
    if table_match is None:
        raise ValueError("Missing find table address")
    table = int(table_match[1], 16)
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
    writers = []
    for owner, instructions in asm.bodies.items():
        for index, instruction in enumerate(instructions):
            reference = re.search(r"# (0x[0-9a-f]+) <", instruction.args)
            if reference is None or int(reference[1], 16) != slot:
                continue
            if slot_load(instruction, slot):
                continue
            # Every statically addressed writer, including the memory resolvers,
            # must use the same validated table-to-slot installation sequence.
            if instruction.op != "movq" or not instruction.args.startswith("%rax,"):
                raise ValueError("Unknown find slot access")
            start = index - 14
            if (
                start < 0
                or instructions[start].op != "callq"
                or instructions[start].target() != selector
            ):
                raise ValueError("Unproven find slot writer selector")
            block = instructions[start + 1 : index + 1]
            for actual, expected in zip(block, tail[:14], strict=True):
                actual_code = actual.op + " " + actual.args.split("#", 1)[0].strip()
                expected_code = expected.op + " " + expected.args.split("#", 1)[0].strip()
                if re.sub(r"-?0x[0-9a-f]+\(%rip\)", "RIP", actual_code) != re.sub(
                    r"-?0x[0-9a-f]+\(%rip\)", "RIP", expected_code
                ):
                    raise ValueError("Unproven find slot writer data flow")
                if expected.args.partition("#")[2] != actual.args.partition("#")[2]:
                    raise ValueError("Different table or slot in find writer")
            if any(
                i.target() in {j.address for j in block}
                for i in instructions
                if BRANCH.fullmatch(i.op)
            ):
                raise ValueError("Branch bypasses find writer proof")
            writers.append(hex(owner))
    return {
        "slot": hex(slot),
        "initial_resolver": hex(resolver),
        "table": hex(table),
        "selector": hex(selector),
        "entries": entries,
        "writers": writers,
    }


def _clock_step(inst: Instruction, values: dict[str, str | None], offset: int) -> bool:  # noqa: C901, PLR0912
    args = inst.args.split("# ", 1)[0].split("//", 1)[0].strip()
    if inst.op in {"callq", "call", "blr"}:
        callback = None
        if inst.op == "blr":
            callback = values.get(args)
        elif (
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
        ):
            values.pop(register, None)
        return callback == "now"
    if inst.op == "movq" and (match := re.fullmatch(r"(.+), (%\w+|-?0x[0-9a-f]+\(%rbp\))", args)):
        source, dest = match.groups()
        value = values.get(source)
        if load := re.fullmatch(r"0x8\((%\w+)\)", source):
            value = "vtable" if values.get(load[1]) == "io" else None
        values[dest] = value
    elif inst.op == "mov" and (match := re.fullmatch(r"(x\d+), (x\d+)", args)):
        values[match[1]] = values.get(match[2])
    elif inst.op == "ldp" and (match := re.fullmatch(r"(x\d+), (x\d+), \[(x\d+)\]", args)):
        value = values.get(match[3])
        values[match[1]] = None
        values[match[2]] = "vtable" if value == "io" else None
    elif inst.op == "ldr" and (match := re.fullmatch(r"(x\d+), \[(x\d+), #?(0x[0-9a-f]+)\]", args)):
        values[match[1]] = (
            "now" if values.get(match[2]) == "vtable" and int(match[3], 16) == offset else None
        )
    elif not BRANCH.fullmatch(inst.op) and not inst.op.startswith(
        ("cmp", "test", "str", "stp", "push")
    ):
        # Invalidate other register writes; handle subregisters as aliases.
        dest = args.rsplit(", ", 1)[-1] if "%" in args else args.split(", ", 1)[0]
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
            if dest in aliases:
                dest = register
        if match := re.fullmatch(r"(%r\d+)[dwb]", dest):
            dest = match[1]
        if re.fullmatch(r"w\d+", dest):
            dest = "x" + dest[1:]
        values.pop(dest, None)
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
            and inst.op not in {"call", "callq", "bl", "blr"}
            and (target := inst.target()) in positions
        ):
            successors.append(positions[target])
        if inst.op not in {"jmp", "jmpq", "b", "br", "ret", "retq"} and index + 1 < len(body):
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
