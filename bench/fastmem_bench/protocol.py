"""Per-target interleaved rounds and remote disassembly."""

import json
import logging
import random
import shlex
import subprocess
from pathlib import Path
from typing import Any

from ec2bench.box import Box
from ec2bench.config import Config
from ec2bench.facts import collect
from ec2bench.isolation import isolate, run_isolated, stop_isolated
from ec2bench.parallel import progress

from fastmem_bench.build import Build
from fastmem_bench.jsonl import parse


def orders(variants: list[str], rounds: int, seed: int) -> list[list[str]]:
    rng = random.Random(seed)  # noqa: S311 — recorded experimental randomization
    labels = variants.copy()
    rng.shuffle(labels)
    count = len(labels)
    if not count:
        raise ValueError("The schedule requires at least one variant")
    # Williams balanced Latin square: every position and predecessor balance per block.
    first = [0]
    first.extend((index + 1) // 2 if index % 2 else count - index // 2 for index in range(1, count))
    rows = [[labels[(value + offset) % count] for value in first] for offset in range(count)]
    if count % 2 and count > 1:
        rows += [list(reversed(row)) for row in rows]
    result = []
    while len(result) < rounds:
        # Shuffle Latin-square blocks separately to balance positions within count rounds.
        blocks = [rows[index : index + count] for index in range(0, len(rows), count)]
        rng.shuffle(blocks)
        for block in blocks:
            rng.shuffle(block)
            result.extend(block)
    return result[:rounds]


def glibc_disassembly(box: Box, probe: dict[str, Any], remote: str) -> None:
    library = shlex.quote(probe["libc_path"])
    for symbol in ("memcpy", "memmove", "memset"):
        offset = probe["symbols"][symbol]["offset"]
        start = int(offset, 0) if isinstance(offset, str) else int(offset)
        # dladdr cannot supply IFUNC implementation sizes. Keep a bounded window.
        command = (
            f"objdump -d --start-address={start} --stop-address={start + 4096} "
            f"{library} > {shlex.quote(remote + '/glibc-' + symbol + '.asm')}"
        )
        box.run(command)


def execute(  # noqa: PLR0915 — keep the target lifecycle and cleanup together
    config: Config,
    box: Box,
    builds: list[Build],
    path: Path,
    *,
    suite: str,
    schedule: list[list[str]],
    aa: bool,
    seed: int,
    binary_args: list[str] | None = None,
) -> dict[str, Any]:
    target = builds[0].target
    destination = path / target
    destination.mkdir(parents=True, exist_ok=True)
    remote = config.project["remote_dir"].rstrip("/") + "/" + path.name
    progress("upload binaries")
    box.run(f"mkdir -p {shlex.quote(remote)}")
    by_variant = {build.source.variant: build for build in builds}
    for variant, build in by_variant.items():
        if build.codegen is None:
            raise ValueError(f"Missing codegen evidence for {variant}/{target}")
        box.upload(build.prefix / "bin/bench-fastmem", f"{remote}/bin/{variant}")
        box.upload(build.prefix / "bin/codegen.json", f"{remote}/bin/{variant}")
    box.upload(builds[0].prefix / "bin/libc-probe", remote)
    binary_args = list(binary_args or [])
    if "--dist-file" in binary_args:
        index = binary_args.index("--dist-file") + 1
        histogram = Path(binary_args[index])
        box.upload(histogram, remote + "/distribution")
        binary_args[index] = remote + "/distribution/" + histogram.name
    progress("host facts and glibc")
    facts = collect(box, config.results_dir)
    (destination / "facts.json").write_text(json.dumps(facts, indent=2) + "\n")
    probe = json.loads(box.run(shlex.quote(remote + "/libc-probe")))
    (destination / "libc-probe.json").write_text(json.dumps(probe, indent=2) + "\n")
    warnings = []
    try:
        glibc_disassembly(box, probe, remote)
    except (OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
        warning = f"glibc disassembly failed: {error}"
        logging.getLogger(__name__).warning("%s", warning)
        warnings.append(warning)
    if aa:
        by_variant["aa"] = builds[0]
    variants = list(by_variant)
    box.run("mkdir -p " + " ".join(shlex.quote(f"{remote}/raw/{variant}") for variant in variants))
    cpu = None
    try:
        if not facts.get("topology"):
            error = facts.get("errors", {}).get("topology", "empty probe")
            raise ValueError(f"CPU topology unavailable: {error}")
        with isolate(box, facts["topology"]) as cpu:
            try:
                for round_index, order in enumerate(schedule):
                    for variant in order:
                        progress(f"round {round_index + 1}/{len(schedule)}: {variant}")
                        binary_variant = by_variant[variant].source.variant
                        binary = f"{remote}/bin/{binary_variant}/bench-fastmem"
                        output = f"{remote}/raw/{variant}/r{round_index}.jsonl"
                        error = f"{remote}/raw/{variant}/r{round_index}.stderr"
                        run_isolated(
                            box,
                            cpu,
                            [
                                binary,
                                "--suite",
                                suite,
                                "--seed",
                                str(seed),
                                "--codegen-file",
                                f"{remote}/bin/{binary_variant}/codegen.json",
                                *(binary_args or []),
                            ],
                            unit=f"{path.name}-{variant}-r{round_index}",
                            output=output,
                            error=error,
                        )
                        box.download(f"{remote}/raw/{variant}", destination / "raw" / variant)
                        measurement = parse(
                            destination / "raw" / variant / f"r{round_index}.jsonl",
                            probe=probe,
                        )
                        if measurement.meta["codegen"] != by_variant[variant].codegen:
                            raise ValueError(
                                f"Raw codegen evidence disagrees with build for {variant}"
                            )
            finally:
                stop_isolated(box, path.name)
    finally:
        box.download(remote, destination)
    return {
        "cpu": cpu,
        "schedule": schedule,
        "instance_id": box.instance_id,
        "warnings": warnings,
        "libc_probe": probe,
        "codegen": {variant: build.codegen for variant, build in by_variant.items()},
    }
