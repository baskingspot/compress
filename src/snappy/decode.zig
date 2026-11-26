//! Snappy block decoder with a SIMD overlapping-copy fast path. Entry points:
//! `decompressBlock` and `decompressedBlockLength`.
//!
//! The tag stream is decoded sequentially (a copy can reference bytes just
//! written). The speed is in how copies run:
//!
//!   - `offset >= length` (no overlap): a plain `fastmem.copy`.
//!   - `offset <= 16` (overlapping, RLE-like): the `offset`-byte pattern is
//!     replicated into a 16-byte register with one byte shuffle (`tbl` on
//!     AArch64, `pshufb` on x86_64) and stored in 16-byte chunks.
//!   - `offset > 16`: the 16-byte source window does not overlap the store, so
//!     a vectorized chunk copy is correct.
//!
//! Targets without those instructions use the same masks with a byte-wise
//! permute (`shuffleBytes`) and produce the same output.
//!
//! Format: https://github.com/google/snappy/blob/main/format_description.txt

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const copyMatch = internal.match.copyMatch;
const common = @import("common.zig");
const readInt = common.readInt;
const readUvarint = common.readUvarint;

/// Errors from `decompressBlock` and `decompressedBlockLength`.
/// `BufferTooSmall`: `target` is shorter than the block's declared length.
/// `DecompressionFailed`: the block is corrupt or truncated.
pub const DecompressError = error{ BufferTooSmall, DecompressionFailed };

/// The decompressed length a raw snappy block declares in its header. Reads
/// only the header; the rest of the block is not checked. Returns
/// `error.DecompressionFailed` if the header is truncated or malformed. The
/// value comes from the block and can be up to 2^32 - 1, so limit it before
/// allocating a buffer for untrusted input.
pub fn decompressedBlockLength(source: []const u8) DecompressError!usize {
    var pos: usize = 0;
    return readUvarint(source, &pos);
}

/// Decompress a raw snappy block from `source` into `target` and return the
/// number of bytes written, which on success is the block's declared length.
///
/// Returns `error.BufferTooSmall` if `target` is shorter than the declared
/// length (see `decompressedBlockLength`), before writing anything. Returns
/// `error.DecompressionFailed` if the block is corrupt: a bad header, an
/// element that runs past `source`, a copy offset of zero or before the start
/// of the output, output that overshoots or falls short of the declared
/// length, or trailing bytes. Never writes past the declared length; after an
/// error the contents of `target` are unspecified. Does not allocate.
pub fn decompressBlock(source: []const u8, target: []u8) DecompressError!usize {
    var in_pos: usize = 0;
    const uncomp_len = try readUvarint(source, &in_pos);
    if (uncomp_len > target.len) return error.BufferTooSmall;

    // One element per tag until `source` ends. `decodeLiteral` and `decodeCopy`
    // enforce the declared length per element; the check after the loop
    // catches a block that ends short.
    var out_pos: usize = 0;
    while (in_pos < source.len) {
        const tag = source[in_pos];
        in_pos += 1;

        switch (tag & 3) {
            0 => try decodeLiteral(source, &in_pos, target, &out_pos, uncomp_len),
            1 => {
                // Copy with 1-byte offset: length = ((tag >> 2) & 7) + 4,
                // offset = ((tag >> 5) << 8) | next_byte. The offset spans the
                // tag bits, so it is not a plain little-endian read.
                const length: usize = @as(usize, (tag >> 2) & 0x07) + 4;
                if (in_pos >= source.len) return error.DecompressionFailed;
                const offset: usize = (@as(usize, tag >> 5) << 8) | @as(usize, source[in_pos]);
                in_pos += 1;
                try decodeCopy(target, &out_pos, uncomp_len, offset, length);
            },
            2 => {
                // Copy with 2-byte offset: length = (tag >> 2) + 1,
                // offset = next 2 bytes LE.
                const length: usize = @as(usize, tag >> 2) + 1;
                if (in_pos + 2 > source.len) return error.DecompressionFailed;
                const offset: usize = readInt(u16, source.ptr[in_pos..][0..2]);
                in_pos += 2;
                try decodeCopy(target, &out_pos, uncomp_len, offset, length);
            },
            3 => {
                // Copy with 4-byte offset: length = (tag >> 2) + 1,
                // offset = next 4 bytes LE.
                const length: usize = @as(usize, tag >> 2) + 1;
                if (in_pos + 4 > source.len) return error.DecompressionFailed;
                const offset: usize = readInt(u32, source.ptr[in_pos..][0..4]);
                in_pos += 4;
                try decodeCopy(target, &out_pos, uncomp_len, offset, length);
            },
            else => unreachable,
        }
    }

    if (out_pos != uncomp_len) return error.DecompressionFailed;
    return out_pos;
}

