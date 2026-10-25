//! The q3 matcher (RFC 7932 §4, §5): the reference's quickly hasher `H3`
//! (16-bit buckets, a two-entry sweep, a five-byte hash, no dictionary
//! search), the greedy backward-reference scan with its lazy one-step
//! lookahead and sparse-search heuristic, and the command record the scan
//! emits — the insert-and-copy length code of §5 and the distance prefix of
//! §4.
//!
//! Ported from google/brotli v1.2.0 `c/enc/backward_references_inc.h`,
//! `c/enc/hash_longest_match_quickly_inc.h`, `c/enc/backward_references.c`,
//! and `c/enc/command.h` (`THIRD_PARTY.md`); the hash parameters are the
//! `H3` instantiation in `c/enc/hash.h` — 16 bucket bits, sweep bits 1,
//! `USE_DICTIONARY` 0. Format: docs/specs/rfc7932-brotli.txt.

const std = @import("std");
const assert = std.debug.assert;
const common = @import("common.zig");

const fastmem = @import("fastmem");

/// The input history the matcher searches, addressed by absolute stream
/// position. `bytes` is the ring (or, for the one-shot, the input itself)
/// and `mask` maps a position to its index; the one-shot passes an all-ones
/// mask, so positions index the input directly.
pub const Window = struct {
    bytes: []const u8,
    mask: usize,

    /// The byte at `position`. Callers guarantee `position` is below the
    /// current block's end.
    pub fn at(self: Window, position: usize) u8 {
        return self.bytes[position & self.mask];
    }

    /// The byte at `position` for the hasher's compare reads, which the
    /// reference allows to reach the current block's end: its ring buffer
    /// carries zeros in the seven bytes past the copied input, so a compare
    /// there reads zero.
    fn compare(self: Window, position: usize, block_end: usize) u8 {
        if (position >= block_end) return 0;
        return self.bytes[position & self.mask];
    }
};

/// The number of bucket-table entries: the `H3` bucket bits are 16.
pub const bucket_bits = 16;
pub const bucket_size = 1 << bucket_bits;
const bucket_mask = bucket_size - 1;
/// The sweep: two adjacent entries per bucket, selected by bit 3 of the
/// position (`BUCKET_SWEEP_BITS` 1).
const bucket_sweep_mask = 8;
/// The hash reads five bytes (`HASH_LEN` 5).
pub const hash_len = 5;

/// The reference's `kHashMul64`, the quickly hashers' odd multiplier.
const hash_mul64: u64 = 0x1FE35A7B_D3579BD3;

/// The reference's `HashBytes`: the top `bucket_bits` of the product of the
/// five-byte prefix (left-justified) and the multiplier.
fn hashBytes(bytes: []const u8, index: usize) u32 {
    const word = common.readInt(u64, bytes[index..][0..8]);
    const h = (word << (64 - 8 * hash_len)) *% hash_mul64;
    return @truncate(h >> (64 - bucket_bits));
}

/// The reference's `Log2FloorNonZero`.
pub fn log2FloorNonZero(n: usize) u32 {
    assert(n != 0);
    return @bitSizeOf(usize) - 1 - @as(u32, @clz(n));
}

const literal_byte_score = 135;
const distance_bit_penalty = 30;
/// `BROTLI_SCORE_BASE`: "score must be positive after applying maximal
/// penalty". The constant cancels from every comparison; it is here for the
/// port's arithmetic to read like the reference's.
const score_base = distance_bit_penalty * 8 * @sizeOf(usize);

fn backwardReferenceScore(copy_length: usize, backward: usize) u64 {
    return score_base + literal_byte_score * copy_length -
        distance_bit_penalty * log2FloorNonZero(backward);
}

fn backwardReferenceScoreUsingLastDistance(copy_length: usize) u64 {
    return literal_byte_score * copy_length + score_base + 15;
}

/// The reference's `HasherSearchResult`: the best candidate `findLongestMatch`
/// found. `len_code_delta` is always zero at this class (no dictionary
/// matches), and is kept because the command's copy-code math reads it.
pub const SearchResult = struct {
    len: usize,
    distance: usize,
    score: u64,
    len_code_delta: i32,
};

