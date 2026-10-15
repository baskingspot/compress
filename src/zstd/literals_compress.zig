//! The literals section of a compressed block for the zstd encoder
//! (`§3.1.1.3.1`): the 1-5 byte header, the four Literals_Block_Types
//! (`§3.1.1.3.1.1`, Table 13), and the cross-block table a
//! Treeless_Literals_Block reuses.
//!
//! `write` is the inverse of `literals.decode`, ladder for ladder
//! (`ZSTD_compressLiterals`, `zstd_compress_literals.c:129-235`): Raw below
//! the C's 64-literal floor (the 6-literal floor needs a dictionary-validated
//! tree, which this package cannot have), when Huffman does not pay the
//! minGain margin, or when one of `HUF_compress_internal`'s two early bails
//! fires — the suspect two-sample check the block layer arms
//! (`huf_compress.c:1366-1380`) and the flat-histogram check (`:1384`); RLE
//! for one-byte literals; Compressed with a tree
//! description and one stream below 256 literals, four above, the header's
//! 3/4/5-byte form by the 1-KiB/16-KiB thresholds; Treeless when the previous
//! block's tree still validates and is cheaper than a new description. The
//! trees come from `huff0_compress`, so the section is the exact inverse of
//! the decoder's section reader.
//!
//! The 11-bit depth cap is enforced while the tree is built (`§4.2.1`), so
//! the serialized weights cannot exceed it.
//!
//! Format: docs/research/specs/rfc8878-zstd.txt
//! Lineage: facebook/zstd v1.5.7 `zstd_compress_literals.c`
//! (`ZSTD_compressLiterals`); attribution in THIRD_PARTY.md.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const fastmem = @import("fastmem");

const huff0 = @import("huff0.zig");
const huff0_compress = @import("huff0_compress.zig");
const literals = @import("literals.zig");
const golden = @import("golden.zig");

/// Everything the literals encoder reports. Every Huffman bail-out
/// (`huff0_compress.Error`) is handled inside `write` by falling back to the
/// Raw form, as the C's `ZSTD_compressLiterals` does on a zero `cLitSize`.
pub const Error = error{
    /// `target` cannot hold the section the writer produces. The caller sizes
    /// its target for the Raw form, which is the largest this ladder emits.
    BufferTooSmall,
};

/// The literals layer's cross-block state (`§3.1.1.3`): the tree of the
/// frame's most recent Compressed_Literals_Block, which a
/// Treeless_Literals_Block reuses. One per frame, threaded through the block
/// loop; only a Compressed block updates it, and Raw, RLE, and Treeless
/// blocks leave it alone.
pub const State = struct {
    /// The frame's one tree; `null` until its first Compressed block.
    table: ?huff0_compress.Table = null,
};

/// `§3.1.1.3.1.1` — "Raw literals below 64 bytes are not compressed" (the
/// C's fast-strategy floor, `zstd_compress_literals.c:114-127`: `8 <<
/// min(9 - strategy, 3)`). The C's 6-literal floor applies only when the
/// previous tree is `HUF_repeat_valid`, which only dictionary loading sets
/// (`zstd_compress.c:5079`); the encoder takes no dictionary yet, so the
/// floor is always 64 here, as it is for any dictionary-free frame the C
/// compresses.
const min_literals_to_compress = 64;

/// `ZSTD_minGain` (`zstd_compress_internal.h:677-683`) at the fast levels:
/// `(srcSize >> 6) + 2`. Huffman is kept only when it beats this margin,
/// which is also what keeps a compressed block inside a single-segment
/// frame's Block_Maximum_Size.
fn minGain(source_len: usize) usize {
    return (source_len >> 6) + 2;
}

/// `SUSPECT_INCOMPRESSIBLE_SAMPLE_SIZE` and `SUSPECT_INCOMPRESSIBLE_SAMPLE_RATIO`
/// (`huf_compress.c:1251-1252`): a block the caller flags as suspect pays two
/// 4-KiB sample histograms before the full one — but only at or above
/// `4096 * 10` literals, so blocks under that size skip the sample entirely.
const suspect_sample_size = 4096;
const suspect_sample_ratio = 10;
/// The sample's verdict (`huf_compress.c:1378`): the two samples' largest
/// counts summed at or below this bound means the literals are too flat to
/// Huffman-code, and the Raw form goes out without the full histogram.
const suspect_sample_largest_max = ((2 * suspect_sample_size) >> 7) + 4;

