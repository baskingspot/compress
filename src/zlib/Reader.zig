//! zlib.Reader: a decompressing `Io.Reader` over one zlib stream.
//!
//! `init` takes the input reader and a caller-provided `Reader.Buffer`.
//! Decoded bytes are served straight from that buffer, which is flate's
//! decode window: one region and one position, with no staging copy. The
//! reader checks the 2-byte header before the first body byte, decodes the
//! deflate body through `flate.Reader`, and at the end of the body reads and
//! verifies the ADLER32 trailer before it reports `error.EndOfStream`. It
//! consumes `input` exactly through the trailer's last byte and leaves
//! whatever follows unread (RFC 1950 §2.2). `streamAll` is the one-call form.
//!
//! The lifecycle (`state`, with the detail in `err`), the window hand-off, and
//! the `Io.Reader` entries come from the shared container driver
//! (`src/internal/container.zig`, `ReaderHooks`), instantiated over
//! `framing.zig`. Flate's checksum hook folds the Adler-32 as decoded bytes
//! enter the window, so the trailer check at the end hashes nothing again.
//!
//! Format: docs/research/specs/rfc1950-zlib.txt

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;
const print = std.debug.print;

const fastmem = @import("fastmem");

const flate = @import("../flate/root.zig");
/// The caller-provided decode window: flate's `Reader.Buffer`, re-exported.
/// 64 KiB (`[2 * history_len]u8`); the last 32 KiB of it is match history.
pub const Buffer = flate.Reader.Buffer;
const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const State = internal.reader.State;
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const framing = @import("framing.zig");
/// The failure detail recorded in `err` when the interface returns
/// `error.ReadFailed`: `BadHeader`, `DictionaryRequired`, `DictionaryMismatch`,
/// and `WrongChecksum` from this module; `Truncated` and flate's other decode
/// errors; `StreamTooLong` for a contiguous request the window cannot hold;
/// and `ReadFailed` when the input reader itself failed.
pub const Error = framing.Error;
const golden = @import("golden.zig");
const Writer = @import("Writer.zig");

const Reader = @This();

reader: Io.Reader,
inner: flate.Reader,
/// The stream's input. The header and trailer are read from it directly, at
/// the exact byte positions flate's reader leaves it at; the body is read
/// through `inner`.
input: *Io.Reader,
/// The header check (`§2.2`), run once, before the first body byte.
header: framing.Header = .pending,
/// The checksum state folded through flate's hook: the Adler-32 over the
/// decoded bytes (`§2.2`).
checksum: framing.Checksum = .{},
/// The stream lifecycle (`src/internal/reader.zig`): `streaming` until the
/// trailer is verified (`done`) or a failure sticks (`failed`, details in
/// `err`).
state: State = .streaming,
/// Detailed error once `state == .failed`; the interface reports
/// `error.ReadFailed`.
err: ?Error = null,
/// The stream's preset dictionary or null (`§2.2`), checked against the
/// header's DICTID when FDICT is set. The driver hands it to the header check;
/// the inner flate reader gets it too, as its window's preset history.
dict: ?[]const u8 = null,

/// The shared container driver over this module's framing
/// (`src/internal/container.zig`): the lifecycle, the window hand-off, the
/// trailer check at the end of the body (on both the fill and the rebase
/// path), and the generated `Io.Reader` entries.
const Hooks = internal.container.ReaderHooks(framing, Reader);

/// Start decoding the zlib stream in `input`, with `buffer` as the decode
/// window. Read decoded bytes through `&r.reader` (`stream`, `take`, `peek`,
/// and the rest of the `Io.Reader` interface). After the last body byte the
/// reader verifies the trailer and then reports `error.EndOfStream`. A
/// malformed header, body, or trailer, or a failing `input`, makes the
/// interface return `error.ReadFailed` from then on; the cause is in `r.err`.
///
/// `dict` is the stream's preset dictionary or `null` (`§2.2`). With FDICT
/// set the dictionary must be supplied: its Adler-32 is checked against the
/// header's DICTID before any body byte (`error.DictionaryRequired` when it
/// is null, `error.DictionaryMismatch` when it is wrong), and it pre-seeds the
/// decode window as history. With FDICT clear the stream names no dictionary
/// and `dict` is unused, so one reader can walk a mixed sequence of streams.
/// A dictionary longer than 32 KiB contributes only its last 32 KiB to the
/// window, while DICTID names the whole — supply the full slice.
///
/// The reader consumes `input` exactly through ADLER32's last byte and leaves
/// the bytes after it unread (`§2.2`: they "are not part of the zlib
/// stream"). The trailer is checked only when the reader is asked for bytes
/// past the last decoded one, so read to `error.EndOfStream`; output served
/// before then is unverified.
///
/// `input`'s buffer must hold at least 3 bytes, or the input must end sooner.
/// A contiguous read (`peek`, `take`) of up to 32 KiB is always served; a
/// larger one can fail with `error.ReadFailed` and
/// `err == error.StreamTooLong`. Do not move the `Reader` after its first
/// read.
pub fn init(input: *Io.Reader, buffer: *Buffer, dict: ?[]const u8) Reader {
    return Hooks.init(input, buffer, dict);
}

