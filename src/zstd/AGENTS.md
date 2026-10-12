# Agent notes: zstd

A Zstandard codec (RFC 8878): a decoder (landed) and a fast encoder (the design
in "The encoder"; `encode.zig` and `Writer.zig` do not exist yet). `README.md` is
the user overview; this file keeps the decisions, errata, and oracle notes
behind it. There is no external-oracle lane yet (`oracle.zig`,
`scripts/zstd_oracle.py`, `just zstd-oracle`); the encoder's oracle plan is
below.

Research is `docs/research/zstd-notes.md` (zstd-notes) for the decoder — `OQn`
are its §7 design questions, `Tn` its §4 divergence rows — and
`docs/research/zstd-encoder-notes.md` (zstd-encoder-notes) for the encoder:
`EQn` are its §3 design questions, `TEn` its §5 divergence rows, and its §1.1
`ZE` matrix is the compliance list (our decoder's every error name is an encoder
MUST). `§` cites are sections of `docs/research/specs/rfc8878-zstd.txt`. zstd
frames itself and owns its checksum, so the container questions gzip answered
recur inside this namespace; `src/gzip/AGENTS.md` ("The wrapping design") states
them once. The Io contracts are in `src/internal/AGENTS.md`. The reader
instantiates `internal.reader.VTable` directly, not the container driver; the
writer will instantiate `internal.writer.VTable`.

## Design decisions

- **The surface is `{encode, decode, Writer, Reader}`.** The decoder's `decode`
  exposes the layer modules because the one-shot and the reader are built from
  them and the tests pin the same functions; the encoder keeps its block layer
  internal (a zstd block is not self-contained) and exposes `Level`, `Options`,
  `maxCompressedLength`, and `compress`. The encoder's contracts are "The
  encoder" below.
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

## The encoder

The fast level (M5), the CLI's level-1 byte class. zstd-encoder-notes is the
research: its §1.1 `ZE` matrix is the compliance list (every `Reader.Error` name
is an encoder MUST our output must never trip, so the day-one conformance test
is "no error name except `BufferTooSmall` is reachable on our own output"), its
§2 the reference study, its `EQn` the design questions. Every choice below is
the C v1.5.7's unless a `TE` row says otherwise; the notes' §0 records the C
checkout and the survey tooling.

