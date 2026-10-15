//! gzip.Reader: a decompressing `Io.Reader` over one gzip member.
//!
//! `init` wraps the input `Io.Reader` and a caller-provided `Buffer`; read
//! through `&r.reader`. Decoded bytes are served straight from that buffer,
//! which is also flate's decode window, so there is no second copy. The CRC-32
//! and length are folded in as bytes enter the window, and the trailer is
//! checked once, at the end of the body: the reader returns `error.EndOfStream`
//! only after it matches. `input` is consumed exactly through the trailer's
//! last byte, so bytes after the member stay unread.
//!
//! `streamMember` and `streamAll` are one-call pumps for one member and for a
//! file of concatenated members. The lifecycle, error recording, and
//! `Io.Reader` entry points are the shared container driver's
//! (`src/internal/container.zig`); this file supplies gzip's framing
//! (`framing.zig`) and the member walk.
//!
//! Format: docs/research/specs/rfc1952-gzip.txt

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;
const print = std.debug.print;

const fastmem = @import("fastmem");

const flate = @import("../flate/root.zig");
/// The caller-provided decode window: flate's `Reader.Buffer`, re-exported,
/// 64 KiB (`[2 * history_len]u8`). gzip adds no buffer of its own.
pub const Buffer = flate.Reader.Buffer;
const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const State = internal.reader.State;
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const framing = @import("framing.zig");
/// The failures a reader records in `err`: flate's reader errors (a malformed
/// deflate body, `Truncated`, `StreamTooLong`) plus `BadHeader`,
/// `HeaderTooLong`, `WrongHeaderChecksum`, `WrongChecksum`, and `WrongSize`.
/// There is no `BufferTooSmall`: output goes through a fixed window, not a
/// sized target.
pub const Error = framing.Error;
const golden = @import("golden.zig");
const Writer = @import("Writer.zig");

const Reader = @This();

/// The `Io.Reader` interface: read through `&r.reader`.
reader: Io.Reader,
/// The flate reader that decodes the body.
inner: flate.Reader,
/// The member's input. The header is parsed from it before the body, and the
/// trailer is read from it right after the body's last byte.
input: *Io.Reader,
/// The header parse (`§2.3.1`), run once, before the first body byte.
header: framing.Header = .{},
/// The checksum state folded through flate's hook: CRC-32 over the decoded
/// bytes and the decoded length mod 2^32, the trailer's ISIZE (`§2.3.1`).
checksum: framing.Checksum = .{},
/// The stream lifecycle (`src/internal/reader.zig`): `streaming` until the
/// trailer is verified (`done`) or a failure sticks (`failed`, details in
/// `err`).
state: State = .streaming,
/// Detailed error once `state == .failed`; the interface reports
/// `error.ReadFailed`.
err: ?Error = null,
/// The driver's preset-dictionary seat: gzip has no dictionary concept
/// (RFC 1952 §2.3.1 has no FDICT-equivalent field), so this is always null
/// and `framing.readHeader` ignores it.
dict: ?[]const u8 = null,

/// The shared container driver over this module's framing
/// (`src/internal/container.zig`).
const Hooks = internal.container.ReaderHooks(framing, Reader);

/// Create a reader for one gzip member read from `input`, decoding through
/// `buffer`. Read through `&r.reader` (`stream`, the `read` family, the `peek`
/// family).
///
/// At the end of the member the reader verifies the trailer and then returns
/// `error.EndOfStream`. A malformed header, body, or trailer, or a failure of
/// `input`, returns `error.ReadFailed` (and keeps returning it) with the
/// specific error in `err`. `input` is consumed exactly through the trailer's
/// last byte, so bytes after the member are left unread. `input` needs a
/// buffer of at least 3 bytes. Do not move the reader once you have started
/// using it.
///
/// A `peek` or `take` of more than 32 KiB (`flate.encode.history_len`) can fail
/// with `error.ReadFailed` and `err == .StreamTooLong`, because the window
/// cannot hold that much contiguously.
pub fn init(input: *Io.Reader, buffer: *Buffer) Reader {
    return Hooks.init(input, buffer, null);
}