/// Decode one zlib stream from `in` into `out` and return the number of
/// decoded bytes written. `in` is consumed exactly through the stream's last
/// trailer byte; anything after it is left unread. `dict` is the stream's
/// preset dictionary or `null` (`§2.2`); see `init`. Returns
/// `error.ReadFailed` for a malformed stream or a failing `in` (the cause is
/// not reported; use a `Reader` to see `err`) and `error.WriteFailed` if `out`
/// fails. Uses about 68 KiB of stack (the 64 KiB window plus 4 KiB of reader
/// state). Allocates nothing.
pub fn streamAll(
    in: *Io.Reader,
    out: *Io.Writer,
    dict: ?[]const u8,
) Io.Reader.StreamRemainingError!usize {
    return Hooks.streamOne(in, out, dict);
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc1950-zlib.txt §2.1 (byte order), §2.2
// (the header, the trailer, the stream's end), §2.3 (decoder obligations).
// Every decode is sentinel-checked.
// ---------------------------------------------------------------------------

/// Decode `r` into `target` through a fixed writer, returning the length.
fn decodeInto(r: *Io.Reader, target: []u8) !usize {
    var w: Io.Writer = .fixed(target);
    _ = try r.streamRemaining(&w);
    return w.end;
}

/// Encode `source` with `Writer`, decode it through a `Reader` over the stream
/// followed by marker bytes, and expect identity with the stream boundary
/// intact.
fn roundTrip(source: []const u8) !void {
    const gpa = testing.allocator;
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf, .{});
    try w.writer.writeAll(source);
    try w.finish();
    const stream = compressed.written();
    try golden.expectHeader(stream, .fast);
    try golden.expectTrailer(stream, source);

    const markers = 8;
    const framed = try gpa.alloc(u8, stream.len + markers);
    defer gpa.free(framed);
    fastmem.copy(u8, framed[0..stream.len], stream);
    fastmem.set(u8, framed[stream.len..], 0xaa);

    const target = try gpa.alloc(u8, source.len + sentinel.len);
    defer gpa.free(target);
    sentinel.fill(target);
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(framed);
    var r: Reader = .init(&fixed_in, &rbuf, null);
    const n = try decodeInto(&r.reader, target);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, target[0..n]);
    try sentinel.expect(target, n);
    // The stream boundary: the markers are not the reader's to consume
    // (`§2.2`: "Any data which may appear after ADLER32 are not part of the
    // zlib stream").
    try testing.expectEqual(stream.len, fixed_in.seek);
    try testing.expectEqual(@as(?Error, null), r.err);
    // The clean end is sticky.
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
}

test "Reader: the buffer type is flate's, re-exported" {
    // `Reader.Buffer` is `flate.Reader.Buffer`: 2 * history_len, 64 KiB.
    try testing.expectEqual(@as(usize, 65536), @sizeOf(Buffer));
    try testing.expect(Buffer == flate.Reader.Buffer);
    try testing.expectEqual(@as(usize, 98303), @sizeOf(Writer.Buffer));
}

test "Reader: the error set mirrors DecompressError minus BufferTooSmall" {
    // `Reader.Error` is the `DecompressError` set minus `BufferTooSmall` (the
    // decode window is fixed), plus the interface's `ReadFailed` and
    // `EndOfStream` and the contiguity cap's `StreamTooLong`.
    const mine = @typeInfo(Error).error_set.?;
    for (@typeInfo(decode.DecompressError).error_set.?) |want| {
        if (mem.eql(u8, want.name, "BufferTooSmall")) continue;
        var found = false;
        for (mine) |entry| {
            if (mem.eql(u8, entry.name, want.name)) found = true;
        }
        try testing.expect(found);
    }
}

