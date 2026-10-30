//! snappy.Writer: a compressing `Io.Writer` over Google's framed snappy
//! stream (`framing_format.txt`). Write through `&w.writer`, then call
//! `finish`.
//!
//! Uncompressed writes accumulate in the caller-provided `Buffer` (one full
//! chunk). As the buffer fills, `drain` compresses whole `max_block_size`
//! chunks and emits them; `flush` and `finish` emit the partial tail. A
//! chunk is emitted compressed only when the block is smaller than the raw
//! bytes; otherwise it is a raw chunk. Each emitted chunk compresses into a
//! `scratch_len` stack buffer, so nothing is allocated.
//!
//! Framing (`framing_format.txt` §4):
//! ```text
//! stream := identifier chunk*
//! identifier := 0xff, u24-le 6, "sNaPpY"
//! chunk  := type, u24-le length, data
//!   compressed   0x00: u32-le masked CRC-32C (uncompressed), snappy block
//!   uncompressed 0x01: u32-le masked CRC-32C, raw bytes
//! ```
//! The stream has no end marker; the input's end is the stream's end.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const common = @import("common.zig");
const readInt = common.readInt;
const writeInt = common.writeInt;
const crc32c = @import("crc32c.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const golden = @import("golden.zig");
const Reader = @import("Reader.zig");

/// The stream identifier chunk every framed stream starts with (`§4.1`).
pub const identifier = "\xff\x06\x00\x00sNaPpY";

/// The chunk header's width: one type byte and a three-byte little-endian
/// length (`§1`).
pub const chunk_header_len = 4;
/// The masked CRC-32C's width, ahead of every data chunk's payload (`§3`).
pub const chunk_crc_len = 4;
/// The most uncompressed bytes one data chunk may carry (`§4.2`, `§4.3`).
pub const max_chunk_len = encode.max_block_size;

/// The caller-provided uncompressed accumulation buffer: one full chunk.
pub const Buffer = [max_chunk_len]u8;

/// The largest compressed block: `maxCompressedLength` of a full chunk.
pub const scratch_len = encode.maxCompressedLength(max_chunk_len);

const Writer = @This();

writer: Io.Writer,
output: *Io.Writer,
/// Whether the stream identifier has gone out. The identifier is written
/// lazily: `finish` still emits it for an empty stream.
started: bool = false,

/// The shared writer machinery (`src/internal/writer.zig`): the generated
/// `Io.Writer` entries and the poisoned `finish`, over this writer's
/// `emitBlock`. The stream has no ending of its own, so the ending hook is
/// null.
const Hooks = internal.writer.VTable(Writer, emitBlock, null);

/// Wrap `output` (the compressed-stream sink) with `buffer` as the
/// uncompressed accumulation buffer. Write through `&w.writer`; complete the
/// stream with `finish`.
pub fn init(output: *Io.Writer, buffer: *Buffer) Writer {
    return .{
        .writer = .{
            .buffer = buffer,
            .end = 0,
            .vtable = &Hooks.vtable,
        },
        .output = output,
    };
}

/// Complete the stream: emit the identifier when nothing has been written,
/// the final partial chunk, then flush `output`. Without it the buffered tail
/// never reaches `output`. Terminal: afterwards, and after any failed write
/// to `output`, writes and `finish` return `error.WriteFailed` rather than
/// reporting a truncated stream as complete.
pub fn finish(w: *Writer) Io.Writer.Error!void {
    if (!w.started) try w.start();
    return Hooks.finish(w);
}

/// Write the stream identifier once.
fn start(w: *Writer) Io.Writer.Error!void {
    if (w.started) return;
    try w.output.writeAll(identifier);
    w.started = true;
}

/// Emit one data chunk for `bytes` (a region of the accumulation buffer):
/// the identifier on first use, the type and length, the masked CRC-32C of
/// the uncompressed bytes, and the compressed block or the raw bytes. A no-op
/// when empty.
fn emitChunk(w: *Writer, bytes: []const u8) Io.Writer.Error!void {
    if (bytes.len == 0) return;
    assert(bytes.len <= max_chunk_len);
    try w.start();
    var scratch: [scratch_len]u8 = undefined;
    // `scratch` holds `maxCompressedLength` of a full chunk, so `compressBlock`
    // cannot run out of room.
    const n = encode.compressBlock(bytes, &scratch) catch unreachable;
    const compressed = n < bytes.len;
    const payload = if (compressed) scratch[0..n] else bytes;
    const length = chunk_crc_len + payload.len;
    assert(length < 1 << 24);
    var header: [chunk_header_len]u8 = .{ if (compressed) 0x00 else 0x01, 0, 0, 0 };
    header[1] = @truncate(length);
    header[2] = @truncate(length >> 8);
    header[3] = @truncate(length >> 16);
    var checksum: [chunk_crc_len]u8 = undefined;
    writeInt(u32, &checksum, crc32c.mask(crc32c.crc32c(0, bytes)));
    try w.output.writeAll(&header);
    try w.output.writeAll(&checksum);
    try w.output.writeAll(payload);
}

/// Emit the first `emit_len` bytes of the buffered chunk, then slide the
/// unemitted tail to the front of the buffer. This is the hook the shared
/// writer machinery (`src/internal/writer.zig`) calls: `drain`, `flush`, and
/// `finish` emit the whole chunk, `rebase` emits the front, and the tail it
/// preserves becomes the new chunk.
fn emitBlock(w: *Writer, emit_len: usize) Io.Writer.Error!void {
    assert(emit_len <= w.writer.end);
    if (emit_len == 0) return;
    try w.emitChunk(w.writer.buffer[0..emit_len]);
    const keep = w.writer.end - emit_len;
    if (keep != 0) {
        fastmem.move(u8, w.writer.buffer[0..keep], w.writer.buffer[emit_len..][0..keep]);
    }
    w.writer.end = keep;
}

test "Writer: empty input is the identifier alone" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf);
    try w.finish();
    try testing.expectEqualSlices(u8, identifier, out.written());
}

