# Agent notes: zstd

A Zstandard codec (RFC 8878): a decoder and a fast encoder, both complete —
one-shot (`encode.zig`), streaming (`Writer.zig`), over the block layer
(`block_compress.zig`) and the match finder (`match_compress.zig`). `README.md`
is the user overview; this file keeps the decisions, errata, and oracle notes
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

- **The surface is `{encode, decode, Writer, Reader}`, complete.** The
  decoder's `decode` exposes the layer modules because the one-shot and the
  reader are built from them and the tests pin the same functions; the encoder
  keeps its block layer internal (a zstd block is not self-contained) and
  exposes `Level`, `Options`, `maxCompressedLength`, `compress`, and
  `compressBuffered` with `encode.Buffer`. `compressBuffered` is the addition
  the stack budget forced (below): the sketch's API block named only
  `compress`, and the name follows the reader's `streamFrame`/`streamFrameAlloc`
  shape — a caller-owned buffer instead of the default allocation. Both encode
  functions are byte-for-byte the same frame; only the stack differs. The encoder's contracts are "The
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
  Decoded bytes reach XXH64 exactly once, in order, with no container buffer.
  RLE and Compressed blocks fold in `frame.State.recordBlock`, handed exactly
  the bytes the block wrote. Raw blocks are the one exception: their output is
  the staged bytes verbatim, so `block.decodeRaw` folds each 4 KiB chunk into
  the checksum right after copying it, while the source bytes are still
  cache-hot, and the frame records the block with `State.recordRawBlock`
  (accounting only). Folding a whole Raw block after the whole copy re-reads
  up to 128 KiB; the interleave was the measured win on incompressible
  corpus shapes (4 KiB beat 8/16/64 KiB chunks locally; 16 KiB was flat, 64
  KiB negative). The digest is chunk-boundary-independent, pinned by the
  checksummed raw-block frame tests in `frame.zig` and `Reader.zig`. There is no
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

**The one-shot is landed and byte-identical to the CLI's level 1.**
`encode.compress` over the corpus shapes (32 KiB, 64 KiB, and the seven 1-MiB
survey shapes) reproduces `zstd -1 -q -k -f`'s whole frame, byte for byte, and
a 232-case sweep (every corpus shape at 32 sizes plus PRNG bytes) is 228
byte-identical, the four exceptions being the Huffman tree's tie order alone
(`huff0_compress`'s stable sort against the C's quicksort; same frame size,
verified in the sweep below). The tests pin the CLI's own bytes for eleven
inputs (`golden.zig`'s `encode_*` group): the text/html/rle corpus shapes at
both sizes, the `words`/`skewlit` shapes' first 4 KiB (the entropy paths),
the tiny class's 100- and 1024-byte text, and a 600 KB text frame (windowed,
five blocks). The CLI's verdicts on all eleven: `zstd -d -c` byte-exact,
`zstd -t` clean, CPython 3.14 `compression.zstd` byte-exact.

- **The entropy writers (landed).** `fse_compress.zig`, `huff0_compress.zig`,
  `sequences_compress.zig`, `literals_compress.zig`, and the writer inverses in
  `bits.zig` (`ForwardWriter`, `BackwardWriter`). Each layer round-trips
  through the landed decoder, and three of them are pinned against the C's own
  bytes: `writeDescription` reproduces `golden.zig`'s recorded
  `FSE_writeNCount` output for two real distributions and the weights fixture,
  `writeTree` reproduces the RFC's worked example and the recorded
  `HUF_compressWeights` series, and `sequences_compress.write` reproduces a
  real `zstd -5` frame's Predefined-mode section byte for byte. The encode
  table's `step` is the C's `FSE_encodeSymbol` (the inverse of
  `fse.State.update`: the source state, its Num_Bits, and
  `destination - baseline`), and its start state is `FSE_initCState2`'s — the
  smallest state whose cell holds the symbol. Three deliberate departures,
  all on the writer's side: the tree sort keeps natural symbol order among
  equal counts where the C's bucket sort is unstable (deterministic output);
  the four-stream floor is errata 7297's 6 regenerated literals, not the C's
  12-literal cost heuristic (a 10-literal four-stream section is legal and the
  fixture carries one); and the `bits.zig` writers cap a field at 31 bits and
  flush whole bytes only, which changes when bytes leave the accumulator but
  never the stream's bits.
