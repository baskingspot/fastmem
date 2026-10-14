"""Offline search requires retained and cross-validated isolation provenance."""

import copy
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
    source_path = str((path / "synthetic-source").resolve())
    source_hash = "b" * 64
    command = [
        "zig",
        "build",
        "bench-find-bin",
        "-Dtarget=aarch64-linux-gnu",
        "-Dcpu=generic",
        "-Doptimize=ReleaseFast",
        "-Drev=fixture",
        "--prefix",
        str(binary.parents[1].resolve()),
    ]
    # These are invented structural sidecars, never executable or performance evidence.
    codegen = {
        "binary_sha256": digest,
        "status": "pending-review",
        "kernel_pending": False,
        "anti_hoist_status": "manual-review-required",
        "checked_roots": ["fixture-root"],
        "followed_callees": ["fixture-root"],
        "followed_functions": [{"address": "0x1", "symbol": "fixture-root"}],
        "delegations": [],
        "unresolved": [],
        "wrapper_symbol": "bench_find_fastmem",
        "wrapper_disassembly": "fixture-root",
        "wrapper_address": "0x1",
        "timed_roots": ["fixture-timed-root"],
        "dispatch_proof": None,
        "dispatch_calls": [],
        "clock_calls_for_manual_review": [],
        "integration_hook": "Synthetic fixture only; not audit acceptance",
    }
    builds = {
        v: {
            "command": command.copy(),
            "binary": str(binary.resolve()),
            "source_hash": source_hash,
            "source_path": source_path,
            "codegen": copy.deepcopy(codegen),
        }
        for v in expected
    }
    (binary.parents[1] / "command.json").write_text(json.dumps(command))
    (binary.parents[1] / "codegen.json").write_text(json.dumps(codegen))
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
        "sources": [
            {"variant": "v0", "revision": "fixture", "hash": source_hash, "path": source_path}
        ],
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
    assert summary["targets"]["local"]["performance_verdict"] == "not-evaluated"
    assert summary["targets"]["local"]["codegen_status"] == {
        "v0": "pending-review",
        "aa": "pending-review",
    }


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


def assert_reanalysis_failed(path: Path) -> None:
    result = CliRunner().invoke(find_analyze, [str(path)])
    assert result.exit_code != 0, result.output
    summary = json.loads((path / "summary.json").read_text())
    assert summary["status"] == "failed"
    assert summary["targets"]["local"]["status"] == "failed"


@pytest.mark.parametrize("field", ["command", "binary", "source_hash", "source_path", "codegen"])
def test_missing_build_fields_rejected(tmp_path: Path, field: str) -> None:
    target, _ = saved_run(tmp_path)
    path = target / "experiment.json"
    experiment = json.loads(path.read_text())
    for item in experiment["builds"].values():
        del item[field]
    path.write_text(json.dumps(experiment))
    assert_reanalysis_failed(tmp_path)


@pytest.mark.parametrize(
    ("index", "value"),
    [
        (0, "false"),
        (2, "install"),
        (3, "-Dtarget=x86_64-linux-gnu"),
        (4, "-Dcpu=wrong"),
        (5, "-Doptimize=Debug"),
        (6, "-Drev=OTHER"),
        (8, "/wrong-prefix"),
    ],
)
def test_changed_build_flags_even_with_matching_sidecar_rejected(
    tmp_path: Path, index: int, value: str
) -> None:
    target, _ = saved_run(tmp_path)
    path = target / "experiment.json"
    experiment = json.loads(path.read_text())
    for item in experiment["builds"].values():
        item["command"][index] = value
    (target / "build/v0/command.json").write_text(json.dumps(experiment["builds"]["v0"]["command"]))
    path.write_text(json.dumps(experiment))
    assert_reanalysis_failed(tmp_path)


@pytest.mark.parametrize("field", ["source_hash", "source_path", "binary"])
def test_wrong_build_identity_rejected(tmp_path: Path, field: str) -> None:
    target, _ = saved_run(tmp_path)
    path = target / "experiment.json"
    experiment = json.loads(path.read_text())
    for item in experiment["builds"].values():
        item[field] = "c" * 64 if field == "source_hash" else "/wrong-identity"
    path.write_text(json.dumps(experiment))
    assert_reanalysis_failed(tmp_path)


