//! LZ4 block encoder: a greedy LZ77 match finder over the 64 KiB window.
//! Entry points: `compressBlock` and `maxCompressedLength`.
//!
//! The match finder follows pierrec/lz4's `internal/lz4block/block.go`: one
//! 64-bit load feeds hash checks at the cursor and the next two positions. The
//! table stores the low 16 bits of each position. An occupancy bitmap keeps
//! unused entries from reading uninitialized table storage and is the only
//! region cleared between blocks. Match extension compares eight bytes at a
//! time and uses `@ctz` on the XOR to find the first mismatch.
//!
//! No heap allocation: the position table and occupancy bitmap use 136 KiB of
//! stack. The caller supplies `target`, sized with `maxCompressedLength`.
//!
//! Format: docs/specs/lz4-block-format.md, "Compressed block format".
//! Reference encoder: https://github.com/pierrec/lz4 (BSD-3-Clause).

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const common = @import("common.zig");
const readInt = common.readInt;
const writeInt = common.writeInt;
const decode = @import("decode.zig");
const golden = @import("golden.zig");
const repeat = @import("../repeat.zig");

/// Largest input `compressBlock` accepts. This is the reference LZ4 maximum,
/// chosen so `maxCompressedLength` also fits a 32-bit `usize`.
pub const max_block_size: usize = 0x7E00_0000;

/// The format's match window. Offset 65536 cannot be encoded.
const window_size: usize = 1 << 16;
const window_mask: usize = window_size - 1;

/// The position table and its occupancy bitmap. Only the 8 KiB bitmap needs
/// clearing: an unoccupied entry's position value is never observed.
const table_bits = 16;
const table_size: usize = 1 << table_bits;
const HashTable = [table_size]u16;
const Occupancy = [table_size / 32]u32;

/// Inputs shorter than 14 bytes skip match finding. The extra byte above the
/// format's 13-byte minimum keeps the three-position scan inside the 12-byte
/// match-start margin.
const min_non_literal_block_size: usize = 14;
const last_literals: usize = 5;
const match_find_margin: usize = 12;
const min_match: usize = 4;

/// Six-byte hash multiplier, shared with pierrec/lz4's fast block encoder.
const prime6bytes: u64 = 227718039650203;

/// Upper bound on `compressBlock` output: the input, one length byte per 255
/// input bytes, and 16 bytes of slack. This is LZ4's `CompressBlockBound`.
/// A `target` of this size makes compression infallible.
pub fn maxCompressedLength(input_len: usize) usize {
    assert(input_len <= max_block_size);
    return input_len + input_len / 255 + 16;
}

/// Hash the low six bytes of `word` into a position-table index.
inline fn hash6(word: u64) usize {
    return @intCast((word << 16) *% prime6bytes >> 48);
}

inline fn load64(source: []const u8, position: usize) u64 {
    return readInt(u64, source[position..][0..8]);
}

inline fn load32(source: []const u8, position: usize) u32 {
    return readInt(u32, source[position..][0..4]);
}

/// Resolve a table entry against the current 64 KiB segment. An entry whose
/// reconstructed position reaches the cursor belongs to the previous segment.
/// Null means the reconstruction reaches before the start of `source`.
inline fn getCandidate(
    table: *const HashTable,
    occupied: *const Occupancy,
    hash: usize,
    position: usize,
) ?usize {
    const bit: u32 = @as(u32, 1) << @intCast(hash & 31);
    const low: usize = if (occupied[hash / 32] & bit != 0) table[hash] else 0;
    var candidate = (position & ~window_mask) + low;
    if (candidate >= position) {
        if (candidate < window_size) return null;
        candidate -= window_size;
    }
    return candidate;
}

inline fn putPosition(
    table: *HashTable,
    occupied: *Occupancy,
    hash: usize,
    position: usize,
) void {
    table[hash] = @truncate(position);
    occupied[hash / 32] |= @as(u32, 1) << @intCast(hash & 31);
}

/// A candidate is useful only inside the encodable window and with four equal
/// bytes. Hash collisions and stale segments fail the same comparison.
inline fn matches4(source: []const u8, position: usize, candidate: usize, word: u32) bool {
    if (candidate >= position) return false;
    if (position - candidate >= window_size) return false;
    return load32(source, candidate) == word;
}

