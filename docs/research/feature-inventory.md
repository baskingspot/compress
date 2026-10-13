# Feature completeness inventory

Where each codec stands: what ships, what's accepted-but-plateaued, what's
rejected, what doesn't exist. Per codec, then the cross-cutting gaps.

## snappy — complete

Raw-block snappy is a single-plateau codec (no levels, no dictionaries —
the format has neither).

- One-shot encode (`encode.compressBlock`) and decode
  (`decode.decompressBlock`, `decode.decompressedBlockLength` for the
  streaming-safe length peek).
- Streaming `Writer` and `Reader` over the framed stream, both directions.
- No known gaps against the format.

## flate — decode complete, encode single-plateau

- Decode: full inflate — stored, fixed, and dynamic Huffman (`decompress`).
- Streaming both directions.
- Encode: **the level enum accepts 11 values but the encoder has two
  behaviors**: `@"0"` is stored-only passthrough; `fast` and `@"1"`–`@"9"`
  are the same L1-class match finder (single-slot table, fixed-Huffman or
  stored blocks — the klauspost level-1 lineage). `ratio` returns
  `error.Unimplemented`. A level-5 request compresses exactly like a
  level-1 request today. The distinct middle/high levels (lazy matching,
  hash chains, dynamic-Huffman block emission) and a real `ratio` level
  are unbuilt.
- Preset dictionaries (zlib §3.1.1's `FDICT` + the 32 KiB preset history):
  not supported. Streams are rejected downstream (`DictionaryRequired` in
  the zlib container), and flate's decode has no preset-history entry
  point at all.

## gzip — complete for what it does

- One-shot and streaming both directions, over the flate encoder above —
  **inherits flate's level plateau** (`.@"1"`–`.@"9"` all L1-class).
- Multi-member decode (`Reader.streamAll`), single-member
  (`streamMember`), exact boundary, FHCRC verified, optional fields
  skipped streaming on decode.
- Encode emits the deterministic header only: FLG=0, MTIME=0, OS=255.
  No caller options for name/comment/mtime/extra — a deliberate
  determinism choice, but callers wanting gzip metadata have no path.

## zlib — complete minus dictionaries

- Same shape as gzip: one-shot and streaming both directions, the FCHECK
  and FLEVEL arithmetic, exact boundary, Adler-32 verified, the
  `DictionaryRequired` refusal.
- Preset dictionaries rejected, never skipped (the compliance stance);
  encode never emits FDICT. **Dict-supplying and dict-decoding are the
  gap** — both the `zlib` API and the flate preset-history entry point
  underneath it.

## zstd — decode complete, encode absent (M5, in research)

- Decode: full — all descriptor forms, window sizes to the comptime
  buffer cap, skippable frames, the multi-frame walk, XXH64 verified
  (the u64-counted kernel), amplification limits, the 32-bit proofs
  (`just check-32`). Namespace is `{Reader, decode}`.
- **No encoder.** `Writer` and `encode` do not exist. M5 (fast level,
  CLI-level-1-compatible output) is in research now.
- Dictionaries: `DictionaryRequired` on decode (fail-closed); nothing on
  encode. zstd dictionaries (RFC 8878 §5 — the dictionary format, the
  entropy tables + the content section) are a real feature lift, not a
  flag flip: the decoder needs the dictionary's content as preset
  history and its entropy tables as the frame's starting state.
- `.ratio` seat: flate's reserved `ratio` precedent — a future
  high-ratio zstd encoder level is unstarted.

## brotli — absent (M6, in research)

The RFC 7932 vendoring and requirements document are in flight. The
static dictionary (122 KiB + the 121 transforms) is the research's
sizing question.

## Cross-cutting gaps, ranked by user impact

1. **zstd encode** (M5, research in flight) — the biggest single absence;
   every other shipped codec encodes.
2. **Dictionaries everywhere they apply**: zlib preset dicts (rejected),
   zstd dicts (rejected on decode, nonexistent on encode), brotli's
   static dictionary (the M6 research owns the decision). User-supplied
   dictionaries are a cross-codec feature, not one codec's gap.
3. **Dictionary training** (low priority, orthogonal): the tool side —
   given a corpus of samples, produce a tuned dictionary. Orthogonal to
   codec support: the `zstd` CLI can generate trained dictionaries today,
   so the requirement on zcompress is *consuming* them — the dictionary
   format as an API (`load`/parse the CLI-produced dictionary, hand it to
   the encoder and decoder). The in-repo trainer (the COVER-style corpus
   selection) is a nice-to-have after that, not a dependency.
4. **flate's level distinctness**: 1–9 are the same encoder. gzip and
   zlib inherit the plateau. The middle levels (lazy matching, dynamic
   block emission) are the classic flate ladder — unbuilt. The real
   `ratio` seat too.
5. **brotli** (M6, research in flight).
6. **gzip metadata options on encode** (name/comment/mtime) — the
   deterministic header is a choice; an options struct could carry
   opt-in metadata without breaking the default.
7. The `s2` extensions (the snappy-compatible better-compression format):
   explicitly post-M6, only if wanted (the plan's decision).

## Demo candidates (not gaps)

- **wasm32-freestanding build of the codecs**: pure functions over caller
  buffers, no OS or allocator in the codec paths, 32-bit safety already
  proven by the standing gate — the browser target is an export wrapper
  plus JS glue (~a day, mostly glue). The Buffer-based APIs are the
  natural wasm surface (JS owns the ArrayBuffers); a `simd128` per-model
  arm is a later perf question. Low priority, after the real milestones.

## What is deliberately NOT a gap

- Zero allocation on hot paths (the codecs allocate nothing; the
  zstd streaming buffer is caller-supplied, `streamAllAlloc` owns the
  convenience allocation explicitly).
- The `anytype`-free, exact-pointer buffer APIs — landed policy, not
  missing flexibility.
- The fleet/CI measurement surface — four committed fleet runs, the
  standing 32-bit execution gate, the 12-target fuzz coverage for zstd
  and per-codec targets before it.
