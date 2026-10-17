//! RFC 1951 §3.2.7 — the dynamic-Huffman block machinery: the token list the
//! match finder fills, the length-limited Huffman tree construction, the
//! code-length codegen, and the per-block stored/fixed/dynamic dispatch. The
//! shape follows klauspost/compress's `huffman_bit_writer.go` and
//! `huffman_code.go`, so the level-6 encoder's blocks are byte-identical to
//! theirs (attribution in THIRD_PARTY.md).
//!
//! This module is the level-6 half of the encoder: level 1 emits fixed blocks
//! from encode.zig and never touches it. The finder stays in encode.zig; this
//! file consumes the tokens it produces.
//!
//! Format: docs/research/specs/rfc1951-deflate.txt

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const sort = std.mem.sort;

const fastmem = @import("fastmem");

const decode = @import("decode.zig");
const encode = @import("encode.zig");

const BitWriter = encode.BitWriter;
const Code = encode.Code;
const fixed_distance_codes = encode.fixed_distance_codes;
const fixed_literal_codes = encode.fixed_literal_codes;
const wireBits = encode.wireBits;

/// §3.2.7 — the literal/length alphabet the dynamic tree covers: 0-255
/// literals, 256 end-of-block, 257-285 the length codes (286-287 exist only
/// in the fixed table).
const literal_count = 286;

/// §3.2.7 — the distance alphabet: 0-29.
const offset_code_count = 30;

/// §3.2.7 — the code-length alphabet: 0-18.
const codegen_code_count = 19;

/// The codegen's end marker: no code length is 255.
const bad_code = 255;

/// §3.2.7 — every code length is at most 15 bits, so the construction's
/// level table needs 16 rows (0 is unused).
const max_bits_limit = 16;

/// The fixed-size comparison runs only below this many tokens; above it a
/// dynamic tree is assumed to win (klauspost's `maxPredefinedTokens`).
const max_predefined_tokens = 250;

/// The new-table penalty's scale, log2: klauspost's `logNewTablePenalty` for
/// levels 1-6, added as `estimate >> 7` so a still-good table is reused.
const log_new_table_penalty = 7;

/// §3.2.7 — the order the code-length code lengths are transmitted in.
const codegen_order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

/// One output token, packed like klauspost's `token`: bits 0-15 hold the
/// literal byte or a match's offset-1, bits 16-21 the offset code, bits 22-29
/// the length-3, bits 30-31 the type (0 literal, 1 match). The end-of-block
/// marker is the value 256, which no literal can take.
pub const Token = u32;

/// The bit offset of a match token's length-3 field.
const length_shift = 22;
/// A match token's type bit.
const match_type: u32 = 1 << 30;
/// The end-of-block token (`§3.2.7`): symbol 256.
const end_block_marker: Token = 256;

/// One block's token buffer: the tokens the finder produced and the three
/// histograms the tree builder reads (klauspost's `tokens`). `tokens` holds
/// one token per input byte plus the deferred end-of-block token a `finish`
/// adds.
pub const TokenList = struct {
    /// §3.2.5 — length codes 257-285 at 1-29; index 0 is the end-of-block
    /// symbol's slot (the literal tree's symbol 256).
    extra_hist: [32]u16 = @splat(0),
    /// §3.2.5 — distance codes 0-29.
    off_hist: [32]u16 = @splat(0),
    /// Literal bytes 0-255.
    lit_hist: [256]u16 = @splat(0),
    /// Tokens in `tokens`.
    n: u32 = 0,
    /// The block's tokens, in emission order.
    tokens: [encode.max_block_size + 1]Token = undefined,

    /// Empty the list for the next block: the token count and the three
    /// histograms (the token array is overwritten as it is filled).
    pub fn reset(self: *TokenList) void {
        if (self.n == 0) return;
        self.n = 0;
        fastmem.set(u16, &self.lit_hist, 0);
        fastmem.set(u16, &self.extra_hist, 0);
        fastmem.set(u16, &self.off_hist, 0);
    }

    /// Append one literal byte (`§3.2.7`'s literal symbols 0-255).
    pub fn addLiteral(self: *TokenList, byte: u8) void {
        assert(self.n < self.tokens.len);
        self.tokens[self.n] = byte;
        self.lit_hist[byte] += 1;
        self.n += 1;
    }

    /// Append `bytes` as literal tokens.
    pub fn addLiterals(self: *TokenList, bytes: []const u8) void {
        assert(self.n + bytes.len <= self.tokens.len);
        for (bytes) |byte| {
            self.tokens[self.n] = byte;
            self.lit_hist[byte] += 1;
            self.n += 1;
        }
    }

    /// Append the end-of-block token (`§3.2.7` symbol 256).
    pub fn addEob(self: *TokenList) void {
        assert(self.n < self.tokens.len);
        self.tokens[self.n] = end_block_marker;
        self.extra_hist[0] += 1;
        self.n += 1;
    }

    /// Append a match of `length` bytes at `distance` (1-32768), splitting
    /// lengths above 258 the way klauspost's `AddMatchLong` does: a chunk is
    /// 258 unless that would leave a 1- or 2-byte tail, which cannot be
    /// coded, in which case the chunk drops to 255.
    pub fn addMatchLong(self: *TokenList, length: usize, distance: usize) void {
        assert(distance >= 1);
        assert(distance <= encode.history_len);
        const ds = encode.distanceSymbol(distance);
        const xoffset: u32 = @as(u32, @intCast(distance - 1)) | (@as(u32, ds.symbol) << 16);
        var remaining = length;
        while (remaining > 0) {
            var chunk = remaining;
            if (chunk > encode.max_match_len) {
                chunk = if (chunk > encode.max_match_len + 3)
                    encode.max_match_len
                else
                    encode.max_match_len - 3;
            }
            remaining -= chunk;
            const ls = encode.lengthSymbol(chunk);
            self.extra_hist[ls.symbol - 257 + 1] += 1;
            self.off_hist[ds.symbol] += 1;
            assert(self.n < self.tokens.len);
            self.tokens[self.n] = match_type |
                (@as(u32, @intCast(chunk - 3)) << length_shift) | xoffset;
            self.n += 1;
        }
    }

    /// klauspost's `EstimatedBits`: the block's cost under an optimal code,
    /// in bits, with the length and distance extra bits added. Used only for
    /// the table-reuse decision.
    fn estimatedBits(self: *const TokenList) i32 {
        var shannon: f32 = 0;
        var bits: i32 = 0;
        var n_matches: usize = 0;
        const total: usize = self.n;
        if (total > 0) {
            const inv_total: f32 = 1.0 / @as(f32, @floatFromInt(total));
            for (self.lit_hist) |v| {
                if (v > 0) {
                    const n: f32 = @floatFromInt(v);
                    shannon += atLeastOne(-mFastLog2(n * inv_total)) * n;
                }
            }
            shannon += 15;
            for (self.extra_hist[1 .. literal_count - 256], 0..) |v, i| {
                if (v > 0) {
                    const n: f32 = @floatFromInt(v);
                    shannon += atLeastOne(-mFastLog2(n * inv_total)) * n;
                    bits += @as(i32, decode.length_extra[i]) * v;
                    n_matches += v;
                }
            }
        }
        if (n_matches > 0) {
            const inv_total: f32 = 1.0 / @as(f32, @floatFromInt(n_matches));
            for (self.off_hist[0..offset_code_count], 0..) |v, i| {
                if (v > 0) {
                    const n: f32 = @floatFromInt(v);
                    shannon += atLeastOne(-mFastLog2(n * inv_total)) * n;
                    bits += @as(i32, decode.distance_extra[i]) * v;
                }
            }
        }
        return @as(i32, @intFromFloat(shannon)) + bits;
    }
};