test "Reader: round-trips through Writer" {
    try roundTrip("");
    try roundTrip("a");
    try roundTrip("hello, zlib");
    try roundTrip("the quick brown fox jumps over the lazy dog. " ** 1000);
    try roundTrip("a" ** (flate.encode.max_block_size - 1));
    try roundTrip("b" ** flate.encode.max_block_size);
    try roundTrip("c" ** (flate.encode.max_block_size + 1));
    try roundTrip("d" ** (3 * flate.encode.max_block_size + 17));
}

test "Reader: multi-block inputs round-trip" {
    // Sizes around the 65535-byte block split, where the second block's
    // matches reach back into the first (`rfc1951-deflate.txt §3.2.3`).
    const gpa = testing.allocator;
    const sizes = [_]usize{ 65534, 65535, 65536, 131070, 200_000 };
    for (sizes) |len| {
        const source = try gpa.alloc(u8, len);
        defer gpa.free(source);
        var rng: DefaultPrng = .init(0xC0FFEE);
        for (source, 0..) |*byte, i| {
            byte.* = if (i % 3 == 0) @truncate(i / 7) else rng.random().int(u8);
        }
        roundTrip(source) catch |err| {
            print("\nFAIL: len {d}: {s}\n", .{ len, @errorName(err) });
            return err;
        };
    }
    // Incompressible input: every block is stored (`§3.2.4`), so the
    // stored-block resume across window slides runs.
    var rng: DefaultPrng = .init(0x5EED);
    const random_bytes = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(random_bytes);
    for (random_bytes) |*byte| byte.* = rng.random().int(u8);
    try roundTrip(random_bytes);
}

test "Reader: the golden table decodes through the streaming layer" {
    // The same vectors the one-shot decoder is judged against, through the
    // streaming interface: valid streams decode to the golden output and
    // consume exactly their own bytes; the trailing bytes of a case are left
    // unconsumed and the next parse is the pinned outcome.
    const gpa = testing.allocator;
    const target = try gpa.alloc(u8, 2048 + @as(usize, sentinel.len));
    defer gpa.free(target);
    for (golden.zlib_cases) |tc| {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(tc.source);
        var r: Reader = .init(&fixed_in, &rbuf, tc.dict);
        switch (tc.expect) {
            .ok => |want| {
                sentinel.fill(target);
                const n = decodeInto(&r.reader, target) catch |err| {
                    print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
                    return err;
                };
                try testing.expectEqual(want.len, n);
                try testing.expectEqualSlices(u8, want, target[0..n]);
                try sentinel.expect(target, n);
                try testing.expectEqual(@as(?Error, null), r.err);
                if (tc.trailing == null) {
                    // The stream is the whole input: the boundary is its end.
                    try testing.expectEqual(tc.source.len, fixed_in.seek);
                } else {
                    // The boundary is inside the input; a fresh reader there
                    // sees the pinned trailing outcome.
                    const stream_len = fixed_in.seek;
                    try testing.expect(stream_len < tc.source.len);
                    try checkAtBoundary(gpa, tc.source[stream_len..], tc.trailing.?);
                }
            },
            .fail => try expectStreamFailure(&r, null),
            .fail_with => |want| try expectStreamFailure(&r, want),
        }
    }
}

/// A golden failure through the streaming layer: `error.ReadFailed` with the
/// detail (when the case pins one) sticky in `err`.
fn expectStreamFailure(r: *Reader, want: ?decode.DecompressError) !void {
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&sink.writer));
    if (want) |detail| try testing.expectEqual(detail, r.err.?);
}

/// Decode `source` with a fresh reader and check the boundary outcome: the
/// caller-loop shape (a fresh `Reader` per stream).
fn checkAtBoundary(gpa: mem.Allocator, source: []const u8, expect: golden.Expect) !void {
    const target = try gpa.alloc(u8, 256 + @as(usize, sentinel.len));
    defer gpa.free(target);
    sentinel.fill(target);
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(source);
    var r: Reader = .init(&fixed_in, &rbuf, null);
    switch (expect) {
        .ok => |want| {
            const n = try decodeInto(&r.reader, target);
            try testing.expectEqual(want.len, n);
            try testing.expectEqualSlices(u8, want, target[0..n]);
            try sentinel.expect(target, n);
        },
        .fail => try expectStreamFailure(&r, null),
        .fail_with => |want| try expectStreamFailure(&r, want),
    }
}

