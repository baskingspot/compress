# Brotli encoder research notes

The research stage of the brotli encoder: the first `encode`/`Writer` seat
the plan's M6 decoder row hands off (`docs/compress-plan.md`, "M6": the
decoder shipped; the README states the encoder seats "reserved and stated,
never silently absent", `src/brotli/README.md`). Four questions, all answered
here with measurements or with the reference's own source:

- **The quality ladder.** google/brotli's `q0`-`q11` is an algorithm map, not
  a dial — which class is this package's first encoder, given the house class
  is speed-first (the zstd encoder is byte-identical to `zstd -1`, the flate
  encoder is the fixed-Huffman speed class)? §1.
- **The encoder-side machinery** the decode side never needed: the
  prefix-code *construction* and emission, the command assembly, the
  dictionary decision path, the meta-block assembly, and the backward-safety
  rules. §2.
- **The parity question.** Byte parity with the pinned reference CLI at a
  chosen quality (the `zstd -1` precedent) vs valid-stream parity only. §3.
- **The custom-dictionary negative**, re-verified with evidence. §4.

Every requirement line cites the vendored spec file and section, or the
reference source at `path:line`; where a claim is measured, the measurement
and its incantation are in §0. The existing registers are ground truth and
cited, not restated: the decode research (`brotli-notes.md` — the `BR`
matrix, `T` divergence rows, `OQ` questions), the decoder's design register
(`src/brotli/AGENTS.md`), the dictionary milestone (`dictionary-notes.md`
§5.2), and the encoder-notes precedent (`zstd-encoder-notes.md`).

## 0. Provenance

- Spec: `rfc7932-brotli.txt` (vendored verbatim; provenance row in
  `docs/specs/README.md`, fetched 2026-10-12). The sections this
  file leans on: §1.5.1 (bit order), §3.2-§3.5 (prefix codes), §4
  (distances), §5 (insert-and-copy lengths), §6 (block switches), §7
  (context modeling), §8 (the static dictionary), §9 (stream and meta-block
  format), §10 (the decoding algorithm — the state machine an encoder must
  advance exactly), §11 (compressor considerations), Appendices A/B.
