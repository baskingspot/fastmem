"""Offline search requires retained and cross-validated isolation provenance."""

import hashlib
import json
from pathlib import Path

import pytest
from click.testing import CliRunner

from fastmem_bench.find import find_analyze
from fastmem_bench.protocol import orders
from tests.test_find_jsonl import PROBE, expected_meta, records, save


def saved_run(path: Path) -> tuple[Path, dict]:
    values = records()
    target = path / "local"
    binary = target / "build/v0/bin/bench-find"
    binary.parent.mkdir(parents=True)
    # Synthetic fixture, not executable/codegen acceptance evidence.
    binary.write_bytes(b"fixture executable bytes")
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    values[0]["binary_sha256"] = digest
    expected = {v: expected_meta(values[0]) for v in ("v0", "aa")}
    builds = {
        v: {"codegen": {"binary_sha256": digest, "status": "pending-review"}} for v in expected
    }
    schedule = orders(["v0", "aa"], 1, 1)
    manifest = {
        "dialect": "fastmem-find",
        "schema": 1,
        "targets": ["local"],
        "instances": {"local": "i-find"},
        "rounds": 1,
        "seed": 1,
        "suite": "quick",
        "samples": 2,
        "sample_ms": 1,
        "filter": values[0]["filter"],
        "cpu_mode": "baseline",
        "minimum_effect": 0.01,
        "schedule": schedule,
        "sources": [{"variant": "v0", "revision": "fixture"}],
        "config": {
            "targets": {
                "local": {
                    "zig_target": "aarch64-linux-gnu",
                    "zig_cpu": "neoverse_v2",
                    "baseline_cpu": "generic",
                }
            },
            "project": {"remote_dir": "/root/bench"},
        },
    }
    (path / "manifest.json").write_text(json.dumps(manifest))
    (target / "experiment.json").write_text(
        json.dumps({"rounds": 1, "expected": expected, "builds": builds})
    )
    (target / "memmem-probe.json").write_text(json.dumps(PROBE))
    (target / "facts.json").write_text(
        json.dumps(
            {
                "instance_id": "i-find",
                "topology": [
                    {"cpu": i, "package": 0, "core": i, "siblings": str(i)} for i in range(4)
                ],
            }
        )
    )
    remote = f"/root/bench/{path.name}-find"
    commands = {
        f"{v}/r0": [
            f"{remote}/bin/v0/bench-find",
            "--suite",
            "quick",
            "--seed",
            "1",
            "--samples",
            "2",
            "--sample-ms",
            "1",
            "--filter",
            values[0]["filter"],
        ]
        for v in expected
    }
    protocol = {
        "cpu": 3,
        "isolation": "systemd-cpuset-taskset-v1",
        "remote": remote,
        "instance_id": "i-find",
        "schedule": schedule,
        "probe": PROBE,
        "expected": expected,
        "commands": commands,
    }
    (target / "protocol.json").write_text(json.dumps(protocol))
    (target / "commands.json").write_text(json.dumps(commands))
    for variant in expected:
        save(target / "raw" / variant / "r0.jsonl", values)
    return target, protocol


def test_reanalysis_bad_raw_never_looks_successful(tmp_path: Path) -> None:
    target, _ = saved_run(tmp_path)
    values = [json.loads(line) for line in (target / "raw/v0/r0.jsonl").read_text().splitlines()]
    values[2]["checksum"] += 1
    save(target / "raw/v0/r0.jsonl", values)
    (tmp_path / "summary.json").write_text('{"status":"complete"}')
    result = CliRunner().invoke(find_analyze, [str(tmp_path)])
    assert result.exit_code != 0
    summary = json.loads((tmp_path / "summary.json").read_text())
    assert summary["status"] == "failed"
    assert "checksum" in summary["targets"]["local"]["error"]


def test_reanalysis_preserves_isolated_cpu_and_commands(tmp_path: Path) -> None:
    _, protocol = saved_run(tmp_path)
    result = CliRunner().invoke(find_analyze, [str(tmp_path)])
    assert result.exit_code == 0, result.output
    summary = json.loads((tmp_path / "summary.json").read_text())
    assert summary["targets"]["local"]["protocol"] == protocol
    assert summary["targets"]["local"]["minimum_effect"] == 0.01


@pytest.mark.parametrize(
    "mutation",
    [
        "missing",
        "schedule",
        "commands",
        "probe",
        "cpu",
        "instance",
        "expected",
        "isolation",
        "facts",
        "manifest-dispatch",
    ],
)
def test_reanalysis_rejects_missing_or_mismatched_provenance(tmp_path: Path, mutation: str) -> None:
    target, protocol = saved_run(tmp_path)
    if mutation == "missing":
        (target / "protocol.json").unlink()
    elif mutation == "facts":
        (target / "facts.json").unlink()
    elif mutation == "manifest-dispatch":
        manifest = json.loads((tmp_path / "manifest.json").read_text())
        manifest["config"]["targets"]["local"]["zig_target"] = "x86_64-linux-gnu"
        manifest["config"]["targets"]["local"]["zig_cpu"] = "znver4"
        manifest["config"]["targets"]["local"]["baseline_cpu"] = "x86_64"
        (tmp_path / "manifest.json").write_text(json.dumps(manifest))
    else:
        if mutation == "schedule":
            protocol["schedule"] = []
        elif mutation == "commands":
            protocol["commands"]["aa/r0"] = ["other-binary"]
        elif mutation == "probe":
            protocol["probe"] = {}
        elif mutation == "cpu":
            protocol["cpu"] = True
        elif mutation == "instance":
            protocol["instance_id"] = "i-other"
        elif mutation == "expected":
            protocol["expected"] = {}
        else:
            protocol["isolation"] = "none"
        (target / "protocol.json").write_text(json.dumps(protocol))
    result = CliRunner().invoke(find_analyze, [str(tmp_path)])
    assert result.exit_code != 0
    assert json.loads((tmp_path / "summary.json").read_text())["status"] == "failed"
