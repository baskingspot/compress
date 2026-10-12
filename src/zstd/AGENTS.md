# Agent notes: zstd

A Zstandard decoder (RFC 8878). `README.md` is the user overview; this file keeps
the decisions, errata, and oracle notes behind it. Decode only: there is no
`encode.zig`, `Writer.zig`, or external-oracle lane (`oracle.zig`,
`scripts/zstd_oracle.py`, `just zstd-oracle`); the encoder is M5.

Research is `docs/research/zstd-notes.md` (zstd-notes): `OQn` are its §7 design
questions, `Tn` its §4 divergence rows. `§` cites are sections of
`docs/research/specs/rfc8878-zstd.txt`. zstd frames itself and owns its checksum,
so the container questions gzip answered recur inside this namespace;
`src/gzip/AGENTS.md` ("The wrapping design") states them once. The Io contracts
are in `src/internal/AGENTS.md`. The reader instantiates `internal.reader.VTable`
directly, not the container driver.

## Design decisions

- **The surface is `{decode, Reader}`.** `Writer` and `encode` are absent, not
  stubbed, and join later without reshaping these two; the encoder states its own
  contracts (`maxCompressedLength`, `Options`, a ratio). `decode` also exposes the
  layer modules because the one-shot and the reader are built from them and the
  tests pin the same functions.
- **The window is the caller's and comptime-sized (OQ1).** A frame declares its
  own window, 1 KB to 3.75 TB (§3.1.1.1.2); flate's is a fixed 32 KB.
  `Reader.init` takes the exact `Buffer(window_len)` type and reads the cap from
  it, so buffer and cap cannot disagree; a runtime `window_len` was rejected
  (exact-pointer buffer types are the house rule). A larger declared window fails
  `WindowTooLarge` before any block byte, never a silent truncation. The default
  is 8 MiB: the RFC's recommended floor, and what `zstd -19` declares on large
  input. The one-shot's history is `target`, so it has no cap and `WindowTooLarge`
  is not in its error set.