/// klauspost's `atLeastOne`: clamp to 1-15 so a zero-probability symbol
/// still costs something.
fn atLeastOne(v: f32) f32 {
    if (v < 1) return 1;
    if (v > 15) return 15;
    return v;
}

/// klauspost's `mFastLog2`: a cheap float32 log2 of a probability. Ported
/// bit-for-bit (the reuse decision's size estimate is part of the emitted
/// bytes), exponent-field hack and polynomial included.
fn mFastLog2(val: f32) f32 {
    var ux: i32 = @bitCast(@as(u32, @bitCast(val)));
    var log2: f32 = @floatFromInt(((ux >> 23) & 255) - 128);
    ux &= -0x7f800001;
    ux += 127 << 23;
    const uval: f32 = @bitCast(@as(u32, @bitCast(ux)));
    log2 += ((-0.34484843) * uval + 2.02466578) * uval - 0.67487759;
    return log2;
}

/// One symbol and its frequency, the tree builder's input.
const LiteralNode = struct { literal: u16, freq: u16 };

/// The sentinel `bitCounts` appends: a literal no symbol can have, so the
/// leaf scan stops.
fn maxNode() LiteralNode {
    return .{ .literal = math.maxInt(u16), .freq = math.maxInt(u16) };
}

/// The per-level state of the length-limited construction.
const LevelInfo = struct {
    /// The level this row describes (1-based).
    level: i32,
    /// The frequency of the last node placed at this level.
    last_freq: i32,
    /// The frequency of the next character (leaf) to place here.
    next_char_freq: i32,
    /// The frequency of the next pair from the level below.
    next_pair_freq: i32,
    /// How many more items this level still owes before the level above can
    /// pair its two children.
    needed: i32,
};

