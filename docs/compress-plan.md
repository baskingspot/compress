# compress plan

## Mission

compress gives Zig fast compression codecs. The performance class is
klauspost/compress. The usability class is std.compress. Every codec is a
self-contained directory that builds alone, with the shared `src/internal/`
layer in tow. Every performance claim is measured, and every number names its
evidence.

Pure Zig: SIMD work uses `@Vector`, `@shuffle`, `@select`, and `std.simd`.
Memory copies go through fastmem, the same-author fast memcpy/memmove/memset
library. Assembly appears only when Zig cannot express an instruction, only in
a thin feature-gated kernel with a generic fallback, and only after
disassembly proves the Zig route loses.

Non-goals until the core codec set ships: archiving formats (zip, tar),
parallel codecs (pgzip-style), dictionary training, s2 extensions, xz/lzma
(std.compress already ships those).

## Facts that the plan uses

- Zig 0.16.0 is the only toolchain. The flake pins it. Zig 0.17.0 (released
  2026-10-02) ships LLVM 22.1.8 with the loop vectorization pass disabled, a
  workaround for an LLVM 22 miscompilation (LLVM issue 186922; the pass returns
  in 0.18 with LLVM 23). `std.simd` in 0.17.0 is the 0.16.0 file modulo
  cosmetic changes. 0.16 keeps the auto-vectorizer and the std.simd toolbox
  (`interlace`, `deinterlace`, `extract`, `mergeShift`, `prefixScan`,
  `suggestVectorLengthForCpu`).
- std.compress 0.16 ships flate (Compress/Decompress), zstd, lzma, lzma2, and
  xz. It ships no snappy, lzw, gzip, or zlib container. Those are ours.
- klauspost/compress covers zstd, s2, flate (with gzip/zlib/zip containers),
  snappy, lzw, huff0, fse, and xpress. License: BSD-3-Clause.
- golang/snappy is BSD-3-Clause. Its test tables are the snappy golden
  vectors, including an exhaustive `length x offset x suffixLen` sweep.
- The raw-block snappy codec is finished: a port of klauspost's
  `encodeBlockSnappyGo64K` encoder, an original SIMD decoder, and the
  golang/snappy golden vectors (attribution in THIRD_PARTY.md).
- fastmem (same author, MIT) is the blessed copy primitive. Its inline layer
  has no loops, and large sizes call its own `no_builtin` kernels, so
  consumer-side inlining cannot idiom-match back into a `memcpy` call.
- Zig 0.16 removed run-time indexing of `@Vector` values, and `@splat` is
  single-argument. `std.Io` is the reader/writer interface; `main` takes
  `std.process.Init`.
- Zig 0.16 fuzz mode takes an iteration budget (`--fuzz=10M`). Debug fuzz hits
  ziglang/zig#30655, so fuzz runs use ReleaseSafe.

## Scope and build order

Codecs, one at a time, each shippable alone:

1. snappy — raw-block codec. (M0, M1)
2. flate — fast encoder plus full inflate. The core value. (M2)
3. gzip + zlib — containers over flate, plus checksum kernels. (M3)
4. zstd — decoder first, then the fast encoder. (M4, M5)
5. brotli — decoder first, RFC 7932. (M6)

Order rationale: snappy is nearly free and calibrates the whole measurement
pipeline. flate is the biggest standalone win and unblocks two containers.
zstd is the largest surface, so it splits decoder-first. brotli goes last:
the HTTP content-encoding codec (the practical surface LZW never had — its
only real users are legacy TIFF/PDF/GIF), decoder-first like zstd because
the format is a second large surface (context modeling, the static
dictionary, two LZ77+Huffman layers). LZW is dropped: no practical use
cases for it here.

## Architecture

### Modules

