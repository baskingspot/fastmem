import shutil
import subprocess
from pathlib import Path
from unittest.mock import Mock

import click
import pytest
from click.testing import CliRunner

from ec2bench.cli import down, ensure_up
from ec2bench.config import Config
from fastmem_bench import correctness, find, runner, search_correctness
from fastmem_bench.build import resolve


@pytest.fixture
def storage(config: Config, monkeypatch: pytest.MonkeyPatch) -> Config:
    # Exercise exact boundaries with bytes, not gigabytes of test artifacts.
    monkeypatch.setattr("ec2bench.config.GIB", 16)
    return config


def write(path: Path, count: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"x" * count)


def test_missing_artifact_directories(storage: Config) -> None:
    storage.check_storage()
    assert not storage.cache_dir.exists()
    assert not storage.results_dir.exists()


def test_combined_limit_and_no_deletion(storage: Config) -> None:
    cache = storage.cache_dir / "object"
    result = storage.results_dir / "completed/raw.jsonl"
    write(cache, 32)
    write(result, 32)
    storage.check_storage()
    result.write_bytes(b"x" * 33)
    with pytest.raises(ValueError, match="exceed the 4 GiB budget"):
        storage.check_storage()
    assert cache.stat().st_size == 32
    assert result.stat().st_size == 33


def test_custom_paths_and_budget(storage: Config) -> None:
    storage.project.update(cache_dir="scratch", results_dir="measurements", artifact_budget_gib=1)
    write(storage.cache_dir / "object", 17)
    with pytest.raises(ValueError, match="exceed the 1 GiB budget"):
        storage.check_storage()


@pytest.mark.parametrize("value", [0, -1, True, 4.0, "4", None])
def test_invalid_budget(storage: Config, value: object) -> None:
    storage.project["artifact_budget_gib"] = value
    with pytest.raises(ValueError, match="positive integer"):
        storage.check_storage()


def test_symlinks_do_not_count_target_files(storage: Config, tmp_path: Path) -> None:
    outside = tmp_path / "unrelated/file"
    write(outside, 100)
    storage.cache_dir.mkdir()
    (storage.cache_dir / "directory-link").symlink_to(outside.parent, target_is_directory=True)
    (storage.cache_dir / "file-link").symlink_to(outside)
    storage.check_storage()


def test_unreadable_directory_fails_closed(
    storage: Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    with monkeypatch.context() as patch:
        patch.setattr("os.scandir", Mock(side_effect=PermissionError("unreadable cache")))
        with pytest.raises(PermissionError, match="unreadable cache"):
            storage.check_storage()


def test_hardlinks_are_counted_once(storage: Config) -> None:
    source = storage.cache_dir / "object"
    write(source, 64)
    storage.results_dir.mkdir()
    (storage.results_dir / "reused-object").hardlink_to(source)
    storage.check_storage()


def test_source_resolution_stops_before_git_or_builds(
    storage: Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    write(storage.cache_dir / "object", 65)
    git = Mock()
    monkeypatch.setattr("fastmem_bench.build.git", git)
    with pytest.raises(ValueError, match="budget"):
        resolve(storage, ("HEAD",))
    git.assert_not_called()


def test_source_cache_can_be_deleted_and_recreated(storage: Config) -> None:
    subprocess.run(["git", "init", "-q", str(storage.root)], check=True)
    subprocess.run(["git", "add", "bench.toml"], cwd=storage.root, check=True)
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "-qm",
            "source",
        ],
        cwd=storage.root,
        check=True,
    )
    original = resolve(storage, ("HEAD",))[0]
    shutil.rmtree(storage.cache_dir)
    restored = resolve(storage, ("HEAD",))[0]
    assert restored == original
    assert (restored.path / "bench.toml").is_file()


def test_launch_stops_before_cloud_access(storage: Config) -> None:
    write(storage.cache_dir / "object", 65)
    fleet = Mock(config=storage)
    with pytest.raises(ValueError, match="budget"):
        ensure_up(fleet, ["intel"])
    fleet.outputs.assert_not_called()
    fleet.launch.assert_not_called()


@pytest.mark.parametrize(
    ("command", "args", "module"),
    [
        (runner.run, [], runner),
        (find.find, ["--rev", "WORKTREE"], find),
        (correctness.test_fleet, [], correctness),
        (search_correctness.test_fleet, [], search_correctness),
    ],
)
def test_new_run_stops_before_cloud_access(
    storage: Config,
    monkeypatch: pytest.MonkeyPatch,
    command: click.Command,
    args: list[str],
    module: object,
) -> None:
    write(storage.results_dir / "completed/raw.jsonl", 65)
    fleet = Mock()
    monkeypatch.setattr(module, "Fleet", fleet)
    result = CliRunner().invoke(command, args, obj=storage)
    assert result.exit_code != 0
    assert isinstance(result.exception, ValueError)
    assert "budget" in str(result.exception)
    fleet.assert_not_called()


def test_shutdown_is_available_above_budget(
    storage: Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    write(storage.cache_dir / "object", 65)
    fleet = Mock()
    fleet.instances.return_value = []
    monkeypatch.setattr("ec2bench.cli.Fleet", lambda _config: fleet)
    result = CliRunner().invoke(down, ["--all"], obj=storage)
    assert result.exit_code == 0
    fleet.terminate.assert_called_once_with([])