- Reference sources, all read from disk (nothing fetched this session):
  - **google/brotli v1.2.0** (MIT, "Distributed under MIT license", the
    tree's `LICENSE`). The pristine release tree at
    `/tmp/benchmethod-brotli/brotli-1.2.0/` (3.1 MB; version verified at
    `c/common/version.h`, no git checkout, byte-for-byte the tag the M6
    research pinned — `brotli-notes.md` §0: "google/brotli at tag v1.2.0
    (commit 028fb5a)"). Cited inline as `c/enc/...:line` relative to that
    tree. This is the *algorithm source of record* for the encoder (§3.3:
    the Go port diverges below `q5`).
  - **The pinned brotli CLI 1.2.0** from the flake (the conformance lane's
    pin, `just brotli-oracle`; `brotli --version` → `brotli 1.2.0`). All
    experiments below encode with it.
  - **andybalholm/brotli v1.2.6** (MIT), the Go reference — in the module
    cache (`~/go/pkg/mod/github.com/andybalholm/brotli@v1.2.6/`) and behind
    `scripts/brotli_go/` (the oracle's driver, `go.mod` pin v1.2.6; built to
    `zig-out/bin/brotli-go` this session). The most *readable* algorithm
    reference (a c2go translation of the C); **not** byte-faithful below
    `q5` (§3.3), so it is the reading companion, never the parity source.
- Oracles and instruments run for this file — every number below was
  produced by one of these, and each was validated before use:
  - **The reference-CLI quality sweep**: `brotli -q <0..11> -c FILE`, twice
    per (shape, quality) on the small shapes, once plus a cross-check on the
    big one — 11 shapes: the repo README, the generated corpus shapes
    (`bench/corpus-gen/`: prose 32K/64K, text, html, words, skewlit, mixed,
    random, rle — `just corpus`), and the vendored RFC 7932 text itself
    (390 KB of natural text).
  - **An instrumented decode census**: a patched *copy* of the C tree (at
    `/tmp/brotli-enc-notes/brotli-c/`, never the pristine tree) with a
    counter at the one §8 decision point (`c/dec/decode.c`'s static-dictionary
    branch, the same site the M6 research instrumented — `brotli-notes.md`
    §4.2), built with cmake plus two drivers: `census3` (decode + verify +
    count dictionary references) and `enc2` (the library form:
    `BrotliEncoderCompressStream` with explicit quality, `LGWIN`, and an
    optional `SIZE_HINT`).
  - **The C's own debug log**: a `BROTLI_ENABLE_LOG` build of the same copy.
    `[ReadHuffmanCode]`/`[ReadCodeLengthCodeLengths]` lines print every code
    length the reference decoder reads — the ground truth the walker below
    was validated against, tree for tree.
  - **A meta-block header walker** (`/tmp/brotli-enc-notes/walk.py`, ~350
    lines of Python): parses the §9.1 stream header and the entire §9.2
    first-meta-block header — every NBLTYPES, NPOSTFIX/NDIRECT, context
    mode, context map (RLEMAX + IMTF), block counts, and all
    NTREESL+NBLTYPESI+NTREESD prefix codes (both §3.4 forms and the full
    §3.5 machine) — asserting every RFC-stated invariant while walking.
    Validated three ways before its output was trusted: (a) §11.1's trivial
    compressor, transcribed verbatim from the RFC's C++ into Python, walked
    clean *and* decoded byte-exact through our example CLI (`just example
    brotli decode`); (b) the C's debug log on the q0 README stream — the
    walker's per-tree code lengths matched the log tree for tree, including
    the log's unlogged-single-zero gaps; (c) the C's own serializer: feeding
    the log's depths for the q0 distance tree to `BrotliStoreHuffmanTree`
    reproduced the stream's 106 tree bits byte-exactly. Coverage: 120 of
    the 132 sweep rows walked clean; the 12 failures are all `q4`+ on
    ≥32 KB inputs (the block-split classes) and are recorded as an open
    question (§8), not chased — the q4+ fingerprint rows below come from the
    census and the debug log instead.
  - **The custom-dictionary battery** (§4): `brotli -q 5 -D dict -c`, the
    CLI's decode with and without `-D`, and our oracle harness on the
    `-D` stream.
- Scratch: `/tmp/brotli-enc-notes/` (the patched C copy ~6 MB with builds,
  the outputs, the tables). The parent deletes it at the milestone's close.
  The pristine tree at `/tmp/benchmethod-brotli/brotli-1.2.0/` belongs to
  the bench lane and is untouched.
- **The parent's independent verification lane** re-measured the parity
  rows (18/18 determinism, 6/6 + 12/12 + 48/48 CLI-vs-C identity) and the
  `q3`/`q2` rows (sizes exact; speed corrected to 0.83-0.85 of `q2`'s
  throughput — §1.5). Its scratch lives at `/tmp/` (deleted at this
  commit).

## 1. The quality ladder (`q0`-`q11`)

### 1.1 The ladder as the reference defines it

The ladder is not a dial: `q0`/`q1` are a *different algorithm family* from
`q2`+, and `q10`/`q11` are a third. The reference's own constants
(`c/enc/quality.h:17-29`) gate whole subsystems:

| gate | value | what it switches |
|---|---|---|
| `FAST_ONE_PASS_COMPRESSION_QUALITY` | 0 | the one-pass fragment compressor (`compress_fragment.c`, "Adapted from the CompressFragment() function in snappy", `compress_fragment.c:9-11`) |
| `FAST_TWO_PASS_COMPRESSION_QUALITY` | 1 | the two-pass fragment compressor (`compress_fragment_two_pass.c`) |
| `MAX_QUALITY_FOR_STATIC_ENTROPY_CODES` | 2 | `q0`-`q2` meta-blocks may use precomputed static prefix codes |
| `MIN_QUALITY_FOR_BLOCK_SPLIT` | 4 | block splitting (`block_splitter.c`) below this never splits |
| `MIN_QUALITY_FOR_NONZERO_DISTANCE_PARAMS` | 4 | NPOSTFIX/NDIRECT stay 0 below this |
| `MIN_QUALITY_FOR_OPTIMIZE_HISTOGRAMS` | 4 | the histogram re-optimization pass |
| `MIN_QUALITY_FOR_EXTENSIVE_REFERENCE_SEARCH` | 5 | the lazy match search's second-pass length floor |
| `MIN_QUALITY_FOR_CONTEXT_MODELING` | 5 | literal context modeling (the context maps of §7.3) |
| `MIN_QUALITY_FOR_HQ_CONTEXT_MODELING` | 7 | the 3-context-model choice |
| `MIN_QUALITY_FOR_HQ_BLOCK_SPLITTING` | 10 | the clustering split (`BrotliBuildMetaBlock`, q10/q11 only) |
| `ZOPFLIFICATION_QUALITY` / `HQ_ZOPFLIFICATION_QUALITY` | 10 / 11 | the binary-tree hasher (`backward_references_hq.c`), zopfli lengths 150/325, candidates 1/5 (`quality.h:41-49`) |

And the hasher map, in the reference's own comment (`quality.h:121-213`,
`ChooseHasher`): `q2`-`q4` are `longest_match_quickly` hashers (bucket bits
16/17/17, source length 5, no chains — one candidate per bucket; `q4` swaps
to a 20-bit table on ≥1 MiB size hints); `q5`-`q9` are the chain hashers
(SIMD `longest_match`/`longest_match64`, bucket 14-15, 4-16 last-distance
checks); `q10`/`q11` are `H10` (the `to_binary_tree` zopfli searcher). The
sparse-search heuristic ("unsuccessful match lookups are very expensive")
applies only to `q2`-`q9` (`quality.h:99-104`).

### 1.2 The four meta-block writer classes

`WriteMetaBlockInternal` (`c/enc/encode.c:481-596`) is the fork the whole
ladder hangs on:

| class | qualities | writer | what it emits |
|---|---|---|---|
| fragment | 0, 1 | `BrotliCompressFragmentFast` / `BrotliCompressFragmentTwoPass` (`encode.c:1479-1490`) | its own meta-blocks, own command machinery, own block splitting (`kFirstBlockSize = 3<<15`, `kMergeBlockSize = 1<<16` with in-place MLEN patching, `compress_fragment.c:438-445`; the two-pass at `kCompressFragmentTwoPassBlockSize = 1<<17`, `compress_fragment_two_pass.h:25`); window forced ≥ 18 (`encode.c:667-671`); **no static dictionary** (no `SearchInStaticDictionary` call anywhere in either file — verified by grep) |
| static entropy codes | 0-2 | `BrotliStoreMetaBlockFast` (`brotli_bit_stream.c:1232+`) | a fresh literal tree, then *precomputed* command and distance trees when ≤128 commands (the 56+3-bit and 28-bit hardcoded tree representations, `entropy_encode_static.h:524-539`; depths 448×9+256×11 and 64×6, counted from the tables) — otherwise fresh trees all around |
| trivial | 3 | `BrotliStoreMetaBlockTrivial` (`brotli_bit_stream.c:1168+`) | fresh trees for all three alphabets; NBLTYPES 1/1/1; no context modeling; the minimal header |
| split | 4-9 / 10-11 | `BrotliStoreMetaBlock` over `BrotliBuildMetaBlockGreedy` / `BrotliBuildMetaBlock` | block splitting (`block_splitter.c` + `block_splitter_inc.h`), literal context modeling from q5 (`DecideOverLiteralContextModeling`, `encode.c:407-432`), histogram optimization from q4, clustering at q10+ |

### 1.3 The measured ladder

The CLI, file form, on four shapes (ratios = output/input), plus the
instrumented dictionary-reference census and the walker's wire
fingerprints. The speed column is the CLI's own encode throughput on the
390 KB RFC text (best of 2; the `q2`/`q3` pair re-measured as the min of
41 quiet runs; process overhead ~1 ms included) — the
*reference's* curve, recorded to price the ladder, not a claim about any
code of ours (fleet numbers come later, from the grid):

| q | class | rfc ratio | prose32 | words32 | MB/s | dict refs (rfc / prose32) | the wire class (measured, walker) |
|---|---|---|---|---|---|---|---|
| 0 | one-pass fragment | 0.338 | 0.350 | 0.384 | 228 | 0 / 0 | WBITS ≥ 18 (forced up from the auto window on the ≤ 256 KiB shapes), ISLAST=0 + a later last block, first MLEN 98304 (= `kFirstBlockSize`) on the 390 KB text, trivial counts, context mode 0 |
| 1 | two-pass fragment | 0.314 | 0.349 | 0.358 | 160 | 0 / 0 | same shape, first MLEN 131072 (= `kCompressFragmentTwoPassBlockSize`) on the 390 KB text |
| 2 | quickly h02 + static codes | 0.294 | 0.312 | 0.326 | 129.4 | 3 / 2 | WBITS by file size, single last meta-block, MLEN 65536 cadence, minimal header, fresh literal + static-or-fresh cmd/dist trees |
| 3 | quickly h03 + trivial | 0.288 | 0.308 | 0.328 | 109.7 | 0 / 0 | same, all-fresh trees, minimal header |
| 4 | quickly h04 + split | 0.277 | 0.297 | 0.325 | 78 | 308 / 211 | context mode 2 (UTF8), NBLTYPESD 2-5 + distance context maps (RLEMAX 1, IMTF), block counts |
| 5 | chain + split + context | 0.263 | 0.280 | 0.310 | 45 | 414 / 302 | as q4, deeper splits |
| 6-9 | longer chains | 0.256-0.246 | 0.278-0.276 | 0.303-0.294 | 37-16 | 402-389 / 301-297 | as q5 |
| 10 | zopfli + HQ split | 0.234 | 0.247 | 0.288 | 2.4 | 1037 / 635 | NTREESL 2-7 with literal context maps (RLEMAX 2-5, IMTF), NPOSTFIX 1-3, NDIRECT 8-120 |
| 11 | zopfli, 5 candidates | 0.226 | 0.239 | 0.276 | 0.9 | 1166 / 699 | as q10 |

Cross-cutting measurements from the same sweep:

- **Determinism**: every two-run pair byte-identical — 11 shapes × 12
  qualities on the small shapes, and the 390 KB text re-encoded across
  batteries with identical bytes at every quality (the library comparison
  of §3.2 is itself a second independent encode agreeing byte-for-byte).
  The bench lane had already measured the stronger property for q11: the
  CLI's output is byte-identical to the tarball's encoder built with zig cc,
  FMA contraction on or off, and on wasm32-wasi (`bench/AGENTS.md`, the
  brotli row, via the lane's patch file). The reference encoder is
  deterministic and build-stable.
- **The uncompressed shortcut is live at every quality**: the mixed and
  random shapes emit `ISUNCOMPRESSED=1` meta-blocks at all twelve
  qualities — 32,772 bytes for a 32,768-byte input, exactly the `+4` of
  `WriteMetaBlockInternal`'s `bytes + 4 < (*storage_ix >> 3)` rollback rule
  (`encode.c:585-596`), preceded by the `ShouldCompress` entropy sampler
  (`encode.c:433-463`) refusing first. The fallback is not a corner: it is
  the *normal* output for incompressible input at every quality.
- **The dictionary-bearing classes**: `q0`/`q1` are structurally
  dictionary-free (no call site). `q2` emits dictionary references on 5 of
  the 9 compressible shapes (2-4 references each); `q3` emitted **zero** on
  all eleven shapes; `q4` jumps to hundreds. This refines the M6 decode
  research's measurement (alice29: "q0-q3 → 0 references; q4 → 365",
  `brotli-notes.md` §4.2): the boundary is not "q4 and up" but "q2
  occasionally, q3 never on this corpus, q4 heavily" — the `q2`/`q3`
  quickly-hashers do call `SearchInStaticDictionary` (§2.4); at `q3` it
  simply never won on any shape measured here.
- **The window by form**: the file form sizes WBITS by input length (10
  upward, capped 24 — `tools/brotli.c:1415-1427`); the pipe form emits
  WBITS 24 (`DEFAULT_LGWIN`, `tools/brotli.c:113`); `q0`/`q1` force ≥18
  regardless. All re-verified by the walker on this sweep (WBITS 13/16/17/19
  by size, 18 at q0/q1) — matching the M6 register's F9 finding.

### 1.4 What each step past `q3` costs

On the reference's own curve (§1.3), from the `q3` class:

| step | ratio gain | throughput cost | the machinery added |
|---|---|---|---|
| q3 → q4 | -4% size | -29% | the block splitter (`block_splitter_inc.h`, 19 KB: sampled histograms, greedy block assignment, remap) + `BrotliOptimizeHistograms` + the NPOSTFIX/NDIRECT search (`ChooseDistanceParams`, `encode.c:598-623`) + the block-switch emission of §6 (type/count prefix codes interleaved in the data) |
| q4 → q5 | -5% | -42% | literal context modeling (`DecideOverLiteralContextModeling` + `ChooseContextMap`, the static context maps, `encode.c:280-432`) and the context-map writer of §7.3; the chain hashers replace the quickly hashers |
| q5 → q9 | -6% cumulative | -64% | deeper chains: last-distance checks 4 → 10 → 16, bucket bits up, the extensive lazy search |
| q9 → q10 | -5% | -85% | the zopfli binary-tree hasher (`backward_references_hq.c`, 37 KB), the clustering split, HQ context modeling — a different matcher, not a tuning of the chain |
| q10 → q11 | -3.4% | -63% more | zopfli length 150 → 325, candidates 1 → 5 |

Read plainly: past the fast tier every quality step buys a few percent of
ratio for 20-40% of throughput, until `q10`/`q11` trade two orders of
magnitude of speed for the last 8%. The speed-first house has no reason to
go past `q4` on the first encoder; the real question is `q2` vs `q3` vs
`q4`.

### 1.5 The first-target recommendation

**The `q3` class** — the `h03` quickly hasher (bucket bits 17, source
length 5, no chains) through `BrotliStoreMetaBlockTrivial`. The case:

1. **It is the minimal-emission class of the real-ladder family.** One
   emission path, always fresh trees, NBLTYPES 1/1/1, NPOSTFIX 0, NDIRECT 0,
   one context mode bit-pair (LSB6), NTREESL/NTREESD 1 — the entire §6/§7
   encode-side surface (block switches, context maps, clustering, distance
   params) is *absent* (§2.7).
2. **It beats `q2` on ratio nearly everywhere measured** — 8 of 11 shapes
   (tied on the two incompressible ones), because `q2`'s static command
   tree is a flat 9/11-bit code that wastes bits on text, while `q3`'s
   fresh trees adapt. `q2` wins only `words32` (by 0.7%); on speed it is
   15-17.5% ahead (point 3).
3. **It runs at 0.83-0.85 of `q2`'s measured throughput** and 1.4×
   `q4`'s. Measured: ~15% slower than `q2` at the CLI level on the RFC
   text (`q2` 129.4 MB/s vs `q3` 109.7 MB/s, min of 41 quiet runs;
   CPU-time ratio 0.846), ~17.5% slower in-process (200 interleaved
   rounds: 181 vs 150 MB/s). The earlier ~0.91 reading rested on a slow
   best-of-2 `q2` sample; the parent's verification lane corrected it.
4. **Its machinery is a strict prefix of everything above it** — the
   hasher, the greedy match loop, the tree builder, the command math, the
   dictionary decision path all survive unchanged at `q4`+; nothing is
   thrown away when the ladder climbs.
5. **It is structurally streaming-deterministic**: `ChooseHasher` consults
   the size hint only at `q4`+ (`quality.h:189-191`), and context modeling
   starts at `q5` — so a `q3` encoder needs no knowledge of the input's
   total size. Measured: the size hint on/off changed zero bytes at `q3`
   (§3.4); it does change classes at `q4`+ on ≥1 MiB inputs.

The `q2` static-entropy-codes class is the closer *analogy* to the flate
fixed-Huffman precedent (precomputed codes, the C's own naming:
`MAX_QUALITY_FOR_STATIC_ENTROPY_CODES`), and it is the right *second*
class if the fleet shows the per-meta-block tree build matters: the static
trees are 87 hardcoded bits plus one branch, and the port covers the shared
machinery either way. The `q4` split class is the right *third* — it is
where the dictionary starts earning its bytes (hundreds of references) and
where the ratio ladder actually begins, at a 29% throughput cost and the
whole splitter port. `q0`/`q1` are *not* recommended as a first target:
the fragment compressors are a snappy-adapted algorithm family that shares
no code with the rest of the ladder (their own command machinery, their own
meta-block merging with in-place MLEN patching, a forced window, no
dictionary), so porting them buys speed the house does not need while
building machinery the ladder above never reuses.

## 2. The encoder-side machinery the decode side never needed

The decoder's layers (`src/brotli/AGENTS.md`'s table) are all *readers*.
Their inverses, per layer, with the reference's implementation as the
porting map. This section is the work inventory; the `EN` matrix (§6) is
the same material as requirement rows.

