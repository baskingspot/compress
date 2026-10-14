# Dictionary research notes

The research stage of the cross-codec dictionary milestone: dictionaries
across the codecs, after M6 (`docs/zcompress-plan.md`, "Milestones": M6 closed
at `a9fdc4a`). The standing decision
(`docs/research/feature-inventory.md`, "Cross-cutting gaps": "the requirement
on zcompress is *consuming* them — the dictionary format as an API") holds
through this file: **the dictionary file is an input**, parsed at setup and
handed to the encoder and the decoder; the in-repo trainer is a nice-to-have
after, never a dependency — the `zstd` CLI trains (verified here, §1.3).

Three questions, three answers of very different size:

- **zstd** (RFC 8878 §5) is the real feature lift: a wire format with entropy
  tables, repeat offsets, and content, parsed into the frame's starting state
  on both sides. §1-§3.
- **zlib preset dictionaries** (RFC 1950 §2.2 FDICT) are the small piece:
  no file format, just bytes — the 32-KiB flate window pre-seeded with caller
  content. §4.
- **gzip and brotli** are negatives, recorded so the plan never asks again:
  gzip has no dictionary concept anywhere in RFC 1952, and brotli's
  custom-dictionary path is an extension surface outside RFC 7932 that this
  repo already refuses naturally. §5.

Every requirement line below cites the spec file and section, or the reference
source at `path:line`; where the spec is silent or self-inconsistent against
the references, both are recorded and the divergence is a decision for the
parent (`DT` rows, §9). The existing registers are ground truth already landed
and are cited, not restated: the M4 decoder notes (`zstd-notes.md` — `Tn`
divergence rows, `OQn` design questions), the M5 encoder notes
(`zstd-encoder-notes.md` — `TEn`, `EQn`), the brotli notes (`brotli-notes.md`),
and the module registers (`src/zstd/AGENTS.md`, `src/brotli/AGENTS.md`,
`src/zlib/AGENTS.md`).

## 0. Provenance

- Specs (all vendored verbatim, provenance rows in
  `docs/research/specs/README.md`): `rfc8878-zstd.txt` §5 (Dictionary Format)
  and §6 (Use of Dictionaries) — 4 pages total, the whole normative surface;
  `rfc1950-zlib.txt` §2.2 (Data format: FDICT, DICTID, and the ADLER32
  trailer's "excluding any dictionary data"), §2.3 (Compliance); `rfc1951-deflate.txt` §3.2.3 (the preset
  dictionary parenthetical — "An application using a preset dictionary might
  discard part of the output stream; a distance can refer to that part of the
  output stream anyway"); `rfc1952-gzip.txt` (nothing — the negative is the
  absence); `rfc7932-brotli.txt` (nothing on custom dictionaries — verified by
  search, §5).
- Reference implementations read for this file (cited inline as `path:line`):
  facebook/zstd at tag **v1.5.7** (dual BSD-3-Clause/GPL-2.0; the M4-era
  checkout `/tmp/zstd-notes-verify/zstd-c`, 13 MB, still present and verified
  at `f8745da` this session), klauspost/compress at **v1.18.0-5-g8df4d01**
  (BSD-3-Clause, `~/code/klauspost-compress`) — `zstd/dict.go` is its
  dictionary parse and its own trainer, and `zstd/enc_fast.go`'s
  `fastEncoderDict` is the encoder-with-dict shape; Zig 0.16.0 std — nothing
  new (std rejects dictionary frames; `zstd-notes.md` T11); zlib **v1.3.1**
  (Jean-loup Gailly and Mark Adler, the C reference, fetched from
  madler/zlib `v1.3.1` `deflate.c` this session for
  `deflateSetDictionary`; the box's python3 links zlib **1.3.2**, the same
  lineage) — `inflateSetDictionary` was not fetched: its semantics are
  pinned empirically through python3 (§4).
- Oracles run for this file — every incantation in §1-§4 was executed here and
  its output recorded before being written down: the zstd CLI v1.5.7
  (`zstd --train` twice — the default fastCover and a `--maxdict`/`--dictID`
  variant; `-D` round-trips at `-1`/`-19`; the mismatch/negative cases;
  `zstd -l -v`, `zstd -t`), the brotli CLI 1.2.0 (`-D` encode/decode round
  trip, the no-dict decode failure), this repo's example CLI (the brotli
  decode of a `-D`-encoded stream), and python3 zlib (the `zdict=` round trips
  and the four mismatch cases, §4). The zstd dictionary files were
  hand-parsed byte level with from-scratch Python (§1.1) and cross-checked
  against klauspost's `InspectDictionary` (§1.1); the frame-level byte classes
  were walked with a hand-built §3.1.1 frame walker (§3.5).
- Scratch lives in the M4-era tree `/tmp/zstd-notes-verify/` (18 MB before this
  session; the additions are a `dict-train/` training set and five scripts,
  under 400 KB total). The parent deletes the tree at this milestone's close.

## 1. The zstd dictionary format (`rfc8878-zstd.txt §5`) — the wire truth

### 1.1 The formatted dictionary, byte-verified

The RFC's whole wire definition is one table and five paragraphs (`§5`,
Table 27): `Magic_Number | Dictionary_ID | Entropy_Tables | Content`.

- **Magic_Number**: 4 bytes, `0xEC30A437` little-endian — on the wire
  `37 a4 30 ec`. Verified: both CLI-trained dictionaries and both of the C's
  own golden dictionary fixtures open with exactly these bytes.
- **Dictionary_ID**: 4 bytes little-endian, "any value, except 0 (which means
  no Dictionary_ID)" (`§5`). The public ranges (≤ 32767 and ≥ 2^31) are
  "reserved and shall not be used" for public distribution (`§5`,
  restating `§3.1.1.1.3`).
- **Entropy_Tables**: "Follow the same format as the tables in compressed
  blocks. See the relevant FSE and Huffman sections for how to decode these
  tables. They are stored in the following order: Huffman table for literals,
  FSE table for offsets, FSE table for match lengths, and FSE table for
  literals lengths. These tables populate the Repeat Stats literals mode and
  Repeat distribution mode for sequence decoding. It is finally followed by
  3 offset values, populating repeat offsets (instead of using {1,4,8}),
  stored in order, 4 bytes little-endian each, for a total of 12 bytes. Each
  repeat offset must have a value less than the dictionary size" (`§5`).
- **Content**: "The rest of the dictionary is its content. The content acts
  as a 'past' in front of data to be compressed or decompressed, so it can be
  referenced in sequence commands" — with the window rule quoted in §2.2
  below.

The RFC does not give the entropy tables a size or a terminator: the
Huffman tree description is the `§4.2.1.1` form (its own length is decoded),
the three FSE tables are the `§4.1.1` forward-read descriptions (each ends
when its probability budget is spent), and the content starts where the
12th repcode byte ends. Verified here, byte level, on
`zstd --train` output (a 14,493-byte and a 15,154-byte dictionary) with a
from-scratch parser (`/tmp/zstd-notes-verify/dict-parse.py`,
`dict-weights.py`), and cross-checked against klauspost's `loadDict`
(`zstd/dict.go:53-124`) through `InspectDictionary` — the two independent parses agree on
every field, and both dictionaries round-trip through the C's loader
(the CLI) byte-exact:

| field | the trained dict (14,493 B) | the second (15,154 B) | cite |
|---|---|---|---|
| magic | `37 a4 30 ec` | same | `§5` |
| dict_id | 574546390 | 537350784 | `§5`; both in the private range [32768, 2^31) — the trainer's `compliantID` formula, `zdict.c:880` |
| literals table | FSE-compressed weights, 28 B (header byte 27) | 27 B | `§4.2.1.1`: "the length of the FSE-compressed series is equal to headerByte" |
| weights decode | 255 entries + 1 implied = **256 symbols**, max code length 10, **no zero weights** | same class | `§4.2.1.2`, the C's `HUF_readStats` (`entropy_common.c:243-321`) |
| offsets table | acc 8 (the cap), symbols 0-17, **no zero counts**, budget exact (250 + 6 "less than 1" = 256) | acc 8, 0-17 | `§4.1.1`, the 8 cap `§3.1.1.3.2.1` |
| match lengths | acc 9 (the cap), symbols 0-52 (the full alphabet), no zero counts | same | same, the 9 cap |
| literal lengths | acc 9 (the cap), symbols 0-35 (the full alphabet), no zero counts | same | same |
| the 12 repcode bytes | **{1, 4, 8}** | {1, 4, 8} | `§5`; `zstd_internal.h:65` (`repStartValue = {1, 4, 8}`), written at `zdict.c:831-833` |
| content | 14,378 B from offset 115, sample fragments (all 8-byte windows found in the training set) | 15,040 B | `§5` |