test "Reader: a doubled stream is a caller loop at the boundary" {
    // The reader consumes `input` exactly through ADLER32's last byte and
    // stops. Nothing in the format promises a second stream follows, but the
    // exact consumption exposes the boundary: a caller loop decodes what the
    // first reader left. The golden table's "stream x2" case pins the same
    // shape (a fresh reader at the boundary decodes the second stream).
    const gpa = testing.allocator;
    var stream: [64]u8 = undefined;
    const source = "hello, zlib";
    const len = try encode.compress(source, &stream, .{});

    var framed: [128 + 8]u8 = undefined;
    fastmem.copy(u8, framed[0..len], stream[0..len]);
    fastmem.copy(u8, framed[len..][0..len], stream[0..len]);
    fastmem.set(u8, framed[2 * len ..], 0xaa);
    const two = framed[0 .. 2 * len + 8];

    var fixed_in: Io.Reader = .fixed(two);
    var first: Io.Writer.Allocating = .init(gpa);
    defer first.deinit();
    var second: Io.Writer.Allocating = .init(gpa);
    defer second.deinit();
    try testing.expectEqual(source.len, try Reader.streamAll(&fixed_in, &first.writer, null));
    try testing.expectEqualStrings(source, first.written());
    try testing.expectEqual(len, fixed_in.seek);
    try testing.expectEqual(source.len, try Reader.streamAll(&fixed_in, &second.writer, null));
    try testing.expectEqualStrings(source, second.written());
    try testing.expectEqual(2 * len, fixed_in.seek);
}

test "Reader: garbage in a stream's place fails" {
    // Decoding returns an error at the first invalid byte. The garbage is at
    // least a full header, so the header check is what rejects it (a shorter
    // prefix is a truncated header instead).
    const garbage = "not a zlib stream at all!";
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(garbage);
    var r: Reader = .init(&fixed_in, &rbuf, null);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&sink.writer));
    try testing.expectEqual(Error.BadHeader, r.err.?);
    // The failure is sticky.
    try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectError(error.ReadFailed, r.reader.peek(1));
}

test "Reader: the dictionary refusal is sticky and before any body byte" {
    // RFC 1950 §2.3 — an FDICT stream with no dictionary supplied is
    // `DictionaryRequired` at the header: the four DICTID bytes are never
    // read, never decoded as deflate data. The refusal arrives at the header,
    // so a valid-looking body behind it is never touched.
    const source: []const u8 = &golden.dictionary_stream;
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(source);
    var r: Reader = .init(&fixed_in, &rbuf, null);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&sink.writer));
    try testing.expectEqual(Error.DictionaryRequired, r.err.?);
    // Exactly the two header bytes were consumed; the DICTID and body stay.
    try testing.expectEqual(@as(usize, decode.header_len), fixed_in.seek);
    // The failure is sticky: the detail stays recorded and every later read
    // reports it again.
    try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&sink.writer));
    try testing.expectEqual(Error.DictionaryRequired, r.err.?);
}

test "Reader: the dictionary mismatch matrix, stickily" {
    // The four cases through the streaming layer, with the exact input
    // positions: `DictionaryRequired` costs the two header bytes (the DICTID
    // is never read), `DictionaryMismatch` the header and the four DICTID
    // bytes, and the right dictionary decodes. `§2.2` — DICTID is the whole
    // dictionary's Adler-32, so a truncation of it is a mismatch too.
    const gpa = testing.allocator;
    const source: []const u8 = &golden.dictionary_stream;
    const want_plain = "Hello, World!\n";

    const cases = [_]struct {
        dict: ?[]const u8,
        want: ?Error,
        consumed: usize,
    }{
        .{ .dict = null, .want = Error.DictionaryRequired, .consumed = decode.header_len },
        .{
            .dict = "not the dictionary",
            .want = Error.DictionaryMismatch,
            .consumed = decode.header_len + decode.dict_id_len,
        },
        .{
            .dict = &golden.wrong_dictionary,
            .want = Error.DictionaryMismatch,
            .consumed = decode.header_len + decode.dict_id_len,
        },
        .{
            .dict = &golden.dictionary,
            .want = null,
            .consumed = source.len,
        },
    };
    for (cases) |tc| {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(source);
        var r: Reader = .init(&fixed_in, &rbuf, tc.dict);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        if (tc.want) |want| {
            try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
            try testing.expectEqual(want, r.err.?);
            // Nothing decoded: the check is before any body byte.
            try testing.expectEqual(@as(usize, 0), out.written().len);
            // The failure is sticky.
            var sink: Io.Writer.Discarding = .init(&.{});
            try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
            try testing.expectEqual(want, r.err.?);
        } else {
            try testing.expectEqual(
                @as(usize, want_plain.len),
                try r.reader.streamRemaining(&out.writer),
            );
            try testing.expectEqualStrings(want_plain, out.written());
            try testing.expectEqual(@as(?Error, null), r.err);
        }
        try testing.expectEqual(tc.consumed, fixed_in.seek);
    }
}

