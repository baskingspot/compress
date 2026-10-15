//! Huffman (huff0) for the zstd encoder: the tree a symbol histogram implies
//! (`HUF_buildCTable_wksp`), the weight series a literals block transmits
//! (`§4.2.1`, `§4.2.1.1`, `§4.2.1.2`), and the backward Huffman-coded streams
//! (`§4.2.2`).
//!
//! The tree's weights are what goes on the wire — a nonzero Weight means
//! `Number_of_Bits = Max_Number_of_Bits + 1 - Weight`, and the last symbol's
//! weight is implied by completing the sum to a power of two. The series is
//! sent directly (two 4-bit weights per byte) or as an FSE bitstream with two
//! interleaved states (`fse_compress.compressSymbols`), whichever is smaller.
//! The code assignment is `§4.2.1.3`'s: sorted by weight, natural order within
//! a weight, sequential from the lowest weight — Table 25's assignment, never
//! the `§4.2.2` example's (errata 8195). A stream writes its symbols in
//! reverse with a single 1-bit end mark, so the decoder reading backward
//! recovers them in order and the last byte is never zero.
//!
//! Format: docs/research/specs/rfc8878-zstd.txt
//! Lineage: facebook/zstd v1.5.7 `huf_compress.c` (`HUF_buildCTable_wksp`,
//! `HUF_writeCTable_wksp`, `HUF_compressWeights`, the stream writers);
//! attribution in THIRD_PARTY.md.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const bits = @import("bits.zig");
const common = @import("common.zig");
const readInt = common.readInt;
const fse_compress = @import("fse_compress.zig");
const golden = @import("golden.zig");
const huff0 = @import("huff0.zig");
const literals = @import("literals.zig");

/// Everything the Huffman encoder reports.
pub const Error = error{
    /// `target` cannot hold the bytes the writer produces.
    BufferTooSmall,
    /// The histogram cannot become a tree: no symbols, or one symbol (which
    /// is RLE_Mode's, `§3.1.1.3.1.3`).
    TreeNotBuildable,
    /// The tree's weight series has no legal description: the FSE form did
    /// not pay and the direct form lists at most 128 weights (`§4.2.1.1`,
    /// `huf_compress.c:282`). The caller falls back to Raw literals.
    TreeNotDescribable,
    /// The four-stream layout cannot carry the input: fewer than errata
    /// 7297's 6 regenerated literals, or a stream over the Jump_Table's
    /// 16-bit field. The caller writes one stream instead.
    NotCompressible,
};

/// `§4.2.1` — "This specification limits the maximum code length to 11 bits."
pub const code_length_max: u5 = huff0.code_length_max;

/// The literals alphabet: symbols 0-255.
pub const symbol_count_max = huff0.symbol_count_max;

/// The C's `LitHufLog` (`zstd_internal.h:101`): the literals tree's depth cap,
/// which `§4.2.1` also states.
pub const depth_max: u5 = 11;

/// The C's `HUF_TABLELOG_MAX` (`huf.h:37`): the widest code length the tree
/// builder's rank arithmetic carries, one above the format's cap.
const tablelog_max: u5 = 12;

/// A symbol's histogram (`HIST_count`, `hist_compress.c`): the counts, the
/// last symbol with a nonzero count, and the largest count.
pub const Histogram = struct {
    counts: [symbol_count_max]u32 = @splat(0),
    /// The last symbol with a nonzero count; 0 when every count is zero.
    max_symbol: u16 = 0,
    largest: u32 = 0,

    /// `HIST_FAST_THRESHOLD` (`hist.c:152`): below it the simple count wins
    /// (the parallel lanes' 4-KiB zeroing would cost more than the count).
    const fast_threshold = 1500;

    /// Count `source`'s bytes — the C's `HIST_count` shape
    /// (`hist.c:33-64,68-144`): the counting itself is branch-free, with
    /// `max_symbol` and `largest` derived in one pass over the 256 counts
    /// afterwards; at or above the threshold four parallel lanes break the
    /// store-to-load dependency a repeated byte would otherwise serialize.
    pub fn count(source: []const u8) Histogram {
        var histogram: Histogram = .{};
        if (source.len == 0) return histogram;
        if (source.len < fast_threshold) {
            for (source) |byte| histogram.counts[byte] += 1;
        } else {
            var lanes: [4][symbol_count_max]u32 = @splat(@splat(0));
            var index: usize = 0;
            while (index + 16 <= source.len) : (index += 16) {
                inline for (0..4) |word_index| {
                    const word = readInt(u32, source[index + 4 * word_index ..][0..4]);
                    lanes[0][@as(u8, @truncate(word))] += 1;
                    lanes[1][@as(u8, @truncate(word >> 8))] += 1;
                    lanes[2][@as(u8, @truncate(word >> 16))] += 1;
                    lanes[3][@as(u8, @truncate(word >> 24))] += 1;
                }
            }
            while (index < source.len) : (index += 1) lanes[0][source[index]] += 1;
            for (0..symbol_count_max) |symbol| {
                histogram.counts[symbol] = lanes[0][symbol] + lanes[1][symbol] +
                    lanes[2][symbol] + lanes[3][symbol];
            }
        }
        for (histogram.counts, 0..) |count_of, symbol| {
            if (count_of != 0) {
                histogram.max_symbol = @intCast(symbol);
                if (count_of > histogram.largest) histogram.largest = count_of;
            }
        }
        return histogram;
    }
};

