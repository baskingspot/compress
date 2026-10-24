# compress bench

The remote benchmark harness. It cross-builds compress and its competitors for
each EC2 target, runs them over one fixed corpus in interleaved rounds on
dedicated boxes, and reports ratios with exact confidence intervals.

Local `just bench` numbers are for iterating and are not claims. A number that
gets quoted comes from a run of this harness, recorded under that run's id.

The harness is adapted from fastmem's (`~/code/fastmem-zig/bench/`).
`ec2bench/` is the generic EC2 core and holds no benchmark-specific code
(`ec2bench/README.md`). `compress_bench/` is the compress adapter: the suite,
the cross builds, the result schema, and the analysis.

## Arms

A run measures **arms**, one binary each. Each round runs every arm once, in an
order drawn from a seeded balanced Latin square, and each binary runs on the
last physical core of the box, isolated through systemd
(`ec2bench/isolation.py`).

| Arm | Binary | Rows | Build |
|---|---|---|---|
| `zc` | `zig build fleet-bench` (bench/zig/bench_compress.zig) | compress one-shots, both directions (flate, gzip, zlib at level 1; snappy blocks; zstd at levels 1 and 3; brotli at quality 3 — the one-shot and the streaming `Writer`), plus flate level 6 (`flate6`) and brotli decode (`decode.decompress`), and the in-binary `std` rows: std.compress.flate raw/gzip/zlib at `level_1`, both directions, and std.compress.zstd decode | cross-built per target: `-Dtarget=<arch>-linux-musl -Dcpu=<model>`, ReleaseFast, static |
| `klauspost` | bench/drivers/klauspost (Go) | klauspost/compress flate, gzip, zlib at level 1 and snappy, both directions; flate at level 6 (`flate6`, the byte pin's race); zstd `EncodeAll` at SpeedFastest (level 1) and SpeedDefault (level 3) with `WithEncoderCRC(true)` (the zc one-shot's frame form) and `DecodeAll`, both directions | `go build` with GOOS=linux per arch; module pinned to v1.18.1-0.20250402062133-8df4d013ff17 |
| `libdeflate` | bench/drivers/c/bench_libdeflate.c | libdeflate v1.26 gzip, zlib, and deflate one-shots at level 1, plus raw deflate at level 6 (`flate6`) | `zig cc -static` per target and CPU, over the pinned source tree |
| `zlibng` | bench/drivers/c/bench_zlibng.c | zlib-ng 2.3.3 streaming API (zlib-compat, windowBits -15/15/31) at level 1, plus raw deflate at level 6 (`flate6`) | cmake (ZLIB_COMPAT, static) with a zig-cc wrapper, per target and CPU |
| `googlesnappy` | bench/drivers/google-snappy/bench_snappy.cc | google/snappy 1.3.1 raw blocks (`snappy::RawCompress`, `RawUncompress`), both directions | cmake (static `snappy`) with zig-cc and zig-c++ wrappers, per target and CPU |
| `zstd-c` | bench/drivers/c/bench_zstd.c | zstd v1.5.7 whole-buffer `ZSTD_compress2` at the CCtx's level-1 and level-3 parameters (the zc one-shot's frame form: content size + the XXH64 trailer; `ZSTD_compressCCtx` ignores the sticky parameters, so the first checksum-fair attempt was a no-op) and `ZSTD_decompressDCtx`, both directions | cmake (`build/cmake`, static library, no programs, tests, or threads) with a zig-cc wrapper, per target and CPU |
| `brotli-c` | bench/drivers/c/bench_brotli.c | google/brotli v1.2.0 `BrotliDecoderCreateInstance` + `BrotliDecoderDecompressStream` over the whole stream, allocating from a pre-faulted bump arena, decode; and `BrotliEncoderCompress`'s q3 call sequence (the CLI's automatic window, the size hint, one FINISH call) over an arena instance, encode | cmake (static `brotlienc`, `brotlidec`, and `brotlicommon`, no tools or tests) with a zig-cc wrapper, per target and CPU |
| `aa` | the `zc` binary again | the A/A noise floor | none |

