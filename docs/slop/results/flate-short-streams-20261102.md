# flate.Reader: table builds and dynamic headers on short streams, 2026-11-02

baskingspot/image's TIFF decoder inflates libtiff's Deflate strips, one
zlib stream of about 8 KiB of output each, through `zlib.Reader`. On
those it ran at 0.93–0.95× libtiff past icon size, and libtiff inflates
with libdeflate 1.26. A profile of this harness over the strips of a
Kodak photo and a Wikipedia photo put 10.6% of the time in a block's
setup: the literal/length `HuffmanDecoder.build` 5.2%, the distance and
precode builds 1.4%, and `readDynamicHeader` 4.0%, besides Adler-32 at
2.1% (libdeflate: `build_decode_table` 6% of a faster total, Adler-32
1%). Within the literal/length build, counting the code lengths (twice:
once in `checkLengths`, once in `build`) and sorting the symbols by
length took about 70%, filling the table about 5%: each step bumped a
per-length counter in memory, so every symbol waited on the store of the
one before it with the same length.

This change, in `src/flate/decode.zig`, `src/flate/Reader.zig`, and
`src/zlib/adler32.zig`:

- `build` turns the lengths into one bit mask per code length, 64
  symbols to a word, with a vector compare per length and word. The masks'
  popcounts are the counts, which `checkCounts` (formerly `checkLengths`,
  now without its own counting pass) validates, and walking a length's set
  bits visits its symbols in canonical order, so there is no sort, no
  sorted array, and no `next_code` table. The table fill is unchanged.
- `BufferedBits`, the dynamic header's bit source over the input's
  buffered bytes, keeps a 64-bit bit buffer refilled eight bytes at a
  time, instead of loading eight bytes at a bit offset for every peek and
  again for every take.
- Adler-32 folds a block's 16-byte chunks with two vector additions each,
  a running sum of the bytes and a running sum of those sums, and weights
  them once per block (16·Σ prefix − Σ j·sum_j), instead of a widening
  multiply by per-chunk weights.

Rejected, measured by the same harness (3 runs, interleaved): a 12-bit
literal/length primary table (photos +2%, icons −2%), and moving the
literal/length symbol two bits up so the fast path shifts by the entry
itself, without masking the code length (+1%, inside the noise).

Tests: `zig build test` (725 tests; the `checkLengths` tests now go
through `build`, the public interface), `just lint`, `just ci`,
`just flate-oracle`, `just zlib-oracle`, and `just gzip-oracle` pass
(exit 0), and `just fuzz 500K` finds nothing. The flate, zlib, and gzip
tests (252) also pass on s390x under qemu: a bool vector's element 0 is
the most significant bit of the integer it casts to on a big-endian
target, so `build` reverses the mask words there. baskingspot/image's
big-endian tests caught it; this repository's CI compiles for no
big-endian target.

## Method

As in `flate-packed-entries-20261102.md`, with `infl.zig` extended: a
`.zs` file is records of a u32 little-endian length and a zlib stream,
and each stream is decoded with a fresh `zlib.Reader` over
`Io.Reader.fixed`, as the TIFF decoder decodes a strip. `strips.py`
extracts a TIFF's strips into one `.zs` file, `idat.py` a PNG's IDAT
into a `.z` file; the inputs are files of baskingspot/image's benchmark
corpus (`bench/corpus-gen/tiff/deflate`, written by libtiff's `tiffcp -c
zip` with its default 8 KiB strips, and the PNG originals). `ref.c` is
the same loop over libdeflate 1.26 (`libdeflate_zlib_decompress` into a
buffer, as libtiff calls it) or, with `-DWUFFS`, Wuffs 0.4's zlib
decoder. `build.sh` builds the harness ReleaseFast for this CPU against a
compress tree: 2e5eb6b (`base`) and this change (`new`). `ab2.sh` runs
base, new, libdeflate, and Wuffs in turn, 10 rounds, pinned to one core
(core 3 for the strips, core 2 for the PNG data), and writes Go
benchmark lines; benchstat compares them (`bs-zs.txt`, `bs-z.txt`).

CPU: Intel Xeon Processor @ 2.60GHz, 4 vCPUs, AVX-512, a shared cloud
host; Linux 6.1, Zig 0.16.0.

## Results: TIFF strips

Median of 10 rounds, MB/s of decompressed output:

| file                    | base | new | speedup | libdeflate | vs libdeflate | Wuffs | vs Wuffs |
| ----------------------- | ---- | --- | ------- | ---------- | ------------- | ----- | -------- |
| icon 16×16              | 152  | 211 | 1.39×   | 206        | 1.03          | 126   | 1.67     |
| icon 64×64              | 500  | 588 | 1.17×   | 597        | 0.98          | 389   | 1.51     |
| icon 512×512            | 716  | 921 | 1.29×   | 940        | 0.98          | 603   | 1.53     |
| kodim01 768×512         | 200  | 211 | 1.05×   | 277        | 0.76          | 180   | 1.17     |
| tecnick 1200×1200       | 294  | 317 | 1.08×   | 415        | 0.76          | 259   | 1.23     |
| wikipedia-001 1276×850  | 238  | 251 | 1.06×   | 331        | 0.76          | 214   | 1.17     |
| amazon.com 1313×6097    | 558  | 640 | 1.15×   | 547        | 1.17          | 439   | 1.46     |
| dice 800×600 (RGBA)     | 607  | 742 | 1.22×   | 662        | 1.12          | 526   | 1.41     |
| plant_02 1024×1316      | 482  | 598 | 1.24×   | 605        | 0.99          | 403   | 1.48     |

benchstat: −15.13% time geomean, every file at p = 0.000.

## Results: PNG image data

The same, over each PNG's whole IDAT stream:

| file                    | base | new  | speedup | libdeflate | vs libdeflate | Wuffs | vs Wuffs |
| ----------------------- | ---- | ---- | ------- | ---------- | ------------- | ----- | -------- |
| icon 16×16              | 179  | 239  | 1.33×   | 238        | 1.00          | 146   | 1.64     |
| icon 64×64              | 630  | 683  | 1.08×   | 792        | 0.86          | 502   | 1.36     |
| icon 512×512            | 1406 | 1506 | 1.07×   | 2466       | 0.61          | 1367  | 1.10     |
| button 64×64 (RGBA)     | 295  | 336  | 1.14×   | 376        | 0.90          | 228   | 1.48     |
| kodim01 768×512         | 270  | 276  | 1.02×   | 394        | 0.70          | 258   | 1.07     |
| wikipedia-001 1276×850  | 320  | 326  | 1.02×   | 453        | 0.72          | 296   | 1.10     |
| air_pump 999×772 (RGBA) | 1086 | 1159 | 1.07×   | 1889       | 0.61          | 997   | 1.16     |
| amazon.com 1313×6097    | 852  | 914  | 1.07×   | 1017       | 0.90          | 627   | 1.46     |
| dice 800×600 (RGBA)     | 957  | 995  | 1.04×   | 1486       | 0.67          | 979   | 1.02     |
| plant_02 1024×1316      | 741  | 781  | 1.05×   | 1109       | 0.70          | 718   | 1.09     |

benchstat: +8.63% throughput geomean, every file at p ≤ 0.003.

## What is left

On photographs' strips this decoder is at 0.76× libdeflate, and after
the build and header changes the setup is 6% of the time there (the
literal/length build 2.4%, the header 4%); the rest is the fast loop,
`flate.Reader.fill`, 88%, with no one line above 7% of it. On long streams libdeflate's lead
is larger (0.6–0.9×), and the same loop is the place to look.
