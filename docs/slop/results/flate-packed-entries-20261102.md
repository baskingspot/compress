# flate.Reader: whole symbols from packed table entries, 2026-11-02

After `flate-fast-inflate-20261101.md`, `flate.Reader` inflated PNG image
data at 0.67–1.10× Wuffs, and inflate was still 75–86% of a PNG decode in
baskingspot/image. A profile of that decode put the rest of the gap in
three places: each fast-path symbol took a table load, then a second
lookup of its length or distance base and extra-bit count; a literal run
took a refill per two literals; and on icons, whose zlib streams are a
few hundred bytes, the dynamic header and the table build were a third
of the decode (the 1024-entry table was filled with `invalid` before
every build). The branch `image-perf-inflate` changes, in
`src/flate/decode.zig` and `src/flate/Reader.zig`:

- The literal/length and distance tables' entries are 32 bits. The low
  16 bits keep `symbol << 4 | code_len`, which the slow path and the long
  code chains read as before. Above them a literal/length entry has a
  literal flag (bit 31), an exceptional flag (bit 30: end of block, a
  reserved symbol, a chained long code, or no code), the bits the code and
  its extra bits take together (bits 16–20), and the length base (bits
  21–29). A distance entry has the distance base (bits 16–30), the
  exceptional flag (bit 31), and the total bits beside its 5-bit symbol.
  One load decodes a whole symbol; the precode table stays 16 bits.
- The fast loop decodes up to four literals from one refill while the
  next entry is a literal and the bits last, and `fast_room` grows to
  the longest match plus 16 + 8 bytes.
- The literal/length primary table is 11 bits. It is built a code length
  at a time: the filled prefix of 2^len slots is copied up to double it,
  then each code of the next length takes its one slot, so no slot is
  written more than once a doubling and there is no fill of the whole
  table first. Codes longer than the table are chained afterwards.
- A dynamic block's header is parsed from the input's buffered bytes with
  a local bit buffer (`BufferedBits`, out of line in `readDynamicHeader`)
  when enough is buffered, falling back to `Bits` when it runs short.

The rejected variants, all measured slower by the same method: a pattern
copy for distances under 8 and a byte broadcast for distance 1 (slower on
the RGBA images, whose short distances are 4), a separate literal loop,
and decoding one or two literals per refill instead of four.

Tests: `zig build test` (718 tests), the test "Reader: the fast path
decodes what the slow path decodes" included; `just flate-oracle`,
`just zlib-oracle`, and `just gzip-oracle` pass (exit 0).

## Method

As in `flate-fast-inflate-20261101.md`: `infl.zig` (here, with
`build.zig`, `build.sh`, and `idat.py`) extracts a PNG file's IDAT data and
decodes it through `zlib.Reader` over `Io.Reader.fixed`, draining with
`peekGreedy` and `toss`, and keeps the best of 9 timings of a loop of
about 30 MB of output. Built ReleaseFast for this CPU against fd03d72
(`base`) and this branch (`new`); `wuffs.c` is the same loop over Wuffs
0.4's zlib decoder. `run.sh` runs base, new, and Wuffs in turn, 10 rounds,
pinned to core 1 (`taskset -c 1`), and writes Go benchmark lines;
benchstat compares them.

CPU: Intel Xeon Processor @ 2.60GHz (3.3 GHz under load), 4 vCPUs,
AVX-512, a shared cloud host; Linux 6.1, Zig 0.16.0.

Inputs are files of baskingspot/image's benchmark corpus: icons at 16,
64, and 512 pixels, a Kodak photo, the 50-megapixel mosaic, a Wikipedia
photo, a web screenshot, two images with alpha, and a texture.

## Results

Median of 10 rounds, MB/s of decompressed output:

| file                       | fd03d72 | this branch | speedup | Wuffs | vs Wuffs |
| -------------------------- | ------- | ----------- | ------- | ----- | -------- |
| icon 16×16                 | 107     | 166         | 1.55×   | 156   | 1.06     |
| icon 64×64                 | 347     | 551         | 1.59×   | 562   | 0.98     |
| icon 512×512               | 1146    | 1439        | 1.26×   | 1555  | 0.93     |
| kodim01 768×512            | 178     | 257         | 1.45×   | 295   | 0.87     |
| mosaic 8192×6144           | 319     | 451         | 1.41×   | 445   | 1.01     |
| wikipedia-001 1276×850     | 225     | 314         | 1.39×   | 340   | 0.92     |
| air_pump 999×772 (RGBA)    | 808     | 1091        | 1.35×   | 1128  | 0.97     |
| amazon.com 1313×6097       | 562     | 815         | 1.45×   | 733   | 1.11     |
| dice 800×600 (RGBA)        | 698     | 946         | 1.35×   | 1104  | 0.86     |
| plant_02 1024×1316 (RGBA)  | 492     | 724         | 1.47×   | 809   | 0.90     |

benchstat: −29.82% time geomean, every file at p = 0.000 (`bs.txt`);
against Wuffs the branch is 4.2% slower geomean (`bs-wuffs.txt`), from
14% faster (amazon.com) to 14% slower (dice). The tables' memory grows
from 2 KiB to 8 KiB for the literal/length table (1024 16-bit entries to
2048 32-bit ones) and from 1 KiB to 2 KiB for the 9-bit distance table;
the `Reader`'s state is that much larger, and no buffer the caller passes
changes size.

In baskingspot/image the branch moves PNG decode from 0.79× Wuffs to
about 0.94× together with that repository's conversion change
(`docs/slop/results/png-perf-20261102.md` there).

## Raw output

`base.txt`, `new.txt`, and `wuffs.txt`: one line per file and round, the
best-of-9 ns per decode and MB/s. `bs.txt`: benchstat base against new.
`bs-wuffs.txt`: new against Wuffs.
