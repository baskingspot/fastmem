"""Machine-readable results and compact human reports."""

import json
import math
from pathlib import Path
from typing import Any

from rich.console import Console
from rich.table import Table


def comparison(row: dict[str, Any]) -> str:
    return (
        f"{row['comparison']} ({row['candidate_impl']})"
        if row["comparison"] in {"A/A", "revision"}
        else row["comparison"]
    )


def dispatch_lines(dispatch: dict[str, dict[str, Any]]) -> list[str]:
    """The runtime-dispatch state of each variant (analysis.record_dispatch)."""
    if not any(state["record"] for state in dispatch.values()):
        return []
    lines = []
    for variant, state in sorted(dispatch.items()):
        record = state["record"]
        if record:
            lines.append(
                f"Runtime dispatch, {variant}: {record['level']} ({record['kernel']}),"
                f" {record['vendor']} family {record['family']} model {record['model']}."
            )
        else:
            lines.append(f"Runtime dispatch, {variant}: none (the binary has no dispatch).")
    return [*lines, ""]


def write(path: Path, summary: dict[str, Any]) -> None:
    (path / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    text = [
        "# Benchmark report",
        "",
        "Ratios below 1 indicate a faster candidate.",
        "",
        "Each round contributes the median of its samples for each case and implementation.",
        "Two variants run in separate processes. A/A and revision rows use the two-sample",
        "Hodges-Lehmann ratio and the exact Mann-Whitney interval (96.8% for 5 against 5 rounds).",
        "The implementations of one variant run in the same processes. Their rows use the",
        "one-sample Hodges-Lehmann ratio of the per-round ratios and the exact Wilcoxon",
        "signed-rank interval (93.75% for 5 rounds: the range of the per-round ratios).",
        "The Level column gives the nominal coverage of each interval under its model",
        "(docs/slop/bench-design.md).",
        "Flagged outlier rounds are reported only. They stay in every ratio and interval.",
        "The noise floor is the 95th percentile of |log A/A ratio| in the operation/size group,",
        "pooled across profiles and implementations. Distribution cases use operation/tier groups.",
        "An asterisk requires at least five rounds and an interval entirely outside",
        "[1/(1+m), 1+m], where m is the larger of the noise floor and the minimum effect.",
        "Rows with fewer than five rounds show insufficient evidence: no mark, no goal verdict.",
        "",
    ]
    text += ["| Variant | Revision |", "|---|---|"]
    for variant, revision in summary["variants"].items():
        text.append(f"| {variant} | {revision} |")
    text.append("")
    table = Table("Target", "Comparison", "Variant", "Operation", "Tier", "Ratio")
    for target, result in summary["targets"].items():
        text += [f"## {target}", ""]
        if "error" in result:
            text += [f"Target failed: {result['error']}", ""]
            continue
        for warning in result.get("warnings", []):
            text += [f"Warning: {warning}", ""]
        text += dispatch_lines(result.get("dispatch", {}))
        text += goal_table(result.get("goals", []))
        text += stability_table(result)
        text += [f"Minimum effect: {result['minimum_effect']:.4%}.", ""]
        if result["noise_floors"]:
            text += ["| A/A floor group | Noise floor |", "|---|---:|"]
            for group, floor in sorted(result["noise_floors"].items()):
                text.append(f"| {group} | {floor:.4%} |")
        else:
            text.append("A/A is disabled. The report does not mark significance.")
        text += ["", *outlier_table(result.get("outliers", []))]
        text += [
            "| Case | Comparison | Variant | Ratio | Interval | Level | Outlier rounds |",
            "|---|---|---|---:|---|---:|---|",
        ]
        for row in result["rows"]:
            mark = " *" if row["significant"] else ""
            lo, hi = row["ci95"]
            level = f"{row['ci_level']:.2%}"
            if row.get("evidence") == "insufficient":
                level += " (insufficient evidence)"
            text.append(
                f"| {row['case']} | {comparison(row)} | {row['variant']} | "
                f"{row['ratio']:.4f}{mark} | {lo:.4f}-{hi:.4f} | {level} | {outlier_cell(row)} |"
            )
        text += [
            "",
            "### Size tiers",
            "",
            "| Comparison | Variant | Operation | Tier | Geomean |",
            "|---|---|---|---|---:|",
        ]
        for row in result["tiers"]:
            values = [
                comparison(row),
                row["variant"],
                row["op"],
                row["tier"],
                f"{row['geomean']:.4f}",
            ]
            table.add_row(target, *values)
            text.append("| " + " | ".join(values) + " |")
        text.append("")
    (path / "report.md").write_text("\n".join(text))
    Console().print(table)


OUTLIER_LIMIT = 50


def outlier_cell(row: dict[str, Any]) -> str:
    flagged = row.get("outlier_rounds", {})
    return " ".join(
        f"{side[0]}:r{index}"
        for side in ("candidate", "baseline")
        for index in flagged.get(side, [])
    )


def outlier_table(outliers: list[dict[str, Any]]) -> list[str]:
    text = ["### Outlier rounds", ""]
    if not outliers:
        return [*text, "No round was flagged.", ""]
    counts: dict[str, int] = {}
    for item in outliers:
        counts[item["variant"]] = counts.get(item["variant"], 0) + 1
    text += [
        "A flagged round departs from the other rounds of its variant, case, and implementation.",
        "It stays in every ratio and interval. Flagged rounds per variant: "
        + ", ".join(f"{variant} {count}" for variant, count in sorted(counts.items()))
        + ".",
        "",
        "| Variant | Case | Implementation | Round | Ratio to other rounds |",
        "|---|---|---|---:|---:|",
    ]
    ordered = sorted(outliers, key=lambda item: -abs(math.log(item["ratio"])))
    text += [
        f"| {item['variant']} | {item['case']} | {item['impl']} | {item['round']} | "
        f"{item['ratio']:.3f} |"
        for item in ordered[:OUTLIER_LIMIT]
    ]
    if len(ordered) > OUTLIER_LIMIT:
        text.append("")
        text.append(
            f"The largest {OUTLIER_LIMIT} of {len(ordered)} appear. `summary.json` has all."
        )
    return [*text, ""]


def null_note(value: dict[str, Any]) -> str:
    reference = value.get("aa_reference")
    if not reference or not reference["cases"]:
        return ""
    return f", A/A null with {reference['rule']}: {reference['violations']}/{reference['cases']}"


def level_note(value: dict[str, Any]) -> str:
    levels = value.get("ci_levels")
    return f", levels={'/'.join(f'{level:.2%}' for level in levels)}" if levels else ""


def goal_table(goals: list[dict[str, Any]]) -> list[str]:
    text = [
        "### Goals",
        "",
        "| Variant | Operation | Goal | Verdict | Evidence |",
        "|---|---|---|---|---|",
    ]
    for goal in goals:
        for name in ("G2", "G3", "G4", "G6"):
            value = goal[name]
            if name == "G2":
                evidence = (
                    f"geomean={value['geomean']}, tiers={value['tier_geomeans']}, "
                    f"significant >1.10: {len(value['significant_above_1_10'])}, "
                    f"cases={value['cases']}/{value['required_cases']}, rounds={value['rounds']}"
                    + level_note(value)
                    + null_note(value)
                )
            elif name in {"G3", "G6"}:
                evidence = (
                    f"worst={value['worst_ratio']}, "
                    f"violations ({value['rule']}): {len(value['violations'])}, "
                    f"missing={len(value['missing_cases'])}, rounds={value['rounds']}"
                    + level_note(value)
                    + null_note(value)
                )
            else:
                evidence = (
                    f"small={value['small']['status']} (ratio={value['small']['ratio']}), "
                    f"const={value['const']['status']}"
                    f"{null_note(value['const'])}, no-call=NA (checked by binary test, P4)"
                )
                if value["const"].get("missing_cases"):
                    evidence += f", const missing={len(value['const']['missing_cases'])}"
            if "reason" in value:
                evidence += ". " + value["reason"]
            text.append(
                f"| {goal['variant']} | {goal['op']} | {name} | {value['status']} | {evidence} |"
            )
    text += ["", "Full goal evidence and missing cases appear in `summary.json`.", ""]
    return text


def stability_line(group: dict[str, Any], metric: str) -> str:
    value = group[metric]
    rate, share = value["spike_rate"], value["worst_process_share"]
    text = (
        f"{'+'.join(group['variants'])} {metric}: spikes {value['spikes']}/{value['round_cells']}"
        f" ({'n/a' if rate is None else f'{rate:.2%}'})"
    )
    if share is not None:
        text += f", worst process {value['worst_process']} {share:.0%}"
    if floor := value["null_floor"]:
        text += (
            f", null floor {floor['candidate']}/{floor['reference']}"
            f" median {floor['median']:.2%} p90 {floor['p90']:.2%} max {floor['max']:.2%}"
        )
    return text


def stability_table(result: dict[str, Any]) -> list[str]:
    stability = result.get("stability")
    memory = result.get("memory")
    if not stability:
        return []
    text = [
        "### Measurement stability",
        "",
        (
            f"A spike is a round median more than {stability['spike_threshold']:.0%} above the"
            " median of its case and implementation over all variants of one binary."
            " Cycles count only samples that the PMU counted for the whole batch."
        ),
        "",
        "| Variants | Metric | Spikes | Rate | Worst process | Null floor median / p90 / max |",
        "|---|---|---:|---:|---|---|",
    ]
    for group in stability["groups"]:
        for metric in stability["metrics"]:
            value = group[metric]
            rate, share, floor = (
                value["spike_rate"],
                value["worst_process_share"],
                value["null_floor"],
            )
            cells = [
                "+".join(group["variants"]),
                metric,
                f"{value['spikes']}/{value['round_cells']}",
                "n/a" if rate is None else f"{rate:.2%}",
                "-" if share is None else f"{value['worst_process']} {share:.0%}",
                f"{floor['median']:.2%} / {floor['p90']:.2%} / {floor['max']:.2%}"
                if floor
                else "-",
            ]
            text.append("| " + " | ".join(cells) + " |")
    if memory and memory["arena_processes"]:
        minimum = memory["thp_coverage_min"]
        text += [
            "",
            (
                f"Memory: arena in {memory['arena_processes']} of {memory['processes']}"
                f" processes. THP covered the whole arena in {memory['thp_full_processes']}"
                f" (minimum start coverage {'unknown' if minimum is None else f'{minimum:.0%}'},"
                f" policy {', '.join(memory['thp_policies'])})."
            ),
        ]
    return [*text, ""]