/// Decode one literal tag: the 6-bit field (tag >> 2) encodes the length.
/// 0–59 => length = field + 1. 60–63 => length is in the next 1–4 bytes
/// (LE), plus 1. The caller has already consumed the tag byte.
fn decodeLiteral(
    source: []const u8,
    in_pos: *usize,
    target: []u8,
    out_pos: *usize,
    uncomp_len: usize,
) DecompressError!void {
    const code6: u8 = source[in_pos.* - 1] >> 2;
    var length: usize = undefined;
    if (code6 < 60) {
        length = @as(usize, code6) + 1;
    } else {
        const extra: usize = @as(usize, code6) - 59; // 60→1 .. 63→4
        if (in_pos.* + extra > source.len) return error.DecompressionFailed;
        var field: usize = 0;
        var i: usize = 0;
        while (i < extra) : (i += 1) {
            field += @as(usize, source[in_pos.* + i]) << @intCast(i * 8);
        }
        in_pos.* += extra;
        // Spec §2.1: the extended length is at most 2^32 - 1. Bound it by
        // the remaining output before adding 1, so `field + 1` cannot wrap
        // even on 32-bit targets.
        if (field >= uncomp_len - out_pos.*) return error.DecompressionFailed;
        length = field + 1;
    }
    if (in_pos.* + length > source.len) return error.DecompressionFailed;
    if (out_pos.* + length > uncomp_len) return error.DecompressionFailed;
    fastmem.copy(u8, target[out_pos.*..][0..length], source[in_pos.*..][0..length]);
    in_pos.* += length;
    out_pos.* += length;
}

/// Validate and apply one copy tag: a zero or backwards offset is corrupt,
/// and a length past `uncomp_len` is corrupt. The caller has already consumed
/// the tag byte and the offset bytes.
fn decodeCopy(
    target: []u8,
    out_pos: *usize,
    uncomp_len: usize,
    offset: usize,
    length: usize,
) DecompressError!void {
    if (offset == 0 or offset > out_pos.*) return error.DecompressionFailed;
    if (out_pos.* + length > uncomp_len) return error.DecompressionFailed;
    copyMatch(target, out_pos.*, offset, length);
    out_pos.* += length;
}

test "decompress: empty block" {
    // Spec: snappy-format-description.txt §1 (preamble: dLen=0).
    const block = [_]u8{0x00}; // varint(0)
    const dlen = try decompressedBlockLength(&block);
    try testing.expectEqual(@as(usize, 0), dlen);
    var target: [1]u8 = undefined;
    const blen = try decompressBlock(&block, &target);
    try testing.expectEqual(@as(usize, 0), blen);
}

test "decompress: literal-only block" {
    // Spec: snappy-format-description.txt §2.1 (literal tag).
    // varint(13) + literal tag (13-1)<<2=0x30 + 13 bytes.
    const msg = "hello, snappy";
    var block: [16]u8 = undefined;
    block[0] = 0x0D;
    block[1] = 0x30;
    fastmem.copy(u8, block[2..][0..msg.len], msg);
    const dlen = try decompressedBlockLength(block[0 .. 2 + msg.len]);
    try testing.expectEqual(msg.len, dlen);
    var target: [32]u8 = undefined;
    const blen = try decompressBlock(block[0 .. 2 + msg.len], &target);
    try testing.expectEqualSlices(u8, msg, target[0..blen]);
}

test "decompress: copy with 1-byte offset (overlapping RLE)" {
    // Spec: snappy-format-description.txt §2.2.1 (copy-1 tag).
    // Decompressed: "ABABABAB" (8 bytes).
    // varint(8)=0x08, literal "AB" (tag 0x04), copy len6 off2 (0x09 0x02).
    const snappy_block = [_]u8{ 0x08, 0x04, 'A', 'B', 0x09, 0x02 };
    var target: [8]u8 = undefined;
    const blen = try decompressBlock(&snappy_block, &target);
    try testing.expectEqual(@as(usize, 8), blen);
    try testing.expectEqualSlices(u8, "ABABABAB", target[0..blen]);
}

test "decompress: copy with 2-byte offset" {
    // Spec: snappy-format-description.txt §2.2.2 (copy-2 tag).
    // Decompressed: "XXXX" + 64 bytes of 'Y' (68 bytes total).
    // varint(68)=0x44, literal "XXXX" (tag 0x0C), copy len64 off4 (0xFE 0x04 0x00).
    const snappy_block = [_]u8{ 0x44, 0x0C, 'X', 'X', 'X', 'X', 0xFE, 0x04, 0x00 };
    var target: [68]u8 = undefined;
    const blen = try decompressBlock(&snappy_block, &target);
    try testing.expectEqual(@as(usize, 68), blen);
    try testing.expectEqualSlices(u8, "XXXX", target[0..4]);
    for (target[4..68], 0..) |b, i| {
        try testing.expectEqual(target[i % 4], b);
    }
}