/// `HIST_count_simple`'s return value over one sample (`huf_compress.c:1371-1376`):
/// the largest single-symbol count. The symbol ids do not feed the verdict.
fn largestCount(sample: []const u8) u32 {
    // A plain count, not `Histogram.count`: at 4 KiB the four-lane path's
    // zeroing and fold cost more than the lane parallelism saves (measured).
    var counts: [256]u32 = @splat(0);
    for (sample) |byte| counts[byte] += 1;
    var largest: u32 = 0;
    for (counts) |count| largest = @max(largest, count);
    return largest;
}

/// Write one literals section for `source`, updating `state` when the section
/// is Compressed. Returns the section's length. `suspect_uncompressible` is
/// the block layer's flag (`zstd_compress.c:2924`: no sequences, or at least
/// 20 literals per sequence), which arms the two-sample fast path below — the
/// C's way of not paying a full histogram and tree build for literals a flat
/// distribution will send out Raw anyway.
///
/// Every path writes at most `source.len + 3` bytes (the Raw form), so a
/// target sized for that cannot overflow; a smaller one fails
/// `error.BufferTooSmall` before the write that would. An abandoned Huffman
/// attempt leaves its scratch bytes in `target` before the Raw form is
/// written over them, so the bytes past the returned length are unspecified
/// (the C's `HUF_compress` writes into the caller's buffer the same way).
pub fn write(
    source: []const u8,
    target: []u8,
    state: *State,
    suspect_uncompressible: bool,
) Error!usize {
    if (source.len < min_literals_to_compress) return writeRaw(source, target);

    // `HUF_compress_internal`'s suspect fast path (`huf_compress.c:1366-1380`):
    // sample the first and last 4 KiB; a flat enough pair means Raw without
    // the full histogram, the tree build, or the streams.
    if (suspect_uncompressible and source.len >= suspect_sample_size * suspect_sample_ratio) {
        const largest_total = largestCount(source[0..suspect_sample_size]) +
            largestCount(source[source.len - suspect_sample_size ..]);
        if (largest_total <= suspect_sample_largest_max) return writeRaw(source, target);
    }

    const histogram = huff0_compress.Histogram.count(source);
    if (histogram.largest == source.len) {
        // "A return value of 1 signals that the alphabet consists of a single
        // symbol": RLE_Mode, or Raw when the one byte does not beat the
        // minGain margin (the C's `cLitSize == 1` path).
        if (source.len <= minGain(source.len) + 1) return writeRaw(source, target);
        return writeRle(source, target);
    }
    // The full-histogram bail (`huf_compress.c:1384`): no symbol carrying
    // over a 128th of the literals means the distribution is too flat for a
    // tree to pay, whatever the streams would have said.
    if (histogram.largest <= (source.len >> 7) + 4) return writeRaw(source, target);

    const table = huff0_compress.buildTable(&histogram, @intCast(source.len)) catch
        return writeRaw(source, target);
    const header_len = compressedHeaderLength(source.len);
    if (target.len < header_len) return error.BufferTooSmall;
    // A tree with no legal description, or a target too small for the
    // description: the C's `HUF_compress` returns 0 on both
    // (`huf_compress.c:262,283`), and `ZSTD_compressLiterals` then writes the
    // Raw form (`zstd_compress_literals.c:180-184`).
    const description_len = huff0_compress.writeTree(
        target[header_len..],
        &table,
    ) catch return writeRaw(source, target);

    // "Check if using previous huffman table is beneficial": the previous
    // tree, when it still validates, wins if it saves the description's bytes
    // or if the description is nearly the whole input (the C's
    // `oldSize <= hSize + newSize || hSize + 12 >= srcSize`,
    // `huf_compress.c:1387-1395`).
    var reused: ?*const huff0_compress.Table = null;
    if (state.table) |*previous| {
        if (covers(previous, &histogram)) {
            const previous_size = estimateSize(previous, &histogram);
            const new_size = estimateSize(&table, &histogram);
            if (previous_size <= description_len + new_size or
                description_len + 12 >= source.len)
            {
                reused = previous;
            }
        }
    }
    const encode_table = reused orelse &table;
    const body_start = header_len + if (reused == null) description_len else 0;
    // The streams' own bail-outs (a target too small for them, the
    // four-stream layout's floor and Jump_Table bound) are the C's `cSize ==
    // 0` and take the Raw form too.
    const streams_len = writeStreams(encode_table, source, target[body_start..]) catch
        return writeRaw(source, target);
    const body_len = if (reused == null) description_len + streams_len else streams_len;
    // "If the compressed block is larger than the uncompressed one, sending
    // the uncompressed block ... is recommended" (`§3.1.1.2.4`): the minGain
    // margin is the C's rule.
    if (body_len >= source.len - minGain(source.len)) return writeRaw(source, target);

    const block_type: literals.BlockType = if (reused == null) .compressed else .treeless;
    writeCompressedHeader(target[0..header_len], block_type, source.len, body_len);
    // The state a later Treeless block sees is the tree this block wrote;
    // a Treeless block leaves the previous one in place.
    if (reused == null) state.table = table;
    return header_len + body_len;
}

