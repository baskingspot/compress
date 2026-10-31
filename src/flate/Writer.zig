//! flate.Writer: a compressing `Io.Writer` that produces a raw deflate stream
//! (RFC 1951) at level 1 (fixed-Huffman blocks) or level 6
//! (dynamic-Huffman blocks, byte-identical to klauspost/compress's flate at
//! level 6). The caller provides the `Buffer`; nothing is allocated.
//! `streamAll` compresses a whole input in one call.
//!
//! Input accumulates in `Buffer` and is emitted as blocks of up to
//! `max_block_size` bytes when the buffer fills, and on `flush` and `finish`.
//! Matches reach back across block boundaries (`§3.2.3`) into the last 32 KiB
//! of earlier input, which the buffer retains as history.
//!
//! Every stream ends with a final empty fixed block (`03 00` when the data
//! before it ends on a byte boundary). No data block carries BFINAL, so `flush`
//! mid-stream is always safe. The stream is complete only after `finish`.
//!
//! Format: docs/specs/rfc1951-deflate.txt

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;
const math = std.math;
const print = std.debug.print;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
/// The checksum hook's type: a container's state plus its byte-fold function
/// (`Checksum.zig`). It is re-exported here so a container can name it
/// through this namespace (one type across build modules) and assign it to
/// `checksum` before the first write.
pub const Checksum = @import("Checksum.zig");
const decode = @import("decode.zig");
const dynamic = @import("dynamic.zig");
const encode = @import("encode.zig");
const max_block_size = encode.max_block_size;
const history_len = encode.history_len;
const flate_reader = @import("Reader.zig");
const golden = @import("golden.zig");

/// The caller-provided buffer, 98303 bytes: the uncompressed accumulation
/// block (`max_block_size`) plus the retained match history (`history_len`).
/// The history sits at the front and the block after it, so the encoder's
/// window (history followed by block) is one contiguous slice.
pub const Buffer = [max_block_size + history_len]u8;

/// The compressed-output scratch for one block: the exact worst case
/// (`maxCompressedLength(max_block_size)`), so the encoder cannot run out of
/// room.
const scratch_len = encode.maxCompressedLength(max_block_size);

/// The tail scratch for the final empty fixed block: its 10 bits, plus the
/// up-to-15-bit end-of-block code a level-6 stream may still owe, plus the
/// up-to-7 pending bits of the previous block, rounded up to whole bytes.
const ending_len = (7 + 15 + 10 + 7) / 8;

/// The match-finder state, one shape per level class: level 1's single
/// 128-KiB table, or level 6's two-table finder (384 KiB). The union is the
/// larger shape, so a level-1 `Writer` reserves the level-6 tables too.
const Finder = union(enum) {
    l1: encode.FinderTable,
    l6: encode.Finder6,
};

const Writer = @This();

/// The `Io.Writer` interface: write the uncompressed bytes through `&w.writer`.
writer: Io.Writer,
/// The sink the compressed stream is written to.
output: *Io.Writer,
/// The options given to `init`, fixed for the stream's lifetime.
options: encode.Options,
/// Optional checksum hook, handed each emitted block's uncompressed bytes,
/// each byte exactly once and in stream order. A container sets it before the
/// first write: a hook set mid-stream sees only the blocks emitted after it.
/// The container reads its own state after `finish`. Null costs one check per
/// emitted block and nothing per byte. This module writes no trailer.
checksum: ?Checksum = null,
/// The caller's buffer in full: `buffer[0..block_start]` is the retained
/// history (a preset dictionary's tail first, then earlier blocks' bytes),
/// `buffer[block_start..]` the accumulating block. The embedded
/// `Io.Writer`'s own `buffer`/`end` are the block region alone.
buffer: *Buffer,
/// The match-finder state, persistent across the stream's blocks: level 1's
/// table (entries are absolute stream positions, so a block pays a strided
/// priming pass over its history, never a 128-KiB re-zero) or level 6's two
/// tables. Null until the first block that runs the match finder, so a
/// never-emitted stream does not initialize it.
finder: ?Finder = null,
/// Level 6's dynamic-block emitter state: the trees that persist across
/// blocks and the reuse bookkeeping. Unused at level 1.
emitter: dynamic.BlockWriter,
/// True while `finish` emits the stream's final block: the level-6 emitter
/// writes the end-of-block code inline and keeps no table open for it.
finishing: bool,
/// The absolute stream position of `buffer[0]` (wrapping u32, matching the
/// table entries): `compact` advances it by the bytes it drops from the
/// window's front. A preset dictionary's first byte is position 0, so the
/// first output byte is at its length.
window_base: u32,
/// Where the buffered block begins — the history length, since the history
/// is exactly the bytes before the block.
block_start: usize,
/// The stream's pending bits, LSB first (`§3.1.1`), carried across blocks so
/// each block's bits continue at the previous block's bit offset.
bits: u64,
/// Valid bits in `bits` (0-7 between emissions).
bit_count: u6,

