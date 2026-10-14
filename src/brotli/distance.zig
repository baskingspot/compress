//! The distance layer (RFC 7932 §4): the four-distance ring, the sixteen
//! special codes that read it, the NDIRECT direct codes, and the extra-bit
//! codes' reconstruction over NPOSTFIX.
//!
//! The ring is stream-scoped: "it is initialized ... at the beginning of the
//! *stream* (as opposed to the beginning of the meta-block), and it is not
//! reset at meta-block boundaries" (§4). The caller decides the push, because
//! both exclusions — a distance symbol 0, and a static dictionary reference —
//! are visible only where the class is known (§4, §8).

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const huffman = @import("huffman.zig");

/// §9.1 — the largest window a stream can declare, `(1 << 24) - 16`: the
/// bound on any distance the ring can hold, because only window references
/// are pushed.
pub const max_window_size: u32 = (1 << 24) - 16;

/// §4's refusals.
pub const Error = error{
    /// §4 — "If a special distance symbol resolves to a zero or negative
    /// value, the stream should be rejected as invalid."
    BadDistance,
};

/// §4 — the ring of the four last distances, `[0]` fourth-to-last through
/// `[3]` last. "The ring buffer of the four last distances is initialized by
/// the values 16, 15, 11, and 4".
pub const Ring = struct {
    /// The distances, oldest first: the last distance is `last[3]`.
    last: [4]u32 = .{ 16, 15, 11, 4 },

    /// §4 — push a window reference. Symbol 0 and dictionary references are
    /// never pushed (the caller excludes them).
    pub fn push(self: *Ring, distance: u32) void {
        assert(distance > 0);
        assert(distance <= max_window_size);
        self.last[0] = self.last[1];
        self.last[1] = self.last[2];
        self.last[2] = self.last[3];
        self.last[3] = distance;
    }

    /// The distance `index` places back: 3 is the last distance, 2 the
    /// second-to-last, 1 the third-to-last, 0 the fourth-to-last.
    pub fn get(self: *const Ring, index: u2) u32 {
        return self.last[index];
    }
};

/// §4 — the special codes' shape: code `c` (< 16) resolves to
/// `ring.get(index_offset[c]) + value_offset[c]`, which is the RFC's table —
/// 0..3 the four last distances, 4..9 the last distance ∓1..3, 10..15 the
/// second-to-last ∓1..3. The reference carries the same two tables
/// (`kDistanceShortCodeIndexOffset`/`ValueOffset`, `c/dec/decode.c`).
const index_offset = [16]u2{ 3, 2, 1, 0, 3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2 };
const value_offset = [16]i8{ 0, 0, 0, 0, -1, 1, -2, 2, -3, 3, -1, 1, -2, 2, -3, 3 };

/// §4 — a special code's distance. `error.BadDistance` when the result is
/// zero or negative ("the stream should be rejected as invalid").
pub fn special(ring: *const Ring, code: u16) Error!u32 {
    assert(code < 16);
    const base: i32 = @intCast(ring.get(index_offset[code]));
    const distance = base + value_offset[code];
    if (distance <= 0) return error.BadDistance;
    return @intCast(distance);
}

