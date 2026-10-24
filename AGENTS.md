# compress: agent notes

compress gives Zig fast compression codecs. `README.md` is the user overview.
`docs/slop/plan.md` is the plan: mission, architecture, the codec
development loop, methodology, and milestones with acceptance criteria. Read
it before you change a kernel or make a performance claim.

## Layout

- `src/root.zig`: the barrel of the ONE `compress` build module. One pub
  decl per codec, each a namespace under it (`compress.snappy`,
  `compress.flate`).
- `src/snappy/`: raw-block snappy, with fastmem wired into its copy paths.
  `encode.zig` ports the klauspost encoder algorithm (THIRD_PARTY.md);
  `decode.zig` is original, with golden vectors in `golden.zig` (ported
  golang/snappy fixtures, shared by every layer's tests); `Writer.zig` +
  `Reader.zig` are the streaming `Io` layer (a compressing `Io.Writer` and a
  decompressing `Io.Reader` over the framed stream; see
  `src/snappy/README.md`); `bench.zig` is the local benchmark;
  `fuzz.zig` ships fuzz targets; `common.zig` (LEB128 varint) is a shared
  helper. One-call pumps: `Writer.streamAll`, `Reader.streamAll`.
- `src/flate/`: raw deflate (RFC 1951). `encode.zig` ports the klauspost
  level-1 match-finder (THIRD_PARTY.md); `decode.zig` carries inflate, the
  bit reader, and the canonical Huffman-table construction and §3.2.5 code
  tables shared by both sides; `Writer.zig` + `Reader.zig` are the streaming
  `Io` layer over raw deflate (BFINAL self-delimits; there is no in-package
  framing; see `src/flate/README.md`); `golden.zig` shares the
  Go flate fixtures and the corpus shapes across every layer's tests;
  `bench.zig` is the local benchmark;
  `oracle.zig` is the external-oracle harness behind `just flate-oracle`.
  Fuzz targets land in `fuzz.zig` (fuzz-engineer lane).
- `src/gzip/`: gzip members (RFC 1952) over flate. `encode.zig` writes the
  one-shot member — the deterministic 10-byte header, the CRC-32/ISIZE
  trailer; `decode.zig` carries the header parser both layers share and the
  trailer check; `Writer.zig` + `Reader.zig` are the streaming `Io` layer
  (the lazy header, the member boundary, the multi-member `streamAll` walk —
  see `src/gzip/README.md`); `crc32.zig` is the slice-by-16
  CRC-32 kernel behind the container's checksum state; `golden.zig` shares
  the Go gzip fixtures across every layer's tests; `bench.zig` is the local
  benchmark; `oracle.zig` is the external-oracle harness behind `just
gzip-oracle`; `common.zig` is the little-endian integer helper. Fuzz
  targets land in `fuzz.zig` (fuzz-engineer lane).
- `src/zlib/`: zlib streams (RFC 1950) over flate. `encode.zig` writes the
  one-shot stream — the CMF/FLG header, the Adler-32 trailer; `decode.zig`
  carries the header check, the trailer reader, and the trailer check both
  layers share; `Writer.zig` + `Reader.zig` are the streaming `Io` layer —
  see `src/zlib/README.md`; `adler32.zig` is the vectorized
  Adler-32 kernel behind the container's checksum state; `golden.zig` shares
  the Go zlib fixtures across every layer's tests; `bench.zig` is the local
  benchmark; `oracle.zig` is the external-oracle harness behind `just
zlib-oracle`; `common.zig` is the big-endian integer helper. Fuzz targets
  land in `fuzz.zig` (fuzz-engineer lane).
- `src/zstd/`: zstd frames (RFC 8878). `decode.zig` carries the one-shot
  decode and the shared decode state; `frame.zig` the magic, the frame
  header, the block chain, the checksum trailer, the skippable frames, and
  the per-block checksum funnel; `block.zig` the block header dispatch;
  `literals.zig` + `huff0.zig` the literals section and its Huffman trees;
  `sequences.zig` the sequences section, sequence execution, and the
  repeat-offset machine; `fse.zig` + `bits.zig` the FSE tables and the two
  bitstream readers; `xxh64.zig` the checksum state over its own u64-counted
  kernel (std's wraps at usize); `probe32.zig` the 32-bit proof probe
  (`just check-32`); `Reader.zig` the
  streaming `Io` layer (one frame per reader with the exact boundary visible,
  the multi-frame `streamAll` walk — see `src/zstd/README.md`);
  `golden.zig` shares the reference fixtures across every layer's tests.
  The encoder's entropy layers: `fse_compress.zig` the normalization, the
  encode-side table, and the `§4.1.1` description writer; `huff0_compress.zig`
  the tree builder, the weight-series writer, and the Huffman streams;
  `sequences_compress.zig` the sequences section and its interleaved
  bitstream; `literals_compress.zig` the literals ladder; `bits.zig` also
  carries their writer inverses. The encoders are `encode.zig` (the one-shot,
  `ZSTD_compress`'s class) and `Writer.zig` (the streaming form), over
  `block_compress.zig` and `match_compress.zig` (the C's `ZSTD_fast` port);
  the public namespace is `{encode, decode, Writer, Reader}`. `oracle.zig` is
  the external-oracle harness behind `just zstd-oracle`.
  `bench.zig` is the local benchmark; the
  fleet rows live in `bench/zig/bench_compress.zig` (`just bench-run`). Fuzz
  targets are in `fuzz.zig`.
- `src/brotli/`: Brotli (RFC 7932), decoder and `q3` encoder. `bits.zig` the
  bit reader; `frame.zig` the stream header and the meta-block ladder;
  `huffman.zig` both prefix-code forms; `context.zig` the context maps;
  `command.zig` the command stream; `distance.zig` the distance codes;
  `dictionary.zig` + `dictionary_data.zig` the 122,784-byte static dictionary
  and its 121 transforms; `decode.zig` the one-shot decode; `Reader.zig` the
  streaming decode over the comptime `Buffer(window_wbits)`, 16.7 MiB at the
  default 24; `encode.zig` the one-shot encode over `encode_match.zig` and
  `encode_huffman.zig`; `Writer.zig` the streaming encode; `golden.zig` the
  corpus; `bench.zig` the local benchmark; `oracle.zig` behind `just brotli-oracle`;
  `fuzz.zig` the targets; `probe32.zig` the 32-bit proof probe
  (`just check-32`). API: `src/brotli/README.md`.
- `src/internal/`: the codec-agnostic shares (plan, "Architecture"): the
  sentinel test machinery, the reader lifecycle + generated reader vtable
  entries, the shared writer machinery (the generated `Io.Writer` entries
  and the poisoned `finish`), the endian-bound integer helpers the codec
  `common.zig` files bind, and the container driver over a codec's framing
  type. Imports only `std` and `fastmem`; reached by relative import
  (`@import("../internal/root.zig")`), never a build module, and never
  re-exported by the barrel; a codec that uses it lifts with it in tow,
  under a module root above both directories (relative imports cannot
  escape the module root's directory).
  `src/internal/AGENTS.md` is the Io codec pattern book every new codec
  follows.
- `docs/`: the human docs. `content/` is the Zola guide, `examples/` the
  snippets it compiles, `specs/` the vendored format text with provenance,
  and `static/` the marks.
- `examples/`: one CLI per codec, thin streaming pumps (`encode`/`decode`)
  over a file or stdin on shared scaffolding (`examples/cli.zig`). The codec
  package owns the framing (snappy's: `src/snappy/README.md`).
- `docs/slop/`: agent material. `plan.md` is the plan, `research/` the codec
  research notes, and `results/` the fleet write-ups, one file per run. No
  human document links this directory.
- `.pi/agents/`: the roster. The parent orchestrates; agents own lanes.

## Toolchain

- Zig 0.16.0 from the flake. Read the zig skill before you write Zig here.
  0.15-era patterns are wrong in 0.16 in silent ways (`std.Io`, `main(init)`,
  run-time vector indexing). Run `zigdoc` to verify any std API before you
  use it.
- The flake is the environment. A missing tool goes in `flake.nix`; do not
  install it globally.

## Disk discipline

The dev box shares one disk with everything else on it (~25 GB free at
best). Lanes and the parent clean up after themselves — this bit us once
(ENOSPC killed two lanes mid-write; the caches and scratch had piled ~20 GB
onto a nearly-full disk):

- Lane scratch trees live under one root (`/tmp/<lane>-*`), and the PARENT
  deletes them at the lane's commit or salvage. A timed-out lane's tree
  dies with its salvage.
- The fuzz corpus cache (`.zig-cache/f/`) accumulates forever — Zig's fuzzer
  never prunes. Prune it (`rm -rf .zig-cache/f`) at each wave's close and
  before any big-budget run; corpora re-warm in minutes.
- Big validation corpora are GENERATED from `just corpus` shapes on demand,
  never hand-built, and deleted at the milestone's close — a 2 GB text
  file and its three decoded outputs lived in /tmp for two days once.
- `du -sh /tmp/* .zig-cache` before assuming headroom; report to the
  parent if anything needs more than a few GB.

## Commands

- `just test`: unit tests for every codec, under the testingx plain-text runner.
  Must pass before a commit.
- `just fuzz [BUDGET]`: per-target fuzz over `--fuzz=<budget>` iterations
  (default 10M). ReleaseSafe only (Debug fuzz hits ziglang/zig#30655).
- `just ci`: everything CI runs: `just test`, `just lint`, and
  `just check-baseline`.
- `just lint`: ziglint over `.ziglint.zon` paths, `zig fmt --check` over
  `src/` and `build.zig`, `uvx ruff`/`uvx ty` over `scripts/`, and `nix fmt`,
  `oxfmt`, `actionlint`, `zizmor`, and `just --fmt` over the rest. Run it
  before you call Zig work done.
- `just fmt`: apply `zig fmt` to `src/` and `build.zig`.
- `just check-baseline`: cross-target `zig build check` covering every
  portable target (freestanding targets excluded — the testingx runner needs
  an OS).
- `just flate-oracle`: external-oracle conformance for flate — `python3
zlib` raw, both directions (catches bit-packing bugs invisible to a
  self-round-trip; the layer is `scripts/flate_oracle.py`).
- `just gzip-oracle`: external-oracle conformance for gzip — `python3 zlib`
  (the wbits 31 wrapper), the CPython `gzip` module, and the gzip/gunzip
  CLIs, both directions (plus FHCRC, the single-member boundary, and the
  trailing-garbage pin; the layer is `scripts/gzip_oracle.py`).
- `just zlib-oracle`: external-oracle conformance for zlib — `python3 zlib`
  (wbits 15), both directions (plus the FDICT refusal, the T5 FCHECK=31
  corner, and the exact stream boundary; the layer is
  `scripts/zlib_oracle.py`).
- `just zstd-oracle`: external-oracle conformance for zstd — the reference
  CLI v1.5.7 and klauspost/compress (the strict Window_Size check the C
  decoder does not make), both directions and byte-parity with `zstd -1` on
  non-ASCII and over-512-KiB inputs; the layer is `scripts/zstd_oracle.py`
  with the `scripts/zstd_klauspost` decoder.
- `just bench [ARGS]`: local benchmarks (testingx). Local numbers are
  never quoted as claims.
- `just example <codec> ...`: run a codec's example CLI (e.g. `just example
snappy encode README.md > /tmp/out` runs `zig build example-snappy --
encode README.md`).
- `just clean`: drop `zig-out/`, `.zig-cache/`, `zig-pkg/`.

## Dependencies

- fastmem (non-lazy): the only memory-copy primitive in this repo. Never
  write `@memcpy`, `@memmove`, or `@memset` in this repo's source — not on
  codec hot paths, not in tests, not in bench corpus builders. Use
  `fastmem.copy`, `fastmem.move`, `fastmem.set` (all `(comptime T, dest,
...)`). `copy` and `set` are non-overlapping only; `move` handles overlap.
  A stray `@memcpy` in a diff is a review blocker.
- testingx (lazy): the test runner and bench harness for the test and bench
  steps only, never imported by codecs. In `build.zig`, lazy deps must go
  through `b.lazyImport` / `b.lazyDependency`, never `b.dependency`.

## Tiger style

The snappy package is the reference application of Tiger Style (the
`tiger-style` skill — safety > performance > developer experience). Copy its
patterns into every codec:

- Centralize control flow in the parent; push pure logic down into helpers
  with primitive arguments. `decompressBlock` (46 lines) owns the tag
  dispatch; `decodeLiteral`/`decodeCopy`/`copyMatch` are the leaves.
  `encodeBlock`'s labeled scan cascade stays in the parent for the same
  reason — see Deviations.
- Byte-buffer pairs are named `source`/`target` (equal length, data-flow
  order: `compressBlock(source, target)`). `in`/`out` name `*Io.Reader` /
  `*Io.Writer` params. Units go last (`scratch_len`, `max_block_size`,
  `decoded_region_len`).
- State machines are enums, not bools: `Reader.State` is
  `streaming`/`done`/`failed` with the detailed error beside it.
- Assertions are useful, not ceremonial: caller-guaranteed preconditions
  (`assert(source.len >= input_margin)` — the gate above guarantees it) and
  postconditions (`assert(w.writer.end == 0)` after an emit). Hostile input
  gets error returns, never asserts.
- Minimal allocations, not zero. Allocation is a measured exception, not
  a ban: compression libraries cannot be strictly zero-allocation. The
  default discipline stays — caller-owned buffers, comptime KiB-scale
  stack scratch, setup allocation documented at the API — because it has
  served the codecs well. But an API taking an allocator where a buffer
  genuinely cannot be caller-stack-owned is a legitimate design, not a
  violation (the zstd pump shape question is the live case). Stack scratch
  is KiB-scale; a large buffer is never a stack local — the caller
  heap-allocates it (the arena pattern, the zstd example after its
  8.4 MiB DefaultBuffer segfaulted under a real 8 MiB `ulimit -s 8192` —
  it had only worked because the dev box's stack was bigger).
- Batching: whole blocks through the data plane; framing is the control
  plane.

Deviations, on purpose:

- No Tracy zones — no profiler dependency in this repo. Observability is
  the benchmark harness plus disassembly.
- The 70-line function limit is consciously overridden on `encodeBlock`'s
  scan cascade (154 lines) and zstd's `match_compress.scanBlock` (160 lines,
  register-resident with the shared match tail):
  centralizing that labeled control flow in the parent is the Tiger rule that
  wins; the pure logic is already extracted (`hash6`, `load64`, `emitLiteral`,
  `emitCopy`; `hashAt`, `match4Found`, `count`).
- House lint is 100 columns (tighter than Tiger's 120).

## Rules

- No binary files in git. Test data and reference bytes commit text: binary
  payloads are single-line base64 with the `.base64` suffix
  (`src/gzip/testdata/issue6550.gz.base64` set the shape). `build.zig`'s
  `fixtures` manifest decodes them into the anonymous `fixtures` module the
  codecs' golden data re-exports. The one exception: brand marks — a raster
  under `docs/static/` commits only as a render, with its SVG source beside
  it. `scripts/check_binary_files.py` enforces the rule in `just lint`.
- Spec-first: a codec's work starts from `docs/specs/`. Every format
  test cites the spec file and section it validates:
  `// RFC 1951 §3.2.5 — fixed Huffman`.
- README-first: each codec directory carries its own `README.md` documenting
  the public API. Write it before the implementation — it is the API sketch
  Matt reviews. An API change updates the module README in the same commit.
- Docs split by reader. A `README.md` is for a human deciding whether and how
  to use the code: what it is, usage, the API, behavior a caller needs,
  limitations. No milestone labels (M3), research-row ids (OQ7, T10), process
  words (lane, wave, fleet, pattern book), review history, or pointers to
  other documents' section names. Agent material goes in `docs/slop/`: the
  plan, the research notes, and the fleet results. `AGENTS.md` and code
  comments may link `docs/slop/`; the README, the guide, `CHANGELOG.md`,
  `THIRD_PARTY.md`, and every other human document must not. Per-codec design
  decisions, errata, and test inventories stay in the `AGENTS.md` beside the
  code (`src/<codec>/AGENTS.md`). Doc comments (`///`, `//!`)
  surface as function docs, so they are written for a caller: what it does,
  arguments, errors, preconditions, costs. A why that only a maintainer needs
  is a plain `//` comment next to the code. Short spec cites
  (`RFC 1951 §3.2.5`) belong everywhere.
- A codec imports only `std` and `fastmem`, plus in-repo relative imports:
  the codec-agnostic `src/internal/` shares when a second codec needs the
  shape (`src/internal/AGENTS.md`), and the codec it wraps (gzip/zlib over
  flate). Shared primitives go to `src/internal/` only when two codecs
  need them.
- Minimal heap allocation on codec hot paths — the codecs as built
  allocate nothing there, which their READMEs state as fact, not as a
  standing ban. Caller owns buffers; setup allocation is documented at the
  API. The streaming layers as built take no allocator (caller-provided
  buffers through exported named buffer types, comptime KiB-scale stack
  scratch); an allocator-taking variant is a legitimate design where a
  buffer cannot be caller-stack-owned — the zstd pump shape is the live
  question.
- Export named buffer-type constants for every caller-provided buffer
  (ztls pattern), and take exact pointers of them at `init`, not slices with
  asserts.
- `anytype` is a last resort, strongly discouraged. If a function needs
  genericity, it takes an explicit `comptime T: type` (or named-type)
  parameter the caller spells out — the type system checks the call, no
  runtime assert stands in for it. Duck-typed params hide signatures and
  push errors to call sites. A stray `anytype` in a diff is a review
  blocker unless the report says why nothing expressible fits.
- A single `*Io.Reader`/`*Io.Writer` param is named `input`/`output` (the
  `std.compress.flate` precedent); `in`/`out` name reader/writer pairs.
- The barrel (`src/root.zig`) exposes exactly one namespace per codec, and
  each namespace exposes exactly `{Reader, Writer, encode, decode}` —
  everything else composes through those namespaces
  (`compress.snappy.encode.compressBlock`,
  `compress.snappy.Reader.streamAll`, `compress.flate.Writer.Buffer`).
  No flat re-export menu at the root.
- CamelCase API names spell `Length` unabbreviated
  (`maxCompressedLength`, `decompressedBlockLength`); snake_case
  identifiers keep `len` (std's `.len` convention: `scratch_len`,
  `dots_len`).
- Style, per Matt's own edits (2026-10-09): hoist short aliases to the top of
  the file for anything used more than once (`const print = std.debug.print;`,
  `const mem = std.mem;`, `const Allocator = mem.Allocator;`);
  type-on-left with dot-init (`var rng: DefaultPrng = .init(seed);`); named
  enums with `std.meta.stringToEnum` over inline enum chains; a blank line
  between the std import/alias block and the fastmem import block; `in`/`out`
  param names for reader/writer pairs; `try` propagation over catch-and-print
  scaffolding.
- Decode never writes past the decoded length; sentinel overrun checks prove
  it in tests.
- A performance claim names the run's date and the measured value; the
  write-up in `docs/slop/results/` carries the run id. A change that helps one
  target and hurts another needs a comptime per-model selection.
- Fuzz runs use ReleaseSafe (`-Doptimize=ReleaseSafe -Dfuzz --fuzz=<budget>`)
  with an iteration budget; Debug fuzz hits ziglang/zig#30655.
- Licensing: BSD-3 reference code (klauspost/compress, golang/snappy) is
  readable without restriction; ports carry attribution in THIRD_PARTY.md.
  Prefer reimplementation from the spec.

## Agents

Work dispatches to `.pi/agents/`. Model pins live in the roster and come
from the model guide; they are never copied from another repo's roster.

- A lane's review runs at the same time as its correctness gate. Only the
  merge waits for both.
- A fleet run gets a watcher: a delegate agent runs `just b watch <run-dir>`
  and exits when `summary.json` exists. The parent never polls.

## Git

- Never `git add -A` or `git add .`. Stage tracked changes with `git add -u`,
  and add a new file by its path after you read `git status --short`.
  Untracked files can hold secrets: core dumps (`*.core`) contain the whole
  process environment.

## Commit messages

A commit message is for a reviewer reading `git log` a year from now. It is not
a lab notebook and not a status report. The planning vocabulary that this repo
scrubbed from its docs (milestones, waves, lanes, research-row ids) does not
belong here either.

- Subject: `area: what changed`, imperative, 72 characters or fewer. The area is
  the codec or directory (`zstd`, `flate`, `bench`, `docs`, `build`). No em
  dash, no diff stats, no planning labels. A subject that needs a clause after
  a dash is two ideas; pick one.
- Body: optional, wrapped at 72. Say why the change exists and anything the diff
  does not show: a constraint, a tradeoff, a rejected alternative. One to three
  short paragraphs of plain prose. No narrative of the investigation, no "the
  honest story", no process history, no restating the diff.
- Measurements and long write-ups go in `docs/slop/results/`. The commit names the
  file by path and gives the headline number in one sentence.
- One logical change per commit. A prose-only cleanup and a code change are
  separate commits. Do not describe an earlier commit as wrong in prose; fix it
  in a new commit and say what was fixed.

Good (illustrative):

    zstd: hoist the source-word load out of the literal copy loop

    The backward reader reloaded the word for every symbol. Hoisting it keeps
    the hot loop to one load per refill. Fleet numbers are in
    docs/slop/results/<run>.md.

Bad: `zstd perf wave 2: the lean backward reader, the corpus revision, the X2
answer`. It names a plan, not a change.

## Changelog

`CHANGELOG.md` is one file, Keep a Changelog format, newest first. Add a bullet
under `## [Unreleased]` in the same change that alters something a user can
notice: the public API, expected behavior, performance a benchmark row would
show, a supported backend, or the build requirements. Docs, CI, and internal
refactors do not need one unless they change how someone uses the package.

Write from the user's side: what changed, and what they must do about it. Name
the symbol, flag, or error. One line, under Added, Changed, Fixed, or Removed.

To release, dispatch the repo's `release.yml` with the version. The workflow
moves the Unreleased section into a dated heading, sets `.version` in
`build.zig.zon`, commits, tags, and opens the GitHub release. Do not tag by hand.
