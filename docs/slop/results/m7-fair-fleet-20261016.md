# The m7-fair fleet run: the zstd grid re-baselined on checksums

Run: `bench-results/20261016T081446Z-m7-fair` (local, gitignored; the run id and this
file are the durable record). 7/7 targets, 7 arms, `rounds=5`, the A/A control on,
`--keep-raw` (the first attempt's record was lost to a mistaken `just b analyze` over
its cleaned directory — the command now refuses, and this run kept its rows). The
arms built from `d97643e`: the checksum-fair drivers. The zc frame form — content
size plus the 4-byte XXH64 trailer — is now paid by every zstd arm:
`ZSTD_c_checksumFlag` on the zstd-c CCtx, `WithEncoderCRC(true)` on klauspost. The
unfair grids (`m5-perf-pass2` and everything before it) are superseded on every zstd
encode row; the decode rows were always fair (the corpus frames carry checksums) and
move only within noise.

One run-dir loss, recorded: `20261016T073414Z-m7-fair` completed with the full grid
printed, then its summary.json and report.md were overwritten by the analyze command
over its raw-rows-deleted state. The re-run is the record. The guard is
`bench: analyze refuses a run with no raw rows`.

## zstd encode, zc ÷ zstd-c (median, lower = zc faster)

| shape | c7a | c8a | c9g | c7g | c8g | c7i | c8i |
|---|---|---|---|---|---|---|---|
| words-32K | 1.20 | 1.26 | 1.20 | 1.22 | 1.28 | 1.08 | 1.12 |
| words-64K | 1.18 | 1.22 | 1.22 | 1.24 | 1.29 | 1.10 | 1.13 |
| skewlit-32K | 1.26 | 1.52 | 1.33 | 1.57 | 1.55 | 1.38 | 1.39 |
| skewlit-64K | 1.29 | 1.53 | 1.33 | 1.56 | 1.55 | 1.40 | 1.40 |
| text-32K | 1.37 | 1.54 | 2.04 | 1.96 | 2.06 | 3.41 | 3.39 |
| text-64K | 1.38 | 1.69 | 2.30 | 2.14 | 2.35 | 3.88 | 3.55 |
| html-32K | 1.38 | 1.54 | 2.09 | 1.95 | 1.91 | 3.37 | 3.33 |
| html-64K | 1.39 | 1.70 | 2.27 | 2.13 | 2.33 | 3.89 | 3.44 |
| rle-32K | 1.42 | 1.59 | 2.14 | 1.98 | 2.06 | 3.46 | 3.54 |
| rle-64K | 1.44 | 1.71 | 2.35 | 2.16 | 2.38 | 3.61 | 3.47 |
| mixed-32K | 1.14 | 1.17 | 1.17 | 1.14 | 1.14 | 1.33 | 1.34 |
| mixed-64K | 1.34 | 1.35 | 1.45 | 1.40 | 1.40 | 1.89 | 1.91 |
| random-32K | 1.14 | 1.17 | 1.17 | 1.13 | 1.14 | 1.33 | 1.34 |
| random-64K | 1.31 | 1.33 | 1.50 | 1.41 | 1.39 | 1.85 | 1.87 |

- The fairness closed part of the literal-heavy gap and confirmed where the rest
  lives: the c7a rows improve to 1.37-1.44 (the checksum is ~35% of that class's
  encode time on ARM, and the C arm now pays it), but the Intel targets stay at
  3.3-3.9 on text/html/rle — a code-layout or ISA-specific edge the local box
  cannot see, still the named target for an Intel-side profile.
- The 64K rows sit above the 32K rows on mixed/random across the board — the
  per-block fixed costs amortize worse at 64K; the M5 pass's register-resident scan
  closed most of this once, the rest is block-boundary work.

## zstd encode, zc ÷ klauspost

| shape | c7a | c8a | c9g | c7g | c8g | c7i | c8i |
|---|---|---|---|---|---|---|---|
| words-32K | 0.70 | 0.72 | 0.64 | 0.72 | 0.72 | 0.75 | 0.77 |
| words-64K | 0.71 | 0.72 | 0.63 | 0.73 | 0.72 | 0.75 | 0.77 |
| skewlit-32K | 8.26 | 11.70 | 9.73 | 13.85 | 14.62 | 8.08 | 8.05 |
| skewlit-64K | 8.93 | 12.48 | 9.87 | 15.75 | 16.89 | 8.60 | 8.55 |
| text-32K | 0.49 | 0.58 | 0.73 | 0.85 | 0.85 | 1.02 | 1.08 |
| text-64K | 0.49 | 0.66 | 0.80 | 0.95 | 1.00 | 1.10 | 1.16 |
| html-32K | 0.38 | 0.42 | 0.54 | 0.63 | 0.60 | 0.80 | 0.86 |
| html-64K | 0.42 | 0.52 | 0.64 | 0.81 | 0.79 | 0.95 | 1.02 |
| rle-32K | 0.72 | 1.05 | 1.18 | 1.42 | 1.38 | 1.55 | 1.63 |
| rle-64K | 0.61 | 0.95 | 1.04 | 1.32 | 1.31 | 1.40 | 1.47 |
| mixed-32K | 3.66 | 4.61 | 4.58 | 5.61 | 5.64 | 4.31 | 4.33 |
| mixed-64K | 1.59 | 1.77 | 1.53 | 2.01 | 2.25 | 2.35 | 2.37 |
| random-32K | 3.65 | 4.58 | 4.49 | 5.60 | 5.59 | 4.36 | 4.34 |
| random-64K | 1.53 | 1.75 | 1.57 | 2.02 | 2.23 | 2.31 | 2.32 |

klauspost pays its checksum now too. The entropy-heavy shapes are not
a contest at this level: klauspost's SpeedFastest walks every symbol
through its entropy path, and zc is 4-17x faster on skewlit and 1.5-5.6x
faster on mixed/random. The literal-heavy shapes are where klauspost
lives: text/html at 0.38-1.16 with every ARM target a zc win, the Intel
targets at parity to 1.16 behind — the same ISA edge the zstd-c table
names. rle splits (0.61-1.63). words stays a zc win everywhere
(0.63-0.77).

The first draft of this table was written from the m5-era grid from
memory and was wrong on most rows; the numbers above are derived from
the run's `klauspost/zc` rows, inverted. The spot-check that caught it
is why tables are derived, never recalled.

## zstd decode, zc ÷ zstd-c (control: fair before and after)

text/html/rle stay won everywhere (0.22-0.86); words 1.59-2.30, skewlit
1.53-1.78, mixed/random 0.56-2.07 with the 64K rows near parity on Graviton
(0.91-1.00) and behind on Intel (1.82-2.07) — within noise of the m6-era grids.
The M5 register's decode findings stand; the checksum change touched encode rows
only.

## brotli decode, zc ÷ brotli-c (control for this run)

The M6 grid reproduced within noise on every row (rle 0.11-0.48, text/html
0.45-1.24 with the 64K rows 0.45-0.65, words 2.35-2.80, skewlit 2.93-4.00,
mixed/random 5.9-12.8) — the dictionary milestone's code cost the brotli decoder
nothing, and the m7-fair run is the pre-wave baseline for the brotli perf wave's
verification run.

## Follow-ups

- The brotli wave's fixes (the byte-drain mechanism, the split root table, the
  bit_count promotion) landed at `8b92adf` after this run; its verification run
  supersedes this grid's brotli rows.
- The zstd Intel literal-heavy gap (3.3-3.9 encode) is the remaining named target;
  the local box cannot profile an Intel ISA, so the fix needs a profile from an
  Intel fleet box or a targeted disassembly comparison.