- **One frame per reader, at the exact boundary (OQ3, T10).** gzip's member
  decisions mapped over: `Reader` consumes `input` through the frame's last byte
  and stops, `streamAll` is the walk at that boundary, and the one-shot decodes
  one frame and ignores what follows. Empty-input, skippable-frame, and
  trailing-garbage behavior is the README's and follows the CLI. A skippable
  Frame_Size is streamed past, never staged (gzip's XLEN rule).
- **Dictionaries are refused, never skipped (OQ4, T11).** A nonzero
  Dictionary_ID_Flag is `DictionaryRequired` at the first Dictionary_ID byte,
  raw-content dictionaries included: §2 requires an unambiguous error for an
  unsupported parameter (the zlib FDICT precedent). No dictionary entry point
  exists; revisit if a use case lands.
- **The checksum rides the block emission funnel (OQ7, T8).**
  `frame.State.recordBlock` is the only place decoded bytes reach XXH64 (Raw copy,
  RLE splat, Compressed sequence output plus trailing literals), so each byte is
  hashed once, in order, with no second pass and no container buffer. There is no
  `flate.Checksum`-style hook. We verify: §2 allows ignoring the checksum, but
  every working reference verifies and std's verification is a documented panic.
- **A compressed block is staged whole before it is decoded (OQ6).** Both
  backwards bitstreams (sequences §3.1.1.3.2.1.2, each Huffman literals stream
  §4.2.2) read from the block's end, so the format needs the last byte's offset
  first. The reader stages into the `Buffer`'s trailing room and bounds every
  read by that region, never by the input's or the frame's end (§8's vector: a
  Number_of_Sequences that reads past the block). Literals decode into one
  comptime `[max_block_size]u8` stack scratch and sequences execute from it
  (§3.1.1.3.1: "decoded first and then copied"). That 128 KiB is the only large
  stack local, which is why staging lives in the `Buffer`. Perf follow-ups not
  taken: reading Raw blocks straight from `input` (they are staged like the
  rest) and writing a literals-only frame's literals straight into `target`
  (they go through the scratch).
- **The frame end runs in one place.** `Reader.endFrame` (Frame_Content_Size
  check, trailer verify, boundary advance) is reached from the pump and from
  `rebase`. An over-the-end `peek` at a frame's tail must not report the end with
  the trailer unread: the wrapper-rebase bug class of fca3604, described in
  `src/internal/AGENTS.md` ("A wrapper's rebase routes the inner end through the
  same ending as fill"). Pinned by the test "an over-the-end request still checks
  the trailer" and the fuzz ops `over_end_peek` and `over_buffer_peek`.
  `recordBlock` also enforces Frame_Content_Size as a running bound (§8's
  smaller-than-actual vector); the declaration never sizes anything.
- **Counts are 64-bit; the pumps' are not.** `frame.State.decoded_len` and
  `xxh64.State.byte_count` are `u64`. A frame's output has no `usize` bound:
  131 KB of RLE blocks decodes to over 4 GiB in constant memory. A `usize` count
  wraps on 32-bit targets (a panic in safe builds, UB or a false `WrongChecksum`
  in ReleaseFast), which is also why `xxh64.zig` is our kernel and not std's
  `XxHash64`. `just check-32` runs the two large frames (`probe32.zig`) on
  wasm32-wasi under wasmtime, ReleaseSafe so a wrap panics, because a 64-bit host
  cannot see either wrap; comptime type pins in the `Reader.zig` tests catch a
  revert on every host. The pumps count in `usize` inside std's `streamRemaining`,
  a std-level limit; tests drive `Reader` with a `u64` count (`drainU64`).
- **One error name per corruption class (OQ5).** Checksum and
  Frame_Content_Size mismatches stay separate names. A structure that runs past
  its staged block is its own error, never `Truncated` (the input ending before
  the frame does). `BufferTooSmall` is the one-shot's alone: the reader frees
  Block_Maximum_Size before each block, so there it asserts, and reports
  `BlockOversize` where assertions are off. `decode.zig` and `Reader.zig` pin
  their error sets at comptime, so a new name fails the build until both lists
  are updated; update the README's list too.
- **The `*Alloc` pumps are the only allocator use in the API.** The primitives
  take caller buffers, and there is no stack-buffered default-window pump (a
  `DefaultBuffer` is 8 MiB + 256 KiB). No decode path allocates.

## Errata register

RFC 8878 is not self-consistent (zstd-notes §0). The vendored file is verbatim, so
it carries the errata'd text; tests and fixtures that touch one say so in a
comment.

- **6441 (Verified).** Each Appendix A table opens with a spurious all-zero
  state-0 row; the real state-0 entries are the second rows. The fixtures drop
  one row per table (64 + 64 + 32 real rows). T2.
- **6442 (Verified).** Table 18's second-to-last row has offset_value 1; it must
  be 3 (the literals_length == 0 corner). Derive repeat-offset expectations from
  §3.1.1.5's rules, never from the table's cells. T3.
- **7297 (Verified).** 4-stream literals need 6-1023 / 6-16383 / 6-262143
  regenerated literals, not 0-1023 / 0-16383 / 0-262143: the fourth stream's size
  underflows below 6. Enforced as `LiteralsTooLarge`. T4.
- **8195 (Reported; proven here).** §4.2.2's worked example encodes "0145" as
  `10 0D` using Table 26's codes (5 is 0000, 4 is 0001). That contradicts Table 25
  and §4.2.1.3's rule (4 is 0000, 5 is 0001), which is normative: the C CLI and
  std decode `01 0D` to `00 01 04 05` and the example's `10 0D` to `00 01 05 04`.
  The `pair_*` and `frame_pair*` fixtures (hand-built 19-byte frames, zstd-notes
  §5.4) pin both; no test asserts the example's claim. T1.
- 7567, 8085, and 8668 are editorial or Reported only. 8085 argues Table 18's last
  row should read 1111; the vendored text stands.

## Deliberate differences from the references

zstd-notes §4 records the RFC text, the C, klauspost, and std for each row. Where
ours differs from a reference it is on purpose; do not "fix" it to match.

- **T5: a decoded-zero sequence count is accepted.** §3.1.1.3.2.1 ends the section
  only on `byte0 == 0`; the C also ends it on the 2-byte `80 00` (its
  `zeroSeq_2B.zst`). std rejects it. Bytes after a zero count are
  `BitstreamNotConsumed` (the C: "extraneous data").
- **T6: offset 0 is `ZeroOffset`.** The RFC never calls it invalid, but the
  repeat arithmetic can produce it. The C and std reject; klauspost substitutes
  offset 1 and decodes a corrupt frame.
- **T7: `BlockOversize` is the one name for the window/block coupling.**
  Block_Maximum_Size bounds compressed size too, so a single-segment frame with a
  small Frame_Content_Size cannot carry a compressed block. The C says "Src size
  is incorrect".
- **T9: FSE distributions.** The budget must land exactly on `1 << Accuracy_Log`;
  the symbol count may fall short of the context's, never exceed it (§4.1.1's
  "not equal to the expected", read literally, rejects short tables the reference
  encoder emits). Fewer than two nonzero-probability symbols is also
  `MalformedFseTable`; the C does not check that, and the reference encoder uses
  RLE mode instead.
- **T12: the window bound is the addressable span at the match.** §3.1.1.4 says
  offsets "must be smaller than Window_Size"; the C's whole-buffer decoder checks
  the history it holds instead. Ours is the retained history plus the block's own
  writes: an offset equal to Window_Size reads the oldest retained byte, and one
  past it is fine when the block's own output makes the byte addressable
  (`frame_window_1k_span`, which the CLI also decodes). The `frame_window_*_over`
  pair is `OffsetTooFar` here and decodes in the C. `block.zig` carries the rule
  where it is enforced.
- **T13: a zero-size Compressed_Block is `MalformedLiteralsHeader`.** The C reads
  it as a no-op; ours has no literals header to read.
- **T14: Frame_Content_Size 2^64-1 is a declaration like any other.** A frame
  declaring it fails `ContentSizeMismatch` unless it decodes that much; the C
  reads it as "unknown" and skips the check.
- **T15: Huffman code lengths over 11 bits are `MalformedHuffmanWeights`** (the
  RFC's cap). The C accepts 12.

## Testing

- `golden.zig` holds the shared fixtures; its header and group comments give
  provenance. Each fixture's doc comment records the zstd CLI v1.5.7 verdict (the
  bytes it decodes to, or the failure), so fixtures are conformant frames, not
  self-consistent guesses. Check a new fixture with the CLI before adding it, and
  say in the comment where ours deliberately differs.
- The bad-frame corpus is `bad_rows` in `fuzz.zig`: the negative `golden.zig`
  frames, each with its pinned error and written floor (the bytes the frame
  legitimately wrote before it failed).
- Upstream's `tests/` corpus (v1.5.7) was run through the CLI during research and
  none of it is vendored; `golden.zig` recreates the shapes (zstd-notes §5.1). Not
  done: `decodecorpus.c` frames, klauspost's `headers.zip` (the nearest
  frame-layer conformance table), `bad.zip`, and `regression.zip` (§5.2), and
  `playTests.sh`-style CLI conformance.