/// The shared writer machinery (`src/internal/writer.zig`): the generated
/// `Io.Writer` entries and the poisoned `finish`, over this writer's
/// `emitBlock` and `writeEnding`.
const Hooks = internal.writer.VTable(Writer, emitBlock, writeEnding);

/// Start a deflate stream into `output`, accumulating input in `buffer`.
/// `options` are fixed for the stream's lifetime; changing `w.options`
/// afterwards is not supported. Write through `&w.writer`, then call
/// `finish`.
///
/// `options.dict` is the stream's preset dictionary or `null` (`§3.2.3`): its
/// last 32 KiB are copied into `buffer`'s front as the window's oldest bytes,
/// so the finder can match into them and a distance can reach them. Raw
/// deflate names no dictionary, so the caller vouches for the bytes; zlib's
/// FDICT/DICTID is the checked form (RFC 1950 §2.2).
///
/// Stack: a `Writer` holds the level-6 match-finder tables (384 KiB) and the
/// emitter state, and `Buffer` is 98303 bytes, so place both with that in
/// mind. Each block emission also uses about 320 KiB of stack for its
/// token list and compressed-output scratch.
pub fn init(output: *Io.Writer, buffer: *Buffer, options: encode.Options) Writer {
    // A preset dictionary is the window's oldest bytes: its tail fills the
    // history region in front of the block region, exactly where earlier
    // blocks' bytes sit once the stream has written them (`§3.2.3`).
    const history = decode.dictHistory(options.dict);
    fastmem.copy(u8, buffer[0..history.len], history);
    return .{
        .writer = .{
            .buffer = buffer[history.len..][0..max_block_size],
            .end = 0,
            .vtable = &Hooks.vtable,
        },
        .output = output,
        .buffer = buffer,
        .options = options,
        .emitter = .empty,
        .finishing = false,
        .window_base = 0,
        .block_start = history.len,
        .bits = 0,
        .bit_count = 0,
    };
}

/// Complete the stream: emit the buffered partial block, write the final
/// empty fixed block, and flush `output`. The stream is complete only after
/// this call, and the writer is unusable afterwards.
///
/// Returns `error.WriteFailed` if `output` fails. A writer that already failed
/// or already finished also returns `error.WriteFailed`, so a truncated stream
/// is never reported as complete.
pub fn finish(w: *Writer) Io.Writer.Error!void {
    w.finishing = true;
    return Hooks.finish(w);
}

/// Write the stream's last block: an empty fixed-Huffman block (BFINAL=1,
/// BTYPE=01, end-of-block code) at the stream's current bit offset, then pad
/// to a byte boundary. The one-shot encoder ends its streams with the same
/// bytes, from the same function. A level-6 stream whose last flushed block
/// still owes its end-of-block code writes that code first.
fn writeEnding(w: *Writer) Io.Writer.Error!void {
    var tail: [ending_len]u8 = undefined;
    var bw: encode.BitWriter = .{
        .target = &tail,
        .pos = 0,
        .bits = w.bits,
        .bit_count = w.bit_count,
    };
    if (w.options.level == .@"6") w.emitter.flushEob(&bw) catch unreachable;
    encode.writeFinalEmptyBlock(&bw) catch unreachable;
    bw.finish() catch unreachable;
    w.bits = 0;
    w.bit_count = 0;
    try w.output.writeAll(tail[0..bw.pos]);
}

/// Emit the first `emit_len` bytes of the buffered block as one deflate
/// block, then slide the window past them: the emitted bytes become history,
/// so nothing moves until the block region runs out of room behind
/// `max_block_size` (`compact`). The generated entries in
/// `src/internal/writer.zig` rely on the unemitted tail ending up at the front
/// of the block region (`writer.end -= emit_len`); `rebase`'s preserved tail
/// is that tail. A no-op when `emit_len` is zero.
fn emitBlock(w: *Writer, emit_len: usize) Io.Writer.Error!void {
    assert(emit_len <= w.writer.end);
    if (emit_len == 0) return;
    const block_end = w.block_start + emit_len;
    // The checksum hook: every emitted byte passes through this function
    // (`drain`, `flush`, `rebase`, and `finish` all call it), so the
    // container's state sees the block's uncompressed bytes here, in stream
    // order, exactly once, before the encoder runs and before any slide moves
    // them. Null when unset: one check per emitted block, nothing per byte.
    if (w.checksum) |checksum| checksum.update(w.buffer[w.block_start..block_end]);
    var scratch: [scratch_len]u8 = undefined;
    var bw: encode.BitWriter = .{
        .target = &scratch,
        .pos = 0,
        .bits = w.bits,
        .bit_count = w.bit_count,
    };
    // The finder's window is the block's 32-KiB history followed by the
    // block itself, so a match crosses block boundaries exactly as `§3.2.3`
    // allows.
    if (w.options.level == .@"6") {
        var prime_dict = false;
        if (w.finder == null) {
            w.finder = .{ .l6 = undefined };
            w.finder.?.l6.clear();
            // The window's front is the preset dictionary when a stream
            // starts with one: its length is the block start before the
            // first emission.
            prime_dict = w.block_start > 0;
        }
        const base = w.window_base +% encode.finder_origin;
        encode.compressBlockStream6(
            w.buffer[0..block_end],
            w.block_start,
            block_end,
            &bw,
            &w.finder.?.l6,
            &w.emitter,
            base,
            prime_dict,
            w.finishing,
        ) catch unreachable;
    } else {
        if (w.finder == null) {
            w.finder = .{ .l1 = undefined };
            fastmem.set(u32, &w.finder.?.l1, 0);
        }
        encode.compressBlockStream(
            w.buffer[0..block_end],
            w.block_start,
            block_end,
            &bw,
            &w.finder.?.l1,
            w.window_base,
        ) catch unreachable;
    }
    w.bits = bw.bits;
    w.bit_count = bw.bit_count;
    try w.output.writeAll(scratch[0..bw.pos]);

    w.writer.end -= emit_len;
    w.block_start += emit_len;
    if (w.block_start + max_block_size > w.buffer.len) w.compact();
    w.writer.buffer = w.buffer[w.block_start..][0..max_block_size];
}

