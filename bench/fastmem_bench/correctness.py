"""Cross-build and execute the guard suite without benchmark CPU isolation."""

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
from ec2bench.cli import box_for, ensure_up
from ec2bench.config import Config
from ec2bench.fleet import Fleet, tags
from ec2bench.parallel import parallel
from ec2bench.runs import create_run, write_manifest
from fastmem_bench.build import baseline_cpu, expected_dispatch, source_hash


def cpus(settings: dict[str, Any]) -> dict[str, str]:
    cpu = settings["zig_cpu"]
    if cpu == "native":
        raise ValueError("Correctness cross builds require an explicit CPU model")
    return {"target": cpu, "baseline": baseline_cpu(settings)}


def build_binary(
    config: Config, target: str, cpu: str, path: Path, *, optimize: str = "ReleaseFast"
) -> dict[str, Any]:
    path.mkdir(parents=True, exist_ok=True)
    command = [
        "zig",
        "build",
        "test-bin",
        f"-Dtarget={config.targets[target]['zig_target']}",
        f"-Dcpu={cpu}",
        f"-Doptimize={optimize}",
        "--prefix",
        str(path.resolve()),
    ]
    result = subprocess.run(
        command,
        cwd=config.root,
        capture_output=True,
        text=True,
        timeout=1200,
        check=False,
    )
    (path / "build.log").write_text(result.stdout + result.stderr)
    (path / "command.json").write_text(json.dumps(command) + "\n")
    if result.returncode:
        raise RuntimeError(f"Cross build failed: {path / 'build.log'}")
    binary = path / "bin/fastmem-tests"
    return {
        "command": command,
        "cpu": cpu,
        "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    }


MIB = 1024 * 1024


def default_max_size(cpu: str) -> int:
    return {"znver4": 16, "znver5": 65, "sapphirerapids": 67, "graniterapids": 302}.get(
        cpu, 1
    ) * MIB


def dense_sizes(max_size: int) -> list[int]:
    dense_limit = min(max_size, MIB)
    lengths = []
    power = 1024
    while power <= dense_limit:
        lengths.extend(n for n in (power - 1, power, power + 1) if n <= dense_limit)
        power *= 2
    for base in (4095, 4096, 4097):
        multiple = base
        while multiple <= dense_limit:
            lengths.append(multiple)
            multiple *= 2
    return lengths


def expected_counts(max_size: int, *, has_set: bool) -> dict[str, int]:
    """Independent arithmetic for the g1-v2 matrix, including deliberate duplicate sizes."""
    counts = dict.fromkeys(("runtime", "abi", "constant"), 0)

    def add(path: str, length: int, offsets: int, overlap_offsets: int) -> None:
        gaps = 4 if length > MIB else 9 if path != "runtime" else 139 if length > 1024 else 129
        counts[path] += 6 * offsets**2 + 4 * overlap_offsets * gaps
        if has_set:
            counts[path] += 6 * offsets

    for length in range(1025):
        add("runtime", length, 64, 4)
        add("abi", length, 4, 1)
    for length in range(1, 257):
        add("constant", length, 4, 1)
    for length in dense_sizes(max_size):
        add("runtime", length, 8 if length <= 65536 else 2, 4)
        add("abi", length, 2, 1)
    if max_size > MIB:
        for length in (max_size - 1, max_size):
            add("runtime", length, 1, 1)
            add("abi", length, 1, 1)
    return counts


def parse_summary(
    text: str, cpu: str, max_size: int | None = None, *, optimize: str = "ReleaseFast"
) -> dict[str, Any]:
    lines = text.splitlines()
    if len(lines) != 1:
        raise ValueError("Expected one correctness JSON summary")
    result = json.loads(lines[0])
    if not isinstance(result, dict) or result.get("schema") != 2 or result.get("matrix") != "g1-v2":
        raise ValueError("Invalid correctness summary schema")
    if result.get("status") not in {"pass", "fail"}:
        raise ValueError("Invalid correctness status")
    if result.get("cpu") != cpu or result.get("optimize") != optimize:
        raise ValueError("Correctness binary CPU or optimization mismatch")
    if type(result.get("cases")) is not int or result["cases"] < 0:
        raise ValueError("Invalid correctness case count")
    if result["status"] == "pass" and result["cases"] == 0:
        raise ValueError("Correctness binary ran no cases")
    if type(result.get("set_available")) is not bool:
        raise ValueError("Missing set availability")
    impl = result.get("impl")
    if not isinstance(impl, dict) or any(
        not isinstance(impl.get(op), str) or not impl[op] for op in ("copy", "move", "set")
    ):
        raise ValueError("Missing correctness kernel identifiers")
    if result["set_available"] == (impl["set"] == "unavailable"):
        raise ValueError("Set availability disagrees with the kernel identifier")
    check_matrix(result, cpu, max_size)
    return result


def check_matrix(result: dict[str, Any], cpu: str, max_size: int | None) -> None:
    ceiling = default_max_size(cpu) if max_size is None else max_size
    if result.get("max_size") != ceiling or not 1024 <= ceiling <= 512 * MIB:
        raise ValueError("Correctness size ceiling mismatch")
    if result.get("link_libc") is not True:
        raise ValueError("Correctness binary must match benchmark libc linkage")
    expected = expected_counts(ceiling, has_set=result["set_available"])
    counts = result.get("path_cases")
    if (
        not isinstance(counts, dict)
        or set(counts) != set(expected)
        or any(
            type(counts[path]) is not int or not 0 <= counts[path] <= expected[path]
            for path in expected
        )
    ):
        raise ValueError("Invalid correctness path counts")
    if result["cases"] != sum(counts.values()):
        raise ValueError("Correctness total disagrees with path counts")
    if result["status"] == "pass" and counts != expected:
        raise ValueError(f"Incomplete correctness matrix: expected {expected}, received {counts}")


def execute_binary(
    box: Box,
    binary: Path,
    remote: str,
    path: Path,
    cpu: str,
    *,
    max_size: int | None = None,
    optimize: str = "ReleaseFast",
) -> dict[str, Any]:
    path.mkdir(parents=True, exist_ok=True)
    box.upload(binary, remote)
    directory = shlex.quote(remote)
    ceiling = default_max_size(cpu) if max_size is None else max_size
    # Save both channels and the exit status, including faults and missing interpreters.
    command = (
        f"cd {directory} && "
        f"(ulimit -c 0; ./fastmem-tests --max-size {ceiling} >summary.json 2>stderr.txt; "
        "status=$?; printf '%s\\n' \"$status\" >exit-status.txt)"
    )
    try:
        box.run(command, timeout=3600 if optimize == "Debug" else 600)
    finally:
        box.download(remote, path)
    status = int((path / "exit-status.txt").read_text().strip())
    try:
        summary = parse_summary(
            (path / "summary.json").read_text(), cpu, ceiling, optimize=optimize
        )
    except (ValueError, OSError) as error:
        raise ValueError(f"Suite exit={status}: {error}") from error
    summary["exit_status"] = status
    if status != 0 or summary["status"] != "pass":
        summary["error"] = f"Suite failed: exit={status}, detail={summary.get('detail', '')}"
    return summary


def run_variant(
    config: Config,
    box: Box,
    target: str,
    variant: str,
    cpu: str,
    *,
    path: Path,
    optimize: str = "ReleaseFast",
) -> dict[str, Any]:
    result: dict[str, Any] = {"cpu": cpu, "optimize": optimize}
    local = path / target / variant
    try:
        result["build"] = build_binary(config, target, cpu, local / "build", optimize=optimize)
        remote = f"{config.project['remote_dir']}/{path.name}/{target}/{variant}"
        result.update(
            execute_binary(
                box,
                local / "build/bin/fastmem-tests",
                remote,
                local / "raw",
                cpu,
                max_size=default_max_size(config.targets[target]["zig_cpu"]),
                optimize=optimize,
            )
        )
        check_dispatch(result, config.targets[target], variant)
    except Exception as error:  # noqa: BLE001 — preserve the other variant's evidence
        result["error"] = str(error)
    return result


def check_dispatch(result: dict[str, Any], settings: dict[str, Any], variant: str) -> None:
    """A baseline x86_64 binary must dispatch to the kernel of the box's model."""
    expected = expected_dispatch(settings, variant.split("-", maxsplit=1)[0])
    actual = (result.get("dispatch") or {}).get("level")
    if expected is not None and actual != expected:
        raise ValueError(f"Runtime dispatch selected {actual}, expected {expected}")


def variant_key(variant: str, optimize: str) -> str:
    return variant if optimize == "ReleaseFast" else f"{variant}-{optimize}"


@click.command(name="test")
@click.option("--target", "targets", multiple=True)
@click.option("--up", "launch", is_flag=True, help="Launch missing targets first.")
@click.option(
    "--optimize",
    "optimizes",
    multiple=True,
    default=("ReleaseFast",),
    type=click.Choice(["ReleaseFast", "Debug", "ReleaseSafe"]),
    show_default=True,
    help=(
        "Repeat to test multiple optimization modes. Debug/ReleaseSafe on a "
        "non-main revision duplicate the main run: the kernel-bytes pin "
        "(zig build test-export) proves a variant's kernels are unchanged. "
        "Use --all-modes for one of those."
    ),
)
@click.option(
    "--all-modes",
    "all_modes",
    is_flag=True,
    help="Run every mode on every revision (slowest; for a final gate before a merge).",
)
@click.pass_obj
def test_fleet(
    config: Config,
    targets: tuple[str, ...],
    launch: bool,
    optimizes: tuple[str, ...],
    all_modes: bool,
) -> None:
    """Run target-CPU and baseline-CPU correctness binaries on each box."""
    config.check_storage()
    if all_modes:
        optimizes = ("ReleaseFast", "ReleaseSafe", "Debug")
    optimizes = tuple(dict.fromkeys(optimizes))
    fleet = Fleet(config)
    names = config.select(targets)
    startup = {}
    if launch:
        startup = ensure_up(fleet, names or list(config.targets))
        names = [name for name, outcome in startup.items() if outcome.error is None]
    elif not names:
        names = config.select(
            [
                tags(instance)["Target"]
                for instance in fleet.instances()
                if instance["State"]["Name"] == "running" and "Target" in tags(instance)
            ]
        )
    if not names and not startup:
        raise click.ClickException("No running targets. Use --up or select a target.")
    path, manifest = create_run(
        config.root,
        "test",
        list(startup) if launch else names,
        {},
        results_dir=config.results_dir,
    )
    manifest.update(
        {
            "kind": "correctness",
            "optimizes": optimizes,
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
    outputs = fleet.outputs() if names else {}

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
            )
            for optimize in optimizes
            for variant, cpu in cpus(config.targets[name]).items()
        }
        return {"instance": instance["InstanceId"], "variants": variants}

    results = parallel(names, check_target)
    summary: dict[str, Any] = {
        name: outcome.value if outcome.error is None else {"error": str(outcome.error)}
        for name, outcome in results.items()
    }
    summary.update(
        {
            name: {"error": str(outcome.error)}
            for name, outcome in startup.items()
            if outcome.error is not None
        }
    )
    (path / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    table = Table("Target", "Optimize", "Target CPU", "Baseline CPU", "Set")
    for name, result in summary.items():
        variants = result.get("variants", {})
        failed = False
        for optimize in optimizes:
            keys = [variant_key(v, optimize) for v in ("target", "baseline")]
            statuses = [
                "PASS"
                if variants.get(v, {}).get("status") == "pass" and "error" not in variants[v]
                else "FAIL"
                for v in keys
            ]
            table.add_row(
                name,
                optimize,
                *statuses,
                "tested"
                if all(variants.get(v, {}).get("set_available") for v in keys)
                else "unavailable",
            )
            failed |= "FAIL" in statuses
        manifest.setdefault("instances", {})[name] = result.get("instance")
        manifest.setdefault("status", {})[name] = "failed" if failed else "complete"
    Console().print(table)
    write_manifest(path, manifest)
    click.echo(str(path))
    if "failed" in manifest["status"].values():
        raise click.ClickException(
            "Correctness failed. Read summary.json and per-variant raw files."
        )
