# brotli

Brotli ([RFC 7932][rfc7932]) in pure Zig: a complete decoder — the stream
header, the meta-block ladder, the canonical prefix codes in both tree forms,
the block-switch and context-modeling layers, and the format's built-in static
dictionary with its 121 word transforms — plus a `std.Io` streaming reader. It
is the codec behind the `br` HTTP content encoding. This is the
`compress.brotli` namespace; it imports only `std` and `fastmem`, and it
allocates nothing.

The format is vendored at `docs/research/specs/rfc7932-brotli.txt`; `§` cites
in this directory are sections of that file.

This package is decoder-first. `brotli.decode` (one-shot) and `brotli.Reader`
(streaming) are the surface; `brotli.encode` and `brotli.Writer` are the
encoder's seats — reserved and stated, never silently absent. The namespace is
exactly `{Reader, decode}`, and the encoder adds its two names without
reshaping these.

## Usage

One-shot decode over buffers you own. The format records no decoded length, so
`target` is a cap:

```zig
const std = @import("std");
const brotli = @import("compress").brotli;

fn decode(gpa: std.mem.Allocator, stream: []const u8, out: *std.Io.Writer) !void {
    const plain = try gpa.alloc(u8, 1024 * 1024); // a cap; brotli records no size
    defer gpa.free(plain);
    const n = try brotli.decode.decompress(stream, plain);
    try out.writeAll(plain[0..n]);
}
```

Streaming, through the `std.Io` interfaces. The default buffer is about
16.7 MiB: keep it in static or heap storage.

```zig
fn decompressTo(out: *std.Io.Writer, in: *std.Io.Reader) !void {
    var buffer: brotli.Reader.DefaultBuffer = undefined;
    var r: brotli.Reader = .init(brotli.Reader.default_window_wbits, in, &buffer);
    _ = try r.reader.streamRemaining(out); // on ReadFailed, r.err says why
}
```

`brotli.Reader.streamAll(brotli.Reader.default_window_wbits, in, out, &buffer)`
decodes every stream in `in` in one call; `just example brotli decode FILE.br

> FILE` runs the example CLI.

## API

```zig
const brotli = @import("compress").brotli; // two names: `decode`, `Reader`

// One-shot decode: one stream, header through last byte. `target` is a cap;
// the return value is the decoded length.
brotli.decode.decompress(source: []const u8, target: []u8) DecompressError!usize
brotli.decode.DecompressError = error{
    BufferTooSmall,      // `target` cannot hold the decoded stream
    // stream header and meta-block ladder (§9.1, §9.2):
    BadWindowBits,       // WBITS is the invalid 0010001 pattern (§9.1)
    Truncated,           // the input ended before the stream did
    ReservedBit,         // the metadata block's reserved bit is set (§9.2)
    ExuberantNibble,     // MNIBBLES > 4 with an all-zero last nibble (§9.2)
    ExuberantMetaNibble, // MSKIPBYTES > 1 with an all-zero last byte (§9.2)
    BadPadding,          // nonzero fill bits where the format requires zeros (§9.2)
    // prefix codes (§3.4, §3.5):
    SimpleHuffmanAlphabet, // a simple code's symbol is at or past the alphabet size
    SimpleHuffmanSame,     // a simple code repeats a symbol
    BadCodeLengthCode,     // the code-length code is not a complete prefix code
    BadHuffmanCode,        // a code-length sequence breaks §3.5's rules
    // block types and the meta-block length (§6, §9.3):
    BadBlockLength,      // the meta-block length accounting (§9.3)
    // context maps (§7.3):
    ContextMapRepeat,    // a context map's zero-run overruns the map
    // distances and the dictionary (§4, §8):
    BadDistance,         // a special distance code resolves to zero or less
    BadTransform,        // a transform id above 120, or a word the transform empties
    BadDictionary,       // a dictionary reference's word length is outside 4..24
    // this decoder's instantiation:
    TooManyTrees,        // a meta-block declares more than 64 trees in a category
};

// Streaming decode: one `Reader` decodes one stream. You own the `Buffer`,
// which holds the sliding window and the meta-block trees.
brotli.Reader.Buffer(comptime window_wbits: usize) type
    // { ring: [(1 << window_wbits)]u8, header: the meta-block tree region };
    // window_wbits is 10..24
brotli.Reader.default_window_wbits: usize // 24: the format's maximum
brotli.Reader.DefaultBuffer // Buffer(24): about 16.7 MiB
brotli.Reader.init(comptime window_wbits: usize, input: *Io.Reader,
    buffer: *Buffer(window_wbits)) Reader
    // consume through `&r.reader`; `r.err: ?Error` holds the cause after ReadFailed
brotli.Reader.Error = error{
    // every DecompressError name except BufferTooSmall, plus:
    WindowTooLarge,  // the stream's WBITS is above `window_wbits` (§9.1)
    BadStreamStart,  // the walk found bytes that cannot begin a stream
    StreamTooLong,   // a contiguous read larger than the buffer can hold
    ReadFailed,      // the Io.Reader error; the cause is in `r.err`
    EndOfStream,     // the Io.Reader end, reported after the stream's last byte
};

// One-call pump: decode every stream in `in`. It returns the bytes written to
// `out` and reports only the coarse ReadFailed; drive a `Reader` for the cause.
brotli.Reader.streamAll(comptime window_wbits: usize, in: *Io.Reader, out: *Io.Writer,
    buffer: *Buffer(window_wbits)) error{ ReadFailed, WriteFailed }!usize
```

