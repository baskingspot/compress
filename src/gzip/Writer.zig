//! gzip.Writer: a compressing `Io.Writer` producing one gzip member
//! (README.md, "Streaming").
//!
//! The real memory is flate's: the caller's `Writer.Buffer` is handed to the
//! inner `flate.Writer`, and this writer's serving region is that block
//! region — one region, one position, no staging copy (OQ6). The front's
//! `Io.Writer` position is resynced into the codec at every entry (`commit`)
//! and taken back after it (`adopt`), because `std.Io.Writer`'s fast paths
//! copy into the region without calling here.
//!
//! The framing is this module's: the 10-byte deterministic header is emitted
//! lazily, before the first compressed byte reaches `output` (Go's shape —
//! `init` cannot fail, so it writes nothing); `finish` completes the deflate
//! stream through flate and writes the trailer from the checksum state the
//! hook accumulated (CRC-32 and the input length, OQ1). Every byte is hashed
//! exactly once, at flate's emit funnel, with no container buffer and no
//! second pass. The driver machinery — the lazy header, the position sync,
//! the checksum arming, the poison check, the `Io.Writer` entries — is
//! `src/internal/container.zig`'s, instantiated over this module's framing
//! (`framing.zig`).

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;
const print = std.debug.print;

const fastmem = @import("fastmem");

const flate = @import("../flate/root.zig");
/// The caller-provided buffer: flate's, re-exported — the container adds no
/// buffer of its own (OQ6). `[max_block_size + history_len]u8`, 98303 bytes.
pub const Buffer = flate.Writer.Buffer;
const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const container = internal.container;
/// Whether the fixed header has reached `output`: the header is lazy
/// (README, "Streaming"), so the first entry that can emit a byte — a write
/// that drains, a flush, a rebase, or `finish` — writes it first.
const Header = container.Header;
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const framing = @import("framing.zig");
const golden = @import("golden.zig");

const Writer = @This();

writer: Io.Writer,
output: *Io.Writer,
inner: flate.Writer,
options: encode.Options,
/// The checksum state folded at flate's emit funnel: CRC-32 over the input
/// and the input length for ISIZE (`§2.3.1`).
checksum: framing.Checksum = .{},
header: Header = .pending,

/// The shared container driver over this module's framing
/// (`src/internal/container.zig`): the lazy header, the position sync, the
/// checksum arming, the poison check, and the generated `Io.Writer` entries.
const Hooks = container.WriterHooks(framing, Writer);

/// Wrap `output` (the member's sink) with `buffer` as the compression window
/// and `options` fixed for the stream's lifetime. Write through `&w.writer`;
/// complete the member with `finish`.
pub fn init(output: *Io.Writer, buffer: *Buffer, options: encode.Options) Writer {
    return Hooks.init(output, buffer, options);
}

/// Complete the member: emit the header if it is still pending, complete the
/// deflate stream through flate (the buffered partial block and the final
/// empty fixed block), write the trailer — CRC-32 and ISIZE from the hook's
/// state (`§2.3.1`) — and flush `output`. Terminal: the writer is poisoned
/// afterwards, and a failed or finished writer reports `error.WriteFailed`
/// instead of a false success (the pattern book's poison check).
pub fn finish(w: *Writer) Io.Writer.Error!void {
    return Hooks.finish(w);
}

/// Stream everything from `in` through a stack-buffered `Writer` into `out`,
/// returning the bytes consumed and encoded. Consumes `in` exactly through
/// its end, then finishes the member (the deflate ending and the trailer are
/// load-bearing). `.ratio` lands as `error.ReadFailed` upfront. Zero
/// allocation.
pub fn streamAll(
    in: *Io.Reader,
    out: *Io.Writer,
    options: encode.Options,
) Io.Reader.StreamRemainingError!usize {
    return Hooks.streamOne(in, out, options);
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc1952-gzip.txt §2.1 (byte order), §2.3
// (the member), §2.3.1 (the fixed header and trailer). Every decode is
// sentinel-checked.
// ---------------------------------------------------------------------------

/// Decode `member` with the landed one-shot decoder and expect `want`.
fn decodeMember(member: []const u8, want: []const u8) !void {
    const target = try testing.allocator.alloc(u8, want.len + sentinel.len);
    defer testing.allocator.free(target);
    sentinel.fill(target);
    const n = try decode.decompress(member, target[0..want.len]);
    try testing.expectEqual(want.len, n);
    try testing.expectEqualSlices(u8, want, target[0..n]);
    try sentinel.expect(target, n);
}

/// Encode `source` through `Writer`, decode with the one-shot decoder, expect
/// identity with the sentinel rule and the deterministic framing.
fn roundTrip(source: []const u8) !void {
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});
    try w.writer.writeAll(source);
    try w.finish();
    try golden.expectHeader(out.written(), encode.xflFor(.fast));
    try golden.expectTrailer(out.written(), source);
    try decodeMember(out.written(), source);
}

