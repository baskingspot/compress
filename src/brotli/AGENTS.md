# Agent notes: brotli

The brotli codec (RFC 7932): the decoder, and the encoder at the reference's
`q3` class. `README.md` is the user-facing contract; this
file keeps the decisions, errata, and oracle notes behind it. The research is
`docs/research/brotli-notes.md` (`brotli-notes.md` below): its `BR1`-`BR41`
requirement matrix, `T1`-`T8` divergence rows, and `OQ1`-`OQ8` design questions
are cited as they appear there. `§` cites are sections of
`docs/research/specs/rfc7932-brotli.txt`. brotli wraps nothing — it is a codec,
not a container — so the layering questions are zstd's one milestone later,
plus one surface no other codec here has: the 122,784-byte static dictionary
the format folds into distance space (§8).

## Design decisions

The OQ register is the implementation contract; each answer below is what this
sketch commits to. Where the sketch had to go past the register, the call is
marked **[sketch call]** and collected at the end.

- **The surface is `{decode, Reader}` today (OQ2).** `brotli.decode.decompress`
  is the one-shot (`target` a cap, the decoded length returned; the format
  declares no size) and `brotli.Reader` the streaming decode, with
  `Reader.Buffer(window_wbits)` and `Reader.streamAll`. `decode` landed with
  `decode.zig` (slice 5), `Reader` with `Reader.zig` (slice 6). The
  encoder seat
  (`encode`, `Writer`) is stated in the README, never silently absent; the
  barrel's `{Reader, Writer, encode, decode}` completes at the encoder
  milestone without reshaping these two. **[sketch call]** there is no
  single-stream pump: the codec's unit is the RFC's own "brotli stream", so a
  `streamStream`-style name would be noise — the zlib shape (its unit is also a
  stream, so `streamAll` only) is the precedent, and a caller who wants exactly
  one stream drives `Reader` directly.
- **One stream per `Reader`, at the exact boundary (OQ3, T4).** The reader
  consumes `input` through the stream's last byte — the ISLAST meta-block's
  last bit, zero fill to the byte — and stops there, so the input position at a
  clean end is the next stream's first byte. `streamAll` is the walk at that
  boundary. Trailing bytes that cannot begin a stream are `BadStreamStart`, a
  header the input ends inside is `Truncated`, and the zero-byte input is
  `Truncated` for `decompress` and `Reader` (no stream began; the empty
  *stream* is the single byte `06`). Metadata blocks skip without touching the
  window, output, or context (BR9), and the CLI's `-C` comment lane is their
  conformance test. **[sketch call]** `streamAll` on zero bytes is the walk's
  clean end (zero streams), the gzip/zstd rule — the notes' "the zero-byte
  input is `Truncated`, never a clean zero-byte decode" is the
  `decompress`/`Reader` contract, not the walk's. **[sketch call]**
  `BadStreamStart` is the walk's name for the refusal at a next-stream
  position; a stream's *own* header with the same wire pattern (0010001) is
  `BadWindowBits` (T3). The two names differ by context — "the tail is not a
  stream" vs "your stream is bad" — and the notes' §3 table has no row for the
  former; the implementation distinguishes with a completed-stream count.