- **The match finder (EQ1, EQ2).** Greedy, the C's `ZSTD_fast` shape: a
  single-slot position-only `u32` table, last writer wins
  (`zstd_fast.c:271-272`); `hashLog = min(15, windowLog + 1)`
  (`zstd_compress.c:1564`); `mls` 6 (the ≤ 128-KiB class's hash width,
  `hash6`'s prime multiply, `zstd_compress_internal.h:930-948`); candidates are
  verified with a 4-byte compare (`ZSTD_match4Found_cmov`, `zstd_fast.c:103-125`),
  so emitted matches are at least 4 bytes. The repcode pre-check at +2
  (`:267-290`) lets a rep match beat the table candidate two bytes ahead; its
  backward extension stops one short of `nextEmit` (`:278-279`), so the hot
  path never emits a zero-literals repcode and never meets §3.1.1.5's ll0
  shift. The scan step starts at 2 and grows by 1 per 128 unmatched bytes
  (`kStepIncr = 1 << (kSearchStrength - 1)`, `:234,341-347`). After a match the
  table is filled at `current+2` and `ip0-2` (`:404-408`), then the offset-2
  immediate-repeat chain runs (`:410-420`), swapping rep1/rep2 per zero-literal
  sequence. Reps outside the window are zeroed before the loop and restored
  after (`:238-243,355-372`), so the emitted history stays decodable. No lazy
  matching (the C's lazy starts at level 5-6); the rep pre-check and the
  offset-2 chain are the only lookahead. The extension reuses the flate port's
  word-XOR machinery.
- **The block layer (EQ3).** Blocks of `min(128 KiB, 1 << windowLog)`
  (`zstd_compress.c:1816`; TE2). The C's fallback ladder: inputs under 7 bytes
  are stored raw (`:3273`); a compressed block is kept only if
  `cSize < blockSize - minGain`, `minGain = (blockSize >> 6) + 2` at fast levels
  (`zstd_compress_internal.h:677-683`, applied `zstd_compress.c:3033`), else
  the block is raw; a whole-block one-byte repeat becomes an RLE block
  (`ZSTD_isRLE`, `:3572-3589`) except as the frame's first block
  (`rleMaxLength = 25`, the zstd ≤ 1.4.3 CLI compatibility rule, `:4424-4433` —
  TE3); an all-literals block gets a `nbSeq == 0` sequences section. The
  minGain margin is also ZE9's safety: a compressed block's `cSize + 3` stays
  under a single-segment frame's FCS-sized Block_Maximum_Size. The empty input
  is one raw 0-size Last_Block plus the trailer (13 bytes, the CLI's empty
  frame).
- **The literals ladder (EQ4).** Raw below 64 literals (fast strategies; 6 with
  a reusable tree — `zstd_compress_literals.c:114-127`) or when Huffman misses
  minGain (`:187-191`); RLE for one-byte literals (`:81-107,192-201`);
  Compressed with a tree description — one stream below 256 literals, four
  above, the 3/4/5-byte header by the 1-KiB/16-KiB thresholds (`:140,142`), the
  split at `(Regenerated_Size+3)/4` (`huf_compress.c:1168-1215`); Treeless when
  the previous tree still validates (`:180-184`, ZE20). The 11-bit depth cap
  (`LitHufLog 11`, `zstd_internal.h:101`) is enforced while building the tree
  (`HUF_setMaxHeight`, `huf_compress.c:376-493`), so the serialized weights
  cannot exceed it (ZE14).
- **The Huffman writer.** The inverse of the decoder's `readTree`: weights for
  literals 0..maxSymbolValue-1, the last implied by the power-of-2 completion
  (§4.2.1); direct mode when the last symbol is at most 128
  (`op[0] = 128 + maxSymbolValue - 1`), else FSE mode with the weight series in
  exactly `headerByte` bytes (`HUF_writeCTable_wksp`, `huf_compress.c:248-289`),
  the FSE form preferred when it is under half the direct form (`:273-288`).
  The weight FSE (`HUF_compressWeights`, `:147-197`) is a §4.1.1 description
  (accuracy at most 6) plus one bitstream whose two interleaved states read the
  weights in reverse (`fse_compress.c:551-640`); all-equal weights take RLE,
  all-unique weights are not compressible. Codes follow §4.2.1.3's assignment
  (`valPerRank`, `huf_compress.c:327-339`) — errata 8195's worked example is
  wrong, and the T1 pair (`01 0D`) is the day-one byte-exact golden. Each
  literals stream writes its symbols in reverse with a single 1-bit end mark
  (`:991-1013,823-915,962-983`); the last byte is never zero (ZE7).
- **The sequences ladder (EQ5).** nbSeq in its 1/2/3-byte forms
  (`zstd_compress.c:2942-2950`). Per alphabet, the C's fast-strategy heuristic
  (`ZSTD_selectEncodingType`, `zstd_compress_sequences.c:157-235`): RLE when
  one symbol carries all sequences, except `nbSeq <= 2` prefers Predefined
  (`:166-178`, TE5); Repeat while a table is valid and `nbSeq < 1000`
  (`:187-191`); Predefined below the `defaultNormLog` thresholds (36 OF, 72
  LL/ML) or when the distribution is skewed (`:181-184,192-193`); FSE
  otherwise. Accuracy_Log: clamp `highbit(nbSeq-1) - 2` into `[minBits, cap]`
  (`FSE_optimalTableLog`, `fse_compress.c:357-373`), caps 9/8/9 for LL/OF/ML.
  The norm is `FSE_normalizeCount` (`:465-533`), the low-probability value 1
  until `nbSeq >= 2048` (`ZSTD_useLowProbCount`,
  `zstd_compress_sequences.c:57-64`, TE1). The description writer
  (`FSE_writeNCount_generic`, `fse_compress.c:234-329`) is the exact inverse of
  our `readDescription`, including Table 20's width descent and the 0xFFFF
  zero-run shortcut; the budget lands exactly (ZE13). The bitstream writer
  (`ZSTD_encodeSequences_body`, `zstd_compress_sequences.c:291-382`): the last
  sequence's states initialize first and flush ML, OF, LL; the last sequence's
  extra bits sit at the stream's low end; then sequences `nbSeq-2..0` write
  transition bits OF/ML/LL and extras LL/ML/OF. The last sequence's code count
  is decremented before normalizing (`:271-274`).
- **The FSE table builder.** `FSE_buildCTable_wksp` (`fse_compress.c:68-225`)
  builds the encode-side table by §4.1.1's exact construction — the
  low-probability symbols' single cells from the table's end, the rest spread
  with `position += (tableSize >> 1) + (tableSize >> 3) + 3` — so its symbol
  column IS the decode table's. Only the norm goes on the wire, so the
  round-trip gate is: our writer's norm → our reader's `readDescription` → the
  table the encode side built. That runs in-process; the external half is the
  CLI decoding frames that carry our tables.
- **The frame header and window ladder (EQ6).** One-shot: the exact
  Frame_Content_Size always, in the smallest form (§3.1.1.1.4; the 2-byte form
  is size-256 for 256..65791, 4 bytes below 2^32-1, 8 bytes at and above); the
  checksum always on (the CLI's default, the corpus blobs' class);
  Dictionary_ID_Flag 0; single-segment iff the input fits the window; windowLog
  `min(19, nextPow2(srcSize))` with floor 10 (the C's effective level-1 ladder,
  `zstd_compress.c:1473-1586`); descriptor bits 4 and 3 zero (ZE2/ZE3). The
  streaming form declares no FCS (it cannot know the length when the header
  goes out) and `1 << window_log`, never 2^64-1 (T14: our own decoder reads the
  sentinel as a declaration and would reject our output).
- **The streaming Writer (EQ7).** The Reader's mirror: one caller-owned
  `Buffer(window_log)` holding the retained history (`1 << window_log`), the
  block staging (`min(128 KiB, 1 << window_log)`), and the hash table
  (`4 << min(15, window_log + 1)` bytes) — all comptime from `window_log`, the
  exact-pointer `init`. The frame header is lazy: `emitBlock` writes it if it is
  not yet written, so it goes out with the first drain/flush/rebase or with
  `finish`; a zero-length emission (a flush with nothing buffered) writes the
  header and no block. `flush` emits the buffered data as one complete block —
  a zstd block boundary is a decode boundary, so a decoder reading the output
  so far decodes every byte written — and only `finish` writes Last_Block and
  the trailer (the poisoned-finish machinery, `src/internal/AGENTS.md`). The
  checksum hashes each input chunk as it is consumed at the one funnel (the C's
  per-chunk `XXH64_update`, `zstd_compress.c:4608`). `window_log` is 10 to 31
  (u32 positions); the recommended ladder caps at 19, inside the decoder's
  default 8 MiB.
- **The one-shot (EQ8).** `encode.compress(source, target, options)`: the
  source IS the history, so no window buffer and no allocation.
  `maxCompressedLength(n) = n + 3 * (n / 131072 + 1) + 18` (a 14-byte header
  cap, 3 bytes per block, the 4-byte checksum), always inside
  `ZSTD_COMPRESSBOUND` (`zstd.h:249`). The block layer stays internal: no zstd
  block function is self-contained (cross-block entropy and repeat-offset
  state), unlike snappy's and flate's. `Level = enum { fast, ratio }`: `.fast`
  is the level-1 class, `.ratio` is reserved and returns
  `error.Unimplemented` (the flate pattern, never a silent alias); the numeric
  CLI ladder gets no seats — each of levels 2-22 is a distinct output class
  this package cannot produce. `Writer.streamAll` and `Writer.streamAllAlloc`
  mirror the Reader's pumps (the caller-buffered pair first, then the
  default-window allocation); there is no stack-buffered default pump.
- **The scratch.** Per-block scratch (literals up to 128 KiB, the sequence
  store, the entropy workspace) is comptime stack in the emission path; the
  caller's `Buffer` holds the window, the staging, and the table (EQ7). The
  stack budget is measured with the implementation and lands in the README
  beside the decoder's figures.
- **The emission survey (verified).** The pinned CLI's `-1` output over the
  corpus and the survey inputs: Raw literals on match-rich data; Predefined
  sequences for small nbSeq; FSE at the 9/8/9 caps for large nbSeq; RLE blocks
  only after the first block; Raw blocks at exactly Block_Maximum_Size for
  incompressible data; single-segment frames with the exact FCS for everything
  under the window; the 1-MiB files windowed (descriptor `0x48`, 512 KiB) in 8
  blocks of 128 KiB. The target byte class is the CLI's; the TE rows are the
  only deliberate departures.

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

### The encoder's register (TE1-TE6)

zstd-encoder-notes §5, decisions as landed: the CLI's byte class is the target
unless a row says otherwise. Each row records the C's rule against klauspost's;
the C's wins, so the survey's class and the corpus fixtures stay in one family.

- **TE1 — the low-probability cell value.** 1 until `nbSeq >= 2048`, then -1
  (`ZSTD_useLowProbCount`, `zstd_compress_sequences.c:57-64`); klauspost always
  writes -1.
- **TE2 — the block size.** 128 KiB (`zstd_compress.c:1816`); klauspost 64 KiB
  at SpeedFastest.
- **TE3 — the first block's RLE.** Suppressed, the C's zstd ≤ 1.4.3 CLI
  compatibility rule (`zstd_compress.c:4424-4433`); klauspost allows it.
- **TE4 — all-literals blocks.** Huffman is attempted (the C's
  `suspectUncompressible` heuristic, minGain arbitrates,
  `zstd_compress.c:2886,2924`); klauspost's level 1 stores them raw.
- **TE5 — tiny-nbSeq mode choice.** Predefined over RLE at `nbSeq <= 2`
  (`zstd_compress_sequences.c:168-175`); klauspost goes RLE.
- **TE6 — the `nbSeq == 0` form.** The 1-byte section (byte0 == 0), as both
  references write it; our decoder also accepts the 2-byte decoded-zero form
  (T5), which our encoder never emits.

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
- **The encoder (the M5 plan).** Round-trip gates first: our writer's norm
  through our reader's `readDescription` (the FSE round-trip gate, in-process),
  writer → reader identity over the corpus, the CLI decoding our frames
  byte-exact (`zstd -d -c` plus `cmp`, `zstd -t` for the trailer), our reader
  decoding the CLI's level-1 frames, and the compliance property: no
  `Reader.Error` name except `BufferTooSmall` is reachable on our own output,
  one-shot and reader alike. The fixture plan: our level-1 output over the
  corpus shapes recorded in `golden.zig` with the CLI's and our decoder's
  verdicts in the provenance comment (the M4 fixture rule), plus the T1
  `01 0D` pair as the Huffman path's day-one byte-exact golden (encode the
  four literals, compare the whole 19-byte frame). Fuzz targets (the fuzz
  lane's): our encode → our decode identity, our encode → CLI decode
  byte-exact, and the compliance property.

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
- **The encoder's oracle set.** The CLI is the encoder oracle too: `zstd -1 -q
  -k -f SRC -o OUT` is the class reference, and our output passes `zstd -d -q
  -c` plus `cmp`, `zstd -t`, our own example decode, and CPython 3.14's
  `compression.zstd` one-shot (libzstd v1.5.7; the module-level function per
  frame — a `ZstdDecompressor` object is stateful and single-frame).
  klauspost's encoder is a read-and-run reference, not a gate: its level-1
  class deliberately differs (TE1-TE5). `zstd.compress(src, level=1)` is
  byte-identical to `zstd -1 --no-check` (verified), so the bench harness's
  ratio arm can use the CLI. The structural check is the survey's scratch frame
  walker (not repo code): exact frame consumption, nonzero backwards-stream
  ends, the mode census.
- No external-oracle lane exists yet, unlike flate, gzip, and zlib. The CLI
  incantations were run by hand while the fixtures were built (zstd-notes §5,
  §6; zstd-encoder-notes §4 for the encoder's).

## Performance

- `just bench` runs `bench.zig` (`just corpus` first). Claims cite a recorded
  fleet run under `docs/results/` (`m4-*`, `zstd-wave2-*`), never local numbers.
  The encoder's bench arm (encode rows against the CLI and klauspost) is the M5
  addition; the fleet's zstd-c driver is decode-only today.
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
`xxh64.zig` follows std's `XxHash64`. The encoder's algorithms were read from
the C's `zstd_fast.c`, `zstd_compress.c`, `zstd_compress_literals.c`,
`zstd_compress_sequences.c`, `fse_compress.c`, and `huf_compress.c`, and from
klauspost's `zstd/enc_fast.go`, `zstd/fse_encoder.go`, and `zstd/blockenc.go`.
Attribution is `THIRD_PARTY.md`.