/// Slide the history and the buffered block to the front of the window,
/// trimming the history to `history_len`, the farthest a match can reach. The
/// caller re-derives the block region from `block_start`.
fn compact(w: *Writer) void {
    const block_len = w.writer.end;
    const keep = @min(w.block_start, history_len);
    fastmem.move(u8, w.buffer[0..keep], w.buffer[w.block_start - keep ..][0..keep]);
    fastmem.move(u8, w.buffer[keep..][0..block_len], w.buffer[w.block_start..][0..block_len]);
    // The dropped front bytes advance the window's absolute base, keeping
    // the persistent table's stream positions honest.
    w.window_base +%= @as(u32, @truncate(w.block_start - keep));
    w.block_start = keep;
}

// ---------------------------------------------------------------------------
// Tests. Every decode goes through the one-shot decoder (decode.zig), with
// the sentinel overrun rule: the target is pre-filled and the bytes past the
// decoded length must be untouched.
// ---------------------------------------------------------------------------

/// Encode `source` through `Writer`, check the final empty block, decode with
/// the one-shot decoder, expect identity with the sentinel rule enforced
/// (`golden.checkDecode`: exact-cap, then slack, both sentinel-checked).
fn roundTrip(source: []const u8) !void {
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});
    try w.writer.writeAll(source);
    try w.finish();

    try golden.expectFinalEmptyBlock(out.written());

    const target = try gpa.alloc(u8, source.len + sentinel.len);
    defer gpa.free(target);
    try golden.checkDecode(target, out.written(), source);
}

test "Writer: empty input is the final empty block" {
    // Spec: rfc1951-deflate.txt §3.2.3 — "BFINAL is set if and only if this
    // is the last block of the data set". The stream ends with the empty
    // fixed block `03 00`, the same bytes the one-shot `compress("")` emits.
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});
    try w.finish();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x03, 0x00 }, out.written());
}

test "Writer: no data block carries BFINAL" {
    // Spec: rfc1951-deflate.txt §3.2.3 — BFINAL marks the last block. The
    // writer keeps it off every data block and sets it only on the final
    // empty block: the stream's first block header has BFINAL clear, and the
    // stream still decodes.
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});
    try w.writer.writeAll("the quick brown fox jumps over the lazy dog. " ** 40);
    try w.finish();
    try testing.expect(out.written().len > 2);
    try testing.expectEqual(@as(u8, 0), out.written()[0] & 0b1);
    try golden.expectFinalEmptyBlock(out.written());
    try roundTrip("the quick brown fox jumps over the lazy dog. " ** 40);
}

test "Writer: round trips across block boundaries" {
    // The 65535-byte split (`§3.2.4`'s stored LEN cap) and the sizes around
    // it, where the second block's matches may reach back into the first
    // (`§3.2.3`: "the backward distance may cross one or more block
    // boundaries").
    const gpa = testing.allocator;
    const sizes = [_]usize{ 0, 1, 4, 13, 1000, 65534, 65535, 65536, 65537, 131071 };
    for (sizes) |len| {
        inline for (.{ golden.Shape.text, golden.Shape.random, golden.Shape.rle }) |shape| {
            const source = try golden.makeShape(gpa, shape, len);
            defer gpa.free(source);
            roundTrip(source) catch |err| {
                print("FAIL: {s} len {d}\n", .{ @tagName(shape), len });
                return err;
            };
        }
    }
}