### 2.1 The stream and meta-block assembly

- **The stream header**: `EncodeWindowBits` (`encode.c:178-198`) writes
  §9.1's 1-7-bit WBITS code; the window arithmetic is `(1 << lgwin) - 16`
  (`BROTLI_WINDOW_GAP = 16`, the same `-16` the decoder's §9.1 rule uses).
- **MLEN**: `BrotliEncodeMlen` writes MNIBBLES 4/5/6 (the 2-bit code) and
  MLEN-1 in nibbles, least significant first; with MNIBBLES > 4 the most
  significant nibble must be nonzero (§9.2's rejection rule — the encoder
  obligation is to never emit the rejected form).
- **The minimal header**: the trivial class's header after MLEN is exactly
  13 zero bits — NBLTYPESL/I/D = 1 (one bit each), NPOSTFIX (2), NDIRECT
  (4), one context mode (2), NTREESL (1), NTREESD (1) — verified on the
  wire by the walker at `q2`/`q3` on every shape.
- **The uncompressed path**: `BrotliStoreUncompressedMetaBlock`
  (`brotli_bit_stream.c:148-163` + the writer): ISUNCOMPRESSED can never
  sit on an ISLAST meta-block (§9.2: "this field is only present if the
  ISLAST bit is not set"), so an uncompressed *final* meta-block is written
  as an uncompressed non-last block followed by the empty
  ISLAST+ISLASTEMPTY pair — exactly what the CLI emits on the incompressible
  shapes (§1.3). The rollback rule (`encode.c:585-596`): save the bit
  position and the distance cache before a meta-block, and if the
  compressed form would exceed `bytes + 4`, restore both and store
  uncompressed. The distance-cache restore matters: a rolled-back
  meta-block's ring updates must not survive (§2.6).
- **The flush cadence**: below `MIN_QUALITY_FOR_BLOCK_SPLIT`, the encoder
  buffers at most `MAX_NUM_DELAYED_SYMBOLS = 0x2FFF` literals-and-commands
  (`quality.h:33-35`; the flush check at `encode.c:1131`) — measured as a
  65,536-byte first-meta-block cadence on the 390 KB text at `q2`/`q3`.
  A byte-parity port must reproduce this cadence exactly (the measured wire
  fact; the symbol-budget-to-bytes mapping is derived in the port, not
  here — open question §8).
- **The last-byte carry**: meta-blocks are *not* byte-aligned between each
  other — the encoder carries the final partial byte in `last_bytes_` /
  `last_bytes_bits_` and the next meta-block's header continues inside it
  (`encode.c:1160-1180`). Only ISLAST (and uncompressed/metadata blocks)
  byte-aligns, via `JumpToByteBoundary` with zero fill (§9.2's "remaining
  bits ... filled with zeros"). §11.2 documents the optional per-meta-block
  alignment trick (an empty metadata meta-block after each block) — a
  non-goal for the first encoder (it costs bytes and no reference output
  uses it).

### 2.2 The prefix-code construction and emission

The decoder's `huffman.zig` *reads* trees; the encoder must *build* them —
three distinct pieces of machinery:

- **The depth-limited tree builder**: `BrotliCreateHuffmanTree`
  (`entropy_encode.c:60-145`) — a two-queue merge over a sorted leaf array
  (the `SortHuffmanTreeItems` comparator: count, then
  `index_right_or_value`, `entropy_encode.c:396-398` — the tie-break is a
  parity detail), with `tree_limit = 15` for the main codes and 5 for the
  code-length code, and the `count_limit`-doubling retry loop ("add fake
  entities to the lowest values and retry") that guarantees the depth
  limit. The fast variant `BrotliBuildAndStoreHuffmanTreeFast`
  (`brotli_bit_stream.c:404-470`) is the fragment class's builder.
- **The canonical assignment**: §3.2's algorithm verbatim (steps 1-3) —
  `BrotliConvertBitDepthsToSymbols`. The same assignment our decoder's
  `huffman.Tree.build` uses to lay out its tables; the encoder must assign
  identical codes for identical depth sets (§3.2's two ordering rules are
  normative, not a convention).
- **The emission** (`BuildAndStoreHuffmanTree`, `brotli_bit_stream.c:349-397`):
  count the nonzero symbols — ≤1: the 4-bit simple-NSYM=1 form (a
  zero-length code, §3.4's "no actual bits are emitted"); ≤4: the simple
  form (NSYM-1 in 2 bits, NSYM × ALPHABET_BITS symbols *sorted by depth*
  per §3.4's "same bit length must be assigned to the symbols in sorted
  order", the tree-select bit at NSYM=4); else the complex form:
  `BrotliWriteHuffmanTree`'s RLE serialization of the depth sequence
  (the `DecideOverRleUse` heuristic — 16/17 runs only when profitable,
  another parity detail), then the code-length code over the fixed 18-symbol
  order with its own 2-4-bit static code (`brotli_bit_stream.c:176-190`,
  §3.5's table), the HSKIP choice (`skip_some` 0/2/3, the trailing-zero
  omission), and the Kraft equalities: 32 for the code-length code, 32768
  for the main code (§3.5). The 16/17 repeat counts are *cumulative*
  ("modifies the repeat count of the previous one", §3.5) — the one §3.5
  subtlety that cost this research a serializer round-trip to pin down
  (§0's validation (c)).

The static entropy codes of the `q2` class (`entropy_encode_static.h`) are
precomputed depth tables emitted as fixed bit patterns — 59 bits for the
command tree, 28 for the distance tree (`entropy_encode_static.h:524-539`)
— plus the `kStaticContextMap*UTF8` tables the fragment compressors use
with `kCmdHistoSeed` (`compress_fragment.c:117-168, 410-417`).

### 2.3 The command stream assembly

- **The insert-and-copy length codes**: `GetInsertLengthCode` /
  `GetCopyLengthCode` / `CombineLengthCodes` (`command.h:44-110`) compute
  the 704-symbol table position (§5) from (insertlen, copylen,
  use_last_distance) — including the 64 short-codes row that packs small
  insert+copy pairs with the "same as last distance" flag, and the magic
  constant `0x520D40` that lays out the nine offset blocks. The decoder
  reads this table (`command.zig`); the encoder must produce exactly its
  inverse.
- **The command record**: `InitCommand` (`command.h:130-155`) packs
  insert_len, copy_len *plus a signed copy-code delta*
  (`copylen_code_delta`) — the delta exists because a static-dictionary
  match's *copy length* can differ from its *produced length* (the
  transformed word is longer or shorter than the match), and the IaC code
  must describe the produced length. `CommandRestoreDistanceCode` and the
  `dist_prefix_`/`dist_extra_` packing are the §4 distance encoding's
  inverse (`PrefixEncodeCopyDistance`); `CommandDistanceContext`
  (`command.h:157-164`) is the §7.2 context for the distance trees (the
  split classes only).
- **The emission order** (`StoreDataWithHuffmanCodes`,
  `brotli_bit_stream.c:1113-1167`): per command — the literals (each under
  the literal tree selected by the context ID; the trivial class's context
  is always 0, so no p1/p2 lookups), then the IaC symbol plus insert extra
  bits plus copy extra bits, then the distance symbol plus extra bits. This
  must be §10's decode order *exactly* (§2.6).
- **The distance ring, encode side**: the four-entry ring (init
  16/15/11/4, stream-scoped — the decoder's `distance.zig` mirror), pushed
  *only* by window matches: `if ((sr.distance <= dictionary_start + gap) &&
  distance_code > 0)` pushes (`backward_references_inc.h:112-126`); a
  static-dictionary reference does **not** push the ring, and the decoder
  compensates ("Compensate double distance-ring-buffer roll for dictionary
  items", `c/dec/decode.c:1693`) — the encoder that pushed on dictionary
  matches would desync every later short-code distance.

### 2.4 The static-dictionary decision path

The decode side ships the dictionary (§8's 122,784 bytes + 121 transforms,
`dictionary.zig`); the encode side needs the *decision* machinery — at the
fast classes it is small and entirely local to the match loop:

- **The trigger**: when the hasher found no window match scoring above
  `kMinScore` — `if (USE_DICTIONARY && min_score == out->score)`
  (`hash_longest_match_quickly_inc.h:255-260` for the `q2`-`q4` quickly
  hashers, with `shallow = BROTLI_TRUE`; the chain hashers call it deep
  from `hash_longest_match_inc.h:270-277`).
- **The throttle**: `dict_num_matches < (dict_num_lookups >> 7)` returns
  early (`hash.h:171-176`) — once the dictionary stops paying (fewer than
  one hit per 128 lookups) the search stops for the meta-block.
- **The lookup**: `Hash14(data) << 1` — two adjacent buckets in a
  precomputed hash table of the dictionary's words
  (`static_dict_lut_inc.h`, 457 KB of generated table; `encoder_dict.c`
  builds the structure at setup). This table is *encode-side data the
  package does not ship yet* — the representation choice is EQ4.
- **The item test**: `TestStaticDictionaryItem` (`hash.h:132-165`) — the
  *cutoff transforms* fast path: only the first few identity-ish transforms
  (the packed `cutoffTransforms`, `encoder_dict.c:418-470`) are searched,
  `matchlen` must cover all but a small suffix (`cut = len - matchlen`
  indexes the transform), and the emitted distance is §8's formula:
  `max_backward + 1 + word_idx + (transform_id <<
  size_bits_by_length[len])`, with `len_code_delta = len - matchlen`
  feeding §2.3's copy-code delta. The full 121-transform trie search
  (`BrotliTrieInit`, `encoder_dict.c`) is `q10`/`q11`-only — the fast
  classes never touch it.
- **The wire obligation**: a dictionary reference's *produced* length
  (the transformed word's length) is what MLEN accounting must count —
  §9.3's rule the M6 decoder review pinned (`src/brotli/AGENTS.md`, the
  F-rows); the copy length alone can overrun or underrun MLEN.

### 2.5 The match finder (the `q3` class's)

`CreateBackwardReferences` (`backward_references_inc.h`, the generic loop
the quickly hashers plug into): greedy scan; `FindLongestMatch` per
position (the quickly hasher: one bucket, `BROTLI_HASH_MAX`-sweep of
1-2 candidates, 4-byte confirm then `FindMatchLengthWithLimit`); the
score model `BackwardReferenceScore = BROTLI_SCORE_BASE +
LITERAL_BYTE_SCORE * len - DISTANCE_BIT_PENALTY * log2floor(dist)`
(`hash.h:100-128`); the lazy second search only at `q5`+
(`MIN_QUALITY_FOR_EXTENSIVE_REFERENCE_SEARCH`, the `cost_diff_lazy = 175`
threshold, `backward_references_inc.h:60-106`); the sparse-search heuristic
for long literal runs (strides 8 then 16, `quality.h:99-104` and
`backward_references_inc.h:150-185`); the hash-store range with the
"avoid hash poisoning with RLE data" adjustment
(`backward_references_inc.h:130-144`). The quickly hasher's own table is
sized by input (`GetHashTable`, `MaxHashTableSize = 1<<15` at `q0`,
`1<<17` above — `quality.h:36-39`, `encode.c:140-170`).

### 2.6 The backward-safety rules — emit exactly what §10 advances

The decoder is a state machine (`§10`); an encoder is conformant exactly
when its output drives it without divergence. The rules the port must hold,
each with its failure mode:

| rule | the obligation | cite |
|---|---|---|
| the decode order | literals, then the IaC symbol and extras, then the distance symbol and extras — the exact order `StoreDataWithHuffmanCodes` emits and §10 reads | §10, `brotli_bit_stream.c:1113-1167` |
| the ring push | window matches only; dictionary references never push; a rolled-back meta-block restores the saved ring | `backward_references_inc.h:112-126`, `encode.c:585-596` |
| MLEN vs produced length | the dictionary word's produced length counts, not the copy length; never overrun | §9.3, `src/brotli/AGENTS.md` (the MLEN pin) |
| Kraft exactness | 32 for every code-length code, 32768 for every main code, depths ≤ 15 | §3.5, `BrotliCreateHuffmanTree(tree_limit=15)` |
| the trailing rules | trailing zero lengths omitted; the last code-length symbol is 1..16; MNIBBLES' top nibble nonzero when > 4 | §3.5, §9.2 |
| the byte fill | ISLAST's tail is zero-filled; ISUNCOMPRESSED's skipped bits are zero | §9.2 |
| the alphabet bounds | every emitted symbol < its alphabet (literal 256, IaC 704, distance `16 + NDIRECT + (48 << NPOSTFIX)`); every context-map value < NTREES; NTREES equals the distinct values used | §3.3, §7.3 |

### 2.7 What the first target class does not need

The point of the class choice, made concrete — at `q3` the encoder needs
**none** of: the block splitter and its clustering (`block_splitter.c`,
`block_splitter_inc.h`, `cluster_inc.h` — 30 KB of the reference), the
block-switch emission of §6 (the type/count prefix codes and the in-data
switch commands), the literal context modeling of §7 (the context maps,
RLEMAX, IMTF — the decoder's whole `context.zig` wire surface has no
`q3` encode counterpart beyond the 2-bit mode field), the NPOSTFIX/NDIRECT
search, the histogram re-optimization, the zopfli hasher and its trie, the
SIMD/forgetful-chain hashers, the HQ splitter, or the fragment
compressors' metablock-merge machinery. The §7.3 obligation "NTREES must
equal the number of different values" and friends are vacuously satisfied
by NTREES=1.

## 3. The parity question

### 3.1 The reference is deterministic

Measured (§1.3): two encodes per (shape, quality) byte-identical across
the sweep; the 390 KB text byte-identical across independent processes and
batteries; and the bench lane's cross-build row (q11 byte-identical across
compilers, FMA settings, and wasm32) — `bench/AGENTS.md`. Single-threaded,
no RNG, no time dependence: the ladder is deterministic at every quality.
**A byte-parity pin is well-defined at any quality.**

### 3.2 The CLI is the library (the recipe)

The CLI's file form is exactly the C library's streaming encoder with
parameters set from the file — no CLI-private processing. Measured both
ways on the 390 KB text at all twelve qualities:

- `brotli -q N -c FILE` (auto window by size, `SIZE_HINT` = file length)
  is **byte-identical** to `BrotliEncoderCompressStream` at (quality,
  `LGWIN` = the auto window, `SIZE_HINT` = length), whole input, one
  FINISH — 12/12 rows.
- `brotli -q N -w 22 -c FILE` is **byte-identical** to the library at
  (quality, `LGWIN` 22) — 48/48 rows over four shapes × twelve qualities,
  *with or without* the size hint at these sizes (≤ 390 KB).

So the parity recipe a `Writer`-shaped encoder pins is the second one:
**quality + window, no size knowledge** — which is exactly the streaming
shape (§1.5's point 5: at `q3` the hint is structurally unused).

### 3.3 The Go reference diverges below `q5`

Measured (library form, `LGWIN` 22, no hint, vs `NewWriterLevel`):
byte-identical at `q5`-`q11` on nearly every shape (the exceptions: two
1-byte differences at `q10`/`q11` on `text32`), **byte-divergent at `q0`-
`q4` on nearly every shape** (differences of 1-35 bytes, both directions).
The Go's fast tiers — its `compress_fragment.go` and
`hash_longest_match_quickly.go` ports — do not reproduce the C 1.2.0's
output. Consequences, recorded for the port:

- **The C source is the algorithm source of record for any fast-class
  port** (the `q3` recommendation included). The Go remains the
  readability companion (the same algorithm, one file per hasher, no
  macros) and the second *decoder* family for the oracle — which is how
  the M6 lane already uses it.
- A port whose parity source is the Go would pin a moving target: the Go's
  own roadmap marks its new matchfinders experimental. Not eligible.
- The divergence cause is undiagnosed (not needed for the port; §8).

### 3.4 The size hint

At `LGWIN` 22 on shapes ≤ 390 KB: the hint changed zero bytes at every
quality (96 rows). Structurally (§1.5): the hint first matters at `q4`
(`ChooseHasher`'s ≥ 1 MiB branch) and in `q5`+ context modeling. The
`q3` class is hint-independent by construction; the open residue is only
"does a ≥ 1 MiB input at `q4`+ change class" — moot for the recommended
first target, recorded for the ladder's later steps.

### 3.5 The parity recommendation

**Byte parity with the pinned CLI at the chosen quality, one-shot form**
(the `zstd -1` precedent, with the recipe of §3.2: the pin is
`brotli -q 3 -w <W> -c FILE` for a caller-chosen W; the corpus pins
per-shape W the same way the zstd lane pins its windows), **plus
valid-stream parity for the streaming `Writer`** — measured reality: a
`Writer` that flushes at its own buffer boundaries produces *different*
metablock cadences than the one-shot (§2.1's flush rules are the
encoder's own), so its streams cannot be byte-pinned to the CLI; their
contract is that the CLI, the Go, and our decoder all decode them, and
the ratio/speed comparison happens on the fleet grid, not against a
pinned byte stream. This mirrors the zstd encoder's split (the one-shot
is the byte-parity artifact; the streaming form is oracle-verified), and
the oracle extension is EQ7.

The alternative — valid-stream parity only, everywhere — is strictly less
for more work: the byte-parity pin costs nothing extra at the one-shot
(the algorithm is the same), gives the oracle a hard equality assertion
per row, and matches the house precedent. Rejected.

## 4. The custom-dictionary negative, re-verified

The standing negative (`dictionary-notes.md` §5.2, reaffirmed by the M6
milestone row) holds, re-verified live this session with the pinned
references:

- **The RFC has no custom-dictionary concept** — `rfc7932-brotli.txt`'s
  "dictionary" is always the static dictionary of §8/Appendix A
  (`dictionary-notes.md` §5.2's full-text finding; unchanged since).
- **The C library's extension surface exists but is an extension**:
  `BrotliEncoderPrepareDictionary` / `BrotliEncoderAttachPreparedDictionary`
  (`c/include/brotli/encode.h`) and `BrotliDecoderAttachDictionary`
  (`decode.h`) — the raw-LZ77-prefix "prepared dictionary" kind; the
  *serialized* shared-dictionary form is explicitly marked "DO NOT USE:
  methods accepting this value will fail" (`shared_dictionary.h:41-49`).
  A `-D`-encoded stream is not an RFC 7932 stream.
- **Measured this session**: `brotli -q 5 -D <8 KiB prefix> -c README.md`
  encodes (1,819 bytes, exit 0); the CLI decodes it **only** with `-D`
  (exit 1 without); and **our decoder refuses it naturally** (the oracle
  harness exits 1 — the distances fall past the window and the dictionary
  boundary, exactly the recorded refusal class,
  `src/brotli/AGENTS.md` "Extensions are out of scope (OQ7, T3)").
- **The encoder side gains nothing from softening this**: a brotli encoder
  with a custom dictionary would emit streams no conformant decoder (the
  CLI without `-D`, the Go, ours) accepts — worse than zlib's FDICT case,
  where at least the wire declares the dependency.

**Recommendation: the negative stands.** No dictionary-supplying API on
the brotli encoder; the README's not-implemented line keeps its evidence
trail (this section). Revisit only under the same condition the flate
register used: a real corpus of `-D`-encoded brotli appearing — and note
that even then the *decoder* is the cheap side to extend (a raw LZ77
prefix is preset history), while the encoder would need the extension's
own format decisions, which the RFC does not license.

## 5. The design decisions for the parent (the `EQ` register)

House constraints applied throughout (`AGENTS.md`, "Rules"): the barrel
exposes exactly `{Reader, Writer, encode, decode}` per codec namespace;
the README is written first as the API sketch; exact-pointer named buffer
types; no heap on hot paths, setup allocation documented at the API;
`anytype` is a last resort; fastmem only for copies. Each decision below
carries a default; Matt's review picks.

### EQ1 — The first target class

*Options*: (a) **`q3`** (trivial: fresh trees, one emission path, the
minimal header); (b) `q2` (static entropy codes: the flate-fixed-Huffman
analogy, a second emission branch, 87 bits of constants, ~15% faster
than `q3` at the CLI level and ~17.5% in-process (the corrected figures,
§1.5), worse ratio on 8 of 11 shapes); (c) `q4` (the split
class: where the dictionary pays and the ratio ladder starts, at -29%
throughput and the whole splitter port); (d) `q0`/`q1` (the fragment
family: fastest, but a throwaway algorithm family — §1.5).
*Default*: **(a) `q3`**, per §1.5. The shared machinery (hasher, greedy
loop, tree build, command math, dictionary path) is identical for (a) and
(b), so (b) can follow as a speed class without rework; (c) is the
natural second milestone; (d) is never worth the port.

### EQ2 — The parity pin

*Options*: (a) **byte parity, one-shot, with the CLI at
`brotli -q 3 -w <W>`** (the §3.2 recipe: the library form, no size
knowledge; the oracle asserts equality per row); (b) valid-stream parity
only (every reference decodes our output; ratio/speed measured on the
grid).
*Default*: **(a)** for `encode.compress`, with the `Writer` carrying (b)
by construction (§3.5). The pin's W is the caller's window parameter —
the corpus rows pin per-shape W the way the zstd lane pins its windows.

### EQ3 — The public surface and the buffer shape

*Options*: (a) **`brotli.encode.compress(source, target)`** returning the
compressed length, target a cap, plus `brotli.Writer` — with a
caller-owned named buffer type for the encoder's scratch: the hash table
(up to `1<<17` u32 entries = 512 KiB at `q3`'s bucket bits 17, sized by
input at runtime), the command/literal buffers (the `MAX_NUM_DELAYED_SYMBOLS`
budget: 0x2FFF commands × 8 B + literals), and the tree-build scratch —
`encode.Buffer` in the `Reader.Buffer` pattern, one type, exact pointers
at init; (b) an allocator-taking init for the table alone; (c) comptime
window/quality generics with the table on the caller's stack (rejected:
512 KiB is not stack-scale, per the house rule and the zstd
`DefaultBuffer` precedent).
*Default*: **(a)** — the one-shot's scratch mirrors the decoder's
`frame.Header` posture (comptime-capped regions, zero allocation), with
the buffer type documented in the README with its size figure. The
quality is a runtime parameter (an enum with named levels? the C's
0..11 integers? — the README sketch decides; default: a named-level enum
with exactly the ported classes, not a free 0..11 dial, since only
ported classes can be honest).

### EQ4 — The encode-side dictionary table

*Options*: (a) **comptime-generate the `Hash14` lookup from the shipped
dictionary** (`dictionary.bin` + the transforms are already `.rodata`; the
generator is a build-time or comptime pass over the words, the same shape
as `scripts/brotli_dictionary_gen.py`); (b) vendor the C's generated
`static_dict_lut_inc.h` (457 KB of source, generated by the reference's
own tool — a faithful copy, attributed); (c) no table: compute candidate
words by direct hashing at runtime (rejected: a per-position dictionary
scan without the LUT is not the reference's algorithm and would cost more
than the LUT's `.rodata`).
*Default*: **(a)** — the house's generator pattern, no new vendored bytes,
and the generated table is pinned by a test against the C's table (the
instrumented copy prints it). (b) is the fallback if comptime generation
busts the build.

### EQ5 — The streaming `Writer`'s flush cadence

*Options*: (a) **flush at the house buffer boundary, oracle-verified
streams** (the §11.3 self-contained rule observed: the distance ring
replenished within the part, no reference into the previous part's
bytes or dictionary words unless the window carries them — the RFC's own
constraint on independently-compressed parts); (b) mimic the one-shot's
`MAX_NUM_DELAYED_SYMBOLS` cadence exactly (byte-closer to the CLI on
streamed input, still not byte-equal — the input arrival differs).
*Default*: **(a)**; the cadence is a tuning knob for the fleet wave, and
§11.3's rules are the conformance obligations that keep parts
independent.

### EQ6 — The error set

*Default*: one name per failure class, the decode register's discipline
(`src/brotli/AGENTS.md` OQ5): `TargetTooSmall` (the cap, the snappy
`compressBlock` shape — there is no max-length formula: the worst case is
the input plus the §11.1 bound `3 * (N >> 16) + 5`), and the Writer's Io
names per the pattern book. No encode-side `BadHuffmanCode`-class names:
the encoder's own trees are correct by construction, and the only hostile
input is a target too small.

### EQ7 — The oracle lane extension

*Default*: extend `scripts/brotli_oracle.py` with the encode direction on
the same corpus rows: our encoder's output must (1) decode byte-exact
through the CLI, the Go, and our own decoder, and (2) be **byte-identical
to `brotli -q 3 -w <W> -c FILE`** per row (the EQ2 pin). The fuzz lane
(`src/brotli/fuzz.zig`) gains round-trip targets (encode → our decode ==
identity, the fuzz-engineer lane's shape).

## 6. The requirements matrix (the `EN` rows)

A conformant brotli encoder at the recommended first class (`q3`,
trivial emission), with the rows the higher classes add marked. Every row
cites the spec section and/or the reference source.

| # | requirement | cite |
|---|---|---|
| EN1 | Every emitted stream decodes through the reference CLI, the Go reference, and this package's decoder; the one-shot is byte-identical to the pinned recipe | §1.4, §3.2 (measured 12/12, 48/48) |
| EN2 | WBITS via §9.1's code, window arithmetic `(1 << lgwin) - 16`; the caller's window, 10..24 | §9.1, `encode.c:178-198` |
| EN3 | ISLAST/ISLASTEMPTY; MNIBBLES 4/5/6 with MLEN-1, most-significant nibble nonzero when MNIBBLES > 4; MLEN ≤ 2^24 | §9.2, `BrotliEncodeMlen` |
| EN4 | ISUNCOMPRESSED never on an ISLAST meta-block; an uncompressed final block is followed by the empty ISLAST+ISLASTEMPTY pair; skipped bits zero-filled | §9.2, `brotli_bit_stream.c:148-163` |
| EN5 | The trivial header: NBLTYPESL/I/D 1, NPOSTFIX 0, NDIRECT 0, one context mode, NTREESL/NTREESD 1 — the 13 zero bits | §9.2 (measured, the walker) |
| EN6 | The uncompressed rollback: compressed form > `bytes + 4` → restore the bit position and the distance ring, store uncompressed; `ShouldCompress`'s sampler may refuse first | `encode.c:433-463, 585-596` (measured: +4 exactly, at every quality) |
| EN7 | Every prefix code canonical per §3.2's steps 1-3; depths ≤ 15; Kraft 32768 for main codes, 32 for code-length codes | §3.2, §3.5, `entropy_encode.c:60-145` |
| EN8 | The simple form at ≤ 4 nonzero symbols (NSYM, ALPHABET_BITS widths, sorted-order assignment, tree-select); the 4-bit NSYM=1 form at ≤ 1; the complex form otherwise — HSKIP, the fixed bit-length code, the 16/17 RLE with cumulative counts, trailing-zero omission | §3.4, §3.5, `brotli_bit_stream.c:242-397` |
| EN9 | The 704-symbol IaC table (§5) exactly: the length-code math, the 64 short codes, the extra-bit ranges | §5, `command.h:44-110` |
| EN10 | Distances per §4: the prefix encoding's inverse, extra bits, the reconstruction matching the decoder's formula; at the first class NPOSTFIX 0/NDIRECT 0 | §4, `PrefixEncodeCopyDistance` |
| EN11 | The distance ring: init 16/15/11/4, stream-scoped; pushed by window matches only, never by dictionary references or rolled-back meta-blocks | §9.3, `backward_references_inc.h:112-126`, `decode.c:1693` |
| EN12 | Emission order = §10's decode order: literals (context 0 at the first class), IaC symbol + insert/copy extras, distance symbol + extras | §10, `brotli_bit_stream.c:1113-1167` |
| EN13 | The dictionary decision path: the fallback trigger (no window match above min score), the throttle, the `Hash14<<1` lookup, the cutoff-transform item test, §8's distance formula, `len_code_delta` | §8, `hash.h:132-198`, `hash_longest_match_quickly_inc.h:255-260` |
| EN14 | A dictionary reference's produced length (not copy length) counts toward MLEN; word lengths 4..24 | §8, §9.3, `src/brotli/AGENTS.md` (the MLEN pin) |
| EN15 | The flush cadence at the first class: the `MAX_NUM_DELAYED_SYMBOLS` budget (measured 65,536-byte meta-blocks on the 390 KB text) | `quality.h:33-35`, `encode.c:1131` |
| EN16 | The last-byte carry across meta-blocks; byte alignment (zero fill) only at ISLAST and uncompressed/metadata blocks | §9.2, §11.2, `encode.c:1160-1180` |
| EN17 | (q2 class) the static command/distance trees (448×9+256×11 and 64×6 depths; the 56+3- and 28-bit patterns) at ≤ 128 commands; fresh trees above | `entropy_encode_static.h:25-80, 524-539` |
| EN18 | (q4+) block splitting, NPOSTFIX/NDIRECT search, histogram optimization, block-switch emission of §6 | `encode.c:534-577`, §6 |
| EN19 | (q5+) literal context modeling, the §7.3 context-map writer (RLEMAX, IMTF), NTREES = distinct values | §7.1, §7.3, `encode.c:407-432` |
| EN20 | (Writer) §11.3's self-contained-part rules at flush boundaries: the ring replenished in-part; no reference into the previous part's bytes or dictionary words beyond the window | §11.3 |

## 7. The oracle plan

The lane extends `just brotli-oracle` (`scripts/brotli_oracle.py`, today
decode-only) with the encode direction, per EQ7:

1. **The parity rows**: every corpus shape at the pinned recipe
   (`brotli -q 3 -w <W> -c FILE`) vs our one-shot — byte equality per row
   (the EQ2 pin; the sweep here is the template).
2. **The decode-direction rows stay**: our encoder's output through the
   CLI, the Go, and our decoder (three decoders, one family of streams).
3. **The corner batteries**: the empty input (the `06` stream — §11.1's
   own fixture, already in `golden.zig`), the incompressible shapes
   (ISUNCOMPRESSED at every quality — §1.3), the dictionary-bearing text
   (the `q3` census rows: zero references expected on the corpus, the `q2`
   rows as the contrast), the > 65,536-byte cadence inputs (the flush
   rule), and the truncation of *our own* output (a Writer partial-flush
   stream decodes as a prefix).
4. **The instrumented census** rides along for the class fingerprints
   (the patched copy is in the scratch tree; the patch is three lines and
   rebuilds in ~30 s — worth keeping as a lane tool while the ladder
   climbs to `q4`+).

## 8. The ranked ambiguities

For the parent, ranked by what they gate; each with what would close it.

1. **The walker's `q4`+ introspection bug** (gates nothing in this file's
   recommendation; gates the *block-split* fingerprint table if the ladder
   climbs). 12 of 132 sweep rows fail to walk — all `q4`+ on ≥ 32 KB
   inputs, both failure modes being run-overrun asserts inside the §6/§7.3
   wire the walker added for the split classes. The q4+ rows in §1.3 came
   from the dictionary census and the C's debug log instead (both
   ground-truth instruments). Close it by fixing the walker's block-count
   or context-map reader against the C's log on one failing stream.
2. **The flush-cadence derivation** (gates the byte-parity port's
   meta-block boundaries). Measured: 65,536-byte first meta-blocks at
   `q2`/`q3` on the 390 KB text. Source: the `MAX_NUM_DELAYED_SYMBOLS`
   symbol budget plus the command-buffer sizing at `encode.c:1906`. The
   symbol-budget → byte-cadence mapping for arbitrary inputs is derived
   in the port slice (it is a property of the greedy loop's command
   density), not here. The port's oracle rows will pin it per shape.
3. **The `q2` dictionary-search behavior** (gates only an EQ1=(b) choice).
   Measured: `q2` emits 2-4 references on 5 of 9 compressible shapes,
   `q3` zero on all 11 — same call site, different outcome. Cause not
   derived (the h02 bucket-16 fallback firing where h03's bucket-17 does
   not). If Matt picks `q2`, the port must match this exactly; the census
   rows in §1.3 are the pin.
4. **The Go divergence cause** (gates nothing; a recorded row). The Go
   v1.2.6 diverges from the C 1.2.0 at `q0`-`q4`, matches at `q5`-`q11`
   (two 1-byte exceptions). Undiagnosed; the C is the port source either
   way. Worth one line in THIRD_PARTY.md's Go row if the Go is ever used
   as an encode-side reading reference below q5.
5. **The fleet speed rows** (gates the EQ1 speed claims about *our*
   encoder). The MB/s column in §1.3 is the pinned CLI's curve — the
   reference's, not ours. The fleet grid after the port measures the
   ported class against it (the `bench/` harness's brotli competitor rows
   already exist from the decode wave).
6. **The ≥ 1 MiB size-hint classes** (gates the ladder's `q4`+ steps, not
   the first target). Unmeasured here (all shapes ≤ 390 KB): the hint's
   hasher-class flip at `q4` and the context-modeling consultations at
   `q5`+. Moot at `q3` (structurally hint-independent); measure before
   any `q4` port.

The deliverable's own residuals: this file records no Zig code (the
research lane's rule), commits nothing (the parent reviews and commits),
and leaves `docs/research/level-ratio-notes.md` (a sibling lane's file)
untouched.
