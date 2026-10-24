//! The encoder's prefix-code construction (RFC 7932 §3.2, §3.4, §3.5): the
//! depth-limited Huffman builder (the reference's two-queue merge over a
//! sorted leaf array, with the count-limit retry that guarantees the depth
//! limit), §3.2's canonical assignment, and §3.5's run-length serialization
//! of a depth sequence. The wire form itself is written by `encode.zig`,
//! which owns the bit writer.
//!
//! Ported from google/brotli v1.2.0 `c/enc/entropy_encode.c` (`THIRD_PARTY.md`).
//! Format: docs/specs/rfc7932-brotli.txt.

const std = @import("std");
const assert = std.debug.assert;

/// One node of the builder's merge: a leaf carries its symbol in `value`
/// (`left < 0`), an internal node carries its children's pool indices.
/// The reference's `HuffmanTree`.
pub const Node = struct {
    count: u32,
    left: i16,
    value: i16,
};

/// The reference's sentinel: a count above any real one, so a parent always
/// wins the merge against it.
const sentinel: Node = .{ .count = std.math.maxInt(u32), .left = -1, .value = -1 };

/// The reference's `kBrotliShellGaps`, used by the Shell sort for n >= 57.
const shell_gaps = [6]usize{ 132, 57, 23, 10, 4, 1 };

/// §3.2's ordering rule, the reference's comparator: by count ascending, ties
/// by symbol index *descending*. The tie-break is a wire detail, not a
/// convention — the depths it produces decide every tree's shape.
fn lessThan(a: Node, b: Node) bool {
    if (a.count != b.count) return a.count < b.count;
    return a.value > b.value;
}

/// The reference's `SortHuffmanTreeItems`: insertion sort below 13 items,
/// Shell sort over the fixed gaps above. Ported as written — a different
/// sort with the same comparator can produce a different tree.
fn sortItems(items: []Node) void {
    const n = items.len;
    if (n < 13) {
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const tmp = items[i];
            var k: usize = i;
            var j: usize = i - 1;
            while (lessThan(tmp, items[j])) {
                items[k] = items[j];
                k = j;
                if (j == 0) break;
                j -= 1;
            }
            items[k] = tmp;
        }
        return;
    }
    var g: usize = if (n < 57) 2 else 0;
    while (g < shell_gaps.len) : (g += 1) {
        const gap = shell_gaps[g];
        var i: usize = gap;
        while (i < n) : (i += 1) {
            const tmp = items[i];
            var j: usize = i;
            while (j >= gap and lessThan(tmp, items[j - gap])) : (j -= gap) {
                items[j] = items[j - gap];
            }
            items[j] = tmp;
        }
    }
}

/// The reference's `BrotliSetDepth`: walk the finished pool from the root,
/// assigning each leaf its depth; fails when a depth would pass `max_depth`,
/// which sends `createTree` back around with the counts floored higher.
fn setDepth(root: usize, pool: []const Node, depth: []u8, max_depth: u8) bool {
    var stack: [16]i32 = undefined;
    var level: i32 = 0;
    var p: usize = root;
    stack[0] = -1;
    while (true) {
        if (pool[p].left >= 0) {
            level += 1;
            if (level > max_depth) return false;
            stack[@intCast(level)] = pool[p].value;
            p = @intCast(pool[p].left);
            continue;
        }
        depth[@intCast(pool[p].value)] = @intCast(level);
        while (level >= 0 and stack[@intCast(level)] == -1) level -= 1;
        if (level < 0) return true;
        p = @intCast(stack[@intCast(level)]);
        stack[@intCast(level)] = -1;
    }
}

