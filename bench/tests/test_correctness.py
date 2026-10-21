import json
import subprocess
from pathlib import Path
from typing import Any
from unittest.mock import Mock

import click
import pytest
from click.testing import CliRunner

from ec2bench.config import Config
from ec2bench.parallel import Outcome
from fastmem_bench import correctness as c


def record(cpu: str = "sapphirerapids", **kwargs: Any) -> dict[str, Any]:
    ceiling = kwargs.get("max_size", c.default_max_size(cpu))
    counts = c.expected_counts(ceiling, has_set=kwargs.get("set_available", False))
    return {
        "schema": 2,
        "matrix": "g1-v2",
        "path_cases": counts,
        "max_size": ceiling,
        "link_libc": True,
        "status": "pass",
        "cpu": cpu,
        "optimize": "ReleaseFast",
        "cases": sum(counts.values()),
        "set_available": False,
        "impl": {"copy": "zig-simd", "move": "zig-simd", "set": "unavailable"},
        **kwargs,
    }


@pytest.mark.parametrize(
    "change",
    [
        {"schema": 1},
        {"status": "skip"},
        {"cpu": "native"},
        {"optimize": "Debug"},
        {"cases": 0},
        {"cases": True},
        {"set_available": None},
        {"impl": {}},
    ],
)
def test_reject_bad_summary(change: dict[str, Any]) -> None:
    with pytest.raises(ValueError, match=r".+"):
        c.parse_summary(json.dumps(record(**change)), "sapphirerapids")


@pytest.mark.parametrize("text", ["", "{}\n{}", "[]", "not JSON"])
def test_reject_incomplete_summary(text: str) -> None:
    with pytest.raises(ValueError, match=r".+"):
        c.parse_summary(text, "sapphirerapids")


def test_zero_cases_failure_is_valid() -> None:
    assert c.parse_summary(
        json.dumps(
            record(
                status="fail", cases=0, path_cases=dict.fromkeys(("runtime", "abi", "constant"), 0)
            )
        ),
        "sapphirerapids",
    )


def test_zen5_ceiling_covers_both_nt_paths() -> None:
    assert c.default_max_size("znver5") == 65 * c.MIB
    assert c.default_max_size("znver4") == 16 * c.MIB
    counts = c.expected_counts(65 * c.MIB, has_set=True)
    assert counts == c.expected_counts(16 * c.MIB, has_set=True)
    assert sum(counts.values()) == 28_047_948
    # Old summaries cannot silently pass without NT coverage.
    with pytest.raises(ValueError, match="size ceiling mismatch"):
        c.parse_summary(json.dumps(record("znver5", max_size=16 * c.MIB)), "znver5")


def test_cpu_contract() -> None:
    assert c.cpus({"zig_target": "x86_64-linux-gnu", "zig_cpu": "znver5"}) == {
        "target": "znver5",
        "baseline": "x86_64",
    }
    assert c.cpus({"zig_target": "aarch64-linux-gnu", "zig_cpu": "neoverse_v3"}) == {
        "target": "neoverse_v3",
        "baseline": "generic",
    }
    with pytest.raises(ValueError, match="explicit"):
        c.cpus({"zig_cpu": "native"})


@pytest.mark.parametrize(
    ("status", "suite_status"), [(0, "pass"), (1, "fail"), (1, "pass"), (0, "fail")]
)
def test_execute_preserves_failure_files(tmp_path: Path, status: int, suite_status: str) -> None:
    box = Mock()

    def download(remote: str, path: Path) -> None:
        (path / "exit-status.txt").write_text(str(status))
        (path / "summary.json").write_text(json.dumps(record(status=suite_status)))
        (path / "stderr.txt").write_text("diagnostic")

    box.download.side_effect = download
    result = c.execute_binary(
        box, tmp_path / "binary", "/root/test dir", tmp_path, "sapphirerapids"
    )
    assert ("error" in result) == (status != 0 or suite_status != "pass")
    assert "cd '/root/test dir'" in box.run.call_args.args[0]
    assert "systemd-run" not in box.run.call_args.args[0]
    assert box.run.call_args.kwargs["timeout"] == 600
    assert (tmp_path / "stderr.txt").read_text() == "diagnostic"