test "Writer: blocks are maximal and the split follows the block size" {
    // Full blocks stay maximal: incompressible input cannot beat the stored
    // form, so sixteen exactly-full blocks are stored and the stream is
    // exactly `input + 5 * blocks + 2` bytes, which only holds if the split is
    // exactly `max_block_size`.
    const gpa = testing.allocator;
    const source = try golden.makeShape(gpa, .random, 16 * max_block_size);
    defer gpa.free(source);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});
    try w.writer.writeAll(source);
    try w.finish();
    try testing.expectEqual(source.len + 5 * 16 + 2, out.written().len);

    // The split follows the block size, not the caller's write boundaries: the
    // same bytes in odd-sized chunks produce the same stream. A flush would
    // end a block early; this test makes none.
    var chunked: Io.Writer.Allocating = .init(gpa);
    defer chunked.deinit();
    var w2: Writer = .init(&chunked.writer, &buf, .{});
    var pos: usize = 0;
    var step: usize = 1;
    while (pos < source.len) {
        const n = @min(source.len - pos, step);
        try w2.writer.writeAll(source[pos..][0..n]);
        pos += n;
        step = (step * 3 + 1) % 40_000;
    }
    try w2.finish();
    try testing.expectEqualSlices(u8, out.written(), chunked.written());
    try roundTrip(source);
}

test "Writer: history reaches back across emitted blocks" {
    // A block that is a copy of the tail of the previously emitted bytes is
    // compressible only through the retained history: without it the block is
    // incompressible and costs a stored block (`§3.2.3`).
    const gpa = testing.allocator;
    const copy_from = max_block_size - history_len + 1000;
    const source = try gpa.alloc(u8, max_block_size + (max_block_size - copy_from));
    defer gpa.free(source);
    var rng: DefaultPrng = .init(0xBADD_CAFE);
    for (source[0..max_block_size]) |*b| b.* = rng.random().int(u8);
    fastmem.copy(u8, source[max_block_size..], source[copy_from..max_block_size]);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});
    try w.writer.writeAll(source);
    try w.finish();
    // The first block is incompressible (stored: 65540 bytes); the second is
    // one match of 31768 bytes, so the stream is far below the stored cost of
    // the whole input.
    try testing.expect(out.written().len > 65540);
    try testing.expect(out.written().len < 67000);
    try roundTrip(source);
}

test "Writer: flush mid-stream emits the partial block and stays usable" {
    // `flush` mid-stream emits the buffered partial block and keeps the
    // writer usable. It is always safe, because no data block carries BFINAL.
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});
    try w.writer.writeAll("hello, ");
    try w.writer.flush();
    const first = out.written().len;
    try testing.expect(first > 0);
    try w.writer.writeAll("flate");
    try w.finish();
    try testing.expect(out.written().len > first);
    // Two blocks plus the ending: the flushed partial block is not merged into
    // the later one, and the whole stream still decodes.
    try golden.expectFinalEmptyBlock(out.written());

    const target = try gpa.alloc(u8, 64);
    defer gpa.free(target);
    sentinel.fill(target);
    const n = try decode.decompress(out.written(), target, null);
    try testing.expectEqualStrings("hello, flate", target[0..n]);
    try sentinel.expect(target, n);
}

test "Writer: writableSliceGreedy on a full block emits, never drops" {
    // The `File.Reader` simple-mode stream feeds a Writer through
    // `writableSliceGreedy` + `advance` (a direct write into the block
    // region), which lands on `rebase` when the region is full. `rebase` must
    // free space by emitting the buffered block; discarding it would silently
    // drop a whole block of input.
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});

    // Fill the region exactly, without forcing a drain.
    try w.writer.writeAll("a" ** max_block_size);
    // The direct-slice read: fills the (freshly emitted) whole region.
    const dest = try w.writer.writableSliceGreedy(1);
    try testing.expectEqual(max_block_size, dest.len);
    fastmem.set(u8, dest, 0x62);
    w.writer.advance(dest.len);
    // More writes past the second block, then finish.
    try w.writer.writeAll("c" ** 1000);
    try w.finish();

    const target = try gpa.alloc(u8, 2 * max_block_size + 1000 + sentinel.len);
    defer gpa.free(target);
    sentinel.fill(target);
    const n = try decode.decompress(out.written(), target, null);
    try testing.expectEqual(2 * max_block_size + 1000, n);
    try testing.expectEqual(@as(u8, 'a'), target[0]);
    try testing.expectEqual(@as(u8, 'b'), target[max_block_size]);
    try testing.expectEqual(@as(u8, 'c'), target[2 * max_block_size]);
    try testing.expectEqual(@as(u8, 'c'), target[n - 1]);
    try sentinel.expect(target, n);
}