test "Writer: partial tail is one data chunk with its checksum" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf);
    try w.writer.writeAll("hello, snappy");
    try w.finish();

    const stream = out.written();
    try testing.expectEqualSlices(u8, identifier, stream[0..identifier.len]);
    const chunk = stream[identifier.len..];
    try testing.expect(chunk[0] == 0x00 or chunk[0] == 0x01);
    const length = @as(usize, chunk[1]) | (@as(usize, chunk[2]) << 8) |
        (@as(usize, chunk[3]) << 16);
    try testing.expectEqual(@as(usize, 4 + 13), length);
    var decoded: [13]u8 = undefined;
    const payload = chunk[4 + chunk_crc_len ..][0 .. length - chunk_crc_len];
    if (chunk[0] == 0x00) {
        const n = try decode.decompressBlock(payload, &decoded);
        try testing.expectEqual(@as(usize, 13), n);
    } else {
        @memcpy(decoded[0..], payload);
    }
    try testing.expectEqualStrings("hello, snappy", &decoded);
    const stored = readInt(u32, chunk[4..8]);
    try testing.expectEqual(crc32c.mask(crc32c.crc32c(0, &decoded)), stored);
    try roundTrip("hello, snappy");
}

test "Writer: writes past one chunk split into full chunks" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf);
    try w.writer.writeAll("a" ** (3 * max_chunk_len + 1));
    try w.finish();
    try testing.expectEqual(4, countChunks(out.written()));
    try roundTrip("a" ** (3 * max_chunk_len + 1));
}

test "Writer: writableSliceGreedy on a full buffer emits, never drops" {
    // The File.Reader simple-mode stream feeds a Writer through
    // `writableSliceGreedy` + `advance` (a direct write into the buffer),
    // which lands on `rebase` when the buffer is full. `rebase` must emit the
    // buffered chunk to free the space; discarding it would silently drop a
    // whole chunk of input.
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf);

    try w.writer.writeAll("a" ** max_chunk_len);
    const dest = try w.writer.writableSliceGreedy(1);
    try testing.expectEqual(max_chunk_len, dest.len);
    fastmem.set(u8, dest, 0x62);
    w.writer.advance(dest.len);
    try w.writer.writeAll("c" ** 1000);
    try w.finish();

    try testing.expectEqual(3, countChunks(out.written()));
    const plain = try decodeFramed(gpa, out.written());
    defer gpa.free(plain);
    try testing.expectEqual(2 * max_chunk_len + 1000, plain.len);
    try testing.expect(plain[0] == 'a');
    try testing.expect(plain[max_chunk_len] == 'b');
    try testing.expect(plain[2 * max_chunk_len] == 'c');
}

