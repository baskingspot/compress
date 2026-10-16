# zlib

zlib streams ([RFC 1950][rfc1950]) for Zig: a 2-byte header, a DEFLATE body, and
a big-endian Adler-32 trailer. The compression is [flate](../flate/README.md)'s
(RFC 1951); this package adds the framing, the preset dictionary (§2.2), the
checksum, and `std.Io` streaming. It is the `compress.zlib` namespace. It uses
`std`, `fastmem`, and `src/flate/` (copy `src/zlib/` out with `src/flate/` and
`src/internal/`), allocates nothing, and takes caller-owned buffers. The spec
is vendored at `docs/research/specs/rfc1950-zlib.txt`.

## Usage

One-shot. The format does not record the decoded length, so you choose the cap
for `decompress`; `maxCompressedLength` sizes the target for `compress`.

```zig
const std = @import("std");
const zlib = @import("compress").zlib;

fn roundTrip(gpa: std.mem.Allocator, source: []const u8) !void {
    const target = try gpa.alloc(u8, zlib.encode.maxCompressedLength(source.len));
    defer gpa.free(target);
    const stream = target[0..try zlib.encode.compress(source, target, .{})];

    const plain = try gpa.alloc(u8, source.len);
    defer gpa.free(plain);
    const n = try zlib.decode.decompress(stream, plain, null);
    std.debug.assert(std.mem.eql(u8, source, plain[0..n]));
}
```

A preset dictionary (§2.2 FDICT) is raw caller bytes, fed to the compressor
before any output and pre-seeding the decoder's 32 KiB window. The header's
DICTID is the Adler-32 of the whole slice:

```zig
// dict: the dictionary bytes, both directions. A dictionary longer than
// 32 KiB contributes only its last 32 KiB to the window; DICTID names the
// whole, so decode needs the full slice.
fn withDictionary(gpa: std.mem.Allocator, dict: []const u8, source: []const u8) !void {
    const target = try gpa.alloc(u8, zlib.encode.maxCompressedLength(source.len));
    defer gpa.free(target);
    const stream = target[0..try zlib.encode.compress(source, target, .{ .dict = dict })];

    const plain = try gpa.alloc(u8, source.len);
    defer gpa.free(plain);
    const n = try zlib.decode.decompress(stream, plain, dict);
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
    var r: zlib.Reader = .init(in, &buffer, null);
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
// One-shot. `dict` is the stream's preset dictionary or `null` (§2.2): on
// encode it sets FDICT and writes the Adler-32 of the whole slice as DICTID;
// on decode it is checked against the header's DICTID before any body byte.
zlib.encode.Level          // flate's level type: .fast (default), .@"0" to .@"9", .ratio
zlib.encode.Options        // struct { level: Level = .fast, dict: ?[]const u8 = null }
zlib.encode.maxCompressedLength(input_len: usize) usize
zlib.encode.compress(source: []const u8, target: []u8, options: Options)
    error{ BufferTooSmall, Unimplemented }!usize      // the stream's length
zlib.decode.decompress(source: []const u8, target: []u8, dict: ?[]const u8) DecompressError!usize
zlib.decode.DecompressError = flate.decode.DecompressError || error{
    BadHeader, DictionaryRequired, DictionaryMismatch, WrongChecksum,
};

// Streaming: write through `w.writer`, read through `r.reader`
zlib.Writer.Buffer = [98303]u8
zlib.Writer.init(output: *Io.Writer, buffer: *Buffer, options: Options) Writer
zlib.Writer.finish(w: *Writer) Io.Writer.Error!void
zlib.Writer.streamAll(in: *Io.Reader, out: *Io.Writer, options: Options)
    error{ ReadFailed, WriteFailed }!usize            // input bytes consumed
zlib.Reader.Buffer = [65536]u8
zlib.Reader.init(input: *Io.Reader, buffer: *Buffer, dict: ?[]const u8) Reader
zlib.Reader.err: ?Error    // the cause once `r.reader` returns error.ReadFailed
zlib.Reader.Error = flate.Reader.Error || error{
    BadHeader, DictionaryRequired, DictionaryMismatch, WrongChecksum,
};
zlib.Reader.streamAll(in: *Io.Reader, out: *Io.Writer, dict: ?[]const u8)
    error{ ReadFailed, WriteFailed }!usize            // decoded bytes written
```