test "Writer: the emitted member is the deterministic one" {
    // RFC 1952 §2.3.1 — the header (FLG=0, MTIME=0, XFL by level, OS=255)
    // and the trailer (CRC-32, ISIZE) are pinned; OQ7 makes them
    // reproducible (no clock, no locale).
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{ .level = .@"9" });
    try w.writer.writeAll("the quick brown fox jumps over the lazy dog. " ** 4);
    try w.finish();
    try golden.expectHeader(out.written(), encode.xflFor(.@"9"));
    try golden.expectTrailer(out.written(), "the quick brown fox jumps over the lazy dog. " ** 4);

    // The same input and level produce the same member.
    var second: Io.Writer.Allocating = .init(gpa);
    defer second.deinit();
    var buf2: Buffer = undefined;
    var w2: Writer = .init(&second.writer, &buf2, .{ .level = .@"9" });
    try w2.writer.writeAll("the quick brown fox jumps over the lazy dog. " ** 4);
    try w2.finish();
    try testing.expectEqualSlices(u8, out.written(), second.written());
}

test "Writer: the header is lazy and written before the first byte" {
    // README, "Streaming": "`init` cannot fail, so it writes nothing; the
    // first write, flush, or finish emits the 10-byte header first" — and
    // nothing but the header reaches `output` until a block is emitted
    // (`TestWriterFlush`'s shape).
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});
    try testing.expectEqual(@as(usize, 0), out.written().len);

    try w.writer.flush();
    var header: [encode.header_len]u8 = undefined;
    encode.writeHeader(&header, .fast);
    try testing.expectEqualSlices(u8, &header, out.written());

    // A write alone does not emit: it lands in the block region.
    try w.writer.writeAll("x");
    try testing.expectEqual(@as(usize, encode.header_len), out.written().len);
    try w.writer.flush();
    try testing.expect(out.written().len > encode.header_len);

    try w.writer.writeAll("y");
    try w.finish();
    try golden.expectHeader(out.written(), encode.xflFor(.fast));
    try golden.expectTrailer(out.written(), "xy");
    try decodeMember(out.written(), "xy");
}

test "Writer: round-trips" {
    try roundTrip("");
    try roundTrip("a");
    try roundTrip("hello, gzip");
    try roundTrip("the quick brown fox jumps over the lazy dog. " ** 1000);
    try roundTrip("a" ** (flate.encode.max_block_size - 1));
    try roundTrip("b" ** flate.encode.max_block_size);
    try roundTrip("c" ** (flate.encode.max_block_size + 1));
    try roundTrip("d" ** (3 * flate.encode.max_block_size + 17));
}

test "Writer: incompressible input round-trips" {
    // Random bytes take the stored fallback (`rfc1951-deflate.txt §3.2.4`),
    // so the container's framing wraps stored blocks.
    const gpa = testing.allocator;
    const source = try gpa.alloc(u8, 200_000);
    defer gpa.free(source);
    var rng: DefaultPrng = .init(0xC0FFEE);
    for (source) |*byte| byte.* = rng.random().int(u8);
    try roundTrip(source);
}

test "Writer: the trailer covers chunked writes with mid-stream flushes" {
    // README, "Streaming": "The CRC-32 and the input length (for ISIZE, mod
    // 2^32) are accumulated as the data crosses the codec boundary — no
    // re-read of the input, no second pass." Chunked writes and flushes
    // must not drop, double, or reorder a byte.
    const gpa = testing.allocator;
    var source: [70_000]u8 = undefined;
    var rng: DefaultPrng = .init(0x5EED);
    for (&source) |*byte| byte.* = rng.random().int(u8);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});
    var pos: usize = 0;
    var step: usize = 1;
    while (pos < source.len) {
        const n = @min(source.len - pos, step);
        try w.writer.writeAll(source[pos..][0..n]);
        pos += n;
        step = (step * 3 + 1) % 20_000;
        if (pos % 7 < 3) try w.writer.flush();
    }
    // Empty writes and flushes do not move the digest.
    try w.writer.writeAll("");
    try w.writer.flush();
    try w.finish();
    try golden.expectTrailer(out.written(), &source);
    try decodeMember(out.written(), &source);
}

test "Writer: the writableSliceGreedy path round-trips" {
    // The `File.Reader` simple-mode stream feeds a writer through
    // `writableSliceGreedy` + `advance` (a direct write into the block
    // region), which lands on `rebase` when the region is full. The front
    // and the codec share the region, so the position must resync.
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});

    const total = 3 * flate.encode.max_block_size;
    var written: usize = 0;
    var fill: u8 = 0;
    while (written < total) {
        const dest = try w.writer.writableSliceGreedy(1);
        const n = @min(dest.len, total - written);
        fastmem.set(u8, dest[0..n], fill);
        w.writer.advance(n);
        written += n;
        fill +%= 1;
    }
    try w.finish();

    const expect = try gpa.alloc(u8, total);
    defer gpa.free(expect);
    var at: usize = 0;
    fill = 0;
    while (at < total) : (fill +%= 1) {
        const n = @min(flate.encode.max_block_size, total - at);
        fastmem.set(u8, expect[at..][0..n], fill);
        at += n;
    }
    try golden.expectTrailer(out.written(), expect);
    try decodeMember(out.written(), expect);
}