One directory per codec under `src/`, and ONE build module for the whole
library: `compress`, rooted at `src/root.zig` (owner's call, 2026-10-09).
The barrel re-exports each codec directory as a namespace
(`compress.snappy`, `compress.flate`), so the consumer surface is
`compress.<codec>.<name>` and there is no module graph to keep in sync.
Codecs import only `std` and `fastmem`, plus in-repo relative imports: a
container imports the codec it wraps (gzip/zlib over flate, M3) by relative
path.

A shared `src/internal/` layer may hold codec-agnostic primitives (history
windows, match-finder skeletons, checksum kernels, huffman tables). Rules: it
imports only `std` and `fastmem`; it holds no codec-specific state; a codec
that uses it lifts with `internal/` in tow. Nothing lands there before two
codecs need it.

The lift story: a codec directory plus `src/internal/`, under one module
root — a two-line barrel file, exactly what `src/root.zig` is — build and
test alone against the fastmem dependency, importing each other relatively,
with no build-graph surgery. The root file must be an ancestor of both
directories: relative imports cannot escape the module root's directory.

### API layers

Each codec exposes two layers, built in this order:

1. Block functions: pure functions over caller-owned buffers. Zero heap
   allocation. A worst-case sizing helper bounds the output buffer. (snappy:
   `compressBlock`, `decompressBlock`, `maxCompressedLength`,
   `decompressedBlockLen`, `max_block_size`.)
2. Streaming, where the format has framing: `std.Io`-native, in-package — a
   compressing `Io.Writer` and a decompressing `Io.Reader` over the codec's
   canonical stream format (snappy: `snappy.Writer`/`snappy.Reader` over the
   `u32-le compressed length + raw block` framing; the `std.compress.flate`
   `Compress`/`Decompress` pair is the in-tree precedent for the shape).
   The caller provides every buffer through exported named buffer types
   (`snappy.WriterBuffer`, `snappy.ReaderBuffer`); scratch is comptime-sized
   stack, so the whole path allocates nothing.

An API sketch gets Matt's review before implementation. APIs are felt, not
just specified.

### Memory and ownership

- Zero heap allocation on codec hot paths. Tables and windows live on the
  stack or in caller-provided buffers.
- Setup-time allocation (encoder state, huffman tables, dictionaries) takes
  a caller-provided allocator, or an arena the state machine owns for its
  lifetime. Ownership is documented at each API.
- Decode output buffers are exact-sized. Tests prove that no byte past the
  decoded length is written (sentinel overrun checks).

### SIMD

- Vector width is comptime, from `std.simd.suggestVectorLengthForCpu` per
  build target.
- Per-model comptime selection lands when fleet data shows divergence
  (fastmem's `tuning.zig` pattern).
- Runtime dispatch is deferred until a baseline-compatible binary is needed.
- Known-good shapes to reuse: comptime shuffle masks for overlapping copies
  (`tbl`/`pshufb`), u64 XOR plus `@ctz` match extension (`eor`/`rbit`/`clz`
  on aarch64), padded pattern loads before the last vector so the tail cannot
  overread.

## The codec development loop

Every codec runs the same loop, one at a time:

1. Research (spec-researcher): vendor the spec into `docs/research/specs/`,
   record provenance, extract the requirements matrix, list fixture sources.
   No code.
2. API sketch (parent): the public surface, error sets, buffer ownership,
   `std.Io` integration. The sketch lands as the module's `README.md`,
   written before any implementation. Matt reviews it before code exists.
3. Data structures: windows, finders, tables. A shared candidate goes to
   `internal/` only when a second codec needs it.
4. Implementation (slice-worker) under an explicit acceptance contract.
5. Correctness (fuzz-engineer, conformance-planner): golden vectors with
   spec-section citations, sentinel overrun checks, conformance lanes, fuzz
   targets.
6. Performance (perf-engineer): disassembly first, vector kernels, per-model
   selection when the fleet demands it.
7. Numbers (benchmark-methodologist + fleet-watcher): fleet runs, confidence
   intervals, results committed under `docs/results/`.

A lane's review runs at the same time as its correctness gate. Only the merge
waits for both.

## Correctness methodology

- Golden vectors from the reference suites, committed as fixtures. Every
  format test cites the spec file and section it validates:
  `// RFC 1951 §3.2.5 — fixed Huffman`.
- Sentinel overrun checks on every decode: the output is pre-filled with
  cycling sentinels, and every byte past the decoded length must survive.
- Conformance lanes: round-trip through reference CLIs (gzip, zstd, snappy)
  on the committed corpus, in both directions.
- Amplification limits are tests, not comments: a corrupt length prefix must
  fail closed, and a decode must never write past its declared output.
- Fuzz: round-trip and differential targets, `--fuzz=<budget>` iterations,
  ReleaseSafe only (ziglang/zig#30655).

## Benchmark methodology

- Iteration is local-first (Matt, 2026-10-08): remote machines slow the
  iteration cycle, so the fleet is on demand, not the default feedback loop.
  Local `just bench` (zig-benchmark, benchstat-friendly `--count=N`) drives
  development. Local numbers are never quoted as claims.
- Claims: the fleet harness, ported from fastmem at M1. Seven EC2 targets
  (c7i, c8i, c7a, c8a, c7g, c8g, c9g), n>=5 rounds, exact confidence
  intervals, outlier rounds reported and never removed.
- Every claim names its run directory and a results file under
  `docs/results/`. No number without provenance.
- Competitors per codec: klauspost/compress (Go) and std.compress (Zig)
  always, plus the strongest native library on the box (libdeflate/zlib-ng
  for the flate family, zstd C for zstd, google/snappy C++ for snappy).
- Corpus: committed, fixed, hashed. The same bytes for every implementation.
  Throughput is measured over uncompressed bytes.

## Licensing

compress is MIT. klauspost/compress, golang/snappy, and the Go stdlib are
BSD-3-Clause: reading is unrestricted, ports are permitted with attribution
in THIRD_PARTY.md. The posture stays the same anyway: reimplement from the
spec and the algorithm description where practical. When code is ported, keep
the upstream notice in the file header and name the upstream file and commit
in THIRD_PARTY.md.

## Agents and orchestration

The parent stays the orchestrator. Work dispatches to the roster in
`.pi/agents/`. Model pins live in the roster and come from the model guide;
they are never copied from another repo's roster.

Roster: slice-worker, implementation-reviewer, spec-researcher,
conformance-planner, fuzz-engineer, perf-engineer, benchmark-methodologist,
fleet-watcher, evidence-auditor, footgun-reviewer, matt-nits. herald joins
when there is a public surface to voice.

Decode of untrusted input is the security surface. It belongs to
fuzz-engineer (amplification and corruption targets) and conformance-planner
(reference-suite lanes), not to a separate security roster.

A fleet run gets a watcher: a delegate agent runs `bench watch <run-dir>` and
exits when `summary.json` exists. The parent never polls.

## Milestones

M0 — scaffold. Repo skeleton, build, Justfile, lint config, vendored specs,
the agent roster, snappy lifted and green under 0.16 with fastmem wired in.
Acceptance: `zig build test` and `just lint` pass on the host, `just bench`
runs, and the commit exists.

M1 — snappy API review. The module `README.md` documents the public surface;
Matt reviews it (README-first). Acceptance: the README merged, the API settled.
The fleet baseline against golang/snappy, google/snappy C++, and klauspost s2
(snappy-compat mode) runs on demand, before the first public performance
claim, and lands under `docs/results/` with its run directory cited.

M2 — flate. Fast encoder (klauspost level-1 class) plus full inflate. Golden
vectors from the Go flate suite; conformance via the gzip CLI; fuzz targets
for the huffman and match machinery.
Acceptance: conformance lanes green; a fleet run against klauspost,
libdeflate, zlib-ng, and std.compress.flate, committed with confidence
intervals.

M3 — gzip + zlib. Containers over flate; crc32 and adler32 kernels; the
PCLMULQDQ decision (study `std.crypto.ghash_polyval` first; no inline asm
before a vector route is proven slower). `GzipWriter`/`GzipReader` over
`std.Io`.
Acceptance: gzip and zlib conformance green; a fleet run committed. Conformance green
(`just gzip-oracle`, `just zlib-oracle`, and `just flate-oracle`) and the
fleet run committed: `docs/results/m3-fleet-20261010.md` (run id
`20261010T160535Z-m3`, seven targets, four arms, n=5). M3 shipped.

M4 — zstd decoder. huff0, fse, block, and frame layers. A decode-side fleet
run against zstd C, klauspost, and std.compress.zstd.
Acceptance: met — the CLI-verified golden corpus (68 fixtures, all decoded
by the pinned zstd v1.5.7), the fuzz targets (12, the T-register corners
pinned), and the fleet run committed:
docs/results/m4-fleet-20261011.md (run id 20261011T014512Z-m4, seven
targets, six arms, n=5; the zstd decoder beats the C reference on five of
seven targets, klauspost nearly everywhere, std everywhere; the M3 snappy
competitor-set gap closed in the same run). The Opus closing review passed
(fca3604 the B1 fix, 6b7e960 the B1-prime fix — the 32-bit wraps, both
proven closed on wasm32-wasi by `just check-32`, the standing 32-bit
execution gate; the reviewer's final confirmation: M4 shippable). M4
shipped.

M5 — zstd encoder, fast level. The one-shot (`encode.compress`) and the
streaming `Writer`, the CLI's level-1 byte class as the target, the
CLI-verified fixtures, and the encoder's fuzz targets.
Acceptance: `just test` and `just lint` green, with the CLI's own level-1
bytes pinned for the fixture set; `just zstd-oracle` green (the reference CLI
and klauspost/compress's strict Window_Size check on non-ASCII and
over-512-KiB inputs); `just check-baseline` green; a fleet run committed with
the encode rows (`docs/results/m5-encode-fleet-20261013.md`, run id
`20261013T071421Z-m5-encode2`); and the closing review's blockers fixed and
pinned by tests — the block-end prefix (`§3.1.1.4`), the FSE Huffman weight
form for literals carrying bytes above 0x80, the FSE last-symbol count
decrement, the one-shot's window rebase over 4 GiB, the hash-log clamp order
for sources under 1 KiB, the scan's exit at a block's end, and the
literals floor's dictionary gate. The encoder's fuzz targets land with it.
The perf pass (the ranked levers, `6ade796`) is adjudicated by
`docs/results/m5-perf-pass-fleet-20261013.md` (run id
`20261013T192145Z-m5-perf-pass`, measured against the `m5-encode2` baseline):
the incompressible 64-KiB rows 6.5-8.8x -> 1.4-1.9x (the block-level
early-exit), mixed/random-32K 2.4-3.6x -> 1.15-1.38x (the 4-lane histogram),
skewlit 3.1-5.9x -> 1.5-2.5x, words ~10-15% (countStats + the spill fix); the
literal-heavy shapes regressed a real 1-3% on every target (TE9's per-block
sample scan the leading candidate — the next pass's ranked lever). Size
parity held: every row `zstd -1` + the 4-byte trailer. The beat-everything
pass 1 (three lever commits through `8895881`: the double-buffer, the
vectorized extension, the register-resident scan and fixed-schedule flushes)
is adjudicated by `docs/results/m5-perf-pass2-fleet-20261014.md` (run id
`20261014T104001Z-m5-perf-pass2`): the entropy shapes collapsed 25-45%
(words 1.5-1.8x -> 1.13-1.32x, skewlit -> 1.27-1.55x), c7a/c8a took the
literal-heavy shapes down 20-25%, Intel 15-18%, decode neutral on every row,
klauspost beaten on words everywhere (0.66-0.80). The bar's named next
levers: the checksum asymmetry (measured ~35% of html-64K encode time on
ARM — a driver fairness fix, not a code lever) and the Intel-target profile
for the 3.3-3.5x literal-heavy gap.

M6 — brotli, decoder first. The one-shot (`decode.decompress`) and the
streaming `Reader`, with the comptime `Reader.Buffer(window_wbits)` and the
format's built-in static dictionary shipped unconditionally. The
research is `docs/research/brotli-notes.md` (the `BR` matrix, the `T`
divergence rows, the `OQ` register; the RFC vendored at
`docs/research/specs/rfc7932-brotli.txt`), the google/brotli C reference is
the oracle lane and the strongest-native competitor, and the API sketch is
`src/brotli/README.md`.
Acceptance: the decoder shipped through six slices (the bit reader, the
stream header and ladder, both prefix-code forms, the command stream with
the distance ring, the static dictionary with its 121 transforms and the
commit-time generator, and the streaming Reader with the ring and the
resumable cursor) plus the example CLI, the dual-reference oracle lane
(`just brotli-oracle`: the pinned CLI 1.2.0 and andybalholm v1.2.6), and the
fuzz wave's 19 targets. The closing review (accept with required fixes)
landed both blockers and all four majors fixed and pinned (`f7c6009` —
the u64 seam proven by `src/brotli/probe32.zig` under `just check-32` with
a 4.3 GB stream, the dictionary-MLEN check and four oracle-only rules
pinned by fixtures). The window default is 24, the format's maximum (F9's
re-measure: every pipe row is WBITS 24, the file form never above 19 —
the library's 22 would refuse every pipe-produced CLI stream);
`DefaultBuffer` ~16.7 MiB. The fleet run of record is
`docs/results/m6-fleet-20261014.md` (run id `20261014T135257Z-m6-brotli`):
the copy-structure shapes won (rle 0.11-0.51 everywhere, text/html on
every ARM target), words (the dictionary path) 2.3-2.8x behind, skewlit
2.9-4.0x, and the mixed/random 6-13x mechanism unidentified (a per-call
cost dominating the row — the brotli decode perf wave owns the
diagnosis). The zstd rows re-measured at the same revision moved within
noise — the brotli decoder cost them nothing.

M7 — dictionaries, consume-first. zstd dictionaries (RFC 8878 §5): the
formatted dictionary parsed at setup (`zstd.Dictionary.parse`, zero-copy over
the caller's file bytes; `initRaw` for format-free content) and handed to the
decoder (the seeded entropy tables and repcodes, the content as preset
history with §5's expiry boundary enforced fail-closed) and the encoder
(`encode.Options.dict`, the `repeat_valid` seats the M5 register recorded,
the parity target `zstd -D dict -1`); then the zlib preset dictionary (RFC
1950 §2.2 FDICT + the 32-KiB flate preset window, both directions,
`dict: ?[]const u8`, the flate preset-history seam). gzip gains nothing (RFC
1952 has no dictionary concept) and brotli gains nothing (the static
dictionary already ships; the custom-dictionary path is an extension surface
the decoder refuses naturally) — both negatives recorded in the research.
Training is not a dependency: the dictionary file is an input; the `zstd` CLI
trains (`--train`, fastCover, verified).
The research is `docs/research/dictionary-notes.md` (the `DD`/`DE`/`ZL`
matrices, the `DT` divergence rows, the `DQ` register with the API sketch
options and recommendations); the API sketches are the dictionary sections of
`src/zstd/README.md`, `src/zlib/README.md`, and `src/flate/README.md`,
approved by Matt 2026-10-14 ("send it").
Acceptance, met 2026-10-14: the three slices landed and gated — zstd
decode-with-dict (`871ef35`: the third-parameter migration across every
callsite, the entropy seeds and virtual-past content, the DICTID matrix, the
fail-closed expiry pinned by hand-built frames, the oracle's 24 dictionary
rows), zstd encode-with-dict (`5aadcb5`: the promotion rules on the M5
encoder's own seats — the repeat_valid row the M5 register recorded as
unreachable-without-a-dictionary closes — the match region searching the
content as virtual past, the `zstd -D -1` parity across both header forms,
the oracle at 34 dictionary rows), and the zlib preset both directions
(`872dadd`: FDICT/DICTID with the whole-dict Adler-32, the >32-KiB tail rule,
the four mismatch cases, the flate seam's optional history, the flate-family
oracles' with-dict rows — zlib at 88 container rows against python3 zlib's
zdict forms, flate's 12 dictionary rows). The suite is 670 tests; every
gate green (check-baseline on all five targets, the clean-cache fuzz 10K
full-set).
written first, with the `zstd.Dictionary` type, the third-parameter decode
shape, and the fail-closed expiry boundary the review's decision points. The
slices land decode-with-dictionary, then encode-with-dictionary, then the
zlib preset.
Acceptance: `just test` and `just lint` green; the zstd dictionary oracle
lane green (decode: the CLI-trained dictionaries round-trip byte-exact both
directions against the CLI's `-D` and klauspost's `WithDecoderDicts`, the
mismatch matrix against the C's own `cli-tests/dictionaries` pins, the
incomplete-statistics fixtures (`zero-weight-dict`,
`http-dict-missing-symbols`) accepted, the expiry-boundary fixtures pinned
with the CLI's verdicts recorded; encode: `zstd -D dict -1` byte-parity on
the corpus shapes and the `-D` frames' decode through the CLI and this
decoder); the zlib dictionary rows green in the zlib and flate oracle lanes
(the four mismatch cases from the research as the error-name pins);
`just check-baseline` green; the fuzz wave's dictionary targets (the C's
`dictionary_*` fuzz shapes: parse, decode, round trip, raw round trip); a
fleet run committed with the dictionary rows (the trained-dictionary corpus
shapes, decode and encode arms); the closing review's blockers fixed and
pinned by tests.

M8 — the perf waves: the fair grid and the two decoder/encoder passes.
The brotli decode perf wave (the M6 grid's ranked gaps), then the zstd
fair-grid fix and the entropy wave (the literal/entropy rows, worst on
Intel).
Acceptance, met 2026-10-16: the brotli wave found and fixed the
mixed/random mechanism (the refilling byte drain — 6-13x behind to
0.36-0.48, won on every target; the split root table and the u64
promotion on the entropy rows: words 2.3-2.8x to 1.39-1.72, skewlit
2.9-4.0x to 1.13-1.53; `docs/results/brotli-wave-fleet-20261016.md`;
the corpus gained the `prose` natural-text shape — the shape set is
copied in five places, the gates caught two stale copies during rollout).
The zstd checksum grid became actually fair (`ZSTD_compress2`, not the
no-op `ZSTD_compressCCtx` flag) and the entropy wave closed the Intel
literal edges: the zstd encode text/html/rle rows 3.3-3.9x to 0.93-1.07
on the Intel targets (the per-model XXH64 accumulator — the scalar
chain with per-lane SLP barriers where the vector multiply's latency
dominated, 2.1x the vector form on graniterapids; the brotli x86_64
literal outline for the 16-GPR register starvation)
(`docs/results/entropy-wave-fleet-20261016.md`). The remaining
above-1.0 rows are the entropy rows on both codecs, each with ranked
algorithmic evidence in the wave's file — the zstd match finder's
literal count, the bit-reader's consume model — not unnamed gaps.

M9 — the second encoder seats: flate level 6, zstd level 3, brotli q3.
The three seats land in order — brotli's q3 encoder, flate's level-6
klauspost port, zstd's dfast level 3 — then the level APIs go numeric
(the community scheme) and the zstd Reader test's dictionaries come off
the stack.
Acceptance, met 2026-10-17: each seat is byte-pinned to its reference —
brotli q3 to the pinned CLI's `brotli -q 3` (the oracle's encode rows,
the one-shot and the `Writer`, with the 22-size boundary ladder and a
sweep across Debug, ReleaseSafe, and ReleaseFast; `a0fe8fc`), flate
level 6 to klauspost/compress's flate at level 6 (the oracle's 30
parity rows and 12 dictionary rows both directions, a 351-row sweep,
and level 1's 14 frozen hashes; `c60a6b5`), and zstd level 3 to the
pinned CLI's `zstd -3` file form up to the 8 MiB job size (the oracle's
parity rows across both encoder forms and 38 dictionary rows at both
levels; `aa66eed`). Every other level is `error.Unimplemented`, never a
silent alias; level 1's bytes are unchanged. The numeric level scheme
retires the `Level` enum across the barrel and the containers
(`ff22a95`), and the macOS-26 test segfault is fixed by holding the
947,824-byte `Dictionary` values off the test's stack (`9b0db3d`). The
fleet grid gains the seats' rows (`9ed24a0`): flate level-6 encode
against klauspost level 6, libdeflate level 6, and zlib-ng level 6;
zstd level-3 encode against zstd-c level 3 and klauspost SpeedDefault;
brotli q3 encode against the brotli-c arm's first encoder surface, plus
the streaming `Writer` row — 7/7 targets, 8 arms, 5 rounds, 1,440
comparison rows per target, exact size parity on every seat, and the
level-1 and decode rows re-measured as controls
(`docs/results/encoder-seats-fleet-20261017.md`). The ranked open gaps:
the flate level-6 literal-heavy rows (2.3-3.1x behind zlib-ng's level 6,
1.2-2.0x behind libdeflate's on the 32K shapes) and the zstd level-3 C
gap (1.04-2.39x, worst on the Intel targets).

## Decisions made

- Zig 0.16.0 only (2026-10-08). Revisit at 0.18: LLVM 23 restores loop
  vectorization.
- Codec order as in Scope.
- fastmem is a direct dependency and the blessed copy primitive on codec hot
  paths (2026-10-08).
- Block functions before streaming cores before `std.Io` adapters.
- Zero allocation on codec hot paths; an arena for setup.
- The fleet harness ports from fastmem at M1.
- API sketches get Matt's review before implementation; each module's
  README is written first and is the API sketch (2026-10-08).
- Local-first iteration: the fleet runs on demand, not as the default loop
  (2026-10-08).
- No `@memcpy`/`@memmove`/`@memset` anywhere in this repo's source —
  `fastmem.copy`/`move`/`set` only (2026-10-08).
- One `compress` build module, codecs as namespaces under it, `src/internal/`
  reached by relative import (2026-10-09, owner's call). The retired wiring
  was one build module per codec plus a private `internal` module.

## Decisions deferred

- Runtime dispatch (baseline+avx2 single binary) versus per-model builds:
  M1 fleet data decides.
- crc32 via PCLMULQDQ inline asm versus folded-vector arithmetic: M3, after
  the ghash_polyval study.
- s2 extensions: after M6, only if wanted.
- Shared `internal/` primitives: the first candidate lands when flate needs a
  second user of a snappy shape.
- flate dynamic-Huffman ratio mode (OQ1): after the fast path wins —
  `Level.ratio` reserves the seat with `error.Unimplemented`, never silent
  aliasing.
