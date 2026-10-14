"""Grouping and exact paired/independent search analysis; no invented statistics."""

from pathlib import Path

import pytest

from fastmem_bench.find_analysis import EXPECTED_FIELDS, analyze
from tests.test_find_jsonl import PROBE, records, save


def rounds(raw: Path, *, count: int = 5) -> dict:
    meta = records("")[0]
    expected = {
        variant: {key: meta[key] for key in EXPECTED_FIELDS} for variant in ("v0", "v1", "aa")
    }
    for variant in expected:
        for index in range(count):
            save(
                raw / variant / f"r{index}.jsonl",
                records("", multiplier=2 if variant == "v1" else 1),
            )
    return expected


def test_exact_methods_and_grouping(tmp_path: Path) -> None:
    expected = rounds(tmp_path)
    result = analyze(tmp_path, expected, rounds=5, probe=PROBE)
    assert result["status"] == "complete"
    paired = [r for r in result["rows"] if r["comparison"] == "fastmem_direct/std_direct"]
    assert paired
    assert all(r["ratio"] == pytest.approx(2) for r in paired)
    assert all(r["ci_method"] == "signed-rank" and r["ci_level"] == 0.9375 for r in paired)
    revisions = [r for r in result["rows"] if r["comparison"] == "revision"]
    assert all(r["ratio"] == pytest.approx(2) for r in revisions)
    assert all(
        r["ci_method"] == "mann-whitney" and r["ci_level"] == pytest.approx(0.9682539682539683)
        for r in revisions
    )
    assert all(r["ratio"] == 1 for r in result["rows"] if r["comparison"] == "A/A")
    assert {g["pattern"] for g in result["groups"]} >= {"prefix", "suffix"}
    assert result["primary_geomeans"] == pytest.approx({"v0": 2, "v1": 2})


def test_insufficient_rounds_never_significant(tmp_path: Path) -> None:
    result = analyze(tmp_path, rounds(tmp_path, count=2), rounds=2, probe=PROBE)
    assert result["warnings"]
    assert all(not row["significant"] for row in result["rows"])


def test_missing_round_fails(tmp_path: Path) -> None:
    expected = rounds(tmp_path)
    (tmp_path / "aa/r4.jsonl").unlink()
    with pytest.raises(ValueError, match="Incomplete"):
        analyze(tmp_path, expected, rounds=5, probe=PROBE)


def test_seed_or_oracle_drift_fails(tmp_path: Path) -> None:
    expected = rounds(tmp_path)
    values = records("")
    values[0]["seed"] = 2
    save(tmp_path / "aa/r4.jsonl", values)
    with pytest.raises(ValueError, match="Wrong seed"):
        analyze(tmp_path, expected, rounds=5, probe=PROBE)


def test_aa_wrong_build_fails(tmp_path: Path) -> None:
    expected = rounds(tmp_path)
    expected["aa"]["binary_sha256"] = "b" * 64
    with pytest.raises(ValueError, match="exact baseline"):
        analyze(tmp_path, expected, rounds=5, probe=PROBE)


def test_missing_build_expectations_fails_closed(tmp_path: Path) -> None:
    expected = rounds(tmp_path)
    for meta in expected.values():
        del meta["cpu"]
    with pytest.raises(ValueError, match="Incomplete expected"):
        analyze(tmp_path, expected, rounds=5, probe=PROBE)


def test_outlier_stays_in_the_exact_interval(tmp_path: Path) -> None:
    expected = rounds(tmp_path)
    values = records("")
    for sample in values:
        if sample["type"] == "sample":
            sample["ns"] *= 10
    values[-1]["elapsed_ns"] = sum(v["ns"] for v in values if v["type"] == "sample") + 1000
    save(tmp_path / "v0/r4.jsonl", values)
    result = analyze(tmp_path, expected, rounds=5, probe=PROBE)
    assert any(o["variant"] == "v0" and o["round"] == 4 for o in result["outliers"])
    revisions = [r for r in result["rows"] if r["comparison"] == "revision"]
    assert all(r["outlier_rounds"]["reference"] == [4] for r in revisions)
    # Removing the high baseline process would make the independent interval [2, 2].
    assert all(r["ci95"][0] == pytest.approx(0.2) for r in revisions)
    assert all(r["ci95"][1] == pytest.approx(2) for r in revisions)
