"""Native protocol and codegen smoke; build `zig build bench-find-bin` first."""

import hashlib
import json
import subprocess
from pathlib import Path
from typing import Any

import pytest

from fastmem_bench.find_build import validate_codegen
from fastmem_bench.find_codegen import inspect
from fastmem_bench.find_jsonl import inventory, parse

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "zig-out/bin/bench-find"
pytestmark = pytest.mark.skipif(not BINARY.exists(), reason="Build bench-find-bin first")


def invoke(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(BINARY), *args], check=False, capture_output=True, text=True, timeout=120
    )


def test_quick_parses_answers_order_and_binary_hash(tmp_path: Path) -> None:
    result = invoke("--suite", "quick", "--samples", "2", "--sample-ms", "1", "--warmup-ms", "0")
    assert result.returncode == 0, result.stderr
    path = tmp_path / "round.jsonl"
    path.write_text(result.stdout)
    probe = json.loads(invoke("--probe").stdout)
    measurement = parse(path, probe=probe)
    assert len(measurement.cases) == 47
    assert len(measurement.samples) == 416
    assert measurement.meta["binary_sha256"] == hashlib.sha256(BINARY.read_bytes()).hexdigest()
    # Empty needle answers and intentional late prefix/suffix mismatch are independently checked.
    for case in measurement.cases.values():
        if case["nlen"] == 0:
            assert case["oracle"] == 0
        if case["pattern"] in ("prefix", "suffix") and case["position"] == "absent":
            assert case["oracle"] is None


@pytest.mark.parametrize("seed", [0, 1, 2, 42, 2**32 - 1, 2**64 - 1])
def test_standard_inventory_matches_binary(seed: int) -> None:
    result = invoke("--suite", "standard", "--list", "--seed", str(seed))
    assert result.returncode == 0, result.stderr
    records: list[dict[str, Any]] = [json.loads(line) for line in result.stdout.splitlines()]
    designed = inventory("standard")
    actual = {r["case"]: r for r in records if r["type"] == "case"}
    assert set(actual) == set(designed)
    for identity, expected in designed.items():
        assert {key: actual[identity][key] for key in expected} == expected
        assert actual[identity]["oracle"] == expected["requested"]


@pytest.mark.parametrize(
    "args",
    [
        ("--samples", "0"),
        ("--sample-ms", "0"),
        ("--sample-ms", "1001"),
        ("--suite", "large"),
        ("--filter", "no-such-case"),
        ("--samples",),
        ("--unknown", "1"),
    ],
)
def test_invalid_cli_no_success_artifact(args: tuple[str, ...]) -> None:
    result = invoke(*args)
    assert result.returncode != 0
    assert not result.stdout


def test_integrated_executable_search_audit(tmp_path: Path) -> None:
    evidence = inspect(BINARY, tmp_path / "executable.asm", kernel_pending=False)
    validate_codegen(evidence)
    assert evidence["status"] in {"clean", "pending-review"}
    assert evidence["kernel_pending"] is False
    assert evidence["anti_hoist_status"] == "manual-review-required"
    assert evidence["followed_callees"]
    assert "runIndirect" in " ".join(evidence["timed_roots"])
    assert "memmem" not in evidence["followed_callees"]


def test_complete_standard_parses_with_independent_probe(tmp_path: Path) -> None:
    probe_result = invoke("--probe")
    assert probe_result.returncode == 0, probe_result.stderr
    result = invoke("--suite", "standard", "--samples", "1", "--sample-ms", "1", "--warmup-ms", "0")
    assert result.returncode == 0, result.stderr
    path = tmp_path / "standard.jsonl"
    path.write_text(result.stdout)
    measurement = parse(path, probe=json.loads(probe_result.stdout))
    assert len(measurement.cases) == 219
    assert len(measurement.samples) == 1068
    dispatch = measurement.meta["dispatch"]
    assert dispatch is None or set(dispatch) == {"level"}
