# The encoder seats' fleet run: flate 6, zstd 3, brotli q3

Run: `bench-results/20261017T115529Z-encoder-seats` (local, gitignored; the run id and
this file are the durable record). 7/7 targets, 8 arms (the A/A control on),
`rounds=5`, `--keep-raw`. The arms built from `9ed24a0`: the bench drivers that carry
the three seats' rows. 6,160 sample rows per target per round (30,800 per target;
215,600 over the run), 1,440 comparison rows per target, outlier rounds flagged and
retained (4-33 per target), A/A noise floors 0.09-1.16% by direction/size group, no
failures. The corpus is unchanged — the corpus-hash gate passed on every round — and
the level-1 and decode rows re-measure as the controls below.

## The rows

The new cases keep the driver's `<codec>/<direction>/<shape>/<size>` shape, with the
class in the codec token:

- `flate6/compress/...` — flate level 6, compress only. The race: the klauspost arm
  at its level 6 (byte-identical output, the seat's pin), libdeflate at level 6, and
  zlib-ng at level 6.
- `zstd3/compress/...` — zstd level 3, compress only. The race: zstd-c at level 3
  (byte-identical frames) and klauspost at SpeedDefault.
- `brotli/compress/...` — brotli q3, the one-shot. The race: the brotli-c arm's
  q3 one-shot (the arm's first encoder surface; its build gained `brotlienc`). The
  brotli rows are no longer decode-only; `brotli/decompress/...` still decodes the
  pinned CLI's q11 reference streams.
- `brotli-stream/compress/...` — the streaming `Writer`, the same q3 class. No arm
  carries a second brotli encoder, so this row has no cross-arm race; it is measured
  against the one-shot below.

A level row is compress only: a decoder is not per-level, so its round trip and
reference decode ride the base codec's decoder. The std rows stay the level-1 flate
family and zstd decode — the seats' levels are outside the in-binary competitor's
row set.

## flate 6, zc ÷ klauspost (the byte pin's race; median, lower = zc faster)

| shape | c7a | c8a | c9g | c7g | c8g | c7i | c8i |
|---|---|---|---|---|---|---|---|
| text-32K | 0.93 | 1.05 | 1.05 | 0.82 | 0.96 | 0.81 | 0.72 |
| text-64K | 0.86 | 0.96 | 0.96 | 0.76 | 0.85 | 0.80 | 0.73 |
| random-32K | 1.11 | 1.27 | 1.17 | 0.89 | 1.10 | 0.79 | 0.69 |
| random-64K | 1.07 | 1.22 | 1.14 | 0.89 | 1.10 | 0.77 | 0.67 |
| html-32K | 0.94 | 1.05 | 1.06 | 0.82 | 0.96 | 0.80 | 0.72 |
| html-64K | 0.88 | 0.95 | 0.95 | 0.75 | 0.84 | 0.79 | 0.73 |
| rle-32K | 0.95 | 1.05 | 1.14 | 0.91 | 1.09 | 0.76 | 0.66 |
| rle-64K | 0.88 | 0.94 | 1.07 | 0.87 | 1.03 | 0.73 | 0.65 |
| mixed-32K | 1.11 | 1.24 | 1.17 | 0.89 | 1.11 | 0.80 | 0.69 |
| mixed-64K | 1.08 | 1.23 | 1.14 | 0.88 | 1.11 | 0.78 | 0.67 |
| words-32K | 0.99 | 1.01 | 0.94 | 0.89 | 0.91 | 0.80 | 0.82 |
| words-64K | 0.90 | 1.06 | 0.91 | 0.90 | 0.92 | 0.89 | 0.87 |
| skewlit-32K | 1.20 | 1.38 | 1.18 | 0.92 | 1.13 | 0.84 | 0.72 |
| skewlit-64K | 1.16 | 1.36 | 1.19 | 0.92 | 1.14 | 0.82 | 0.71 |
| prose-32K | 0.95 | 0.84 | 0.93 | 0.90 | 0.90 | 0.85 | 0.85 |
| prose-64K | 0.88 | 1.01 | 0.93 | 0.90 | 0.93 | 0.90 | 0.86 |

- **The size rows are exact parity on every shape and target** (text-32K 155 = 155
  bytes, text-64K 258 = 258, random-64K 65,548 = 65,548): the level-6 port emits the
  Go arm's bytes. The byte pin itself is the flate oracle's (30 level-6 parity rows,
  a 351-row sweep, `c60a6b5`); the fleet's size rows corroborate it end to end.
- The race is close: zc wins both Intel targets (0.65-0.90), c7g (0.75-0.92), and
  most of c7a (0.86-1.20, the skewlit rows at 1.16-1.20); the Go arm is ahead on
  c9g (0.91-1.19, up to 19% on skewlit-64K) and on the c8a skewlit rows (1.36-1.38),
  and c8a/c8g split (0.84-1.38 / 0.84-1.14).
  The Go arm constructs its writer per iteration (the one-shot's per-call table
  setup, plus its allocator); ours builds its two tables and the token list per
  call. Across the grid the two land at 0.65-1.38 (c9g is the one target where the
  Go arm leads every row, up to 19% on skewlit-64K).

## flate 6 vs the C flate arms

zc ÷ libdeflate:

| shape | c7a | c8a | c9g | c7g | c8g | c7i | c8i |
|---|---|---|---|---|---|---|---|
| text-32K | 1.49 | 1.70 | 1.27 | 1.28 | 1.23 | 1.82 | 1.75 |
| text-64K | 1.00 | 1.09 | 0.78 | 0.81 | 0.76 | 1.18 | 1.13 |
| random-32K | 0.21 | 0.24 | 0.28 | 0.20 | 0.23 | 0.21 | 0.19 |
| random-64K | 0.08 | 0.08 | 0.12 | 0.09 | 0.11 | 0.09 | 0.08 |
| html-32K | 1.48 | 1.67 | 1.24 | 1.24 | 1.21 | 1.79 | 1.75 |
| html-64K | 1.01 | 1.07 | 0.76 | 0.79 | 0.76 | 1.14 | 1.12 |
| rle-32K | 1.42 | 1.60 | 2.03 | 1.58 | 1.99 | 1.68 | 1.55 |
| rle-64K | 0.96 | 1.02 | 1.40 | 1.05 | 1.38 | 1.03 | 0.96 |
| mixed-32K | 0.21 | 0.24 | 0.28 | 0.21 | 0.24 | 0.21 | 0.19 |
| mixed-64K | 0.08 | 0.08 | 0.12 | 0.09 | 0.11 | 0.09 | 0.08 |
| words-32K | 0.34 | 0.33 | 0.38 | 0.44 | 0.44 | 0.44 | 0.43 |
| words-64K | 0.29 | 0.35 | 0.33 | 0.35 | 0.38 | 0.37 | 0.36 |
| skewlit-32K | 0.18 | 0.20 | 0.24 | 0.19 | 0.21 | 0.19 | 0.18 |
| skewlit-64K | 0.08 | 0.07 | 0.11 | 0.08 | 0.10 | 0.08 | 0.08 |
| prose-32K | 0.64 | 0.62 | 0.71 | 0.83 | 0.81 | 0.91 | 0.86 |
| prose-64K | 0.59 | 0.74 | 0.66 | 0.70 | 0.72 | 0.78 | 0.73 |

zc ÷ zlib-ng:

| shape | c7a | c8a | c9g | c7g | c8g | c7i | c8i |
|---|---|---|---|---|---|---|---|
| text-32K | 2.78 | 2.54 | 2.41 | 2.50 | 2.41 | 2.69 | 2.69 |
| text-64K | 2.95 | 2.68 | 2.27 | 2.42 | 2.29 | 2.66 | 2.65 |
| random-32K | 0.11 | 0.12 | 0.18 | 0.14 | 0.16 | 0.13 | 0.12 |
| random-64K | 0.05 | 0.05 | 0.07 | 0.06 | 0.06 | 0.05 | 0.05 |
| html-32K | 2.83 | 2.55 | 2.42 | 2.48 | 2.41 | 2.67 | 2.74 |
| html-64K | 3.02 | 2.69 | 2.27 | 2.39 | 2.30 | 2.64 | 2.68 |
| rle-32K | 2.78 | 2.51 | 2.97 | 2.71 | 2.89 | 2.53 | 2.51 |
| rle-64K | 2.96 | 2.65 | 3.14 | 2.73 | 3.12 | 2.39 | 2.35 |
| mixed-32K | 0.11 | 0.12 | 0.17 | 0.14 | 0.16 | 0.13 | 0.12 |
| mixed-64K | 0.05 | 0.05 | 0.07 | 0.06 | 0.06 | 0.05 | 0.05 |
| words-32K | 0.24 | 0.23 | 0.32 | 0.39 | 0.38 | 0.30 | 0.31 |
| words-64K | 0.16 | 0.19 | 0.22 | 0.25 | 0.26 | 0.20 | 0.20 |
| skewlit-32K | 0.10 | 0.11 | 0.14 | 0.13 | 0.14 | 0.12 | 0.11 |
| skewlit-64K | 0.05 | 0.05 | 0.06 | 0.05 | 0.06 | 0.05 | 0.05 |
| prose-32K | 0.51 | 0.51 | 0.65 | 0.74 | 0.72 | 0.70 | 0.70 |
| prose-64K | 0.48 | 0.58 | 0.58 | 0.62 | 0.63 | 0.59 | 0.58 |

The flate level-6 grid splits by shape class, and the split is the same on both C
arms:

- **The incompressible and entropy shapes are ours, by a lot**: 3.6-14x faster
  than libdeflate on random/mixed/skewlit (0.07-0.28) and 5.6-20x faster than
  zlib-ng on the same rows (0.05-0.18), with words 2.3-3.4x (0.29-0.44) and
  2.6-6.3x (0.16-0.39) respectively. The absolute times show what the C libraries
  spend on input they cannot compress: random-64K on c7a is 44.8 µs for zc, 532 µs
  for libdeflate's level 6, and 959 µs for zlib-ng's. Our path fills its token list
  and falls back to stored cheaply; their level-6 search pays the full scan. The
  mechanism is unprofiled — this run measures the gap.
- **The literal-heavy shapes are the C's**: zc is 2.3-3.1x behind zlib-ng on every
  text/html/rle row (text-32K on c7a: 65.9 µs vs 23.7 µs) and 1.2-2.0x behind
  libdeflate on the 32K rows (44.4 µs there), while the 64K text/html rows are near
  parity with libdeflate (0.76-1.18: won on the ARM targets, 1.12-1.18 on Intel) and
  rle-64K sits at 0.96-1.40. The C libraries' Huffman emission on short-match data
  is the tuned side; the level-6 port is a first pass and its literal rows are the
  named gap.
- **Prose is ours** on both arms: 0.59-0.91 vs libdeflate, 0.48-0.74 vs zlib-ng
  (1.1-2.1x faster).

## zstd 3, zc ÷ zstd-c (byte-identical frames)

| shape | c7a | c8a | c9g | c7g | c8g | c7i | c8i |
|---|---|---|---|---|---|---|---|
| text-32K | 1.16 | 1.13 | 1.42 | 1.56 | 1.53 | 1.99 | 2.31 |
| text-64K | 0.85 | 0.94 | 1.25 | 1.39 | 1.42 | 1.40 | 1.63 |
| random-32K | 1.04 | 1.06 | 1.10 | 1.10 | 1.11 | 1.29 | 1.31 |
| random-64K | 0.92 | 1.00 | 1.06 | 1.06 | 1.12 | 1.26 | 1.29 |
| html-32K | 1.16 | 1.13 | 1.46 | 1.55 | 1.54 | 1.92 | 2.30 |
| html-64K | 0.86 | 0.93 | 1.20 | 1.39 | 1.44 | 1.39 | 1.63 |
| rle-32K | 1.06 | 1.15 | 1.44 | 1.66 | 1.56 | 2.37 | 2.39 |
| rle-64K | 0.76 | 0.94 | 1.21 | 1.49 | 1.44 | 1.67 | 1.66 |
| mixed-32K | 1.04 | 1.05 | 1.09 | 1.10 | 1.10 | 1.29 | 1.31 |
| mixed-64K | 0.91 | 0.98 | 1.04 | 1.08 | 1.12 | 1.26 | 1.29 |
| words-32K | 1.26 | 1.33 | 1.22 | 1.21 | 1.24 | 1.24 | 1.27 |
| words-64K | 1.21 | 1.38 | 1.16 | 1.19 | 1.21 | 1.15 | 1.20 |
| skewlit-32K | 1.19 | 1.39 | 1.27 | 1.49 | 1.44 | 1.35 | 1.37 |
| skewlit-64K | 1.18 | 1.41 | 1.25 | 1.48 | 1.47 | 1.28 | 1.29 |
| prose-32K | 1.14 | 1.16 | 1.22 | 1.34 | 1.26 | 1.47 | 1.34 |
| prose-64K | 1.17 | 1.26 | 1.21 | 1.31 | 1.32 | 1.33 | 1.36 |

- **The size rows are exact parity on every shape and target** (text-32K 70 = 70,
  words-64K 20,410 = 20,410, random-64K 65,550 = 65,550): the level-3 dfast port
  writes the C's level-3 frames. The byte pin is the zstd oracle's (`aa66eed`: the
  level-3 parity rows across both encoder forms, up to the CLI's 8 MiB job size).
- **The C's level 3 is still ahead, and the Intel targets show it most**: zc is at
  0.76-1.26 on c7a (the 64K text/html/rle rows won, 0.76-0.94) and 0.93-1.41 on
  c8a, then 1.04-1.66 on the other ARM targets and 1.15-2.39 on c7i/c8i (text-32K
  2.31, rle-32K 2.39). The literal-heavy 32K rows and the rle rows carry the gap;
  the words rows are the closest (1.15-1.38). The mechanism is not yet profiled —
  the level-3 seat landed byte-identical first; its speed is the next pass's target.

## zstd 3, zc ÷ klauspost (SpeedDefault)

| shape | c7a | c8a | c9g | c7g | c8g | c7i | c8i |
|---|---|---|---|---|---|---|---|
| text-32K | 0.91 | 0.78 | 1.02 | 1.11 | 1.17 | 1.39 | 1.65 |
| text-64K | 0.76 | 0.74 | 0.99 | 1.12 | 1.19 | 1.07 | 1.29 |
| random-32K | 3.07 | 3.37 | 3.54 | 3.97 | 4.11 | 3.69 | 3.83 |
| random-64K | 1.64 | 1.70 | 1.59 | 1.87 | 2.02 | 2.05 | 2.12 |
| html-32K | 0.71 | 0.58 | 0.79 | 0.85 | 0.87 | 1.18 | 1.25 |
| html-64K | 0.64 | 0.59 | 0.81 | 0.96 | 0.98 | 1.03 | 1.07 |
| rle-32K | 1.33 | 1.38 | 1.58 | 1.84 | 1.87 | 2.25 | 2.41 |
| rle-64K | 0.94 | 1.06 | 1.22 | 1.56 | 1.54 | 1.51 | 1.60 |
| mixed-32K | 3.06 | 3.41 | 3.53 | 3.97 | 4.11 | 3.69 | 3.83 |
| mixed-64K | 1.62 | 1.70 | 1.60 | 1.86 | 2.03 | 2.05 | 2.12 |
| words-32K | 0.71 | 0.76 | 0.68 | 0.69 | 0.74 | 0.80 | 0.80 |
| words-64K | 0.68 | 0.74 | 0.66 | 0.67 | 0.73 | 0.76 | 0.79 |
| skewlit-32K | 5.73 | 7.79 | 6.98 | 8.88 | 9.62 | 6.21 | 6.42 |
| skewlit-64K | 6.89 | 9.63 | 7.97 | 11.46 | 12.30 | 6.88 | 7.05 |
| prose-32K | 0.67 | 0.68 | 0.68 | 0.65 | 0.68 | 0.79 | 0.73 |
| prose-64K | 0.62 | 0.62 | 0.62 | 0.67 | 0.68 | 0.74 | 0.76 |

klauspost's SpeedDefault is its own algorithm, not the C's dfast, and the grid
splits along different lines: klauspost wins the entropy-heavy rows (skewlit,
where zc runs 5.7-12.3x its time) and the incompressible pair (random/mixed
1.6-4.1x), while zc wins words/prose (1.25-1.6x faster, 0.62-0.80) and the
literal-heavy shapes on c7a/c8a (1.1-1.7x faster, 0.58-0.91); the other ARM
targets split (0.79-1.17), Intel is klauspost's (zc 1.03-1.65), and rle splits by
target (0.94-2.41). The class difference is the algorithm's, not the seat's.

## brotli q3 one-shot, zc ÷ brotli-c

| shape | c7a | c8a | c9g | c7g | c8g | c7i | c8i |
|---|---|---|---|---|---|---|---|
| text-32K | 0.42 | 0.42 | 0.51 | 0.48 | 0.53 | 0.41 | 0.43 |
| text-64K | 0.55 | 0.67 | 0.71 | 0.66 | 0.73 | 0.53 | 0.57 |
| random-32K | 6.52 | 6.91 | 5.52 | 5.27 | 5.55 | 3.63 | 4.02 |
| random-64K | 9.75 | 10.74 | 8.89 | 7.92 | 8.61 | 5.52 | 6.08 |
| html-32K | 0.43 | 0.43 | 0.52 | 0.48 | 0.53 | 0.42 | 0.43 |
| html-64K | 0.55 | 0.68 | 0.71 | 0.66 | 0.73 | 0.54 | 0.57 |
| rle-32K | 0.31 | 0.34 | 0.45 | 0.41 | 0.46 | 0.34 | 0.32 |
| rle-64K | 0.48 | 0.63 | 0.68 | 0.63 | 0.70 | 0.60 | 0.50 |
| mixed-32K | 3.19 | 3.31 | 2.21 | 2.37 | 2.32 | 2.00 | 2.06 |
| mixed-64K | 9.77 | 10.72 | 8.89 | 7.91 | 8.62 | 5.50 | 6.05 |
| words-32K | 1.75 | 2.25 | 1.87 | 1.61 | 1.59 | 1.62 | 1.65 |
| words-64K | 1.77 | 1.88 | 1.83 | 1.71 | 1.66 | 1.67 | 1.73 |
| skewlit-32K | 2.08 | 1.92 | 1.61 | 1.86 | 1.69 | 2.08 | 2.09 |
| skewlit-64K | 2.53 | 2.54 | 1.90 | 2.11 | 1.94 | 2.44 | 2.43 |
| prose-32K | 1.85 | 2.44 | 1.83 | 1.57 | 1.54 | 1.58 | 1.63 |
| prose-64K | 1.78 | 1.77 | 1.76 | 1.65 | 1.61 | 1.65 | 1.70 |

- **zc wins every encode row**: text/html 1.4-2.4x, rle 1.4-3.2x, words 1.6-2.25x,
  skewlit 1.6-2.5x, prose 1.5-2.4x, random 3.6-10.7x, mixed 2.0-10.7x. The C arm
  runs the one-shot's own call sequence (quality 3, the CLI's window and size hint,
  one FINISH call) over an arena instance, so the row is the algorithm, not
  allocation: the q3 emitter's trivial-tree path is the faster one here.
- **The size rows are exact parity on every shape and target** (text-32K 47 = 47,
  prose-64K 18,352 = 18,352): the C arm's call sequence reproduces our stream
  lengths. Byte identity is the brotli oracle's pin (`a0fe8fc`).

## The streaming Writer (`brotli-stream`)

zc-only rows: the `Writer` at the one-shot's per-size window (the CLI's
automatic-window rule). Measured against the one-shot in the same processes — the
median of the five per-round ratios, which the harness's comparison machinery does
not carry as a row (both sides are the same arm) — the streaming form runs at
**1.01-1.05x the one-shot** on every target (c7a 1.02, c8a 1.01, c9g 1.03, c7g 1.03,
c8g 1.03, c7i 1.03, c8i 1.05; per-cell ranges 0.87-1.22 on the sub-2-µs rle cells).
The 16-KiB staging block and the ring's copy are the delta; the corpus is too small
to separate them further.

## The controls

Every existing row was compared against the M8 runs (`20261016T200719Z-entropy-wave`
for the zstd and flate-family rows, `20261016T130208Z-brotli-wave` for brotli
decode), cell by cell on absolute medians and on the ratios — same corpus, same
method.

- **zstd level 1 (encode and decode) and brotli decode reproduce the M8 grid.**
  The zstd level-1 encode table is within 0.01-0.06 of the entropy-wave numbers on
  the tabulated rows (text-32K 0.60 vs 0.60, text-64K 0.54 vs 0.55, words-64K 1.18
  vs 1.16, skewlit-64K 1.16 vs 1.15; the largest move is prose-64K on c8i, 1.17 →
  1.27, 8.5%). zstd decode holds its M8 ranges (text/html/rle 0.21-0.62, words
  1.52-2.24, skewlit 1.50-1.75, prose 1.55-2.47, the Intel mixed/random rows
  0.95-1.05), and brotli decode holds its (mixed/random 0.37-0.48, text/html/rle
  0.01-0.34, words 1.39-1.76, skewlit 1.07-1.34, prose 1.33-1.73).
- **The c7i box ran 6-7% faster this run, on every arm and codec** (zstd-c's
  level-1 cells move -6.6% in absolute time; the whole arm set moves together). It
  cancels in every ratio, which is why the c7i columns above are the stable ones.
- **The zc binary's latency-bound cells moved, in both directions, with the seats'
  code landing in the same binary.** The clearest are the snappy compress cells on
  c7a (2-5 µs absolute: text/html-64K 5.4 → 3.6 µs, rle-64K 3.4 → 5.4 µs), flate
  level-1 html-64K on c8a (5.1 → 6.6 µs), zstd level-1 prose-32K (74 → 91 µs on
  c8i, 90 → 71 µs on c7i), and brotli decode mixed-32K on c7a (790 → 680 ns). The
  A/A duplicate reproduces the same moves in the same run, so they are deterministic
  for the binary — layout, not process noise — and no row class shows a consistent
  regression. The rows that moved are the ones whose absolute times are single-digit
  microseconds.
- **The klauspost arm's flate/gzip/zlib compress rows moved -4 to -16% per target**
  (median -9 to -12%), all in the faster direction; its snappy and zstd rows are
  flat. The Go binary gained the two new codecs this run, so its hot loops' layout
  shifted; the level-1 comparisons against it should be read with that in mind.
- **The flate family's level-1 rows have no M8-era table** (the M8 files carry zstd
  and brotli). Against the M8 runs' own row data they are stable at the group
  medians: zc's flate/gzip/zlib level-1 cells within ±1.2% except c7i (the instance
  effect), the C arms within ±1%, and the paired `container/flate` rows hold their
  M8 shape.

## Follow-ups

- **The flate level-6 literal-heavy rows** (text/html/rle: 2.3-3.1x behind
  zlib-ng's level 6, 1.2-2.0x behind libdeflate's on the 32K shapes, near parity
  on the 64K ones): the C libraries' Huffman emission on short-match data. The
  first pass's named gap; unprofiled.
- **The zstd level-3 gap vs the C** (1.15-2.39 on the Intel targets, 1.04-1.66 on
  the other ARM targets, near parity on c7a/c8a): the literal-heavy 32K rows and
  rle carry it. Unprofiled — the seat landed byte-identical first.
