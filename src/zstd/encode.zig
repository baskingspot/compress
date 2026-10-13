//! The zstd encoder's one-shot: `compress` writes one frame — the frame
//! header, the block chain, and the XXH64 trailer — into a caller's buffer
//! (`ZSTD_compress`, the CLI's level-1 class). Nothing is allocated; the
//! per-block scratch (the match finder's table, the literals buffer, and the
//! sequence list) is on the stack, and the source itself is the match
//! history, so no window buffer exists (`decode`'s symmetry).
//!
//! The frame declares its exact Frame_Content_Size in the smallest form
//! (`§3.1.1.1.4`) and always carries the checksum (`§3.1.1`); the window is
//! the smallest power of two covering the source, from 1 KiB to 512 KiB, so
//! a source that fits its window is single-segment (`§3.1.1.1.2`).
//!
//! Format: docs/research/specs/rfc8878-zstd.txt §3.1.1 (the frame), §3.1.1.1
//! (the frame header), §3.1.1.2 (the block chain).

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const block = @import("block.zig");
const block_compress = @import("block_compress.zig");
const common = @import("common.zig");
const writeInt = common.writeInt;
const decode = @import("decode.zig");
const frame = @import("frame.zig");
const golden = @import("golden.zig");
const match_compress = @import("match_compress.zig");
const sequences_compress = @import("sequences_compress.zig");

/// The compression level. `.fast` is the CLI's level-1 byte class; `.ratio`
/// is a reserved seat that returns `error.Unimplemented` (the flate
/// pattern — never a silent alias for `.fast`).
pub const Level = enum { fast, ratio };

/// `compress`'s options.
pub const Options = struct {
    level: Level = .fast,
};

/// Everything `compress` reports.
pub const Error = error{
    /// `target` cannot hold the frame. Its contents are then unspecified.
    BufferTooSmall,
    /// The option is not implemented (`Level.ratio`).
    Unimplemented,
};

/// The one-shot's per-block scratch, on the stack: the literals buffer, the
/// sequence list, and the match finder's position table. Sized by the block
/// layer's worst cases, so no allocation is needed (see the README's stack
/// figure).
const Scratch = struct {
    literals: [block_compress.max_block_size]u8 = undefined,
    sequences: [block_compress.max_sequences]sequences_compress.Sequence = undefined,
    hash_table: [block_compress.hash_table_max]u32 = undefined,
};

/// The largest frame `compress` can write for a `source_len`-byte source:
/// the 14-byte header cap, 3 bytes per block, the source itself, and the
/// 4-byte checksum. Always inside the C's `ZSTD_COMPRESSBOUND` (`zstd.h`).
pub fn maxCompressedLength(source_len: usize) usize {
    return source_len + 3 * (source_len / block_compress.max_block_size + 1) + 18;
}

/// Compress `source` into `target` as one Zstandard frame and return the
/// frame's length.
///
/// The frame declares its exact Frame_Content_Size in the smallest form
/// (`§3.1.1.1.4`) and always carries the XXH64 Content_Checksum
/// (`§3.1.1`). The window is the smallest power of two covering the source,
/// from 1 KiB to 512 KiB (`§3.1.1.1.2`); a source of at most 512 KiB fits
/// its window and is single-segment, and a larger one declares a 512 KiB
/// window. No dictionary is ever named, and the output is deterministic: the
/// same source and options produce the same bytes.
///
/// `target` must be at least `maxCompressedLength(source.len)`; a smaller
/// one can still work when the source compresses, and otherwise fails with
/// `error.BufferTooSmall` before writing past `target`. `target`'s contents
/// are unspecified after a failure. Nothing is allocated.
pub fn compress(source: []const u8, target: []u8, options: Options) Error!usize {
    if (options.level != .fast) return error.Unimplemented;
    const params: match_compress.Params = .forSource(source.len);
    var cursor = try writeFrameHeader(source.len, params, target);
    var state: block_compress.State = .{};
    var scratch: Scratch = .{};
    // The finder's table holds frame offsets and starts zeroed; only the
    // ladder's chosen width is touched, as the C zeroes its allocated table
    // width at reset.
    const hash_table = scratch.hash_table[0 .. @as(usize, 1) << @intCast(params.hash_log)];
    fastmem.set(u32, hash_table, 0);
    if (source.len == 0) {
        // `§3.1.1.2` — "Each frame must have at least 1 block": the empty
        // input is one raw 0-size Last_Block, the CLI's 13-byte empty frame.
        if (target.len - cursor < block.block_header_len) return error.BufferTooSmall;
        writeInt(u24, target[cursor..][0..block.block_header_len], 1);
        cursor += block.block_header_len;
    } else {
        var blocks: block_compress.Scratch = .{
            .literals = &scratch.literals,
            .sequences = &scratch.sequences,
        };
        const block_size = block_compress.blockSize(params);
        assert(block_size <= block_compress.max_block_size);
        var offset: usize = 0;
        while (offset < source.len) {
            const size = @min(block_size, source.len - offset);
            cursor += try block_compress.writeBlock(
                &state,
                &blocks,
                params,
                hash_table,
                source,
                offset,
                size,
                target[cursor..],
                offset + size == source.len,
            );
            offset += size;
        }
    }
    // `§3.1.1` — "The low 4 bytes of the checksum are stored in
    // little-endian format": the XXH64 of the decoded bytes, seed zero.
    if (target.len - cursor < frame.checksum_len) return error.BufferTooSmall;
    writeInt(u32, target[cursor..][0..frame.checksum_len], state.checksum.final());
    cursor += frame.checksum_len;
    return cursor;
}

