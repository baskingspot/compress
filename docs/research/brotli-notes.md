# brotli research notes

The research stage of the codec development loop for M6: the brotli decoder —
the prefix-code, context-modeling, distance, block-switch, and static-
dictionary layers (`docs/zcompress-plan.md`, "Milestones": "M6 — brotli,
decoder first"). Spec: `docs/research/specs/rfc7932-brotli.txt` (vendored,
verbatim). Every requirement line below cites that file and its section; where
the RFC is ambiguous, silent, or self-inconsistent, that is stated explicitly
and the divergence is recorded as a decision for the parent, never silently
picked. The lane shape is M4's `zstd-notes.md` (the codec-scale format study,
the hand-built streams decoded by the oracles to settle wire-level questions,
the OQ decision log with answers inline, the verified oracle incantations,
the pinned reference versions, the fixture and competitor inventories);
`containers-notes.md` contributed the zlib-FDICT refusal precedent that the
dictionary question below tested and rejected. brotli wraps nothing — it is a
codec, not a container — so the layering questions here are zstd's questions
one milestone later, with one new surface the other codecs never had: the
122,784-byte static dictionary the format's distance space folds in.

## 0. Provenance

- Spec: `rfc7932-brotli.txt` — RFC 7932, "Brotli Compressed Data Format"
  (J. Alakuijala, Z. Szabadka, Google, July 2016, Informational), **389,979
  bytes, verified by title line and byte count**; provenance row added to
  `docs/research/specs/README.md` (fetched 2026-10-12 from rfc-editor.org).
  The size is not a typo: this RFC carries its own data — Appendix A is the
  122,784-byte static dictionary in hex (pages 44-123, roughly 60% of the
  document), Appendix B the 121 word transforms, Appendix C a CRC-32
  definition. IETF RFCs are freely distributable (the document's own Status
  of This Memo).