/// The reference's `BrotliCreateHuffmanTree`: a Huffman tree over `data`'s
/// population counts, no deeper than `tree_limit` bits. `tree` is the
/// 2 * data.len + 1 node scratch; `depth` receives the per-symbol depths.
///
/// The retry loop is the depth guarantee: when the natural tree is too deep,
/// every count below `count_limit` is faked up to it and the merge repeats,
/// which flattens the tree until it fits.
pub fn createTree(data: []const u32, tree_limit: u8, tree: []Node, depth: []u8) void {
    var count_limit: u32 = 1;
    while (true) : (count_limit *%= 2) {
        var n: usize = 0;
        var i: usize = data.len;
        while (i != 0) {
            i -= 1;
            if (data[i] != 0) {
                tree[n] = .{
                    .count = @max(data[i], count_limit),
                    .left = -1,
                    .value = @intCast(i),
                };
                n += 1;
            }
        }
        if (n == 1) {
            // A single symbol: one bit, the reference's special case.
            depth[@intCast(tree[0].value)] = 1;
            break;
        }
        sortItems(tree[0..n]);
        tree[n] = sentinel;
        tree[n + 1] = sentinel;
        var leaf: usize = 0;
        var parent: usize = n + 1;
        var k: usize = n - 1;
        while (k != 0) : (k -= 1) {
            var left: usize = undefined;
            var right: usize = undefined;
            if (tree[leaf].count <= tree[parent].count) {
                left = leaf;
                leaf += 1;
            } else {
                left = parent;
                parent += 1;
            }
            if (tree[leaf].count <= tree[parent].count) {
                right = leaf;
                leaf += 1;
            } else {
                right = parent;
                parent += 1;
            }
            const end = 2 * n - k;
            tree[end] = .{
                .count = tree[left].count +% tree[right].count,
                .left = @intCast(left),
                .value = @intCast(right),
            };
            tree[end + 1] = sentinel;
        }
        if (setDepth(2 * n - 1, tree, depth, tree_limit)) break;
    }
}

/// §3.2's canonical assignment, the reference's
/// `BrotliConvertBitDepthsToSymbols`: sort by depth, then by symbol, and
/// number the codes in that order. `bits[s]` holds the code in transmission
/// order (the low `depth[s]` bits, first bit in bit 0).
pub fn convertBitDepthsToSymbols(depth: []const u8, bits: []u16) void {
    var bl_count: [16]u16 = @splat(0);
    var next_code: [16]u16 = @splat(0);
    for (depth) |d| bl_count[d] += 1;
    bl_count[0] = 0;
    var code: u32 = 0;
    for (1..16) |i| {
        code = (code + bl_count[i - 1]) << 1;
        next_code[i] = @intCast(code);
    }
    for (depth, 0..) |d, symbol| {
        if (d != 0) {
            bits[symbol] = @bitReverse(next_code[d]) >> @intCast(16 - @as(u5, @intCast(d)));
            next_code[d] += 1;
        }
    }
}

/// The reference's `BrotliWriteHuffmanTreeRepetitions`: a run of a non-zero
/// length, as 16-repeat symbols (the extra 2 bits are the count low bits) or
/// literal lengths. The repeats are emitted backwards and then reversed —
/// the reference's arithmetic, ported as written.
fn writeRepetitions(
    previous_value: u8,
    value: u8,
    repetitions: usize,
    tree: []u8,
    extra_bits: []u8,
    tree_size: *usize,
) void {
    assert(repetitions > 0);
    var reps = repetitions;
    if (previous_value != value) {
        tree[tree_size.*] = value;
        extra_bits[tree_size.*] = 0;
        tree_size.* += 1;
        reps -= 1;
    }
    if (reps == 7) {
        tree[tree_size.*] = value;
        extra_bits[tree_size.*] = 0;
        tree_size.* += 1;
        reps -= 1;
    }
    if (reps < 3) {
        for (0..reps) |_| {
            tree[tree_size.*] = value;
            extra_bits[tree_size.*] = 0;
            tree_size.* += 1;
        }
        return;
    }
    const start = tree_size.*;
    reps -= 3;
    while (true) {
        tree[tree_size.*] = 16;
        extra_bits[tree_size.*] = @truncate(reps & 0x3);
        tree_size.* += 1;
        reps >>= 2;
        if (reps == 0) break;
        reps -= 1;
    }
    std.mem.reverse(u8, tree[start..tree_size.*]);
    std.mem.reverse(u8, extra_bits[start..tree_size.*]);
}

