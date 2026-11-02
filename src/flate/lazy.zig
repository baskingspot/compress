//! The lazy levels' match finder: hash chains with lazy match evaluation,
//! the method RFC 1951 §4 describes. Every position with four bytes ahead
//! is hashed into a table of chain heads, and each position links to the
//! previous one with the same hash, so a search walks back through the
//! candidates, newest first, up to `Params.chain` of them. A match found at
//! one position is held while the next position is searched too, and the
//! longer of the two wins (§4's "lazy match evaluation"): when the next
//! one is longer, the first position becomes a literal.
//!
//! Positions in the tables are absolute stream positions (wrapping u32),
//! offset by `encode.finder_origin` so that a cleared head is out of reach,
//! as the level-6 finder keeps them. A link is followed only while it goes
//! strictly back and stays within the 32 KiB window (`§3.2.5`), and every
//! candidate's bytes are compared before it is used, so neither a link the
//! window has slid past nor a wrapped one is ever emitted.
//!
//! The filtered strategy (`Params.min_len` above 4) codes short matches as
//! literals. Data that a predictor has turned into small residuals, such as
//! PNG's filtered rows, has short repeats everywhere whose literals the
//! dynamic Huffman code makes cheaper than a length and distance.
//!
//! Format: docs/specs/rfc1951-deflate.txt

const std = @import("std");
const assert = std.debug.assert;

const fastmem = @import("fastmem");

const encode = @import("encode.zig");
const dynamic = @import("dynamic.zig");

const history_len = encode.history_len;
const max_match_len = encode.max_match_len;

/// The shortest match the finder considers: a 4-byte hash.
pub const min_match: usize = 4;

/// One level's search effort.
pub const Params = struct {
    /// The most candidates one search compares.
    chain: u16,
    /// A held match at least this long is taken without searching the next
    /// position.
    lazy: u16,
    /// A match at least this long ends a search.
    nice: u16,
    /// With a held match at least this long, the next search compares a
    /// quarter of `chain`.
    good: u16,
    /// Matches shorter than this are coded as literals: `min_match`, or
    /// more for the filtered strategy.
    min_len: u16,
};

/// The chain heads' hash width.
const hash_bits = 15;

/// The finder's tables: a chain head per hash and a link per window
/// position, 256 KiB, the heads cleared once per stream. The links need no
/// clearing: a search reaches a link only through a position this stream
/// inserted, which set it.
pub const Finder = struct {
    head: [1 << hash_bits]u32,
    prev: [history_len]u32,

    pub fn clear(self: *Finder) void {
        fastmem.set(u32, &self.head, 0);
    }
};

inline fn hash4(v: u32) usize {
    return @intCast((v *% 2654435761) >> (32 - hash_bits));
}

/// A match: its length and distance.
const Match = struct { len: usize = 0, dist: usize = 0 };

/// The lazy scan over one block, `window.source`'s positions
/// `[block_start, block_end)`, filling `tokens`, then emitted as one deflate
/// block through `emitter`; `sync` marks the stream's last block. (Smaller
/// blocks, for codes that follow the data more closely, measured larger on
/// PNG image data.)
/// `base` is the absolute stream position of the window's first byte, and
/// `windowed` says the window may have dropped bytes the tables still name
/// (the streaming `Writer`).
pub fn compressBlock(
    comptime preset: bool,
    comptime windowed: bool,
    window: encode.Window(preset),
    block_start: usize,
    block_end: usize,
    w: *encode.BitWriter,
    tokens: *dynamic.TokenList,
    finder: *Finder,
    emitter: *dynamic.BlockWriter,
    base: u32,
    params: Params,
    sync: bool,
) error{BufferTooSmall}!void {
    tokens.reset();
    var s = block_start;
    var held: Match = .{};
    var pending = false;
    while (s < block_end) {
        var cur: Match = .{};
        if (s + min_match <= block_end) {
            if (held.len < params.lazy) {
                cur = longest(
                    preset,
                    windowed,
                    window,
                    finder,
                    s,
                    base,
                    block_end,
                    held.len,
                    params,
                );
                if (cur.len < params.min_len) cur = .{};
            }
            insert(preset, window, finder, s, base);
        }
        if (held.len != 0 and cur.len <= held.len) {
            // The held match, which starts a byte back, wins.
            tokens.addMatchLong(held.len, held.dist);
            const stop = s - 1 + held.len;
            var p = s + 1;
            while (p < stop and p + min_match <= block_end) : (p += 1) {
                insert(preset, window, finder, p, base);
            }
            s = stop;
            held = .{};
            pending = false;
        } else {
            if (pending) tokens.addLiteral(window.byte(s - 1));
            pending = true;
            held = cur;
            s += 1;
        }
    }
    // The last position can hold no match: it has fewer than four bytes.
    if (pending) tokens.addLiteral(window.byte(s - 1));
    if (block_end == block_start) return;
    return emitter.writeBlockFast(w, tokens, window.sourceSlice(block_start, block_end), sync);
}

/// Links every position in `[start, end)` with four bytes ahead into the
/// chains: a preset dictionary's, before the first block.
pub fn prime(
    comptime preset: bool,
    window: encode.Window(preset),
    finder: *Finder,
    start: usize,
    end: usize,
    base: u32,
) void {
    const window_len = window.dict.len + window.source.len;
    var p = start;
    while (p < end and p + min_match <= window_len) : (p += 1) {
        insert(preset, window, finder, p, base);
    }
}

/// Links position `s` into its hash chain.
inline fn insert(
    comptime preset: bool,
    window: encode.Window(preset),
    finder: *Finder,
    s: usize,
    base: u32,
) void {
    const h = hash4(window.load32At(s));
    const abs = base +% @as(u32, @truncate(s));
    finder.prev[abs & (history_len - 1)] = finder.head[h];
    finder.head[h] = abs;
}

/// The longest match at `s` longer than `held`, walking `s`'s chain from
/// its head. Called before `s` is inserted.
fn longest(
    comptime preset: bool,
    comptime windowed: bool,
    window: encode.Window(preset),
    finder: *const Finder,
    s: usize,
    base: u32,
    limit: usize,
    held: usize,
    params: Params,
) Match {
    const max_len = @min(max_match_len, limit - s);
    var best: Match = .{ .len = @max(held, min_match - 1) };
    if (best.len >= max_len) return .{};
    const nice = @min(params.nice, max_len);
    var chain: usize = params.chain;
    if (held >= params.good) chain = (chain + 3) >> 2;
    const s_abs = base +% @as(u32, @truncate(s));
    const first = window.load32At(s);
    var entry = finder.head[hash4(first)];
    var last_dist: u32 = 0;
    while (chain > 0) : (chain -= 1) {
        const dist = s_abs -% entry;
        // Strictly back, within the window, and still in it.
        if (dist <= last_dist or dist > history_len) break;
        if (windowed and dist > s) break;
        last_dist = dist;
        const t = s - dist;
        // The byte that would make this match the longest, then the first
        // four.
        const tail_equal = window.byte(t + best.len) == window.byte(s + best.len);
        if (tail_equal and window.load32At(t) == first) {
            const len = if (max_len <= min_match)
                max_len
            else
                min_match + window.matchLength(t + min_match, s + min_match, s + max_len);
            if (len > best.len) {
                best = .{ .len = len, .dist = dist };
                if (len >= nice) break;
            }
        }
        entry = finder.prev[entry & (history_len - 1)];
    }
    return if (best.dist == 0) .{} else best;
}