/// One prefix code (`§4.2.1.3`): the code's bits, right-aligned, and its
/// length. A zero length means the symbol has no code (its weight is zero).
pub const Code = struct {
    bits: u16 = 0,
    len: u5 = 0,
};

/// A Huffman table ready to encode: the weights the tree description
/// transmits and the codes they assign.
pub const Table = struct {
    /// One weight per symbol, in symbol order; a zero weight means the symbol
    /// is absent. Only the first `symbol_count` entries are meaningful, and
    /// the last of those is implied by the completion (`§4.2.1`), so the
    /// description lists one fewer.
    weights: [symbol_count_max]u8,
    /// The number of symbols the tree covers, the implied last weight
    /// included.
    symbol_count: u16,
    /// Max_Number_of_Bits: the tree's depth.
    max_bits: u5,
    /// One code per symbol.
    codes: [symbol_count_max]Code,

    /// The weight a symbol transmits (`§4.2.1`): `Max_Number_of_Bits + 1 -
    /// Number_of_Bits`, zero for a symbol the tree leaves out.
    pub fn weight(self: *const Table, symbol: u8) u8 {
        return self.weights[symbol];
    }
};

/// The tree builder's node (`nodeElt`, `huf_compress.c:520-527`).
const Node = struct {
    count: u32 = 0,
    parent: u16 = 0,
    symbol: u8 = 0,
    nb_bits: u8 = 0,
};

/// The node table. Index 0 is the C's barrier entry (`huffNode[-1]`, count
/// `1 << 31`); the symbols and the internal nodes start at 1, so a C index `i`
/// is `nodes[i + 1]`.
const NodeTable = struct {
    nodes: [2 * (symbol_count_max + 1)]Node,

    fn at(self: *NodeTable, index: i32) *Node {
        assert(index >= -1);
        assert(index < @as(i32, @intCast(self.nodes.len)) - 1);
        return &self.nodes[@intCast(index + 1)];
    }

    /// The symbol count's floor: the C's `HUF_SYMBOLVALUE_MAX + 1`.
    const start_node: u32 = symbol_count_max + 1;
};

/// Build the Huffman table a histogram implies (`HUF_buildCTable_wksp`,
/// `huf_compress.c:723-757`): sort by decreasing count, merge into a tree,
/// cap the depth at the C's `HUF_optimalTableLog` guess, and assign the codes.
///
/// `source_len` is the histogram's total, which sets the depth cap
/// (`FSE_optimalTableLog_internal(11, srcLen, maxSymbol, 1)`).
pub fn buildTable(histogram: *const Histogram, source_len: u32) Error!Table {
    assert(source_len >= 2);
    const max_symbol = histogram.max_symbol;
    if (histogram.largest == source_len) return error.TreeNotBuildable;
    var nodes: NodeTable = undefined;
    fastmem.set(Node, &nodes.nodes, .{});

    // The sort: decreasing count. The C's bucket sort leaves ties in an
    // arbitrary order (its quicksort is not stable); this keeps natural
    // symbol order among equal counts, so the same input always produces the
    // same tree.
    for (0..@as(usize, max_symbol) + 1) |symbol| {
        nodes.at(@intCast(symbol)).* = .{
            .count = histogram.counts[symbol],
            .symbol = @intCast(symbol),
        };
    }
    var index: u32 = 1;
    while (index <= max_symbol) : (index += 1) {
        const key = nodes.at(@intCast(index)).*;
        var position: i32 = @intCast(index);
        while (position > 0 and nodes.at(position - 1).count < key.count) : (position -= 1) {
            nodes.at(position).* = nodes.at(position - 1).*;
        }
        nodes.at(position).* = key;
    }

    const non_null_rank = buildTree(&nodes, max_symbol);
    const depth = fse_compress.optimalAccuracyLog(depth_max, source_len, max_symbol, 1);
    const max_bits = setMaxHeight(&nodes, non_null_rank, depth);
    if (max_bits > depth_max) return error.TreeNotBuildable;

    var table: Table = .{
        .weights = @splat(0),
        .symbol_count = 0,
        .max_bits = max_bits,
        .codes = @splat(.{}),
    };
    assignCodes(&table, &nodes, non_null_rank, max_symbol, max_bits);
    return table;
}