/// Decode one member from `in` into `out` and return the number of decoded
/// bytes. `in` is consumed exactly through the member's last trailer byte, so
/// anything after it (the next member, or garbage) stays unread.
///
/// Returns `error.ReadFailed` for a bad or truncated member or a failure of
/// `in`, and `error.WriteFailed` for a failure of `out`. The specific error is
/// not available here; drive a `Reader` to get it. Allocates nothing; the
/// 64 KiB window and the reader's state are on the stack.
pub fn streamMember(in: *Io.Reader, out: *Io.Writer) Io.Reader.StreamRemainingError!usize {
    return Hooks.streamOne(in, out, null);
}

/// Decode every member in `in` into `out` and return the total number of
/// decoded bytes (RFC 1952 §2.2: a gzip file is a series of members). After
/// each member it looks at the next byte of `in`: end of input finishes the
/// walk, so an empty `in` yields zero bytes and no error; any other byte
/// starts another member, so trailing garbage returns `error.ReadFailed`
/// (`BadHeader`) instead of being skipped. A member cut short fails as it
/// does in `streamMember`.
///
/// Like `streamMember` it reports only the coarse `error.ReadFailed` or
/// `error.WriteFailed`; drive a `Reader` to get the specific error. Allocates
/// nothing; one member's window at a time is on the stack.
pub fn streamAll(in: *Io.Reader, out: *Io.Writer) Io.Reader.StreamRemainingError!usize {
    var served: usize = 0;
    while (true) {
        // A clean end between members is the file's end; any byte where a
        // member should start is parsed as one, so garbage is an error and is
        // never skipped.
        _ = in.peekByte() catch |err| switch (err) {
            error.EndOfStream => return served,
            else => |e| return e,
        };
        served += try Hooks.streamOne(in, out, null);
    }
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc1952-gzip.txt §2.1 (byte order), §2.2
// (members), §2.3 (the member), §2.3.1 (the fixed header and trailer),
// §2.3.1.2 (decoder obligations). Every decode is sentinel-checked.
// ---------------------------------------------------------------------------

/// Decode `r` into `target` through a fixed writer, returning the length.
fn decodeInto(r: *Io.Reader, target: []u8) !usize {
    var w: Io.Writer = .fixed(target);
    _ = try r.streamRemaining(&w);
    return w.end;
}

/// Encode `source` with `Writer`, decode it through a `Reader` over the
/// member followed by marker bytes, and expect identity with the member
/// boundary intact.
fn roundTrip(source: []const u8) !void {
    const gpa = testing.allocator;
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf, .{});
    try w.writer.writeAll(source);
    try w.finish();
    const member = compressed.written();
    try golden.expectHeader(member, encode.xflFor(.fast));
    try golden.expectTrailer(member, source);

    const markers = 8;
    const framed = try gpa.alloc(u8, member.len + markers);
    defer gpa.free(framed);
    fastmem.copy(u8, framed[0..member.len], member);
    fastmem.set(u8, framed[member.len..], 0xaa);

    const target = try gpa.alloc(u8, source.len + sentinel.len);
    defer gpa.free(target);
    sentinel.fill(target);
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(framed);
    var r: Reader = .init(&fixed_in, &rbuf);
    const n = try decodeInto(&r.reader, target);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, target[0..n]);
    try sentinel.expect(target, n);
    // The member boundary: the markers are not the reader's to consume.
    try testing.expectEqual(member.len, fixed_in.seek);
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
    // `Reader.err`'s type is the `DecompressError` set minus `BufferTooSmall`
    // (output goes through a fixed window), plus the interface's
    // `ReadFailed`/`EndOfStream` and the contiguity cap's `StreamTooLong`.
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
    try roundTrip("hello, gzip");
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
    // streaming interface: valid members decode to the golden output and
    // consume exactly their own bytes; the trailing bytes of a case are left
    // unconsumed and the next parse is the pinned outcome.
    const gpa = testing.allocator;
    const target = try gpa.alloc(u8, 2048 + @as(usize, sentinel.len));
    defer gpa.free(target);
    for (golden.gunzip_cases) |tc| {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(tc.source);
        var r: Reader = .init(&fixed_in, &rbuf);
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
                    // The member is the whole input: the boundary is its end.
                    try testing.expectEqual(tc.source.len, fixed_in.seek);
                } else {
                    // The boundary is inside the input; a fresh reader there
                    // sees the pinned trailing outcome.
                    const member_len = fixed_in.seek;
                    try testing.expect(member_len < tc.source.len);
                    try checkAtBoundary(gpa, tc.source[member_len..], tc.trailing.?);
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
/// caller-loop shape (a fresh `Reader` per member).
fn checkAtBoundary(gpa: mem.Allocator, source: []const u8, expect: golden.Expect) !void {
    const target = try gpa.alloc(u8, 256 + @as(usize, sentinel.len));
    defer gpa.free(target);
    sentinel.fill(target);
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(source);
    var r: Reader = .init(&fixed_in, &rbuf);
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

test "Reader: a multi-member file is a caller loop at the boundary" {
    // A reader handles one member and stops exactly at its boundary, so
    // concatenated members are walked one reader (or `streamMember`) at a
    // time. The x2 vector decodes member by member, and the CVE-2022-30631
    // input (`TestCVE202230631`: an empty member repeated) walks without
    // accumulating or hanging.
    const gpa = testing.allocator;
    const x2 = golden.gunzip_cases[3].source;
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(x2);
    var first: Io.Writer.Allocating = .init(gpa);
    defer first.deinit();
    var second: Io.Writer.Allocating = .init(gpa);
    defer second.deinit();
    try testing.expectEqual(@as(usize, 12), try Reader.streamMember(&fixed_in, &first.writer));
    try testing.expectEqualStrings("hello world\n", first.written());
    try testing.expectEqual(@as(usize, 42), fixed_in.seek);
    try testing.expectEqual(@as(usize, 12), try Reader.streamMember(&fixed_in, &second.writer));
    try testing.expectEqualStrings("hello world\n", second.written());
    try testing.expectEqual(@as(usize, 84), fixed_in.seek);

    // The repeated empty member: 64 members, each boundary exact.
    var repeated: [64 * 20]u8 = undefined;
    for (0..64) |i| {
        fastmem.copy(u8, repeated[i * 20 ..][0..20], &golden.cve_2022_30631_member);
    }
    var walk_in: Io.Reader = .fixed(&repeated);
    var sink: Io.Writer.Discarding = .init(&.{});
    var members: usize = 0;
    while (members < 64) : (members += 1) {
        var member_reader: Reader = .init(&walk_in, &rbuf);
        _ = try member_reader.reader.streamRemaining(&sink.writer);
        try testing.expectEqual((members + 1) * 20, walk_in.seek);
        try testing.expectEqual(@as(?Error, null), member_reader.err);
    }
}

test "Reader: garbage in a member's place fails" {
    // Garbage where a member should start is parsed as a header and fails
    // with `BadHeader`; it is never skipped.
    const garbage = "not a gzip member at all!";
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(garbage);
    var r: Reader = .init(&fixed_in, &rbuf);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&sink.writer));
    try testing.expectEqual(Error.BadHeader, r.err.?);
    // The failure is sticky.
    try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectError(error.ReadFailed, r.reader.peek(1));
}

