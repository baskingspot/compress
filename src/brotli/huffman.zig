//! The prefix-code layer (RFC 7932 §3): the two tree forms — §3.4's simple
//! form and §3.5's complex form — over §3.2's canonical code construction,
//! and the two-level decode table they build.
//!
//! A symbol is decoded by peeking `root_bits` bits, resolving the root
//! entry, and consuming the code with `take` — the strict gate, so a read the
//! input cannot satisfy is `error.Truncated`, never a symbol assembled from
//! padding. Codes longer than `root_bits` continue into a subtable indexed by
//! the following bits. Both levels store the code's length, so the table is
//! a pure peek-and-take structure; the reference's `BrotliReadSymbol` has the
//! same shape (`c/dec/huffman.c`).
//!
//! The table region is comptime-capped: `max_trees` trees per category
//! and, per tree, the reference's proven ceiling on the two-level table's
//! size. Nothing here allocates.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const bits = @import("bits.zig");
const golden = @import("golden.zig");

/// §3.3 — the alphabet sizes. Distance alphabets are dynamic: 16 special
/// codes, NDIRECT direct codes, and 48 code slots per NPOSTFIX bit (max 520
/// at NPOSTFIX=3, NDIRECT=120). Block-type and context-map alphabets are
/// dynamic too; these are their storage ceilings, `max_trees` and the
/// 256-value block-type ceiling plus the two extra symbols.
pub const literal_alphabet_size = 256;
pub const command_alphabet_size = 704;
pub const block_count_alphabet_size = 26;
pub const max_distance_alphabet_size = 16 + 120 + (48 << 3);
pub const max_block_type_alphabet_size = 256 + 2;
pub const max_context_map_alphabet_size = max_trees + 16;

/// The comptime cap on trees per tree category. The format allows up
/// to 256; a meta-block declaring more fails `error.TooManyTrees`, and the
/// cap is raisable by editing this constant (the region grows with it).
pub const max_trees = 64;

/// §3.4, §3.5 — the prefix-code layer's refusals.
pub const Error = error{
    /// §3.4 — a simple code's symbol is at or past the alphabet size.
    SimpleHuffmanAlphabet,
    /// §3.4 — a simple code repeats a symbol.
    SimpleHuffmanSame,
    /// §3.5 — the code-length code is not a complete prefix code.
    BadCodeLengthCode,
    /// §3.5 — the code-length sequence breaks a rule: the Kraft sum is not
    /// 32768, a repeat overruns the alphabet, or the set would need more
    /// table than the format's proven ceiling.
    BadHuffmanCode,
};

/// The reference's proven ceiling on a two-level table's entry count, per
/// 32-symbol block of alphabet: "Maximum possible Huffman table size for an
/// alphabet size of (index * 32), max code length 15 and root table bits 8"
/// (google/brotli v1.2.0 `c/dec/huffman.c`; ~13.4% over the alphabet size).
/// The build's two-pass construction produces the same table as the
/// reference's and stays inside this bound.
const max_table_size_by_block = [37]u16{
    256,  402,  436,  468,  500,  534,  566,  598,  630,  662,  694,  726,  758,
    790,  822,  854,  886,  920,  952,  984,  1016, 1048, 1080, 1112, 1144, 1176,
    1208, 1240, 1272, 1304, 1336, 1368, 1400, 1432, 1464, 1496, 1528,
};

/// The table-entry ceiling for `alphabet_size` symbols.
fn tableBound(comptime alphabet_size: usize) usize {
    return max_table_size_by_block[(alphabet_size + 31) / 32];
}

/// The root table's width. Fixed at 8 for every tree, the reference's
/// `HUFFMAN_TABLE_BITS`; shorter codes are replicated across the root, so
/// every tree's primary table is 256 entries.
const root_bits: u5 = 8;

/// One decode-table entry: a leaf consuming `len` code bits and returning
/// `symbol`, or — with `len == 0` — a root entry pointing at a subtable
/// `symbol` bits wide based at `sub_base` within the tree's `sub` region.
const Entry = packed struct(u32) {
    len: u4,
    symbol: u10,
    sub_base: u10,
    _unused: u8,
};

