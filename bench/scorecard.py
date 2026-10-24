"""Record absolute one-shot throughput from a fleet run.

The harness's summary.json holds nanosecond timings, not throughput, and the
run directory is gitignored. This script extracts the compress arm's numbers
into a small scorecard under docs/slop/results/ that the chart script reads.

    uv run --project bench python bench/scorecard.py 20261017T115529Z-encoder-seats
"""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
CODECS = ("snappy", "flate", "gzip", "zlib", "zstd", "brotli")


def load(run_dir: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    manifest = json.loads((run_dir / "manifest.json").read_text(encoding="utf-8"))
    summary = json.loads((run_dir / "summary.json").read_text(encoding="utf-8"))
    return manifest, summary


def zc_ns(row: dict[str, Any]) -> float | None:
    """The compress arm's time in one comparison row, whichever side it is on."""
    if row["comparison"] == "A/A":
        return None
    if row["candidate_impl"] == "zc":
        return float(row["candidate_ns"])
    if row["reference_impl"] == "zc":
        return float(row["baseline_ns"])
    return None


def observations(summary: dict[str, Any]) -> list[dict[str, Any]]:
    """One row per codec, direction, shape, size, and target.

    A zc cell repeats once per competitor it was compared against. The medians
    agree across those rows; dedupe them through the median.
    """
    seen: dict[tuple[str, str, str, int, str], list[float]] = {}
    for target, data in summary["targets"].items():
        for row in data["rows"]:
            codec = row["codec"]
            if codec not in CODECS:
                continue
            ns = zc_ns(row)
            if ns is None:
                continue
            key = (codec, row["direction"], row["shape"], int(row["size"]), target)
            seen.setdefault(key, []).append(float(row["size"]) / ns)

    rows: list[dict[str, object]] = []
    for key in sorted(seen):
        codec, direction, shape, size, target = key
        rows.append(
            {
                "codec": codec,
                "direction": direction,
                "shape": shape,
                "size": size,
                "target": target,
                "gbs": round(statistics.median(seen[key]), 4),
            }
        )
    return rows


def main() -> int:
    if len(sys.argv) != 2:
        sys.exit("usage: scorecard.py RUN, such as 20261017T115529Z-encoder-seats")
    run = sys.argv[1]
    run_dir = ROOT / "bench-results" / run
    if not run_dir.is_dir():
        sys.exit(f"no run directory at {run_dir}")
    manifest, summary = load(run_dir)
    date = f"{run[0:4]}-{run[4:6]}-{run[6:8]}"
    out = ROOT / "docs/slop/results" / f"scorecard-{date}.json"
    payload = {
        "run": run,
        "date": date,
        "rounds": manifest["rounds"],
        "revision": manifest["git"]["head"],
        "arms": summary["arms"],
        "targets": sorted(summary["targets"]),
        "observations": observations(summary),
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {out.relative_to(ROOT)} ({len(payload['observations'])} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