/// The q3 hasher's state: the bucket table, whose entries are absolute
/// positions (the reference's `uint32_t`).
pub const Hasher = struct {
    /// `bucket_size` entries, owned by the caller; zero at the stream's
    /// start, and the zero reads as "position 0", which the reference's
    /// zeroed table does too.
    buckets: []u32,

    /// The reference's `Prepare`: zero the whole table. (Its partial-prepare
    /// shortcut for one-shot inputs only skips buckets no lookup can read,
    /// so the effective state is the same.)
    pub fn init(self: *Hasher) void {
        assert(self.buckets.len == bucket_size);
        fastmem.set(u32, self.buckets, 0);
    }

    /// The reference's `StitchToPreviousBlock`: the three bytes before the
    /// block could not be hashed before it, because they need both sides.
    pub fn stitch(self: *Hasher, window: Window, position: usize, num_bytes: usize) void {
        if (num_bytes >= hash_len + 2 and position >= 3) {
            self.store(window, position - 3);
            self.store(window, position - 2);
            self.store(window, position - 1);
        }
    }

    /// The reference's `Store`: hash the five bytes at `position` and drop
    /// the position into the sweep slot bit 3 selects.
    fn store(self: *Hasher, window: Window, position: usize) void {
        const key = hashBytes(window.bytes, position & window.mask);
        const off = position & bucket_sweep_mask;
        self.buckets[(key + off) & bucket_mask] = @truncate(position);
    }

    fn storeRange(self: *Hasher, window: Window, start: usize, end: usize) void {
        var i = start;
        while (i < end) : (i += 1) self.store(window, i);
    }

    /// The reference's `FindLongestMatch` for `H3`: the last-distance
    /// candidate, then the two sweep slots, then the current position is
    /// stored. Every read is bounded by `block_end`; the compare byte may
    /// land exactly on it, which reads as zero (see `Window.compare`).
    fn findLongestMatch(
        self: *Hasher,
        window: Window,
        dist_cache: *const [4]i32,
        cur_ix: usize,
        max_length: usize,
        max_backward: usize,
        block_end: usize,
        out: *SearchResult,
    ) void {
        const buckets = self.buckets;
        const best_len_in = out.len;
        var compare_char = window.compare(cur_ix + best_len_in, block_end);
        const key = hashBytes(window.bytes, cur_ix & window.mask);
        var best_score = out.score;
        var best_len = best_len_in;
        const cached_backward: usize = @intCast(dist_cache[0]);
        out.len_code_delta = 0;
        if (cached_backward <= cur_ix) {
            const prev = (cur_ix - cached_backward) & window.mask;
            if (compare_char == window.bytes[prev + best_len]) {
                const len = findMatchLength(window, cur_ix - cached_backward, cur_ix, max_length);
                if (len >= 4) {
                    const score = backwardReferenceScoreUsingLastDistance(len);
                    if (best_score < score) {
                        out.len = len;
                        out.distance = cached_backward;
                        out.score = score;
                        best_len = len;
                        best_score = score;
                        compare_char = window.compare(cur_ix + len, block_end);
                    }
                }
            }
        }
        const keys: [2]usize = .{ key, (key + bucket_sweep_mask) & bucket_mask };
        const key_out = keys[(cur_ix & bucket_sweep_mask) >> 3];
        for (keys) |bucket_key| {
            const stored = buckets[bucket_key];
            const backward = cur_ix - stored;
            const prev = stored & window.mask;
            if (compare_char != window.bytes[prev + best_len]) continue;
            if (backward == 0 or backward > max_backward) continue;
            const len = findMatchLength(window, stored, cur_ix, max_length);
            if (len >= 4) {
                const score = backwardReferenceScore(len, backward);
                if (best_score < score) {
                    best_len = len;
                    out.len = len;
                    compare_char = window.compare(cur_ix + len, block_end);
                    best_score = score;
                    out.score = score;
                    out.distance = backward;
                }
            }
        }
        // The dictionary fallback of the reference's quickly hashers is
        // compiled out at `H3` (`USE_DICTIONARY` 0): this is the whole body.
        buckets[key_out] = @truncate(cur_ix);
    }
};

/// The reference's `FindMatchLengthWithLimit`: the longest common prefix of
/// the bytes at `source` and `target`, at most `limit` bytes.
fn findMatchLength(window: Window, source: usize, target: usize, limit: usize) usize {
    var matched: usize = 0;
    while (matched + 8 <= limit) : (matched += 8) {
        const from = (source + matched) & window.mask;
        const to = (target + matched) & window.mask;
        const a = common.readInt(u64, window.bytes[from..][0..8]);
        const b = common.readInt(u64, window.bytes[to..][0..8]);
        if (a != b) return matched + (@ctz(a ^ b) >> 3);
    }
    while (matched < limit and
        window.bytes[(source + matched) & window.mask] ==
            window.bytes[(target + matched) & window.mask]) : (matched += 1)
    {}
    return matched;
}

