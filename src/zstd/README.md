# zstd

Zstandard ([RFC 8878][rfc8878]) in pure Zig: a fast encoder and a complete
decoder — frames, blocks, the Huffman and FSE entropy layers, the XXH64
content checksum, dictionaries (§5), and streaming `std.Io` adapters. It is
the `compress.zstd` namespace; it imports only `std` and `fastmem`, and
neither direction allocates (the `*Alloc` pumps allocate their default buffer
for the call).

The format is vendored at `docs/research/specs/rfc8878-zstd.txt`; `§` cites in
this directory are sections of that file.

## Usage

One call each way, over buffers you own:

```zig
const std = @import("std");
const zstd = @import("compress").zstd;

fn roundTrip(gpa: std.mem.Allocator, data: []const u8) !void {
    const frame = try gpa.alloc(u8, zstd.encode.maxCompressedLength(data.len));
    defer gpa.free(frame);
    const frame_len = try zstd.encode.compress(data, frame, .{});
    const plain = try gpa.alloc(u8, data.len); // the caller must know the size
    defer gpa.free(plain);
    const n = try zstd.decode.decompress(frame[0..frame_len], plain, null);
    std.debug.assert(std.mem.eql(u8, data, plain[0..n]));
}
```

A dictionary (§5) is parsed once and handed to either direction. The
`Dictionary` borrows the file bytes — keep them alive — and is about 158 KiB,
mostly the match table the encoder looks up:

```zig
// dict_file: the bytes of a `zstd --train` output, or any formatted
// dictionary (`Dictionary.initRaw` takes format-free content instead).
fn withDictionary(gpa: std.mem.Allocator, dict_file: []const u8, data: []const u8) !void {
    const dict = try zstd.Dictionary.parse(dict_file);
    const frame = try gpa.alloc(u8, zstd.encode.maxCompressedLength(data.len));
    defer gpa.free(frame);
    const frame_len = try zstd.encode.compress(data, frame, .{ .dict = &dict });
    const plain = try gpa.alloc(u8, data.len);
    defer gpa.free(plain);
    const n = try zstd.decode.decompress(frame[0..frame_len], plain, &dict);
    std.debug.assert(std.mem.eql(u8, data, plain[0..n]));
}
```

Streaming, through the `std.Io` interfaces. `Writer.Buffer(19)` is 1.5 MiB and
`Reader.Buffer(1 MiB)` 1.25 MiB: keep them in static or heap storage.

```zig
fn compressTo(out: *std.Io.Writer, bytes: []const u8, buffer: *zstd.Writer.Buffer(19)) !void {
    var w: zstd.Writer = .init(19, out, buffer, .{});
    try w.writer.writeAll(bytes);
    try w.finish(); // required: it writes the last block and the checksum
}

fn decompressTo(out: *std.Io.Writer, in: *std.Io.Reader,
    buffer: *zstd.Reader.Buffer(1024 * 1024)) !void {
    var r: zstd.Reader = .init(1024 * 1024, in, buffer, null);
    _ = try r.reader.streamRemaining(out); // on ReadFailed, r.err says why
}
```

`zstd.Writer.streamAll(19, in, out, &buffer, .{})` and
`zstd.Reader.streamAll(1024 * 1024, in, out, &buffer, null)` pump a whole
stream in one call; `just example zstd encode FILE > FILE.zst` and
`just example zstd decode FILE.zst > FILE` run the example CLI. The example's
`encode` streams, so its frame carries the FCS-unknown header and the
streaming class — the bytes the CLI writes for `zstd -1 -c < FILE`. The
one-shot `encode.compress` is the form that declares the exact
Frame_Content_Size (single-segment when the input fits the window), which is
what `zstd -1 FILE -o OUT` writes.

## API