/// The reference's `BrotliWriteHuffmanTreeRepetitionsZeros`: a run of zeros,
/// as 17-repeat symbols (the extra 3 bits are the count low bits).
fn writeRepetitionsZeros(
    repetitions: usize,
    tree: []u8,
    extra_bits: []u8,
    tree_size: *usize,
) void {
    var reps = repetitions;
    if (reps == 11) {
        tree[tree_size.*] = 0;
        extra_bits[tree_size.*] = 0;
        tree_size.* += 1;
        reps -= 1;
    }
    if (reps < 3) {
        for (0..reps) |_| {
            tree[tree_size.*] = 0;
            extra_bits[tree_size.*] = 0;
            tree_size.* += 1;
        }
        return;
    }
    const start = tree_size.*;
    reps -= 3;
    while (true) {
        tree[tree_size.*] = 17;
        extra_bits[tree_size.*] = @truncate(reps & 0x7);
        tree_size.* += 1;
        reps >>= 3;
        if (reps == 0) break;
        reps -= 1;
    }
    std.mem.reverse(u8, tree[start..tree_size.*]);
    std.mem.reverse(u8, extra_bits[start..tree_size.*]);
}

/// The reference's `DecideOverRleUse`: 16/17 runs are only profitable on
/// long-enough data, and only when the runs dominate.
fn decideOverRleUse(depth: []const u8) struct { non_zero: bool, zero: bool } {
    var total_reps_zero: usize = 0;
    var total_reps_non_zero: usize = 0;
    var count_reps_zero: usize = 1;
    var count_reps_non_zero: usize = 1;
    var i: usize = 0;
    while (i < depth.len) {
        const value = depth[i];
        var reps: usize = 1;
        var k = i + 1;
        while (k < depth.len and depth[k] == value) : (k += 1) reps += 1;
        if (reps >= 3 and value == 0) {
            total_reps_zero += reps;
            count_reps_zero += 1;
        }
        if (reps >= 4 and value != 0) {
            total_reps_non_zero += reps;
            count_reps_non_zero += 1;
        }
        i += reps;
    }
    return .{
        .non_zero = total_reps_non_zero > count_reps_non_zero * 2,
        .zero = total_reps_zero > count_reps_zero * 2,
    };
}

/// The reference's `BrotliWriteHuffmanTree`: serialize a depth sequence into
/// (symbol, extra-bits) pairs for the code-length code. Trailing zeros are
/// dropped, the first length is "the previous length is taken to be 8", and
/// the run-length symbols are §3.5's 16 (repeat a non-zero length) and 17
/// (repeat zero).
pub fn writeHuffmanTree(
    depth: []const u8,
    tree: []u8,
    extra_bits: []u8,
    tree_size: *usize,
) void {
    var previous_value: u8 = 8;
    var new_length = depth.len;
    for (0..depth.len) |i| {
        if (depth[depth.len - i - 1] == 0) {
            new_length -= 1;
        } else {
            break;
        }
    }
    var use_rle_for_non_zero = false;
    var use_rle_for_zero = false;
    if (depth.len > 50) {
        const use = decideOverRleUse(depth[0..new_length]);
        use_rle_for_non_zero = use.non_zero;
        use_rle_for_zero = use.zero;
    }
    var i: usize = 0;
    while (i < new_length) {
        const value = depth[i];
        var reps: usize = 1;
        if ((value != 0 and use_rle_for_non_zero) or (value == 0 and use_rle_for_zero)) {
            var k = i + 1;
            while (k < new_length and depth[k] == value) : (k += 1) reps += 1;
        }
        if (value == 0) {
            writeRepetitionsZeros(reps, tree, extra_bits, tree_size);
        } else {
            writeRepetitions(previous_value, value, reps, tree, extra_bits, tree_size);
            previous_value = value;
        }
        i += reps;
    }
}

