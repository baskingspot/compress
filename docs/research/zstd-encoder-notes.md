# zstd encoder research notes

The research stage of the codec development loop for M5: the zstd encoder,
fast level (`docs/zcompress-plan.md`, "Milestones": "M5 — zstd encoder, fast
level"). Spec: `docs/research/specs/rfc8878-zstd.txt` (vendored, verbatim,
provenance in `docs/research/specs/README.md`). The decoder side of the same
format is `docs/research/zstd-notes.md` (zstd-notes): its §1 format study
covers both directions' wire formats, its OQ numbering is the decoder's, and
its `Tn` divergence rows are cited here as `Tn` without restating them. This
file builds the ENCODER side: what a conformant fast encoder must EMIT — the
inverse of every check our own decoder makes — the reference architecture
(the C v1.5.7 and klauspost), the fast-level design questions (`EQn`,
numbered like the decoder's `OQn`), and the oracle plan. The vocabulary is
the research register's: milestones, OQ/EQ rows, lanes, and fleet names live
here and in the module `AGENTS.md`, never in the codec `README.md`.

## 0. Provenance

- Spec: `rfc8878-zstd.txt` — RFC 8878 (verified, 112,425 bytes; fetched
  2026-10-08 from rfc-editor.org; freely distributable per the document's own
  Status of This Memo). Line numbers below are that file's; `§x.y.z` cites
  its sections.
- The C reference: facebook/zstd tag **v1.5.7** (dual BSD-3-Clause/GPL-2.0),
  read from `/tmp/zstd-notes-verify/zstd-c` — the M4 research's shallow
  checkout, still on disk (18 MB), reused per the disk discipline. Cites are
  `zstd-c/<path>:<line>`. The box's CLI is the same version
  (`zstd --version` → "Zstandard CLI (64-bit) v1.5.7", the flake's
  `/nix/store/...zstd-1.5.7-bin`; run this session).
- The Go reference: klauspost/compress **v1.18.0-5-g8df4d01** (BSD-3-Clause,
  local checkout `~/code/klauspost-compress`), `zstd/` — cites are
  `klauspost zstd/<file>:<line>`. Its encoder was RUN this session (below),
  not just read.
- Our decoder (`src/zstd/`, M4, landed) is the compliance list: §1's matrix
  maps every normative encoder MUST to the named error our decoder raises on
  a violation. The decoder's own notes own the decode-side rows (`Tn`);
  encoder-side divergences between the references are `TEn` here.
- Oracles run for this file — every incantation in §4 was executed this
  session and its output recorded before being written down: the zstd CLI
  v1.5.7 (`-1` encodes, `-d -c`, `-t`, `-l -v`, `--no-check`), our own
  decoder through the example CLI (`zig build example-zstd -- decode FILE`),
  and **CPython 3.14's `compression.zstd`** (libzstd **v1.5.7** — verified:
  `zstd.zstd_version == "1.5.7"`), which the M4 notes did not have: it
  supplies a third independent decode check of any encoder output AND a
  byte-level encode comparison (`zstd.compress(src, level=1)` is
  **byte-identical** to `zstd -1 --no-check` on the same input — verified
  with `cmp` on `text-32768`; the CLI's default output is those same bytes
  plus descriptor bit 2 and the 4-byte trailer, verified likewise). Python
  has no stdlib zstd outside that module (`import zstandard` fails —
  verified; `zlib` is flate-family only), so the CLI remains the fixture
  oracle and `compression.zstd` the second libzstd opinion.
- The **level-1 emission survey** (§2.6) was produced by a scratch Python
  frame walker (`/tmp/zstd-enc-notes/walk.py`, this lane's tooling, not repo
  code) that walks every block of a frame at the header level — block types,
  literals section forms, tree-description modes, nbSeq forms, symbol
  compression modes — and self-validates two ways on all 30 frames it
  walked: the walk consumes each frame exactly, and every backwards
  bitstream's last byte is nonzero (`§4.2.2`). The walker's literals-header
  bit layouts were cross-checked against `src/zstd/literals.zig`
  (`parseCompressedSizes`, the `headerBits` little-endian field), and its
  FSE-description reader against `zstd-c/lib/common/entropy_common.c`
  (`FSE_readNCount_body`, the small-value one-fewer-bit scheme of Table 20).
- The corpus: `bench/corpus-gen/` (generated, `just corpus`; 8 shapes × 2
  sizes, the `.zst` blobs written by the pinned CLI at `-1` for the
  fast-class shapes and `-19` for `words`/`skewlit` — `bench/zig/corpus.zig`
  pins the CLI version and verifies each blob through our decoder at
  generation). The level-1 `.zst` blobs are the CLI's level-1 output over
  the fixture corpus: the byte class M5's encoder targets.

## 1. The encoder's wire obligations — the inverse of the decoder's checks

RFC 8878's compliance bar for a compressor (`§2`, line 181-184): "Unless
otherwise indicated below, a compliant compressor must produce data sets
that conform to the specifications presented here. However, it does not need
to support all options." That last sentence is the fast level's license: M5
emits a deliberately narrow subset of the format, and the subset is chosen
so that every decoder in the family accepts it. The subset's boundary is
exactly what our decoder checks: a frame our encoder writes must never
raise any error in `zstd.Reader.Error` (`src/zstd/README.md`'s list; the
one-shot's `DecompressError` is the same set plus `BufferTooSmall`, which a
correctly-sized `target` cannot hit). The matrix below states each
normative MUST with the decoder's enforcement name — the encoder's output
tripping any of them is a conformance bug by definition, which is why the
day-one conformance test is "no error name except `BufferTooSmall` is
reachable on our own output."

### 1.1 Requirements matrix — a conformant zstd encoder (fast level's subset)