- Fuzz is `just fuzz 10M`; `fuzz.zig`'s header lists the five targets. Two
  properties run through them: the one-shot and the reader agree on every input
  (same bytes or the same named error, `WindowTooLarge` excepted), and the
  reader-machinery target asks past a frame's tail so the trailer step runs
  through `rebase`.

## Oracles

- **zstd CLI v1.5.7** (the flake's) is the fixture oracle: `zstd -d -c` and
  `zstd -t` verdicts, `zstd -l -v` for Window Size and Check. A flipped trailer
  byte fails `zstd -t` with `Decoding error (36) : Restored data doesn't match
  checksum`.
- **CPython 3.14 `compression.zstd`** (libzstd): `ZstdDecompressor` over
  concatenated frames leaves the next frame in `unused_data`, the exact-boundary
  check.
- **`std.compress.zstd`** (0.16.0) is a second opinion and a divergence pin, not a
  fixture source: it ships no tests or testdata. `std.hash.XxHash64` is the
  differential oracle for `xxh64.zig` (zstd-notes §3).
- **klauspost/compress zstd v1.18.0-5** (`DecodeAll`, from a scratch Go module) is
  the third opinion. Divergence: T6.
- No external-oracle lane exists, unlike flate, gzip, and zlib. The CLI
  incantations were run by hand while the fixtures were built (zstd-notes §5, §6).

## Performance

- `just bench` runs `bench.zig` (`just corpus` first). Claims cite a recorded
  fleet run under `docs/results/` (`m4-*`, `zstd-wave2-*`), never local numbers.
- The streaming direction is not a bench row: a streaming row in the bench binary
  shifts the one-shot rows through code layout (flate tried one and reverted it).
  Time it through the example pump, `just example zstd decode <file>`.
- Thread stack: the one-shot and the reader both need about 161 KiB in ReleaseFast
  and 206 KiB in Debug; the 128 KiB literals scratch is the floor. To re-measure,
  decode in a `std.Thread.spawn(.{ .stack_size = N })` thread and bisect on the
  segfault (aarch64 Linux, glibc; the window buffer is static, so only the
  decoder's frames count). Re-measure after changes to the compressed-block path
  and keep the README's figures in step.

## Provenance

facebook/zstd v1.5.7, klauspost/compress v1.18.0-5, and Zig's `std.compress.zstd`
(0.16.0) were read and run as oracles; no code is copied, and fixtures are data.
`xxh64.zig` follows std's `XxHash64`. Attribution is `THIRD_PARTY.md`.