/// A canonical prefix-code decode table (§3.2) for alphabets of at most
/// `bound` symbols, built by `build` from a length-per-symbol slice. The
/// declared alphabet size is the slice's length, so the storage bound and
/// the §3.4 symbol-width rules are independent.
pub fn Tree(comptime bound: usize) type {
    const table_size = tableBound(bound);
    // The entry's `symbol` and `sub_base` fields are 10 bits wide: the
    // largest alphabet this package instantiates (704) needs 824 subtable
    // entries, and a raisable cap must stay inside the field.
    comptime {
        assert(bound <= 1024);
        assert(table_size - (1 << root_bits) <= 1023);
    }

    return struct {
        const Self = @This();

        /// The largest declared alphabet this instantiation can hold.
        pub const alphabet_size = bound;

        /// The primary table, indexed by the next `root_bits` wire bits.
        root: [1 << root_bits]Entry,
        /// Subtables, in first-use order; `sub_used` entries are live.
        sub: [table_size - (1 << root_bits)]Entry,
        /// Live entries in `sub`.
        sub_used: u16,
        /// §3.4, §3.5 — the single zero-length-code symbol: decoding it
        /// consumes no bits and returns it. `null` for a normal tree.
        single: ?u16,

        /// Build the table from `lens`: the code length of each symbol in
        /// symbol order, 0 meaning the symbol does not occur (`§3.2`).
        /// `lens.len` is the declared alphabet size, at most `bound`.
        ///
        /// `error.BadHuffmanCode` when `lens` is not a complete prefix code
        /// — `§3.5`: "the sum of (32768 >> code length) over all the non-zero
        /// code lengths ... must be equal to 32768" — or when the two-level
        /// table would exceed the storage: no conformant code-length set
        /// can, the storage is the reference's proven ceiling, but the check
        /// is what makes the region a hard bound rather than a hope. The
        /// wire path (`readComplexTree`'s `code_space` accumulator) refuses a
        /// bad set first, so a caller of this public entry gets the refusal
        /// rather than a table built from an over- or under-subscribed set.
        pub fn build(self: *Self, lens: []const u4) Error!void {
            assert(lens.len > 0);
            assert(lens.len <= bound);
            self.single = null;
            self.sub_used = 0;

            // §3.2, steps 1-2: the length histogram and the smallest code of
            // each length. A length of 0 means the symbol is absent, and
            // `bl_count[0]` is 0 by definition. The histogram pass also sums
            // the Kraft weights: an over-subscribed set would overflow the
            // canonical `next_code` below, and an under-subscribed one has no
            // table at all.
            var count: [16]u16 = @splat(0);
            var kraft: u32 = 0;
            for (lens) |len| {
                count[len] += 1;
                if (len != 0) kraft += @as(u32, 0x8000) >> @intCast(len);
            }
            if (kraft != 0x8000) return error.BadHuffmanCode;
            count[0] = 0;
            var next_code: [16]u16 = @splat(0);
            var code: u32 = 0;
            for (1..16) |len| {
                code = (code + count[len - 1]) << 1;
                next_code[len] = @intCast(code);
            }

            // §3.2, step 3 — the longest code of every root-prefix group,
            // needed before the subtables can be laid out. The canonical
            // assignment gives each length's symbols consecutive codes in
            // symbol order, so one symbol-order pass with a running code per
            // length is exact.
            var group_max: [1 << root_bits]u4 = @splat(0);
            var running: [16]u32 = widenCodes(next_code);
            for (lens) |len| {
                if (len == 0) continue;
                const symbol_code = running[len];
                running[len] += 1;
                if (len > root_bits) {
                    const prefix = wireBits(@intCast(symbol_code), len) & ((1 << root_bits) - 1);
                    if (len > group_max[prefix]) group_max[prefix] = len;
                }
            }

            // Lay the subtables out in prefix order; the root entry for each
            // long group becomes the pointer.
            var sub_base: [1 << root_bits]u16 = @splat(0);
            var sub_total: usize = 0;
            for (0..1 << root_bits) |prefix| {
                if (group_max[prefix] == 0) continue;
                const width: u5 = group_max[prefix] - root_bits;
                const size = @as(usize, 1) << width;
                const total = (1 << root_bits) + sub_total + size;
                if (total > table_size) return error.BadHuffmanCode;
                sub_base[prefix] = @intCast(sub_total);
                self.root[prefix] = .{
                    .len = 0,
                    .symbol = width,
                    .sub_base = @intCast(sub_total),
                    ._unused = 0,
                };
                sub_total += size;
            }
            self.sub_used = @intCast(sub_total);

            // §3.2, step 3 — assign the codes and fill both levels.
            running = widenCodes(next_code);
            for (lens, 0..) |len, symbol| {
                if (len == 0) continue;
                const symbol_code = running[len];
                running[len] += 1;
                const wire = wireBits(@intCast(symbol_code), len);
                if (len <= root_bits) {
                    var i: usize = wire;
                    while (i < 1 << root_bits) : (i += @as(usize, 1) << @intCast(len)) {
                        self.root[i] = .{
                            .len = len,
                            .symbol = @intCast(symbol),
                            .sub_base = 0,
                            ._unused = 0,
                        };
                    }
                } else {
                    const prefix = wire & ((1 << root_bits) - 1);
                    const size = @as(usize, 1) << (group_max[prefix] - root_bits);
                    var i: usize = wire >> root_bits;
                    while (i < size) : (i += @as(usize, 1) << @intCast(len - root_bits)) {
                        self.sub[sub_base[prefix] + i] = .{
                            .len = @intCast(len - root_bits),
                            .symbol = @intCast(symbol),
                            .sub_base = 0,
                            ._unused = 0,
                        };
                    }
                }
            }
        }

        /// Decode one symbol (§3.2). The caller spells out the bit source:
        /// a type with `peek`, `take`, and an `ErrorSet`, such as this
        /// package's `bits.BitReader` or the streaming reader's bit source.
        /// The peek can read padding; every consume is a strict `take`, so
        /// a starved decode is `error.Truncated`.
        pub inline fn decode(self: *const Self, comptime Bits: type, br: *Bits) Bits.ErrorSet!u16 {
            if (try self.decodeRoot(Bits, br)) |symbol| return symbol;
            return self.decodeSubtable(Bits, br);
        }

        /// The root-table half of `decode` (§3.2): the symbol, or `null`
        /// when the peeked code runs past `root_bits` — the caller's
        /// fallback is `decodeSubtable` (or the plain `decode`). Split out
        /// for hot loops that keep their bit source in a local the cold
        /// path must not escape (the command layer's literal run).
        pub inline fn decodeRoot(
            self: *const Self,
            comptime Bits: type,
            br: *Bits,
        ) Bits.ErrorSet!?u16 {
            if (self.single) |symbol| return symbol;
            const entry = self.root[@intCast(try br.peek(root_bits))];
            if (entry.len == 0) return null;
            // The peek covered the root's width, and a root code is never
            // wider: the consume needs no second refill.
            _ = try br.takeLoaded(entry.len);
            return entry.symbol;
        }

        /// The subtable half of `decode`, outlined: codes longer than
        /// `root_bits` are the rare path, and keeping it out of the inlined
        /// fast path keeps the hot loop's register pressure to the root
        /// peek-and-take. Re-peeks the root bits `decodeRoot` left
        /// unconsumed.
        pub fn decodeSubtable(self: *const Self, comptime Bits: type, br: *Bits) Bits.ErrorSet!u16 {
            const entry = self.root[@intCast(try br.peek(root_bits))];
            assert(entry.len == 0);
            _ = try br.takeLoaded(root_bits);
            const sub_index: u6 = @intCast(entry.symbol);
            const sub_base: usize = entry.sub_base;
            // A subtable is as wide as its group's longest suffix, so the
            // peek covers every code it holds.
            const sub_entry = self.sub[sub_base + @as(usize, @intCast(try br.peek(sub_index)))];
            _ = try br.takeLoaded(sub_entry.len);
            return sub_entry.symbol;
        }
    };
}