test "Writer: a stream crossing the 4-GiB window-base wrap round-trips" {
    // The table's entries are absolute wrapping positions; these streams
    // preset window_base near maxInt(u32) so every compact crosses the
    // wrap. The decode asserts correctness, not byte-identity: a
    // zero-initialized slot at base X aliases differently than at base 0.
    const gpa = testing.allocator;
    const bases = [_]u32{
        math.maxInt(u32),
        math.maxInt(u32) - 1,
        math.maxInt(u32) - history_len,
        math.maxInt(u32) - max_block_size,
        math.maxInt(u32) - 200_000,
        math.maxInt(u32) - 400_000,
        0x8000_0000,
    };
    for (bases) |base| {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var buf: Buffer = undefined;
        var w: Writer = .init(&out.writer, &buf, .{});
        w.window_base = base;

        // Mixed input: repeated phrases (long matches that cross compacts)
        // and random runs, with flushes between chunks.
        var rng: DefaultPrng = .init(base);
        const phrase = "the quick brown fox jumps over the lazy dog. ";
        var chunk: [30_000]u8 = undefined;
        var total: usize = 0;
        while (total < 700_000) {
            const phrase_len = (rng.random().uintLessThan(usize, 3)) * 10_000;
            if (phrase_len > 0) {
                var j: usize = 0;
                while (j < phrase_len) : (j += phrase.len) {
                    const n = @min(phrase.len, phrase_len - j);
                    try w.writer.writeAll(phrase[0..n]);
                }
            } else {
                rng.random().bytes(&chunk);
                try w.writer.writeAll(&chunk);
            }
            if (rng.random().uintLessThan(u8, 4) == 0) try w.writer.flush();
            total += phrase_len + chunk.len;
        }
        try w.finish();

        var rbuf: flate_reader.Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(out.written());
        var r = flate_reader.init(&fixed_in, &rbuf, null);
        const got = try r.reader.allocRemaining(gpa, .unlimited);
        defer gpa.free(got);
        try testing.expect(got.len > 0);
    }
}

test "Writer: level 6 round-trips through the stream, dispatch included" {
    // The dynamic-Huffman level through the streaming Writer: random input
    // (the stored rung), a phrase (the dynamic rung), and a run (long
    // matches). The one-shot encoder emits the same bytes for the same
    // input, so the streaming and one-shot layers cannot drift.
    const gpa = testing.allocator;
    const input_len = 3 * max_block_size + 17;
    const input = try gpa.alloc(u8, input_len);
    defer gpa.free(input);
    var rng: DefaultPrng = .init(0x5700D0);
    rng.random().bytes(input);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{ .level = .@"6" });
    try w.writer.writeAll(input);
    try w.finish();
    // Random bytes cannot beat the stored form, so the stream is exactly
    // the bound at level 6.
    try testing.expect(out.written().len <= encode.maxCompressedLength(input_len));

    var d_buf: [input_len + 1]u8 = undefined;
    sentinel.fill(&d_buf);
    const n = try decode.decompress(out.written(), d_buf[0..input_len], null);
    try testing.expectEqualSlices(u8, input, d_buf[0..n]);
    try sentinel.expect(&d_buf, n);

    // The one-shot path emits the identical stream, byte for byte.
    const one_shot = try gpa.alloc(u8, encode.maxCompressedLength(input_len));
    defer gpa.free(one_shot);
    const clen = try encode.compress(input, one_shot, .{ .level = .@"6" });
    try testing.expectEqualSlices(u8, one_shot[0..clen], out.written());
}

test "Writer: a failed or finished writer never reports a false success" {
    // `finish` after a failed write, after `finish`, and writes after
    // `finish` must all report `error.WriteFailed` — a truncated stream must
    // not be reported as complete.
    const gpa = testing.allocator;

    // Finish after a failed write: the write buffers fine (it fits the
    // accumulation block), the emit fails into the full fixed output, and
    // `finish` must report it — twice, not a false success the second time.
    var small: [8]u8 = undefined;
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
    try w2.writer.writeAll("hello, flate");
    try w2.finish();
    try testing.expectError(error.WriteFailed, w2.writer.writeAll("more"));
    try testing.expectError(error.WriteFailed, w2.finish());
    try golden.expectFinalEmptyBlock(out.written());
}

test "Writer: random write machinery sequences stay correct" {
    // Mixed writeSplatAll/writeVecAll/splatBytesAll/writableSliceGreedy+
    // advance/writeByte/flush sequences. This catches drain and rebase
    // accounting errors under the full vtable contract: multi-slice data with
    // splat, partial straddling takes, direct-slice writes onto a full block
    // region.
    const gpa = testing.allocator;
    var rng: DefaultPrng = .init(99);
    const rand = rng.random();

    var iter: usize = 0;
    while (iter < 60) : (iter += 1) {
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
                    // The File.Reader simple-mode path: a direct write into the
                    // block region, which lands on `rebase` when it is full.
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

        // Decode with the one-shot decoder, independent of Reader.
        const target = try gpa.alloc(u8, expect.items.len + sentinel.len);
        defer gpa.free(target);
        sentinel.fill(target);
        const n = try decode.decompress(out.written(), target, null);
        try testing.expectEqual(expect.items.len, n);
        try testing.expectEqualSlices(u8, expect.items, target[0..n]);
        try sentinel.expect(target, n);
    }
}

