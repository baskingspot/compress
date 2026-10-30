//! The brotli stream header (`§9.1`) and the meta-block ladder (`§9.2`):
//! WBITS and the window arithmetic, ISLAST/ISLASTEMPTY, MNIBBLES/MLEN, the
//! metadata and uncompressed meta-block forms, the compressed meta-block
//! header's completion — the block-type counts with their trees and first
//! counts, NPOSTFIX/NDIRECT, the context modes and maps, and the three tree
//! groups — and the stream end with its zero fill.
//!
//! The ladder's bit source is spelled out by the caller: a type with
//! `peek`, `take`, `alignToByte`, `skipBytes`, and an `ErrorSet`, such as
//! this package's `bits.BitReader` over a slice or the streaming reader's
//! bit source over its input.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const fastmem = @import("fastmem");

const bits = @import("bits.zig");
const context = @import("context.zig");
const golden = @import("golden.zig");
const huffman = @import("huffman.zig");
const internal = @import("../internal/root.zig");

/// Everything the framing layer reports: the bit reader's own refusals, this
/// layer's names, and the tree and context layers' names. The names match
/// `decompress`'s header and ladder rows.
pub const Error = error{
    /// `§9.1` — WBITS is the invalid pattern 0010001.
    BadWindowBits,
    /// `§9.2` — the metadata meta-block's reserved bit is set.
    ReservedBit,
    /// `§9.2` — MNIBBLES > 4 with an all-zero last nibble.
    ExuberantNibble,
    /// `§9.2` — MSKIPBYTES > 1 with an all-zero last byte.
    ExuberantMetaNibble,
    /// A meta-block declares more trees in a category than the
    /// comptime-capped region holds (`huffman.max_trees`).
    TooManyTrees,
};

/// The composed error set of the header layers for a bit source of `Bits`'s
/// kind.
fn Errors(comptime Bits: type) type {
    return Bits.ErrorSet || Error || huffman.Error || context.Error;
}

/// `§9.2`'s three block categories, in wire order.
pub const Category = enum(u2) {
    literal,
    command,
    distance,
};

/// `§9.1` — the stream header has exactly one field.
pub const StreamHeader = struct {
    /// WBITS, 10..24.
    wbits: u5,
    /// `§9.1` — "window size = (1 << WBITS) - 16": the maximum value of any
    /// non-dictionary reference backward distance (`§2`), 1,008 bytes to
    /// 16,777,200.
    window_size: u32,
};

/// `§9.1` — read WBITS. The 1..7-bit code is `0` for 16, `0011`..`1111`
/// (read low bit first) for 18..24, `0000001` for 17, and
/// `0100001`..`1110001` for 10..15; `0010001` "is invalid and must not be
/// used".
pub fn readStreamHeader(comptime Bits: type, br: *Bits) Errors(Bits)!StreamHeader {
    if ((try br.take(1)) == 0) return window(16);
    const short = try br.take(3);
    if (short != 0) return window(@intCast(17 + short));
    const long = try br.take(3);
    if (long == 1) return error.BadWindowBits;
    if (long != 0) return window(@intCast(8 + long));
    return window(17);
}

/// The kind of meta-block the ladder found: the two forms that carry
/// uncompressed data. The empty forms do not produce a value at all —
/// `nextMetaBlock` returns `null` for them.
pub const Kind = enum {
    /// ISUNCOMPRESSED=1 (`§9.2`): MLEN bytes of literal data follow at the
    /// next byte boundary. "An uncompressed meta-block cannot be the last
    /// meta-block" (`§2`).
    uncompressed,
    /// The compressed form. Its header is read into the caller's `Header`
    /// before `nextMetaBlock` returns, so the position after it is the
    /// meta-block's compressed data (`§9.3`).
    compressed,
};

/// A meta-block header (`§9.2`), as much as the framing layer reads.
pub const MetaBlock = struct {
    kind: Kind,
    /// MLEN: the meta-block's uncompressed length, 1..16777216 (`§2`).
    mlen: u32,
    /// ISLAST: the stream ends after this meta-block's data. The last
    /// byte's zero fill (`§9.3`) is the caller's check once the data is
    /// decoded — `bits.BitReader.alignToByte` — because for a non-empty
    /// meta-block it lies past the data, not in this header.
    is_last: bool,
};

/// The compressed meta-block header's arena (`§9.2`'s tail, `§3`, `§6`,
/// `§7`): the parameters, the context models, and the tree region. About
/// 690 KiB at the tree cap, so it lives in a caller-owned stack or static
/// object — never a copy.
pub const Header = struct {
    /// `§4` — NPOSTFIX, 0..3, and NDIRECT: the 4-bit field left-shifted by
    /// NPOSTFIX (0..120).
    npostfix: u3,
    ndirect: u8,
    /// `§9.2` — NBLTYPESL/I/D: the block-type count of each category.
    block_types: [3]u16,
    /// `§9.2` — NTREESL/NBLTYPESI/NTREESD: the tree count of each group.
    num_trees: [3]u16,
    /// `§6` — the first block count of each category. A category with a
    /// single block type has none on the wire: BLEN = 16777216 (`§10`).
    first_block_count: [3]u32,
    /// `§7` — the context modes and the two context maps.
    context: context.Arena,
    /// `§3` — the literal, command, and distance trees.
    trees: huffman.Trees,
};