/// §3.3's fixed alphabets and the capped dynamic ones.
pub const LiteralTree = Tree(literal_alphabet_size);
pub const CommandTree = Tree(command_alphabet_size);
pub const DistanceTree = Tree(max_distance_alphabet_size);
pub const BlockTypeTree = Tree(max_block_type_alphabet_size);
pub const BlockCountTree = Tree(block_count_alphabet_size);
pub const ContextMapTree = Tree(max_context_map_alphabet_size);

/// One meta-block's tree region: `max_trees` trees in each tree
/// category, the three block-type and block-count trees of §6, and the
/// context-map tree of §7.3 (the literal map's, then the distance map's).
/// About 672 KiB at the cap: a caller-owned stack or `Buffer` object, never
/// a copy.
pub const Trees = struct {
    /// NTREESL literal trees.
    literal: [max_trees]LiteralTree,
    /// NBLTYPESI insert-and-copy trees, one per command block type.
    command: [max_trees]CommandTree,
    /// NTREESD distance trees.
    distance: [max_trees]DistanceTree,
    /// One block-type tree per block category (L, I, D).
    block_type: [3]BlockTypeTree,
    /// One block-count tree per block category (L, I, D).
    block_count: [3]BlockCountTree,
    /// The context-map tree, reused by the literal and distance maps.
    context_map: ContextMapTree,
};

/// §3.2 — the code's wire value: `code` is the canonical numeral, whose most
/// significant bit is transmitted first, so the low `len` bits of the result
/// are the code in transmission order.
fn wireBits(code: u16, len: u5) u16 {
    return @bitReverse(code) >> @intCast(16 - @as(u6, len));
}

fn widenCodes(next_code: [16]u16) [16]u32 {
    var wide: [16]u32 = @splat(0);
    for (next_code, 0..) |value, i| wide[i] = value;
    return wide;
}

/// §3 — read one prefix code description: the simple form (§3.4), the
/// complex form (§3.5), and the table build. `alphabet_size` is the
/// declared alphabet — 256 for literals, 704 for insert-and-copy lengths,
/// NBLTYPES + 2 for block types, NTREES + RLEMAX for context maps, and
/// 16 + NDIRECT + (48 << NPOSTFIX) for distances — and must fit the tree
/// type's bound.
pub fn readTree(
    comptime T: type,
    comptime Bits: type,
    br: *Bits,
    tree: *T,
    alphabet_size: u16,
) (Bits.ErrorSet || Error)!void {
    assert(alphabet_size > 0);
    assert(alphabet_size <= T.alphabet_size);
    const form = try br.take(2);
    if (form == 1) return readSimpleTree(T, Bits, br, tree, alphabet_size);
    return readComplexTree(T, Bits, br, tree, alphabet_size, @intCast(form));
}