```zig
const zstd = @import("compress").zstd;
// the surface: `encode`, `decode`, `Writer`, `Reader`, and the shared `Dictionary`

// A dictionary (§5): parse once and hand it to either direction. `parse`
// reads the formatted form (magic 0xEC30A437, the ID, the entropy tables,
// the 12 repcode bytes, then the content) and builds both directions'
// tables from that one parse, with `ZSTD_loadCEntropy`'s promotion rules
// deciding what a frame may reuse; `initRaw` takes format-free content. The
// value borrows `source` — no copy, no allocation — and is about 158 KiB:
// the parsed tree, the decode and encode tables (the four built tables
// twice over), the repcodes, the content slice, and the match table the
// encoder looks up (the C keeps that one in a `ZSTD_CDict`; here it is the
// dictionary's, so no frame pays to rebuild it).
zstd.Dictionary
zstd.Dictionary.parse(source: []const u8) ParseError!Dictionary
zstd.Dictionary.initRaw(content: []const u8) Dictionary
zstd.Dictionary.ParseError = error{
    Truncated,                // the source ends before the magic, the ID, or the 12 repcode bytes
    BadDictionaryMagic,       // no 0xEC30A437 magic: not the formatted form
    InvalidDictionaryId,      // Dictionary_ID is 0 (§5: "any value, except 0")
    InvalidDictionaryRepcode, // a repeat offset is 0 or above the content size
    MalformedHuffmanWeights,  // the literals tree (§4.2.1) — the block layer's name
    MalformedFseTable,        // one of the three FSE descriptions (§4.1.1)
};

// One-shot encode: one frame, header through checksum. With `options.dict`
// the frame names the dictionary's ID, and the window and size class cover
// source + dictionary content, so the dictionary never expires mid-frame.
zstd.encode.compress(source: []const u8, target: []u8, options: Options)
    error{ BufferTooSmall, Unimplemented }!usize
zstd.encode.compressBuffered(source: []const u8, target: []u8, buffer: *Buffer,
    options: Options) error{ BufferTooSmall, Unimplemented }!usize
zstd.encode.Buffer // literals 128 KiB + sequences 512 KiB + hash table 128 KiB; 768 KiB
zstd.encode.maxCompressedLength(input_len: usize) usize // 18-byte header cap + 3/block + input_len + 4
zstd.encode.Options = struct { level: u8 = 1, dict: ?*const Dictionary = null }
    // level: 1-19, the CLI's scale (1 is the default):
    //   1: the level-1 class — the `zstd -1` byte pin.
    //   3: the double-fast (dfast) class — two hash tables (long + small), the
    //      two-candidate scan, the repcode pre-check reused — byte-identical to
    //      the pinned CLI's `zstd -3` (v1.5.7, file form, default threading,
    //      inputs up to 8 MiB, the level's job size; above it the CLI's
    //      multithread form splits jobs, so the pin there is round-trip-only,
    //      the same shape the level-1 parity exclusions already document).
    // Levels 2 and 4-19 are reserved seats that return error.Unimplemented,
    // never a silent alias, and so is any level outside 1-19. A level-3
    // `Writer`'s match table region grows to the long+small tables, and its
    // default window is log 21 (the -3 class's window), so `Writer.Buffer(21)`
    // is its default. Callers of the old `.fast` name change to level 1, and
    // of `.ratio` to level 3 — a source-breaking rename of the same classes.

// One-shot decode. `dict` seeds the frame's tables, repeat offsets, and
// history; `null` is the no-dictionary decode. The third parameter is
// required at every callsite (add `, null`): one form, no duplicate names,
// and the compiler marks every call that must decide.
zstd.decode.decompress(source: []const u8, target: []u8, dict: ?*const Dictionary)
    DecompressError!usize
zstd.decode.max_block_size: usize // 128 KiB, the largest block a frame can carry (§3.1.1.2.4)
zstd.decode.DecompressError = error{
    BufferTooSmall, // `target` cannot hold the decoded frame
    // frame layer (§3.1.1.1, §3.1.1.2, §5):
    BadMagic, ReservedBitSet, DictionaryRequired, DictionaryMismatch,
    BlockOversize, ReservedBlock,
    // literals and trees (§3.1.1.3.1, §4.2.1):
    MalformedLiteralsHeader, LiteralsTooLarge, TreelessLiteralsFirst, MalformedHuffmanWeights,
    // sequences and bitstreams (§3.1.1.3.2, §4.2.2):
    MalformedFseTable, MalformedSequencesHeader, RepeatModeFirst, ReservedModeBits,
    MissingStartBit, InvalidBitStream, BitstreamNotConsumed, ZeroOffset, OffsetTooFar,
    // frame end (§3.1.1):
    ContentSizeMismatch, WrongChecksum, Truncated,
};

// Streaming encode. One `Writer` writes one frame; `finish` is required.
zstd.Writer.Buffer(comptime window_log: usize) type
    // history (1 << window_log) + block min(128 KiB, 1 << window_log)
    // + literals (the block) + the block's output (the block + 3)
    // + hash table 128 KiB (1 << 15 entries, the widest hashLog a frame
    //   takes when it attaches a dictionary; the frame's own slice is
    //   narrower when no dictionary is in play)
    // + sequences 12 * (block / 3 + 1); window_log must be 10 to 31
zstd.Writer.default_window_log: usize // 19: a 512 KiB window, the largest level 1 declares
zstd.Writer.DefaultBuffer // Buffer(default_window_log): 1.44 MiB
zstd.Writer.init(comptime window_log: usize, output: *Io.Writer, buffer: *Buffer(window_log),
    options: encode.Options) Writer // write through `&w.writer`, then call `finish`
zstd.Writer.finish(w: *Writer) Io.Writer.Error!void // writes the last block and the checksum
zstd.Writer.streamAll(comptime window_log: usize, in: *Io.Reader, out: *Io.Writer,
    buffer: *Buffer(window_log), options: encode.Options) error{ReadFailed, WriteFailed}!usize
zstd.Writer.streamAllAlloc(allocator: Allocator, in: *Io.Reader, out: *Io.Writer,
    options: encode.Options) error{ReadFailed, WriteFailed, OutOfMemory}!usize

// Streaming decode. One `Reader` decodes one frame.
zstd.Reader.Buffer(comptime window_len: usize) type
    // [window_len + 128 KiB + min(window_len, 128 KiB)]u8; `window_len` must be >= 1024
zstd.Reader.default_window_len: usize // 8 MiB
zstd.Reader.DefaultBuffer // Buffer(default_window_len): 8 MiB + 256 KiB
zstd.Reader.init(comptime window_len: usize, input: *Io.Reader, buffer: *Buffer(window_len),
    dict: ?*const Dictionary) Reader
    // consume through `&r.reader`; `r.err: ?Error` holds the cause after ReadFailed
zstd.Reader.Error = error{
    // every DecompressError name except BufferTooSmall, plus:
    WindowTooLarge, // the frame's Window_Size exceeds `window_len` (§3.1.1.1.2)
    StreamTooLong,  // a contiguous read larger than the window can hold
    ReadFailed,     // the Io.Reader error; the cause is in `r.err`
    EndOfStream,    // the Io.Reader end, reported after the checksum was verified
};

// One-call pumps: `streamFrame` decodes one frame, `streamAll` every frame in `in`.
// Both return the bytes written to `out` and report only the coarse ReadFailed;
// drive a `Reader` for the cause. The `*Alloc` pair allocates the default window.
zstd.Reader.streamFrame(comptime window_len: usize, in: *Io.Reader, out: *Io.Writer,
    buffer: *Buffer(window_len), dict: ?*const Dictionary) error{ReadFailed, WriteFailed}!usize
zstd.Reader.streamAll(comptime window_len: usize, in: *Io.Reader, out: *Io.Writer,
    buffer: *Buffer(window_len), dict: ?*const Dictionary) error{ReadFailed, WriteFailed}!usize
zstd.Reader.streamFrameAlloc(allocator: Allocator, in: *Io.Reader, out: *Io.Writer,
    dict: ?*const Dictionary) error{ReadFailed, WriteFailed, OutOfMemory}!usize
zstd.Reader.streamAllAlloc(allocator: Allocator, in: *Io.Reader, out: *Io.Writer,
    dict: ?*const Dictionary) error{ReadFailed, WriteFailed, OutOfMemory}!usize
```

