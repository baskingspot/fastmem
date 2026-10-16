"""The independent search guard matrix and its fleet execution."""

import hashlib
import json
import shlex
import subprocess
from pathlib import Path
from typing import Any

import click
from rich.console import Console
from rich.table import Table

from ec2bench.box import Box
from ec2bench.cli import box_for
from ec2bench.config import Config
from ec2bench.fleet import Fleet, tags
from ec2bench.parallel import parallel, progress
from ec2bench.runs import create_run, write_manifest
from fastmem_bench.build import source_hash
from fastmem_bench.correctness import check_dispatch, cpus, variant_key

SEED = 0x66696E642D673031
CATEGORIES = (
    "dense",
    "boundary",
    "adversarial",
    "alphabet",
    "shared",
    "random",
    "fixed",
    "seams",
    "structured",
)
PATHS = ["runtime", "fixed"]
OPTIMIZES = ("ReleaseFast", "ReleaseSafe", "Debug")
LIMITS = {"haystack": 1024 * 1024, "needle": 4096, "offset": 63}


def expected_counts(mode: str) -> list[list[int]]:
    """Derive counts independently from the published matrix dimensions."""
    if mode not in {"quick", "full"}:
        raise ValueError("Unknown search guard mode")
    needle_lengths = 27
    large_lengths = 10 * 3 + 2
    alphabet_h = 2 ** (7 if mode == "quick" else 9) - 1
    alphabet_n = 2 ** (5 if mode == "quick" else 6) - 1
    fixed = needle_lengths * 6 * 64 * 2
    return [
        [1025 * 7 * 64 * 4, 0],
        [large_lengths * needle_lengths * 4 * 4 * 5, 0],
        [7 * needle_lengths * 4 * 3, 0],
        [alphabet_h * alphabet_n * 4, 0],
        [1025 * 7 * 4, 0],
        [2000 if mode == "quick" else 20000, 0],
        [fixed, fixed],
        [needle_lengths * 3 * 4 * 9 * 4 * 2, 0],
        [needle_lengths * 8 * 4 * 4, 0],
    ]


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate summary key: {key}")
        result[key] = value
    return result


def invalid_constant(value: str) -> None:
    raise ValueError(f"Non-finite JSON value: {value}")


def count_pair(value: Any) -> bool:
    return (
        isinstance(value, list)
        and len(value) == len(PATHS)
        and all(type(count) is int and count >= 0 for count in value)
    )


def parse_summary(
    text: str,
    cpu: str,
    *,
    optimize: str = "ReleaseFast",
    mode: str = "quick",
    seed: int = SEED,
) -> dict[str, Any]:
    lines = text.splitlines()
    if len(lines) != 1:
        raise ValueError("Expected one search correctness JSON summary")
    result = json.loads(lines[0], object_pairs_hook=unique_object, parse_constant=invalid_constant)
    if (
        not isinstance(result, dict)
        or type(result.get("schema")) is not int
        or result["schema"] != 1
        or result.get("matrix") != "find-g1-balanced-v1"
    ):
        raise ValueError("Invalid search correctness schema")
    if result.get("cpu") != cpu or result.get("optimize") != optimize:
        raise ValueError("Search correctness CPU or optimization mismatch")
    if (
        result.get("mode") != mode
        or type(result.get("seed")) is not int
        or result["seed"] != seed
        or result.get("limits") != LIMITS
        or result.get("paths") != PATHS
        or result.get("categories") != list(CATEGORIES)
        or result.get("link_libc") is not True
    ):
        raise ValueError("Search correctness matrix configuration mismatch")
    if result.get("status") not in {"pass", "fail"}:
        raise ValueError("Invalid search correctness status")
    if type(result.get("elapsed_ns")) is not int or result["elapsed_ns"] < 0:
        raise ValueError("Invalid search correctness elapsed time")
    if not isinstance(result.get("detail"), str) or not isinstance(result.get("case"), dict):
        raise ValueError("Missing search correctness diagnostics")  # noqa: TRY004 — invalid JSON record
    dispatch = result.get("dispatch")
    if dispatch is not None and (
        not isinstance(dispatch, dict)
        or not isinstance(dispatch.get("level"), str)
        or not isinstance(dispatch.get("kernel"), str)
    ):
        raise ValueError("Invalid search correctness dispatch metadata")
    check_matrix(result, mode)
    return result


