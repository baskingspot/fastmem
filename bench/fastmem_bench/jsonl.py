"""Schema-v2 and v3 input and independent libc-probe resolution checks.

v3 adds the `memory` meta object and const cases for move and set. The parser
accepts both versions, so that old run directories still analyze.
"""

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

Implementation = Literal["builtin", "glibc", "fastmem_abi", "fastmem_inline", "builtin_const"]
Operation = Literal["copy", "move", "set"]
IMPLEMENTATIONS = ("builtin", "glibc", "fastmem_abi", "fastmem_inline", "builtin_const")
SYMBOLS = ("memcpy", "memmove", "memset")
SCHEMAS = (2, 3)
HUGE_PAGE = 2 << 20
# The destination view starts one page into its region (src/bench_fastmem.zig).
DST_STAGGER = 4096


class Record(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False, extra="forbid", strict=True)


class Perf(Record):
    available: bool
    events: list[str]
    error: str | None

    @model_validator(mode="after")
    def check_group(self) -> Perf:
        if self.events not in (
            ["cycles", "instructions"],
            ["cycles", "instructions", "ref-cycles"],
        ):
            raise ValueError("Invalid perf event group")
        if not self.available and not self.error:
            raise ValueError("Unavailable perf group requires an error")
        if (
            self.available
            and self.error
            and (len(self.events) != 2 or not self.error.startswith("perf_event_open(ref-cycles):"))
        ):
            raise ValueError("Available perf error must describe the ref-cycles fallback")
        return self


class Evidence(Record):
    address: int = Field(gt=0)
    dli_fname: str = Field(min_length=1)
    dli_fbase: int = Field(gt=0)
    offset: int = Field(ge=0)

    @model_validator(mode="after")
    def check_offset(self) -> Evidence:
        if self.address != self.dli_fbase + self.offset:
            raise ValueError("Resolution address does not equal base plus offset")
        return self


class Resolution(Record):
    glibc: Evidence
    builtin: Evidence


class Delegation(Record):
    caller: str
    symbol: Literal["memcpy", "memmove", "memset"]
    address: str = Field(pattern=r"^0x[0-9a-f]+$")


class Codegen(Record):
    binary_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    checked_roots: list[str]
    delegations: list[Delegation]

    @model_validator(mode="after")
    def check_roots(self) -> Codegen:
        roots = set(self.checked_roots)
        if len(roots) != len(self.checked_roots) or not {"fastmem_copy", "fastmem_move"} <= roots:
            raise ValueError("Codegen evidence requires unique ABI roots")
        if not any(root.startswith("bench_fastmem.runFastmemInline") for root in roots):
            raise ValueError("Codegen evidence requires inline roots")
        if any(call.caller not in roots for call in self.delegations):
            raise ValueError("Delegation caller is outside the inspected roots")
        return self


class Dispatch(Record):
    """The runtime-dispatch level of a baseline x86_64 build (docs/slop/runtime-dispatch.md)."""

    level: Literal[
        "generic", "x86_64_v3", "x86_64_v4", "sapphirerapids", "graniterapids", "znver4", "znver5"
    ]
    kernel: str = Field(min_length=1)
    vendor: Literal["intel", "amd", "other"]
    family: int = Field(ge=0)
    model: int = Field(ge=0)


class Memory(Record):
    """The v3 benchmark memory: one arena at fixed offsets, with its THP state."""

    layout: Literal["arena"]
    arena_bytes: int = Field(gt=0)
    region_bytes: int = Field(gt=0)
    base_align: int = Field(gt=0)
    src_offset: int = Field(ge=0)
    dst_offset: int = Field(ge=0)
    seq_offset: int = Field(ge=0)
    hugepage_advice: str = Field(min_length=1)
    populate: str = Field(min_length=1)
    collapse: str = Field(min_length=1)
    thp_enabled: str | None
    thp_defrag: str | None
    thp_pmd_bytes: int | None = Field(gt=0)
    anon_huge_bytes_start: int | None = Field(ge=0)
    anon_huge_bytes_end: int | None = Field(ge=0)

    @model_validator(mode="after")
    def check_layout(self) -> Memory:
        region = self.region_bytes
        if region % HUGE_PAGE or self.base_align % HUGE_PAGE:
            raise ValueError("Memory regions must be whole 2 MiB pages")
        if self.base_align & (self.base_align - 1):
            raise ValueError("Memory alignment must be a power of two")
        offsets = (self.src_offset, self.dst_offset, self.seq_offset)
        if offsets != (0, region + DST_STAGGER, 2 * region):
            raise ValueError("Memory regions are not at their fixed offsets")
        tail = self.arena_bytes - self.seq_offset
        if tail <= 0 or tail % HUGE_PAGE:
            raise ValueError("Memory sequence region must be whole 2 MiB pages")
        for value in (self.anon_huge_bytes_start, self.anon_huge_bytes_end):
            if value is not None and value > self.arena_bytes:
                raise ValueError("Huge page bytes exceed the arena")
        return self