/// §3.4 — the simple form: 2 bits NSYM-1, NSYM symbols in ALPHABET_BITS
/// bits, and the tree-select bit for NSYM = 4. ALPHABET_BITS is "the
/// smallest number of bits that can represent all symbols in the alphabet":
/// the bit width of `alphabet_size - 1`, not its floor-log (T7).
fn readSimpleTree(
    comptime T: type,
    comptime Bits: type,
    br: *Bits,
    tree: *T,
    alphabet_size: u16,
) (Bits.ErrorSet || Error)!void {
    const nsym: u8 = @as(u8, @intCast(try br.take(2))) + 1;
    const alphabet_bits: u6 = @intCast(32 - @clz(@as(u32, alphabet_size - 1)));
    var symbols: [4]u16 = undefined;
    var i: u8 = 0;
    while (i < nsym) : (i += 1) {
        const symbol: u16 = @intCast(try br.take(alphabet_bits));
        if (symbol >= alphabet_size) return error.SimpleHuffmanAlphabet;
        for (symbols[0..i]) |seen| {
            if (seen == symbol) return error.SimpleHuffmanSame;
        }
        symbols[i] = symbol;
    }

    if (nsym == 1) {
        // §3.4: "the code length for the one symbol is zero — ... when
        // decoding a symbol using this prefix code, no bits are read and the
        // one symbol is returned".
        tree.single = symbols[0];
        return;
    }
    var lens: [T.alphabet_size]u4 = @splat(0);
    switch (nsym) {
        2 => {
            lens[symbols[0]] = 1;
            lens[symbols[1]] = 1;
        },
        3 => {
            // §3.4 — "the code lengths for the symbols are 1, 2, 2 in the
            // order they appear in the representation".
            lens[symbols[0]] = 1;
            lens[symbols[1]] = 2;
            lens[symbols[2]] = 2;
        },
        else => {
            // §3.4 — "the code lengths (in order of symbols decoded) depend
            // on the tree-select bit: 2, 2, 2, 2 (tree-select bit 0), or
            // 1, 2, 3, 3 (tree-select bit 1)".
            if ((try br.take(1)) == 0) {
                for (symbols) |symbol| lens[symbol] = 2;
            } else {
                lens[symbols[0]] = 1;
                lens[symbols[1]] = 2;
                lens[symbols[2]] = 3;
                lens[symbols[3]] = 3;
            }
        },
    }
    try tree.build(lens[0..alphabet_size]);
}

/// §3.5 — the fixed variable-length code for the code-length-code lengths,
/// read right to left: 0 -> `00`, 1 -> `0111`, 2 -> `011`, 3 -> `10`,
/// 4 -> `01`, 5 -> `1111`. Decoded with a 4-bit peek and the two tables the
/// reference carries (`kCodeLengthPrefixLength`/`Value`).
fn readClLength(comptime Bits: type, br: *Bits) Bits.ErrorSet!u4 {
    const peeked: usize = @intCast(try br.peek(4));
    const len = cl_prefix_length[peeked];
    _ = try br.take(len);
    return cl_prefix_value[peeked];
}

const cl_prefix_length = [16]u4{ 2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4 };
const cl_prefix_value = [16]u4{ 0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5 };