The sources of the five native arms are pinned by release-tarball URL and hash
in `bench/build.zig.zon`, a separate build root, so that the root package and
`zig build test` never fetch them. `zig build bench-vendor` (the root step
delegates to `bench/build.zig`) materializes them under
`bench/zig-out/bench-src/<name>/`, hash-verified by zig's own fetcher. The
harness runs that step itself and never downloads or unpacks a tarball.

Row naming: a case is `<codec>/<direction>/<shape>/<size>`, and a codec token
names the codec plus, when it has a second class, that class — `flate6`
(level 6), `zstd3` (level 3), `brotli-stream` (the streaming `Writer`). The
bare tokens are the level-1 and one-shot rows. The level and streaming rows
are compress only: a decoder is not per-level, so there is no separate decode
row, and their round trips ride the base codec's decoder.

zstd rows run both directions on the arms that carry the codec, at two
levels: zc (the level-1 and level-3 one-shots), klauspost (SpeedFastest and
SpeedDefault), and zstd-c (levels 1 and 3) — the same two classes on every
arm. The in-binary std.compress.zstd rows stay decode only: the std library
ships no zstd compressor.

flate level-6 rows (`flate6/compress/...`) race on zc, klauspost, libdeflate,
and zlib-ng: each library's own level-6-class setting (klauspost's level 6 —
the class our level 6 is byte-identical to; libdeflate's level 6; zlib-ng's
level 6). The flate family's level-1 rows stay the level-1 race.