// ---------------------------------------------------------------------------
// Tests: the §3.2 assignment against the RFC's own worked example, and the
// builder's invariants.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "canonical assignment: §3.2's own example" {
    // RFC 7932 §3.2: lengths (2, 1, 3, 3) for ABCD give A=10, B=0, C=110,
    // D=111, read most significant bit first; `bits` holds the transmitted
    // order (low bit first).
    var depth: [4]u8 = .{ 2, 1, 3, 3 };
    var bits: [4]u16 = @splat(0);
    convertBitDepthsToSymbols(&depth, &bits);
    try testing.expectEqual(@as(u16, 0b01), bits[0]); // "10"
    try testing.expectEqual(@as(u16, 0b0), bits[1]); // "0"
    try testing.expectEqual(@as(u16, 0b011), bits[2]); // "110"
    try testing.expectEqual(@as(u16, 0b111), bits[3]); // "111"
}

test "the builder respects the depth limit on a pathological histogram" {
    // Fibonacci counts force the natural tree deep; the count-limit retry
    // must still land every depth at or under 15.
    var histo: [32]u32 = @splat(0);
    var a: u32 = 1;
    var b: u32 = 1;
    for (&histo) |*h| {
        h.* = a;
        const next = a +% b;
        a = b;
        b = next;
    }
    var tree: [2 * 32 + 1]Node = undefined;
    var depth: [32]u8 = @splat(0);
    createTree(&histo, 15, &tree, &depth);
    var used: usize = 0;
    for (depth) |d| {
        try testing.expect(d <= 15);
        if (d != 0) used += 1;
    }
    try testing.expectEqual(@as(usize, 32), used);
}

test "the builder is deterministic and its depths are a complete code" {
    var histo: [64]u32 = @splat(0);
    histo[0] = 100;
    histo[3] = 7;
    histo[9] = 55;
    histo[63] = 1;
    var tree: [2 * 64 + 1]Node = undefined;
    var depth_a: [64]u8 = @splat(0);
    var depth_b: [64]u8 = @splat(0);
    createTree(&histo, 15, &tree, &depth_a);
    createTree(&histo, 15, &tree, &depth_b);
    try testing.expectEqualSlices(u8, &depth_a, &depth_b);
    // Kraft equality at the 15-bit scale.
    var space: i32 = 1 << 15;
    for (depth_a) |d| {
        if (d != 0) space -= @as(i32, 1) << @intCast(15 - @as(u4, @intCast(d)));
    }
    try testing.expectEqual(@as(i32, 0), space);
}

test "the RLE serialization round-trips through the reference's arithmetic" {
    // A depth sequence with a long zero run and a long non-zero run: the 17
    // and 16 repeat symbols must describe it exactly.
    var depth: [80]u8 = @splat(0);
    for (depth[10..70]) |*d| d.* = 5;
    var tree: [80]u8 = @splat(0);
    var extra: [80]u8 = @splat(0);
    var tree_size: usize = 0;
    writeHuffmanTree(&depth, &tree, &extra, &tree_size);
    try testing.expect(tree_size > 0);
    // Replay the symbols and expect the original sequence.
    var replayed: [80]u8 = @splat(0);
    var pos: usize = 0;
    var prev: u8 = 8;
    var repeat: usize = 0;
    var repeat_len: u8 = 8;
    for (tree[0..tree_size], extra[0..tree_size]) |symbol, bits| {
        if (symbol < 16) {
            replayed[pos] = symbol;
            pos += 1;
            repeat = 0;
            if (symbol != 0) prev = symbol;
            continue;
        }
        const target: u8 = if (symbol == 16) prev else 0;
        if (repeat_len != target) {
            repeat = 0;
            repeat_len = target;
        }
        var count = repeat;
        const width: u5 = if (symbol == 16) 2 else 3;
        if (count > 0) count = (count - 2) << width;
        count += bits + 3;
        const added = count - repeat;
        for (replayed[pos..][0..added]) |*d| d.* = target;
        pos += added;
        repeat = count;
    }
    // The trailing zeros are dropped on the wire, so compare the prefix.
    try testing.expectEqualSlices(u8, depth[0..pos], replayed[0..pos]);
    for (depth[pos..]) |d| try testing.expectEqual(@as(u8, 0), d);
}
