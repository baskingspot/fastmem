"""Fake transport tests exercise immediate validation and isolation restoration."""

import copy
import json
import subprocess
from pathlib import Path
from typing import Any

import pytest

from ec2bench.config import Config
from fastmem_bench.build import Source
from fastmem_bench.find_build import Build
from fastmem_bench.find_protocol import execute
from tests.test_find_jsonl import PROBE, records, save


class FakeBox:
    instance_id = "i-find"

    def __init__(self, *, fail: bool = False, bad: bool = False) -> None:
        self.fail, self.bad = fail, bad
        self.commands: list[str] = []
        self.downloads: list[str] = []

    def run(self, command: str, **_kwargs: Any) -> str:
        self.commands.append(command)
        if command.endswith("--probe"):
            return json.dumps(PROBE)
        if command.startswith("systemd-run") and self.fail:
            raise subprocess.CalledProcessError(1, command)
        if command.startswith("systemctl show"):
            return "0-3\n"
        return ""

    def upload(self, _source: Path, _destination: str) -> None:
        pass

    def download(self, source: str, destination: Path) -> None:
        self.downloads.append(source)
        if destination.name in ("v0", "aa"):
            for index in range(2):
                values = records()
                values[0]["warmup_ms"] = 1
                if self.bad:
                    values[2]["checksum"] += 1
                save(destination / f"r{index}.jsonl", values)


def setup(config: Config) -> tuple[Path, Build]:
    facts = config.results_dir / ".facts/i-find.json"
    facts.parent.mkdir(parents=True, exist_ok=True)
    facts.write_text(
        json.dumps(
            {
                "instance_id": "i-find",
                "topology": [
                    {"cpu": i, "package": 0, "core": i, "siblings": str(i)} for i in range(4)
                ],
            }
        )
    )
    destination = config.results_dir / "find-run/intel"
    source = Source("v0", "fixture", config.root, "sourcehash")
    build = Build(
        source,
        config.root / "bin/bench-find",
        "generic",
        "aarch64-linux-gnu",
        "0.16.0",
        ["zig", "build", "bench-find-bin"],
        {"binary_sha256": "a" * 64},
    )
    return destination, build


def test_protocol_isolated_same_binary_aa_no_glibc_disassembly(config: Config) -> None:
    destination, build = setup(config)
    box: Any = FakeBox()
    result = execute(
        config,
        box,
        {"v0": build},
        destination,
        schedule=[["v0", "aa"], ["aa", "v0"]],
        suite="quick",
        seed=1,
        samples=2,
        sample_ms=1,
        case_filter="find/runtime/text/start/64/1",
    )
    commands = [c for c in box.commands if c.startswith("systemd-run")]
    assert len(commands) == 4
    assert all("taskset -c 3" in c and "--slice=bench.slice" in c for c in commands)
    assert all("/bin/v0/bench-find" in c for c in commands)
    assert result["expected"]["aa"] == result["expected"]["v0"]
    assert json.loads((destination / "protocol.json").read_text()) == result
    assert all("objdump" not in c for c in box.commands)
    assert len([c for c in box.commands if "AllowedCPUs=0-3" in c]) == 3


@pytest.mark.parametrize("bad", [False, True])
def test_failure_restores_and_downloads(config: Config, bad: bool) -> None:
    destination, build = setup(config)
    box: Any = FakeBox(fail=not bad, bad=bad)
    with pytest.raises(
        (ValueError, subprocess.CalledProcessError), match=r"checksum|returned non-zero"
    ):
        execute(
            config,
            box,
            {"v0": build},
            destination,
            schedule=[["v0", "aa"]],
            suite="quick",
            seed=1,
            samples=2,
            sample_ms=1,
            case_filter="find/runtime/text/start/64/1",
        )
    assert box.downloads
    assert len([c for c in box.commands if "AllowedCPUs=0-3" in c]) == 3
    assert any(c.startswith("systemctl stop ") and "ec2bench-run-" in c for c in box.commands)
    assert (destination / "commands.json").exists()
    assert json.loads((destination / "protocol.json").read_text())["cpu"] == 3


def test_probe_duplicate_fails_before_isolation(
    config: Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    destination, build = setup(config)
    box: Any = FakeBox()
    original_run = box.run

    def run(command: str, **kwargs: Any) -> str:
        if command.endswith("--probe"):
            return '{"libc_path":"/TAMPERED",' + json.dumps(PROBE)[1:]
        return original_run(command, **kwargs)

    monkeypatch.setattr(box, "run", run)
    with pytest.raises(ValueError, match="Duplicate JSON key"):
        execute(
            config,
            box,
            {"v0": build},
            destination,
            schedule=[["v0", "aa"]],
            suite="quick",
            seed=1,
            samples=2,
            sample_ms=1,
            case_filter="find/runtime/text/start/64/1",
        )
    assert not (destination / "memmem-probe.json").exists()
    assert not any(c.startswith("systemd-run") for c in box.commands)


def test_probe_library_mismatch_fails(config: Config, monkeypatch: pytest.MonkeyPatch) -> None:
    destination, build = setup(config)
    box: Any = FakeBox()
    old_run = box.run

    def run(command: str, **kwargs: Any) -> str:
        if command.endswith("--probe"):
            bad = copy.deepcopy(PROBE)
            bad["libc_base"] = bad["executable_base"]
            return json.dumps(bad)
        return old_run(command, **kwargs)

    monkeypatch.setattr(box, "run", run)
    with pytest.raises(ValueError, match="libc handle"):
        execute(
            config,
            box,
            {"v0": build},
            destination,
            schedule=[["v0", "aa"]],
            suite="quick",
            seed=1,
            samples=2,
            sample_ms=1,
            case_filter="find/runtime/text/start/64/1",
        )
    assert not any(c.startswith("systemd-run") for c in box.commands)
