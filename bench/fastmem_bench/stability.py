"""Measurement stability: spike rates, null floors, and THP coverage.

These numbers describe the measurement, not an implementation. They let one run
compare two binaries of the same source (for example the arena layout against the
per-case mappings) on the same box, in interleaved rounds.

A spike is a round median more than SPIKE above the median of all rounds of its
(case, implementation) cell, pooled across the variants that run one binary. This
is the definition of docs/slop/bench-design.md, section "Estimator evidence".
"""

import math
import statistics
from collections import defaultdict
from typing import Any

SPIKE = 0.10
Cells = dict[tuple[str, str, str], tuple[list[float], list[int]]]


def binary_groups(
    variants: list[str], codegen: dict[str, Any], baseline: str, aa: str | None
) -> list[list[str]]:
    """Group variants by executable digest. Without evidence, A/A joins its baseline."""
    groups: dict[str, list[str]] = {}
    for variant in variants:
        evidence = codegen.get(variant)
        if evidence is not None:
            key = evidence["binary_sha256"]
        else:
            key = "variant:" + (baseline if variant == aa else variant)
        groups.setdefault(key, []).append(variant)
    return list(groups.values())


def spike_group(cells: Cells, members: list[str]) -> dict[str, Any]:
    keys = {(case, impl) for variant, case, impl in cells if variant == members[0]}
    keys = {key for key in keys if all((member, *key) in cells for member in members)}
    by_process: dict[str, int] = defaultdict(int)
    by_variant = dict.fromkeys(members, 0)
    total = 0
    for case, impl in keys:
        pooled = [value for member in members for value in cells[member, case, impl][0]]
        limit = (1 + SPIKE) * statistics.median(pooled)
        for member in members:
            for index, value in enumerate(cells[member, case, impl][0]):
                total += 1
                if value > limit:
                    by_variant[member] += 1
                    by_process[f"{member}/r{index}"] += 1
    spikes = sum(by_variant.values())
    worst = max(by_process.items(), key=lambda item: item[1], default=(None, 0))
    return {
        "round_cells": total,
        "spikes": spikes,
        "spike_rate": spikes / total if total else None,
        "by_variant": by_variant,
        "by_process": dict(sorted(by_process.items())),
        # Spikes that cluster by process show one large share here.
        "worst_process": worst[0],
        "worst_process_share": worst[1] / spikes if spikes else None,
    }


def null_floors(
    cells: Cells, details: dict[str, dict[str, Any]], members: list[str]
) -> dict[str, Any] | None:
    """Floors from the first two variants of one binary, as the A/A floor computes them."""
    from fastmem_bench.analysis import (
        FLOOR_QUANTILE,
        compare_independent,
        floor_group,
        quantile,
    )

    if len(members) < 2:
        return None
    left, right = members[1], members[0]
    departures: dict[str, list[float]] = defaultdict(list)
    for (variant, case, impl), (values, _flagged) in cells.items():
        other = cells.get((right, case, impl))
        if variant != left or other is None:
            continue
        ratio = compare_independent(values, other[0])["ratio"]
        departures[floor_group(details[case])].append(abs(math.log(ratio)))
    floors = sorted(math.expm1(quantile(values, FLOOR_QUANTILE)) for values in departures.values())
    if not floors:
        return None
    return {
        "candidate": left,
        "reference": right,
        "groups": len(floors),
        "median": statistics.median(floors),
        "p90": quantile(floors, 0.9),
        "max": floors[-1],
    }


def stability(
    metrics: dict[str, Cells],
    details: dict[str, dict[str, Any]],
    variants: list[str],
    codegen: dict[str, Any],
    *,
    baseline: str,
    aa: str | None,
) -> dict[str, Any]:
    """Spikes and null floors per binary group, for ns and cycles per operation.

    The time includes descheduled periods. The cycles count only the benchmark thread
    on its core, so spikes in both metrics are in-core effects, such as placement.
    """
    groups = []
    for members in binary_groups(variants, codegen, baseline, aa):
        evidence = codegen.get(members[0])
        group: dict[str, Any] = {
            "variants": members,
            "binary_sha256": evidence["binary_sha256"] if evidence else None,
        }
        for metric, cells in metrics.items():
            group[metric] = {
                **spike_group(cells, members),
                "null_floor": null_floors(cells, details, members),
            }
        groups.append(group)
    return {"spike_threshold": SPIKE, "metrics": list(metrics), "groups": groups}


def memory_summary(memory: dict[str, dict[str, Any] | None]) -> dict[str, Any]:
    """THP coverage of the arena for each process that has one (schema v3)."""
    arenas = {process: value for process, value in memory.items() if value is not None}
    coverage = {
        process: value["anon_huge_bytes_start"] / value["arena_bytes"]
        for process, value in arenas.items()
        if value["anon_huge_bytes_start"] is not None
    }
    full = [
        process
        for process, value in arenas.items()
        if value["anon_huge_bytes_start"] == value["arena_bytes"]
        and value["anon_huge_bytes_end"] == value["arena_bytes"]
    ]
    changed = [
        process
        for process, value in arenas.items()
        if value["anon_huge_bytes_start"] != value["anon_huge_bytes_end"]
    ]
    return {
        "processes": len(memory),
        "arena_processes": len(arenas),
        "thp_full_processes": len(full),
        "thp_changed_processes": sorted(changed),
        "thp_coverage_min": min(coverage.values(), default=None),
        "thp_coverage": dict(sorted(coverage.items())),
        "thp_policies": sorted(
            {f"{value['thp_enabled']}/{value['thp_defrag']}" for value in arenas.values()}
        ),
        "region_bytes": sorted({value["region_bytes"] for value in arenas.values()}),
    }


def memory_warning(summary: dict[str, Any]) -> str | None:
    arenas = summary["arena_processes"]
    if not arenas or summary["thp_full_processes"] == arenas:
        return None
    minimum = summary["thp_coverage_min"]
    low = "unknown" if minimum is None else f"{minimum:.0%}"
    return (
        f"THP backed the whole arena in {summary['thp_full_processes']} of {arenas}"
        f" processes (minimum start coverage {low}). Placement within a 2 MiB region"
        " is not fixed in the other processes."
    )
