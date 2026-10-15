//! zlib.Writer: a compressing `Io.Writer` that produces one zlib stream.
//!
//! `init` takes the output writer and a caller-provided `Writer.Buffer`,
//! which is flate's block buffer: written bytes land in it directly, with no
//! staging copy, and are compressed into `output` a block at a time. The
//! 2-byte header is written lazily, before the first compressed byte reaches
//! `output` (`init` cannot fail, so it writes nothing). `finish` completes
//! the deflate stream through flate and writes the Adler-32 trailer. Flate's
//! checksum hook folds the Adler-32 as each block is emitted, so every byte is
//! hashed once, with no second pass.
//!
//! The lazy header, the position sync with flate's block region, the checksum
//! arming, the poisoned `finish`, and the `Io.Writer` entries come from the
//! shared container driver (`src/internal/container.zig`, `WriterHooks`),
//! instantiated over `framing.zig`.
//!
//! Format: docs/research/specs/rfc1950-zlib.txt

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;
const print = std.debug.print;

const fastmem = @import("fastmem");

const flate = @import("../flate/root.zig");
/// The caller-provided compression buffer: flate's `Writer.Buffer`,
/// re-exported. 98303 bytes (`[max_block_size + history_len]u8`): one
/// 65535-byte block plus 32 KiB of match history.
pub const Buffer = flate.Writer.Buffer;
const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const container = internal.container;
/// Whether the 2-byte header has reached `output`. It is written lazily, by
/// the first entry that can emit a byte: a write that drains, a flush, a
/// rebase, or `finish`.
const Header = container.Header;
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const framing = @import("framing.zig");
const golden = @import("golden.zig");
const zlib_reader = @import("Reader.zig");

const Writer = @This();

writer: Io.Writer,
output: *Io.Writer,
inner: flate.Writer,
options: encode.Options,
/// The Adler-32 of the input so far, folded in as flate emits each block
/// (`§2.2`). `finish` writes it as the trailer.
checksum: framing.Checksum = .{},
header: Header = .pending,

/// The shared container driver over this module's framing
/// (`src/internal/container.zig`): the lazy header, the position sync, the
/// checksum arming, the poison check, and the generated `Io.Writer` entries.
const Hooks = container.WriterHooks(framing, Writer);

/// Start a zlib stream that is written to `output`, with `buffer` as the
/// compression buffer and `options` fixed for the stream's lifetime. Write
/// through `&w.writer` and complete the stream with `finish`. Nothing reaches
/// `output` until a write fills the buffer or `flush` or `finish` is called.
///
/// `options.dict` is the stream's preset dictionary or `null` (`§2.2`): the
/// header then carries FDICT and the dictionary's Adler-32 as DICTID, and the
/// compressor matches into the dictionary's last 32 KiB. A dictionary longer
/// than 32 KiB contributes only its tail to the window while DICTID names the
/// whole.
///
/// `options.level == .ratio` is not implemented: the returned writer has
/// already failed, so every write and `finish` returns `error.WriteFailed`.
/// Do not move the `Writer` after its first write.
pub fn init(output: *Io.Writer, buffer: *Buffer, options: encode.Options) Writer {
    return Hooks.init(output, buffer, options);
}

/// Complete the stream: write the header if it is still pending, the
/// buffered data as a last block, the empty final block that ends the deflate
/// stream, and the Adler-32 trailer (`§2.2`), then flush `output`. A stream
/// that is never finished is incomplete and will not decode.
///
/// Returns `error.WriteFailed` if `output` fails. It also returns
/// `error.WriteFailed` if an earlier write failed or the writer was already
/// finished, so a truncated stream is never reported as complete. The writer
/// is unusable afterwards: later writes and a second `finish` return
/// `error.WriteFailed`.
pub fn finish(w: *Writer) Io.Writer.Error!void {
    return Hooks.finish(w);
}

