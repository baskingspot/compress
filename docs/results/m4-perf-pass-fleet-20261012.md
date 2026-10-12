# The post-perf-pass fleet run: the zstd decoder's keepers, adjudicated

Run: `bench-results/20261012T031758Z-m4-perf-pass` (local, gitignored; the run
id and this file are the durable record). 7/7 targets, 6 arms, 750 rows per
target (5,250 total), `rounds=5`, no failures, the expected arm-scope
coverage warnings only. Outlier rounds flagged and retained (c9g/c8g 12,
c7i 11, c8a/c8i 8, c7g 2, c7a 0). A/A noise floors 0.9997-1.0020.

- Arms: `zc` (zcompress, HEAD 4749961 — the perf pass's keepers + Matt's
  accumulator restructure), `klauspost` v1.18.1-pinned, `libdeflate` 1.26,
  `zlib-ng` 2.3.3, `google/snappy` 1.3.1, `zstd-c` v1.5.7 — the M4 set
  unchanged except the zc arm's code.
- Protocol: the M3/M4 shape — seeded balanced Latin square, last-core
  isolation, per-round corpus-hash verification, exact intervals.
- Corpus: the committed-anchor generated corpus (`just corpus`; the lane's
  correctness gate caught and fixed the burn-down's remote-contract
  regression before the run — fa641b2).

## The verdict: every target improved

zstd decode, zcompress ÷ zstd-c (lower = we're faster), M4 → post-pass:

| target | M4 | post-pass | |
|---|---|---|---|
| c7g (neoverse_v1) | 0.70 | 0.65 | improved |
| c8g (neoverse_v2) | 0.59 | 0.58 | improved |
| c9g (neoverse_v3) | 0.71 | 0.57 | improved |
| c7a (znver4) | 0.51 | 0.41 | improved |
| c8a (znver5) | 0.84 | 0.69 | improved |
| c7i (sapphirerapids) | 1.16 | **1.01** | parity |
| c8i (graniterapids) | 1.30 | 1.16 | improved, remains behind |

The Intel gap — the pass's primary target — closed to parity on Sapphire
Rapids; Granite Rapids improved 11% and is the last target behind the C
reference (1.16). The ARM/AMD targets all improved: the Graviton line to
0.57-0.65 (up to 1.75x faster than the reference), and both Zen generations
improved with the AVX-512 fold gate active — znver4 to 0.41 (2.4x faster),
znver5 to 0.69 — so the flip-gate question is answered: the AVX-512 path is
a win on both Zen generations, no flip.

Against the rest of the pinned set (post-pass): klauspost 0.20-0.79
(behind nearly everywhere), std 0.27-0.68 (behind everywhere).

## What moved it (the pass's keepers, now claims)

The fleet corpus is checksum-dominated (the profile found the XXH64 fold at
74-83% of decode on these shapes), so the fold's in-context collapse —
root-caused to LLVM SLP packing the four independent lanes into two serial
SVE2 chains, pinned with barriers and the 4-stripe unroll (9.35 → 18.5-19.5
GB/s in-situ) — carried the ARM/Graviton rows. The Intel movement is the
BMI2-shaped bit readers + the AVX-512DQ vector fold (vpmullq/vpaddq/vprolq,
4 vector ops per stripe) + the generic wins. The entropy-path keepers (the
four-stream fused literals decode, the cached bit-reader container, the
fused sequence cells, the in-place State init) are exercised lightly by
this corpus (predefined tables, few sequences) — the synthetic entropy
corpus showed 1.6-2.7x there, and the next codec-shaped corpus revision
will see them in fleet rows.

## Remaining, ranked

- Granite Rapids at 1.16 — the last target behind the C reference; the
  Huffman double-symbol tables (our ~1.4 vs their 0.5-0.6 ns/symbol,
  sized and evidenced in the pass) are the known next lever.
- The raw-copy/hash interplay and the match doubling-copy (~5% of
  match-heavy frames) — flagged, not opened.

## Provenance

- Run id `20261012T031758Z-m4-perf-pass`, executed 2026-10-12, artifacts
  under `bench-results/20261012T031758Z-m4-perf-pass/` (trimmed to the
  non-regenerable evidence post-analysis: the raw round JSONL, the
  summaries, the manifests; the bins/corpus regenerate from the pins).
- Correctness gate PASS x 42 (6 arms x 7 targets) in
  `bench-results/20261012T031737Z-test`.
- Reproduce: `just bench-up`, `just bench-run --rev <rev>`, `just b analyze
  ../bench-results/<run-dir>` (see bench/README.md).
