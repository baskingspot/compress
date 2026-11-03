# flate encode: the per-stream and per-tree clears, 2026-11-03

baskingspot/image's profile of its benchmark ops
(`docs/slop/results/memset-20261103.md` there) found `flate.Writer.initInPlace`
at about 1% of its Deflate encodes (TIFF strips, fast PNG): Zig 0.16 links
compiler_rt's `memset`, which stores a byte at a time, even into a program
that links libc, and LLVM turns a large zeroing into a call to it. In this
harness's binary there were two such calls in the encoder:

- `w.emitter = .empty` in `initInPlace` (and the one-shot encoders'
  `var emitter: dynamic.BlockWriter = .empty`): one `memset` of 8359
  bytes, the whole `BlockWriter` with its undefined scratch merged in,
  once a stream.
- `bitCounts`' `leaf_counts = @splat(@splat(0))`: a 1 KiB `memset` every
  time a Huffman tree is built, several times a block.

This change, in `src/flate/dynamic.zig`, `src/flate/Writer.zig`, and
`src/flate/encode.zig`, clears both with `fastmem.set`, as the finders and
`TokenList.clear` already do: `BlockWriter.reset` zeroes the writer's
bytes (every field `empty` sets is zero bytes; a test checks it), and
`leaf_counts` starts undefined and is filled. The encoder's output is
unchanged. After it, no flate encode function in this binary calls
`memset`.

Tests: `just test`, `just test-be` (s390x), `just lint`,
`just flate-oracle` (level 1 and level 6 byte parity), `just zlib-oracle`,
and `just gzip-oracle`, all exit 0.

## Method

`main.zig` encodes each strip of a TIFF as its own zlib stream with
`zlib.Writer.initInPlace`, as image's TIFF encoder does, at level 1, 6, or
7, the best of 9 timings. The inputs are the raw strips (predictor
residuals, about 8 KiB each) that image's benchmark TIFFs store, from the
strip files of `flate-short-streams-20261102.md`, decompressed. Built
ReleaseFast for this CPU against 025d176 (`base`) and this change (`new`);
`ab.sh` alternates them for 10 rounds, pinned to core 3, and benchstat
compares them (`bs-l1.txt`, `bs-l6.txt`, `bs-l7.txt`).

CPU: Intel Xeon Processor @ 2.60GHz, 4 vCPUs, AVX-512, a shared cloud
host; Linux 6.1, Zig 0.16.0.

## Results

Median of 10 rounds, MB/s of input:

| file                | level 1 base | new | speedup | level 6 base | new | speedup | level 7 base | new | speedup |
| ------------------- | ------------ | --- | ------- | ------------ | --- | ------- | ------------ | --- | ------- |
| icon 16×16          | 113          | 145 | 1.28×   | 24           | 25  | 1.07×   | 26           | 28  | 1.08×   |
| icon 64×64          | 362          | 399 | 1.10×   | 80           | 84  | 1.04×   | 70           | 73  | 1.04×   |
| water1 128×128      | 191          | 199 | 1.04×   | 61           | 62  | 1.03×   | 50           | 50  | 1.00×   |
| test card 256×256   | 740          | 877 | 1.18×   | 153          | 159 | 1.04×   | 131          | 137 | 1.05×   |
| kodim01 768×512     | 216          | 230 | 1.06×   | 51           | 51  | 1.01×   | 44           | 44  | 1.00×   |
| dice 800×600 (RGBA) | 414          | 447 | 1.08×   | 122          | 126 | 1.04×   | 102          | 105 | 1.03×   |

benchstat geomean: level 1 +12.3% (every file at p ≤ 0.002), level 6
+3.8%, level 7 +3.2% (kodim01 and, at level 7, water1 within noise; the
rest at p ≤ 0.024). No file slower. The gain is a fixed cost saved per
stream and per tree, so it is largest where a stream is cheap: small
strips and level 1.