/// Compress everything in `in` into one zlib stream written to `out`, and
/// return the number of input bytes consumed. `in` is read to its end, then
/// the stream is finished. Returns `error.ReadFailed` if `in` fails (and at
/// once for `.ratio`, which is not implemented) and `error.WriteFailed` if
/// `out` fails. Uses about 288 KiB of stack (the 96 KiB buffer plus flate's
/// writer state and block scratch) and allocates nothing.
pub fn streamAll(
    in: *Io.Reader,
    out: *Io.Writer,
    options: encode.Options,
) Io.Reader.StreamRemainingError!usize {
    return Hooks.streamOne(in, out, options);
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc1950-zlib.txt §2.1 (byte order), §2.2
// (the header, the trailer), §2.3 (decoder obligations). Every decode is
// sentinel-checked.
// ---------------------------------------------------------------------------

/// Decode `stream` with the one-shot decoder and expect `want`.
fn decodeStream(stream: []const u8, want: []const u8) !void {
    return decodeStreamDict(stream, want, null);
}

/// `decodeStream` with a preset dictionary supplied to the decode.
fn decodeStreamDict(stream: []const u8, want: []const u8, dict: ?[]const u8) !void {
    const target = try testing.allocator.alloc(u8, want.len + sentinel.len);
    defer testing.allocator.free(target);
    sentinel.fill(target);
    const n = try decode.decompress(stream, target[0..want.len], dict);
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
    try golden.expectHeader(out.written(), .fast);
    try golden.expectTrailer(out.written(), source);
    try decodeStream(out.written(), source);
}

test "Writer: the buffer type is flate's, re-exported" {
    // `Writer.Buffer` is `flate.Writer.Buffer`: max_block_size +
    // history_len, 98303 bytes.
    try testing.expectEqual(@as(usize, 98303), @sizeOf(Buffer));
    try testing.expect(Buffer == flate.Writer.Buffer);
}

test "Writer: the emitted stream is the deterministic one" {
    // RFC 1950 §2.2 — the header (CM=8, CINFO=7, FLEVEL by band, the minimal
    // FCHECK, FDICT clear) and the trailer (the Adler-32, big-endian) are
    // pinned, and reproducible (no clock, no locale).
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{ .level = .@"9" });
    try w.writer.writeAll("the quick brown fox jumps over the lazy dog. " ** 4);
    try w.finish();
    try golden.expectHeader(out.written(), .@"9");
    try golden.expectTrailer(out.written(), "the quick brown fox jumps over the lazy dog. " ** 4);

    // The same input and level produce the same stream.
    var second: Io.Writer.Allocating = .init(gpa);
    defer second.deinit();
    var buf2: Buffer = undefined;
    var w2: Writer = .init(&second.writer, &buf2, .{ .level = .@"9" });
    try w2.writer.writeAll("the quick brown fox jumps over the lazy dog. " ** 4);
    try w2.finish();
    try testing.expectEqualSlices(u8, out.written(), second.written());
}

test "Writer: the header is lazy and written before the first byte" {
    // The 2-byte header is written lazily, before the first compressed byte
    // reaches `output`: `init` writes nothing, and nothing but the header
    // reaches `output` until a block is emitted.
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});
    try testing.expectEqual(@as(usize, 0), out.written().len);

    try w.writer.flush();
    var header: [encode.header_len]u8 = undefined;
    encode.writeHeader(&header, .fast, false);
    try testing.expectEqualSlices(u8, &header, out.written());

    // A write alone does not emit: it lands in the block region.
    try w.writer.writeAll("x");
    try testing.expectEqual(@as(usize, encode.header_len), out.written().len);
    try w.writer.flush();
    try testing.expect(out.written().len > encode.header_len);

    try w.writer.writeAll("y");
    try w.finish();
    try golden.expectHeader(out.written(), .fast);
    try golden.expectTrailer(out.written(), "xy");
    try decodeStream(out.written(), "xy");
}

test "Writer: round-trips" {
    try roundTrip("");
    try roundTrip("a");
    try roundTrip("hello, zlib");
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
    // The Adler-32 is accumulated as the data crosses the codec boundary,
    // with no re-read of the input and no second pass. Chunked writes and
    // flushes must not drop, double, or reorder a byte.
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
    try decodeStream(out.written(), &source);
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
    try decodeStream(out.written(), expect);
}

test "Writer: a failed or finished writer never reports a false success" {
    // `finish` after a failed write, `finish` after `finish`, and writes after
    // `finish` all report `error.WriteFailed`: a truncated stream must not be
    // reported as complete.
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
    try w2.writer.writeAll("hello, zlib");
    try w2.finish();
    try testing.expectError(error.WriteFailed, w2.writer.writeAll("more"));
    try testing.expectError(error.WriteFailed, w2.finish());
    try golden.expectTrailer(out.written(), "hello, zlib");
}

test "Writer: the ratio seat is rejected, never silently aliased" {
    // `Writer.init(..., .{ .level = .ratio })` poisons the interface (every
    // write and `finish` reports `error.WriteFailed`), and `Writer.streamAll`
    // returns `error.ReadFailed` upfront.
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{ .level = .ratio });
    try testing.expectError(error.WriteFailed, w.writer.writeAll("hello, zlib"));
    try testing.expectError(error.WriteFailed, w.finish());
    try testing.expectEqual(@as(usize, 0), out.written().len);

    var in: Io.Reader = .fixed("hello, zlib");
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
        try golden.expectHeader(out.written(), .fast);
        try golden.expectTrailer(out.written(), expect.items);
        decodeStream(out.written(), expect.items) catch |err| {
            print("\nFAIL: iter {d}: {s}\n", .{ iter, @errorName(err) });
            return err;
        };
    }
}