## Behavior

- **Buffers.** You own every buffer; nothing is allocated, freed, or retained,
  and no function takes an allocator. `decompress` writes only into `target`,
  leaves the bytes past the returned length untouched, and returns
  `error.BufferTooSmall` before any write that would pass the end. A `Reader`
  keeps the sliding window and the meta-block trees in the `Buffer` you give
  it: a `(1 << window_wbits)`-byte history ring — the window bound is
  `(1 << window_wbits) - 16` (§9.1) — plus the tree region. The default
  `Buffer(24)` is about 16.7 MiB; `Buffer(22)` is about 4.7 MiB.
- **The window.** The stream header's only field is WBITS (§9.1), a 1..7-bit
  code over 10..24 (16 is the single bit `0`); the window is
  `(1 << WBITS) - 16` bytes, 1,008 bytes to 16,777,200 (§9.1, §2).
  `Reader.Buffer(window_wbits)` fixes the cap at comptime, and a stream whose
  WBITS is above it fails `WindowTooLarge` before any meta-block byte. The
  default 24 is the format's maximum, and the measured reason is the reference
  CLI's own behavior: its pipe form emits WBITS 24 for every stream it writes
  (it cannot stat a pipe), while its file form picks 10..19 by input size. 22 —
  the reference encoder library's own default window, 4,194,288 bytes — is one
  `Buffer(22)` away and decodes the file family, at 4.7 MiB rather than 16.7.
  The pattern `0010001` — "invalid and must not be used"
  (§9.1), and reused by the reference family as the marker for its large-window
  extension — is refused with `BadWindowBits`; there is no large-window surface
  here.
- **Meta-blocks.** A stream is a header plus one or more meta-blocks, each
  producing 0 to 16,777,216 bytes (§2); the caller sees only the decoded bytes
  and the stream's end, never a meta-block boundary. Metadata meta-blocks are
  skipped without touching the output, the window, or the literal context
  (their bytes are never context and never matchable, §2), and an uncompressed
  meta-block's bytes pass through. A stream ends at its last meta-block; the
  unused bits of its last byte must be zero (`BadPadding` otherwise).
