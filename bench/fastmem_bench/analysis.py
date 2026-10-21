"""Robust round-level ratios, exact rank intervals, and A/A noise floors.

One round is one process run, and the round is the unit of independence.
Each (variant, case, implementation, round) cell reduces to the median of its
samples. A ratio compares the round medians of two cells on the log scale.
Cells of two variants come from separate processes: a two-sample comparison.
Cells of one variant come from the same processes: a paired comparison.
Outlier rounds are reported only. They never leave an estimate or interval.
The design and its evidence are in docs/slop/bench-design.md, section "Analysis".
"""

import logging
import math
import statistics
from collections import defaultdict
from dataclasses import dataclass
from functools import cache
from pathlib import Path
from typing import Any

from fastmem_bench.build import dispatches
from fastmem_bench.goals import evaluate
from fastmem_bench.jsonl import IMPLEMENTATIONS, Measurement, parse
from fastmem_bench.stability import Cells, memory_summary, memory_warning, stability

# The estimator has no random component. The runner still records this value.
BOOTSTRAP_SEED = 20260923
CONFIDENCE = 0.95
FLOOR_QUANTILE = 0.95
OUTLIER_Z = 5.0
OUTLIER_MIN = math.log1p(0.05)
OUTLIER_SCALE_MIN = 0.005
OUTLIER_MIN_ROUNDS = 5
# Fewer rounds give insufficient evidence: no mark and no goal verdict.
MIN_ROUNDS = 5
MAD_TO_SD = 1.4826
TIERS = (
    (16, "0-16"),
    (64, "17-64"),
    (256, "65-256"),
    (1024, "257-1024"),
    (16384, "1025-16384"),
    (math.inf, ">16384"),
)


def tier(size: float) -> str:
    return next(name for maximum, name in TIERS if size <= maximum)


def round_medians(rounds: list[list[float]]) -> list[float]:
    if not rounds or any(not samples for samples in rounds):
        raise ValueError("Every round requires samples")
    values = [statistics.median(samples) for samples in rounds]
    if any(value <= 0 for value in values):
        raise ValueError("Round medians must be positive")
    return values


def outlier_rounds(values: list[float]) -> list[int]:
    """Return the one round that departs from the other rounds of its cell, if any.

    The flag is for reports only. No estimate or interval removes the round.

    A round departs when its log distance from the median of the other rounds
    exceeds both OUTLIER_Z robust standard deviations of those rounds and
    OUTLIER_MIN. Two or more departing rounds indicate a multimodal cell, not
    a spike, so no round is flagged.
    """
    if len(values) < OUTLIER_MIN_ROUNDS:
        return []
    logs = [math.log(value) for value in values]
    flagged = []
    for index, value in enumerate(logs):
        others = logs[:index] + logs[index + 1 :]
        center = statistics.median(others)
        spread = MAD_TO_SD * statistics.median(abs(other - center) for other in others)
        if abs(value - center) > max(OUTLIER_Z * max(spread, OUTLIER_SCALE_MIN), OUTLIER_MIN):
            flagged.append(index)
    return flagged if len(flagged) == 1 else []


@cache
def rank_counts(n: int, m: int) -> tuple[int, ...]:
    """Count the orderings of n + m values by the Mann-Whitney statistic U."""
    if n == 0 or m == 0:
        return (1,)
    counts = [0] * (n * m + 1)
    # The largest value is either in the first sample (it exceeds all m) or in the second.
    for u, count in enumerate(rank_counts(n - 1, m)):
        counts[u + m] += count
    for u, count in enumerate(rank_counts(n, m - 1)):
        counts[u] += count
    return tuple(counts)


@cache
def signed_rank_counts(n: int) -> tuple[int, ...]:
    """Count the sign assignments of n paired differences by the signed-rank statistic T."""
    counts = [1]
    for rank in range(1, n + 1):
        extended = [0] * (len(counts) + rank)
        for total, count in enumerate(counts):
            extended[total] += count
            extended[total + rank] += count
        counts = extended
    return tuple(counts)