test "Writer: golden decoded outputs encode to verified chunks" {
    // Encode each golden `want` through Writer, then walk the chunks
    // independently of Reader: every checksum must match the decoded bytes,
    // and every compressed block must decode to its input.
    const gpa = testing.allocator;
    for (golden.golden_decode_cases) |tc| {
        if (tc.want_err) continue; // Corrupt sources have no output.

        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var buf: Buffer = undefined;
        var w: Writer = .init(&out.writer, &buf);
        try w.writer.writeAll(tc.want);
        try w.finish();

        const stream = out.written();
        try testing.expectEqualSlices(u8, identifier, stream[0..identifier.len]);
        var pos: usize = identifier.len;
        var plain: Io.Writer.Allocating = .init(gpa);
        defer plain.deinit();
        var decoded: [max_chunk_len]u8 = undefined;
        while (pos < stream.len) {
            const kind = stream[pos];
            const length = @as(usize, stream[pos + 1]) |
                (@as(usize, stream[pos + 2]) << 8) |
                (@as(usize, stream[pos + 3]) << 16);
            pos += chunk_header_len;
            try testing.expect(length >= chunk_crc_len);
            const stored = readInt(u32, stream[pos..][0..4]);
            pos += chunk_crc_len;
            const payload = stream[pos..][0 .. length - chunk_crc_len];
            pos += length - chunk_crc_len;
            const n = switch (kind) {
                0x00 => try decode.decompressBlock(payload, &decoded),
                0x01 => blk: {
                    fastmem.copy(u8, &decoded, payload);
                    break :blk payload.len;
                },
                else => return error.InvalidStream,
            };
            try testing.expectEqual(crc32c.mask(crc32c.crc32c(0, decoded[0..n])), stored);
            try plain.writer.writeAll(decoded[0..n]);
        }
        try testing.expectEqualSlices(u8, tc.want, plain.written());
    }
}

test "Writer: a failed or finished writer never reports a false success" {
    // `finish` after a failed write, after `finish`, and writes after
    // `finish` must all report `error.WriteFailed` — a truncated stream must
    // not be reported as complete.
    const gpa = testing.allocator;

    // Finish after a failed write: the write buffers fine (it fits the
    // accumulation buffer), the emit fails into the full fixed output, and
    // `finish` must report it — twice, not a false success the second time.
    var small: [8]u8 = undefined;
    var fixed_out: Io.Writer = .fixed(&small);
    var buf: Buffer = undefined;
    var w: Writer = .init(&fixed_out, &buf);
    try w.writer.writeAll("a" ** 4096);
    try testing.expectError(error.WriteFailed, w.finish());
    try testing.expectError(error.WriteFailed, w.finish());

    // Write and finish after finish.
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var w2: Writer = .init(&out.writer, &buf);
    try w2.writer.writeAll("hello, snappy");
    try w2.finish();
    try testing.expectError(error.WriteFailed, w2.writer.writeAll("more"));
    try testing.expectError(error.WriteFailed, w2.finish());
    try testing.expectEqual(1, countChunks(out.written()));
}