/// `§3.1.1.3.1.2` — "The data in Stream_1 is Regenerated_Size bytes long. It
/// contains the raw literals data to be used during Sequence Execution", with
/// the 1/2/3-byte header by the 32/4096 thresholds
/// (`ZSTD_noCompressLiterals`, `zstd_compress_literals.c:41-66`).
fn writeRaw(source: []const u8, target: []u8) Error!usize {
    const header_len = rawHeaderLength(source.len);
    if (header_len + source.len > target.len) return error.BufferTooSmall;
    writeRawHeader(target[0..header_len], .raw, source.len);
    fastmem.copy(u8, target[header_len..][0..source.len], source);
    return header_len + source.len;
}

/// `§3.1.1.3.1.3` — "Stream_1 consists of a single byte that should be
/// repeated Regenerated_Size times".
fn writeRle(source: []const u8, target: []u8) Error!usize {
    assert(source.len >= 1);
    const header_len = rawHeaderLength(source.len);
    if (header_len + 1 > target.len) return error.BufferTooSmall;
    writeRawHeader(target[0..header_len], .rle, source.len);
    target[header_len] = source[0];
    return header_len + 1;
}

/// The Raw and RLE header's length (`§3.1.1.3.1.1`): 1 byte up to 31
/// literals, 2 up to 4095, 3 above.
fn rawHeaderLength(source_len: usize) usize {
    return 1 + @as(usize, @intFromBool(source_len > 31)) +
        @as(usize, @intFromBool(source_len > 4095));
}

/// The header's fields for the Raw/RLE family: the type in bits 0-1, then
/// Regenerated_Size. Size_Format 00 and 10 share the 1-byte form, 01 is the
/// 12-bit form, 11 the 20-bit one.
fn writeRawHeader(target: []u8, block_type: literals.BlockType, source_len: usize) void {
    const type_bits: u32 = @intFromEnum(block_type);
    switch (target.len) {
        1 => target[0] = @intCast(type_bits + (source_len << 3)),
        2 => {
            const header: u32 = type_bits + (1 << 2) + (@as(u32, @intCast(source_len)) << 4);
            target[0] = @truncate(header);
            target[1] = @truncate(header >> 8);
        },
        3 => {
            const header: u32 = type_bits + (3 << 2) + (@as(u32, @intCast(source_len)) << 4);
            target[0] = @truncate(header);
            target[1] = @truncate(header >> 8);
            target[2] = @truncate(header >> 16);
        },
        else => unreachable,
    }
}

/// The Compressed and Treeless header's length (`§3.1.1.3.1.1`):
/// `3 + (srcSize >= 1 KB) + (srcSize >= 16 KB)` (`zstd_compress_literals.c:140`).
fn compressedHeaderLength(source_len: usize) usize {
    return 3 + @as(usize, @intFromBool(source_len >= 1024)) +
        @as(usize, @intFromBool(source_len >= 16384));
}

/// The Compressed/Treeless header (`§3.1.1.3.1.1`): the type, the Size_Format
/// bit that selects one or four streams (or the wider size fields), then
/// Regenerated_Size and Compressed_Size as adjacent little-endian fields.
fn writeCompressedHeader(
    target: []u8,
    block_type: literals.BlockType,
    source_len: usize,
    body_len: usize,
) void {
    const single_stream = source_len < 256;
    const size_format: u2 = switch (target.len) {
        3 => @intFromBool(!single_stream),
        4 => 2,
        else => 3,
    };
    const shift: u6 = switch (size_format) {
        0, 1 => 14,
        2 => 18,
        3 => 22,
    };
    var header: u64 = @intFromEnum(block_type) + (@as(u64, size_format) << 2);
    header |= @as(u64, @intCast(source_len)) << 4;
    header |= @as(u64, @intCast(body_len)) << shift;
    for (target, 0..) |*byte, index| {
        byte.* = @truncate(header >> @intCast(8 * index));
    }
}

