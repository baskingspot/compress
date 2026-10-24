"""Render the light and dark throughput charts from the newest scorecard.

Six panels, one per codec namespace, each with an encode and a decode line
over the corpus shapes. The y axis is a shared log scale in GB/s, so the
panels compare directly. Only the brand palette is used.

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

Y_MIN = 0.03
Y_MAX = 100.0
Y_TICKS = (0.1, 1.0, 10.0, 100.0)

WIDTH = 760
HEIGHT = 420
LEFT = 64.0
RIGHT = 18.0
TOP = 76.0
BOTTOM = 58.0
GAP_X = 26.0
GAP_Y = 34.0
PANEL_W = (WIDTH - LEFT - RIGHT - 2 * GAP_X) / 3
PANEL_H = (HEIGHT - TOP - BOTTOM - GAP_Y) / 2
PLOT_W = PANEL_W - 8.0
PLOT_H = PANEL_H - 24.0

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
    rotate: float | None = None,
) -> str:
    transform = f' transform="rotate({rotate} {x:.2f} {y:.2f})"' if rotate else ""
    return (
        f'<text x="{x:.2f}" y="{y:.2f}" font-size="{size}" fill="{fill}"'
        f' font-family="{FONT}" font-weight="{weight}" text-anchor="{anchor}"'
        f' opacity="{opacity}"{transform}>{escape(value)}</text>'
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


def y_of(value: float, top: float) -> float:
    fraction = (math.log10(value) - math.log10(Y_MIN)) / (math.log10(Y_MAX) - math.log10(Y_MIN))
    return top + PLOT_H * (1.0 - fraction)


def panel(
    codec: str,
    series: dict[tuple[str, str], list[float]],
    x0: float,
    top: float,
    theme: dict[str, str],
    *,
    row: int,
) -> list[str]:
    parts: list[str] = []
    bottom = top + PLOT_H
    parts.append(text(x0, top - 9, codec, size=9.5, fill=theme["fg"], weight="600"))

    for tick in Y_TICKS:
        y = y_of(tick, top)
        parts.append(
            f'<line x1="{x0:.2f}" y1="{y:.2f}" x2="{x0 + PLOT_W:.2f}" y2="{y:.2f}"'
            f' stroke="{theme["rule"]}" stroke-width="0.7" opacity="{theme["grid"]}"/>'
        )
        if x0 == LEFT and tick != Y_TICKS[-1]:
            label = f"{tick:g}"
            parts.append(text(x0 - 7, y + 2.4, label, size=7, fill=theme["muted"], anchor="end"))

    parts.append(
        f'<line x1="{x0:.2f}" y1="{top:.2f}" x2="{x0:.2f}" y2="{bottom:.2f}"'
        f' stroke="{theme["rule"]}" stroke-width="0.7" opacity="{theme["axis"]}"/>'
    )
    parts.append(
        f'<line x1="{x0:.2f}" y1="{bottom:.2f}" x2="{x0 + PLOT_W:.2f}" y2="{bottom:.2f}"'
        f' stroke="{theme["rule"]}" stroke-width="0.7" opacity="{theme["axis"]}"/>'
    )

    step = PLOT_W / (len(SHAPES) - 1)
    for index, shape in enumerate(SHAPES):
        x = x0 + step * index
        if row == 1:
            parts.append(
                text(
                    x,
                    bottom + 12,
                    shape,
                    size=6.8,
                    fill=theme["muted"],
                    anchor="end",
                    rotate=-40,
                )
            )

    for direction, color in (("compress", theme["encode"]), ("decompress", theme["decode"])):
        values = series[(codec, direction)]
        points = [
            (x0 + step * index, y_of(value, top))
            for index, value in enumerate(values)
            if not math.isnan(value)
        ]
        if len(points) < 2:
            continue
        path = " ".join(f"{x:.2f},{y:.2f}" for x, y in points)
        parts.append(
            f'<polyline points="{path}" fill="none" stroke="{color}"'
            f' stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/>'
        )
        for x, y in points:
            parts.append(f'<circle cx="{x:.2f}" cy="{y:.2f}" r="2.1" fill="{color}"/>')

    return parts


def render(theme: dict[str, str], name: str, series: dict[tuple[str, str], list[float]]) -> Path:
    parts = [
        (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}"'
            f' viewBox="0 0 {WIDTH} {HEIGHT}" role="img">'
        ),
        f'<rect width="{WIDTH}" height="{HEIGHT}" fill="{theme["bg"]}"/>',
    ]
    parts.append(text(LEFT, 30, "compress throughput", size=15, fill=theme["fg"], weight="700"))
    parts.append(
        text(
            LEFT,
            48,
            "64 KiB inputs. Median of seven EC2 targets; eight corpus shapes.",
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
        parts.append(f'<circle cx="{x + 8:.2f}" cy="27" r="2.1" fill="{color}"/>')
        parts.append(text(x + 21, 30, label, size=8, fill=theme["fg"]))

    for index, codec in enumerate(CODECS):
        column = index % 3
        row = index // 3
        x0 = LEFT + column * (PANEL_W + GAP_X)
        top = TOP + row * (PANEL_H + GAP_Y)
        parts.extend(panel(codec, series, x0, top, theme, row=row))

    parts.append(
        text(
            18,
            (TOP + HEIGHT - BOTTOM) / 2,
            "GB/s",
            size=7.5,
            fill=theme["muted"],
            anchor="middle",
            rotate=-90,
        )
    )
    parts.append(
        text(
            LEFT,
            HEIGHT - 16,
            "flate, gzip, zlib, and zstd at level 1; brotli at quality 3. Five rounds.",
            size=6.5,
            fill=theme["muted"],
        )
    )
    parts.append(
        text(
            WIDTH - RIGHT,
            HEIGHT - 16,
            "Zig 0.16.0 · 2026-10-17",
            size=6.5,
            fill=theme["muted"],
            anchor="end",
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
        "axis": "0.32",
        "encode": HEAT,
        "decode": SLATE,
    }
    dark = {
        "bg": INK,
        "fg": PAPER,
        "muted": PAPER,
        "rule": PAPER,
        "grid": "0.14",
        "axis": "0.30",
        "encode": HEAT,
        "decode": PAPER,
    }
    render(light, "throughput.svg", series)
    render(dark, "throughput-dark.svg", series)
    return 0


if __name__ == "__main__":
    sys.exit(main())
