"""Build, execute, and analyze one reproducible experiment."""

import hashlib
import json
import secrets
from pathlib import Path
from typing import Any

import click

from ec2bench.cli import box_for, ensure_up
from ec2bench.config import Config
from ec2bench.fleet import Fleet, tags
from ec2bench.parallel import Outcome, parallel, progress
from ec2bench.runs import create_run, validate_label, write_manifest
from fastmem_bench.analysis import BOOTSTRAP_SEED, analyze, validate_effect
from fastmem_bench.build import (
    CPU_MODES,
    build_all,
    build_cpu,
    disassemble,
    expected_dispatch,
    provenance,
    resolve,
)
from fastmem_bench.codegen import verify_recorded
from fastmem_bench.protocol import execute, orders
from fastmem_bench.report import stability_line, write


@click.command()
@click.option("--rev", "revisions", multiple=True, default=("WORKTREE",))
@click.option("--target", "targets", multiple=True)
@click.option(
    "--suite",
    type=click.Choice(["quick", "standard", "large", "const", "dist"]),
    default="standard",
)
@click.option("--rounds", type=click.IntRange(min=1), default=5, show_default=True)
@click.option(
    "--cpu",
    "cpu_mode",
    type=click.Choice(CPU_MODES),
    default="target",
    show_default=True,
    help="target: bench.toml zig_cpu (G2-G4). baseline: baseline_cpu (G6).",
)
@click.option(
    "--no-aa", is_flag=True, help="Disable the baseline duplicate and significance marks."
)
@click.option("--up", "launch", is_flag=True, help="Launch missing targets first.")
@click.option("--label", default="run", show_default=True)
@click.option("--filter", "case_filter", default=None, help="Case substring passed to the binary.")
@click.option("--impl", default=None, help="Comma-separated implementations passed to the binary.")
@click.option("--dist-file", type=click.Path(exists=True, dir_okay=False, path_type=Path))
@click.option(
    "--x86-experiment",
    default="auto",
    show_default=True,
    help="-Dx86-experiment for every source in the run (x86_64 only).",
)
@click.option("--samples", type=click.IntRange(min=1), default=None)
@click.option("--sample-ms", type=click.IntRange(min=1), default=None)
@click.option(
    "--minimum-effect",
    type=click.FloatRange(min=0),
    default=None,
    help="Minimum fractional effect for marks. Default: project.minimum_effect or 0.",
)
@click.pass_obj
def run(  # noqa: C901, PLR0912, PLR0915 — orchestration keeps the experiment lifecycle visible
    config: Config,
    *,
    revisions: tuple[str, ...],
    targets: tuple[str, ...],
    suite: str,
    rounds: int,
    cpu_mode: str,
    no_aa: bool,
    launch: bool,
    label: str,
    case_filter: str | None,
    impl: str | None,
    samples: int | None,
    sample_ms: int | None,
    minimum_effect: float | None,
    dist_file: Path | None = None,
    x86_experiment: str = "auto",
) -> None:
    """Cross-build revisions and measure interleaved rounds across the fleet."""
    config.check_storage()
    effect = (
        minimum_effect if minimum_effect is not None else config.project.get("minimum_effect", 0.0)
    )
    validate_effect(effect)
    try:
        validate_label(label)
    except ValueError as error:
        raise click.ClickException(str(error)) from error
    if dist_file is not None and suite != "dist":
        raise click.ClickException("--dist-file requires --suite dist")
    binary_args = []
    for option, value in (
        ("--filter", case_filter),
        ("--impl", impl),
        ("--samples", samples),
        ("--sample-ms", sample_ms),
        ("--dist-file", dist_file.resolve() if dist_file else None),
    ):
        if value is not None:
            binary_args.extend([option, str(value)])
    fleet = Fleet(config)
    fleet.reap()
    names = config.select(targets)
    startup = {}
    if launch:
        names = names or list(config.targets)
        startup = ensure_up(fleet, names)
        names = [name for name, outcome in startup.items() if outcome.error is None]
    if not names and not launch:
        names = config.select(
            [
                tags(instance)["Target"]
                for instance in fleet.instances()
                if instance["State"]["Name"] == "running" and "Target" in tags(instance)
            ]
        )
    if not names and not startup:
        raise click.ClickException("No running targets. Use --up or select a target.")
    try:
        cpus = {name: build_cpu(config.targets[name], cpu_mode) for name in names}
        levels = {name: expected_dispatch(config.targets[name], cpu_mode) for name in names}
    except ValueError as error:
        raise click.ClickException(str(error)) from error
    instances = {name: fleet.one(name) for name in names}
    path, manifest = create_run(
        config.root,
        label,
        list(startup) if launch else names,
        {name: instance["InstanceId"] for name, instance in instances.items()},
        results_dir=config.results_dir,
    )
    seed = secrets.randbits(32)
    sources = resolve(config, revisions, x86_experiment)
    for source in sources:
        if source.experiment != x86_experiment:
            click.echo(
                f"note: {source.revision} does not declare {x86_experiment};"
                " it builds its own default",
                err=True,
            )
    variants = [source.variant for source in sources]
    schedule = orders([*variants, *([] if no_aa else ["aa"])], rounds, seed)
    manifest.update(
        {
            "seed": seed,
            "bootstrap_seed": BOOTSTRAP_SEED,
            "rounds": rounds,
            "suite": suite,
            "cpu_mode": cpu_mode,
            "cpus": cpus,
            "dispatch_levels": levels,
            "aa": not no_aa,
            "schedule": schedule,
            "schedule_method": "seeded-balanced-latin-square",
            "binary_args": binary_args,
            "minimum_effect": effect,
            "config": {"project": config.project, "targets": config.targets},
        }
    )
    if dist_file is not None:
        data = dist_file.read_bytes()
        snapshot = path / "distribution.json"
        snapshot.write_bytes(data)
        binary_args[binary_args.index("--dist-file") + 1] = str(snapshot.resolve())
        manifest["distribution"] = {
            "path": str(dist_file.resolve()),
            "sha256": hashlib.sha256(data).hexdigest(),
        }
    write_manifest(path, manifest)
    builds = build_all(config, sources, names, cpu_mode=cpu_mode)
    manifest.update(provenance(sources, builds))
    manifest["codegen"] = {
        name: {
            source.variant: build.codegen
            for source in sources
            if (build := builds[f"{source.variant}/{name}"].value) is not None
        }
        for name in names
    }
    if not no_aa:
        for evidence in manifest["codegen"].values():
            if variants[0] in evidence:
                evidence["aa"] = evidence[variants[0]]
    write_manifest(path, manifest)
    outputs = fleet.outputs()

    def measure(name: str) -> dict[str, Any]:
        selected = []
        warnings = []
        for source in sources:
            outcome = builds[f"{source.variant}/{name}"]
            if outcome.error:
                raise RuntimeError(
                    f"Build failed: {source.revision}: {outcome.error}"
                ) from outcome.error
            if outcome.value is None:
                raise RuntimeError("Build returned no artifact")
            selected.append(outcome.value)
            warning = disassemble(outcome.value, path / name / "asm" / f"{source.variant}.asm")
            if warning:
                warnings.append(warning)
        box = box_for(fleet, instances[name], outputs)
        try:
            box.ready(config.project["image_version"])
        except Exception:
            fleet.terminate([instances[name]["InstanceId"]])
            raise
        protocol = execute(
            config,
            box,
            selected,
            path,
            suite=suite,
            schedule=schedule,
            aa=not no_aa,
            seed=seed,
            binary_args=binary_args,
        )
        progress("bootstrap analysis")
        result = analyze(
            path / name / "raw",
            variants,
            variants[0],
            aa=None if no_aa else "aa",
            minimum_effect=effect,
            expected_round_count=rounds,
            probe=protocol["libc_probe"],
            cpu_mode=cpu_mode,
            expected_cpu=cpus[name],
            expected_dispatch=levels[name],
        )
        if result["codegen"] != protocol["codegen"]:
            raise ValueError("Analysis codegen evidence disagrees with the build")
        # Keep the independent resolution evidence in both the manifest and target artifacts.
        manifest.setdefault("libc_probes", {})[name] = protocol["libc_probe"]
        result["protocol"] = protocol
        result["warnings"] += warnings + protocol.get("warnings", [])
        return result

    results = parallel(names, measure)
    results.update(
        {name: Outcome(error=outcome.error) for name, outcome in startup.items() if outcome.error}
    )
    summary = {
        "run_id": path.name,
        "variants": {source.variant: source.revision for source in sources},
        "bootstrap_seed": BOOTSTRAP_SEED,
        "targets": {
            name: outcome.value if outcome.error is None else {"error": str(outcome.error)}
            for name, outcome in results.items()
        },
    }
    write(path, summary)
    manifest["status"] = {
        name: "failed" if outcome.error else "complete" for name, outcome in results.items()
    }
    write_manifest(path, manifest)
    click.echo(str(path))
    if any(outcome.error for outcome in results.values()):
        raise click.ClickException(
            "One or more targets failed. Successful target results remain available."
        )