/// Compress `source` into `target` as one raw LZ4 block and return the bytes
/// written. The block carries no decoded length or framing.
///
/// `source.len` must be at most `max_block_size` (asserted). Returns
/// `error.BufferTooSmall` if `target` cannot hold the result. A `target` of
/// `maxCompressedLength(source.len)` bytes always can. `source` and `target`
/// must not overlap. Uses 136 KiB of stack and does not allocate. The output
/// is valid LZ4 but need not match another encoder's bytes.
pub fn compressBlock(source: []const u8, target: []u8) error{BufferTooSmall}!usize {
    assert(source.len <= max_block_size);
    if (source.len < min_non_literal_block_size) return emitLastLiterals(target, source);

    var table: HashTable = undefined;
    var occupied: Occupancy = undefined;
    fastmem.set(u32, &occupied, 0);

    // The scan probes s, s+1, and s+2. Reserve those two positions so the
    // latest possible match starts exactly 12 bytes before the input's end.
    const scan_limit = source.len - match_find_margin - 2;
    const match_limit = source.len - last_literals;
    var written: usize = 0;
    var next_emit: usize = 0;
    var s: usize = 0;

    // The three-hash scan stays here because its labeled exits own the cursor,
    // the candidate, and the literal anchor. Pure loads and table access sit in
    // helpers. This is the same control-flow split as snappy's encodeBlock.
    outer: while (s <= scan_limit) {
        const current = load64(source, s);
        const h0 = hash6(current);
        const h1 = hash6(current >> 8);
        const candidate0 = getCandidate(&table, &occupied, h0, s);
        const candidate1 = getCandidate(&table, &occupied, h1, s + 1);
        putPosition(&table, &occupied, h0, s);
        putPosition(&table, &occupied, h1, s + 1);

        var candidate = candidate0 orelse 0;
        var found = candidate0 != null and
            matches4(source, s, candidate, @truncate(current));
        if (!found) {
            const h2 = hash6(current >> 16);
            const candidate2 = getCandidate(&table, &occupied, h2, s + 2);

            s += 1;
            candidate = candidate1 orelse 0;
            found = candidate1 != null and
                matches4(source, s, candidate, @truncate(current >> 8));
            if (!found) {
                s += 1;
                candidate = candidate2 orelse 0;
                putPosition(&table, &occupied, h2, s);
                found = candidate2 != null and
                    matches4(source, s, candidate, @truncate(current >> 16));
                if (!found) {
                    // Stride past incompressible regions. The first 128 bytes
                    // after a match are still visited at the dense cadence.
                    s += 2 + ((s - next_emit) >> 7);
                    continue :outer;
                }
            }
        }

        // Extend over literals already passed, then eight bytes at a time up
        // to the five trailing literals required by the format.
        while (candidate > 0 and s > next_emit and source[candidate - 1] == source[s - 1]) {
            candidate -= 1;
            s -= 1;
        }
        const match_start = s;
        const offset = match_start - candidate;
        s += min_match;
        candidate += min_match;
        while (s + 8 <= match_limit) {
            const difference = load64(source, s) ^ load64(source, candidate);
            if (difference != 0) {
                const common_len = @ctz(difference) >> 3;
                s += common_len;
                candidate += common_len;
                break;
            }
            s += 8;
            candidate += 8;
        }
        while (s < match_limit and source[s] == source[candidate]) {
            s += 1;
            candidate += 1;
        }

        written += try emitSequence(
            target[written..],
            source[next_emit..match_start],
            offset,
            s - match_start,
        );
        next_emit = s;
        if (s > scan_limit) break :outer;

        // A match at the match end can become the next sequence with no
        // literals. Inserting two bytes before it catches overlapping phrases.
        putPosition(&table, &occupied, hash6(load64(source, s - 2)), s - 2);
    }

    written += try emitLastLiterals(target[written..], source[next_emit..]);
    return written;
}

/// The extension-byte count for a token field. A field of 15 always has a
/// final extension byte, including zero when the total is exactly 15.
inline fn extensionSize(length: usize) usize {
    return if (length < 15) 0 else (length - 15) / 255 + 1;
}

/// Write the extension bytes for a token field of 15. The caller reserves
/// `extensionSize(length)` bytes.
fn writeExtendedLength(target: []u8, length: usize) usize {
    assert(length >= 15);
    var remaining = length - 15;
    var written: usize = 0;
    while (remaining >= 255) : (remaining -= 255) {
        target[written] = 255;
        written += 1;
    }
    target[written] = @intCast(remaining);
    return written + 1;
}

/// Write one literal-and-match sequence. The single size check keeps the hot
/// emission path free of per-byte capacity branches.
fn emitSequence(
    target: []u8,
    literals: []const u8,
    offset: usize,
    match_len: usize,
) error{BufferTooSmall}!usize {
    assert(offset > 0);
    assert(offset < window_size);
    assert(match_len >= min_match);
    const match_code = match_len - min_match;
    const sequence_len = 1 + extensionSize(literals.len) + literals.len + 2 +
        extensionSize(match_code);
    if (sequence_len > target.len) return error.BufferTooSmall;

    target[0] = @as(u8, @intCast(@min(literals.len, 15))) << 4 |
        @as(u8, @intCast(@min(match_code, 15)));
    var written: usize = 1;
    if (literals.len >= 15) written += writeExtendedLength(target[written..], literals.len);
    fastmem.copy(u8, target[written..][0..literals.len], literals);
    written += literals.len;
    writeInt(u16, target[written..][0..2], @intCast(offset));
    written += 2;
    if (match_code >= 15) written += writeExtendedLength(target[written..], match_code);
    return written;
}