/// A canonical Huffman code table for one alphabet: the wire bits and length
/// per symbol (§3.2.2's construction, §3.1.1's transmission order). Built by
/// `generate` from a frequency histogram.
pub fn HuffmanEncoder(comptime alphabet_len: usize) type {
    return struct {
        const Self = @This();

        /// One code per symbol; length 0 means "not assigned".
        codes: [alphabet_len]Code = @splat(.{ .bits = 0, .len = 0 }),
        /// Scratch for `bitCounts`: `bit_count[n]` is the number of codes
        /// that are `n` bits long.
        bit_count: [max_bits_limit + 1]i32 = @splat(0),
        /// Scratch for `generate`: the non-zero-frequency symbols, sorted.
        freq_cache: [literal_count + 1]LiteralNode = undefined,

        /// §3.2.2/§3.2.7 — build the length-limited tree for `freq` and
        /// assign the canonical codes. `max_bits` caps every length (15 for
        /// the literal/length and distance trees, 7 for the code-length
        /// tree); `freq` is shorter than the alphabet for the literals-only
        /// tree. Every symbol with a non-zero frequency gets a code.
        fn generate(self: *Self, freq: []const u16, max_bits: i32) void {
            assert(max_bits > 0);
            assert(max_bits < max_bits_limit);
            assert(freq.len <= alphabet_len);
            var list = self.freq_cache[0 .. freq.len + 1];
            var count: usize = 0;
            for (freq, 0..) |f, i| {
                if (f != 0) {
                    list[count] = .{ .literal = @intCast(i), .freq = f };
                    count += 1;
                } else {
                    self.codes[i] = .{ .bits = 0, .len = 0 };
                }
            }
            list = list[0..count];
            if (count <= 2) {
                // §3.2.7 — "If only one distance code is used, it is encoded
                // using one bit, not zero bits": one or two symbols take
                // one-bit codes, in literal order.
                for (list, 0..) |node, i| {
                    self.codes[node.literal] = .{ .bits = @intCast(i), .len = 1 };
                }
                return;
            }
            sortByFreq(list);
            const counts = self.bitCounts(list, max_bits);
            self.assignEncodingAndSize(counts, list);
        }

        /// The bit cost of `freq` under the current codes: the sum over
        /// symbols with a non-zero frequency.
        fn bitLength(self: *const Self, freq: []const u16) i32 {
            assert(freq.len <= alphabet_len);
            var total: i32 = 0;
            for (freq, 0..) |f, i| {
                if (f != 0) total += @as(i32, f) * self.codes[i].len;
            }
            return total;
        }

        /// The bit cost of `freq` under the current codes, or
        /// `math.maxInt(i32)` when a symbol with a non-zero frequency has no
        /// code — the table cannot encode this block.
        fn canReuseBits(self: *const Self, freq: []const u16) i32 {
            assert(freq.len <= alphabet_len);
            var total: i32 = 0;
            for (freq, 0..) |f, i| {
                if (f != 0) {
                    const code = self.codes[i];
                    if (code.len == 0) return math.maxInt(i32);
                    total += @as(i32, f) * code.len;
                }
            }
            return total;
        }

        /// §3.2.7's length-limited construction (klauspost's `bitCounts`,
        /// which is Go's `compress/flate`): the level-by-level leaf-count
        /// build that enforces the depth cap while building. Returns
        /// `bit_count[1..max_bits]`: how many symbols take each length.
        /// `list` is sorted by frequency; the caller's `freq_cache` holds
        /// room for the sentinel this appends.
        fn bitCounts(self: *Self, list: []LiteralNode, max_bits_in: i32) []const i32 {
            assert(max_bits_in < max_bits_limit);
            assert(list.len >= 3);
            const n: i32 = @intCast(list.len);
            self.freq_cache[list.len] = maxNode();
            const nodes = self.freq_cache[0 .. list.len + 1];
            var max_bits: usize = @intCast(max_bits_in);
            if (max_bits_in > n - 1) max_bits = @intCast(n - 1);

            // A bogus level 0 exists only so level 1's `next_pair_freq` has a
            // legitimate never-chosen value.
            var levels: [max_bits_limit]LevelInfo = @splat(.{
                .level = 0,
                .last_freq = 0,
                .next_char_freq = 0,
                .next_pair_freq = 0,
                .needed = 0,
            });
            var leaf_counts: [max_bits_limit][max_bits_limit]i32 = @splat(@splat(0));
            const l2f: i32 = nodes[2].freq;
            const l1f: i32 = nodes[1].freq;
            const l0f: i32 = @as(i32, nodes[0].freq) + @as(i32, nodes[1].freq);
            var level: usize = 1;
            while (level <= max_bits) : (level += 1) {
                levels[level] = .{
                    .level = @intCast(level),
                    .last_freq = l1f,
                    .next_char_freq = l2f,
                    .next_pair_freq = l0f,
                    .needed = 0,
                };
                leaf_counts[level][level] = 2;
                if (level == 1) levels[level].next_pair_freq = math.maxInt(i32);
            }
            // A total of 2n-2 items reach the top level; 2 are seeded above.
            levels[max_bits].needed = 2 * n - 4;

            level = max_bits;
            while (level < max_bits_limit) {
                const l = &levels[level];
                if (l.next_pair_freq == math.maxInt(i32) and
                    l.next_char_freq == math.maxInt(i32))
                {
                    // Both leaves and pairs ran out: end this level and make
                    // sure the walk never comes back to it.
                    l.needed = 0;
                    assert(level + 1 < levels.len);
                    levels[level + 1].next_pair_freq = math.maxInt(i32);
                    level += 1;
                    continue;
                }
                const prev_freq = l.last_freq;
                if (l.next_char_freq < l.next_pair_freq) {
                    // The next item is a leaf.
                    const count = leaf_counts[level][level] + 1;
                    l.last_freq = l.next_char_freq;
                    // Lower leaf counts are the previous node's.
                    leaf_counts[level][level] = count;
                    const e = nodes[@intCast(count)];
                    if (e.literal < math.maxInt(u16)) {
                        l.next_char_freq = e.freq;
                    } else {
                        l.next_char_freq = math.maxInt(i32);
                    }
                } else {
                    // The next item is a pair from the level below.
                    l.last_freq = l.next_pair_freq;
                    const save = leaf_counts[level][level];
                    leaf_counts[level] = leaf_counts[level - 1];
                    leaf_counts[level][level] = save;
                    levels[@intCast(l.level - 1)].needed = 2;
                }
                l.needed -= 1;
                if (l.needed == 0) {
                    if (l.level == @as(i32, @intCast(max_bits))) break;
                    levels[@intCast(l.level + 1)].next_pair_freq = prev_freq + l.last_freq;
                    level += 1;
                } else {
                    // If a lower level was robbed, walk down to replenish it.
                    // The guard mirrors the reference's non-underflow
                    // invariant; a zero here would be a construction bug.
                    while (level > 0 and levels[level - 1].needed > 0) level -= 1;
                }
            }
            assert(leaf_counts[max_bits][max_bits] == n);

            var bits: usize = 1;
            const counts = &leaf_counts[max_bits];
            var row = max_bits;
            while (row > 0) : (row -= 1) {
                self.bit_count[bits] = counts[row] - counts[row - 1];
                bits += 1;
            }
            return self.bit_count[0 .. max_bits + 1];
        }

        /// §3.2.2 — assign the canonical codes: within each length, symbols
        /// in literal order, numbered consecutively; the wire form is the
        /// numeral's MSB-first bits (`wireBits`).
        fn assignEncodingAndSize(
            self: *Self,
            bit_count: []const i32,
            list_in: []LiteralNode,
        ) void {
            var code: u16 = 0;
            var list = list_in;
            for (bit_count, 0..) |bits, n| {
                code <<= 1;
                if (n == 0 or bits == 0) continue;
                const count: usize = @intCast(bits);
                const chunk = list[list.len - count ..];
                sortByLiteral(chunk);
                for (chunk) |node| {
                    self.codes[node.literal] = .{
                        .bits = wireBits(code, @intCast(n)),
                        .len = @intCast(n),
                    };
                    code += 1;
                }
                list = list[0 .. list.len - count];
            }
        }
    };
}

/// The code-length tree of a literals-only block's distance section: a
/// single symbol, code 0 in one bit (§3.2.7's one-code rule).
const huff_offset: HuffmanEncoder(offset_code_count) = blk: {
    var e: HuffmanEncoder(offset_code_count) = .{};
    e.codes[0] = .{ .bits = 0, .len = 1 };
    break :blk e;
};

/// klauspost's `sortByFreq`: ascending frequency, then literal. The
/// comparator is a strict total order (literals are unique in the list), so
/// the sorted list is unique and any correct sort produces it; the
/// reference's quicksort is not ported.
fn sortByFreq(list: []LiteralNode) void {
    sort(LiteralNode, list, {}, lessByFreq);
}