test "Reader: a corrupt trailer fails at the clean end, stickily" {
    // At the body's end the reader reads and verifies the trailer once, and
    // only then reports `error.EndOfStream`. A mismatch is `error.ReadFailed`
    // with the detail in `err` (`§2.3.1`).
    const gpa = testing.allocator;
    var member: [128]u8 = undefined;
    const source = "the quick brown fox jumps over the lazy dog. " ** 4;
    const len = try encode.compress(source, &member, .{});

    for (0..decode.trailer_len) |at| {
        var bad = member;
        bad[len - decode.trailer_len + at] ^= 0x01;
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(bad[0..len]);
        var r: Reader = .init(&fixed_in, &rbuf);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
        const want: Error = if (at < 4) error.WrongChecksum else error.WrongSize;
        try testing.expectEqual(want, r.err.?);
        // The decoded bytes are still served (the check is at the end), but
        // no clean end is reported.
        try testing.expectEqualStrings(source, out.written());
    }
}

test "Reader: an over-the-end request still checks the trailer" {
    // The rebase path: a request the window cannot hold at the consumer's
    // position goes through `rebase`, where flate's sticky end fires before
    // the trailer is read. The trailer check must run there too: a clean
    // `EndOfStream` always means the trailer was verified (RFC 1952 §2.3.1).
    // Without the check the input stops 8 bytes short and a corrupted member
    // ends with a clean `EndOfStream`.

    // A member whose decoded size lands the window deep enough that a
    // 30-KiB request overflows the room at the consumer's position.
    const source = "the quick brown fox jumps over the lazy dog. " ** 950;
    var member: [encode.maxCompressedLength(source.len)]u8 = undefined;
    const len = try encode.compress(source, &member, .{});

    // The good trailer: the over-the-end request reports the clean end
    // with the input exactly at the member's last byte (the boundary
    // contract) and the state done.
    {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(member[0..len]);
        var r: Reader = .init(&fixed_in, &rbuf);
        _ = try r.reader.take(39 * 1024);
        try testing.expectError(error.EndOfStream, r.reader.peek(30 * 1024));
        try testing.expectEqual(@as(usize, len), fixed_in.seek);
        try testing.expectEqual(State.done, r.state);
        try testing.expectEqual(@as(?Error, null), r.err);
    }

    // The corrupted trailer: the same request fails `ReadFailed` with the
    // specific error, on every trailer byte.
    for (0..decode.trailer_len) |at| {
        var bad = member;
        bad[len - decode.trailer_len + at] ^= 0x01;
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(bad[0..len]);
        var r: Reader = .init(&fixed_in, &rbuf);
        _ = try r.reader.take(39 * 1024);
        try testing.expectError(error.ReadFailed, r.reader.peek(30 * 1024));
        const want: Error = if (at < 4) error.WrongChecksum else error.WrongSize;
        try testing.expectEqual(want, r.err.?);
        try testing.expectEqual(State.failed, r.state);
    }
}