// ---------------------------------------------------------------------------
// §5 — the insert-and-copy length codes
// ---------------------------------------------------------------------------

/// §5's insert-length bases (`kBrotliInsBase`).
pub const insert_base = [24]u32{
    0,  1,  2,  3,  4,   5,   6,   8,   10,   14,   18,   26,
    34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594,
};
/// §5's insert extra-bit counts.
pub const insert_extra = [24]u5{
    0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24,
};
/// §5's copy-length bases (`kBrotliCopyBase`).
pub const copy_base = [24]u32{
    2,  3,  4,  5,  6,  7,   8,   9,   10,  12,  14,   18,
    22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118,
};
/// §5's copy extra-bit counts.
pub const copy_extra = [24]u5{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24,
};

/// The reference's `GetInsertLengthCode`.
pub fn insertLengthCode(insertlen: usize) u16 {
    if (insertlen < 6) return @intCast(insertlen);
    if (insertlen < 130) {
        const nbits = log2FloorNonZero(insertlen - 2) - 1;
        return @intCast((nbits << 1) + ((insertlen - 2) >> @intCast(nbits)) + 2);
    }
    if (insertlen < 2114) return @intCast(log2FloorNonZero(insertlen - 66) + 10);
    if (insertlen < 6210) return 21;
    if (insertlen < 22594) return 22;
    return 23;
}

/// The reference's `GetCopyLengthCode`.
pub fn copyLengthCode(copylen: usize) u16 {
    if (copylen < 10) return @intCast(copylen - 2);
    if (copylen < 134) {
        const nbits = log2FloorNonZero(copylen - 6) - 1;
        return @intCast((nbits << 1) + ((copylen - 6) >> @intCast(nbits)) + 4);
    }
    if (copylen < 2118) return @intCast(log2FloorNonZero(copylen - 70) + 12);
    return 23;
}

/// The reference's `CombineLengthCodes`: §5's 704-symbol table position, the
/// 64 short codes included.
fn combineLengthCodes(inscode: u16, copycode: u16, use_last_distance: bool) u16 {
    const bits64: u16 = (copycode & 0x7) | ((inscode & 0x7) << 3);
    if (use_last_distance and inscode < 8 and copycode < 16) {
        return if (copycode < 8) bits64 else bits64 | 64;
    }
    var offset: u32 = 2 * (@as(u32, copycode >> 3) + 3 * @as(u32, inscode >> 3));
    offset = (offset << 5) + 0x40 + ((@as(u32, 0x520D40) >> @intCast(offset)) & 0xC0);
    return @intCast(offset | bits64);
}

/// The reference's `GetLengthCode`.
pub fn lengthCode(insertlen: usize, copylen: usize, use_last_distance: bool) u16 {
    return combineLengthCodes(
        insertLengthCode(insertlen),
        copyLengthCode(copylen),
        use_last_distance,
    );
}

/// The reference's `PrefixEncodeCopyDistance` at NPOSTFIX 0 and NDIRECT 0:
/// §4's distance symbol (the low 10 bits of the result) and its extra bits
/// (the high 6 bits are the extra-bit count).
pub fn prefixEncodeCopyDistance(distance_code: usize) struct { code: u16, extra: u32 } {
    if (distance_code < 16) return .{ .code = @intCast(distance_code), .extra = 0 };
    const dist = 4 + (distance_code - 16);
    const bucket = log2FloorNonZero(dist) - 1;
    const prefix = (dist >> @intCast(bucket)) & 1;
    const offset = (2 + prefix) << @intCast(bucket);
    const nbits = bucket;
    return .{
        .code = @intCast((nbits << 10) |
            (16 + ((2 * (nbits - 1) + prefix) << 0))),
        .extra = @intCast(dist - offset),
    };
}