The layers the decoder is built from are also public under `zstd.decode`:
`frame`, `block`, `literals`, `sequences`, `fse`, and `window` (the
Window_Size arithmetic of §3.1.1.1.2); most callers never need them. The
encoder's block layer stays internal — a zstd block depends on the frame's
state — so `encode` exposes only the names above.

## Behavior

- **Encode sizing.** `maxCompressedLength(n)` is `n + 3 * (n / 131072 + 1) +
  22` — an 18-byte header cap (the 4-byte Dictionary_ID included), 3 bytes per
  block, the 4-byte checksum — and stays inside the C's `ZSTD_COMPRESSBOUND`.
  A smaller `target` can still work when the data compresses; if it is too
  small, `compress` returns `error.BufferTooSmall` and `target`'s contents are
  unspecified.
- **Encode output.** Deterministic: the same input and options produce the same
  bytes. `compress` declares the exact Frame_Content_Size (§3.1.1.1.4) in the
  smallest form and always writes the XXH64 checksum. With `options.dict` the
  frame names the dictionary's Dictionary_ID (§3.1.1.1.1.6), in the smallest
  of the 1/2/4-byte forms — always written, never suppressed — and the level's
  window and size class cover the input plus the dictionary content, so the
  dictionary never expires mid-frame. Without a dictionary no ID is named.
  The window is the smallest power of two covering the input, from 1 KiB to
  512 KiB; when the input fits it the frame is single-segment, and above
  512 KiB it declares a 512 KiB window. A frame that attaches a dictionary
  at or below the 8-KiB source cutoff takes the dictionary's own hash width
  and match width (the C's `ZSTD_resetCCtx_byAttachingCDict`); a larger one
  copies the dictionary's match table into the frame's own. A `Writer` cannot know the length when
  its header goes out, so its frames declare no Frame_Content_Size and always
  carry a `window_log`-sized Window_Descriptor.
- **Emission.** The ladder follows `zstd -1`: a block that does not shrink by
  `(size >> 6) + 2` bytes is stored raw; a block of one repeated byte becomes an
  RLE block, except the frame's first block, which is never RLE (a zstd ≤ 1.4.3
  CLI convention); literals and sequences pick their entropy modes by the
  level-1 heuristics. Every frame is valid zstd that the CLI, libzstd, and this
  package's decoder accept, and the whole frame reproduces the pinned CLI
  v1.5.7's `zstd -1` bytes on the corpus shapes, on the tests' fixtures, and
  on the `just zstd-oracle` lane's non-ASCII and over-512-KiB inputs. With a
  dictionary the target is the CLI's `zstd -D dict -1`: the same
  form-matched parity, one-shot against the file form and `Writer` against
  the pipe form, over CLI-trained dictionaries — including the
  attach/copy switch at the 8-KiB source cutoff and the frames for
  incomplete-statistics dictionaries, whose unpromoted tables degrade
  exactly as the C's do. Three
  deliberate differences can show up outside that set, all of them the C's
  own heuristics: a Huffman tree's equal-count symbols keep natural order
  here, where the C's sort is unstable (a tree description's bytes can differ
  while decoding identically); the C's two literals heuristics are not
  ported, so a block the C stores as raw literals may come out Huffman-coded
  here (a smaller frame); and the C v1.5.7's optional pre-block splitter is
  not ported, so a compressible block can stay whole where the CLI cuts it.
