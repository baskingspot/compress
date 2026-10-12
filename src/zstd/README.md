# zstd

A Zstandard decoder in pure Zig: frames, blocks, the Huffman and FSE entropy
layers, the XXH64 content checksum, and a streaming `std.Io.Reader`. It is the
`zcompress.zstd` namespace. It imports only `std` and `fastmem`, and decoding
allocates nothing.

The format is [RFC 8878][rfc8878], vendored at
`docs/research/specs/rfc8878-zstd.txt`; `§` cites in this directory are
sections of that file. This namespace only decodes: the encoder is not
implemented yet.

## Usage

One call, when the whole frame is in memory and you can bound its decoded size:

```zig
const zstd = @import("zcompress").zstd;

/// Decodes the first frame of `compressed` into `target`; returns the decoded bytes.
fn decodeOne(compressed: []const u8, target: []u8) ![]u8 {
    const len = try zstd.decode.decompress(compressed, target);
    return target[0..len];
}
```

Streaming, through a `std.Io.Reader` over one frame:

```zig
const std = @import("std");
const zstd = @import("zcompress").zstd;

const window_len = 1024 * 1024; // accept frames that declare a window up to 1 MiB

/// `buffer` is 1.25 MiB: keep it in static or heap storage, not on a small stack.
fn decodeFrame(
    input: *std.Io.Reader,
    output: *std.Io.Writer,
    buffer: *zstd.Reader.Buffer(window_len),
) !usize {
    var r: zstd.Reader = .init(window_len, input, buffer);
    return r.reader.streamRemaining(output) catch |err| switch (err) {
        error.ReadFailed => return r.err.?, // the cause, e.g. error.WrongChecksum
        error.WriteFailed => return err,
    };
}
```

To decode every frame in `input` with the default 8 MiB window, allocated for
the call: `_ = try zstd.Reader.streamAllAlloc(allocator, input, output);`. The
example CLI does this: `just example zstd decode file.zst > out`.

## API

```zig
const zstd = @import("zcompress").zstd; // two names: `decode` and `Reader`

// One-shot decode.
zstd.decode.decompress(source: []const u8, target: []u8) DecompressError!usize
zstd.decode.max_block_size: usize // 128 KiB, the largest block a frame can carry (§3.1.1.2.4)
zstd.decode.DecompressError = error{
    BufferTooSmall,           // `target` cannot hold the decoded frame
    BadMagic,                 // not a Zstandard or skippable frame (§3.1)
    ReservedBitSet,           // reserved bit set in the frame header (§3.1.1.1.1.4)
    DictionaryRequired,       // the frame names a dictionary (§3.1.1.1.3)
    BlockOversize,            // a block exceeds min(Window_Size, 128 KiB) (§3.1.1.2.4)
    ReservedBlock,            // reserved block type (§3.1.1.2.2)
    MalformedLiteralsHeader,  // literals section header cut short (§3.1.1.3.1.1)
    LiteralsTooLarge,         // literals sizes do not fit the block (§3.1.1.3.1)
    TreelessLiteralsFirst,    // reuses a Huffman tree no earlier block defined
    MalformedHuffmanWeights,  // bad Huffman tree description (§4.2.1)
    MalformedFseTable,        // bad FSE table description (§4.1.1)
    MalformedSequencesHeader, // sequences header runs past the block (§3.1.1.3.2.1)
    RepeatModeFirst,          // reuses an FSE table no earlier block defined
    ReservedModeBits,         // reserved bits set in the sequence modes byte
    MissingStartBit,          // a backwards bitstream ends in a zero byte (§4.2.2)
    InvalidBitStream,         // a bitstream ran out of bits
    BitstreamNotConsumed,     // bits left over at the end of a bitstream
    ZeroOffset,               // a match with offset 0 (§3.1.1.5)
    OffsetTooFar,             // a match reaches before the available history (§3.1.1.4)
    ContentSizeMismatch,      // output size differs from Frame_Content_Size (§3.1.1.1.4)
    WrongChecksum,            // content checksum mismatch (§3.1.1)
    Truncated,                // the input ended inside a frame
};

// Streaming decode. One `Reader` decodes one frame.
zstd.Reader.Buffer(comptime window_len: usize) type
    // [window_len + 128 KiB + min(window_len, 128 KiB)]u8; `window_len` must be >= 1024
zstd.Reader.default_window_len: usize // 8 MiB
zstd.Reader.DefaultBuffer // Buffer(default_window_len): 8 MiB + 256 KiB
zstd.Reader.init(comptime window_len: usize, input: *Io.Reader, buffer: *Buffer(window_len)) Reader
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
// drive a `Reader` for the cause.
zstd.Reader.streamFrame(comptime window_len: usize, in: *Io.Reader, out: *Io.Writer,
    buffer: *Buffer(window_len)) error{ReadFailed, WriteFailed}!usize
zstd.Reader.streamAll(comptime window_len: usize, in: *Io.Reader, out: *Io.Writer,
    buffer: *Buffer(window_len)) error{ReadFailed, WriteFailed}!usize
// The same two with the default window, allocated from `allocator` for the call:
zstd.Reader.streamFrameAlloc(allocator: Allocator, in: *Io.Reader, out: *Io.Writer)
    error{ReadFailed, WriteFailed, OutOfMemory}!usize
zstd.Reader.streamAllAlloc(allocator: Allocator, in: *Io.Reader, out: *Io.Writer)
    error{ReadFailed, WriteFailed, OutOfMemory}!usize
```