@click.command(name="analyze")
@click.argument("run_dir", type=click.Path(exists=True, file_okay=False, path_type=Path))
@click.option(
    "--minimum-effect",
    type=click.FloatRange(min=0),
    default=None,
    help="Override the recorded minimum fractional effect.",
)
def analyze_run(run_dir: Path, minimum_effect: float | None) -> None:
    """Analyze saved raw rounds without AWS, SSH, or builds."""
    manifest = json.loads((run_dir / "manifest.json").read_text())
    variants = {source["variant"]: source["revision"] for source in manifest["sources"]}
    effect = minimum_effect if minimum_effect is not None else manifest.get("minimum_effect", 0.0)
    previous_path = run_dir / "summary.json"
    previous = json.loads(previous_path.read_text()) if previous_path.exists() else {}
    targets: dict[str, dict[str, Any]] = {}
    for target in manifest["targets"]:
        try:
            result = analyze(
                run_dir / target / "raw",
                list(variants),
                next(iter(variants)),
                aa="aa" if manifest["aa"] else None,
                minimum_effect=effect,
                expected_round_count=manifest["rounds"],
                probe=json.loads((run_dir / target / "libc-probe.json").read_text()),
                # Runs before G6 builds have neither field: they are target-CPU builds.
                cpu_mode=manifest.get("cpu_mode", "target"),
                expected_cpu=manifest.get("cpus", {}).get(target),
                expected_dispatch=manifest.get("dispatch_levels", {}).get(target),
            )
            expected = manifest.get("codegen", {}).get(target)
            if expected is not None:
                verify_recorded(result["codegen"], expected)
            old = previous.get("targets", {}).get(target, {})
            if "protocol" in old:
                result["protocol"] = old["protocol"]
            targets[target] = result
        except (ValueError, OSError) as error:
            targets[target] = {"error": str(error)}
    write(
        run_dir,
        {
            "run_id": manifest["run_id"],
            "variants": variants,
            "bootstrap_seed": BOOTSTRAP_SEED,
            "targets": targets,
        },
    )
    for target, result in targets.items():
        echo_result(target, result)
    if any("error" in result for result in targets.values()):
        raise click.ClickException("One or more targets failed analysis. Read summary.json.")


def echo_result(target: str, result: dict[str, Any]) -> None:
    for variant, state in sorted((result.get("dispatch") or {}).items()):
        if record := state["record"]:
            click.echo(f"{target} {variant} dispatch: {record['level']} ({record['kernel']})")
    for group, floor in sorted(result.get("noise_floors", {}).items()):
        click.echo(f"{target} {group}: {floor:.4%}")
    stability = result.get("stability", {})
    for group in stability.get("groups", []):
        for metric in stability["metrics"]:
            click.echo(f"{target} stability: {stability_line(group, metric)}")
    for warning in result.get("warnings", []):
        click.echo(f"{target}: {warning}")
