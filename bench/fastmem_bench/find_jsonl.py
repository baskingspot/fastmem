"""Strict, separate fastmem-find/1 dialect. Case inventory is part of the protocol.

This is a deliberately sparse stress inventory, not a user-frequency distribution.
Every case has equal geometric-mean weight (fixed/direct/indirect stay separate).
Standard emphasizes end/absence, boundaries and long-prefix scaling. The ten extra
alignment cases hold bytes constant for random and prefix end/8192/33 with 0/0,
1/0, 0/1, 63/0, 0/63; the older nine correlated pairs are only sparse coverage.
Pattern means and >10% regression rows remain visible; no overall mean proves
worst-case complexity or mission-level acceptance."""

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

IMPLEMENTATIONS = (
    "std_direct",
    "fastmem_direct",
    "std_indirect",
    "fastmem_indirect",
    "glibc_indirect",
)
FIXED_IMPLEMENTATIONS = ("std_fixed", "fastmem_fixed")
PATTERNS = ("random", "text", "low", "uniform", "periodic", "prefix", "suffix")
POSITIONS = ("absent", "start", "middle", "end")
FIXED_LENGTHS = (1, 2, 3, 15, 16, 17, 31, 32, 33)
Implementation = Literal[
    "std_direct",
    "fastmem_direct",
    "std_indirect",
    "fastmem_indirect",
    "glibc_indirect",
    "std_fixed",
    "fastmem_fixed",
]
Pattern = Literal[
    "random", "text", "low", "uniform", "periodic", "prefix", "suffix", "near", "rare"
]
Position = Literal["absent", "start", "middle", "end"]