/// `ZSTD_writeFrameHeader` (`zstd_compress.c:4695-4749`): the Magic_Number,
/// the descriptor, the Window_Descriptor (only when the frame is not
/// single-segment), and the exact Frame_Content_Size in its smallest form.
/// The checksum flag is always set and the dictionary flag never is.
fn writeFrameHeader(source_len: usize, params: match_compress.Params, target: []u8) Error!usize {
    if (target.len < frame_header_len_max) return error.BufferTooSmall;
    const window_size: u64 = @as(u64, 1) << params.window_log;
    // `§3.1.1.1.1.2` — "Single_Segment_Flag ... In this case, Window_Size is
    // Frame_Content_Size": set exactly when the source fits the window.
    const single_segment = window_size >= source_len;
    var fcs_code: u2 = 0;
    if (source_len >= 256) fcs_code += 1;
    if (source_len >= 65536 + 256) fcs_code += 1;
    if (source_len >= 0xffff_ffff) fcs_code += 1;
    var cursor: usize = 0;
    writeInt(u32, target[0..frame.magic_len], frame.magic);
    cursor += frame.magic_len;
    const descriptor: u8 = (@as(u8, fcs_code) << 6) |
        (@as(u8, @intFromBool(single_segment)) << 5) |
        frame.descriptor_checksum;
    target[cursor] = descriptor;
    cursor += 1;
    if (!single_segment) {
        // The C writes `(windowLog - 10) << 3`: the exponent in the high
        // five bits, mantissa 0 (`zstd_compress.c:4705,4722`).
        target[cursor] = @as(u8, params.window_log - 10) << 3;
        cursor += 1;
    }
    switch (fcs_code) {
        // `§3.1.1.1.1.1` — "When Frame_Content_Size_Flag is 0,
        // FCS_Field_Size depends on Single_Segment_Flag: if
        // Single_Segment_Flag is set, FCS_Field_Size is 1": a source under
        // 256 bytes always fits its window.
        0 => {
            assert(single_segment);
            target[cursor] = @intCast(source_len);
            cursor += 1;
        },
        // "When FCS_Field_Size is 2, the offset of 256 is added"
        // (`§3.1.1.1.4`).
        1 => {
            writeInt(u16, target[cursor..][0..2], @intCast(source_len - 256));
            cursor += 2;
        },
        2 => {
            writeInt(u32, target[cursor..][0..4], @intCast(source_len));
            cursor += 4;
        },
        else => {
            writeInt(u64, target[cursor..][0..8], source_len);
            cursor += 8;
        },
    }
    assert(cursor <= frame_header_len_max);
    return cursor;
}