/// The reference's `ComputeDistanceCode`: the §4 short code when the distance
/// is in the ring, else the plain code (`distance + 15`).
fn computeDistanceCode(distance: usize, max_distance: usize, dist_cache: *const [4]i32) usize {
    if (distance <= max_distance) {
        const distance_plus_3 = distance + 3;
        const offset0 = distance_plus_3 -% @as(usize, @intCast(dist_cache[0]));
        const offset1 = distance_plus_3 -% @as(usize, @intCast(dist_cache[1]));
        if (distance == @as(usize, @intCast(dist_cache[0]))) return 0;
        if (distance == @as(usize, @intCast(dist_cache[1]))) return 1;
        if (offset0 < 7) return (@as(u32, 0x9750468) >> @intCast(4 * offset0)) & 0xF;
        if (offset1 < 7) return (@as(u32, 0xFDB1ACE) >> @intCast(4 * offset1)) & 0xF;
        if (distance == @as(usize, @intCast(dist_cache[2]))) return 2;
        if (distance == @as(usize, @intCast(dist_cache[3]))) return 3;
    }
    return distance + 16 - 1;
}

/// One command of the stream: the reference's `Command`, unpacked into the
/// fields the emission reads.
pub const Command = struct {
    /// §5's insert-and-copy length code, 0..703.
    cmd_prefix: u16,
    /// §4's distance symbol (low 10 bits) and extra-bit count (high 6).
    dist_prefix: u16,
    /// Literals to insert before the copy.
    insert_len: u32,
    /// The copy *code* length — the produced length plus the copy-code
    /// delta. The delta is zero at this class (no dictionary matches).
    copy_len_code: u32,
    /// The copy's produced length.
    copy_len: u32,
    /// §4's distance extra bits.
    dist_extra: u32,
};

/// The reference's `InitCommand`, with `copylen_code_delta` 0.
fn initCommand(
    insertlen: usize,
    copylen: usize,
    distance_code: usize,
    out: *Command,
) void {
    const dist = prefixEncodeCopyDistance(distance_code);
    out.insert_len = @intCast(insertlen);
    out.copy_len = @intCast(copylen);
    out.copy_len_code = @intCast(copylen);
    out.dist_prefix = dist.code;
    out.dist_extra = dist.extra;
    out.cmd_prefix = lengthCode(insertlen, copylen, (dist.code & 0x3FF) == 0);
}

/// The reference's `InitInsertCommand`: an insert-only command, whose copy is
/// ignored by §9.3's last-command rule. The copy length code is 4 (the
/// shortest real copy) so the code is a valid table position.
pub fn initInsertCommand(insertlen: usize, out: *Command) void {
    out.insert_len = @intCast(insertlen);
    out.copy_len = 0;
    out.copy_len_code = 4;
    out.dist_prefix = 16;
    out.dist_extra = 0;
    out.cmd_prefix = lengthCode(insertlen, 4, false);
}

/// The delayed commands of one meta-block: the reference's `commands_` array
/// with its `num_commands_`, `num_literals_`, and the pending literal run
/// (`last_insert_len_`).
pub const Commands = struct {
    buffer: []Command,
    len: usize = 0,
    literals: usize = 0,
    /// Literals after the last command, without a command of their own; the
    /// flush turns them into one (`InitInsertCommand`).
    last_insert_len: usize = 0,

    pub fn reset(self: *Commands) void {
        self.len = 0;
        self.literals = 0;
        self.last_insert_len = 0;
    }
};

