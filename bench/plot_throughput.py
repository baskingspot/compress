"""Render the light and dark throughput charts from the newest scorecard.

One row per codec, two dots per row: encode and decode. Each dot is the median
throughput across the corpus shapes, and the line through it is the shape
range, so the reader sees both the rate and how much the input moves it. The x
axis is a shared log scale in GB/s. Only the brand palette is used.

    uv run --project bench python bench/plot_throughput.py
"""

from __future__ import annotations

import json
import math
import statistics
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SCORECARDS = ROOT / "docs/slop/results"
OUTPUT = ROOT / "docs/static"

CODECS = ("snappy", "flate", "gzip", "zlib", "zstd", "brotli")
SHAPES = ("rle", "text", "html", "prose", "words", "mixed", "skewlit", "random")
SIZE = 65536

INK = "#16191d"
PAPER = "#f4f1ec"
HEAT = "#d4412b"
SLATE = "#58616c"

X_MIN = 0.05
X_MAX = 100.0
X_TICKS = (0.1, 1.0, 10.0, 100.0)

WIDTH = 760
HEIGHT = 330
LEFT = 88.0
RIGHT = 24.0
TOP = 66.0
BOTTOM = 44.0
PLOT_W = WIDTH - LEFT - RIGHT
PLOT_H = HEIGHT - TOP - BOTTOM
ROW_H = PLOT_H / len(CODECS)

FONT = "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif"


def escape(value: str) -> str:
    return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(
    x: float,
    y: float,
    value: str,
    *,
    size: float,
    fill: str,
    anchor: str = "start",
    weight: str = "normal",
    opacity: float = 1.0,
) -> str:
    return (
        f'<text x="{x:.2f}" y="{y:.2f}" font-size="{size}" fill="{fill}"'
        f' font-family="{FONT}" font-weight="{weight}" text-anchor="{anchor}"'
        f' opacity="{opacity}">{escape(value)}</text>'
    )


def shape_medians(observations: list[dict[str, Any]]) -> dict[tuple[str, str], list[float]]:
    cells: dict[tuple[str, str, str], list[float]] = {}
    for row in observations:
        if int(row["size"]) != SIZE:
            continue
        key = (str(row["codec"]), str(row["direction"]), str(row["shape"]))
        cells.setdefault(key, []).append(float(row["gbs"]))
    series: dict[tuple[str, str], list[float]] = {}
    for codec in CODECS:
        for direction in ("compress", "decompress"):
            series[(codec, direction)] = [
                statistics.median(cells[(codec, direction, shape)])
                if (codec, direction, shape) in cells
                else float("nan")
                for shape in SHAPES
            ]
    return series


def summarize(
    series: dict[tuple[str, str], list[float]],
) -> dict[tuple[str, str], tuple[float, float, float]]:
    """Lowest shape, median shape, highest shape for each codec and direction."""
    out: dict[tuple[str, str], tuple[float, float, float]] = {}
    for key, values in series.items():
        present = [value for value in values if not math.isnan(value)]
        out[key] = (min(present), statistics.median(present), max(present))
    return out


def x_of(value: float) -> float:
    fraction = (math.log10(value) - math.log10(X_MIN)) / (math.log10(X_MAX) - math.log10(X_MIN))
    return LEFT + PLOT_W * fraction