/// Write the mandatory final literal-only sequence. Its low token bits are 0.
fn emitLastLiterals(target: []u8, literals: []const u8) error{BufferTooSmall}!usize {
    const block_len = 1 + extensionSize(literals.len) + literals.len;
    if (block_len > target.len) return error.BufferTooSmall;

    target[0] = @as(u8, @intCast(@min(literals.len, 15))) << 4;
    var written: usize = 1;
    if (literals.len >= 15) written += writeExtendedLength(target[written..], literals.len);
    fastmem.copy(u8, target[written..][0..literals.len], literals);
    return written + literals.len;
}

fn roundTrip(input: []const u8) !void {
    const bound = maxCompressedLength(input.len);
    const compressed = try testing.allocator.alloc(u8, bound);
    defer testing.allocator.free(compressed);
    const compressed_len = try compressBlock(input, compressed);
    try testing.expect(compressed_len <= bound);
    try golden.expectEncoderBlock(input, compressed[0..compressed_len]);

    const decoded = try testing.allocator.alloc(u8, input.len);
    defer testing.allocator.free(decoded);
    const decoded_len = try decode.decompressBlock(compressed[0..compressed_len], decoded);
    try testing.expectEqual(input.len, decoded_len);
    try testing.expectEqualSlices(u8, input, decoded);
}

test "encode: empty and short inputs are final literals" {
    // docs/specs/lz4-block-format.md, End of block conditions §2 and §3.
    inline for (.{ 0, 1, 4, 5, 12, 13 }) |len| {
        const input = repeat.repeatString("a", len);
        var target: [maxCompressedLength(12)]u8 = undefined;
        const written = try compressBlock(input, &target);
        try testing.expectEqual(@as(usize, 1 + len), written);
        try testing.expectEqual(@as(u8, @intCast(len << 4)), target[0]);
        try roundTrip(input);
    }
}

test "encode: repetitive and incompressible inputs round-trip" {
    try roundTrip(repeat.repeatString("the quick brown fox", 1000));
    var random: [64 * 1024]u8 = undefined;
    var rng: DefaultPrng = .init(0xC0FFEE);
    rng.random().bytes(&random);
    try roundTrip(&random);
}

test "encode: the 13, 16, and 64 KiB boundaries round-trip" {
    inline for (.{
        13,
        14,
        15,
        16,
        17,
        16 * 1024 - 1,
        16 * 1024,
        16 * 1024 + 1,
        64 * 1024 - 1,
        64 * 1024,
        64 * 1024 + 1,
    }) |len| {
        const input = try testing.allocator.alloc(u8, len);
        defer testing.allocator.free(input);
        for (input, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% i / 97);
        try roundTrip(input);
    }
}

test "encode: the three-position scan preserves the last-match margin" {
    // docs/specs/lz4-block-format.md, End of block conditions §3. The second
    // candidate used to start two bytes past the permitted match start.
    try roundTrip("abababbababba");
}

test "encode: a mismatch tail keeps the match cursor paired" {
    // The eight-byte compare stops at a mismatch. Both cursors must advance by
    // the common prefix before the byte-wise tail starts.
    try roundTrip(" allocat allocator, for b");
}

test "encode: matches work beyond the first 64 KiB" {
    const input = repeat.repeatString("a journal record with repeated fields. ", 4000);
    try testing.expect(input.len > 2 * window_size);
    try roundTrip(input);
}

test "encode: maxCompressedLength covers the literal form" {
    // The reference LZ4_COMPRESSBOUND is input + input/255 + 16.
    inline for (.{ 0, 1, 14, 15, 16, 254, 255, 270, 4096, 65536, 65537 }) |len| {
        const input = try testing.allocator.alloc(u8, len);
        defer testing.allocator.free(input);
        fastmem.set(u8, input, 0xAB);
        const target = try testing.allocator.alloc(u8, maxCompressedLength(len));
        defer testing.allocator.free(target);
        const written = try compressBlock(input, target);
        try testing.expect(written <= target.len);
    }
}

test "encode: a short target reports BufferTooSmall" {
    const input = repeat.repeatString("abcdefgh", 100);
    var target: [maxCompressedLength(input.len)]u8 = undefined;
    const written = try compressBlock(input, &target);
    inline for (.{ 0, 1 }) |cap| {
        try testing.expectError(error.BufferTooSmall, compressBlock(input, target[0..cap]));
    }
    try testing.expectError(
        error.BufferTooSmall,
        compressBlock(input, target[0 .. written - 1]),
    );
}