test "Reader: a corrupt trailer fails at the clean end, stickily" {
    // At the body's clean end the reader reads and verifies ADLER32 exactly
    // once, and only then reports `error.EndOfStream`. A mismatch is
    // `error.ReadFailed` with the detail in `err` (`§2.3`).
    const gpa = testing.allocator;
    var stream: [128]u8 = undefined;
    const source = "the quick brown fox jumps over the lazy dog. " ** 4;
    const len = try encode.compress(source, &stream, .{});

    for (0..decode.trailer_len) |at| {
        var bad = stream;
        bad[len - decode.trailer_len + at] ^= 0x01;
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(bad[0..len]);
        var r: Reader = .init(&fixed_in, &rbuf, null);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
        try testing.expectEqual(Error.WrongChecksum, r.err.?);
        // The decoded bytes are still served (the check is at the end), but
        // no clean end is reported.
        try testing.expectEqualStrings(source, out.written());
    }
}

test "Reader: an over-the-end request still checks the trailer" {
    // The rebase path: a request the window cannot hold at the consumer's
    // position routes through `rebase`, where flate's sticky end fires
    // before the trailer is read. The trailer check must run there too: the
    // reader verifies the trailer exactly once, and only then reports
    // `error.EndOfStream`, on every path, and RFC 1950 §2.3 requires the
    // ADLER32 check unconditionally. Without it the input stops 4 bytes short
    // and a corrupted stream ends with a clean `EndOfStream`.

    // A stream whose decoded size lands the window deep enough that a
    // 30-KiB request overflows the room at the consumer's position.
    const source = "the quick brown fox jumps over the lazy dog. " ** 950;
    var stream: [encode.maxCompressedLength(source.len)]u8 = undefined;
    const len = try encode.compress(source, &stream, .{});

    // The good trailer: the over-the-end request reports the clean end
    // with the input exactly at the stream's last byte (the boundary
    // contract) and the state done.
    {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(stream[0..len]);
        var r: Reader = .init(&fixed_in, &rbuf, null);
        _ = try r.reader.take(39 * 1024);
        try testing.expectError(error.EndOfStream, r.reader.peek(30 * 1024));
        try testing.expectEqual(@as(usize, len), fixed_in.seek);
        try testing.expectEqual(State.done, r.state);
        try testing.expectEqual(@as(?Error, null), r.err);
    }

    // The corrupted trailer: the same request fails `ReadFailed` with the
    // specific error, on every trailer byte.
    for (0..decode.trailer_len) |at| {
        var bad = stream;
        bad[len - decode.trailer_len + at] ^= 0x01;
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(bad[0..len]);
        var r: Reader = .init(&fixed_in, &rbuf, null);
        _ = try r.reader.take(39 * 1024);
        try testing.expectError(error.ReadFailed, r.reader.peek(30 * 1024));
        try testing.expectEqual(Error.WrongChecksum, r.err.?);
        try testing.expectEqual(State.failed, r.state);
    }
}

test "Reader: a truncated stream is Truncated at every prefix" {
    // A truncated stream (header, body, or trailer) is `error.Truncated`.
    // Every prefix of a real stream returns an error, and none decodes
    // cleanly.
    const gpa = testing.allocator;
    var stream: [128]u8 = undefined;
    const len = try encode.compress("hello world\n", &stream, .{});
    for (1..len) |prefix| {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(stream[0..prefix]);
        var r: Reader = .init(&fixed_in, &rbuf, null);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
        try testing.expectEqual(Error.Truncated, r.err.?);
    }
}