def render(theme: dict[str, str], name: str, series: dict[tuple[str, str], list[float]]) -> Path:
    summary = summarize(series)
    parts = [
        (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}"'
            f' viewBox="0 0 {WIDTH} {HEIGHT}" role="img">\n'
        ),
        f'<rect width="{WIDTH}" height="{HEIGHT}" fill="{theme["bg"]}"/>',
    ]
    parts.append(text(LEFT, 30, "compress throughput", size=15, fill=theme["fg"], weight="700"))
    parts.append(
        text(
            LEFT,
            48,
            "GB/s on a log scale. Median and range across eight corpus shapes; seven EC2 targets.",
            size=8.5,
            fill=theme["muted"],
        )
    )

    legend_x = WIDTH - RIGHT - 118
    for index, (label, color) in enumerate(
        (("encode", theme["encode"]), ("decode", theme["decode"]))
    ):
        x = legend_x + index * 62
        parts.append(
            f'<line x1="{x:.2f}" y1="27" x2="{x + 16:.2f}" y2="27"'
            f' stroke="{color}" stroke-width="1.7" stroke-linecap="round"/>'
        )
        parts.append(f'<circle cx="{x + 8:.2f}" cy="27" r="2.6" fill="{color}"/>')
        parts.append(text(x + 21, 30, label, size=8, fill=theme["fg"]))

    for tick in X_TICKS:
        x = x_of(tick)
        parts.append(
            f'<line x1="{x:.2f}" y1="{TOP:.2f}" x2="{x:.2f}" y2="{TOP + PLOT_H:.2f}"'
            f' stroke="{theme["rule"]}" stroke-width="0.7" opacity="{theme["grid"]}"/>'
        )
        parts.append(
            text(
                x,
                TOP + PLOT_H + 16,
                f"{tick:g}",
                size=7.5,
                fill=theme["muted"],
                anchor="middle",
            )
        )

    for index, codec in enumerate(CODECS):
        center = TOP + ROW_H * (index + 0.5)
        parts.append(
            text(
                LEFT - 14,
                center + 3.5,
                codec,
                size=10,
                fill=theme["fg"],
                anchor="end",
                weight="600",
            )
        )
        for direction, color, offset in (
            ("compress", theme["encode"], -7.0),
            ("decompress", theme["decode"], 7.0),
        ):
            low, middle, high = summary[(codec, direction)]
            y = center + offset
            parts.append(
                f'<line x1="{x_of(low):.2f}" y1="{y:.2f}" x2="{x_of(high):.2f}" y2="{y:.2f}"'
                f' stroke="{color}" stroke-width="1.2" stroke-linecap="round"'
                f' opacity="{theme["range"]}"/>'
            )
            parts.extend(
                f'<line x1="{x_of(edge):.2f}" y1="{y - 4:.2f}"'
                f' x2="{x_of(edge):.2f}" y2="{y + 4:.2f}"'
                f' stroke="{color}" stroke-width="1.2" stroke-linecap="round"'
                f' opacity="{theme["range"]}"/>'
                for edge in (low, high)
            )
            parts.append(f'<circle cx="{x_of(middle):.2f}" cy="{y:.2f}" r="3.2" fill="{color}"/>')

    parts.append(
        text(
            WIDTH - RIGHT,
            HEIGHT - 14,
            "Zig 0.16.0 · 2026-10-17",
            size=6.5,
            fill=theme["muted"],
            anchor="end",
        )
    )
    parts.append(
        text(
            LEFT,
            HEIGHT - 14,
            "flate, gzip, zlib, and zstd at level 1; brotli at quality 3. Five rounds.",
            size=6.5,
            fill=theme["muted"],
        )
    )
    parts.append("</svg>")

    path = OUTPUT / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(parts) + "\n", encoding="utf-8")
    print(f"wrote {path.relative_to(ROOT)}")
    return path


def main() -> int:
    candidates = sorted(SCORECARDS.glob("scorecard-*.json"))
    if not candidates:
        sys.exit("no scorecard under docs/slop/results; run bench/scorecard.py first")
    scorecard = json.loads(candidates[-1].read_text(encoding="utf-8"))
    series = shape_medians(scorecard["observations"])

    light = {
        "bg": PAPER,
        "fg": INK,
        "muted": SLATE,
        "rule": SLATE,
        "grid": "0.18",
        "range": "0.45",
        "encode": HEAT,
        "decode": SLATE,
    }
    dark = {
        "bg": INK,
        "fg": PAPER,
        "muted": PAPER,
        "rule": PAPER,
        "grid": "0.14",
        "range": "0.55",
        "encode": HEAT,
        "decode": PAPER,
    }
    render(light, "throughput.svg", series)
    render(dark, "throughput-dark.svg", series)
    return 0


if __name__ == "__main__":
    sys.exit(main())
