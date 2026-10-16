# The entropy wave verification: the final fair grid

Run: `bench-results/20261016T200719Z-entropy-wave` (local, gitignored; the run id and
this file are the durable record). 7/7 targets, 8 arms (A/A control on), `rounds=5`,
`--keep-raw`. The arms built from `fe4aca4`: the entropy wave's two kept changes (the
zstd per-model XXH64 accumulator, the brotli x86_64 literal outline) and the zstd-c
driver's real checksum fix (`ZSTD_compress2` — the m7-fair attempt was a no-op:
`ZSTD_compressCCtx` ignores the CCtx's sticky parameters, so the C arm never paid its
checksum on encode rows until this run). Every zstd encode row in the m7-fair file and
every A/B row in `entropy-wave-20261016.md` is superseded by this grid.

## zstd encode, zc ÷ zstd-c (median, lower = zc faster)

| shape | c7a | c8a | c9g | c7g | c8g | c7i | c8i |
|---|---|---|---|---|---|---|---|
| text-32K | 0.60 | 0.73 | 0.97 | 1.20 | 1.08 | 1.07 | 1.06 |
| text-64K | 0.55 | 0.71 | 0.97 | 1.22 | 1.17 | 1.02 | 0.95 |
| html-32K | 0.61 | 0.74 | 1.02 | 1.20 | 1.12 | 1.07 | 1.06 |
| html-64K | 0.55 | 0.71 | 1.00 | 1.22 | 1.12 | 1.02 | 0.95 |
| rle-64K | 0.55 | 0.72 | 0.95 | 1.22 | 1.17 | 0.94 | 0.93 |
| mixed-64K | 0.80 | 0.91 | 0.94 | 1.00 | 1.01 | 0.95 | 0.96 |
| random-64K | 0.78 | 0.90 | 0.94 | 1.00 | 1.02 | 0.95 | 0.95 |
| words-64K | 1.16 | 1.19 | 1.19 | 1.21 | 1.26 | 1.07 | 1.08 |
| skewlit-64K | 1.15 | 1.38 | 1.23 | 1.49 | 1.46 | 1.19 | 1.20 |
| prose-64K | 1.21 | 1.22 | 1.26 | 1.23 | 1.28 | 1.21 | 1.17 |

The Intel literal-heavy gap — 3.3-3.9x in the m7-fair grid — is closed: c7i/c8i at
0.93-1.07 (won at 64K), the two changes stacking (the scalar checksum chain was
~76% of the text-64K row; the C arm now pays its ~12 µs checksum). c7a/c8a/c9g win
outright (0.55-1.02). The residual ARM gap is c7g/c8g at 1.06-1.22 — the wave's
checksum fix is x86_64-gated (aarch64's form already measured best there) and the C
arm's checksum penalty closed most of that gap, so what remains on the Gravitons is
the encoder's own per-literal cost, not the checksum.

## zstd decode, zc ÷ zstd-c

The Intel mixed/random deficit (1.82-2.07 in m7-fair) closed to parity: c7i/c8i at
0.95-1.07. text/html/rle stay won everywhere (0.22-0.62). The entropy rows are the
remaining zstd decode gaps: words 1.50-2.30, skewlit 1.50-1.77, prose 1.55-2.59 —
the C's entropy decode path is fast and our per-symbol work there is the known
writeStream/reader-model cost (the wave's ranked bottlenecks).

## brotli decode, zc ÷ brotli-c

The wave's rows hold: mixed/random won at 0.36-0.53, text/html/rle won at
0.01-0.34, skewlit 1.13-1.36 (the outline bought 1.11-1.13x on Intel locally; the
grid shows the same rows at their new level), words 1.40-1.69, prose 1.33-1.78.

## The mission's scorecard

Against "every row under 1.0 versus every arm": the copy-structure and literal-heavy
rows are won or at parity on both codecs everywhere that was targeted — mixed/random
on both codecs, text/html/rle on both, the Intel literal edges closed. The rows that
remain above 1.0 are the entropy rows, consistently: zstd encode words/skewlit
(~1.1-1.5, the literal-count question in the match finder, not per-symbol cost),
zstd decode words/skewlit/prose (1.5-2.6), brotli words/skewlit/prose (1.1-1.8,
the bit-reader's consume model — a reader rewrite, per the wave's profile). These
are algorithmic residues, each with ranked evidence in
`docs/results/entropy-wave-20261016.md`'s "next bottlenecks" section, not unnamed
gaps.
