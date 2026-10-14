import hashlib
import json
import subprocess
from pathlib import Path
from typing import Any
from unittest.mock import Mock

import pytest
from click.testing import CliRunner

from ec2bench.config import Config
from fastmem_bench import search_correctness as c


def record(**changes: Any) -> dict[str, Any]:
    mode = changes.get("mode", "quick")
    return {
        "schema": 1,
        "matrix": "find-g1-balanced-v1",
        "mode": mode,
        "cpu": "sapphirerapids",
        "optimize": "ReleaseFast",
        "seed": c.SEED,
        "limits": c.LIMITS.copy(),
        "paths": c.PATHS.copy(),
        "categories": list(c.CATEGORIES),
        "link_libc": True,
        "dispatch": None,
        "status": "pass",
        "detail": "",
        "elapsed_ns": 100,
        "case": {},
        "expected_result": None,
        "actual_result": None,
        "fault_address": None,
        "fault_region": None,
        "counts": [
            {"expected": pair.copy(), "actual": pair.copy()} for pair in c.expected_counts(mode)
        ],
        **changes,
    }


@pytest.mark.parametrize(("mode", "total"), [("quick", 2_022_892), ("full", 2_153_916)])
def test_independent_matrix(mode: str, total: int) -> None:
    counts = c.expected_counts(mode)
    assert sum(map(sum, counts)) == total
    summary = c.parse_summary(json.dumps(record(mode=mode)), "sapphirerapids", mode=mode)
    assert len(summary["counts"]) == 9
    assert counts[6] == [20_736, 20_736]


@pytest.mark.parametrize(
    "changes",
    [
        {"schema": True},
        {"schema": 2},
        {"matrix": "g1-v2"},
        {"cpu": "native"},
        {"optimize": "Debug"},
        {"mode": "full"},
        {"seed": 1},
        {"seed": True},
        {"limits": {}},
        {"paths": ["runtime"]},
        {"categories": []},
        {"counts": []},
        {"link_libc": False},
        {"status": "skip"},
        {"elapsed_ns": True},
        {"elapsed_ns": -1},
        {"detail": "fault"},
        {"fault_address": 1},
        {"fault_region": "haystack"},
        {"actual_result": 1},
        {"dispatch": "znver5"},
    ],
)
def test_reject_bad_summary(changes: dict[str, Any]) -> None:
    with pytest.raises(ValueError, match=r".+"):
        c.parse_summary(json.dumps(record(**changes)), "sapphirerapids")


@pytest.mark.parametrize(
    "text",
    [
        "",
        "[]",
        "{}\n{}",
        "not JSON",
        '{"schema":1,"schema":1}',
        '{"value":NaN}',
        '{"value":Infinity}',
    ],
)
def test_reject_incomplete_or_ambiguous_json(text: str) -> None:
    with pytest.raises(ValueError, match=r".+"):
        c.parse_summary(text, "sapphirerapids")


@pytest.mark.parametrize("mutation", ["missing", "extra", "bool", "float", "negative", "inflated"])
def test_independent_count_gate(mutation: str) -> None:
    item = record()
    counts = item["counts"]
    if mutation == "missing":
        counts[0]["actual"][0] -= 1
    elif mutation == "extra":
        counts[0]["actual"].append(0)
    elif mutation == "bool":
        counts[0]["actual"][1] = False
    elif mutation == "float":
        counts[0]["expected"][0] = float(counts[0]["expected"][0])
    elif mutation == "negative":
        counts[0]["actual"][0] = -1
    else:
        counts[0]["actual"][0] += 1
    with pytest.raises(ValueError, match=r"counts|Incomplete"):
        c.parse_summary(json.dumps(item), "sapphirerapids")


def test_partial_failure_remains_diagnostic() -> None:
    item = record(status="fail", detail="ResultMismatch")
    for category in item["counts"]:
        category["actual"] = [0, 0]
    assert c.parse_summary(json.dumps(item), "sapphirerapids")["status"] == "fail"


