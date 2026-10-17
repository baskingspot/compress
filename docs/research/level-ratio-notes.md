# Level.ratio research notes

The research stage of the `.ratio` seat: the two encoder upgrades that fill
the level enums the API sketches reserved (`docs/compress-plan.md`,
"Decisions deferred": "`Level.ratio` reserves the seat with
`error.Unimplemented`, never silent aliasing"). One file, both codecs,
because the two seats ask the same three questions and answer them
differently: what the ratio class costs, whether the pin is byte parity or
a valid-stream class, and how many slices the work is.

The standing decisions this file extends, none reopened here:

- **flate `.fast`** is a klauspost level-1-class greedy finder that emits
  **fixed-Huffman or stored blocks only** (`src/flate/README.md`,
  "Limitations": "No dynamic-Huffman encoder … `Level.ratio` is reserved
  for one"). The plan's OQ1 defers the dynamic mode until "the fast path
  wins".
- **zstd `.fast`** is byte-identical to the pinned CLI's `zstd -1`
  (`src/zstd/README.md`, "Emission": "the whole frame reproduces the
  pinned CLI v1.5.7's `zstd -1` bytes on the corpus shapes"). `.ratio` is
  reserved (`zstd.encode.Level = enum { fast, ratio }`).
- The house parity rule is per-codec asymmetric already: zstd `-1` is a byte
  pin; flate `.fast` is a **class** pin (no reference emits fixed-Huffman
  deflate, so there is nothing to be byte-identical to; the golden corpus
  pins decode compatibility, `src/flate/golden.zig`'s provenance header).

Every measured number below was produced this session by the pinned
references (§0); local speed numbers are never performance claims — a claim
cites a fleet run in `docs/results/`.

## 0. Provenance

- Specs (vendored verbatim, provenance in `docs/research/specs/README.md`):
  `rfc1951-deflate.txt` §3.2.2 (the canonical code-length rules),
  §3.2.3 (block header, BFINAL/BTYPE), §3.2.4 (stored blocks),
  §3.2.6 (fixed Huffman), §3.2.7 (dynamic Huffman: HLIT/HDIST/HCLEN, the
  code-length alphabet, the 16/17/18 run codes, the HCLEN order, the
  single-sequence rule, the one-distance-code case), §3.3 (Compliance:
  a compressor may limit ranges further); `rfc8878-zstd.txt` §3.1.1.1.2
  (Window_Descriptor), §3.1.1.3 (blocks and sections) — the entropy layers
  the ratio class shares unchanged.
- Reference implementations read (cited inline as `path:line`, relative to
  the source root named here): facebook/zstd **v1.5.7**, vendored in-repo at
  `bench/zig-out/bench-src/zstd/` (dual BSD-3-Clause/GPL-2.0; verified
  present, `lib/compress/clevels.h` matches the pinned CLI's reported
  cParams, §2.1); klauspost/compress at **v1.18.1-0.20250402062133-8df4d013ff17**
  (BSD-3-Clause) — the module pin the oracle and bench driver use
  (`scripts/zstd_klauspost/go.mod`), read from the module cache at
  `~/go/pkg/mod/github.com/klauspost/compress@v1.18.1-…/flate/`;
  Go stdlib `compress/flate` from the flake's **go1.26.8**
  (`$(go env GOROOT)/src/compress/flate/`); zlib semantics via CPython
  **3.14.7**'s `zlib` **1.3.2** and the GNU **gzip 1.14** CLI from the
  flake. Nothing was fetched: every source was already on the box.
- Oracles and measurements run for this file (every number below was
  executed before being written): the zstd CLI v1.5.7 and gzip 1.14 over
  the 15 oracle-class shapes (the `scripts/oracle_common.py` shapes plus
  the zstd oracle's non-ASCII, 520-KiB-period, mixed-binary, RFC-text, and
  repo-prose rows, plus the corpus-gen prose/words/html/skewlit 64-KiB
  shapes) — every zstd level 1-2-3-4-5-6-7-9-12-13-16-19 and gzip level
  1-6-7-8-9, **run twice per cell**; the threading matrix (default vs
  `--single-thread` vs `-T2`, file form vs pipe form) at -1/-3/-6/-19;
  a 10-MiB extension crossing every level's job size; our decoders over
  every CLI output (the `zstd-oracle` harness's `decode`, the example CLI's
  gzip `decode`); our encoders' sizes (the harness's `encode-oneshot`, the
  example CLI's gzip `encode`); the klauspost and Go stdlib flate ladders
  levels 1-9, run twice, through a scratch Go program over the same shapes;
  and `zstd --show-default-cparams` as an independent check of the level
  table read from `clevels.h`.
- Scratch: `/tmp/level-ratio-research/` (the shapes ~7 MB, the scripts
  `measure.py`, `goflate/`, `goflate/tgo/`, and the result JSONs, under
  10 MB total). The parent deletes the tree at this seat's close.
- Negative finding, recorded so the plan never asks again: **`gen_static_lit_times.gz`
  does not exist** in the pinned klauspost source (searched the module
  cache's six cached versions, v1.18.1-… through v1.20.1, and the flate
  package's `_gen/`): no generated static-literal table backs the flate
  cost model. The mechanism that actually decides fixed-vs-dynamic-vs-stored
  is the size arithmetic in `huffman_bit_writer.go` (`fixedSize`,
  `dynamicSize`, `storedSize`, `extraBitSize`, §1.2) — that is what a port
  pins, and it is small.

## 1. flate's ratio path

> **Superseded 2026-10-17.** The class-pin recommendation below did not
> survive review: Matt ruled flate's seat a **byte pin to klauspost's level
> 6**, and it landed as `c60a6b5` ("flate: level 6, the klauspost port,
> byte-identical at level 6") — their `fastEncL6` finder and dynamic-block
> emitter, byte-identical on the pinned module version. §1.4's LR1 (the
> dynamic emitter over our own level-1 finder) and §3.2's LR3 (a class pin,
> ratio-gated) are the superseded shapes; the measurements and port costs
> below stand as the research that preceded the ruling.

### 1.1 What the references do per level

Three references, three ladders, one emission rule. All of them emit
**dynamic Huffman blocks at every level**; no reference combines a
stronger finder with fixed-Huffman emission. The levels differ only in the
match finder:

| level | klauspost v1.18.1 (`flate/`) | Go stdlib go1.26.8 | GNU gzip 1.14 (zlib class) |
|---|---|---|---|
| 1 | `fastEncL1`: one 15-bit table, 5-byte hash, greedy (`level1.go`); the scan runs over `fastGen.hist`, the previous block's tail plus the new block, so matches reach the 32-KiB window back — the shape our port kept (`src/flate/encode.zig`, `Window`) | `deflatefast.go`: the snappy-derived 14-bit table, greedy | `deflate_fast`, good 4 / chain 4 |
| 2 | `fastEncL2`: same scan over a 17-bit table — more entries survive between blocks (`level2.go`: "capable of matching across blocks") | hash chain, **no lazy** (`deflate.go` levels table: "For levels 2-3 we don't bother trying with lazy matches") | `deflate_fast`, good 4 / chain 8 |
| 3 | `fastEncL3`: 16-bit table of `tableEntryPrev` — checks **two candidates** per hash (`level3.go`) | hash chain, no lazy, deeper | `deflate_fast`, deeper chain |
| 4 | `fastEncL4`: **two hash tables** (15-bit short, 17-bit long), greedy (`level4.go`) | lazy hash chain, good 4 | zlib's `deflate_slow` (lazy) begins |
| 5-6 | `fastEncL5`/`L6`: two tables, the long one with two candidates — still **greedy** (`level5.go`, `level6.go`) | lazy, deeper chains | lazy, deeper |
| 7-9 | Go's lazy hash chain (`deflate.go`: `{8,12,16,24}`, `{16,30,40,64}`, `{32,258,258,1024}`) | lazy, deepest | lazy, deepest |

klauspost's own table comment says why their 2-6 differ from Go's
(`deflate.go:60-62`): "Compression levels have been rebalanced from zlib
deflate defaults to give a bigger spread in speed and compression." Their
levels 1-6 are all greedy fast encoders of increasing width; lazy starts at
7. Go's stdlib keeps zlib's shape: 2-3 chain-without-lazy, 4-9 lazy.

The block emission is shared by all klauspost levels
(`deflate.go:758-767`, `storeFast`): find matches into a token list, then
per block — zero matches ⇒ stored; tokens removed less than 1/16 of the
input ⇒ a literals-only dynamic block (`writeBlockHuff`); otherwise
`writeBlockDynamic`. Go stdlib's `writeBlock` compares stored, fixed, and
dynamic sizes and picks the smallest
(`huffman_bit_writer.go:429-497`). Our `.fast` deliberately kept only the
stored and fixed rungs and writes bits **inline during the scan**
(`src/flate/encode.zig`, `encodeFixedBlock` — there is no token list
today); that is the structural fact behind the slice map (§5.1).

### 1.2 The dynamic-block work, precisely (RFC 1951 §3.2.7)

What the wire requires (all of it decode-tested already — the decoder side
of every piece below exists in `src/flate/decode.zig`):

- **Code-length sequences and their code.** The literal/length and
  distance trees are each described by a sequence of code lengths
  (0-15; a 0 excludes the symbol from the construction, §3.2.7), and the
  two sequences are compressed **as one sequence** with a Huffman code over
  the 19-symbol code-length alphabet, using 16 (repeat previous 3-6, 2
  extra bits), 17 (repeat 0, 3-10, 3 extra bits), 18 (repeat 0, 11-138,
  7 extra bits) — §3.2.7: "all code lengths form a single sequence of
  HLIT + HDIST + 258 values." The header: 5 bits HLIT (#lit/len codes −
  257), 5 bits HDIST (#distance codes − 1), 4 bits HCLEN (#code-length
  codes − 4), then (HCLEN+4)×3 bits of code-length lengths in the fixed
  order 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15.
  The one-distance-code case is special: "If only one distance code is
  used, it is encoded using one bit, not zero bits" (§3.2.7).
- **The length-limited tree construction.** §3.2.2 fixes the canonical
  code assignment (sorted by length, then by symbol); §3.2.7 caps every
  code length at 15 (the alphabet is 0-15). **The RFC mandates no
  construction algorithm** — any prefix code with lengths ≤ 15 that
  assigns every used symbol is compliant. This freedom is why the
  references' dynamic blocks differ byte-wise at the same level (§3.2),
  and it is the one requirement a first implementation can meet with
  klauspost's exact algorithm for free (it is ~200 lines,
  `huffman_code.go:bitCounts` — the level-by-level leaf-count construction
  that enforces the depth limit while building, the package-merge family,
  not a post-hoc tree rebalance).
- **The cost model.** Per block, in bits: `storedSize = (len+5)*8`;
  `fixedSize = 3 + Σ freq·fixed_len + extraBits`; `dynamicSize = header +
  Σ freq·dyn_len + extraBits`, where `extraBits` counts the length and
  distance extra-bit fields (§3.2.5's tables — already in this repo as the
  shared §3.2.5 code tables). klauspost adds two shortcuts on top
  (`huffman_bit_writer.go`): the fixed-size comparison runs only when the
  block has fewer than `maxPredefinedTokens = 250` tokens (above that a
  dynamic tree is assumed to win), and `writeBlockDynamic` may **reuse the
  previous block's tables** for the size estimate (`lastHeader`,
  `canReuse`, `dynamicReuseSize`, a `logNewTablePenalty`) — every block
  still writes its own header; reuse only avoids regenerating and can keep
  a still-good tree. The storeFast dispatch (1/16th rule) and the
  `writeBlockHuff` literals-only form complete the ladder.

### 1.3 What each step buys, measured

The ladder below is raw deflate bytes (gzip containers minus the 18-byte
wrapper; our column is the example CLI's gzip output minus 18). "dyn step"
is ours → klauspost level 1: **the same finder class, dynamic emission
instead of fixed** — the isolated value of §3.2.7. "kp9 step" is
klauspost 1 → 9: the full finder ladder on top of dynamic emission.

| shape | ours (fixed) | kp1 | kp4 | kp6 | kp9 | gz-1 | gz-6 | gz-9 | dyn step | kp9 step |
|---|---|---|---|---|---|---|---|---|---|---|
| text 8K | 115 | 88 | 84 | 84 | 84 | 119 | 88 | 88 | −23.5% | −4.5% |
| rle 133K | 856 | 187 | 185 | 251 | 153 | 603 | 152 | 152 | −78.2% | −18.2% |
| long text 276K | 2284 | 1026 | 1009 | 884 | 846 | 1642 | 849 | 849 | −55.1% | −17.5% |
| non-ASCII 1M | 8740 | 3189 | 3189 | 3189 | 3124 | 6688 | 3123 | 3123 | −63.5% | −2.0% |
| long text 2M | 16457 | 7074 | 7046 | 5900 | 5816 | 11584 | 5820 | 5820 | −57.0% | −17.8% |
| html 64K | 591 | 266 | 266 | 266 | 258 | 600 | 258 | 258 | −55.0% | −3.0% |
| prose 64K | 24450 | 20689 | 18805 | 17728 | 17044 | 20742 | 17198 | 17131 | −15.4% | −17.6% |
| words 64K | 29802 | 22928 | 20583 | 19519 | 18862 | 23747 | 19117 | 18931 | −23.1% | −17.7% |
| repo prose 23K | 32244 | 26983 | 24880 | 24008 | 23314 | 27003 | 23501 | 23432 | −16.3% | −13.6% |
| rfc8878 110K | 36560 | 31136 | 28379 | 26623 | 25380 | 31730 | 25881 | 25568 | −14.8% | −18.5% |
| rfc7932 381K | 158551 | 128376 | 115971 | 107203 | 103071 | 134384 | 105316 | 103616 | −19.0% | −19.7% |
| mixed 1.5M | 16440 | 9444 | 5928 | 5997 | 4203 | 9653 | 5111 | 4189 | −42.6% | −55.5% |
| random 4K | 4103 | 4103 | 4103 | 4103 | 4103 | 4101 | 4101 | 4101 | 0.0% | 0.0% |
| skewlit 64K | 65540 | 65548 | 65548 | 65548 | 46326 | 49358 | 47993 | 47993 | +0.0% | −29.3% |

(The 520-KiB-period row is omitted: every implementation stores it.) Read
off the two steps' value: the **dynamic-Huffman step alone** is worth
15-25% on prose-class shapes and 55-78% on text/RLE shapes, with zero
finder change. The **finder ladder** on top of it is worth another ~15-20%
on prose-class and up to 55% on mixed. GNU gzip's level 6 tracks
klauspost's level 6 within ±3% on prose and does better on rle and mixed —
the "gzip -6 class" is a real ratio class whichever reference defines it.

Local indicative speed (the CLIs, best of two, MB/s — never a claim):

| shape | gz-1 | gz-6 | gz-9 |
|---|---|---|---|
| long text 2M | 812 | 496 | 498 |
| mixed 1.5M | 740 | 339 | 87 |
| rfc7932 381K | 100 | 23 | 7.6 |

So the C's ratio class runs at ~60% of fast speed on text, ~45% on
mixed, and ~25% on RFC-class prose; klauspost's 2-6 sit between by
construction (they are greedy fast encoders of increasing width, built
to soften exactly this cliff).

### 1.4 Which intermediate step is the right first `.ratio`

The task's framing — "level 2-3 (lazy matching, still fixed-Huffman) or
level 4-6 (lazy + dynamic trees)" — does not survive contact with the
references: **no reference emits fixed-Huffman from anything but its
fastest finder, and klauspost's levels 2-6 are not lazy at all** (§1.1).
The real choice is which of two independent upgrades lands first:

- **LR1 (flate's first `.ratio`): the dynamic-Huffman block emitter over
  the existing L1 finder** — klauspost's level-1 *emission* (their
  `storeFast` ladder + `writeBlockDynamic`), our finder untouched. It is
  the isolated 15-25%/55-78% step, it is the piece every later finder
  upgrade reuses (all finder work feeds the same token list), and it is
  the piece our decoder already fully validates on the decode side.
  *Recommendation*: this is the first `.ratio`, alone.
- The finder ladder (klauspost L2/L3's wider tables and candidates, or
  Go's lazy chains for a `-6`-class) is the **second** step, a later seat
  if the grid demands it. The measured 15-20% it adds on prose is real but
  it is the smaller number and it is meaningless without the emitter.

A middle option exists and is cheap later: klauspost's L4 (two hash
tables, greedy) is structurally zstd's dfast (§2.2) — if both codecs grow
a double-hash finder, the shape lands once in `src/internal/`? No — the
windows, hashes, and match rules differ enough (32-KiB flate window vs
2-MiB zstd; 258-byte flate match cap vs zstd's block-bound count) that
sharing would be forced; record it as considered and rejected (LR6).

## 2. zstd's ratio path

### 2.1 What the C's levels are (v1.5.7, `lib/compress/clevels.h`)

The default row (srcSize > 256 KiB), verified independently with
`zstd --show-default-cparams` on a 1.98-MiB and a 112-KiB input:

| level | window | chain | hash | search | minMatch | target | strategy |
|---|---|---|---|---|---|---|---|
| 1 | 19 | 13 | 14 | 1 | 7 | 0 | **fast** (ours) |
| 2 | 20 | 15 | 16 | 1 | 6 | 0 | **fast** (wider tables, 1-MiB window) |
| 3 | 21 | 16 | 17 | 1 | 5 | 0 | **dfast** |
| 4 | 21 | 18 | 18 | 1 | 5 | 0 | **dfast** (wider tables) |
| 5 | 21 | 18 | 19 | 3 | 5 | 2 | greedy |
| 6 | 21 | 18 | 19 | 3 | 5 | 4 | lazy |
| 7 | 21 | 19 | 20 | 4 | 5 | 8 | lazy |
| 8-12 | 21-22 | 20-22 | 21-23 | 4-6 | 5 | 16-32 | lazy2 |
| 13-15 | 22-23 | 22-23 | 22-23 | 4-6 | 5 | 32 | btlazy2 (binary tree) |
| 16-17 | 23 | 23 | 22 | 5-6 | 4 | 64 | **btopt** |
| 18 | 23 | 24 | 22 | 7 | 3 | 256 | btultra |
| 19-22 | 23-27 | 23-27 | 22-25 | 7-9 | 3 | 256-999 | btultra2 |

Three facts fall out of the table and the code:

- **Level 2 is still `ZSTD_fast`** in the default row — a param bump, not
  a strategy change (it is dfast only for sources in the ≤256-KiB row).
  It exists mostly to lift the window to 1 MiB: on the 520-KiB-period
  shape it alone halves the output (§2.3).
- **dfast is levels 3-4** (`zstd_double_fast.c`): two hash tables —
  `hashLong` (8-byte hash, `hashLog` wide) and `hashSmall` (the
  `minMatch`-byte hash, `chainLog` wide, mls 5) — a greedy scan like fast's
  with a repcode pre-check at +1, the long-match check at `ip`
  (`read64`), the short-match check with a **second long-match check at
  `ip+1`** taking the longer (`_search_next_long`), backward extension,
  complementary insertion after each match (positions `ip-2`, `ip-1`,
  `curr+2` into both tables), and the same immediate-repcode chain at
  offset 2 (`zstd_double_fast.c:105-328`, the noDict core). Its step
  acceleration is `1 << kSearchStrength` = 256 against fast's 128
  (`zstd_compress_internal.h:32`) — dfast skips *faster* over
  incompressible data, which is one reason it can lose to level 1 there
  (§2.3).
- **The row match finder is a third data structure**, auto-enabled for
  greedy through lazy2 (levels 5-12) whenever windowLog > 14
  (`zstd_compress.c:225-245`): bucketed rows with tags, its own fill
  cache. A `-5`/`-6` port is not "dfast plus a lookahead" — it is a
  different finder. btopt (16+) is a fourth: the full
  price-function parse (`zstd_opt.c`, 1580 lines).

The level-independent parts (verified: `ZSTD_compress_frameChunk` →
`ZSTD_compressBlock_internal` → `ZSTD_entropyCompressSeqStore` is
strategy-blind): the entropy emission — literals ladder, FSE tables,
Huffman trees, sequence bitstream — is **one pipeline for every level**.
The block splitter's aggressiveness does vary by strategy
(`zstd_compress.c:4560`, `splitLevels[strat]`): fast and dfast share the
same entry (0 → `ZSTD_splitBlock_fromBorders`), greedy and above move to
the chunk-based splitter — so a `-3` pin inherits exactly the `-1` pin's
TE8 preSplit caveat, unchanged, and a `-5` pin would change it.

### 2.2 What our `.fast` already shares with dfast, and what level 3 adds

Everything except the scan (`src/zstd/`):

- the sequences pipeline: `match_compress.find` fills the sequence list;
  `block_compress.compressBlock` runs the emission; `sequences_compress`
  and `literals_compress` (with `fse_compress` / `huff0_compress`) are
  untouched by the strategy — dfast's output is a different sequence list
  fed to the same layers.
- the repcode machine (offset_1/offset_2, the immediate-repeat chain), the
  backward/forward match extension, the table-priming discipline, and the
  `Params` ladder shape (`match_compress.Params` already models
  window/hash/mls per source class; dfast adds the `chainLog` field and
  the `ZSTD_adjustCParams_internal` clamp for it: `cycleLog > windowLog ⇒
  chainLog -= (cycleLog - windowLog)` alongside the existing
  `hashLog ≤ windowLog + 1`, `zstd_compress.c:1563-1567`).
- the frame layer, the fallback ladder (raw/RLE/minGain), and the
  dictionary machinery (dfast has its own dictMatchState variant of the
  scan, `zstd_double_fast.c:328-553` — the port must carry it; the
  dictionary *tables and promotion rules* are shared).

What level 3 adds, concretely: a second table and the two-candidate
scan (~220 lines of C noDict core, ~220 more for the dictMatchState
variant), the `chainLog` param and its clamp, the level-3 row of every
`clevels.h` table (the ≤16-KiB and ≤128-KiB rows shift searchLog to 2),
and buffers sized for it: at the default row, `hashLong` 2^17 u32
(512 KiB) + `hashSmall` 2^16 u32 (256 KiB) = **768 KiB of tables**
against level 1's 64 KiB (128 KiB with a dictionary), and the window at
`window_log` 21. `Writer.Buffer(21)` lands around **3.6 MiB** (2-MiB
window + 768-KiB tables + the existing block/literals/output/sequences
regions) against 1.4 MiB today; the one-shot `encode.Buffer` grows by the
table region to ~1.5 MiB. Still inside the decoder's default 8-MiB
window on the read side.

### 2.3 The measured ladder, with the pathologies

CLI sizes in bytes over the oracle shapes (default threading, file form;
ours is the one-shot harness):

| shape | ours | -1 | -2 | -3 | -4 | -6 | -9 | -19 |
|---|---|---|---|---|---|---|---|---|
| 520K-period 1M | 1065042 | 1065042 | 532570 | 532875 | 532875 | 532569 | 532569 | 532588 |
| long text 276K | 94 | 94 | 94 | 95 | 95 | 94 | 105 | 94 |
| long text 2M | 251 | 251 | 251 | 251 | 251 | 250 | **1934** | 237 |
| non-ASCII 1M | 158 | 158 | 157 | 157 | 157 | **999** | 157 | 150 |
| prose 64K | 19426 | 19426 | 19497 | 18528 | 18484 | 17206 | 16822 | 16072 |
| words 64K | 21456 | 21456 | 21819 | 20410 | 20857 | 20394 | 19575 | 17575 |
| repo prose 23K | 26404 | 26404 | 25280 | 24383 | 24371 | 23287 | 22940 | 22178 |
| rfc8878 110K | 28362 | 28362 | 28486 | 27006 | 27174 | 25114 | 24554 | 23215 |
| rfc7932 381K | 116232 | 116241 | 116848 | 110327 | 110161 | 102248 | 99495 | 91446 |
| mixed 1.5M | 3058 | 3337 | 3337 | **3927** | 3927 | 3464 | 3461 | 3399 |
| rle 133K | 39 | 39 | 36 | 36 | 36 | 35 | 35 | 34 |
| skewlit 64K | 46107 | 46107 | 46107 | 46107 | 46107 | 46761 | 46761 | 46207 |
| html 64K | 72 | 72 | 70 | 70 | 70 | 70 | 70 | 72 |

What the ladder says:

- **`-3` over `-1` is worth 5-8% on prose-class shapes and 2x on
  window-bound shapes** (the 520-KiB period: the 512-KiB `-1` window
  cannot reach the period; `-2`'s 1-MiB window and `-3`'s 2-MiB window
  can). On the bench corpus's 64-KiB shapes the whole finder ladder
  compresses to ~11% (prose-65536: 19469 → 17287 at -6).
- **The ladder is not monotone, badly.** `-3` is 17.7% *worse* than `-1`
  on mixed 1.5M (3927 vs 3337; ours at 3058 beats both — dfast's
  256-position step acceleration and the preSplit hurt there);
  `-6`/`-7` are **6.3x worse than `-3`** on non-ASCII 1M (999 vs 157 —
  the row finder on ultra-repetitive input); `-9` through `-13` are 7.7x
  worse than `-6` on long text 2M (1934 vs 250). These are the C's own
  deterministic quirks, stable across runs, and they are a direct input
  to the pin choice: a byte pin against a level the reference itself
  regrets on whole shape classes bakes the quirk in.

Local indicative speed (MB/s, best of two):

| shape | -1 | -2 | -3 | -4 | -5 | -6 | -9 | -13 | -19 |
|---|---|---|---|---|---|---|---|---|---|
| long text 2M | 773 | 801 | 772 | 581 | 603 | 603 | 319 | 77 | 102 |
| mixed 1.5M | 677 | 712 | 616 | 524 | 267 | 382 | 191 | 87 | 70 |
| rfc7932 381K | 199 | 203 | 170 | 144 | 102 | 77 | 49 | 19 | 5.7 |

`-3` costs 0-15% of `-1`'s speed — it is still a fast level. `-6` costs
25-60%. `-19` is 8-35x.

### 2.4 Which level is the right first `.ratio` pin

- **LR2 (zstd's first `.ratio`): dfast, pinned to `zstd -3`.** It is the
  last level before the row match finder (levels 5+), before the chunk
  splitter (levels 5+), and before the ladder's pathologies (the -6
  non-ASCII and -9 long-text rows above); it shares the emission pipeline
  byte-for-byte with the ported `-1`; its preSplit caveat is *identical*
  to the existing TE8 row (same `splitLevels` entry); and its window
  (2 MiB) covers the long-range shapes where `.fast` genuinely loses.
  *Recommendation*: `-3`, byte parity, the same oracle shape as the `-1`
  pin (§3.1 for what that pin must name).
- `-4` is the same strategy with wider tables: 0.2-1% over `-3` on the
  ladder, 768 KiB more table (chainLog 18/hashLog 18), ~15% slower. Not
  worth a second class; if the fleet wants it later it is a param row,
  not a port.
- `-6` and up are a different finder (row/hash-chain, then opt); a
  `-6`-class seat is a later decision with its own research, and the
  non-ASCII pathology says the C's `-6` is not even a safe target to
  pin. btopt (16+) is out of scope for this repo's speed charter
  (the plan's mission statement).
- The 520-KiB-period result exposes a cheaper partial win worth recording:
  **half the `-3` gain on long-range shapes is the window, not the
  strategy** — `-2` (still fast) halves that shape. If the grid shows
  `.fast` losing only on window-bound shapes, a `.fast` window bump
  (windowLog 20-21 at the fast strategy) is a one-slice alternative to a
  dfast port. It costs speed on nothing (the table is the cost, not the
  window) but changes every `-1`-parity frame above 512 KiB, so it is a
  parity-breaking non-starter while the `-1` pin stands — record as
  rejected-while-pinned (LR7).

## 3. The parity question

### 3.1 zstd: what "byte parity with `zstd -3`" actually pins

Measured this session, twice per cell, all levels 1-19:

- **Run determinism: total.** Every level, every mode (default,
  `--single-thread`, `-T2`, file form, pipe form) produced identical bytes
  on repeated runs, and our decoder accepted every CLI frame at every
  level (the whole 1-19 matrix, both file and pipe forms).
- **The default CLI is multithreaded since 1.5.7** (CHANGELOG: "cli:
  multi-threading as default CLI setting"), and `default_nbThreads()` is
  core-count-derived (`zstdcli.c:776`, `ZSTDCLI_NBTHREADS_DEFAULT =
  max(1, min(4, cores/4))`). MT output is deterministic — `-T2` equals the
  default on every cell — because the job split depends on job size, not
  worker count.
- **But default ≠ `--single-thread`**, and the pin must say which it means:

| where they agree | where they differ |
|---|---|
| long-text / non-ASCII / RFC-8878-class shapes below the level's job size, at every level tested | mixed 1.5M at -1, -2, -3, -6 — file form (3337 vs 3645 at -1; 18 vs 22 blocks) |
| | 520-KiB-period 1M at -3; non-ASCII 1M at -6 — file form |
| | RFC 7932 at -6 and -19 — pipe form only (the file form agrees) |
| | every input above the job size, every level, both forms (10-MiB long text: 1016 vs 1020 at -1) |

  The job size is `1 << max(20, windowLog + 2)`
  (`zstdmt_compress.c:1184-1193`, `ZSTDMT_computeTargetJobLog`): **2 MiB
  at -1, 8 MiB at -3/-6, 32 MiB at -19**. Above it the default CLI's
  output carries job-boundary blocks no single-threaded encoder
  produces. The below-job-size divergences are the block splitter:
  `savings` is computed once per `ZSTD_compress_frameChunk` call
  (`zstd_compress.c:4595`) — the single-thread path makes one call per
  ~128-KiB read chunk (`ZSTD_CStreamInSize` = `ZSTD_BLOCKSIZE_MAX`), the
  MT path one per job, so the `savings >= 3` gate unfreezes at different
  points and the splitter fires differently (the 18-vs-22-block row).
- **Our `-1` pin is really the library one-shot class.** Below 2 MiB the
  two CLI modes agree with each other and with us on the parity rows;
  above it, ours matches `--single-thread` exactly on the non-excluded
  class (the 10-MiB long-text row reproduced byte-identical this session,
  and the parent's verification lane reproduced it again), while the
  default CLI splits jobs. RFC-7932-class and mixed-binary inputs stay
  excluded: the CLI's single-thread path calls `ZSTD_compress_frameChunk`
  once per 128-KiB read, so its `savings >= 3` splitter gate unfreezes
  from the second block, while our one-shot's single call keeps the
  gate frozen and emits the unsplit block — the already-documented
  TE8 round-trip-only class (`src/zstd/README.md`'s parity exclusions),
  re-verified at 11.7 MiB (RFC 7932 ×30: block 0 identical, block 1
  split 31,348+9,189 in the CLI vs one 40,543 block in ours). The oracle
  suite never noticed because its largest parity input is 1.98 MiB. The
  README's "up to about 2 MiB" pipe caveat is the same fact from the
  other side.
- **Version stability: the pin is version-locked by nature.** The 1.5.7
  CHANGELOG records that 1.5.6 → 1.5.7 changed level 3-4 output
  ("perf: slight compression ratio improvement for `dfast`, aka levels 3
  and 4 (#4171)") and block boundaries (#4136, #4176, #4178 — the
  preSplit). A flake bump of zstd breaks the `-3` suite exactly as it
  would break `-1`'s; that is the existing pin's cost structure, not a
  new one, and it should be written into the flake-bump checklist when
  the seat lands.
- **TE8 carries over unchanged**: `zstd -3` at the default row uses the
  same `splitLevels[dfast] = 0` fromBorders splitter as `-1`, so the
  mixed-binary and RFC-7932 rows stay round-trip-only for the `-3` suite
  too, unless the splitter is ported (a separate, deliberate slice).

So: **byte parity with `zstd -3` is achievable and worth pinning**, with
the pin stated precisely: *the pinned CLI v1.5.7, file form, default
threading, inputs at or below the level's job size (8 MiB at -3), the
TE8 class excluded as today*. The looser alternative — a valid-stream
class with ratio measured on the grid — would give up the oracle's
strongest property (the CLI as an encode oracle catches finder drift the
round-trip cannot) for a class that is *cheaper* to reach but unjudgeable.
The measured ladder's pathologies (§2.3) argue the other way only for
levels ≥ 5, which LR2 already excludes.

### 3.2 flate: what a `.ratio` pin could even be

- **Run determinism: total** for klauspost (levels 1-9), Go stdlib
  (1-9), and GNU gzip 1.14 (1-9) — every implementation, every level,
  twice.
- **But "gzip -6" is not one byte target.** GNU gzip 1.14's deflate body
  differs from CPython zlib 1.3.2's at the same level on 3 of 16 shapes
  (520-KiB-period, rfc7932, skewlit, at both -6 and -9) — same zlib
  lineage, one patch level apart. klauspost's level 6 differs from both
  on rle (251 vs gzip's 152/134-class) by whole block-ladder decisions.
  A flate `.ratio` byte pin would have to name **one implementation and
  version**, and unlike zstd there is no single-C-reference argument for
  which one.
- **What a klauspost-parity pin would cost** (the natural candidate: it
  is the module the bench oracle already pins): the exact per-level
  finder (L5/L6's double tables with prev-entries, or 7-9's hash chains),
  the exact token pipeline, `writeBlockDynamic`'s cost model with the
  reuse machinery and the `maxPredefinedTokens`/penalty shortcuts — and,
  the part that makes it expensive, **the tie-break sorts**: klauspost's
  code-length assignment stability comes from vendored copies of Go's
  sort (`huffman_sortByFreq.go`, `huffman_sortByLiteral.go` — heap/quick
  /shell hybrids). Porting those byte-exactly is possible (they vendored
  them for the same reason) but it is the largest single slice of the
  emitter and it buys determinism, not ratio.
- **The flate house rule was never byte parity** (this file's opening
  section): `.fast`
  is pinned as a class (round-trip + decode compat + the golden corpus)
  because no reference emits it. The consistent continuation for
  `.ratio` is the same class pin with harder judges: our dynamic blocks
  decoded by python3's zlib at levels 4-9, by the example CLI, and by
  klauspost/Go readers (all already wired in the oracle scripts' shapes),
  plus a **ratio gate** on the grid (ours vs gzip -6 and klauspost 5/6
  within a stated margin on the corpus) instead of a byte gate.

- **LR3 (flate `.ratio` pin): valid-stream class, ratio-gated — not byte
  parity.** *Recommendation*: keep flate's pin a class; add the ratio
  gate to the oracle so "worse than gzip -6 by more than X% on shape Y"
  is a named failure. If Matt wants a byte target later, klauspost level
  5 or 6 is the candidate and the tie-break sort port is the price — a
  decision to make *after* the emitter exists and its ratio is measured
  (LR5).

### 3.3 The house rule, restated per codec

zstd: byte parity at both classes (the `-1` precedent extended to `-3`).
flate: class parity at both classes (the fixed-Huffman precedent extended
to dynamic). The asymmetry is not an accident — it tracks whether a
single reference implementation *defines* the class (zstd's C) or many
equally-valid ones do (deflate's dynamic blocks, where the RFC mandates
the wire and leaves the construction free, §1.2).

## 4. The seat's API shape

- **Should `.ratio` stay one step?** Yes — **LR4: one class per codec
  now, ladder growth only if the grid demands it.** Evidence: the
  measured ladders show each codec has one clear next class (dynamic
  flate; dfast zstd) and a long tail of reference levels whose value
  (1-8% per step) does not justify public enum surface, some of which
  the reference itself gets wrong on whole shape classes (§2.3). The
  internal param ladder (which table widths, which window) is
  implementation freedom and should stay out of the API.
- **What the READMEs' error contracts imply for migration.** Filling the
  seat is signature-compatible by construction: both `compress` functions
  already return `error{ BufferTooSmall, Unimplemented }`, and the
  "rejected, never silently aliased" tests (both codecs) *flip* from
  expecting `Unimplemented` to expecting success — a test-only change.
  Dropping `Unimplemented` from the error set afterward narrows the set
  (never a breaking change for callers), but keeping it reserved for a
  *next* seat is the honest choice only if a next seat is plausibly
  wanted; otherwise it is a lie in the type. `Writer.streamAll`'s
  `error.ReadFailed`-before-reading behavior and the poisoned-`finish`
  contracts are level-agnostic and unaffected. Callers that `switch` on
  `Level` exhaustively (rare — the type is an options field) get a
  compile error on any new variant, which is the migration surface
  working as intended.
- **flate's numeric variants are a live contract question.** flate's
  `Level` already declares `.@"1"` through `.@"9"` as documented aliases
  of `.fast` (`src/flate/README.md`, API). Two coherent end states:
  (a) keep them aliases forever (numeric levels mean nothing in this
  API; `.ratio` is the only stronger class), or (b) once a finder ladder
  exists, make 4-6 select it with per-level params (a behavior change
  for any caller relying on the documented alias-for-speed). zstd's
  `Level = enum { fast, ratio }` has no such debt. *Recommendation*:
  (a) — one stronger class, aliases stay aliases, and the README says so
  in the same sentence that stops reserving `.ratio`. This is Matt's
  call at the sketch review (LR5).
- **Buffer-size growth is API-visible and must be in the sketch.** zstd's
  `Writer.Buffer(21)` ≈ 3.6 MiB and `encode.Buffer` ≈ 1.5 MiB at `.ratio`
  (§2.2) against 1.4 MiB / 768 KiB today; flate's dynamic path adds the
  token list (klauspost's is `type token uint32`, capped at
  `maxFlateBlockTokens = 1<<15` — a block flushes when the list fills,
  so a 128-KiB region at 4 bytes a token; a `Writer`-owned region,
  documented) plus two `huffmanEncoder`-sized scratch arrays
  (~2.5 KiB) and the codegen buffer (~320 B). None of it changes the
  caller-owned-buffer pattern; all of it changes the published sizes.

## 5. Slice maps

### 5.1 flate `.ratio` (dynamic Huffman over the existing finder)

Grounded against klauspost's file sizes (`huffman_code.go` 417 lines,
the dynamic third of `huffman_bit_writer.go` ~400, `token.go` 379) and
our `src/flate/encode.zig` (1551 lines, of which the finder's scan
cascade and `BitWriter` are reused as-is):

| slice | what | est. size |
|---|---|---|
| 1 | the token list: a `Token` type (literal / length+distance pairs) and the finder refactor from inline bit emission to token production (`encodeFixedBlock`'s scan cascade is kept; its emit leaves become token pushes) | ~350 lines + the re-plumb of `compressBlockStateful`/`Writer` |
| 2 | histograms and the length-limited tree builder (`bitCounts` + `assignEncodingAndSize`, maxBits 15, klauspost's tie-break order) | ~300 lines |
| 3 | codegen: the 16/17/18 run-length encoding of the two trees as one sequence, the code-length tree (7-bit cap), HLIT/HDIST/HCLEN and the §3.2.7 order, the one-distance-code case | ~300 lines |
| 4 | the cost model and block dispatch: `storedSize`/`fixedSize`/`dynamicSize`/`extraBitSize`, the stored fallback (already exists), the fixed rung kept for small blocks, the 1/16th literals-only rung; the `maxPredefinedTokens` shortcut optional (without a byte pin it is free either way) | ~200 lines |
| 5 | integration: `Level.ratio` dispatch, `Writer` + one-shot paths, `maxCompressedLength` review (unchanged: stored still bounds it), README rewrite | ~150 lines + docs |
| 6 | tests and oracle: RFC §3.2.7 worked vectors as encode goldens, round-trip, the ratio gate (§3.2), python3-zlib/klauspost decode judges, fuzz target updates | ~400 lines |

**~6 slices, ~1700 lines** — between one and two waves of the M2 shape,
with slices 2-3 (the trees) the only genuinely new algorithms. The reuse
machinery (`lastHeader`/`canReuse`) is deliberately out: it is a speed
optimization on the header-estimation path, not a ratio feature — but
it is not output-neutral (it decides when a block keeps the previous
tree, which changes bytes), so if it ever lands it carries its own
ratio/parity decision (noted in LR5). The finder ladder (L4/L5 or
7-9) is **not** in this map: a later seat, +2-4 slices each.

### 5.2 zstd `.ratio` (dfast, `-3` parity)

Grounded against `zstd_double_fast.c` (778 lines total; ~220 noDict core
+ ~220 dictMatchState + fill/dispatch) and our `match_compress.zig`
(1854 lines including the dict handling and tests):

| slice | what | est. size |
|---|---|---|
| 1 | `Params` growth: `chain_log`, the level-3 rows of all four `clevels.h` tables (with the ≤128-KiB searchLog-2 and ≤16-KiB rows), the `adjustCParams` chainLog clamp, `forSource`/`forSourceAttached`/`forSourceCopied` variants per level | ~150 lines |
| 2 | the dfast scan: `hashLong`/`hashSmall` tables, the repcode pre-check (exists), long+short candidate checks, the ip+1 long-match arbitration, complementary insertion, step 256; the dictMatchState variant and the fill (fastHashFillStep 3) | ~700 lines incl. dict |
| 3 | buffers and plumbing: `encode.Buffer` table region (long+small), `Writer.Buffer` at window_log 21, `block_compress`/`Writer` param threading, `Level.ratio` dispatch | ~200 lines |
| 4 | tests and oracle: the `-3` parity suite (the `-1` oracle's shape, file form, default threading, ≤ 8 MiB, TE8 rows round-trip-only), corpus-shape parity, fuzz level coverage | ~350 lines |

**~4 slices, ~1400 lines** — one to two waves. The emission layers are
untouched (§2.2), which is what keeps this map smaller than flate's
despite the finder being the bigger algorithm: every new line is
match-finding. The `-6`-class (row finder) would be a separate ~6-8
slice map and is out of scope (LR2).

### 5.3 Order between the codecs

flate first (LR1+LR3), zstd second (LR2): the flate seat is the larger
ratio win per measurement (15-25%/55-78% vs 5-8%/2x), it serves three
codecs (gzip and zlib wrap it), and the zstd seat's biggest risk —
parity pin semantics — is resolved by this file rather than by code.
The reverse order is defensible only if the grid shows `.fast`-zstd
losing to klauspost's zstd on the fleet corpus (its `-1` is already the
fast class klauspost measures); nothing in this session's data says that.

## 6. Decisions for the parent

Ranked by how much they block the API sketches:

1. **LR1 — flate's first `.ratio` = the dynamic emitter over the existing
   finder** (§1.4). Default if Matt is silent: proceed; the finder ladder
   is a later seat.
2. **LR2 — zstd's first `.ratio` = dfast, byte parity with the pinned
   CLI's `zstd -3`** (§2.4, §3.1), the pin stated as: v1.5.7, file form,
   default threading, inputs ≤ 8 MiB, TE8 rows excluded as today. Default
   if silent: proceed.
3. **LR3 — flate `.ratio` is a valid-stream class with a ratio gate, not
   a byte pin** (§3.2). Default if silent: proceed; the byte-pin option
   (klauspost level 5/6 + the sort ports) is a post-emitter decision.
4. **LR4 — `.ratio` stays one class per codec; no numeric ladder in the
   API** (§4). Default if silent: proceed.
5. **LR5 — the sketch-review questions for Matt**, all with defaults:
   (a) do flate's `.@"1"`-`.@"9"` stay permanent aliases of `.fast` when
   `.ratio` fills (recommended: yes)? (b) does `Unimplemented` leave the
   error sets once both seats are filled (recommended: yes, unless a
   btopt-class seat is wanted later)? (c) does the zstd `-3` pin's
   version-lock go on the flake-bump checklist (recommended: yes)? (d)
   does the klauspost reuse machinery stay out of the first flate
   emitter (recommended: yes; it changes bytes, so it needs its own
   parity decision if it ever lands)?
6. **LR6 — rejected: sharing a double-hash finder across flate and zstd
   in `src/internal/`** (§1.4). The windows, match caps, and insert
   rules differ; the share would be a shape, not code.
7. **LR7 — rejected while the `-1` pin stands: a `.fast` window bump
   (windowLog 20-21)** (§2.4). Half the `-3` gain on long-range shapes is
   the window alone, but it breaks `-1` parity above 512 KiB. Revisit
   only if the pin is ever retired.

## 7. Open questions the spec leaves unstated

- RFC 1951 §3.2.7 fixes the wire but not the tree construction (§1.2) —
  every reference's dynamic blocks are valid and mutually
  non-identical. Not a gap to file; the reason LR3 is a class pin.
- RFC 1951 §3.3 lets a compressor limit ranges ("a compressor may limit
  the range of backward pointers … and still be compliant") — our
  32-KiB window and 64-KiB blocks are already this; the dynamic emitter
  inherits both.
- RFC 8878 is silent on level semantics entirely (levels are a
  libzstd API convention, not format); the pin's dependence on
  `clevels.h` and `ZSTDMT` job sizes (§3.1) is upstream's, not the
  RFC's — recorded so a future "but the spec says" review of the oracle
  knows the pin's authority is the pinned CLI, not §3.
- The C's level pathologies (§2.3) are undocumented upstream behavior;
  if a `-3` parity pin lands, the mixed-binary +17.7% row becomes
  *our* behavior too. Worth one line in the module README's behavior
  section when the seat fills, and a check that the bench corpus's
  mixed shapes (which store at 64 KiB) do not regress at scale.
