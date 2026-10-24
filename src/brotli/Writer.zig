//! brotli.Writer: a compressing `Io.Writer` that produces one brotli stream
//! (RFC 7932) at the encoder's `q3` class — the same algorithm as the
//! one-shot `encode.compress`, driven from a streaming input. The caller
//! provides the `Buffer`; nothing is allocated, and `finish` is required: the
//! stream is incomplete without it.
//!
//! The input accumulates in a 16-KiB staging block and is copied into the
//! history ring in the reference encoder's input-block cadence, so a `Writer`
//! fed everything at once emits the same stream as the one-shot at the same
//! window. A mid-stream `flush` forces the pending meta-block out, which is
//! the reference's `BROTLI_OPERATION_FLUSH`; the streams it produces are
//! valid streams, not byte-pinned ones (the one-shot is the byte-parity
//! artifact).
//!
//! Format: docs/specs/rfc7932-brotli.txt. API: README.md.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;

const fastmem = @import("fastmem");

const encode = @import("encode.zig");
const match = encode.match;
const decode = @import("decode.zig");

/// The input staging size: the reference's `lgblock` is 14 below the
/// block-split qualities, so the matcher sees 16-KiB input blocks.
const chunk_len = encode.input_block_size;

/// The output window the emission flushes through: compressed bytes reach
/// `output` in blocks of at most this size.
const out_len = 1 << 16;

/// The ring's proper size, the reference's `ComputeRbBits`: at least
/// `lgwin + 1` bits, so a whole input block fits and the copy tail is
/// smaller than the ring.
fn ringSize(comptime window_wbits: usize) usize {
    const lgwin: usize = @max(window_wbits, 14);
    const bits: u6 = @intCast(1 + lgwin);
    return @as(usize, 1) << bits;
}

/// The caller-provided buffer for `Buffer(window_wbits)`: the history ring
/// with its 16-KiB mirror, the q3 bucket table, the delayed commands, the
/// tree-build scratch, the input staging block, and the compressed-output
/// window.
pub fn Buffer(comptime window_wbits: usize) type {
    return struct {
        /// The ring plus a mirror of the ring's first 16 KiB: a read of up
        /// to one input block can run past the ring's end, and the
        /// reference's ring keeps those bytes copied there.
        ring: [ringSize(window_wbits) + chunk_len]u8,
        /// The q3 bucket table: the reference's `H3` is always
        /// `1 << 16` entries.
        hash: [encode.bucket_entries]u32,
        /// The delayed commands of the pending meta-block.
        commands: [encode.max_commands]match.Command,
        /// The tree-build scratch.
        scratch: encode.Scratch,
        /// The input staging block: the `Io.Writer`'s own buffer region.
        staging: [chunk_len]u8,
        /// The compressed-output window.
        out: [out_len]u8,
    };
}

/// The reference encoder library's default window: 22, 4,194,288 bytes.
pub const default_window_wbits: usize = 22;

/// `Buffer(22)`: about 9.1 MiB. Keep it in static or heap storage.
pub const DefaultBuffer = Buffer(default_window_wbits);

const Writer = @This();

/// The `Io.Writer` interface: write the uncompressed bytes through
/// `&w.writer`.
writer: Io.Writer,
/// The sink the compressed stream is written to.
output: *Io.Writer,
/// The caller's buffer regions.
ring: []u8,
mask: usize,
staging: []u8,
/// The encoder core: the matcher over `ring`, the delayed commands, the
/// distance ring, and the bit writer over the output window.
state: encode.State,
/// The stream's window bits.
lgwin: u6,
/// Whether the stream header is on the wire. It is written with the first
/// meta-block, so `init` cannot fail.
started: bool = false,

const vtable: Io.Writer.VTable = .{
    .drain = drain,
    .flush = flush,
    .rebase = rebase,
};

