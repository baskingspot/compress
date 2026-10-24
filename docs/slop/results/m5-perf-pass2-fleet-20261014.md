# The beat-everything pass 1 fleet run: the grid moves

Run: `bench-results/20261014T104001Z-m5-perf-pass2` (local, gitignored; the run id and this
file are the durable record). The arms built from the working tree at `abb599b` — the
beat-everything pass 1's three lever commits (`0713469` the sequences-table double-buffer,
`9b1d05e` the vectorized match-finder extension, `8895881` the register-resident scan and
fixed-schedule flushes) on top of the brotli decoder's completed surface (unreferenced by
the driver). The baseline is `bench-results/20261013T192145Z-m5-perf-pass` (measured
`6ade796`, the run of record behind `docs/results/m5-perf-pass-fleet-20261013.md`).
7/7 targets, 6 arms + A/A, `rounds=5`, `evidence=sufficient` on every row, no failures,
the four expected cross-format coverage warnings per target. Outlier rounds retained.

## The verdict: the kept levers paid everywhere the local numbers said they would

zstd encode, zcompress ÷ competitor (median, lower = zcompress faster), baseline → this run:

| shape | c7g | c8g | c9g | c7a | c8a | c7i | c8i |
|---|---|---|---|---|---|---|---|
| words-32K | 1.59 → 1.22 | 1.74 → 1.31 | 1.70 → 1.24 | 1.65 → 1.23 | 1.78 → 1.27 | 1.52 → 1.16 | 1.53 → 1.15 |
| words-64K | 1.62 → 1.25 | 1.75 → 1.32 | 1.84 → 1.29 | 1.58 → 1.23 | 1.71 → 1.28 | 1.49 → 1.14 | 1.47 → 1.13 |
| skewlit-32K | 1.77 → 1.55 | 1.90 → 1.53 | 1.73 → 1.32 | 1.95 → 1.27 | 1.53 → 1.52 | 2.06 → 1.40 | 2.16 → 1.38 |
| skewlit-64K | 1.99 → 1.55 | 2.01 → 1.53 | 1.88 → 1.33 | 2.05 → 1.29 | 1.69 → 1.53 | 2.27 → 1.41 | 2.45 → 1.39 |
| text/html/rle-32K | 1.90-1.93 → 1.92-1.95 | 2.10-2.23 → 1.91-2.05 | 2.01-2.05 → 2.03-2.07 | 1.74-1.81 → 1.38-1.43 | 1.98-2.09 → 1.55-1.59 | 3.73-4.14 → 3.36-3.52 | 3.64-3.87 → 3.26-3.52 |
| mixed/random-32K | 1.15-1.18 → 1.12-1.16 | 1.15 → 1.13 | 1.16-1.18 → 1.16 | 1.14-1.18 → 1.14 | 1.17-1.20 → 1.17 | 1.34-1.38 → 1.33-1.34 | 1.33-1.38 → 1.33 |
| mixed/random-64K | 1.39-1.44 → 1.38-1.41 | 1.38-1.41 → 1.38 | 1.45-1.54 → 1.45-1.49 | 1.28-1.40 → 1.28-1.29 | 1.33-1.39 → 1.33-1.35 | 1.84-1.91 → 1.84-1.86 | 1.84-1.92 → 1.84-1.85 |

- **The entropy shapes collapsed 25-45%**: words-32K/64K 1.5-1.8x → 1.13-1.32x
  (the register-resident scan + the fixed-schedule flushes, exactly the local
  prediction of +34-38%), skewlit-32K/64K → 1.27-1.55 (the local +20-31%).
- **c7a (Graviton4) took the literal-heavy shapes down 20-25%** (text/html/rle-32K
  1.74-1.81 → 1.38-1.43) and c8a 20-25%; the other Gravitons stayed flat and Intel
  moved 15-18% — the layout effects distribute unevenly and the Intel-specific
  serial-chain signature remains.
- **klauspost is beaten on words on every target now** (zcompress ÷ klauspost
  0.90-1.06 → 0.66-0.80), and the ARM text/html rows extended the lead
  (0.48-0.66 → 0.38-0.54 on c7a/c8a). The remaining klauspost deficits are rle-64K
  on three targets and one c9g html-64K row at 1.02.
- **Decode verified neutral**: all 28 decode rows moved within ±1% — the pass's
  changes are encode-side only, confirmed at the fleet.

## Where the bar stands

The beat-everything bar (every zstd row under 1.0 vs every arm) after pass 1: the
entropy shapes sit at 1.13-1.55 vs the C, the literal-heavy shapes at 1.38-1.43 on
c7a but still 3.26-3.52 on the Intel targets and 1.9-2.1 on c7g/c8g, mixed/random
at 1.12-1.34. The two named levers for pass 2:

1. **The checksum asymmetry is now the biggest honest-grid lever.** Measured in the
   pass: the XXH64 full-input pass costs ~2.5 µs per 64 KiB, ~35% of html-64K encode
   time on ARM — the zstd-c library arm pays nothing while our frames carry the
   trailer (the +4-byte size parity). The fair-grid fix — the driver's zstd-c arm
   made to pay its checksum flag — moves every zc ÷ C row down 10-30% without a code
   change, and it is a driver/methodology decision, not a codec lever.
2. **The Intel literal-heavy gap (3.3-3.5x)**: the find is only 2.7 µs of those rows
   post-l3c; the residual is the vectorized count, the checksum, and block-ladder
   overhead, with an Intel-specific multiplier the local box cannot profile. An
   Intel-target profile (the fleet's c7i/c8i with perf counters) is the prerequisite
   for the next pass's ranking.

The pass's honest reversions and record corrections stand in the lever commit
(`8895881`) and `docs/results/m5-perf-pass-fleet-20261013.md`'s correction note:
the TE9 attribution for the 1-3% literal-heavy regression was disproven (code
layout, not the scan), and the TE9 early-exit lever itself was tried and reverted
(the per-byte cap check costs more than the one final max scan on the only rows
that reach the path).