test "Reader: a truncated member is Truncated at every prefix" {
    // A truncated member (header, body, or trailer) is `error.Truncated`:
    // every prefix of a real member returns an error, never a clean end.
    const gpa = testing.allocator;
    var member: [128]u8 = undefined;
    const len = try encode.compress("hello world\n", &member, .{});
    for (1..len) |prefix| {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(member[0..prefix]);
        var r: Reader = .init(&fixed_in, &rbuf);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
        try testing.expectEqual(Error.Truncated, r.err.?);
    }
}

test "Reader: a contiguous request past the window fails" {
    // A request beyond what the window can hold at the consumer's position
    // returns `error.ReadFailed` with `err == .StreamTooLong`, never an
    // assert.
    const gpa = testing.allocator;
    const source = try gpa.alloc(u8, 200_000);
    defer gpa.free(source);
    var rng: DefaultPrng = .init(0xBEEF);
    for (source, 0..) |*byte, i| byte.* = @truncate(i / 7 +% rng.random().int(u8));
    var member: Io.Writer.Allocating = .init(gpa);
    defer member.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&member.writer, &wbuf, .{});
    try w.writer.writeAll(source);
    try w.finish();

    const history_len = flate.encode.history_len;
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(member.written());
    var r: Reader = .init(&fixed_in, &rbuf);
    // A full history is always servable: any contiguous request of at most
    // 32 KiB is served.
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
    // (a slide retains exactly `history_len` bytes). Fail closed with the
    // contiguity detail, stickily.
    try r.reader.discardAll(r.reader.end - r.reader.seek);
    try testing.expect(r.reader.end > history_len);
    try testing.expectError(error.ReadFailed, r.reader.peek(@sizeOf(Buffer)));
    try testing.expectEqual(Error.StreamTooLong, r.err.?);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectError(error.ReadFailed, r.reader.peek(1));
}

