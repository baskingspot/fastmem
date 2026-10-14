"""Search transport/isolation lifecycle; no glibc disassembly or cloud mutations."""

import json
import shlex
from pathlib import Path
from typing import Any

from ec2bench.box import Box
from ec2bench.config import Config
from ec2bench.facts import collect
from ec2bench.isolation import isolate, run_isolated, stop_isolated
from ec2bench.parallel import progress
from fastmem_bench.find_build import Build
from fastmem_bench.find_jsonl import parse, unique_object, validate_resolution


def execute(
    config: Config,
    box: Box,
    builds: dict[str, Build],
    destination: Path,
    *,
    schedule: list[list[str]],
    suite: str,
    seed: int,
    samples: int,
    sample_ms: int,
    case_filter: str,
) -> dict[str, Any]:
    destination.mkdir(parents=True, exist_ok=True)
    remote = config.project["remote_dir"].rstrip("/") + "/" + destination.parent.name + "-find"
    for variant, build in builds.items():
        box.upload(build.binary, f"{remote}/bin/{variant}")
    baseline = builds["v0"]
    # Separate process, same dlopen + independent link-map/dladdr proof; ASLR addresses differ.
    probe = json.loads(
        box.run(shlex.join([f"{remote}/bin/v0/bench-find", "--probe"])),
        object_pairs_hook=unique_object,
    )
    validate_resolution(probe)
    (destination / "memmem-probe.json").write_text(json.dumps(probe, indent=2) + "\n")
    facts = collect(box, config.results_dir)
    (destination / "facts.json").write_text(json.dumps(facts, indent=2) + "\n")
    variants = {**builds, "aa": baseline}
    expected = {
        variant: build.expected(
            suite=suite, seed=seed, samples=samples, sample_ms=sample_ms, case_filter=case_filter
        )
        for variant, build in variants.items()
    }
    commands: dict[str, list[str]] = {}
    box.run("mkdir -p " + " ".join(shlex.quote(f"{remote}/raw/{v}") for v in variants))
    protocol: dict[str, Any] = {
        "cpu": None,
        "isolation": "systemd-cpuset-taskset-v1",
        "remote": remote,
        "instance_id": box.instance_id,
        "schedule": schedule,
        "commands": commands,
        "probe": probe,
        "expected": expected,
    }
    try:
        if not facts.get("topology"):
            raise ValueError("CPU topology unavailable; refusing an unisolated measurement")
        with isolate(box, facts["topology"]) as cpu:
            protocol["cpu"] = cpu
            try:
                for index, order in enumerate(schedule):
                    for variant in order:
                        progress(f"search round {index + 1}/{len(schedule)}: {variant}")
                        actual = variants[variant].source.variant
                        command = [
                            f"{remote}/bin/{actual}/bench-find",
                            "--suite",
                            suite,
                            "--seed",
                            str(seed),
                            "--samples",
                            str(samples),
                            "--sample-ms",
                            str(sample_ms),
                            "--filter",
                            case_filter,
                        ]
                        commands[f"{variant}/r{index}"] = command
                        # Persist BEFORE launching so a failed run retains the exact command.
                        (destination / "commands.json").write_text(
                            json.dumps(commands, indent=2) + "\n"
                        )
                        (destination / "protocol.json").write_text(
                            json.dumps(protocol, indent=2) + "\n"
                        )
                        run_isolated(
                            box,
                            cpu,
                            command,
                            unit=f"{destination.parent.name}-find-{variant}-r{index}",
                            output=f"{remote}/raw/{variant}/r{index}.jsonl",
                            error=f"{remote}/raw/{variant}/r{index}.stderr",
                        )
                        box.download(f"{remote}/raw/{variant}", destination / "raw" / variant)
                        parse(
                            destination / "raw" / variant / f"r{index}.jsonl",
                            expected=expected[variant],
                            probe=probe,
                        )
            finally:
                stop_isolated(box, destination.parent.name + "-find")
    finally:
        box.download(remote + "/raw", destination / "raw")
    return protocol
