//! LZ4 block decoder. Entry point: `decompressBlock`.
//!
//! Sequences are decoded in order because a match can reference bytes just
//! written. Literal and non-overlapping match copies use fastmem. Overlapping
//! matches use the shared SIMD kernel in `src/internal/match.zig`.
//!
//! The decoder enforces the sequence grammar and both buffers' bounds. It does
//! not enforce the encoder-side five-literal and 12-byte end margins, so valid
//! blocks from encoders with different tail policies remain readable.
//!
//! Format: docs/specs/lz4-block-format.md, "Compressed block format".

const std = @import("std");
const testing = std.testing;
const math = std.math;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const copyMatch = internal.match.copyMatch;
const common = @import("common.zig");
const readInt = common.readInt;

/// A block is empty, truncated, malformed, or inconsistent with the expected
/// decoded length `target.len`.
pub const DecompressError = error{DecompressionFailed};

/// Read a literal or match length after its token nibble. `base` is 0 for a
/// literal and 4 for a match. Every 255 extension byte requires another byte.
/// The overflow check runs in every build mode for hostile input.
inline fn readLength(
    source: []const u8,
    in_pos: *usize,
    nibble: u8,
    base: usize,
) DecompressError!usize {
    var length = base + nibble;
    if (nibble < 15) return length;

    while (true) {
        if (in_pos.* == source.len) return error.DecompressionFailed;
        const byte = source[in_pos.*];
        in_pos.* += 1;
        if (length > math.maxInt(usize) - @as(usize, byte)) {
            return error.DecompressionFailed;
        }
        length += byte;
        if (byte != 255) return length;
    }
}

/// Decompress one raw LZ4 block from `source` into `target` and return the
/// bytes written. `target.len` is the expected decoded length, carried out of
/// band by the block's container. Success always returns `target.len`.
///
/// Returns `error.DecompressionFailed` for an empty or truncated source, a
/// length overflow, input or output overrun, offset zero, an offset before the
/// output's start, a missing final literal sequence, or decoded output shorter
/// than `target.len`. `source` and `target` must not overlap. Never writes
/// past `target`; after an error its contents are unspecified. Does not
/// allocate.
pub fn decompressBlock(source: []const u8, target: []u8) DecompressError!usize {
    if (source.len == 0) return error.DecompressionFailed;

    var in_pos: usize = 0;
    var out_pos: usize = 0;
    while (true) {
        const token = source[in_pos];
        in_pos += 1;

        const literal_len = try readLength(source, &in_pos, token >> 4, 0);
        if (literal_len > source.len - in_pos) return error.DecompressionFailed;
        if (literal_len > target.len - out_pos) return error.DecompressionFailed;
        fastmem.copy(u8, target[out_pos..][0..literal_len], source[in_pos..][0..literal_len]);
        in_pos += literal_len;
        out_pos += literal_len;

        // End of block conditions §1: the final sequence ends after literals.
        // Its low token bits are unused and deliberately ignored.
        if (in_pos == source.len) {
            if (out_pos != target.len) return error.DecompressionFailed;
            return out_pos;
        }

        if (source.len - in_pos < 2) return error.DecompressionFailed;
        const offset = readInt(u16, source[in_pos..][0..2]);
        in_pos += 2;
        if (offset == 0 or offset > out_pos) return error.DecompressionFailed;

        const match_len = try readLength(source, &in_pos, token & 15, 4);
        if (match_len > target.len - out_pos) return error.DecompressionFailed;
        copyMatch(target, out_pos, offset, match_len);
        out_pos += match_len;

        // A match is followed by another token. Ending here omits the final
        // literal-only sequence, even when the expected output is complete.
        if (in_pos == source.len) return error.DecompressionFailed;
    }
}

test "decompress: the empty block is one zero token" {
    // docs/specs/lz4-block-format.md, End of block conditions §2.
    const source = [_]u8{0};
    const written = try decompressBlock(&source, &.{});
    try testing.expectEqual(@as(usize, 0), written);
}

test "decompress: a literal-only block" {
    // docs/specs/lz4-block-format.md, Compressed block format: literal nibble.
    const source = [_]u8{ 0x30, 'a', 'b', 'c' };
    var target: [3]u8 = undefined;
    const written = try decompressBlock(&source, &target);
    try testing.expectEqual(@as(usize, 3), written);
    try testing.expectEqualSlices(u8, "abc", &target);
}

test "decompress: an overlapping offset-one match" {
    // docs/specs/lz4-block-format.md, Safe decoding: overlap match.
    // One literal 'A', a four-byte match at offset 1, then the final token.
    const source = [_]u8{ 0x10, 'A', 1, 0, 0 };
    var target: [5]u8 = undefined;
    const written = try decompressBlock(&source, &target);
    try testing.expectEqual(@as(usize, 5), written);
    try testing.expectEqualSlices(u8, "AAAAA", &target);
}

test "decompress: an empty compressed slice is invalid" {
    try testing.expectError(error.DecompressionFailed, decompressBlock(&.{}, &.{}));
}