- **The errata register** (fetched 2026-10-12 from
  https://www.rfc-editor.org/errata/rfc7932): one **Verified** erratum and
  one **Reported** technical erratum, both recorded where they bite:
  - **5948 (Verified, Editorial)**: §3.5's "three of more" is a typo for
    "three or more". Nothing load-bearing; the vendored text carries it.
  - **6977 (Reported, Technical)**: §9.3's distance block-switch conditions
    omit "and the distance code is not an implicit 0, as indicated by the
    insert-and-copy length code". Read literally, the vendored §9.3 would
    have a decoder read a distance block-switch (type + count) for a command
    whose distance is implicit — a misparse. §10's own algorithm and both
    references implement the exclusion (§5 T2 below). No other errata exist
    for this RFC — unlike RFC 8878, the worked examples and tables that
    matter here check out (proven by the hand-built streams of §7.3 and the
    CRC-verified data of §4.3).
- Reference implementations read for this file (cited inline as `path:line`):
  **google/brotli at tag v1.2.0** (commit 028fb5a, 2025-10-27; MIT, the full
  license text in `LICENSE`; fetched shallow to `/tmp/brotli-notes-verify/
  brotli-c` for this research) — `c/dec/` (decode.c 105 KB, huffman.c,
  prefix.c, bit_reader.c, state.c), `c/common/` (context.c, transform.c,
  dictionary.bin, constants.h), `c/include/brotli/decode.h` (the API and
  error-code surface), `c/tools/brotli.c` (the CLI), `c/enc/` (the encoder's
  dictionary-use gates, quality.h). The repo's master HEAD (392b261,
  2026-10-05) is eleven days past the tag with one commit — an out-of-bounds
  read fix in compound-dictionary header prefetch, an extension surface out
  of RFC 7932 scope — so the tag is the pin. **andybalholm/brotli at tag
  v1.2.6** (2026; MIT, same Brotli-Authors license; fetched shallow to
  `/tmp/brotli-notes-verify/brotli-go`) — the Go reference: `decode.go`
  (67 KB, a direct port whose error names mirror the C's), `dictionary.go`
  (the same 122,784 bytes as Go source, CRC-verified identical here),
  `reader.go`/`writer.go` (the `io.Reader`/`io.Writer` API).
- **Premises in the task brief that needed correction** (the
  `flate-notes.md` §0 / `zstd-notes.md` §0 precedent, recorded rather than
  smoothed over):
  1. "klauspost's Go brotli (the local checkout `~/code/klauspost-compress`
     has it)" is **false**. klauspost/compress (v1.18.0-5-g8df4d01, local
     checkout, BSD-3) ships s2, flate, gzip, zlib, zip, snappy, zstd, huff0,
     fse, xpress, lzw — no brotli anywhere in the tree (verified: a full
     `find -iname '*brotli*'` and a `grep -rli brotli --include='*.go'`
     return only `gzhttp/compress.go`, a content-encoding name mapping; the
     README's own dependency list points elsewhere for brotli: "* github.com/
     dsnet/compress - brotli decompression"). The Go reference for brotli is
     **andybalholm/brotli** — the port behind the HTTP content-encoding
     ecosystem; the local `~/code/connect-brotli` depends on exactly it
     (v1.0.4 in that repo's go.mod; the oracle here pins the current v1.2.6).
     dsnet/compress (frozen since 2017) also has a decoder but is not the
     maintained reference.
  2. The brief's "citing rfc7972-brotli.txt §x.y.z" is a typo for the
     vendored file's real name, `rfc7932-brotli.txt`; every cite below uses
     the real name.
  3. The std premise, checked per the standing audit lesson (verify, never
     assume): **Zig 0.16.0 ships no brotli** — `grep -ril brotli` over the
     whole std tree (`/nix/store/amh3bnymjncd56jwmd2hqdkciz9d7pys-zig-0.16.0/
     lib/zig/std/`) returns nothing, and `std/compress/` holds only flate,
     lzma, lzma2, xz, zstd. No in-tree competitor, no in-tree fixture source,
     no in-tree API to study or steal. The std side of the audit that did
     land: `std.hash.crc.Crc32` computes RFC 7932 Appendix C's CRC-32 exactly
     (§4.3 — the dictionary, the transform sequence, and all three context
     Luts verify through it), which makes the vendored spec's own check
     values the day-one golden vectors.
- **The CLI on the box: absent** — `brotli` is not on PATH and not in
  `/run/current-system/sw/bin`. The oracle CLI for this research was built
  from the pinned tag (cmake, Release, `/tmp/brotli-notes-verify/build/
  brotli`, reports `brotli 1.2.0`). **nixpkgs carries `brotli` 1.2.0**
  (verified: `nix eval nixpkgs#brotli.version` → `"1.2.0"`, src rev
  `refs/tags/v1.2.0` — the same tag as the C pin; outputs `out`/`dev`/`lib`,
  the `out` output ships the CLI). The flake already pins the conformance
  CLIs (`zstd`, `gzip` at `flake.nix:53-60`, "the flake pins the oracles, not
  the box") — adding `brotli` to that list is the parent's move; this
  research's verified incantations (§5) are written against exactly that
  binary. Python is no oracle here: no stdlib module (verified: `import
  brotli` and `import brotlicffi` both fail), and the pypi bindings are the
  C library anyway — the CLI, the C library, and andybalholm are the oracles.
- Oracles run for this file — every incantation in §5 was executed here and
  its output recorded before being written down (the M3/M4 lesson): the
  built-from-tag C CLI v1.2.0 (round-trips, the golden corpus, the
  corruption battery, the empty-family hand-decode cross-check, the
  large-window and comment lanes), a scratch Go module running andybalholm
  v1.2.6's `NewReader` over the same files (45/45 goldens byte-exact MATCH,
  the same corrupt inputs refused), and `zig run` scratch harnesses against
  the 0.16.0 store (`std.hash.crc.Crc32` over the dictionary and transform
  data). One instrumented build of the reference decoder (a counter and a
  refuse-mode added at the one decision point, `decode.c:2152`) produced the
  dictionary-use measurements of §4.2 — the numbers behind the OQ1 answer.

## 1. Format summary

brotli is an LZ77-family codec with one entropy layer — canonical prefix
codes, the same construction as deflate's — over a stream of meta-blocks,
with two modeling layers deflate lacks: per-block-type context modeling for
literals and distances, and a static dictionary folded into the distance
space. Five layers for an M6 module map: **stream** (the WBITS header),
**meta-block** (the header ladder and the command stream), **prefix codes**
(the two tree forms),**distances** (the ring buffer, NPOSTFIX/NDIRECT, the
dictionary), **context** (the Luts and the context maps). Everything is
read LSB-first from byte 0 forward: "Data elements are packed into bytes in
order of increasing bit number within the byte, i.e., starting with the
least significant bit of the byte"; integer values pack LSB-first and
"prefix codes are packed starting with the most significant bit of the code"
(`§1.5.1`) — the same three rules as RFC 1951 §3.1.1, with the same 520
example stored little-endian (`§1.5`). No checksum exists anywhere in the
format: a corrupted stream that stays structurally valid decodes to
*different data* silently (proven here: flipping byte 5 or 10 of a 49-byte
CLI stream decodes fine, output differs — §7.5). Integrity is out of format.

### 1.1 The stream header (`rfc7932-brotli.txt §9.1`)

"The stream header has only the following one field": WBITS, 1..7 bits, a
variable-length code over 10..24 (`§9.1`'s table: 16 is the single bit `0`;
17 is `0000001`; 18-24 are 4-bit patterns `0011`..`1111`; 10-15 are 7-bit
patterns `0100001`..`1110001`). "Note that bit pattern 0010001 is invalid
and must not be used" — and the reference family reuses exactly that
pattern as the marker for the *large-window* extension (windows up to
2^30, `--large_window`, explicitly "not compatible with brotli RFC 7932"
per the CLI's own help; §5 T3). The window: "The size of the sliding
window, which is the maximum value of any non-dictionary reference backward
distance, is given by the following formula: window size = (1 << WBITS) -
16" (`§9.1`) — "a power of two, minus 16, where the power is in the range
of 10 to 24. The possible sliding window sizes range from 1 KiB - 16 B to
16 MiB - 16 B" (`§2`). The -16 gap (`BROTLI_WINDOW_GAP`, `constants.h:100`)
is why a WBITS-24 decoder needs a 16,777,200-byte history, not 16 MiB.

### 1.2 The meta-block ladder (`rfc7932-brotli.txt §9.2`, `§2`, `§9.3`)

"A compressed data set consists of a header and a series of meta-blocks.
Each meta-block decompresses to a sequence of 0 to 16,777,216 (16 MiB)
uncompressed bytes" (`§2`). "A compliant compressed data set has at least
one meta-block" (`§9.2`). Four meta-block kinds, all reached through one
header ladder:

1. **Last-empty** — ISLAST=1, then ISLASTEMPTY=1: "the meta-block and the
   brotli stream ends at that bit, with any remaining bits in the last byte
   of the compressed stream filled with zeros (if the fill bits are not
   zero, then the stream should be rejected as invalid)" (`§9.2`). The
   canonical empty stream is one byte, `0x06` (verified: the golden
   `empty.compressed` is exactly `06`, and 18 more valid empty encodings
   exist — §7.2's hand-decode of the family).
2. **Metadata** — MNIBBLES=0 (the 2-bit code `11`): a reserved bit (must be
   zero), MSKIPBYTES (2 bits), MSKIPLEN-1 (MSKIPBYTES × 8 bits, only when
   positive), zero fill to the byte boundary, then MSKIPLEN bytes of
   metadata "not part of either the sliding window or the uncompressed
   data. Thus, these metadata bytes cannot be used to create matching
   strings in subsequent meta-blocks and are not used as context bytes for
   literals" (`§2`; the field rules and both exuberant-zero rejections at
   `§9.2`). The CLI's `-C/--comment` rides this path (verified round-trip,
   §7.5).
3. **Uncompressed** — ISUNCOMPRESSED=1 (present only when ISLAST=0): "any
   bits of compressed data up to the next byte boundary are ignored, and
   the rest of the meta-block contains MLEN bytes of literal data"; the
   ignored bits must be zero. "An uncompressed meta-block cannot be the
   last meta-block" (`§2`, `§9.2`).
4. **Compressed** — the full ladder below.

The compressed-meta-block header, in wire order (`§9.2`): ISLAST (1 bit) →
ISLASTEMPTY (1 bit, only if ISLAST) → MNIBBLES (2 bits: `11`→0,
`00`→4, `01`→5, `10`→6) → MLEN-1 (MNIBBLES × 4 bits; MLEN ≤ 2^24;
"if MNIBBLES is greater than 4, and the last nibble is all zeros, then the
stream should be rejected as invalid") → ISUNCOMPRESSED (1 bit, only when
not ISLAST) → **NBLTYPESL, NBLTYPESI, NBLTYPESD** (each a 1..11-bit
variable-length code over 1..256 — 1 is one `0` bit, 2 is `0001`, 3..4 is
`x0011`, doubling bands up to 129..256 at `xxxxxxx1111`; "it must equal to
the largest block type plus one in that block category", `§6`), each
followed — only when ≥ 2 — by its block-type prefix code, its block-count
prefix code, and the first block count → NPOSTFIX (2 bits, 0..3) → NDIRECT
(4 bits; "to get the actual value of the parameter NDIRECT, left-shift
this four-bit number by NPOSTFIX bits", so 0..120) → the context modes
("NBLTYPESL * 2 bits: context mode for each literal block type") → NTREESL
(same varlen; the literal context map follows only when ≥ 2, "otherwise,
the context map has only zero values") → NTREESD (same; the distance
context map under the same rule) → **the three tree groups**: "NTREESL
prefix codes for literals", "NBLTYPESI prefix codes for insert-and-copy
lengths", "NTREESD prefix codes for distances". When a category has one
block type, no block trees are read and its block count is implicitly
2^24 (`§10`: "set block count, BLEN_i to 16777216"; the C's
`BROTLI_BLOCK_SIZE_CAP (1U << 24)`, `state.h:390` — a meta-block is ≤ 2^24
bytes, so a single block type never switches).

### 1.3 The command stream (`rfc7932-brotli.txt §9.3`, `§10`)

Each command: an insert-and-copy length code (under the current IaC block
type's tree), then that many literals (each under the tree selected by the
literal block type + the two-byte context + CMAPL), then a distance (under
the tree selected by the distance block type + the copy-length context +
CMAPD) — unless the IaC code already implied distance code 0. Block
switches are inline: "Whenever an element of a category is needed, and the
block count for that category has reached zero, then a new block type and
count are read from the stream just before reading that next element"
(`§2`) — the type code first, then the count code, per category
(IaC → literal → distance within a command; `§9.3`). The distance
block-switch only happens when a distance is actually read — erratum 6977,
§5 T2. Termination: "If the total number of uncompressed bytes produced
after the insert part of the last command equals MLEN, then the copy length
of the last command is ignored and will not produce any uncompressed
output. In this case, the copy length of the last command can have any
value. In any other case, if the number of literals to insert, the copy
length, or the resulting dictionary word length would cause MLEN to be
exceeded, then the stream should be rejected as invalid" (`§9.3`). "The
last command in the meta-block is permitted to have only literals and no
pointer to a string to duplicate" (`§2`). "If the last command of the last
non-empty meta-block does not end on a byte boundary, the unused bits in
the last byte must be zeros" (`§9.3`). Backward references may cross
meta-block boundaries ("a duplicated string reference may refer to a string
in a previous meta-block"), may overlap the current position (§10's X,Y →
X,Y,X,Y,X example), and "a backward copy distance will not refer past the
beginning of the uncompressed stream or the window size; any such distance
is interpreted as a reference to a static dictionary word" (`§10`).

### 1.4 Prefix codes: the two forms (`rfc7932-brotli.txt §3`)

Canonical prefix codes (`§3.2`): the RFC reprints deflate's construction
algorithm verbatim (bl_count, next_code, consecutive values within a
length, shorter codes lexicographically precede longer), so the code
*assignment* machinery is the flate module's, already built and golden-
tested. The tree description comes in two forms (`§3.4`, `§3.5`), chosen by
the first 2 bits (value 1 → simple):

- **Simple prefix codes** (`§3.4`): up to four symbols. 2 bits NSYM-1, then
  NSYM symbols each in ALPHABET_BITS bits, then a tree-select bit for
  NSYM=4. "If the integer value is greater than or equal to the alphabet
  size, or the value is identical to a previous value, then the stream
  should be rejected as invalid." Lengths: NSYM=1 → zero (the symbol decodes
  from no bits at all — both oracles proven on a hand-built stream, §7.3);
  NSYM=2 → 1,1; NSYM=3 → 1,2,2 "in the order they appear"; NSYM=4 → 2,2,2,2
  or 1,2,3,3 by tree-select. "Note that the NSYM symbols may not be
  presented in sorted order. Prefix codes of the same bit length must be
  assigned to the symbols in sorted order" — proven by hand-build: symbols
  presented (66, 65) still assign 65→code 0, 66→code 1 (§7.3).
  **ALPHABET_BITS is the bit-width of the largest symbol value**
  (alphabet_size − 1) — "the smallest number of bits that can represent all
  symbols in the alphabet. For example, for the alphabet of literal bytes,
  ALPHABET_BITS is 8" (`§3.4`): 8 for literals (256), 10 for IaC (704), and
  alphabet-dependent for distances/block types/counts/context maps
  (`§3.3`). The C computes it as a *width* function it names Log2Floor
  (`decode.c:521-527`: `while (x) { x >>= 1; ++result; }` — Log2Floor(255)
  = 8, not 7); the hand-built w8-vs-w7 pair proves the wire truth (§5 T7).
  A consequence worth a row: for exact-power-of-two alphabets (literals)
  the ≥-alphabet-size rejection is unreachable — no 8-bit read reaches 256
  — so the rejection only bites on the non-power-of-two alphabets
  (proven: an IaC simple code with symbol 704 fails SIMPLE_HUFFMAN_ALPHABET
  on both oracles, the same construction with a literal symbol 256 silently
  reads 0, §5 T7).
- **Complex prefix codes** (`§3.5`): the code-length sequence itself prefix-
  coded, deflate-style. 2 bits HSKIP ∈ {0, 2, 3} ("An HSKIP of 1 indicates
  a Simple prefix code"; the skipped code-length symbols are implicit
  zeros). The code-length alphabet is 0..15 (lengths) plus **16**: "Copy
  the previous non-zero code length 3..6 times" (2 extra bits; "If this is
  the first code length, or all previous code lengths are zero, a code
  length of 8 is repeated") and **17**: "Repeat a code length of 0 for
  3..10 times" (3 extra bits) — both with the back-to-back modifier
  arithmetic (16 after 16: `repeat count = (4 * (repeat count - 2)) +
  (3..6)`; 17 after 17: `(8 * (repeat count - 2)) + (3..10)`; "A 16 repeat
  does not modify an immediately preceding 17 count nor vice versa"). The
  code-length-code lengths (0..5, for the 18 symbols in the fixed order
  **1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, ..., 15**) are coded with a fixed
  variable-length code (`§3.5`'s table: symbol 0 → `00`, 1 → `0111`, 2 →
  `011`, 3 → `10`, 4 → `01`, 5 → `1111`). Two Kraft equalities are
  normative: "the sum of (32 >> code length) over all the non-zero code
  lengths must equal to 32" for the code-length code (max length 5), and
  "The sum of (32768 >> code length) over all the non-zero code lengths in
  the alphabet ... must be equal to 32768" for the main code (max length
  15, `BROTLI_HUFFMAN_MAX_CODE_LENGTH`, `huffman.h:18`). "Any trailing 0 or
  17 must be omitted, i.e., the last encoded code length symbol must be
  between 1 and 16"; "If the number of times to repeat the previous length
  or repeat a zero length would result in more lengths in total than the
  number of symbols in the alphabet, then the stream should be rejected as
  invalid." A complex code with a single non-zero code-length symbol is the
  zero-length-code case again (`§3.5`'s literal example: all-256-equal →
  the one symbol 16 repeating length 8). The C implements every one of
  these rules in `ReadCodeLengthCodeLengths` (`decode.c:748-791`, the
  `space -= 32 >> v` accumulator with the `num_codes == 1 || space == 0`
  acceptance) and `ReadSymbolCodeLengths`; `kCodeLengthCodeOrder` at
  `decode.c:48` matches the RFC order exactly.

The alphabet sizes (`§3.3`, its table): literals 256; IaC lengths 704;
block counts 26; distances "16 + NDIRECT + (48 << NPOSTFIX)" (max 520 at
NPOSTFIX=3/NDIRECT=120); block types NBLTYPESx + 2; context maps NTREESx +
RLEMAX.

### 1.5 Distances and the ring buffer (`rfc7932-brotli.txt §4`)

A distance is `<distance code, extra bits>`, the code prefix-coded and the
extra bits fixed-width ("The number of extra bits can be 0..24"). Three
code bands:

- **0..15, the special codes**: 0 = last distance, 1..3 = second/third/
  fourth-to-last, 4..9 = last ± 1..3, 10..15 = second-to-last ± 1..3 —
  over "the ring buffer of the four last distances", initialized "by the
  values 16, 15, 11, and 4 ... at the beginning of the *stream* (as opposed
  to the beginning of the meta-block), and it is not reset at meta-block
  boundaries" (`§4`). "When a distance symbol 0 appears, the distance it
  represents ... is not pushed to the ring buffer" — nor are dictionary
  distances (`§4`, restated in §10's algorithm: "if distance code is not
  zero, and distance is not a static dictionary reference, push distance to
  the ring buffer"). "If a special distance symbol resolves to a zero or
  negative value, the stream should be rejected as invalid" (`§4`) — the
  distance-RB corner zstd's T6 (offset 0) maps onto, with the same
  fail-closed answer.
- **16..15+NDIRECT**: "represent distances from 1 to NDIRECT. Neither the
  special distance symbols nor the NDIRECT direct distance symbols are
  followed by any extra bits."
- **≥ 16+NDIRECT**: `ndistbits = 1 + ((dcode - NDIRECT - 16) >>
  (NPOSTFIX + 1))` (max 24), and the reconstruction: `hcode = (dcode -
  NDIRECT - 16) >> NPOSTFIX; lcode = (dcode - NDIRECT - 16) & POSTFIX_MASK;
  offset = ((2 + (hcode & 1)) << ndistbits) - 4; distance = ((offset +
  dextra) << NPOSTFIX) + lcode + NDIRECT + 1` (`§4`) — the NPOSTFIX/NDIRECT
  pair reshapes the whole code space per meta-block, which is why the
  distance alphabet is dynamic.

### 1.6 Insert-and-copy lengths (`rfc7932-brotli.txt §5`)

One prefix code carries both lengths: `<insert-and-copy length code,
insert extra bits, copy extra bits>`. The 704-symbol alphabet factors
through a 24-symbol insert code table (0..5 → lengths 0..5, ... 23 →
"22594..16799809" with 24 extra bits) and a 24-symbol copy code table
(0..7 → lengths 2..9, ... 23 → "2118..16779333" with 24 extra bits)
(`§5`'s two tables). The 704 cells decompose as a 4×3 grid of 64-code
blocks (`§5`'s table): "The copy length code within its range is
determined by bits 0..2 (counted from the lsb) of the insert-and-copy
length code. The insert length code within its range is determined by bits
3..5" — the row/column bands are insert-code 0..7/8..15/16..23 ×
copy-code 0..7/8..15/16..23, and **"If the insert-and-copy length code is
between 0 and 127, the distance code of the command is set to zero (the
last distance reused)"** — the implicit-distance band; no distance is read
for those commands (§9.3, erratum 6977). The C carries the tables as
`kInsertLengthExtraBits`/`kCopyLengthExtraBits` (`prefix.c:23-34`, matching
`§5` cell for cell) and a precomputed command LUT (`prefix_inc.h`).

### 1.7 Block switches (`rfc7932-brotli.txt §6`, `§2`)

Three categories (L, I, D), each with a block type in 0..255 and a
remaining count; the switch reads a type code then a count code inline
(§1.3). Type codes: "a block type symbol 0 means that the new block type
is the same as the type of the previous block from the same block
category, i.e., the block type that preceded the current type, while a
block type symbol 1 means that the new block type equals the current block
type plus one. If the current block type is the maximal possible, then a
block type symbol of 1 results in wrapping to a new block type of 0. Block
type symbols 2..257 represent block types 0..255, respectively. The
previous and current block types are initialized to 1 and 0, respectively,
at the end of the meta-block header" (`§6`). Count codes: the 26-symbol
table (code 0 → "1..4" with 2 extra bits, ... code 25 → "16625..16793840"
with 24) (`§6`). "Since the end of the meta-block is detected by the number
of uncompressed bytes produced, the block counts for any of the three
categories need not count down to exactly zero at the end of the
meta-block" (`§6`). The ring-buffer initialization is the one place the
RFC contradicts itself — §6 says (previous, current) = (1, 0); §10's
pseudocode says "initialize second-to-last and last block types to 0 and
1" — the reverse. **Settled against the reference**: the C initializes
`block_type_rb` to {1, 0} per category (`state.c:120-125`,
`BrotliDecoderStateMetablockBegin`), matching §6; §10's line is the
misleading one (not in the errata register; §5 T1). It matters on the
wire: the first switch's symbol 0 selects the *previous* type — 1 under
the reference reading, 0 under §10's.

### 1.8 Context modeling (`rfc7932-brotli.txt §7`)

Literals: "The context for encoding the next literal is defined by the last
two bytes in the stream (p1, p2, where p1 is the most recent byte),
regardless of whether these bytes are produced by uncompressed meta-blocks,
backward references, static dictionary references, or by literal
insertions. At the start of the stream, p1 and p2 are initialized to zero"
(`§7.1`). Four context modes, two bits per literal block type in the
header: **LSB6** (`p1 & 0x3f`), **MSB6** (`p1 >> 2`), **UTF8**
(`Lut0[p1] | Lut1[p2]`), **Signed** (`(Lut2[p1] << 3) | Lut2[p2]`) —
"context IDs for literals are in the range of 0..63" (`§7.1`). The three
256-byte Luts are carried in the RFC with their own CRC-32 check values
(Lut0 0x8e91efb7, Lut1 0xd01a32f4, Lut2 0x0dd7a0d6) — all three verified
here by parsing the vendored tables and hashing them (`§4.3`); the C's
`context.c` `_kBrotliContextLookupTable` is the same 2,048 bytes. Distances:
"The context IDs are 0, 1, 2, and 3 for copy lengths 2, 3, 4, and more
than 4, respectively" (`§7.2`) — the distance context is known before the
distance is read, from the same command's copy length.

The context maps (`§7.3`): `CMAPL[0..(64 * NBLTYPESL - 1)]` and
`CMAPD[0..(4 * NBLTYPESD - 1)]`, each value 0..255, "indicating the index
of the prefix code" — `index of literal prefix code = CMAPL[64 * BTYPE_L +
CIDL]`, `index of distance prefix code = CMAPD[4 * BTYPE_D + CIDD]`.
Encoded per map: RLEMAX ("1..5 bits: RLEMAX, 0 is encoded with one 0 bit,
and values 1..16 are encoded with bit pattern xxxx1"), then a prefix code
over the NTREES + RLEMAX alphabet (symbol 0 = value zero; 1..RLEMAX =
zero-runs of 2..(1<<(RLEMAX+1))-1 with RLEMAX bits of run length; then the
values 1..NTREES-1), then the map run-length coded, then the **IMTF**
bit ("if set, we do an inverse move-to-front transform on the values in
the context map") — the RFC carries the transform's C code verbatim
(`§7.3`). Normative constraints: "NTREES must equal the number of different
values in the context map; in other words, the different values in the
context map must be the [0..NTREES-1] interval"; "If a run length would
result in more lengths in total than the size of the context map, then the
stream should be rejected as invalid"; "RLEMAX may be larger than the value
necessary to represent the longest sequence of zero values" (a decoder
must accept oversized RLEMAX); "the inverse move-to-front transform will
not produce values outside the [0..NTREES-1] interval".

### 1.9 The static dictionary (`rfc7932-brotli.txt §8`, Appendices A-B)

The load-bearing rule: "At any given point during decoding the compressed
data, a reference to a duplicated string in the uncompressed data produced
so far has a maximum backward distance value, which is the minimum of the
window size and the number of uncompressed bytes produced. However,
decoding a distance from the compressed stream, as described in Section 4,
can produce distances that are greater than this maximum allowed value. In
this case, the distance is treated as a reference to a word in the static
dictionary" (`§8`). The dictionary is *distance space*: there is no header
bit, no opt-in, no way to tell from the stream header whether dictionary
references occur. "The copy length for a static dictionary reference must
be between 4 and 24."

Structure (`§8`): `DICT[0..DICTSIZE]` (the bytes), `DOFFSET[0..24]`,
`NDBITS[0..24]`, with `NWORDS[length] = (1 << NDBITS[length])` for length
≥ 4 and the recursion `DOFFSET[length + 1] = DOFFSET[length] + length *
NWORDS[length]; DICTSIZE = DOFFSET[24] + 24 * NWORDS[24]`. The reference's
own values (`dictionary.c`): NDBITS = {0,0,0,0,10,10,11,11,10,10,10,10,
10,9,9,8,7,7,8,7,7,6,6,5,5}, DOFFSET[24] = 122,016, DICTSIZE = 122,784
(the recursion checks: 24 × 32 = 768, 122,016 + 768 = 122,784). Word
selection: `word_id = distance - (max allowed distance + 1); index =
word_id % NWORDS[length]; base_word = DICT[offset(length, index)..];
transform_id = word_id >> NDBITS[length]` — "If transform_id is greater
than 120, or the length is smaller than 4 or greater than 24, then the
compressed stream should be rejected as invalid" (`§8`).

The 121 transforms (`§8`, Appendix B): `transform_i(word) = prefix_i +
T_i(word) + suffix_i` over 21 elementary transforms — Identity,
FermentFirst, FermentAll, OmitFirst1..9, OmitLast1..9 (the RFC's Ferment C
code is the UTF-8 case-flip: ASCII `^32` for a-z; 2-byte sequences flip the
second byte's bit 5; 3-byte sequences `^5` the third). "Note that the
OmitFirst8 elementary transform is not used in the list of transformations"
(verified in the parsed table). "The maximum number of additional bytes
that a transform may add to a base word is 13. Since the largest base word
is 24 bytes long, a buffer of 38 bytes is sufficient to store any
transformed words (counting a terminating zero byte)" — **verified exactly
against the parsed Appendix B**: max prefix+suffix = 13 (transform 73,
`" the "` + `" of the "`), worst case 24 + 13 + 1 = 38 (`§4.3`). Appendix
A states its own CRC: "the length is 122,784 bytes and the CRC-32 of the
byte sequence is 0x5136cb04"; Appendix B: "The length of that sequence is
648 bytes, and the CRC-32 is 0x3d965f81" — both verified (§4.3), and the
122,784 bytes are byte-identical across the RFC, the C's `dictionary.bin`,
and the Go port's `dictionary.go`. The C's own representation of the
transforms is a deduplicated one (`transform.c`: a 217-byte prefix/suffix
pool + a 50-entry u16 offset map + 121 triplets of [prefix_id, type,
suffix_id] — 680 bytes total, the same 121 transforms; §4.4 records the
representation choice).

### 1.10 Security and the sizing bound (`rfc7932-brotli.txt §12`, `§11.1`)

"Decompressor implementations should handle all compressed data byte
sequences, not only those that conform to this specification, where
non-conformant compressed data sequences should be rejected as invalid";
they "should perform bounds-checking for each memory access that result
from values decoded from the compressed stream"; and resource consumption
is controlled by exactly two parameters — MLEN and the window — on which
"a sanity-check" is recommended, against "a hard limit ... or a certain
multiple of the size of the compressed data" (`§12`). The trivial
compressor (`§11.1`) proves every N-byte input has a valid stream of at
most `S(N) = N + (3 * (N >> 16) + 5)` bytes — the amplification bound for
hostile MLENs (a 3-byte stream can declare MLEN 2^24; the output bound is
the caller's target, and the *input* amplification is what S(N) bounds).
§11.1's C++ was ported here and verified byte-exact through both oracles
at 11 B and 100,000 B — the 100,000-byte input produced exactly 100,008
bytes, the bound exactly met (§7.3; the port needs one C++-ism noted:
`append(1, c)` truncates to uint8).

## 2. Requirements matrix — a conformant brotli decoder

RFC 7932's compliance bar (`§1.4`): "a compliant decompressor must be able
to accept and decompress any data set that conforms to all the
specifications presented here. A compliant compressor must produce data
sets that conform to all the specifications presented here." The rows
below are the decoder-side obligations for M6 (decoder-first; the encoder
is a later milestone's matrix). The RFC's modal verb at every rejection
site is "the stream should be rejected as invalid" — read as must, per
`§12`'s "non-conformant compressed data sequences should be rejected".

| # | requirement | cite |
|---|-------------|------|
| BR1 | Accept and decompress any conformant data set — the root duty; the dictionary it silently requires is OQ1's subject (§4.2) | `rfc7932-brotli.txt §1.4` |
| BR2 | Handle all byte sequences, not only conformant ones; reject non-conformant with an unambiguous error; bounds-check every memory access derived from decoded values; sanity-check MLEN and the window against a hard limit or a multiple of the compressed size | `§12` |
| BR3 | Multi-byte numbers little-endian; bits numbered lsb=0 | `§1.5` |
| BR4 | Bit packing: elements fill bytes lsb-first; integer values pack lsb-first; prefix codes pack msb-first | `§1.5.1` |
| BR5 | WBITS: the 1..7-bit code over 10..24; window = (1 << WBITS) - 16; pattern 0010001 invalid — reject | `§9.1` |
| BR6 | At least one meta-block per stream | `§9.2` |
| BR7 | ISLAST+ISLASTEMPTY ends the stream at that bit; the last byte's remaining bits must be zero — reject otherwise | `§9.2` |
| BR8 | MNIBBLES code {11→0, 00→4, 01→5, 10→6}; MLEN-1 in MNIBBLES×4 bits; MNIBBLES>4 with an all-zero last nibble — reject | `§9.2` |
| BR9 | Metadata blocks (MNIBBLES=0): reserved bit zero; MSKIPBYTES; MSKIPLEN-1; MSKIPBYTES>1 with an all-zero last byte — reject; zero fill to the boundary; MSKIPLEN bytes are skipped and are neither window nor uncompressed data nor literal context | `§9.2`, `§2` |
| BR10 | ISUNCOMPRESSED only when ISLAST=0; the skipped boundary bits must be zero — reject otherwise; MLEN raw bytes follow | `§9.2` |
| BR11 | NBLTYPESL/I/D: the 1..11-bit varlen over 1..256; each must equal the largest block type + 1 (the types are exactly [0..N-1]) | `§9.2`, `§6` |
| BR12 | Per category with NBLTYPES ≥ 2: block-type and block-count prefix codes plus the first block count, all in the header; with NBLTYPES = 1: no trees, BLEN = 16777216 | `§9.2`, `§10` |
| BR13 | NPOSTFIX 0..3; NDIRECT = (4-bit field) << NPOSTFIX, 0..120 | `§9.2`, `§4` |
| BR14 | Context modes: 2 bits per literal block type; the four modes and their CID formulas; CID 0..63 | `§9.2`, `§7.1` |
| BR15 | NTREESL/NTREESD varlen; the context map is read only when ≥ 2, else the map is all zeros | `§9.2` |
| BR16 | The three tree groups in order: NTREESL literal trees, NBLTYPESI insert-and-copy trees, NTREESD distance trees | `§9.2` |
| BR17 | Simple prefix codes: NSYM 1..4; ALPHABET_BITS per alphabet; symbol ≥ alphabet size or duplicate symbol — reject; the length patterns per NSYM; equal-length codes assigned in sorted symbol order regardless of presentation order; the tree-select bit for NSYM=4 | `§3.4` |
| BR18 | Complex prefix codes: HSKIP ∈ {0,2,3}; the code-length-code lengths 0..5 in the fixed symbol order 1,2,3,4,0,5,17,6,16,7..15; the fixed VL code for them; trailing zeros omitted; sum(32>>len) = 32 over non-zero lengths; the single-non-zero-symbol zero-length-code case | `§3.5` |
| BR19 | The code-length symbol sequence: ≤ alphabet size; 16 repeats the previous non-zero length (8 initially) 3..6 with 2 bits and the 4×(count-2)+n modifier; 17 repeats zero 3..10 with 3 bits and the 8×(count-2)+n modifier; 16/17 only modify the same code's count; trailing 0/17 omitted, last symbol 1..16; sum(32768>>len) = 32768; a repeat overrunning the alphabet — reject | `§3.5` |
| BR20 | Canonical code construction from lengths (the RFC's algorithm — flate's, already built) | `§3.2` |
| BR21 | Distance alphabet size 16 + NDIRECT + (48 << NPOSTFIX) | `§3.3`, `§4` |
| BR22 | The 16 special codes over the 4-distance ring buffer, initialized 16/15/11/4 at stream start, never reset per meta-block; symbol 0 does not push; dictionary distances do not push | `§4` |
| BR23 | A special code resolving to zero or negative — reject | `§4` |
| BR24 | Direct codes 16..15+NDIRECT = distances 1..NDIRECT, no extra bits | `§4` |
| BR25 | Extra-bit codes: ndistbits = 1 + ((dcode - NDIRECT - 16) >> (NPOSTFIX+1)), max 24 | `§4` |
| BR26 | The distance reconstruction formula (hcode/lcode/offset/distance) | `§4` |
| BR27 | The 704-symbol IaC alphabet: the insert and copy code tables (their extra bits and ranges); bits 0..2 select the copy code within its band, bits 3..5 the insert code | `§5`, `§3.3` |
| BR28 | IaC codes 0..127 imply distance code 0 — no distance element is read | `§5`, `§9.3` |
| BR29 | MLEN accounting: the last command may be literals-only; a copy whose insert already reached MLEN is ignored (any copy value legal); any insert/copy/dictionary-word length that would exceed MLEN — reject | `§2`, `§9.3` |
| BR30 | Block type codes: 0 = previous, 1 = current+1 with wrap to 0 at the max, 2..257 = types 0..255; the previous/current ring initialized (1, 0) at the end of the meta-block header (§10's "0 and 1" is the contradiction — follow §6/the reference, T1) | `§6` |
| BR31 | Block counts: the 26-symbol table with 2..24 extra bits; counts need not reach zero at meta-block end | `§6` |
| BR32 | Literal context: p1/p2 = the last two uncompressed bytes (any producer), initialized (0, 0) at stream start; the four mode formulas; metadata bytes are never context | `§7.1`, `§2` |
| BR33 | Distance context: copy length 2/3/4/>4 → CID 0/1/2/3 | `§7.2` |
| BR34 | Context maps: RLEMAX's 1..5-bit code (0 → one 0 bit; 1..16 → xxxx1); NTREES = max value + 1 = the distinct-value count ([0..NTREES-1] exactly); the NTREES+RLEMAX alphabet; zero-run symbols; a run overrunning the map — reject; oversized RLEMAX accepted | `§7.3` |
| BR35 | The IMTF bit and the inverse move-to-front transform (the RFC's C code) | `§7.3` |
| BR36 | Command order: the IaC switch before the length code, the literal switch before each literal, the distance switch before the distance — each only when that category's count is zero; the distance switch only when a distance is read (erratum 6977, T2) | `§9.3`, `§10` |
| BR37 | Execution: literals then copy; copies may overlap; references may cross meta-block boundaries; a distance beyond min(window, produced) is a dictionary reference, never a window read | `§10`, `§8` |
| BR38 | Dictionary references: length 4..24; word_id/index/transform_id arithmetic; transform_id > 120 or length outside 4..24 — reject | `§8` |
| BR39 | The 121 transforms and 21 elementary transforms (Ferment's UTF-8 case-flip semantics); the 38-byte worst-case transformed word | `§8`, Appendix B |
| BR40 | Stream end: a stream ending before the last meta-block completes — reject; the last non-empty meta-block's unused trailing bits must be zero | `§10`, `§9.3` |
| BR41 | The window history: retain at least window-size bytes of uncompressed data behind the current position (the streaming shape's one real memory duty) | `§2`, `§9.1` |

(The one deliberate absence: no checksum row — the format has none. zstd's
ZD2-style "may ignore" debate does not exist here; integrity is the
container's job, and there is no container.)

## 3. The error taxonomy

The RFC's rejection sites are all "the stream should be rejected as
invalid" sentences — BR2/§12 makes them duties, and the C gives each one a
named code (`c/include/brotli/decode.h:64-113`,
`BROTLI_DECODER_ERROR_CODES_LIST`), which the Go port mirrors verbatim
(`decode.go:26-56`). Our vocabulary (the zstd OQ5 rule: compose, never
wrap — the coarse `error.EndOfStream`/`error.ReadFailed` through the `Io`
interface, the specific detail beside it, one name per corruption class),
seeded from both references and mapped to the rows that raise them:

| our name | the C's code | raised by (BR rows) | proven on |
|---|---|---|---|
| `BadWindowBits` | FORMAT_WINDOW_BITS (-13) | BR5 (the 0010001 pattern; also the starved header) | the large-window lane, §7.5: Go prints `brotli: WINDOW_BITS`; the C CLI accepts it only because it force-enables the extension (T3) |
| `Truncated` | (needs-more-input at end) | BR40 and every starved read — the C CLI's "truncated input", Go's "unexpected EOF" | truncations at 1..48 bytes, all "truncated input", §7.5 |
| `ReservedBit` | FORMAT_RESERVED (-2) | BR9 (the metadata block's reserved bit) | (the C's code; no hand-built vector yet) |
| `ExuberantNibble` | FORMAT_EXUBERANT_NIBBLE (-1) | BR8 (MNIBBLES>4, zero last nibble) | (same) |
| `ExuberantMetaNibble` | FORMAT_EXUBERANT_META_NIBBLE (-3) | BR9 (MSKIPBYTES>1, zero last byte) | (same) |
| `BadPadding` | FORMAT_PADDING_1 (-14) / PADDING_2 (-15) | BR7, BR10 (nonzero fill bits; the C splits the two sites, ours is one class) | flip@0 → `FORMAT_PADDING_2`, x00 flip0 → `FORMAT_PADDING_1`, §7.5 |
| `SimpleHuffmanAlphabet` | FORMAT_SIMPLE_HUFFMAN_ALPHABET (-4) | BR17 (symbol ≥ alphabet size — reachable only on non-power-of-two alphabets, T7) | hand-built IaC symbol 704: C `FORMAT_SIMPLE_HUFFMAN_ALPHABET (-4)`, Go `brotli: SIMPLE_HUFFMAN_ALPHABET`, §7.3 |
| `SimpleHuffmanSame` | FORMAT_SIMPLE_HUFFMAN_SAME (-5) | BR17 (duplicate symbol) | hand-built (65,65): `FORMAT_SIMPLE_HUFFMAN_SAME (-5)`, §7.3 |
| `BadCodeLengthCode` | FORMAT_CL_SPACE (-6) | BR18 (the 32-Kraft and CL-code rules) | (the C's code) |
| `BadHuffmanCode` | FORMAT_HUFFMAN_SPACE (-7) | BR19 (the 32768-Kraft, the last-symbol rule, the repeat overrun) | (the C's code) |
| `ContextMapRepeat` | FORMAT_CONTEXT_MAP_REPEAT (-8) | BR34 (a zero-run overrunning the map) | (the C's code) |
| `BadBlockLength` | FORMAT_BLOCK_LENGTH_1 (-9) / _2 (-10) | BR12, BR31 (the block-count decode) | (the C's code) |
| `BadTransform` | FORMAT_TRANSFORM (-11) | BR38 (transform_id > 120; a length-0 transformed word) | (the C's code) |
| `BadDictionary` | FORMAT_DICTIONARY (-12) | BR38 (length outside 4..24; a word_id past the dictionary space; NDBITS=0 for that length) | (the C's code) |
| `BadDistance` | FORMAT_DISTANCE (-16) | BR23 (a special code resolving ≤ 0) | (the C's code; the zstd T6 fail-closed analogue) |
| `DictionaryRequired` | (ours; no C analogue — the C always has the dictionary) | OQ1's refusal mode, *not* shipped: the named error a dictionary-less build would raise. Recorded because the sizing question asked for it; the answer (§4.2) ships the dictionary instead | the instrumented refuse-mode: `FORMAT_DICTIONARY` on the first reference, §4.2 |
| `WindowTooLarge` | (ours, the zstd OQ1 name) | BR41/OQ4: a WBITS beyond the instantiated buffer's window | (our design; the C grows its ring buffer instead) |

Plus the non-corruption outcomes the `Io` layer needs: the clean end of
stream (ISLAST/ISLASTEMPTY), and — for the one-shot — the target-size cap.
Two notes for the naming pass: the C's PADDING_1/PADDING_2 and
BLOCK_LENGTH_1/2 splits are allocation-context artifacts (two check sites
for one class), not two classes; and the CLI's own rendering (the "reason:"
lines under `-v`, e.g. `reason: FORMAT_PADDING_2 (-15)`) is the oracle's
error-message surface the conformance lanes will assert against.

## 4. The static dictionary: sizing, use, and self-verification

The plan names this as the research's decision ("the static dictionary is a
sizing decision the M6 research owns", `docs/zcompress-plan.md`,
"Milestones"). Three questions: what it costs, whether a decoder can refuse
it, and how it is represented. All three answered with measurements.

### 4.1 What it costs

The data: **122,784 bytes** (Appendix A / `dictionary.bin` / the Go
`dictionary.go` — all three byte-identical, CRC 0x5136cb04). The indexing:
DOFFSET (25 u32) + NDBITS (25 u8) — trivial. The transforms: **648 bytes**
in the RFC's flat form, 680 in the C's deduplicated form (§4.4). Total
static data ≈ **120 KiB** — as a comptime `const` array it lands in
`.rodata`: no stack, no heap, no runtime allocation, no per-instance cost.
For scale: zstd's `Reader.Buffer` default is 8 MiB + 128 KiB of *caller*
memory; the dictionary is 1.5% of that, paid once in binary size.

### 4.2 Whether a decoder can refuse it

**No — not and stay conformant, and not and decode the reference encoder's
output family.** The evidence, all measured here with an instrumented build
of the pinned reference (a counter at the one decision point,
`decode.c:2152`, plus a refuse-mode that fails `FORMAT_DICTIONARY` on the
first dictionary reference):

- **The reference's own golden corpus needs it**: 7 of the 45 decodable
  vectors in `tests/testdata/` fail under refuse-mode — `alice29.txt
  .compressed`, `asyoulik.txt.compressed`, `cp852-utf8.compressed`,
  `lcet10.txt.compressed`, `monkey.compressed`, `plrabn12.txt.compressed`,
  `quickfox_repeated.compressed`. Two of those (`monkey`, 843 bytes;
  `cp852-utf8`, 706 bytes) are among the *smallest* text fixtures — this is
  not a big-corpus-only effect.
- **The CLI's default output needs it**: the CLI's default quality is 11
  (`-Z/--best ... (default)`, `BROTLI_DEFAULT_QUALITY 11`, `encode.h:61`),
  and default-quality text compression emits thousands of dictionary
  references — measured on the sweep (§7.5): alice29 1,837; asyoulik 2,050;
  lcet10 5,587; plrabn12 3,930; the vendored RFC 7932 text itself 1,166.
- **There is no encoder quality gate to lean on**: the static dictionary
  is searched in the fallback path of *every* hasher at *every* quality
  (`SearchInStaticDictionary`, `hash.h:171-198`, called from all six
  hasher `*_inc.h` files; the only throttle is the `dict_num_matches <
  (dict_num_lookups >> 7)` heuristic, which slows but does not disable).
  Measured per quality on alice29: q0-q3 → 0 references; q4 → 365; q5 →
  483; q9 → 462; q11 → 1,837. The fast tier (q0-q3, the class our own
  future encoder targets) happens to be dictionary-free on this corpus —
  but a *decoder* must decode q4+ output, which is the entire quality
  range above the fast tier and the CLI's default.
- **The zlib-FDICT precedent does not transfer**: FDICT is a header bit no
  encoder sets, so a dict-less zlib decoder loses nothing real. Brotli's
  dictionary is not signaled — it is distance space beyond
  min(window, produced) — so a dict-less decoder cannot even detect the
  need until mid-meta-block, and then only to fail.

**Answer: ship the 122,784 bytes.** The refusal posture is recorded
(`DictionaryRequired` in §3) for completeness; it fails the reference's
own conformance corpus on day one.

### 4.3 The spec as its own golden corpus

Appendix C defines CRC-32 (the standard reflected 0xEDB88320 construction
— the same function as gzip's, `std.hash.crc.Crc32`) and every static data
element in the RFC carries a check value. **Every one verified here**, by
parsing the vendored text and hashing (python `zlib.crc32`) and, for the
two big ones, through the Zig std kernel (`zig run` against the 0.16.0
store — the std-availability audit that pays):

| element | bytes | CRC-32 (RFC's claim) | verified |
|---|---|---|---|
| DICT (Appendix A hex → binary) | 122,784 | 0x5136cb04 (`Appendix A`) | python and `std.hash.crc.Crc32` both exact; byte-identical to `dictionary.bin` and the Go port |
| transforms (Appendix B rows → flat prefix/0/type/suffix/0 sequence) | 648 | 0x3d965f81 (`Appendix B`) | python and `std.hash.crc.Crc32` both exact; ids 0..120 in order; OmitFirst8 absent as the RFC notes |
| Lut0 / Lut1 / Lut2 (`§7.1`) | 256 each | 0x8e91efb7 / 0xd01a32f4 / 0x0dd7a0d6 | python, all three exact |

So the day-one tests write themselves: port the dictionary as a generated
`const` array, port the transforms and the three Luts, and pin all five by
CRC through `std.hash.crc.Crc32` — the fixtures need no vendored binary at
all, the RFC text *is* the fixture (the hex parse of Appendix A is 3,837
lines → 122,784 bytes, mechanical). The transformed-word bound verified
too: max prefix+suffix over all 121 transforms = 13 (transform 73, `" the "
` + `" of the "`), so 24 + 13 + 1 = **38 bytes** exactly as `§8` claims.

### 4.4 Representation

The dictionary itself is one flat `const` array — there is nothing to
choose. The transforms have two shapes: the RFC's flat 648-byte sequence
(prefix, NUL, type, suffix, NUL per transform), or the C's deduplicated
form — a 217-byte string pool with length-prefixed entries, a 50-entry u16
offset map, and 121 triplets of [prefix_id, transform_type, suffix_id]
(`transform.c:15-172`, 680 bytes total) with a `cutOffTransforms` shortcut
table (`{0, 12, 27, 23, 42, 63, 56, 48, 59, 64}` — the indices of the
`["", OMIT_LAST_k, ""]` transforms, used to fast-path the identity-ish
cases at `decode.c:2237`). **Recommendation (OQ6)**: port the C's dedup
form — it is the reference's own shape, 32 bytes smaller, and the
lookup-by-id it enables is what the decode loop wants; the CRC test pins
it against the RFC's flat form, so both representations stay honest
against each other. The dictionary port generates from Appendix A's hex at
port time (a build-time or commit-time codegen step, committed once, never
re-run silently).

## 5. Spec-vs-reference divergences (decisions for the parent)

The RFC text, the C reference, the Go port, and the CLI — all recorded;
none silently picked. `brotli-c` cites the v1.2.0 checkout; `brotli-go`
cites v1.2.6; the CLI is the build from the tag.

- **T1 — §6 and §10 contradict each other on the block-type ring-buffer
  init.** §6: "The previous and current block types are initialized to 1
  and 0, respectively, at the end of the meta-block header." §10's
  pseudocode: "initialize second-to-last and last block types to 0 and 1"
  — the reverse assignment. Not in the errata register. **Settled against
  the reference**: `BrotliDecoderStateMetablockBegin` sets `block_type_rb`
  to {1, 0} per category (`state.c:120-125`), and `DecodeBlockType`
  resolves symbol 0 → `ringbuffer[0]` (previous) and symbol 1 →
  `ringbuffer[1] + 1` (`decode.c:1208-1218`) — §6's reading. The two
  readings differ on real wire bytes (the first switch's symbol-0 selects
  type 1 under §6, type 0 under §10). Decision: **follow §6/the
  reference**; BR30 records it; the fuzz lane should pin a first-switch
  symbol-0 vector.
- **T2 — erratum 6977 (Reported): §9.3's distance block-switch conditions
  are wrong.** The vendored §9.3 reads the distance type/count switch
  whenever the distance count is zero; §10's algorithm reads it only
  inside the not-implicit-0 branch ("if distance code is implicit zero
  from insert-and-copy code / set backward distance to the last distance /
  else ... read block type ... read distance code"), and both references
  implement §10 (the C's `DecodeBlockType` for the distance category is
  called only on the read-a-distance path). The erratum's correction adds
  "and the distance code is not an implicit 0, as indicated by the
  insert-and-copy length code" to both §9.3 fields. Decision: implement
  §10/6977 (BR36); the vendored §9.3 text is annotated in the module
  README, never copied into a test.
- **T3 — the CLI's large-window leniency vs the library and the RFC.** The
  RFC: pattern 0010001 "is invalid and must not be used" (`§9.1`). The C
  library default: `DecodeWindowBits` fails FORMAT_WINDOW_BITS on it
  (`decode.c:162-170`). The Go port: same ("brotli: WINDOW_BITS", verified
  on a hand-made `--large_window=30` stream). The **CLI**: `InitDecoder`
  unconditionally sets `BROTLI_DECODER_PARAM_LARGE_WINDOW` — its own
  comment: "This allows decoding 'large-window' streams. Though it creates
  fragmentation (new builds decode streams that old builds don't), it is
  better from used experience perspective." (`brotli.c:1205-1209`) — so
  the pinned CLI *decodes* large-window streams byte-exact without any
  flag (verified). Decision: RFC-7932 scope — reject 0010001 with
  `BadWindowBits`; the CLI's tolerance is a convenience divergence,
  recorded, never a model. The extension itself (WBITS up to 2^30 via 1+6
  more bits) is out of scope; no `--large_window` surface.
- **T4 — trailing bytes and concatenated streams: both references fail
  closed, unlike the gzip CLI family.** Appending `GARBAGEGARBAGE` to a
  good stream: the CLI fails "corrupt input" (exit 1, after emitting the
  first stream's 44 bytes); Go fails "brotli: excessive input". Two
  concatenated good streams: the CLI fails the same way *by default* —
  `-K/--concatenated` ("allows concatenated brotli streams as input") is
  the opt-in, and with it both streams decode (88 bytes, exit 0); Go's
  `NewReader` is single-stream and fails "excessive input" on the second.
  The zero-byte input: "corrupt input" (CLI) / "unexpected EOF" (Go) — an
  empty *file* is not a valid stream (there is no WBITS); the empty
  *stream* is the 1-byte `06`. Decision (OQ3): one stream per `Reader`
  with the exact boundary visible; `streamAll` walks streams at that
  boundary and fails `BadStreamStart`/`Truncated` on garbage in the next
  stream's place; the empty input is `Truncated`, never a clean zero-byte
  decode. The M3 trailing-garbage-warning posture (gzip CLI) has no
  brotli analogue to accommodate.
- **T5 — the metadata-block ISLAST corner.** §9.2's ISLASTEMPTY is present
  only when ISLAST=1, and §10's `while not ISLAST` loop exit means an
  ISLAST=1 *metadata* meta-block (ISLASTEMPTY=0, MNIBBLES=0) ends the
  stream too — after skipping its metadata. The golden corpus pins it:
  `empty.compressed.15` is the single byte `1a` (WBITS=16, ISLAST=1,
  ISLASTEMPTY=0, MNIBBLES=0, reserved=0, MSKIPBYTES=0, zero fill) and
  decodes to empty through both oracles; `.16` (`81 16 00 58`) is the
  same corner with one metadata byte. §2's "an empty meta-block may
  contain metadata information" and the pseudocode agree once read
  together; a literal §9.2-only reading might expect ISLASTEMPTY to be
  the only last-empty terminator. Decision: implement §10's loop (a
  metadata block with ISLAST=1 is last); both fixtures go in the golden
  corpus.
- **T6 — no integrity check exists, so corruption is often silent.**
  Flipping byte 5 or byte 10 of a 49-byte q11 stream decodes without
  error to *different* output (verified: 44 bytes, byte 2 / byte 7
  differ). The format has no checksum; only structural corruption is
  detectable. Consequences: the corruption lanes assert on *error or
  difference*, never on error alone; and any future container over brotli
  (none planned) owns integrity. Recorded so the conformance-planner lane
  does not import the zstd/gzip trailer-check posture by habit.
- **T7 — ALPHABET_BITS is a width, and the ≥-alphabet rejection is
  unreachable on power-of-two alphabets.** §3.4: "it is the smallest
  number of bits that can represent all symbols in the alphabet. For
  example, for the alphabet of literal bytes, ALPHABET_BITS is 8." The C
  computes it as `Log2Floor(alphabet_size_max - 1)` — where the decoder's
  `Log2Floor` is a *bit-width* function (`decode.c:521-527`,
  `while (x) { x >>= 1; ++result; }`: Log2Floor(255) = 8), not a
  floor-log. **Proven on the wire**: a hand-built literal tree with
  symbols {65, 200} packed 8-bit decodes to 'A' on both oracles; the same
  construction packed 7-bit (the floor-log reading) is corrupt on both.
  The consequence: a simple code's symbol field for a 256-symbol alphabet
  can never express ≥ 256, so §3.4's "greater than or equal to the
  alphabet size ... rejected" is vacuous there — it bites only on
  non-power-of-two alphabets (704, or 16+NDIRECT+(48<<NPOSTFIX) whenever
  NDIRECT/NPOSTFIX make it inexact): proven by the hand-built IaC symbol
  704 failing `SIMPLE_HUFFMAN_ALPHABET` on both oracles while the literal
  symbol "256" silently reads as 0. Decision: implement the width rule
  and keep the ≥-check (it is cheap and correct on the alphabets where it
  is reachable); the notes' hand-built pair is the fixture.
- **T8 — the transformed-word buffer: 38 bytes (RFC) vs 542 (C).** §8:
  "a buffer of 38 bytes is sufficient to store any transformed words
  (counting a terminating zero byte)" — verified exactly (§4.3: max
  prefix+suffix 13, worst 24+13+1 = 38). The C sizes its ring-buffer
  write-ahead slack at 542 — "255 prefix + 32 base + 255 suffix"
  (`decode.c:44-45`) — because the *extension* surfaces (shared
  dictionaries with arbitrary transforms) need the bigger bound, and 32
  accommodates the maxDictionaryWordLength of the extension. Decision:
  RFC scope — 38 bytes is honest and stack-sized; if the transformed-word
  path ever shares a buffer with extension code, re-measure. (OmitFirst9
  on a 4-byte word can also produce an empty word — `§8`'s "or empty
  string if length(word) < k" — and `decode.c:2247-2250` rejects a
  length-0 *transformed* word when the distance code ≤ 120: a transform
  that erases the word is invalid unless the distance puts it past the
  special-code band. That corner is the C's reading of §8's rejection
  sentence; adopt it as `BadTransform`.)
- **T9 — the spent single-type block count.** §9.3 gives a single-type
  category BLEN = 16777216 with no switch on the wire, and §10's
  pseudocode decrements the count with no branch for zero. It is
  reachable: a command whose copy is an emptied dictionary word (T8)
  produces no output, so a conformant meta-block can hold more than 2^24
  commands. Decision: re-arm the count, read nothing. google/brotli
  v1.2.0 returns a failure there; its safe callers read that as "needs
  more input" and the literal caller ignored it, which is the bug class
  CVE-2026-111497 closed. v1.2.1 rejects the stream as
  `FORMAT_BLOCK_SWITCH`; ours decodes it, and should.

## 6. The buffer and window design

The window arithmetic first (`§9.1`): window = (1 << WBITS) - 16, WBITS
10..24 — 1,008 bytes to 16,777,200. The decoder's history duty is BR41
("The decompressor must retain at least that amount of uncompressed data
prior to the current position", `§2`). What the references emit: the
encoder default is lgwin 22 (`BROTLI_DEFAULT_WINDOW 22`, `encode.h:63` —
a 4,194,288-byte window) with q0/q1 forced to ≥ 18 (`encode.c:653-656`);
measured auto-lgwin on the sweep corpus: 10 for tiny inputs, 17-19 through
400 KB, `-w 10..24` all honored exactly (§7.5). A 22-bit instantiation
decodes the whole CLI family unconfigured; 23/24 need a bigger one.

- **The one-shot decode needs no window buffer at all** — the zstd OQ1
  answer maps over exactly: the decoded output *is* the history. A match
  at distance d reads `target[n - d ..][0..copy_len]`; d > min(window, n)
  is a dictionary reference (never a read before the target's start);
  the caller's `target` cap is the MLEN bound. `brotli.decode.
  decompress(source, target) !usize` with `target` a cap, like zstd's.
- **The streaming decode needs one ring buffer** of window size — the
  zstd `Reader.Buffer(window_len)` precedent, comptime-parameterized with
  an exported default constant at 22 (`brotli.Reader.Buffer` = the 22-bit
  window + the per-metablock tree region + the literals scratch, below),
  a named `WindowTooLarge` for a stream whose WBITS exceeds the
  instantiation. A ring buffer (pos & mask) rather than a sliding buffer —
  the window is a power of two minus 16, so mask to 2^WBITS and keep the
  -16 in the bound arithmetic, exactly the C's ringbuffer/ringbuffer_mask
  shape. The RFC's §12 progressive-growth recommendation (start small,
  grow per meta-block) is a *should* for constrained systems; a fixed
  comptime buffer is the house pattern and simpler — record the deviation
  as deliberate (the buffer is caller-owned; growing it would mean
  reallocation nobody asked for).
- **The per-metablock tree storage is the real memory question — the one
  this research leaves open for the parent (OQ8).** The counts are
  frame-bounded but large: up to NTREESL=256 literal trees + NBLTYPESI=256
  IaC trees + NTREESD=256 distance trees per meta-block, each a
  two-level table the C sizes at `alphabet_size_limit + 376` entries × 4
  bytes (`state.c:170-171`) — 2,528 B per literal tree, 4,320 per IaC
  tree, up to 3,584 per distance tree, so the worst case is ≈ **2.7 MB of
  tables** against a 16-MiB-class window. The C heap-allocates per meta-
  block; klauspost-style zero-alloc wants this in the caller-owned
  buffer. Options: (a) the `Reader.Buffer` carries a tree region sized
  for a comptime-capped tree count (say 64 trees/category — every real
  stream the sweep produced uses ≤ 2 handfuls; a stream declaring more
  fails a named `TooManyTrees`), which keeps the whole path allocation-
  free at a ~675 KB region; (b) the full 256-cap region rides the buffer
  (+2.7 MB, honest to the format, memory-hungry for small windows);
  (c) an allocator-taking `Reader` init for the tree region alone — the
  AGENTS.md legitimacy clause ("an API taking an allocator where a buffer
  genuinely cannot be caller-stack-owned is a legitimate design"; the
  zstd pump-shape question's sibling). *Recommendation*: (a) — the same
  fail-closed-with-a-named-error posture as the window cap, with the cap
  raised if a real corpus ever trips it; but this is the parent's call,
  and it gates the README sketch the way zstd's OQ1 did.
- **The scratch that stays comptime stack**: the meta-block header arena
  (the C's `BrotliMetablockHeaderArena`: a 646-entry context-map table,
  symbol lists, code-length arrays — a few KiB), the distance-code tables
  (`dist_extra_bits[544]` + `dist_offset[544]`, `state.h:246-247` — filled
  per meta-block from NPOSTFIX/NDIRECT), the literals staging ([2^24]
  worst case is not stackable — the C stages literals into the ring
  buffer directly; ours: literals decode straight into the output/window
  when insert lengths allow, with the 128-KiB-class block scratch the
  zstd S2 shape used — a recommendation for the slice contract, not a
  research fact), and the 38-byte transformed-word buffer (§4.3).
- **The dictionary rides `.rodata`** (§4.1) — comptime const, zero
  runtime cost, both the one-shot and the streaming path read it
  directly.

## 7. Fixture inventory

### 7.1 google/brotli `tests/testdata/` (MIT, tag v1.2.0)

69 files; the decodable vectors are the golden corpus: **22 round-trip
pairs** (`X` + `X.compressed`): 10x10y, 64x, alice29.txt, asyoulik.txt,
backward65536, compressed_file, compressed_repeated, cp1251-utf16le,
cp852-utf8, lcet10.txt, mapsdatazrh, monkey, plrabn12.txt, quickfox,
quickfox_repeated, random_org_10k.bin, ukkonooa, x, xyzzy, zeros,
zerosukkanooa — **all 22 decoded byte-exact here through both oracles**;
**19 empty-input variants** (`empty.compressed` + `.00`-`.18`) and **4
single-byte variants** (`x.compressed` + `.00`-`.03`) — all 23 decoded
byte-exact here; total **45/45**. The non-pair files (`bb.binast` 11.8 MB,
`random_chunks`) are round-trip-lane inputs, not decode goldens. The
harness that consumes them: `run-compatibility-test.cmake` (decode +
SHA512 compare, the pattern our conformance lane ports) and
`run-roundtrip-test.cmake`; `cli_test.sh` is the Google-internal script
shape; `c/fuzz/decode_fuzzer.c` is the oss-fuzz harness (corpora live in
google/oss-fuzz, not this repo). The empty family is a wire-format
specification in itself — hand-decoded here, every byte accounted
(`§7.2`).

### 7.2 The empty family, decoded by hand (the minimal-stream set)

All verified by bit-level hand-decode here (§1.5.1's rules) and by both
oracles:

| bytes | reading |
|---|---|
| `06` | WBITS=16 (bit 0), ISLAST=1, ISLASTEMPTY=1, zero fill — the canonical empty stream (`empty.compressed`, `.00`, `.08`-`.14` are one-byte variants) |
| `81 01`, `a1`-`f1 01` | WBITS=17 (`0000001`) and 10..15 (`0100001`..`1110001` 7-bit patterns) + ISLAST + ISLASTEMPTY in the next byte |
| `33` `35` `37` `39` `3b` `3d` `3f` | WBITS=18..24 (4-bit patterns) + ISLAST + ISLASTEMPTY + zero fill, one byte |
| `1a` | WBITS=16, ISLAST=1, ISLASTEMPTY=0, MNIBBLES=0 → a *last* empty metadata block (T5's corner) |
| `81 16 00 58` | WBITS=17, ISLAST=1, metadata block with MSKIPBYTES=1, MSKIPLEN=1, one metadata byte `0x58` |
| `.17` (65,538 B) | WBITS=17, ISLAST=0; then 65,536 empty metadata blocks (the first completes byte 1 as `03`, the rest are one-byte `06`s) + the `03` last-empty terminator |
| `.18` (196,610 B) | WBITS=17, ISLAST=0; then 65,536 one-byte metadata blocks (the first as `0b 00 58`, the rest `16 00 58`, each carrying `X`) + the `03` last-empty terminator |

### 7.3 The hand-built fixtures from this research (golden candidates)

Every one built by a from-scratch bit writer over §1.5.1's rules and
decoded by both oracles before being recorded:

- **`hand.br` (9 B, `02 00 00 00 44 50 20 10 00`) → `A`**: the full ladder
  — WBITS=16, a last MLEN=1 compressed meta-block, all three NBLTYPES=1,
  NPOSTFIX=0/NDIRECT=0, LSB6, NTREESL=NTREESD=1, three simple NSYM=1
  codes (literal 65 in 8 bits, IaC 8 in 10 bits, distance 0 in 6 bits —
  the ALPHABET_BITS widths proven), one command, implicit distance, MLEN-
  exact termination. The day-one fixture: every header field and both
  zero-length-code cases in nine bytes.
- **`h2.br` → `A`**: NSYM=2 literal code presented *unordered* (66, 65),
  one literal bit 0 — pins the sorted-order code assignment (§3.4).
- **`h200w8.br` → `A` vs `h200w7.br` corrupt**: literal symbols {65, 200}
  packed 8-bit vs 7-bit — the ALPHABET_BITS proof (T7).
- **`hdup.br`** (65, 65) → `FORMAT_SIMPLE_HUFFMAN_SAME (-5)`;
  **`hiac.br`** (IaC symbol 704) → `FORMAT_SIMPLE_HUFFMAN_ALPHABET (-4)` /
  Go `brotli: SIMPLE_HUFFMAN_ALPHABET` — the two §3.4 rejections; plus
  `hal.br` (literal "256" → reads 0, decodes!) — the unreachability pin.
- **The trivial-compressor streams**: `06` (empty), 16 B for "hello world",
  100,008 B for 100,000 bytes — the §11.1 port, byte-exact on both
  oracles, the S(N) bound met exactly.
- **The corruption battery**: byte flips at 0/1/2/48 → `FORMAT_PADDING_2`
  / "truncated input"; flips at 5/10 → silent different output (T6);
  truncations at every length → "truncated input".
- **`lw.br`**: a `--large_window=30` stream — refused by Go
  (`brotli: WINDOW_BITS`), accepted by the CLI (T3); our decoder's
  `BadWindowBits` fixture.
- **`cmt.br`**: a `-C` comment stream (metadata block) — round-trips with
  the comment checked, fails with the wrong comment expected.

### 7.4 andybalholm/brotli `testdata/` (MIT, v1.2.6)

Two files (`Isaac.Newton-Opticks.txt` 554 KB, `issue22.gz` 1.2 MB —
round-trip inputs, not decode goldens); `corpus-test/` holds the fuzz-
corpus generator; `brotli_test.go` (32 KB) carries inline hex vectors for
both directions — a secondary fixture source worth mining at the
conformance lane, not vendored here. Zig std: nothing (§0). dsnet/
compress: the frozen alternative, noted, not used.

### 7.5 The verified oracle incantations (every command run here, outputs recorded)

The zstd-notes lesson applied: nothing below is reported that was not
executed against the pinned references in this research. `$B` is the
built-from-tag CLI (`/tmp/brotli-notes-verify/build/brotli`, reports
`brotli 1.2.0`); the Go oracle is the scratch module at
`/tmp/brotli-notes-verify/gooracle` (andybalholm v1.2.6, `NewReader` +
byte-compare). These are the commands the M6 conformance lane inherits;
the flake's `brotli` package provides the same CLI version (§0).

- **Version**: `$B --version` → `brotli 1.2.0`; `nix eval
  nixpkgs#brotli.version` → `"1.2.0"` (src `refs/tags/v1.2.0`).
- **Round-trip**: `printf 'the quick brown fox jumps over the lazy dog\n'
  > t.txt; $B -q 11 -c t.txt > t.br` (49 B) → `$B -d -c t.br | cmp - t.txt`
  → identical. Go: `brotlioracle t.br t.txt` → `MATCH`.
- **The golden corpus** (45 vectors, both oracles): `for f in
  brotli-c/tests/testdata/*.compressed*; do $B -d -c --force $f | cmp -
  ${f%.compressed*}; done` → 45/45 byte-exact; the Go oracle over the same
  set → 45/45 `MATCH`.
- **Cross-oracle on CLI output**: 24 files (alice29/mapsdatazrh/zeros/
  rfc7932 × qualities 0/1/2/5/9/11) — the C decode and the Go decode agree
  with the original on every pair; the trivial-compressor streams (11 B,
  100,000 B inputs) decode `MATCH` through both.
- **The corruption battery** (error messages): `$B -d -v -c <corrupt>`
  → flip@0 `reason: FORMAT_PADDING_2 (-15)`; flips@1/2 and every
  truncation `reason: truncated input`; flips@5/@10 decode to *different*
  output (no checksum — T6); hand-built duplicate symbol
  `FORMAT_SIMPLE_HUFFMAN_SAME (-5)`; hand-built IaC symbol 704
  `FORMAT_SIMPLE_HUFFMAN_ALPHABET (-4)` (Go: `brotli:
  SIMPLE_HUFFMAN_ALPHABET`); the large-window stream → Go `brotli:
  WINDOW_BITS`, the C CLI accepts (T3, its forced leniency).
- **Trailing garbage / concatenation / empty input** (T4): `cat t.br
  garbage > g.br; $B -d -c g.br` → exit 1 "corrupt input" (44 B emitted
  first); Go → `brotli: excessive input`. `cat t.br t.br | $B -d -c` →
  exit 1 without `-K`, 88 B clean with `-K`. `: > zero.br; $B -d -c
  zero.br` → "corrupt input" (Go: "unexpected EOF").
- **The metadata lane**: `$B -q 11 -C <b64> -c t.txt` → decodes with the
  comment checked (`-C` on decode verifies; the wrong comment → "corrupt
  input", exit 1).
- **The window lane**: `$B -q 11 -w {10,16,22,24} -c alice29.txt` →
  round-trips exact; the sniffed WBITS (a 20-line python bit-reader over
  §9.1's code) matches the flag every time; `-w 9` → "lgwin parameter (9)
  smaller than the minimum (10)"; `-w 25` → "error parsing lgwin value
  [25]". Auto-lgwin measured: 10 (tiny), 17-19 (the sweep corpus), the
  library default 22.
- **The dictionary measurements** (§4.2): the instrumented build
  (`BROTLI_NOTES_NODICT=1 $BI -d -c <file>` refuses; without the env var
  it prints `BROTLI_NOTES_DICTREFS <n>` per stream) over the quality sweep
  and the golden corpus — the numbers in §4.2's bullets are its output.
- **The std check** (the Zig side of the oracle set): `zig run crc.zig`
  against the 0.16.0 store — `std.hash.crc.Crc32.hash` over
  `dictionary.bin` → `0x5136cb04`, over the 648-byte transform sequence →
  `0x3d965f81` (both exact; §4.3).

## 8. Competitor inventory

The plan's default set ("klauspost/compress (Go) and std.compress (Zig)
always, plus the strongest native library on the box", `docs/
zcompress-plan.md`, "Benchmark methodology") **has two empty seats for
brotli**: klauspost ships none (§0's premise correction) and std ships
none (verified). The arms that exist:

- **google/brotli C v1.2.0 — the native ceiling, and the oracle.** The
  API: `BrotliDecoderCreateInstance` / `BrotliDecoderDecompressStream`
  (the streaming state machine: `BrotliDecoderResult` ∈ {ERROR, SUCCESS,
  NEEDS_MORE_INPUT, NEEDS_MORE_OUTPUT}, input/output pointers advanced in
  place, `BrotliDecoderSetParameter` for LARGE_WINDOW and ring-buffer
  reallocation, `BrotliDecoderGetErrorCode` for the detail) plus the
  one-shot `BrotliDecoderDecompress` (`decode.h`). The decoder is one
  105-KB `decode.c` with the huffman/bit-reader helpers — no assembly on
  the decode side (the encoder has some). Numbers mean: the native band
  the M6 fleet run targets. The `tests/` harness and testdata (§7.1) are
  the conformance corpus. License MIT — readable, portable, fixtures
  unrestricted.
- **andybalholm/brotli v1.2.6 — the Go class target.** `NewReader(io
  .Reader) *Reader` (streaming decode; no DecodeAll — the one-shot is
  io.ReadAll over it), `NewWriter`/`NewWriterLevel`/`NewWriterOptions`
  (encode), the HTTP helpers. A direct port of the C decoder (error names
  identical, dictionary byte-identical — both verified here); single-
  stream, fails "excessive input" on trailing bytes. Its `go.mod` pulls
  one tiny test-only dep (`xyproto/randomstring v1.0.5`) — the oracle
  module here builds offline after one fetch. Numbers mean: the speed
  class the plan's "performance class is klauspost" line maps onto for
  brotli — the Go arm the M6 fleet run races, and the klauspost seat's
  stand-in.
- **std.compress — absent.** No in-tree arm, no in-tree fixtures, no
  stealables. The fleet run's third arm is *ours* by default; the
  competitor-set note for the parent: M6's arms are brotli C, andybalholm,
  zcompress (the M4 precedent of recording a competitor-set gap in the
  run's results file applies — `docs/results/m4-fleet-20261011.md` closed
  the M3 gap the same way).
- **The CLI**: absent on the box; nixpkgs `brotli` 1.2.0 (out/dev/lib;
  the same tag as the C pin) is the flake add (§0). Python: no oracle
  (§0). libbrotli itself is a system dep candidates never need — the
  harness builds the C arm from the pinned tarball with zig cc (the
  flake comment's standing pattern, `flake.nix:57-60`).

## 9. The design questions (decisions for the README sketch)

Each labeled with its answer and reasoning; each feeds the M6 README
sketch (`src/brotli/README.md`, written before any implementation). The
OQ numbering mirrors zstd-notes' register (OQ1 is the memory
question in both) so the two files read together.

- **OQ1 — the static dictionary: ship it.** Answered with measurements
  (§4.2): 122,784 bytes of `.rodata` + the transform tables (~1.2 KB); 7
  of 45 reference goldens are undecodable without it; the CLI's default
  quality emits thousands of references on text; there is no encoder
  quality gate and no header bit — the dictionary is distance space. The
  zlib-FDICT refusal precedent is recorded and rejected: FDICT is an
  opt-in no encoder sets; brotli's dictionary is in every encoder's match
  space. The CRC self-tests (§4.3) pin the port day one.
  → *README*: the data section (what ships, its size, the CRC tests).
- **OQ2 — the M6 surface shape.** Decoder-first, the zstd M4 precedent:
  the namespace ships `brotli.Reader` + `brotli.decode` (one-shot) with
  the layers reachable inside it (`brotli.decode.prefix`, `.distance`,
  `.context`, `.dictionary`, the meta-block/frame machinery — the flate
  precedent of reachable internals), and the README states the encoder
  seat explicitly (never silently absent; the barrel rule's `{Reader,
  Writer, encode, decode}` completes when the encoder milestone lands).
  One-shot `decompress(source, target) !usize`, target-as-cap, MLEN
  checked against the produced total (the C verifies; a mismatched MLEN
  is either truncation or overrun, both named).
  → *README*: the namespace map, the M6 boundary.
- **OQ3 — the stream boundary and cardinality.** One stream per
  `Reader`, the exact boundary visible; `streamAll` walks streams at
  that boundary; trailing garbage and a second stream both fail
  (`BadStreamStart` on a next-stream WBITS that is not a valid start;
  both references fail closed here — T4 — so no gzip-style warn mode
  exists to accommodate); the zero-byte input is `Truncated`; the empty
  stream is the clean end (the `06` family decodes to zero bytes). The
  metadata blocks skip without touching window, output, or context
  (BR9); the comment lane (`-C`) is the conformance test for them.
  → *README*: the Reader contract, the walk.
- **OQ4 — the window buffer and cap.** Comptime-parameterized
  `brotli.Reader.Buffer(window_wbits)` (the zstd OQ1(b) pattern), an
  exported default at WBITS 22 (the encoder default — decodes the whole
  CLI family unconfigured, measured), `WindowTooLarge` for a stream
  beyond the instantiation. WBITS 10..24 are all structurally valid
  (BR5); the cap is our instantiation vs the stream, never a spec
  range check. The one-shot needs no window buffer (§6).
  → *README*: the Buffer type, the cap semantics.
- **OQ5 — the error taxonomy.** §3's table, composed (the coarse `Io`
  errors through the interface, the named detail beside): the
  C-code-seeded vocabulary with our `WindowTooLarge`, `BadStreamStart`,
  `Truncated`. One name per corruption class; the C's PADDING_1/2 and
  BLOCK_LENGTH_1/2 splits collapse to one class each; `DictionaryRequired`
  exists only in the notes (the refusal mode we did not ship).
  → *README*: the error set.
- **OQ6 — the transform table and the dictionary port.** The C's
  deduplicated form (680 B, the reference's own shape) for the
  transforms; the dictionary as a generated flat `const` from Appendix
  A's hex, committed once; both pinned by the RFC's own CRCs through
  `std.hash.crc.Crc32` (§4.3) — the vendored RFC is the fixture source,
  no binary vendoring needed. The codegen is a port-time step (a script
  under `scripts/`, the flate-oracle pattern), never a build-time
  network fetch.
  → *README*: the data provenance row (RFC Appendix A/B, the CRCs).
- **OQ7 — the large-window extension.** Out of scope, refused with
  `BadWindowBits` at the 0010001 pattern (BR5); the CLI's leniency is
  T3's recorded divergence; no `--large_window` surface anywhere. The
  custom/compound dictionary surfaces (`-D`, shared dictionaries) are
  likewise out of RFC scope — a `-D`-encoded stream is not an RFC 7932
  stream, and the decoder errors on its distances naturally (they fall
  past the dictionary space) — no dedicated refusal surface needed.
  → *README*: the scope statement.
- **OQ8 — the per-metablock tree storage.** The one open memory-design
  question (§6): up to ~2.7 MB of Huffman tables per meta-block at the
  format's worst case, against the house zero-alloc posture.
  Recommendation: the caller-owned `Buffer` carries a tree region sized
  for a comptime-capped tree count per category (64 recommended — every
  measured stream uses single digits; the cap fails a named
  `TooManyTrees`), the cap documented and raisable. The alternative (an
  allocator-taking `Reader` init for the tree region alone) is the
  AGENTS.md legitimacy clause — legitimate, but the cap keeps the whole
  path allocation-free and honest about a bound no real corpus
  approaches. **This is the parent's call before the README sketch** —
  it sizes the exported Buffer type.
  → *README*: the Buffer composition, the cap and its error.

## 10. Ranked ambiguities — the ones most likely to bite

1. **OQ8 — the tree storage.** The only open design decision: the
   exported Buffer's composition depends on it, the worst case is
   MiB-scale against a KiB-scale stack discipline, and the honest options
   (cap-and-name vs allocator) change the public API shape. Decide before
   the sketch; every streaming test sizes a buffer against it.
2. **T1 — the block-type ring-buffer init.** The RFC contradicts itself
   and the errata register does not know; the wrong reading misparses
   real first-switch bytes. The reference settles it (§6's {1, 0}), and a
   fuzz-lane vector should pin it.
3. **T2/erratum 6977 — the implicit-0 distance and the block switch.** A
   literal reading of the vendored §9.3 reads a block-switch that is not
   there; §10 and both references exclude it. The golden corpus's
   dictionary-bearing streams will exercise the corner constantly (every
   implicit-0 distance is one).
4. **OQ1 — the dictionary (answered, but the plan's named decision).**
   Ship it: the measured case is total (7/45 goldens, the default encoder
   quality, no gate). The residual risk is not the decision but the port:
   the transforms' Ferment semantics (the UTF-8 case-flip) and the
   word_id arithmetic are where a dictionary bug hides; the CRC tests
   pin the data, and the golden corpus's seven dictionary-bearing
   vectors pin the execution.
5. **T7 — ALPHABET_BITS and the unreachable rejection.** A width, not a
   floor-log; the hand-built pair proves it. An implementer who reads
   "Log2Floor" in the C and trusts the name writes a decoder that cannot
   express literal symbols ≥ 128 in simple codes — and every real stream
   with a two-symbol literal code over high bytes then misparses.
6. **OQ4 — the window cap and the auto-lgwin reality.** 22 is the
   default that covers the family; 23/24 exist in the wild (`-w 24`) and
   need the bigger instantiation. The zstd OQ1 lesson maps over: pick the
   default from what the encoder family emits (measured here), not from
   the spec's maximum.
7. **T5 — the last-metadata corner.** ISLAST=1 + MNIBBLES=0 is a legal
   stream end the §9.2 ladder does not obviously produce; two golden
   fixtures pin it; a decoder written only from §9.2's field list can
   get the loop exit wrong.

The two that gate the README sketch: **OQ8** (the Buffer composition)
and **OQ2/OQ4** (the surface shape and the window default) — with OQ1's
shipped answer stated as fact, not decision, because the measurements
closed it.