fn lessByFreq(_: void, a: LiteralNode, b: LiteralNode) bool {
    if (a.freq != b.freq) return a.freq < b.freq;
    return a.literal < b.literal;
}

/// klauspost's `sortByLiteral`: ascending literal, the order the canonical
/// codes are assigned in. Unique keys again, so the result is unique.
fn sortByLiteral(list: []LiteralNode) void {
    sort(LiteralNode, list, {}, lessByLiteral);
}

fn lessByLiteral(_: void, a: LiteralNode, b: LiteralNode) bool {
    return a.literal < b.literal;
}

/// The two alphabet sizes a dynamic header transmits (§3.2.7's HLIT and
/// HDIST).
const Counts = struct { num_literals: usize, num_offsets: usize };

/// The dynamic header's size in bits and its code-length code count.
const HeaderSize = struct { size: i32, num_codegens: usize };

/// The dynamic form's size in bits and its code-length code count.
const DynamicSize = struct { size: i32, num_codegens: usize };

/// The per-stream dynamic-block emitter state (klauspost's
/// `huffmanBitWriter`): the encodings that persist across blocks, the
/// codegen scratch, and the reuse bookkeeping. One instance per stream; the
/// token list is per block.
pub const BlockWriter = struct {
    /// Bits written for the last dynamic header, or 0 when the next block
    /// must write its own table. Non-zero also means an end-of-block code is
    /// owed (the block's bits end without one; the next header or the stream
    /// ending flushes it).
    last_header: i32 = 0,
    /// The last block was literals-only: the distance table does not cover
    /// the symbols a match block needs, so it can never be reused.
    last_huff_man: bool = false,
    /// The literal/length encoding of the last dynamic block.
    literal_encoding: HuffmanEncoder(literal_count) = .{},
    /// `writeBlockHuff`'s scratch tree: the literals-only candidate.
    tmp_literal_encoding: HuffmanEncoder(literal_count) = .{},
    /// The distance encoding of the last dynamic block.
    offset_encoding: HuffmanEncoder(offset_code_count) = .{},
    /// The code-length encoding of the last dynamic header.
    codegen_encoding: HuffmanEncoder(codegen_code_count) = .{},
    /// The §3.2.7 histograms of the block being written.
    literal_freq: [257 + 32]u16 = @splat(0),
    offset_freq: [32]u16 = @splat(0),
    codegen_freq: [codegen_code_count]u16 = @splat(0),
    /// The run-length-encoded code lengths, `bad_code` terminated.
    codegen: [literal_count + offset_code_count + 1]u8 = @splat(0),

    /// Write the owed end-of-block code from the current literal table, if
    /// one is open (`last_header > 0`).
    pub fn flushEob(self: *BlockWriter, bw: *BitWriter) error{BufferTooSmall}!void {
        if (self.last_header > 0) {
            try bw.writeCode(self.literal_encoding.codes[256]);
            self.last_header = 0;
        }
    }

    /// §3.2.4 — write `input` as a stored block (after any owed end-of-block
    /// code). The caller has already chosen the stored form.
    pub fn writeStored(
        self: *BlockWriter,
        bw: *BitWriter,
        input: []const u8,
    ) error{BufferTooSmall}!void {
        try self.flushEob(bw);
        try encode.emitStoredBlock(bw, input);
    }

    /// klauspost's `storeFast` dispatch for one block: stored when the
    /// finder found nothing, the literals-only form when matches removed
    /// less than 1/16th of the input, else the dynamic form with its
    /// fixed/stored fallbacks.
    pub fn writeBlockFast(
        self: *BlockWriter,
        bw: *BitWriter,
        tokens: *TokenList,
        input: []const u8,
        sync: bool,
    ) error{BufferTooSmall}!void {
        if (tokens.n == 0) return self.writeStored(bw, input);
        if (tokens.n > input.len - (input.len >> 4)) {
            return self.writeBlockHuff(bw, input, sync);
        }
        return self.writeBlockDynamic(bw, tokens, input, sync);
    }

    /// klauspost's `writeBlockDynamic`: encode the block with a dynamic
    /// table, reusing the previous block's table when the estimate says it
    /// is cheaper, and falling back to a fixed or stored block when either
    /// is smaller. `sync` marks the stream's final block (the end-of-block
    /// code is written inline; otherwise it is deferred).
    pub fn writeBlockDynamic(
        self: *BlockWriter,
        bw: *BitWriter,
        tokens: *TokenList,
        input: []const u8,
        sync: bool,
    ) error{BufferTooSmall}!void {
        if (sync) tokens.addEob();

        // A literals-only table cannot take matches, and a final block must
        // not leave an EOB owed.
        if (self.last_huff_man and self.last_header > 0) {
            try bw.writeCode(self.literal_encoding.codes[256]);
            self.last_header = 0;
            self.last_huff_man = false;
        }
        if (self.last_header > 0 and !self.canReuse(tokens)) {
            try bw.writeCode(self.literal_encoding.codes[256]);
            self.last_header = 0;
        }

        const counts = self.indexTokens(tokens, !sync);
        // The stored form always exists for a full-size block, so the extra
        // bits are always part of the size arithmetic.
        const extra_bits = self.extraBitSize();
        const ssize: i32 = @intCast((input.len + 5) * 8);

        var size: i32 = undefined;
        if (self.last_header > 0) {
            // Estimate a new table against reusing the old one. The estimate
            // is an optimal table's, so it gets the penalty added back.
            var new_size: i32 = self.last_header + tokens.estimatedBits();
            new_size += self.literal_encoding.codes[256].len;
            new_size += new_size >> log_new_table_penalty;
            const reuse_size = self.dynamicReuseSize() + extra_bits;
            if (new_size < reuse_size) {
                try bw.writeCode(self.literal_encoding.codes[256]);
                size = new_size;
                self.last_header = 0;
            } else {
                size = reuse_size;
            }
            if (tokens.n < max_predefined_tokens) {
                const pre_size = self.fixedSize(extra_bits) + 7;
                if (pre_size < size) {
                    return self.writeFixedOrStored(bw, tokens, input, ssize, size, sync);
                }
            }
            if (ssize <= size) return self.writeStored(bw, input);
        }

        if (self.last_header == 0) {
            self.literal_freq[256] = 1;
            self.generate();
            self.generateCodegen(
                counts.num_literals,
                counts.num_offsets,
                &self.literal_encoding,
                &self.offset_encoding,
            );
            self.codegen_encoding.generate(&self.codegen_freq, 7);
            const dynamic = self.dynamicSize(extra_bits);
            size = dynamic.size;
            if (tokens.n < max_predefined_tokens) {
                const pre_size = self.fixedSize(extra_bits);
                if (pre_size <= size) {
                    return self.writeFixedOrStored(bw, tokens, input, ssize, pre_size, sync);
                }
            }
            if (ssize <= size) return self.writeStored(bw, input);
            try self.writeDynamicHeader(
                bw,
                counts.num_literals,
                counts.num_offsets,
                dynamic.num_codegens,
                false,
            );
            if (!sync) self.last_header = self.headerSize().size;
            self.last_huff_man = false;
        }

        if (sync) self.last_header = 0;
        try writeTokens(
            bw,
            tokens.tokens[0..tokens.n],
            &self.literal_encoding.codes,
            &self.offset_encoding.codes,
        );
    }

    /// The fixed rung of the dynamic dispatch: a fixed block when it fits
    /// the stored form, else stored. Both callers compare against the size
    /// already chosen (klauspost's two `ssize <= ...` gates).
    fn writeFixedOrStored(
        self: *BlockWriter,
        bw: *BitWriter,
        tokens: *TokenList,
        input: []const u8,
        ssize: i32,
        size: i32,
        sync: bool,
    ) error{BufferTooSmall}!void {
        if (ssize <= size) return self.writeStored(bw, input);
        try self.flushEob(bw);
        try bw.writeBits(2, 3); // BFINAL=0, BTYPE=01, fixed
        if (!sync) tokens.addEob();
        try writeTokens(
            bw,
            tokens.tokens[0..tokens.n],
            &fixed_literal_codes,
            &fixed_distance_codes,
        );
    }

    /// klauspost's `writeBlockHuff`: a block of literals only, with its own
    /// dynamic table, or stored when the literals do not beat the stored
    /// form. Used when the finder removed less than 1/16th of the block.
    pub fn writeBlockHuff(
        self: *BlockWriter,
        bw: *BitWriter,
        input: []const u8,
        sync: bool,
    ) error{BufferTooSmall}!void {
        fastmem.set(u16, &self.literal_freq, 0);
        if (!self.last_huff_man) fastmem.set(u16, &self.offset_freq, 0);

        const num_literals = 257;
        const num_offsets = 1;
        for (input) |byte| self.literal_freq[byte] += 1;
        const ssize: i32 = @intCast((input.len + 5) * 8);
        if (input.len > 1024) {
            // A quick incompressible-content check: the histogram's squared
            // distance from uniform, capped at twice the input.
            var abs: f64 = 0;
            const avg: f64 = @as(f64, @floatFromInt(input.len)) / 256;
            const max: f64 = @floatFromInt(input.len * 2);
            for (self.literal_freq[0..256]) |v| {
                const diff = @as(f64, @floatFromInt(v)) - avg;
                abs += diff * diff;
                if (abs > max) break;
            }
            if (abs < max) return self.writeStored(bw, input);
        }
        self.literal_freq[256] = 1;
        self.tmp_literal_encoding.generate(self.literal_freq[0..num_literals], 15);
        var est_bits = self.tmp_literal_encoding.canReuseBits(self.literal_freq[0..num_literals]);
        if (est_bits < math.maxInt(i32)) {
            est_bits += self.last_header;
            if (self.last_header == 0) est_bits += 70 * 8;
            est_bits += est_bits >> log_new_table_penalty;
        }
        if (ssize <= est_bits) return self.writeStored(bw, input);
        if (self.last_header > 0) {
            const reuse_size = self.literal_encoding.canReuseBits(self.literal_freq[0..256]);
            if (est_bits < reuse_size) {
                try bw.writeCode(self.literal_encoding.codes[256]);
                self.last_header = 0;
            }
        }
        if (self.last_header == 0) {
            const swap = self.literal_encoding;
            self.literal_encoding = self.tmp_literal_encoding;
            self.tmp_literal_encoding = swap;
            self.generateCodegen(num_literals, num_offsets, &self.literal_encoding, &huff_offset);
            self.codegen_encoding.generate(&self.codegen_freq, 7);
            const num_codegens = self.codegens();
            try self.writeDynamicHeader(bw, num_literals, num_offsets, num_codegens, false);
            self.last_huff_man = true;
            self.last_header = self.headerSize().size;
        }
        for (input) |byte| try bw.writeCode(self.literal_encoding.codes[byte]);
        if (sync) {
            try bw.writeCode(self.literal_encoding.codes[256]);
            self.last_header = 0;
            self.last_huff_man = false;
        }
    }

    /// §3.2.7 — copy the block's symbols into the histograms and return the
    /// transmitted alphabet sizes. `filled` is the mid-stream shortcut: the
    /// counts are not trimmed to the highest used symbol.
    fn indexTokens(self: *BlockWriter, tokens: *const TokenList, filled: bool) Counts {
        fastmem.copy(u16, self.literal_freq[0..256], &tokens.lit_hist);
        fastmem.copy(u16, self.literal_freq[256..288], &tokens.extra_hist);
        fastmem.copy(u16, &self.offset_freq, &tokens.off_hist);
        if (tokens.n == 0) return .{ .num_literals = 0, .num_offsets = 0 };
        if (filled) {
            return .{ .num_literals = literal_count, .num_offsets = offset_code_count };
        }
        var num_literals: usize = self.literal_freq.len;
        while (self.literal_freq[num_literals - 1] == 0) num_literals -= 1;
        var num_offsets: usize = self.offset_freq.len;
        while (num_offsets > 0 and self.offset_freq[num_offsets - 1] == 0) num_offsets -= 1;
        if (num_offsets == 0) {
            // §3.2.7 — the distance tree needs at least one code to describe.
            self.offset_freq[0] = 1;
            num_offsets = 1;
        }
        return .{ .num_literals = num_literals, .num_offsets = num_offsets };
    }

    /// Build both trees from the histograms: symbol 256 is already forced
    /// present by the caller.
    fn generate(self: *BlockWriter) void {
        self.literal_encoding.generate(self.literal_freq[0..literal_count], 15);
        self.offset_encoding.generate(self.offset_freq[0..offset_code_count], 15);
    }

    /// §3.2.7 — the run-length encoding of the two trees' code lengths,
    /// concatenated into one sequence: 16 (repeat previous 3-6), 17 (repeat
    /// zero 3-10), 18 (repeat zero 11-138), with their extra values.
    fn generateCodegen(
        self: *BlockWriter,
        num_literals: usize,
        num_offsets: usize,
        lit_enc: *const HuffmanEncoder(literal_count),
        off_enc: *const HuffmanEncoder(offset_code_count),
    ) void {
        fastmem.set(u16, &self.codegen_freq, 0);
        for (0..num_literals) |i| self.codegen[i] = lit_enc.codes[i].len;
        for (0..num_offsets) |i| {
            self.codegen[num_literals + i] = off_enc.codes[i].len;
        }
        self.codegen[num_literals + num_offsets] = bad_code;

        var size = self.codegen[0];
        var count: i32 = 1;
        var out_index: usize = 0;
        var in_index: usize = 1;
        while (size != bad_code) : (in_index += 1) {
            const next_size = self.codegen[in_index];
            if (next_size == size) {
                count += 1;
                continue;
            }
            if (size != 0) {
                self.codegen[out_index] = size;
                out_index += 1;
                self.codegen_freq[size] += 1;
                count -= 1;
                while (count >= 3) {
                    const n = @min(@as(i32, 6), count);
                    self.codegen[out_index] = 16;
                    out_index += 1;
                    self.codegen[out_index] = @intCast(n - 3);
                    out_index += 1;
                    self.codegen_freq[16] += 1;
                    count -= n;
                }
            } else {
                while (count >= 11) {
                    const n = @min(@as(i32, 138), count);
                    self.codegen[out_index] = 18;
                    out_index += 1;
                    self.codegen[out_index] = @intCast(n - 11);
                    out_index += 1;
                    self.codegen_freq[18] += 1;
                    count -= n;
                }
                if (count >= 3) {
                    self.codegen[out_index] = 17;
                    out_index += 1;
                    self.codegen[out_index] = @intCast(count - 3);
                    out_index += 1;
                    self.codegen_freq[17] += 1;
                    count = 0;
                }
            }
            count -= 1;
            while (count >= 0) : (count -= 1) {
                self.codegen[out_index] = size;
                out_index += 1;
                self.codegen_freq[size] += 1;
            }
            size = next_size;
            count = 1;
        }
        assert(out_index < self.codegen.len);
        self.codegen[out_index] = bad_code;
    }

    /// The number of code-length code lengths the header transmits (HCLEN).
    fn codegens(self: *const BlockWriter) usize {
        var num: usize = codegen_code_count;
        while (num > 4 and self.codegen_freq[codegen_order[num - 1]] == 0) num -= 1;
        return num;
    }

    /// The dynamic header's size in bits.
    fn headerSize(self: *const BlockWriter) HeaderSize {
        const num_codegens = self.codegens();
        const size: i32 = 3 + 5 + 5 + 4 + @as(i32, @intCast(3 * num_codegens)) +
            self.codegen_encoding.bitLength(&self.codegen_freq) +
            @as(i32, self.codegen_freq[16]) * 2 +
            @as(i32, self.codegen_freq[17]) * 3 +
            @as(i32, self.codegen_freq[18]) * 7;
        return .{ .size = size, .num_codegens = num_codegens };
    }

    /// The bit cost of the current tables over the new histograms.
    fn dynamicReuseSize(self: *const BlockWriter) i32 {
        return self.literal_encoding.bitLength(self.literal_freq[0..literal_count]) +
            self.offset_encoding.bitLength(self.offset_freq[0..offset_code_count]);
    }

    /// The dynamic form's size in bits: the header plus the two trees' cost
    /// plus the extra bits.
    fn dynamicSize(self: *const BlockWriter, extra_bits: i32) DynamicSize {
        const header = self.headerSize();
        return .{
            .size = header.size +
                self.literal_encoding.bitLength(self.literal_freq[0..literal_count]) +
                self.offset_encoding.bitLength(self.offset_freq[0..offset_code_count]) +
                extra_bits,
            .num_codegens = header.num_codegens,
        };
    }

    /// The bits the block spends on length and distance extra values.
    fn extraBitSize(self: *const BlockWriter) i32 {
        var total: i32 = 0;
        for (self.literal_freq[257..literal_count], 0..) |n, i| {
            total += @as(i32, n) * @as(i32, decode.length_extra[i]);
        }
        for (self.offset_freq[0..offset_code_count], 0..) |n, i| {
            total += @as(i32, n) * @as(i32, decode.distance_extra[i]);
        }
        return total;
    }

    /// The fixed form's size in bits: 3 header bits, the fixed codes over
    /// the histograms, and the extra bits.
    fn fixedSize(self: *const BlockWriter, extra_bits: i32) i32 {
        var total: i32 = 3 + extra_bits;
        for (self.literal_freq[0..literal_count], 0..) |f, i| {
            if (f != 0) total += @as(i32, f) * fixed_literal_codes[i].len;
        }
        for (self.offset_freq[0..offset_code_count], 0..) |f, i| {
            if (f != 0) total += @as(i32, f) * fixed_distance_codes[i].len;
        }
        return total;
    }

    /// Whether the current tables cover every symbol the block uses.
    fn canReuse(self: *const BlockWriter, tokens: *const TokenList) bool {
        for (tokens.off_hist[0..offset_code_count], 0..) |v, i| {
            if (v != 0 and self.offset_encoding.codes[i].len == 0) return false;
        }
        for (tokens.extra_hist[0 .. literal_count - 256], 0..) |v, i| {
            if (v != 0 and self.literal_encoding.codes[256 + i].len == 0) return false;
        }
        for (tokens.lit_hist, 0..) |v, i| {
            if (v != 0 and self.literal_encoding.codes[i].len == 0) return false;
        }
        return true;
    }

    /// §3.2.7 — write a dynamic block's header: BFINAL/BTYPE, HLIT/HDIST,
    /// HCLEN, the code-length code lengths in `codegen_order`, and the
    /// codegen's run-length sequence.
    fn writeDynamicHeader(
        self: *BlockWriter,
        bw: *BitWriter,
        num_literals: usize,
        num_offsets: usize,
        num_codegens: usize,
        is_eof: bool,
    ) error{BufferTooSmall}!void {
        // BFINAL, BTYPE=10: value 4, or 5 with BFINAL set.
        try bw.writeBits(if (is_eof) 5 else 4, 3);
        try bw.writeBits(@intCast(num_literals - 257), 5);
        try bw.writeBits(@intCast(num_offsets - 1), 5);
        try bw.writeBits(@intCast(num_codegens - 4), 4);
        for (0..num_codegens) |i| {
            try bw.writeBits(self.codegen_encoding.codes[codegen_order[i]].len, 3);
        }
        var i: usize = 0;
        while (true) {
            const code_word = self.codegen[i];
            i += 1;
            if (code_word == bad_code) break;
            try bw.writeCode(self.codegen_encoding.codes[code_word]);
            switch (code_word) {
                16 => {
                    try bw.writeBits(self.codegen[i], 2);
                    i += 1;
                },
                17 => {
                    try bw.writeBits(self.codegen[i], 3);
                    i += 1;
                },
                18 => {
                    try bw.writeBits(self.codegen[i], 7);
                    i += 1;
                },
                else => {},
            }
        }
    }
};