/// `ZSTD_FRAMEHEADERSIZE_MAX` (`zstd_compress.c:4695`): the magic, the
/// descriptor, the Window_Descriptor, and the 8-byte Frame_Content_Size
/// form.
const frame_header_len_max = frame.magic_len + 1 + 1 + 8;

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc8878-zstd.txt §3.1.1 (the frame and
// its checksum), §3.1.1.1 (the header's forms), §3.1.1.2 (the block chain),
// §3.1.1.4 (offsets and the window). Every frame is decoded back through
// the landed one-shot decoder and its bytes past the decoded length checked;
// the CLI v1.5.7 verdicts on the recorded fixtures are in `golden.zig`.
// ---------------------------------------------------------------------------

/// One corpus shape, restated from `bench/zig/corpus.zig` so the codec tests
/// pin the same bytes the bench corpus generates (`just corpus`).
const Shape = enum { text, html, rle, random, mixed, skewlit, words, zeros };

fn fillShape(shape: Shape, buf: []u8) void {
    switch (shape) {
        .text => fill(buf, "the quick brown fox jumps over the lazy dog. "),
        .html => fill(buf, "<div class=\"row\"><span>hello</span><span>flate</span></div>"),
        .rle, .zeros => fastmem.set(u8, buf, if (shape == .rle) 0x41 else 0),
        .random => {
            var rng: DefaultPrng = .init(0xC0FFEE);
            for (buf) |*byte| byte.* = rng.random().int(u8);
        },
        .mixed => {
            var rng: DefaultPrng = .init(0x5A4BEEF);
            for (buf, 0..) |*byte, index| {
                byte.* = @truncate(rng.random().int(u8) ^ @as(u8, @truncate(index)));
            }
        },
        .skewlit => {
            var rng: DefaultPrng = .init(0x5CEBE1);
            for (buf) |*byte| {
                const x: u16 = rng.random().int(u8);
                byte.* = @truncate(x * x >> 10);
            }
        },
        .words => {
            var rng: DefaultPrng = .init(0xD1C710);
            var index: usize = 0;
            while (index < buf.len) {
                const word = dictionary[rng.random().uintLessThan(usize, dictionary.len)];
                const length = @min(word.len, buf.len - index);
                fastmem.copy(u8, buf[index..][0..length], word[0..length]);
                index += length;
                if (index < buf.len) {
                    buf[index] = ' ';
                    index += 1;
                }
            }
        },
    }
}

fn fill(buf: []u8, phrase: []const u8) void {
    var index: usize = 0;
    while (index < buf.len) {
        const length = @min(phrase.len, buf.len - index);
        fastmem.copy(u8, buf[index..][0..length], phrase[0..length]);
        index += length;
    }
}

/// The `words` shape's vocabulary, the same 64 words `bench/zig/corpus.zig`
/// pins.
const dictionary = [_][]const u8{
    "the",  "of",    "and",  "a",     "to",    "in",    "is",   "you",
    "that", "it",    "he",   "was",   "for",   "on",    "are",  "as",
    "with", "his",   "they", "at",    "be",    "this",  "have", "from",
    "or",   "one",   "had",  "by",    "word",  "but",   "not",  "what",
    "all",  "were",  "we",   "when",  "your",  "can",   "said", "there",
    "use",  "an",    "each", "which", "she",   "do",    "how",  "their",
    "if",   "will",  "up",   "other", "about", "out",   "many", "then",
    "them", "these", "so",   "some",  "her",   "would", "make", "like",
};

/// Compress `source` into a fresh bound-sized target and decode it back
/// through the landed one-shot, with the sentinel overrun check. Returns the
/// frame's length.
fn expectRoundTrip(source: []const u8) !usize {
    const frame_buffer = try testing.allocator.alloc(u8, maxCompressedLength(source.len));
    defer testing.allocator.free(frame_buffer);
    const written = try compress(source, frame_buffer, .{});
    try testing.expect(written <= frame_buffer.len);
    const plain = try testing.allocator.alloc(u8, source.len);
    defer testing.allocator.free(plain);
    internal.sentinel.fill(plain);
    const decoded = try decode.decompress(frame_buffer[0..written], plain);
    try testing.expectEqual(source.len, decoded);
    try testing.expectEqualSlices(u8, source, plain[0..decoded]);
    try internal.sentinel.expect(plain, decoded);
    return written;
}

test "compress round-trips through the landed decoder" {
    // RFC 8878 §3.1.1 — the frame's decoded output is the source, byte for
    // byte, over every shape and across the parameter ladder's classes: the
    // tiny classes (1 KB and 16 KB windows), the 128-KB and 256-KB classes,
    // and the windowed path above 512 KB.
    var source: [600 * 1024]u8 = undefined;
    const sizes = [_]usize{
        0,      1,      6,      7,      8,      31,     32,     100,
        255,    256,    1024,   4096,   16384,  32768,  65536,  131071,
        131072, 131073, 200000, 262144, 300000, 524288, 524289, 600 * 1024,
    };
    for ([_]Shape{ .text, .rle, .random, .skewlit }) |shape| {
        for (sizes) |size| {
            fillShape(shape, source[0..size]);
            _ = try expectRoundTrip(source[0..size]);
        }
    }
    // The remaining shapes at the ladder's class boundaries.
    for ([_]Shape{ .html, .mixed, .words, .zeros }) |shape| {
        for ([_]usize{ 100, 4096, 65536, 131072, 300000 }) |size| {
            fillShape(shape, source[0..size]);
            _ = try expectRoundTrip(source[0..size]);
        }
    }
}

test "the frame header declares the exact size and the ladder's window" {
    // RFC 8878 §3.1.1.1.1 (the descriptor), §3.1.1.1.2 (the window),
    // §3.1.1.1.4 (the size forms): the exact Frame_Content_Size in its
    // smallest form, single-segment exactly when the source fits the
    // window, and the C's window ladder `min(19, nextPow2(size))` floor 10.
    var source: [600 * 1024]u8 = undefined;
    fillShape(.text, &source);
    const target = try testing.allocator.alloc(u8, maxCompressedLength(source.len));
    defer testing.allocator.free(target);
    const cases = [_]struct { size: usize, descriptor: u8, window_log: u6 }{
        .{ .size = 0, .descriptor = 0x24, .window_log = 10 },
        .{ .size = 1, .descriptor = 0x24, .window_log = 10 },
        .{ .size = 100, .descriptor = 0x24, .window_log = 10 },
        .{ .size = 255, .descriptor = 0x24, .window_log = 10 },
        .{ .size = 256, .descriptor = 0x64, .window_log = 10 },
        .{ .size = 1024, .descriptor = 0x64, .window_log = 10 },
        .{ .size = 1025, .descriptor = 0x64, .window_log = 11 },
        .{ .size = 4096, .descriptor = 0x64, .window_log = 12 },
        .{ .size = 16384, .descriptor = 0x64, .window_log = 14 },
        .{ .size = 32768, .descriptor = 0x64, .window_log = 15 },
        .{ .size = 65536, .descriptor = 0x64, .window_log = 16 },
        .{ .size = 65536 + 256, .descriptor = 0xa4, .window_log = 17 },
        .{ .size = 131072, .descriptor = 0xa4, .window_log = 17 },
        .{ .size = 131073, .descriptor = 0xa4, .window_log = 18 },
        .{ .size = 262144, .descriptor = 0xa4, .window_log = 18 },
        .{ .size = 262145, .descriptor = 0xa4, .window_log = 19 },
        .{ .size = 524288, .descriptor = 0xa4, .window_log = 19 },
        // Above the window: windowed, descriptor 0x84 (checksum and the
        // 4-byte FCS form), a 512 KiB window.
        .{ .size = 524289, .descriptor = 0x84, .window_log = 19 },
        .{ .size = 600 * 1024, .descriptor = 0x84, .window_log = 19 },
    };
    for (cases) |case| {
        const written = try compress(source[0..case.size], target, .{});
        const header = try frame.parseHeader(target[frame.magic_len..][0..written]);
        try testing.expectEqual(case.descriptor, header.descriptor);
        try testing.expectEqual(@as(?u64, case.size), header.content_size);
        // `§3.1.1.1.1.2` — "In this case, Window_Size is Frame_Content_Size":
        // a single-segment frame's window is its size, not the descriptor's
        // window log.
        const expected_window: u64 = if (header.descriptor & frame.descriptor_single_segment != 0)
            case.size
        else
            @as(u64, 1) << case.window_log;
        try testing.expectEqual(expected_window, header.window_size);
        try testing.expect(header.checksum);
        // The window descriptor's exponent, when the frame carries one.
        if (header.descriptor & frame.descriptor_single_segment == 0) {
            const window_byte = target[frame.magic_len + 1];
            try testing.expectEqual(
                @as(u8, case.window_log - 10) << 3,
                window_byte,
            );
        }
    }
}

test "the empty frame is the CLI's 13 bytes" {
    // RFC 8878 §3.1.1.2 — a frame with no input is one raw 0-size
    // Last_Block; the CLI v1.5.7 writes exactly these 13 bytes for empty
    // input (verified with `printf '' | zstd -1 | xxd`).
    var target: [64]u8 = undefined;
    const written = try compress(&.{}, &target, .{});
    try testing.expectEqual(@as(usize, 13), written);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x28, 0xb5, 0x2f, 0xfd, // magic
            0x24, // descriptor: single-segment, checksum
            0x00, // Frame_Content_Size: 0
            0x01, 0x00, 0x00, // raw, last, size 0
            0x99, 0xe9, 0xd8, 0x51, // XXH64("") low 4 bytes, little-endian
        },
        target[0..written],
    );
}

