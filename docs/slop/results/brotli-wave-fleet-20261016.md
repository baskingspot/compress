# The brotli decode perf wave: the drain, the promotion, the split root table

Run: `bench-results/20261016T130208Z-brotli-wave` (local, gitignored; the run id and this
file are the durable record). 7/7 targets, 8 arms (the A/A control on, so zc runs twice),
`rounds=5`, `--keep-raw` (three runs died getting here — the record below names them).
The arms built from `7f942f8`: the brotli wave's decoder changes over the m7-fair
baseline, plus the corpus's new `prose` shape (a 64-KiB prefix of the vendored RFC 7932,
quality 11, the first natural-text row — real prose exercises context modeling and
block switching at scale, which no synthetic shape did) and the checksum-fair zstd
drivers of the m7-fair grid, so the zstd rows re-verify as a control.

The three dead runs, for the record: `124032` died on the corpus-hash gate (the drivers'
hand-copied shape lists lacked prose — the gate refused a silently prose-less run, which
is its job); `124422` died one arm-round in (the harness's own shape copy — `jsonl.py`'s
`SHAPES` — was the fourth stale copy; the run's in-process validator rejected every
target's first round meta after libdeflate's r0); and the re-analysis of `124422`
correctly reported "No complete rounds" over the interrupted tree. The shape set is
copied in five places (the generator, the zig driver, `cbench.h`, the Go driver, the
harness validator) — the corpus-hash gate and the Meta validator each caught one stale
copy, which is the design working, and the comment at each copy now names them all.

## The mechanism, found and fixed

mixed/random was 6-13x behind with the mechanism unidentified since M6. The mechanism:
the uncompressed payload's byte drain gated its loop on the bit accumulator's count and
used `take(8)` — but `take` refills the accumulator from the source, so the gate
re-armed every byte and the payload drained through the bit reader one byte at a time,
never reaching the bulk copy; the refill also left the accumulator holding bytes past
the point a later `pull` attaches at, which `rewind` cannot represent — the assert the
fuzz caught on a tiny-chunk input (pinned as a regression in `fuzz.zig`, verified by
reverting the fix and watching the pin fire). The drain now captures the byte count on
entry and empties exactly those bytes with `takeLoaded` (never refills), leaving the
accumulator empty so the bulk copy runs.

## brotli decode, zc ÷ brotli-c (median, lower = zc faster)

| shape | c7a | c8a | c9g | c7g | c8g | c7i | c8i |
|---|---|---|---|---|---|---|---|
| mixed-32K | 0.46 | 0.43 | 0.40 | 0.38 | 0.43 | 0.41 | 0.44 |
| mixed-64K | 0.47 | 0.46 | 0.41 | 0.42 | 0.44 | 0.44 | 0.46 |
| random-32K | 0.46 | 0.42 | 0.40 | 0.36 | 0.42 | 0.41 | 0.43 |
| random-64K | 0.48 | 0.45 | 0.41 | 0.38 | 0.43 | 0.42 | 0.44 |
| words-32K | 1.57 | 1.49 | 1.39 | 1.55 | 1.54 | 1.69 | 1.69 |
| words-64K | 1.56 | 1.53 | 1.42 | 1.47 | 1.48 | 1.68 | 1.72 |
| skewlit-32K | 1.28 | 1.25 | 1.19 | 1.27 | 1.15 | 1.53 | 1.38 |
| skewlit-64K | 1.22 | 1.26 | 1.21 | 1.20 | 1.13 | 1.47 | 1.36 |
| prose-32K | 1.37 | 1.37 | 1.34 | 1.43 | 1.43 | 1.80 | 1.78 |
| prose-64K | 1.44 | 1.38 | 1.36 | 1.44 | 1.46 | 1.59 | 1.62 |
| text-32K | 0.23 | 0.23 | 0.34 | 0.25 | 0.32 | 0.25 | 0.28 |
| text-64K | 0.13 | 0.12 | 0.19 | 0.14 | 0.18 | 0.14 | 0.16 |
| html-32K | 0.23 | 0.23 | 0.33 | 0.24 | 0.31 | 0.24 | 0.27 |
| html-64K | 0.13 | 0.12 | 0.19 | 0.14 | 0.17 | 0.14 | 0.16 |
| rle-32K | 0.02 | 0.01 | 0.02 | 0.03 | 0.02 | 0.02 | 0.02 |
| rle-64K | 0.01 | 0.01 | 0.01 | 0.02 | 0.01 | 0.02 | 0.02 |

The M6 grid's verdict is inverted. mixed/random — 6-13x behind, mechanism unknown — is
now **won at 0.36-0.48 on every target**: the C decoder always copies out of its ring;
the fixed bulk path is a straight `fastmem` through the one-shot. text/html improved
from 0.45-1.24 to 0.12-0.34 (the bit-reader work pays everywhere), rle from 0.11-0.48
to 0.01-0.03. The entropy rows: words 2.3-2.8x → 1.39-1.72, skewlit 2.9-4.0x →
1.13-1.53 (the split root table: the inlined single-peek fast path plus the outlined
subtable, consumes as `takeLoaded` — no second refill; and `bit_count` widened u7 to
u64 so the field promotes in the hot loops). prose, the natural-text row, lands at
1.34-1.80 — a first measurement, not a claim.

The remaining gaps are the entropy rows: words ~1.4-1.7x (the static-dictionary
transform path), skewlit ~1.15-1.53x, prose ~1.35-1.8x (worse on Intel, 1.6-1.8) —
the same ISA edge the zstd grid names.

## The zstd control

The zstd rows re-measured within noise of the m7-fair grid on every shape (text-32K
encode 1.37/3.42 here vs 1.37/3.41 there): the brotli decoder's changes cost the zstd
rows nothing, and the checksum-fair drivers hold.

## Follow-ups

- The words/skewlit/prose entropy rows are the remaining brotli gaps — the dictionary
  transform path and the Intel literal edge.
- The M6-era geomean caveat stands: the corpus's mix is copy-heavy; no headline beyond
  the rows.