/// §3.2.5/§3.2.7 — write the block's tokens with `le_codes`/`oe_codes`.
/// A trailing end-of-block token is deferred to the end, so the codes can be
/// the fixed tables while the token list's EOB still lands after the
/// payload.
fn writeTokens(
    bw: *BitWriter,
    tokens: []const Token,
    le_codes: []const Code,
    oe_codes: []const Code,
) error{BufferTooSmall}!void {
    var slice = tokens;
    var defer_eob = false;
    if (slice[slice.len - 1] == end_block_marker) {
        slice = slice[0 .. slice.len - 1];
        defer_eob = true;
    }
    for (slice) |token| {
        if (token < 256) {
            try bw.writeCode(le_codes[token]);
            continue;
        }
        const length = (token >> length_shift) & 0xff;
        const ls = encode.lengthSymbol(length + 3);
        try bw.writeCode(le_codes[ls.symbol]);
        if (ls.extra_bits != 0) try bw.writeBits(ls.extra_value, ls.extra_bits);
        const ds = encode.distanceSymbol((token & 0xffff) + 1);
        try bw.writeCode(oe_codes[ds.symbol]);
        if (ds.extra_bits != 0) try bw.writeBits(ds.extra, ds.extra_bits);
    }
    if (defer_eob) try bw.writeCode(le_codes[end_block_marker]);
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc1951-deflate.txt §3.2.2 (the canonical
// code construction), §3.2.7 (the dynamic header, the code-length codegen,
// the length cap, the one-distance-code case).
// ---------------------------------------------------------------------------

const testing = std.testing;

/// §3.2.2 — the canonical code construction: count the codes per length,
/// number them consecutively from the shortest, and assign within each length
/// in symbol order. The encoder's table stores the wire bits (`wireBits`), so
/// the test reverses the check.
fn expectCanonical(codes: []const Code, lens: []const u5) !void {
    var count: [16]u16 = @splat(0);
    for (lens) |len| {
        if (len != 0) count[len] += 1;
    }
    var next_code: [16]u16 = @splat(0);
    var code: u16 = 0;
    for (1..16) |bits| {
        code = (code + count[bits - 1]) << 1;
        next_code[bits] = code;
    }
    for (codes, lens) |entry, len| {
        if (len == 0) {
            try testing.expectEqual(@as(u5, 0), entry.len);
            continue;
        }
        try testing.expectEqual(len, entry.len);
        try testing.expectEqual(wireBits(next_code[len], len), entry.bits);
        next_code[len] += 1;
    }
}

test "dynamic: the tree builder assigns §3.2.2 canonical codes" {
    // A histogram with several lengths and a gap (symbol 3 unused): every
    // used symbol gets a code, every unused symbol stays zero, and the
    // assignment is the canonical one.
    var freq: [literal_count]u16 = @splat(0);
    freq[0] = 5;
    freq[1] = 4;
    freq[2] = 3;
    freq[4] = 2;
    freq[10] = 1;
    freq[256] = 1; // the end-of-block symbol the emitter always adds
    var enc: HuffmanEncoder(literal_count) = .{};
    enc.generate(&freq, 15);

    var lens: [literal_count]u5 = undefined;
    for (enc.codes, 0..) |entry, i| {
        lens[i] = entry.len;
        if (freq[i] == 0) try testing.expectEqual(@as(u5, 0), entry.len);
    }
    try expectCanonical(&enc.codes, &lens);

    // §3.2.7 — no code is longer than 15 bits, and the Kraft sum is exactly
    // one (the tree is complete: every symbol with a frequency is assigned).
    var kraft: f64 = 0;
    for (lens) |len| {
        if (len != 0) {
            try testing.expect(len <= 15);
            kraft += 1.0 / @as(f64, @floatFromInt(@as(u32, 1) << len));
        }
    }
    try testing.expectApproxEqAbs(@as(f64, 1.0), kraft, 1e-9);
}

test "dynamic: the 15-bit cap holds on a pathological histogram" {
    // Fibonacci frequencies force the deepest tree the construction can make;
    // §3.2.7 caps every code at 15 bits, and the construction enforces the
    // cap while building rather than rebalancing after.
    var freq: [literal_count]u16 = @splat(0);
    var a: u32 = 1;
    var b: u32 = 1;
    for (0..24) |i| {
        freq[i] = @intCast(a); // the largest, fib(24) = 46368, fits u16
        const next = a + b;
        a = b;
        b = next;
    }
    freq[256] = 1;
    var enc: HuffmanEncoder(literal_count) = .{};
    enc.generate(&freq, 15);

    var kraft: f64 = 0;
    var max_len: u5 = 0;
    for (enc.codes, 0..) |entry, i| {
        if (freq[i] == 0) continue;
        try testing.expect(entry.len <= 15);
        if (entry.len > max_len) max_len = entry.len;
        kraft += 1.0 / @as(f64, @floatFromInt(@as(u32, 1) << entry.len));
    }
    try testing.expect(max_len > 8); // the histogram really is deep
    try testing.expectApproxEqAbs(@as(f64, 1.0), kraft, 1e-9);
    try expectCanonical(&enc.codes, &@as([literal_count]u5, blk: {
        var lens: [literal_count]u5 = undefined;
        for (enc.codes, 0..) |entry, i| lens[i] = entry.len;
        break :blk lens;
    }));
}

test "dynamic: the one-distance-code case is one bit (§3.2.7)" {
    // "If only one distance code is used, it is encoded using one bit, not
    // zero bits": a single used symbol takes code 0 in one bit.
    var freq: [offset_code_count]u16 = @splat(0);
    freq[0] = 1;
    var enc: HuffmanEncoder(offset_code_count) = .{};
    enc.generate(&freq, 15);
    try testing.expectEqual(@as(u5, 1), enc.codes[0].len);
    try testing.expectEqual(@as(u16, 0), enc.codes[0].bits);
    for (enc.codes[1..]) |entry| try testing.expectEqual(@as(u5, 0), entry.len);

    // Two used symbols take one-bit codes in literal order.
    freq[3] = 1;
    enc.generate(&freq, 15);
    try testing.expectEqual(@as(u16, 0), enc.codes[0].bits);
    try testing.expectEqual(@as(u16, 1), enc.codes[3].bits);
    try testing.expectEqual(@as(u5, 1), enc.codes[0].len);
    try testing.expectEqual(@as(u5, 1), enc.codes[3].len);
}

test "dynamic: the codegen run codes follow §3.2.7 (16, 17, 18)" {
    // §3.2.7 — the two trees' code lengths are concatenated into one
    // sequence and run-length encoded: 16 repeats the previous length 3-6
    // times (2 extra bits), 17 repeats zero 3-10 times (3 extra bits), 18
    // repeats zero 11-138 times (7 extra bits).
    var w: BlockWriter = .{};
    var lit: HuffmanEncoder(literal_count) = .{};
    var off: HuffmanEncoder(offset_code_count) = .{};
    // Literal lengths 5,5,5,5 then zeros to 8; one distance length of 1.
    for (0..4) |i| lit.codes[i] = .{ .bits = 0, .len = 5 };
    lit.codes[7] = .{ .bits = 0, .len = 3 };
    off.codes[0] = .{ .bits = 0, .len = 1 };
    w.generateCodegen(8, 1, &lit, &off);
    // 5, then 16 (repeat previous 3 more: n-3 = 0), then 17 (three zeros:
    // n-3 = 0), then 3, then 1, then the marker.
    const want = [_]u8{ 5, 16, 0, 17, 0, 3, 1, bad_code };
    try testing.expectEqualSlices(u8, &want, w.codegen[0..want.len]);
    try testing.expectEqual(@as(u16, 1), w.codegen_freq[5]);
    try testing.expectEqual(@as(u16, 1), w.codegen_freq[16]);
    try testing.expectEqual(@as(u16, 1), w.codegen_freq[17]);
    try testing.expectEqual(@as(u16, 1), w.codegen_freq[3]);
    try testing.expectEqual(@as(u16, 1), w.codegen_freq[1]);

    // A long zero run takes the code-18 form: 139 zeros split as 138 (the
    // code's maximum, n-11 = 127) plus one literal zero.
    var lit2: HuffmanEncoder(literal_count) = .{};
    var off2: HuffmanEncoder(offset_code_count) = .{};
    lit2.codes[0] = .{ .bits = 0, .len = 2 };
    off2.codes[0] = .{ .bits = 0, .len = 1 };
    w.generateCodegen(140, 1, &lit2, &off2);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ 2, 18, 127, 0, 1, bad_code },
        w.codegen[0..6],
    );
}

