"""Render the light and dark benchmark charts from the scorecard tables."""

from __future__ import annotations

import statistics
from pathlib import Path

import matplotlib as mpl

mpl.use("Agg")
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parents[1]
SCORECARD = ROOT / "docs/slop/results/scorecard.md"
OUTPUT = ROOT / "docs/static"

TIERS = ["0–16", "17–64", "65–256", "257–1K", "1K–16K", ">16K"]
OPERATIONS = ("set", "copy", "move")
HEAT = "#d4412b"
INK = "#16191d"
PAPER = "#f4f1ec"
SLATE = "#58616c"


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


def render(
    name: str,
    series: dict[str, list[tuple[float, float, float]]],
    *,
    background: str,
    foreground: str,
    muted: str,
    rule: str,
    colors: dict[str, str],
    move_alpha: float,
) -> None:
    """Draw one theme variant."""
    plt.rcParams.update(
        {
            "font.family": "DejaVu Sans",
            "font.size": 9,
            "svg.fonttype": "none",
            "text.color": foreground,
            "axes.edgecolor": rule,
            "axes.labelcolor": muted,
            "xtick.color": muted,
            "ytick.color": muted,
            "figure.facecolor": background,
            "axes.facecolor": background,
            "savefig.facecolor": background,
        }
    )

    figure = plt.figure(figsize=(7.3, 3.5))
    axis = figure.add_axes((0.105, 0.185, 0.865, 0.58))
    handles = []
    for operation in OPERATIONS:
        tiers = series[operation]
        median = [tier[0] for tier in tiers]
        low = [tier[1] for tier in tiers]
        high = [tier[2] for tier in tiers]
        color = colors[operation]
        alpha = move_alpha if operation == "move" else 1.0
        axis.errorbar(
            range(6),
            median,
            yerr=[
                [m - lo for m, lo in zip(median, low, strict=True)],
                [hi - m for m, hi in zip(median, high, strict=True)],
            ],
            fmt="none",
            color=color,
            ecolor=color,
            elinewidth=1.1,
            capsize=3,
            capthick=1.1,
            alpha=0.35 * alpha,
            zorder=2,
        )
        (line,) = axis.plot(
            range(6),
            median,
            color=color,
            linewidth=2.2,
            marker="o",
            markersize=4.2,
            alpha=alpha,
            solid_capstyle="round",
            label=operation,
            zorder=3,
        )
        handles.append(line)

    axis.axhline(1, color=rule, linewidth=1, linestyle=(0, (4, 3)), alpha=0.5, zorder=0)
    axis.set_yscale("log")
    axis.set_ylim(0.8, 36)
    axis.set_xlim(-0.35, 5.35)
    axis.set_xticks(range(6), TIERS, fontsize=8.5)
    axis.set_yticks([1, 2, 4, 8, 16, 32])
    axis.set_yticklabels(["1×", "2×", "4×", "8×", "16×", "32×"], fontsize=8.5)
    axis.minorticks_off()
    axis.grid(axis="y", color=rule, linewidth=0.8, alpha=0.16)
    axis.set_axisbelow(True)
    axis.tick_params(length=0, pad=6)
    for side in ("top", "right"):
        axis.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        axis.spines[side].set_linewidth(0.8)
        axis.spines[side].set_alpha(0.28)
    axis.set_ylabel("faster than compiler-rt (×)", fontsize=9, labelpad=8)

    figure.text(
        0.105,
        0.905,
        "fastmem against compiler-rt",
        fontsize=15,
        fontweight="bold",
        color=foreground,
    )
    figure.text(
        0.105,
        0.835,
        "ABI calls; median and range across seven EC2 targets. 1× is compiler-rt.",
        fontsize=8.5,
        color=muted,
    )
    figure.legend(
        handles=handles,
        labels=[line.get_label() for line in handles],
        loc="upper right",
        bbox_to_anchor=(0.97, 0.93),
        ncol=3,
        frameon=False,
        fontsize=8.5,
        handlelength=1.4,
        columnspacing=1.2,
    )
    figure.text(0.5, 0.075, "size (bytes)", ha="center", fontsize=9, color=muted)
    figure.text(
        0.105,
        0.025,
        "Zig 0.16.0 · six rounds · September 2026",
        fontsize=7.5,
        color=rule,
        alpha=0.65,
    )

    path = OUTPUT / name
    path.parent.mkdir(parents=True, exist_ok=True)
    figure.savefig(path, format="svg", metadata={"Date": None, "Creator": None})
    plt.close(figure)
    svg = path.read_text(encoding="utf-8")
    svg = svg.replace(
        "DejaVu Sans",
        "system-ui, -apple-system, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif",
    )
    path.write_text(svg, encoding="utf-8")
    print(f"wrote {path.relative_to(ROOT)}")


def main() -> None:
    text = SCORECARD.read_text(encoding="utf-8")
    series = bands(table(text, "### target, abi / compiler-rt (G3)"))
    render(
        "benchmark.svg",
        series,
        background=PAPER,
        foreground=INK,
        muted=SLATE,
        rule=SLATE,
        colors={"set": HEAT, "copy": SLATE, "move": INK},
        move_alpha=1.0,
    )
    render(
        "benchmark-dark.svg",
        series,
        background=INK,
        foreground=PAPER,
        muted=PAPER,
        rule=PAPER,
        colors={"set": HEAT, "copy": PAPER, "move": PAPER},
        move_alpha=0.55,
    )


if __name__ == "__main__":
    main()
