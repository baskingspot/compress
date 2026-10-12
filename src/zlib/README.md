# zlib

zlib streams ([RFC 1950][rfc1950]) for Zig: a 2-byte header, a DEFLATE body, and
a big-endian Adler-32 trailer. The compression is [flate](../flate/README.md)'s
(RFC 1951); this package adds the framing, the checksum, and `std.Io` streaming.
It is the `zcompress.zlib` namespace. It uses `std`, `fastmem`, and `src/flate/`
(copy `src/zlib/` out with `src/flate/` and `src/internal/`), allocates nothing,
and takes caller-owned buffers. The spec is vendored at
`docs/research/specs/rfc1950-zlib.txt`.

## Usage

One-shot. The format does not record the decoded length, so you choose the cap
for `decompress`; `maxCompressedLength` sizes the target for `compress`.

```zig
const std = @import("std");
const zlib = @import("zcompress").zlib;

fn roundTrip(gpa: std.mem.Allocator, source: []const u8) !void {
    const target = try gpa.alloc(u8, zlib.encode.maxCompressedLength(source.len));
    defer gpa.free(target);
    const stream = target[0..try zlib.encode.compress(source, target, .{})];

    const plain = try gpa.alloc(u8, source.len);
    defer gpa.free(plain);
    const n = try zlib.decode.decompress(stream, plain);
    std.debug.assert(std.mem.eql(u8, source, plain[0..n]));
}
```

Streaming, over any `*std.Io.Writer` and `*std.Io.Reader`:

```zig
fn compressTo(out: *std.Io.Writer, bytes: []const u8) !void {
    var buffer: zlib.Writer.Buffer = undefined; // 98,303 bytes
    var w: zlib.Writer = .init(out, &buffer, .{});
    try w.writer.writeAll(bytes);
    try w.finish(); // writes the trailer; the stream is incomplete without it
}

fn decompressTo(out: *std.Io.Writer, in: *std.Io.Reader) !void {
    var buffer: zlib.Reader.Buffer = undefined; // 65,536 bytes
    var r: zlib.Reader = .init(in, &buffer);
    _ = r.reader.streamRemaining(out) catch |err| switch (err) {
        error.ReadFailed => return r.err.?, // BadHeader, WrongChecksum, ...
        error.WriteFailed => return error.WriteFailed,
    };
}
```

`Writer.streamAll` and `Reader.streamAll` pump a whole stream in one call;
`Reader.streamAll` reports only `error.ReadFailed`, not the cause.
`just example zlib encode FILE > out` runs the example CLI.

## API

```zig
// One-shot
zlib.encode.Level          // flate's level type: .fast (default), .@"0" to .@"9", .ratio
zlib.encode.Options        // struct { level: Level = .fast }
zlib.encode.maxCompressedLength(input_len: usize) usize
zlib.encode.compress(source: []const u8, target: []u8, options: Options)
    error{ BufferTooSmall, Unimplemented }!usize      // the stream's length
zlib.decode.decompress(source: []const u8, target: []u8) DecompressError!usize
zlib.decode.DecompressError = flate.decode.DecompressError || error{
    BadHeader, DictionaryRequired, WrongChecksum,
};

// Streaming: write through `w.writer`, read through `r.reader`
zlib.Writer.Buffer = [98303]u8
zlib.Writer.init(output: *Io.Writer, buffer: *Buffer, options: Options) Writer
zlib.Writer.finish(w: *Writer) Io.Writer.Error!void
zlib.Writer.streamAll(in: *Io.Reader, out: *Io.Writer, options: Options)
    error{ ReadFailed, WriteFailed }!usize            // input bytes consumed
zlib.Reader.Buffer = [65536]u8
zlib.Reader.init(input: *Io.Reader, buffer: *Buffer) Reader
zlib.Reader.err: ?Error    // the cause once `r.reader` returns error.ReadFailed
zlib.Reader.Error = flate.Reader.Error || error{ BadHeader, DictionaryRequired, WrongChecksum };
zlib.Reader.streamAll(in: *Io.Reader, out: *Io.Writer)
    error{ ReadFailed, WriteFailed }!usize            // decoded bytes written
```