The headline facts a consumer needs, each verified above:

1. **The trainer writes the default repcodes.** The v1.5.7 `ZDICT_analyzeEntropy`
   computes "most common first offset" statistics and then discards them:
   "at this stage, we don't use the result of 'most common first offset', as
   the impact of statistics is not properly evaluated" (`zdict.c:824-833`,
   the `#if 0` block). A CLI-trained dictionary's 12 repcode bytes are
   literally `{1,4,8}` — the same seeds a no-dictionary frame uses.
2. **The trainer writes complete statistics by design.** Every table covers
   its whole alphabet with nonzero probability — the offsets table tops out at
   the code the dictionary size requires (17 here: the C's
   `offcodeMax = highbit32(dictContentSize + 128 KB)`,
   `zdict.c:669`, the `OFFCODE_MAX` 30 gate at `:688`),
   the length tables at the alphabet maxima (52/35), and the Huffman tree at
   256 symbols with no zero weights. This is deliberate: a "complete" table
   is promotable to the trusted reuse state (§3.1), and the reference
   trainer never generates the partial kind (facebook/zstd issue #3724,
   Cyan4973: "the reference dictionary builder always generate 'complete'
   statistics").
3. **A dictionary with incomplete statistics is still a legal dictionary.**
   The C ships two such fixtures: `tests/dict-files/zero-weight-dict`
   (153 B — 120 zero-weight symbols in the literals tree) and
   `tests/golden-dictionaries/http-dict-missing-symbols` (1,000 B — zero
   weights in the tree *and* zero-probability symbols in the offsets and
   match-length tables). Both round-trip through the CLI (verified here for
   zero-weight-dict; the missing-symbols row is the C's own
   `playTests.sh:1291` and `cli-tests/dictionaries/golden.sh`). The
   partial kind is exactly what the load-side promotion rules (§3.1) demote,
   and what the v1.5.5-and-earlier C **errored on** — the versioning story
   in §1.3.

### 1.2 The raw-content dictionary

"Zstandard is compatible with 'raw content' dictionaries, free of any format
restriction, except that they must be at least 8 bytes. These dictionaries
function as if they were just the content part of a formatted dictionary"
(`§5`). So the raw form contributes content (the preset history) and nothing
else: no ID, no tables, and the default `{1,4,8}` seeds. Verified live: the
CLI's `-D` on a plain text file compresses and decodes cleanly, and the frame
it writes carries no Dictionary_ID field at all (`zstd -l -v` shows
"DictID: 0", the same as a no-dictionary frame) — decoding it without the
dictionary fails "Data corruption detected", not "Dictionary mismatch"
(§3.5). The C's detection is by magic:
`ZSTD_decompress_insertDictionary` reads a dictionary under 8 bytes or
without the magic as pure content (`zstd_decompress.c:1539-1545`); the
encoder-side equivalent is `ZSTD_compress_insertDictionary`'s `dct_auto`
(`zstd_compress.c:5205-5234`).

klauspost's raw form is `WithDecoderDictRaw(id, content)`
(`decoder_options.go:110-118`) — it lets the caller *assign* an ID to raw
content so a dictionary-ID frame can select it (their comment: "zstd
--patch-from uses this id"). The C has no such thing: a raw dictionary has
no ID, so a dictionary-ID frame never matches it (verified live: a
formatted-dictionary frame decoded with a raw dictionary fails "Dictionary
mismatch"). Recorded as a divergence (§9, DT6) — ours follows the C.

### 1.3 The trainer's output and its versioning

`zstd --train` is the fastCover algorithm by default (`zstdcli.c:905`:
`dictType dict = fastCover`; `--train-cover` and `--train-legacy` select the
others), writing through `ZDICT_finalizeDictionary` (`zdict.c:858-933`):
magic, a dictID derived from `XXH64(content)` folded into the private range
(`compliantID = (randomID % ((1<<31)-32768)) + 32768`, `zdict.c:879-881`) —
or the caller's `--dictID=#` (verified: `--dictID=100` lands in the
reserved low range and the CLI happily round-trips it, §9 DT5), the entropy
tables written by `HUF_writeCTable_wksp` (a 255-symbol literals tree,
`zdict.c:775-784`) and three `FSE_writeNCount` calls (`:786-816`), the
repcodes (§1.1 fact 1), then the content — placed at the *end* of the buffer,
with zero padding *before* it when the content is smaller than the largest
repcode: "The padding comes before the content because the 'best' position
in the dictionary is the last byte" (`zdict.c:896-925`). The trainer's
constants: `ZDICT_DICTSIZE_MIN` 256 and `ZDICT_CONTENTSIZE_MIN` 128
(`zdict.h:305-307`), the CLI's default `--maxdict` 110 KB
(`zstdcli.c:83`), and the practical size ceiling ~2 GiB — the trainer
errors when `highbit32(dictContentSize + 128 KB)` exceeds `OFFCODE_MAX` 30
(`zdict.c:688`, "too large dictionary"); klauspost pins the same bound as
`dictMaxLength = 1 << 31` ("Maximum dictionary size for the reference
implementation (1.5.3) is 2 GiB", `zstd/dict.go:19-20`).

**The format has no version field.** Compatibility is not negotiated in the
bytes; it falls out of two facts. First, the entropy tables are literally the
compressed-block table forms (`§5`'s own sentence), so any parser that reads
frames reads dictionaries — the table wire forms have been stable across the
library's life. Second, the one behavioral change in the format's history is
the acceptance of *incomplete* statistics (§1.1 fact 3): the C v1.5.5 and
earlier errored `dictionary_corrupted` on a literals tree whose
`maxSymbolValue < 255` (facebook/zstd issue #3724 — klauspost hit it
building his own trainer; terrelln's fix landed in v1.5.6 as the promotion
rule quoted in §3.1). klauspost's own `BuildDict` carries a `CompatV155`
flag whose entire job is to append a literal-255 weight so the output stays
loadable by v1.5.5 (`zstd/dict.go:185-186`, `:441-442`, `:466-468`). A
consumer that accepts both complete and incomplete tables (the v1.5.6+
behavior) is compatible with every trainer output; a consumer that wants to
*emit* maximally compatible dictionaries writes complete statistics, which
the CLI's trainer always does (§1.1 fact 2).

### 1.4 The dictionary in a frame header

The frame side (`§3.1.1.1`): the descriptor's Dictionary_ID_Flag carries
0/1/2/4 bytes of Dictionary_ID. The C's encoder writes the loaded
dictionary's ID whenever one is loaded (the CLI's `--no-dictID` suppresses
it; `FIO_setDictIDFlag`, `programs/fileio.c:361`). Verified live at both
settings: `-D dict -1 file` emits descriptor `0x67` (single-segment, FCS
flag 1, checksum, DID flag 3 = the 4-byte form) with the dictionary's ID,
and `--no-dictID` emits the same frame with DID flag 0. The RFC's reserved
ranges (`§3.1.1.1.3`: "Any payload presented for decompression that
references an unregistered reserved dictionary ID results in an error") are
not enforced by the C (§9, DT5).

## 2. What the decoder needs (`zstd_decompress.c`, the load path)

The C's decoder-side dictionary load is `ZSTD_decompressBegin_usingDict`
(`zstd_decompress.c:1588-1597`) → `ZSTD_decompress_insertDictionary`
(`:1539-1558`): under 8 bytes or without the magic → `ZSTD_refDictContent`
(the raw-content path); with the magic → read the ID, load the entropy
tables (`ZSTD_loadDEntropy`, `:1448-1536`), then reference the content.

### 2.1 `ZSTD_loadDEntropy` — the parse, in the C's own order

`zstd_decompress.c:1452-1536`, every check a named `dictionary_corrupted`:

1. `dictSize <= 8` → "dict is too small" (the raw-content path already
   handled the < 8 case; this catches an 8-byte "formatted" stub).
2. Skip 8 bytes (magic + ID — the ID is read by the caller, `:1546`).
3. The literals Huffman table: `HUF_readDTableX2_wksp` — the exact same
   reader a Compressed_Literals_Block's tree description goes through. Our
   landed `huff0.readTree` is that reader (`src/zstd/huff0.zig:73`).
4. Offsets FSE: `FSE_readNCount` with `offcodeMaxValue > MaxOff` (31) and
   `offcodeLog > OffFSELog` (8) both fatal, then build the decode table.
5. Match lengths: same, caps 52 and 9.
6. Literal lengths: same, caps 35 and 9.
7. The 12 repcode bytes: `rep == 0 || rep > dictContentSize` is fatal,
   where `dictContentSize` is the content after the 12 bytes — the RFC's
   "less than the dictionary size" read as "less than the content size"
   (the only reading that can hold: the RFC's own sentence says "less than
   the dictionary size" while the trainer's reps are seeds against the
   content — recorded as DT2).
8. The rest is content; `ZSTD_refDictContent` (`:1435-1446`) splices it in
   front of the output as the virtual past (`prefixStart`/`virtualStart`/
   `dictEnd` — the exact three-pointer shape `ZSTD_execSequence_extDict`
   walks, `zstd_decompress_block.c:910-1000`, including the match that
   straddles the dictionary/output boundary: "span extDict &
   currentPrefixSegment", `:938-943`).
9. `dctx->litEntropy = dctx->fseEntropy = 1` (`:1554`) — this is what makes
   Treeless literals and Repeat sequences legal from the frame's first
   block (`§3.1.1.3.1.1`: "if this mode is triggered without any previous
   Huffman table in the frame (or dictionary, per Section 5)"; the M4
   matrix's ZD16/ZD17/ZD24 rows already carry the dictionary clause).

**The decomposition — load-time vs decode-time.** Everything above is
load-time: the tables are parsed and built once, the repcodes checked once,
the content never touched. Decode-time work is unchanged: the block layer
consults the seeded state instead of `{1,4,8}` and empty-table seats
(`frame.State.literals.has_table`, `frame.State.sequences.tables`,
`src/zstd/frame.zig:392-396` — the exact three seats `frame.State.init`
resets today; `sequences.State.repeat_offsets`, `src/zstd/sequences.zig:428`, its seeds at `:434`).
The one decode-time rule the load cannot pre-check is the window rule:

### 2.2 The content as preset history — the window rule

`§5`: "As long as the amount of data decoded from this frame is less than or
equal to Window_Size, sequence commands may specify offsets longer than the
total length of decoded output so far to reference back to the dictionary,
even parts of the dictionary with offsets larger than Window_Size. After the
total output has surpassed Window_Size, however, this is no longer allowed,
and the dictionary is no longer accessible."

So the decoder's addressable span at a match (the M4 T12 rule, generalized):
while the frame's decoded total is ≤ Window_Size, the span is the *whole*
dictionary content plus the decoded output; once the total passes
Window_Size, the span is the last Window_Size bytes of the frame's own
output, dictionary gone. This is the M4 OQ1/T12 machinery with one extra
region in front and one expiry boundary — `sequences.decode`'s
`target[0..history_len]` history becomes two regions (the caller's
dictionary content slice and the output), and the `history_len` the caller
computes drops the dictionary at the boundary.

**The references do not enforce the rule as written** (a T12-class
divergence, §9 DT1): the C's whole-buffer decoder checks only the available
history — `sequence.offset > (oLitEnd - prefixStart)` walks into the
dictionary region whenever it is still referenced
(`zstd_decompress_block.c:930-933`), with no Window_Size test against the
dictionary; the streaming decoder's dictionary access instead ends by buffer
adjacency (`ZSTD_checkContinuity` re-bases `dictEnd` to the previous output
chunk when a new output buffer is not contiguous). Neither is the RFC's
boundary exactly. The hand-built-frame oracle pin (a small window, a
sequence that reaches into the dictionary after the total passes
Window_Size) is the oracle lane's job, exactly as T12's `frame_window_*`
fixtures were; the fail-closed reading (enforce the RFC's boundary) is the
recommendation, with the references' leniencies recorded.

### 2.3 The dictionary-ID check

`ZSTD_decodeFrameHeader`: `RETURN_ERROR_IF(dctx->fParams.dictID &&
(dctx->dictID != dctx->fParams.dictID), dictionary_wrong, "")`
(`zstd_decompress.c:716-719`, skipped entirely in fuzzing builds,
`:712-715`). Verified live, and pinned by the C's own
`tests/cli-tests/dictionaries/dictionary-mismatch.sh` with its
`.stderr.exact`:

- the right dictionary: clean decode, `zstd -t` clean;
- no dictionary: `Decoding error (36) : Dictionary mismatch`, exit 1;
- the wrong dictionary (a different trained dictionary, a raw file, another
  trained dictionary's ID): the same "Dictionary mismatch".

Our current fail-closed posture (M4 OQ4/T11: `DictionaryRequired` at the
first Dictionary_ID byte, before any body byte) extends, not changes: a
dictionary *supplied* whose ID does not match the frame's needs its own
name (`DictionaryMismatch`, the C's own label), while no-dictionary keeps
`DictionaryRequired`. A frame with DID flag 0 decodes with any (or no)
dictionary — but a dictionary whose *tables* the frame's first block reuses
(Treeless/Repeat from block 0) is silently load-bearing (§3.5): the
`--no-dictID` frame decodes with the dictionary and fails "Data corruption
detected" without it (verified live). The DID is metadata, not a
dependency marker.

## 3. What the encoder needs (`zstd_compress.c`, the load path)

### 3.1 `ZSTD_loadCEntropy` and the promotion rules — the `repeat_valid` seat

`ZSTD_loadCEntropy` (`zstd_compress.c:5061-5165`) parses the same bytes in
the same order as the decoder's load (skip 8; `HUF_readCTable` at
`maxSymbolValue` 255; the three `FSE_readNCount`s with the same log caps;
the 12 repcodes with the same nonzero/content-bound checks), but into the
*encode-side* tables (`FSE_buildCTable_wksp`), and it computes the reuse
state instead of merely enabling it:

- **The literals tree**: `repeatMode` starts `HUF_repeat_check`; it is
  promoted `HUF_repeat_valid` only "if it contains all non-zero weights"
  and reaches the full alphabet — `if (!hasZeroWeights && maxSymbolValue ==
  255) bs->entropy.huf.repeatMode = HUF_repeat_valid` (`:5078-5079`). The
  `maxSymbolValue == 255` clause is the #3724 subject (§1.3): the tree must
  cover every literal byte value to be trusted blindly.
- **Each FSE table**: `ZSTD_dictNCountRepeat` (`:5047-5059`) — `valid` only
  if the loaded table covers the whole alphabet the encoder may need
  (`dictMaxSymbolValue >= maxSymbolValue`) with no zero-probability symbol
  in it; else `check`. For the offsets table the requirement is
  representability: `offcodeMax = highbit32(dictContentSize + 128 KB)`,
  "All offset values <= dictContentSize + 128 KB must be representable for
  a valid table" (`:5134-5140`) — every offset the match finder can emit
  into the dictionary (§3.2) must have a code in the table.

These are exactly the seats the M5 encoder landed: `State.repeat_valid`
(`src/zstd/sequences_compress.zig:96`, with its doc comment citing this
function), selected by the fast-level ladder only while valid and under
1,000 sequences (`:467`; the C's `zstd_compress_sequences.c:187-191`), and
the literals floor's dictionary gate — the 6-literal floor "applies only
when the previous tree is `HUF_repeat_valid`, which only dictionary loading
sets" (`src/zstd/literals_compress.zig:57-64`, `min_literals_to_compress`).
The M5 register's row is the summary ("Repeat_Mode is unreachable without a
dictionary ... with `State.repeat_valid` the seat a dictionary would set",
`src/zstd/AGENTS.md`); this section is its ground truth.

The semantics of the two states, from the fix's author (facebook/zstd
#3724, terrelln): "if the table is marked as `valid` we will always use the
dictionaries (or previous blocks) tables [at lower compression levels]. If
the dictionary is marked as `check` we won't re-use the tables ever [at
lower compression levels]." At the fast level the check-state table is dead
(no cost model runs below `ZSTD_lazy`), which is why a CLI-trained
dictionary (always valid, §1.1 fact 2) is what makes the with-dictionary
byte class at `-1` (§3.5).

### 3.2 The match finder with dictionary content

The content enters the match state through `ZSTD_loadDictionaryContent`
(`zstd_compress.c:4898-5038`): the content (cut to a suffix if larger than
the index space allows, `:4918-4941`) is appended to the window and hashed —
for the fast strategy, `ZSTD_fillHashTableForCCtx` inserts every
`fastHashFillStep` (3rd) position (`zstd_fast.c:53-85`), with the
positions 1-2 inside each step filled "only if their hash entry is empty"
under `ZSTD_dtlm_full` (the CDict path, `:71-78`; the raw
`ZSTD_compress_usingDict` family passes `ZSTD_dtlm_fast` — every 3rd
position only, `zstd_compress.c:5312,5325,5467`; the CLI's `-D` goes
through `ZSTD_CCtx_loadDictionary` → a CDict → **dtlm_full**, `:5591-5594`).
The two fills select different first-candidates (the table is
last-writer-wins), so the fill density is a real byte-parity variable for
the oracle lane (§8), not a detail.

The repcode seeds are the dictionary's 12 bytes (`bs->rep`, `:5127-5129`)
in place of `{1,4,8}` — the encoder-side mirror is the landed
`block_compress`'s rep machine with its seeds swapped
(`src/zstd/block_compress.zig:112`, the decode-side seed
`src/zstd/sequences.zig:434`).

klauspost's shape is the other implementable option: a separate
`dictTable` built once per dictionary (`fastEncoderDict.Reset`,
`zstd/enc_fast.go:819-880`) with dictionary indices offset above the
frame's own index space (`e.cur = e.maxMatchOff`), filled every 2nd
position (`i`, `i+1` — a different density again). The C's CDict path keeps
the dictionary as a separate match state too (`dictMatchState` variants,
`zstd_fast.c:483-679`); the raw `usingDict` path splices the dictionary into
the one window. For this package's one-shot the natural port is the
two-region form (the dictionary content is caller memory, the source is
caller memory, they are not contiguous): a pre-filled table over dictionary
positions whose candidates verify by reading the dictionary region, plus
the existing single-slot table over the source. Which fill density lands is
the parity decision the oracle lane settles (§8).

### 3.3 The window arithmetic and the expiry rule

The dictionary participates in the level's parameter arithmetic: the class
row is selected by `rSize = srcSize + dictContentSize`
(`ZSTD_getCParamRowSize`, `zstd_compress.c:7734-7748`, the encoder notes'
§2.1 table), and the window is sized so the dictionary never expires
mid-frame on the one-shot: `ZSTD_dictAndWindowLog` keeps `windowLog`
"large enough to fit the source and the dictionary" (`:1431-1447`, the
comment quoting the same §5 rule), and `ZSTD_adjustCParams_internal`
clamps `windowLog` down to the next power of two covering
`srcSize + dictSize` (`:1550-1561`). Verified live at both sizes: a 735-B
source with a 14-KB dictionary single-segments (Window_Size = FCS = 735 —
and the whole decode stays ≤ Window_Size, so the dictionary is addressable
throughout), and a 591-KB source declares the 512-KiB class window
(descriptor `0x87`, Window_Size 524,288, FCS flag 2) — past 512 KiB of
output the dictionary expires and the encoder stops matching into it
(the C's `ZSTD_checkDictValidity` window-slide machinery,
`zstd_compress_internal.h:1100-1145`). Our `Params.forSource`
(`src/zstd/match_compress.zig:90-133`) takes the effective size — with a
dictionary it is `forSource(source_len + dict_content_len)`, a one-line
seat.

The expiry rule is the one streaming-encoder obligation the one-shot never
trips (its window covers source + dictionary by construction): a `Writer`
with a fixed comptime window can outgrow its dictionary, and must stop
reaching into it exactly at the §5 boundary — the mirror of the decoder
rule in §2.2.

### 3.4 The frame header with a dictionary

`ZSTD_writeFrameHeader` adds the Dictionary_ID field when a dictionary is
loaded (the `--no-dictID` knob suppresses it; `zstd_compress.c:4695-4749`).
The single-segment decision is unchanged in form — `windowSize >=
pledgedSrcSize` with the dictionary-adjusted window (`:4704`) — verified
live (§3.3). The `--no-dictID` frame is the interesting case for a
consumer: it is *legal* and *undecodable without the dictionary* whenever
the encoder reused the dictionary's tables (§3.5), and the decoder cannot
tell that from corruption (§2.3). The RFC's own media-type note says
public-interchange content "should not use a dictionary" (`§6`); the
`--no-dictID` CLI option is the private-distribution carve-out. An encoder
that always writes the DID (the default) is the honest form; ours should
(the `no-dictID` suppression is a documented knob at most, not a default).

### 3.5 The verified with-dictionary byte class at level 1 — the parity target

Walked with a hand-built §3.1.1 frame walker over CLI output, this session:

| input | frame | first block's literals | sequences modes |
|---|---|---|---|
| 735-B sample, `zstd -D dict -1` | single-segment, FCS, DID, checksum | **Treeless** (the dictionary's tree, reused from block 0) | nbSeq 87 < 1000: **LL/OF/ML all Repeat** |
| 23.6-KB concatenation, `-D dict -1` | single-segment | Treeless | nbSeq 1827 ≥ 1000: **FSE ×3** (the ladder's `< 1000` gate; the dictionary is not consulted above it) |
| 591-KB file, `-D dict -1` | windowed (512 KiB), FCS flag 2 | Treeless (block 0), Raw (blocks 1-4, no literals) | block 0 FSE ×3, blocks 1-4 Predefined ×3 (nbSeq 32-111) |
| the same 735-B sample, `zstd -D dict -19` | single-segment | **Raw** | **Predefined/Predefined/FSE** — at `-19` the cost path (`strategy >= ZSTD_lazy`) recomputes and the dictionary's tables lost the race |

The level-1 class (the M5 encoder's parity target) is therefore:
Treeless literals whenever the literals clear the 6-literal floor and the
dictionary's tree is valid; Repeat on all three alphabets while
`repeat_valid` and nbSeq < 1000; FSE above 1000; the RLE/Predefined corners
unchanged. The parity target for the encoder-with-dictionary lane is
**`zstd -D dict -1`** (the M5 no-dictionary target was `zstd -1`;
with-dictionary parity is a new target, not an extension of the old one —
the fill-density question in §3.2 makes it the oracle lane's first job).

## 4. The zlib preset dictionary (`rfc1950-zlib.txt §2.2`, `§2.3`) — the small piece

zlib dictionaries are not a file format: "The dictionary is a sequence of
bytes which are initially fed to the compressor without producing any
compressed output. DICT is the Adler-32 checksum of this sequence of bytes
... The decompressor can use this identifier to determine which dictionary
has been used by the compressor" (`rfc1950-zlib.txt §2.2`, FDICT). The
container carries the flag and the ID; the bytes are out of band, exactly
like zstd's content-only form.

The wire and behavior, all verified live through python3 zlib (zlib 1.3.2,
the C lineage):

- **FDICT** (FLG bit 5) set; the FCHECK arithmetic still holds (verified:
  CMF 0x78, FLG 0xbb, `(CMF<<8|FLG) % 31 == 0`).
- **DICTID**: 4 bytes, big-endian ("MSB order" — `putShortMSB`,
  `deflate.c`), the Adler-32 of the *whole* dictionary, written at the
  first `deflate()` call: "if (s->strstart != 0) header |= PRESET_DICT" then
  the two saved Adler-16 halves (`deflate.c`, `deflate()`'s INIT_STATE
  block). Verified: DICTID == `zlib.adler32(dict)` exactly.
- **The window**: deflate's own 32-KiB window ("up to 32K", `rfc1950-zlib.txt`
  §2.2 CM; `rfc1951-deflate.txt` §2: "up to 32K input bytes
  before"). A dictionary longer than 32 KiB is cut to its **last** 32 KiB for
  the window, while the DICTID still names the whole thing:
  `deflateSetDictionary` computes the Adler first, then "if dictionary
  would fill window, just replace the history ... dictionary +=
  dictLength - s->w_size; /* use the tail */" (`deflate.c`,
  `deflateSetDictionary`). So the *decoder* must be given the full bytes
  (for the ID check) even though only the tail is ever matchable —
  verified: a 40-KiB dictionary round-trips with the full 40 KiB
  supplied, and fails with the last 32 KiB alone.
- **Decoding**: the C's inflate returns `Z_NEED_DICT` after the FDICT
  header; the application supplies the dictionary (`inflateSetDictionary`,
  which re-computes the Adler and compares it with DICTID). Verified
  through python3: the right dictionary decodes; no dictionary fails
  `Error 2` ("need dictionary"); a wrong or truncated dictionary fails
  `Error -3 while setting zdict: invalid input data` — the ID compare,
  before any deflate data is read.
- **Compliance** (`rfc1950-zlib.txt` §2.3): "A compliant decompressor must
  give an error indication if FDICT is set and DICTID is not the
  identifier of a known preset dictionary." Our M3 stance (the
  `DictionaryRequired` refusal, `src/zlib/AGENTS.md`: FDICT rejected at the
  header "for 'no dictionary' and 'wrong dictionary' alike") satisfies
  this today; with dictionaries supported the two cases become distinct
  names (§7).
- **The trailer**: ADLER32 covers the output "excluding any dictionary
  data" (`rfc1950-zlib.txt` §2.2, ADLER32) — the dictionary bytes never enter the
  checksum, verified by the round trips.

**The encoder's hash pre-fill is the encoder's choice, not the format's**
(the task's own framing, confirmed by the references): the C inserts
*every* position of the (cut) dictionary into its hash chains regardless
of level (`deflateSetDictionary`'s insert loop); Go's `compress/flate`
copies the dictionary into the window but **skips the pre-hash entirely at
level 1** — `fillWindow`: "Do not fill window if we are in store-only
mode. if d.compressionLevel.level < 2 { return }"
(`~/code/golang/go/src/compress/flate/deflate.go:181-185`), and
`NewWriterDict` is the only dictionary entry point (`deflate.go:671-683`).
Our encoder is the klauspost level-1 lineage (a single-slot table, no
chains): pre-filling the table with dictionary positions is the natural
port (the C's insert-every-position collapsed to last-writer-wins), and
the flate oracle is round-trip conformance, not byte-parity
(`scripts/flate_oracle.py` checks both directions' decodes, never
encoder-byte equality) — so the pre-fill choice is a ratio/speed decision
measured by the fleet, not a conformance question. Recorded as an open
question for the slice (§10, DQ6).

**flate's kernel needs two things** (the flate-notes' OQ6 deferral
resolved by this milestone): a preset-history entry point on decode —
the window's bytes pre-seeded in front of the output, exactly the RFC 1951
§3.2.3 parenthetical ("a distance can refer to that part of the output
stream anyway") — and the encoder's optional pre-fill. The decode side
is one region-splice: our `flate` decode's history is `target` (one-shot)
or the `Reader`'s 64-KiB window buffer; the dictionary rides in front as
caller memory, the same two-region shape as zstd's content (§2.2), minus
every complication zstd has: no entropy tables, no repcodes, no ID
arithmetic beyond one Adler-32 compare, no expiry rule (the window is
fixed 32 KiB and the dictionary *is* the window's oldest bytes — once the
output passes 32 KiB the dictionary has slid out, which the existing
distance-bound check already refuses).

## 5. The negatives, recorded so the plan does not ask again

### 5.1 gzip

RFC 1952 has no dictionary concept: the member header (`§2.3`) has no
FDICT-equivalent field, and the container carries raw deflate only. There
is no place to declare a dictionary, so a gzip member cannot depend on
one. The container-notes' zlib-in-gzip observation holds by construction:
a zlib stream (with its FDICT) is a different container, never the payload
of a gzip member. **No dictionary surface in `zcompress.gzip`, ever.** The
one real-world thing this kills is "gzip with a preset dictionary" —
nobody can express it; callers wanting a dictionary with the gzip shape
use the zlib container or raw flate.

### 5.2 brotli

RFC 7932's dictionary is *built in* and already shipped: the 122,784-byte
static dictionary plus the 121 transforms, distance space with no header
bit and no opt-in (`src/brotli/AGENTS.md`: "The dictionary ships
unconditionally (OQ1)"). The RFC has **no custom-dictionary concept at
all** — a full-text search of the vendored `rfc7932-brotli.txt` finds the
word "dictionary" only in the static-dictionary sense (§8, Appendix A/B,
and the distance/command references to them). The custom dictionary is a
C-library extension: `BrotliDecoderAttachDictionary` with a
`BrotliSharedDictionaryType` (`c/include/brotli/decode.h:176-181`, the
v1.2.0 checkout) — whose serialized form is marked "DO NOT USE: methods
accepting this value will fail" (`c/include/brotli/
shared_dictionary.h:41-49`), leaving the **raw LZ77 prefix** as the only
attachable kind, plus the encoder's `BrotliEncoderAttachPreparedDictionary`.
The brotli CLI 1.2.0 exposes it: `-D FILE, --dictionary=FILE  use FILE as
raw (LZ77) dictionary` (`c/tools/brotli.c:763`). Verified live, this
session: `brotli -q 11 -D dict src` encodes (283 B), decodes with `-D`
cleanly, fails exit 1 without it — and **our decoder refuses it
naturally** (`just example brotli decode` → `error: ReadFailed`; the
block-layer name per the M6 register: the backward references fall before
the stream start) — exactly the recorded position: "a `-D`-encoded stream
is not an RFC 7932 stream, and its distances fall past the dictionary
space and fail naturally (`BadDictionary`/`BadDistance`), so no dedicated
refusal surface is needed" (`src/brotli/AGENTS.md`, "Extensions are out of
scope (OQ7, T3)"; `brotli-notes.md` §7 OQ7).

**Recommendation: no brotli dictionary API.** The mechanism (a raw LZ77
prefix) is the same as zlib's preset dictionary and would be cheap to add
to a *decoder* the day a use case lands, but the use case is absent: the
format does not standardize it, the two other reference decoders on this
box (andybalholm/brotli Go — the M6 oracle — and std) have no reason to
produce such streams, and our decoder already fails them with the correct
class. The oracle's references don't exercise it (the M6 lane never
touched `-D`); adding an API no oracle can pin is a surface with no
conformance story. Revisit only if a real corpus of `-D`-encoded brotli
appears — the same condition the flate OQ6 deferral used.

## 6. Requirements matrices

### 6.1 zstd decode-with-dictionary (the `DD` rows)

| # | requirement | cite |
|---|---|---|
| DD1 | Accept a formatted dictionary: magic 0xEC30A437 LE, ID, the entropy tables, 12 repcode bytes, content — reject each malformed piece with a named error | `rfc8878-zstd.txt §5` |
| DD2 | The entropy tables are the compressed-block forms, in the order literals-Huffman, offsets-FSE, match-lengths-FSE, literal-lengths-FSE | `§5` |
| DD3 | The Huffman description follows `§4.2.1.1`/`§4.2.1.2` (accuracy ≤ 6, max code length 11, the implied last weight) — the landed `huff0.readTree` unchanged | `§5`, `§4.2.1` |
| DD4 | The three FSE descriptions follow `§4.1.1`; accuracy caps 8/9/9; max symbol values 31/52/35 | `§5`, `§3.1.1.3.2.1`, `zstd_decompress.c:1482-1524` |
| DD5 | The 12 repcode bytes: each nonzero and ≤ the content size; they seed the repeat offsets in place of {1,4,8} | `§5`, `§3.1.1.5`, `zstd_decompress.c:1526-1534` |
| DD6 | The content is preset history: while the frame's decoded total ≤ Window_Size, offsets may reach the whole dictionary (beyond Window_Size); after, the dictionary is inaccessible | `§5` |
| DD7 | Treeless literals and Repeat sequences are legal from the frame's first block when the dictionary's tables are loaded | `§3.1.1.3.1.1`, `§3.1.1.3.2.1`, `zstd_decompress.c:1554` |
| DD8 | Raw-content dictionaries (≥ 8 bytes, format-free) are content-only: no tables, default {1,4,8} seeds, no ID | `§5`, `zstd_decompress.c:1540-1545` |
| DD9 | A frame whose DID is nonzero errors when the supplied dictionary's ID does not match (DictionaryMismatch); with no dictionary supplied it errors DictionaryRequired before any body byte (the M4 posture, unchanged) | `§2`, `§3.1.1.1.3`, `zstd_decompress.c:716-719` |
| DD10 | A DID-flag-0 frame decodes with or without a supplied dictionary; a supplied dictionary's tables seed the state regardless of the frame's DID | `§3.1.1.1.1.6`, `zstd_decompress.c:716-719` (the `fParams.dictID &&` guard) |
| DD11 | Accept incomplete statistics (zero weights, zero-probability symbols, tables short of the alphabet max) — legal dictionaries, unpromotable only | issue #3724's fix; `zero-weight-dict`, `http-dict-missing-symbols` |
| DD12 | The dictionary parse is setup work: tables built once, content referenced zero-copy, nothing re-parsed per frame or block | the house rule (`AGENTS.md`, "Rules"); `ZSTD_DDict` |

### 6.2 zstd encode-with-dictionary (the `DE` rows)

| # | requirement | cite |
|---|---|---|
| DE1 | Parse the same dictionary bytes into the encode-side tables with the same validation as DD1-DD5 | `zstd_compress.c:5061-5165` |
| DE2 | Promote the literals tree to repeat-valid only on 256 symbols with no zero weights; each FSE table only on full coverage with no zero counts; else check (unusable at the fast level) | `zstd_compress.c:5071-5079,5109,5123,5140`, `:5047-5059` |
| DE3 | The offsets table must represent every offset up to dictContentSize + 128 KiB | `zstd_compress.c:5134-5140` |
| DE4 | Seed the repcodes from the dictionary's 12 bytes | `§3.1.1.5`, `zstd_compress.c:5127-5129` |
| DE5 | The dictionary content is matchable history: candidates from it verified against the dictionary region; the emitted offsets legal under the window rule | `§5`, `zstd_compress.c:4898-5038` |
| DE6 | Stop matching into the dictionary after the output passes Window_Size (the streaming form; the one-shot's window covers source + dictionary by construction) | `§5`, `zstd_compress_internal.h:1100-1145` |
| DE7 | Size the level's window and class from srcSize + dictContentSize | `zstd_compress.c:7734-7748,1431-1447,1550-1561` |
| DE8 | Write the Dictionary_ID field when a dictionary is used (the 1/2/4-byte forms); `--no-dictID` suppression is a knob, never the default | `§3.1.1.1.1.6`, `zstd_compress.c:4695-4749` |
| DE9 | The with-dictionary byte class at level 1: Treeless literals from the 6-literal floor; Repeat on all alphabets while valid and nbSeq < 1000; FSE above; RLE/Predefined corners unchanged | `zstd_compress_sequences.c:158-235`, `zstd_compress_literals.c:114-127`; §3.5, verified live |
| DE10 | The fast-level ladder consults a check-state table never; a valid-state table always (below 1,000 sequences) | issue #3724 (terrelln); `zstd_compress_sequences.c:187-191` |
| DE11 | Every frame emitted with a dictionary decodes through the CLI's `-D`, klauspost's `WithDecoderDicts`, and this package's decoder | the oracle contract (§8) |

### 6.3 zlib preset dictionaries (the `ZL` rows)

| # | requirement | cite |
|---|---|---|
| ZL1 | FDICT set with DICTID = Adler-32 of the whole dictionary, big-endian, when the encoder is given one; never otherwise | `rfc1950-zlib.txt` §2.2, `deflate.c` (`deflate()` INIT_STATE, `deflateSetDictionary`) |
| ZL2 | A dictionary longer than 32 KiB contributes only its last 32 KiB to the window; the DICTID still names the whole | `deflate.c` (`deflateSetDictionary`'s "use the tail"); verified live |
| ZL3 | Decode: FDICT set and no dictionary supplied → error before any deflate data (DictionaryRequired, the M3 name); a dictionary whose Adler-32 ≠ DICTID → error at the compare (a distinct name, §7) | `rfc1950-zlib.txt` §2.3, §4 (verified live through python3 this session) |
| ZL4 | The dictionary is preset history for raw deflate: distances may reach into it; it slides out of the 32-KiB window naturally | `rfc1951-deflate.txt` §2, `§3.2.3` |
| ZL5 | ADLER32 covers the output excluding the dictionary | `rfc1950-zlib.txt` §2.2 (ADLER32) |
| ZL6 | The flate kernel's preset entry: the decode's history region gains a caller-owned prefix; the encoder's pre-fill is a measured choice, not a conformance duty | `rfc1951-deflate.txt §3.2.3`; §4, DQ6 |

## 7. The API sketch options — the Matt decision points

House constraints applied throughout (`AGENTS.md`, "Rules"): the barrel
exposes exactly `{Reader, Writer, encode, decode}` per codec namespace and
everything else composes inside it; exact-pointer buffer types; no heap on
hot paths, setup allocation documented at the API; README-first (each
codec's README gains the dictionary sketch before implementation).

### DQ1 — the zstd parse surface: a `Dictionary` type vs an init-time option

*Options*:
(a) **A `zstd.Dictionary` type** — `Dictionary.parse(source) !Dictionary`
   (the formatted form) and `Dictionary.initRaw(content) Dictionary`, the
   value holding `id`, the decode-side tables (3 × `fse.Table` + the
   literals tree/table), the encode-side tables (3 × `fse_compress.Table` +
   the encode tree), the repcodes, and `content: []const u8` — zero-copy
   over the caller's dictionary file, comptime-sized arrays throughout
   (roughly 20-30 KiB of tables; the exact figure is a slice-time fact for
   the README). The entry points take `dict: ?*const Dictionary`.
(b) **Init-time bytes** — `decode.decompress(source, target, dict_bytes)` with
   the parse inside every call: no new type, but a multi-frame decode
   re-parses per frame and the parse/build work has no home.
(c) **A State-prep function** — `decode.loadDictionary(state, bytes)` plus
   the existing calls: the C's `ZSTD_DCtx_loadDictionary` shape, but it
   exposes the internal `State` the one-shot currently owns.

*Recommendation*: (a). It is the C's own `ZSTD_DDict`/`ZSTD_CDict` shape
(parse once, reuse across frames — the reason those types exist), it is
klauspost's `dict` struct exactly (`zstd/dict.go:11-19`), and it fits the
house rules without any new buffer type: the `Dictionary` is a caller-owned
value like the `Buffer`s, documented in the README's usage with its size.
(b) fails the reuse case every real caller has (decode a shard set with one
dictionary); (c) breaks the one-shot's encapsulation for no gain.

### DQ2 — the exact decode call shape

*Options*:
(a) `decode.decompress(source, target, dict: ?*const Dictionary)` — the
   third parameter, `null` meaning today's behavior. Every existing call
   gains `, null` (a breaking change, caught at compile time).
(b) A separate `decode.decompressDict(source, target, dict)` alongside the
   two-argument form.
(c) An options struct on decode (`decode.Options { dict }`) — the encode
   side already has one; the decode side never needed one.

*Recommendation*: (a) for the one-shot and `Reader.init`'s parameter list
(the streaming reader gains the same fourth parameter) — one form, no
duplicate names, the optional pointer reads naturally, and the callsite
migration is mechanical and compile-checked. (b) doubles the surface for
the same machinery (the barrel rule prefers composition over name
proliferation); (c) is heavier than a single optional pointer today and
still needs the streaming form decided separately. This is the exact
"Matt question" the task names — the decision point for the parent.

### DQ3 — the encode call shape

`encode.Options` already exists (`Options = struct { level: Level =
.fast }`): it gains `dict: ?*const Dictionary = null`. No new function, no
new name; `Writer.init` and the `streamAll` pumps thread it through the
options they already take. The parity target is `zstd -D -1` (§3.5).

### DQ4 — the error names

The M4 error set gains one name: `DictionaryMismatch` (DD9 — the
dictionary is supplied but its ID does not match the frame's DID). The
comptime-pinned error sets (`decode.zig`, `Reader.zig`) fail the build
until both lists and the README's list are updated — the designed forcing
function (`src/zstd/AGENTS.md`, "One error name per corruption class").
`DictionaryRequired` keeps its current meaning (no dictionary supplied).
The zlib container gains the same distinction: `DictionaryRequired`
(FDICT set, nothing supplied) vs `DictionaryMismatch` (a dictionary
supplied whose Adler-32 ≠ DICTID) — the two cases the M3 register
deliberately collapsed ("no dictionary and wrong dictionary alike") split
the moment the second becomes actionable.

### DQ5 — the zlib surface

The dictionary is raw bytes: `dict: ?[]const u8` at `zlib.decode.decompress`,
`zlib.Reader.init`, and `zlib.encode.Options` (no `Dictionary` type — there
is nothing to parse; the Adler-32 compare is one line at the header, and the
flate kernel takes the same slice as preset history). The flate kernel
itself gains the preset-history entry point (the internal seam the
zlib container drives; not exposed at `zcompress.flate`'s barrel — a
preset dictionary on *raw* flate is expressible but has no container to
name it, and the README documents the flate functions' new optional
parameter instead of a new name).

### DQ6 — the flate encoder's pre-fill (a measured choice, not a conformance duty)

The C inserts every dictionary position into its chains at every level;
Go's level-1 skips the pre-hash entirely (§4). Our single-slot table's
options: pre-fill every dictionary position (the C collapsed to
last-writer-wins — the most candidates), every 3rd (the zstd CCtx
density), or none (Go's level-1 — the dictionary is then only rep-window
history). The flate oracle is round-trip conformance, so this is a
ratio/speed decision: the slice measures the variants on the fleet
corpus and keeps the winner, the way the checksum interleave was decided
(`src/zstd/AGENTS.md`, the raw-block 4-KiB fold).

### DQ7 — what the trainer question gets (a row, not a milestone)

Consuming is the requirement; training is not. The CLI trains (verified:
two dictionaries this session), klauspost ships a Go trainer
(`BuildDict`) for the reading, and an in-repo trainer would be a new
algorithm with its own oracle problem (nothing to differentially verify
against except the CLI's own output, which the COVER-family does not
reproduce byte-exactly — its parameters are search-tuned). The milestone
row (§11) carries dictionaries-as-input only; a trainer, if ever wanted,
is a separate follow-up with its own research file.

## 8. The oracle resources (every lane shape, verified where runnable now)

- **The training set**: `zstd --train -r <dir> -o dict.bin` over the fleet
  corpus shapes (the `just corpus` generator produces the sample set;
  this session used 24 seeded text samples). The trainer is the CLI
  v1.5.7 itself — no external dependency. The dict files and the
  CLI-generated dict frames become `golden.zig` fixtures with the CLI's
  verdict recorded beside each (the M4 fixture rule).
- **The decode-with-dictionary differential lane** (lands first): our
  decode of CLI `-D` frames vs the CLI's `zstd -D dict -d` (byte-exact)
  and klauspost's `WithDecoderDicts` (byte-exact), both directions — we
  compress with the CLI and decode here, and vice versa; plus the
  negative matrix (no dict, wrong dict, raw dict) against the C's own
  `cli-tests/dictionaries/dictionary-mismatch.sh` behaviors; plus the
  hand-built frames for the §2.2 window corners (the T12 methodology:
  a small window, a dictionary reach before and after the boundary —
  settle DT1's rule with the CLI's verdict recorded, ours fail-closed).
- **The encode-with-dictionary parity lane**: the parity target is
  `zstd -D dict -1` byte-for-byte on the corpus shapes (the M5 target
  was `zstd -1`; §3.5 records the class). The fill-density question
  (§3.2: dtlm_fast vs dtlm_full vs klauspost's every-2nd) is decided by
  whichever reproduces the CLI's bytes — the CLI's `-D` path is
  dtlm_full, so that is the first candidate. `zstd -t` and our own
  decoder verify every frame; the `-19` class (§3.5's last row) is out of
  scope for the fast level, as the no-dictionary `-19` class was.
- **The zlib lane**: `zlib.compressobj(..., zdict=...)` / `zlib
  .decompressobj(..., zdict=...)` rows added to the flate/zlib oracle
  scripts — the four mismatch cases verified live here (§4) become the
  error-name pins.
- **The fixture inventory** (licenses: facebook/zstd dual BSD-3/GPL-2,
  data fixtures unrestricted; klauspost BSD-3; Go BSD-3):
  - facebook/zstd `tests/golden-dictionaries/http-dict-missing-symbols`
    (1,000 B) and `tests/dict-files/zero-weight-dict` (153 B) — the two
    incomplete-statistics dictionaries, both round-tripping through the
    CLI (§1.1 fact 3): the parse-side goldens for DD11, and the
    promotion-side pins for DE2.
  - facebook/zstd `tests/cli-tests/dictionaries/` — the C's own CLI
    conformance scripts (`golden.sh`, `dictionary-mismatch.sh` with its
    `.stderr.exact`): the exact error-message pins for the lane.
  - facebook/zstd `tests/invalidDictionaries.c`, `bigdict.c`,
    `largeDictionary.c` — the dict-parse fuzz vectors and the large-dict
    generators; `tests/fuzz/dictionary_{decompress,loader,
    round_trip,stream_round_trip}.c`, `raw_dictionary_round_trip.c` —
    the reference's own fuzz-target shapes for our fuzz lane to mirror.
  - klauspost `zstd/testdata/dict-tests-small.zip` (627 KB) — a corpus of
    dict-compressed files with their dictionaries (their
    `TestDecoder_SmallDict` is the round-trip lane); `zstd/dict_test.go`
    is the conformance test to port fixtures from.
  - Go `compress/flate`'s `dict_decoder.go` + `dict_decoder_test.go` —
    the sliding-window preset-dictionary reference (the M2 flate-notes
    already inventoried them as "preset dictionaries — out of scope for
    M2, revisit with T2"; this is the revisit).
- **The competitor inventory** (what each arm's numbers mean): the C
  v1.5.7 (the `ZSTD_DDict`/`ZSTD_CDict` precomputed-table path —
  `ZSTD_getDictID_fromDDict`, the cold/hot dictionary tracking at
  `zstd_decompress.c:1604-1612` — the native ceiling for
  dictionary decode; note its CLI decode is the streaming path, so the
  one-shot `ZSTD_decompress_usingDict` and the CLI differ on the DT1
  corner), klauspost (the class target: `WithDecoderDicts`' map-based
  selection at `decoder.go:933-948`, the retained `dictTable` on encode
  — the arm our one-shot races), std (no dictionary support at all —
  `DictionaryIdFlagUnsupported`, the T11 divergence; it stays a decode
  datapoint only). zlib: the C's inflate/deflate dictionary paths through
  python3 (the oracle) and the box's zlib-ng (the fleet arm; its
  `deflateSetDictionary` semantics are the C's).

## 9. The divergence register (decisions for the parent, never silent picks)

- **DT1 — the dictionary-expiry boundary is not enforced as written.**
  `§5`'s rule (the dictionary is inaccessible once the output passes
  Window_Size) is enforced by no reference exactly: the C's whole-buffer
  decoder accepts dictionary reaches with no Window_Size test
  (`zstd_decompress_block.c:930-933`, the T12 class), and the streaming
  decoder ends dictionary access by buffer adjacency, not the boundary.
  *Decision for the parent*: enforce the RFC's boundary (fail-closed, the
  T12 posture — `OffsetTooFar` at the reach) with the references'
  leniencies recorded, and pin it with hand-built frames the way T12's
  `frame_window_*` pair did. The oracle lane owns the fixture.
- **DT2 — "less than the dictionary size".** `§5` says each repeat offset
  "must have a value less than the dictionary size"; both references
  enforce `rep <= dictContentSize` — the *content* size (`zstd_decompress
  .c:1529-1532`, `zstd_compress.c:5145-5146`, klauspost `dict.go:118-121`).
  A repcode equal to the content size is accepted by all three; a repcode
  between the content size and the whole-file size is rejected by all
  three. *Decision*: follow the references (≤ content size); the RFC's
  "dictionary size" reads as the content, which is the only consistent
  reading with the trainer's own outputs. Not a real ambiguity — recorded
  because the RFC's word is "dictionary" and the enforcement is
  "content".
- **DT3 — the reserved dictionary-ID ranges.** `§3.1.1.1.3`/"§5": reserved
  IDs "shall not be used" for public distribution and referencing an
  unregistered reserved ID "results in an error". The C does not enforce
  either (verified live: `--dictID=100` trains, compresses, and decodes
  cleanly through the CLI; the trainer's `compliantID` merely *defaults*
  into the private range); klauspost likewise checks only its map. A
  decoder cannot know the IANA registry. *Decision*: accept any ID when
  the dictionary is supplied and matches (the references' behavior); the
  reserved-range rule is a *producer* concern our encoder honors by
  never choosing one itself. Recorded, not enforced.
- **DT4 — a formatted dictionary with ID 0.** The RFC: the ID is "any
  value, except 0". klauspost rejects it at parse ("dictionaries cannot
  have ID 0", `dict.go:51-53`); the C's loaders read the field with no
  zero check (`zstd_decompress.c:1546` — a zero-ID dictionary loads, and
  then only DID-0 frames pass the §2.3 check). *Decision*: fail closed —
  reject ID 0 at `Dictionary.parse` (the RFC's rule), a named
  `InvalidDictionaryId`-class error; the C's leniency is recorded. This
  is the FDICT-class stance (the RFC names the invalid value; the house
  refuses it).
- **DT5 — klauspost assigns IDs to raw dictionaries.** klauspost's
  `WithDecoderDictRaw(id, content)` assigns an caller-chosen ID to raw
  content so a DID frame can select it (their `--patch-from` comment);
  the C has no such concept — a raw dictionary has no ID and never
  satisfies a DID frame. *Decision*: follow the C (`initRaw` takes no ID);
  klauspost's shape is a Go-ergonomics feature, recorded.
- **DT6 — the v1.5.5-and-earlier incompatibility.** The C v1.5.5- errored
  `dictionary_corrupted` on incomplete literals statistics (issue #3724;
  §1.3). Our parse must accept them (DD11) — the v1.5.6+ behavior, and the
  RFC imposes no completeness rule. Recorded as the format's one real
  versioning seam: a consumer targeting "every trainer output ever" needs
  both the complete and the incomplete kinds, and ours does.
- **DT7 — Go's flate level-1 skips the dictionary pre-hash.** The C
  inserts every position at every level; Go's `fillWindow` returns for
  `level < 2` (§4). Our encoder's lineage is Go's; our oracle is the C's
  (python3 zlib). *Decision*: not a conformance question (the flate
  oracle is round-trip), a DQ6 measurement. Recorded so the slice does
  not mistake the lineage's behavior for the requirement.
- **DT8 — the C's CLI decode vs its one-shot on dictionary frames.** The
  CLI's `-d` runs the streaming decoder, whose dictionary access ends by
  buffer adjacency; the one-shot `ZSTD_decompress_usingDict` keeps the
  dictionary referenced for the whole output. A hand-built late-reach
  frame can therefore decode through one C path and fail through the
  other — the oracle lane must record which C it cites on the DT1
  fixtures (the M4 lesson: name the oracle's exact path, as
  `zstd-notes.md` T12 recorded "the pinned CLI v1.5.7").

## 10. The DQ register (§7) and the ranked ambiguities

The design questions are §7's DQ1-DQ7; the ranking of what gates the
README sketches:

1. **DQ1 + DQ2 — the `Dictionary` type and the exact decode call shape.**
   The parent's two calls before any sketch is written: the parse-once
   type (recommended (a)) and the `?*const Dictionary` third parameter vs
   the alternatives. Everything downstream (the Reader's parameter list,
   the golden fixtures' helpers, the example CLI's flags) hangs on it.
2. **DT1 — the expiry boundary.** The one decode-side rule the references
   do not pin; it decides a `sequences`-layer signature (the two-region
   history) and a fixture class before the first slice lands.
3. **DQ4 — the error names.** `DictionaryMismatch` joins two error sets
   (zstd decode, zlib) — cheap now, expensive after the READMEs are
   reviewed; decide with the sketches.
4. **DQ3 + DQ5 — the encode options and the zlib slice.** Mechanical once
   DQ1/DQ2 are settled; the zlib piece is small enough to sketch in the
   same pass (its only open choice is DQ6's measurement).
5. **DQ7 — the trainer row.** Nothing; it stays out of the milestone.

## 11. The milestone row draft (for `docs/zcompress-plan.md`)

The row, in the M6 style; the slice order is the evidence's ranking —
decode-with-dict first (the parsers are landed and verified against the
CLI's own dictionaries; every dictionary user needs it; the risk is one
window rule the oracle pins), encode-with-dict second (the bigger lift:
the match region, the promotion seats, the parity target), the zlib
preset third (the small piece, both directions, one kernel seam):

> M7 — dictionaries, consume-first. zstd dictionaries (RFC 8878 §5) — the
> formatted dictionary parsed at setup (`zstd.Dictionary`, zero-copy over
> the caller's file bytes) and handed to the decoder (the seeded entropy
> tables and repcodes, the content as preset history) and the encoder
> (`encode.Options.dict`, the `repeat_valid` seats the M5 register
> recorded, the parity target `zstd -D -1`) — then the zlib preset
> dictionary (RFC 1950 §2.2 FDICT + the 32-KiB flate preset window, both
> directions, `dict: ?[]const u8`). gzip gains nothing (RFC 1952 has no
> dictionary concept) and brotli gains nothing (the static dictionary
> already ships; the custom-dictionary path is an extension surface the
> decoder refuses naturally) — both negatives recorded in the research.
> Training is not a dependency: the dictionary file is an input; the
> `zstd` CLI trains (`--train`, fastCover, verified).
> The research is `docs/research/dictionary-notes.md` (the `DD`/`DE`/`ZL`
> matrices, the `DT` divergence rows, the `DQ` register with the API
> sketch options and recommendations); the API sketches are the
> dictionary sections of `src/zstd/README.md` and `src/zlib/README.md`,
> written first, with the `zstd.Dictionary` type and the exact call
> shapes (DQ1/DQ2) the review's decision points.
> Acceptance: `just test` and `just lint` green; the zstd dictionary
> oracle lane green (decode: the CLI-trained dictionaries round-trip
> byte-exact both directions against the CLI's `-D` and klauspost's
> `WithDecoderDicts`, the mismatch matrix against the C's own
> `cli-tests/dictionaries` pins, the incomplete-statistics fixtures
> (`zero-weight-dict`, `http-dict-missing-symbols`) accepted, the
> expiry-boundary fixtures pinned with the CLI's verdicts recorded;
> encode: `zstd -D dict -1` byte-parity on the corpus shapes and the
> `-D` frames' decode through the CLI and this decoder); the zlib
> dictionary rows green in the zlib and flate oracle lanes (the four
> mismatch cases from the research as the error-name pins);
> `just check-baseline` green; the fuzz wave's dictionary targets
> (the C's `dictionary_*` fuzz shapes: parse, decode, round trip, raw
> round trip); a fleet run committed with the dictionary rows (the
> trained-dictionary corpus shapes, decode and encode arms); the closing
> review's blockers fixed and pinned by tests.

The plan's "Decisions deferred" list retires one row with this milestone:
"flate preset dictionaries (OQ6): deferred; the decoder surface does not
preclude a dictionary entry point later" — M7 is the later.
