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
//! Format: docs/specs/rfc8878-zstd.txt §3.1.1 (the frame), §3.1.1.1
//! (the frame header), §3.1.1.2 (the block chain).

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const block = @import("block.zig");
const block_compress = @import("block_compress.zig");
const dfast_compress = @import("dfast_compress.zig");
const Dictionary = @import("Dictionary.zig");
const common = @import("common.zig");
const writeInt = common.writeInt;
const decode = @import("decode.zig");
const frame = @import("frame.zig");
const golden = @import("golden.zig");
const literals = @import("literals.zig");
const match_compress = @import("match_compress.zig");
const sequences = @import("sequences.zig");
const sequences_compress = @import("sequences_compress.zig");
const split_compress = @import("split_compress.zig");

/// The compression levels this encoder implements, named by the CLI scale.
/// The tag is the level number, so `@intFromEnum` spells the CLI's value.
pub const Level = enum(u8) {
    /// `ZSTD_fast`, byte-identical to `zstd -1`.
    @"1" = 1,
    /// `ZSTD_dfast`, byte-identical to `zstd -3` up to the 8 MiB job size.
    @"3" = 3,

    /// The level for a CLI-scale number, or `null` when this encoder does not
    /// implement it. Use this at a boundary where the number comes from
    /// outside the type system; a literal needs no conversion.
    pub fn fromInt(number: u8) ?Level {
        return std.enums.fromInt(Level, number);
    }
};

/// `compress`'s options.
// ast-grep-ignore: public-struct-field-default -- options bag: call sites override one knob
pub const Options = struct {
    /// The compression level. Only the levels in `Level` are representable.
    level: Level = .@"1",
    /// The dictionary the frame is compressed against (`§5`): its tables seed
    /// the frame's entropy state (with `ZSTD_loadCEntropy`'s promotions) and
    /// its content is the match region's virtual past. The frame names the
    /// dictionary's ID in its header (`§3.1.1.1.1.6`). `null` is a
    /// no-dictionary frame.
    dict: ?*const Dictionary = null,
};

/// Everything `compress` reports.
pub const Error = error{
    /// `target` cannot hold the frame. Its contents are then unspecified.
    BufferTooSmall,
};

/// The one-shot's heavy per-block arrays: the literals buffer, the sequence
/// list, and the match finder's position tables (the long one, and dfast's
/// small one). Sized by the block layer's worst cases, so no allocation is
/// needed. `compress` puts one on the stack, about 1.5 MiB in all;
/// `compressBuffered` takes a pointer to one the caller owns, which keeps
/// that stack out of the caller's thread.
pub const Buffer = struct {
    literals: [block_compress.max_block_size]u8 = undefined,
    sequences: [block_compress.max_sequences]sequences_compress.Sequence = undefined,
    long_table: [dfast_compress.long_table_entries_max]u32 = undefined,
    small_table: [dfast_compress.small_table_entries_max]u32 = undefined,
};

/// `ZSTDMT_JOBSIZE_MIN` (`zstdmt_compress.h:33`): a source at or below it
/// never enters the multithreaded path, so the CLI's file form reads it in
/// `ZSTD_CStreamInSize` chunks instead of job-sized ones.
const zstdmt_jobsize_min = 512 * 1024;