The layers the decoders are built from are also public under `zstd.decode`:
`frame`, `block`, `literals`, `sequences`, `fse`, and `window` (the
Window_Size arithmetic of §3.1.1.1.2). Most callers never need them.

## Behavior

- **Buffers.** You own every buffer, and the decoder keeps nothing between
  calls. `decompress` writes only into `target`, leaves the bytes past the
  returned length untouched, and returns `error.BufferTooSmall` before any
  write that would pass the end. Size `target` from what you know about the
  data: a frame may declare its decoded size (Frame_Content_Size, §3.1.1.1.4),
  but many do not, and a declared size is checked against the output, never
  used to size anything.
- **Windows.** The one-shot needs no window: a match can only reach back into
  output already in `target`. A `Reader` keeps its history in the `Buffer` you
  give it: `window_len` bytes of history, one 128 KiB block of output, and room
  to stage one compressed block (a block is decoded from its end, so all of it
  is read first). A frame that declares a Window_Size above `window_len` fails
  with `WindowTooLarge` before any block is read. For scale, on large or piped
  input `zstd -19` writes 8 MiB windows, `--long=26` 64 MiB, and `--ultra -22`
  128 MiB; the default window covers the first.
- **Frames and trailing bytes.** `decompress` skips any skippable frames
  (§3.1.2), decodes the next frame, and ignores whatever follows. It does not
  report how many bytes it used, and it never looks at a second frame. A
  `Reader` skips skippable frames, decodes one frame, and consumes `input`
  through that frame's last byte (the checksum, when there is one), so `input`
  is left at whatever follows. `Reader.streamAll` walks every frame until
  `input` ends: skippable frames produce no output, and bytes that do not
  start a frame fail with `ReadFailed` (`BadMagic` is the cause).
- **Empty input.** Zero bytes is an error, because no frame began:
  `Truncated` from `decompress`, and `ReadFailed` (cause `Truncated`) from a
  `Reader` or `streamFrame`. `streamAll` treats it as a clean end with zero
  bytes. Input made only of skippable frames decodes to zero bytes everywhere.
- **Corrupt input.** Decoding stops at the first invalid byte with an error
  from the sets above. Sizes the input declares (blocks, windows,
  Frame_Content_Size, skippable frames) are checked against your buffers and
  never trusted; a 4 GiB skippable frame is skipped without buffering it.
- **Partial output.** The content checksum (§3.1.1) and Frame_Content_Size are
  checked at the end of the frame, so a corrupt frame can deliver output before
  the error. Trust the output only after the call returns without error or the
  `Reader` reports `EndOfStream`. After a failure `target` may hold partial
  output, and a `Reader` stays failed: every later read returns `ReadFailed`. A
  caller that stops reading before the end of a frame never sees the checksum
  check.
- **Stack.** A compressed block decodes its literals into a 128 KiB buffer on
  the stack. Measured on aarch64 Linux, `decompress` and `Reader` need about
  160 KiB of thread stack in release builds and 210 KiB in Debug, so a 128 KiB
  thread stack (musl's default) overflows. Give decoding threads 256 KiB or
  more.
- **Allocation.** None while decoding. `streamFrameAlloc` and `streamAllAlloc`
  allocate one `DefaultBuffer` from your allocator for the duration of the call
  and free it before returning; a failed allocation is `error.OutOfMemory`.
- **Reader input.** `input` needs a buffer of at least 4 bytes (a smaller one
  trips an assertion); `Io.Reader.fixed` always qualifies. A contiguous `peek`
  or `take` of up to 128 KiB is served; a larger one fails with `StreamTooLong`
  when the window cannot hold it at the read position.

## Limitations

- Decode only: `zstd.encode` and `zstd.Writer` do not exist.
- No dictionary support. A frame that names a dictionary fails with
  `DictionaryRequired` before any block is read, raw-content dictionaries
  included.
- On 32-bit targets, `streamFrame` and `streamAll` count output in a `usize`
  (inside std's `streamRemaining`), so more than 4 GiB through them overflows.
  Read through a `Reader` and count in a `u64` instead.

## Testing and benchmarks

`just test` runs the unit tests: frames built by hand or produced by `zstd`
1.5.7 and checked against it, tables from the RFC, and a check on every decode
that no byte past the output was written. `just fuzz 1M` runs the fuzz targets
(ReleaseSafe only), and `just check-32` runs a large-frame probe on wasm32-wasi
under wasmtime. `just corpus` generates the hash-checked benchmark corpus, and
`just bench` runs the local decode benchmarks over it. Local numbers are not
performance claims; claims cite a run recorded under `docs/results/`. Design
notes, RFC errata, and the test inventory are in [`AGENTS.md`](AGENTS.md).

## License

MIT, like the rest of the repository. Ports and vendored artifacts are
attributed in [`THIRD_PARTY.md`](../../THIRD_PARTY.md).

[rfc8878]: https://www.rfc-editor.org/rfc/rfc8878.txt