- **The window is the caller's and comptime-sized (OQ4).** `Reader.Buffer(
  window_wbits)` = `(1 << window_wbits)` bytes of history ring plus the tree
  region, and the buffer *is* the cap: a stream whose WBITS is above it fails
  `WindowTooLarge` before any meta-block byte. **The default is 24** (F9's
  re-measure closed F1): the CLI's pipe form emits WBITS 24 for all 84 sweep
  rows and its file form 10..19 by input size, so 22 — the reference encoder
  library's own default — refuses every pipe-produced stream. 24 is the
  format's maximum, so the default refuses nothing conformant, and the price is
  the figure: `DefaultBuffer` is 16,777,216 + 707,204 = 17,484,420 bytes
  (about 16.7 MiB) against `Buffer(22)`'s 4,901,508 (about 4.7). The ring is a
  power-of-two buffer with the `-16` in the bound arithmetic (`§9.1`'s window
  size), the C's `ringbuffer`/`ringbuffer_mask` shape. The RFC's §12 progressive-growth
  recommendation (start small, grow per meta-block) is a deliberate non-goal:
  the buffer is caller-owned, and growing it means reallocating nobody asked
  for. The one-shot has no window at all — `target` is the history — so
  `WindowTooLarge` is not in its error set.
- **One error name per corruption class (OQ5).** The notes' §3 table is the
  vocabulary; the C's `PADDING_1`/`PADDING_2` and `BLOCK_LENGTH_1`/
  `BLOCK_LENGTH_2` splits collapse to one class each. `BadBlockLength` carries
  both the block-count decode (BR12, BR31) and the meta-block overrun (BR29):
  the C detects the overrun as a negative remaining length at the meta-block's
  end (`decode.c:1338`, `:2838`), which is the same class. `DictionaryRequired`
  is recorded in the notes only — the dictionary ships, so it has no surface.
  `WindowTooLarge` is streaming-only; `TooManyTrees` comes from OQ8's cap; the
  Io names (`StreamTooLong`, `ReadFailed`, `EndOfStream`) are the pattern
  book's. The C's error list (`c/include/brotli/decode.h:64-113`) and the Go
  port's names mirror ours one for one, which is what makes the CLI's `-v`
  rendering (`reason: FORMAT_PADDING_2 (-15)`) usable as an oracle assertion.
- **The dictionary ships unconditionally (OQ1).** Measured, not assumed: 7 of
  the 45 reference golden vectors are undecodable without it, the CLI's default
  quality (q11) emits thousands of references on text, there is no encoder
  quality gate (the dictionary is searched at every quality) and no header bit
  — the dictionary is distance space (§8). The zlib-FDICT refusal precedent
  does not transfer: FDICT is an opt-in bit no encoder sets; a brotli stream
  cannot be told apart before the reference. The data is ~120 KiB of `.rodata`
  (122,784 bytes + the transform tables): no allocation, no per-instance cost,
  paid once in binary size. There is no dictionary-supplying API, and the
  custom/compound dictionary surfaces are out of scope (OQ7).
- **The tree region is comptime-capped (OQ8).** The caller-owned `Buffer`
  carries a tree region sized for a comptime-capped **64 trees per category**;
  a meta-block declaring more fails `TooManyTrees`, and the cap is documented
  and raisable. The alternatives were rejected: the full 256-cap region costs
  ~2.7 MB of tables against a 4-MiB-class window (the C heap-allocates per
  meta-block; this package's posture is zero allocation), and an
  allocator-taking `Reader.init` for the tree region alone would make every
  streaming caller allocate for a worst case no measured stream approaches
  (every stream the sweep produced uses single digits). **The landed shape
  (slice 2):** `huffman.Tree` is a two-level table — a 256-entry root table
  indexed by the next eight wire bits, then one subtable per root prefix whose
  codes run long, sized by the longest code in that prefix's group; the
  consumption is a peek-table (`bits.BitReader.peek` plus a strict `take` — the
  flate reader's rule: the peek may read padding, the take is the gate, so a
  starved decode is `Truncated`, never a symbol out of padding). Each tree's
  table is bounded by the reference's *proven* ceiling (`kMaxHuffmanTableSize`,
  13.4% over the alphabet size; THIRD_PARTY.md), so the region is a comptime
  array, never an allocation: 2,528 B per literal tree, 4,328 per command
  tree, 3,688 per distance tree, 2,656/1,616/1,880 for the
  block-type/block-count/context-map trees — `huffman.Trees` is **689,512 B**,
  and `frame.Header` (the trees plus the 17,664-byte context arena — the
  modes and the two maps) is **707,204 B**, the README's "about 691 KiB". The
  cap applies to the three *tree* categories (NTREESL, NBLTYPESI, NTREESD);
  NBLTYPESL/NBLTYPESD are not capped — they size the modes array and the maps,
  and the format's own 256-value ceiling fits (the literal map is 64 × 256 =
  16 KiB). The build checks the computed table size against the ceiling and
  returns `BadHuffmanCode` if it ever exceeds it: no conformant code-length set
  can (F2), and the check is what makes the region a hard bound rather than a
  hope. **[sketch call, landed]** the one-shot carries the same region as a
  comptime stack local (about 691 KiB at the cap, 707,204 bytes for
  `frame.Header`), because `decompress(source, target)` has no buffer
  parameter; the README's Stack bullet states the figure. If it bites, a
  `decompressBuffered` addition follows the zstd `compressBuffered` precedent
  without reshaping the two names.
- **Extensions are out of scope (OQ7, T3).** The large-window extension: the
  RFC's invalid 0010001 pattern is refused with `BadWindowBits`, and the CLI's
  forced leniency (`BROTLI_DECODER_PARAM_LARGE_WINDOW` set unconditionally,
  `brotli.c:1205-1209`) is a recorded divergence, never a model; no
  `--large_window` surface. Custom and compound dictionaries (`-D`, shared
  dictionaries) are extension surfaces: a stream encoded with one is not an
  RFC 7932 stream, and its distances fall past the dictionary space and fail
  naturally (`BadDictionary`/`BadDistance`), so no dedicated refusal surface is
  needed. The dictionary milestone verified the refusal live
  (`dictionary-notes.md §5.2`: the CLI 1.2.0's `-D` stream decodes with `-D`,
  fails without it, and fails here with the natural distance refusal) and lands
  no brotli dictionary API; the milestone row in `docs/compress-plan.md`
  records the negative.

- **The prefix-code layer owns both forms and both Kraft rules (§3.4, §3.5).**
  `huffman.zig` reads the simple form (NSYM 1..4, ALPHABET_BITS as the width
  rule of T7, the tree-select bit, the sorted-symbol-order assignment) and the
  complex form (HSKIP, the code-length code over the fixed 18-symbol order,
  the 16/17 repeat machine with the reference's exact modifier arithmetic, and
  the main code's length sequence), then builds the §3.2 canonical table. The
  two Kraft equalities are `space == 0` accumulators — 32 for the code-length
  code, with the one-non-zero-length zero-length-code exception; 32768 for the
  main code — and each rejection site keeps one name (OQ5):
  `BadCodeLengthCode` for the code-length code, `BadHuffmanCode` for the length
  sequence and the table bound. A tree's declared alphabet is a runtime
  parameter (block types are NBLTYPES + 2, context maps NTREES + RLEMAX,
  distances 16 + NDIRECT + (48 << NPOSTFIX)), so the tree type's comptime
  parameter is the *storage* bound, not the alphabet.
- **The context layer owns the wire of §7.1 and §7.3.** `context.zig` reads
  the modes (two bits per literal block type) and the two maps: RLEMAX's 1..5
  bit code, the map's own prefix code, the zero-run coding, and the IMTF bit.
  The context ID computation — the three Luts, the literal formulas, and §7.2's
  copy-length bands — is the command layer's. The map values are in
  [0, NTREES-1] by the alphabet size and by the MTF's own property, so nothing
  downstream re-checks an index; §7.3's "NTREES must equal the number of
  different values" is an encoder obligation the references do not check, and
  neither do we.

## The requirement matrix, mapped to the layers

Five layers, the research's §1 split (stream, meta-block, prefix codes,
distances, context), with the dictionary and the window as the data plane.
Every BR row lands somewhere; the row text is in `brotli-notes.md` §2.

| layer | BR rows | what it owns |
|---|---|---|
| the root duty | BR1, BR2 | accept every conformant set; reject non-conformant with a named error; bounds-check every value decoded from the stream |
| stream header | BR3-BR5 | the bit order (`§1.5.1`), WBITS, the window arithmetic |
| meta-block ladder | BR6-BR12, BR40 | ISLAST/ISLASTEMPTY, MNIBBLES/MLEN, metadata, uncompressed, NBLTYPES, the stream end and its zero fill |
| prefix codes | BR16-BR20 | the two tree forms (simple, complex), the two Huffman layers (the code-length code and the main code), the two Kraft equalities, the canonical construction (flate's algorithm, §3.2) |
| block switches | BR30, BR31 | the three categories, the type ring `{1, 0}` (T1), the 26-symbol count table |
| context | BR14, BR15, BR32-BR35 | the three Luts, the four modes, the context maps, RLEMAX, the IMTF |
| distances | BR13, BR21-BR26 | NPOSTFIX/NDIRECT, the 4-distance ring (init 16/15/11/4, stream-scoped), the special codes, the reconstruction formula |
| the command stream | BR27-BR29, BR36, BR37 | the 704-symbol IaC alphabet, the implicit-distance band (codes 0..127), MLEN accounting, the inline block-switch order, execution (overlap, cross-meta-block, dictionary-vs-window) |
| dictionary and transforms | BR38, BR39 | the ported data, the 21 elementary transforms, the 121 compositions |
| the window | BR41 | the history ring, the `-16` bound |

The file split as landed: `bits.zig` (the LSB-first reader), `frame.zig` (the
stream header, the meta-block ladder, and the compressed header's completion),
`huffman.zig` (both tree forms, the table builder, and the OQ8 region),
`context.zig` (the modes and the maps), `distance.zig` (the four-distance
ring, the special codes, and the per-meta-block NPOSTFIX/NDIRECT tables),
`command.zig` (the insert-and-copy alphabet, the three block switches, the
context IDs, the distance element, and the copy machinery), `dictionary.zig`
(the §8 class's word fetch and transforms, over the generated
`dictionary.bin.base64` and `dictionary_data.zig`), `golden.zig` (the CLI-verified
wire vectors, the test-side bit writer, and the §11.1 trivial compressor),
`decode.zig` (the one-shot and the shared decode state, slice 5), and
`Reader.zig` (the streaming `Io.Reader` over the same layers, slice 6). The
oracle lane's files are `oracle.zig` (the harness), `scripts/brotli_oracle.py`,
and `scripts/brotli_go/` (the Go reference).

The command layer's shape, as landed: the loop takes a `Window` — `bytes`,
the index of the next output byte, the stream's produced count, the
meta-block's remaining MLEN, and `§9.1`'s bound — and runs to the meta-block's
end or the window's, whichever comes first. `decodeMetaBlock` (the one-shot)
calls it once with the whole meta-block's room, so its target *is* the window;
`step` with a `Cursor` is the same body stopped between any two bytes, which
is what the streaming ring resumes from. The copy machinery is `copyMatch`, a
free function over `(window, pos, distance, length)`: the ring passes
contiguous segments, and its source may sit past `pos` (the ring's previous
pass), where the pattern's head is copied from the wrapped source — through
`fastmem.move` when the destination overlaps it in the buffer — and then
doubled as before. `fastmem.move` is
deliberately not the overlap primitive: a move copies as through a temporary
and preserves the source, while §10's overlapping reference replicates the
pattern, so the overlap is a doubling run of `fastmem.copy` (the flate
decoder's `copyMatch` shape). The literal context reads p1/p2 back out of the
window, so a byte an uncompressed meta-block produced is context for the next
compressed one with no extra state (§7.1, BR32).

The §8 class boundary is the `step` loop's `.distance` phase: a resolved
distance above `min(window size, produced)` resolves through
`dictionary.transformedWord` into the cursor's 38-byte scratch and writes like
an insert, so §9.3's MLEN check is the *produced* length — the copy length for
a window match, the transformed word's length for a dictionary reference
(which can be shorter or longer than the copy length; the C detects the same
overrun as a negative remaining length at the meta-block's end). That moved
the copy's MLEN check below the distance read: a dictionary reference whose
produced length fits is legal even when its copy length would not, and the
read order matches the reference's (`ReadDistance` before the class branch).
The word lives in the cursor, not on the stack, because a ring may run out of
room mid-word and resume.

## The streaming Reader (slice 6)

`Reader.zig` is the `Io.Reader`: the same layers, driven from an incremental
input and writing into a ring the consumer reads out of.

- **`Buffer(window_wbits)` is a struct, not a byte array**: `ring: [1 <<
  window_wbits]u8` and `header: frame.Header`, so the tree region's alignment
  is the compiler's (`frame.Header` is 4-aligned; a bare `[N]u8` would have
  needed `@alignCast` at every decode). The README's API block states the
  shape, and `@sizeOf(DefaultBuffer)` is pinned by a test so the README's
  figures cannot drift.
- **The ring is the serving region**, so a consumer must keep up within a
  window's worth of output: the reader decodes into `[end, ring.len)` and the
  consumer reads `[seek, end)`. When the ring fills the reader stops (the
  flush); when the consumer has drained it the ring wraps (`seek = end = 0`)
  and the history stays where it is. `end` is therefore both the ring index of
  the next output byte and the `Io.Reader`'s end, and `produced` (the stream's
  total) is what §8's bound and the dictionary class compare against — it
  keeps growing after a wrap. A contiguous `peek`/`take` is served up to the
  ring's room at the read position; a larger one is `StreamTooLong`, and
  `rebase` wraps a drained full ring first so a consumer can keep peeking.
- **`StreamBits` is the `Io.Reader`-driven bit source**: the layers are
  generic over `Bits`, so the header, the ladder, the prefix codes, and the
  command stream run the *same* code as the one-shot, pulling input whenever
  the loaded slice runs out. The seam is `bits.BitReader.attach(source, base)`
  plus `loadedBytes()`: `pull` gives the input back every byte the accumulator
  has loaded and then forces one read, because a plain `fill(1)` would return
  on the byte the accumulator already holds and the caller's loop would make
  no progress. A byte-level `takeBytes`/`skipBytes` drains the accumulator's
  whole bytes first, then reads the slice. **The input's buffer must hold at
  least four bytes** (the widest field is 24 bits); the README says so.
- **The end is exact (T4)**: the `.end` phase checks §9.3's zero fill and then
  gives the input back the bytes the stream consumed, so `input`'s position at
  a clean end is the next stream's first byte. `streamAll` walks there; a tail
  that cannot begin a stream fails `BadStreamStart` (F10).
- **The uncompressed payload** writes into the ring in segments (bounded by
  the ring's end), the **metadata payload** is skipped by the ladder without
  touching the ring, and the **compressed form** runs `command.step` until the
  ring is full, then flushes.
- **The error set is the README's**, with the comptime vocabulary check the
  one-shot uses: every `DecompressError` name except `BufferTooSmall` (the ring
  is the caller's buffer) plus `WindowTooLarge`, `BadStreamStart`,
  `StreamTooLong`, `ReadFailed`, and `EndOfStream`.

## The one-shot (slice 5)

`decode.decompress` is the whole-stream walk in one function: the `§9.1`
header, meta-block after meta-block through `frame.nextMetaBlock`, the
dispatch over the three forms, the last meta-block's `§9.3` zero fill, and the
returned decoded length. `target` is the window, so the command layer's
`decodeMetaBlock` is called with `target[0..pos + mlen]` — the same shape the
command layer's tests used before, now the public entry point; the target cap
is checked before the call, so the command layer's MLEN accounting stays the
invalid-stream class (`§9.3`), never `BufferTooSmall`.

- **The error set is the README's list, name for name.** `DecompressError` is
  an explicit literal (each name's doc comment cites the section), and a
  comptime block asserts the set equals the README's vocabulary exactly: a
  layer that gains a name fails the build rather than leaking an undocumented
  error, and the `try`s in `decompress` prove every layer name is in the set
  (their return types are the layers' composed sets).
- **The shared state is two fields.** `decode.State` bundles the current
  meta-block's `frame.Header` and the stream-scoped `command.State` (`§4`'s
  ring plus the derived tables). The streaming `Reader` reuses the shape with
  its header arena in the caller's `Buffer`; the walk itself stays the
  one-shot's, because the reader's is ring-based, resumable, and interleaved
  with flushes.
- **The layers stay reachable under `decode`** (OQ2): `decode.prefix`,
  `decode.context`, `decode.distance`, `decode.dictionary`, `decode.command`,
  and `decode.frame`, each one line of doc, the zstd/flate precedent. The
  README's API block documents `decompress` and `DecompressError` only; the
  reachable layers are the same kind of internal surface `flate.decode` and
  `zstd.decode` carry.
- **The §11.1 trivial compressor moved to `golden.zig`** (`trivialBound`,
  `trivialCompress`, `trivialCompressToBuf`): the frame and decode tests both
  drive it, and the command layer's test-only `decodeStream` walk is gone —
  its tests call `decode.decompress`.
- **The oracle lane landed** (see Oracles): `just brotli-oracle` runs
  `src/brotli/oracle.zig` + `scripts/brotli_oracle.py` + `scripts/brotli_go/`,
  and `build.zig`'s `oracle_codecs` gained `brotli`.
- **Deferred, and why.** The reference `tests/testdata/*.compressed*` corpus
  (the 45 vectors) is not vendored and not fetchable in the lane (no network),
  so the lane's live substitute is the CLI's and the Go encoder's own streams
  (F8). The README's `just example brotli decode FILE.br` line needs the
  example CLI, which pumps through `Reader.streamAll` — it lands with
  `Reader.zig`.

## Register findings

Rows discovered while landing a layer; each is a fact the next slice carries,
not a decision.

- **F1 — closed by F9's re-measure (slice 6).** `printf 'A' | brotli -c`
  emits `0f` (WBITS 24) and a one-byte file emits `21` (WBITS 10): the CLI's
  automatic window is a *source-form* behavior, not a size threshold. The
  README's "the default is 22 ... which decodes the CLI family unconfigured"
  was a library default the CLI never emits, and it is corrected: the exported
  default is 24, the format's maximum, which is what the pipe form emits (F9).
  A `Buffer(22)` — 4.7 MiB rather than 16.7 — decodes the file family.
- **F2 — the tree table's ceiling is the reference's, and the build guards
  it.** `kMaxHuffmanTableSize` is a *proven* ceiling (google/brotli v1.2.0
  `c/dec/huffman.c`, "13.4% maximum overhead"; THIRD_PARTY.md). This package's
  two-pass construction was verified against it before landing: 30k random
  conformant code-length sets, plus a hill-climbed maximum (1,078 entries for
  a 704-symbol alphabet against the ceiling's 1,080), produce the same table
  size as the reference's incremental builder and never exceed the ceiling.
  The build still checks, because a region that trusts a table is one
  transcription error from a buffer overrun.
- **F3 — §3.5's single-non-zero-length code-length code consumes no bits.**
  "That symbol results in no bits being emitted ... and no bits consumed": the
  code-length *symbols* are free, but a 16/17 code's extra bits are still read,
  and the main code the sequence describes is a normal tree. Pinned by the
  CLI-verified `complex_single_stream` and its unit test.
- **F4 — `BadBlockLength` is the command layer's, not the header's.** §6's
  block counts "need not count down to exactly zero at the end of the
  meta-block", so a first count larger than MLEN is legal; the C's
  `FORMAT_BLOCK_LENGTH_1` is raised where the *output* overruns MLEN
  (`decode.c`'s `WriteRingBuffer`, `meta_block_remaining_len < 0`). The §3
  table's "BR12, BR31 (the block-count decode)" attribution is loose: the
  count decode itself cannot fail beyond `Truncated`, and the overrun check
  lands with BR29 in the command layer.
- **F5 — the header's field order is one wire sequence, trees interleaved.**
  §9.2 reads NBLTYPESL/I/D, each with its own block-type tree, block-count
  tree, and first count; then NPOSTFIX/NDIRECT, the modes, NTREESL + the
  literal map, NTREESD + the distance map; and only then the three tree groups
  (literals, insert-and-copy, distances). The references confirm it
  (`decode.c`: `BROTLI_STATE_HUFFMAN_CODE_*` → `METABLOCK_HEADER_2` →
  `CONTEXT_MODES` → `CONTEXT_MAP_1/2` → `TREE_GROUP`), and the interleaving is
  what makes "each count read needs its tree" true.
- **F6 — the dictionary branch is closed; the class decodes.** §8's class
  boundary (a distance past `min(window size, produced)` is a dictionary
  reference) and its length rule (4..24, else `BadDictionary`) are wired in the
  command layer, and the word fetch — index/transform selection, the 121
  transforms, the produced-length MLEN check — is `dictionary.zig`. The
  interim `DictionaryRequired` name is gone. The measured split is test
  coverage: the three `cli_text_q5/q9/q11` streams (slice 3's parked
  refusals) decode byte-exact, `window_bound` proves the window half of the
  minimum (WBITS 10, 2000 produced, distance 1500 -> the word "lose"), and
  the port's sweep (56 CLI streams, 6 shapes x 8 qualities, 1.2 MB
  compressed) decoded 5,381 dictionary words byte-exact: text at q4 and up
  carries hundreds to 1,166 references per stream (q11 on the RFC text:
  1,166 — the research's own figure), q1..q3 carry a handful or none, and
  random and RLE shapes never reference it at any quality. The `-v` reasons
  pin the refusals: `dictionary_length` is FORMAT_DICTIONARY (-12),
  `dictionary_transform` (transform id 121) FORMAT_TRANSFORM (-11).
- **F7 — both MLEN overruns report `FORMAT_BLOCK_LENGTH_2` on one-shot-sized
  streams.** F4's collapse to one name is exact: the C's
  `FORMAT_BLOCK_LENGTH_1` fires only when the ring buffer flushes mid-meta-block
  with a negative remaining length (a meta-block larger than the ring), so the
  insert overrun and the copy overrun both reach `METABLOCK_DONE` and report
  `FORMAT_BLOCK_LENGTH_2 (-10)` — pinned by the two refusal vectors.

- **F8 — the reference corpus row is not landable offline.** google/brotli
  v1.2.0's `tests/testdata/*.compressed*` (the 45 decodable vectors) is
  neither vendored here nor present in the nix store, and the lane has no
  network, so the conformance lane's live substitute is the two references'
  own encoders: 96 CLI streams (8 inputs × qualities 0..11, the pipe form),
  18 file-form rows, the Go encoder's 40 streams, and the corruption and
  truncation batteries. Vendoring the corpus (or a fetch step) stays open for
  whoever wants the reference harness's exact shape
  (`run-compatibility-test.cmake`).
- **F9 — the CLI's automatic window is 24 for pipes and 10..19 for files.
  Re-measured for the Reader's default (slice 6).** Over 7 shapes (empty, a
  1-byte file, the 8 KiB text, 64 KiB of random, 136 KB of RLE, the 390 KB RFC
  text, and the 81 KB notes) x 12 qualities = 84 rows: **every pipe row is
  WBITS 24** (the CLI cannot stat a pipe, so it uses the maximum), and the file
  form's histogram is `{10: 20, 14: 10, 17: 20, 18: 22, 19: 12}` — never above
  19. The Reader's default is therefore 24, the format's maximum, which refuses
  nothing conformant; the README's default line and its size figures move with
  it. The oracle lane pins both classes (the file lane asserts the 1-byte file
  is 10 and the pipe form is 24).

- **F10 — `BadStreamStart` is the start position's name for §9.1's invalid
  pattern, and the one-shot keeps `BadWindowBits` for it.** The register's
  sketch call wanted the two names split by a *completed-stream count* ("the
  walk found bytes" vs "your stream is bad"), but with the README's API block
  there is nowhere to thread that count: `streamAll` reports only the coarse
  `ReadFailed`, and a caller who "drives a `Reader` for the cause" starts a
  fresh one, which would report the stream's own name. So the split is by
  entry point: `decompress` reads a stream's own header and names the pattern
  `BadWindowBits` (T3, the large-window marker — the oracle lane's refusal
  row), while a `Reader` is only ever at a *start position* (its own, or the
  walk's next iteration), where the bytes "cannot begin a stream": both are
  `BadStreamStart`. That is what the README's Behavior section says, and it
  keeps both names reachable — `BadWindowBits` stays in the Reader's set by
  the README's vocabulary rule, never raised there.
- **F11 — the streaming bit seam needs an explicit slice base.** `attach`
  cannot assume its slice begins at the byte holding the next unconsumed bit:
  the reader's own count and the input's buffer coordinates drift apart (a
  fill slides the buffer; the walk starts a second `Reader` at a nonzero
  input position), so `attach(source, base)` carries the stream byte
  `source[0]` is and `loadedBytes()` names the first byte the accumulator has
  not read. `pull` gives the input back everything loaded — a plain `fill(1)`
  would return on the byte the accumulator already holds, and the caller's
  loop would spin — and forces one read; the streaming `takeBytes`/`skipBytes`
  drain the accumulator's whole bytes first, which is also what makes the
  byte-level slice reads exact. The input's buffer must hold at least 4 bytes
  (the widest field is 24 bits): with 1 byte the reader can never assemble a
  `take(32)`, and the fill that would add more asserts in std's `rebase`.

## Errata register

RFC 7932 carries one Verified and one Reported erratum; both are recorded here
because the vendored file is verbatim.

- **5948 (Verified, Editorial).** §3.5's "three of more" is a typo for "three
  or more". Nothing load-bearing.
- **6977 (Reported, Technical).** §9.3's distance block-switch conditions omit
  "and the distance code is not an implicit 0, as indicated by the
  insert-and-copy length code". Read literally, a decoder would read a
  distance block switch (type + count) for a command whose distance is
  implicit — a misparse. §10's own algorithm and both references implement the
  exclusion. Decision: implement §10 (T2); the vendored §9.3 text is annotated
  in a comment, never copied into a test.

No other errata exist for this RFC; unlike RFC 8878, the worked examples and
tables that matter here check out — proven by the hand-built streams of
`brotli-notes.md` §7.3 and the CRC-verified data of §4.3.

## Divergences from the references (T1-T8)

`brotli-notes.md` §5 records the RFC text, the C v1.2.0, the Go v1.2.6, and the
CLI for each row. Where ours differs from a reference it is on purpose; do not
"fix" it to match.

- **T1 — the block-type ring-buffer init.** §6 says (previous, current) =
  (1, 0); §10's pseudocode says the reverse. Settled against the reference:
  `BrotliDecoderStateMetablockBegin` sets `block_type_rb` to {1, 0}
  (`state.c:120-125`) and `DecodeBlockType` resolves symbol 0 → previous,
  symbol 1 → current + 1 (`decode.c:1208-1218`) — §6's reading. The readings
  differ on real bytes (the first switch's symbol 0 selects type 1, not 0), so
  the fuzz lane pins a first-switch symbol-0 vector.
- **T2 — erratum 6977.** Implement §10: the distance block switch happens only
  when a distance is actually read. Every implicit-0 distance in the golden
  corpus exercises the corner.
- **T3 — the CLI's large-window leniency.** RFC scope: reject 0010001 with
  `BadWindowBits`; the CLI decodes large-window streams only because it
  force-enables the extension. No large-window surface.
- **T4 — trailing bytes and concatenation.** Both references fail closed by
  default (the CLI needs `-K` to concatenate; Go is single-stream). Ours is the
  boundary rule: one stream per `Reader`, `streamAll` walks, a tail that cannot
  begin a stream fails `BadStreamStart`, the zero-byte input is `Truncated` for
  the single-stream entry points. There is no gzip-style warn-and-continue
  mode to accommodate.
- **T5 — the metadata-block ISLAST corner.** §9.2's ISLASTEMPTY exists only
  when ISLAST=1, and §10's loop exit means an ISLAST=1 *metadata* block ends
  the stream too. The corpus pins it: `empty.compressed.15` (the single byte
  `1a`) and `.16` (`81 16 00 58`) both decode to empty through both oracles.
- **T6 — no integrity check exists.** Flipping byte 5 or 10 of a 49-byte q11
  stream decodes without error to *different* output. Corruption lanes assert
  on error *or* difference, never on error alone; any future container owns
  integrity (none is planned).
- **T7 — ALPHABET_BITS is a width, not a floor-log.** `Log2Floor(255) = 8`
  (`decode.c:521-527` is a bit-width loop); the hand-built 8-bit vs 7-bit pair
  proves it on the wire. Implement the width rule and keep the ≥-alphabet-size
  rejection: it is unreachable on power-of-two alphabets (literals) and bites
  on the non-power-of-two ones (704, and distance alphabets where
  NDIRECT/NPOSTFIX make the size inexact).
- **T8 — the transformed-word buffer is 38 bytes.** §8's bound (max
  prefix+suffix 13, 24 + 13 + 1), not the C's 542 (extension slack). The C's
  reading that a transform emptying a word is invalid when the distance code is
  ≤ 120 is adopted as `BadTransform` (`decode.c:2247-2250`).

**The fixture plan** (`brotli-notes.md` §7): the 45 decodable vectors of
google/brotli v1.2.0's `tests/testdata/` (22 round-trip pairs, 19 empty-input
variants, 4 single-byte variants — all decoded byte-exact through both oracles
during research); the hand-built streams of §7.3 (`hand.br`'s full ladder in 9
bytes, the unordered-symbol pair, the ALPHABET_BITS pair, the §3.4 rejection
set, the trivial-compressor streams, `lw.br`, `cmt.br`); the corruption battery
(flips and truncations with their CLI reasons); and the empty family decoded by
hand (§7.2). The Go port's `brotli_test.go` carries inline hex vectors for both
directions — a secondary source worth mining at the conformance lane, not
vendored.

## The dictionary port (OQ1, OQ6)

The data is generated, never hand-copied: Appendix A's hex parses mechanically
(3,837 lines → 122,784 bytes) and the transforms come from Appendix B, both by
a commit-time script under `scripts/` (the flate-oracle pattern) — committed
once, never re-run silently, never fetched at build time.

**Landed (slice 4):** `scripts/brotli_dictionary_gen.py` parses the vendored
RFC and writes two committed artifacts: `src/brotli/dictionary.bin.base64` (Appendix
A's 122,784 DICT bytes, embedded by `dictionary.zig` via `@embedFile`) and
`src/brotli/dictionary_data.zig` (NDBITS, the pool, the map, the 121 triplets,
and the cut-off table, as Zig source). The script asserts every check value
the RFC prints (DICT 122,784/0x5136cb04, the flat sequence 648/0x3d965f81),
the DOFFSET recursion's end (`DOFFSET[24] + 24 * 32 = 122,784`), the affix
bound (13, transform 73), and the cut-off table (`{0, 12, 27, 23, 42, 63, 56,
48, 59, 64}`, *computed* from the parsed Appendix B, not copied). Its output
is `zig fmt` clean; `ruff`/`ty` cover it with the other scripts. The generated
`dictionary_data.zig` is regenerated byte-identically on every run (checked
by re-running the generator and diffing).

| element | bytes | CRC-32 (the RFC's own claim) |
|---|---|---|
| DICT (Appendix A) | 122,784 | 0x5136cb04 |
| the transform sequence (Appendix B) | 648 | 0x3d965f81 |
| Lut0 / Lut1 / Lut2 (§7.1) | 256 each | 0x8e91efb7 / 0xd01a32f4 / 0x0dd7a0d6 |

Every value was verified during research, both by python's `zlib.crc32` and by
`std.hash.crc.Crc32` against the 0.16.0 store, and the 122,784 bytes are
byte-identical across the RFC, the C's `dictionary.bin`, and the Go port
(the committed form is `dictionary.bin.base64`, the same bytes as base64
text). The
ported *representation* is the C's deduplicated transform shape (OQ6): a
217-byte prefix/suffix pool, a 50-entry `u16` offset map, and 121 triplets of
`[prefix_id, transform_type, suffix_id]` (`transform.c:15-172`, 680 bytes), with
the `cutOffTransforms` shortcut table (`{0, 12, 27, 23, 42, 63, 56, 48, 59,
64}`) for the `["", OMIT_LAST_k, ""]` cases. The CRC test pins the port against
the RFC's flat 648-byte form, so both representations stay honest against each
other. The transformed-word bound is 38 bytes (T8), and the `word_id`
arithmetic — `word_id = distance - (max allowed distance + 1)`, `index =
word_id % NWORDS[length]`, `transform_id = word_id >> NDBITS[length]` (§8) —
plus the Ferment UTF-8 case-flip semantics are where a dictionary bug hides;
the dictionary-bearing goldens (the eight hand-built vectors below plus the
three CLI text streams) and the CRC pins are the gates.

**Landed, and where the shape went past the sketch:**

- The pool's *order* is first use in Appendix B, not the C's own order (the
  reference's pool order is hand-chosen — no generator in google/brotli
  produces it). Only the transform semantics are pinned, and the
  `dictionary_data.zig` header says so; the triplet *types* are the C's
  numbering (`transform.h`), so the flat-form CRC test maps them back through
  `rfcType` and proves the generated tables encode Appendix B's list exactly,
  in order. The landing also parsed the C's `kPrefixSuffix`/map/triplets and
  compared all 121 `(prefix, type, suffix)` triples with ours: zero
  mismatches, and the C's pool is a permutation of ours (same 50 strings).
  `dictionary.bin` is byte-identical to the C's `c/common/dictionary.bin`.
- The 121 triplets' type bytes are validated at comptime (`<= OmitFirst9`);
  the pool offsets come from the generated map, so a bad offset is a compile
  error, not a misdecode.
- `cut_off_transforms[0]` (0) is the identity fast path, as the C's
  `decode.c` uses it; the other nine entries are the encoder's cut-off ids,
  carried because the table is the reference's shape and the generator
  *computes* it from Appendix B.
- The Ferment guards: the RFC's `Ferment` checks `pos + 1 < word_len` /
  `pos + 2 < word_len` before the flip; the C's `ToUpperCase` drops them and
  writes one or two bytes past the word into its ring-buffer slack, where the
  suffix copy (or the next word) overwrites them. The emitted bytes agree, so
  the port implements the RFC's guarded form — the 38-byte scratch is never
  written past its returned length.
- The emptiness guard (T8) landed as the C reads it: `word.len == 0 and
  distance <= 120` is `BadTransform`. For RFC streams the guard is
  unreachable (the smallest emptying transform is OmitFirst4, id 34, so an
  emptied word's `word_id` is at least 34 * 1024 and its distance above
  120); the *acceptance* half — an emptied word at a distance above 120
  produces nothing — is pinned by `dictionary_empty`.
- The transform arithmetic is verified twice: `dictionary.zig`'s unit tests
  cover the classes against Appendix B, and the landing sweep ran every
  (length 4..24) x (transform 0..120) pair — 2,541 streams — through the
  pinned CLI, then through `transformedWord`, byte-for-byte, and 56 real CLI
  streams (6 shapes x 8 qualities) through the whole decoder (5,381
  dictionary words; F6).

## The encoder (`encode.zig`, `encode_match.zig`, `encode_huffman.zig`, `Writer.zig`)

The first encoder class is the reference's `q3` (`docs/research/brotli-encode-notes.md`
§1.5, the `EN` matrix in §6): the `h03` quickly hasher through
`BrotliStoreMetaBlockTrivial` — one emission path, fresh trees per meta-block,
NBLTYPES 1/1/1, no block splitting, no context modeling, and no dictionary
search (`H3`'s `USE_DICTIONARY` is 0, so the reference's dictionary decision
path is compiled out, not ported). The file split follows the layers: the
hasher, the greedy scan, and §5's length codes in `encode_match.zig`; the
depth-limited tree builder, §3.2's assignment, and §3.5's run-length
serialization in `encode_huffman.zig`; the bit writer, the stream/meta-block
assembly, the trivial emission, and the one-shot in `encode.zig`; the
streaming form in `Writer.zig`.

**The parity pin.** `encode.compress` is byte-identical to the pinned CLI's
file form at `brotli -q 3` — `BrotliEncoderCompressStream(FINISH)` with
`SIZE_HINT` unset at the CLI's automatic window. The window rule is the CLI's
own (`c/tools/brotli.c`): the smallest `lgwin` in 10..24 whose
`(1 << lgwin) - 16` bound holds the input, so the one-shot is a pure function
of the input bytes. The size hint is structurally unused at `q3`
(`ChooseHasher` reads it at `q4`+, context modeling at `q5`+), which is what
makes the pin a function of the input alone. The oracle lane asserts the
parity per row; the fuzz targets assert validity only (there is no in-process
reference encoder).

**The emission is sized before it is written.** The reference writes a
meta-block into a `2 * bytes + 503` storage buffer, compares the result
against `bytes + 4`, and rolls back to the uncompressed form when the
compressed one does not pay. This package has no such buffer — `target` is the
caller's, sized to `maxCompressedLength` — so the same emission runs twice:
once against a counting sink to learn the exact size (which is what the
rollback rule needs), then for real. The two passes are the same code over
the same cached trees, so they cannot disagree; the decision is made before
the first byte lands, and the one-shot never writes past `target`. The cost is
one extra pass over the emission per meta-block; the match finder dominates.

**The sink.** `encode.Sink` is the bit writer's destination: a slice (the
one-shot), a counting sink (the sizing pass), or a streaming window flushed
to an `Io.Writer` (the `Writer`). That is what lets the streaming form write
MiB-scale meta-blocks with no allocation: the emission hands whole bytes to
the output window as it fills, instead of buffering the meta-block.

**The `Writer`'s ring is the reference's.** `ComputeRbBits` gives
`1 << (1 + max(lgwin, lgblock))` — twice the window — because a match at the
window bound `(1 << lgwin) - 16` must stay resident while a whole 16-KiB input
block is being written; a `1 << lgwin` ring is 16,368 bytes short at the
bound. A 16-KiB mirror of the ring's first bytes follows it (the reference's
`tail_size_`), so a read of up to one input block never wraps and the match
length compare stays a flat 8-byte-at-a-time loop. The mirror is refreshed
after every input block.

**The `Writer` is not byte-pinned.** It shares the core with the one-shot, so
a `Writer` fed everything at once at the one-shot's window emits the
one-shot's exact bytes (a test pins that); a caller that flushes mid-stream or
writes in pieces gets a valid stream with the encoder's own meta-block
boundaries, which is the README's contract and the zstd precedent.

**`maxCompressedLength` is the q3 class's bound, not §11.1's.** The research's
`EQ6` recorded `input_len + 3 * (input_len >> 16) + 5` — §11.1's bound for the
*trivial* compressor's 64-KiB blocks. The q3 class emits 16-KiB-granular
meta-blocks and a fresh tree per meta-block, so its worst case is larger:
every meta-block costs at most five bytes of header beyond its input (the
`bytes + 4 < (*storage_ix >> 3)` rollback rule bounds the kept compressed
form, and an uncompressed meta-block's header is at most 28 bits plus the
zero fill), and every meta-block but the last holds at least one full input
block, so an `N`-byte input has at most `1 + (N >> 14)` of them. Measured, not
argued: on a 128-KiB adversarial input (`/tmp` shapes from the research lane,
a 5-byte repeat every 700 bytes) the pinned CLI emits `N + 11`, past §11.1's
bound. The shipped formula is `N + 5 * (N >> 14) + 7`, and the README's
figures move with it.

**Deviations.** `encode_match.findReferences` is 141 lines: the reference's
greedy scan cascade, kept whole for the same reason snappy's `encodeBlock`
and zstd's `match_compress.scanBlock` are (the house's deviation register) —
one labeled control flow whose state would otherwise be threaded through
helpers. Its pure pieces are extracted. The encoder carries no Tracy zones
(the repo has no profiler dependency) and no allocation on any path.

## Encoder register findings

- **E1 — the distance ring's initial order is the *reverse* of the decoder's
  array.** The C's encoder initializes `dist_cache_ = {4, 11, 15, 16}` with
  index 0 the most recent, while the decoder's `dist_rb = {16, 15, 11, 4}` is
  indexed so that the initial "last distance" (symbol 0) resolves to 4
  (`TakeDistanceFromRingBuffer` walks backwards from `dist_rb_idx`). The
  encoder's `ComputeDistanceCode` compares against `dist_cache[0]`, so the two
  orders are the same state. Porting the decoder's array order into the
  encoder produces a stream that decodes to different bytes — the parity suite
  catches it on any input with a short-code distance.
- **E2 — `ExtendLastCommand` is what makes a block boundary invisible.** When
  the pending meta-block's last command is a copy and the new input continues
  the same match, the reference extends that command's copy length instead of
  starting a new command mid-match. Without it, every chunk-boundary match
  costs a command and the byte parity fails on any input longer than one input
  block. The extension's condition reads `CommandRestoreDistanceCode` — the
  *intermediate* code, distance + 15 — not the distance, so the port compares
  `code - 15` against `dist_cache[0]`.
- **E3 — `CommandRestoreDistanceCode` adds the 16 short codes, not 15.** The
  decoder's §4 reconstruction is `offset + extra + 1`; the encoder's inverse
  is `offset + extra + 16`, because its offset is 4 lower (`-4` in the
  formula) and its result is the intermediate code. Reading the `- 1` of the
  short-code count into this function (as the first port did) shifts every
  extended command's distance by one and fails parity on multi-block inputs.
- **E4 — the `H3` hasher's bucket bits are 16, not 17.** `quality.h`'s
  comment says `b17`; the `hash.h` macro block that instantiates `H3` inherits
  `BUCKET_BITS 16` from `H2` and only overrides the sweep bits and the
  dictionary flag, so the table is `1 << 16` entries with a two-entry sweep
  (`BUCKET_SWEEP_BITS 1`) and `HASH_LEN 5`. Verified by compiling the
  reference's `HasherSize` (`alloc0 = 262144` bytes = 65,536 buckets) and by
  the byte parity of every small input.
- **E5 — the reference allows one read at the current block's end.** The
  hasher's compare byte (`data[cur_ix + best_len]`) can land exactly on
  `pos_end` when the previous match ran to the block's end. The reference's
  ring carries zeros in the seven bytes past the copied input on the first
  lap, so that read is zero; the port makes it explicit
  (`Window.compare(position, block_end)`) instead of relying on ring slack.
- **E6 — the empty input's pin is the CLI's file form, not the library's
  shortcut.** `BrotliEncoderCompress` returns the two-byte `06` for an empty
  input before any encoder state exists; the CLI's file form goes through the
  streaming encoder and emits the window header plus the empty last
  meta-block (`a1 01`, WBITS 10). The one-shot follows the CLI — the pin —
  and the README records the divergence.
- **E8 — the hasher stitches *before* `ExtendLastCommand`.** The reference's
  `EncodeData` order is: `InitOrStitchToPreviousBlock` with the *unadvanced*
  position and the full block, then `ExtendLastCommand` (which advances both
  for the matcher only), then `BrotliCreateBackwardReferences`. The stitch's
  three stores (`position - 3`, `-2`, `-1`) are the only way the last three
  bytes of a block ever enter the bucket table — every other store is bounded
  by `store_end = position + num_bytes - 7` — so stitching after the extension
  silently drops those candidates and picks a different (equally valid, longer
  distance) match. Caught by a "runs" generator at 128 KiB: ours 63,620 bytes
  against the CLI's 63,624, both decoding to the input.
- **E9 — the pin is the CLI's file form, and its read loop is part of the
  wire.** `tools/brotli.c` reads through a 512-KiB buffer and passes PROCESS
  while `feof` is clear, FINISH at the end; a read that returns exactly the
  requested count does not set `feof` (glibc), so a positive multiple of
  512 KiB is processed as non-final and the stream ends with the empty
  ISLAST+ISLASTEMPTY meta-block. The reference *library*'s one-shot
  (`BrotliEncoderCompress`, all input through one FINISH) puts ISLAST on the
  last data meta-block instead, so the two disagree by a byte for exactly
  those sizes. The oracle's encode rows compare against the CLI, so the port
  follows the CLI (`run`'s `final_chunk_is_last`); the README records both
  this and the empty-input `06`-vs-`a1 01` corner. Measured with a streaming
  driver that mimics the CLI (`BrotliEncoderCompressStream(PROCESS)` then
  `FINISH`): it reproduces the CLI's bytes exactly, while
  `BrotliEncoderCompress` at the same (quality, lgwin, size hint) differs at
  byte 175,855 of a 512-KiB record-shaped input.
- **E7 — `ShouldCompress` is a wire constant, not a heuristic.** Its entropy
  sample reads the reference's 256-entry `kBrotliLog2Table` (16 digits, as
  `fast_log.c` prints them) and compares a double against
  `bytes * 7.92 / 13`; the port embeds the table and keeps the accumulation
  order, because a different rounding flips the decision on near-random data
  and the stream then differs by a meta-block header. Above 255 the table
  falls back to `log2`, matching the reference.

## Testing

- **The day-one goldens are the RFC's own check values.** Appendix C defines
  CRC-32, `std.hash.crc.Crc32` is that function (verified on the spec's own
  values), and the vendored RFC text *is* the fixture: no binary vendoring, no
  network. The port's first tests are the five CRCs above plus the
  transformed-word bound.
- **The hand-built streams** (`brotli-notes.md` §7.3) pin the wire: `hand.br`
  exercises every header field and both zero-length-code cases in nine bytes;
  the unordered-symbol and ALPHABET_BITS pairs pin §3.4's construction and
  width rules; the rejection set pins the named errors; the trivial-compressor
  streams pin §11.1's bound exactly (100,008 bytes for a 100,000-byte input).
  **Landed so far** (all built by a §1.5.1 bit writer and verified with the
  pinned CLI before landing; the vectors are in `golden.zig`): `hand_stream`
  (the notes' `hand.br`, three NSYM = 1 codes); `unordered_symbol_stream`;
  `wide_symbol_stream` + `floor_log_stream` (T7's pair);
  `high_literal_stream` (T7's unreachability half);
  `duplicate_symbol_streams` + `out_of_alphabet_streams` (§3.4's rejections,
  the CLI's `FORMAT_SIMPLE_HUFFMAN_SAME`/`_ALPHABET`); `complex_tree_stream`,
  `complex_single_stream`, `repeat16_stream` (§3.5's complex form, the 17 and
  16 repeats, and the single-symbol code-length code);
  `context_map_stream` (§7.3's RLEMAX, zero runs, and IMTF — the map selects
  between two literal trees, so a decoder that ignored the IMTF bit emits
  different bytes). **Slice 3** adds the command stream's set: the four
  special-code/ring vectors (`special_codes`, `ring_init_second`,
  `ring_init_third`, `ring_init_last`, `ring_no_push_zero` — the init 16/15/
  11/4 code by code, and that symbol 0 does not push); `mlen_exact_insert`
  (the ignored copy with no distance element) and the two overrun refusals;
  `negative_special` (§4's zero-resolution refusal); the three switch
  vectors (`block_switch_literal_t1` for T1, `block_switch_command`,
  `distance_switch_t2` for erratum 6977); `ndirect` and `npostfix` (§4's
  arithmetic); `distance_context` (§7.2); the three context-mode vectors
  (§7.1); `dictionary_word`, `dictionary_length`, `window_bound` (§8's class
  and length rule); `cross_meta_block` (§10's cross-boundary copy and the
  stream-scoped ring); `uncompressed_context` (§7.1's p1 across a meta-block
  boundary); and 20 CLI-generated streams (4 inputs × q1/q2/q5/q9/q11) of
  which 17 decode byte-exact here and 3 carry dictionary references (F6). The
  Lut0/Lut1/Lut2 tables are pinned by the RFC's own CRCs (§7.1). **Slice 4**
  adds the dictionary's set, all hand-built from Appendix A/B and verified
  with the pinned CLI: `dictionary_word` (the literal 'A' + "time"),
  `dictionary_ferment` (transform 9, FermentFirst), `dictionary_ferment_utf8`
  (transform 44, FermentAll over a three-byte sequence), `dictionary_affix`
  (transform 73, the longest affix pair), `dictionary_omit` (transform 54,
  OmitFirst9 of the last 24-byte word), `dictionary_identity_24` (the
  identity fast path at the longest length), `dictionary_empty` (an emptied
  word accepted at a distance above 120), `dictionary_transform` (transform
  id 121, the CLI's FORMAT_TRANSFORM), and the now-decoding `window_bound`
  (min(window, produced) with WBITS 10). `dictionary.zig`'s unit tests pin
  the two data CRCs, the DOFFSET recursion, the word selection, the
  transform classes (including both Ferment UTF-8 paths), and §8's 38-byte
  bound over all 2,541 (length, transform) pairs. **Slice 5** adds
  `decode.zig`'s twelve tests, all through the public `decompress`: the
  README usage snippet (its cap, its length, its error path), the reachable
  layers, the empty and last-metadata families (zero decoded bytes, sentinel
  intact), the metadata and uncompressed forms, the whole golden corpus
  (every hand-built vector plus all 20 CLI streams), the §11.1 trivial
  compressor's 100,000-byte bound, the cap (`BufferTooSmall` before the
  write, partial output, the exact-size fit), the trailing-bytes rule (T4),
  the §9.3 last-byte fill (the CLI's `FORMAT_PADDING_2` vector), the named
  refusals of every layer through the public entry point, and every strict
  prefix of five streams (Truncated, never a short decode). The command
  layer's tests now drive `decode.decompress` instead of their own walk.
  **Slice 6** adds `Reader.zig`'s fifteen tests — the README's streaming
  snippet through `DefaultBuffer`, the whole golden corpus and the empty,
  metadata, and uncompressed families through `streamAll`-shaped streaming
  decodes, the exact input boundary after every one of them, the
  `WindowTooLarge` cap, the walk (a doubled stream, the zero-byte clean end, a
  `BadStreamStart` tail with a `Reader` driven for the cause), the consumer
  machinery (the zero-length poll, `StreamTooLong` past the ring's room, a
  sticky failure, a peek-driven consumer across wraps), a one-byte-at-a-time
  input through a 4-byte buffer, the ring's untouched tail (the streaming
  sentinel check), the named refusals of every layer, every strict prefix of
  `cli_small_window` and of the empty family, and the README's size figures
  pinned with `@sizeOf` — plus `bits.zig`'s `attach` test and `command.zig`'s
  exhaustive ring-copy sweep (every position x distance x length against the
  byte-at-a-time §10 reading). The new golden vector is `cli_small_window`
  (`brotli -q 9 -w 10`, 4,400 bytes in 49, one copy of 4,355 at distance 45),
  whose ring wrap under a `Buffer(10)` is deterministic.
- **The close review's vectors.** `dictionary_mlen_overrun` pins §9.3's
  dictionary-word MLEN check — the word "time" after one literal in a
  four-byte meta-block, the CLI's `FORMAT_BLOCK_LENGTH_2` (-10) — in the
  command, `decode` and `Reader` refusal lists. `cli_golden_q9_w16` is the
  pinned CLI's `-q 9 -w 16` output over this file's text at its landing
  commit, 34,382 bytes in 8,192, vendored under `testdata/`: one stream that
  kills the four mutants the oracle alone used to catch — §4's
  implicit-distance push exclusion and its dictionary-reference twin, §3.5's
  16/17 repeat-count reset, and §3.5's first-length-16 rule ("the previous
  length is taken to be 8"). It decodes byte-exact through the one-shot and
  the streaming reader, with the sentinel check; a mutation run against each
  of the four fails that test through both layers. The quality is part of the
  fixture: at `-q 11` the same text's stream drops the first-length-16 tree,
  so the flags and the input pair are frozen together.
- **The golden corpus** (the fixture plan above) is the conformance bar; the
  reference harness's shape is `run-compatibility-test.cmake` (decode plus a
  SHA512 compare). The empty family doubles as a wire-format specification.
  The 45-vector reference corpus itself is not vendored (F8); the oracle lane
  runs the two references' own streams instead.
- **Every decode test carries the sentinel overrun check** (the house rule):
  output pre-filled, bytes past the decoded length untouched.
- **The encoder's set.** `encode.zig`, `encode_match.zig`,
  `encode_huffman.zig`, and `Writer.zig` carry the unit tests: the pinned
  bytes of the empty input (`a1 01`) and the one-byte input, the
  window-by-size ladder, round trips through the one-shot and through a
  `Writer` at every window class, the multi-meta-block and incompressible
  paths, the cap (`BufferTooSmall`, never a short write), the unimplemented
  quality's refusal (and the poisoned writer), the forced mid-stream flush,
  §3.2's own worked example for the canonical assignment, the builder's
  depth limit and determinism, §5's length-code table positions, §4's
  distance-prefix inverse, the matcher's first copy and ring push, and the
  README's writer buffer figure pinned with `@sizeOf`. The parity half is the
  oracle lane, not the suite.
- **Fuzz is the fuzz-engineer's lane. Landed:** `fuzz.zig`'s thirteen
  targets, seeded from `golden.zig`'s vectors and the CLI's streams (nothing
  generated is committed). The codec is decoder-only, so there is no
  self-round-trip and no in-process reference encoder: the corpus's model
  bytes *are* the round trip (the pinned CLI's own output, byte-exact), and
  the differential available in-process is the one-shot against the streaming
  `Reader` (`fuzzDifferential`: same verdict, same named class through
  `sharedName`, same bytes, `§9.1`'s window cap, and T4's exact boundary).
  The encoder half of the differential gap stays open until the encoder
  milestone; `just brotli-oracle` is the external half. The targets:
  `fuzzGoldenCorpus` (every vector at the exact cap, with slack, and one byte
  short, the refusal classes pinned), `fuzzTruncation` (`§10`'s prefix rule,
  both entry points), `fuzzCorruption` (the mutation taxonomy with the class
  pinned wherever the wire rule fixes it), `fuzzDifferential`,
  `fuzzReaderMachinery` (the consumer surface, the ring wrap,
  `StreamTooLong`, the sticky end), `fuzzAmplification` (caps and the
  zero-bit-command bomb: `bombStream`, eleven bytes declaring up to 16 MiB,
  CLI-verified at its landing lengths), `fuzzBits` (`§1.5.1` against a
  bit-at-a-time model), `fuzzHeaders` (the ladder and the invariants a parsed
  `Header` must hold), `fuzzPrefixCodes` (both forms, the Kraft classes, the
  table bound), `fuzzContextMaps`, and `fuzzDictionary` (the 121 transforms
  against an independent model, `§8`'s word arithmetic against the model of
  Appendix A/B, with the boundary pinned on both sides of transform 120). The
  eight plain tests beside them run the whole corpus, the whole truncation
  ladder, the bomb's MLEN boundary, the tree cap, the ring wrap and the
  walk's `BadStreamStart`, the dictionary sweep (7,623 pairs) and the T6
  measurement in `just test`, so a regression fails the suite before a fuzz
  budget is spent. Every target caps its input, its output, and its call
  count; a reader that neither serves nor fails is `error.PumpStalled`
  (reported, never a timeout) — the bit seam's two hangs are that class.
  The fuzz report's one finding is fixed: `huffman.Tree.build` used to panic
  ("integer does not fit in destination type", and undefined behavior in
  ReleaseFast) on an over-subscribed length set whose Kraft sum exceeds the
  15-bit scale, instead of returning `BadHuffmanCode`. The decoder's own path
  never reached it (`readComplexTree`'s `code_space` accumulator refuses such
  a set first), so it was a public-API hazard under `decode.prefix`, not a
  stream-reachable bug; `build` now checks §3.5's Kraft equality itself, so
  any length set either builds or is `BadHuffmanCode`, and `fuzzPrefixCodes`
  feeds it arbitrary sets. Gaps left open on purpose: the distance layer has
  no target of its own (its arithmetic is exercised through the CLI-verified
  `ndirect`/`npostfix`/ring vectors and the command stream, and pinned by
  `distance.zig`'s unit tests); the layer targets feed arbitrary bytes to
  the layers directly rather than through whole streams, so a layer bug that
  only a real stream shape reaches is the whole-stream targets' to find; and
  no target measures allocation, because the decoder allocates nothing (the
  one-shot's region is a stack local and the reader's is the caller's
  `Buffer`).
- **Fuzz corners, from the register** (the targets' source list): T1's
  first-switch symbol 0, T5's last-metadata corner, T7's
  simple-code widths, T6's error-or-difference rule, the walk's boundary (an
  over-end peek reaches the stream end through `rebase` — the pattern book's
  entry, `src/internal/AGENTS.md`), the `TooManyTrees` cap, and slice 2's
  surfaces: both tree forms' rejection sites (the two Kraft equalities, the
  repeat overruns, the §3.4 symbol rules), the code-length-code's HSKIP ladder
  and the 16/17 modifier arithmetic, the single-symbol code-length code, the
  table-bound guard, the context map's RLE overrun and IMTF, and the
  code-length peek that reads padding at the stream's last byte (a decode that
  must be `Truncated`, never a symbol). Slice 3's surfaces for the targets: the
  block-type resolution (T1's init, the symbol-1 wrap, the explicit symbols),
  the MLEN accounting's boundary (the ignored copy, the two overruns), §4's
  zero-resolution `BadDistance`, §8's class boundary and length rule, the
  ring's push exclusions (symbol 0, dictionary), the four context IDs, and
  `copyMatch`'s overlap (distance < length, the one-byte run). Slice 4's
  surfaces: the `word_id` arithmetic's boundaries (the last valid word_id,
  transform 121, index wrap), the transform ids' classes (the two Ferment
  UTF-8 paths, the omit overruns into the empty string), the emptiness guard,
  the encoder's `fuzzEncode` (the one-shot's stream decodes to its input,
  the guard past the decoded length untouched, the result inside
  `maxCompressedLength`) and `fuzzEncodeStream` (the same through a `Writer`
  at every window class, over structured seeds, runs, and random stretches),
  the transformed-length MLEN overrun, and a hostile `dictionary.bin` is not
  a surface — the data is comptime and CRC-pinned, not input. Slice 5's
  surfaces: the one-shot's walk (a stream plus trailing bytes, a stream cut
  anywhere, the empty input, the last-byte fill), the cap arithmetic
  (`BufferTooSmall` before any write past the target, against §9.3's
  invalid-stream MLEN class), and the composition's error-set mapping (any
  input must fail with a name from `DecompressError`, never a panic or a
  write past the cap) — the target is prefilled and the tail checked.
  Slice 6's surfaces: the streaming reader over the same corpus, with the
  input handed over in small chunks (the `pull` seam: an over-end peek must
  reach the input's end and report `Truncated`, never spin), a ring small
  enough to wrap mid-copy (a match whose source is the ring's previous pass)
  and to fill mid-command and mid-dictionary-word (the resumable `step`), the
  flush at the window bound with a consumer that reads in odd-sized peeks, the
  `WindowTooLarge` cap, `StreamTooLong` at the ring's room, the walk's
  `BadStreamStart` at a tail, and the end-of-stream toss (the input position
  must be the stream's last byte + 1, never past it).
- `just test` gates the unit tests, `just fuzz` the targets (ReleaseSafe only),
  `just check-baseline` the portable targets, `just brotli-oracle` the
  differential lane against the two references (Oracles), and `just check-32`
  the 32-bit probes: `src/brotli/probe32.zig` decodes one stream whose
  compressed input runs past 2^32 bytes (257 metadata meta-blocks of 16 MiB,
  generated on the fly) on wasm32-wasi under wasmtime, which is the only place
  the bit reader's u64 stream position can be seen narrowing to a `usize`.

## Oracles

- **The CLI: nixpkgs `brotli` 1.2.0** (already in `flake.nix`, the same tag as
  the C pin). Its `-v` output (`reason: FORMAT_* (<n>)`) is the error-message
  surface the conformance lane asserts against.
- **google/brotli v1.2.0 C** (MIT; the tag's commit is `028fb5a`): the
  reference decoder and the native ceiling. The repo's master HEAD is eleven
  days past the tag with one extension-surface commit, so the tag is the pin.
- **andybalholm/brotli v1.2.6** (MIT): the Go reference — a direct port of the
  C decoder with the same error names and the byte-identical dictionary. This
  is brotli's klauspost seat (klauspost/compress ships no brotli — premise
  corrected during research — and std ships none either).
- Python is no oracle (no stdlib module; the pypi bindings are the C library).

The verified incantations are `brotli-notes.md` §7.5 — every one was executed
during research: the round trip (`brotli -q 11 -c`, then `-d -c | cmp`), the
45-vector corpus through both oracles, the cross-oracle quality sweep, the
corruption battery with the CLI's reasons, the trailing/concatenation/empty
lane (`-K` as the CLI's opt-in), the metadata lane (`-C`), the window lane
(`-w 10..24` plus the auto-lgwin measurement), and the dictionary counter (the
instrumented refuse-mode build).

**Landed (slice 5).** `just brotli-oracle` = `src/brotli/oracle.zig` (the
harness: `decode <stream-file> <cap-bytes>` for the one-shot and, since slice
6, `stream <stream-file> <window-wbits>` for `Reader.streamAll`),
`scripts/brotli_go/` (the Go reference: `decode <stream-file>`,
`encode <input-file> <quality>`), and `scripts/brotli_oracle.py` over
`scripts/oracle_common.py`. One run covers, in about 20 seconds:

- the differential sweep — 8 inputs × qualities 0..11, 96 CLI streams (the
  pipe form, all WBITS 24) — each decoding through our one-shot at the exact
  cap and through the Go reference, to the input bytes;
- the same 96 streams through the streaming reader (`stream ... 24`), each
  decoded twice: once as written and once doubled, which is the walk at T4's
  boundary;
- the ring lane — the `-w 10..24` text streams through a `Buffer` of the same
  size, so the reader's ring wraps under real copies, plus F9's cap row: the
  same pipe stream (WBITS 24) refused by `Buffer(22)` and decoded by
  `Buffer(24)`;
- the window lane — `-w 10..24` on the text shape plus the four research
  values on the other shapes, 23 rows;
- the file lane — 18 rows over the size ladder, asserting the file form's
  WBITS classes (10..19) against the pipe form's 24 (F9), each also decoded
  through the streaming reader at `Buffer(19)`;
- the metadata lane — the CLI's `-C` comment, verified by the CLI and
  decoded by ours and Go;
- the trailing/concatenation rows (T4) — ours ignores the tail, both
  references refuse it, and the CLI's `-K` walks a doubled stream;
- the empty family — 17 streams (the §7.2 table plus T5's terminators)
  decoding to zero bytes through all three;
- the truncation battery — 1,135 prefixes, refused by all three (§10);
  the count follows the sampled input files' sizes, so it moves by a few
  whenever one of them is edited (`src/brotli/AGENTS.md` is one);
- the corruption battery (T6) — 142 flips, each asserting the references'
  verdict: refuse together, or byte-identical output;
- the Go encoder's 40 streams (qualities 0/1/5/9/11 × the 8 inputs) — a
  second encoder family, decoded by ours and by the CLI.

The corpus row (the 45 reference vectors) is deferred per F8. `just test`
keeps the committed golden vectors (the CLI-verified ones) in the unit suite,
so the lane is the differential half and the suite the byte-exact half.

## Performance

The plan's default competitor set has two empty seats for brotli: klauspost
ships none and std ships none (both verified). The arms that exist:

- **google/brotli C v1.2.0** — the native ceiling and the oracle. The decoder
  is one 105-KB `decode.c` with no assembly on the decode side; the numbers
  mean the band the decoder targets.
- **andybalholm/brotli v1.2.6** — the oracle's Go reference (the conformance
  lane's second reference), not a fleet arm: the M6 run races google/brotli's
  C decoder only, and the missing competitors (klauspost/compress ships no
  brotli, std ships none) are recorded in the results file.
- **compress** — ours.

The fleet run records the missing arms (the M4 precedent: the competitor-set
gap is stated in the run's results file under `docs/results/`). Claims cite a
recorded fleet run, never local numbers.

## Sketch calls beyond the register

Collected for the review; each is also marked **[sketch call]** above.

1. **The one-shot's tree region is a stack local (landed; 691 KiB at the
   cap).** The register fixed the streaming `Buffer`'s tree region and the
   one-shot's lack of a window, but not where the one-shot's trees live.
   Options were a stack local (chosen), a caller-buffer form
   (`decompressBuffered`), or an allocator. If the figure bites, the buffered
   form is the zstd `compressBuffered` remedy, an addition that does not
   reshape the two names.
2. **The `BadStreamStart` split.** The notes name it (OQ3, OQ5) but give it no
   §3 taxonomy row; the sketch reads it as the walk's next-stream refusal, with
   `BadWindowBits` for a stream's own header.
3. **`streamAll` on zero bytes is the walk's clean end.** The notes' "the
   zero-byte input is `Truncated`, never a clean zero-byte decode" is the
   single-stream contract; the walk follows the gzip/zstd rule.
4. **No single-stream pump.** `streamAll` only (the zlib shape); a caller who
   wants exactly one stream drives `Reader`.
5. **The tree region's byte figure (landed).** The ~650 KiB budget used the
   reference's two-level table shape; the implementation's shape set the final
   number — `frame.Header` is 707,204 bytes (the tree region plus the context
   arena), the README's Stack figure.
6. **Literals decode straight through.** No staging region: a literal's context
   is the output's own last two bytes, so literals are written directly into
   `target` (one-shot) or the history ring (streaming), and the streaming
   command loop is resumable at command boundaries to make room. The research
   left this as "a recommendation for the slice contract".

## Provenance

google/brotli v1.2.0 (MIT) and andybalholm/brotli v1.2.6 (MIT) were read and
run as oracles during research; the RFC's appendices are the data source for
the dictionary and the transforms. Attribution landed in `THIRD_PARTY.md` with
the port: the RFC's appendices are the data source, the C reference the
representation, and `scripts/brotli_dictionary_gen.py` the generator.