class Meta(Record):
    type: Literal["meta"]
    schema_version: Literal[2, 3] = Field(alias="schema")
    rev: str
    zig: str
    target: str
    cpu: str
    optimize: Literal["ReleaseFast"]
    link_libc: bool
    chunk_bytes: int = Field(gt=0)
    suite: Literal["quick", "standard", "large", "const", "dist"]
    seed: int = Field(ge=0)
    samples: int = Field(gt=0)
    sample_ms: int = Field(gt=0, le=60000)
    warmup_ms: int = Field(ge=0, le=60000)
    impls: list[Implementation] = Field(min_length=1)
    perf: Perf
    fastmem_set: bool
    set_value: int = Field(gt=0, le=255)
    dist_file: str | None
    libc_path: str
    libc_base: int = Field(gt=0)
    resolution: dict[str, Resolution]
    codegen: Codegen | None
    memory: Memory | None = None
    # Present only in a binary that dispatches at run time (docs/slop/runtime-dispatch.md).
    dispatch: Dispatch | None = None

    @field_validator("schema_version", mode="before")
    @classmethod
    def strict_schema(cls, value: Any) -> int:
        if type(value) is not int or value not in SCHEMAS:
            raise ValueError("Schema must be the integer 2 or 3")
        return value

    @model_validator(mode="after")
    def check_memory(self) -> Meta:
        if (self.memory is None) != (self.schema_version == 2):
            raise ValueError("Schema v3 requires memory, and schema v2 has none")
        return self

    @model_validator(mode="after")
    def check_config(self) -> Meta:
        if self.chunk_bytes not in (16, 32):
            raise ValueError("Invalid SIMD chunk size")
        if not self.link_libc:
            raise ValueError("The schema requires libc")
        if self.target not in {"aarch64-linux-gnu", "x86_64-linux-gnu"}:
            raise ValueError("The schema requires a Linux GNU target")
        if self.target.startswith("aarch64") and "ref-cycles" in self.perf.events:
            raise ValueError("aarch64 does not report ref-cycles")
        if self.dist_file is not None and self.suite != "dist":
            raise ValueError("A histogram requires the dist suite")
        if self.dispatch is not None and not self.target.startswith("x86_64"):
            raise ValueError("Only x86_64 builds dispatch at run time")
        return self

    @model_validator(mode="after")
    def check_resolution(self) -> Meta:
        if set(self.resolution) != set(SYMBOLS):
            raise ValueError("Resolution requires memcpy, memmove, and memset")
        if len(self.impls) != len(set(self.impls)):
            raise ValueError("Duplicate implementation in meta")
        local_libraries = set()
        for pair in self.resolution.values():
            if (
                pair.glibc.dli_fname != self.libc_path
                or pair.glibc.dli_fbase != self.libc_base
                or not self.libc_path.endswith("/libc.so.6")
                or pair.builtin.dli_fbase == self.libc_base
                or pair.builtin.dli_fname == self.libc_path
            ):
                raise ValueError("Invalid glibc/builtin resolution")
            local_libraries.add((pair.builtin.dli_fname, pair.builtin.dli_fbase))
        if len(local_libraries) != 1:
            raise ValueError("Builtins do not resolve to one executable")
        return self