test "maxCompressedLength bounds every emission" {
    // The bound is the raw worst case: the header cap, 3 bytes per 128-KiB
    // block, the source, and the trailer. Incompressible data reaches it;
    // compressible data stays under it.
    try testing.expectEqual(@as(usize, 21), maxCompressedLength(0));
    try testing.expectEqual(@as(usize, 22), maxCompressedLength(1));
    var source: [300 * 1024]u8 = undefined;
    fillShape(.random, &source);
    const bound = maxCompressedLength(source.len);
    const frame_buffer = try testing.allocator.alloc(u8, bound);
    defer testing.allocator.free(frame_buffer);
    const written = try compress(&source, frame_buffer, .{});
    try testing.expect(written <= bound);
    // Three raw blocks (128 KiB, 128 KiB, 44 KiB), a 9-byte header (magic,
    // descriptor, the 4-byte Frame_Content_Size form), the trailer.
    try testing.expectEqual(@as(usize, 300 * 1024 + 3 * 3 + 9 + 4), written);
    // One byte under the raw form's need fails before the last write.
    try testing.expectError(
        error.BufferTooSmall,
        compress(&source, frame_buffer[0 .. written - 1], .{}),
    );
}

test "the level seat is reserved, never aliased" {
    var target: [64]u8 = undefined;
    try testing.expectError(error.Unimplemented, compress(&.{}, &target, .{ .level = .ratio }));
}