/// `§9.2`, `§10` — read the next meta-block header. Metadata meta-blocks are
/// skipped here: they are "not part of either the sliding window or the
/// uncompressed data", and "not used as context bytes for literals" (`§2`),
/// so nothing above this layer sees them. `null` means the stream ends at
/// the current position: ISLAST+ISLASTEMPTY, or a metadata meta-block with
/// ISLAST set, whose zero fill was verified.
///
/// A compressed meta-block's header is read into `header` (`§9.2`'s tail,
/// `§3`, `§6`, `§7.3`) before this returns; `header` is untouched by the
/// other forms.
pub fn nextMetaBlock(comptime Bits: type, br: *Bits, header: *Header) Errors(Bits)!?MetaBlock {
    while (true) {
        const is_last = (try br.take(1)) != 0;
        if (is_last) {
            if ((try br.take(1)) != 0) {
                // §9.2: "the meta-block and the brotli stream ends at that
                // bit, with any remaining bits in the last byte of the
                // compressed stream filled with zeros".
                try br.alignToByte();
                return null;
            }
        }
        const mnibbles = try readMnibbles(Bits, br);
        if (mnibbles == 0) {
            try skipMetadata(Bits, br);
            // A metadata meta-block with ISLAST set ends the stream too:
            // §10's loop exits on ISLAST after skipping the metadata, and
            // both references implement it that way. The stream ends on the
            // byte boundary the metadata payload already reached.
            if (is_last) return null;
            continue;
        }
        const mlen = try readMlen(Bits, br, mnibbles);
        if (!is_last) {
            if ((try br.take(1)) != 0) {
                // §9.2: ISUNCOMPRESSED's skipped bits "must be all zeros"
                // (the references' PADDING_1 site).
                try br.alignToByte();
                return .{ .kind = .uncompressed, .mlen = mlen, .is_last = false };
            }
        }
        try readCompressedHeader(Bits, br, header);
        return .{ .kind = .compressed, .mlen = mlen, .is_last = is_last };
    }
}

/// `§9.2`'s compressed meta-block header, from NBLTYPESL on: the block-type
/// counts, each interleaved with its block-type tree, block-count tree, and
/// first block count (`§6`); NPOSTFIX and NDIRECT (`§4`); the context modes
/// (`§7.1`); NTREESL and the literal context map, NTREESD and the distance
/// context map (`§7.3`); and the three tree groups in order — literals,
/// insert-and-copy lengths, distances (`§3`).
pub fn readCompressedHeader(comptime Bits: type, br: *Bits, header: *Header) Errors(Bits)!void {
    for (0..3) |cat| {
        const count = try readCount(Bits, br);
        // NBLTYPESI is the command tree count: its trees are the region's
        // command category, so it is capped. The literal and distance
        // categories size only the modes array and the maps, which the
        // format's own 256 ceiling fits.
        if (cat == @intFromEnum(Category.command) and count > huffman.max_trees) {
            return error.TooManyTrees;
        }
        header.block_types[cat] = @intCast(count);
        if (count == 1) {
            header.first_block_count[cat] = 1 << 24;
            continue;
        }
        try huffman.readTree(
            huffman.BlockTypeTree,
            Bits,
            br,
            &header.trees.block_type[cat],
            @intCast(count + 2),
        );
        try huffman.readTree(
            huffman.BlockCountTree,
            Bits,
            br,
            &header.trees.block_count[cat],
            huffman.block_count_alphabet_size,
        );
        const count_tree = &header.trees.block_count[cat];
        header.first_block_count[cat] = try readBlockCount(Bits, br, count_tree);
    }

    // §9.2 — "2 bits: NPOSTFIX"; "4 bits: four most significant bits of
    // NDIRECT, to get the actual value of the parameter NDIRECT,
    // left-shift this four-bit number by NPOSTFIX bits".
    header.npostfix = @intCast(try br.take(2));
    header.ndirect = @intCast((try br.take(4)) << header.npostfix);

    // §9.2, §7.1 — "NBLTYPESL * 2 bits: context mode for each literal block
    // type".
    try context.readModes(Bits, br, header.context.modes[0..header.block_types[0]]);

    // §9.2, §7.3 — NTREESL, then the literal context map if NTREESL >= 2;
    // "otherwise, the context map has only zero values".
    const num_literal_trees = try readCount(Bits, br);
    if (num_literal_trees > huffman.max_trees) return error.TooManyTrees;
    header.num_trees[@intFromEnum(Category.literal)] = @intCast(num_literal_trees);
    const literal_map = header.context.literal_map[0 .. 64 * header.block_types[0]];
    if (num_literal_trees >= 2) {
        try context.readMap(
            Bits,
            br,
            &header.trees.context_map,
            literal_map,
            @intCast(num_literal_trees),
        );
    } else {
        fastmem.set(u8, literal_map, 0);
    }

    // NTREESD, then the distance context map.
    const num_distance_trees = try readCount(Bits, br);
    if (num_distance_trees > huffman.max_trees) return error.TooManyTrees;
    header.num_trees[@intFromEnum(Category.distance)] = @intCast(num_distance_trees);
    const distance_map = header.context.distance_map[0 .. 4 * header.block_types[2]];
    if (num_distance_trees >= 2) {
        try context.readMap(
            Bits,
            br,
            &header.trees.context_map,
            distance_map,
            @intCast(num_distance_trees),
        );
    } else {
        fastmem.set(u8, distance_map, 0);
    }

    // §9.2 — the tree groups, in order: "NTREESL prefix codes for literals;
    // NBLTYPESI prefix codes for insert-and-copy lengths; NTREESD prefix
    // codes for distances". The distance alphabet is dynamic: "16 + NDIRECT
    // + (48 << NPOSTFIX)" (§3.3, §4).
    const num_command_trees = header.block_types[@intFromEnum(Category.command)];
    header.num_trees[@intFromEnum(Category.command)] = num_command_trees;
    const postfix_slots: u32 = @as(u32, 48) << @intCast(header.npostfix);
    const distance_alphabet_size: u16 = @intCast(16 + header.ndirect + postfix_slots);
    for (0..num_literal_trees) |i| {
        try huffman.readTree(
            huffman.LiteralTree,
            Bits,
            br,
            &header.trees.literal[i],
            huffman.literal_alphabet_size,
        );
    }
    for (0..num_command_trees) |i| {
        try huffman.readTree(
            huffman.CommandTree,
            Bits,
            br,
            &header.trees.command[i],
            huffman.command_alphabet_size,
        );
    }
    for (0..num_distance_trees) |i| {
        try huffman.readTree(
            huffman.DistanceTree,
            Bits,
            br,
            &header.trees.distance[i],
            distance_alphabet_size,
        );
    }
}

