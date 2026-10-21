"""Runtime-dispatch evidence of G6 x86_64 builds (docs/slop/runtime-dispatch.md)."""

import json
from pathlib import Path
from typing import Any

import pytest

from fastmem_bench.analysis import analyze
from fastmem_bench.build import check_dispatch_build, dispatches, expected_dispatch
from fastmem_bench.jsonl import parse
from fastmem_bench.report import dispatch_lines
from tests.conftest import CODEGEN, PROBE, measurement

SPR: dict[str, Any] = {
    "level": "sapphirerapids",
    "kernel": "x86-avx512-straight_1k-v3",
    "vendor": "intel",
    "family": 6,
    "model": 143,
}
# The codegen evidence of a dispatching binary names its resolvers.
DISPATCHING: dict[str, Any] = {
    **CODEGEN,
    "checked_roots": [
        *CODEGEN["checked_roots"],
        "fastmem_x86_0123456789abcdef_resolve_memcpy",
        "fastmem_x86_0123456789abcdef_sapphirerapids_memmove",
    ],
}
INTEL = {"zig_target": "x86_64-linux-gnu", "zig_cpu": "sapphirerapids", "baseline_cpu": "x86_64"}


def rounds(path: Path, **kwargs: Any) -> None:
    for variant in ("v0", "aa"):
        for index in range(5):
            measurement(path / variant / f"r{index}.jsonl", cpu="x86_64", **kwargs)


def baseline(path: Path, expected: str | None = "sapphirerapids") -> dict[str, Any]:
    return analyze(path, ["v0"], "v0", probe=PROBE, cpu_mode="baseline", expected_dispatch=expected)


def test_expected_level_is_the_target_model_of_a_baseline_x86_build() -> None:
    assert expected_dispatch(INTEL, "baseline") == "sapphirerapids"
    assert expected_dispatch(INTEL, "target") is None
    assert expected_dispatch({**INTEL, "baseline_cpu": "x86_64_v3"}, "baseline") is None
    assert expected_dispatch({**INTEL, "zig_cpu": "skylake"}, "baseline") is None
    arm = {"zig_target": "aarch64-linux-gnu", "zig_cpu": "neoverse_v2"}
    assert expected_dispatch(arm, "baseline") is None


def test_capability_comes_from_the_binary_and_the_revision(tmp_path: Path) -> None:
    assert dispatches(DISPATCHING)
    assert not dispatches(CODEGEN)
    assert not dispatches(None)
    old = tmp_path / "old"
    new = tmp_path / "new"
    old.mkdir()
    new.mkdir()
    (old / "build.zig").write_text('b.option(bool, "link-libc", "")')
    (new / "build.zig").write_text('b.option(bool, "x86-dispatch", "")')
    # A revision without the feature: its binary has no resolvers, and passes.
    check_dispatch_build(INTEL, "baseline", old, CODEGEN)
    check_dispatch_build(INTEL, "baseline", new, DISPATCHING)
    # A revision with the feature whose G6 binary does not dispatch.
    with pytest.raises(RuntimeError, match="has no dispatch resolvers"):
        check_dispatch_build(INTEL, "baseline", new, CODEGEN)
    # Target-CPU builds do not dispatch.
    check_dispatch_build(INTEL, "target", new, CODEGEN)


def test_meta_accepts_dispatch_and_rejects_bad_records(tmp_path: Path) -> None:
    measurement(tmp_path / "ok.jsonl", cpu="x86_64", dispatch=SPR, codegen=DISPATCHING)
    assert parse(tmp_path / "ok.jsonl").meta["dispatch"] == SPR
    measurement(tmp_path / "none.jsonl")
    assert parse(tmp_path / "none.jsonl").meta["dispatch"] is None
    measurement(tmp_path / "bad.jsonl", dispatch={**SPR, "level": "haswell"})
    with pytest.raises(ValueError, match="level"):
        parse(tmp_path / "bad.jsonl")


def test_analysis_checks_the_dispatched_level(tmp_path: Path) -> None:
    rounds(tmp_path, dispatch=SPR, codegen=DISPATCHING)
    result = baseline(tmp_path)
    state = {"capable": True, "record": SPR}
    assert result["dispatch"] == {"v0": state, "aa": state}
    with pytest.raises(ValueError, match="dispatched level is sapphirerapids, not x86_64_v4"):
        baseline(tmp_path, "x86_64_v4")
    # One process with a different level: the variant is not one binary state.
    measurement(
        tmp_path / "v0/r4.jsonl",
        cpu="x86_64",
        dispatch={**SPR, "level": "x86_64_v4"},
        codegen=DISPATCHING,
    )
    with pytest.raises(ValueError, match="changed within v0"):
        baseline(tmp_path, None)


def test_a_dispatching_binary_without_its_record_fails(tmp_path: Path) -> None:
    # The resolvers are in the binary, but the meta record has no level.
    rounds(tmp_path, codegen=DISPATCHING)
    with pytest.raises(ValueError, match="disagrees with the binary"):
        baseline(tmp_path)
    with pytest.raises(ValueError, match="disagrees with the binary"):
        baseline(tmp_path, None)
    # A record from a binary without resolvers.
    rounds(tmp_path, dispatch=SPR)
    with pytest.raises(ValueError, match="disagrees with the binary"):
        baseline(tmp_path)


def test_codegen_evidence_is_required_for_an_expectation(tmp_path: Path) -> None:
    rounds(tmp_path, dispatch=SPR, codegen=DISPATCHING)
    for file in tmp_path.glob("*/r*.jsonl"):
        lines = file.read_text().splitlines()
        meta = json.loads(lines[0])
        meta["codegen"] = None
        file.write_text("\n".join([json.dumps(meta), *lines[1:]]) + "\n")
    with pytest.raises(ValueError, match="no codegen evidence"):
        baseline(tmp_path)
    assert baseline(tmp_path, None)["dispatch"]["v0"] == {"capable": True, "record": SPR}


def test_a_binary_without_dispatch_has_no_level(tmp_path: Path) -> None:
    # A revision before P7: no resolvers and no record. It runs the generic
    # kernels, and the report says so.
    rounds(tmp_path)
    result = baseline(tmp_path)
    state = {"capable": False, "record": None}
    assert result["dispatch"] == {"v0": state, "aa": state}


def test_report_names_the_dispatched_level() -> None:
    kernel = "sapphirerapids (x86-avx512-straight_1k-v3)"
    assert dispatch_lines(
        {
            "v0": {"capable": False, "record": None},
            "v1": {"capable": True, "record": SPR},
        }
    ) == [
        "Runtime dispatch, v0: none (the binary has no dispatch).",
        f"Runtime dispatch, v1: {kernel}, intel family 6 model 143.",
        "",
    ]
    assert dispatch_lines({"v0": {"capable": False, "record": None}}) == []
    assert dispatch_lines({}) == []
