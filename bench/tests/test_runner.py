import json
from pathlib import Path
from typing import Any
from unittest.mock import Mock

import pytest
from click.testing import CliRunner
from ec2bench.config import Config
from ec2bench.parallel import Outcome

from fastmem_bench.build import Build, Source
from fastmem_bench.runner import run
from tests.conftest import CODEGEN, PROBE, measurement
from tests.test_protocol import FakeBox, setup


def test_run_up_partial_success_and_passthrough(
    config: Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = Source("v0", "WORKTREE", config.root, "hash")
    build = Build(source, "intel", config.root / "prefix", "key", CODEGEN)
    fleet = Mock()
    fleet.one.return_value = {"InstanceId": "i-test"}
    monkeypatch.setattr("fastmem_bench.runner.Fleet", Mock(return_value=fleet))
    monkeypatch.setattr(
        "fastmem_bench.runner.ensure_up",
        Mock(
            return_value={
                "intel": Outcome(value="i-test"),
                "arm": Outcome(error=TimeoutError("image missing")),
            }
        ),
    )
    monkeypatch.setattr("fastmem_bench.runner.resolve", Mock(return_value=[source]))
    builder = Mock(return_value={"v0/intel": Outcome(value=build)})
    monkeypatch.setattr("fastmem_bench.runner.build_all", builder)
    monkeypatch.setattr("fastmem_bench.runner.disassemble", Mock(return_value=None))
    monkeypatch.setattr("fastmem_bench.runner.box_for", Mock(return_value=Mock()))
    monkeypatch.setattr("ec2bench.runs.git", Mock(return_value="fixture"))
    captured = {}

    def execute(
        _config: Config, _box: Any, _builds: Any, path: Path, **kwargs: Any
    ) -> dict[str, Any]:
        captured.update(kwargs)
        for variant in ("v0", "aa"):
            for index in range(5):
                measurement(path / "intel/raw" / variant / f"r{index}.jsonl")
        return {"warnings": [], "libc_probe": PROBE, "codegen": {"v0": CODEGEN, "aa": CODEGEN}}

    monkeypatch.setattr("fastmem_bench.runner.execute", execute)
    result = CliRunner().invoke(
        run,
        [
            "--up",
            "--label",
            "partial",
            "--filter",
            "aligned",
            "--impl",
            "fastmem_abi,glibc",
            "--samples",
            "2",
            "--sample-ms",
            "1",
            "--minimum-effect",
            "0.005",
        ],
        obj=config,
    )
    assert result.exit_code == 1, result.output
    fleet.reap.assert_called_once()
    assert builder.call_args.args[2] == ["intel"]
    assert captured["binary_args"] == [
        "--filter",
        "aligned",
        "--impl",
        "fastmem_abi,glibc",
        "--samples",
        "2",
        "--sample-ms",
        "1",
    ]
    path = next(config.results_dir.glob("*-partial"))
    summary = json.loads((path / "summary.json").read_text())
    assert summary["targets"]["arm"]["error"] == "image missing"
    assert summary["targets"]["intel"]["minimum_effect"] == 0.005
    manifest = json.loads((path / "manifest.json").read_text())
    assert manifest["schedule_method"] == "seeded-balanced-latin-square"
    assert manifest["schedule"] == captured["schedule"]
    assert manifest["binary_args"] == captured["binary_args"]
    assert manifest["codegen"]["intel"] == {"v0": CODEGEN, "aa": CODEGEN}


def test_early_parse_failure_stops_remaining_rounds(config: Config) -> None:
    from fastmem_bench.protocol import execute

    path, build = setup(config)
    box: Any = FakeBox()
    downloads = 0

    def download(_source: str, destination: Path) -> None:
        nonlocal downloads
        downloads += 1
        if destination.name == "v0":
            measurement(destination / "r0.jsonl")
            file = destination / "r0.jsonl"
            file.write_text("\n".join(file.read_text().splitlines()[:-1]))

    box.download = download
    with pytest.raises(ValueError, match="no end record"):
        execute(
            config,
            box,
            [build],
            path,
            suite="quick",
            schedule=[["v0"], ["v0"]],
            aa=False,
            seed=1,
            binary_args=["--samples", "1", "--filter", "fwd gap"],
        )
    commands = [cmd for cmd in box.commands if cmd.startswith("systemd-run")]
    assert len(commands) == 1
    assert "--samples 1 --filter 'fwd gap'" in commands[0]
    assert "cat " in commands[0]
    assert downloads == 2
    assert any(cmd.startswith("systemctl stop") for cmd in box.commands)


@pytest.mark.parametrize(("cpu", "model"), [("baseline", "x86_64"), ("target", "sapphirerapids")])
def test_run_cpu_mode_reaches_build_manifest_and_goals(
    config: Config, monkeypatch: pytest.MonkeyPatch, cpu: str, model: str
) -> None:
    source = Source("v0", "WORKTREE", config.root, "hash")
    build = Build(source, "intel", config.root / "prefix", "key", CODEGEN)
    fleet = Mock()
    fleet.one.return_value = {"InstanceId": "i-test"}
    monkeypatch.setattr("fastmem_bench.runner.Fleet", Mock(return_value=fleet))
    monkeypatch.setattr("fastmem_bench.runner.resolve", Mock(return_value=[source]))
    builder = Mock(return_value={"v0/intel": Outcome(value=build)})
    monkeypatch.setattr("fastmem_bench.runner.build_all", builder)
    monkeypatch.setattr("fastmem_bench.runner.disassemble", Mock(return_value=None))
    monkeypatch.setattr("fastmem_bench.runner.box_for", Mock(return_value=Mock()))
    monkeypatch.setattr("ec2bench.runs.git", Mock(return_value="fixture"))

    def execute(
        _config: Config, _box: Any, _builds: Any, path: Path, **_kwargs: Any
    ) -> dict[str, Any]:
        for variant in ("v0", "aa"):
            for index in range(5):
                measurement(path / "intel/raw" / variant / f"r{index}.jsonl", cpu=model)
        return {"warnings": [], "libc_probe": PROBE, "codegen": {"v0": CODEGEN, "aa": CODEGEN}}

    monkeypatch.setattr("fastmem_bench.runner.execute", execute)
    result = CliRunner().invoke(
        run, ["--target", "intel", "--cpu", cpu, "--label", "cpu"], obj=config
    )
    assert result.exit_code == 0, result.output
    assert builder.call_args.kwargs["cpu_mode"] == cpu
    path = next(config.results_dir.glob("*-cpu"))
    manifest = json.loads((path / "manifest.json").read_text())
    assert manifest["cpu_mode"] == cpu
    assert manifest["cpus"] == {"intel": model}
    level = "sapphirerapids" if cpu == "baseline" else None
    assert manifest["dispatch_levels"] == {"intel": level}
    summary = json.loads((path / "summary.json").read_text())
    goals = summary["targets"]["intel"]["goals"]
    assert summary["targets"]["intel"]["cpu"] == {"mode": cpu, "models": [model]}
    in_scope = ("G6",) if cpu == "baseline" else ("G2", "G3")
    out_of_scope = ("G2", "G3", "G4") if cpu == "baseline" else ("G6",)
    for goal in goals:
        # The fixture suite is incomplete, so in-scope goals are NA for evidence, not scope.
        for name in in_scope:
            assert goal[name]["reason"].startswith("The complete case set")
        for name in out_of_scope:
            assert goal[name]["status"] == "NA"
            assert "CPU" in goal[name]["reason"]
    # Offline analysis applies the same mode and rejects a mislabeled build.
    from fastmem_bench.runner import analyze_run

    (path / "intel/libc-probe.json").write_text(json.dumps(PROBE))
    assert CliRunner().invoke(analyze_run, [str(path)]).exit_code == 0
    manifest["cpus"]["intel"] = "znver4"
    (path / "manifest.json").write_text(json.dumps(manifest))
    result = CliRunner().invoke(analyze_run, [str(path)])
    assert result.exit_code == 1
    summary = json.loads((path / "summary.json").read_text())
    assert "not znver4" in summary["targets"]["intel"]["error"]