/// `§9.2` — the 1..11-bit variable-length code shared by NBLTYPESL, NBLTYPESI,
/// NBLTYPESD, NTREESL, and NTREESD: the values 1..256, "as it appears in the
/// compressed data, where the bits are parsed from right to left". Returns
/// the count itself: the wire encodes count - 1, `0` being the single bit 0.
pub fn readCount(comptime Bits: type, br: *Bits) Bits.ErrorSet!u32 {
    if ((try br.take(1)) == 0) return 1;
    const nbits = try br.take(3);
    if (nbits == 0) return 2;
    const extra = try br.take(@intCast(nbits));
    return (@as(u32, 1) << @intCast(nbits)) + extra + 1;
}

/// `§6` — the 26-symbol block-count code: the number of extra bits and the
/// base of each range. "The block counts for any of the three categories
/// need not count down to exactly zero at the end of the meta-block", so a
/// count is not checked against MLEN here; the command layer's accounting
/// is where an overrun is caught.
const CountRow = struct {
    extra_bits: u5,
    base: u32,
};

const block_count_rows = [26]CountRow{
    .{ .extra_bits = 2, .base = 1 },     .{ .extra_bits = 2, .base = 5 },
    .{ .extra_bits = 2, .base = 9 },     .{ .extra_bits = 2, .base = 13 },
    .{ .extra_bits = 3, .base = 17 },    .{ .extra_bits = 3, .base = 25 },
    .{ .extra_bits = 3, .base = 33 },    .{ .extra_bits = 3, .base = 41 },
    .{ .extra_bits = 4, .base = 49 },    .{ .extra_bits = 4, .base = 65 },
    .{ .extra_bits = 4, .base = 81 },    .{ .extra_bits = 4, .base = 97 },
    .{ .extra_bits = 5, .base = 113 },   .{ .extra_bits = 5, .base = 145 },
    .{ .extra_bits = 5, .base = 177 },   .{ .extra_bits = 5, .base = 209 },
    .{ .extra_bits = 6, .base = 241 },   .{ .extra_bits = 6, .base = 305 },
    .{ .extra_bits = 7, .base = 369 },   .{ .extra_bits = 8, .base = 497 },
    .{ .extra_bits = 9, .base = 753 },   .{ .extra_bits = 10, .base = 1265 },
    .{ .extra_bits = 11, .base = 2289 }, .{ .extra_bits = 12, .base = 4337 },
    .{ .extra_bits = 13, .base = 8433 }, .{ .extra_bits = 24, .base = 16625 },
};

/// `§6` — one block count: a symbol from the 26-symbol count alphabet plus
/// its fixed-width extra bits. The command layer reads the switches' counts
/// through this too.
pub fn readBlockCount(
    comptime Bits: type,
    br: *Bits,
    tree: *const huffman.BlockCountTree,
) Bits.ErrorSet!u32 {
    const symbol = try tree.decode(Bits, br);
    const row = block_count_rows[symbol];
    return row.base + try br.take(row.extra_bits);
}

/// `§9.1` — the window arithmetic, for the 10..24 WBITS values.
fn window(wbits: u5) StreamHeader {
    assert(wbits >= 10);
    assert(wbits <= 24);
    return .{ .wbits = wbits, .window_size = (@as(u32, 1) << wbits) - 16 };
}

/// `§9.2` — the 2-bit MNIBBLES code: `11` is the metadata form (0 nibbles),
/// `00`/`01`/`10` are 4, 5, and 6 nibbles of MLEN-1.
fn readMnibbles(comptime Bits: type, br: *Bits) Bits.ErrorSet!u32 {
    const code = try br.take(2);
    if (code == 3) return 0;
    return code + 4;
}

/// `§9.2` — MLEN-1, in MNIBBLES 4-bit nibbles, least significant first. With
/// MNIBBLES > 4 "the last nibble" (the most significant one, read last) must
/// not be zero.
fn readMlen(comptime Bits: type, br: *Bits, mnibbles: u32) Errors(Bits)!u32 {
    assert(mnibbles >= 4);
    assert(mnibbles <= 6);
    var value: u32 = 0;
    var i: u32 = 0;
    while (i < mnibbles) : (i += 1) {
        const nibble = try br.take(4);
        if (mnibbles > 4 and i + 1 == mnibbles and nibble == 0) return error.ExuberantNibble;
        value |= nibble << @intCast(i * 4);
    }
    return value + 1;
}