/// The matcher: the hasher, the window it searches, the window's bit width,
/// and §4's four-distance ring.
pub const Matcher = struct {
    hasher: Hasher,
    window: Window,
    /// The stream's `lgwin`, 10..24: the window bound is `(1 << lgwin) - 16`
    /// (§9.1).
    lgwin: u6,
    /// §4's ring, most recent first: "initialized by the values 16, 15, 11,
    /// and 4 (i.e., the last four distances used)". The reference encoder
    /// stores them newest-first, so index 0 is the last distance (4) and
    /// index 3 the fourth-to-last (16) — the same order the decoder's ring
    /// resolves symbol 0 through.
    dist_cache: [4]i32 = .{ 4, 11, 15, 16 },

    /// The reference's `CreateBackwardReferences`: scan
    /// `[position, position + num_bytes)`, appending commands.
    ///
    /// The scan cascade stays in one function on purpose (the house's
    /// documented deviation, like snappy's `encodeBlock` and zstd's
    /// `scanBlock`): it is one labeled control flow — the greedy accept, the
    /// one-step lazy re-check, and the sparse-search jump — and splitting it
    /// would scatter the loop's state (`insert_length`, the score, the
    /// heuristic cursor) across helpers. Every pure piece is extracted:
    /// `hashBytes`, `findLongestMatch`, `findMatchLength`, `store`,
    /// `storeRange`, `computeDistanceCode`, and `initCommand`.
    pub fn findReferences(
        self: *Matcher,
        position: usize,
        num_bytes: usize,
        commands: *Commands,
    ) void {
        const window = self.window;
        // The reference's `BROTLI_MAX_BACKWARD_LIMIT(lgwin)`: §9.1's window
        // bound.
        const max_backward_limit = (@as(usize, 1) << @intCast(self.lgwin)) - 16;
        var pos = position;
        const pos_end = position + num_bytes;
        // The hasher's lookahead is eight bytes; the last seven positions of
        // a block cannot be hashed (they need the next block's bytes).
        const store_end = if (num_bytes >= hash_len + 3)
            position + num_bytes - (hash_len + 3) + 1
        else
            position;
        // The sparse-search heuristic's window (`LiteralSpreeLengthForSparse
        // Search`: 64 below quality 9).
        const spree = 64;
        var apply_random_heuristics = pos + spree;
        var insert_length = commands.last_insert_len;
        const min_score = score_base + 100;
        var sr: SearchResult = .{
            .len = 0,
            .distance = 0,
            .score = min_score,
            .len_code_delta = 0,
        };
        while (pos + hash_len + 3 < pos_end) {
            var max_length = pos_end - pos;
            var max_distance = @min(pos, max_backward_limit);
            sr.len = 0;
            sr.len_code_delta = 0;
            sr.distance = 0;
            sr.score = min_score;
            self.hasher.findLongestMatch(
                window,
                &self.dist_cache,
                pos,
                max_length,
                max_distance,
                pos_end,
                &sr,
            );
            if (sr.score > min_score) {
                // Found a match; look one byte ahead (the reference's lazy
                // search, at this class a one-step check with the previous
                // length as the starting bound).
                var delayed: usize = 0;
                max_length -= 1;
                while (true) : (max_length -= 1) {
                    const cost_diff_lazy = 175;
                    var sr2: SearchResult = .{
                        .len = @min(sr.len - 1, max_length),
                        .distance = 0,
                        .score = min_score,
                        .len_code_delta = 0,
                    };
                    max_distance = @min(pos + 1, max_backward_limit);
                    self.hasher.findLongestMatch(
                        window,
                        &self.dist_cache,
                        pos + 1,
                        max_length,
                        max_distance,
                        pos_end,
                        &sr2,
                    );
                    if (sr2.score >= sr.score + cost_diff_lazy) {
                        // The next byte starts a better match: emit this
                        // byte as a literal and take that one instead.
                        pos += 1;
                        insert_length += 1;
                        sr = sr2;
                        delayed += 1;
                        if (delayed < 4 and pos + hash_len + 3 < pos_end) continue;
                    }
                    break;
                }
                apply_random_heuristics = pos + 2 * sr.len + spree;
                max_distance = @min(pos, max_backward_limit);
                const distance_code = computeDistanceCode(
                    sr.distance,
                    max_distance,
                    &self.dist_cache,
                );
                // §4 — the ring is pushed by window matches only; a rolled
                // back meta-block restores it (the caller's job).
                if (sr.distance <= max_distance and distance_code > 0) {
                    self.dist_cache[3] = self.dist_cache[2];
                    self.dist_cache[2] = self.dist_cache[1];
                    self.dist_cache[1] = self.dist_cache[0];
                    self.dist_cache[0] = @intCast(sr.distance);
                }
                assert(commands.len < commands.buffer.len);
                initCommand(insert_length, sr.len, distance_code, &commands.buffer[commands.len]);
                commands.len += 1;
                commands.literals += insert_length;
                insert_length = 0;
                // Store the hashes the match skipped. "Avoid hash poisoning
                // with RLE data": a short distance skips the positions whose
                // hashes would all collide.
                var range_start = pos + 2;
                const range_end = @min(pos + sr.len, store_end);
                if (sr.distance < (sr.len >> 2)) {
                    range_start = @min(
                        range_end,
                        @max(range_start, pos + sr.len - (sr.distance << 2)),
                    );
                }
                self.hasher.storeRange(window, range_start, range_end);
                pos += sr.len;
            } else {
                insert_length += 1;
                pos += 1;
                // Unsuccessful match lookups are expensive: past a run of
                // literals, look only every second (then every fourth) byte.
                if (pos > apply_random_heuristics) {
                    if (pos > apply_random_heuristics + 4 * spree) {
                        const margin = @max(hash_len + 3 - 1, 4);
                        const pos_jump = @min(pos + 16, pos_end - margin);
                        while (pos < pos_jump) : (pos += 4) {
                            self.hasher.store(window, pos);
                            insert_length += 4;
                        }
                    } else {
                        const margin = @max(hash_len + 3 - 1, 2);
                        const pos_jump = @min(pos + 8, pos_end - margin);
                        while (pos < pos_jump) : (pos += 2) {
                            self.hasher.store(window, pos);
                            insert_length += 2;
                        }
                    }
                }
            }
        }
        insert_length += pos_end - pos;
        commands.last_insert_len = insert_length;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "§5's length codes are the reference's table positions" {
    // The short codes: insert 0..5 map to themselves, copy 2..9 map to 0..7.
    try testing.expectEqual(@as(u16, 0), insertLengthCode(0));
    try testing.expectEqual(@as(u16, 5), insertLengthCode(5));
    try testing.expectEqual(@as(u16, 0), copyLengthCode(2));
    try testing.expectEqual(@as(u16, 7), copyLengthCode(9));
    // The 64 short codes pack small insert+copy pairs (§5's table).
    try testing.expectEqual(@as(u16, 0), lengthCode(0, 2, true));
    try testing.expectEqual(@as(u16, 64), lengthCode(0, 10, true));
    // Without the last-distance flag the code moves out of the short row.
    try testing.expect(lengthCode(0, 2, false) >= 128);
    // The largest codes: 23 for both, which is the last table block.
    try testing.expectEqual(@as(u16, 23), insertLengthCode(22594));
    try testing.expectEqual(@as(u16, 23), copyLengthCode(2118));
}

test "§4's distance prefix inverts to the decoder's formula" {
    // A plain distance code (>= 16) at NPOSTFIX 0, NDIRECT 0: the symbol's
    // bucket and extra bits reconstruct the distance the decoder computes.
    for ([_]usize{ 16, 17, 20, 100, 1000, 65535 }) |distance_code| {
        const encoded = prefixEncodeCopyDistance(distance_code);
        const symbol = encoded.code & 0x3FF;
        const nbits = 1 + ((symbol - 16) >> 1);
        const hcode = symbol - 16;
        const offset = (@as(u32, 2 + (hcode & 1)) << @intCast(nbits)) - 4;
        const distance = offset + encoded.extra + 1;
        try testing.expectEqual(distance_code, distance + 15);
    }
}

test "the matcher finds a copy and leaves the ring at the last distance" {
    // "abcabcabcabc": a three-literal insert, then a distance-3 copy of the
    // remaining nine bytes.
    const text = "abcabcabcabc";
    var buckets: [bucket_size]u32 = @splat(0);
    var matcher: Matcher = .{
        .hasher = .{ .buckets = &buckets },
        .window = .{ .bytes = text, .mask = std.math.maxInt(usize) },
        .lgwin = 22,
    };
    matcher.hasher.init();
    var command_buffer: [16]Command = @splat(.{
        .cmd_prefix = 0,
        .dist_prefix = 0,
        .insert_len = 0,
        .copy_len_code = 0,
        .copy_len = 0,
        .dist_extra = 0,
    });
    var commands: Commands = .{ .buffer = &command_buffer };
    matcher.findReferences(0, text.len, &commands);
    try testing.expectEqual(@as(usize, 1), commands.len);
    try testing.expectEqual(@as(u32, 3), commands.buffer[0].insert_len);
    try testing.expectEqual(@as(u32, 9), commands.buffer[0].copy_len);
    try testing.expectEqual(@as(u32, 9), commands.buffer[0].copy_len_code);
    // Distance 3 against the initial ring {4, 11, 15, 16}: §4's short table
    // gives symbol 4 (the decoder's own table maps 4 back to 3), with no
    // extra bits.
    try testing.expectEqual(@as(u16, 4), commands.buffer[0].dist_prefix & 0x3FF);
    try testing.expectEqual(@as(u32, 0), commands.buffer[0].dist_extra);
    try testing.expectEqual(@as(u32, 0), commands.buffer[0].dist_prefix >> 10);
    try testing.expectEqual(@as(i32, 3), matcher.dist_cache[0]);
}
