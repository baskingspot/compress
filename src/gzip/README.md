# gzip

gzip (RFC 1952) for Zig: one-shot `compress` and `decompress` over caller-owned
buffers, and streaming `Writer` and `Reader` types for `std.Io`. A gzip member is
a 10-byte header, a deflate body, and an 8-byte trailer holding the CRC-32 and
size of the original data. The deflate codec is `src/flate/`; this module adds
the framing and the checksum. It depends on `std`, `fastmem`, flate, and the
shared helpers in `src/internal/`, and never allocates. The format is
[RFC 1952][rfc1952], vendored at `docs/research/specs/rfc1952-gzip.txt`.

## Usage

```zig
// One-shot, over caller-owned buffers.
const std = @import("std");
const gzip = @import("zcompress").gzip;

fn roundTrip(gpa: std.mem.Allocator, data: []const u8) !void {
    const member = try gpa.alloc(u8, gzip.encode.maxCompressedLength(data.len));
    defer gpa.free(member);
    const member_len = try gzip.encode.compress(data, member, .{});

    const plain = try gpa.alloc(u8, data.len); // the caller must know the size
    defer gpa.free(plain);
    const n = try gzip.decode.decompress(member[0..member_len], plain);
    std.debug.assert(std.mem.eql(u8, data, plain[0..n]));
}
```

```zig
// Streaming, through the std.Io interfaces.
fn streamingRoundTrip(gpa: std.mem.Allocator, input: []const u8) !void {
    var member: std.Io.Writer.Allocating = .init(gpa);
    defer member.deinit();
    var wbuf: gzip.Writer.Buffer = undefined;
    var w: gzip.Writer = .init(&member.writer, &wbuf, .{});
    try w.writer.writeAll(input);
    try w.finish(); // required: it writes the trailer

    var in: std.Io.Reader = .fixed(member.written());
    var rbuf: gzip.Reader.Buffer = undefined;
    var r: gzip.Reader = .init(&in, &rbuf);
    const plain = try r.reader.allocRemaining(gpa, .unlimited); // r.err says why on ReadFailed
    defer gpa.free(plain);
}
```

`gzip.Writer.streamAll(in, out, .{})` and `gzip.Reader.streamAll(in, out)` are the
one-call versions; `just example gzip encode FILE > FILE.gz` runs them.

## API

```zig
// Names are relative to gzip = @import("zcompress").gzip
encode.Level          // flate's level enum: .fast (default), .@"0" .. .@"9", .ratio
encode.Options        // struct { level: Level = .fast }
encode.maxCompressedLength(input_len: usize) usize
encode.compress(source: []const u8, target: []u8, options: Options)
    error{ BufferTooSmall, Unimplemented }!usize

decode.decompress(source: []const u8, target: []u8) DecompressError!usize
decode.DecompressError = flate.decode.DecompressError || error{
    BadHeader,           // ID1, ID2, or CM wrong, or a reserved FLG bit (§2.3.1.2)
    HeaderTooLong,       // FNAME or FCOMMENT over 512 bytes, NUL included
    WrongHeaderChecksum, // the optional header CRC16 (FHCRC) does not match
    WrongChecksum,       // the trailer's CRC-32 does not match the data
    WrongSize,           // the trailer's size does not match the data
}

Writer.Buffer = [98303]u8
Writer.init(output: *Io.Writer, buffer: *Buffer, options: encode.Options) Writer
w.writer              // the Io.Writer to write to
w.finish() Io.Writer.Error!void
Writer.streamAll(in: *Io.Reader, out: *Io.Writer, options: encode.Options)
    error{ ReadFailed, WriteFailed }!usize
Reader.Buffer = [65536]u8
Reader.init(input: *Io.Reader, buffer: *Buffer) Reader
r.reader              // the Io.Reader to read from
r.err                 // ?Reader.Error, set after error.ReadFailed
Reader.Error = flate.Reader.Error || <the five header and trailer errors above>
Reader.streamMember(in: *Io.Reader, out: *Io.Writer) error{ ReadFailed, WriteFailed }!usize
Reader.streamAll(in: *Io.Reader, out: *Io.Writer) error{ ReadFailed, WriteFailed }!usize
```