/// Start a brotli stream into `output`, accumulating input in `buffer` and
/// searching a `window_wbits` window. Write through `&w.writer`, then call
/// `finish`.
///
/// `options.quality` must be 3 (the implemented class); any other value
/// poisons the returned writer, so every write and `finish` returns
/// `error.WriteFailed`, never a silent alias.
///
/// Stack: `Buffer(window_wbits)` is MiB-scale and lives in the caller's
/// storage; the writer itself is KiB-scale.
pub fn init(
    comptime window_wbits: usize,
    output: *Io.Writer,
    buffer: *Buffer(window_wbits),
    options: encode.Options,
) Writer {
    assert(window_wbits >= 10);
    assert(window_wbits <= 24);
    if (options.quality != 3) {
        return .{
            .writer = .failing,
            .output = output,
            .ring = &.{},
            .mask = 0,
            .staging = &.{},
            .state = undefined,
            .lgwin = @intCast(window_wbits),
        };
    }
    const ring_size = ringSize(window_wbits);
    var state: encode.State = .{
        .matcher = .{
            .hasher = .{ .buckets = &buffer.hash },
            .window = .{ .bytes = &buffer.ring, .mask = ring_size - 1 },
            .lgwin = @intCast(window_wbits),
        },
        .commands = .{ .buffer = &buffer.commands },
        .writer = .{ .sink = .{ .stream = .{ .output = output, .buffer = &buffer.out } } },
        .scratch = &buffer.scratch,
        .max_metablock_size = encode.maxMetablockSize(@intCast(window_wbits)),
    };
    state.matcher.hasher.init();
    return .{
        .writer = .{
            .buffer = &buffer.staging,
            .end = 0,
            .vtable = &vtable,
        },
        .output = output,
        .ring = &buffer.ring,
        .mask = ring_size - 1,
        .staging = &buffer.staging,
        .state = state,
        .lgwin = @intCast(window_wbits),
    };
}

/// Complete the stream: process the buffered input, write the last
/// meta-block, flush the output window, and flush `output`. The stream is
/// complete only after this call, and the writer is unusable afterwards.
///
/// Returns `error.WriteFailed` if `output` fails; a writer that already
/// failed or already finished returns `error.WriteFailed` too, so a
/// truncated stream is never reported as complete.
pub fn finish(self: *Writer) Io.Writer.Error!void {
    if (self.writer.vtable != &vtable) return error.WriteFailed;
    defer self.writer = .failing;
    try self.process(self.writer.end, true, false);
    self.writer.end = 0;
    self.state.writer.sink.stream.flush() catch |err| return emitError(err);
    try self.output.flush();
}

/// The input the writer will accept before it must emit: the space left in
/// the staging block.
fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    errdefer w.* = .failing;
    const self: *Writer = @alignCast(@fieldParentPtr("writer", w));
    var consumed: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        consumed += accept(w, bytes);
        if (w.end == w.buffer.len) break;
    }
    const pattern = data[data.len - 1];
    if (pattern.len != 0) {
        for (0..splat) |_| {
            if (w.end == w.buffer.len) break;
            consumed += accept(w, pattern);
        }
    }
    // A full staging block is one input block; a call that accepted nothing
    // still makes progress by processing what is buffered.
    if (w.end == w.buffer.len or consumed == 0) {
        try self.process(w.end, false, false);
        w.end = 0;
    }
    return consumed;
}

/// Force the pending meta-block out (the reference's `BROTLI_OPERATION_FLUSH`),
/// then flush `output`. The writer stays usable.
fn flush(w: *Io.Writer) Io.Writer.Error!void {
    errdefer w.* = .failing;
    const self: *Writer = @alignCast(@fieldParentPtr("writer", w));
    try self.process(w.end, false, true);
    w.end = 0;
    try self.output.flush();
}

/// Make room for `capacity` more bytes: process everything but the last
/// `preserve` buffered bytes, then leave that tail at the front.
fn rebase(w: *Io.Writer, preserve: usize, capacity: usize) Io.Writer.Error!void {
    errdefer w.* = .failing;
    assert(preserve + capacity <= w.buffer.len);
    const self: *Writer = @alignCast(@fieldParentPtr("writer", w));
    const keep = @min(preserve, w.end);
    try self.process(w.end - keep, false, false);
    fastmem.move(u8, w.buffer[0..keep], w.buffer[w.end - keep ..][0..keep]);
    w.end = keep;
}