/// §4's per-meta-block distance tables, derived from NPOSTFIX and NDIRECT:
/// the extra-bit count and the offset of every code at or above
/// 16 + NDIRECT, so the reconstruction is `offset[code] + (dextra <<
/// NPOSTFIX)`. Comptime-sized for the format's largest alphabet
/// (`16 + 120 + (48 << 3)` = 520) and filled per meta-block, the
/// reference's `CalculateDistanceLut` shape (`c/dec/decode.c`).
pub const Tables = struct {
    /// §4 — NPOSTFIX, 0..3.
    npostfix: u3 = 0,
    /// §4 — the extra bits of each code; 0 for the direct codes and unused
    /// below 16.
    extra_bits: [huffman.max_distance_alphabet_size]u5 = @splat(0),
    /// §4 — the offset of each code: the reconstruction adds the extra bits
    /// shifted by NPOSTFIX. The direct codes' offsets are their distances
    /// (1..NDIRECT).
    offset: [huffman.max_distance_alphabet_size]u32 = @splat(0),

    /// Fill the tables for `§3.3`'s declared alphabet size,
    /// `16 + NDIRECT + (48 << NPOSTFIX)`: the NDIRECT direct codes first
    /// (no extra bits), then the extra-bit codes a postfix group at a time.
    pub fn init(self: *Tables, npostfix: u3, ndirect: u8, alphabet_size: u16) void {
        assert(alphabet_size >= 16);
        assert(alphabet_size <= huffman.max_distance_alphabet_size);
        self.* = .{ .npostfix = npostfix };

        const postfix: u32 = @as(u32, 1) << npostfix;
        var code: u16 = 16;

        // §4 — "the next NDIRECT distance symbols, from 16 to 15 + NDIRECT,
        // represent distances from 1 to NDIRECT. Neither the special distance
        // symbols nor the NDIRECT direct distance symbols are followed by any
        // extra bits."
        var direct: u32 = 1;
        while (direct <= ndirect) : (direct += 1) {
            self.extra_bits[code] = 0;
            self.offset[code] = direct;
            code += 1;
        }

        // §4 — the extra-bit codes: `ndistbits = 1 + (xcode >> (NPOSTFIX+1))`
        // and `offset = ((2 + (hcode & 1)) << ndistbits) - 4`, with the
        // postfix remainder folded into the offset. The (bits, half) walk is
        // the reference's: bits gains half's old value each step, so the
        // groups run (1,0), (1,1), (2,0), (2,1), (3,0), ...
        var bits: u5 = 1;
        var half: u32 = 0;
        while (code < alphabet_size) {
            const base: u32 = @as(u32, ndirect) +
                ((((2 + half) << bits) - 4) << npostfix) + 1;
            var i: u32 = 0;
            while (i < postfix) : (i += 1) {
                assert(code < alphabet_size);
                self.extra_bits[code] = bits;
                self.offset[code] = base + i;
                code += 1;
            }
            bits += @intCast(half);
            half ^= 1;
        }
        assert(code == alphabet_size);
    }

    /// §4 — the distance of an extra-bit or direct code: "distance = ((offset
    /// + dextra) << NPOSTFIX) + lcode + NDIRECT + 1" with `offset` and the
    /// postfix folded in.
    pub fn resolve(self: *const Tables, code: u16, dextra: u32) u32 {
        assert(code >= 16);
        assert(code < huffman.max_distance_alphabet_size);
        return self.offset[code] + (dextra << self.npostfix);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "distance ring: RFC 7932 §4's initialization and pushes" {
    // RFC 7932 §4 — "initialized by the values 16, 15, 11, and 4 (i.e., the
    // fourth-to-last is set to 16, the third-to-last to 15, the second-to-
    // last to 11, and the last distance to 4)".
    var ring: Ring = .{};
    try testing.expectEqual(@as(u32, 16), ring.get(0));
    try testing.expectEqual(@as(u32, 15), ring.get(1));
    try testing.expectEqual(@as(u32, 11), ring.get(2));
    try testing.expectEqual(@as(u32, 4), ring.get(3));

    // A push moves the oldest out: the new last is the pushed distance and
    // the old last becomes the second-to-last.
    ring.push(7);
    try testing.expectEqual(@as(u32, 15), ring.get(0));
    try testing.expectEqual(@as(u32, 11), ring.get(1));
    try testing.expectEqual(@as(u32, 4), ring.get(2));
    try testing.expectEqual(@as(u32, 7), ring.get(3));
}

test "distance: RFC 7932 §4's sixteen special codes" {
    // RFC 7932 §4's table against the initialized ring (16, 15, 11, 4):
    // 0..3 the four last distances, 4..9 the last ∓1..3, 10..15 the
    // second-to-last ∓1..3.
    const ring: Ring = .{};
    const expected = [16]u32{ 4, 11, 15, 16, 3, 5, 2, 6, 1, 7, 10, 12, 9, 13, 8, 14 };
    for (expected, 0..) |want, code| {
        try testing.expectEqual(want, try special(&ring, @intCast(code)));
    }
}

test "distance: a special code resolving to zero or less is refused" {
    // RFC 7932 §4 — "If a special distance symbol resolves to a zero or
    // negative value, the stream should be rejected as invalid." With the
    // last distance 1, code 4 (last - 1) is zero and code 8 (last - 3) is
    // negative; the second-to-last-based codes read 11 and stay positive.
    var ring: Ring = .{};
    ring.push(1);
    try testing.expectError(error.BadDistance, special(&ring, 4));
    try testing.expectError(error.BadDistance, special(&ring, 8));
    try testing.expectEqual(@as(u32, 2), try special(&ring, 5));
    // The push left the ring (15, 11, 4, 1): the second-to-last-based codes
    // read 4, so code 10 (second-to-last - 1) is 3 and code 14 is 1.
    try testing.expectEqual(@as(u32, 3), try special(&ring, 10));
    try testing.expectEqual(@as(u32, 1), try special(&ring, 14));
}

test "distance tables: RFC 7932 §4's reconstruction formula" {
    // The tables must equal §4's formula for every NPOSTFIX/NDIRECT pair and
    // every code: `hcode = x >> NPOSTFIX`, `lcode = x & POSTFIX_MASK`,
    // `ndistbits = 1 + (x >> (NPOSTFIX + 1))`,
    // `distance = ((offset + dextra) << NPOSTFIX) + lcode + NDIRECT + 1`
    // with `offset = ((2 + (hcode & 1)) << ndistbits) - 4`.
    const cases = [_]struct { npostfix: u3, ndirect: u8 }{
        .{ .npostfix = 0, .ndirect = 0 },  .{ .npostfix = 0, .ndirect = 1 },
        .{ .npostfix = 0, .ndirect = 4 },  .{ .npostfix = 0, .ndirect = 15 },
        .{ .npostfix = 1, .ndirect = 0 },  .{ .npostfix = 1, .ndirect = 2 },
        .{ .npostfix = 2, .ndirect = 12 }, .{ .npostfix = 3, .ndirect = 120 },
        .{ .npostfix = 3, .ndirect = 0 },
    };
    for (cases) |case| {
        const alphabet_size: u16 =
            16 + case.ndirect + (@as(u16, 48) << case.npostfix);
        var tables: Tables = undefined;
        tables.init(case.npostfix, case.ndirect, alphabet_size);
        const mask: u32 = (@as(u32, 1) << case.npostfix) - 1;

        // The direct codes: distances 1..NDIRECT, no extra bits.
        for (16..16 + @as(u16, case.ndirect)) |code| {
            try testing.expectEqual(@as(u5, 0), tables.extra_bits[code]);
            const want = @as(u32, @intCast(code - 15));
            try testing.expectEqual(want, tables.resolve(@intCast(code), 0));
        }

        // The extra-bit codes, at their smallest, largest, and a middle
        // extra value.
        for (16 + @as(u16, case.ndirect)..alphabet_size) |code| {
            const x: u32 = @intCast(code - case.ndirect - 16);
            const ndistbits: u5 = 1 + @as(u5, @intCast(x >> (case.npostfix + 1)));
            const hcode = x >> case.npostfix;
            const lcode = x & mask;
            const offset = ((2 + (hcode & 1)) << ndistbits) - 4;
            const formula = ((offset + 0) << case.npostfix) + lcode +
                @as(u32, case.ndirect) + 1;
            try testing.expectEqual(ndistbits, tables.extra_bits[code]);
            try testing.expectEqual(formula, tables.resolve(@intCast(code), 0));
            const max_extra: u32 = (@as(u32, 1) << ndistbits) - 1;
            for ([_]u32{ 1, max_extra / 2, max_extra }) |dextra| {
                const want = ((offset + dextra) << case.npostfix) +
                    lcode + case.ndirect + 1;
                try testing.expectEqual(want, tables.resolve(@intCast(code), dextra));
            }
        }
    }
}