def order_statistic_rank(counts: tuple[int, ...], size: int, level: float) -> tuple[int, float]:
    """Return k and the coverage of [x_(k), x_(size+1-k)] for a null count distribution.

    The coverage of k is 1 - 2 P(statistic <= k - 1). k is the largest value that
    reaches the level. If no value reaches it, k is 1: the full range.
    """
    total = sum(counts)
    k, below = 1, counts[0]
    while 2 * (k + 1) <= size + 1 and 1 - 2 * (below + counts[k]) / total >= level:
        below += counts[k]
        k += 1
    return k, 1 - 2 * below / total


@cache
def rank_interval(n: int, m: int, level: float = CONFIDENCE) -> tuple[int, float]:
    """Exact Mann-Whitney rank and coverage for n against m independent rounds."""
    if n < 1 or m < 1:
        raise ValueError("Intervals require nonempty samples")
    return order_statistic_rank(rank_counts(n, m), n * m, level)


@cache
def signed_rank_interval(n: int, level: float = CONFIDENCE) -> tuple[int, float]:
    """Exact Wilcoxon signed-rank rank and coverage for n paired rounds."""
    if n < 1:
        raise ValueError("Intervals require nonempty samples")
    return order_statistic_rank(signed_rank_counts(n), n * (n + 1) // 2, level)


def hodges_lehmann(candidate: list[float], baseline: list[float]) -> float:
    return statistics.median(x - y for x in candidate for y in baseline)


def interval_row(
    point: float, ordered: list[float], rank: tuple[int, float], method: str
) -> dict[str, Any]:
    k, coverage = rank
    return {
        "ratio": math.exp(point),
        "ci95": [math.exp(ordered[k - 1]), math.exp(ordered[-k])],
        "ci_level": coverage,
        "ci_method": method,
    }


def compare_independent(candidate: list[float], baseline: list[float]) -> dict[str, Any]:
    """Compare round medians of separate processes (A/A and revisions).

    The ratio is the two-sample Hodges-Lehmann estimate. The interval is the exact
    Mann-Whitney interval over all rounds.
    """
    left = [math.log(value) for value in candidate]
    right = [math.log(value) for value in baseline]
    differences = sorted(x - y for x in left for y in right)
    rank = rank_interval(len(left), len(right))
    return interval_row(statistics.median(differences), differences, rank, "mann-whitney")


def compare_paired(candidate: list[float], baseline: list[float]) -> dict[str, Any]:
    """Compare round medians of two implementations measured in the same processes.

    Round i of the candidate and round i of the baseline share one process. The
    ratio is the one-sample Hodges-Lehmann estimate of the per-round log ratios.
    The interval is the exact Wilcoxon signed-rank interval over their Walsh
    averages. It needs no independence between the two implementations.
    """
    if len(candidate) != len(baseline) or not candidate:
        raise ValueError("A paired comparison requires matched nonempty rounds")
    ratios = [math.log(x / y) for x, y in zip(candidate, baseline, strict=True)]
    walsh = sorted(
        (ratios[i] + ratios[j]) / 2 for i in range(len(ratios)) for j in range(i, len(ratios))
    )
    rank = signed_rank_interval(len(ratios))
    return interval_row(statistics.median(walsh), walsh, rank, "signed-rank")


def quantile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        raise ValueError("Quantiles require values")
    position = (len(ordered) - 1) * fraction
    below = math.floor(position)
    above = min(below + 1, len(ordered) - 1)
    return ordered[below] + (ordered[above] - ordered[below]) * (position - below)


def significant(interval: tuple[float, float], floor: float | None) -> bool:
    """The whole interval lies outside the band [1 / (1 + floor), 1 + floor]."""
    return floor is not None and (interval[0] > 1 + floor or interval[1] < 1 / (1 + floor))


def geomean(values: list[float]) -> float:
    if not values or any(value <= 0 for value in values):
        raise ValueError("Geometric means require positive ratios")
    return math.exp(statistics.fmean(math.log(value) for value in values))


Series = dict[tuple[str, str, str], dict[int, list[float]]]


@dataclass
class Rounds:
    data: Series
    # Cycles per operation of the samples that the PMU counted for the whole batch.
    cycles: Series
    details: dict[str, dict[str, Any]]
    warnings: list[str]
    codegen: dict[str, Any]
    # The meta memory object of each process, keyed "<variant>/r<round>". None for v2.
    memory: dict[str, dict[str, Any] | None]
    cpus: set[str]
    # The runtime-dispatch capability and record of each variant (record_dispatch).
    dispatch: dict[str, dict[str, Any]]


def add_samples(  # noqa: PLR0917 — one round's destinations
    measurement: Measurement,
    variant: str,
    index: int,
    data: Series,
    cycles: Series,
    details: dict[str, dict[str, Any]],
) -> None:
    for sample in measurement.samples:
        case = sample["case"]
        detail = {key: sample[key] for key in ("op", "size", "profile")}
        detail["chunk_bytes"] = measurement.meta["chunk_bytes"]
        if case in details and detail != details[case]:
            raise ValueError(f"Case metadata changed for {case}")
        details[case] = detail
        key = (variant, case, sample["impl"])
        data[key][index].append(sample["ns"] / sample["iters"])
        # Multiplexed samples have scaled-down counts. Keep only fully counted batches.
        if (
            sample["cycles"] is not None
            and sample["cycles"] > 0
            and sample["time_running"] > 0
            and sample["time_running"] == sample["time_enabled"]
        ):
            cycles[key][index].append(sample["cycles"] / sample["iters"])


def record_dispatch(
    path: Path,
    meta: dict[str, Any],
    variant: str,
    dispatch: dict[str, dict[str, Any]],
    expected: str | None,
) -> None:
    """Keep the runtime-dispatch capability and record of each variant.

    The capability comes from the binary (docs/slop/runtime-dispatch.md): a
    dispatching binary exports its resolvers, and the codegen evidence in
    the meta record names them. Such a binary must emit the `dispatch`
    object, with the expected level. Any other binary must not emit it.
    build.check_dispatch_build rejects a revision with runtime dispatch
    whose G6 x86_64 build has no resolvers.
    """
    record = meta.get("dispatch")
    codegen = meta.get("codegen")
    if codegen is None:
        if expected is not None:
            raise ValueError(f"{path}: no codegen evidence for the dispatch capability")
        capable = record is not None
    else:
        capable = dispatches(codegen)
        if capable != (record is not None):
            raise ValueError(
                f"{path}: the dispatch record ({record}) disagrees with the binary "
                f"({'with' if capable else 'without'} dispatch resolvers)"
            )
    if expected is not None and record is not None and record["level"] != expected:
        raise ValueError(f"{path}: the dispatched level is {record['level']}, not {expected}")
    state = {"capable": capable, "record": record}
    if variant in dispatch and dispatch[variant] != state:
        raise ValueError(f"Dispatch level changed within {variant}")
    dispatch[variant] = state


def load_rounds(  # noqa: C901 — validate clusters before case intersection
    raw: Path,
    variants: list[str],
    *,
    expected_round_count: int | None = None,
    probe: dict[str, Any] | None = None,
    expected_cpu: str | None = None,
    expected_dispatch: str | None = None,
) -> Rounds:
    data: Series = defaultdict(lambda: defaultdict(list))
    cycles: Series = defaultdict(lambda: defaultdict(list))
    details: dict[str, dict[str, Any]] = {}
    variant_cases: dict[str, set[tuple[str, str]]] = {}
    codegen: dict[str, Any] = {}
    memory: dict[str, dict[str, Any] | None] = {}
    cpus: set[str] = set()
    dispatch: dict[str, dict[str, Any]] = {}
    expected_rounds: set[int] | None = None
    for variant in variants:
        paths = sorted((raw / variant).glob("r*.jsonl"))
        if not paths:
            raise ValueError(f"No complete rounds for {variant}")
        rounds = {int(path.stem[1:]) for path in paths}
        if expected_rounds is not None and rounds != expected_rounds:
            raise ValueError("Variants have different round sets")
        if rounds != set(range(expected_round_count or len(rounds))):
            raise ValueError(f"Incomplete round set for {variant}: {sorted(rounds)}")
        expected_rounds = rounds
        for path in paths:
            measurement = parse(path, probe=probe)
            cpu = measurement.meta["cpu"]
            if expected_cpu is not None and cpu != expected_cpu:
                raise ValueError(f"{path}: the build CPU is {cpu}, not {expected_cpu}")
            cpus.add(cpu)
            record_dispatch(path, measurement.meta, variant, dispatch, expected_dispatch)
            memory[f"{variant}/{path.stem}"] = measurement.meta["memory"]
            evidence = measurement.meta["codegen"]
            if variant in codegen and codegen[variant] != evidence:
                raise ValueError(f"Codegen evidence changed within {variant}")
            codegen[variant] = evidence
            cases = {(sample["case"], sample["impl"]) for sample in measurement.samples}
            if variant in variant_cases and cases != variant_cases[variant]:
                raise ValueError(f"Rounds have different case/implementation sets within {variant}")
            variant_cases[variant] = cases
            add_samples(measurement, variant, int(path.stem[1:]), data, cycles, details)
    common = set.intersection(*variant_cases.values())
    warnings = []
    for variant, cases in variant_cases.items():
        if excluded := cases - common:
            warning = (
                f"{variant}: excluded {len(excluded)} unmatched case/implementation pairs: "
                + ", ".join(f"{case}:{impl}" for case, impl in sorted(excluded))
            )
            warnings.append(warning)
            logging.getLogger(__name__).warning("%s", warning)
    if not common:
        raise ValueError("Variants have no common case/implementation pairs")
    data = {key: rounds for key, rounds in data.items() if (key[1], key[2]) in common}
    rounds = len(expected_rounds or ())
    # A cycles cell needs a counted sample in every round.
    cycles = {
        key: value
        for key, value in cycles.items()
        if (key[1], key[2]) in common and len(value) == rounds
    }
    common_cases = {case for case, _impl in common}
    details = {case: detail for case, detail in details.items() if case in common_cases}
    return Rounds(data, cycles, details, warnings, codegen, memory, cpus, dispatch)


def floor_group(detail: dict[str, Any]) -> str:
    if detail["profile"] == "dist":
        return f"{detail['op']}/tier/{tier(detail['size'])}"
    return f"{detail['op']}/size/{detail['size']:g}"


def validate_effect(minimum_effect: float) -> None:
    if not math.isfinite(minimum_effect) or minimum_effect < 0:
        raise ValueError("The minimum effect must be a finite nonnegative fraction")


def analyze(  # noqa: C901 — paired comparisons share one cluster table
    raw: Path,
    variants: list[str],
    baseline: str,
    *,
    aa: str | None = "aa",
    minimum_effect: float = 0.0,
    expected_round_count: int | None = None,
    probe: dict[str, Any] | None = None,
    cpu_mode: str = "target",
    expected_cpu: str | None = None,
    expected_dispatch: str | None = None,
) -> dict[str, Any]:
    validate_effect(minimum_effect)
    loaded = load_rounds(
        raw,
        [*variants, *([aa] if aa else [])],
        expected_round_count=expected_round_count,
        probe=probe,
        expected_cpu=expected_cpu,
        expected_dispatch=expected_dispatch,
    )
    data, details, warnings, codegen = loaded.data, loaded.details, loaded.warnings, loaded.codegen
    cells: dict[tuple[str, str, str], tuple[list[float], list[int]]] = {}
    for key in sorted(data):
        rounds = data[key]
        values = round_medians([rounds[index] for index in sorted(rounds)])
        cells[key] = (values, outlier_rounds(values))
    outliers = [
        {
            "variant": variant,
            "case": case,
            "impl": impl,
            "round": index,
            "ratio": values[index] / statistics.median(values[:index] + values[index + 1 :]),
        }
        for (variant, case, impl), (values, flagged) in cells.items()
        for index in flagged
    ]

    rows: list[dict[str, Any]] = []

    def compare(  # noqa: PLR0917 — paired variant/implementation identifiers
        case: str,
        kind: str,
        candidate: str,
        candidate_impl: str,
        reference: str,
        reference_impl: str,
    ) -> None:
        left = cells.get((candidate, case, candidate_impl))
        right = cells.get((reference, case, reference_impl))
        if left is None or right is None:
            return
        # One variant runs all of its implementations in the same processes.
        method = compare_paired if candidate == reference else compare_independent
        estimate = method(left[0], right[0])
        rounds = min(len(left[0]), len(right[0]))
        rows.append(
            {
                "case": case,
                **details[case],
                "tier": tier(details[case]["size"]),
                "comparison": kind,
                "variant": candidate,
                "reference": reference,
                "candidate_impl": candidate_impl,
                "reference_impl": reference_impl,
                "candidate_ns": statistics.median(left[0]),
                "baseline_ns": statistics.median(right[0]),
                **estimate,
                "outlier_rounds": {"candidate": left[1], "baseline": right[1]},
                "rounds": rounds,
                "evidence": "sufficient" if rounds >= MIN_ROUNDS else "insufficient",
                "floor_group": floor_group(details[case]),
            }
        )

    for case in sorted(details):
        if aa:
            for implementation in IMPLEMENTATIONS:
                compare(case, "A/A", aa, implementation, baseline, implementation)
        for variant in variants:
            if variant != baseline:
                for implementation in ("fastmem_abi", "fastmem_inline"):
                    compare(case, "revision", variant, implementation, baseline, implementation)
            for candidate, reference in (
                ("builtin", "glibc"),
                ("fastmem_abi", "glibc"),
                ("fastmem_inline", "glibc"),
                ("fastmem_abi", "builtin"),
                ("fastmem_inline", "builtin_const"),
            ):
                compare(case, f"{candidate}/{reference}", variant, candidate, variant, reference)
    memory = memory_summary(loaded.memory)
    if warning := memory_warning(memory):
        warnings.append(warning)
    result = summarize(rows, warnings, minimum_effect)
    result["outliers"] = outliers
    result["codegen"] = codegen
    result["cpu"] = {"mode": cpu_mode, "models": sorted(loaded.cpus)}
    result["dispatch"] = loaded.dispatch
    result["memory"] = memory
    cycle_cells: Cells = {
        key: (round_medians([rounds[index] for index in sorted(rounds)]), [])
        for key, rounds in sorted(loaded.cycles.items())
    }
    result["stability"] = stability(
        {"ns": cells, "cycles": cycle_cells},
        details,
        [*variants, *([aa] if aa else [])],
        codegen,
        baseline=baseline,
        aa=aa,
    )
    result["goals"] = evaluate(rows, variants, codegen=codegen, cpu_mode=cpu_mode)
    return result


def summarize(
    rows: list[dict[str, Any]], warnings: list[str], minimum_effect: float
) -> dict[str, Any]:
    departures: dict[str, list[float]] = defaultdict(list)
    for row in rows:
        if row["comparison"] == "A/A":
            departures[row["floor_group"]].append(abs(math.log(row["ratio"])))
    noise_floors = {
        group: math.expm1(quantile(values, FLOOR_QUANTILE)) for group, values in departures.items()
    }
    if any(row["evidence"] == "insufficient" for row in rows):
        warnings.append(
            f"Fewer than {MIN_ROUNDS} rounds: insufficient evidence."
            " Significance marks and goal verdicts are disabled."
        )
    groups: dict[tuple[str, str, str, str, str], list[float]] = defaultdict(list)
    for row in rows:
        floor = noise_floors.get(row["floor_group"])
        row["noise_floor"] = floor
        row["minimum_effect"] = minimum_effect
        row["significant"] = (
            row["comparison"] != "A/A"
            and row["evidence"] == "sufficient"
            and significant(
                tuple(row["ci95"]),
                max(floor, minimum_effect) if floor is not None else None,
            )
        )
        groups[
            row["comparison"], row["variant"], row["op"], row["tier"], row["candidate_impl"]
        ].append(row["ratio"])
    tiers = [
        {
            "comparison": key[0],
            "variant": key[1],
            "op": key[2],
            "tier": key[3],
            "candidate_impl": key[4],
            "geomean": geomean(values),
            "cases": len(values),
        }
        for key, values in sorted(groups.items())
    ]
    return {
        "noise_floors": noise_floors,
        "floor_quantile": FLOOR_QUANTILE,
        "minimum_effect": minimum_effect,
        "rows": rows,
        "tiers": tiers,
        "warnings": warnings,
    }