@pytest.mark.parametrize(
    ("status", "suite_status"), [(0, "pass"), (1, "fail"), (1, "pass"), (0, "fail")]
)
def test_remote_result_and_evidence(tmp_path: Path, status: int, suite_status: str) -> None:
    binary = tmp_path / "fastmem-find-tests"
    binary.write_bytes(b"fixture")
    box = Mock()

    def download(remote: str, destination: Path) -> None:
        (destination / "summary.json").write_text(json.dumps(record(status=suite_status)))
        (destination / "exit-status.txt").write_text(str(status))
        (destination / "stderr.txt").write_text("diagnostic")
        (destination / "binary-sha256.txt").write_text(
            hashlib.sha256(b"fixture").hexdigest() + "  ./fastmem-find-tests\n"
        )

    box.download.side_effect = download
    result = c.execute_binary(
        box,
        binary,
        "/root/test dir",
        tmp_path,
        "sapphirerapids",
        optimize="ReleaseFast",
        mode="quick",
        seed=c.SEED,
    )
    assert ("error" in result) == (status != 0 or suite_status != "pass")
    assert result["binary_sha256"] == hashlib.sha256(b"fixture").hexdigest()
    assert "cd '/root/test dir'" in box.run.call_args.args[0]
    assert "ulimit -c 0" in box.run.call_args.args[0]
    assert "systemd-run" not in box.run.call_args.args[0]
    assert box.run.call_args.kwargs["timeout"] == 1800
    assert (tmp_path / "stderr.txt").read_text() == "diagnostic"


def test_remote_timeout_preserves_files(tmp_path: Path) -> None:
    binary = tmp_path / "binary"
    binary.write_bytes(b"fixture")
    box = Mock()
    box.run.side_effect = TimeoutError("deadline")
    with pytest.raises(TimeoutError):
        c.execute_binary(
            box,
            binary,
            "/root/test",
            tmp_path,
            "sapphirerapids",
            optimize="Debug",
            mode="quick",
            seed=c.SEED,
        )
    box.download.assert_called_once()


@pytest.mark.parametrize("optimize", c.OPTIMIZES)
@pytest.mark.parametrize("returncode", [0, 1])
def test_build_command_and_log(
    config: Config, monkeypatch: pytest.MonkeyPatch, returncode: int, optimize: str
) -> None:
    config.targets["intel"]["zig_target"] = "x86_64-linux-gnu"
    path = config.root / "build"

    def build(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        assert kwargs["cwd"] == config.root
        assert command[:3] == ["zig", "build", "find-test-bin"]
        assert f"-Doptimize={optimize}" in command
        assert "-Dcpu=sapphirerapids" in command
        assert "-j2" in command
        (path / "bin").mkdir(parents=True)
        (path / "bin/fastmem-find-tests").write_bytes(b"fixture")
        return subprocess.CompletedProcess(command, returncode, "out", "err")

    monkeypatch.setattr(c.subprocess, "run", build)
    if returncode:
        with pytest.raises(RuntimeError, match=r"build\.log"):
            c.build_binary(config, "intel", "sapphirerapids", path, optimize=optimize)
    else:
        result = c.build_binary(config, "intel", "sapphirerapids", path, optimize=optimize)
        assert result["sha256"] == hashlib.sha256(b"fixture").hexdigest()
    assert (path / "build.log").read_text() == "outerr"
    assert json.loads((path / "command.json").read_text())[:3] == [
        "zig",
        "build",
        "find-test-bin",
    ]


def test_empty_fleet_does_not_launch(config: Config, monkeypatch: pytest.MonkeyPatch) -> None:
    fleet = Mock()
    fleet.instances.return_value = []
    monkeypatch.setattr(c, "Fleet", Mock(return_value=fleet))
    result = CliRunner().invoke(c.test_fleet, obj=config)
    assert result.exit_code == 1
    assert "No running" in result.output
    fleet.launch.assert_not_called()
    fleet.terminate.assert_not_called()