class Strict(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")


class Evidence(Strict):
    address: int = Field(gt=0, le=2**64 - 1)
    dli_fname: str = Field(min_length=1)
    dli_fbase: int = Field(gt=0, le=2**64 - 1)
    offset: int = Field(ge=0, le=2**64 - 1)


class Resolution(Strict):
    libc_path: str = Field(min_length=1)
    libc_base: int = Field(gt=0, le=2**64 - 1)
    executable_base: int = Field(gt=0, le=2**64 - 1)
    memmem: Evidence


class Dispatch(Strict):
    """Shared selected large-search level; tiny/local paths need not use its entry."""

    level: Literal[
        "generic", "x86_64_v3", "x86_64_v4", "sapphirerapids", "graniterapids", "znver4", "znver5"
    ]


class Meta(Strict):
    type: Literal["meta"]
    dialect: Literal["fastmem-find"]
    schema_version: Literal[1] = Field(alias="schema")
    rev: str = Field(min_length=1, max_length=64)
    zig: str = Field(min_length=1)
    target: str = Field(pattern=r"^(x86_64|aarch64)-linux-gnu$")
    cpu: str = Field(min_length=1)
    dispatch: Dispatch | None
    optimize: Literal["ReleaseFast"]
    link_libc: Literal[True]
    suite: Literal["quick", "standard"]
    seed: int = Field(ge=0, le=2**64 - 1)
    samples: int = Field(ge=1, le=1000)
    sample_ms: int = Field(ge=1, le=1000)
    warmup_ms: int = Field(ge=0, le=1000)
    filter: str
    list: Literal[False]
    resolution: Resolution
    one_shot: Literal[True]
    binary_sha256: str = Field(pattern=r"^[a-f0-9]{64}$")


class Case(Strict):
    type: Literal["case"]
    case: str
    hlen: int = Field(ge=0, le=1048576)
    nlen: int = Field(ge=0, le=4096)
    pattern: Pattern
    position: Position
    requested: int | None = Field(ge=0)
    oracle: int | None = Field(ge=0)
    hay_off: int = Field(ge=0, le=63)
    needle_off: int = Field(ge=0, le=63)
    fixed: bool
    impls: list[Implementation]


class Sample(Strict):
    type: Literal["sample"]
    case: str
    impl: Implementation
    sample: int = Field(ge=0, le=999)
    iters: int = Field(gt=0, le=2**30)
    ns: int = Field(gt=0, le=2**64 - 1)
    checksum: int = Field(ge=0, le=2**64 - 1)
    result: int | None = Field(ge=0)


class End(Strict):
    type: Literal["end"]
    cases: int = Field(gt=0)
    samples: int = Field(gt=0)
    elapsed_ns: int = Field(gt=0, le=2**64 - 1)


def inventory(  # noqa: C901, PLR0912 — the designed protocol inventory stays explicit
    suite: str, case_filter: str = ""
) -> dict[str, dict[str, Any]]:
    cases: dict[str, dict[str, Any]] = {}

    def add(
        hl: int,
        nl: int,
        pattern: str,
        position: str,
        *,
        fixed: bool = False,
        offsets: tuple[int, int] | None = None,
    ) -> None:
        index = len(cases)
        identity = f"find/{'fixed' if fixed else 'runtime'}/{pattern}/{position}/{hl}/{nl}"
        if offsets is not None:
            identity += f"/align/{offsets[0]}/{offsets[1]}"
        if identity in cases:
            raise ValueError(f"Duplicate designed case {identity}")
        requested = (
            0
            if nl == 0
            else None
            if position == "absent" or nl > hl
            else {"start": 0, "middle": (hl - nl) // 2, "end": hl - nl}[position]
        )
        cases[identity] = {
            "case": identity,
            "hlen": hl,
            "nlen": nl,
            "pattern": pattern,
            "position": position,
            "requested": requested,
            "hay_off": offsets[0]
            if offsets is not None
            else (0, 1, 15, 16, 17, 31, 32, 33, 63)[index % 9],
            "needle_off": offsets[1]
            if offsets is not None
            else (3, 0, 33, 1, 31, 17, 63, 16, 32)[index % 9],
            "fixed": fixed,
            "impls": list(FIXED_IMPLEMENTATIONS if fixed else IMPLEMENTATIONS),
        }

    lengths = (
        (0, 1, 2, 3, 16, 17, 32, 33, 256, 257, 1024, 4096)
        if suite == "quick"
        else (
            0,
            1,
            2,
            3,
            4,
            7,
            8,
            15,
            16,
            17,
            31,
            32,
            33,
            63,
            64,
            65,
            127,
            128,
            129,
            255,
            256,
            257,
            512,
            1024,
            4096,
        )
    )
    if suite not in ("quick", "standard"):
        raise ValueError("Unknown search suite")
    for i, nl in enumerate(lengths):
        add(max(64, nl * 4), nl, PATTERNS[i % 7], POSITIONS[i % 4])
        add(max(4096, nl * 8), nl, PATTERNS[(i + 2) % 7], POSITIONS[(i + 1) % 4])
    if suite == "standard":
        for nl in (33, 257, 1024, 4096):
            add(65536, nl, "near", "absent")
        for nl in (512, 1024, 4096):
            add(nl, nl, "rare", "start")
            add(nl + 1, nl, "rare", "end")
            add(262144, nl, "rare", "absent")
        for hl in range(9):
            for nl in (0, 1, 2, 3, 9):
                add(hl, nl, "random", "end")
        for hl in (
            15,
            16,
            17,
            31,
            32,
            33,
            63,
            64,
            65,
            127,
            128,
            129,
            255,
            256,
            257,
            511,
            512,
            513,
            1023,
            1024,
            1025,
            4095,
            4096,
            4097,
        ):
            add(hl, 3, "text", "end")
        for hl in (4096, 16384, 65536):
            for nl in (17, 257, 1024, 4096):
                for pattern in ("prefix", "suffix"):
                    add(hl, nl, pattern, "absent")
        for hl in (16384, 65536, 262144, 1048576):
            for i, position in enumerate(POSITIONS):
                add(hl, 31 + i, PATTERNS[i], position)
        for pattern in PATTERNS:
            for position in POSITIONS:
                add(8192, 15, pattern, position)
    else:
        add(0, 0, "random", "absent")
        add(2, 3, "random", "end")
        add(65536, 257, "prefix", "absent")
        add(65536, 1024, "suffix", "absent")
    for nl in FIXED_LENGTHS:
        add(4096, nl, "text", "end", fixed=True)
    for pattern in ("random", "prefix"):
        for offsets in ((0, 0), (1, 0), (0, 1), (63, 0), (0, 63)):
            add(8192, 33, pattern, "end", offsets=offsets)
    return {key: value for key, value in cases.items() if case_filter in key}


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def validate_resolution(value: dict[str, Any], probe: dict[str, Any] | None = None) -> None:
    r = Resolution.model_validate(value)
    e = r.memmem
    if (
        not r.libc_path.endswith("/libc.so.6")
        or r.libc_base == r.executable_base
        or e.dli_fname != r.libc_path
        or e.dli_fbase != r.libc_base
        or e.address != e.dli_fbase + e.offset
    ):
        raise ValueError("memmem resolution disagrees with independent libc handle")
    if probe is not None:
        validate_resolution(probe)
        if r.libc_path != probe["libc_path"] or e.offset != probe["memmem"]["offset"]:
            raise ValueError("memmem resolution disagrees with independent process probe")


@dataclass
class Measurement:
    meta: dict[str, Any]
    cases: dict[str, dict[str, Any]]
    samples: list[dict[str, Any]]


def parse(  # noqa: C901, PLR0912, PLR0915 — validate the complete atomic protocol seam
    path: Path, *, expected: dict[str, Any] | None = None, probe: dict[str, Any] | None = None
) -> Measurement:
    records = [
        json.loads(line, object_pairs_hook=unique_object) for line in path.read_text().splitlines()
    ]
    if len(records) < 4 or any(not isinstance(record, dict) for record in records):
        raise ValueError("Incomplete search measurement or non-object record")
    meta = Meta.model_validate(records[0]).model_dump(by_alias=True)
    # Literal[1]/Literal[True] use equality in pydantic, so require exact scalar types too.
    if type(records[0].get("schema")) is not int or any(
        type(records[0].get(key)) is not bool for key in ("link_libc", "one_shot", "list")
    ):
        raise ValueError("Wrong literal scalar type")
    if len(meta["rev"].encode()) > 64:
        raise ValueError("Wrong fixed-width revision label")
    dispatching = meta["target"].startswith("x86_64-") and meta["cpu"] in (
        "x86_64",
        "baseline",
        "x86_64_v2",
    )
    if dispatching != (meta["dispatch"] is not None):
        raise ValueError("Missing or unexpected runtime dispatch evidence")
    for key, value in (expected or {}).items():
        actual = (meta["dispatch"] or {}).get("level") if key == "dispatch_level" else meta.get(key)
        if actual != value:
            raise ValueError(f"Wrong {key}: {actual!r}, expected {value!r}")
    validate_resolution(meta["resolution"], probe)
    end = End.model_validate(records[-1])
    designed = inventory(meta["suite"], meta["filter"])
    cases: dict[str, dict[str, Any]] = {}
    samples: list[dict[str, Any]] = []
    seen: set[tuple[str, str, int]] = set()
    sampling = False
    for record in records[1:-1]:
        if record.get("type") == "case":
            case = Case.model_validate(record).model_dump()
            identity = case["case"]
            if sampling or identity in cases or identity not in designed:
                raise ValueError("Duplicate, unknown, or late search case")
            if {key: case[key] for key in designed[identity]} != designed[identity]:
                raise ValueError("Case metadata disagrees with suite inventory")
            answer, hl, nl = case["oracle"], case["hlen"], case["nlen"]
            advertised = 0 if nl == 0 else case["requested"]
            if answer != advertised or (answer is not None and (nl > hl or answer > hl - nl)):
                raise ValueError("Invalid independent oracle first-match answer")
            cases[identity] = case
        else:
            sampling = True
            sample = Sample.model_validate(record).model_dump()
            identity = sample["case"]
            case = cases.get(identity)
            key = (identity, sample["impl"], sample["sample"])
            if (
                case is None
                or sample["impl"] not in case["impls"]
                or key in seen
                or sample["sample"] >= meta["samples"]
                or sample["result"] != case["oracle"]
            ):
                raise ValueError("Duplicate, unknown, or inconsistent search sample")
            expected_checksum = (
                ((case["oracle"] + 1) if case["oracle"] is not None else 0)
                * sample["iters"]
                % 2**64
            )
            if sample["checksum"] != expected_checksum:
                raise ValueError("Wrong result-dependent checksum")
            seen.add(key)
            samples.append(sample)
    complete = {
        (identity, impl, s)
        for identity, case in cases.items()
        for impl in case["impls"]
        for s in range(meta["samples"])
    }
    if (
        list(cases) != list(designed)
        or seen != complete
        or end.cases != len(cases)
        or end.samples != len(samples)
        or end.elapsed_ns < sum(s["ns"] for s in samples)
    ):
        raise ValueError("Incomplete search cases/implementations/samples or invalid end record")
    # Require the emitted rotation, not only a complete unordered set.
    order = [
        (identity, impl, s)
        for identity, case in cases.items()
        for s in range(meta["samples"])
        for impl in case["impls"][s % len(case["impls"]) :]
        + case["impls"][: s % len(case["impls"])]
    ]
    if [(s["case"], s["impl"], s["sample"]) for s in samples] != order:
        raise ValueError("Wrong per-sample implementation rotation")
    return Measurement(meta, cases, samples)