/// The Huffman-coded streams: four above 256 literals, one below
/// (`§3.1.1.3.1.6`), the split at `(Regenerated_Size + 3) / 4`.
fn writeStreams(
    table: *const huff0_compress.Table,
    source: []const u8,
    target: []u8,
) huff0_compress.Error!usize {
    if (source.len < 256) return huff0_compress.writeStream(target, source, table);
    return huff0_compress.writeFourStreams(target, source, table);
}

/// `HUF_estimateCompressedSize` (`huf_compress.c:760-770`): the coded bits
/// each symbol costs, in whole bytes.
fn estimateSize(
    table: *const huff0_compress.Table,
    histogram: *const huff0_compress.Histogram,
) usize {
    var bits: usize = 0;
    for (histogram.counts[0 .. @as(usize, histogram.max_symbol) + 1], 0..) |count, symbol| {
        bits += @as(usize, table.codes[symbol].len) * count;
    }
    return bits >> 3;
}

/// `HUF_validateCTable` (`huf_compress.c:804-818`): a previous tree can
/// encode this block's literals only when it reaches the block's last symbol
/// and gives every symbol the block uses a code.
fn covers(table: *const huff0_compress.Table, histogram: *const huff0_compress.Histogram) bool {
    if (table.symbol_count - 1 < histogram.max_symbol) return false;
    for (histogram.counts[0 .. @as(usize, histogram.max_symbol) + 1], 0..) |count, symbol| {
        if (count != 0 and table.codes[symbol].len == 0) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc8878-zstd.txt §3.1.1.3.1 (the section
// and its types), §3.1.1.3.1.1 (the header and Table 13),
// §3.1.1.3.1.2/§3.1.1.3.1.3 (Raw and RLE), §3.1.1.3.1.6 (the Jump_Table).
// Every section is decoded back through `literals.decode`.
// ---------------------------------------------------------------------------

/// Decode a section the writer produced and check the literals come back
/// untouched past their end.
fn expectRoundTrip(source: []const u8, expected_type: literals.BlockType) !void {
    var target: [256 * 1024]u8 = undefined;
    var state: State = .{};
    const written = try write(source, &target, &state, false);
    const header = try literals.parseHeader(target[0..written]);
    try testing.expectEqual(expected_type, header.block_type);
    try testing.expectEqual(@as(u20, @intCast(source.len)), header.regenerated_size);
    var decoded: [256 * 1024]u8 = undefined;
    var decode_state: literals.State = .{};
    const section = try literals.decode(target[0..written], &decoded, &decode_state);
    try testing.expectEqual(source.len, section.bytes.len);
    try testing.expectEqualSlices(u8, source, section.bytes);
    try testing.expectEqual(written, section.bytes_consumed);
}

test "write's ladder picks Raw, RLE, and Compressed at the C's thresholds" {
    // RFC 8878 §3.1.1.3.1.1 (Table 13) — the fast level's ladder: Raw below
    // 64 literals, RLE for a one-byte alphabet, Compressed above with one
    // stream under 256 literals and four above.
    var target: [256 * 1024]u8 = undefined;
    var state: State = .{};
    // 63 literals: Raw, the C's floor (`zstd_compress_literals.c:114-127`).
    // The header is 2 bytes at that size (Regenerated_Size is over 31).
    var short: [63]u8 = undefined;
    for (&short, 0..) |*byte, index| byte.* = @intCast(index % 7);
    try testing.expectEqual(@as(usize, 65), try write(&short, &target, &state, false));
    // 64: the floor is passed, and the skewed distribution compresses.
    var literals_64: [64]u8 = undefined;
    for (&literals_64, 0..) |*byte, index| byte.* = if (index % 8 == 0) 7 else 0;
    try expectRoundTrip(&literals_64, .compressed);
    // One distinct byte, 100 literals: RLE.
    const repeated = [_]u8{0x41} ** 100;
    try expectRoundTrip(&repeated, .rle);
    // A two-byte input of one symbol: Raw, because the one content byte does
    // not beat minGain (the C's `cLitSize == 1` path).
    try testing.expectEqual(@as(usize, 3), try write(&.{ 0x41, 0x41 }, &target, &state, false));
    // 255 literals: one stream (Size_Format 00); 256: four (01).
    var one_stream: [255]u8 = undefined;
    for (&one_stream, 0..) |*byte, index| byte.* = @intCast(index % 11);
    var four_streams: [256]u8 = undefined;
    for (&four_streams, 0..) |*byte, index| byte.* = @intCast(index % 11);
    const one = try write(&one_stream, &target, &state, false);
    try testing.expectEqual(@as(u2, 0), (try literals.parseHeader(target[0..one])).size_format);
    const four = try write(&four_streams, &target, &state, false);
    try testing.expectEqual(@as(u2, 1), (try literals.parseHeader(target[0..four])).size_format);
    // The 4- and 5-byte headers at the 1-KiB and 16-KiB thresholds.
    var kilo: [1024]u8 = undefined;
    for (&kilo, 0..) |*byte, index| byte.* = @intCast(index % 13);
    const kilo_len = try write(&kilo, &target, &state, false);
    const kilo_header = try literals.parseHeader(target[0..kilo_len]);
    try testing.expectEqual(@as(usize, 4), kilo_header.header_len);
    var sixteen: [16384]u8 = undefined;
    for (&sixteen, 0..) |*byte, index| byte.* = @intCast(index % 17);
    const sixteen_len = try write(&sixteen, &target, &state, false);
    const wide_header = try literals.parseHeader(target[0..sixteen_len]);
    try testing.expectEqual(@as(usize, 5), wide_header.header_len);
}

test "the suspect sample check bails before the full histogram" {
    // `huf_compress.c:1366-1380` — a suspect block of at least 40 KiB of
    // literals is judged by two 4-KiB samples: both ends flat (the samples'
    // largest counts summing to at most 68) means Raw without the full
    // histogram, even when the middle would have Huffman-coded — the C's
    // sacrifice, reproduced exactly.
    var source: [49152]u8 = undefined;
    // Both samples flat: 256 symbols at 16 occurrences each per sample,
    // largest_total 32. The middle is one repeated byte, so the full ladder
    // would keep a Compressed section.
    for (&source, 0..) |*byte, index| byte.* = if (index < 4096 or index >= source.len - 4096)
        @truncate(index % 256)
    else
        0x41;
    var target: [256 * 1024]u8 = undefined;
    var state: State = .{};
    const raw_len = try write(&source, &target, &state, true);
    try testing.expectEqual(
        literals.BlockType.raw,
        (try literals.parseHeader(target[0..raw_len])).block_type,
    );
    // Without the flag the same bytes take the full ladder and compress.
    state = .{};
    const compressed_len = try write(&source, &target, &state, false);
    try testing.expectEqual(
        literals.BlockType.compressed,
        (try literals.parseHeader(target[0..compressed_len])).block_type,
    );
    // A suspect block whose samples are NOT flat pays the full ladder: half
    // one byte at both ends, largest_total far over 68.
    for (&source, 0..) |*byte, index| byte.* = if (index % 2 == 0) 0x41 else @truncate(index % 7);
    state = .{};
    const skewed_len = try write(&source, &target, &state, true);
    try testing.expectEqual(
        literals.BlockType.compressed,
        (try literals.parseHeader(target[0..skewed_len])).block_type,
    );
}

test "the flat-histogram bail keeps a treeless distribution Raw" {
    // `huf_compress.c:1384` — after the full histogram, no symbol carrying
    // over a 128th of the literals (plus 4) means Raw, whatever the streams
    // would have saved. 2048 literals over 128 symbols at 16 each: largest
    // 16 <= (2048 >> 7) + 4 = 20, though the 7-bit codes would have beaten
    // the minGain margin.
    var source: [2048]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = @truncate(index % 128);
    var target: [256 * 1024]u8 = undefined;
    var state: State = .{};
    const written = try write(&source, &target, &state, false);
    try testing.expectEqual(
        literals.BlockType.raw,
        (try literals.parseHeader(target[0..written])).block_type,
    );
    // One symbol past the bound: five more occurrences of byte 0 make its
    // count 21, over the bail's 20, and the tree is attempted.
    for (source[1..6]) |*byte| byte.* = 0;
    state = .{};
    const past = try write(&source, &target, &state, false);
    try testing.expectEqual(
        literals.BlockType.compressed,
        (try literals.parseHeader(target[0..past])).block_type,
    );
}

test "every ladder rung decodes back through the landed decoder" {
    // RFC 8878 §3.1.1.3.1 — the round-trip gate over the corpus shapes the
    // ladder's rungs cover: flat (Raw), one symbol (RLE), skewed text
    // (Compressed), and random (Raw), at sizes that cross every header form.
    var rng: std.Random.DefaultPrng = .init(0x11A1);
    const random = rng.random();
    var source: [64 * 1024]u8 = undefined;
    for (0..120) |_| {
        const length = random.uintLessThan(usize, source.len - 1) + 1;
        const shape = random.uintLessThan(u8, 4);
        for (source[0..length]) |*byte| {
            byte.* = switch (shape) {
                0 => random.int(u8),
                1 => 0x5a,
                2 => @truncate(random.uintLessThan(u32, 4)),
                else => @truncate(97 + random.uintLessThan(u32, 3)),
            };
        }
        var target: [256 * 1024]u8 = undefined;
        var state: State = .{};
        const written = try write(source[0..length], &target, &state, false);
        var decoded: [256 * 1024]u8 = undefined;
        var decode_state: literals.State = .{};
        const section = try literals.decode(target[0..written], &decoded, &decode_state);
        try testing.expectEqualSlices(u8, source[0..length], section.bytes);
        try testing.expectEqual(written, section.bytes_consumed);
        // The state a later block sees is this section's: a Compressed
        // section leaves a tree, RLE and Raw leave none.
        try testing.expectEqual(
            (try literals.parseHeader(target[0..written])).block_type == .compressed,
            state.table != null,
        );
    }
}

test "the pair fixture's literals section is regenerated byte for byte" {
    // RFC 8878 §4.2.1.3 (Table 25) + §3.1.1.3.1.1 — the `pair_*` fixtures, the
    // day-one
    // byte-exact golden: given the example's tree and the four literals, the
    // section the writer produces must be the fixture's own bytes (a 3-byte
    // header, the tree, and the `01 0D` stream). The tree is injected rather
    // than derived, because the example's tree is not the one its four
    // literals imply — which is the point: the stream writer is pinned to the
    // tree, not to a histogram.
    const tree = try huff0.readTree(&golden.pair_tree);
    var table: huff0_compress.Table = .{
        .weights = @splat(0),
        .symbol_count = tree.symbol_count,
        .max_bits = tree.max_bits,
        .codes = @splat(.{}),
    };
    for (tree.weights[0..tree.symbol_count], 0..) |weight, symbol| {
        table.weights[symbol] = weight;
    }
    // §4.2.1.3's assignment: rank starts walking down from the deepest code.
    var rank_count: [huff0.code_length_max + 1]u16 = @splat(0);
    for (table.weights[0..table.symbol_count]) |weight| rank_count[weight] += 1;
    var rank_start: [huff0.code_length_max + 1]u16 = @splat(0);
    var start: u16 = 0;
    for (1..huff0.code_length_max + 1) |weight| {
        rank_start[weight] = start;
        start += rank_count[weight] << @intCast(weight - 1);
    }
    for (table.weights[0..table.symbol_count], 0..) |weight, symbol| {
        if (weight == 0) continue;
        const cell = rank_start[weight];
        rank_start[weight] += @as(u16, 1) << @intCast(weight - 1);
        table.codes[symbol] = .{
            .bits = cell >> @intCast(weight - 1),
            .len = @intCast(table.max_bits + 1 - weight),
        };
    }
    var target: [64]u8 = undefined;
    const tree_len = try huff0_compress.writeTree(target[3..], &table);
    const stream_len = try writeStreams(&table, &golden.pair_literals, target[3 + tree_len ..]);
    const body_len = tree_len + stream_len;
    writeCompressedHeader(target[0..3], .compressed, golden.pair_literals.len, body_len);
    try testing.expectEqualSlices(
        u8,
        &golden.pair_literals_section,
        target[0 .. 3 + body_len],
    );
}

test "Treeless reuses the previous block's tree" {
    // RFC 8878 §3.1.1.3.1.1 — "Treeless_Literals_Block ... us[es] the
    // Huffman tree from the previous Compressed_Literals_Block". The second
    // block's literals are a subset of the first's alphabet, so the previous
    // tree validates and the description's bytes are saved.
    var first: [4096]u8 = undefined;
    for (&first, 0..) |*byte, index| byte.* = @truncate((index * 7) % 40);
    // A prefix of the first block: the same alphabet and a near-identical
    // distribution, so the previous tree is as good as a new one and the
    // description's bytes are what Treeless saves.
    const second: []const u8 = first[0..2048];
    var target: [64 * 1024]u8 = undefined;
    var state: State = .{};
    const first_len = try write(&first, &target, &state, false);
    const first_header = try literals.parseHeader(target[0..first_len]);
    try testing.expectEqual(literals.BlockType.compressed, first_header.block_type);
    const first_table = state.table.?;
    var second_target: [64 * 1024]u8 = undefined;
    const second_len = try write(second, &second_target, &state, false);
    try testing.expectEqual(
        literals.BlockType.treeless,
        (try literals.parseHeader(second_target[0..second_len])).block_type,
    );
    // The state's tree is unchanged, and the section decodes through it.
    try testing.expectEqual(first_table.symbol_count, state.table.?.symbol_count);
    var decoded: [64 * 1024]u8 = undefined;
    var decode_state: literals.State = .{};
    _ = try literals.decode(target[0..first_len], &decoded, &decode_state);
    const section = try literals.decode(second_target[0..second_len], &decoded, &decode_state);
    try testing.expectEqualSlices(u8, second, section.bytes);
    try testing.expectEqual(second_len, section.bytes_consumed);
    // A Raw section leaves the tree in place: the third block still reuses
    // it.
    var third_target: [64]u8 = undefined;
    const raw_len = try write(&.{ 1, 2, 3, 4, 5 }, &third_target, &state, false);
    const raw_header = try literals.parseHeader(third_target[0..raw_len]);
    try testing.expectEqual(literals.BlockType.raw, raw_header.block_type);
    try testing.expectEqual(first_table.symbol_count, state.table.?.symbol_count);
}

test "a tree listing over 128 weights takes the FSE series, never Raw" {
    // RFC 8878 §4.2.1.1 — the direct description's header byte is
    // `127 + listed`, so at most 128 weights fit it (`huf_compress.c:282`),
    // and the C tries the FSE series first (`:275-279`). A tree whose
    // literals carry a byte of 0x81 or above lists more than 128 weights:
    // checking the direct form's limit before the series attempt would send
    // every such section to Raw, which is every UTF-8 text's first block.
    var source: [2048]u8 = undefined;
    for (&source, 0..) |*byte, index| {
        byte.* = if (index % 16 == 0) @intCast(0x81 + (index / 16) % 8) else 'a';
    }
    var target: [4096]u8 = undefined;
    var state: State = .{};
    const written = try write(&source, &target, &state, false);
    const header = try literals.parseHeader(target[0..written]);
    try testing.expectEqual(literals.BlockType.compressed, header.block_type);
    // The tree description's first byte is the series length (< 128) in the
    // FSE form; the direct form's is `127 + listed` (>= 128 here).
    try testing.expect(target[header.header_len] < 128);
    var decoded: [4096]u8 = undefined;
    var decode_state: literals.State = .{};
    const section = try literals.decode(target[0..written], &decoded, &decode_state);
    try testing.expectEqualSlices(u8, &source, section.bytes);
}

test "a Raw-sized target never fails the Huffman attempt" {
    // RFC 8878 §3.1.1.3.1.2 — the Raw form is `source.len + 3` bytes, the
    // largest this ladder emits, so a target that size must succeed on every
    // input: an abandoned Huffman attempt (its tree description or streams
    // running past the target) falls back to Raw, as the C's `HUF_compress`
    // returning 0 does. Without the fallback the attempt's own
    // `error.BufferTooSmall` escapes, and a caller sizing for the Raw form
    // (the block layer's contract) sees a spurious failure.
    var rng: std.Random.DefaultPrng = .init(77);
    var target: [4099]u8 = undefined;
    for (0..200) |round| {
        var source: [4096]u8 = undefined;
        const length = 64 + round * 19;
        rng.random().bytes(source[0..length]);
        // Skew it a little, so Huffman is attempted and stays near 8
        // bits/symbol (the shape that writes the widest sections).
        for (source[0..length], 0..) |*byte, index| {
            if (index % 9 == 0) byte.* = 'e';
        }
        var state: State = .{};
        const raw_len = rawHeaderLength(length) + length;
        const written = try write(source[0..length], target[0..raw_len], &state, false);
        try testing.expect(written <= raw_len);
    }
}