/// `HUF_buildTree` (`huf_compress.c:634-683`): merge the sorted symbols into a
/// Huffman tree, deepest last, and return the last symbol node. The internal
/// nodes live above the symbol nodes, the C's `STARTNODE` = 256.
fn buildTree(nodes: *NodeTable, max_symbol: u16) u32 {
    var non_null_rank: i32 = max_symbol;
    while (nodes.at(non_null_rank).count == 0) non_null_rank -= 1;
    var low_symbol: i32 = non_null_rank;
    const node_root: i32 = @as(i32, NodeTable.start_node) + low_symbol - 1;
    var low_node: i32 = NodeTable.start_node;
    var node_count: i32 = NodeTable.start_node;

    // The first merge is of the two least frequent symbols.
    nodes.at(node_count).count = nodes.at(low_symbol).count + nodes.at(low_symbol - 1).count;
    nodes.at(low_symbol).parent = @intCast(node_count);
    nodes.at(low_symbol - 1).parent = @intCast(node_count);
    node_count += 1;
    low_symbol -= 2;
    // Uncreated internal nodes carry `1 << 30`, so they always lose to a real
    // node; the barrier (`1 << 31`) is the last resort.
    for (@as(usize, @intCast(node_count))..@as(usize, @intCast(node_root)) + 1) |index| {
        nodes.at(@intCast(index)).count = 1 << 30;
    }
    nodes.at(-1).count = 1 << 31;

    while (node_count <= node_root) : (node_count += 1) {
        const first = if (nodes.at(low_symbol).count < nodes.at(low_node).count) blk: {
            low_symbol -= 1;
            break :blk low_symbol + 1;
        } else blk: {
            low_node += 1;
            break :blk low_node - 1;
        };
        const second = if (nodes.at(low_symbol).count < nodes.at(low_node).count) blk: {
            low_symbol -= 1;
            break :blk low_symbol + 1;
        } else blk: {
            low_node += 1;
            break :blk low_node - 1;
        };
        nodes.at(node_count).count = nodes.at(first).count + nodes.at(second).count;
        nodes.at(first).parent = @intCast(node_count);
        nodes.at(second).parent = @intCast(node_count);
    }

    // The depth of each node, from the root down.
    nodes.at(node_root).nb_bits = 0;
    var index: i32 = node_root - 1;
    while (index >= NodeTable.start_node) : (index -= 1) {
        nodes.at(index).nb_bits = nodes.at(nodes.at(index).parent).nb_bits + 1;
    }
    index = 0;
    while (index <= non_null_rank) : (index += 1) {
        nodes.at(index).nb_bits = nodes.at(nodes.at(index).parent).nb_bits + 1;
    }
    return @intCast(non_null_rank);
}

/// The C's `noSymbol` marker (`huf_compress.c:394`).
const no_symbol: u32 = 0xffff_ffff;

/// `HUF_setMaxHeight` (`huf_compress.c:376-493`): force the tree's depth to
/// `target_nb_bits`. The nodes over the cap are flattened onto it, the cost
/// the flattening leaves is repaid by raising the cheapest nodes one rank, and
/// a repayment that overshoots is added back. Returns the tree's depth, which
/// is at most `target_nb_bits`.
fn setMaxHeight(nodes: *NodeTable, last_non_null: u32, target_nb_bits: u5) u5 {
    // The cast's bound: an unlimited tree of depth `d` needs at least
    // Fib(d + 2) bytes of source, so a 128-KiB block's depth is at most 27.
    assert(nodes.at(@intCast(last_non_null)).nb_bits <= 31);
    const largest_bits: u5 = @intCast(nodes.at(@intCast(last_non_null)).nb_bits);
    if (largest_bits <= target_nb_bits) return largest_bits;
    // The unlimited tree's depth is NOT bounded by tablelog_max: the C's
    // `HUF_setMaxHeight` (huf_compress.c:376-380) flattens any depth onto
    // the target (a skewed histogram's unlimited tree can be deeper than
    // the cap; the depth is bounded by the source's byte count, the
    // Fibonacci bound asserted above, not by `nb_bits: u8`). An assert on
    // the depth here was reachable through the public Writer with ordinary
    // bytes; found by the encode-side fuzz wave.

    // Flatten every node over the cap and accumulate the rank cost the
    // flattening gives back, in units of `base_cost`.
    const base_cost: i32 = @as(i32, 1) << @intCast(largest_bits - target_nb_bits);
    var total_cost: i32 = 0;
    var position: i32 = @intCast(last_non_null);
    while (nodes.at(position).nb_bits > target_nb_bits) : (position -= 1) {
        const saved = @as(i32, 1) << @intCast(largest_bits - nodes.at(position).nb_bits);
        total_cost += base_cost - saved;
        nodes.at(position).nb_bits = target_nb_bits;
    }
    // The C's barrier at -1 has depth 0, so this stops there.
    while (nodes.at(position).nb_bits == target_nb_bits) position -= 1;
    assert(total_cost & (base_cost - 1) == 0);
    total_cost >>= @intCast(largest_bits - target_nb_bits);
    assert(total_cost > 0);

    // The last (smallest) node of each rank, from the C's `rankLast`: index
    // `target - depth`, so rank 1 holds the deepest nodes.
    var rank_last: [tablelog_max + 2]u32 = @splat(no_symbol);
    var current_nb_bits: u5 = target_nb_bits;
    var scan: i32 = position;
    while (scan >= 0) : (scan -= 1) {
        if (nodes.at(scan).nb_bits >= current_nb_bits) continue;
        current_nb_bits = @intCast(nodes.at(scan).nb_bits);
        rank_last[target_nb_bits - current_nb_bits] = @intCast(scan);
    }

    repayCost(nodes, &rank_last, target_nb_bits, &total_cost);
    while (total_cost < 0) addBackCost(nodes, &rank_last, target_nb_bits, &total_cost, &position);
    return target_nb_bits;
}