- **The static dictionary.** The format folds a 122,784-byte built-in
  dictionary and 121 word transforms into distance space (§8, Appendices A and
  B): a distance beyond `min(window, produced)` is a dictionary reference, with
  no header bit and no opt-in, so every conforming decoder ships the table.
  Here it is about 120 KiB of `.rodata` — no allocation, no per-instance cost —
  and both tables are pinned in the tests by the RFC's own CRC-32 check values
  (0x5136cb04 for the dictionary, 0x3d965f81 for the transforms). A transformed
  word is built in a 38-byte scratch (§8's bound).
- **Corrupt input.** Decoding stops at the first invalid byte with an error
  from the sets above; the sizes a stream declares are checked against your
  buffers and never trusted. The format has no checksum: a corrupt stream that
  stays structurally valid decodes to different bytes silently, so "no error"
  means structurally valid, not intact — integrity is a container's job, and
  brotli has no container.
- **After the stream.** `decompress` ignores whatever follows the stream's last
  byte. `Reader` consumes `input` exactly through the stream's last byte and
  leaves the rest unread, so the input position at a clean end is the next
  stream's first byte. A second stream there is not an error: `streamAll` reads
  it as the walk's next iteration, and a plain `Reader` simply leaves it
  unconsumed. Bytes that cannot begin a stream fail `ReadFailed`
  (`BadStreamStart` is the cause; an input that ends inside a header is
  `Truncated`). The reference implementations fail closed on trailing bytes
  rather than warning, so there is no warn-and-continue mode.
- **Empty input.** Zero bytes is `Truncated` from `decompress` and a `Reader`:
  no stream began. The empty _stream_ is the single byte `06` and decodes to
  zero bytes. `streamAll` treats a zero-byte input as the walk's clean end
  (zero streams), like the other codecs here.
- **Stack.** The per-meta-block scratch is comptime and KiB-scale: the
  symbol lists and code lengths of a tree description, the distance-code
  tables derived from NPOSTFIX and NDIRECT, and the 38-byte transformed-word
  buffer. `decompress` also carries the meta-block header arena as a stack
  local — about 691 KiB, nearly all of it the tree region: a two-level table
  per tree, 64 trees per category at the cap, sized by the reference's proven
  ceiling (about 2.5 KiB per literal tree, 4.3 KiB per command tree, 3.7 KiB
  per distance tree) — so give decoding threads 1 MiB or more. A `Reader`
  keeps that region in its `Buffer` instead, and its own stack stays
  KiB-scale.
- **Reader input.** `input` needs a buffer of at least 4 bytes (the widest
  field the bit reader assembles is 24 bits); `Io.Reader.fixed` always
  qualifies. A contiguous `peek` or `take` is served up to the history ring's
  room at the read position; a larger one fails with `StreamTooLong`.

## Limitations

- **Decoder only.** There is no encoder: `brotli.encode` and `brotli.Writer`
  are the encoder's seats, and the namespace grows to the full
  `{Reader, Writer, encode, decode}` then.
- **No dictionary-supplying API.** The built-in dictionary ships
  unconditionally — any stream can reference it, so there is nothing to
  configure — and a custom or shared dictionary is outside RFC 7932: a stream
  encoded with one is not an RFC 7932 stream, and its distances fail naturally.
- **The tree cap.** A meta-block that declares more than 64 trees in a
  category fails `TooManyTrees`; the format allows up to 256 per category. The
  region is comptime-sized so the decode stays allocation-free. The alternative
  — an allocator-taking `Reader.init` for the tree region alone — would make
  every streaming caller allocate for a worst case no measured stream
  approaches; raise the cap instead if a real one ever trips it.
- **No extensions.** The large-window streams the reference CLI tolerates, and
  the custom/compound dictionary surfaces, are out of scope (the RFC's own
  invalid pattern is refused; no `--large_window`-style flag exists).
- On 32-bit targets, the one-call pump counts bytes in a `usize` (inside std's
  `streamRemaining`), so more than 4 GiB through one call overflows. Drive a
  `Reader` and count in a `u64` instead.

## Testing and benchmarks

`just test` runs the unit tests: the RFC's own check values (the dictionary,
the transform table, and the three context Luts by CRC-32), the hand-built
minimal streams (the empty family, the one-command streams, the rejection
vectors), and the streams the pinned reference CLI wrote — the small text,
repeat, run, and digits inputs at five qualities, the `-w 10` ring vector,
and one 34,382-byte mixed text — each decoded byte-exact through both the
one-shot and the streaming reader, with a check on every decode that no byte
past the decoded length was written. The codec is decoder-only, so there is
no round trip to test: the CLI's own output is the encoder evidence, and the
45-vector reference corpus is not vendored.
`just fuzz 1M` runs the fuzz targets (ReleaseSafe only). `just brotli-oracle`
cross-checks the decoder against the pinned reference CLI (brotli 1.2.0) and
andybalholm/brotli over streams both encoders wrote: the CLI's quality sweep
(eight inputs × qualities 0..11), its window, file, metadata, and
trailing-byte lanes, and the Go port's own 40 streams, with the truncation
and corruption batteries asserting the references' verdicts. `just bench`
runs the local benchmarks; local numbers are not performance claims. Design
notes, the divergence register, and the fixture inventory are in
[`AGENTS.md`](AGENTS.md).

## License

MIT, like the rest of the repository. Ports and vendored artifacts are
attributed in [`THIRD_PARTY.md`](../../THIRD_PARTY.md).

[rfc7932]: https://www.rfc-editor.org/rfc/rfc7932.txt