- **Encode streaming.** Nothing reaches `output` until the block region fills,
  you call `w.writer.flush()`, or `finish`; the frame header goes out with the
  first of those, and a `flush` with nothing buffered emits the header alone.
  A `flush` emits the buffered data as one complete block, so a decoder reading
  the output so far decodes every byte written; only `finish` writes the last
  block and the checksum trailer. `finish` is required and final: after it, or
  after a failed write, the writer returns `error.WriteFailed`. An empty
  writer's `finish` is still a frame: the header, one raw zero-size last block,
  and the checksum — 13 bytes. Blocks are `min(128 KiB, 1 << window_log)` bytes
  and the splits follow the block region, never the caller's write sizes; a
  `writableSliceGreedy` write onto a full region emits the block, never drops
  it. The frames match the zstd CLI's own `zstd -1` output over a pipe byte for
  byte up to about 2 MiB, and the finder's parameters are that CLI class:
  windowLog 19, hashLog 14, and 7-byte hashing at the default `window_log`.
  Above 2 MiB the CLI's own pipe output splits its streaming jobs (its
  multi-threaded workers cut different blocks), so the pipe comparison stops
  there; the frames remain valid and every strict decoder accepts them.
- **Buffers.** You own every buffer, and neither direction keeps anything
  between calls. `decompress` writes only into `target`, leaves the bytes past
  the returned length untouched, and returns `error.BufferTooSmall` before any
  write that would pass the end; a declared Frame_Content_Size is checked
  against the output, never used to size anything. `encode.compressBuffered`
  and `Writer` put the encoder's heavy per-block arrays in the `Buffer` you
  provide (`encode.Buffer`, 768 KiB; `Writer.Buffer(window_log)`, 1.5 MiB at
  the default) instead of on the stack.
