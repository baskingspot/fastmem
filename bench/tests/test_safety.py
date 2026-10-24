import errno
import json
import shutil
import subprocess
from pathlib import Path
from typing import Any
from unittest.mock import Mock

import pytest
from ec2bench.box import Box, RemoteError
from ec2bench.cli import ensure_up
from ec2bench.config import Config
from ec2bench.facts import collect
from ec2bench.isolation import isolate

from fastmem_bench.build import Source, build_all
from tests.test_protocol import FakeBox, setup


def test_ttl_limit(config: Config) -> None:
    assert config.ttl("12h").total_seconds() == 43200
    with pytest.raises(ValueError, match=r"exceeds fleet\.max_ttl"):
        config.ttl("30d")
    config.fleet["max_ttl"] = "2h"
    with pytest.raises(ValueError, match=r"exceeds fleet\.max_ttl"):
        config.ttl("3h")


def test_generic_config(config: Config) -> None:
    path = config.root / "bench.toml"
    path.write_text(path.read_text().replace('remote_dir = "/root/bench"', ""))
    loaded = Config.load(config.root)
    assert loaded.results_dir == config.root / "bench-results"
    assert loaded.cache_dir == config.root / ".bench-cache"
    loaded.project.update(results_dir="out", cache_dir="cache", ssh_key="~/keys/x.pem")
    assert loaded.results_dir == config.root / "out"
    assert loaded.cache_dir == config.root / "cache"
    assert loaded.ssh_key == Path.home() / "keys" / "x.pem"


def test_ready_failure_terminates_only_failed_box(
    config: Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    fleet = Mock(config=config)
    fleet.launch.side_effect = lambda name, *_args: {"InstanceId": name}
    fleet.wait_running.side_effect = lambda name: {"InstanceId": name}

    def box_for(_fleet: Any, instance: dict[str, Any], _outputs: Any) -> Mock:
        return Mock(
            ready=Mock(
                side_effect=TimeoutError("image missing")
                if instance["InstanceId"] == "arm"
                else None
            )
        )

    monkeypatch.setattr("ec2bench.cli.box_for", box_for)
    results = ensure_up(fleet, ["intel", "arm"])
    assert results["intel"].value == "intel"
    assert "image missing" in str(results["arm"].error)
    fleet.terminate.assert_called_once_with(["arm"])


def test_remote_stderr_and_keepalives(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    box = Box("i-test", "host", tmp_path / "key", tmp_path / "cache", user="bench")
    assert box.destination == "bench@host"
    assert "ServerAliveInterval=15" in box.options
    assert "ServerAliveCountMax=3" in box.options
    monkeypatch.setattr(
        subprocess,
        "run",
        Mock(side_effect=subprocess.CalledProcessError(255, "ssh", stderr="remote failure")),
    )
    with pytest.raises(RemoteError, match="remote failure"):
        box.run("false")


def test_optional_facts(config: Config) -> None:
    box = Mock(instance_id="i-facts", run=Mock(side_effect=RuntimeError("probe unavailable")))
    facts = collect(box, config.results_dir)
    assert len(facts["errors"]) == 8
    assert facts["topology"] is None
    assert json.loads((config.results_dir / ".facts/i-facts.json").read_text()) == facts


def test_busy_box_does_not_change_cpuset() -> None:
    box: Any = Mock()
    box.run.side_effect = ["", "ec2bench-run-other.service loaded active running", ""]
    with (
        pytest.raises(RuntimeError, match="box busy"),
        isolate(
            box,
            [
                {"cpu": 0, "package": 0, "core": 0},
                {"cpu": 1, "package": 0, "core": 1},
            ],
        ),
    ):
        pytest.fail("busy box acquired")
    assert not any("set-property" in call.args[0] for call in box.run.call_args_list)
    # Only harness units count as busy: the box also runs bench-ttl-guard.timer.
    listing = next(c.args[0] for c in box.run.call_args_list if "list-units" in c.args[0])
    assert "ec2bench-run-*" in listing
    assert "'bench-*'" not in listing


def test_stop_before_restore_on_interrupt(config: Config) -> None:
    from fastmem_bench.protocol import execute

    path, build = setup(config)
    box: Any = FakeBox()
    original = box.run

    def run(command: str, **kwargs: Any) -> str:
        if command.startswith("systemd-run"):
            raise KeyboardInterrupt
        return original(command, **kwargs)

    box.run = run
    with pytest.raises(KeyboardInterrupt):
        execute(config, box, [build], path, suite="quick", schedule=[["v0"]], aa=False, seed=1)
    stop = next(index for index, cmd in enumerate(box.commands) if cmd.startswith("systemctl stop"))
    restore = next(index for index, cmd in enumerate(box.commands) if "AllowedCPUs=0-3" in cmd)
    assert stop < restore
    assert box.downloaded


def test_build_race_enotempty(config: Config, monkeypatch: pytest.MonkeyPatch) -> None:
    from tests.conftest import CODEGEN

    config.targets["intel"]["zig_target"] = "x86_64-linux-gnu"
    source = Source("v0", "WORKTREE", config.root, "hash")

    def run(args: list[str], **_kwargs: Any) -> subprocess.CompletedProcess[str]:
        if args[1] == "version":
            return subprocess.CompletedProcess(args, 0, stdout="0.16.0", stderr="")
        prefix = Path(args[-1])
        (prefix / "bin").mkdir()
        for binary in ("bench-fastmem", "libc-probe"):
            (prefix / "bin" / binary).touch()
        return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

    def rename(_path: Path, target: Path) -> None:
        target.mkdir(exist_ok=True)
        shutil.copytree(_path / "bin", target / "bin")
        (target / "complete.json").write_text("{}")
        raise OSError(errno.ENOTEMPTY, "Directory not empty")

    monkeypatch.setattr(subprocess, "run", run)
    monkeypatch.setattr(Path, "rename", rename)
    monkeypatch.setattr("fastmem_bench.build.verify_builtin_calls", lambda _: None)
    monkeypatch.setattr("fastmem_bench.build.inspect_codegen", lambda _: CODEGEN)
    results = build_all(config, [source], ["intel"])
    assert results["v0/intel"].error is None


def test_bad_label_fails_before_launch(config: Config, monkeypatch: pytest.MonkeyPatch) -> None:
    from click.testing import CliRunner

    from fastmem_bench import runner

    launched = Mock()
    monkeypatch.setattr(runner, "Fleet", launched)
    result = CliRunner().invoke(runner.run, ["--up", "--label", "baseline-0.16"], obj=config)
    assert result.exit_code != 0
    assert "Run label" in result.output
    launched.assert_not_called()