The framing pieces are public too: `encode.cmf`, `flgFor`, `writeHeader`,
`writeDictId`, `writeTrailer`, and the `header_len`, `dict_id_len`, and
`trailer_len` constants, and `decode.checkHeader`, `checkDictionary`,
`checkTrailer`, `flg_fdict`, and `readExact`.

## Behavior

- **Buffers.** The caller owns every buffer. Nothing is allocated, freed, or
  retained, and no function takes an allocator. Do not move or copy a `Reader`
  or `Writer` after its first read or write.
- **Sizing.** `maxCompressedLength(n)` is `n + 5 * ceil(n / 65535) + 12`: the
  2-byte header, the 4-byte DICTID (reserved whether or not a dictionary is
  used), the 4-byte trailer, and flate's body bound. A smaller target can still
  be enough for data that compresses well; if it is too small, `compress`
  returns `error.BufferTooSmall` and the target's contents are unspecified.
  `decompress` treats `target` as a cap: a stream that decodes to more returns
  `error.BufferTooSmall`. Neither writes past `target`.
- **Dictionaries.** The preset dictionary is raw caller bytes, both
  directions (§2.2). On encode it is fed to the compressor before any output
  (the window's oldest bytes) and named by the header's DICTID; on decode it
  pre-seeds the window, and a distance may reach into it until the output
  pushes it out of the 32 KiB window. A dictionary longer than 32 KiB
  contributes only its last 32 KiB to the window, while DICTID names the
  whole — supply the full slice on decode, or the Adler-32 compare fails. The
  ADLER32 trailer covers the output excluding the dictionary. With FDICT
  clear the stream names no dictionary and a supplied `dict` is unused; with
  FDICT set and `dict` null the decode fails `DictionaryRequired` before any
  body byte, and a dictionary whose Adler-32 is not DICTID fails
  `DictionaryMismatch`. An empty slice is no dictionary on encode — the header
  carries no DICTID and FDICT stays clear — so `null` and `""` encode alike;
  on decode an empty dictionary is simply one whose Adler-32 cannot match.
- **Corrupt input.** Decoding returns an error at the first invalid byte:
  `Truncated` (the input ends early, empty input included), `BadHeader` (CM is
  not 8, CINFO is above 7, or `CMF*256 + FLG` is not a multiple of 31),
  `DictionaryRequired` (FDICT is set and `dict` is null), `DictionaryMismatch`
  (`dict`'s Adler-32 is not the header's DICTID), `WrongChecksum` (the
  Adler-32 does not match), or one of flate's errors for a malformed body
  (`InvalidBlockType`, `InvalidCode`, `InvalidMatch`, and so on). FLEVEL is
  ignored.
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
- **Output.** The encoder is deterministic: CMF is always `0x78` (deflate,
  32 KiB window), FLEVEL follows the level (`encode.flgFor`), and FDICT is set
  exactly when a non-empty `options.dict` is, with DICTID the Adler-32 of the
  whole dictionary (most-significant byte first); otherwise FDICT is never set.
  The default header is `78 9c`; with a dictionary it is `78 bb` plus the
  4-byte DICTID at the default level (FLEVEL 0 gives `78 20`, the minimal
  FCHECK; C zlib's naive arithmetic writes `78 3f` there, and both are
  conformant). The empty stream is `78 9c 03 00 00 00 00 01`.

## Limitations

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

MIT, like the rest of compress. Ported test vectors are attributed in
[`THIRD_PARTY.md`](../../THIRD_PARTY.md).

[rfc1950]: https://www.rfc-editor.org/rfc/rfc1950.txt
