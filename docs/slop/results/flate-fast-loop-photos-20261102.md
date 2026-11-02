# flate.Reader: the fast loop on photographs, 2026-11-02

After `flate-short-streams-20261102.md`, inflate on a photograph's TIFF
strips ran at 0.76× libdeflate 1.26, with 88% of the time in the fast
loop (`fastSymbols`, inlined into `flate.Reader.fill`) and no line of it
above 7%. Its disassembly showed the loop spilling: the input slice's
base pointer, the distance table pointer, the reach, and on the match
path the bit buffer itself, stored and reloaded between the length and
the distance. This change, in `src/flate/Reader.zig`, reads the input
through a cursor, `ip`, instead of `in[pos..]`, so the loop holds no base
pointer for the input slice beside the index. Each load stays behind the
same bound check as before, now on the cursor's address.

Rejected, measured by the same harness (3 interleaved runs each unless
noted):

- Copying a match's first two 16-byte chunks unconditionally (distance
  16 or more), then looping from 32: most matches end inside 32 bytes,
  and the loop's exit after one chunk mispredicts. With the cursor it
  measured +6% on photographs' strips here (10 rounds), about 3 points
  more than the cursor alone, and the 256×256 test card's strips still
  inflated 10–20% faster alone. But in baskingspot/image's TIFF decode
  the test card's two rows were 3–4% slower than before, in two
  `bench-compare` runs and in a direct interleaved run (median 531 MP/s
  against 553 before, the cursor alone 553), so the gain did not survive
  inlining into a real caller. Taking the second chunk only at distances
  of 32 or more, where its source cannot overlap the first chunk's
  store, cost the 128×128 water texture's strips 4% in the same decode.
- Refilling and looking up the next symbol's entry before a match's
  copy, so that a mispredicted branch in the copy does not discard the
  lookup: 1–2% faster on most files, but 12% slower on the water
  texture's strips (10 rounds), which image's bench-compare flagged at
  0.94.
- Two unconditional 8-byte chunks for distances of 8 to 15: 1% faster
  elsewhere, 5% slower on the water texture.
- An output cursor as well, `fastSymbols` out of line, the
  literal/length and distance tables behind one pointer, and a third
  unconditional 16-byte chunk: no change.
- Entries whose low 6 bits are the bits to consume, so that
  `bits >> entry` needs no field extraction on the match path: 2%
  slower.
- An 8-byte-word copy for distances under 8: up to 43% slower on runs of
  distance 1, where it steps a byte at a time.

Tests: `just test`, `just test-be` (s390x), `just lint`,
`just flate-oracle`, `just zlib-oracle`, and `just gzip-oracle`, all
exit 0, and `just fuzz` with no findings.

## Method

The harness of `flate-short-streams-20261102.md` (`infl.zig`, `ref.c`,
`build.sh`, `strips.py`, `idat.py` there), on the same inputs plus the
water texture and the test card: TIFF Deflate strips (`.zs`) and PNG
IDAT streams (`.z`) from baskingspot/image's benchmark corpus. Built
ReleaseFast for this CPU against 364ef40 (`base`) and this change
(`new`). `ab2.sh` runs base, new, libdeflate, and Wuffs in turn, 10
rounds, pinned to core 3; benchstat compares them (`bs-zs.txt`,
`bs-z.txt`, `bs-tc.txt`), and `table.py` gives the medians below.

CPU: Intel Xeon Processor @ 2.60GHz, 4 vCPUs, AVX-512, a shared cloud
host; Linux 6.1, Zig 0.16.0.

## Results: TIFF strips

Median of 10 rounds, MB/s of decompressed output:

| file                   | base | new  | speedup | libdeflate | vs libdeflate | Wuffs | vs Wuffs |
| ---------------------- | ---- | ---- | ------- | ---------- | ------------- | ----- | -------- |
| icon 16×16             | 243  | 244  | 1.00×   | 242        | 1.01          | 146   | 1.68     |
| icon 64×64             | 679  | 680  | 1.00×   | 697        | 0.98          | 454   | 1.50     |
| icon 512×512           | 1076 | 1116 | 1.04×   | 1105       | 1.01          | 710   | 1.57     |
| water1 128×128         | 420  | 457  | 1.09×   | 529        | 0.86          | 297   | 1.54     |
| test card 256×256      | 2437 | 2696 | 1.11×   | 1793       | 1.50          | 1218  | 2.21     |
| test card 256×256 RGBA | 2156 | 2522 | 1.17×   | 1871       | 1.35          | 1167  | 2.16     |
| kodim01 768×512        | 245  | 254  | 1.03×   | 324        | 0.78          | 210   | 1.20     |
| tecnick 1200×1200      | 370  | 383  | 1.04×   | 486        | 0.79          | 302   | 1.27     |
| wikipedia-001 1276×850 | 295  | 304  | 1.03×   | 386        | 0.79          | 248   | 1.23     |
| amazon.com 1313×6097   | 748  | 777  | 1.04×   | 639        | 1.22          | 510   | 1.52     |
| dice 800×600 (RGBA)    | 868  | 902  | 1.04×   | 781        | 1.15          | 615   | 1.47     |
| plant_02 1024×1316     | 693  | 710  | 1.02×   | 705        | 1.01          | 474   | 1.50     |

benchstat: +3.31% throughput geomean over the first ten files (the
photographs +3.2–3.6%, the water texture +9.0%, all at p ≤ 0.004), the
test cards +10.6% and +17.0% (p < 0.001); the 16×16 and 64×64 icons
within noise (p ≥ 0.39); no file slower.

## Results: PNG image data

| file                    | base | new  | speedup | libdeflate | vs libdeflate | Wuffs | vs Wuffs |
| ----------------------- | ---- | ---- | ------- | ---------- | ------------- | ----- | -------- |
| icon 16×16              | 278  | 278  | 1.00×   | 276        | 1.01          | 167   | 1.67     |
| icon 64×64              | 791  | 793  | 1.00×   | 928        | 0.85          | 587   | 1.35     |
| icon 512×512            | 1776 | 1846 | 1.04×   | 2946       | 0.63          | 1611  | 1.15     |
| button 64×64 (RGBA)     | 388  | 389  | 1.00×   | 438        | 0.89          | 265   | 1.47     |
| kodim01 768×512         | 325  | 333  | 1.02×   | 461        | 0.72          | 299   | 1.11     |
| wikipedia-001 1276×850  | 378  | 393  | 1.04×   | 522        | 0.75          | 346   | 1.14     |
| air_pump 999×772 (RGBA) | 1358 | 1438 | 1.06×   | 2216       | 0.65          | 1172  | 1.23     |
| amazon.com 1313×6097    | 1067 | 1104 | 1.03×   | 1218       | 0.91          | 734   | 1.50     |
| dice 800×600 (RGBA)     | 1154 | 1217 | 1.05×   | 1738       | 0.70          | 1151  | 1.06     |
| plant_02 1024×1316      | 901  | 940  | 1.04×   | 1302       | 0.72          | 838   | 1.12     |

benchstat: +3.03% throughput geomean; the larger files +2.4–5.8% at
p ≤ 0.002; the 16×16 and 64×64 icons and the button within noise
(p ≥ 0.47); no file slower.

## What is left

Photographs' strips are at 0.78–0.79× libdeflate, and whole PNG streams
at 0.63–0.91×. This harness has no hardware counters (a cloud VM), so
the rest of the gap is not attributed: the experiments that cut the
loop's critical path in instructions did not move it, which points at
branch mispredictions between literals and matches rather than latency.