test "Writer: golden decoded outputs encode to streams the decoder verifies" {
    // Encode each golden `want` through Writer and decode it with the
    // one-shot decoder (the golden-verified path), independent of Reader: the
    // framing must parse and the bytes must reproduce.
    for (golden.stream_cases) |tc| {
        const want = switch (tc.expect) {
            .ok => |bytes| bytes,
            else => continue, // Reject cases have no output.
        };
        roundTrip(want) catch |err| {
            print("\nFAIL: {s}\n", .{tc.desc});
            return err;
        };
    }
    for (golden.micro_cases) |tc| {
        roundTrip(tc.want) catch |err| {
            print("\nFAIL: {s}\n", .{tc.desc});
            return err;
        };
    }
    for (golden.deflate_cases) |tc| {
        roundTrip(tc.want) catch |err| {
            print("\nFAIL: deflateTests input len {d}\n", .{tc.want.len});
            return err;
        };
    }
}

test "Writer: every length and distance code round trips through the stream" {
    // Sweep the encodable space across block boundaries: a pattern repeated
    // at every distance class, then runs of every length — through the
    // streaming Writer and the one-shot decoder.
    const gpa = testing.allocator;
    const source = try gpa.alloc(u8, 200_000);
    defer gpa.free(source);
    var rng: DefaultPrng = .init(0x1234_5678);
    for (source[0..4096]) |*b| b.* = rng.random().int(u8);
    for (4096..source.len) |i| source[i] = source[i - 4096];
    try roundTrip(source);

    for (3..259) |length| {
        const run = try gpa.alloc(u8, length + 1);
        defer gpa.free(run);
        fastmem.set(u8, run, 0x7E);
        try roundTrip(run);
    }
}

test "Writer: the checksum hook folds every emitted byte exactly once, in order" {
    // The hook rides `emitBlock`, which every emitted byte passes through
    // (`drain`, `flush`, `rebase`, and `finish` all call it), so the block's
    // uncompressed bytes reach the container's state in stream order, exactly
    // once. The synthetic fold is order-sensitive: a dropped, doubled, or
    // reordered byte changes the digest. The write mix is the same as the
    // random-machinery test's (multi-slice splat, direct-slice writes onto a
    // full block, flushes), with the hook set.
    const gpa = testing.allocator;
    var rng: DefaultPrng = .init(0x5EED_1234);
    const rand = rng.random();

    var iter: usize = 0;
    while (iter < 40) : (iter += 1) {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var expect: std.ArrayList(u8) = .empty;
        defer expect.deinit(gpa);
        var buf: Buffer = undefined;
        var w: Writer = .init(&out.writer, &buf, .{});
        var digest: golden.TestChecksum = .init;
        w.checksum = digest.hook();

        var ops: usize = 0;
        while (ops < 8) : (ops += 1) {
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
            switch (rand.uintLessThan(u8, 4)) {
                0 => {
                    var data = [_][]const u8{ a[0..a_len], b[0..b_len], pattern[0..p_len] };
                    try w.writer.writeSplatAll(&data, splat);
                    try expect.appendSlice(gpa, a[0..a_len]);
                    try expect.appendSlice(gpa, b[0..b_len]);
                    for (0..splat) |_| try expect.appendSlice(gpa, pattern[0..p_len]);
                },
                1 => {
                    // The File.Reader simple-mode path: a direct write into
                    // the block region, which lands on `rebase` when full.
                    const dest = try w.writer.writableSliceGreedy(1);
                    const n = @min(dest.len, b_len);
                    for (dest[0..n], b[0..n]) |*d, x| d.* = x;
                    w.writer.advance(n);
                    try expect.appendSlice(gpa, b[0..n]);
                },
                2 => {
                    try w.writer.writeAll(b[0..b_len]);
                    try expect.appendSlice(gpa, b[0..b_len]);
                },
                else => {
                    try w.writer.writeByte(pattern[0]);
                    try expect.append(gpa, pattern[0]);
                    if (rand.boolean()) try w.writer.flush();
                },
            }
        }
        try w.finish();

        try testing.expectEqual(golden.TestChecksum.fold(expect.items), digest.value);

        // The hook is observation-only: the stream is the raw module's.
        const target = try gpa.alloc(u8, expect.items.len + sentinel.len);
        defer gpa.free(target);
        sentinel.fill(target);
        const n = try decode.decompress(out.written(), target, null);
        try testing.expectEqual(expect.items.len, n);
        try testing.expectEqualSlices(u8, expect.items, target[0..n]);
        try sentinel.expect(target, n);
    }
}

