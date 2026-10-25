# Agent notes: flate

Raw DEFLATE (RFC 1951): a fixed-Huffman encoder with a stored-block fallback, an
inflate for all three block types, and a streaming `Io` layer over both.
`README.md` is the user contract; this file holds the decisions and traps behind
it. The research is `docs/slop/research/flate-notes.md` (flate-notes §N). T1-T5 are
its divergence ids (§2.3) and OQ1-OQ6 its open questions (§6). The generated
`Io.Writer` and `Io.Reader` entries (drain top-up, rebase, sticky failure) are
explained in `src/internal/AGENTS.md`. Attribution is in `THIRD_PARTY.md`.

## Design decisions

- No framing of our own (OQ2). BFINAL self-delimits the stream. The Reader
  decodes straight from the input `Io.Reader` through a bit reader with a few
  bytes of lookahead: a Huffman block has no compressed length, so there is no
  staging region. std's decoder works the same way (flate-notes §5.4).
- Level 1 is fixed Huffman with a stored fallback (OQ1). Fixed emission needs
  no header, precode, or table build, and zlib-ng's fastest level is fixed-only
  too (flate-notes §5.3). The cost is ratio: a literal takes 8-9 bits against
  about 5 dynamic on text — which is what level 6 buys (the dynamic emitter,
  klauspost's wider finder, and the per-block dispatch).
- The match finder is klauspost's level-1 shape (OQ3); encode.zig's header
  describes it. It is greedy because every fast-level reference is lazyless.
  Minimum match is 4; 3-byte matches wait for the level-6 finder.
- Level 6 is a byte pin, not a class pin: the finder (`Finder6`, encode.zig)
  and the dynamic block machinery (`dynamic.zig`) are ports of
  klauspost/compress's `flate/level6.go` and its `huffman_bit_writer.go` +
  `huffman_code.go`, and the emitted bytes must equal theirs for the pinned
  module version (scripts/klauspost_flate, the oracle's level-6 lane). The
  pin is what forces the ports' fidelity: the empty-slot sentinel
  (`finder_origin` = 65535, klauspost's `cur`, so a zero table entry is
  unreachable by the distance cap), the *full* final block emitted with
  `sync` (their `Close` processes a still-full window), the deferred
  end-of-block code a non-final dynamic block owes, and the two candidate
  tables' exact store order.
- Two port traps, both found by the parity lane and worth keeping in mind
  when touching either scan:
  - Zig lowers `slot.* = .{ .cur = x, .prev = slot.cur }` field-wise, so the
    `prev` read sees the *new* cur. Go's multiple assignment reads the old
    one. Every table store that chains a previous entry captures the old cur
    in a local first (`storeAhead`, the in-between loops).
  - In the end-of-match check, the second candidate's `t2 = prev - l + 2` is
    computed with the possibly *updated* `l` (Go reads the current value);
    hoisting `l` into a local before the first check diverges the output.
- The dynamic emitter's numbers that are part of the bytes: the tree
  construction (`bitCounts` + `assignEncodingAndSize`, klauspost's
  level-by-level build with the 15-bit cap), the codegen run codes (16/17/18),
  the `filled` alphabet shortcut (`indexTokens(tokens, true)` → HLIT 286 /
  HDIST 30 for every mid-stream block), the table-reuse estimate
  (`EstimatedBits`'s float32 log2, `logNewTablePenalty` 7), the literals-only
  block's 70-byte header guess, and the 1/16th huff-vs-dynamic rule. The
  *sorts* (`sortByFreq`/`sortByLiteral`) are not ported: their comparators
  are total orders on unique keys, so any correct sort produces the same
  lists.
- Level 6's one-shot and streaming layers must agree byte for byte: the
  one-shot splits blocks exactly as `Write` + `Close` do (a full block is
  emitted mid-stream only when input follows it; the last block, full or not,
  is the `sync` one), and the streaming `Writer` gets the same split from the
  generated writer machinery (a full block region drains only when the next
  write needs the room). `Writer.finish` sets `finishing` so the final block
  is emitted with `sync`; `writeEnding` flushes any owed end-of-block code
  before the empty fixed block.
- A preset dictionary primes the level-6 tables the way klauspost's
  `fillWindow` does: a full scan over the dictionary's tail with the tokens
  discarded, run before the first block. The one-shot's priming scan uses the
  dictionary itself as the window's stream (its positions are the window
  positions the block scans use), never the `Window(preset)` shape, whose
  `source` side assumes the block is in the stream's own region.
- One deliberate divergence in the streaming layer: a block under 13 bytes
  (`minNonLiteralBlockSize`) cannot hold a match, and klauspost's finder marks
  it with its token count rather than a token list — a marker only its own
  close-time path reads, because its window never flushes a tiny block
  mid-stream. Our `flush` and `rebase` can, so `compressBlock6` writes such a
  block as stored before the finder runs. The one-shot path is unaffected
  (its sub-128-byte final block takes the close-time branch), so the byte pin
  holds; the `Writer` test with a flushed 1-byte block pins the divergence.
- The `Writer`'s finder state is a union of the two level classes, so a
  level-1 `Writer` reserves the level-6 tables (392 KiB total against the old
  128 KiB). The alternative — two optional fields — is 512 KiB, and an
  allocator-taking `init` would break the committed signature. Documented in
  the README's Stack paragraph.
- Writer layout (OQ4). `Writer.Buffer` is the retained history followed by the
  block region, so the encoder's window is one contiguous slice. The block
  region (`writer.buffer`) is always the `max_block_size` bytes after the
  history. `emitBlock` advances the region in place; `compact` runs only when
  the region would pass the end of `Buffer`, and trims history to `history_len`,
  the farthest a match reaches. So the generated `rebase` finds its room in the
  block region (it asserts `preserve + capacity <= max_block_size`) and never
  gives up history, which is the full 32 KiB once that much has been emitted.
  `rebase` emits all buffered input except the last `preserve` bytes and never
  discards any.
- Preset dictionaries (OQ6 retired): the decode's history gains a caller-owned
  prefix (`dict: ?[]const u8` on `decode.decompress`, `Reader.init`, and
  `Reader.streamAll`), and the encoder primes its table from the dictionary
  (`encode.Options.dict`; the density is the measured choice — the C inserts
  every position at every level, Go's level-1 skips the pre-hash — landed as
  the C's stride-1 shape, `dictionary-notes.md §4`, DQ6/DT7). The two window
  shapes follow the buffer's owner: the streaming `Reader` copies the
  dictionary's tail into its window's front (`total_out` starts at its
  length, so the reach check counts it) and the streaming `Writer` copies it
  into its buffer's front (`block_start` starts there), while the one-shot
  paths keep it as a second region — `encode.Window(preset)` for the finder
  and `decode.copyMatchHistory` for the match copy. Both shapes treat the
  dictionary as conceptually in front of the output, so a match that starts
  in it and crosses its end continues at the output's start. The caller
  vouches for the bytes on both sides: raw flate carries no identifier; zlib's
  FDICT/DICTID is the checked form and drives this seam through
  `framing.initReader`.

### Contracts the containers rely on

gzip and zlib wrap `Reader`, `Writer`, their `Buffer`s, and the checksum hook,
and the container `Reader` reads its trailer from the same `input`. Changing
one of these changes theirs; run `just gzip-oracle` and `just zlib-oracle` after
touching one.

- Exact consumption. The Reader takes input bytes only through `peek`/`toss`, so
  `input` ends just past the stream's last byte, partial final byte included.
- The 3-byte input buffer. A 16-bit peek can start 7 bits into a byte, and
  `Io.Reader.fill` asserts its capacity, so a narrower buffer cannot show the
  decoder enough bits. Widening any peek raises this floor for every container.
- The level is an enum: `encode.Level` has `@"1"` and `@"6"` only, named by
  the zlib scale, so an unimplemented level is unrepresentable. `gzip` and
  `zlib` re-export the type and the shared container driver takes it as is.
- A contiguous read the window cannot hold is `error.ReadFailed` with
  `err == .StreamTooLong`, never an assert.
- The preset-history parameter. `decode.decompress`, `Reader.init`, and
  `Reader.streamAll` take `dict: ?[]const u8`, and `encode.Options` carries it
  for both encoders; zlib's `framing.zig` threads its own through, and gzip
  has no dictionary concept. Run the flate and zlib oracles after touching
  either history shape (the pre-seeded window and the two-region one).

### Checksum hook

`Checksum.zig` lives here, not in `src/internal/`, because containers consume it
through flate. The hook has two call sites: `Writer.emitBlock` (one run per
block, before the encoder runs or any slide) and the Reader's window fill (one
run per fill, flushed before a slide drops the run's head). The one-shot
functions and the `streamAll`s carry no hook. A container's one-shot encode
folds `source` directly; its one-shot decode runs the body through the
streaming Reader, so the digest never comes from `target`. After a decode
failure the digest is partial, and the container reports the decode error,
never a checksum result.

## Format notes and errata

The RFC is silent or self-contradictory where every implementation must pick
(flate-notes §2.3, §7). The conformance suite pins these calls on purpose. An
RFC-literal decoder would differ on T1, T3, and T5; ours follows the reference
lineage (zlib, Go, std), because the conformance fixtures are the reference
suites.

- T1, extra-bit order. Extra bits pack LSB-of-value first, like every
  non-Huffman element; only Huffman codes go out MSB-of-code first (the code
  tables hold wire bits pre-reversed). §3.2.5's "stored with the
  most-significant bit first" describes the numeral, not the wire order, and
  reading only that gives streams every reference decoder misreads. `BitWriter`
  keeps `writeBits` and `writeCode` apart for this. A mix-up still round-trips
  through our own decoder when both sides share it, so the oracle and the
  hand-built streams in flate-notes §3.2 are what catch it.
- T2, degenerate trees. A literal/length tree with no code for 256 is rejected
  at table build (`MissingEndOfBlockCode`), as zlib and std do. A single 1-bit
  code is the one incomplete set accepted (zlib, Go, and std agree); in the
  literal/length tree it must be 256. An empty precode tree is rejected: it
  cannot decode the lengths that follow. Distance trees follow §3.2.7: zero
  codes and a single 1-bit code are both accepted. Any other incomplete set is
  `IncompleteHuffmanTree`.
- T3, alphabet caps. HLIT <= 286 and HDIST <= 30, and length symbols 286-287 and
  distance codes 30-31 never decode (`InvalidCode`). The RFC's parentheticals
  ("257 - 286", "1 - 32") read wider; zlib, Go, and std all cap.
- T4, stream ending. Every data block has BFINAL=0 and the stream ends with a
  final empty fixed block (`03 00` at a byte boundary), so `flush` mid-stream is
  always safe. Both layers emit it through `encode.writeFinalEmptyBlock`. zlib's
  level 0 ends an empty stream with a stored block (`01 00 00 ff ff`); both are
  legal, and `03 00` is the cheapest.
- T5, code 284 with extra 31. Length is base + extra, unclamped, so this is 258
  even though §3.2.5 gives 284 the range 227-257. Go's TestStreams expects it;
  clamping would reject a stream the whole lineage accepts.

## Testing and golden vectors

- The conformance bar is the reference suites ported into `golden.zig` (sources
  in its header), shared by the one-shot, streaming, and round-trip tests.
- Go's `deflateTests` outputs are decode goldens only. Deflate has no canonical
  form and those bytes assert Go's encoder heuristics, so nothing compares our
  encoder's output against them.
- Level 6's encode goldens are klauspost's own bytes for five small inputs
  (encode.zig) plus one dictionary case, generated from the pinned module and
  re-derived by the oracle's parity lane. `dynamic.zig`'s tests pin the
  §3.2.7 machinery structurally: canonical assignment against §3.2.2's
  construction, the 15-bit cap on a Fibonacci histogram, the codegen's
  16/17/18 runs, the one-distance-code case, and the three dispatch rungs.

## Oracles

`just flate-oracle` builds `oracle.zig` and runs `scripts/flate_oracle.py`, with
python3's `zlib` (raw, `wbits=-15`) as the independent implementation and
klauspost/compress's flate (the pinned module, `scripts/klauspost_flate`) as
the level-6 byte target. Level 1 is pinned against its own bytes (a hash per
fixture and shape in the script): the level-6 work must not perturb a single
one. The level-6 lane compares ours with theirs byte for byte over the
fixtures, the oracle shapes, the generated corpus shapes when `bench/corpus-gen`
is populated, and the dictionary rows, and cross-decodes both directions. The
Go tool is the module pin's second consumer; bumping the pin moves both. Both
directions run over the committed fixtures and generated shapes: our encoder
into zlib's decoder, and zlib's streams (stored, `Z_HUFFMAN_ONLY`, levels 1, 6,
9) into our decoder. The preset-dictionary rows are the same both-directions
rule against a `zdict=` reference (`compressobj(..., -15, ..., zdict=)` and
`decompressobj(-15, zdict)`), with a text dictionary and a 40-KiB one whose
tail is the matchable window; the harness takes an optional dictionary file
after its own arguments. The streaming rows pump `examples/flate.zig`: zlib
decodes the streaming Writer's output and the streaming Reader round-trips it.
Run it after any change to bit packing, block emission, or the streaming layer:
a bug both sides share passes `just test` and fails here (T1). The incantations
are flate-notes §4.3. `just gzip-oracle` and `just zlib-oracle` cover the
containers.

## Performance notes

- `bench.zig` has one-shot rows only. Do not add a streaming row: one was tried
  and the one-shot rows moved about 3x (attributed to code layout, not
  profiled), so it was reverted. Time the streaming path with the example pump,
  `just example flate encode|decode <file>`, over a large file.
- Local numbers are never claims. A claim cites a recorded run in
  `docs/slop/results/` (method: `docs/slop/plan.md`, "Benchmark methodology").