The framing pieces are public too: `encode.cmf`, `flgFor`, `writeHeader`,
`writeTrailer`, and the `header_len` and `trailer_len` constants, and
`decode.checkHeader`, `checkTrailer`, `flg_fdict`, and `readExact`.

## Behavior

- **Buffers.** The caller owns every buffer. Nothing is allocated, freed, or
  retained, and no function takes an allocator. Do not move or copy a `Reader`
  or `Writer` after its first read or write.
- **Sizing.** `maxCompressedLength(n)` is `n + 5 * ceil(n / 65535) + 8`. A
  smaller target can still be enough for data that compresses well; if it is too
  small, `compress` returns `error.BufferTooSmall` and the target's contents are
  unspecified. `decompress` treats `target` as a cap: a stream that decodes to
  more returns `error.BufferTooSmall`. Neither writes past `target`.
- **Corrupt input.** Decoding returns an error at the first invalid byte:
  `Truncated` (the input ends early, empty input included), `BadHeader` (CM is
  not 8, CINFO is above 7, or `CMF*256 + FLG` is not a multiple of 31),
  `DictionaryRequired` (FDICT is set), `WrongChecksum` (the Adler-32 does not
  match), or one of flate's errors for a malformed body (`InvalidBlockType`,
  `InvalidCode`, `InvalidMatch`, and so on). FLEVEL is ignored.
- **The checksum is verified last.** The Adler-32 is compared after the body is
  decoded, so when `WrongChecksum` arrives the output already exists: treat
  output as unverified until decoding succeeds. A streaming caller must read to
  `error.EndOfStream` (`streamRemaining` and `streamAll` do); one that stops at
  an expected length never triggers the check.
- **After the stream.** The format ends at ADLER32. `decompress` ignores bytes
  after it and does not say where the stream ended. `Reader` consumes its input
  exactly through ADLER32 and leaves the rest unread, so to read streams back to
  back, start a new `Reader` on the same input.
- **Streaming.** The writer emits the header with its first compressed output.
  `w.writer.flush()` ends the current block and keeps the stream open;
  `finish()` writes the end of the deflate stream and the trailer, and is
  terminal (later writes and a second `finish` return `error.WriteFailed`). The
  reader's input must buffer at least 3 bytes, or end sooner. `peek` and `take`
  of up to 32 KiB are always served; a larger contiguous request can fail with
  `error.ReadFailed` and `r.err == error.StreamTooLong`.
- **Stack.** `encode.compress` uses about 128 KiB (flate's match-finder table).
  `decode.decompress` and `Reader.streamAll` use about 68 KiB. `Writer.streamAll`
  peaks near 288 KiB. A stack-allocated `Writer.Buffer` adds 96 KiB and a
  `Reader.Buffer` 64 KiB; heap-allocate them on a small stack.
- **Output.** The encoder is deterministic: CMF is always `0x78` (deflate, 32 KiB
  window), FDICT is never set, and FLEVEL follows the level (`encode.flgFor`).
  The default header is `78 9c`; the empty stream is `78 9c 03 00 00 00 00 01`.

## Limitations

- No preset dictionaries. A stream with FDICT set returns `DictionaryRequired`
  before any body byte is decoded, and the encoder never sets FDICT.
- `.ratio` is not implemented. `compress` returns `error.Unimplemented`, and a
  `Writer` made with it fails every write and `finish`.
- The encoder writes fixed-Huffman and stored blocks only, and `.@"1"` to `.@"9"`
  encode like `.fast`, so output is larger than a dynamic-Huffman encoder's. The
  decoder handles every block type.

## Testing and benchmarks

`just test` runs the unit tests and the golden vectors. `just fuzz [BUDGET]` runs
the fuzz targets, and `just zlib-oracle` cross-checks the codec against python3's
`zlib` in both directions. `just bench` runs local benchmarks, with raw-flate
rows that show what the container adds. Local numbers are not performance claims.

## License

MIT, like the rest of zcompress. Ported test vectors are attributed in
[`THIRD_PARTY.md`](../../THIRD_PARTY.md).

[rfc1950]: https://www.rfc-editor.org/rfc/rfc1950.txt
