"""Render the benchmark chart from the scorecard tables."""

from __future__ import annotations

import statistics
from pathlib import Path

import matplotlib as mpl

mpl.use("Agg")
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parents[1]
SCORECARD = ROOT / "docs/slop/results/scorecard.md"
OUTPUT = ROOT / "docs/static/benchmark.svg"

TIERS = ["0–16", "17–64", "65–256", "257–1K", "1K–16K", ">16K"]
OPERATIONS = ("set", "copy", "move")
COLORS = {"set": "#d4412b", "copy": "#58616c", "move": "#16191d"}
INK = "#16191d"
PAPER = "#f4f1ec"
SLATE = "#58616c"
RULE = "#58616c"


def table(text: str, heading: str) -> dict[str, list[list[float]]]:
    """Read the three operation rows of one scorecard table."""
    block = text.split(heading, 1)[1].split("\n### ", 1)[0]
    rows: dict[str, list[list[float]]] = {}
    for line in block.splitlines():
        stripped = line.strip()
        if not stripped.startswith("| "):
            continue
        cells = [cell.strip() for cell in stripped.strip("|").split("|")]
        if len(cells) != 8 or cells[0] not in OPERATIONS:
            continue
        values = [[float(v) for v in cell.split()] for cell in cells[1:]]
        if len(values) != 7 or any(len(target) != 6 for target in values):
            raise SystemExit(f"unexpected scorecard row: {line}")
        rows[cells[0]] = values
    missing = set(OPERATIONS) - set(rows)
    if missing:
        raise SystemExit(f"scorecard has no rows for {sorted(missing)}")
    return rows


def bands(rows: dict[str, list[list[float]]]) -> dict[str, list[tuple[float, float, float]]]:
    """Turn time ratios into median, minimum, and maximum speedups per tier."""
    out: dict[str, list[tuple[float, float, float]]] = {}
    for operation, targets in rows.items():
        tiers = []
        for tier in range(6):
            speedups = [1 / target[tier] for target in targets]
            tiers.append((statistics.median(speedups), min(speedups), max(speedups)))
        out[operation] = tiers
    return out


def render() -> None:
    text = SCORECARD.read_text(encoding="utf-8")
    panels = {
        "glibc 2.40": bands(table(text, "### target, abi / glibc (G2)")),
        "compiler-rt": bands(table(text, "### target, abi / compiler-rt (G3)")),
    }

    plt.rcParams.update(
        {
            "font.family": "DejaVu Sans",
            "font.size": 9,
            "svg.fonttype": "none",
            "text.color": INK,
            "axes.edgecolor": RULE,
            "axes.labelcolor": SLATE,
            "xtick.color": SLATE,
            "ytick.color": SLATE,
            "figure.facecolor": PAPER,
            "axes.facecolor": PAPER,
            "savefig.facecolor": PAPER,
        }
    )

    figure = plt.figure(figsize=(9.6, 4.6))
    grid = figure.add_gridspec(1, 2, left=0.075, right=0.985, top=0.73, bottom=0.17, wspace=0.14)
    axes = [figure.add_subplot(grid[0, index]) for index in range(2)]
    handles = []
    for axis, (baseline, series) in zip(axes, panels.items(), strict=True):
        for operation in OPERATIONS:
            tiers = series[operation]
            median = [tier[0] for tier in tiers]
            low = [tier[1] for tier in tiers]
            high = [tier[2] for tier in tiers]
            axis.fill_between(range(6), low, high, color=COLORS[operation], alpha=0.14, linewidth=0)
            (line,) = axis.plot(
                range(6),
                median,
                color=COLORS[operation],
                linewidth=2.2,
                solid_capstyle="round",
                label=operation,
            )
            if baseline == "glibc 2.40":
                handles.append(line)
        axis.axhline(1, color=RULE, linewidth=1, linestyle=(0, (4, 3)), alpha=0.55, zorder=0)
        axis.set_yscale("log")
        axis.set_ylim(0.8, 32)
        axis.set_xlim(-0.35, 5.35)
        axis.set_xticks(range(6), TIERS, fontsize=8.5)
        axis.set_yticks([1, 2, 4, 8, 16, 32])
        axis.set_yticklabels(["1×", "2×", "4×", "8×", "16×", "32×"], fontsize=8.5)
        axis.minorticks_off()
        axis.grid(axis="y", color=RULE, linewidth=0.8, alpha=0.18)
        axis.set_axisbelow(True)
        axis.tick_params(length=0, pad=6)
        for side in ("top", "right"):
            axis.spines[side].set_visible(False)
        for side in ("left", "bottom"):
            axis.spines[side].set_linewidth(0.8)
            axis.spines[side].set_alpha(0.25)
        axis.set_title(
            f"vs {baseline}",
            loc="left",
            fontsize=11,
            fontweight="bold",
            color=INK,
            pad=12,
        )

    axes[0].set_ylabel("faster than the baseline (×)", fontsize=9, labelpad=8)
    figure.text(
        0.075,
        0.925,
        "fastmem speedup by size tier",
        fontsize=17,
        fontweight="bold",
        color=INK,
    )
    figure.text(
        0.075,
        0.855,
        "ABI calls. Median and range across seven EC2 targets; 1× is the baseline.",
        fontsize=9,
        color=SLATE,
    )
    figure.legend(
        handles=handles,
        labels=[line.get_label() for line in handles],
        loc="upper right",
        bbox_to_anchor=(0.985, 0.955),
        ncol=3,
        frameon=False,
        fontsize=9,
        handlelength=1.5,
        columnspacing=1.4,
    )
    figure.text(0.5, 0.075, "size (bytes)", ha="center", fontsize=9, color=SLATE)
    figure.text(
        0.075,
        0.025,
        "Zig 0.16.0 · glibc 2.40 · six rounds · September 2026",
        fontsize=8,
        color=RULE,
        alpha=0.75,
    )

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    figure.savefig(OUTPUT, format="svg", metadata={"Date": None, "Creator": None})
    plt.close(figure)

    svg = OUTPUT.read_text(encoding="utf-8")
    svg = svg.replace(
        "DejaVu Sans",
        "system-ui, -apple-system, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif",
    )
    OUTPUT.write_text(svg, encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    render()