test "compress is deterministic" {
    var source: [64 * 1024]u8 = undefined;
    fillShape(.mixed, &source);
    const first = try testing.allocator.alloc(u8, maxCompressedLength(source.len));
    defer testing.allocator.free(first);
    const second = try testing.allocator.alloc(u8, maxCompressedLength(source.len));
    defer testing.allocator.free(second);
    const first_len = try compress(&source, first, .{});
    const second_len = try compress(&source, second, .{});
    try testing.expectEqual(first_len, second_len);
    try testing.expectEqualSlices(u8, first[0..first_len], second[0..second_len]);
}

test "our level-1 frame is the CLI's own bytes" {
    // RFC 8878 §3.1 — the whole emission, header through trailer, for every
    // fixture class: our level-1 frame reproduces the pinned CLI v1.5.7's
    // `zstd -1` bytes exactly, and each CLI frame decodes back through our
    // decoder to the input. The fixture bytes and their verdicts are
    // `golden.zig`'s `encode_*` group.
    var source: [600 * 1024]u8 = undefined;
    const cases = [_]struct {
        name: []const u8,
        shape: Shape,
        size: usize,
        expected: []const u8,
    }{
        .{ .name = "text-100", .shape = .text, .size = 100, .expected = &golden.encode_text_100 },
        .{
            .name = "text-1024",
            .shape = .text,
            .size = 1024,
            .expected = &golden.encode_text_1024,
        },
        .{
            .name = "text-32768",
            .shape = .text,
            .size = 32768,
            .expected = &golden.encode_text_32768,
        },
        .{
            .name = "text-65536",
            .shape = .text,
            .size = 65536,
            .expected = &golden.encode_text_65536,
        },
        .{
            .name = "html-32768",
            .shape = .html,
            .size = 32768,
            .expected = &golden.encode_html_32768,
        },
        .{
            .name = "html-65536",
            .shape = .html,
            .size = 65536,
            .expected = &golden.encode_html_65536,
        },
        .{
            .name = "rle-32768",
            .shape = .rle,
            .size = 32768,
            .expected = &golden.encode_rle_32768,
        },
        .{
            .name = "rle-65536",
            .shape = .rle,
            .size = 65536,
            .expected = &golden.encode_rle_65536,
        },
        .{
            .name = "words-4096",
            .shape = .words,
            .size = 4096,
            .expected = &golden.encode_words_4096,
        },
        .{
            .name = "skewlit-4096",
            .shape = .skewlit,
            .size = 4096,
            .expected = &golden.encode_skewlit_4096,
        },
        .{
            .name = "text-600000",
            .shape = .text,
            .size = 600000,
            .expected = &golden.encode_text_600000,
        },
    };
    for (cases) |case| {
        const input = source[0..case.size];
        fillShape(case.shape, input);
        const target = try testing.allocator.alloc(u8, maxCompressedLength(input.len));
        defer testing.allocator.free(target);
        const written = try compress(input, target, .{});
        try testing.expectEqual(case.expected.len, written);
        try testing.expectEqualSlices(u8, case.expected, target[0..written]);
        // The CLI's frame decodes through our decoder to the input.
        const plain = try testing.allocator.alloc(u8, input.len);
        defer testing.allocator.free(plain);
        internal.sentinel.fill(plain);
        const decoded = try decode.decompress(case.expected, plain);
        try testing.expectEqual(input.len, decoded);
        try testing.expectEqualSlices(u8, input, plain[0..decoded]);
        try internal.sentinel.expect(plain, decoded);
    }
}

