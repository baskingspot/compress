# Agent notes: bench

The benchmark harness: EC2 boxes, cross builds of compress and its competitors,
interleaved rounds, and exact-interval analysis. `README.md` is the operator
documentation.

## Provenance

The harness is a port of fastmem's (`~/code/fastmem-zig/bench/`; the design is
in `docs/bench-design.md` there). `ec2bench/` is copied from fastmem's and stays
free of benchmark-specific code. `compress_bench/` is the compress adapter.

Not ported from fastmem:

- `goals.py` (the G1-G6 gates) and `stability.py` (spike and process-share
  tables).
- `codegen.py` and the libc probes (fastmem kernel evidence).
- The dist and large suites.
- The runtime-dispatch machinery (compress has no dispatch).
- fastmem's `bench/tests` suite. The adapter has no tests of its own.

Where the competitor pins came from:

- libdeflate v1.26 and zlib-ng 2.3.3: the flate-family native competitors in
  `docs/slop/research/containers-notes.md` §6.3 and §6.4.
- google/snappy 1.3.1: the snappy competitor named in `docs/slop/plan.md`
  ("Benchmark methodology").
- zstd v1.5.7: the tag in `docs/slop/research/zstd-notes.md` §6.1.
- google/brotli v1.2.0: the tag in `docs/slop/research/brotli-notes.md` §8, the
  same tag as the flake's brotli CLI that writes the `.br` corpus streams
  (the CLI's q11 output is byte-identical to the tarball's encoder built
  with zig cc, FMA contraction on or off, and on wasm32-wasi).
- klauspost/compress `v1.18.1-0.20250402062133-8df4d013ff17`: commit 8df4d01 of
  the local research checkout (`~/code/klauspost-compress`, `v1.18.0-5-g8df4d01`
  in `docs/slop/research/zstd-notes.md` §6.2), pinned in
  `bench/drivers/klauspost/go.mod`.

## Design decisions

- The corpus shape list is repeated in `bench/zig/corpus.zig`,
  `bench/zig/bench_compress.zig`, `bench/compress_bench/jsonl.py` (twice),
  `bench/drivers/c/cbench.h`, `bench/drivers/klauspost/main.go`,
  `src/zstd/bench.zig`, and `src/brotli/bench.zig`. A new shape updates all
  of them and `bench/corpus/SHA256SUMS` in the same commit.
- The codec list is repeated in `bench/zig/bench_compress.zig` (`codecs`,
  `blobExt`, `carries`, `codecDirections`), `bench/drivers/c/cbench.h`
  (`blob_ext`, `CBENCH_CODEC_HAS_DIRECTION`), and
  `bench/compress_bench/jsonl.py` (`Sample.codec`, `STD_SKIPS`, `applicable`).
  A new codec updates all of them. A codec or direction that an
  implementation in a binary does not carry must be excluded in `applicable`,
  or every round fails the sample-set check at round 0. The level and
  streaming rows (`flate6`, `zstd3`, `brotli-stream`) are codec tokens too:
  they are compress-only, share their base codec's reference blob, and the
  std rows skip them (STD_SKIPS) because std's rows are the level-1 class.
- The corpus anchor is append-only. A new reference blob appends its rows
  after the existing ones, in the order the generator hashes them (the
  sorted `.zst` rows, then the sorted `.br` rows), and no existing row
  changes.
- brotli-c allocates from a bump arena (`bench_brotli.c`). The library has
  no decoder reset, and `BrotliDecoderDecompress` makes 4 to 10 malloc/free
  pairs per stream on this corpus (52 to 114 KiB, measured with a counting
  allocator). The arena keeps musl's allocator out of the timed loop, the
  way the other native arms keep allocation out by reusing their contexts.