test "Writer: the golden payloads encode to decodable streams" {
    // The ported golang/go and std payloads through the streaming writer:
    // the framing must reproduce them byte-for-byte on decode.
    for (golden.zlib_cases) |tc| {
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

test "Writer: streamAll consumes its input exactly and writes one stream" {
    // The one-call pump: stack-buffered end to end, zero allocation, the
    // input consumed through its end, one stream on the output.
    const gpa = testing.allocator;
    const source = "the quick brown fox jumps over the lazy dog. " ** 100;
    var in: Io.Reader = .fixed(source);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try testing.expectEqual(source.len, try Writer.streamAll(&in, &out.writer, .{}));
    try testing.expectEqual(source.len, in.seek);
    try golden.expectHeader(out.written(), .fast);
    try golden.expectTrailer(out.written(), source);
    try decodeStream(out.written(), source);
}

test "Writer: a dictionary stream's header is FDICT plus the DICTID" {
    // RFC 1950 §2.2 — with a dictionary the header is six bytes (CMF, FLG
    // with FDICT, the 4-byte DICTID) and the trailer still covers the payload
    // only. The header stays lazy: `init` writes nothing, the first flush
    // writes all six bytes before any compressed byte.
    const gpa = testing.allocator;
    const dict = "she sells seashells by the seashore\n";
    const source = "she sells seashells " ** 4;

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{ .dict = dict });
    try testing.expectEqual(@as(usize, 0), out.written().len);
    try w.writer.flush();
    try testing.expectEqual(
        @as(usize, encode.header_len + encode.dict_id_len),
        out.written().len,
    );
    try golden.expectDictHeader(out.written(), .fast, dict);

    try w.writer.writeAll(source);
    try w.finish();
    try golden.expectDictHeader(out.written(), .fast, dict);
    try golden.expectTrailer(out.written(), source);
    try decodeStreamDict(out.written(), source, dict);

    // The dictionary carried the stream: the same source without one is
    // larger, and the stream decodes only against the dictionary's bytes.
    var plain_out: Io.Writer.Allocating = .init(gpa);
    defer plain_out.deinit();
    var plain_buf: Buffer = undefined;
    var plain_w: Writer = .init(&plain_out.writer, &plain_buf, .{});
    try plain_w.writer.writeAll(source);
    try plain_w.finish();
    try testing.expect(out.written().len < plain_out.written().len);
    try testing.expectError(
        error.DictionaryRequired,
        decode.decompress(out.written(), buf[0..source.len], null),
    );
    try testing.expectError(
        error.DictionaryMismatch,
        decode.decompress(out.written(), buf[0..source.len], "another dictionary"),
    );

    // An empty dictionary is no dictionary: FDICT stays clear.
    var empty_out: Io.Writer.Allocating = .init(gpa);
    defer empty_out.deinit();
    var empty_buf: Buffer = undefined;
    var empty_w: Writer = .init(&empty_out.writer, &empty_buf, .{ .dict = "" });
    try empty_w.writer.writeAll(source);
    try empty_w.finish();
    try testing.expectEqualSlices(u8, plain_out.written(), empty_out.written());
    try golden.expectHeader(empty_out.written(), .fast);
}

test "Writer: a dictionary round-trips through the streaming layer" {
    // The writer's dictionary becomes the reader's pre-seeded window: the
    // stream's distances reach into it, and the decoder reproduces the source
    // with the same bytes supplied.
    const gpa = testing.allocator;
    const dict = "the quick brown fox jumps over the lazy dog. " ** 3;
    const source = "the quick brown fox jumps over the lazy dog. " ** 8;

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{ .dict = dict });
    try w.writer.writeAll(source);
    try w.finish();

    var in: Io.Reader = .fixed(out.written());
    var target: Io.Writer.Allocating = .init(gpa);
    defer target.deinit();
    try testing.expectEqual(source.len, try zlib_reader.streamAll(&in, &target.writer, dict));
    try testing.expectEqualStrings(source, target.written());
    try testing.expectEqual(out.written().len, in.seek);

    // The same stream without the dictionary: the reader cannot serve the
    // reach.
    var in2: Io.Reader = .fixed(out.written());
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(
        error.ReadFailed,
        zlib_reader.streamAll(&in2, &sink.writer, null),
    );
}