/// Process the first `len` staging bytes: copy them into the ring and run
/// the encoder's input-block step. `force_flush` emits a meta-block now;
/// `is_last` ends the stream.
fn process(self: *Writer, len: usize, is_last: bool, force_flush: bool) Io.Writer.Error!void {
    assert(len <= self.staging.len);
    if (!self.started) {
        // The stream header rides with the first meta-block, so `init` has
        // nothing to fail on.
        encode.storeWindowBits(&self.state.writer, self.lgwin) catch |err| return emitError(err);
        self.started = true;
    }
    self.copyIntoRing(self.staging[0..len]);
    self.state.feed(len, is_last, force_flush) catch |err| return emitError(err);
    // Hand the meta-block's whole bytes to the output: a caller that flushes
    // mid-stream must see them, and `finish`'s own flush then has nothing
    // left to do.
    self.state.writer.sink.stream.flush() catch |err| return emitError(err);
}

/// Copy one input block into the ring, splitting at the ring's end, and
/// refresh the mirror.
fn copyIntoRing(self: *Writer, chunk: []const u8) void {
    const index = self.state.input_pos & self.mask;
    const first = @min(chunk.len, self.ring.len - chunk_len - index);
    fastmem.copy(u8, self.ring[index..][0..first], chunk[0..first]);
    if (first < chunk.len) {
        fastmem.copy(u8, self.ring[0..][0 .. chunk.len - first], chunk[first..]);
    }
    const mirror_at = self.ring.len - chunk_len;
    fastmem.copy(u8, self.ring[mirror_at..][0..chunk_len], self.ring[0..chunk_len]);
}

/// Narrow the emission's error set to the writer's: the stream sink has no
/// cap, so `BufferTooSmall` cannot be raised here.
fn emitError(err: encode.EmitError) Io.Writer.Error {
    return switch (err) {
        error.WriteFailed => error.WriteFailed,
        error.BufferTooSmall => unreachable,
    };
}

/// Copy at most the staging block's remaining space from the front of
/// `bytes`, returning the bytes taken.
fn accept(w: *Io.Writer, bytes: []const u8) usize {
    const n = @min(bytes.len, w.buffer.len - w.end);
    fastmem.copy(u8, w.buffer[w.end..][0..n], bytes[0..n]);
    w.end += n;
    return n;
}

/// One-call pump: encode every byte of `in` into one stream on `out`, using
/// `buffer`. Returns the bytes read. `error.ReadFailed` reports an input or
/// an unimplemented quality; `error.WriteFailed` an output failure.
pub fn streamAll(
    comptime window_wbits: usize,
    in: *Io.Reader,
    out: *Io.Writer,
    buffer: *Buffer(window_wbits),
    options: encode.Options,
) error{ ReadFailed, WriteFailed }!usize {
    if (options.quality != 3) return error.ReadFailed;
    var w: Writer = .init(window_wbits, out, buffer, options);
    const n = try in.streamRemaining(&w.writer);
    try w.finish();
    return n;
}

// ---------------------------------------------------------------------------
// Tests. Every decode goes through the one-shot decoder, with the sentinel
// overrun rule: the target is pre-filled and the bytes past the decoded
// length must be untouched.
// ---------------------------------------------------------------------------

/// Encode `source` through a `Writer` at `window_wbits`, then decode with the
/// one-shot decoder and expect identity with the sentinel rule enforced.
fn roundTrip(comptime window_wbits: usize, source: []const u8) !void {
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const buffer = try gpa.create(Buffer(window_wbits));
    defer gpa.destroy(buffer);
    var in: Io.Reader = .fixed(source);
    _ = try streamAll(window_wbits, &in, &out.writer, buffer, .{});

    const plain = try gpa.alloc(u8, source.len + 1);
    defer gpa.free(plain);
    fastmem.set(u8, plain, 0xA5);
    const decoded = try decode.decompress(out.written(), plain[0..source.len]);
    try testing.expectEqual(source.len, decoded);
    try testing.expectEqualSlices(u8, source, plain[0..decoded]);
    try testing.expectEqual(@as(u8, 0xA5), plain[decoded]);
}

test "round trip: the README's shapes through a Writer" {
    try roundTrip(22, "");
    try roundTrip(22, "A");
    try roundTrip(22, "hello world");
    try roundTrip(22, "the quick brown fox jumps over the lazy dog. " ** 200);
    try roundTrip(10, "\x5a" ** 3000);
    try roundTrip(24, "abcabcabcabcabcabc");
}

