# The wave-2 fleet run: the corpus revision's first fleet appearance

Run: `bench-results/20261012T090216Z-wave2` (local, gitignored; the run id and
this file are the durable record). 7/7 targets, 6 arms, 14-shape corpus (the
revision's `words` + `skewlit` at level 19 riding the original five), `rounds=5`,
zero errors, the trimmed run-dir shape (facts + manifest + raw only). The
correctness gate `bench-results/20261012T090216Z-test` passed PASS x 42 — the
first gate genuinely covering all 14 shapes on every arm (the wave's first
launch caught the C drivers' stale `s < 5` loop bounds — fixed in 7f4d7bf —
before any run).

**A measurement lesson recorded here**: the first per-shape extraction of
this run's raw rows (by the parent, before this file) mixed the zc arm's
`std` impl samples into the medians — std's zstd decoder runs ~2.4 ms/op on
skewlit (69x slower than ours), and the median of poisoned samples produced
phantom 50x ratios. The impl-filtered numbers below are the real ones; the
analysis scripts must key on `(arm, impl)`, never arm alone.

## The verdict: the old shapes flat, the new shapes measured

**The old five shapes: flat vs the wave-1 run** (per-shape medians, 32K;
the full table below; the wave-1 numbers in
`m4-perf-pass-fleet-20261012.md`'s run): text/html/rle 0.23-0.85 (we lead
nearly everywhere), mixed/random 0.62 on Zen to 1.9 on Intel — every cell
within ±0.05 of wave-1. The lean-reader keeper does not touch these paths
(level-1 frames: predefined tables, light literals), and the wave's local
±6-14% movements on mixed/random/words were layout dice, as the fleet now
confirms — the zero-changed-code rows moved the same amount locally.

**The new shapes (the first fleet measurement of the custom-entropy paths,
which before wave 1's pass were 4-11x behind the C locally):**

| shape | c7g | c8g | c9g | c7a | c8a | c7i | c8i |
|---|---|---|---|---|---|---|---|
| words-32K | 1.86 | 1.54 | 1.36 | 1.87 | 1.85 | 1.65 | 2.03 |
| skewlit-32K | 1.62 | 1.63 | 1.53 | 1.72 | 1.57 | 1.60 | 1.65 |

zcompress ÷ zstd-c (lower = faster): the C leads the custom-entropy shapes
1.4-2.2x everywhere. Wave 1's entropy work (the fused four-stream literals,
the cached bit-reader container) plus wave 2's lean reader brought this
deficit from 4-11x to 1.4-2.2x — the C's remaining edge is its per-symbol
loop on deep custom trees (max_bits 7: the X2 double-symbol experiment,
built complete and measured in wave 2, showed X2 is not the answer — the
C built both ways gains only ~10% from X2; its speed is the loop shape).

**rle on Granite Rapids confirmed in fleet**: 1.10-1.11 on c8i (vs 0.23-0.62
everywhere else) — the C's `ZSTD_overlapCopy8` offset-1 match-fill path
doubling on GNR's fill/store hardware, exactly the wave-2 c8i-oddity
analysis from the raw JSONL. The match-overlap copy (the C's
seed-then-stride dec32/dec64 tables vs our doubling's per-chunk call
overhead) is the designed-not-implemented lever.

**The biggest old-shape gap on Intel**: mixed/random at 1.77-1.91 on
c7i/c8i — the raw-block copy+fold interplay (our copy and the XXH64 fold
fight for the same bytes; the sanctioned interleaved-fold shape is written
down in the wave-2 report).

## Ranked, end of wave 2 (fleet-evidenced)

1. The match-overlap copy (rle c8i 1.10, words' Zen rows 1.85-2.0 — the
   offset-1/short-offset matches are the common thread).
2. The raw-block copy+fold interleave (mixed/random Intel 1.8-1.9).
3. The custom-entropy per-symbol residue (words/skewlit 1.4-2.2 — the
   C's loop shape; X2 retired with evidence).
4. The FSE/sequences loop over the lean-reader shape (its own campaign).

## Provenance

- Run id `20261012T090216Z-wave2`, executed 2026-10-12, artifacts under
  `bench-results/20261012T090216Z-wave2/` (trimmed shape).
- Codec under test byte-identical to 7679cfa (7f4d7bf is harness-only).
- Reproduce: `just bench-up`, `just bench-test`, `just bench-run --suite
  standard --rounds 5`, `just b analyze ../bench-results/<run-dir>`.