class Sample(Record):
    type: Literal["sample"]
    case: str
    op: Operation
    profile: str
    size: float = Field(ge=0)
    src_off: int | None = Field(ge=0)
    dst_off: int | None = Field(ge=0)
    gap: int | None = Field(ge=0)
    impl: Implementation
    sample: int = Field(ge=0)
    iters: int = Field(gt=0)
    ns: int = Field(gt=0)
    cycles: int | None = Field(ge=0)
    instructions: int | None = Field(ge=0)
    ref_cycles: int | None = Field(ge=0)
    time_enabled: int | None = Field(ge=0)
    time_running: int | None = Field(ge=0)

    @model_validator(mode="after")
    def check_counters(self) -> Sample:
        group = (self.cycles, self.instructions, self.time_enabled, self.time_running)
        if any(value is None for value in group) and any(value is not None for value in group):
            raise ValueError("Incomplete perf group")
        if self.time_running is not None and self.time_enabled is not None:
            if self.time_running > self.time_enabled:
                raise ValueError("Perf running time exceeds enabled time")
        elif self.ref_cycles is not None:
            raise ValueError("Ref-cycles without a perf group")
        if not self.case.startswith(f"{self.op}/{self.profile}/") or self.case.count("/") != 2:
            raise ValueError("Case ID disagrees with operation/profile")
        return self

    @model_validator(mode="after")
    def check_case(self) -> Sample:
        suffix = self.case.rsplit("/", 1)[-1]
        if self.profile == "dist":
            if suffix not in {"small", "mixed", "file"}:
                raise ValueError("Unknown distribution")
            if (self.src_off, self.dst_off, self.gap) != (None, None, None):
                raise ValueError("Distribution offsets and gap must be null")
        else:
            if not self.size.is_integer() or suffix != str(int(self.size)):
                raise ValueError("Fixed size disagrees with case ID")
            if self.src_off is None or self.dst_off is None:
                raise ValueError("Fixed offsets must be integers")
            if self.op != "move" and self.gap is not None:
                raise ValueError("Only a directional move can have a gap")
        return self


class End(Record):
    type: Literal["end"]
    cases: int = Field(ge=0)
    elapsed_ns: int = Field(ge=0)


@dataclass
class Measurement:
    meta: dict[str, Any]
    samples: list[dict[str, Any]]
    end: dict[str, Any]


def applicable(meta: Meta, sample: Sample) -> list[str]:
    if sample.profile == "const":
        allowed = {"builtin_const", "fastmem_inline"}
    else:
        allowed = {"builtin", "glibc", "fastmem_abi", "fastmem_inline"}
    if sample.op == "set" and not meta.fastmem_set:
        allowed -= {"fastmem_abi", "fastmem_inline"}
    return [impl for impl in meta.impls if impl in allowed]


def verify_probe(measurement: Measurement, probe: dict[str, Any]) -> None:
    """Compare paths and offsets, not ASLR-dependent process addresses."""
    meta = measurement.meta
    if meta["libc_path"] != probe.get("libc_path"):
        raise ValueError("Measurement libc path disagrees with libc-probe")
    for name in SYMBOLS:
        reference = probe.get("symbols", {}).get(name, {})
        offset = reference.get("offset")
        if isinstance(offset, str):
            offset = int(offset, 0)
        if meta["resolution"][name]["glibc"]["offset"] != offset:
            raise ValueError(f"Measurement {name} offset disagrees with libc-probe")


def parse(path: Path, *, probe: dict[str, Any] | None = None) -> Measurement:
    try:
        measurement = parse_text(path.read_text())
        if probe is not None:
            verify_probe(measurement, probe)
    except ValueError as error:
        raise ValueError(f"{path}: {error}") from error
    else:
        return measurement


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def validate_case(meta: Meta, sample: Sample) -> None:
    from fastmem_bench.goals import CONST_SIZES, STANDARD_SIZES

    if sample.profile == "dist":
        name = sample.case.rsplit("/", 1)[-1]
        if meta.suite not in {"standard", "dist"}:
            raise ValueError("Distribution is outside the selected suite")
        if (name == "file") != (meta.dist_file is not None):
            raise ValueError("Distribution disagrees with histogram configuration")
        maximum = {"small": 256, "mixed": 16384, "file": 1 << 30}[name]
        if sample.size > maximum:
            raise ValueError("Distribution mean exceeds its maximum")
        return
    sizes = {
        "quick": {8, 32, 64, 256, 1024, 4096, 16384, 262144},
        "standard": set(STANDARD_SIZES),
        "large": {1 << 20, 4 << 20, 16 << 20, 64 << 20},
        "const": set(CONST_SIZES),
        "dist": set(),
    }
    if sample.op == "set":
        sizes["large"].update({24 << 20, 32 << 20, 48 << 20})
    if sample.profile == "const":
        if meta.suite not in {"standard", "const"} or sample.size not in CONST_SIZES:
            raise ValueError("Const case is outside the selected suite")
        if meta.schema_version == 2 and sample.op != "copy":
            raise ValueError("The schema-v2 const profile requires copy")
    elif meta.suite == "const" or sample.size not in sizes[meta.suite]:
        raise ValueError("Fixed case is outside the selected suite")
    validate_offsets(meta, sample)


