# flate.Reader's fast path, 2026-11-01

`flate.Reader` decoded one Huffman symbol per `step`, each bit read through
`Bits.peek` and `take` against the input `Io.Reader`. On PNG image data
that ran at 85–340 MB/s, a third of Wuffs's speed, and was 75–100% of a PNG
decode in baskingspot/image. The branch `image-png-inflate` adds:

- `fastSymbols`: while the input has 16 bytes buffered and the window 274
  bytes free, whole symbols (literals, and matches with their extra bits)
  decode from a local 64-bit bit buffer loaded straight from the input's
  buffered bytes. The refill is branchless and leaves at least 56 bits,
  the widest length code, length extra bits, distance code, and distance
  extra bits together. After a literal, a second symbol is decoded from the
  same refill when 15 bits remain. Matches at distance 16 or more copy 16
  bytes at a time, 8 or more 8 at a time, writing up to 15 bytes past the
  match into the free window; shorter distances keep `copyMatch`. It stops
  only between symbols and writes the input position and the consumed-bit
  count back, so the slow path resumes exactly where it left off, and it
  makes every check the slow path makes (reserved symbols, distances past
  the output's start).
- `Bits.peek` reads its 8-byte window with one `readInt` when 8 bytes are
  buffered, instead of `readVarInt`; a dynamic header's code lengths are
  read through it (not measured on its own).
- The literal/length table's primary lookup is 10 bits instead of 9.
- `HuffmanDecoder.resolve` and `mask`, for decoding from a caller's bits.

The test "Reader: the fast path decodes what the slow path decodes" decodes
level-1 and level-6 streams with matches at every distance class, the Go
golden streams, and 80 corrupted copies through a fixed reader (fast path)
and a one-byte reader (slow path only), and requires the same bytes or the
same error. baskingspot/image's PNG oracle (libpng, libspng, Wuffs) ran
20,000 fuzzed PNGs and the 305 corpus files through it with 0 mismatches,
and its PNG fuzz target ran 620,000 inputs with no findings.

## Method

`/tmp/infl` (not committed; it is 60 lines): extract the IDAT data of a PNG
file, then decode it 15 times through `zlib.Reader` over `Io.Reader.fixed`,
draining with `peekGreedy` and `toss`, and keep the best time. Built
ReleaseFast for the host CPU against two source trees, `v0` (v0.2.0,
18476dc) and `v9` (this branch), and run interleaved v0, v9, v0, v9, ...
7 times per file, pinned to one core (`taskset -c 3`). The figure is the
median of the 7 best-of-15 numbers, in MB/s of decompressed output. Wuffs
0.4 and zlib 1.3 (`uncompress`) ran the same files the same way, once.

CPU: Intel Xeon Processor @ 2.60GHz, 4 vCPUs, AVX-512, a shared cloud host
whose runs swing by up to 30% between processes (the brackets show every
run), Linux 6.1, Zig 0.16.0.

Inputs are files of baskingspot/image's benchmark corpus: a Kodak photo, the
50-megapixel photo mosaic, a long web screenshot, a 512-pixel icon, and a
plant texture with alpha.

## Results

| file (output size)           | v0.2.0 | this branch | speedup | Wuffs  | zlib  |
| ---------------------------- | ------ | ----------- | ------- | ------ | ----- |
| kodim01 768×512 (1.2 MB)     | 88.3   | 199.0       | 2.25×   | 288.6  | 184.1 |
| mosaic 8192×6144 (151 MB)    | 159.1  | 465.7       | 2.93×   | 480.0  | 277.2 |
| amazon.com 1313×6097 (32 MB) | 337.5  | 892.9       | 2.65×   | 812.3  | 457.3 |
| icon 512×512 (1.0 MB)        | 546.1  | 1280.1      | 2.34×   | 1648.9 | 703.7 |
| plant 1024×1316 (5.4 MB)     | 227.4  | 596.8       | 2.62×   | 893.6  | 512.1 |

The branch is 2.25–2.93× faster than v0.2.0, faster than zlib on every
file, and from 0.67× (plant, kodim01) to 1.10× (amazon.com) Wuffs. What
is left against Wuffs is literal-heavy data: Wuffs decodes literals from a
wider table with the bits for two at once.

Interleaved runs that chose the details (same method, 5–7 rounds, four
files without the mosaic): a 10-bit primary table beat 9 bits by 5–35%
(the screenshot and the texture most) and 11 bits was within noise of 10,
so 10 avoids the bigger table build on small streams; decoding a second
literal per refill and, when the bits allow, going straight on to its match
won 5–7% on the icon and the photo and tied on the texture; 8-byte copies for distances 8 to 15 were neutral;
`fastmem.copy` in place of array assignment for the 16- and 8-byte chunks
was neutral, and the repository's rule asks for it.

## Raw output

v0 against v9, median then every run, MB/s:

```
icon_512-actions_address_book_new-512x512.png v0 546.1   [531.7 546.0 551.9 546.1 558.1 712.9 538.7]
icon_512-actions_address_book_new-512x512.png v9 1280.1   [1224.4 1280.1 1249.7 1285.0 1539.3 1645.6 1232.1]
photo_kodak-kodim01-768x512.png v0 88.3   [98.6 81.6 103.8 83.9 98.8 88.3 81.1]
photo_kodak-kodim01-768x512.png v9 199.0   [192.5 192.3 258.0 199.0 237.4 257.7 191.3]
photo_mosaic-50mp-8192x6144.png v0 159.1   [169.2 165.7 159.1 149.8 154.4 171.6 129.8]
photo_mosaic-50mp-8192x6144.png v9 465.7   [474.2 474.3 460.1 480.1 431.3 401.1 465.7]
screenshot_web-amazon_com-1313x6097.png v0 337.5   [253.8 255.6 338.8 339.2 337.5 305.8 340.0]
screenshot_web-amazon_com-1313x6097.png v9 892.9   [725.0 966.6 962.3 747.2 896.6 725.4 892.9]
textures_plants-plant_02-1024x1316.png v0 227.4   [230.7 278.5 227.4 227.1 235.1 227.4 227.1]
textures_plants-plant_02-1024x1316.png v9 596.8   [590.7 597.6 595.2 688.7 714.6 596.8 595.5]
```

Wuffs and zlib:

```
photo_kodak-kodim01-768x512.png wuffs 288.6 MB/s zlib 184.1 MB/s (1180160 1180160)
photo_mosaic-50mp-8192x6144.png wuffs 480.0 MB/s zlib 277.2 MB/s (151001088 151001088)
screenshot_web-amazon_com-1313x6097.png wuffs 812.3 MB/s zlib 457.3 MB/s (32027541 32027541)
icon_512-actions_address_book_new-512x512.png wuffs 1648.9 MB/s zlib 703.7 MB/s (1049088 1049088)
textures_plants-plant_02-1024x1316.png wuffs 893.6 MB/s zlib 512.1 MB/s (5391652 5391652)
```