brotli rows run both directions on zc and brotli-c. The encode rows are the
quality-3 class: the zc one-shot and the zc streaming `Writer` (the
`brotli-stream` rows, whose window follows the CLI's automatic rule), against
the C encoder's q3 one-shot. The decode rows decode the pinned CLI's quality
11 reference streams. The C decoder has no reset, so every brotli-c decode
iteration creates, runs, and destroys one decoder instance; its allocations
come from an arena rewound per stream instead of `malloc`, the same "codec
alone" rule the other native arms follow. The C encoder has no reset either,
and its row is the same shape: one instance per iteration from the same
arena, the one-shot's own call sequence. The C decoder decodes through its
ring buffer and copies out; the zc one-shot decodes in place. That copy is
part of what the rows measure.

## Corpus

`bench/corpus/SHA256SUMS` is committed and is the only corpus file in git. It is
the trust anchor. The bytes generate on demand into the gitignored
`bench/corpus-gen/` with `just corpus` (the generator is `bench/zig/corpus.zig`,
run as `zig build corpus`).

There are seven shapes at two sizes (32 KiB and 64 KiB): `text`, `random`,
`html`, `rle`, `mixed`, `words`, and `skewlit`. The first five mirror the codec
bench files (`src/flate/bench.zig`). `words` and `skewlit` are literals-heavy
shapes that exercise zstd's Huffman path.

Next to each raw file sit reference blobs: `.flate`, `.gz`, `.zz`, and `.snappy`
from the compress encoders, `.zst` from the pinned zstd CLI (v1.5.7, from
the flake), and `.br` from the pinned brotli CLI (1.2.0, from the flake). Every arm's decompression rows decode these identical bytes. The
CLI writes the `.zst` frames at level 1, the fast class that every arm's rows
measure, except for `words` and `skewlit`, which use level 19 so that their
frames carry Huffman-coded literals. The frames carry XXH64 checksums, and the
generator checks each one byte for byte with our decoder before writing it.
The `.br` streams are quality 11, the CLI's default, for every shape. The
CLI reads each file by path, so it sizes the window to the file (WBITS 16 for
32 KiB, 17 for 64 KiB). The generator checks each stream byte for byte with
our decoder before writing it. Brotli has no checksum, so the check is the
only integrity gate. On this corpus `random` and `mixed` come out as
uncompressed meta-blocks, so their rows measure copies rather than entropy
decoding.

The generator compares every file it writes with `SHA256SUMS` and exits with an
error on any difference, missing file, or extra file. The harness checks again
before it uses the tree: `compress_bench/corpus.py` verifies each generated
file against the committed hashes, and a run fails if the generated directory
is missing (run `just corpus`) or differs. Each driver's meta record carries the
SHA-256 of every raw file it read, and the parser rejects a round whose hashes
differ from the committed ones. The manifest records one `tree_sha256` over the
verified anchor (names and digests, sorted) next to the per-file hashes. It
identifies the corpus across runs without the bytes.

## Result schema (JSONL, v1)

Each driver (Zig, Go, C, C++) writes one JSONL file per arm and round: a `meta`
record (arm, tool, rev, toolchain, target, cpu, optimize, suite, seed, samples,
sample_ms, impls, corpus hashes), one `sample` record per case, implementation,
and sample (the case is `<codec>/<direction>/<shape>/<size>`, plus iters, ns,
out_len), and an `end` record. `compress_bench/jsonl.py` validates the schema
strictly, and a file that does not validate fails the round.

## Analysis

The estimator core is carried over from fastmem. Each (arm, case,
implementation) cell reduces to the median of its samples in each round. Cells
from separate processes get a two-sample Hodges-Lehmann estimate with an exact
Mann-Whitney interval. Cells that share a process get a one-sample
Hodges-Lehmann estimate with an exact Wilcoxon signed-rank interval. Outlier
rounds are flagged and never removed. A significance mark needs at least 5
rounds and an interval that clears the A/A noise floor. The comparisons:

- `A/A`: aa against zc, the noise floor.
- `<arm>/zc`: a competitor arm against zc (two-sample, across binaries).
- `zc/std`: zc against the in-binary std rows (paired).
- `container/flate`: each gzip or zlib row against the flate row of the same
  implementation in the same processes. Code layout differs between binaries
  and skews cross-binary comparisons on latency-bound shapes, so this paired
  row is the reference for container overhead.

The `sizes` rows record the median compressed length per cell, which gives the
compression ratio.

## Credentials and infrastructure

The harness uses fastmem's AWS setup: profile `fastmem-bench`, the same launch
templates and reaper, and `tofu_dir` pointing at `~/code/fastmem-zig/infra/base`
(read-only: the harness only runs `tofu output`). The IAM policy pins
`Project=fastmem-bench`, so `project.name` in `bench.toml` stays `fastmem-bench`.

Both repos' boxes therefore carry the same tag and the same `Target` names, and
the two harnesses see each other's boxes. `bench ls` lists both,
`bench down --all` terminates both, and `bench up` adopts an existing box for a
target and terminates later duplicates, whichever repo launched it. Check
`just bench-ls` before launching, and do not run this harness while a fastmem
run is using its boxes.

A dedicated `compress-bench` stack needs the human bootstrap in fastmem's
`infra/README.md` ("Copy into another project"), which needs the `playground-ops`
SSO profile.

## Commands

```sh
just corpus                              # generate and verify the corpus (bench/corpus-gen/)
just bench-up                            # launch the seven targets (2h TTL default)
just bench-ls                            # show the running boxes
just bench-test                          # correctness gate: every arm's --check on every box
just bench-run --rounds 5 --label base   # the measurement
just b analyze <run-dir>                 # re-analyze a run without AWS, SSH, or builds
just b watch <run-dir>                   # exit when summary.json exists
just bench-down                          # terminate the boxes
just bench-check                         # uv format and uv check over the harness
```

A run directory (`bench-results/<run-id>/`) holds the manifest (seed, schedule,
corpus tree hash and per-file hashes, competitor pins, build cache keys and
binary SHA-256s, git provenance), the raw rounds and host facts for each target,
`summary.json`, and `report.md`. The uploaded binaries and the generated corpus
are not kept there. Both can be regenerated from what the manifest records
(source revision, build cache keys, binary SHA-256s, corpus hashes, and the
committed anchor), so the run directory holds only evidence that cannot be
regenerated. A correctness run (`bench test`) holds each arm's `check.json`,
`check.exit`, and `check.stderr` per target, plus its summary.
