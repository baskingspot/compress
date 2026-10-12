# Agent notes: bench

The benchmark harness: EC2 boxes, cross builds of zcompress and its competitors,
interleaved rounds, and exact-interval analysis. `README.md` is the operator
documentation.

## Provenance

The harness is a port of fastmem's (`~/code/fastmem-zig/bench/`; the design is
in `docs/bench-design.md` there). `ec2bench/` is copied from fastmem's and stays
free of benchmark-specific code. `zcompress_bench/` is the zcompress adapter.

Not ported from fastmem:

- `goals.py` (the G1-G6 gates) and `stability.py` (spike and process-share
  tables).
- `codegen.py` and the libc probes (fastmem kernel evidence).
- The dist and large suites.
- The runtime-dispatch machinery (zcompress has no dispatch).
- fastmem's `bench/tests` suite. The adapter has no tests of its own.

Where the competitor pins came from:

- libdeflate v1.26 and zlib-ng 2.3.3: the flate-family native competitors in
  `docs/research/containers-notes.md` §6.3 and §6.4.
- google/snappy 1.3.1: the snappy competitor named in `docs/zcompress-plan.md`
  ("Benchmark methodology").
- zstd v1.5.7: the tag in `docs/research/zstd-notes.md` §6.1.
- klauspost/compress `v1.18.1-0.20250402062133-8df4d013ff17`: commit 8df4d01 of
  the local research checkout (`~/code/klauspost-compress`, `v1.18.0-5-g8df4d01`
  in `docs/research/zstd-notes.md` §6.2), pinned in
  `bench/drivers/klauspost/go.mod`.

## Design decisions

- The corpus shape list is repeated in `bench/zig/corpus.zig`,
  `bench/zig/bench_zcompress.zig`, `bench/zcompress_bench/jsonl.py` (twice),
  `bench/drivers/c/cbench.h`, `bench/drivers/klauspost/main.go`, and
  `src/zstd/bench.zig`. A new shape updates all of them and
  `bench/corpus/SHA256SUMS` in the same commit.
