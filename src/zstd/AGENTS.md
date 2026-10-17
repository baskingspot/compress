# Agent notes: zstd

A Zstandard codec (RFC 8878): a decoder and a fast encoder, both complete —
one-shot (`encode.zig`), streaming (`Writer.zig`), over the block layer
(`block_compress.zig`) and the match finder (`match_compress.zig`). `README.md`
is the user overview; this file keeps the decisions, errata, and oracle notes
behind it. The external-oracle lane is `just zstd-oracle` (`oracle.zig`,
`scripts/zstd_oracle.py`, `scripts/zstd_klauspost`); the encoder's oracle
notes are below.

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
- **Dictionaries are consumed through a parse-once value (OQ4, T11 retired;
  "The dictionary" below).** The M4 posture was refusal — `DictionaryRequired`
  at the first Dictionary_ID byte, raw-content dictionaries included, §2's
  unambiguous-error rule and the zlib FDICT precedent. The dictionary
  milestone lands the entry point: `zstd.Dictionary` parses a formatted (§5)
  or raw dictionary once, and both directions take `?*const Dictionary`.
  `DictionaryRequired` keeps its meaning (no dictionary supplied); a supplied
  dictionary whose ID does not match the frame's is `DictionaryMismatch` (the
  C's own label, `zstd_decompress.c:716-719`).
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
a 264-case sweep (every corpus shape at 32 sizes plus PRNG bytes, the sizes
straddling the tiny class's hash-width clamp) is byte-identical on every
case, as are the non-ASCII, repo-prose, and over-512-KiB rows the
`just zstd-oracle` lane drives through both public forms. The tests pin the
CLI's own bytes for twelve inputs (`golden.zig`'s `encode_*` group): the
text/html/rle corpus shapes at both sizes, the `words`/`skewlit` shapes'
first 4 KiB (the entropy paths), the `words` shape's 495-byte prefix (the
smallest corpus prefix the FSE last-symbol count decrement changes, pinning
that step), the tiny class's 100- and 1024-byte text, a
600 KB text frame (windowed, five blocks), and the scan-exit input (below).
The CLI's verdicts on all twelve: `zstd -d -c` byte-exact, `zstd -t` clean,
CPython 3.14 `compression.zstd` byte-exact. A byte comparison outside those
sets can still hit the deliberate differences (TE8, TE11 below).

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
  never the stream's bits. The two hot bitstream loops (the Huffman literals
  streams, the sequences bitstream) run on `bits.BackwardAccumulator`, the
  register-resident twin: the same flush discipline, but the writer struct's
  fields no longer spill to the stack across a flush call per field
  (measured: the Huffman stream loop dropped from a byte-at-a-time flush and
  a store-load round trip per symbol to one 8-byte store per flush, ~2.5x on
  the literals-heavy rows).
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
  (`kStepIncr = 1 << (kSearchStrength - 1)`, `:234,341-347`). Its labeled
  cascade is 71 lines, kept whole for the same reason the flate port's
  `encodeBlock` is (the control flow belongs in one parent; the house's
  70-line limit is consciously overridden). After a match the
  table is filled at `current+2` and `ip0-2` (`:404-408`), then the offset-2
  immediate-repeat chain runs (`:410-420`), swapping rep1/rep2 per zero-literal
  sequence. Reps outside the window are zeroed before the loop and restored
  after (`:238-243,355-372`), so the emitted history stays decodable. No lazy
  matching (the C's lazy starts at level 5-6); the rep pre-check and the
  offset-2 chain are the only lookahead. The extension reuses the flate port's
  word-XOR machinery.
- **The dfast level (level 3), landed as `dfast_compress.zig` +
  `split_compress.zig`.** The C's `ZSTD_dfast` (`zstd_double_fast.c`): two
  position tables (the long one keyed on 8 bytes at `hashLog`, the small on the
  class's `minMatch` at `chainLog`), a greedy scan that checks both candidates
  per probe and arbitrates a long match at `ip + 1` against a short match found
  at `ip` (`_search_next_long`), a repcode pre-check at `ip + 1` (no backward
  extension, no rep shift), the complementary insertion (`curr+2`, `ip-2` into
  the long table and `curr+2`, `ip-1` into the small), and a step that grows by
  one per 256 unmatched bytes (`1 << kSearchStrength`, twice level 1's). The
  three variants are the C's three: `find` (noDict), `findDict` (the attach
  path — the CDict's tagged tables consulted only where the frame's own table
  has no candidate, the C's `else if`, not a byte-mismatch fallback), and
  `findExtDict` (the copy path, virtual indices and split reads). The frame
  parameters are the level-3 rows of `clevels.h` (`W21 C16 H17 L5` above
  256 KB, `W18 C16 H16 L4`, `W17 C15 H16 L5`, `W14 C14 H15 L4`) with the same
  adjust order as level 1 plus the `chainLog` clamp
  (`zstd_compress.c:1563-1567`); the attach cutoff is
  `attachDictSizeCutoffs[dfast]` = 16 KB (level 1's 8 KB was the fast row of
  the same table). One table convention does not carry over from the level-1
  port: the noDict and extDict scans keep frame offsets (the 0 = "never
  written" sentinel, the `max(prefix_start, 1)` floor), while the *attach* scan
  stores *virtual* indices (`dict.len + frame position` — the C's
  `curr = ip - base`, whose base sits at the dictionary's end), because the
  C's `matchIndexL >= prefixLowestIndex` accepts the frame's position 0 there
  and a frame-offset table with a 0 sentinel cannot. The dict tables live in
  the `Dictionary` value (the C's CDict shape): `match_dfast` is the long+small
  tagged pair, filled by `ZSTD_fillDoubleHashTableForCDict`'s
  every-third-position rule (the small table only at `i == 0`; the long table
  also at `i == 1, 2` when its slot is still empty) and copied tag-stripped on
  the copy path.
- **The dfast pre-splitter, landed as `split_compress.zig`.** The C's
  `ZSTD_optimalBlockSize` (`zstd_compress.c:4550-4583`) resolves
  `splitLevels[strategy]`: level 1 (`ZSTD_fast`) is 0 →
  `ZSTD_splitBlock_fromBorders`, which this port does not carry (TE8); level 3
  (`ZSTD_dfast`) is 1 → `ZSTD_splitBlock_byChunks` at level 0 — the fingerprint
  splitter, 43-byte sampling at `hashLog` 8, an 8-KiB chunk grid, the C's
  `THRESHOLD_BASE + penalty` comparison. The level-ratio notes' claim that fast
  and dfast share the entry is wrong: dfast's splitter fires on inputs level
  1's never touches (the 520-KiB period row's level-3 frame splits where its
  level-1 frame does not), so a level-3 port without it is not the CLI's bytes.
  It is gated exactly as the C gates it (`srcSize >= 128 KB`,
  `blockSizeMax >= 128 KB`, `savings >= 3`), and the one-shot also models the
  CLI's *chunking*, because the gate's `remaining` is the chunk's, not the
  frame's: at or below `ZSTDMT_JOBSIZE_MIN` (512 KB) the CLI reads
  `ZSTD_CStreamInSize` = 128-KB chunks; above it the multithreaded path
  compresses each job in 512-KB chunks (`zstdmt_compress.c:765`), which for a
  single job (input at or below the level's 8-MiB job size) is the whole input.
  `savings` is the C's `consumedSrcSize - producedCSize`, the frame header
  counted with the first block.
- **The offsets-table promotion lasts one block (found landing level 3).**
  `ZSTD_compressBlock_internal`'s tail (`zstd_compress.c:4168-4171`) demotes a
  dictionary-promoted `offcode_repeatMode` from `FSE_repeat_valid` to
  `FSE_repeat_check` after every block — "After the first block, the offcode
  table might not have large enough codes to represent the offsets in the
  data" — so Repeat_Mode for the offsets alphabet is a first-block-only seat
  even with a dictionary. The level-1 port did not carry the demotion; the
  symptom that found it was a skewlit-with-dictionary level-3 frame whose
  second block used Predefined in the C and Repeat here. It is a fix for
  level 1 too, and the committed level-1 fixtures and oracle rows are
  unchanged by it (the port's own level-1 words-8192 dictionary frame still
  differs from the CLI's, with or without the demotion — a separate,
  pre-existing level-1 divergence outside the pinned sets).
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
  a reusable tree — `zstd_compress_literals.c:114-127`), when Huffman misses
  minGain (`:187-191`), or when one of `HUF_compress_internal`'s two early
  bails fires — the block-layer-armed `suspectUncompressible` two-sample check
  and the flat-histogram `largest <= (srcSize >> 7) + 4` check
  (`huf_compress.c:1366-1384`, TE9); RLE for one-byte literals (`:81-107,192-201`);
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
  transition bits OF/ML/LL and extras LL/ML/OF. In the FSE path the last
  sequence's code is excluded from the distribution when it appears more than
  once, and the low-probability decision follows the decremented count —
  `nbSeq_1`, not `nbSeq` (`zstd_compress_sequences.c:271-278`); the accuracy
  log stays the one chosen for the full count. TE13.
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
  (`4 << min(17, window_log + 1)` bytes) plus the small table
  (`4 << min(16, window_log)`), and the sequence list
  (`12 * (block / 3 + 1)` bytes) — all comptime from `window_log`, the
  exact-pointer `init`. Two deviations from the sketch's byte figures, both
  deliberate: the tables are sized for the widest widths a frame can take when
  it attaches a dictionary (17/16 at level 3, 15 at level 1), not for the
  writer's own slice, and the Buffer also carries the literals, the emission
  target, and the sequence list so the writer's own frame stays KiB-scale (the
  sketch listed only the first three; the stack measurement below is why).
  `streamAllAlloc` takes the level's default window (19, or 21 at level 3). The
  finder's parameters are the C's streaming class
  (`ZSTD_getCParams(level, ZSTD_CONTENTSIZE_UNKNOWN, 0)`): windowLog = the
  caller's, hashLog 14 and minMatch 7 at level 1, hashLog 17, chainLog 16, and
  minMatch 5 at level 3 — which is what makes the CLI's `zstd -1`-over-a-pipe
  frames byte-identical (the `encode_stream_*` fixtures). The level-3 pipe
  form is the same class but not a byte pin (the CLI's pipe form chunks
  through its multithreaded path). The finder's table entries are
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
  `compressBuffered` is the same encoder over `encode.Buffer` (1.375 MiB,
  caller-owned), so its thread stack is about 40 KiB; the pair exists because
  the stack local violated the house's KiB-scale rule and survived only the
  8-MiB default `ulimit -s`. The block layer stays internal: no zstd
  block function is self-contained (cross-block entropy and repeat-offset
  state), unlike snappy's and flate's. `Options.level` is the CLI's numeric
  scale: 1 is the level-1 class, 3 the dfast class, and every other level
  (2, 4-19, and anything outside 1-19) returns `error.Unimplemented` — the
  flate pattern, never a silent alias (the enum seat became the number in the
  level-APIs commit; the dfast class filled level 3). The barrel is complete: `{encode, decode,
  Writer, Reader}`. `Writer.streamAll` and `Writer.streamAllAlloc` mirror the
  Reader's pumps (the caller-buffered pair first, then the default-window
  allocation); there is no stack-buffered default pump — `Writer.Buffer(19)`
  is 1.4 MiB, so a stack-buffered default is out (the `ulimit -s 8192` lesson).
- **The scratch.** Per-block scratch (the entropy writers' workspaces) is
  comptime stack in the emission path; the caller's `Buffer` holds the
  window, the staging, the finder's tables, and the block's literals and
  sequence list (EQ7). The
  one-shot's measured need on aarch64 Linux was about 830 KiB of thread stack
  before level 3 (Debug and ReleaseFast alike: 128 KiB of table, 128 KiB of
  literals, 512 KiB of sequence list — `max_block_size / 3 + 1` twelve-byte
  sequences, the `min_match_length` bound — plus the writers' workspaces); the
  level-3 tables (`encode.Buffer`: the long table 512 KiB + the small 256 KiB
  in place of level 1's 128 KiB) raise it for *both* levels, because the
  `Buffer` is level-independent: the 2026-10-16 re-bisect on aarch64 Linux
  (ReleaseFast, a 600-KiB input, a thread per stack size) crashes at 1.25 MiB
  and passes at 1.5 MiB at level 1 and level 3 alike, so the README says
  about 1.5 MiB and 2 MiB or more of thread stack. (The old 805-830 KiB
  figure was the same box and method; only the tables grew.) The bisect (ReleaseFast, 600 KiB and 1.5 MiB inputs, a thread
  spawned at a given `stack_size`): `compress` was 805 KiB on aarch64 macOS,
  re-measured at 810 KiB on aarch64 Linux after the four-lane histogram
  added its 4 KiB workspace; `compressBuffered` 37 KiB (41 KiB Debug),
  `Writer.streamAll` 37 KiB (57 KiB Debug), against a 3-KiB floor for an empty
  thread — so the two buffered forms are the KiB-scale paths, and the figure is
  flat in the input size. `Writer.Buffer(19)` is 2228232 bytes (2.2 MiB):
  512 KiB history, 128 KiB block, 128 KiB literals, 128 KiB + 3 output, the
  long table 512 KiB + the small table 256 KiB (the level-3 dictionary's
  widest widths; a level-1 frame slices the long one alone), 512 KiB
  sequences, one byte of padding. `Buffer(21)` — the level-3 default — is
  about 3.6 MiB. On macOS a thread stack below
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

## The dictionary (RFC 8878 §5; the M7 sketch)

The dictionary milestone consumes dictionaries, never trains them. The
research is `docs/research/dictionary-notes.md` (`dict-notes` below): its
`DD`/`DE`/`ZL` matrices are the requirements, its `DT` rows the divergences,
its `DQ` register the API questions, and its §11 the milestone row. The
dictionary file is an input — the `zstd` CLI trains (`--train`, fastCover,
verified live) — and nothing here depends on a trainer (DQ7: an in-repo one
is a separate follow-up with its own oracle problem) **[sketch call 10]**. The
negatives are the research's §5: gzip has no dictionary concept, and brotli's
custom-dictionary path stays without an API **[sketch call 9]** (`dict-notes
§5.2`; the brotli register's OQ7 row records the live verification). The
slices land decode-with-dictionary first, then encode-with-dictionary, then
the zlib preset (`dict-notes §11`).

**The shape (DQ1-DQ4).** `zstd.Dictionary` is a parse-once, zero-copy,
caller-owned value **[sketch call 2]** (the name sits at the namespace level:
both directions take it). `Dictionary.parse(source)` reads the formatted form:
the `0xEC30A437` LE magic, the Dictionary_ID, the entropy tables in §5's
order (literals Huffman, offsets FSE, match lengths, literal lengths), the 12
repcode bytes, then the content. `Dictionary.initRaw(content)` is the §5 raw
form: content only, the default {1,4,8} seeds, no ID (the C's shape; DT5 —
klauspost's ID-assigning raw form is not ported) **[sketch call 5]**. The
value borrows `source` and carries both directions' tables — the decode
side's three `fse.Table`s and the literals `Tree`/`DecodeTable`, the encode
side's three `fse_compress.Table`s and the `huff0_compress.Table`, the
repcodes, and the content slice — about 13 KiB of entropy tables,
comptime-sized, no heap (the match tables beside them are the encoder's).
`decode.decompress` takes `dict: ?*const Dictionary` as its third parameter
and `Reader.init`
plus the four pumps as their last **[sketch calls 1, 3]**; `encode.Options`
gains `dict: ?*const Dictionary = null`; `Writer` and `Writer.streamAll`
thread the options through unchanged. The migration is compile-checked:
every existing callsite adds `, null`. The decode error sets gain
`DictionaryMismatch` (the `decode.zig` and `Reader.zig` comptime vocabularies
fail the build until both lists and the README's are updated);
`DictionaryRequired` keeps its meaning.
`Dictionary.parse`'s own error vocabulary is **[sketch call 4]**, and
`maxCompressedLength` gains 4 bytes for the DID field **[sketch call 8]**.

**Landed so far (the decode slice).** `Dictionary.zig` carries the decode
side's parsed state — the literals `Tree` and `DecodeTable`, the three fused
`sequences.SeqTable`s (the form the decode loop reads, as the C's DDict
stores `ZSTD_seqSymbol` tables), the repcodes, and the content slice. The
frame state seeds by pointer for the sequences tables and by value for the
literals table (a ~1.3 KiB copy per frame with a dictionary); nothing is
re-parsed per frame or block (DD12).

**Landed so far (the encode slice).** `Dictionary.zig` also carries the
encode side's tables from the same parse: the literals tree in its
`huff0_compress.Table` form, the three `fse_compress.Table`s, the
`ZSTD_loadCEntropy` promotions (`literals_repeat_valid`, the per-alphabet
`sequence_repeat_valid`), the whole file's length (`source_len`, the C's
`cdict->dictContentSize`, which the parameters are sized from), and the
CDict match tables: level 1's `match_compress.DictTable` (`dtlm_full` over
the content with the short-cache tags, `ZSTD_fillHashTableForCDict`) and level
3's `dfast_compress.DictTables` (`ZSTD_fillDoubleHashTableForCDict`'s
long+small tagged pair). `@sizeOf(Dictionary)` is pinned at 947,824 bytes —
the entropy tables are ~13 KiB and the match tables 128 KiB + 768 KiB — and
the README's figure says so. The sketch's "about 21 KiB"
line predated the match-region research and is superseded: the C keeps the
match table in a `ZSTD_CDict` because a frame that attaches one reuses it;
this package has one dictionary value, so the table lives there rather than
in every frame's buffer (the alternative cost every `encode.Buffer` 128 KiB
and rebuilt the table per frame).

**The decode load (§2.1; DD1-DD12).** The parse reuses the landed readers in
the C's order: `huff0.readTree` for the literals tree, `fse.readDescription`
×3 with the caps (31/8, 52/9, 35/9), then the 12 repcode bytes checked
nonzero and ≤ the content size (DT2: the references enforce the content size;
§5's word is "dictionary size", and the content reading is the only one
consistent with the trainer's output), then the content. Incomplete
statistics are legal and accepted (DD11): the C through v1.5.5 errored on
them, v1.5.6+ does not, and the format has no version field (DT6). The load
seeds exactly the seats `frame.State.init` resets today (`frame.zig:395-397`:
`literals.has_table`, `sequences.tables`, `sequences.repeat_offsets`) plus
the content; nothing re-parses per frame or block (DD12). The content is
preset history: `sequences.decode`'s single history region becomes two (the
caller's dictionary content, then the output), and the addressable span
follows §5 — the whole dictionary while the frame's decoded total is ≤
Window_Size, the output's last Window_Size bytes after. That boundary is DT1:
no reference enforces it exactly (the C's whole-buffer decoder checks only
the history it holds, `zstd_decompress_block.c:930-933`; its streaming
decoder ends dictionary access by buffer adjacency — DT8 names which C path
a fixture cites). Ours is fail-closed, the T12 posture: `OffsetTooFar` at the
reach **[sketch call 6]**, pinned by the oracle's hand-built frames with the
CLI's verdicts recorded. A supplied dictionary whose ID matches decodes
whatever the ID is: the reserved ranges are not enforced, since a decoder
cannot know the registry **[sketch call 7]**.

**The encode side (DE1-DE11), landed.** `ZSTD_loadCEntropy`'s promotion
rules are the contract (`dict-notes §3.1`): the literals tree is
`repeat_valid` only on 256 symbols with no zero weights; each FSE table only
on full coverage with no zero counts; the offsets table must represent every
offset up to `dictContentSize + 128 KiB`. A check-state table is never
consulted at the fast level (facebook/zstd issue #3724) — and an FSE build
demotes its alphabet (`ZSTD_selectEncodingType`'s `FSE_repeat_check`), which
the encode slice added to `sequences_compress.selectMode`. The repcodes seed
from the dictionary's 12 bytes; the content is matchable history.

The match region is *both* of the C's shapes, chosen by the source size, not
one two-region port: at or below the 8-KiB cutoff
(`ZSTD_USE_CDICT_PARAMS_SRCSIZE_CUTOFF`, `zstd_compress.c:5232`) the
dictionary is attached as a separate match state
(`ZSTD_compressBlock_fast_dictMatchState_generic`: the tagged CDict table,
the repcode pre-check at `ip0 + 1`, the scan's step starting at 1, the
frame's own table holding source positions), and above it the CDict's table
is copied into the frame's own with the content as the window's extDict
(`ZSTD_compressBlock_fast_extDict_generic`). A streaming writer never knows
its length, so it always attaches (`ZSTD_shouldAttachDict`). The frame
parameters follow the C's two paths: the attach path takes the *dictionary's*
hash width and `minMatch` with the frame's window
(`ZSTD_resetCCtx_byAttachingCDict`), the copy path takes the window from
`srcSize + dictContentSize`'s class with the dictionary's hash width and
`minMatch` (`ZSTD_resetCCtx_byCopyingCDict`). Two consequences the tests
pin: a frame that attaches a dictionary needs a hash table as wide as the
dictionary's `hashLog` (up to 15 — the `Writer`'s buffer grew to 1<<15
entries), and the dictionary-table *lookup* hashes with the frame's
`minMatch` while the table was filled with the dictionary's
(`zstd_fast.c:22` against `:547`) — for the one-shot's attach path the two
are the same width by construction, and where they are not, the lookups
miss exactly as the C's do.

The one-shot never expires the dictionary (its window covers source +
content); the streaming `Writer` stops reaching into it exactly at §5's
boundary (DE6) — the per-block `ZSTD_checkDictValidity` /
`ZSTD_window_enforceMaxDist` arithmetic lives in `block_compress.Dict`.
The frame writes the DID in the smallest 1/2/4-byte form (DE8); there is no
suppression knob — the honest form (`dict-notes §3.4`), and
`maxCompressedLength` gained the 4-byte field (the header cap is 18 bytes).
The level-1 with-dictionary byte class is `dict-notes §3.5`: Treeless
literals from the 6-literal floor, Repeat while valid and nbSeq < 1000, FSE
above; the parity target is `zstd -D dict -1`, a new target, not an
extension of `zstd -1`.

**The test plan (the oracle rows, `dict-notes §8`).** The CLI trains the
fixtures (`zstd --train -r <dir>` over the corpus shapes); the dict files and
the CLI-generated frames land in `golden.zig` with the CLI's verdict recorded
beside each. The encode side's fixtures are the `dict_encode_*` group: the
pinned CLI's `zstd -D dict-trained.bin -1` frames for the corpus shapes in
both header forms (the file form and the `-c` pipe form), the 8-KiB pair
bracketing the attach/copy switch, plus the decode slice's own
`dict_frame_s00` / `dict_frame_big` / `dict_frame_zw` (all level-1 frames)
re-emitted byte for byte. The oracle's dictionary rows grew from 24 to 34:
the encode parity rows (both forms over the trained dictionary), the
zero-weight dictionary's encode parity, and a raw-content dictionary row. Decode: our decode of CLI `-D` frames against `zstd -D dict -d`
and klauspost's `WithDecoderDicts`, byte-exact both directions; the mismatch
matrix (no dict, wrong dict, raw dict) against the C's
`tests/cli-tests/dictionaries/dictionary-mismatch.sh` pins; the
incomplete-statistics fixture (`zero-weight-dict`) accepted and the C's
`http-dict-missing-symbols` pinned as a *rejection* (DT9 below); the DT1
expiry fixtures (the T12 methodology). Encode: `zstd -D dict -1` byte-parity on the corpus shapes,
with `zstd -t` and our own decoder verifying every frame. The zlib rows are
`src/zlib/AGENTS.md`'s.

**DT9 — the C's 12-bit Huffman leniency (found landing the decode slice).**
The C's `HUF_readStats` accepts a literals tree up to its internal
`HUF_TABLELOG_MAX` 12, and its own
`tests/golden-dictionaries/http-dict-missing-symbols` fixture carries exactly
that: its weight series completes to a 12-bit code, which the C reads as
`tableLog = 12` (verified against the C source with a standalone
`HUF_readStats_wksp` call, and klauspost rejects the same fixture with
"tableLog too big"). RFC 8878 §4.2.1 "limits the maximum code length to 11
bits", and the shared `huff0.readTree` is RFC-strict, so `Dictionary.parse`
refuses the fixture with `MalformedHuffmanWeights` — the register's earlier
"both fixtures accepted" line is amended by this row. Accepting the C's
12-bit trees would need a `1 << 12`-entry `DecodeTable` and a laxer cap in
the shared reader (the C accepts 12-bit trees in blocks too): a deliberate
follow-up if interop demands it, never a silent widening.

**Errata found landing the encode slice.**

- **Two decode-slice fixtures are `-19` frames, not level-1.** `dict_frame_s01_r100`
  (244 bytes) and `dict_frame_s01_raw` (300 bytes) were documented as the
  CLI's level-1 frames; the pinned CLI reproduces them at `-19` (`-1` gives
  311 and 321 bytes). They are decode fixtures only — the level is now
  recorded in `golden.zig`'s comments — and the encode parity rows use
  level-1 frames the oracle generates live.
- **The `Reader`'s raw-dictionary path is `Dictionary.initRaw`** (already
  landed); the encoder's oracle mode is `encode-raw-dict`.
- **Two divergences kept deliberately in the match region.** The frame's own
  table never takes content position 0 as a candidate (a zeroed slot means
  "none", and this port's frame positions start at zero, unlike the C's
  window indices; the landed noDict port made the same choice). And the
  backward extension of a rep match is skipped when the rep's 4 bytes would
  straddle the dictionary's end or when a writer has compacted the byte away:
  the C reads across the boundary (undefined bytes) and this port does not.
  Neither fires on any fixture or corpus shape the oracle covers.
- **The `-19` class stays out of scope** (`dict-notes §8`): at `-19` the cost
  path recomputes and the dictionary's tables lose the race (§3.5's last
  row), which is the no-dictionary `-19` class again.

**The fuzz shapes (`dict-notes §8`).** The C's own targets are the model
(`tests/fuzz/dictionary_{decompress,loader,round_trip,stream_round_trip}.c`,
`raw_dictionary_round_trip.c`, and `invalidDictionaries.c`'s parse vectors): a
`Dictionary.parse` target (no input may crash it; a parsed dictionary decodes
its matching frames), a decode-with-dictionary target (the one-shot and the
Reader agree), and the round-trip targets with and without a dictionary. Handed
to the fuzz lane with the slices.

**Sketch calls, collected for the review** (the M6 pattern; each is also
marked above where it occurs):

1. **The third parameter over a decode options struct (DQ2).** One form, no
   duplicate names, and the compile-checked migration — the README carries the
   reasoning. An options struct on decode is heavier than a single optional
   pointer and still needs the streaming shape decided separately.
2. **`Dictionary` sits at the namespace level.** The barrel rule reads "each
   namespace exposes exactly `{Reader, Writer, encode, decode}`"; `Dictionary`
   is the shared value type both directions take, not a fifth entry point — a
   `Dictionary` under `decode` or `encode` would make the other reach across.
   Matt's call whether the rule wants the type spelled `zstd.decode.Dictionary`
   instead.
3. **The pumps take the dictionary too.** `dict-notes DQ2` names `decompress`
   and `Reader.init`; a pump without the parameter cannot decode a dictionary
   stream, and a second pump family would double the surface.
4. **`Dictionary.parse`'s error vocabulary.** `Truncated`,
   `BadDictionaryMagic`, `InvalidDictionaryId` (DT4: ID 0 is rejected at
   parse; the C is lenient), `InvalidDictionaryRepcode`, plus the reused
   `MalformedHuffmanWeights` and `MalformedFseTable` from the shared readers.
5. **`initRaw` is infallible** (the task's shape) and does not enforce §5's
   8-byte floor; the C's raw path accepts shorter content too. No ID, ever
   (DT5).
6. **The expiry boundary is fail-closed (DT1).** No reference enforces §5's
   rule as written; the oracle's first job pins ours against the C's lenient
   path with the divergence named (DT8: which C path each fixture cites).
7. **The reserved ID ranges are not enforced (DT3).** A supplied dictionary
   whose ID matches decodes whatever the ID is; the encoder never chooses a
   reserved ID itself, and a decoder cannot know the registry.
8. **`maxCompressedLength` gains 4 bytes** for the Dictionary_ID field (an
   18-byte header cap plus the checksum), so the documented bound covers a
   dictionary frame.
9. **The brotli negative is final** (`dict-notes §5.2`): no brotli dictionary
   API; the CLI's `-D` streams are refused naturally (verified live), and
   `src/brotli/AGENTS.md`'s OQ7 row records it.
10. **Training is not a dependency (DQ7).** The dictionary file is an input;
    the CLI trains; an in-repo trainer is a separate follow-up.

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

### The encoder's register (TE1-TE13)

zstd-encoder-notes §5, decisions as landed: the CLI's byte class is the target
unless a row says otherwise. Each row records the C's rule against klauspost's;
the C's wins, so the survey's class and the corpus fixtures stay in one family.
TE7-TE13 were added while the encoder was built; TE13 is resolved and kept as
the record of what the divergence was.

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
  228 byte-identical at the time, without it 195 (every input under 16 KiB
  diverges). The same adjust step also clamps the hash log *before* the
  window floor (`ZSTD_adjustCParams_internal`, `zstd_compress.c:1548-1580`),
  which is what keeps sources of at most 512 bytes in the CLI's class
  (`Params.forSource`).
- **TE8 — level 1's pre-block splitter is not ported (level 3's is).** The C
  v1.5.7's `ZSTD_optimalBlockSize` (`zstd_compress.c:4550-4583`) runs
  `ZSTD_splitBlock` on full 128-KB blocks once a frame has saved 3 bytes,
  which at level 1 resolves to `ZSTD_splitBlock_fromBorders` and can cut a
  block to 32/64/96 KiB (`zstd_preSplit.c:198-226`). The level-1 port splits
  at exactly `min(128 KiB, 1 << windowLog)`, the C's pre-1.5.7 shape and the
  survey's 1-MiB observation (8 blocks of 128 KiB); a level-1 frame may
  therefore carry fewer, larger blocks than the CLI's on split-triggering
  data. Level 3 resolves to the *other* splitter
  (`ZSTD_splitBlock_byChunks`, `split_compress.zig`) and that one is ported,
  so the level-3 byte pin inherits no such hole.
- **TE9 — the literals heuristics (resolved: the bails are ported).** The
  divergence was that `literals_compress` carried the C's ladder without
  `HUF_compress_internal`'s two early bails — the `largest <= (srcSize >> 7)
  + 4` histogram check and the `suspectUncompressible` first/last-4096 sample
  (`huf_compress.c:1251-1252, 1366-1379`, armed by the block layer's
  `nbSeq == 0 or litSize / nbSeq >= 20`, `zstd_compress.c:2886,2924`). Where
  a bail sacrificed a real Huffman win, our frame was *smaller* than the
  CLI's (a 256-KiB text with one high byte per line: 6796 bytes against the
  CLI's 7399). The M5 encode perf pass ranked the missing sample check its
  #1 lever (the incompressible 64-KiB rows ran the full entropy ladder the C
  skips), so both bails are now ported with the C's exact thresholds
  (40960-byte floor, `largestTotal <= 68`, `largest <= (srcSize >> 7) + 4`),
  and that input class now matches the CLI's bytes. The corpus shapes never
  reach either bail, so the pinned fixtures are untouched.
- **TE10 — the old-decoder workaround is not emitted.** The C returns 0 (a Raw
  block) when the last FSE description is 2 bytes and the sequences bitstream
  is 1 byte, to dodge a zstd ≤ 1.3.4 decoder bug (`zstd_compress.c:2985-2996`).
  Our decoder and the CLI v1.5.7 read that shape fine, so the port emits the
  Compressed block; a frame that would have hit it is a few bytes shorter than
  the CLI's.
- **TE11 — the Huffman tree's tie order.** `huff0_compress.buildTable` sorts
  equal counts in natural symbol order, where the C's per-rank quicksort is
  unstable (`huf_compress.c:610-632`); a tree description can differ from the
  CLI's while the frame decodes identically, usually at the same size and
  sometimes by a byte or two (the description's form or length changes). The
  four `words` cases the 232-case sweep first blamed on this row were the
  missing last-symbol decrement (TE13's cause), not ties; the class is real
  on histograms with many equal counts — the `skewlit` shape at 65792,
  524289, and 1500000 bytes differs from the CLI by one byte, starting in the
  tree description, with identical literals sizes, sequence counts, and
  decoded output. The corpus-sized sweep is byte-identical on all 264 cases.
- **TE12 — the empty streaming frame.** `Writer` declares no
  Frame_Content_Size in any frame, so `finish` on an empty writer writes the
  6-byte streaming header, a raw zero-size last block, and the checksum: 13
  bytes (`28 b5 2f fd 04 48 01 00 00 99 e9 d8 51` at the default window_log).
  The CLI's empty *pipe* frame is the other 13 bytes — the single-segment form
  the one-shot writes (`24 00` for the descriptor and FCS) — because its length
  is known by the time it ends the frame. Every non-empty pipe input uses the
  FCS-unknown header, which our `Writer` reproduces byte for byte (the
  `encode_stream_*` fixtures); only the empty case departs.
- **TE13 — the sequences bitstream on prose input (resolved).** The
  divergence was the missing last-symbol count decrement in the FSE path
  (`ZSTD_buildCTable`'s `count[codeTable[nbSeq-1]]--` and the `nbSeq_1`
  low-probability decision, `zstd_compress_sequences.c:271-278`): the norm,
  the built table, and the whole interleaved bitstream followed from the
  wrong distribution. The row's original hypothesis (repcode accounting) was
  wrong, and the `words-65536` corpus residue was the same cause. With the
  decrement landed, the README prefix sweep is identical on every prefix, the
  264-case corpus sweep is byte-identical, and `golden.zig`'s `encode_words_495`
  (the smallest corpus prefix the decrement changes) pins the behavior. The
  symptom that started the investigation: `zstd -1 -c README.md` and our
  one-shot differed at byte 7 (1712 vs 1713 compressed bytes in the first
  block) and in 490 bytes of that block, with identical literals and sequence
  counts.

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
- Fuzz is `just fuzz 10M`; `fuzz.zig`'s header lists the ten targets (five
  decode, five encode). Two properties run through the decode targets: the
  one-shot and the reader agree on every input (same bytes or the same named
  error, `WindowTooLarge` excepted), and the reader-machinery target asks past
  a frame's tail so the trailer step runs through `rebase`. The encode
  targets exercise the finder's own assertion that every emitted offset stays
  strictly below the declared Window_Size (`§3.1.1.4`), so a fuzz run checks
  it on every input.
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
  byte-exact golden (`literals_compress`). The encode identity and the
  compliance property (no `Reader.Error` name except `BufferTooSmall`
  reachable on our own output) run in the encode fuzz targets
  (`fuzzEncodeRoundTrip`, `fuzzEncodeCorruption`), and the CLI's decode of our
  frames is the `just zstd-oracle` lane's row.

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
  survey shapes are byte-identical to the CLI's level 1, and a 264-case sweep
  (corpus shapes at 32 sizes, PRNG bytes) passes `zstd -d` byte-exact and
  `zstd -t` clean on every case, byte-identical on every one of them; the
  classes a byte comparison outside that set can hit are the TE rows below.
  klauspost's encoder is a read-and-run reference, not a gate: its level-1
  class deliberately differs (TE1-TE5). `zstd.compress(src, level=1)` is
  byte-identical to `zstd -1 --no-check` (verified), so the bench harness's
  ratio arm can use the CLI. The structural check is the survey's scratch frame
  walker (not repo code): exact frame consumption, nonzero backwards-stream
  ends, the mode census.
- **`just zstd-oracle`** is the external-oracle lane
  (`scripts/zstd_oracle.py`, the harness in `src/zstd/oracle.zig`): every
  input is encoded through both public forms and checked all the way around —
  `zstd -t`, the CLI's decode, klauspost's `DecodeAll` and streaming decoder,
  our own decode — and byte-compared with `zstd -1` for the one-shot's file
  form and the Writer's pipe form. klauspost is the strict Window_Size check
  the C decoder is not (`§3.1.1.4`): it bounds its history by the frame's
  declared window, so an offset past it fails there while the C and our own
  decoder accept it. The input set covers the two blind spots the unit tests
  cannot see: bytes of 0x81 and above (the FSE weight form) and inputs over
  512 KiB (the window). The klauspost decoder is
  `scripts/zstd_klauspost` (the same pinned module as the bench arm). The CLI
  incantations were run by hand while the fixtures were built (zstd-notes §5,
  §6; zstd-encoder-notes §4 for the encoder's).

## Performance

- `just bench` runs `bench.zig` (`just corpus` first). Claims cite a recorded
  fleet run under `docs/results/` (`m4-*`, `zstd-wave2-*`), never local numbers.
  The encoder's bench arm (encode rows against the CLI and klauspost) is the M5
  addition; the fleet's zstd-c driver runs the encode rows too (the
  `m5-encode-fleet-20261013` run).
- The streaming direction is not a bench row: a streaming row in the bench binary
  shifts the one-shot rows through code layout (flate tried one and reverted it).
  Time it through the example pump, `just example zstd decode <file>`.
- Thread stack: the reader needs about 161 KiB in ReleaseFast
  and 206 KiB in Debug; the 128 KiB literals scratch is the floor. The encoder's
  figures (the one-shot's 805-830 KiB, the buffered forms' 37-48 KiB, which the
  README's 64 KiB figure covers) are in "The scratch" above. To re-measure,
  run the path in a `std.Thread.spawn(.{ .stack_size = N })` thread and bisect on the
  segfault (aarch64 Linux, glibc; the window buffer is static, so only the
  decoder's frames count). Re-measure after changes to the compressed-block path
  and keep the README's figures in step.

## Provenance

facebook/zstd v1.5.7, klauspost/compress v1.18.0-5, and Zig's `std.compress.zstd`
(0.16.0) were read and run as oracles; fixtures are data. `xxh64.zig` follows
std's `XxHash64`. The encoder is a port of the C's `zstd_fast.c`,
`zstd_compress.c`, `zstd_compress_literals.c`, `zstd_compress_sequences.c`,
`fse_compress.c`, and `huf_compress.c` (the algorithm, not the code — the hash
primes and the FSE rounding table are the C's values), with klauspost's
`zstd/enc_fast.go`, `zstd/fse_encoder.go`, and `zstd/blockenc.go` read for the
divergences the TE rows record. The decoder is written from the RFC and the
`zstd-notes` research. Attribution is `THIRD_PARTY.md`.