test "Reader: a zero-length poll does not fail the stream" {
    // std calls `vtable.stream` at limit 0 when the buffer is nonempty, and
    // the poll must answer 0 without filling (a fill could fail with
    // `StreamTooLong` on a valid stream).
    const gpa = testing.allocator;
    var member: [64]u8 = undefined;
    const source = "poll";
    const len = try encode.compress(source, &member, .{});
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(member[0..len]);
    var r: Reader = .init(&fixed_in, &rbuf);
    _ = try r.reader.peek(1);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectEqual(@as(usize, 0), try r.reader.stream(&sink.writer, .limited(0)));
    try testing.expectEqual(@as(?Error, null), r.err);
    const got = try r.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(got);
    try testing.expectEqualStrings(source, got);
}

test "Reader: a chunked input refills across the header and the body" {
    // The input's buffer is small (16 bytes: enough for the fixed header and
    // a refill), so the header parse, the bit reader, and the trailer read
    // all run on refills — and the marker bytes behind the member must never
    // reach the decoder.
    const gpa = testing.allocator;
    var member: [128]u8 = undefined;
    const source = "the quick brown fox jumps over the lazy dog. " ** 4;
    const len = try encode.compress(source, &member, .{});

    var framed: [144]u8 = undefined;
    fastmem.copy(u8, framed[0..len], member[0..len]);
    fastmem.set(u8, framed[len..], 0xaa);
    var small: [16]u8 = undefined;
    var inner: Io.Reader = .fixed(framed[0..len]);
    var chunked: Io.Reader.Limited = .init(&inner, .unlimited, &small);
    var rbuf: Buffer = undefined;
    var r: Reader = .init(&chunked.interface, &rbuf);
    const got = try r.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(got);
    try testing.expectEqualStrings(source, got);
    try testing.expectEqual(@as(?Error, null), r.err);
}

test "Reader: streamMember consumes one member and leaves the rest" {
    // `Reader.streamMember` consumes one member and leaves the rest of `in`
    // unconsumed, the same boundary the manual path keeps.
    const gpa = testing.allocator;
    const x2 = golden.gunzip_cases[3].source;
    var fixed_in: Io.Reader = .fixed(x2);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 12), try Reader.streamMember(&fixed_in, &out.writer));
    try testing.expectEqualStrings("hello world\n", out.written());
    try testing.expectEqual(@as(usize, 42), fixed_in.seek);
}

test "Reader: streamAll walks every member to the input's end" {
    // RFC 1952 §2.2 — "a gzip file is a sequence of members": `streamAll`
    // decodes the whole sequence and stops at the last member's last trailer
    // byte.
    const gpa = testing.allocator;
    // `gunzip_cases[3]` is itself a two-member file (the fixture above's
    // `streamMember` pair): the walk serves both members and stops at the
    // second member's last trailer byte.
    const x2 = golden.gunzip_cases[3].source;
    var fixed_in: Io.Reader = .fixed(x2);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 24), try Reader.streamAll(&fixed_in, &out.writer));
    try testing.expectEqualStrings("hello world\nhello world\n", out.written());
    try testing.expectEqual(@as(usize, x2.len), fixed_in.seek);
}

test "Reader: streamAll serves zero members from empty input" {
    // A member that is not present at all is the file's clean end, so an
    // empty input serves zero bytes and returns no error.
    var fixed_in: Io.Reader = .fixed("");
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 0), try Reader.streamAll(&fixed_in, &out.writer));
    try testing.expectEqual(@as(usize, 0), out.written().len);
}

test "Reader: streamAll fails where a member should start" {
    // Any byte where a member should start is parsed as one, so trailing
    // garbage fails its header parse instead of being skipped.
    const gpa = testing.allocator;
    const x2 = golden.gunzip_cases[3].source;
    var framed: [x2.len + 1]u8 = undefined;
    fastmem.copy(u8, framed[0..x2.len], x2);
    framed[x2.len] = 0x00; // garbage: not ID1, so the header parse rejects.
    var fixed_in: Io.Reader = .fixed(&framed);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try testing.expectError(
        error.ReadFailed,
        Reader.streamAll(&fixed_in, &out.writer),
    );
}
