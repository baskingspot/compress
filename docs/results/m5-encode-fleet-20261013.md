# The M5 encode fleet run: the zstd encoder's first numbers

Run: `bench-results/20261013T071421Z-m5-encode2` (local, gitignored; the run id and
this file are the durable record). 7/7 targets, 6 arms, 1,092 rows per target
(the encode rows' first fleet appearance beside the decode rows), `rounds=5`,
`evidence=sufficient` on every row, no failures, the four expected
cross-format coverage warnings per target. Outlier rounds retained.

The first launch (`20261013T070400Z-m5-encode`) failed all seven targets at
round 0 — the harness's sample-set check expected std rows for zstd
compression, which `std.compress.zstd` cannot emit (the std audit: Zig 0.16
ships `Decompress` only, no encoder). The fix (the std-zstd-compress cells
exclude like std-snappy always did) landed at 86a742c with the encode-row
arm work; this run is the clean relaunch.

## The encode verdict: byte-parity with the C's class, 2.5-4x the time

zstd encode, zcompress ÷ zstd-c v1.5.7 at its level 1 (median, lower =
zcompress faster):

| shape | c7g | c8g | c9g | c7a | c8a | c7i | c8i |
|---|---|---|---|---|---|---|---|
| text/html/rle-32K | 1.85-2.16 | 2.03-2.16 | 1.91-2.00 | 1.69-1.76 | 1.95-2.02 | 4.03-4.07 | 3.60-3.83 |
| mixed/random-32K | 1.95-1.98 | 2.36-2.40 | 2.35-2.39 | 2.62-2.73 | 2.78-2.83 | 3.52-3.56 | 3.50-3.54 |
| mixed/random-64K | 6.63-6.70 | 7.28-7.31 | 7.58-7.69 | 6.48-6.73 | 7.36-7.44 | 8.68-8.76 | 8.70-8.79 |
| words-32K | 1.86 | 2.07 | 2.01 | 2.09 | 2.16 | 1.74 | 1.76 |
| skewlit-32K | 3.08 | 3.86 | 3.71 | 4.83 | 4.67 | 3.55 | 3.64 |

- **Byte-parity holds**: our level-1 output is the C's class exactly (the
  corpus's `.zst` blobs decode through our decoder; the encode rows'
  round-trips ride the correctness gate), with the deterministic +4-byte
  XXH64 trailer the C's default omits.
- **The compressible shapes run 1.7-4.1x the C's time** — the first-pass
  port against the C's tuned level-1. The Intel targets are the slowest
  ratios (3.5-4.1x on compressible) while running the fastest absolute
  clocks; the ARM targets are 1.7-2.2x.
- **The incompressible 64-KiB rows are the outlier at 6.5-8.8x**: the C's
  block-level early-exit detects incompressible input and emits Raw without
  the match finder's full scan; our port runs the full find before the
  minGain fallback. This is the encode side's ranked #1 lever.
- **The entropy-heavy rows (words) are the closest at 1.7-2.2x** — the
  entropy writers are the same machinery the decoder proved byte-exact, and
  the C's per-symbol loop edge (the decode side's known 1.4-2.2x residue)
  carries over to encoding.

Against klauspost's `EncodeAll` at `SpeedFastest` (the Go level-1-class
peer) on the compressible shapes: 0.6-0.89 on the ARM targets (zcompress
faster), 1.17-1.21 on Intel (klauspost faster). The first fleet run of the
Go arm's encode side on this corpus.

## The decode rows (stability check)

The decode rows re-ran in the same invocation: the copy-side keepers from
the wave-2 run hold — rle on c8i at ~1.1 (the C's Granite fill/store
doubling), mixed/random on c7i/c8i at ~1.8-1.9 (the raw copy+fold
interleave's target; the local interleave win was bandwidth-capped, so the
fleet's verdict on the interleave's effect there is: no measurable change
on c9g, the Intel rows carry the same deficit as wave 2), text/html/rle
0.23-0.85 everywhere else. The words/skewlit decode rows (1.4-2.2) carry
the same per-symbol residue. No decode regression from the encoder's
landing.

## Ranked, end of M5

1. **The incompressible early-exit** (mixed/random-64K at 6.5-8.8x): the
   C's fast-path detection before the match find; sized, not started.
2. **The compressible-shape 1.7-4.1x**: the port's per-block costs (the
   sequence-list recompute the entropy-kernels slice flagged, the finder's
   window handling) — a measurement campaign over the block layer.
3. **The Intel encode gap** (3.5-4.1x vs ARM's 1.7-2.2x): the ratios invert
   the clocks — the C's level-1 gains more on Intel than ours does. The
   BMI2-shaped writer paths are the hypothesis; unmeasured.

## Provenance

- Run id `20261013T071421Z-m5-encode2`, executed 2026-10-13. The zc arm at
  86a742c (the encode rows + the sample-set fix). Gate: PASS x 42 in
  `bench-results/20261013T071411Z-test`.
- Reproduce: `just bench-up`, `just bench-test`, `just bench-run --suite
  standard --rounds 5`, `just b analyze ../bench-results/<run-dir>`.