test "dynamic: the block dispatch picks the smallest form" {
    // The three rungs: a block the finder left empty is stored; a block whose
    // symbols do not beat the fixed table is fixed; a compressible block is
    // dynamic. The choice is size arithmetic on the same histograms the
    // reference uses.
    var w: BlockWriter = .{};
    var tokens: TokenList = .{};
    var out: [1024]u8 = undefined;
    const input = "the quick brown fox jumps over the lazy dog. " ** 4;

    // Zero tokens: stored.
    var bw: BitWriter = .{ .target = &out };
    try w.writeBlockFast(&bw, &tokens, input, false);
    try testing.expectEqual(@as(u8, 0b000), out[0] & 0b111); // BFINAL=0, BTYPE=00

    // One literal per byte (no matches): the literals-only form, whose own
    // dispatch stores or builds a literals-only table — never a match table.
    w = .{};
    tokens = .{};
    tokens.addLiterals(input);
    bw = .{ .target = &out };
    try w.writeBlockFast(&bw, &tokens, input, false);
    try testing.expect(out[0] & 0b1 == 0); // BFINAL clear on data blocks

    // A match-heavy block: dynamic, with the end-of-block code owed (a
    // non-final dynamic block leaves its table open, so `last_header` is
    // set and the next header — or the ending — writes the EOB).
    var big: [4000]u8 = undefined;
    for (0..big.len) |i| big[i] = @intCast(i % 8);
    w = .{};
    tokens = .{};
    tokens.addLiterals(big[0..8]);
    var remaining: usize = big.len - 8;
    while (remaining > 0) {
        const chunk = @min(remaining, encode.max_match_len);
        tokens.addMatchLong(chunk, 8);
        remaining -= chunk;
    }
    bw = .{ .target = &out };
    try w.writeBlockFast(&bw, &tokens, &big, false);
    try testing.expectEqual(@as(u8, 0b100), out[0] & 0b111); // BFINAL=0, BTYPE=10
    try testing.expect(w.last_header > 0);
}
