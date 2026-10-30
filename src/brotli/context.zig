//! The context-model layer (RFC 7932 §7): the four context modes (§7.1) and
//! the context maps (§7.3) — RLEMAX, the map's own prefix code, the zero-run
//! coding, and the inverse move-to-front transform.
//!
//! The context ID computation itself — §7.1's Lut0/Lut1/Lut2 tables, the
//! literal formulas, and §7.2's copy-length bands — belongs to the layer
//! that decodes commands. This file owns the wire: the modes array and the
//! two maps the meta-block header carries.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const fastmem = @import("fastmem");

const bits = @import("bits.zig");
const golden = @import("golden.zig");
const huffman = @import("huffman.zig");

/// §9.2 — the 1..11-bit count code's ceiling: a meta-block can declare up to
/// 256 block types, and the modes array and context maps are sized for it.
pub const max_block_types = 256;

/// §7.1 — the four context modes, in their 2-bit wire order.
pub const Mode = enum(u2) {
    /// The six least significant bits of p1.
    lsb6,
    /// The six most significant bits of p1.
    msb6,
    /// A UTF-8-aware function of p1 and p2.
    utf8,
    /// A signed-integer-aware function of p1 and p2.
    signed,
};

/// §7.3 — the context-map layer's refusal.
pub const Error = error{
    /// §7.3 — "If a run length would result in more lengths in total than
    /// the size of the context map, then the stream should be rejected as
    /// invalid."
    ContextMapRepeat,
};

/// The context-model state of one meta-block: the context mode of every
/// literal block type and the two context maps. The maps are indexed by
/// `64 * block_type + cid` for literals and `4 * block_type + cid` for
/// distances (§7.3).
pub const Arena = struct {
    /// §9.2 — the context mode of each literal block type.
    modes: [max_block_types]Mode,
    /// §7.3 — CMAPL: 64 entries per literal block type.
    literal_map: [64 * max_block_types]u8,
    /// §7.3 — CMAPD: 4 entries per distance block type.
    distance_map: [4 * max_block_types]u8,
};

/// §9.2 — the context modes: two bits per literal block type, in block-type
/// order.
pub fn readModes(comptime Bits: type, br: *Bits, modes: []Mode) Bits.ErrorSet!void {
    for (modes) |*mode| mode.* = @enumFromInt(@as(u2, @intCast(try br.take(2))));
}

/// §7.3 — read one context map into `values`. `num_trees` is the map's
/// NTREES (the header's count, 2 or more); `tree` receives the map's own
/// prefix code, and `values.len` is the map's size (64 × NBLTYPESL for
/// literals, 4 × NBLTYPESD for distances).
///
/// The values are the tree indexes of the map, in [0, num_trees - 1] — the
/// alphabet size bounds them, so no index check is needed downstream.
pub fn readMap(
    comptime Bits: type,
    br: *Bits,
    tree: *huffman.ContextMapTree,
    values: []u8,
    num_trees: u16,
) (Bits.ErrorSet || huffman.Error || Error)!void {
    assert(num_trees >= 2);
    assert(num_trees <= huffman.max_trees);
    assert(values.len > 0);

    // "1..5 bits: RLEMAX, 0 is encoded with one 0 bit, and values 1..16 are
    // encoded with bit pattern xxxx1".
    var rlemax: u5 = 0;
    if ((try br.take(1)) != 0) rlemax = @intCast(try br.take(4) + 1);

    const alphabet_size: u16 = num_trees + rlemax;
    try huffman.readTree(huffman.ContextMapTree, Bits, br, tree, alphabet_size);

    // "Context map size values encoded with the above prefix code and run
    // length coding for zero values": symbol 0 is a zero, 1..RLEMAX repeat
    // a zero (1 << symbol) + (symbol extra bits) times, and the rest are the
    // values RLEMAX + 1 .. RLEMAX + NTREES - 1.
    var i: usize = 0;
    while (i < values.len) {
        const symbol = try tree.decode(Bits, br);
        if (symbol == 0) {
            values[i] = 0;
            i += 1;
        } else if (symbol <= rlemax) {
            const run = (@as(u32, 1) << @intCast(symbol)) + try br.take(@intCast(symbol));
            if (i + run > values.len) return error.ContextMapRepeat;
            fastmem.set(u8, values[i..][0..run], 0);
            i += run;
        } else {
            values[i] = @intCast(symbol - rlemax);
            i += 1;
        }
    }

    // "1 bit: IMTF bit, if set, we do an inverse move-to-front transform on
    // the values in the context map".
    if ((try br.take(1)) != 0) inverseMoveToFront(values);
}