- **Windows.** The decoder's one-shot needs no window: a match can reach back
  into the output already in `target`, and — with a dictionary — into the
  dictionary content in front of it. §5's boundary is enforced: while the
  frame's decoded total is at most its Window_Size the whole dictionary is
  addressable (an offset may exceed Window_Size into it); once the total
  passes Window_Size the dictionary is out of reach, and a match that still
  references it is `OffsetTooFar`. The C's whole-buffer decoder is lenient
  here — it checks only the history it holds — so a frame hand-built to that
  leniency can decode there and fail here. A `Reader` keeps its history in
  the `Buffer` you give it: `window_len` bytes of history, one 128 KiB block
  of output, and room to stage one compressed block (a block is decoded from
  its end, so all of it is read first). A frame that declares a Window_Size
  above `window_len` fails with `WindowTooLarge` before any block is read;
  the default covers the 8 MiB window `zstd -19` writes on large input.
- **Dictionaries.** `zstd.Dictionary` is parsed once (§5) and seeds a frame's
  literals and FSE tables, its repeat offsets (the dictionary's 12 bytes in
  place of {1,4,8}), and its history (the content in front of the output).
  Both directions use the one value: the decoder takes the parsed decode
  tables, and the encoder takes the encode tables (with
  `ZSTD_loadCEntropy`'s promotion rules — a table is reused only when it
  covers what the frame needs, the literals tree only when it spans all 256
  symbols with no zero weight) and the content as matchable history. A
  frame that reuses a dictionary's tables carries Treeless literals and
  Repeat sequences from its first block, which is what a CLI-trained
  dictionary produces at level 1. A
  frame whose Dictionary_ID does not match the supplied dictionary fails
  `DictionaryMismatch`; a frame that names an ID with no dictionary supplied
  fails `DictionaryRequired` before any body byte; a frame with no ID decodes
  with or without a dictionary, and a supplied one still seeds it. The
  parse accepts the incomplete statistics some trainers emit (zero weights,
  tables short of the alphabet), which the C before v1.5.6 rejected. It is
  RFC-strict where the C is not: a literals tree deeper than §4.2.1's 11-bit
  limit is `MalformedHuffmanWeights`, so the C's own
  `http-dict-missing-symbols` fixture (a 12-bit tree) is rejected here.
  `initRaw` takes content-only dictionaries: no tables, the default repcodes,
  and no ID, so they never satisfy a frame that declares one. The value
  borrows its source bytes and must outlive every call that uses it.
- **Frames and trailing bytes.** `decompress` skips any skippable frames
  (§3.1.2), decodes the next frame, and ignores whatever follows; it never
  looks at a second frame. A `Reader` skips skippable frames, decodes one
  frame, and consumes `input` through that frame's last byte, so `input` is
  left at whatever follows. `Reader.streamAll` walks every frame until `input`
  ends: skippable frames produce no output, and trailing bytes that do not
  start a frame fail with `ReadFailed` (`BadMagic` is the cause).
- **Empty input.** Zero bytes is an error, because no frame began: `Truncated`
  from `decompress`, and `ReadFailed` (cause `Truncated`) from a `Reader` or
  `streamFrame`. `streamAll` treats it as a clean end with zero bytes. Encoding
  zero bytes is fine: a header, one raw 0-size last block, and the checksum.
- **Corrupt input.** Decoding stops at the first invalid byte with an error
  from the sets above. Sizes the input declares (blocks, windows,
  Frame_Content_Size, skippable frames) are checked against your buffers and
  never trusted; a 4 GiB skippable frame is skipped without buffering it.