@pytest.mark.parametrize("sidecar", ["command.json", "codegen.json"])
@pytest.mark.parametrize("mutation", ["missing", "malformed", "contradictory", "duplicate-key"])
def test_bad_build_sidecars_rejected(tmp_path: Path, sidecar: str, mutation: str) -> None:
    target, _ = saved_run(tmp_path)
    path = target / "build/v0" / sidecar
    if mutation == "missing":
        path.unlink()
    elif mutation == "malformed":
        path.write_text("not json")
    elif mutation == "duplicate-key":
        path.write_text('{"status":"pending-review","status":"invalid"}')
    else:
        path.write_text(json.dumps([] if sidecar == "command.json" else {}))
    assert_reanalysis_failed(tmp_path)


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("status", "invalid"),
        ("status", "clean"),
        ("status", "unknown"),
        ("status", None),
        ("delegations", [{"symbol": "memmem"}]),
        ("unresolved", [{"symbol": "unknown-callee"}]),
        ("delegations", "none"),
        ("unresolved", None),
        ("followed_callees", ["memchr"]),
        ("checked_roots", []),
        ("followed_functions", [{}]),
        ("kernel_pending", True),
        ("binary_sha256", "bad"),
    ],
)
def test_invalid_codegen_even_with_matching_sidecar_rejected(
    tmp_path: Path, field: str, value: object
) -> None:
    target, _ = saved_run(tmp_path)
    path = target / "experiment.json"
    experiment = json.loads(path.read_text())
    for item in experiment["builds"].values():
        item["codegen"][field] = value
    (target / "build/v0/codegen.json").write_text(json.dumps(experiment["builds"]["v0"]["codegen"]))
    path.write_text(json.dumps(experiment))
    assert_reanalysis_failed(tmp_path)


@pytest.mark.parametrize(
    "field",
    [
        "binary_sha256",
        "status",
        "kernel_pending",
        "anti_hoist_status",
        "checked_roots",
        "followed_callees",
        "followed_functions",
        "delegations",
        "unresolved",
        "timed_roots",
        "dispatch_proof",
        "dispatch_calls",
        "clock_calls_for_manual_review",
        "wrapper_symbol",
        "wrapper_disassembly",
        "wrapper_address",
        "integration_hook",
    ],
)
def test_missing_codegen_fields_rejected(tmp_path: Path, field: str) -> None:
    target, _ = saved_run(tmp_path)
    path = target / "experiment.json"
    experiment = json.loads(path.read_text())
    for item in experiment["builds"].values():
        del item["codegen"][field]
    (target / "build/v0/codegen.json").write_text(json.dumps(experiment["builds"]["v0"]["codegen"]))
    path.write_text(json.dumps(experiment))
    assert_reanalysis_failed(tmp_path)


@pytest.mark.parametrize("field", ["command", "binary", "source_hash", "codegen"])
def test_aa_build_drift_rejected(tmp_path: Path, field: str) -> None:
    target, _ = saved_run(tmp_path)
    path = target / "experiment.json"
    experiment = json.loads(path.read_text())
    aa = experiment["builds"]["aa"]
    if field == "command":
        aa[field].append("-Doptimize=Debug")
    elif field == "codegen":
        aa[field]["status"] = "pending-kernel"
    else:
        aa[field] = "drift"
    path.write_text(json.dumps(experiment))
    assert_reanalysis_failed(tmp_path)


def test_changed_retained_binary_rejected(tmp_path: Path) -> None:
    target, _ = saved_run(tmp_path)
    (target / "build/v0/bin/bench-find").write_bytes(b"changed fixture bytes")
    assert_reanalysis_failed(tmp_path)


@pytest.mark.parametrize("field", ["hash", "path", "revision"])
def test_missing_manifest_source_identity_rejected(tmp_path: Path, field: str) -> None:
    saved_run(tmp_path)
    path = tmp_path / "manifest.json"
    manifest = json.loads(path.read_text())
    del manifest["sources"][0][field]
    path.write_text(json.dumps(manifest))
    assert_reanalysis_failed(tmp_path)


def test_aa_expected_metadata_drift_rejected(tmp_path: Path) -> None:
    target, protocol = saved_run(tmp_path)
    path = target / "experiment.json"
    experiment = json.loads(path.read_text())
    experiment["expected"]["aa"]["warmup_ms"] += 1
    protocol["expected"] = experiment["expected"]
    path.write_text(json.dumps(experiment))
    (target / "protocol.json").write_text(json.dumps(protocol))
    assert_reanalysis_failed(tmp_path)