/// The largest frame `compress` can write for a `source_len`-byte source:
/// the 18-byte header cap (the 14 no-dictionary bytes plus the 4-byte
/// Dictionary_ID field, `§3.1.1.1.1.6`), 3 bytes per block, the source
/// itself, and the 4-byte checksum. Always inside the C's
/// `ZSTD_COMPRESSBOUND` (`zstd.h`).
pub fn maxCompressedLength(source_len: usize) usize {
    return source_len + 3 * (source_len / block_compress.max_block_size + 1) + 22;
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
/// `error.BufferTooSmall` before writing past `target`. On success only the
/// first `n` bytes are the frame: an abandoned entropy attempt leaves
/// scratch bytes past `n`, so do not assume `target[n..]` was untouched.
/// `target`'s contents are unspecified after a failure. Nothing is allocated.
pub fn compress(source: []const u8, target: []u8, options: Options) Error!usize {
    // The convenience form: the heavy per-block arrays ride this frame, so
    // give encoding threads 1 MiB or more of stack (the README's figure).
    // `compressBuffered` is the same encoder over a caller-owned `Buffer`.
    var buffer: Buffer = .{};
    return compressBuffered(source, target, &buffer, options);
}

/// `compress` over a caller-owned `Buffer` instead of the stack: the
/// literals buffer, the sequence list, and the match finder's table live in
/// `buffer` (768 KiB), so this form needs only the entropy writers' KiB-scale
/// scratch of thread stack (about 64 KiB). The frame is
/// the same, byte for byte; `buffer`'s contents are unspecified after the
/// call.
pub fn compressBuffered(
    source: []const u8,
    target: []u8,
    buffer: *Buffer,
    options: Options,
) Error!usize {
    const level: u8 = @intFromEnum(options.level);
    // The dictionary's shape: which scan the frame runs and how its
    // parameters are sized (the C's `ZSTD_shouldAttachDict` switch,
    // `zstd_compress.c:2309-2323`). An empty content attaches nothing and
    // matches nothing, but the frame still names the dictionary and seeds
    // its entropy state — the C's `cdictLen == 0` carve-out.
    var dict: block_compress.Dict = .empty;
    const params: match_compress.Params = if (options.dict) |d| p: {
        if (d.content.len == 0) break :p .forSource(level, source.len);
        const dict_params = d.matchParams(level);
        if (source.len <= match_compress.attachCutoff(level)) {
            dict = .{
                .content = d.content,
                .table = if (level == 1) &d.match else null,
                .dfast = if (level == 3) &d.match_dfast else null,
                .window_size = 0,
                .frame_start = 0,
                .low_limit = d.content.len,
                .dict_limit = d.content.len,
                .valid = true,
            };
            break :p match_compress.forSourceAttached(level, source.len, dict_params);
        }
        // The copy path: the frame's own tables start as the dictionary's
        // (`copyDictTable`/`copyDictTables` below), and the content runs as
        // the window's extDict, whose addressable span the block loop's
        // arithmetic narrows as the output grows.
        dict = .{
            .content = d.content,
            .table = null,
            .dfast = null,
            .window_size = 0,
            .frame_start = 0,
            .low_limit = 0,
            .dict_limit = d.content.len,
            .valid = true,
        };
        break :p match_compress.forSourceCopied(level, source.len, d.source_len, dict_params);
    } else .forSource(level, source.len);
    const window_size: usize = @as(usize, 1) << @intCast(params.window_log);
    dict.window_size = window_size;
    var cursor = try writeFrameHeader(source.len, params, options.dict, target);
    var state: block_compress.State = .init;
    if (options.dict) |d| block_compress.seedFromDict(&state, d);
    // The finder's tables hold frame offsets and start zeroed; only the
    // ladder's chosen widths are touched, as the C zeroes its allocated table
    // width at reset. The copy path instead starts from the dictionary's own
    // tables, tags stripped (`ZSTD_copyCDictTableIntoCCtx`): their entries are
    // the content's positions, and the scan writes the frame's over them.
    const tables: block_compress.Tables = .{
        .long = buffer.long_table[0 .. @as(usize, 1) << @intCast(params.hash_log)],
        .small = if (level == 3)
            buffer.small_table[0 .. @as(usize, 1) << @intCast(params.chain_log)]
        else
            &.{},
    };
    if (dict.content.len > 0 and dict.table == null and dict.dfast == null) {
        const d = options.dict.?;
        if (level == 3) {
            dfast_compress.copyDictTables(tables.long, tables.small, &d.match_dfast);
        } else {
            match_compress.copyDictTable(tables.long, &d.match);
        }
    } else {
        fastmem.set(u32, tables.long, 0);
        if (tables.small.len > 0) fastmem.set(u32, tables.small, 0);
    }
    if (source.len == 0) {
        // `§3.1.1.2` — "Each frame must have at least 1 block": the empty
        // input is one raw 0-size Last_Block, the CLI's 13-byte empty frame.
        if (target.len - cursor < block.block_header_len) return error.BufferTooSmall;
        writeInt(u24, target[cursor..][0..block.block_header_len], 1);
        cursor += block.block_header_len;
    } else {
        var blocks: block_compress.Scratch = .{
            .literals = &buffer.literals,
            .sequences = &buffer.sequences,
        };
        const block_size = block_compress.blockSize(params);
        assert(block_size <= block_compress.max_block_size);
        const header_len = cursor;
        // The C's `savings` (`zstd_compress.c:4602,4837`): the frame's input
        // consumed minus its output produced, the header counted with the
        // first block. It is the pre-splitter's gate (only the dfast level
        // splits; see `split_compress`).
        var savings: i64 = 0;
        // The finder's table holds positions relative to `base`, and `find`
        // sees `source[base..]`. The base slides when the block start drifts
        // a whole window past it — the Writer's `compact` condition — so no
        // position ever exceeds the window plus one block, and a source over
        // 4 GiB cannot overflow the table's `u32` entries (the C's own
        // window rebase, `ZSTD_window_correctOverflow`, on its one-shot
        // path). The emitted offsets are differences, so the slide changes
        // no byte of the frame.
        var base: usize = 0;
        var offset: usize = 0;
        // The CLI's file form reaches `ZSTD_compress_frameChunk` in chunks,
        // and the pre-splitter's `remaining` is the chunk's, not the frame's
        // (`ZSTD_optimalBlockSize`'s `srcSize` gate). A source at or below
        // `ZSTDMT_JOBSIZE_MIN` (512 KB) runs the single-thread path, whose
        // chunks are `ZSTD_CStreamInSize` = 128 KB (`fileio.c`'s read pool);
        // a larger one runs the multithreaded path even with one job, and
        // that path compresses each job in chunks of `4 * ZSTD_BLOCKSIZE_MAX`
        // = 512 KB (`zstdmt_compress.c:765`). Both agree with the library
        // one-shot whenever no split fires, and the pin is the CLI's file
        // form.
        const chunk_size = if (source.len <= zstdmt_jobsize_min)
            block_compress.max_block_size
        else
            4 * block_compress.max_block_size;
        while (offset < source.len) {
            const chunk_end = @min(offset + chunk_size, source.len);
            while (offset < chunk_end) {
                const size = split_compress.optimalBlockSize(
                    level,
                    source[base..],
                    offset - base,
                    chunk_end - offset,
                    block_size,
                    savings,
                );
                if (offset - base > window_size) {
                    const slide = offset - base - window_size;
                    base += slide;
                    block_compress.rebaseTable(tables, slide);
                }
                const written = try block_compress.writeBlock(
                    &state,
                    &dict,
                    &blocks,
                    params,
                    tables,
                    source[base..],
                    offset - base,
                    size,
                    target[cursor..],
                    offset + size == source.len,
                );
                cursor += written;
                savings += @as(i64, @intCast(size)) -
                    @as(i64, @intCast(written + if (offset == 0) header_len else 0));
                offset += size;
            }
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
/// single-segment), the Dictionary_ID in its smallest 1/2/4-byte form
/// (`§3.1.1.1.1.6`; nothing when the dictionary has no ID), and the exact
/// Frame_Content_Size in its smallest form. The checksum flag is always set.
fn writeFrameHeader(
    source_len: usize,
    params: match_compress.Params,
    dict: ?*const Dictionary,
    target: []u8,
) Error!usize {
    if (target.len < frame_header_len_max) return error.BufferTooSmall;
    const window_size: u64 = @as(u64, 1) << params.window_log;
    // `§3.1.1.1.1.2` — "Single_Segment_Flag ... In this case, Window_Size is
    // Frame_Content_Size": set exactly when the source fits the window.
    const single_segment = window_size >= source_len;
    const dict_id: u32 = if (dict) |d| d.id else 0;
    // `dictIDSizeCodeLength = (dictID>0) + (dictID>=256) + (dictID>=65536)`.
    const dict_id_code: u2 = @intFromBool(dict_id > 0) +
        @as(u2, @intFromBool(dict_id >= 256)) +
        @as(u2, @intFromBool(dict_id >= 65536));
    var fcs_code: u2 = 0;
    if (source_len >= 256) fcs_code += 1;
    if (source_len >= 65536 + 256) fcs_code += 1;
    if (source_len >= 0xffff_ffff) fcs_code += 1;
    var cursor: usize = 0;
    writeInt(u32, target[0..frame.magic_len], frame.magic);
    cursor += frame.magic_len;
    const descriptor: u8 = (@as(u8, fcs_code) << 6) |
        (@as(u8, @intFromBool(single_segment)) << 5) |
        (@as(u8, dict_id_code)) |
        frame.descriptor_checksum;
    target[cursor] = descriptor;
    cursor += 1;
    if (!single_segment) {
        // The C writes `(windowLog - 10) << 3`: the exponent in the high
        // five bits, mantissa 0 (`zstd_compress.c:4705,4722`).
        target[cursor] = frame.window.descriptor(params.window_log);
        cursor += 1;
    }
    switch (dict_id_code) {
        0 => {},
        1 => {
            target[cursor] = @truncate(dict_id);
            cursor += 1;
        },
        2 => {
            writeInt(u16, target[cursor..][0..2], @truncate(dict_id));
            cursor += 2;
        },
        else => {
            writeInt(u32, target[cursor..][0..4], dict_id);
            cursor += 4;
        },
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
/// descriptor, the Window_Descriptor, the 4-byte Dictionary_ID form, and the
/// 8-byte Frame_Content_Size form. `writeFrameHeader` gates on it, as the C
/// does on `ZSTD_FRAMEHEADERSIZE_MAX`.
pub const frame_header_len_max = frame.magic_len + 1 + 1 + 4 + 8;

// ---------------------------------------------------------------------------
// Tests. Spec: docs/specs/rfc8878-zstd.txt §3.1.1 (the frame and
// its checksum), §3.1.1.1 (the header's forms), §3.1.1.2 (the block chain),
// §3.1.1.4 (offsets and the window). Every frame is decoded back through
// the landed one-shot decoder and its bytes past the decoded length checked;
// the CLI v1.5.7 verdicts on the recorded fixtures are in `golden.zig`.
// ---------------------------------------------------------------------------

/// Compress `source` against `dict` and decode it back through the landed
/// one-shot with the same dictionary, sentinel-checked (`§5`'s tables seed
/// the decoder, so a frame this package's decoder rejects is malformed whatever the
/// CLI says). Returns the frame's length.
fn expectDictRoundTrip(dict: *const Dictionary, source: []const u8) !usize {
    const frame_buffer = try testing.allocator.alloc(u8, maxCompressedLength(source.len));
    defer testing.allocator.free(frame_buffer);
    const written = try compress(source, frame_buffer, .{ .level = .@"1", .dict = dict });
    try testing.expect(written <= frame_buffer.len);
    const plain = try testing.allocator.alloc(u8, source.len);
    defer testing.allocator.free(plain);
    internal.sentinel.fill(plain);
    const decoded = try decode.decompress(frame_buffer[0..written], plain, dict);
    try testing.expectEqual(source.len, decoded);
    try testing.expectEqualSlices(u8, source, plain[0..decoded]);
    try internal.sentinel.expect(plain, decoded);
    return written;
}

/// The first Compressed_Block's sections of a frame (`§3.1.1.2`): the
/// literals block type and the three sequence modes, for the byte-class pins.
const FirstBlock = struct {
    literals_type: literals.BlockType,
    modes: sequences.Modes,
};

/// Walk to the frame's first Compressed_Block and read its section headers.
fn firstBlock(frame_bytes: []const u8, frame_len: usize) !FirstBlock {
    const header = try frame.parseHeader(frame_bytes[frame.magic_len..frame_len]);
    var cursor = frame.magic_len + header.bytes_consumed;
    while (true) {
        const block_header = try block.parseHeader(frame_bytes[cursor..frame_len]);
        cursor += block.block_header_len;
        const content = frame_bytes[cursor..][0..block.contentLength(block_header)];
        if (block_header.block_type == .compressed) {
            const literals_header = try literals.parseHeader(content);
            // The sequences section follows the literals section's own
            // content (`§3.1.1.3.1.1`): the regenerated size for Raw, the
            // one content byte for RLE, the Compressed_Size for the
            // compressed family.
            const literals_len = switch (literals_header.block_type) {
                .raw => literals_header.header_len + literals_header.regenerated_size,
                .rle => literals_header.header_len + 1,
                .compressed, .treeless => literals_header.header_len +
                    literals_header.compressed_size,
            };
            const sequences_header = try sequences.parseHeader(content[literals_len..]);
            return .{
                .literals_type = literals_header.block_type,
                .modes = sequences_header.modes.?,
            };
        }
        cursor += content.len;
    }
}

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
    const decoded = try decode.decompress(frame_buffer[0..written], plain, null);
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
    for ([_]golden.Shape{ .text, .rle, .random, .skewlit }) |shape| {
        for (sizes) |size| {
            golden.fillShape(shape, source[0..size]);
            _ = try expectRoundTrip(source[0..size]);
        }
    }
    // The remaining shapes at the ladder's class boundaries.
    for ([_]golden.Shape{ .html, .mixed, .words, .zeros }) |shape| {
        for ([_]usize{ 100, 4096, 65536, 131072, 300000 }) |size| {
            golden.fillShape(shape, source[0..size]);
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
    golden.fillShape(.text, &source);
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
    // The bound is the raw worst case: the header cap (the 18 bytes a
    // dictionary frame's header can take), 3 bytes per 128-KiB block, the
    // source, and the trailer. Incompressible data reaches it; compressible
    // data stays under it.
    try testing.expectEqual(@as(usize, 25), maxCompressedLength(0));
    try testing.expectEqual(@as(usize, 26), maxCompressedLength(1));
    var source: [300 * 1024]u8 = undefined;
    golden.fillShape(.random, &source);
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

test "level 3 round-trips through the landed decoder" {
    // RFC 8878 §3.1.1 — the dfast class's frames decode to the source, byte
    // for byte, over every shape and across the parameter ladder's classes:
    // the mls-4 tiny classes, the 128-KB and 256-KB classes, and the
    // windowed path above 512 KB.
    var source: [600 * 1024]u8 = undefined;
    const sizes = [_]usize{
        0,      1,      6,      7,      8,      31,     32,     100,
        255,    256,    1024,   4096,   16384,  32768,  65536,  131071,
        131072, 131073, 200000, 262144, 300000, 524288, 524289, 600 * 1024,
    };
    for ([_]golden.Shape{ .text, .rle, .random, .skewlit }) |shape| {
        for (sizes) |size| {
            golden.fillShape(shape, source[0..size]);
            const frame_buffer = try testing.allocator.alloc(
                u8,
                maxCompressedLength(size),
            );
            defer testing.allocator.free(frame_buffer);
            const written = try compress(source[0..size], frame_buffer, .{
                .level = .@"3",
            });
            const plain = try testing.allocator.alloc(u8, size);
            defer testing.allocator.free(plain);
            internal.sentinel.fill(plain);
            const decoded = try decode.decompress(frame_buffer[0..written], plain, null);
            try testing.expectEqual(size, decoded);
            try testing.expectEqualSlices(u8, source[0..size], plain[0..decoded]);
            try internal.sentinel.expect(plain, decoded);
        }
    }
    for ([_]golden.Shape{ .html, .mixed, .words, .zeros }) |shape| {
        for ([_]usize{ 100, 4096, 65536, 131072, 300000 }) |size| {
            golden.fillShape(shape, source[0..size]);
            const frame_buffer = try testing.allocator.alloc(
                u8,
                maxCompressedLength(size),
            );
            defer testing.allocator.free(frame_buffer);
            const written = try compress(source[0..size], frame_buffer, .{
                .level = .@"3",
            });
            const plain = try testing.allocator.alloc(u8, size);
            defer testing.allocator.free(plain);
            internal.sentinel.fill(plain);
            const decoded = try decode.decompress(frame_buffer[0..written], plain, null);
            try testing.expectEqual(size, decoded);
            try testing.expectEqualSlices(u8, source[0..size], plain[0..decoded]);
            try internal.sentinel.expect(plain, decoded);
        }
    }
}

test "our level-3 frame is the CLI's own bytes" {
    // RFC 8878 §3.1 — the whole emission, header through trailer, for every
    // fixture class: our level-3 (dfast) frame reproduces the pinned CLI
    // v1.5.7's `zstd -3` bytes exactly, and each CLI frame decodes back
    // through our decoder to the input. The fixture bytes and their verdicts
    // are `golden.zig`'s `encode3_*` group. The set straddles every
    // `clevels.h` size class: the mls-4 tiny and 128-256-KB rows, the
    // mls-5 16-128-KB and default rows.
    var source: [600 * 1024]u8 = undefined;
    const cases = [_]struct {
        name: []const u8,
        shape: golden.Shape,
        size: usize,
        expected: []const u8,
    }{
        .{ .name = "text-100", .shape = .text, .size = 100, .expected = &golden.encode3_text_100 },
        .{
            .name = "text-1024",
            .shape = .text,
            .size = 1024,
            .expected = &golden.encode3_text_1024,
        },
        .{
            .name = "text-32768",
            .shape = .text,
            .size = 32768,
            .expected = &golden.encode3_text_32768,
        },
        .{
            .name = "html-32768",
            .shape = .html,
            .size = 32768,
            .expected = &golden.encode3_html_32768,
        },
        .{
            .name = "rle-32768",
            .shape = .rle,
            .size = 32768,
            .expected = &golden.encode3_rle_32768,
        },
        .{
            .name = "words-4096",
            .shape = .words,
            .size = 4096,
            .expected = &golden.encode3_words_4096,
        },
        .{
            .name = "skewlit-4096",
            .shape = .skewlit,
            .size = 4096,
            .expected = &golden.encode3_skewlit_4096,
        },
        .{
            .name = "rle-133005",
            .shape = .rle,
            .size = 133005,
            .expected = &golden.encode3_rle_133005,
        },
        .{
            .name = "text-600000",
            .shape = .text,
            .size = 600000,
            .expected = &golden.encode3_text_600000,
        },
    };
    for (cases) |case| {
        const input = source[0..case.size];
        golden.fillShape(case.shape, input);
        const target = try testing.allocator.alloc(u8, maxCompressedLength(input.len));
        defer testing.allocator.free(target);
        const written = try compress(input, target, .{ .level = .@"3" });
        try testing.expectEqual(case.expected.len, written);
        try testing.expectEqualSlices(u8, case.expected, target[0..written]);
        // The CLI's frame decodes through our decoder to the input.
        const plain = try testing.allocator.alloc(u8, input.len);
        defer testing.allocator.free(plain);
        internal.sentinel.fill(plain);
        const decoded = try decode.decompress(case.expected, plain, null);
        try testing.expectEqual(input.len, decoded);
        try testing.expectEqualSlices(u8, input, plain[0..decoded]);
        try internal.sentinel.expect(plain, decoded);
    }
}

test "the level-3 pre-splitter cuts a full block at a chunk boundary" {
    // The dfast class's pre-block splitter (`split_compress`, the C's
    // `ZSTD_optimalBlockSize` over `ZSTD_splitBlock_byChunks`): once a frame
    // has saved at least 3 bytes, a full 128-KiB block whose byte fingerprints
    // change partway through is cut at an 8-KiB chunk boundary, so the frame
    // carries more blocks than the block size alone implies. This input is a
    // compressible first block (so the savings gate opens), then one full
    // block of an RLE run followed by random bytes: the regime change at
    // 64 KiB is the split point. The CLI's own `zstd -3` frame splits there
    // too (the `just zstd-oracle` lane pins the bytes).
    var source: [3 * block_compress.max_block_size]u8 = undefined;
    const total = 131072 + 65536 + 65536 + 1000;
    golden.fillShape(.text, source[0..131072]);
    fastmem.set(u8, source[131072..][0..65536], 0x41);
    golden.fillShape(.random, source[196608..][0..65536]);
    fastmem.copy(u8, source[262144..][0..1000], source[0..1000]);
    const target = try testing.allocator.alloc(u8, maxCompressedLength(total));
    defer testing.allocator.free(target);
    const written = try compress(source[0..total], target, .{ .level = .@"3" });
    var cursor = headerLenFor(target, written);
    var blocks: usize = 0;
    var split_seen = false;
    while (true) {
        const header = try block.parseHeader(target[cursor..]);
        blocks += 1;
        if (header.block_size == 65536) split_seen = true;
        cursor += block.block_header_len + block.contentLength(header);
        if (header.last_block) break;
    }
    try testing.expectEqual(written - frame.checksum_len, cursor);
    // The 128-KiB block was cut at the 64-KiB regime change: the frame has
    // more blocks than the block size alone would produce (three full blocks
    // and the tail here), and one of them is the 64-KiB piece.
    try testing.expect(split_seen);
    try testing.expect(blocks > total / block_compress.max_block_size);
    // The frame still decodes to the source.
    const plain = try testing.allocator.alloc(u8, total);
    defer testing.allocator.free(plain);
    internal.sentinel.fill(plain);
    const decoded = try decode.decompress(target[0..written], plain, null);
    try testing.expectEqual(total, decoded);
    try testing.expectEqualSlices(u8, source[0..total], plain[0..decoded]);
    try internal.sentinel.expect(plain, decoded);
}

test "compress round-trips at level 3 with a dictionary, both match-region shapes" {
    // RFC 8878 §5 — the dictionary is virtual past at level 3 too: the attach
    // path (a source at or below the 16-KiB dfast cutoff) and the copy path
    // (a larger source, its tables copied into the frame's own).
    const trained = try Dictionary.parse(golden.dict_trained);
    const raw = Dictionary.initRaw(golden.dict_trained[115..]);
    var source: [600 * 1024]u8 = undefined;
    const sizes = [_]usize{
        0,      1,      6,          7,    8,     31,    100,   255,
        256,    1024,   4096,       8192, 16384, 16385, 65536, 131072,
        300000, 524289, 600 * 1024,
    };
    for ([_]golden.Shape{ .text, .rle, .random, .skewlit }) |shape| {
        for (sizes) |size| {
            golden.fillShape(shape, source[0..size]);
            const frame_buffer = try testing.allocator.alloc(
                u8,
                maxCompressedLength(size),
            );
            defer testing.allocator.free(frame_buffer);
            const written = try compress(source[0..size], frame_buffer, .{
                .level = .@"3",
                .dict = &trained,
            });
            const plain = try testing.allocator.alloc(u8, size);
            defer testing.allocator.free(plain);
            internal.sentinel.fill(plain);
            const decoded = try decode.decompress(frame_buffer[0..written], plain, &trained);
            try testing.expectEqual(size, decoded);
            try testing.expectEqualSlices(u8, source[0..size], plain[0..decoded]);
            try internal.sentinel.expect(plain, decoded);
        }
    }
    // A raw dictionary: content only, no entropy tables, the default
    // repcodes, no ID.
    for ([_]usize{ 0, 100, 16385, 300000 }) |size| {
        golden.fillShape(.text, source[0..size]);
        const frame_buffer = try testing.allocator.alloc(u8, maxCompressedLength(size));
        defer testing.allocator.free(frame_buffer);
        const written = try compress(source[0..size], frame_buffer, .{
            .level = .@"3",
            .dict = &raw,
        });
        const header = try frame.parseHeader(frame_buffer[frame.magic_len..written]);
        try testing.expectEqual(@as(?u32, null), header.dictionary_id);
        const plain = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(plain);
        internal.sentinel.fill(plain);
        const decoded = try decode.decompress(frame_buffer[0..written], plain, &raw);
        try testing.expectEqual(size, decoded);
        try testing.expectEqualSlices(u8, source[0..size], plain[0..decoded]);
        try internal.sentinel.expect(plain, decoded);
    }
}

test "the level-3 with-dictionary frames are the CLI's own bytes" {
    // RFC 8878 §3.1 + §5 — the whole emission with a dictionary at level 3:
    // our frame reproduces the pinned CLI v1.5.7's
    // `zstd -D dict-trained.bin -3` bytes exactly on every corpus shape, and
    // each CLI frame decodes back through our decoder with the dictionary.
    // The fixtures and their CLI verdicts are `golden.zig`'s `dict3_encode_*`
    // group; the 16-KiB pair brackets dfast's attach/copy switch.
    const trained = try Dictionary.parse(golden.dict_trained);
    var source: [600 * 1024]u8 = undefined;
    const cases = [_]struct {
        name: []const u8,
        shape: golden.Shape,
        size: usize,
        expected: []const u8,
    }{
        .{
            .name = "text-100",
            .shape = .text,
            .size = 100,
            .expected = &golden.dict3_encode_text_100,
        },
        .{
            .name = "text-8192",
            .shape = .text,
            .size = 8192,
            .expected = &golden.dict3_encode_text_8192,
        },
        .{
            .name = "text-16385",
            .shape = .text,
            .size = 16385,
            .expected = &golden.dict3_encode_text_16385,
        },
        .{
            .name = "html-65536",
            .shape = .html,
            .size = 65536,
            .expected = &golden.dict3_encode_html_65536,
        },
        .{
            .name = "rle-133005",
            .shape = .rle,
            .size = 133005,
            .expected = &golden.dict3_encode_rle_133005,
        },
        .{
            .name = "words-4096",
            .shape = .words,
            .size = 4096,
            .expected = &golden.dict3_encode_words_4096,
        },
    };
    for (cases) |case| {
        const input = source[0..case.size];
        golden.fillShape(case.shape, input);
        const target = try testing.allocator.alloc(u8, maxCompressedLength(input.len));
        defer testing.allocator.free(target);
        const written = try compress(input, target, .{ .level = .@"3", .dict = &trained });
        try testing.expectEqual(case.expected.len, written);
        try testing.expectEqualSlices(u8, case.expected, target[0..written]);
        const plain = try testing.allocator.alloc(u8, input.len);
        defer testing.allocator.free(plain);
        internal.sentinel.fill(plain);
        const decoded = try decode.decompress(case.expected, plain, &trained);
        try testing.expectEqual(input.len, decoded);
        try testing.expectEqualSlices(u8, input, plain[0..decoded]);
        try internal.sentinel.expect(plain, decoded);
    }
}

test "compress is deterministic" {
    var source: [64 * 1024]u8 = undefined;
    golden.fillShape(.mixed, &source);
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
        shape: golden.Shape,
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
            .name = "words-495",
            .shape = .words,
            .size = 495,
            .expected = &golden.encode_words_495,
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
        golden.fillShape(case.shape, input);
        const target = try testing.allocator.alloc(u8, maxCompressedLength(input.len));
        defer testing.allocator.free(target);
        const written = try compress(input, target, .{});
        try testing.expectEqual(case.expected.len, written);
        try testing.expectEqualSlices(u8, case.expected, target[0..written]);
        // The CLI's frame decodes through our decoder to the input.
        const plain = try testing.allocator.alloc(u8, input.len);
        defer testing.allocator.free(plain);
        internal.sentinel.fill(plain);
        const decoded = try decode.decompress(case.expected, plain, null);
        try testing.expectEqual(input.len, decoded);
        try testing.expectEqualSlices(u8, input, plain[0..decoded]);
        try internal.sentinel.expect(plain, decoded);
    }
}

test "the witness inputs reproduce the CLI's frames, guarding three fixes' reverts" {
    // RFC 8878 §3.1 — the M5 verification witnesses: real inputs whose
    // emitted frames the reviewer verified byte-identical to the CLI's.
    // The clamp-order pair guards the hash-clamp order in `forSource`
    // (zstd_compress.c:1552-1569: clamp the hash to the shrunk window
    // before flooring the window); the tree-tie pair guards the
    // integer-division tie rule in `writeTree` (`huf_compress.c`:
    // `hSize < maxSymbolValue/2` with integer division, not the float
    // shape). With either fix reverted, the frame differs from the
    // CLI's recorded bytes.
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "clamp-order-85B",
            .source = &golden.clamp_order_85b_source,
            .expected = &golden.clamp_order_85b_frame,
        },
        .{
            .name = "clamp-order-94B",
            .source = &golden.clamp_order_94b_source,
            .expected = &golden.clamp_order_94b_frame,
        },
        .{
            .name = "tree-tie-584B",
            .source = &golden.tree_tie_584b_source,
            .expected = &golden.tree_tie_584b_frame,
        },
        .{
            .name = "tree-tie-890B",
            .source = &golden.tree_tie_890b_source,
            .expected = &golden.tree_tie_890b_frame,
        },
    };
    var target: [700 * 1024]u8 = undefined;
    for (cases) |case| {
        const written = try compress(case.source, &target, .{});
        try testing.expectEqualSlices(u8, case.expected, target[0..written]);
        // and the frame decodes back through our decoder.
        var plain: [700 * 1024]u8 = undefined;
        const n = try decode.decompress(case.expected, &plain, null);
        try testing.expectEqual(case.source.len, n);
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
    golden.fillShape(.rle, source[0..32768]);
    const rle_frame = try testing.allocator.alloc(u8, maxCompressedLength(source.len));
    defer testing.allocator.free(rle_frame);
    const rle_len = try compress(source[0..32768], rle_frame, .{});
    const rle_header = try block.parseHeader(rle_frame[headerLenFor(rle_frame, rle_len)..]);
    try testing.expectEqual(block.BlockType.compressed, rle_header.block_type);
    // The random shape: one Raw block at exactly the block size.
    golden.fillShape(.random, source[0..32768]);
    const random_frame = try testing.allocator.alloc(u8, maxCompressedLength(source.len));
    defer testing.allocator.free(random_frame);
    const random_len = try compress(source[0..32768], random_frame, .{});
    const random_offset = headerLenFor(random_frame, random_len);
    const random_header = try block.parseHeader(random_frame[random_offset..]);
    try testing.expectEqual(block.BlockType.raw, random_header.block_type);
    try testing.expectEqual(@as(usize, 32768), random_header.block_size);
    try testing.expect(random_header.last_block);
    // The 600 KB text frame: windowed, five blocks, the last one last.
    var big: [600 * 1024]u8 = undefined;
    golden.fillShape(.text, &big);
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

/// The scan-exit input's length: one block of the ladder's 128-KiB class.
const scan_exit_len = 2048;
/// The input's prefix: the corpus phrase, whose scan runs at step 2.
const scan_exit_text_len = 384;
/// Where the 8-byte repeat is planted: inside the block's last 16 bytes,
/// where only a scan restarted with its step reset to 2 would reach it.
const scan_exit_plant = 2033;

/// Fill the scan-exit input: `scan_exit_text_len` bytes of the corpus phrase,
/// then PRNG noise (which grows the scan's step), then the planted repeat.
fn fillScanExitInput(source: []u8) void {
    assert(source.len == scan_exit_len);
    const phrase = "the quick brown fox jumps over the lazy dog. ";
    for (source[0..scan_exit_text_len], 0..) |*byte, index| {
        byte.* = phrase[index % phrase.len];
    }
    var rng: DefaultPrng = .init(0xB3B);
    for (source[scan_exit_text_len..]) |*byte| byte.* = rng.random().int(u8);
    fastmem.copy(u8, source[scan_exit_plant..][0..8], source[0..8]);
}

test "the scan stops at the block's end, never restarting at it" {
    // The C's scan loop exits at `ip3 >= ilimit` into `_cleanup`
    // (`zstd_fast.c:348-350`), which ends the block; only a match's
    // `goto _start` re-enters with the step reset. A restart on the natural
    // exit rescans the tail at step 2 and finds matches the C never visits:
    // this input plants one in the block's last 16 bytes, and the CLI's own
    // frame (the `encode_scan_exit` fixture) does not carry it.
    var source: [scan_exit_len]u8 = undefined;
    fillScanExitInput(&source);
    const target = try testing.allocator.alloc(u8, maxCompressedLength(source.len));
    defer testing.allocator.free(target);
    const written = try compress(&source, target, .{});
    try testing.expectEqual(golden.encode_scan_exit.len, written);
    try testing.expectEqualSlices(u8, &golden.encode_scan_exit, target[0..written]);
}

test "the one-shot encodes a source over 4 GiB" {
    // The finder's table holds `u32` positions, so the one-shot slides the
    // table's base with the block start (`rebaseTable`, the Writer's
    // `compact` condition): a source over 4 GiB must not overflow a position
    // (`match_compress`'s `@intCast`s) nor emit an offset past the declared
    // Window_Size. 4 GiB of zeros is one match-rich first block and RLE
    // blocks after it, so the frame is about 131 KiB and the target can stay
    // small. The frame's header, block chain, and checksum are checked
    // structurally; a full decode would need a second 4 GiB buffer.
    // A 32-bit `usize` cannot hold the source at all (and its slices cannot
    // reach past 4 GiB), so the test exists only on 64-bit targets. It needs
    // about 4 GiB of memory plus the 1-MiB target.
    if (@bitSizeOf(usize) >= 64) {
        const total: usize = (1 << 32) + 256 * 1024;
        const source = try std.heap.page_allocator.alloc(u8, total);
        defer std.heap.page_allocator.free(source);
        fastmem.set(u8, source, 0);
        const target = try testing.allocator.alloc(u8, 1 << 20);
        defer testing.allocator.free(target);
        const written = try compress(source, target, .{});
        try testing.expect(written < target.len);
        const header = try frame.parseHeader(target[frame.magic_len..written]);
        try testing.expectEqual(@as(?u64, total), header.content_size);
        // The block chain: 128-KiB blocks of one repeated byte are RLE blocks
        // after the first, and the chain ends at the trailer with Last_Block
        // set on its last block (`§3.1.1.2`).
        var cursor = headerLenFor(target, written);
        var blocks: usize = 0;
        while (true) {
            const block_header = try block.parseHeader(target[cursor..written]);
            cursor += block.block_header_len + block.contentLength(block_header);
            blocks += 1;
            if (block_header.last_block) break;
        }
        try testing.expectEqual((total - 1) / block_compress.max_block_size + 1, blocks);
        try testing.expectEqual(written - frame.checksum_len, cursor);
    }
}

/// The frame header's length, from the parsed descriptor: the magic, the
/// descriptor, the optional Window_Descriptor, and the Frame_Content_Size
/// field (`§3.1.1.1`).
fn headerLenFor(frame_bytes: []const u8, frame_len: usize) usize {
    const header = frame.parseHeader(frame_bytes[frame.magic_len..frame_len]) catch unreachable;
    return frame.magic_len + header.bytes_consumed;
}

test "compress round-trips with a dictionary, both match-region shapes" {
    // RFC 8878 §5 — the dictionary is virtual past: every emitted offset
    // counts from the frame's start with the content behind it, and the
    // decoder's seeded tables decode the frame. Both of the C's match-region
    // shapes are exercised: the attach path (a source at or below the 8-KiB
    // cutoff, the dictionary a separate match state) and the copy path (a
    // larger source, its table copied into the frame's own).
    const trained = try Dictionary.parse(golden.dict_trained);
    const raw = Dictionary.initRaw(golden.dict_trained[115..]);
    var source: [600 * 1024]u8 = undefined;
    const sizes = [_]usize{
        0,      1,      6,          7,    8,    31,    100,   255,
        256,    1024,   4096,       8192, 8193, 16384, 65536, 131072,
        300000, 524289, 600 * 1024,
    };
    for ([_]golden.Shape{ .text, .rle, .random, .skewlit }) |shape| {
        for (sizes) |size| {
            golden.fillShape(shape, source[0..size]);
            _ = try expectDictRoundTrip(&trained, source[0..size]);
        }
    }
    // The remaining shapes at the region boundaries.
    for ([_]golden.Shape{ .html, .mixed, .words, .zeros }) |shape| {
        for ([_]usize{ 100, 8192, 8193, 65536 }) |size| {
            golden.fillShape(shape, source[0..size]);
            _ = try expectDictRoundTrip(&trained, source[0..size]);
        }
    }
    // A raw dictionary: content only, no entropy tables, the default
    // repcodes, no ID — the frame carries no Dictionary_ID field.
    for ([_]usize{ 0, 100, 8192, 8193, 300000 }) |size| {
        golden.fillShape(.text, source[0..size]);
        const frame_buffer = try testing.allocator.alloc(u8, maxCompressedLength(size));
        defer testing.allocator.free(frame_buffer);
        const written = try compress(source[0..size], frame_buffer, .{
            .level = .@"1",
            .dict = &raw,
        });
        const header = try frame.parseHeader(frame_buffer[frame.magic_len..written]);
        // A raw dictionary names no ID, so the header carries no DID field.
        try testing.expectEqual(@as(?u32, null), header.dictionary_id);
        _ = try expectDictRoundTrip(&raw, source[0..size]);
    }
}

test "the with-dictionary frames are the CLI's own bytes" {
    // RFC 8878 §3.1 + §5 — the whole emission, header through trailer, with a
    // dictionary: our level-1 frame reproduces the pinned CLI v1.5.7's
    // `zstd -D dict-trained.bin -1` bytes exactly on every corpus shape, and
    // each CLI frame decodes back through our decoder with the dictionary.
    // The fixtures and their CLI verdicts are `golden.zig`'s `dict_encode_*`
    // group; the 8-KiB pair brackets the C's attach/copy switch.
    const trained = try Dictionary.parse(golden.dict_trained);
    var source: [600 * 1024]u8 = undefined;
    const cases = [_]struct {
        name: []const u8,
        shape: golden.Shape,
        size: usize,
        expected: []const u8,
    }{
        .{
            .name = "text-100",
            .shape = .text,
            .size = 100,
            .expected = &golden.dict_encode_text_100,
        },
        .{
            .name = "text-8192",
            .shape = .text,
            .size = 8192,
            .expected = &golden.dict_encode_text_8192,
        },
        .{
            .name = "text-8193",
            .shape = .text,
            .size = 8193,
            .expected = &golden.dict_encode_text_8193,
        },
        .{
            .name = "text-65536",
            .shape = .text,
            .size = 65536,
            .expected = &golden.dict_encode_text_65536,
        },
        .{
            .name = "text-265000",
            .shape = .text,
            .size = 265000,
            .expected = &golden.dict_encode_text_265000,
        },
        .{
            .name = "html-65536",
            .shape = .html,
            .size = 65536,
            .expected = &golden.dict_encode_html_65536,
        },
        .{
            .name = "rle-133005",
            .shape = .rle,
            .size = 133005,
            .expected = &golden.dict_encode_rle_133005,
        },
        .{
            .name = "random-4096",
            .shape = .random,
            .size = 4096,
            .expected = &golden.dict_encode_random_4096,
        },
    };
    for (cases) |case| {
        const input = source[0..case.size];
        golden.fillShape(case.shape, input);
        const target = try testing.allocator.alloc(u8, maxCompressedLength(input.len));
        defer testing.allocator.free(target);
        const written = try compress(input, target, .{ .level = .@"1", .dict = &trained });
        try testing.expectEqual(case.expected.len, written);
        try testing.expectEqualSlices(u8, case.expected, target[0..written]);
        // The CLI's frame decodes through our decoder with the dictionary.
        const plain = try testing.allocator.alloc(u8, input.len);
        defer testing.allocator.free(plain);
        internal.sentinel.fill(plain);
        const decoded = try decode.decompress(case.expected, plain, &trained);
        try testing.expectEqual(input.len, decoded);
        try testing.expectEqualSlices(u8, input, plain[0..decoded]);
        try internal.sentinel.expect(plain, decoded);
    }
}

test "the with-dictionary fixtures the decode slice committed re-emit exactly" {
    // RFC 8878 §5 — the committed CLI frames for the corpus-shaped samples
    // (`dict_s00`, `dict_s01`, `dict_big`) over the trained dictionary and
    // the C's `zero-weight-dict`: our encoder reproduces each byte for byte.
    // The zero-weight dictionary is the promotion pin: its literals tree has
    // zero weights and its offsets table stops short of its alphabet, so
    // `ZSTD_loadCEntropy` promotes neither — and the frame still matches the
    // CLI's, which is what "degrade honestly" means (DE2, DD11).
    const cases = [_]struct {
        dict: []const u8,
        plain: []const u8,
        frame: []const u8,
    }{
        .{ .dict = golden.dict_trained, .plain = golden.dict_s00, .frame = golden.dict_frame_s00 },

        .{
            .dict = golden.dict_zero_weight,
            .plain = golden.dict_s00,
            .frame = golden.dict_frame_zw,
        },
        .{ .dict = golden.dict_trained, .plain = golden.dict_big, .frame = golden.dict_frame_big },
    };
    for (cases) |case| {
        const dict = try Dictionary.parse(case.dict);
        const target = try testing.allocator.alloc(u8, maxCompressedLength(case.plain.len));
        defer testing.allocator.free(target);
        const written = try compress(case.plain, target, .{ .level = .@"1", .dict = &dict });
        try testing.expectEqualSlices(u8, case.frame, target[0..written]);
    }
}

test "the byte class at level 1 is Treeless literals and Repeat sequences" {
    // RFC 8878 §3.1.1.3.1.1 + §3.1.1.3.2.1 (DE9, the walked-live record in
    // docs/slop/research/dictionary-notes.md §3.5): a small source over a
    // CLI-trained dictionary emits Treeless literals (the dictionary's tree,
    // reused from block 0) and Repeat_Mode on all three alphabets while
    // nbSeq < 1000; a source past 1,000 sequences recomputes (FSE ×3), the
    // ladder's own gate.
    const trained = try Dictionary.parse(golden.dict_trained);
    const target = try testing.allocator.alloc(u8, maxCompressedLength(golden.dict_big.len));
    defer testing.allocator.free(target);

    const small = try compress(golden.dict_s00, target, .{ .level = .@"1", .dict = &trained });
    const small_block = try firstBlock(target, small);
    try testing.expectEqual(literals.BlockType.treeless, small_block.literals_type);
    try testing.expectEqual(sequences.Mode.repeat, small_block.modes.literals_lengths);
    try testing.expectEqual(sequences.Mode.repeat, small_block.modes.offsets);
    try testing.expectEqual(sequences.Mode.repeat, small_block.modes.match_lengths);

    const big = try compress(golden.dict_big, target, .{ .level = .@"1", .dict = &trained });
    const big_block = try firstBlock(target, big);
    try testing.expectEqual(literals.BlockType.treeless, big_block.literals_type);
    try testing.expectEqual(sequences.Mode.fse, big_block.modes.literals_lengths);
    try testing.expectEqual(sequences.Mode.fse, big_block.modes.offsets);
    try testing.expectEqual(sequences.Mode.fse, big_block.modes.match_lengths);
}

test "the Fibonacci histogram's deep literals tree round-trips" {
    // The literals of a shuffled Fibonacci-count input carry a histogram
    // whose unlimited Huffman tree is deeper than the 11-bit cap; the tree
    // builder flattens it (`huff0_compress`'s test pins the builder), and
    // the block round-trips through the landed decoder. This is the public
    // path the depth assert used to abort on.
    var source: [17710]u8 = undefined;
    var index: usize = 0;
    var previous: usize = 0;
    var current: usize = 1;
    var symbol: u8 = 'A';
    while (index < source.len) {
        const count = @min(current, source.len - index);
        fastmem.set(u8, source[index..][0..count], symbol);
        index += count;
        symbol += 1;
        const next = previous + current;
        previous = current;
        current = next;
    }
    // Shuffle deterministically (Fisher-Yates), so the literals keep the
    // Fibonacci histogram without being one long run.
    var rng: DefaultPrng = .init(0xF1B0);
    var position: usize = source.len;
    while (position > 1) {
        position -= 1;
        const swap = rng.random().uintLessThan(usize, position + 1);
        const byte = source[position];
        source[position] = source[swap];
        source[swap] = byte;
    }
    _ = try expectRoundTrip(&source);
}