/// The C's repayment loop (`huf_compress.c:412-455`): raise the cheapest
/// node one rank at a time until the flattening's cost is repaid.
fn repayCost(
    nodes: *NodeTable,
    rank_last: *[tablelog_max + 2]u32,
    target_nb_bits: u5,
    total_cost: *i32,
) void {
    while (total_cost.* > 0) {
        var decrease: u32 = highBit(@intCast(total_cost.*)) + 1;
        while (decrease > 1) : (decrease -= 1) {
            const high = rank_last[decrease];
            const low = rank_last[decrease - 1];
            if (high == no_symbol) continue;
            // "Decrease highPos if no symbols of lowPos or if it is not
            // cheaper to remove 2 lowPos than highPos."
            if (low == no_symbol) break;
            if (nodes.at(@intCast(high)).count <= 2 * nodes.at(@intCast(low)).count) break;
        }
        assert(rank_last[decrease] != no_symbol or decrease == 1);
        while (decrease <= tablelog_max and rank_last[decrease] == no_symbol) decrease += 1;
        assert(rank_last[decrease] != no_symbol);
        total_cost.* -= @as(i32, 1) << @intCast(decrease - 1);
        nodes.at(@intCast(rank_last[decrease])).nb_bits += 1;
        // Fix up the two ranks the move touched.
        if (rank_last[decrease - 1] == no_symbol) rank_last[decrease - 1] = rank_last[decrease];
        if (rank_last[decrease] == 0) {
            rank_last[decrease] = no_symbol;
        } else {
            rank_last[decrease] -= 1;
            if (nodes.at(@intCast(rank_last[decrease])).nb_bits != target_nb_bits - decrease) {
                rank_last[decrease] = no_symbol;
            }
        }
    }
}

/// The C's cost-correction loop (`huf_compress.c:463-477`): a repayment that
/// overshot takes the largest nodes of the shallowest rank and moves them one
/// rank deeper.
fn addBackCost(
    nodes: *NodeTable,
    rank_last: *[tablelog_max + 2]u32,
    target_nb_bits: u5,
    total_cost: *i32,
    position: *i32,
) void {
    if (rank_last[1] == no_symbol) {
        while (nodes.at(position.*).nb_bits == target_nb_bits) position.* -= 1;
        nodes.at(position.* + 1).nb_bits -= 1;
        assert(position.* >= 0);
        rank_last[1] = @intCast(position.* + 1);
        total_cost.* += 1;
        return;
    }
    nodes.at(@intCast(rank_last[1] + 1)).nb_bits -= 1;
    rank_last[1] += 1;
    total_cost.* += 1;
}

/// `HUF_buildCTableFromTree` (`huf_compress.c:692-720`): the depth per symbol
/// and `§4.2.1.3`'s code assignment — "sorted by Weight, natural order within
/// a weight, sequential from the lowest weight".
fn assignCodes(
    table: *Table,
    nodes: *NodeTable,
    non_null_rank: u32,
    max_symbol: u16,
    max_bits: u5,
) void {
    for (0..non_null_rank + 1) |index| {
        const node = nodes.at(@intCast(index)).*;
        assert(node.nb_bits <= max_bits);
        table.codes[node.symbol].len = @intCast(node.nb_bits);
    }
    // The weights (`§4.2.1`): `Max_Number_of_Bits + 1 - Number_of_Bits`, and
    // the deepest symbol is the last one with a nonzero count.
    for (0..@as(usize, max_symbol) + 1) |symbol| {
        const len = table.codes[symbol].len;
        if (len == 0) continue;
        table.weights[symbol] = @intCast(max_bits + 1 - len);
    }
    table.symbol_count = max_symbol + 1;
    assert(table.weights[table.symbol_count - 1] != 0);
    codesFromWeights(table);
}

/// `§4.2.1.3`'s code values from the weights alone: "Symbols are sorted by
/// Weight. Within the same Weight, symbols keep natural sequential order. ...
/// Then, starting from the lowest Weight, prefix codes are distributed in
/// sequential order." The same arithmetic the decoder's `huff0.buildTable`
/// runs over its cells.
fn codesFromWeights(table: *Table) void {
    var rank_start: [code_length_max + 1]u16 = @splat(0);
    var rank_count: [code_length_max + 1]u16 = @splat(0);
    for (table.weights[0..table.symbol_count]) |weight| rank_count[weight] += 1;
    var start: u16 = 0;
    for (1..code_length_max + 1) |weight| {
        rank_start[weight] = start;
        start += rank_count[weight] << @intCast(weight - 1);
    }
    assert(start == @as(u16, 1) << @intCast(table.max_bits));
    for (table.weights[0..table.symbol_count], 0..) |weight, symbol| {
        if (weight == 0) continue;
        const cell = rank_start[weight];
        rank_start[weight] += @as(u16, 1) << @intCast(weight - 1);
        table.codes[symbol].bits = cell >> @intCast(weight - 1);
        table.codes[symbol].len = @intCast(table.max_bits + 1 - weight);
    }
}