flate's errors cover the rest: `Truncated` (the input ended early, or was empty),
`BufferTooSmall` (`decompress` only: the decoded member does not fit `target`),
and `InvalidBlockType` through `InvalidMatch` for a malformed deflate body.
`Reader.Error` also has `StreamTooLong`. Also public: `encode.writeHeader`,
`writeTrailer`, `xflFor`, `header_len`, `trailer_len`, and `decode.HeaderParser`,
`checkTrailer`, `name_comment_cap`.

## Behavior

- **Buffers.** The caller owns every buffer; nothing is allocated, freed, or retained.
- **Sizing.** `maxCompressedLength(n)` is `n + 5 * ceil(n / 65535) + 20`. A smaller
  `target` can still work when the data compresses; otherwise `compress` returns
  `error.BufferTooSmall`. `decompress` takes `target` as a cap and returns
  `error.BufferTooSmall` before writing past it. The decoded size is not known in
  advance: the trailer holds it, modulo 2^32, after the body.
- **Corrupt input.** Every malformed header, body, or trailer returns a specific
  error, and `target` is unspecified after one. `Reader` serves decoded bytes as
  it goes and checks the trailer at the end of the member, so its output is
  unverified until the whole member has been read without an error. An empty input
  is `Truncated`, except that `Reader.streamAll` treats it as zero members.
- **After the member.** `decompress` ignores bytes after the trailer and does not
  say where the member ended. `Reader` consumes `input` exactly through the
  trailer's last byte and leaves the rest unread. `Reader.streamAll` reads what
  follows as another member: end of input ends the walk, and anything else is
  parsed as a header, so trailing garbage returns `error.ReadFailed`.
- **Writer.** Nothing reaches `output` until the buffer fills or you call
  `w.writer.flush()` (which keeps the writer usable) or `finish`; the first output
  is the header. `finish` is required and final: it writes the last block and the
  trailer and flushes `output`. After it, or after a failed write, the writer
  returns `error.WriteFailed`.
- **Headers.** Output is reproducible: FLG=0, MTIME=0, OS=255, no name or
  comment, and XFL 4 for `.fast`, `.@"0"`, and `.@"1"`, 2 for `.@"9"`, else 0. The
  decoder checks ID1, ID2, CM, and the reserved flags, verifies FHCRC when
  present, skips the extra field, name, and comment without storing them, and
  ignores (and does not return) MTIME, XFL, OS, and FTEXT.
- **Reader input.** `input` needs a buffer of at least 3 bytes. A `peek` or `take`
  of more than 32 KiB can fail with `error.ReadFailed` and `err == .StreamTooLong`.
  Once used, a `Reader` or `Writer` points into itself: initialize it in place and
  do not copy or move it.
- **Stack.** `compress` uses about 128 KiB; `decompress`, `Reader.streamMember`,
  and `Reader.streamAll` about 68 KiB. A `Writer` is about 128 KiB plus its 96 KiB
  `Buffer`, and `Writer.streamAll` peaks near 288 KiB. On small stacks, allocate
  the writer and its buffer on the heap.

## Limitations

- Only flate's fast encoder exists: `.@"1"` to `.@"9"` match `.fast` apart from the
  XFL byte, `.@"0"` stores, and `.ratio` returns `error.Unimplemented`.
- A `Writer` or `compress` call writes one member, with no file name, comment,
  modification time, or extra field. On input, names and comments over 512 bytes
  are rejected (`HeaderTooLong`), though RFC 1952 allows them.

## Testing and benchmarks

`just test` runs the unit tests (vectors ported from Go's gzip tests and Zig's
std, round trips, corruption and truncation cases), `just fuzz 1M` the fuzz
targets, and `just gzip-oracle` checks members in both directions against
python3's zlib, CPython's gzip module, and the gzip tools. `just bench` runs the
benchmarks; local numbers are not claims. Design notes: `AGENTS.md`.

## License

MIT, like the rest of the repository. Test vectors are ported from golang/go
(BSD-3-Clause) and Zig's std (MIT); see [`THIRD_PARTY.md`](../../THIRD_PARTY.md).

[rfc1952]: https://www.rfc-editor.org/rfc/rfc1952.txt