test "Writer: the checksum hook folds multi-block streams and changes no byte" {
    // Sizes around the 65535-byte split (`§3.2.4`), so the fold crosses block
    // boundaries: `drain` emits whole blocks, `rebase` the front of a partly
    // written one, `finish` the tail. The fold must follow the emission
    // order, and the emitted stream must be byte-identical with and without
    // the hook (the hook is observation-only).
    const gpa = testing.allocator;
    const sizes = [_]usize{ 0, 1, 1000, 65535, 65536, 3 * max_block_size + 17 };
    for (sizes) |len| {
        const source = try golden.makeShape(gpa, .text, len);
        defer gpa.free(source);

        var plain: Io.Writer.Allocating = .init(gpa);
        defer plain.deinit();
        var buf: Buffer = undefined;
        var w: Writer = .init(&plain.writer, &buf, .{});
        try pumpChunked(&w, source);

        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var hooked_buf: Buffer = undefined;
        var w2: Writer = .init(&out.writer, &hooked_buf, .{});
        var digest: golden.TestChecksum = .init;
        w2.checksum = digest.hook();
        try pumpChunked(&w2, source);

        try testing.expectEqual(golden.TestChecksum.fold(source), digest.value);
        try testing.expectEqualSlices(u8, plain.written(), out.written());
    }
}

test "Writer: the checksum hook folds a rebased direct-slice write in order" {
    // `rebase` (the `writableSliceGreedy` path) emits the front of a partly
    // written block and preserves the tail as the block: the fold must cover
    // the emitted front and the later-emitted tail, once each, in order.
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{});
    var digest: golden.TestChecksum = .init;
    w.checksum = digest.hook();

    try w.writer.writeAll("a" ** max_block_size);
    // The direct-slice read: rebase emits the full block region, then hands
    // the whole of it back.
    const dest = try w.writer.writableSliceGreedy(1);
    try testing.expectEqual(max_block_size, dest.len);
    fastmem.set(u8, dest, 0x62);
    w.writer.advance(dest.len);
    try w.writer.writeAll("c" ** 1000);
    try w.finish();

    var expect: [2 * max_block_size + 1000]u8 = undefined;
    fastmem.set(u8, expect[0..max_block_size], 0x61);
    fastmem.set(u8, expect[max_block_size..][0..max_block_size], 0x62);
    fastmem.set(u8, expect[2 * max_block_size ..], 0x63);
    try testing.expectEqual(golden.TestChecksum.fold(&expect), digest.value);
}

/// Write `source` through `w` in 999-byte chunks, flushing after every
/// seventh write, then finish. The chunking is fixed, so two writers fed the
/// same source emit the same blocks.
fn pumpChunked(w: *Writer, source: []const u8) !void {
    var pos: usize = 0;
    var writes: usize = 0;
    while (pos < source.len) {
        const n = @min(source.len - pos, 999);
        try w.writer.writeAll(source[pos..][0..n]);
        pos += n;
        writes += 1;
        if (writes % 7 == 0) try w.writer.flush();
    }
    try w.finish();
}

/// Compress everything `in` yields into one complete raw deflate stream in
/// `out`, and return the number of input bytes consumed. The stream is
/// finished and `out` is flushed before the call returns.
///
/// Returns `error.ReadFailed` if `in` fails, and `error.WriteFailed` if `out`
/// fails.
/// Allocates nothing: the `Writer`, its `Buffer`, and the block scratch are
/// locals on the caller's stack, about 700 KiB at the peak at level 6.
pub fn streamAll(
    in: *Io.Reader,
    out: *Io.Writer,
    options: encode.Options,
) Io.Reader.StreamRemainingError!usize {
    var buf: Buffer = undefined;
    var ww: Writer = .init(out, &buf, options);
    const n = try in.streamRemaining(&ww.writer);
    // The stream is not complete until `finish`, which emits the final partial
    // block and the closing empty block.
    try ww.finish();
    return n;
}

test "Writer: a preset dictionary is the window's oldest bytes" {
    // `§3.2.3` — the writer copies the dictionary's tail into the buffer's
    // front and starts the block region after it, so the finder matches into
    // the dictionary exactly as it matches into an earlier block. The
    // interface's serving region is the block region, after the dictionary.
    const gpa = testing.allocator;
    const dict = "the quick brown fox jumps over the lazy dog. " ** 3;
    const source = "the quick brown fox jumps over the lazy dog. " ** 8;

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{ .level = .@"1", .dict = dict });
    try testing.expectEqual(@as(usize, max_block_size), w.writer.buffer.len);
    try testing.expectEqual(@intFromPtr(&buf[dict.len]), @intFromPtr(w.writer.buffer.ptr));
    try testing.expectEqual(@as(usize, dict.len), w.block_start);

    try w.writer.writeAll(source);
    try w.finish();

    const target = try gpa.alloc(u8, source.len + sentinel.len);
    defer gpa.free(target);
    try golden.checkDecodeDict(target, out.written(), dict, source);
    try golden.expectFinalEmptyBlock(out.written());

    // The stream references the dictionary: without it the reach is past the
    // history.
    sentinel.fill(target);
    try testing.expectError(
        error.InvalidMatch,
        decode.decompress(out.written(), target, null),
    );

    // The one-shot encoder emits the same bytes for the same input: the
    // dictionary is the window's oldest bytes either way.
    const comp = try gpa.alloc(u8, encode.maxCompressedLength(source.len));
    defer gpa.free(comp);
    const clen = try encode.compress(source, comp, .{ .level = .@"1", .dict = dict });
    try testing.expectEqualSlices(u8, comp[0..clen], out.written());

    // An empty dictionary is no dictionary: the same bytes as `.{}`, and the
    // block region starts at the buffer's front.
    var plain: Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    var buf2: Buffer = undefined;
    var w2: Writer = .init(&plain.writer, &buf2, .{ .level = .@"1", .dict = "" });
    try testing.expectEqual(@as(usize, 0), w2.block_start);
    try testing.expectEqual(@intFromPtr(&buf2[0]), @intFromPtr(w2.writer.buffer.ptr));
    try w2.writer.writeAll(source);
    try w2.finish();

    var plainest: Io.Writer.Allocating = .init(gpa);
    defer plainest.deinit();
    var buf3: Buffer = undefined;
    var w3: Writer = .init(&plainest.writer, &buf3, .{});
    try w3.writer.writeAll(source);
    try w3.finish();
    try testing.expectEqualSlices(u8, plainest.written(), plain.written());
}