test "round trip: a multi-block input through a Writer" {
    var source: [100 * 1024]u8 = undefined;
    for (&source, 0..) |*byte, i| byte.* = @truncate((i * 7) ^ (i >> 5));
    try roundTrip(17, &source);
}

test "round trip: incompressible data through a Writer" {
    var source: [64 * 1024]u8 = undefined;
    var rng: std.Random.DefaultPrng = .init(0x5eed);
    rng.random().bytes(&source);
    try roundTrip(22, &source);
}

test "a Writer fed everything at once is the one-shot" {
    // The same algorithm over the same window: the streaming form's staging
    // cadence is the one-shot's input-block cadence.
    const gpa = testing.allocator;
    var source: [300 * 1024]u8 = undefined;
    for (&source, 0..) |*byte, i| byte.* = @truncate((i * 31) ^ (i >> 3));
    // 300 KiB needs lgwin 19 (the one-shot's automatic window).
    const lgwin = encode.windowBitsFor(source.len);
    try testing.expectEqual(@as(u6, 19), lgwin);
    const comptime_lgwin = 19;

    var streamed: Io.Writer.Allocating = .init(gpa);
    defer streamed.deinit();
    const buffer = try gpa.create(Buffer(comptime_lgwin));
    defer gpa.destroy(buffer);
    var in: Io.Reader = .fixed(&source);
    _ = try streamAll(comptime_lgwin, &in, &streamed.writer, buffer, .{});

    const one_shot = try gpa.alloc(u8, encode.maxCompressedLength(source.len));
    defer gpa.free(one_shot);
    const written = try encode.compress(&source, one_shot, .{});
    try testing.expectEqualSlices(u8, one_shot[0..written], streamed.written());
}

test "an unimplemented quality poisons the writer, never a silent alias" {
    const gpa = testing.allocator;
    const buffer = try gpa.create(DefaultBuffer);
    defer gpa.destroy(buffer);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var w: Writer = .init(22, &out.writer, buffer, .{ .quality = 11 });
    try testing.expectError(error.WriteFailed, w.writer.writeAll("hello"));
    try testing.expectError(error.WriteFailed, w.finish());

    var in: Io.Reader = .fixed("hello");
    try testing.expectError(
        error.ReadFailed,
        streamAll(22, &in, &out.writer, buffer, .{ .quality = 0 }),
    );
}

test "flush forces the pending meta-block out" {
    const gpa = testing.allocator;
    const buffer = try gpa.create(DefaultBuffer);
    defer gpa.destroy(buffer);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var w: Writer = .init(22, &out.writer, buffer, .{});
    try w.writer.writeAll("hello world, hello world, hello world");
    const before = out.written().len;
    try w.writer.flush();
    try testing.expect(out.written().len > before);
    // The stream so far is a valid non-last meta-block; finish completes it.
    try w.writer.writeAll(" and more");
    try w.finish();
    const plain = try gpa.alloc(u8, 128);
    defer gpa.free(plain);
    fastmem.set(u8, plain, 0xA5);
    const decoded = try decode.decompress(out.written(), plain);
    const want = "hello world, hello world, hello world and more";
    try testing.expectEqualStrings(want, plain[0..decoded]);
}

test "the buffer's size is the documented figure" {
    // README.md's writer figures are pinned here: Buffer(22) is about
    // 8.7 MiB, and the ring is the reference's `1 << (lgwin + 1)` plus the
    // 16-KiB mirror.
    try testing.expectEqual(@as(usize, (1 << 23) + (1 << 14)), ringSize(22) + chunk_len);
    try testing.expectEqual(@as(usize, (1 << 15) + (1 << 14)), ringSize(10) + chunk_len);
    try testing.expect(@sizeOf(DefaultBuffer) > 8 * 1024 * 1024);
    try testing.expect(@sizeOf(DefaultBuffer) < 9 * 1024 * 1024);
}

test "every window the format allows round-trips" {
    inline for (10..25) |w| {
        try roundTrip(w, "the quick brown fox jumps over the lazy dog. " ** 40);
    }
}
