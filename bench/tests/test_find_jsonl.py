"""Attack every seam of the separate search dialect with synthetic (not timing) records."""

import copy
import json
from pathlib import Path
from typing import Any

import pytest

from fastmem_bench.find_jsonl import inventory, parse

PROBE: dict[str, Any] = {
    "libc_path": "/lib/libc.so.6",
    "libc_base": 10000,
    "executable_base": 20000,
    "memmem": {"address": 10300, "dli_fname": "/lib/libc.so.6", "dli_fbase": 10000, "offset": 300},
}


def records(
    case_filter: str = "find/runtime/text/start/64/1", *, multiplier: int = 1, suite: str = "quick"
) -> list[dict[str, Any]]:
    meta = {
        "type": "meta",
        "dialect": "fastmem-find",
        "schema": 1,
        "rev": "fixture",
        "zig": "0.16.0",
        "target": "aarch64-linux-gnu",
        "cpu": "generic",
        "dispatch": None,
        "optimize": "ReleaseFast",
        "link_libc": True,
        "suite": suite,
        "seed": 1,
        "samples": 2,
        "sample_ms": 1,
        "warmup_ms": 0,
        "filter": case_filter,
        "list": False,
        "resolution": copy.deepcopy(PROBE),
        "one_shot": True,
        "binary_sha256": "a" * 64,
    }
    cases: list[dict[str, Any]] = []
    samples: list[dict[str, Any]] = []
    for case in inventory(suite, case_filter).values():
        oracle = 0 if case["nlen"] == 0 else case["requested"]
        cases.append({"type": "case", **case, "oracle": oracle})
        for s in range(2):
            impls = case["impls"]
            for impl in impls[s % len(impls) :] + impls[: s % len(impls)]:
                samples.append(  # noqa: PERF401 — explicit synthetic protocol record construction
                    {
                        "type": "sample",
                        "case": case["case"],
                        "impl": impl,
                        "sample": s,
                        "iters": 10,
                        "ns": 100 * multiplier * (2 if impl.startswith("fastmem") else 1),
                        "checksum": 0 if oracle is None else 10 * (oracle + 1),
                        "result": oracle,
                    }
                )
    return [
        meta,
        *cases,
        *samples,
        {
            "type": "end",
            "cases": len(cases),
            "samples": len(samples),
            "elapsed_ns": sum(s["ns"] for s in samples) + 1000,
        },
    ]


def save(path: Path, values: list[dict[str, Any]]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(v) for v in values) + "\n")
    return path


def test_valid_fixture(tmp_path: Path) -> None:
    measurement = parse(save(tmp_path / "round.jsonl", records()), probe=PROBE)
    assert len(measurement.cases) == 1
    assert len(measurement.samples) == 10


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("schema", 3),
        ("schema", True),
        ("schema", 1.0),
        ("dialect", "fastmem-memory"),
        ("samples", True),
        ("seed", "1"),
        ("list", True),
        ("one_shot", 1),
        ("target", "aarch64-linux-musl"),
        ("optimize", "Debug"),
        ("binary_sha256", "bad"),
        ("rev", "é" * 64),
    ],
)
def test_bad_meta(tmp_path: Path, field: str, value: Any) -> None:
    values = records()
    values[0][field] = value
    with pytest.raises(ValueError, match=r"validation error|Wrong literal|Wrong fixed-width"):
        parse(save(tmp_path / "bad.jsonl", values))


@pytest.mark.parametrize("field", ["cpu", "target", "rev", "zig", "seed", "binary_sha256"])
def test_manifest_build_mismatch(tmp_path: Path, field: str) -> None:
    with pytest.raises(ValueError, match=f"Wrong {field}"):
        parse(save(tmp_path / "bad.jsonl", records()), expected={field: "wrong"})


@pytest.mark.parametrize(
    "mutation",
    [
        "no-end",
        "duplicate-sample",
        "missing-sample",
        "missing-case",
        "wrong-count",
        "unknown-field",
        "wrong-rotation",
        "wrong-result",
        "wrong-checksum",
        "wrong-iters",
        "zero-ns",
        "overflow-ns",
        "wrong-oracle",
        "wrong-impl",
        "wrong-offset",
        "wrong-position",
        "duplicate-case",
    ],
)
def test_bad_records(  # noqa: C901, PLR0912 — one explicit attack per parameter
    tmp_path: Path, mutation: str
) -> None:
    values = records()
    if mutation == "no-end":
        values.pop()
    elif mutation == "duplicate-sample":
        values.insert(-1, values[2])
    elif mutation == "missing-sample":
        values.pop(2)
    elif mutation == "missing-case":
        values.pop(1)
    elif mutation == "wrong-count":
        values[-1]["cases"] = 2
    elif mutation == "unknown-field":
        values[2]["bytes_per_second"] = 1
    elif mutation == "wrong-rotation":
        values[2], values[3] = values[3], values[2]
    elif mutation == "wrong-result":
        values[2]["result"] = None
    elif mutation == "wrong-checksum":
        values[2]["checksum"] = 11
    elif mutation == "wrong-iters":
        values[2]["iters"] = True
    elif mutation == "zero-ns":
        values[2]["ns"] = 0
    elif mutation == "overflow-ns":
        values[2]["ns"] = 2**64
    elif mutation == "wrong-oracle":
        values[1]["oracle"] = 64
    elif mutation == "wrong-impl":
        values[2]["impl"] = "std_fixed"
    elif mutation == "wrong-offset":
        values[1]["hay_off"] = 63
    elif mutation == "wrong-position":
        values[1]["position"] = "absent"
    else:
        values.insert(2, values[1])
    with pytest.raises(
        ValueError, match=r"validation error|Invalid|Wrong|Duplicate|Incomplete|Case"
    ):
        parse(save(tmp_path / "bad.jsonl", values))