test "Writer: random call sequences round-trip at both levels" {
    // Random `Io.Writer` call sequences at both levels against a model:
    // writes, direct-slice writes (the `rebase` path), flushes, and bytes,
    // then a decode compared byte for byte with the model. This is the
    // streaming half of the fuzz targets' contract, driven by a fixed PRNG so
    // a regression reproduces. It found the sub-13-byte mid-stream block bug
    // (see `compressBlock6`): a flushed tiny block used to dispatch
    // klauspost's "too small" marker as a real token list.
    const gpa = testing.allocator;
    for (std.enums.values(encode.Level)) |level| {
        var rng: DefaultPrng = .init(0xF00D + @as(u64, @intFromEnum(level)));
        const rand = rng.random();
        var iter: usize = 0;
        while (iter < 200) : (iter += 1) {
            var out: Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            var expect: std.ArrayList(u8) = .empty;
            defer expect.deinit(gpa);
            var buf: Buffer = undefined;
            var w: Writer = .init(&out.writer, &buf, .{ .level = level });
            var ops: usize = 0;
            while (ops < 20) : (ops += 1) {
                var b: [9000]u8 = undefined;
                rand.bytes(&b);
                const n = rand.uintAtMost(usize, b.len);
                switch (rand.uintLessThan(u8, 4)) {
                    0 => {
                        try w.writer.writeAll(b[0..n]);
                        try expect.appendSlice(gpa, b[0..n]);
                    },
                    1 => {
                        // The File.Reader simple-mode path: a direct write
                        // into the block region, which lands on `rebase`.
                        const dest = try w.writer.writableSliceGreedy(1);
                        const k = @min(dest.len, n);
                        fastmem.copy(u8, dest[0..k], b[0..k]);
                        w.writer.advance(k);
                        try expect.appendSlice(gpa, b[0..k]);
                    },
                    2 => try w.writer.flush(),
                    else => {
                        try w.writer.writeByte(b[0]);
                        try expect.append(gpa, b[0]);
                        if (rand.boolean()) try w.writer.flush();
                    },
                }
            }
            try w.finish();

            const target = try gpa.alloc(u8, expect.items.len + sentinel.len);
            defer gpa.free(target);
            sentinel.fill(target);
            const dn = decode.decompress(
                out.written(),
                target[0..expect.items.len],
                null,
            ) catch |err| {
                print("FAIL: level {d} iteration {d}: decode {s}\n", .{
                    level, iter, @errorName(err),
                });
                return err;
            };
            try testing.expectEqual(expect.items.len, dn);
            try testing.expectEqualSlices(u8, expect.items, target[0..dn]);
            try sentinel.expect(target, dn);
        }
    }
}

test "Writer: a flushed tiny block is stored at level 6" {
    // A block under 13 bytes cannot hold a match, and klauspost's finder marks
    // such a block with its token count rather than a token list — a marker
    // only its own close-time path reads. Our `flush` can emit one mid-stream,
    // so the caller writes it as a stored block (`§3.2.4`) instead of
    // dispatching the marker. The bytes round-trip through the one-shot
    // decoder, sentinel-checked.
    const gpa = testing.allocator;
    const data = "abc";
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: Buffer = undefined;
    var w: Writer = .init(&out.writer, &buf, .{ .level = .@"6" });
    try w.writer.writeAll(data[0..1]);
    try w.writer.flush();
    try w.writer.writeAll(data[1..2]);
    try w.writer.flush();
    try w.writer.writeAll(data[2..3]);
    try w.finish();

    const target = try gpa.alloc(u8, data.len + sentinel.len);
    defer gpa.free(target);
    try golden.checkDecode(target, out.written(), data);
}