/// Write the Huffman_Tree_Description (`§4.2.1.1`, `§4.2.1.2`), the inverse
/// of `huff0.readTree` (`HUF_writeCTable_wksp`, `huf_compress.c:248-289`).
/// Returns the bytes written: the header byte plus the series.
///
/// The weights of symbols 0 through `symbol_count - 2` are listed; the last
/// symbol's is implied by the completion. The FSE-compressed form is preferred
/// when it is under half the direct form's size, as the C prefers it.
pub fn writeTree(target: []u8, table: *const Table) Error!usize {
    const listed = table.symbol_count - 1;
    if (target.len < 1) return error.BufferTooSmall;
    var weights: [symbol_count_max - 1]u8 = undefined;
    for (0..listed) |symbol| weights[symbol] = table.weights[symbol];

    if (writeCompressedWeights(target[1..], weights[0..listed])) |series_len| {
        // `HUF_writeCTable_wksp` (`huf_compress.c:275-279`): the series form
        // wins when it is more than one byte and under half the listed
        // count, with the C's integer division (`hSize < maxSymbolValue / 2`).
        if (series_len > 1 and series_len < listed / 2) {
            target[0] = @intCast(series_len);
            return series_len + 1;
        }
    } else |_| {}

    // "write raw values as 4-bits (max : 15)": the direct form, two weights
    // per byte, high nibble first, the odd tail's low nibble zero. Only the
    // direct form is limited to 128 listed weights (`huf_compress.c:282`);
    // the series form above covers the rest, so the check sits here, after
    // the attempt. Checked before it, any tree listing more than 128 weights
    // fell back to Raw literals — which is every block whose literals carry
    // a byte of 0x81 or above.
    if (listed > 128) return error.TreeNotDescribable;
    const byte_count = (@as(usize, listed) + 1) / 2;
    if (1 + byte_count > target.len) return error.BufferTooSmall;
    target[0] = @intCast(126 + table.symbol_count);
    var index: usize = 0;
    while (index < byte_count) : (index += 1) {
        const high: u8 = weights[2 * index];
        const low: u8 = if (2 * index + 1 < listed) weights[2 * index + 1] else 0;
        target[1 + index] = (high << 4) + low;
    }
    return 1 + byte_count;
}

/// `HUF_compressWeights` (`huf_compress.c:147-197`): the weight series as an
/// `§4.1.1` table description plus one two-state bitstream. `error.NotCompressible`
/// when the C would return 0 or 1 — a single distinct weight is RLE's shape
/// and an all-distinct series cannot be compressed, and either falls back to
/// the direct form.
fn writeCompressedWeights(target: []u8, weights: []const u8) fse_compress.Error!usize {
    if (weights.len <= 1) return error.NotCompressible;
    var counts: [tablelog_max + 1]u32 = @splat(0);
    var max_symbol: u16 = 0;
    var largest: u32 = 0;
    for (weights) |weight| {
        assert(weight <= depth_max);
        counts[weight] += 1;
        if (weight > max_symbol) max_symbol = weight;
        if (counts[weight] > largest) largest = counts[weight];
    }
    // "only a single symbol in src : rle" and "each symbol present maximum
    // once => not compressible".
    if (largest == weights.len) return error.NotCompressible;
    if (largest == 1) return error.NotCompressible;

    const accuracy_log = fse_compress.optimalAccuracyLog(6, @intCast(weights.len), max_symbol, 2);
    var norm: fse_compress.Norm = undefined;
    try fse_compress.normalize(
        &norm,
        &counts,
        @intCast(weights.len),
        max_symbol,
        accuracy_log,
        .one,
    );
    const written = try fse_compress.writeDescription(target, &norm);
    const table = fse_compress.buildTable(norm);
    const stream = try fse_compress.compressSymbols(target[written..], weights, &table);
    return written + stream;
}