| # | requirement | enforced by | cite |
|---|-------------|-------------|------|
| ZE1 | Produce data sets conforming to the spec; support of all options is not required — the narrow-subset license | (the frame must decode) | `rfc8878-zstd.txt §2` |
| ZE2 | The descriptor's unused bit (4) must be set to zero | `ReservedBitSet` never trips — our decoder does not interpret it (`ZD7`) | `§3.1.1.1.1.3` |
| ZE3 | The descriptor's reserved bit (3): "Its value must be zero" | `ReservedBitSet` | `§3.1.1.1.1.4` |
| ZE4 | The modes byte's reserved low two bits "must be all zeroes" | `ReservedModeBits` | `§3.1.1.3.2.1` (Table 14) |
| ZE5 | FSE_Compressed "must not be used when only one symbol is present" — RLE instead | `MalformedFseTable` (a one-symbol distribution breaks the two-nonzero rule) | `§3.1.1.3.2.1` (Table 15), `§4.1.1` |
| ZE6 | The compressor "must encode the sequences starting with the last one and ending with the first" — the reverse-order bitstream obligation | `BitstreamNotConsumed` / `InvalidBitStream` | `§3.1.1.3.2.1.2` |
| ZE7 | After the last information bit, write a single 1 bit, then zero-fill; "The last byte of the compressed bitstream cannot be zero" — every backwards stream (sequences, each Huffman stream, the FSE weights) | `MissingStartBit` | `§3.1.1.3.2.1.2`, `§4.2.2` |
| ZE8 | At the end the sequences bitstream "shall be entirely consumed" — the writer's bit accounting is exact | `BitstreamNotConsumed` | `§3.1.1.3.2.1.2` |
| ZE9 | Every block's size, compressed AND decompressed, is bounded by Block_Maximum_Size = min(Window_Size, 128 KB), constant per frame | `BlockOversize` (T7's coupling: a single-segment frame's FCS is the bound) | `§3.1.1.2.4` |
| ZE10 | Never emit the Reserved block type | `ReservedBlock` | `§3.1.1.2.2` |
| ZE11 | Every offset "must be smaller than Window_Size" — and within the bytes actually written (the addressable span, T12) | `OffsetTooFar` | `§3.1.1.4`, T12 |
| ZE12 | The repeat-offset arithmetic: offset_value 1-3 select the repeat codes with the literals_length==0 shift; offset 0 is never emitted | `ZeroOffset`, the T6 corner | `§3.1.1.5`, T3/T6 |
| ZE13 | An FSE table description's budget lands exactly on `1 << Accuracy_Log`; at least two nonzero-probability symbols; accuracy within the context's cap (9 LL / 9 ML / 8 OF / 6 weights); the symbol count never exceeds the context's | `MalformedFseTable` | `§4.1.1`, T9 |
| ZE14 | Huffman: max code length 11 bits; the weight series completes to a power of 2 (the implied last weight); direct mode lists at most 128 weights | `MalformedHuffmanWeights` (T15: the C would accept 12) | `§4.2.1`, `§4.2.1.1` |
| ZE15 | 4-stream literals need ≥ 6 regenerated literals (the fourth stream's size underflows below 6) | `LiteralsTooLarge` | errata 7297, T4 |
| ZE16 | Single_Segment_Flag ⇒ no Window_Descriptor, FCS necessarily present, Window_Size = FCS | the frame walks clean end to end | `§3.1.1.1.1.2` |
| ZE17 | FCS, when present, is the true decoded size (any compatible field form; the 2-byte form adds 256) | `ContentSizeMismatch` | `§3.1.1.1.4` |
| ZE18 | The checksum, when the flag is set: XXH64(decoded, seed 0), low 4 bytes, little-endian, after the last block | `WrongChecksum` | `§3.1.1` |
| ZE19 | Huffman prefix codes: sorted by weight, natural order within a weight, "starting from the lowest Weight, prefix codes are distributed in sequential order" — Table 25's assignment, never the §4.2.2 example's (errata 8195) | the T1 fixture pair decodes our output to the literals we encoded | `§4.2.1.3`, T1 |
| ZE20 | Treeless literals and Repeat modes are legal only after a previous Compressed_Block with Number_Of_Sequences > 0 defined the tree/tables — within the same frame | `TreelessLiteralsFirst`, `RepeatModeFirst` | `§3.1.1.3.1.1`, `§3.1.1.3.2.1` |

Two decoder-side facts complete the compliance picture. First, the RFC
leaves the descriptor's unused bit uninterpreted for decoders but still
binds encoders ("An encoder compliant with this specification must set this
bit to zero", `§3.1.1.1.1.3`) — ZE2 is a MUST even though no decoder can
catch us. Second, our decoder is stricter than the C in corners the encoder
never enters (T13's zero-size compressed block, T14's 2^64-1 "unknown" FCS
sentinel, T12's offset past the retained history at literals_length 0): the
encoder emits none of those shapes, so the strictness costs nothing — but
one of them bites in reverse: **an unknown-size streaming Writer must omit
the FCS field entirely (descriptor flag 0, no field), never emit 2^64-1**
(T14: our own decoder would reject our own output; both references emit the
absent field for unknown size — `zstd-c/lib/compress/zstd_compress.c:4711`
computes fcsCode 0 without `contentSizeFlag`, and klauspost's
`frameHeader.appendTo` at `klauspost zstd/frameenc.go:74-79` writes nothing
for fcs 0 unless single-segment).

### 1.2 The frame-header forms we emit

The frame header (`§3.1.1.1`, Table 2) is where the encoder's choices are
most visible, and the fast level's subset is small. What the C emits
(`ZSTD_writeFrameHeader`, `zstd-c/lib/compress/zstd_compress.c:4695-4749`)
and what the survey shows on real level-1 output (§2.6):

- **Magic** `0xFD2FB528` little-endian (`§3.1.1`, 4 bytes).
- **Descriptor** (`§3.1.1.1.1`): Dictionary_ID_Flag 0 (no dictionary —
  `§6`'s media-type note says public interchange "should not use a
  dictionary"; M5 has none); Content_Checksum_Flag 1 (the CLI's default,
  verified on every level-1 artifact; ZE18's trailer then rides the frame);
  Single_Segment_Flag set iff the input size is known AND the window covers
  it (`zstd-c:4704`: `singleSegment = params->fParams.contentSizeFlag &&
  (windowSize >= pledgedSrcSize)`; klauspost `encoder.go:537`:
  `single := len(src) <= e.o.windowSize && len(src) > MinWindowSize`);
  Frame_Content_Size_Flag per the size (below); bits 4 and 3 zero (ZE2/ZE3).
- **Window_Descriptor** (`§3.1.1.1.2`), only when not single-segment: the
  C writes `(windowLog - 10) << 3` — exponent in the high 5 bits, mantissa
  always 0 (`zstd-c:4705`, `:4722`). The survey's 1-MiB files carry
  `0x48` = exponent 9, mantissa 0 = Window_Size 512 KiB, and `zstd -l -v`
  confirms ("Window Size: 512 KiB").
- **Frame_Content_Size** (`§3.1.1.1.4`): the one-shot knows the size, so it
  always declares it. Field forms (`zstd-c:4711-4712`): fcsCode 1 (2 bytes,
  value minus 256) for 256 ≤ size < 65792; fcsCode 2 (4 bytes) below 2^32-1;
  fcsCode 3 (8 bytes) at and above; fcsCode 0 (1 byte) only possible with
  single-segment (size < 256). The survey: every 32-KiB/64-KiB corpus file
  and every 1-MiB file declares the exact size (flag 1 and 2
  respectively); `empty.txt` (0 bytes) and `one.txt` (1 byte) carry the
  1-byte form; the unknown-size streaming form omits the field (§1.1's
  closing paragraph). "It is permitted to represent a small size (for
  example, 18) using any compatible variant" (`§3.1.1.1.4`) — we always
  take the smallest exact form, as the C does.

The one form the fast level does NOT emit: a Dictionary_ID (ZE20's frame
would then need the dictionary out of band, `§5`), and skippable frames
(the CLI's `--pad` and klauspost's `WithEncoderPadding` use them; nothing
in M5's surface needs one).

### 1.3 The block layer: splitting and the emission ladder

A frame is "one or more" blocks (`§3.1.1.2`), each a 3-byte little-endian
Block_Header (bit 0 Last_Block, bits 1-2 Block_Type, bits 3-23 Block_Size)
plus Block_Content. The encoder's obligations and choices:

- **Block size**: the streaming side buffers `blockSize =
  MIN(maxBlockSize, 1 << windowLog)` (`zstd-c/lib/compress/
  zstd_compress.c:1816`; `ZSTD_BLOCKSIZE_MAX` = 128 KiB, `zstd.h:148`), so
  a 1-MiB window-512-KiB input is 8 blocks of 128 KiB — the survey's
  shape, at exactly Block_Maximum_Size (ZE9's bound includes the value).
  The one-shot can chunk at the same boundary (the C does; klauspost at 64
  KiB — TE2).
- **Raw_Block** when compression does not pay: the RFC's own advice — "If
  the compressed block is larger than the uncompressed one, sending the
  uncompressed block (i.e., a Raw_Block) is recommended instead"
  (`§3.1.1.2.4`) — a recommendation the C implements as `minGain`:
  `cSize >= blockSize - ZSTD_minGain(blockSize, strategy)` ⇒ raw, with
  `ZSTD_minGain = (srcSize >> 6) + 2` at fast levels
  (`zstd-c/lib/compress/zstd_compress_internal.h:677-683`, applied at
  `zstd_compress.c:3033`). This is also ZE9's safety: the minGain margin
  guarantees a compressed block's `cSize + 3` stays under a
  single-segment frame's FCS-sized Block_Maximum_Size.
- **RLE_Block** when the whole block is one byte: the C's `ZSTD_isRLE`
  (`zstd_compress.c:3572-3589`, a word-at-a-time scan) plus the
  first-block rule — "We don't want to emit our first block as a RLE even
  if it qualifies" for zstd ≤ v1.4.3 CLI compatibility
  (`zstd_compress.c:4424-4433`, `rleMaxLength = 25`): the first block of
  the frame is compressed-or-raw, never RLE (the survey: `rle-1m` is one
  compressed 10-byte block then seven RLE blocks; klauspost's
  `blockEnc.encode` RLE fast path at `klauspost zstd/blockenc.go:483-489`
  CAN fire on the first block — TE3).
- **Compressed_Block**: literals then sequences (§1.4/§1.5), with
  Block_Size = the compressed length.
- **Tiny inputs**: the C refuses to even attempt compression below
  `MIN_CBLOCK_SIZE + 3 + 1 + 1` = 7 bytes (`zstd_compress.c:3273`), and
  klauspost below `1 + 1 + 8` = 10 (`klauspost zstd/enc_fast.go:41-43`) —
  both emit raw. The empty input is one raw 0-size block with Last_Block
  (the survey's `empty.txt.zst`, 13 bytes, matches the C CLI exactly; the
  M4 `empty-block.zst` fixture).
- **Last_Block** on the final block; the frame then ends at the checksum
  trailer if flagged (ZE18).

### 1.4 The literals section: four modes and the cost model

The Literals_Section_Header (`§3.1.1.3.1.1`, Table 12: type 2 bits, size
format 1-2 bits, Regenerated_Size 5-20 bits, Compressed_Size 0-18 bits,
little-endian across bytes) and the four types (Table 13). The fast
encoder's ladder, from the C's `ZSTD_compressLiterals`
(`zstd-c/lib/compress/zstd_compress_literals.c:129-235`):

1. **Raw** (`flSize` forms at `:39-66`): the floor cases — fewer than
   `ZSTD_minLiteralsToCompress` literals (fast strategies: 64, or 6 with a
   reusable tree, `:114-127`), or Huffman did not pay the minGain margin
   (`:187-191`). Incompressible literals stay raw: the C's
   `suspectUncompressible` heuristic — no sequences, or
   `litSize / nbSeq >= 20` (`zstd_compress.c:2886,2924`) — makes HUF skip
   to raw faster on skewed-but-flat data. klauspost adds an explicit
   "close call" (compressed within a header-size of raw ⇒ raw,
   `klauspost zstd/blockenc.go:545-556`).
2. **RLE** (`:81-107`): all literals one byte (`cLitSize == 1` from
   HUF, actively verified with `allBytesIdentical`, `:192-201`).
3. **Compressed**, with a Huffman tree description (`§4.2.1`): the
   Regenerated/Compressed sizes and the stream count choose the header form
   — Size_Format 00 (1 stream, 3-byte header, 10-bit sizes) below 256
   literals, 01/10/11 (4 streams, 3/4/5-byte headers, 10/14/18-bit sizes)
   at and above (`:140,142`: `lhSize = 3 + (srcSize >= 1KB) + (srcSize >=
   16KB)`, `singleStream = srcSize < 256`). Four streams: the Jump_Table
   (three u16-LE sizes, Stream4 by difference, `§3.1.1.3.1.6`), each
   stream's decompressed size `(Regenerated_Size+3)/4` with the last up to
   3 smaller (`§3.1.1.3.1.6`), each stream written as §1.6's backwards
   Huffman stream; the C requires ≥ 12 literals to even split
   (`huf_compress.c`, `HUF_compress4X_usingCTable_internal`: `if (srcSize
   < 12) return 0`), and ZE15/errata 7297's ≥ 6 is the format's floor.
4. **Treeless**: reuses the previous block's tree when it still fits
   (`hType = set_repeat` at `:180-184`) — the previous frame's
   Huffman table is the state that makes this legal (ZE20).

The C's depth cap for the literals tree is 11 bits (`LitHufLog 11`,
`zstd-c/lib/common/zstd_internal.h:101`, = the RFC's `§4.2.1` cap — the
C's own encoder never emits 12; T15 is a decoder-side laxity only), and the
tree's weight serialization is §1.6's subject.

### 1.5 The sequences section: nbSeq, four modes, the FSE builder

The sequences section header (`§3.1.1.3.2.1`): Number_of_Sequences in its
1-3 byte forms (byte0 == 0 ends the section — the block is its literals;
the C emits that 1-byte section for nbSeq 0, survey's `skewlit-l1`), then
Symbol_Compression_Modes (ZE4), then per-alphabet table descriptions in
LL, OF, ML order, then one backwards bitstream.

Per alphabet, the four modes (Table 15) and the C's choice ladder — the
fast-strategy path of `ZSTD_selectEncodingType`
(`zstd-c/lib/compress/zstd_compress_sequences.c:157-235`), which is a
heuristic, not a cost model (the cost path is `strategy >= ZSTD_lazy`,
`:205-231`; klauspost runs a cost comparison at every level — §2.4):

- **RLE** when one symbol carries all sequences (`mostFrequent == nbSeq`,
  `:166-178`) — except `nbSeq <= 2` prefers Predefined when allowed
  ("since RLE uses 1 byte, but set_basic uses 5-6 bits per symbol",
  `:168-175`). Survey: the CLI's `text-32768` (nbSeq 1) and `html-*`
  (nbSeq 3) emit Predefined; klauspost's nbSeq-1 output emits RLE (TE1's
  cousin — §2.4).
- **Repeat** when a previous table is valid and `nbSeq < 1000`
  (`:187-191`) — the cheapest mode (zero table bytes).
- **Predefined** when `nbSeq < dynamicFse_nbSeq_min` (offset: 36, LL/ML:
  72 at ZSTD_fast — `(1 << defaultNormLog) * (10 - strategy) >> 3` with
  OF_defaultNormLog 5, LL/ML 6, `:181-184`) or the distribution is skewed
  (`mostFrequent < nbSeq >> (defaultNormLog - 1)`, `:192-193`).
- **FSE_Compressed** otherwise: a normalized distribution, its table
  description via `FSE_writeNCount` (§1.5.1), and the encode table built
  from the same norm (§1.5.2). Accuracy_Log selection
  (`FSE_optimalTableLog`, `fse_compress.c:357-370`): clamp
  `highbit(nbSeq-1) - 2` (the "minus 2" variant, `:373`) into
  `[minBits, cap]` where `minBits = min(highbit(nbSeq)+1,
  highbit(maxCode)+2)` and floor 5 — verified empirically across the
  survey (nbSeq 249 → acc 6, 561 → 7, 1201 → 8, 2526 → 9; the caps 9/8/9
  are `MaxFSELog`-derived, `zstd_internal.h:108-110`).

The nbSeq wire forms (`zstd_compress.c:2942-2950`): `< 128` one byte;
`< 0x7F00` two (`(nbSeq>>8) + 0x80`, then the low byte); else three
(`0xFF`, low, high, of `nbSeq - 0x7F00`). klauspost's byte order is the
same wire form (`blockenc.go:588-596`).

**1.5.1 The FSE table description writer** — the exact inverse of the
decoder's `readDescription` (`§4.1.1`; ours: `src/zstd/fse.zig`). The C's
`FSE_writeNCount_generic` (`fse_compress.c:234-329`):

- First 4 bits: `tableLog - 5` (`:252-253`; `FSE_MIN_TABLELOG` 5, the RFC's
  "Accuracy_Log = low4bits + 5").
- Then per symbol in order: the probability `P = norm + 1` (norm -1 is the
  "less than 1" value 0), in a field whose width follows Table 20 — the
  same `remaining`/`threshold` descent the decoder walks (`:256-258`'s
  init `remaining = tableSize + 1; threshold = tableSize; nbBits =
  tableLog + 1`, the max bracket `(2*threshold-1) - remaining` at `:292`,
  the value shifted above threshold by `max` at `:293-295`, one fewer bit
  when the small bracket hits — `bitCount += nbBits - (count < max)`
  `:297-299`).
- Zero runs: 2-bit repeat flags, 3 extends (`:277-281`); the C writes a
  run of ≥ 24 zeros as pairs of 0xFFFF (16 bits = eight 3-flags, `:266-275`)
  — a wire-level shortcut that decodes identically.
- The budget must land exactly (`remaining != 1` is an error, `:314`)
  — ZE13 from the writer's side.

**1.5.2 The FSE table builder** — the encode-side table from the same
norm, laid out so the decoder's `§4.1.1` construction reproduces it
byte-for-byte. `FSE_buildCTable_wksp` (`fse_compress.c:68-225`) builds
`tableSymbol[]` with exactly the RFC's construction: the low-probability
(-1) symbols' single cells "starting from the end of the table and
retreating" (`highThreshold` from `tableSize - 1` down, `:84-112`), the
rest in natural order with the spread `position += (tableSize >> 1) +
(tableSize >> 3) + 3; position &= tableSize - 1`, skipping the low-prob
area (`while (position > highThreshold)` — `:162-164`), so the encode
table's `tableSymbol` IS the decode table's Symbol column. From it the
encode side builds `stateTable` (the next-state map, `:169-174`) and the
per-symbol `deltaNbBits`/`deltaFindState` transform (`:175-215`). The
decoder never sees those two — only the norm, through the description —
which is why the writer's norm constraints (ZE13) are the whole contract.

**The normalization** that produces the norm: `FSE_normalizeCount`
(`fse_compress.c:465-533`) — the scaled-probability pass with the
`rtbTable` rounding beats (`:473-495`), low-probability symbols getting
`-1` or `1` per `useLowProbCount` (the C's `ZSTD_useLowProbCount`:
`nbSeq >= 2048` ⇒ -1, else 1, `zstd_compress_sequences.c:57-64` — TE1),
the largest-symbol remainder fixup (`:496-498`), and the `FSE_normalizeM2`
secondary method when the remainder cannot be absorbed (`:386-464`).
Every produced norm sums exactly to `1 << tableLog` with -1 counting as 1
— the assertion the C keeps compiled out at `:520-530`.

**1.5.3 The sequences bitstream writer** — ZE6/ZE7/ZE8's exact algorithm,
from `ZSTD_encodeSequences_body` (`zstd_compress_sequences.c:291-382`) and
the RFC's read order. The stream is written FORWARD from the section's
bitstream region; the decoder reads it backward from the last byte, so:

1. The writer initializes the three FSE states from the LAST sequence's
   codes (`FSE_initCState2` ML, OF, LL at `:311-313`) — those states end
   up flushed at the stream's end, where the decoder reads them first, in
   LL, OF, ML order (the flushes write ML, then OF, then LL, `:372-376`).
2. The last sequence's extra bits go in FIRST, at the stream's lowest
   positions: literals_length's raw bits, then match length's, then the
   offset's (`:314-330`) — the decoder reads them last.
3. Then the loop, `n` from `nbSeq-2` down to 0 (the RFC's "starting with
   the last one", `§3.1.1.3.2.1.2`): per sequence, the state-transition
   bits in OF, ML, LL order (`FSE_encodeSymbol` calls at `:346-349` —
   these are the bits the decoder reads as the LL, ML, OF updates after
   each earlier sequence), then the raw extra bits in LL, ML, OF order
   (`:352-366`).
4. The final states flush ML, OF, LL (`:372-376`), then the single 1 bit
   and the zero fill (`BIT_closeCStream`, `bitstream.h`; the survey's
   every sequences stream ends in a nonzero last byte).

The per-sequence bit plumbing is `BIT_addBits`-style: little-endian
forward writes, each value's low bits at the lower bit positions
(`zstd-c/lib/common/bitstream.h`, `BIT_addBits`). Long offset codes split
their addBits when ofBits nears the accumulator limit — `longOffsets`, set
by `ZSTD_seqToCodes` only on 32-bit builds (`zstd_compress.c:2711`,
`MEM_32bits() && ofCode >= STREAM_ACCUMULATOR_MIN` = 25 there; 64-bit
never sets it); the writer's split at `:318-329,356-366`. A fast level
with a ≤ 512-KiB window never meets it anywhere: offset+3 < 2^19 ⇒
ofBits ≤ 18, far under both machines' limits.

**The statistics detail**: the C decrements the last sequence's code count
before normalizing when it exceeds 1 (`count[codeTable[nbSeq-1]]--`,
`zstd_compress_sequences.c:271-274`) — the initial states encode the last
sequence's codes without consuming transition bits, so the count is
biased by one; a tiny-nbSeq ratio detail, not a format rule.

### 1.6 The Huffman weight serialization — the inverse of `readTree`

The tree description (`§4.2.1.1`'s one header byte) and the C's writer
`HUF_writeCTable_wksp` (`huf_compress.c:248-289`):

- The weights are `Weight = Max_Number_of_Bits + 1 - Number_of_Bits`, the
  LAST symbol's weight implied by "completing to the nearest power of 2"
  (`§4.2.1`) — the writer lists weights for literals 0..maxSymbolValue-1
  (one fewer than the symbol count; `:270-271`).
- **Direct mode** (header ≥ 128): two 4-bit weights per byte, high nibble
  first, `Number_of_Symbols = headerByte - 127` listed weights, ceiling
  halves, `op[0] = 128 + maxSymbolValue - 1` (`:281-288`). Legal only
  when the last symbol's value ≤ 128 (`§4.2.1.1`'s "if any literal has a
  value over 128"; the C errors past `256-128`, `:282`).
- **FSE mode** (header < 128): the weight series FSE-compressed into
  exactly `headerByte` bytes (`:273-278`) by `HUF_compressWeights`
  (`:147-197`): a `§4.1.1` table description (accuracy ≤ 6, symbols = the
  weight values 0..11) followed by ONE bitstream with the two interleaved
  states — `FSE_compress_usingCTable_generic` (`fse_compress.c:551-640`):
  the weights are processed in REVERSE order from the last listed weight
  (`ip` from the end, `*--ip`), State1 takes the even indices and State2
  the odd (the RFC's even/odd interleave, `§4.2.1.2`; the writer's init
  and flush order at `:567-599` puts State1's final state at the stream's
  high end, where the decoder reads it first), and the stream terminates
  by the decoder's overflow rule — the writer's bit count is exactly what
  the two flushed states plus the transitions produce, no end marker.
  Skipped shapes: one distinct weight ⇒ RLE (maxCount == wtSize, `:161`),
  all-unique weights ⇒ not compressible (`:162`).
- The weights must complete to a power of 2 with the implied last weight
  ≥ 1, the tree's depth ≤ 11 (ZE14) — the depth cap is enforced while
  building the tree from counts (`HUF_setMaxHeight`, `huf_compress.c:
  376-493`, the rank-flattening algorithm), so the serialized weights
  cannot exceed it by construction.
- The **code assignment** is `§4.2.1.3`'s (ZE19): sort by weight, natural
  within a weight, sequential from the lowest weight — the C's
  `valPerRank` construction (`huf_compress.c:327-339`, `valPerRank[n]
  = min; min += nbPerRank[n]; min >>= 1` walking down from tableLog)
  produces exactly Table 25's assignment; errata 8195's worked example is
  the one place the RFC's own bytes disagree, and the T1 fixture pair
  (zstd-notes §5.4) is the day-one encoder golden: our Huffman path must
  reproduce the `01 0D` frame's literals stream byte-for-byte.
- The **literals streams** themselves (`§4.2.2`): each stream is written
  forward with the SYMBOLS IN REVERSE ORDER (`HUF_compress1X_...
  internal_body_loop`'s `HUF_encodeSymbol(bitC, ip[--n], ...)`,
  `huf_compress.c:991-1013`), each code's low bit at the lower position
  (the `HUF_CStream` container: `bitContainer >>= nbBits; bitContainer |=
  value` — the first-written code's LSB lands at byte 0 bit 0,
  `huf_compress.c:823-915`), then the single 1-bit end mark and zero
  fill (`HUF_endMark`/`HUF_closeCStream`, `:962-983`) — the last byte is
  nonzero (ZE7), and the decoder reading backward from the end recovers
  the literals in forward order. Four-stream mode splits the literals at
  `(Regenerated_Size+3)/4` (`HUF_compress4X_usingCTable_internal`,
  `:1168-1215`) and writes the Jump_Table's three u16-LE sizes (§1.4).

### 1.7 The repeat-offset machine — the encoder's mirror of `§3.1.1.5`

The three Repeated_Offsets seed {1, 4, 8} at the frame's start
(`§3.1.1.5`), and the encoder must model the decoder's machine exactly to
use the repeat codes: an offset_value of 1-3 selects a repeat code with the
literals_length==0 shift (offset_value 1 means Repeated_Offset2 when
litLen is 0, etc., and 3 means Repeated_Offset1 - 1 — the arithmetic that
can reach offset 0, our decoder's `ZeroOffset`, T6). The C's encoder-side
mirror is `ZSTD_updateRep` (`zstd_compress_internal.h:817-833`, the
`repCode - 1 + ll0` sum-type) with the wire values `OFFSET_TO_OFFBASE(o)
= o + 3` and `REPCODE_TO_OFFBASE(1..3)` (`:718-722`) — so a real offset o
is emitted as Offset_Value o+3 (ofCode = highbit(o+3), extra bits the
low ofCode bits of o+3), and the repeat codes as 1-3. The encoder must
also mirror the decoder's cross-block state rule: "blocks that are not
Compressed_Block are skipped; they do not contribute to offset history"
(`§3.1.1.5`) — the C resets its simulated rep history when it falls back
to raw/RLE (`*dRep = dRepOriginal`, `zstd_compress.c:4155-4160`; the non-split path's equivalent is the confirm gate, `:4435-4437`)
— and it never lets an offset reach outside the window or before the
frame start (ZE11; the C bounds the match finder by `prefixStartIndex`
from `windowLog`, `zstd_fast.c:204`).

## 2. The reference architecture study

### 2.1 The level ladder — what "level 1" means in each reference

**The C** (`ZSTD_defaultCParameters`, `zstd-c/lib/compress/clevels.h:25`):
four tables selected by input size (`ZSTD_getCParams_internal`,
`zstd_compress.c:7759-7780`: tableID = (rSize ≤ 256 KB) + (rSize ≤
128 KB) + (rSize ≤ 16 KB), rSize = srcSize + dictSize), 23 rows each
(levels 0-22 with row 0 the negative-level base). **Level 1 is
ZSTD_fast at every size class**, with (W, C, H, S, L, TL):

| tableID | class | W (windowLog) | H (hashLog) | L (minMatch/mls) | line |
|---|---|---|---|---|---|
| 0 | > 256 KB | 19 | 14 | 7 | `clevels.h:29` |
| 1 | ≤ 256 KB | 18 | 14 | 6 | `clevels.h:55` |
| 2 | ≤ 128 KB | 17 | 13 | 6 | `clevels.h:81` |
| 3 | ≤ 16 KB | 14 | 15 | 5 | `clevels.h:107` |

C (chainLog) and S (searchLog) are dead parameters at ZSTD_fast (no
chain, no search depth); TL (targetLength) only drives the uncompressible
step size (`zstd_fast.c:200`). The rows are then refined by the input
size (`ZSTD_adjustCParams_internal`, `zstd_compress.c:1473-1586`):
windowLog clamps down to `highbit(srcSize+dictSize-1)+1` (the next power
of two covering the input, floor 10 — `:1557-1559`), hashLog clamps to
windowLog+1 (`:1564`). The C's effective level-1 windowLog is therefore
`min(class_W, nextPow2(srcSize))` — verified in the survey: 32-KiB/64-KiB
inputs single-segment (window ≥ size ⇒ the header carries no window byte
at all), 1-MiB input windowLog 19 = 512 KiB (the survey's `0x48`
descriptor byte and `zstd -l -v`). **ZSTD_fast is greedy with a repcode
pre-check** — no chain, no lazy second match (lazy begins at the C's
level 5-6).

**klauspost** (`zstd/encoder_options.go:149-241`): four levels map to
four encoders — `SpeedFastest` (CLI level 1-2) = `fastEncoder`
(`encoder_options.go:190-193`, `:50-54`), `SpeedDefault` (3-4) =
`doubleFastEncoder`, `SpeedBetterCompression` (5-7) = `betterFastEncoder`,
`SpeedBestCompression` (8+) = `bestFastEncoder`. Level 1's shape
(`WithEncoderLevel`, `:221-243`): window 4 MiB FIXED (not size-adaptive,
`:228`), blockSize 64 KiB (`:229-231` — TE2), allLitEntropy off at level
1 (`:241`: `o.allLitEntropy = l > SpeedDefault` — TE4). So klauspost's
level-1 window/hash/block parameters are input-independent constants,
where the C's are a size ladder.

### 2.2 The C's ZSTD_fast — the level-1 match finder

`ZSTD_compressBlock_fast_noDict_generic` (`zstd_fast.c:192-423`) — the
v1.5.7 pipelined loop:

- **A single-slot hash table**: `U32 hashTable[1 << hashLog]`, one
  position per hash, last writer wins (`hashTable[hash0] = current0`,
  `:271-272,314-315`) — the flate klausport's shape, and the table holds
  only positions (no verification value).
- **The hash** reads `mls` bytes (`ZSTD_hashPtr`, `zstd_compress_
  internal.h:930-948`: the prime-multiply hashes, e.g. hash6 = `(u64 <<
  16) * prime6bytes >> (64-hBits)`); mls = the level's L (6 at ≤128-KB
  inputs, 7 above 256 KB). Match VERIFICATION is a 4-byte compare
  (`ZSTD_match4Found_cmov`, `:103-125`) — the emitted matches are ≥ 4
  bytes regardless of mls.
- **The repcode pre-check** ("R"): before accepting the table candidate at
  ip0, it checks `rep_offset1` at ip2 (`MEM_read32(ip2) ==
  MEM_read32(ip2 - rep_offset1)`, `:267-290`) — a 4-byte rep match 2 bytes
  ahead beats the table match at the current position, and its backward
  extension deliberately stops one short of `nextEmit` (`mLength =
  ip0[-1] == match0[-1]`, `:278-279` — never a zero-literals repcode,
  dodging `§3.1.1.5`'s ll0 shift in the hot path).
- **The acceleration**: step starts at `targetLength + !targetLength + 1`
  = 2 at level 1 (`:200`), and grows by 1 every `kStepIncr = 1 <<
  (kSearchStrength - 1)` = 128 bytes of unmatched scan (`:234,341-347`;
  `kSearchStrength 8`, `zstd_compress_internal.h:32`) — incompressible
  data is skipped progressively faster.
- **Match extension**: backward byte-at-a-time while above `anchor` and
  the match stays above `prefixStart` (`:387-391`), forward via
  `ZSTD_count` (a word-at-a-time XOR + trailing-zero count,
  `zstd_compress_internal.h:854-875`).
- **After a match**: the table is filled at `current+2` and `ip0-2`
  (`:404-408`), then the **offset-2 immediate-repeat chain** — while
  `rep_offset2` matches at the new ip0, emit zero-literal repcode
  sequences back-to-back (`:410-420`), swapping rep1/rep2 each time
  (`REPCODE1_TO_OFFBASE` after the swap, `:414,417`).
- **Rep invalidation**: reps outside the window are zeroed before the
  loop and restored after (`:238-243,355-372`) — the block's emitted
  offset history stays decodable.
- The `noDict` variant is what a no-dictionary fast level runs; the
  dictMatchState variants and the `useCmov` dispatch (`windowLog < 19`,
  `:449`) are perf-lane details.

### 2.3 klauspost's fastEncoder — the Go level-1

`klauspost zstd/enc_fast.go:39-295` ("mimmics functionality in
zstd_fast.c"):

- A FIXED `2^15`-entry table of `{val uint32, offset int32}` pairs — the
  stored 4-byte value verifies the candidate without a second load
  (`:12-29,124-131`); `tableFastHashLen = 6` (hashLen 6 — the C's ≤128-KB
  mls) regardless of input size.
- The search probes TWO candidates per iteration — the hash of the
  current 6 bytes and of the next 5 (`cv` and `cv>>8`, `:124-131`) — a
  one-position lookahead in the table that the C's pipelined loop
  achieves with ip1 (`:301-306`).
- The rep pre-check at s+2 (`repIndex := s - offset1 + 2`, `:128,133`)
  matches the C's R step, but gated: `canRepeat := len(blk.sequences) >
  2` (`:117`) — klauspost refuses to USE repeat codes for the first
  three sequences of a block, sidestepping the early-frame/ll0 corners
  the C handles with invalidation.
- The acceleration: `s += stepSize + ((s - nextEmit) >> (kSearchStrength
  - 1))` with constants 2 and 6 (`:83-88,204`) — klauspost's growth is
  continuous (every 32 unmatched bytes adds a step byte) where the C's
  steps up every 128.
- The offset-2 chain after a match (`:256-283`), the same shape as the
  C's.
- `EncodeNoHist` (`:300+`) is a no-history single-block fast path (the
  one-shot's first block).

### 2.4 The emission architecture — both references

Both wrap the same emission spine: build a SeqStore (literals buffer +
per-sequence litLength/offBase/matchLength arrays + the code tables,
`ZSTD_storeSeq` `zstd_compress_internal.h:769-805`; klauspost
`blockEnc.sequences/literals`), convert to codes (`ZSTD_seqToCodes`:
llCode via the LL band walk, **ofCode = highbit32(offBase)**, mlCode,
`zstd_compress.c:2700-2717`; klauspost `blockEnc.genCodes`), then emit.
The differences are the decision thresholds:

| decision | the C v1.5.7 | klauspost v1.18.0-5 |
|---|---|---|
| literals Raw fallback | minGain `(size>>6)+2` (`zstd_compress_literals.c:187-191`) + the ≥ 64-literals floor (`:114-127`) | `saved < 16` with `saved = size - literals - (size>>6)` (`blockenc.go:491-497`), no literals floor in `encode` (the ≥ 16 literals / ErrIncompressible ladder at `:519-543`) |
| 1 vs 4 streams | `< 256` literals single (`:142`) | `≥ 1024` four, `> 16` single (`:519-523`) |
| sequences mode | the §1.5 heuristic at fast levels (no cost computation) | a cost model at every level: `approxSize(hist) + maxHeaderSize` (+ a 1/16 header penalty) vs predefined's and the previous table's `approxSize` (`blockenc.go:619-655`) |
| nbSeq ≤ 2, one symbol | Predefined preferred over RLE ("set_basic uses 5-6 bits per symbol", `zstd_compress_sequences.c:168-175`) | RLE (`normalizeCount`'s `maxCount == length` ⇒ useRLE, `fse_encoder.go:274-277`) — verified live: kp's `text-32768` level-1 output carries RLE modes where the CLI's carries Predefined |
| all-literals blocks (nbSeq 0) | Huffman attempted (the `suspectUncompressible` heuristic still tries; the survey's `skewlit-l1` is a 23-KB compressed-literals block) | RAW unconditionally at level 1 (`allLitEntropy` off, `encoder_options.go:241`; verified live: kp's `skewlit-32768` level 1 is a raw block, 32778 B vs the CLI's 23091 B — TE4) |
| low-prob FSE cells | -1 only at `nbSeq >= 2048`, else 1 (`zstd_compress_sequences.c:57-64`) | -1 always (`fse_encoder.go:288`) — TE1 |
| block size | 128 KiB (`zstd_compress.c:1816`) | 64 KiB at SpeedFastest (`encoder_options.go:229-231`) — TE2 |
| first block RLE | suppressed (zstd ≤ 1.4.3 CLI compat, `zstd_compress.c:4424-4433`) | allowed (`blockenc.go:483-489`) — TE3 |

klauspost's FSE encoder is a line-for-line port of the C's
(`normalizeCount`'s rtbTable and largest-fixup at `fse_encoder.go:259-333`,
`buildCTable`'s spread/retreat/stateTable at `:102-190` — the same
BSD-lineage algorithm), and its `writeCount` the description writer's.
klauspost's `chooseComp` cost model is the interesting steal: it is the
C's `strategy >= ZSTD_lazy` cost path (`ZSTD_selectEncodingType:205-231`)
demoted to every level — a candidate M5 follow-up if the fleet says the
heuristic's Predefined/FSE boundary loses ratio.

### 2.5 The streaming shape — both references

**The C**: `ZSTD_compressStream2` buffers input into `blockSize`-sized
chunks (`MIN(maxBlockSize, 1 << windowLog)`, `zstd_compress.c:1816`), each
chunk compressed as a block into the output buffer, the XXH64 state
updated per consumed input chunk (`XXH64_update(&cctx->xxhState, src,
srcSize)`, `:4608,7085`), and `ZSTD_writeEpilogue` (`:5344-5376`) closes
the frame: the frame header for the never-started case (the empty frame,
`:5354-5360`), one last empty raw block when the frame has not already
ended (`1 + (bt_raw<<1) + 0` — the same 3 bytes as the public
`ZSTD_writeLastEmptyBlock`, `:4765-4777`; the epilogue's own write at
`:5361-5367`), then the checksum `(U32)XXH64_digest(...)` little-endian
(`:5372-5376`). The Writer's `finish` mirrors exactly this: no block
flushed yet ⇒ the empty last block still goes out. The frame header is
written at the first output (`:7077`, or `ZSTD_compressBegin`'s); a
pledged srcSize makes it §1.2's forms, an unknown one omits the FCS field.

**klauspost**: `Encoder.Write` buffers into `s.filling` up to blockSize
and calls `nextBlock(false)` when full (`encoder.go:148-186`); the header
is written at the FIRST flush with `SingleSegment: false` and
`ContentSize` = the pledged size or 0 (`Reset`'s default,
`encoder.go:131,225-229` — ContentSize 0 with no single-segment ⇒ the
absent FCS field, `frameenc.go:74-79`); `Close` flushes the remainder,
marks the block last, and appends the CRC (`AppendCRC`). The window
maintenance is a sliding `hist` buffer (`fastBase`, `history.go`) with
`cur` wraparound protection that re-bases the whole table every
`bufferReset` bytes (`enc_fast.go:44-67`) — the price of the fixed
4-MiB-window/64-KiB-block shape: the encoder must RETAIN `windowSize`
bytes of history for matches to reach into (the C retains them in its
circular window buffer, `zc->blockState.matchState.window`).

**What our Writer owes OUR Reader** (the boundary contract): one frame per
`Writer`, ending exactly at its checksum trailer, so `Reader.streamAll`
walks a multi-frame stream our `Writer.streamAll`-style pump produces; the
frame's Window_Size declared honestly (the history the Writer actually
retained — never larger, or a decoder with a smaller buffer refuses it,
`WindowTooLarge`; never smaller, or our own offsets break ZE11); and the
Writer's `finish` is the only path that sets Last_Block and writes the
trailer (the poisoned-finish pattern the internal writer machinery
enforces).

### 2.6 The verified level-1 emission survey

The pinned CLI v1.5.7, `zstd -1`, over the corpus shapes and the ad-hoc
survey inputs (all run this session; every frame walked by the §0 walker,
every one decoded byte-exact by the CLI AND our decoder — §4):

| input | frame form | blocks | literals | sequences |
|---|---|---|---|---|
| text-32768/65536 | single-segment, FCS flag 1, checksum | 1 compressed (54/55 B) | Raw (45), 1-stream header form sf 1 | nbSeq 1, **Predefined ×3** |
| html-32768/65536 | single-segment, flag 1, checksum | 1 compressed (58 B) | Raw (44) | nbSeq 3-5, Predefined ×3 |
| rle-32768/65536 | single-segment, flag 1, checksum | 1 compressed (9/10 B) — first block NOT RLE | Raw (2) | nbSeq 1, Predefined ×3 |
| mixed/random ×2 | single-segment, flag 1, checksum | **1 Raw block** at exactly Block_Size (32/64 KiB) | — | — |
| words-32768 at `-1` | single-segment, flag 1, checksum | 1 compressed (10 967 B) | Compressed, 4 streams, sf 2, FSE-weights tree (22 B, acc 5) | nbSeq 4056, **FSE ×3 at the caps (9/8/9)** |
| skewlit-32768 at `-1` | single-segment, flag 1, checksum | 1 compressed (23 077 B) | Compressed, 4 streams, sf 3, FSE weights | **nbSeq 0** (all literals) |
| words truncated 2/4/8/16 KiB | single-segment, flag 1 | 1 compressed | Compressed, 4 streams | nbSeq 249/561/1201/2526 → FSE everywhere, the accuracy ladder LL 6/7/8/9 with OF 5/7/8/8 and the caps 9/8/9 at 2526 |
| 1-MiB text/html/mixed/rle/random/randseq | **windowed** (descriptor `0x48`, 512 KiB), FCS flag 2, checksum | 8 blocks of 128 KiB: raw (randseq), or compressed then 9-10 B long-match blocks, or compressed then RLE (rle) | Raw or Compressed | Predefined, one RLE LL mode seen (html blk1) |
| small (24 B), one, empty | single-segment, FCS flag 0 (1-byte form) | compressed 18 B / raw 1 / raw 0 | Raw | nbSeq 1, Predefined ×3 |

The survey's headline facts for the fast level's design: level 1 emits
**Raw literals on match-rich data** (the ≥ 64-literals floor and the tiny
nbSeq keep Huffman off), **Predefined sequence modes for small nbSeq**
with **FSE at the 9/8/9 caps** for large nbSeq, **RLE blocks only after
the first block**, **Raw blocks at exactly Block_Maximum_Size** for
incompressible data, and **single-segment frames with exact FCS** for
everything ≤ window. The `-19` corpus blobs (words/skewlit) are the
decode-side fixtures and are NOT this level's output class.

## 3. The M5 fast-level design questions (the README sketch's inputs)

Numbered `EQn` (the decoder notes' `OQn` convention; `EQ` keeps the two
files' rows distinct). Each carries a recommendation; each maps to a
`src/zstd/README.md` section the API sketch owns.

- **EQ1 — the match finder.** Both references run a single-slot table with
  a repcode pre-check; the deltas are the table width, the entry layout,
  and the acceleration curve. *Recommendation*: the C's shape — a
  position-only `u32` table (half klauspost's cache footprint; the
  candidate load it costs is the load the backward extension wants
  anyway), `mls` 6 (the ≤128-KiB class's hash width; 7 only pays on
  > 256-KiB windows, where the C uses it — take the C's ladder or fix 6
  and accept the corner, a parent call), hashLog = `min(15,
  windowLog + 1)` per the C's clamp (`zstd_compress.c:1564`), the rep
  pre-check at +2 with the C's invalidation semantics (`zstd_fast.c:
  238-243`), and the offset-2 immediate-repeat chain. The match
  extension reuses the flate port's word-XOR machinery. → *README*: the
  `Options`/level surface and the finder's parameters as behavior notes.
- **EQ2 — greedy vs lazy.** Level 1 is greedy in both references; the only
  "lookahead" is the repcode pre-check at +2 (a rep match beats a table
  match two bytes later) — the survey's ratio class comes almost free
  with it. *Recommendation*: greedy + the rep pre-check + the offset-2
  chain; NO lazy at M5 (the C's lazy starts at level 5-6; a lazy level is
  a later seat if the fleet demands it).
- **EQ3 — the block splitting and the fallback ladder.** *Recommendation*:
  128-KiB blocks (the C's class; klauspost's 64 KiB trades ratio for
  flush latency — TE2), the C's exact fallback ladder: tiny inputs (< 7 B)
  raw, `minGain = (size >> 6) + 2` ⇒ raw, whole-block RLE after the first
  block (`ZSTD_isRLE`, `rleMaxLength = 25`, the first-block suppression),
  and `nbSeq == 0` sections for all-literals blocks. → *README*: the
  behavior section's raw/RLE/compressed rules.
- **EQ4 — the literals emission ladder.** *Recommendation*: the C's —
  Raw below 64 literals (6 with a reusable tree) or when HUF does not
  pay minGain; RLE for one-byte literals; Compressed with 1 stream below
  256 literals and 4 above; the close-call check; Treeless when the
  previous tree validates. The 11-bit depth cap enforced in the tree
  builder (ZE14); the weights per §1.6, with the FSE-compressed series
  preferred when it is under half the direct form (`hSize <
  maxSymbolValue/2`, `huf_compress.c:273-288` — either preference is
  conformant; the C's produces the fixtures' class).
- **EQ5 — the sequences emission ladder and the FSE builder.**
  *Recommendation*: the C's fast-level heuristic (RLE single-symbol with
  the nbSeq ≤ 2 Predefined preference; Repeat while valid and
  `nbSeq < 1000`; Predefined under 36/72 nbSeq or skewed; FSE above), the
  C's accuracy-log selection and normalization (including
  `useLowProbCount` at nbSeq ≥ 2048 — TE1), the §1.5.1 description writer
  (the exact inverse of our `readDescription`), and the §1.5.3 bitstream
  orderings. The implementation gate for the builder: our writer's norm
  → our reader's table == the same table the encode side used (round-trip
  inside one process), plus the CLI decoding frames that carry our
  tables. klauspost's cost model is the recorded follow-up.
- **EQ6 — the frame-header forms and the window ladder.** *Recommendation*:
  always declare FCS on the one-shot (the exact-size forms of §1.2);
  checksum always on (the CLI's default, the corpus blobs' class — a
  `--no-check`-style option is a later seat); no dictionary; single
  segment iff size ≤ window; the windowLog ladder `min(19,
  nextPow2(srcSize))` with floor 10 (the C's effective level-1 ladder,
  verified across the survey) — which keeps the Writer's retained
  history at ≤ 512 KiB and every declared window inside our Reader's
  8-MiB default. The unknown-size streaming form omits the FCS field
  (never 2^64-1 — T14).
- **EQ7 — the streaming Writer's shape.** *Recommendation*: the Reader's
  mirror — `Writer.Buffer(comptime window_log)` as one caller-owned
  buffer holding the history window (`1 << window_log`, ≤ 512 KiB at the
  recommended ladder), the block staging area, and the hash table
  (`4 << min(15, window_log + 1)` bytes — all comptime from
  `window_log`, the exact-pointer buffer rule); `init` takes the exact
  pointer; a mid-stream flush emits whole blocks (never partial); the
  poisoned `finish` is the only path to Last_Block + trailer; the
  checksum hashes each input chunk at the one funnel as it is consumed
  (the C's per-chunk `XXH64_update`, `zstd_compress.c:4608`). The one-shot
  `encode.encode(source, target)` needs no window buffer at all (the
  source IS the history, the decode one-shot's symmetry).
- **EQ8 — the public surface.** *Recommendation*: complete the barrel to
  the house rule (`{Reader, Writer, encode, decode}`): `zstd.encode.
  encode(source, target) !usize` (one frame, FCS declared, checksum on),
  `zstd.encode.maxCompressedLength(n)` — the exact bound for our emission
  subset: `frame header (≤ 13) + 3 per 128-KiB block + n + checksum 4`
  (tighter than and always inside the C's `ZSTD_COMPRESSBOUND`,
  `zstd.h:249`; no `zstd` block function is self-contained — the frame
  carries cross-block state, so the block layer is internal, unlike
  snappy/flate); `zstd.Writer` + `Writer.Buffer(window_log)` + the
  `*Alloc` pump pair only if the decoder's precedent demands it (the
  decoder's `streamAllAlloc` exists because an 8-MiB window never fits a
  stack; the encoder's 512-KiB-class window DOES — a stack-buffered
  default is on the table, the exact opposite trade from the Reader's,
  and the `ulimit -s 8192` lesson in AGENTS.md says the default pump
  stays lean). A `Level` enum with exactly `.fast` implemented and the
  stronger seats reserved with `error.Unimplemented` (the flate
  `Level.ratio` pattern), never silent aliasing.

## 4. The oracle plan (every incantation verified this session)

The plan's methodology ("conformance lanes: round-trip through reference
CLIs on the committed corpus, in both directions") maps to zstd as: the
CLI is the encoder oracle AND the decoder oracle (python has no stdlib
zstd; `compression.zstd` is the same libzstd underneath — §0). The lane,
as run here and as it lands for M5:

- **Encode-side oracle** (the M5 gate): for every corpus shape and survey
  input — `zstd -1 -q -k -f SRC -o OUT`, then (this session: all four
  checks on the 30 distinct level-1 artifacts — 14 corpus blobs, 6 big
  inputs, 3 entropy shapes re-encoded at `-1` plus the 4 truncated
  shapes that pin the accuracy-log ladder, 3 tiny/empty inputs):
  1. `zstd -d -q -c OUT > dec` and `cmp dec SRC` — the CLI decodes our
     output byte-exact (the encode gate re-runs it on OUR output);
  2. `zstd -t OUT` — the integrity check (a flipped trailer byte fails:
     "Decoding error (36) : Restored data doesn't match checksum", exit 1 —
     run fresh this session on a corrupted copy; our decoder fails the
     same copy with `WrongChecksum`, `frame.zig`'s `verifyTrailer`);
  3. `zig build example-zstd -- decode OUT > dec` + `cmp` — OUR decoder
     decodes our output byte-exact (run through the example CLI; the M4
     example gains `encode` when the encoder lands);
  4. `python3 -c "from compression import zstd; zstd.decompress(
     open(OUT,'rb').read())"` — libzstd as the third opinion (run on all
     30: byte-exact). Use the module-level one-shot per frame: a
     `ZstdDecompressor` object is stateful and single-frame — reusing one
     across frames raises EOFError "Already at the end of a Zstandard
     frame" (run into it, then with fresh objects), the same exact-
     boundary semantics the M4 module notes recorded (`unused_data`
     carries the next frame);
  5. the frame walker over OUR output — the survey's structural checks
     (exact consumption, nonzero stream ends, the mode census).
- **Decode-side conformance** (already landed as the corpus): the CLI's
  `.zst` blobs over the corpus shapes, verified through our decoder at
  generation (`bench/zig/corpus.zig`); M5 adds the encode direction to
  the same corpus.
- **The byte-class reference**: `zstd.compress(src, level=1)` (libzstd)
  is byte-identical to `zstd -1 --no-check` (verified with `cmp`) — the
  ratio/speed comparisons in the bench harness use the CLI (checksum on,
  the corpus class), and the fleet's zstd-c arm already links the same
  library (`bench/drivers/c/bench_zstd.c`, decode-only today; the encode
  arm is the M5 bench addition).
- **The fixture corpus plan**: the level-1 `.zst` blobs in
  `bench/corpus-gen` stay CLI-generated (the trust anchor's class). The
  ENCODE-side fixtures are OUR level-1 output over the corpus shapes,
  each recorded in `src/zstd/golden.zig` with the CLI's and our decoder's
  verdicts in its provenance comment (the M4 fixture rule), plus the T1
  pair as the Huffman path's day-one byte-exact golden (encode the four
  literals, compare the whole 19-byte frame). The fuzz lane adds the
  round-trip and differential targets: our encode → our decode (identity),
  our encode → CLI decode (byte-exact), and the compliance-list property
  (no `Reader.Error` name except `BufferTooSmall` is reachable on our own
  output, driven through the one-shot and the reader alike).
- **What was NOT run and stays with the implementation lane**: klauspost
  as an encode oracle was run (level 1 on three shapes — §2.4's
  verified rows) but is not a gate (its level-1 class deliberately
  differs, TE1-TE4); `decodecorpus.c` frames remain the M4-noted follow-up.

## 5. The divergence register (encoder side)

The RFC text, the C, and klauspost — all three recorded, none silently
picked. `TEn` mirrors the decoder notes' `Tn`.

- **TE1 — the low-probability cell value.** The C writes -1 ("less than
  1") only at `nbSeq >= 2048` (`ZSTD_useLowProbCount`,
  `zstd_compress_sequences.c:57-64`), 1 otherwise; klauspost always -1
  (`fse_encoder.go:288`). Both are conformant norms (either sums to the
  budget); the outputs differ byte-wise. *Decision for M5*: the C's rule
  (the CLI's byte class is the target).
- **TE2 — the block size at the fast level.** The C 128 KiB
  (`zstd_compress.c:1816`), klauspost 64 KiB at SpeedFastest
  (`encoder_options.go:229-231`). Smaller blocks flush streaming output
  sooner at a ratio cost (more block headers, shorter match chains).
  *Decision for M5*: 128 KiB (the CLI class; revisit only with fleet data
  on a streaming latency use case).
- **TE3 — the first block's RLE.** The C suppresses a first-block RLE for
  zstd ≤ 1.4.3 CLI compatibility (`zstd_compress.c:4424-4433`) — no RFC
  basis, a compatibility convention; klauspost allows it
  (`blockenc.go:483-489`). *Decision for M5*: follow the C (the corpus
  fixtures and the CLI's own output stay in one class).
- **TE4 — all-literals blocks at level 1.** The C attempts Huffman even
  at nbSeq 0 (the `suspectUncompressible` heuristic tries, minGain
  arbitrates — the survey's `skewlit-1`: 32 768 → 23 091 B); klauspost's
  level 1 emits RAW unconditionally (`allLitEntropy` off,
  `encoder_options.go:241`; verified live: a raw block, 32 778 B).
  *Decision for M5*: the C's (entropy-coding skewed literals is a real
  win the fast level should keep; the fallback stays minGain-bounded).
- **TE5 — tiny-nbSeq mode choice.** The C prefers Predefined over RLE at
  nbSeq ≤ 2 (`zstd_compress_sequences.c:168-175`); klauspost goes RLE
  (verified live on `text-32768`: RLE ×3 vs the CLI's Predefined ×3).
  *Decision for M5*: the C's.
- **TE6 — the nbSeq==0 empty-sequences form.** Both references emit the
  1-byte section (byte0 == 0); our decoder also accepts the decoded-zero
  2-byte form (T5) — the encoder simply never needs it (the C's writer
  cannot produce it). No decision; recorded so the fuzz lane knows our
  output never carries it.

## 6. Ranked ambiguities — the ones that gate the README sketch

1. **EQ7 — the Writer's buffer shape and the flush contract.** The
   largest surface decision: one comptime-sized `Writer.Buffer` carrying
   window + staging + hash table (the Reader's mirror, all sizes from
   `window_log`), against a separate table allocation or the 64-KiB
   klauspost shape. It fixes the API's ownership story and the streaming
   semantics (`finish`-only trailer, whole-block flushes); decide before
   the sketch.
2. **EQ1 — the hash width and the table width.** mls 6 vs the C's 6/7
   ladder, hashLog's clamp, the entry layout (position-only vs
   val+position). Ratio and speed both move here, and the fleet's
   zstd-c arm will measure exactly the C's choice; the sketch needs the
   parameters named even if the values are provisional.
3. **EQ6 — the windowLog ladder.** The single-segment/`nextPow2` ladder
   (the CLI's class) against a fixed 17/19. It fixes the declared window
   in the README's behavior section and the Writer's retained-history
   sizing; the corpus is single-segment either way, the 1-MiB survey
   files are the ladder's evidence.
4. **EQ8 — the reserved seats.** `Level.fast` plus `error.Unimplemented`
   seats (the flate pattern), and whether the default pump is
   stack-buffered (the encoder's window fits a stack where the decoder's
   8 MiB does not — the opposite of the Reader's `*Alloc` pair). The
   barrel rule completes at M5 either way.
5. **TE1-TE5 — the byte-class decisions.** Each is small alone; together
   they decide whether "level-1-class output" means the CLI's bytes-class
   or merely its decodability class. The recommendation throughout is
   the CLI's class (the corpus fixtures, the survey, and the fleet's
   comparison arms all assume it).

The three that must be settled before the API sketch: **EQ7** (the
buffer/flush contract), **EQ8** (the surface and seats), and **EQ6** (the
window ladder) — the same trio shape the decoder notes' ranked list ended
on, one milestone later.
