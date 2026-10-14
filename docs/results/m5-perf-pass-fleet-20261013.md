# The M5 perf pass fleet run: the ranked levers adjudicated

Run: `bench-results/20261013T192145Z-m5-perf-pass` (local, gitignored; the run id and
this file are the durable record). The arms built from `6ade796` exactly — the pass
committed before the fleet launched, tree clean. The baseline is
`bench-results/20261013T071421Z-m5-encode2`, the M5-close run of record behind
`docs/results/m5-encode-fleet-20261013.md` (built overnight, before the pass's first
edit). 7/7 targets, 6 arms + A/A, `rounds=5`, `evidence=sufficient` on every row, no
failures, the four expected cross-format coverage warnings per target. Outlier rounds
retained (c7g 2, c7a 4, c7i 8, c8a 8, c8i 14, c9g 21, c8g 23).

## The verdict: the targeted shapes 1.7-4.6x faster; the literal-heavy shapes pay 1-3%

zstd encode, zcompress ÷ zstd-c v1.5.7 at its level 1 (median, lower = zcompress
faster), old run → this run:

| shape | c7g | c8g | c9g | c7a | c8a | c7i | c8i |
|---|---|---|---|---|---|---|---|
| text/html/rle-32K | 1.85-2.16 → 1.90-2.23 | 2.03-2.16 → 2.10-2.23 | 1.91-2.00 → 2.01-2.05 | 1.69-1.76 → 1.74-1.81 | 1.95-2.02 → 1.98-2.09 | 4.03-4.07 → 4.08-4.14 | 3.60-3.83 → 3.64-3.87 |
| mixed/random-32K | 1.95-1.97 → 1.15 | 2.36-2.40 → 1.15 | 2.35-2.39 → 1.18 | 2.62-2.74 → 1.18 | 2.78-2.83 → 1.20 | 3.51-3.56 → 1.37-1.38 | 3.50-3.54 → 1.38 |
| skewlit-32K | 3.09 → 1.77 | 3.86 → 1.90 | 3.71 → 1.73 | 4.83 → 1.95 | 4.67 → 1.53 | 3.53 → 2.06 | 3.64 → 2.16 |
| words-32K | 1.86 → 1.59 | 2.07 → 1.74 | 2.01 → 1.70 | 2.09 → 1.65 | 2.16 → 1.78 | 1.74 → 1.52 | 1.76 → 1.53 |
| text/html/rle-64K | 2.06-2.09 → 2.09-2.12 | 2.41-2.43 → 2.40-2.46 | 2.18-2.28 → 2.25-2.31 | 1.84-1.90 → 1.86-1.93 | 2.18-2.26 → 2.20-2.33 | 4.34-4.73 → 4.37-4.76 | 3.82-3.96 → 3.85-3.99 |
| mixed/random-64K | 6.64-6.70 → 1.43-1.44 | 7.28-7.31 → 1.41 | 7.58-7.69 → 1.51-1.54 | 6.46-6.73 → 1.39-1.40 | 7.24-7.32 → 1.38-1.39 | 8.67-8.75 → 1.90-1.91 | 8.70-8.78 → 1.91-1.92 |
| skewlit-64K | 3.25 → 1.99 | 3.97 → 2.01 | 3.90 → 1.88 | 5.20 → 2.05 | 5.86 → 1.69 | 3.82 → 2.27 | 3.87 → 2.45 |
| words-64K | 1.90 → 1.62 | 2.12 → 1.75 | 2.14 → 1.84 | 2.01 → 1.58 | 2.12 → 1.71 | 1.72 → 1.49 | 1.69 → 1.47 |

- **The incompressible 64-KiB rows collapsed**: 6.5-8.8x the C's time down to
  1.38-1.92x. The ranked #1 lever (the block-level early-exit the C runs and the
  port skipped) is the whole story on those rows — the match finder no longer scans
  what Raw fallback will emit anyway.
- **mixed/random-32K went 2.4-3.6x → 1.15-1.38x**: the 4-lane histogram. On the ARM
  targets we sit at 1.15-1.18x, a few percent off the C's tuned level-1.
- **skewlit-32K/64K went 3.1-5.9x → 1.5-2.5x**: the histogram plus the skewlit
  lever (the lane's t3 fix).
- **words (entropy-heavy) improved ~10-15%**: the branch-free countStats kernel
  and the sequences-writer spill fix (aarch64 spill-free, x86 BMI2, both verified
  by disassembly in the pass).
- **The literal-heavy shapes regressed 1-3%, uniformly on all seven targets** —
  text/html/rle at both sizes. This is real, not noise: the compress noise floors
  are 0.22% (32K) and 0.58% (64K), and the intervals are disjoint (text-32K on
  c7a: 1.686-1.694 → 1.732-1.742). ~~The leading candidate is TE9's port price —
  the suspect-uncompressible sample now scans the first and last 4 KiB of every
  Compressed-literals block before the Huffman attempt, the same scan the C pays
  for its emission parity; the bits.zig restructure's code layout is the other.
  Neither was measured in isolation on these shapes; the next pass's ranked lever
  is to make that scan early-exit (stop at the first byte over the threshold, the
  C's own loop shape) or prove the cost lives elsewhere.~~ **Correction (the
  beat-everything pass, `8895881`)**: isolated pre/post-TE9 binaries disproved
  the TE9 attribution — text/html/rle blocks never reach the 40,960-literal
  threshold (html-64K carries 44 literals), so TE9's scan never runs on these
  shapes; the regression was code layout. The TE9 port's real cost, measured on
  the rows that do reach the path (mixed/random-64K, 0 sequences, always
  suspect-scanned): -1.5-1.9%. The early-exit lever itself was tried and
  reverted in that pass: the per-byte cap check costs more than the one final
  max scan. The recorded future design is a branchless running umax with a
  checkpointed compare every 512 bytes.

- **Size parity unchanged**: every encode row's frame is its `zstd -1`
  counterpart's size plus 4 bytes — 98 of 98 target/case pairs, the deterministic
  XXH64 trailer the C's default omits. Byte-identity remains the separate claim
  with its own evidence (`src/zstd/AGENTS.md`, the witness fixtures, and `just
  zstd-oracle`, which re-ran green after the pass).
- **One lever was reverted on measurement before this run**: the 4-lane
  `largestCount` (the suspect sample's max tracking) lost on 4-KiB samples
  (10.7 → 12.8 µs local on 64K mixed/random) and never flew.
