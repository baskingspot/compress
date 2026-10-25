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

X_MAX = 20.0
X_TICKS = (0.0, 5.0, 10.0, 15.0, 20.0)

WIDTH = 760
HEIGHT = 300
LEFT = 88.0
RIGHT = 52.0
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


def medians(series: dict[tuple[str, str], list[float]]) -> dict[tuple[str, str], float]:
    return {
        key: statistics.median([value for value in values if not math.isnan(value)])
        for key, values in series.items()
    }


def x_of(value: float) -> float:
    return LEFT + PLOT_W * min(value, X_MAX) / X_MAX


def label(value: float) -> str:
    return f"{value:.2f}" if value < 1 else f"{value:.1f}"


def render(theme: dict[str, str], name: str, series: dict[tuple[str, str], list[float]]) -> Path:
    middle = medians(series)
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
            "64 KiB inputs, median across eight corpus shapes and seven EC2 targets. GB/s.",
            size=8.5,
            fill=theme["muted"],
        )
    )

    legend_x = WIDTH - RIGHT - 118
    for index, (direction_label, color) in enumerate(
        (("encode", theme["encode"]), ("decode", theme["decode"]))
    ):
        x = legend_x + index * 62
        parts.append(f'<rect x="{x:.2f}" y="23" width="16" height="7" rx="1.5" fill="{color}"/>')
        parts.append(text(x + 21, 30, direction_label, size=8, fill=theme["fg"]))

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
            ("compress", theme["encode"], -8.0),
            ("decompress", theme["decode"], 8.0),
        ):
            value = middle[(codec, direction)]
            y = center + offset
            parts.append(
                f'<rect x="{LEFT:.2f}" y="{y - 4.5:.2f}" width="{x_of(value) - LEFT:.2f}"'
                f' height="9" rx="1.5" fill="{color}"/>'
            )
            parts.append(
                text(x_of(value) + 6, y + 2.6, label(value), size=7.5, fill=theme["muted"])
            )

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