def test_duplicate_json_keys(tmp_path: Path) -> None:
    path = save(tmp_path / "bad.jsonl", records())
    path.write_text(path.read_text().replace('"seed": 1', '"seed": 1, "seed": 2'))
    with pytest.raises(ValueError, match="Duplicate JSON key"):
        parse(path)


@pytest.mark.parametrize(("field", "value"), [("libc_path", "/not-libc/exe"), ("libc_base", 20000)])
def test_library_identity(tmp_path: Path, field: str, value: Any) -> None:
    values = records()
    values[0]["resolution"][field] = value
    with pytest.raises(ValueError, match="libc handle"):
        parse(save(tmp_path / "bad.jsonl", values))


def test_independent_probe_offset(tmp_path: Path) -> None:
    other = copy.deepcopy(PROBE)
    other["memmem"]["offset"] += 1
    other["memmem"]["address"] += 1
    with pytest.raises(ValueError, match="independent process probe"):
        parse(save(tmp_path / "bad.jsonl", records()), probe=other)


def test_boundary_inventory_and_filter_stability() -> None:
    cases = inventory("standard")
    assert len(cases) == 219
    assert {0, 1, 2, 3, 15, 16, 17, 31, 32, 33, 63, 64, 65, 255, 256, 257, 512, 1024, 4096} <= {
        c["nlen"] for c in cases.values()
    }
    assert {"random", "text", "low", "uniform", "periodic", "prefix", "suffix", "near", "rare"} == {
        c["pattern"] for c in cases.values()
    }
    selected = inventory("standard", "prefix")
    assert selected == {key: c for key, c in cases.items() if "prefix" in key}
    aligned = [c for c in cases.values() if "/align/" in c["case"]]
    assert len(aligned) == 10
    assert {(c["hay_off"], c["needle_off"]) for c in aligned} == {
        (0, 0),
        (1, 0),
        (0, 1),
        (63, 0),
        (0, 63),
    }


def expected_meta(meta: dict[str, Any]) -> dict[str, Any]:
    from fastmem_bench.find_analysis import EXPECTED_FIELDS

    return {
        key: (meta["dispatch"] or {}).get("level") if key == "dispatch_level" else meta[key]
        for key in EXPECTED_FIELDS
    }


@pytest.mark.parametrize(
    "case_filter",
    [
        "find/runtime/text/end/4096/8",
        "find/runtime/text/absent/64/16",
        "find/runtime/low/middle/64/2",
    ],
)
def test_mislabeled_first_matches_rejected(tmp_path: Path, case_filter: str) -> None:
    values = records("", suite="standard")
    case = next(c for c in values if c.get("case") == case_filter and c["type"] == "case")
    case["oracle"] = 0  # Valid bounds, coherent samples, but wrong FIRST match.
    for sample in values:
        if sample["type"] == "sample" and sample["case"] == case_filter:
            sample["result"] = 0
            sample["checksum"] = sample["iters"]
    with pytest.raises(ValueError, match="first-match"):
        parse(save(tmp_path / "bad.jsonl", values))


def test_dispatch_required_and_expected_level_enforced(tmp_path: Path) -> None:
    values = records()
    values[0].update(target="x86_64-linux-gnu", cpu="x86_64")
    with pytest.raises(ValueError, match="dispatch evidence"):
        parse(save(tmp_path / "bad.jsonl", values))
    values[0]["dispatch"] = {"level": "generic"}
    with pytest.raises(ValueError, match="Wrong dispatch_level"):
        parse(save(tmp_path / "bad.jsonl", values), expected={"dispatch_level": "znver4"})
    values[0]["dispatch"]["level"] = "znver4"
    parse(save(tmp_path / "good.jsonl", values), expected={"dispatch_level": "znver4"})


def test_non_find_kernel_decoration_rejected(tmp_path: Path) -> None:
    values = records()
    values[0].update(target="x86_64-linux-gnu", cpu="x86_64")
    values[0]["dispatch"] = {"level": "znver4", "kernel": "not-a-find-kernel"}
    with pytest.raises(ValueError, match="kernel"):
        parse(save(tmp_path / "bad.jsonl", values))