/// Write one Huffman-coded stream (`§4.2.2`): the symbols in reverse order,
/// then the single 1-bit end mark and the zero fill
/// (`HUF_compress1X_usingCTable_internal`, `huf_compress.c:1053-1155`).
/// Returns the stream's length.
///
/// The loop runs on a `bits.BackwardAccumulator`: the writer's fields would
/// spill to the stack across its flush call (a store-load round trip per
/// symbol), so the hot loop carries the accumulator in registers instead.
/// The emitted bytes are the writer's, exactly.
pub fn writeStream(target: []u8, source: []const u8, table: *const Table) Error!usize {
    var accumulator: bits.BackwardAccumulator = .init;
    var written: usize = 0;
    var index = source.len;
    // Five codes at most 11 bits each (§4.2.1's limit) fit the container
    // under any flush residue (55 + 7 <= 64), so the flush runs on a fixed
    // per-group schedule: one predictable bounds branch per five symbols
    // instead of one data-dependent fit check per symbol (the C's unrolled
    // `HUF_compress1X_usingCTable` body, `huf_compress.c:1080-1110`).
    while (index >= 5) {
        try accumulator.flush(target, &written);
        inline for (0..5) |_| {
            index -= 1;
            const code = table.codes[source[index]];
            // Every literal must have a code: the caller built the tree from
            // this very source.
            assert(code.len > 0);
            accumulator.addUnchecked(code.bits, code.len);
        }
    }
    while (index > 0) {
        index -= 1;
        const code = table.codes[source[index]];
        assert(code.len > 0);
        try accumulator.add(target, &written, code.bits, code.len);
    }
    return accumulator.close(target, &written);
}

/// Write the four-stream layout (`§3.1.1.3.1.6`,
/// `HUF_compress4X_usingCTable_internal`, `huf_compress.c:1141-1191`): the
/// 6-byte Jump_Table of the first three streams' sizes, then four independent
/// streams, the last one carrying the remainder. Returns the bytes written.
pub fn writeFourStreams(target: []u8, source: []const u8, table: *const Table) Error!usize {
    // Errata 7297 (`§3.1.1.3.1.6`): below 6 regenerated literals the fourth
    // stream's size underflows. The C's own floor here is 12, its cost
    // heuristic; the format's 6 is what the fixture's 10-literal section
    // shows is legal, and the ladder never splits below 256 literals anyway.
    if (source.len < literals.min_literals_for_4streams) return error.NotCompressible;
    const segment_len = (source.len + 3) / 4;
    if (target.len < literals.jump_table_len) return error.BufferTooSmall;
    var written: usize = literals.jump_table_len;
    for (0..4) |stream| {
        const begin = stream * segment_len;
        const end = if (stream == 3) source.len else @min(begin + segment_len, source.len);
        const stream_len = try writeStream(target[written..], source[begin..end], table);
        // "if (cSize == 0 || cSize > 65535) return 0": the Jump_Table's fields
        // are 16 bits, and a stream that cannot fit them is not one this
        // layout can carry.
        if (stream < 3) {
            if (stream_len > 0xffff) return error.NotCompressible;
            writeInt16(target[2 * stream ..][0..2], @intCast(stream_len));
        }
        written += stream_len;
    }
    return written;
}

/// The little-endian `u16` the Jump_Table's fields use.
fn writeInt16(target: []u8, value: u16) void {
    target[0] = @truncate(value);
    target[1] = @truncate(value >> 8);
}

