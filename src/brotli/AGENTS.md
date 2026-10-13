# Agent notes: brotli

The brotli decoder (RFC 7932). `README.md` is the user-facing contract; this
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
  `Reader.Buffer(window_wbits)` and `Reader.streamAll`. The encoder seat
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
  `WindowTooLarge` before any meta-block byte. The default is 22 — the
  reference encoder's default (`BROTLI_DEFAULT_WINDOW`, a 4,194,288-byte
  window) — which decodes the CLI family unconfigured (measured); 23 and 24 are
  one bigger instantiation away. The ring is a power-of-two buffer with the
  `-16` in the bound arithmetic (`§9.1`'s window size), the C's
  `ringbuffer`/`ringbuffer_mask` shape. The RFC's §12 progressive-growth
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
  (every stream the sweep produced uses single digits). The region's exact
  byte figure follows the implementation's table shape; the sketch's budget is
  the reference's two-level table — 2,528 B per literal tree, 4,320 per IaC
  tree, 3,584 per distance tree (`alphabet_size_limit + 376` entries × 4 B,
  `state.c:170-171`), so 64 × (2,528 + 4,320 + 3,584) ≈ 650 KiB.
  **[sketch call]** the one-shot carries the same region as a comptime stack
  local (about 650 KiB at the cap), because `decompress(source, target)` has no
  buffer parameter; the README's Stack bullet states the figure. If it bites, a
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
  needed.

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

The likely file split (the implementation lane's to settle): `decode.zig` (the
one-shot and the shared decode state), `frame.zig` (the stream header and the
meta-block ladder), `huffman.zig` (both tree forms and the table builder),
`context.zig` (the Luts and the context maps), `distance.zig` (the ring and the
reconstruction), `dictionary.zig` (the generated data and the transforms),
`Reader.zig`, `golden.zig`.

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

| element | bytes | CRC-32 (the RFC's own claim) |
|---|---|---|
| DICT (Appendix A) | 122,784 | 0x5136cb04 |
| the transform sequence (Appendix B) | 648 | 0x3d965f81 |
| Lut0 / Lut1 / Lut2 (§7.1) | 256 each | 0x8e91efb7 / 0xd01a32f4 / 0x0dd7a0d6 |

Every value was verified during research, both by python's `zlib.crc32` and by
`std.hash.crc.Crc32` against the 0.16.0 store, and the 122,784 bytes are
byte-identical across the RFC, the C's `dictionary.bin`, and the Go port. The
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
the seven dictionary-bearing goldens and the CRC pins are the gates.

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
- **The golden corpus** (the fixture plan above) is the conformance bar; the
  reference harness's shape is `run-compatibility-test.cmake` (decode plus a
  SHA512 compare). The empty family doubles as a wire-format specification.
- **Every decode test carries the sentinel overrun check** (the house rule):
  output pre-filled, bytes past the decoded length untouched.
- **Fuzz is the fuzz-engineer's lane.** The corners worth a target, from the
  register: T1's first-switch symbol 0, T5's last-metadata corner, T7's
  simple-code widths, T6's error-or-difference rule, the walk's boundary (an
  over-end peek reaches the stream end through `rebase` — the pattern book's
  entry, `src/internal/AGENTS.md`), and the `TooManyTrees` cap.
- `just test` gates the unit tests, `just fuzz` the targets (ReleaseSafe only),
  and `just check-baseline` the portable targets.

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
instrumented refuse-mode build). The lane lands as `src/brotli/oracle.zig` +
`scripts/brotli_oracle.py` behind `just brotli-oracle` (the flate/gzip
precedent).

## Performance

The plan's default competitor set has two empty seats for brotli: klauspost
ships none and std ships none (both verified). The arms that exist:

- **google/brotli C v1.2.0** — the native ceiling and the oracle. The decoder
  is one 105-KB `decode.c` with no assembly on the decode side; the numbers
  mean the band the decoder targets.
- **andybalholm/brotli v1.2.6** — the Go class, the plan's "performance class is
  klauspost" line mapped onto brotli.
- **zcompress** — ours.

The fleet run records the missing arms (the M4 precedent: the competitor-set
gap is stated in the run's results file under `docs/results/`). Claims cite a
recorded fleet run, never local numbers.

## Sketch calls beyond the register

Collected for the review; each is also marked **[sketch call]** above.

1. **The one-shot's tree region is a stack local (~650 KiB at the cap).** The
   register fixed the streaming `Buffer`'s tree region and the one-shot's lack
   of a window, but not where the one-shot's trees live. Options were a stack
   local (chosen), a caller-buffer form (`decompressBuffered`), or an
   allocator. If the figure bites, the buffered form is the zstd
   `compressBuffered` remedy, an addition that does not reshape the two names.
2. **The `BadStreamStart` split.** The notes name it (OQ3, OQ5) but give it no
   §3 taxonomy row; the sketch reads it as the walk's next-stream refusal, with
   `BadWindowBits` for a stream's own header.
3. **`streamAll` on zero bytes is the walk's clean end.** The notes' "the
   zero-byte input is `Truncated`, never a clean zero-byte decode" is the
   single-stream contract; the walk follows the gzip/zstd rule.
4. **No single-stream pump.** `streamAll` only (the zlib shape); a caller who
   wants exactly one stream drives `Reader`.
5. **The tree region's byte figure.** The ~650 KiB budget uses the reference's
   two-level table shape; the implementation's shape sets the final number, and
   the README's Buffer/Stack figures move with it.
6. **Literals decode straight through.** No staging region: a literal's context
   is the output's own last two bytes, so literals are written directly into
   `target` (one-shot) or the history ring (streaming), and the streaming
   command loop is resumable at command boundaries to make room. The research
   left this as "a recommendation for the slice contract".

## Provenance

google/brotli v1.2.0 (MIT) and andybalholm/brotli v1.2.6 (MIT) were read and
run as oracles during research; the RFC's appendices are the data source for
the dictionary and the transforms. Attribution lands in `THIRD_PARTY.md` with
the port.
