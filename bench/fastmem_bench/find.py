"""The `just b find` experiment and offline reanalysis, isolated from schema-v3 goals."""

import hashlib
import json
import re
from pathlib import Path
from typing import Any

import click

from ec2bench.cli import box_for
from ec2bench.config import Config
from ec2bench.fleet import Fleet, tags
from ec2bench.isolation import select_cpu
from ec2bench.parallel import parallel
from ec2bench.runs import create_run, validate_label, write_manifest
from fastmem_bench.analysis import validate_effect
from fastmem_bench.build import CPU_MODES, build_cpu, expected_dispatch, resolve
from fastmem_bench.find_analysis import analyze
from fastmem_bench.find_build import build, build_command, read_evidence, validate_codegen
from fastmem_bench.find_jsonl import validate_resolution
from fastmem_bench.find_protocol import execute
from fastmem_bench.protocol import orders


@click.command(name="find")
@click.option("--rev", "revisions", multiple=True, default=("WORKTREE",))
@click.option("--target", "targets", multiple=True)
@click.option("--cpu", "cpu_mode", type=click.Choice(CPU_MODES), default="target")
@click.option("--suite", type=click.Choice(["quick", "standard"]), default="standard")
@click.option("--rounds", type=click.IntRange(1, 50), default=5)
@click.option("--label", default="find")
@click.option("--samples", type=click.IntRange(1, 1000), default=10)
@click.option("--sample-ms", type=click.IntRange(1, 1000), default=2)
@click.option("--seed", type=click.IntRange(0, 2**32 - 1), default=1)
@click.option("--filter", "case_filter", default="")
@click.pass_obj
def find(
    config: Config,
    *,
    revisions: tuple[str, ...],
    targets: tuple[str, ...],
    cpu_mode: str,
    suite: str,
    rounds: int,
    label: str,
    samples: int,
    sample_ms: int,
    seed: int,
    case_filter: str,
) -> None:
    """Measure one-shot search on running boxes; always include the exact baseline A/A.

    Does not launch, reap, terminate, or mutate cloud resources. `bench watch` monitors
    this ordinary ec2bench run directory. Ratios count operations, not searched bytes.
    """
    config.check_storage()
    try:
        validate_label(label)
    except ValueError as error:
        raise click.ClickException(str(error)) from error
    effect = config.project.get("minimum_effect", 0.0)
    validate_effect(effect)
    fleet = Fleet(config)
    names = config.select(targets)
    if not names:
        names = config.select(
            [
                tags(i)["Target"]
                for i in fleet.instances()
                if i["State"]["Name"] == "running" and "Target" in tags(i)
            ]
        )
    if not names:
        raise click.ClickException("No running targets; find never launches instances")
    instances = {name: fleet.one(name) for name in names}
    path, manifest = create_run(
        config.root,
        label,
        names,
        {n: i["InstanceId"] for n, i in instances.items()},
        results_dir=config.results_dir,
    )
    sources = resolve(config, revisions)
    schedule = orders([s.variant for s in sources] + ["aa"], rounds, seed)
    manifest.update(
        {
            "dialect": "fastmem-find",
            "schema": 1,
            "seed": seed,
            "rounds": rounds,
            "suite": suite,
            "samples": samples,
            "sample_ms": sample_ms,
            "filter": case_filter,
            "cpu_mode": cpu_mode,
            "aa": True,
            "schedule": schedule,
            "schedule_method": "seeded-balanced-latin-square",
            "minimum_effect": effect,
            "config": {
                "targets": config.targets,
                "project": {"remote_dir": config.project["remote_dir"]},
            },
            "sources": [
                {
                    "variant": s.variant,
                    "revision": s.revision,
                    "hash": s.source_hash,
                    "path": str(s.path),
                }
                for s in sources
            ],
        }
    )
    write_manifest(path, manifest)
    outputs = fleet.outputs()

    def measure(name: str) -> dict[str, Any]:
        settings = config.targets[name]
        cpu = build_cpu(settings, cpu_mode)
        destination = path / name
        builds = {
            s.variant: build(
                s,
                destination / "build" / s.variant,
                target=settings["zig_target"],
                cpu=cpu,
                dispatch_level=expected_dispatch(settings, cpu_mode),
            )
            for s in sources
        }
        variants = {**builds, "aa": builds["v0"]}
        experiment = {
            "rounds": rounds,
            "expected": {
                v: b.expected(
                    suite=suite,
                    seed=seed,
                    samples=samples,
                    sample_ms=sample_ms,
                    case_filter=case_filter,
                )
                for v, b in variants.items()
            },
            "builds": {
                v: {
                    "command": b.command,
                    "binary": str(b.binary),
                    "codegen": b.codegen,
                    "source_hash": b.source.source_hash,
                    "source_path": str(b.source.path),
                }
                for v, b in variants.items()
            },
        }
        (destination / "experiment.json").write_text(json.dumps(experiment, indent=2) + "\n")
        box = box_for(fleet, instances[name], outputs)
        box.ready(config.project["image_version"])
        protocol = execute(
            config,
            box,
            builds,
            destination,
            schedule=schedule,
            suite=suite,
            seed=seed,
            samples=samples,
            sample_ms=sample_ms,
            case_filter=case_filter,
        )
        result = analyze_target(destination)
        result["protocol"] = protocol
        return result

    results = parallel(names, measure)
    summary = {
        "run_id": path.name,
        "dialect": "fastmem-find",
        "schema": 1,
        "status": "failed" if any(r.error for r in results.values()) else "complete",
        "targets": {
            name: r.value if r.error is None else {"status": "failed", "error": str(r.error)}
            for name, r in results.items()
        },
    }
    (path / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    manifest["status"] = {name: "failed" if r.error else "complete" for name, r in results.items()}
    write_manifest(path, manifest)
    click.echo(str(path))
    if summary["status"] == "failed":
        raise click.ClickException(
            "Search measurement failed; read summary.json and retained raw files"
        )


def analyze_target(destination: Path) -> dict[str, Any]:
    experiment = read_evidence(destination / "experiment.json")
    manifest = read_evidence(destination.parent / "manifest.json")
    protocol = read_evidence(destination / "protocol.json")
    validate_protocol(destination, manifest, experiment, protocol)
    validate_builds(destination, manifest, experiment)
    result = analyze(
        destination / "raw",
        experiment["expected"],
        rounds=experiment["rounds"],
        probe=read_evidence(destination / "memmem-probe.json"),
        minimum_effect=manifest["minimum_effect"],
    )
    result["protocol"] = protocol
    result["builds"] = experiment["builds"]
    result["codegen_status"] = {
        v: item["codegen"]["status"] for v, item in experiment["builds"].items()
    }
    result["performance_verdict"] = "not-evaluated"
    result["warnings"].append(
        "No search goal verdict; pending-kernel or manual codegen review is not acceptance"
    )
    return result


def validate_builds(
    destination: Path, manifest: dict[str, Any], experiment: dict[str, Any]
) -> None:
    """Cross-check retained identities before analyzing any successful measurement rows."""
    sources = {source["variant"]: source for source in manifest["sources"]}
    if (
        len(sources) != len(manifest["sources"])
        or "v0" not in sources
        or any(not re.fullmatch(r"v[0-9]+", variant) for variant in sources)
    ):
        raise ValueError("Invalid search source variants")
    settings = manifest["config"]["targets"][destination.name]
    cpu = build_cpu(settings, manifest["cpu_mode"])
    builds, expected = experiment["builds"], experiment["expected"]
    if builds["aa"] != builds["v0"] or expected["aa"] != expected["v0"]:
        raise ValueError("Search A/A must reuse the exact baseline build and metadata")
    for variant, item in builds.items():
        source = sources["v0" if variant == "aa" else variant]
        if (
            not isinstance(source["hash"], str)
            or not re.fullmatch(r"(?:[a-f0-9]{40}|[a-f0-9]{64})", source["hash"])
            or item["source_hash"] != source["hash"]
            or not isinstance(source["path"], str)
            or not Path(source["path"]).is_absolute()
            or item["source_path"] != source["path"]
        ):
            raise ValueError("Saved search source identity disagrees with manifest")
        prefix = (destination / "build" / source["variant"]).resolve()
        command = build_command(
            target=settings["zig_target"], cpu=cpu, revision=source["revision"], prefix=prefix
        )
        if item["command"] != command or read_evidence(prefix / "command.json") != command:
            raise ValueError("Saved search build command disagrees with configured build")
        binary = prefix / "bin/bench-find"
        if item["binary"] != str(binary) or not binary.is_file():
            raise ValueError("Saved search binary path disagrees with retained build")
        codegen = item["codegen"]
        validate_codegen(codegen)
        if read_evidence(prefix / "codegen.json") != codegen:
            raise ValueError("Saved search codegen sidecar contradicts experiment")
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        if digest != codegen["binary_sha256"] or digest != expected[variant]["binary_sha256"]:
            raise ValueError("Saved search binary digest disagrees with build/expected evidence")
        if expected[variant]["dispatch_level"] is not None and not codegen["dispatch_proof"]:
            raise ValueError("Missing search dispatch codegen proof")


def validate_protocol(
    destination: Path,
    manifest: dict[str, Any],
    experiment: dict[str, Any],
    protocol: dict[str, Any],
) -> None:
    """Retained isolation provenance is required, not an optional offline annotation."""
    expected = experiment["expected"]
    name = destination.name
    variants = [s["variant"] for s in manifest["sources"]] + ["aa"]
    schedule = orders(variants, manifest["rounds"], manifest["seed"])
    if (
        manifest["schedule"] != schedule
        or protocol.get("schedule") != schedule
        or experiment["rounds"] != manifest["rounds"]
        or set(expected) != set(variants)
        or set(experiment["builds"]) != set(variants)
        or protocol.get("expected") != expected
        or protocol.get("isolation") != "systemd-cpuset-taskset-v1"
    ):
        raise ValueError("Saved search protocol disagrees with manifest/schedule/builds")
    settings = manifest["config"]["targets"][name]
    level = expected_dispatch(settings, manifest["cpu_mode"])
    revisions = {s["variant"]: s["revision"] for s in manifest["sources"]}
    revisions["aa"] = revisions["v0"]
    for variant, meta in expected.items():
        if meta["rev"] != revisions[variant]:
            raise ValueError("Expected search revision disagrees with manifest source")
        if (
            meta["dispatch_level"] != level
            or meta["cpu"] != build_cpu(settings, manifest["cpu_mode"])
            or meta["target"] != settings["zig_target"]
        ):
            raise ValueError("Expected search dispatch/build disagrees with configured target")
        if any(meta[k] != manifest[k] for k in ("suite", "seed", "samples", "sample_ms", "filter")):
            raise ValueError("Expected search configuration disagrees with manifest")
    facts = read_evidence(destination / "facts.json")
    if (
        protocol.get("instance_id") != manifest["instances"][name]
        or facts.get("instance_id") != protocol["instance_id"]
    ):
        raise ValueError("Saved search instance identity mismatch")
    if type(protocol.get("cpu")) is not int or protocol["cpu"] != select_cpu(facts["topology"])[0]:
        raise ValueError("Invalid saved isolated CPU")
    probe = read_evidence(destination / "memmem-probe.json")
    if protocol.get("probe") != probe:
        raise ValueError("Saved search protocol probe mismatch")
    validate_resolution(probe)
    remote = (
        manifest["config"]["project"]["remote_dir"].rstrip("/")
        + "/"
        + destination.parent.name
        + "-find"
    )
    commands = {
        f"{v}/r{i}": [
            f"{remote}/bin/{'v0' if v == 'aa' else v}/bench-find",
            "--suite",
            manifest["suite"],
            "--seed",
            str(manifest["seed"]),
            "--samples",
            str(manifest["samples"]),
            "--sample-ms",
            str(manifest["sample_ms"]),
            "--filter",
            manifest["filter"],
        ]
        for i, order in enumerate(schedule)
        for v in order
    }
    if (
        protocol.get("remote") != remote
        or protocol.get("commands") != commands
        or read_evidence(destination / "commands.json") != commands
    ):
        raise ValueError("Saved search commands disagree with manifest/round schedule")


@click.command(name="find-analyze")
@click.argument("run_dir", type=click.Path(exists=True, file_okay=False, path_type=Path))
def find_analyze(run_dir: Path) -> None:
    """Strictly reanalyze a saved find experiment without AWS, SSH, or builds."""
    try:
        manifest = read_evidence(run_dir / "manifest.json")
    except (ValueError, OSError) as error:
        failure = {
            "run_id": run_dir.name,
            "dialect": "fastmem-find",
            "schema": 1,
            "status": "failed",
            "targets": {},
            "error": str(error),
        }
        (run_dir / "summary.json").write_text(json.dumps(failure, indent=2) + "\n")
        raise click.ClickException("Invalid search manifest: " + str(error)) from error
    if manifest.get("dialect") != "fastmem-find" or manifest.get("schema") != 1:
        raise click.ClickException("Not a fastmem-find/1 run directory")
    targets = {}
    for name in manifest["targets"]:
        try:
            targets[name] = analyze_target(run_dir / name)
        except (ValueError, OSError, KeyError, TypeError) as error:
            targets[name] = {"status": "failed", "error": str(error)}
    failed = any(r["status"] == "failed" for r in targets.values())
    summary = {
        "run_id": run_dir.name,
        "dialect": "fastmem-find",
        "schema": 1,
        "status": "failed" if failed else "complete",
        "targets": targets,
    }
    (run_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    click.echo(str(run_dir))
    if failed:
        raise click.ClickException(
            "Search reanalysis failed; no successful verdict in summary.json"
        )
