# flate levels 7 and 9 for PNG, 2026-11-01

baskingspot/image's PNG encoder compressed its filtered rows through
`zlib.encode` at level 6, and the output came out 1.6% larger than libpng's
in total, up to 2.5% on photographs. The filter choices matched libpng's, so
the gap was deflate: on the same filtered bytes, C zlib's level 6 with
`Z_FILTERED` was 3.7 to 9% smaller per file than our greedy level 6. The
branch `image-png-deflate` adds:

- `lazy.zig`: a hash-chain match finder with lazy evaluation, from RFC 1951
  §4. Chain heads on a 4-byte hash (`1 << 15` of them) plus one link per
  window position, 256 KiB; only the heads are cleared per stream. A held
  match is emitted when the next position's search finds nothing longer;
  otherwise the held position becomes a literal.
- `Level.@"7"` (32 candidates a search, lazy 16, nice 128, good 8) and
  `Level.@"9"` (1024, 258, 258, 32) over level 6's block emitter
  (`writeBlockFast`: the per-block stored/fixed/dynamic choice, so the
  `maxCompressedLength` bound holds unchanged), one-shot and in `Writer`
  (the lazy tables fit inside the level-6 member of the finder union, so a
  `Writer` does not grow).
- `Options.strategy`, `.filtered`: levels 7 and 9 code matches shorter than
  6 bytes as literals. Threaded through `zlib` and `gzip` options.
- FLEVEL 3 for both lazy levels in zlib's header, XFL 2 for level 9 in gzip's.

## Method

`/tmp/scratch/flab` (not committed, 60 lines): compress every file in a
directory through `flate.encode.compress` at each configuration, interleaved,
3 repetitions (5 for text), best time per configuration. ReleaseFast for the
host CPU, pinned with `taskset -c 2`. CPU: Intel Xeon Processor @ 2.60GHz
(4 vCPUs, a cloud VM). The PNG set is the filtered IDAT payload (filter byte
plus filtered row, before zlib) that image's encoder produces at its MSAD
filter choice for 43 files of its bench corpus: icons from 16×16 to 512×512,
screenshots, line art, and photographs up to 12 MP; 109,803,164 bytes. The
50-MP mosaic is left out for time. C zlib 1.2.13 through python3's `zlib`
(raw, `wbits=-15`) is the reference; its times include the Python call but
are dominated by the compression.

## Results

PNG filtered rows, 109.8 MB:

| configuration         | bytes      | of L6  | best time | MB/s  |
| --------------------- | ---------- | ------ | --------- | ----- |
| level 6               | 23,839,578 | 1.0000 | 0.716 s   | 153.4 |
| level 7               | 23,121,552 | 0.9699 | 1.705 s   | 64.4  |
| level 7, filtered     | 22,997,610 | 0.9647 | 1.843 s   | 59.6  |
| level 9, filtered     | 22,671,027 | 0.9510 | 6.330 s   | 17.3  |
| zlib 6                | 23,175,349 | 0.9721 | 3.326 s   | 33.0  |
| zlib 6, `Z_FILTERED`  | 23,056,181 | 0.9671 | 3.851 s   | 28.5  |
| zlib 9, `Z_FILTERED`  | 22,683,190 | 0.9515 | 14.563 s  | 7.5   |

Level 7 filtered is 0.25% smaller than zlib's level 6 `Z_FILTERED` at 2.1
times its speed; level 9 filtered is 0.05% smaller than zlib's level 9
`Z_FILTERED` at 2.3 times its speed.

Text (the seven vendored RFCs in `docs/specs/`, 594,371 bytes):

| configuration     | bytes   | of L6  | MB/s  |
| ----------------- | ------- | ------ | ----- |
| level 6           | 164,133 | 1.0000 | 107.5 |
| level 7           | 160,628 | 0.9786 | 43.9  |
| level 7, filtered | 163,635 | 0.9970 | 42.4  |
| level 9, filtered | 160,539 | 0.9781 | 13.1  |
| zlib 6            | 159,835 | 0.9738 |       |
| zlib 9            | 157,850 | 0.9617 |       |

On text the filtered strategy costs what it gains on PNG, as expected; the
default strategy is the one for general data.

## Tuning notes

On the PNG set, with level 7's chain: a minimum match of 5 or 6 was best
(6 by 0.1%), 4 and 7 worse. A chain of 1024 gave 22.67 MB in 5.8 s, no
better than level 9's lazy 258. Splitting blocks every 16K or 8K tokens, so
the Huffman codes follow the data more closely, made the output larger on
this set and would have broken the one-stored-header-per-65535 arithmetic
of `maxCompressedLength`, so blocks stay at 64 KiB of input as at level 6.

Levels 1 and 6 are unchanged: `just flate-oracle` still pins level 1's
bytes and checks level 6 against klauspost/compress byte for byte.