/// §3.5 — the order the code-length-code lengths appear in.
const cl_order = [18]u5{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

/// §3.5 — the complex form: HSKIP, the code-length code over the 18
/// code-length symbols, then the alphabet's code lengths themselves, run
/// length coded with symbols 16 and 17.
fn readComplexTree(
    comptime T: type,
    comptime Bits: type,
    br: *Bits,
    tree: *T,
    alphabet_size: u16,
    hskip: u2,
) (Bits.ErrorSet || Error)!void {
    assert(hskip != 1);

    // The code-length code's own lengths, read in `cl_order` from HSKIP on.
    // "If there are at least two non-zero code lengths, any trailing zero
    // code lengths are omitted": the sequence ends when the Kraft sum of
    // (32 >> len) over the non-zero lengths reaches 32. A single non-zero
    // length means the code is the one-symbol zero-length code.
    var cl_lens: [18]u4 = @splat(0);
    var space: i32 = 32;
    var nonzero: u32 = 0;
    var i: usize = hskip;
    while (i < cl_order.len) : (i += 1) {
        const len = try readClLength(Bits, br);
        cl_lens[cl_order[i]] = len;
        if (len != 0) {
            space -= @as(i32, 32) >> len;
            nonzero += 1;
            if (space < 0) return error.BadCodeLengthCode;
            if (space == 0) break;
        }
    }
    if (space != 0 and nonzero != 1) return error.BadCodeLengthCode;

    // The code-length code's decode table: 32 entries (lengths are at most
    // 5), or the single symbol.
    var cl_table: [32]u4 = @splat(0);
    var cl_symbols: [32]u5 = @splat(0);
    var cl_single: ?u5 = null;
    if (nonzero == 1) {
        for (cl_lens, 0..) |len, symbol| {
            if (len != 0) cl_single = @intCast(symbol);
        }
    } else {
        var count: [6]u16 = @splat(0);
        for (cl_lens) |len| count[len] += 1;
        count[0] = 0;
        var next: [6]u16 = @splat(0);
        var code: u32 = 0;
        for (1..6) |len| {
            code = (code + count[len - 1]) << 1;
            next[len] = @intCast(code);
        }
        for (cl_lens, 0..) |len, symbol| {
            if (len == 0) continue;
            const wire = wireBits(next[len], len);
            next[len] += 1;
            var e: usize = wire;
            while (e < 32) : (e += @as(usize, 1) << @intCast(len)) {
                cl_table[e] = len;
                cl_symbols[e] = @intCast(symbol);
            }
        }
    }

    // §3.5 — the alphabet's code lengths, one symbol at a time: 0..15 are
    // lengths, 16 repeats the previous non-zero length 3..6 times, 17
    // repeats zero 3..10 times, and a repeat of the same kind modifies the
    // previous count instead of adding to it.
    var lens: [T.alphabet_size]u4 = @splat(0);
    var symbol: usize = 0;
    var code_space: i32 = 32768;
    var repeat: u32 = 0;
    var prev_len: u4 = 8; // "the previous length is taken to be 8"
    var repeat_len: u4 = 8; // the length a 16/17 run targets (0 = zeros)
    while (symbol < alphabet_size and code_space > 0) {
        const code_len: u5 = cl_single orelse blk: {
            const peeked: usize = @intCast(try br.peek(5));
            const len = cl_table[peeked];
            _ = try br.take(len);
            break :blk cl_symbols[peeked];
        };
        if (code_len < 16) {
            repeat = 0;
            lens[symbol] = @intCast(code_len);
            symbol += 1;
            if (code_len != 0) {
                prev_len = @intCast(code_len);
                code_space -= @as(i32, 32768) >> code_len;
                if (code_space < 0) return error.BadHuffmanCode;
            }
            continue;
        }
        const extra_bits: u3 = if (code_len == 16) 2 else 3;
        const target: u4 = if (code_len == 16) prev_len else 0;
        if (repeat_len != target) {
            repeat = 0;
            repeat_len = target;
        }
        const delta: u32 = try br.take(extra_bits);
        var count = repeat;
        if (count > 0) count = (count - 2) << extra_bits;
        count += delta + 3;
        const added = count - repeat;
        if (symbol + added > alphabet_size) return error.BadHuffmanCode;
        if (target != 0) {
            for (lens[symbol..][0..added]) |*len| len.* = target;
            code_space -= @as(i32, @intCast(added)) << @intCast(15 - @as(u5, target));
            if (code_space < 0) return error.BadHuffmanCode;
        }
        symbol += added;
        repeat = count;
    }
    if (code_space != 0) return error.BadHuffmanCode;
    try tree.build(lens[0..alphabet_size]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "prefix codes: RFC 7932 §3.2's canonical construction example" {
    // RFC 7932 §3.2 — the alphabet ABCDEFGH with lengths
    // (3, 3, 3, 3, 3, 2, 4, 4) assigns A..E = 010..110, F = 00, G = 1110,
    // H = 1111 (symbols decoded in order).
    const lens = [8]u4{ 3, 3, 3, 3, 3, 2, 4, 4 };
    var tree: LiteralTree = undefined;
    try tree.build(&lens);
    const codes = [8]struct { value: u16, len: u5 }{
        .{ .value = 0b010, .len = 3 },
        .{ .value = 0b011, .len = 3 },
        .{ .value = 0b100, .len = 3 },
        .{ .value = 0b101, .len = 3 },
        .{ .value = 0b110, .len = 3 },
        .{ .value = 0b00, .len = 2 },
        .{ .value = 0b1110, .len = 4 },
        .{ .value = 0b1111, .len = 4 },
    };
    for (codes, 0..) |code, symbol| {
        var packer: golden.Packer = .{};
        packCode(&packer, code.value, code.len);
        var br: bits.BitReader = .init(packer.slice());
        try testing.expectEqual(@as(u16, @intCast(symbol)), try tree.decode(bits.BitReader, &br));
        try testing.expectEqual(@as(u64, packer.bit_len), br.bit_pos);
    }
}

test "prefix codes: a code longer than the root table takes the subtable" {
    // A complete ladder code (§3.2's construction, lengths 1..15 with the
    // last length doubled): the Kraft sum is 32768, so it is a conformant
    // code whose longest codes live in a subtable.
    var lens: [16]u4 = undefined;
    for (0..15) |i| lens[i] = @intCast(i + 1);
    lens[15] = 15;
    var tree: LiteralTree = undefined;
    try tree.build(&lens);
    try testing.expect(tree.sub_used > 0);

    // Symbol 14 (length 15) is the last of the ladder; symbol 15 shares the
    // length. Their canonical codes are 0b111111111111110 and
    // 0b111111111111111.
    var packer: golden.Packer = .{};
    packCode(&packer, 0b111111111111110, 15);
    var br: bits.BitReader = .init(packer.slice());
    try testing.expectEqual(@as(u16, 14), try tree.decode(bits.BitReader, &br));

    var second: golden.Packer = .{};
    packCode(&second, 0b111111111111111, 15);
    var br2: bits.BitReader = .init(second.slice());
    try testing.expectEqual(@as(u16, 15), try tree.decode(bits.BitReader, &br2));
}

test "prefix codes: a set that is not a complete code is BadHuffmanCode" {
    // RFC 7932 §3.5 — "the sum of (32768 >> code length) over all the
    // non-zero code lengths ... must be equal to 32768". 200 one-bit codes
    // is 200 * 16384: the canonical `next_code` accumulator used to overflow
    // the `u16` it stores on a set like this one (a panic in Debug and
    // ReleaseSafe, undefined behavior in ReleaseFast) before the table was
    // even built.
    var tree: LiteralTree = undefined;
    try testing.expectError(error.BadHuffmanCode, tree.build(&([_]u4{1} ** 200)));
    // Under-subscribed: three two-bit codes leave 24,576 of the 32,768
    // unassigned, so there is no table to build. The all-zero set is the
    // degenerate case.
    try testing.expectError(error.BadHuffmanCode, tree.build(&([_]u4{2} ** 3)));
    try testing.expectError(error.BadHuffmanCode, tree.build(&([_]u4{0} ** 256)));
}

test "prefix codes: the two-level table never overflows a short read" {
    // A two-symbol code: one bit is consumed, and a starved read is
    // `error.Truncated`, never a symbol decoded out of padding.
    const lens = [2]u4{ 1, 1 };
    var tree: LiteralTree = undefined;
    try tree.build(&lens);
    var empty: bits.BitReader = .init(&[_]u8{});
    try testing.expectError(error.Truncated, tree.decode(bits.BitReader, &empty));
    var one: bits.BitReader = .init(&[_]u8{0x00});
    try testing.expectEqual(@as(u16, 0), try tree.decode(bits.BitReader, &one));
}

test "simple form: RFC 7932 §3.4's length patterns and the sorted order rule" {
    // NSYM = 2, symbols presented unordered (66, 65): both get length 1, and
    // "prefix codes of the same bit length must be assigned to the symbols
    // in sorted order", so 65 gets code 0 and 66 code 1.
    var packer: golden.Packer = .{};
    packer.pack(1, 2); // simple
    packer.pack(1, 2); // NSYM - 1 = 1
    packer.pack(66, 8);
    packer.pack(65, 8);
    var br: bits.BitReader = .init(packer.slice());
    var tree: LiteralTree = undefined;
    try readTree(LiteralTree, bits.BitReader, &br, &tree, 256);
    try testing.expectEqual(@as(u64, packer.bit_len), br.bit_pos);
    var zero: bits.BitReader = .init(&[_]u8{0x00});
    try testing.expectEqual(@as(u16, 65), try tree.decode(bits.BitReader, &zero));
    var one: bits.BitReader = .init(&[_]u8{0x01});
    try testing.expectEqual(@as(u16, 66), try tree.decode(bits.BitReader, &one));

    // NSYM = 3: lengths 1, 2, 2 in presentation order.
    var three: golden.Packer = .{};
    three.pack(1, 2);
    three.pack(2, 2);
    three.pack(7, 8);
    three.pack(9, 8);
    three.pack(8, 8);
    var br3: bits.BitReader = .init(three.slice());
    var tree3: LiteralTree = undefined;
    try readTree(LiteralTree, bits.BitReader, &br3, &tree3, 256);
    // 7 has the length-1 code (wire 0); 8 and 9 the length-2 codes in sorted
    // order (wire 10 and 11).
    var b0: bits.BitReader = .init(&[_]u8{0x00});
    try testing.expectEqual(@as(u16, 7), try tree3.decode(bits.BitReader, &b0));
    var b1: bits.BitReader = .init(&[_]u8{0b01});
    try testing.expectEqual(@as(u16, 8), try tree3.decode(bits.BitReader, &b1));
    var b2: bits.BitReader = .init(&[_]u8{0b11});
    try testing.expectEqual(@as(u16, 9), try tree3.decode(bits.BitReader, &b2));

    // NSYM = 4 with tree-select 1: lengths 1, 2, 3, 3.
    var four: golden.Packer = .{};
    four.pack(1, 2);
    four.pack(3, 2);
    for ([_]u16{ 1, 2, 3, 4 }) |symbol| four.pack(symbol, 8);
    four.pack(1, 1); // tree-select
    var br4: bits.BitReader = .init(four.slice());
    var tree4: LiteralTree = undefined;
    try readTree(LiteralTree, bits.BitReader, &br4, &tree4, 256);
    try testing.expectEqual(@as(u64, four.bit_len), br4.bit_pos);

    // NSYM = 4 with tree-select 0: all four lengths are 2.
    var flat: golden.Packer = .{};
    flat.pack(1, 2);
    flat.pack(3, 2);
    for ([_]u16{ 1, 2, 3, 4 }) |symbol| flat.pack(symbol, 8);
    flat.pack(0, 1);
    var br5: bits.BitReader = .init(flat.slice());
    var tree5: LiteralTree = undefined;
    try readTree(LiteralTree, bits.BitReader, &br5, &tree5, 256);
    try testing.expectEqual(@as(u64, flat.bit_len), br5.bit_pos);
}

test "simple form: NSYM = 1 decodes with no bits, and §3.4's two rejections" {
    // NSYM = 1: the single symbol has the zero-length code.
    var one: golden.Packer = .{};
    one.pack(1, 2);
    one.pack(0, 2);
    one.pack(65, 8);
    var br: bits.BitReader = .init(one.slice());
    var tree: LiteralTree = undefined;
    try readTree(LiteralTree, bits.BitReader, &br, &tree, 256);
    try testing.expectEqual(@as(u64, one.bit_len), br.bit_pos);
    var empty: bits.BitReader = .init(&[_]u8{});
    try testing.expectEqual(@as(u16, 65), try tree.decode(bits.BitReader, &empty));

    // RFC 7932 §3.4: "If the integer value is greater than or equal to the
    // alphabet size ... rejected as invalid." Reachable only on a
    // non-power-of-two alphabet (T7): the 704-symbol command alphabet.
    var wide: golden.Packer = .{};
    wide.pack(1, 2);
    wide.pack(0, 2);
    wide.pack(704, 10);
    var br_wide: bits.BitReader = .init(wide.slice());
    var command: CommandTree = undefined;
    try testing.expectError(
        error.SimpleHuffmanAlphabet,
        readTree(CommandTree, bits.BitReader, &br_wide, &command, 704),
    );

    // RFC 7932 §3.4: "or the value is identical to a previous value".
    var dup: golden.Packer = .{};
    dup.pack(1, 2);
    dup.pack(1, 2);
    dup.pack(65, 8);
    dup.pack(65, 8);
    var br_dup: bits.BitReader = .init(dup.slice());
    var tree_dup: LiteralTree = undefined;
    try testing.expectError(
        error.SimpleHuffmanSame,
        readTree(LiteralTree, bits.BitReader, &br_dup, &tree_dup, 256),
    );
}

test "complex form: RFC 7932 §3.5's 17 modifier and the length sequence" {
    // The code-length code carries symbols {0, 1, 17} with lengths 2, 1, 2
    // (8 + 16 + 8 = 32, so it is complete). The sequence is two 17s in a row:
    // the first repeats zero 10 times (extra bits 7), the second modifies the
    // count — "repeat count = (8 * (repeat count - 2)) + (3..10 on the next 3
    // bits)" — to 8 * (10 - 2) + 0 + 3 = 67 zeros. Then two length-1 symbols
    // complete the Kraft sum (2 * 16384 = 32768) at symbols 67 and 68.
    var packer: golden.Packer = .{};
    packer.pack(0, 2); // HSKIP = 0
    // §3.5's order: 1, 2, 3, 4, 0, 5, 17, ...
    packClLength(&packer, 1); // symbol 1: length 1
    packClLength(&packer, 0); // symbol 2: 0
    packClLength(&packer, 0); // symbol 3: 0
    packClLength(&packer, 0); // symbol 4: 0
    packClLength(&packer, 2); // symbol 0: length 2
    packClLength(&packer, 0); // symbol 5: 0
    packClLength(&packer, 2); // symbol 17: length 2 (space = 0 here)
    // The code-length code: symbol 1 -> code 0 (1 bit), symbol 0 -> 10,
    // symbol 17 -> 11.
    packer.code(0b11, 2);
    packer.pack(7, 3); // 17: repeat zero 10 times
    packer.code(0b11, 2);
    packer.pack(0, 3); // 17: repeat count becomes 67
    packer.code(0, 1); // a length-1 code for symbol 67
    packer.code(0, 1); // and for symbol 68: space is 0, the loop ends
    var br: bits.BitReader = .init(packer.slice());
    var tree: LiteralTree = undefined;
    try readTree(LiteralTree, bits.BitReader, &br, &tree, 256);
    try testing.expectEqual(@as(u64, packer.bit_len), br.bit_pos);

    // The canonical assignment gives 67 the length-1 code 0 and 68 code 1.
    var zero: bits.BitReader = .init(&[_]u8{0x00});
    try testing.expectEqual(@as(u16, 67), try tree.decode(bits.BitReader, &zero));
    var one: bits.BitReader = .init(&[_]u8{0x01});
    try testing.expectEqual(@as(u16, 68), try tree.decode(bits.BitReader, &one));
}

/// Append the code for `value`, the RFC's canonical numeral, in transmission
/// order (`§3.2`: the most significant bit goes first).
fn packCode(p: *golden.Packer, value: u16, len: u5) void {
    p.pack(wireBits(value, len), len);
}

/// The fixed §3.5 code for a code-length-code length: the value's bits are
/// the code in transmission order, and its length is the code's.
fn packClLength(p: *golden.Packer, len: u4) void {
    const wire: u16 = switch (len) {
        0 => 0b00,
        1 => 0b0111,
        2 => 0b011,
        3 => 0b10,
        4 => 0b01,
        5 => 0b1111,
        else => unreachable,
    };
    const bit_len: u5 = switch (len) {
        0, 3, 4 => 2,
        2 => 3,
        1, 5 => 4,
        else => unreachable,
    };
    p.pack(wire, bit_len);
}

test "complex form: the Kraft checks and the repeat overrun are named errors" {
    // A code-length code whose non-zero lengths do not sum to 32: symbol 1
    // gets length 1 (16) and symbol 0 length 1 (16), then the sequence ends
    // with space 0 — that is complete. Drop to a single length-2 symbol to
    // leave the code incomplete: 32 - 8 = 24 != 0, and only one non-zero
    // length is accepted, so use two.
    var bad_cl: golden.Packer = .{};
    bad_cl.pack(0, 2); // HSKIP = 0
    packClLength(&bad_cl, 2); // symbol 1: length 2 (8 of 32)
    packClLength(&bad_cl, 0); // symbol 2: 0
    packClLength(&bad_cl, 0); // symbol 3: 0
    packClLength(&bad_cl, 0); // symbol 4: 0
    packClLength(&bad_cl, 2); // symbol 0: length 2 (8)
    for (0..13) |_| packClLength(&bad_cl, 0); // the rest zero
    var br: bits.BitReader = .init(bad_cl.slice());
    var tree: LiteralTree = undefined;
    try testing.expectError(
        error.BadCodeLengthCode,
        readTree(LiteralTree, bits.BitReader, &br, &tree, 256),
    );

    // The main code's Kraft sum: a code-length code over {1, 16} with lengths
    // 1, 1 (16 is the "repeat the previous non-zero length" code), then one
    // length-1 symbol followed by a 16 repeating it six times. Six length-1
    // codes would overshoot 32768, and the repeat's target is the previous
    // length, so the sequence must be rejected as the Kraft sum is missed.
    var over: golden.Packer = .{};
    over.pack(0, 2); // HSKIP = 0
    packClLength(&over, 1); // symbol 1: length 1
    // The code-length symbols 2, 3, 4, 0, 5, 17 and 6 stay zero; symbol 16
    // completes the code-length code's Kraft sum.
    for (0..7) |_| packClLength(&over, 0);
    packClLength(&over, 1); // symbol 16: length 1
    // The code-length code: symbol 1 -> code 0 (1 bit), symbol 16 -> code 1.
    over.code(0, 1); // a length-1 code for symbol 0
    over.code(1, 1); // 16: repeat 3..6 times
    over.pack(3, 2); // six times: lengths 1 for symbols 1..6
    var br_over: bits.BitReader = .init(over.slice());
    var tree_over: LiteralTree = undefined;
    try testing.expectError(
        error.BadHuffmanCode,
        readTree(LiteralTree, bits.BitReader, &br_over, &tree_over, 256),
    );
}

test "complex form: the single-symbol code-length code consumes no bits" {
    // §3.5: "If the lengths have been read for the entire code length
    // alphabet and there was only one non-zero code length, then the prefix
    // code has one symbol whose code has zero length." Here the code-length
    // code is symbol 1 (length 1 written, then 17 zeros), and the main
    // sequence is two length-1 symbols read with no bits at all.
    var packer: golden.Packer = .{};
    packer.pack(0, 2); // HSKIP = 0
    packClLength(&packer, 1); // symbol 1: length 1
    for (0..17) |_| packClLength(&packer, 0);
    var br: bits.BitReader = .init(packer.slice());
    var tree: LiteralTree = undefined;
    try readTree(LiteralTree, bits.BitReader, &br, &tree, 256);
    try testing.expectEqual(@as(u64, packer.bit_len), br.bit_pos);
    // The sequence consumed no bits, but the code it describes is a normal
    // two-symbol tree: decoding it takes one bit.
    var zero: bits.BitReader = .init(&[_]u8{0x00});
    try testing.expectEqual(@as(u16, 0), try tree.decode(bits.BitReader, &zero));
}

test "tree region: OQ8's cap and its byte figure" {
    // The cap is a compile-time constant, and the region it sizes is what the
    // README's Stack bullet states. A change to either must move both.
    try testing.expectEqual(@as(usize, 64), max_trees);
    try testing.expectEqual(@as(usize, 689_512), @sizeOf(Trees));
}