test "Writer: random write machinery sequences stay correct" {
    // Mixed writeSplatAll/writeVecAll/splatBytesAll/writableSliceGreedy+advance/
    // writeByte/flush sequences: this is the driver class that catches drain
    // accounting under the full vtable contract (multi-slice data with splat,
    // partial straddling takes, direct-slice writes onto a full buffer).
    const gpa = testing.allocator;
    var rng: DefaultPrng = .init(99);
    const rand = rng.random();

    var iter: usize = 0;
    while (iter < 200) : (iter += 1) {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var expect: std.ArrayList(u8) = .empty;
        defer expect.deinit(gpa);
        var buf: Buffer = undefined;
        var w: Writer = .init(&out.writer, &buf);

        var ops: usize = 0;
        while (ops < 12) : (ops += 1) {
            var a: [3000]u8 = undefined;
            var b: [40000]u8 = undefined;
            var pattern: [7]u8 = undefined;
            rand.bytes(&a);
            rand.bytes(&b);
            rand.bytes(&pattern);
            const a_len = rand.uintAtMost(usize, a.len);
            const b_len = rand.uintAtMost(usize, b.len);
            const p_len = rand.intRangeAtMost(usize, 1, pattern.len);
            const splat = rand.uintAtMost(usize, 30000);
            switch (rand.uintLessThan(u8, 5)) {
                0 => {
                    var data = [_][]const u8{ a[0..a_len], b[0..b_len], pattern[0..p_len] };
                    try w.writer.writeSplatAll(&data, splat);
                    try expect.appendSlice(gpa, a[0..a_len]);
                    try expect.appendSlice(gpa, b[0..b_len]);
                    for (0..splat) |_| try expect.appendSlice(gpa, pattern[0..p_len]);
                },
                1 => {
                    var data = [_][]const u8{ a[0..a_len], b[0..b_len] };
                    try w.writer.writeVecAll(&data);
                    try expect.appendSlice(gpa, a[0..a_len]);
                    try expect.appendSlice(gpa, b[0..b_len]);
                },
                2 => {
                    try w.writer.splatBytesAll(pattern[0..p_len], splat);
                    for (0..splat) |_| try expect.appendSlice(gpa, pattern[0..p_len]);
                },
                3 => {
                    // The File.Reader simple-mode path: a direct write into the
                    // buffer, which lands on `rebase` when the buffer is full.
                    const dest = try w.writer.writableSliceGreedy(1);
                    const n = @min(dest.len, b_len);
                    for (dest[0..n], b[0..n]) |*d, x| d.* = x;
                    w.writer.advance(n);
                    try expect.appendSlice(gpa, b[0..n]);
                },
                else => {
                    try w.writer.writeByte(pattern[0]);
                    try expect.append(gpa, pattern[0]);
                    if (rand.boolean()) try w.writer.flush();
                },
            }
        }
        try w.finish();

        const got = try decodeFramed(gpa, out.written());
        defer gpa.free(got);
        try testing.expectEqual(expect.items.len, got.len);
        try testing.expectEqualSlices(u8, expect.items, got);
    }
}

test "Writer: flush mid-stream emits the partial chunk" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf);
    try w.writer.writeAll("hello, ");
    try w.writer.flush();
    try testing.expectEqual(1, countChunks(out.written()));
    try w.writer.writeAll("snappy");
    try w.finish();
    try testing.expectEqual(2, countChunks(out.written()));
    try roundTrip("hello, snappy");
}

/// Count the data chunks in a stream produced by `Writer`.
fn countChunks(stream: []const u8) usize {
    assert(std.mem.startsWith(u8, stream, identifier));
    var n: usize = 0;
    var pos: usize = identifier.len;
    while (pos < stream.len) {
        const kind = stream[pos];
        const length = @as(usize, stream[pos + 1]) | (@as(usize, stream[pos + 2]) << 8) |
            (@as(usize, stream[pos + 3]) << 16);
        pos += chunk_header_len + length;
        if (kind == 0x00 or kind == 0x01) n += 1;
    }
    assert(pos == stream.len);
    return n;
}

/// Decode a framed stream with `Reader`, for the round-trip checks.
fn decodeFramed(gpa: Allocator, stream: []const u8) ![]u8 {
    var rbuf: Reader.Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(stream);
    var r: Reader = .init(&fixed_in, &rbuf);
    return r.reader.allocRemaining(gpa, .unlimited);
}

/// Encode `src` with `Writer`, decode with `Reader`, expect identity.
fn roundTrip(src: []const u8) !void {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var wbuf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &wbuf);
    try w.writer.writeAll(src);
    try w.finish();
    const got = try decodeFramed(testing.allocator, out.written());
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, src, got);
}

/// Compress everything `in` yields into `out` as one framed snappy stream and
/// finish it (the last partial block is written and `out` is flushed).
/// Returns the number of uncompressed bytes read from `in`. Errors are
/// `error.ReadFailed` (`in` failing) and `error.WriteFailed` (`out` failing).
/// The `Writer` and its 64 KiB `Buffer` live on this function's stack frame,
/// and compressing a block uses about 97 KiB more; nothing is allocated.
pub fn streamAll(in: *Io.Reader, out: *Io.Writer) Io.Reader.StreamRemainingError!usize {
    var buf: Buffer = undefined;
    var ww: Writer = .init(out, &buf);
    const n = try in.streamRemaining(&ww.writer);
    // The stream is not complete until `finish` writes the final partial block.
    try ww.finish();
    return n;
}