/// `§9.2` — a metadata meta-block: the reserved bit, MSKIPBYTES, MSKIPLEN-1,
/// zero fill to the byte boundary, then MSKIPLEN bytes skipped. Those bytes
/// are never output, never window, and never literal context (`§2`).
fn skipMetadata(comptime Bits: type, br: *Bits) Errors(Bits)!void {
    if ((try br.take(1)) != 0) return error.ReservedBit;
    const mskip_bytes = try br.take(2);
    var mskip_len: u32 = 0;
    if (mskip_bytes != 0) {
        var value: u32 = 0;
        var i: u32 = 0;
        while (i < mskip_bytes) : (i += 1) {
            const byte = try br.take(8);
            if (mskip_bytes > 1 and i + 1 == mskip_bytes and byte == 0) {
                return error.ExuberantMetaNibble;
            }
            value |= byte << @intCast(i * 8);
        }
        mskip_len = value + 1;
    }
    try br.alignToByte();
    try br.skipBytes(mskip_len);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Drive the ladder over a stream whose meta-blocks are all of the
/// entropy-free kinds, collecting the output. Test-only: the reader in
/// `Reader.zig` decodes compressed meta-blocks; this helper handles only
/// the entropy-free forms, and `error.Compressed` is its marker when a
/// stream contains a compressed meta-block.
fn decodeEntropyFree(source: []const u8, target: []u8) !usize {
    var header: Header = undefined;
    var br: bits.BitReader = .init(source);
    _ = try readStreamHeader(bits.BitReader, &br);
    var out_pos: usize = 0;
    while (try nextMetaBlock(bits.BitReader, &br, &header)) |meta| {
        switch (meta.kind) {
            .uncompressed => {
                if (out_pos + meta.mlen > target.len) return error.BufferTooSmall;
                try br.takeBytes(target[out_pos..][0..meta.mlen]);
                out_pos += meta.mlen;
            },
            .compressed => return error.Compressed,
        }
    }
    return out_pos;
}

/// A parsed stream: its stream header and the bit position after the
/// meta-block header.
const Parsed = struct {
    stream: StreamHeader,
    br: bits.BitReader,
};

/// Parse one whole stream (header plus its single meta-block header) into a
/// `Header`, for the compressed-header tests.
fn parseHeader(source: []const u8, header: *Header) !Parsed {
    var br: bits.BitReader = .init(source);
    const stream = try readStreamHeader(bits.BitReader, &br);
    _ = (try nextMetaBlock(bits.BitReader, &br, header)).?;
    return .{ .stream = stream, .br = br };
}

/// WBITS 16, ISLAST=1, ISLASTEMPTY=0, MNIBBLES=4, MLEN-1, ISUNCOMPRESSED
/// absent — the common head of a single last compressed meta-block.
fn packMetaHead(p: *golden.Packer, mlen: u32) void {
    p.pack(0, 1);
    p.pack(1, 1);
    p.pack(0, 1);
    p.pack(0, 2);
    p.pack(mlen - 1, 16);
}

/// A simple NSYM = 1 tree (`§3.4`) for `symbol`, in `alphabet_bits` bits.
fn packSingle(p: *golden.Packer, symbol: u16, alphabet_bits: u5) void {
    p.pack(1, 2);
    p.pack(0, 2);
    p.pack(symbol, alphabet_bits);
}

/// One block type and one tree per category, NPOSTFIX 0, NDIRECT 0, mode
/// LSB6 — the head of the hand-built streams that vary only their trees.
fn packOneBlockHead(p: *golden.Packer) void {
    p.pack(0, 1); // NBLTYPESL = 1
    p.pack(0, 1); // NBLTYPESI = 1
    p.pack(0, 1); // NBLTYPESD = 1
    p.pack(0, 2); // NPOSTFIX = 0
    p.pack(0, 4); // NDIRECT = 0
    p.pack(0, 2); // context mode 0 = LSB6
    p.pack(0, 1); // NTREESL = 1
    p.pack(0, 1); // NTREESD = 1
}

test "stream header: every WBITS value from RFC 7932 §9.1's table" {
    // RFC 7932 §9.1 — the table's patterns, read right to left. Each entry
    // is the byte holding the pattern (the stream's first byte), its WBITS,
    // and the window size (1 << WBITS) - 16.
    const cases = [_]struct { byte: u8, wbits: u5, window_size: u32 }{
        .{ .byte = 0x21, .wbits = 10, .window_size = 1008 },
        .{ .byte = 0x31, .wbits = 11, .window_size = 2032 },
        .{ .byte = 0x41, .wbits = 12, .window_size = 4080 },
        .{ .byte = 0x51, .wbits = 13, .window_size = 8176 },
        .{ .byte = 0x61, .wbits = 14, .window_size = 16368 },
        .{ .byte = 0x71, .wbits = 15, .window_size = 32752 },
        .{ .byte = 0x00, .wbits = 16, .window_size = 65520 },
        .{ .byte = 0x01, .wbits = 17, .window_size = 131056 },
        .{ .byte = 0x03, .wbits = 18, .window_size = 262128 },
        .{ .byte = 0x05, .wbits = 19, .window_size = 524272 },
        .{ .byte = 0x07, .wbits = 20, .window_size = 1048560 },
        .{ .byte = 0x09, .wbits = 21, .window_size = 2097136 },
        .{ .byte = 0x0B, .wbits = 22, .window_size = 4194288 },
        .{ .byte = 0x0D, .wbits = 23, .window_size = 8388592 },
        .{ .byte = 0x0F, .wbits = 24, .window_size = 16777200 },
    };
    for (cases) |case| {
        const source = [_]u8{case.byte};
        var br: bits.BitReader = .init(&source);
        const header = try readStreamHeader(bits.BitReader, &br);
        try testing.expectEqual(case.wbits, header.wbits);
        try testing.expectEqual(case.window_size, header.window_size);
    }
}

test "stream header: 0010001 is refused, a starved header is truncated" {
    // RFC 7932 §9.1: "bit pattern 0010001 is invalid and must not be used" —
    // the reference family's large-window extension marker, out of scope.
    var invalid: bits.BitReader = .init(&[_]u8{0x11});
    try testing.expectError(error.BadWindowBits, readStreamHeader(bits.BitReader, &invalid));

    // RFC 7932 §10: a stream that ends before its last bit is invalid.
    var empty: bits.BitReader = .init(&[_]u8{});
    try testing.expectError(error.Truncated, readStreamHeader(bits.BitReader, &empty));
}

test "empty streams: RFC 7932 §9.2's last-empty forms decode to nothing" {
    // brotli-notes.md §7.2's hand-decoded family, re-verified against the
    // pinned CLI (brotli 1.2.0): every byte string is a whole stream that
    // decodes to zero bytes. The sentinel proves nothing was written.
    var target: [64]u8 = undefined;
    for (golden.empty_streams) |stream| {
        internal.sentinel.fill(&target);
        const n = try decodeEntropyFree(stream, &target);
        try testing.expectEqual(@as(usize, 0), n);
        try internal.sentinel.expect(&target, n);
    }
}

test "metadata: the ISLAST corner and the payload skip" {
    // brotli-notes.md §7.2 / T5: a metadata meta-block with ISLAST=1 ends
    // the stream (the last-empty form is not the only terminator).
    var target: [8]u8 = undefined;
    for (golden.last_metadata_streams) |stream| {
        internal.sentinel.fill(&target);
        const n = try decodeEntropyFree(stream, &target);
        try testing.expectEqual(@as(usize, 0), n);
        try internal.sentinel.expect(&target, n);
    }

    // A metadata payload in the middle of a stream is skipped: its bytes are
    // neither output nor literal context (§2).
    var wide: [16]u8 = undefined;
    for (golden.metadata_streams) |stream| {
        internal.sentinel.fill(&wide);
        const n = try decodeEntropyFree(stream.bytes, &wide);
        try testing.expectEqual(stream.plain.len, n);
        try testing.expectEqualSlices(u8, stream.plain, wide[0..n]);
        try internal.sentinel.expect(&wide, n);
    }
}

test "metadata: the 65,536-block empty chain decodes to nothing" {
    // brotli-notes.md §7.2's `.17` fixture (google/brotli's
    // `empty.compressed.17`, re-verified against the pinned CLI): WBITS 17,
    // ISLAST=0, then 65,536 empty metadata meta-blocks, then the last-empty
    // terminator — 65,538 bytes. The first block's header is completed by
    // the byte boundary, the rest are the one-byte `06` form.
    var stream: [65538]u8 = undefined;
    stream[0] = 0x01; // WBITS 17, ISLAST=0
    stream[1] = 0x03; // the first metadata header, completed by the boundary
    fastmem.set(u8, stream[2..65537], 0x06);
    stream[65537] = 0x03;
    var target: [4]u8 = undefined;
    internal.sentinel.fill(&target);
    const n = try decodeEntropyFree(&stream, &target);
    try testing.expectEqual(@as(usize, 0), n);
    try internal.sentinel.expect(&target, n);
}

test "uncompressed meta-blocks pass their bytes through" {
    // RFC 7932 §9.2: "the rest of the meta-block contains MLEN bytes of
    // literal data" at the next byte boundary.
    var target: [16]u8 = undefined;
    for (golden.uncompressed_streams) |stream| {
        internal.sentinel.fill(&target);
        const n = try decodeEntropyFree(stream.bytes, &target);
        try testing.expectEqual(stream.plain.len, n);
        try testing.expectEqualSlices(u8, stream.plain, target[0..n]);
        try internal.sentinel.expect(&target, n);
    }

    // The same header with MLEN = 100 (MNIBBLES=4, MLEN-1 = 99), the largest
    // 4-nibble length, and a payload that is not constant.
    var long_target: [128]u8 = undefined;
    var hundred: [104]u8 = undefined;
    const long_header = [_]u8{ 0x30, 0x06, 0x10 };
    fastmem.copy(u8, hundred[0..3], &long_header);
    for (hundred[3..103], 0..) |*byte, i| byte.* = @intCast(i);
    hundred[103] = 0x03;
    internal.sentinel.fill(&long_target);
    const long_n = try decodeEntropyFree(&hundred, &long_target);
    try testing.expectEqual(@as(usize, 100), long_n);
    for (long_target[0..long_n], 0..) |byte, i| {
        try testing.expectEqual(@as(u8, @intCast(i)), byte);
    }
    try internal.sentinel.expect(&long_target, long_n);
}

test "uncompressed meta-blocks: the RFC 7932 §11.1 trivial compressor's streams" {
    // RFC 7932 §11.1: every N-byte input has a valid stream of at most
    // N + (3 * (N >> 16) + 5) bytes. The C++ is ported in `golden.zig` and
    // its output decoded by the ladder; the 100,000-byte case meets the
    // bound exactly (100,008 bytes), the fixture the research measured
    // through both oracles.
    var source: [100_000]u8 = undefined;
    for (&source, 0..) |*byte, i| byte.* = @intCast((i * 7 + 3) & 0xFF);

    const stream = try testing.allocator.alloc(u8, golden.trivialBound(source.len));
    defer testing.allocator.free(stream);
    const stream_len = golden.trivialCompress(&source, stream);
    try testing.expectEqual(golden.trivialBound(source.len), stream_len);

    const target = try testing.allocator.alloc(u8, source.len);
    defer testing.allocator.free(target);
    internal.sentinel.fill(target);
    const n = try decodeEntropyFree(stream[0..stream_len], target);
    try testing.expectEqual(@as(usize, source.len), n);
    try testing.expectEqualSlices(u8, &source, target[0..n]);
    try internal.sentinel.expect(target, n);

    // The research's small fixture: "hello world" (11 bytes) in 16 bytes.
    const hello = golden.trivialCompressToBuf("hello world");
    try testing.expectEqual(@as(usize, 16), hello.len);
    var small: [16]u8 = undefined;
    internal.sentinel.fill(&small);
    const small_n = try decodeEntropyFree(&hello, &small);
    try testing.expectEqual(@as(usize, 11), small_n);
    try testing.expectEqualSlices(u8, "hello world", small[0..small_n]);
    try internal.sentinel.expect(&small, small_n);
}

test "meta-block ladder: a compressed meta-block's header runs past the ladder" {
    // A compressed meta-block whose MLEN is the format's maximum: ISLAST=0,
    // MNIBBLES=6, MLEN-1 = 0xFFFFFF, ISUNCOMPRESSED=0. The ladder reads the
    // header through ISUNCOMPRESSED and the compressed header's completion
    // follows: NBLTYPESL is next, and this four-byte stream ends before it.
    var br: bits.BitReader = .init(&[_]u8{ 0xF8, 0xFF, 0xFF, 0x0F });
    var header: Header = undefined;
    _ = try readStreamHeader(bits.BitReader, &br);
    try testing.expectError(error.Truncated, nextMetaBlock(bits.BitReader, &br, &header));
}

test "meta-block ladder: the named refusals" {
    // RFC 7932 §9.2 — the reserved bit must be zero.
    var reserved: bits.BitReader = .init(&[_]u8{0x3A});
    var header: Header = undefined;
    _ = try readStreamHeader(bits.BitReader, &reserved);
    try testing.expectError(error.ReservedBit, nextMetaBlock(bits.BitReader, &reserved, &header));

    // RFC 7932 §9.2 — MNIBBLES > 4 with an all-zero last nibble.
    var nibble: bits.BitReader = .init(&[_]u8{ 0x2A, 0x00, 0x00, 0x00 });
    _ = try readStreamHeader(bits.BitReader, &nibble);
    try testing.expectError(error.ExuberantNibble, nextMetaBlock(bits.BitReader, &nibble, &header));

    // RFC 7932 §9.2 — MSKIPBYTES > 1 with an all-zero last byte.
    var meta_nibble: bits.BitReader = .init(&[_]u8{ 0xCC, 0x00, 0x00 });
    _ = try readStreamHeader(bits.BitReader, &meta_nibble);
    try testing.expectError(
        error.ExuberantMetaNibble,
        nextMetaBlock(bits.BitReader, &meta_nibble, &header),
    );

    // RFC 7932 §9.2 — ISLASTEMPTY's fill bits must be zero.
    var fill: bits.BitReader = .init(&[_]u8{0x0E});
    _ = try readStreamHeader(bits.BitReader, &fill);
    try testing.expectError(error.BadPadding, nextMetaBlock(bits.BitReader, &fill, &header));

    // RFC 7932 §9.2 — a metadata block's fill bits must be zero.
    var meta_fill: bits.BitReader = .init(&[_]u8{ 0x8C, 0x03 });
    _ = try readStreamHeader(bits.BitReader, &meta_fill);
    try testing.expectError(error.BadPadding, nextMetaBlock(bits.BitReader, &meta_fill, &header));

    // RFC 7932 §9.2 — ISUNCOMPRESSED's skipped bits must be zero.
    var uncompressed_fill: bits.BitReader = .init(&[_]u8{ 0x10, 0x00, 0x30, 'h', 'i', 0x03 });
    _ = try readStreamHeader(bits.BitReader, &uncompressed_fill);
    try testing.expectError(
        error.BadPadding,
        nextMetaBlock(bits.BitReader, &uncompressed_fill, &header),
    );
}

test "meta-block ladder: a stream that ends inside its header is truncated" {
    // RFC 7932 §10: "If the stream ends before the completion of the last
    // meta-block, then the stream should be rejected as invalid." Every
    // prefix of a metadata stream, and an uncompressed block missing its
    // payload byte, must be refused.
    const stream = golden.last_metadata_streams[1];
    for (0..stream.len - 1) |n| {
        var br: bits.BitReader = .init(stream[0..n]);
        _ = readStreamHeader(bits.BitReader, &br) catch continue;
        const result = nextMetaBlock(bits.BitReader, &br, undefined);
        try testing.expectError(error.Truncated, result);
    }

    // An uncompressed meta-block whose payload stops one byte short: the
    // declared MLEN is 2, the input holds one payload byte and no
    // terminator. (A failed decode may have written output up to the
    // failure point; the sentinel rule is the successful decode's.)
    const short = [_]u8{ 0x10, 0x00, 0x10, 'h', 0x03 };
    var target: [8]u8 = undefined;
    try testing.expectError(error.Truncated, decodeEntropyFree(&short, &target));
}

test "readCount: every value of RFC 7932 §9.2's variable-length code" {
    // RFC 7932 §9.2 — the code for NBLTYPESL/I/D and NTREESL/NTREESD, read
    // right to left: 0 → 1, 0001 → 2, x0011 → 3..4, xx0101 → 5..8,
    // xxx0111 → 9..16, xxxx1001 → 17..32, xxxxx1011 → 33..64,
    // xxxxxx1101 → 65..128, xxxxxxx1111 → 129..256.
    for (1..257) |count| {
        var packer: golden.Packer = .empty;
        packCount(&packer, @intCast(count));
        var br: bits.BitReader = .init(packer.slice());
        try testing.expectEqual(@as(u32, @intCast(count)), try readCount(bits.BitReader, &br));
        // Exactly the table's bits were consumed, no more (the last packed
        // byte's padding bits are not the code's).
        try testing.expectEqual(@as(u64, packer.bit_len), br.bit_pos);
    }
}

/// The inverse of `readCount`: the §9.2 table read forward.
fn packCount(p: *golden.Packer, count: u32) void {
    assert(count >= 1);
    assert(count <= 256);
    if (count == 1) {
        p.pack(0, 1);
        return;
    }
    if (count == 2) {
        p.pack(1, 1);
        p.pack(0, 3);
        return;
    }
    const value = count - 1;
    var nbits: u5 = 1;
    while ((@as(u32, 1) << (nbits + 1)) <= value) : (nbits += 1) {}
    p.pack(1, 1);
    p.pack(nbits, 3);
    p.pack(value - (@as(u32, 1) << nbits), nbits);
}

test "compressed header: the day-one fixture's whole ladder" {
    // brotli-notes.md §7.3's `hand.br` (re-verified against the pinned CLI):
    // WBITS 16, a last MLEN=1 compressed meta-block, one block type and one
    // tree per category, NPOSTFIX 0/NDIRECT 0, mode LSB6, and three simple
    // NSYM = 1 codes whose symbols consume no bits.
    var header: Header = undefined;
    const parsed = try parseHeader(golden.hand_stream.bytes, &header);
    try testing.expectEqual(@as(u5, 16), parsed.stream.wbits);
    var br = parsed.br;
    try testing.expectEqual(@as(u64, 70), br.bit_pos);

    // §9.2, §6 — one block type per category, and BLEN = 16777216.
    try testing.expectEqualSlices(u16, &[_]u16{ 1, 1, 1 }, &header.block_types);
    const single_type_count = [_]u32{ 1 << 24, 1 << 24, 1 << 24 };
    try testing.expectEqualSlices(u32, &single_type_count, &header.first_block_count);
    // §9.2, §4 — NPOSTFIX 0 and NDIRECT 0.
    try testing.expectEqual(@as(u3, 0), header.npostfix);
    try testing.expectEqual(@as(u8, 0), header.ndirect);
    // §9.2, §7.1 — the one literal block type's mode.
    try testing.expectEqual(context.Mode.lsb6, header.context.modes[0]);
    // §9.2 — one tree in each group.
    try testing.expectEqualSlices(u16, &[_]u16{ 1, 1, 1 }, &header.num_trees);
    // §3.4 — the three NSYM = 1 codes (T7's ALPHABET_BITS widths).
    try testing.expectEqual(@as(?u16, 65), header.trees.literal[0].single);
    try testing.expectEqual(@as(?u16, 8), header.trees.command[0].single);
    try testing.expectEqual(@as(?u16, 0), header.trees.distance[0].single);
    // The command stream: the IaC symbol, then the literal — no bits.
    try testing.expectEqual(@as(u16, 8), try header.trees.command[0].decode(bits.BitReader, &br));
    try testing.expectEqual(@as(u16, 65), try header.trees.literal[0].decode(bits.BitReader, &br));
    try testing.expectEqual(@as(u64, 70), br.bit_pos);
}

test "compressed header: RFC 7932 §3.4's simple-form goldens" {
    // The sorted-order rule (§3.4): symbols (66, 65) still assign 65 code 0.
    var header: Header = undefined;
    var br = (try parseHeader(golden.unordered_symbol_stream.bytes, &header)).br;
    try testing.expectEqual(@as(u16, 65), try header.trees.literal[0].decode(bits.BitReader, &br));

    // T7 — ALPHABET_BITS is the width of the largest symbol: {200, 65} in
    // 8 bits is a valid tree, and the 7-bit variant is corrupt.
    var wide: Header = undefined;
    var wide_br = (try parseHeader(golden.wide_symbol_stream.bytes, &wide)).br;
    const wide_symbol = try wide.trees.literal[0].decode(bits.BitReader, &wide_br);
    try testing.expectEqual(@as(u16, 65), wide_symbol);

    // The shifted parse runs out of input, the CLI's "corrupt input"; T7's
    // point is that the two readings differ on the wire at all.
    var floor_log: Header = undefined;
    try testing.expectError(
        error.Truncated,
        parseHeader(golden.floor_log_stream[0..], &floor_log),
    );

    // The unreachability half of T7: a literal field of 256 in an 8-bit
    // alphabet reads as 0, so the tree decodes symbol 0.
    var high: Header = undefined;
    var high_br = (try parseHeader(golden.high_literal_stream.bytes, &high)).br;
    const high_symbol = try high.trees.literal[0].decode(bits.BitReader, &high_br);
    try testing.expectEqual(@as(u16, 0), high_symbol);

    // §3.4's two rejections.
    for (golden.duplicate_symbol_streams) |stream| {
        var dup: Header = undefined;
        try testing.expectError(error.SimpleHuffmanSame, parseHeader(stream, &dup));
    }
    for (golden.out_of_alphabet_streams) |stream| {
        var out: Header = undefined;
        try testing.expectError(error.SimpleHuffmanAlphabet, parseHeader(stream, &out));
    }
}

test "compressed header: RFC 7932 §3.5's complex-form goldens" {
    var header: Header = undefined;
    var br = (try parseHeader(golden.complex_tree_stream.bytes, &header)).br;
    try testing.expectEqual(@as(u16, 65), try header.trees.literal[0].decode(bits.BitReader, &br));

    var single: Header = undefined;
    var single_br = (try parseHeader(golden.complex_single_stream.bytes, &single)).br;
    try testing.expectEqual(
        @as(u16, 0),
        try single.trees.literal[0].decode(bits.BitReader, &single_br),
    );

    var repeat: Header = undefined;
    var repeat_br = (try parseHeader(golden.repeat16_stream.bytes, &repeat)).br;
    try testing.expectEqual(
        @as(u16, 10),
        try repeat.trees.literal[0].decode(bits.BitReader, &repeat_br),
    );
}

test "compressed header: RFC 7932 §7.3's context map selects the tree" {
    // The golden stream's map is NTREESL = 2, RLEMAX = 1, raw [1, 1, 0, ...],
    // IMTF: the decoded map is [1, 0, 0, ...].
    var header: Header = undefined;
    _ = try parseHeader(golden.context_map_stream.bytes, &header);
    try testing.expectEqual(@as(u16, 2), header.num_trees[0]);
    try testing.expectEqual(@as(u8, 1), header.context.literal_map[0]);
    try testing.expectEqual(@as(u8, 0), header.context.literal_map[1]);
    for (header.context.literal_map[2..64]) |value| try testing.expectEqual(@as(u8, 0), value);
    // The two literal trees decode the two bytes of "BA".
    try testing.expectEqual(@as(?u16, 66), header.trees.literal[1].single);
    try testing.expectEqual(@as(?u16, 65), header.trees.literal[0].single);
    // NTREESD = 1: the distance map is all zeros.
    try testing.expectEqual(@as(u16, 1), header.num_trees[2]);
    for (header.context.distance_map[0..4]) |value| try testing.expectEqual(@as(u8, 0), value);
}

test "compressed header: OQ8's tree cap fails TooManyTrees" {
    // NTREESL = 65: the region holds 64.
    var p: golden.Packer = .empty;
    packMetaHead(&p, 1);
    p.pack(0, 1); // NBLTYPESL = 1
    p.pack(0, 1); // NBLTYPESI = 1
    p.pack(0, 1); // NBLTYPESD = 1
    p.pack(0, 2); // NPOSTFIX = 0
    p.pack(0, 4); // NDIRECT = 0
    p.pack(0, 2); // mode LSB6
    packCount(&p, 65); // NTREESL = 65
    var header: Header = undefined;
    try testing.expectError(error.TooManyTrees, parseHeader(p.slice(), &header));

    // NBLTYPESI = 65: the command trees are the region's command category.
    var q: golden.Packer = .empty;
    packMetaHead(&q, 1);
    q.pack(0, 1); // NBLTYPESL = 1
    packCount(&q, 65); // NBLTYPESI = 65
    var command: Header = undefined;
    try testing.expectError(error.TooManyTrees, parseHeader(q.slice(), &command));
}

test "compressed header: RFC 7932 §3.3's dynamic distance alphabet" {
    // NPOSTFIX = 2, NDIRECT = 3 << 2 = 12: the alphabet is
    // 16 + 12 + (48 << 2) = 220, so ALPHABET_BITS is 8 and symbol 219 is the
    // last valid one — symbol 220 is not.
    const build = struct {
        fn call(p: *golden.Packer, symbol: u16) void {
            packMetaHead(p, 1);
            p.pack(0, 1); // NBLTYPESL = 1
            p.pack(0, 1); // NBLTYPESI = 1
            p.pack(0, 1); // NBLTYPESD = 1
            p.pack(2, 2); // NPOSTFIX = 2
            p.pack(3, 4); // NDIRECT = 3 << 2 = 12
            p.pack(0, 2); // mode LSB6
            p.pack(0, 1); // NTREESL = 1
            p.pack(0, 1); // NTREESD = 1
            packSingle(p, 65, 8); // literal
            packSingle(p, 8, 10); // insert-and-copy
            packSingle(p, symbol, 8); // distance
        }
    };
    var p: golden.Packer = .empty;
    build.call(&p, 219);
    var header: Header = undefined;
    _ = try parseHeader(p.slice(), &header);
    try testing.expectEqual(@as(u3, 2), header.npostfix);
    try testing.expectEqual(@as(u8, 12), header.ndirect);
    try testing.expectEqual(@as(?u16, 219), header.trees.distance[0].single);

    var over: golden.Packer = .empty;
    build.call(&over, 220);
    var rejected: Header = undefined;
    try testing.expectError(error.SimpleHuffmanAlphabet, parseHeader(over.slice(), &rejected));
}

test "compressed header: the arena's byte figure" {
    // The README's Stack bullet states this figure: the tree region (OQ8's
    // cap) plus the context-model arena. It moves with either.
    try testing.expectEqual(@as(usize, 707_204), @sizeOf(Header));
}

test "compressed header: RFC 7932 §6's block-count rows tile the count space" {
    // The RFC's table: each row's range ends one below the next row's base.
    // Row 0 is anchored here and the loop pins the 24 rows above it, so a
    // base mutated by one no longer fits the row below; the last row's range
    // top is the RFC's 16793840.
    try testing.expectEqual(@as(u32, 1), block_count_rows[0].base);
    inline for (0..25) |i| {
        try testing.expectEqual(
            block_count_rows[i + 1].base,
            block_count_rows[i].base + (@as(u32, 1) << block_count_rows[i].extra_bits),
        );
    }
    try testing.expectEqual(
        @as(u32, 16793840),
        block_count_rows[25].base + (@as(u32, 1) << 24) - 1,
    );
}

test "compressed header: RFC 7932 §6's first block count" {
    // NBLTYPESL = 2 reads the literal block-type tree, the block-count tree,
    // and the first literal block count (§9.2). The count tree is a simple
    // NSYM = 1 code for symbol 3, whose range is 13..16 with two extra bits.
    var p: golden.Packer = .empty;
    packMetaHead(&p, 1);
    packCount(&p, 2); // NBLTYPESL = 2
    p.pack(1, 2); // the literal block-type tree: simple form
    p.pack(1, 2); // NSYM = 2
    p.pack(0, 2); // symbol 0 (ALPHABET_BITS = 2 for NBLTYPESL + 2 = 4)
    p.pack(1, 2); // symbol 1
    packSingle(&p, 3, 5); // the block-count tree: symbol 3, ALPHABET_BITS 5
    p.pack(2, 2); // the first count: base 13 + 2 = 15
    p.pack(0, 1); // NBLTYPESI = 1
    p.pack(0, 1); // NBLTYPESD = 1
    p.pack(0, 2); // NPOSTFIX = 0
    p.pack(0, 4); // NDIRECT = 0
    p.pack(0, 2); // the two literal block types' modes: both LSB6
    p.pack(0, 2);
    p.pack(0, 1); // NTREESL = 1
    p.pack(0, 1); // NTREESD = 1
    packSingle(&p, 65, 8);
    packSingle(&p, 8, 10);
    packSingle(&p, 0, 6);
    var header: Header = undefined;
    _ = try parseHeader(p.slice(), &header);
    try testing.expectEqual(@as(u16, 2), header.block_types[0]);
    try testing.expectEqual(@as(u32, 15), header.first_block_count[0]);
    try testing.expectEqual(@as(u32, 1 << 24), header.first_block_count[1]);
    try testing.expectEqual(context.Mode.lsb6, header.context.modes[1]);
    // The literal context map (64 × NBLTYPESL = 128 entries) is all zeros:
    // one tree.
    for (header.context.literal_map[0..128]) |value| try testing.expectEqual(@as(u8, 0), value);
}
