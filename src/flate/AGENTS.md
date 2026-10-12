# Agent notes: flate

Raw DEFLATE (RFC 1951): a fixed-Huffman encoder with a stored-block fallback, an
inflate for all three block types, and a streaming `Io` layer over both.
`README.md` is the user contract; this file holds the decisions and traps behind
it. The research is `docs/research/flate-notes.md` (flate-notes §N). T1-T5 are
its divergence ids (§2.3) and OQ1-OQ6 its open questions (§6). The generated
`Io.Writer` and `Io.Reader` entries (drain top-up, rebase, sticky failure) are
explained in `src/internal/AGENTS.md`. Attribution is in `THIRD_PARTY.md`.

## Design decisions

- No framing of our own (OQ2). BFINAL self-delimits the stream. The Reader
  decodes straight from the input `Io.Reader` through a bit reader with a few
  bytes of lookahead: a Huffman block has no compressed length, so there is no
  staging region. std's decoder works the same way (flate-notes §5.4).
- The fast level is fixed Huffman with a stored fallback (OQ1). Fixed emission
  needs no header, precode, or table build, and zlib-ng's fastest level is
  fixed-only too (flate-notes §5.3). The cost is ratio: a literal takes 8-9 bits
  against about 5 dynamic on text. Dynamic Huffman with cross-block table reuse
  is the planned `.ratio` mode (flate-notes §6, §8); whether `.fast` gains a
  dynamic sibling is a benchmark question.
- The match finder is klauspost's level-1 shape (OQ3); encode.zig's header
  describes it. It is greedy because every fast-level reference is lazyless.
  Minimum match is 4; 3-byte matches wait for the ratio mode.
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
- Preset dictionaries are deferred and undesigned (OQ6); nothing here precludes
  an entry point.

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
- `.ratio` fails instead of aliasing: `error.Unimplemented` from `compress`, a
  poisoned `Writer`, `error.ReadFailed` from `Writer.streamAll`.
- A contiguous read the window cannot hold is `error.ReadFailed` with
  `err == .StreamTooLong`, never an assert.

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

## Oracles

`just flate-oracle` builds `oracle.zig` and runs `scripts/flate_oracle.py`, with
python3's `zlib` (raw, `wbits=-15`) as the independent implementation. Both
directions run over the committed fixtures and generated shapes: our encoder
into zlib's decoder, and zlib's streams (stored, `Z_HUFFMAN_ONLY`, levels 1, 6,
9) into our decoder. The streaming rows pump `examples/flate.zig`: zlib decodes
the streaming Writer's output and the streaming Reader round-trips it. Run it
after any change to bit packing, block emission, or the streaming layer: a bug
both sides share passes `just test` and fails here (T1). The incantations are
flate-notes §4.3. `just gzip-oracle` and `just zlib-oracle` cover the
containers.

## Performance notes

- `bench.zig` has one-shot rows only. Do not add a streaming row: one was tried
  and the one-shot rows moved about 3x (attributed to code layout, not
  profiled), so it was reverted. Time the streaming path with the example pump,
  `just example flate encode|decode <file>`, over a large file.
- Local numbers are never claims. A claim cites a recorded run in
  `docs/results/` (method: `docs/zcompress-plan.md`, "Benchmark methodology").