test "Reader: a contiguous request past the window fails" {
    // A request beyond what the window can hold at the consumer's position
    // returns `error.ReadFailed` (`err == .StreamTooLong`), never an assert.
    const gpa = testing.allocator;
    const source = try gpa.alloc(u8, 200_000);
    defer gpa.free(source);
    var rng: DefaultPrng = .init(0xBEEF);
    for (source, 0..) |*byte, i| byte.* = @truncate(i / 7 +% rng.random().int(u8));
    var stream: Io.Writer.Allocating = .init(gpa);
    defer stream.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&stream.writer, &wbuf, .{});
    try w.writer.writeAll(source);
    try w.finish();

    const history_len = flate.encode.history_len;
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(stream.written());
    var r: Reader = .init(&fixed_in, &rbuf, null);
    // A full history is always servable (any contiguous request of at most
    // 32 KiB is served).
    try testing.expectEqualSlices(u8, source[0..history_len], try r.reader.peek(history_len));
    // Drain what the pump buffered: the window's guaranteed contiguous room
    // is exactly the retained history.
    const buffered = r.reader.end - r.reader.seek;
    try r.reader.discardAll(buffered);
    try testing.expectEqualSlices(
        u8,
        source[buffered..][0..history_len],
        try r.reader.peek(history_len),
    );
    // Drain everything the pump buffered, so only the retained history stands
    // behind the next request: a whole-window request cannot fit beside it
    // (a slide retains exactly `history_len` bytes). The reader fails with
    // the contiguity detail, stickily.
    try r.reader.discardAll(r.reader.end - r.reader.seek);
    try testing.expect(r.reader.end > history_len);
    try testing.expectError(error.ReadFailed, r.reader.peek(@sizeOf(Buffer)));
    try testing.expectEqual(Error.StreamTooLong, r.err.?);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectError(error.ReadFailed, r.reader.peek(1));
}

test "Reader: a zero-length poll does not fail the stream" {
    // The zero-length poll: std calls `vtable.stream` at limit 0 when the
    // buffer is nonempty, and the poll must answer 0 without filling (a fill
    // could fail `StreamTooLong` on a valid stream).
    const gpa = testing.allocator;
    var stream: [64]u8 = undefined;
    const source = "poll";
    const len = try encode.compress(source, &stream, .{});
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(stream[0..len]);
    var r: Reader = .init(&fixed_in, &rbuf, null);
    _ = try r.reader.peek(1);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectEqual(@as(usize, 0), try r.reader.stream(&sink.writer, .limited(0)));
    try testing.expectEqual(@as(?Error, null), r.err);
    const got = try r.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(got);
    try testing.expectEqualStrings(source, got);
}

test "Reader: a chunked input refills across the header and the body" {
    // The input's buffer is small (16 bytes: enough for the 2-byte header and
    // a refill), so the header check, the bit reader, and the trailer read
    // all run on refills — and the marker bytes behind the stream must never
    // reach the decoder.
    const gpa = testing.allocator;
    var stream: [128]u8 = undefined;
    const source = "the quick brown fox jumps over the lazy dog. " ** 4;
    const len = try encode.compress(source, &stream, .{});

    var framed: [144]u8 = undefined;
    fastmem.copy(u8, framed[0..len], stream[0..len]);
    fastmem.set(u8, framed[len..], 0xaa);
    var small: [16]u8 = undefined;
    var inner: Io.Reader = .fixed(framed[0..len]);
    var chunked: Io.Reader.Limited = .init(&inner, .unlimited, &small);
    var rbuf: Buffer = undefined;
    var r: Reader = .init(&chunked.interface, &rbuf, null);
    const got = try r.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(got);
    try testing.expectEqualStrings(source, got);
    try testing.expectEqual(@as(?Error, null), r.err);
}

test "Reader: streamAll consumes one stream and leaves the rest" {
    // `Reader.streamAll` consumes one stream and leaves the rest of `in`
    // unconsumed, the same boundary the manual path keeps.
    const gpa = testing.allocator;
    var stream: [64]u8 = undefined;
    const source = "hello, zlib";
    const len = try encode.compress(source, &stream, .{});
    var framed: [64 + 8]u8 = undefined;
    fastmem.copy(u8, framed[0..len], stream[0..len]);
    fastmem.set(u8, framed[len..][0..8], 0xaa);

    var fixed_in: Io.Reader = .fixed(framed[0 .. len + 8]);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try testing.expectEqual(source.len, try Reader.streamAll(&fixed_in, &out.writer, null));
    try testing.expectEqualStrings(source, out.written());
    try testing.expectEqual(len, fixed_in.seek);
}