test "the emission ladder picks the CLI's block forms" {
    // RFC 8878 §3.1.1.2 — the corpus shapes' block forms: incompressible
    // noise is stored Raw at exactly Block_Size; a one-byte run is a single
    // RLE block after the frame's first; a repeated phrase is one Compressed
    // block. The block headers are read straight off the frames.
    var source: [64 * 1024]u8 = undefined;
    // The rle shape: one RLE block (the first block is never RLE, but the
    // whole 32-KiB block compresses to 4 bytes, so it is Compressed first).
    fillShape(.rle, source[0..32768]);
    const rle_frame = try testing.allocator.alloc(u8, maxCompressedLength(source.len));
    defer testing.allocator.free(rle_frame);
    const rle_len = try compress(source[0..32768], rle_frame, .{});
    const rle_header = try block.parseHeader(rle_frame[headerLenFor(rle_frame, rle_len)..]);
    try testing.expectEqual(block.BlockType.compressed, rle_header.block_type);
    // The random shape: one Raw block at exactly the block size.
    fillShape(.random, source[0..32768]);
    const random_frame = try testing.allocator.alloc(u8, maxCompressedLength(source.len));
    defer testing.allocator.free(random_frame);
    const random_len = try compress(source[0..32768], random_frame, .{});
    const random_offset = headerLenFor(random_frame, random_len);
    const random_header = try block.parseHeader(random_frame[random_offset..]);
    try testing.expectEqual(block.BlockType.raw, random_header.block_type);
    try testing.expectEqual(@as(usize, 32768), random_header.block_size);
    try testing.expect(random_header.last_block);
    // The 600 KB text frame: windowed, eight blocks, the last one last.
    var big: [600 * 1024]u8 = undefined;
    fillShape(.text, &big);
    const big_frame = try testing.allocator.alloc(u8, maxCompressedLength(big.len));
    defer testing.allocator.free(big_frame);
    const big_len = try compress(&big, big_frame, .{});
    var cursor = headerLenFor(big_frame, big_len);
    var blocks: usize = 0;
    while (true) {
        const header = try block.parseHeader(big_frame[cursor..]);
        blocks += 1;
        cursor += block.block_header_len + block.contentLength(header);
        if (header.last_block) break;
    }
    try testing.expectEqual(@as(usize, 5), blocks);
    // The chain ends at the trailer.
    try testing.expectEqual(big_len - frame.checksum_len, cursor);
}

/// The frame header's length, from the parsed descriptor: the magic, the
/// descriptor, the optional Window_Descriptor, and the Frame_Content_Size
/// field (`§3.1.1.1`).
fn headerLenFor(frame_bytes: []const u8, frame_len: usize) usize {
    const header = frame.parseHeader(frame_bytes[frame.magic_len..frame_len]) catch unreachable;
    return frame.magic_len + header.bytes_consumed;
}