def check_matrix(result: dict[str, Any], mode: str) -> None:
    counts = result.get("counts")
    expected = expected_counts(mode)
    if not isinstance(counts, list) or len(counts) != len(expected):
        raise ValueError("Incomplete search correctness category list")
    for category, item, required in zip(CATEGORIES, counts, expected, strict=True):
        if (
            not isinstance(item, dict)
            or set(item) != {"expected", "actual"}
            or not count_pair(item["expected"])
            or not count_pair(item["actual"])
            or item["expected"] != required
            or any(actual > limit for actual, limit in zip(item["actual"], required, strict=True))
        ):
            raise ValueError(f"Invalid search correctness counts: {category}")
        if result["status"] == "pass" and item["actual"] != required:
            raise ValueError(f"Incomplete search correctness matrix: {category}")
    if result["status"] == "pass" and (
        result["detail"]
        or result.get("fault_address") is not None
        or result.get("fault_region") is not None
        or result.get("expected_result") != result.get("actual_result")
    ):
        raise ValueError("Search correctness success contains failure diagnostics")


def build_binary(
    config: Config, target: str, cpu: str, path: Path, *, optimize: str
) -> dict[str, Any]:
    path.mkdir(parents=True, exist_ok=True)
    command = [
        "zig",
        "build",
        "find-test-bin",
        "-j2",
        f"-Dtarget={config.targets[target]['zig_target']}",
        f"-Dcpu={cpu}",
        f"-Doptimize={optimize}",
        "--prefix",
        str(path.resolve()),
    ]
    (path / "command.json").write_text(json.dumps(command) + "\n")
    result = subprocess.run(
        command, cwd=config.root, capture_output=True, text=True, timeout=1800, check=False
    )
    (path / "build.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"Search cross build failed: {path / 'build.log'}")
    binary = path / "bin/fastmem-find-tests"
    return {
        "command": command,
        "cpu": cpu,
        "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    }


def execute_binary(
    box: Box,
    binary: Path,
    remote: str,
    path: Path,
    cpu: str,
    *,
    optimize: str,
    mode: str,
    seed: int,
) -> dict[str, Any]:
    path.mkdir(parents=True, exist_ok=True)
    expected_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    box.upload(binary, remote)
    command = (
        f"cd {shlex.quote(remote)} && "
        "sha256sum ./fastmem-find-tests >binary-sha256.txt && "
        f"(ulimit -c 0; ./fastmem-find-tests --mode {shlex.quote(mode)} --seed {seed} "
        ">summary.json 2>stderr.txt; "
        "status=$?; printf '%s\\n' \"$status\" >exit-status.txt)"
    )
    try:
        box.run(command, timeout=3600 if optimize == "Debug" else 1800)
    finally:
        box.download(remote, path)
    if (path / "binary-sha256.txt").read_text().split()[0] != expected_hash:
        raise ValueError("Remote search correctness binary hash mismatch")
    status = int((path / "exit-status.txt").read_text().strip())
    summary = parse_summary(
        (path / "summary.json").read_text(), cpu, optimize=optimize, mode=mode, seed=seed
    )
    summary["exit_status"] = status
    summary["binary_sha256"] = expected_hash
    if status != 0 or summary["status"] != "pass":
        summary["error"] = f"Search guards failed: exit={status}, detail={summary['detail']}"
    return summary


def run_variant(
    config: Config,
    box: Box,
    target: str,
    variant: str,
    cpu: str,
    *,
    path: Path,
    optimize: str,
    mode: str,
    seed: int,
) -> dict[str, Any]:
    result: dict[str, Any] = {"cpu": cpu, "optimize": optimize}
    local = path / target / variant
    try:
        progress(f"build {variant}")
        result["build"] = build_binary(config, target, cpu, local / "build", optimize=optimize)
        progress(f"guards {variant}")
        remote = f"{config.project['remote_dir']}/{path.name}/{target}/{variant}"
        result.update(
            execute_binary(
                box,
                local / "build/bin/fastmem-find-tests",
                remote,
                local / "raw",
                cpu,
                optimize=optimize,
                mode=mode,
                seed=seed,
            )
        )
        check_dispatch(result, config.targets[target], variant)
    except Exception as error:  # noqa: BLE001 — retain the other variants and their evidence
        result["error"] = str(error)
    return result


@click.command(name="find-test")
@click.option("--target", "targets", multiple=True)
@click.option(
    "--optimize",
    "optimizes",
    multiple=True,
    default=("ReleaseFast",),
    type=click.Choice(OPTIMIZES),
    show_default=True,
)
@click.option("--all-modes", is_flag=True, help="Test ReleaseFast, ReleaseSafe, and Debug.")
@click.option("--mode", type=click.Choice(["quick", "full"]), default="quick", show_default=True)
@click.option("--seed", type=click.IntRange(0, 2**64 - 1), default=SEED, show_default=True)
@click.pass_obj
def test_fleet(
    config: Config,
    *,
    targets: tuple[str, ...],
    optimizes: tuple[str, ...],
    all_modes: bool,
    mode: str,
    seed: int,
) -> None:
    """Test search on existing target-CPU and baseline-CPU fleet instances."""
    config.check_storage()
    optimizes = OPTIMIZES if all_modes else tuple(dict.fromkeys(optimizes))
    fleet = Fleet(config)
    names = config.select(targets)
    if not names:
        names = config.select(
            [
                tags(instance)["Target"]
                for instance in fleet.instances()
                if instance["State"]["Name"] == "running" and "Target" in tags(instance)
            ]
        )
    if not names:
        raise click.ClickException("No running search test targets")
    path, manifest = create_run(config.root, "find-test", names, {}, results_dir=config.results_dir)
    manifest.update(
        {
            "kind": "find-correctness",
            "optimizes": optimizes,
            "mode": mode,
            "seed": seed,
            "source_hash": source_hash(config.root),
            "config": {"project": config.project, "targets": config.targets},
            "zig_version": subprocess.run(
                ["zig", "version"],
                capture_output=True,
                text=True,
                check=True,
                timeout=30,
            ).stdout.strip(),
        }
    )
    write_manifest(path, manifest)
    outputs = fleet.outputs()

    def check_target(name: str) -> dict[str, Any]:
        instance = fleet.one(name)
        box = box_for(fleet, instance, outputs)
        box.ready(config.project["image_version"])
        variants = {
            variant_key(variant, optimize): run_variant(
                config,
                box,
                name,
                variant_key(variant, optimize),
                cpu,
                path=path,
                optimize=optimize,
                mode=mode,
                seed=seed,
            )
            for optimize in optimizes
            for variant, cpu in cpus(config.targets[name]).items()
        }
        return {"instance": instance["InstanceId"], "variants": variants}

    outcomes = parallel(names, check_target)
    summary: dict[str, Any] = {
        name: outcome.value if outcome.error is None else {"error": str(outcome.error)}
        for name, outcome in outcomes.items()
    }
    table = Table("Target", "Optimize", "Target CPU", "Baseline CPU")
    for name in names:
        result = summary[name]
        variants = result.get("variants", {})
        failed = False
        for optimize in optimizes:
            statuses = [
                "PASS"
                if variants.get(variant_key(v, optimize), {}).get("status") == "pass"
                and "error" not in variants[variant_key(v, optimize)]
                else "FAIL"
                for v in ("target", "baseline")
            ]
            table.add_row(name, optimize, *statuses)
            failed |= "FAIL" in statuses
        manifest["instances"][name] = result.get("instance")
        manifest.setdefault("status", {})[name] = "failed" if failed else "complete"
    Console().print(table)
    write_manifest(path, manifest)
    temporary = path / "summary.json.tmp"
    temporary.write_text(json.dumps(summary, indent=2, allow_nan=False) + "\n")
    temporary.replace(path / "summary.json")
    click.echo(str(path))
    if "failed" in manifest["status"].values():
        raise click.ClickException("Search guards failed. Read the per-variant raw files.")