- **Repeat_Mode is unreachable without a dictionary.** The C's fast-level
  ladder selects Repeat only while the previous table is `FSE_repeat_valid`
  (`zstd_compress_sequences.c:187-191`), and the only promotion to `valid` is
  `ZSTD_dictNCountRepeat`'s, from a *dictionary's* entropy tables
  (`zstd_compress.c:5044-5058`): a frame built without one never carries the
  mode, and the survey's level-1 output never does either. The writer
  implements the mode (its sections round-trip, `Resolved` models the
  decoder's four resolutions) and the dispatch keeps the C's precondition,
  with `State.repeat_valid` the seat a dictionary would set. Do not "fix" the
  branch to fire: that would leave the CLI's byte class.
- **The match finder (EQ1, EQ2), landed as `match_compress.zig`.** Greedy, the
  C's `ZSTD_fast` shape: a single-slot position-only `u32` table, last writer
  wins (`zstd_fast.c:271-272`); `hashLog = min(class hashLog, windowLog + 1)`
  (`zstd_compress.c:1564`, the class row's own hashLog — `min(15, windowLog +
  1)` is only the ≤ 16-KB class's shape, not the rule); `mls` 5/6/7 by the size
  class (`clevels.h`'s `L`: 5 under 16 KB, 6 up to 256 KB, 7 above — see TE7);
  candidates are verified with a 4-byte compare (`ZSTD_match4Found_cmov`,
  `zstd_fast.c:103-125`), so emitted matches are at least 4 bytes. A zeroed
  table slot is "no candidate": the C's window indices start above zero
  (`ZSTD_WINDOW_START_INDEX`, `zstd_compress_internal.h:1334-1340`), while
  this port's frame offsets start at zero, so the candidate floor is
  `max(prefixStart, 1)` — without it the frame's first bytes become a
  candidate the CLI never has, and the whole output class shifts. The repcode pre-check at +2
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
- **The block layer (EQ3), landed as `block_compress.zig`.** Blocks of
  `min(128 KiB, 1 << windowLog)` (`zstd_compress.c:1816`; TE2). The C's
  fallback ladder: inputs under 7 bytes are stored raw (`:3273`); a compressed
  block is kept only if `cSize < blockSize - minGain`, `minGain = (blockSize
  >> 6) + 2` at fast levels (`zstd_compress_internal.h:677-683`, applied
  `zstd_compress.c:3033`), else the block is raw; a whole-block one-byte
  repeat becomes an RLE block (`ZSTD_isRLE`, `:3572-3589`) except as the
  frame's first block (`rleMaxLength = 25`, the zstd ≤ 1.4.3 CLI
  compatibility rule, `:4424-4433` — TE3); an all-literals block gets a
  `nbSeq == 0` sequences section. Raw and RLE blocks revert the frame's
  cross-block state (the entropy tables and the repeat offsets) to what the
  previous block left, and the checksum folds through the decoder's funnel:
  a Raw block's fold rides its copy chunk by chunk, Compressed and RLE blocks
  fold through `State.recordBlock`. The minGain margin is also ZE9's safety: a
  compressed block's `cSize + 3` stays under a single-segment frame's
  FCS-sized Block_Maximum_Size. The empty input is one raw 0-size Last_Block
  plus the trailer (13 bytes, the CLI's empty frame).
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
- **The streaming Writer (EQ7, landed).** The Reader's mirror: one
  caller-owned `Buffer(window_log)` holding the retained history
  (`1 << window_log`), the accumulating block (`min(128 KiB, 1 << window_log)`),
  the block's literals and its compressed output, the finder's table
  (`4 << min(14, window_log + 1)` bytes), and the sequence list
  (`12 * (block / 3 + 1)` bytes) — all comptime from `window_log`, the
  exact-pointer `init`. Two deviations from the sketch's byte figures, both
  deliberate: the table is `min(14, ...)` entries, not `min(15, ...)`, because
  the writer is always the *streaming* class (14 is level 1's `hashLog` for an
  unknown size, and the sketch's 15 was the one-shot ladder's cap), and the
  Buffer also carries the literals, the emission target, and the sequence list
  so the writer's own frame stays KiB-scale (the sketch listed only the first
  three; the stack measurement below is why). The finder's parameters are the
  C's streaming class, `ZSTD_getCParams(1, ZSTD_CONTENTSIZE_UNKNOWN, 0)`:
  windowLog = the caller's, hashLog 14 (clamped to `window_log + 1`), minMatch
  7 — which is what makes the CLI's `zstd -1`-over-a-pipe frames byte-identical
  (the `encode_stream_*` fixtures). The finder's table entries are
  window-relative, so a window slide rebases them (`correctTable`, the C's
  `ZSTD_window_correctOffsets` shape) — a slide costs one pass over the table
  per `min(128 KiB, window)` emitted. The flush contract, the lazy header, and
  the trailer are as sketched: the frame header is lazy — `emitBlock` writes it
  if it is not yet written, so it goes out with the first drain/flush/rebase or
  with `finish`, and a zero-length emission (a flush with nothing buffered)
  writes the header and no block. `flush` emits the buffered data as one complete block —
  a zstd block boundary is a decode boundary, so a decoder reading the output
  so far decodes every byte written — and only `finish` writes Last_Block and
  the trailer (the poisoned-finish machinery, `src/internal/AGENTS.md`). The
  checksum hashes each input chunk as it is consumed at the one funnel (the C's
  per-chunk `XXH64_update`, `zstd_compress.c:4608`). `window_log` is 10 to 31
  (u32 positions); the recommended ladder caps at 19, inside the decoder's
  default 8 MiB. The empty writer's frame is the FCS-unknown header, one raw
  zero-size last block, and the checksum (13 bytes) — the CLI's *empty* stdin
  frame is the one-shot's single-segment 13 bytes instead, because the CLI
  knows the length at the frame's end (TE12).
- **The one-shot (EQ8), landed as `encode.zig`.** `encode.compress(source,
  target, options)`: the source IS the history, so no window buffer and no
  allocation. `maxCompressedLength(n) = n + 3 * (n / 131072 + 1) + 18` (a
  14-byte header cap, 3 bytes per block, the 4-byte checksum), always inside
  `ZSTD_COMPRESSBOUND` (`zstd.h:249`). `compress` is the convenience form:
  the heavy per-block arrays (the literals, the sequence list, the finder's
  table) are a stack local, which is the 830-KiB figure the README cites.
  `compressBuffered` is the same encoder over `encode.Buffer` (768 KiB,
  caller-owned), so its thread stack is about 40 KiB; the pair exists because
  the stack local violated the house's KiB-scale rule and survived only the
  8-MiB default `ulimit -s`. The block layer stays internal: no zstd
  block function is self-contained (cross-block entropy and repeat-offset
  state), unlike snappy's and flate's. `Level = enum { fast, ratio }`: `.fast`
  is the level-1 class, `.ratio` is reserved and returns
  `error.Unimplemented` (the flate pattern, never a silent alias); the numeric
  CLI ladder gets no seats — each of levels 2-22 is a distinct output class
  this package cannot produce. The barrel is complete: `{encode, decode,
  Writer, Reader}`. `Writer.streamAll` and `Writer.streamAllAlloc` mirror the
  Reader's pumps (the caller-buffered pair first, then the default-window
  allocation); there is no stack-buffered default pump — `Writer.Buffer(19)`
  is 1.4 MiB, so a stack-buffered default is out (the `ulimit -s 8192` lesson).
- **The scratch.** Per-block scratch (literals up to 128 KiB, the sequence
  store, the entropy workspace) is comptime stack in the emission path; the
  caller's `Buffer` holds the window, the staging, and the table (EQ7). The
  one-shot's measured need on aarch64 Linux is about 830 KiB of thread stack
  (Debug and ReleaseFast alike: 128 KiB of table, 128 KiB of literals, 512
  KiB of sequence list — `max_block_size / 3 + 1` twelve-byte sequences, the
  `min_match_length` bound — plus the writers' workspaces); the README carries
  the figure. The bisect, re-run on aarch64 macOS (ReleaseFast, 600 KiB and
  1.5 MiB text inputs, a thread spawned at a given `stack_size`): `compress`
  805 KiB (809 KiB Debug), `compressBuffered` 37 KiB (41 KiB Debug),
  `Writer.streamAll` 37 KiB (57 KiB Debug), against a 3-KiB floor for an empty
  thread — so the two buffered forms are the KiB-scale paths, and the figure is
  flat in the input size. `Writer.Buffer(19)` is 1507336 bytes (1.44 MiB):
  512 KiB history, 128 KiB block, 128 KiB literals, 128 KiB + 3 output, 64 KiB
  table, 512 KiB sequences, one byte of padding. On macOS a thread stack below
  ~772 KiB crashes even with an empty thread body when the caller's frame is
  large (the bisect needs each path in its own `noinline` frame, and the
  ReleaseFast floor only resolves needs above ~772 KiB).
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
- **TE7 — the `mls` ladder.** The C's 5/6/7 by size class (`clevels.h`'s `L`),
  as landed. The prompt for the encoder's block layer named "mls 6 with the
  6/7 length ladder"; the measurements say the ≤ 16-KB class's 5 is what
  keeps the CLI's byte class on small inputs — with it the 232-case sweep is
  228 byte-identical, without it 195 (every input under 16 KiB diverges).
- **TE8 — no pre-block splitter.** The C v1.5.7's `ZSTD_optimalBlockSize`
  (`zstd_compress.c:4550-4583`) runs `ZSTD_splitBlock` on full 128-KB blocks
  once a frame has saved 3 bytes, which at level 1 can cut a block to 32/64/96
  KiB (`zstd_preSplit.c:198-226`). The port splits at exactly `min(128 KiB, 1
  << windowLog)`, the C's pre-1.5.7 shape and the survey's 1-MiB observation
  (8 blocks of 128 KiB); a frame may therefore carry fewer, larger blocks
  than the CLI's on split-triggering data.
- **TE9 — the literals heuristics are the landed writer's.** `literals_compress`
  carries the C's ladder (the 64/6-literal floor, minGain, RLE, the 1/4-stream
  split) but not `HUF_compress_internal`'s two early bails — the
  `largest <= (srcSize >> 7) + 4` histogram check and the
  `suspectUncompressible` first/last-4096 sample (`huf_compress.c:1251-1252,
  1366-1379`). Both can only turn a marginal Huffman win into Raw literals, and
  the minGain margin catches the rest; the byte-identity sweep says the corpus
  shapes never reach them.
- **TE10 — the old-decoder workaround is not emitted.** The C returns 0 (a Raw
  block) when the last FSE description is 2 bytes and the sequences bitstream
  is 1 byte, to dodge a zstd ≤ 1.3.4 decoder bug (`zstd_compress.c:2985-2996`).
  Our decoder and the CLI v1.5.7 read that shape fine, so the port emits the
  Compressed block; a frame that would have hit it is a few bytes shorter than
  the CLI's.
- **TE11 — the Huffman tree's tie order.** `huff0_compress.buildTable` sorts
  equal counts in natural symbol order, where the C's per-rank quicksort is
  unstable (`huf_compress.c:610-632`); a tree description can differ from the
  CLI's while the frame decodes identically and usually at the same size. This
  is the four-case residue of the 232-case byte-identity sweep (all `words`
  inputs under 8 KiB).
- **TE12 — the empty streaming frame.** `Writer` declares no
  Frame_Content_Size in any frame, so `finish` on an empty writer writes the
  6-byte streaming header, a raw zero-size last block, and the checksum: 13
  bytes (`28 b5 2f fd 04 48 01 00 00 99 e9 d8 51` at the default window_log).
  The CLI's empty *pipe* frame is the other 13 bytes — the single-segment form
  the one-shot writes (`24 00` for the descriptor and FCS) — because its length
  is known by the time it ends the frame. Every non-empty pipe input uses the
  FCS-unknown header, which our `Writer` reproduces byte for byte (the
  `encode_stream_*` fixtures); only the empty case departs.
- **TE13 — the sequences bitstream on prose input.** `zstd -1 -c README.md`
  (v1.5.7) and our one-shot both decode to README.md and their 7-byte headers
  are identical (`28 b5 2f fd 64 71 0c`); the frames differ at byte 7 (ours
  `0x85`, the CLI's `0x8d`: the first block header's size bits, 1712 vs 1713
  compressed bytes) and in 490 bytes of that block. It is not the FCS form,
  and not TE11's Huffman tie: the whole literals section (484 bytes — the
  3-byte header, the tree description, and both Huffman streams) is
  byte-identical, as are the sequence count (73), the modes byte (`0xcc`), and
  the first ~700 bytes of the sequences bitstream. The difference is inside the
  bitstream, so the two encoders encode the same match spans (identical
  literals and counts) with different repcode accounting. The prefix sweep
  localizes it: our one-shot's frame equals the CLI's for every README prefix
  up to 832 bytes and first differs at 896 (both frames 460 bytes; the first
  differing byte is 362, the bitstream's third byte; 55 bytes differ; all three
  tables are Predefined, so there are no descriptions to blame). The corpus
  sweep is unaffected: 116 of 117 shape/size cases are byte-identical, and the
  residue is `words-65536` (same length, different bytes). Open: which finder
  decision differs — the rep pre-check's position, the offset-2 chain, or a
  rule the port reads differently from the C — and whether it is a port bug or
  a documented C behavior. A byte-identity investigation, not a correctness
  one: every frame here decodes byte-exactly through the CLI, libzstd, and our
  decoder, and passes `zstd -t`.

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
- **The encoder.** Landed: the round-trip gates (encoder → reader identity over
  the corpus shapes and the fixture classes, sentinel-checked, one-shot and
  streaming), the CLI's own level-1 bytes pinned for eleven inputs
  (`golden.zig`'s `encode_*` group, each rebuilt from the corpus shape
  definitions and compared whole-frame), the CLI's own *streaming* bytes pinned
  for five inputs (`encode_stream_*`, the same shapes through a pipe, which
  `Writer` reproduces byte for byte), the block-form checks (Raw at exactly
  Block_Size, RLE after the first block, the windowed five-block frame), the
  header forms (the one-shot's exact FCS in its smallest form; the Writer's
  FCS-unknown two-field header), the empty frame's 13 bytes in both forms, the
  Writer's lazy header and zero-data flush, the flush-boundary walk, the
  sliding window's cross-block matches, the one-shot/Writer block-byte
  agreement, determinism under chunked writes, the poisoned lifecycle, and the
  `maxCompressedLength` bound. The T1 `01 0D` pair is the literals layer's
  byte-exact golden (`literals_compress`). Still the fuzz lane's: our encode →
  our decode identity, our encode → CLI decode byte-exact, and the compliance
  property (no `Reader.Error` name except `BufferTooSmall` reachable on our own
  output).

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
  frame — a `ZstdDecompressor` object is stateful and single-frame). The
  landed evidence: all fourteen 32-KiB/64-KiB corpus blobs and the seven 1-MiB
  survey shapes are byte-identical to the CLI's level 1, and a 232-case sweep
  (corpus shapes at 32 sizes, PRNG bytes, the accuracy-ladder truncations)
  passes `zstd -d` byte-exact and `zstd -t` clean on every case, 228 of them
  byte-identical (TE7 and TE11 account for the rest).
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
- Thread stack: the reader needs about 161 KiB in ReleaseFast
  and 206 KiB in Debug; the 128 KiB literals scratch is the floor. The encoder's
  figures (the one-shot's 805-830 KiB, the buffered forms' ~40 KiB) are in "The
  scratch" above. To re-measure,
  run the path in a `std.Thread.spawn(.{ .stack_size = N })` thread and bisect on the
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