/// The index of the highest set bit; `value` must be nonzero.
fn highBit(value: u32) u5 {
    assert(value != 0);
    return @intCast(31 - @clz(value));
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc8878-zstd.txt §4.2.1 (weights, the
// completion, the code assignment), §4.2.1.1 (the direct description),
// §4.2.1.2 (the FSE series), §4.2.2 (the streams), §3.1.1.3.1.1 and
// §3.1.1.3.1.6 (the section's headers and the Jump_Table).
// ---------------------------------------------------------------------------

/// The encoder's table for a tree the decoder read (`HUF_readCTable`,
/// `huf_compress.c:119-165`): the weights are the tree's, and the codes are
/// `§4.2.1.3`'s assignment. A dictionary's literals tree enters the encoder
/// this way — the tree is trusted as parsed, and the reuse rules decide
/// whether a block may use it.
pub fn tableOfTree(tree: *const huff0.Tree) Table {
    var table: Table = .{
        .weights = @splat(0),
        .symbol_count = tree.symbol_count,
        .max_bits = tree.max_bits,
        .codes = @splat(.{}),
    };
    for (tree.weights[0..tree.symbol_count], 0..) |weight, symbol| {
        table.weights[symbol] = weight;
    }
    codesFromWeights(&table);
    return table;
}

/// The `pair_*` fixtures' tree (`golden.pair_tree`): a hand-built, CLI-verified tree of
/// five listed weights plus the implied one.
fn pairTable() Table {
    const tree = huff0.readTree(&golden.pair_tree) catch unreachable;
    return tableOfTree(&tree);
}

test "buildTable's codes are the decoder's table, symbol for symbol" {
    // RFC 8878 §4.2.1.3 — the encoder's codes and the decoder's decode table
    // must be one assignment: a symbol's code, left-justified and read as the
    // stream's next Max_Number_of_Bits bits, indexes a cell holding it. The
    // tree's wire form (the description) is the middle of the round trip.
    var rng: DefaultPrng = .init(0xC0DE);
    const random = rng.random();
    var source: [4096]u8 = undefined;
    var description: [512]u8 = undefined;
    for (0..60) |_| {
        const length = random.uintLessThan(usize, source.len - 1) + 2;
        for (source[0..length]) |*byte| byte.* = random.uintLessThan(u8, 40);
        const histogram = Histogram.count(source[0..length]);
        const table = buildTable(&histogram, @intCast(length)) catch continue;
        // The description through the decoder's reader: the weights and the
        // completion's implied last symbol must come back.
        const written = try writeTree(&description, &table);
        const tree = try huff0.readTree(description[0..written]);
        try testing.expectEqual(table.symbol_count, tree.symbol_count);
        try testing.expectEqual(table.max_bits, tree.max_bits);
        try testing.expectEqualSlices(
            u8,
            table.weights[0..table.symbol_count],
            tree.weights[0..tree.symbol_count],
        );
        // And the codes: the decoder's own table, indexed by each code
        // left-justified at the top of Max_Number_of_Bits bits.
        const decoding = huff0.buildTable(&tree);
        for (table.codes, 0..) |code, symbol| {
            if (code.len == 0) continue;
            const cell = decoding.entries[code.bits << @intCast(tree.max_bits - code.len)];
            try testing.expectEqual(@as(u8, @intCast(symbol)), cell.symbol);
            try testing.expectEqual(code.len, cell.num_bits);
        }
        // And the stream: the source through the tree, decoded back by the
        // decoder's own stream reader.
        var stream: [4096]u8 = undefined;
        const stream_len = try writeStream(&stream, source[0..length], &table);
        var decoded: [4096]u8 = undefined;
        try huff0.decodeStream(&decoding, stream[0..stream_len], decoded[0..length]);
        try testing.expectEqualSlices(u8, source[0..length], decoded[0..length]);
    }
}

test "writeTree reproduces the reference encoder's tree descriptions" {
    // RFC 8878 §4.2.1.1 — the direct form against the RFC's own worked
    // example (`golden.pair_tree`, CLI-verified): five listed weights, high
    // nibble first, header 128 + (Number_of_Symbols - 1).
    const table = pairTable();
    var target: [64]u8 = undefined;
    const written = try writeTree(&target, &table);
    try testing.expectEqualSlices(u8, &golden.pair_tree, target[0..written]);
    // RFC 8878 §4.2.1.2 — the FSE form against `zstd` v1.5.7's own
    // `HUF_compressWeights` bytes: the golden weights (122 listed, plus the
    // completion's implied seventh) re-encode to the reference's description
    // and stream, byte for byte. The tree comes from the decoder's own reader
    // of the reference bytes, so the weights, the depth, and the implied last
    // symbol are all the reference's.
    const golden_tree = try huff0.readTree(&golden.weights_description);
    const series_table = tableOfTree(&golden_tree);
    try testing.expectEqual(@as(usize, golden.weights_expected.len + 1), series_table.symbol_count);
    const written_series = try writeTree(&target, &series_table);
    try testing.expectEqualSlices(
        u8,
        &golden.weights_description,
        target[0..written_series],
    );
}

test "the streams reproduce the RFC's Table 25 example byte for byte" {
    // RFC 8878 §4.2.1.3 (Table 25) — the pair golden: the four literals of the
    // §4.2.2 example through the example's tree write `01 0D`, which the CLI
    // and Zig std decode to `00 01 04 05` (errata 8195's `10 0D` is the
    // example's own, wrong, assignment). This is the Huffman path's day-one
    // byte-exact anchor.
    const table = pairTable();
    var target: [16]u8 = undefined;
    const written = try writeStream(&target, &golden.pair_literals, &table);
    try testing.expectEqualSlices(u8, &golden.pair_stream, target[0..written]);
    // And the whole literals section, as the fixture carries it: the 3-byte
    // header (Compressed, Size_Format 00, Regenerated_Size 4, Compressed_Size
    // 6), the tree, the stream.
    var section: [16]u8 = undefined;
    const header = try literals.parseHeader(&golden.pair_literals_section);
    try testing.expectEqual(literals.BlockType.compressed, header.block_type);
    const tree_written = try writeTree(section[3..], &table);
    const stream_written = try writeStream(
        section[3 + tree_written ..],
        &golden.pair_literals,
        &table,
    );
    const compressed_size = tree_written + stream_written;
    writeHeader(section[0..3], header.block_type, header.size_format, 4, compressed_size);
    try testing.expectEqualSlices(
        u8,
        &golden.pair_literals_section,
        section[0 .. 3 + compressed_size],
    );
}

test "the four-stream writer reproduces the hand-built fixture" {
    // RFC 8878 §3.1.1.3.1.6 — the Jump_Table and the four streams: the
    // hand-built, CLI-verified fixture's body (tree, Jump_Table 1/2/2, four
    // streams) re-encoded from its literals must come out byte for byte.
    const table = pairTable();
    const literals_bytes = [_]u8{ 0, 1, 2, 4, 5, 0, 2, 2, 2, 0 };
    var body: [64]u8 = undefined;
    const tree_written = try writeTree(&body, &table);
    const streams_written = try writeFourStreams(
        body[tree_written..],
        &literals_bytes,
        &table,
    );
    const body_len = tree_written + streams_written;
    try testing.expectEqualSlices(
        u8,
        &four_stream_body,
        body[0..body_len],
    );
    // The last-stream padding corners: 7 literals split 2/2/2/1, and 6 split
    // 2/2/2/0 (the fourth stream is the end marker alone).
    const seven = [_]u8{ 0, 1, 4, 5, 2, 0, 4 };
    const six = [_]u8{ 0, 1, 4, 5, 2, 0 };
    try expectFourStreamBody(&table, &seven, &four_stream_rs7_body);
    try expectFourStreamBody(&table, &six, &four_stream_rs6_body);
}

/// The rs = 7 and rs = 6 bodies of the hand-built fixtures
/// (`literals.zig`'s `four_stream_rs7` / `four_stream_rs6`, each CLI-verified
/// as a one-block frame): the tree, the Jump_Table, and the four streams, the
/// last of which decodes one symbol (rs = 7) or is the end marker alone
/// (rs = 6).
const four_stream_rs7_body: [15]u8 = .{
    0x84, 0x43, 0x20, 0x10, // the tree
    0x01, 0x00, 0x02, 0x00, 0x01, 0x00, // Jump_Table: 1, 2, 1
    0x0d, 0x01, 0x01, 0x13, 0x10,
};
const four_stream_rs6_body: [15]u8 = .{
    0x84, 0x43, 0x20, 0x10, // the tree
    0x01, 0x00, 0x02, 0x00, 0x01, 0x00, // Jump_Table: 1, 2, 1
    0x0d, 0x01, 0x01, 0x13, 0x01,
};

/// The hand-built four-stream body the `literals.zig` fixture carries
/// (`four_stream_body`, CLI-verified): the tree, the Jump_Table, and the
/// streams.
const four_stream_body: [16]u8 = .{
    0x84, 0x43, 0x20, 0x10, // the tree (`golden.pair_tree`)
    0x01, 0x00, 0x02, 0x00, 0x02, 0x00, // Jump_Table: 1, 2, 2
    0x69, // stream 1: 0, 1, 2
    0x03, 0x02, // stream 2: 4, 5, 0
    0x49, 0x02, // stream 3: 2, 2, 2
    0x03, // stream 4: 0
};

fn expectFourStreamBody(table: *const Table, source: []const u8, expected: []const u8) !void {
    var body: [64]u8 = undefined;
    const tree_written = try writeTree(&body, table);
    const streams_written = try writeFourStreams(body[tree_written..], source, table);
    try testing.expectEqualSlices(u8, expected, body[0 .. tree_written + streams_written]);
}

/// The literals section's compressed-family header (`§3.1.1.3.1.1`), written
/// for `literals_compress` to share: the type and Size_Format bits, then
/// Regenerated_Size and Compressed_Size as adjacent little-endian fields.
fn writeHeader(
    target: []u8,
    block_type: literals.BlockType,
    size_format: u2,
    regenerated_size: u32,
    compressed_size: usize,
) void {
    var header_bits: u64 = @intFromEnum(block_type) + (@as(u64, size_format) << 2);
    header_bits |= @as(u64, regenerated_size) << 4;
    const shift: u6 = switch (size_format) {
        0, 1 => 14,
        2 => 18,
        3 => 22,
    };
    header_bits |= @as(u64, compressed_size) << shift;
    const header_len: usize = switch (size_format) {
        0, 1 => 3,
        2 => 4,
        3 => 5,
    };
    for (target[0..header_len], 0..) |*byte, index| {
        byte.* = @truncate(header_bits >> @intCast(8 * index));
    }
}

test "a Fibonacci histogram's tree flattens onto the depth cap" {
    // `HUF_buildCTable_wksp` (`huf_compress.c:723-757`) builds the unlimited
    // tree first and `HUF_setMaxHeight` (`:376-493`) flattens it onto
    // `HUF_optimalTableLog`'s cap. A Fibonacci-count histogram is the
    // deepest a tree can be for its byte count — 20 symbols' unlimited tree
    // is deeper than the 11-bit cap — so this pins the flattening path (and
    // the absence of a pre-flattening depth assert, which ordinary Writer
    // bytes reached; the fuzz wave that found it is in src/zstd/AGENTS.md).
    var counts: [symbol_count_max]u32 = @splat(0);
    var previous: u32 = 0;
    var current: u32 = 1;
    var total: u32 = 0;
    for (0..20) |symbol| {
        counts[symbol] = current;
        total += current;
        const next = previous + current;
        previous = current;
        current = next;
    }
    const histogram: Histogram = .{
        .counts = counts,
        .max_symbol = 19,
        .largest = previous,
    };
    const table = try buildTable(&histogram, total);
    try testing.expect(table.max_bits <= depth_max);
    try testing.expect(table.max_bits > 0);
    for (counts[0..20], 0..) |count, symbol| {
        try testing.expectEqual(count != 0, table.codes[symbol].len != 0);
    }
}