test "Writer: a failed or finished writer never reports a false success" {
    // The pattern book's poison check: `finish` after a failed write, after
    // `finish`, and writes after `finish` all report `error.WriteFailed` — a
    // truncated member must not be reported as complete.
    const gpa = testing.allocator;

    // Finish after a failed write: the write buffers fine, the emit fails
    // into the full fixed output, and `finish` must report it — twice, not a
    // false success the second time.
    var small: [16]u8 = undefined;
    var fixed_out: Io.Writer = .fixed(&small);
    var buf: Buffer = undefined;
    var w: Writer = .init(&fixed_out, &buf, .{});
    try w.writer.writeAll("a" ** 4096);
    try testing.expectError(error.WriteFailed, w.finish());
    try testing.expectError(error.WriteFailed, w.finish());

    // Write and finish after finish.
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var w2: Writer = .init(&out.writer, &buf, .{});
    try w2.writer.writeAll("hello, gzip");
    try w2.finish();
    try testing.expectError(error.WriteFailed, w2.writer.writeAll("more"));
    try testing.expectError(error.WriteFailed, w2.finish());
    try golden.expectTrailer(out.written(), "hello, gzip");
}

test "Writer: the ratio seat is rejected, never silently aliased" {
    // README, "API": `Writer.init(..., .{ .level = .ratio })` poisons the
    // interface (every write and `finish` reports `error.WriteFailed`), and
    // `Writer.streamAll` returns `error.ReadFailed` upfront.
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{ .level = .ratio });
    try testing.expectError(error.WriteFailed, w.writer.writeAll("hello, gzip"));
    try testing.expectError(error.WriteFailed, w.finish());
    try testing.expectEqual(@as(usize, 0), out.written().len);

    var in: Io.Reader = .fixed("hello, gzip");
    try testing.expectError(
        error.ReadFailed,
        Writer.streamAll(&in, &out.writer, .{ .level = .ratio }),
    );
}

test "Writer: random write machinery sequences stay correct" {
    // Mixed writeSplatAll/writeVecAll/splatBytesAll/writableSliceGreedy+
    // advance/writeByte/flush sequences: the driver class that catches drain
    // and rebase accounting under the full vtable contract (multi-slice data
    // with splat, partial straddling takes, direct-slice writes onto a full
    // region).
    const gpa = testing.allocator;
    var rng: DefaultPrng = .init(99);
    const rand = rng.random();

    var iter: usize = 0;
    while (iter < 40) : (iter += 1) {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var expect: std.ArrayList(u8) = .empty;
        defer expect.deinit(gpa);
        var buf: Buffer = undefined;
        var w: Writer = .init(&out.writer, &buf, .{});

        var ops: usize = 0;
        while (ops < 10) : (ops += 1) {
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
                    const dest = try w.writer.writableSliceGreedy(1);
                    const n = @min(dest.len, b_len);
                    fastmem.copy(u8, dest[0..n], b[0..n]);
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
        try golden.expectHeader(out.written(), encode.xflFor(.fast));
        try golden.expectTrailer(out.written(), expect.items);
        decodeMember(out.written(), expect.items) catch |err| {
            print("\nFAIL: iter {d}: {s}\n", .{ iter, @errorName(err) });
            return err;
        };
    }
}

test "Writer: the golden payloads encode to decodable members" {
    // The ported golang/go payloads and std's members through the streaming
    // writer: the framing must reproduce them byte-for-byte on decode.
    for (golden.gunzip_cases) |tc| {
        const source = switch (tc.expect) {
            .ok => |bytes| bytes,
            else => continue,
        };
        roundTrip(source) catch |err| {
            print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
            return err;
        };
    }
    for (golden.std_cases) |tc| {
        const source = switch (tc.expect) {
            .ok => |bytes| bytes,
            else => continue,
        };
        roundTrip(source) catch |err| {
            print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
            return err;
        };
    }
}

test "Writer: streamAll consumes its input exactly and writes one member" {
    // The one-call pump: stack-buffered end to end, zero allocation, the
    // input consumed through its end, one member on the output.
    const gpa = testing.allocator;
    const source = "the quick brown fox jumps over the lazy dog. " ** 100;
    var in: Io.Reader = .fixed(source);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try testing.expectEqual(source.len, try Writer.streamAll(&in, &out.writer, .{}));
    try testing.expectEqual(source.len, in.seek);
    try golden.expectHeader(out.written(), encode.xflFor(.fast));
    try golden.expectTrailer(out.written(), source);
    try decodeMember(out.written(), source);
}