/// §7.3 — the inverse move-to-front transform, the RFC's own C function:
/// `value = mtf[index]`, then move that value to the front of the list.
fn inverseMoveToFront(values: []u8) void {
    var mtf: [256]u8 = undefined;
    for (&mtf, 0..) |*entry, i| entry.* = @intCast(i);
    for (values) |*value| {
        const index: u8 = value.*;
        const front = mtf[index];
        value.* = front;
        var j: usize = index;
        while (j > 0) : (j -= 1) mtf[j] = mtf[j - 1];
        mtf[0] = front;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "context modes: RFC 7932 §9.2's two bits per literal block type" {
    // 0 = LSB6, 1 = MSB6, 2 = UTF8, 3 = Signed (§7.1); read in block-type
    // order, two bits each.
    var br: bits.BitReader = .init(&[_]u8{0b11_10_01_00});
    var modes: [4]Mode = undefined;
    try readModes(bits.BitReader, &br, &modes);
    try testing.expectEqual(Mode.lsb6, modes[0]);
    try testing.expectEqual(Mode.msb6, modes[1]);
    try testing.expectEqual(Mode.utf8, modes[2]);
    try testing.expectEqual(Mode.signed, modes[3]);
}

test "context map: RFC 7932 §7.3's RLEMAX, zero runs, and the IMTF bit" {
    // NTREES = 2, RLEMAX = 1: the alphabet is three symbols — 0 is a zero,
    // 1 repeats a zero 2..3 times (one extra bit), 2 is the value 1. The
    // map's simple tree gives symbol 0 code 0, symbol 1 code 10, symbol 2
    // code 11, so their wire values are 0, 01 and 11.
    var packer: golden.Packer = .empty;
    packer.pack(1, 1); // RLEMAX = 1 (the 5-bit form)
    packer.pack(0, 4);
    packer.pack(1, 2); // simple form
    packer.pack(2, 2); // NSYM = 3
    packer.pack(0, 2); // symbol 0
    packer.pack(1, 2); // symbol 1
    packer.pack(2, 2); // symbol 2
    packer.code(0b11, 2); // value 1
    packer.code(0b11, 2); // value 1
    for (0..31) |_| {
        packer.code(0b01, 2); // repeat zero 2..3 times
        packer.pack(0, 1); // twice
    }
    packer.pack(1, 1); // IMTF
    var br: bits.BitReader = .init(packer.slice());
    var tree: huffman.ContextMapTree = undefined;
    var values: [64]u8 = @splat(0xFF);
    try readMap(bits.BitReader, &br, &tree, &values, 2);
    try testing.expectEqual(@as(u64, packer.bit_len), br.bit_pos);
    // The raw map is [1, 1, 0, ...]; the inverse move-to-front transform
    // turns it into [1, 0, 0, ...] (the RFC's own function: after the first
    // value 1 moves to the front, index 1 reads the 0 behind it).
    try testing.expectEqual(@as(u8, 1), values[0]);
    try testing.expectEqual(@as(u8, 0), values[1]);
    for (values[2..]) |value| try testing.expectEqual(@as(u8, 0), value);
}

test "context map: a zero run past the map's end is RFC 7932 §7.3's refusal" {
    // NTREES = 2, RLEMAX = 1 (alphabet 3, ALPHABET_BITS 2): the map's simple
    // tree gives symbol 0 code 0 (wire 0), symbol 1 code 10 (wire 01) and
    // symbol 2 code 11 (wire 11). Two zero values fill entries 0 and 1 of a
    // 3-entry map, then a repeat of two more would reach five.
    var packer: golden.Packer = .empty;
    packer.pack(1, 1); // RLEMAX = 1
    packer.pack(0, 4);
    packer.pack(1, 2); // simple form
    packer.pack(2, 2); // NSYM = 3
    packer.pack(0, 2); // symbol 0
    packer.pack(1, 2); // symbol 1
    packer.pack(2, 2); // symbol 2
    packer.code(0b0, 1); // a zero
    packer.code(0b0, 1); // a zero
    packer.code(0b01, 2); // repeat zero 2..3 times
    packer.pack(0, 1); // twice: entries 2 and 3, and the map has three
    var br: bits.BitReader = .init(packer.slice());
    var tree: huffman.ContextMapTree = undefined;
    var values: [3]u8 = @splat(0xFF);
    try testing.expectError(
        error.ContextMapRepeat,
        readMap(bits.BitReader, &br, &tree, &values, 2),
    );
}

test "inverse move-to-front: RFC 7932 §7.3's worked shape" {
    // [2, 0, 0] -> index 2 reads mtf[2] = 2 (list 2,0,1); index 0 reads 2
    // (no move); index 0 reads 2 again: the repeated index pins the move.
    var values = [_]u8{ 2, 0, 0 };
    inverseMoveToFront(&values);
    try testing.expectEqualSlices(u8, &[_]u8{ 2, 2, 2 }, &values);
}