def validate_offsets(meta: Meta, sample: Sample) -> None:
    expected = {
        "copy": {
            "aligned": (0, 0),
            "misaligned": (1, 3),
            "cross-lane": (meta.chunk_bytes - 1, meta.chunk_bytes // 2),
            "page-offset": (0, 2048),
            "const": (0, 0),
        },
        "set": {"aligned": (0, 0), "misaligned": (1, 3), "const": (0, 0)},
        "move": {"disjoint": (0, 0), "const": (0, 0)},
    }
    offsets = expected[sample.op].get(sample.profile)
    if offsets is not None:
        if (sample.src_off, sample.dst_off) != offsets or sample.gap is not None:
            raise ValueError("Offsets or gap disagree with profile")
        return
    if sample.op == "move" and sample.profile == "fwd-half":
        gap = int(sample.size) // 2
        if sample.gap != gap or (sample.src_off, sample.dst_off) != (gap, 0):
            raise ValueError("Move half-gap disagrees with size or offsets")
        return
    directional = re.fullmatch(r"(fwd|bwd)-gap([0-9]+)", sample.profile)
    if sample.op != "move" or directional is None:
        raise ValueError("Unknown operation profile")
    gap = int(directional[2])
    offsets = (gap, 0) if directional[1] == "fwd" else (0, gap)
    allowed = {1, meta.chunk_bytes - 1, meta.chunk_bytes + 1}
    if directional[1] == "fwd":
        allowed.add(4096)
    if gap not in allowed or sample.gap != gap:
        raise ValueError("Move gap disagrees with profile")
    if (sample.src_off, sample.dst_off) != offsets:
        raise ValueError("Move offsets disagree with direction and gap")


def validate_perf_sample(meta: Meta, sample: Sample) -> None:
    if meta.perf.available and sample.cycles is None:
        raise ValueError("Available perf group has null counters")
    if sample.cycles is not None:
        has_ref = "ref-cycles" in meta.perf.events
        if has_ref != (sample.ref_cycles is not None):
            raise ValueError("Ref-cycles disagree with the final perf group")


def parse_text(text: str) -> Measurement:
    records = [
        json.loads(line, object_pairs_hook=unique_object)
        for line in text.splitlines()
        if line.strip()
    ]
    if any(not isinstance(record, dict) for record in records):
        raise ValueError("JSONL records must be objects")
    first = records[0] if records else {}
    schema = first.get("schema")
    if first.get("type") != "meta" or type(schema) is not int or schema not in SCHEMAS:
        raise ValueError("Expected a schema-v2 or v3 meta record")
    if records[-1].get("type") != "end":
        raise ValueError("Incomplete measurement: no end record")
    meta = Meta.model_validate(records[0])
    end = End.model_validate(records[-1])
    samples = [Sample.model_validate(record) for record in records[1:-1]]
    validate_samples(meta, samples, end)
    return Measurement(
        meta.model_dump(by_alias=True),
        [sample.model_dump() for sample in samples],
        end.model_dump(),
    )


def validate_samples(meta: Meta, samples: list[Sample], end: End) -> None:
    seen = set()
    cases: dict[str, Sample] = {}
    for sample in samples:
        validate_case(meta, sample)
        validate_perf_sample(meta, sample)
        key = (sample.case, sample.impl, sample.sample)
        if key in seen:
            raise ValueError(f"Duplicate sample {key}")
        seen.add(key)
        if sample.case in cases:
            first = cases[sample.case]
            fields = ("op", "profile", "size", "src_off", "dst_off", "gap")
            if any(getattr(first, field) != getattr(sample, field) for field in fields):
                raise ValueError(f"Case metadata changed: {sample.case}")
        cases[sample.case] = sample
    if end.cases != len(cases):
        raise ValueError("End case count does not match samples")
    expected = {
        (case, impl, index)
        for case, sample in cases.items()
        for impl in applicable(meta, sample)
        for index in range(meta.samples)
    }
    if seen != expected:
        raise ValueError("Sample set does not match the declared implementations and sample count")