- **Partial output.** The content checksum (§3.1.1) and Frame_Content_Size are
  checked at the end of the frame, so a corrupt frame can deliver output before
  the error. Trust the output only after the call returns without error or the
  `Reader` reports `EndOfStream`; after a failure a `Reader` stays failed.
- **Stack.** A compressed block decodes its literals into a 128 KiB buffer on
  the stack. Measured on aarch64 Linux, `decompress` and `Reader` need about
  160 KiB of thread stack in release builds and 210 KiB in Debug, so give
  decoding threads 256 KiB or more. `encode.compress` needs about 830 KiB
  (Debug and release alike): the match finder's table (128 KiB), the literals
  buffer (128 KiB), and the sequence list (512 KiB) are stack scratch, the
  price of a one-shot with no allocator — give encoding threads 1 MiB or more.
  `encode.compressBuffered` and `Writer.streamAll` are the same encoders over a
  caller-owned `Buffer`, and need about 64 KiB of thread stack (measured by the
  same bisect: 37-48 KiB release, 41-57 KiB Debug, flat from 600 KiB to 1.5 MiB
  of input; give them 64 KiB and keep the thread's own frames small).
- **Allocation.** None while encoding or decoding. `Reader.streamFrameAlloc`
  and `Reader.streamAllAlloc` allocate one `Reader.DefaultBuffer` (8 MiB + 256
  KiB), and `Writer.streamAllAlloc` one `Writer.DefaultBuffer` (1.44 MiB), from
  your allocator for the call, and free it before returning; a failed
  allocation is `error.OutOfMemory`.
- **Reader input.** `input` needs a buffer of at least 4 bytes; `Io.Reader.fixed`
  always qualifies. A contiguous `peek` or `take` of up to 128 KiB is served; a
  larger one fails with `StreamTooLong` when the window cannot hold it at the
  read position.

## Limitations

- Levels 1 and 3 only: level 1 is the level-1 class and level 3 the dfast
  class; levels 2 and 4-19, and anything outside 1-19, are reserved seats
  that return `error.Unimplemented` (a `Writer` made with one fails every
  write and `finish`). Each of the CLI's other levels is a distinct output
  class this package cannot produce.
- No trainer: a dictionary is an input. `zstd --train` (the CLI's fastCover)
  or any other tool produces the file, and `zstd.Dictionary` consumes it; an
  in-repo trainer is out of scope. Content-only dictionaries work through
  `initRaw`, but they name no Dictionary_ID, so they never satisfy a frame
  that declares one.
- On 32-bit targets, the one-call pumps count bytes in a `usize` (inside std's
  `streamRemaining`), so more than 4 GiB through one call overflows. Read or
  write through a `Reader`/`Writer` and count in a `u64` instead.

## Testing and benchmarks

`just test` runs the unit tests: frames built by hand or produced by `zstd`
1.5.7 and checked against it — including the encoder's own output, which
reproduces the CLI's `zstd -1` bytes on the recorded fixtures — tables from the
RFC, encode and decode round trips, and a check on every decode that no byte
past the output was written.
`just zstd-oracle` cross-checks both directions against the reference CLI and
klauspost/compress on non-ASCII and over-512-KiB inputs, including the strict
Window_Size check the C decoder does not make, plus the dictionary rows: a
CLI-trained dictionary over the corpus shapes, every `-D` frame decoded here
and by klauspost's `WithDecoderDicts`, the mismatch matrix, and the §5
boundary pair with the CLI's own verdicts recorded.
`just fuzz 1M` runs the fuzz targets (ReleaseSafe only), and `just check-32`
runs a large-frame probe on wasm32-wasi under wasmtime. `just corpus` generates
the hash-checked benchmark corpus, and `just bench` runs the local benchmarks;
local numbers are not performance claims. Design notes, RFC errata, and the
test inventory are in [`AGENTS.md`](AGENTS.md).

## License

MIT, like the rest of the repository. Ports and vendored artifacts are
attributed in [`THIRD_PARTY.md`](../../THIRD_PARTY.md).

[rfc8878]: https://www.rfc-editor.org/rfc/rfc8878.txt
