"""Saved search rounds analyzed with the existing exact estimators, without goals v3."""

import math
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Any

from fastmem_bench.analysis import (
    FLOOR_QUANTILE,
    MIN_ROUNDS,
    compare_independent,
    compare_paired,
    geomean,
    outlier_rounds,
    quantile,
    round_medians,
    significant,
    validate_effect,
)
from fastmem_bench.find_jsonl import parse

EXPECTED_FIELDS = {
    "rev",
    "cpu",
    "dispatch_level",
    "target",
    "zig",
    "binary_sha256",
    "suite",
    "seed",
    "samples",
    "sample_ms",
    "warmup_ms",
    "filter",
}


def analyze(  # noqa: C901, PLR0912, PLR0915 — exact paired/independent cells share one validated inventory
    raw: Path,
    expected: dict[str, dict[str, Any]],
    *,
    rounds: int,
    probe: dict[str, Any],
    baseline: str = "v0",
    aa: str = "aa",
    minimum_effect: float = 0.0,
) -> dict[str, Any]:
    """Require the complete manifest inventory; reject mixed seeds/configs/builds/results."""
    validate_effect(minimum_effect)
    if rounds < 1 or baseline not in expected or aa not in expected:
        raise ValueError("Search analysis requires positive rounds, baseline, and A/A")
    if any(set(meta) != EXPECTED_FIELDS for meta in expected.values()):
        raise ValueError("Incomplete expected search build/configuration metadata")
    if expected[aa] != expected[baseline]:
        raise ValueError("A/A must duplicate the exact baseline build and configuration")
    series: dict[tuple[str, str, str], dict[int, list[float]]] = defaultdict(
        lambda: defaultdict(list)
    )
    details: dict[str, dict[str, Any]] | None = None
    config: dict[str, Any] | None = None
    for variant, meta_expected in expected.items():
        paths = sorted((raw / variant).glob("r*.jsonl"))
        if {p.name for p in paths} != {f"r{i}.jsonl" for i in range(rounds)}:
            raise ValueError(f"Incomplete or duplicate round set for {variant}")
        for path in paths:
            measurement = parse(path, expected=meta_expected, probe=probe)
            current = {
                key: measurement.meta[key]
                for key in (
                    "zig",
                    "target",
                    "cpu",
                    "dispatch",
                    "suite",
                    "seed",
                    "samples",
                    "sample_ms",
                    "warmup_ms",
                    "filter",
                )
            }
            if config is not None and config != current:
                raise ValueError("Search configuration changed between rounds or variants")
            config = current
            if details is not None and details != measurement.cases:
                raise ValueError("Case inventory/oracle changed between rounds or variants")
            details = measurement.cases
            for sample in measurement.samples:
                series[variant, sample["case"], sample["impl"]][int(path.stem[1:])].append(
                    sample["ns"] / sample["iters"]
                )
    if not details:
        raise ValueError("No search cases")
    cells = {
        key: round_medians([values[i] for i in range(rounds)]) for key, values in series.items()
    }
    flags = {key: outlier_rounds(values) for key, values in cells.items()}
    rows = []

    def compare(  # noqa: PLR0917 — explicit paired variant/implementation identifiers
        case: str, variant: str, impl: str, reference: str, ref_impl: str, comparison: str
    ) -> None:
        left_key, right_key = (variant, case, impl), (reference, case, ref_impl)
        left, right = cells[left_key], cells[right_key]
        method = compare_paired if variant == reference else compare_independent
        rows.append(
            {
                "case": case,
                "variant": variant,
                "reference": reference,
                "candidate_impl": impl,
                "reference_impl": ref_impl,
                "comparison": comparison,
                "candidate_ns": statistics.median(left),
                "reference_ns": statistics.median(right),
                **method(left, right),
                "rounds": rounds,
                "evidence": "sufficient" if rounds >= MIN_ROUNDS else "insufficient",
                "outlier_rounds": {"candidate": flags[left_key], "reference": flags[right_key]},
            }
        )

    for case, detail in details.items():
        for impl in detail["impls"]:
            compare(case, aa, impl, baseline, impl, "A/A")
        pairs = (
            (("fastmem_fixed", "std_fixed"),)
            if detail["fixed"]
            else (
                ("fastmem_direct", "std_direct"),
                ("fastmem_indirect", "std_indirect"),
                ("fastmem_indirect", "glibc_indirect"),
                ("std_indirect", "glibc_indirect"),
                ("std_indirect", "std_direct"),
                ("fastmem_indirect", "fastmem_direct"),
            )
        )
        for variant in expected:
            if variant == aa:
                continue
            for candidate, reference in pairs:
                compare(case, variant, candidate, variant, reference, f"{candidate}/{reference}")
            if variant != baseline:
                for impl in detail["impls"]:
                    compare(case, variant, impl, baseline, impl, "revision")
    # Search-specific analogue of the per-operation/size floor: exact (haystack,
    # needle) lengths and runtime/fixed path, pooled across patterns, positions,
    # alignments and all implementations. Length pairs matter for search cost;
    # per-case pools would leave only two or five A/A estimates.
    floor_groups = {
        case: f"{d['hlen']}/{d['nlen']}/{'fixed' if d['fixed'] else 'runtime'}"
        for case, d in details.items()
    }
    null: dict[str, list[float]] = defaultdict(list)
    for row in rows:
        if row["comparison"] == "A/A":
            null[floor_groups[row["case"]]].append(abs(math.log(row["ratio"])))
    floors = {case: math.expm1(quantile(values, FLOOR_QUANTILE)) for case, values in null.items()}
    groups: dict[tuple[str, str, str], list[float]] = defaultdict(list)
    for row in rows:
        row["floor_group"] = floor_groups[row["case"]]
        row["noise_floor"] = floors[row["floor_group"]]
        row["minimum_effect"] = minimum_effect
        row["significant"] = (
            row["comparison"] != "A/A"
            and rounds >= MIN_ROUNDS
            and significant(tuple(row["ci95"]), max(row["noise_floor"], minimum_effect))
        )
        # Keep adversarial profile means separate; an overall mean cannot hide them.
        groups[row["variant"], row["comparison"], details[row["case"]]["pattern"]].append(
            row["ratio"]
        )
    primary = [r for r in rows if r["comparison"] == "fastmem_direct/std_direct"]
    return {
        "status": "complete",
        "dialect": "fastmem-find",
        "schema": 1,
        "metric": "ns_per_one_shot_search",
        "config": config,
        "cases": details,
        "rows": rows,
        "noise_floors": floors,
        "floor_quantile": FLOOR_QUANTILE,
        "minimum_effect": minimum_effect,
        "outliers": [
            {"variant": key[0], "case": key[1], "impl": key[2], "round": i}
            for key, indices in flags.items()
            for i in indices
        ],
        "groups": [
            {
                "variant": key[0],
                "comparison": key[1],
                "pattern": key[2],
                "geomean": geomean(values),
                "cases": len(values),
            }
            for key, values in sorted(groups.items())
        ],
        "primary_geomeans": {
            variant: geomean([r["ratio"] for r in primary if r["variant"] == variant])
            for variant in expected
            if variant != aa and primary
        },
        "regressions_above_10_percent": [
            r
            for r in rows
            if r["comparison"] != "A/A" and rounds >= MIN_ROUNDS and r["ci95"][0] > 1.10
        ],
        "warnings": (
            []
            if rounds >= MIN_ROUNDS
            else ["Fewer than five independent rounds; no performance verdict."]
        ),
    }