def test_execute_downloads_on_timeout(tmp_path: Path) -> None:
    box = Mock()
    box.run.side_effect = TimeoutError("deadline")
    with pytest.raises(TimeoutError):
        c.execute_binary(box, tmp_path / "binary", "/root/test", tmp_path, "sapphirerapids")
    box.download.assert_called_once()


@pytest.mark.parametrize("optimize", ["Debug", "ReleaseSafe", "ReleaseFast"])
@pytest.mark.parametrize("returncode", [0, 1])
def test_build_command_and_log(
    config: Config,
    monkeypatch: pytest.MonkeyPatch,
    returncode: int,
    optimize: str,
) -> None:
    config.targets["intel"]["zig_target"] = "x86_64-linux-gnu"
    path = config.root / "build"

    def build(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
        assert kwargs["cwd"] == config.root
        assert command[:3] == ["zig", "build", "test-bin"]
        assert f"-Doptimize={optimize}" in command
        assert "-Dcpu=x86_64_v3" in command
        assert "-Dtarget=x86_64-linux-gnu" in command
        (path / "bin").mkdir(parents=True)
        (path / "bin/fastmem-tests").write_bytes(b"fixture")
        return subprocess.CompletedProcess(command, returncode, "out", "err")

    monkeypatch.setattr(c.subprocess, "run", build)
    if returncode:
        with pytest.raises(RuntimeError, match=r"build\.log"):
            c.build_binary(config, "intel", "x86_64_v3", path, optimize=optimize)
    else:
        assert (
            len(c.build_binary(config, "intel", "x86_64_v3", path, optimize=optimize)["sha256"])
            == 64
        )
    assert (path / "build.log").read_text() == "outerr"


def setup(config: Config, monkeypatch: pytest.MonkeyPatch) -> tuple[Mock, Mock]:
    config.targets["intel"]["zig_target"] = "x86_64-linux-gnu"
    config.targets["arm"]["zig_target"] = "aarch64-linux-gnu"
    fleet = Mock()
    fleet.one.side_effect = lambda name: {"InstanceId": f"i-{name}"}
    fleet.instances.return_value = [
        {
            "InstanceId": "i-arm",
            "State": {"Name": "running"},
            "Tags": [{"Key": "Target", "Value": "arm"}],
        }
    ]
    monkeypatch.setattr(c, "Fleet", Mock(return_value=fleet))
    monkeypatch.setattr(c, "source_hash", Mock(return_value="fixture-hash"))
    monkeypatch.setattr(c, "box_for", Mock(return_value=Mock()))
    monkeypatch.setattr("ec2bench.runs.git", Mock(return_value="fixture"))
    monkeypatch.setattr(c.subprocess, "run", Mock(return_value=Mock(stdout="0.16.0\n")))
    builder = Mock(return_value={"sha256": "hash"})
    monkeypatch.setattr(c, "build_binary", builder)
    monkeypatch.setattr(
        c,
        "execute_binary",
        lambda *args, **kwargs: record(
            cpu=args[-1],
            max_size=kwargs["max_size"],
            optimize=kwargs["optimize"],
            **({"dispatch": {"level": "sapphirerapids"}} if args[-1] == "x86_64" else {}),
        ),
    )
    return fleet, builder


@pytest.mark.parametrize(
    ("args", "targets"),
    [([], ["arm"]), (["--target", "intel", "--target", "arm"], ["intel", "arm"])],
)
def test_fleet_selection(
    config: Config,
    monkeypatch: pytest.MonkeyPatch,
    args: list[str],
    targets: list[str],
) -> None:
    fleet, builder = setup(config, monkeypatch)
    result = CliRunner().invoke(c.test_fleet, args, obj=config)
    assert result.exit_code == 0, result.output
    assert "PASS" in result.output
    assert builder.call_count == 2 * len(targets)
    fleet.reap.assert_not_called()
    fleet.terminate.assert_not_called()
    path = next(config.results_dir.glob("*-test"))
    summary = json.loads((path / "summary.json").read_text())
    assert set(summary) == set(targets)
    for item in summary.values():
        assert set(item["variants"]) == {"target", "baseline"}
    manifest = json.loads((path / "manifest.json").read_text())
    assert manifest["source_hash"] == "fixture-hash"
    assert manifest["zig_version"] == "0.16.0"


def test_up_partial_failure(config: Config, monkeypatch: pytest.MonkeyPatch) -> None:
    fleet, builder = setup(config, monkeypatch)
    launch = Mock(
        return_value={
            "intel": Outcome(value="i-intel"),
            "arm": Outcome(error=TimeoutError("image missing")),
        }
    )
    monkeypatch.setattr(c, "ensure_up", launch)
    result = CliRunner().invoke(c.test_fleet, ["--up"], obj=config)
    assert result.exit_code == 1, result.output
    assert "PASS" in result.output
    assert "FAIL" in result.output
    assert builder.call_count == 2
    launch.assert_called_once_with(fleet, ["intel", "arm"])
    summary = json.loads(next(config.results_dir.glob("*/summary.json")).read_text())
    assert summary["arm"]["error"] == "image missing"


def test_failed_build_does_not_skip_baseline(
    config: Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    _, builder = setup(config, monkeypatch)
    builder.side_effect = [RuntimeError("broken target"), {"sha256": "baseline"}]
    result = CliRunner().invoke(c.test_fleet, ["--target", "intel"], obj=config)
    assert result.exit_code == 1, result.output
    assert builder.call_count == 2
    summary = json.loads(next(config.results_dir.glob("*/summary.json")).read_text())
    assert summary["intel"]["variants"]["target"]["error"] == "broken target"
    assert summary["intel"]["variants"]["baseline"]["status"] == "pass"


def test_no_targets(config: Config, monkeypatch: pytest.MonkeyPatch) -> None:
    fleet, _ = setup(config, monkeypatch)
    fleet.instances.return_value = []
    result = CliRunner().invoke(c.test_fleet, [], obj=config)
    assert result.exit_code == 1
    assert "No running targets" in result.output


def test_unknown_target_stops_before_work(config: Config, monkeypatch: pytest.MonkeyPatch) -> None:
    _, builder = setup(config, monkeypatch)
    result = CliRunner().invoke(c.test_fleet, ["--target", "typo"], obj=config)
    assert result.exit_code != 0
    builder.assert_not_called()


@pytest.mark.parametrize("exit_status", [132, 137])
def test_jsonless_death_keeps_exit_status(tmp_path: Path, exit_status: int) -> None:
    box = Mock()

    def download(_remote: str, path: Path) -> None:
        (path / "exit-status.txt").write_text(str(exit_status))
        (path / "summary.json").write_text("")

    box.download.side_effect = download
    with pytest.raises(ValueError, match=f"exit={exit_status}"):
        c.execute_binary(box, tmp_path / "binary", "/root/test", tmp_path, "sapphirerapids")


@pytest.mark.parametrize(
    ("cpu", "mib"),
    [
        ("znver4", 16),
        ("znver5", 65),
        ("sapphirerapids", 67),
        ("graniterapids", 302),
        ("generic", 1),
        ("neoverse_v3", 1),
    ],
)
def test_nt_ceilings(cpu: str, mib: int) -> None:
    assert c.default_max_size(cpu) == mib * c.MIB


def test_verified_native_matrix_count() -> None:
    assert sum(c.expected_counts(c.MIB, has_set=False).values()) == 27620876


@pytest.mark.parametrize(("has_set", "impl"), [(True, "unavailable"), (False, "set-kernel")])
def test_reject_set_availability_mismatch(has_set: bool, impl: str) -> None:
    summary = record(set_available=has_set)
    summary["impl"]["set"] = impl
    with pytest.raises(ValueError, match="Set availability"):
        c.parse_summary(json.dumps(summary), "sapphirerapids")


def test_reject_partial_pass_even_when_counts_agree() -> None:
    summary = record()
    summary["cases"] -= 1
    summary["path_cases"]["constant"] -= 1
    with pytest.raises(ValueError, match="Incomplete correctness matrix"):
        c.parse_summary(json.dumps(summary), "sapphirerapids")


def test_baseline_uses_host_ceiling(config: Config, monkeypatch: pytest.MonkeyPatch) -> None:
    setup(config, monkeypatch)
    execute = Mock(return_value=record(cpu="x86_64_v3", max_size=67 * c.MIB))
    monkeypatch.setattr(c, "execute_binary", execute)
    c.run_variant(config, Mock(), "intel", "baseline", "x86_64_v3", path=config.root)
    assert execute.call_args.kwargs["max_size"] == 67 * c.MIB


@pytest.mark.parametrize(
    ("variant", "dispatch", "error"),
    [
        ("baseline", {"level": "sapphirerapids"}, None),
        ("baseline-Debug", {"level": "x86_64_v4"}, "selected x86_64_v4, expected sapphirerapids"),
        ("baseline", None, "selected None"),
        ("target", None, None),
    ],
)
def test_baseline_checks_the_dispatched_level(
    config: Config,
    monkeypatch: pytest.MonkeyPatch,
    variant: str,
    dispatch: dict[str, str] | None,
    error: str | None,
) -> None:
    setup(config, monkeypatch)
    summary = record(cpu="x86_64", max_size=67 * c.MIB, dispatch=dispatch)
    monkeypatch.setattr(c, "execute_binary", Mock(return_value=summary))
    result = c.run_variant(config, Mock(), "intel", variant, "x86_64", path=config.root)
    assert (error in result.get("error", "")) if error else "error" not in result


@pytest.mark.parametrize("optimize", ["Debug", "ReleaseSafe", "ReleaseFast"])
def test_requested_optimize_summary(optimize: str) -> None:
    assert (
        c.parse_summary(json.dumps(record(optimize=optimize)), "sapphirerapids", optimize=optimize)[
            "optimize"
        ]
        == optimize
    )


def test_multiple_optimizes(config: Config, monkeypatch: pytest.MonkeyPatch) -> None:
    _, builder = setup(config, monkeypatch)
    args = [
        "--target",
        "intel",
        "--optimize",
        "Debug",
        "--optimize",
        "ReleaseSafe",
        "--optimize",
        "ReleaseFast",
        "--optimize",
        "Debug",
    ]
    result = CliRunner().invoke(c.test_fleet, args, obj=config)
    assert result.exit_code == 0, result.output
    assert builder.call_count == 6
    assert {call.kwargs["optimize"] for call in builder.call_args_list} == {
        "Debug",
        "ReleaseSafe",
        "ReleaseFast",
    }
    summary = json.loads(next(config.results_dir.glob("*/summary.json")).read_text())
    assert set(summary["intel"]["variants"]) == {
        "target",
        "baseline",
        "target-Debug",
        "baseline-Debug",
        "target-ReleaseSafe",
        "baseline-ReleaseSafe",
    }


def test_invalid_optimize(config: Config, monkeypatch: pytest.MonkeyPatch) -> None:
    _, builder = setup(config, monkeypatch)
    result = CliRunner().invoke(c.test_fleet, ["--optimize", "ReleaseSmall"], obj=config)
    assert result.exit_code == 2
    builder.assert_not_called()


def test_debug_execution_timeout(tmp_path: Path) -> None:
    box = Mock()

    def download(_remote: str, path: Path) -> None:
        (path / "exit-status.txt").write_text("0")
        (path / "summary.json").write_text(json.dumps(record(optimize="Debug")))

    box.download.side_effect = download
    result = c.execute_binary(
        box, tmp_path / "binary", "/root/test", tmp_path, "sapphirerapids", optimize="Debug"
    )
    assert result["status"] == "pass"
    assert box.run.call_args.kwargs["timeout"] == 3600


def test_watch_exits_when_summary_exists(tmp_path: Path) -> None:
    from ec2bench.runs import watch

    (tmp_path / "summary.json").write_text("{}")
    assert watch(str(tmp_path), 1) == 0
    assert watch(str(tmp_path / "missing"), 0) == 1


def test_all_modes_flag(config: Config) -> None:
    from fastmem_bench.correctness import test_fleet

    ctx = click.Context(test_fleet)
    ctx.ensure_object(type("C", (), {}))
    params = {p.name: p for p in test_fleet.params}
    assert "all_modes" in params
    option = params["all_modes"]
    assert isinstance(option, click.Option)
    assert option.is_flag