test "decompress: overlapping copy offset 1 (single-byte run)" {
    // Spec: snappy-format-description.txt §2.2 (overlapping copy).
    // varint(5)=0x05, literal "A" (tag 0x00), copy len4 off1 (0x01 0x01).
    const snappy_block = [_]u8{ 0x05, 0x00, 'A', 0x01, 0x01 };
    var target: [5]u8 = undefined;
    const blen = try decompressBlock(&snappy_block, &target);
    try testing.expectEqual(@as(usize, 5), blen);
    try testing.expectEqualSlices(u8, "AAAAA", target[0..blen]);
}

test "decompress: corrupt block returns DecompressionFailed" {
    // Spec: snappy-format-description.txt §1 (truncated preamble).
    const bad = [_]u8{0x80}; // truncated varint
    var target: [8]u8 = undefined;
    try testing.expectError(error.DecompressionFailed, decompressBlock(&bad, &target));
    try testing.expectError(error.DecompressionFailed, decompressedBlockLength(&bad));
}

test "decompress: too-small target buffer returns BufferTooSmall" {
    // Spec: snappy-format-description.txt §1 (dLen).
    // varint(13) + literal tag + 13 bytes, but target is only 4 bytes.
    const msg = "hello, snappy";
    var block: [16]u8 = undefined;
    block[0] = 0x0D;
    block[1] = 0x30;
    fastmem.copy(u8, block[2..][0..msg.len], msg);
    var target: [4]u8 = undefined;
    const block_view = block[0 .. 2 + msg.len];
    try testing.expectError(error.BufferTooSmall, decompressBlock(block_view, &target));
}

test "copyMatch: non-overlapping uses plain copy" {
    var buf: [64]u8 = undefined;
    fastmem.set(u8, &buf, 0);
    fastmem.copy(u8, buf[0..8], "abcdefgh");
    copyMatch(&buf, 16, 16, 8); // copy buf[0..8] to buf[16..24]
    try testing.expectEqualSlices(u8, "abcdefgh", buf[16..24]);
}

test "copyMatch: SIMD shuffle for small offsets round-trips" {
    // Exercise the shuffle path for every offset 1..16 with a length that
    // spans multiple 16-byte chunks plus a tail.
    for (1..17) |offset| {
        var buf: [256]u8 = undefined;
        fastmem.set(u8, &buf, 0);
        // Seed the first `offset` bytes with a recognizable pattern.
        for (0..offset) |i| buf[i] = @intCast(0xA0 + (i % 16));
        const length = 64 + offset; // > 16, forces chunked stores + tail
        copyMatch(&buf, offset, offset, length);
        // Verify the repeating pattern across the whole copied region.
        for (0..length) |i| {
            try testing.expectEqual(buf[i % offset], buf[offset + i]);
        }
    }
}

// ---------------------------------------------------------------------------
// Note on encoder golden vectors: Snappy does not mandate a canonical
// compressed form (golang/snappy's snappy_test.go: "There is more than one
// valid encoding of any given input"). So encoder output is not compared byte
// for byte against reference corpora, only round-tripped through our decoder,
// which accepts any valid block. The decode vectors in golden.zig are the
// interop bar.
// ---------------------------------------------------------------------------

test "golden decode: format_description.txt hand examples" {
    // Spec: docs/specs/snappy-format-description.txt §2.2 (copies):
    //   "xababab" could be encoded as <literal: "xab"> <copy: offset=2 length=4>
    // Decompressed = "xababab" (3 literal + 4 copied from offset 2 → "abab").
    //   varint(7)=0x07, literal "xab" (tag (3-1)<<2=0x08), copy1 len4 off2
    //   (tag = 01|((4-4)<<2)|((2>>8)<<5) = 0x01, off byte 0x02).
    const block = [_]u8{ 0x07, 0x08, 'x', 'a', 'b', 0x01, 0x02 };
    var target: [7]u8 = undefined;
    const n = try decompressBlock(&block, &target);
    try testing.expectEqualSlices(u8, "xababab", target[0..n]);
}

test "golden decode: varint prefix examples from the spec" {
    // Section 1 (Preamble): uncompressed length 64 -> 0x40; 2097150 (0x1FFFFE)
    // -> 0xFE 0xFF 0x7F. We only need decompressedBlockLength to read them back.
    var pos: usize = 0;
    try testing.expectEqual(@as(usize, 64), try readUvarint(&[_]u8{0x40}, &pos));
    pos = 0;
    try testing.expectEqual(@as(usize, 2097150), try readUvarint(&[_]u8{ 0xFE, 0xFF, 0x7F }, &pos));
}
