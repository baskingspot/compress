//! Raw DEFLATE (RFC 1951) encoder, levels 1 and 6. `compress` splits the input
//! into blocks of at most 65535 bytes and encodes each from a greedy match
//! finder: level 1 as fixed-Huffman symbols or a stored block when that is
//! smaller (`§3.2.4`); level 6 as klauspost/compress's level-6 class — their
//! wider finder, dynamic-Huffman blocks (`§3.2.7`, `dynamic.zig`), and the
//! per-block stored/fixed/dynamic dispatch. Either way the output never
//! exceeds `maxCompressedLength`. Every stream ends with an empty final fixed
//! block (`03 00`); no data block carries BFINAL.
//!
//! The level-1 finder follows klauspost/compress level 1: a single-slot table
//! of `1 << 15` absolute stream positions keyed by a 5-byte hash, a 4-byte
//! confirm, an accelerating skip, backward extension into the preceding
//! literals, minimum match 4, and a 32768-byte distance cap (`§3.2.5`). Its
//! window is a block's 32 KiB of history followed by the block, so matches
//! cross block boundaries as the format allows (`§3.2.3`). A preset
//! dictionary (`Options.dict`) is history in front of that window: the finder
//! is primed from the dictionary's tail and can emit distances that reach
//! into it. The level-6 finder (`Finder6`, `encodeTokens6`) is their
//! `fastEncL6`: a 4-byte-hash table plus a 7-byte-hash table with two
//! candidates per slot, the same window shape, and the same dictionary
//! priming (a full scan over the dictionary's tail).
//!
//! The streaming `Writer` is built on `BitWriter`, `compressBlockStream`,
//! `compressBlockStream6`, `emitStoredBlock`, and `writeFinalEmptyBlock`,
//! which are public for it.
//!
//! Format: docs/specs/rfc1951-deflate.txt
//! Lineage: klauspost/compress `flate/level1.go` (`fastEncL1`) and
//! `flate/fast_encoder.go`; attribution in THIRD_PARTY.md.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const print = std.debug.print;
const math = std.math;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const common = @import("common.zig");
const readInt = common.readInt;
const decode = @import("decode.zig");
const dynamic = @import("dynamic.zig");
const writer = @import("Writer.zig");
const golden = @import("golden.zig");

/// The encoder's block size: 65535, the stored-block LEN cap (`§3.2.4`), so any
/// block can fall back to stored. `compress` splits input at it; the streaming
/// `Writer` emits blocks at it.
pub const max_block_size: usize = 65535;

/// The format's maximum backward match reach: 32768 (`§3.2.5`, the canonical
/// constant in decode.zig with the distance tables). The finder's window is
/// this much history followed by the block, so the cap is structural.
pub const history_len = decode.history_len;

/// Worst-case compressed size for `input_len` bytes:
/// `input_len + 5 * ceil(input_len / max_block_size) + 2`. Every block costs at
/// most 5 bytes of stored-block header beyond its input (`§3.2.4`), and every
/// stream ends with a 2-byte empty block. Size `target` to this before
/// `compress`.
pub fn maxCompressedLength(input_len: usize) usize {
    return input_len + 5 * ((input_len + max_block_size - 1) / max_block_size) + 2;
}

/// The finder table has `1 << 15` single-slot `u32` entries, 128 KiB.
const table_bits = 15;
const table_size = 1 << table_bits;

/// The match-finder table. An entry is the absolute stream position (wrapping
/// `u32`) of the newest scanned position with that hash. A stale entry fails
/// `matchCandidate`'s distance cap, so one table persists across a stream's
/// blocks with no per-block zeroing. Callers zero it once per stream
/// (`fastmem.set`) and prime each block's history at `stream_prime_stride`.
pub const FinderTable = [table_size]u32;

/// History priming density for the streaming/one-shot block sequence: every
/// `stream_prime_stride`-th history position is hashed so a match can reach
/// across the block boundary (`§3.2.3`). Backward extension recovers a
/// repeat from any covered position inside it, so a stride above 1 keeps the
/// long matches while dividing the priming pass's cost.
const stream_prime_stride: usize = 1;

/// The 5-byte hash multiplier from klauspost/compress's level-1 encoder.
const prime5bytes: u64 = 889523592379;

/// Hash the low 5 bytes of `u` to a table index: the 5 bytes into the high 40
/// bits, multiply by the 40-bit prime, keep the top `table_bits`.
inline fn hash5(u: u64) usize {
    return @intCast(((u << 24) *% prime5bytes) >> (64 - table_bits));
}

/// 8 bytes of `source` at `pos`, little-endian. The caller keeps the 8-byte
/// margin.
inline fn load64(source: []const u8, pos: usize) u64 {
    return readInt(u64, source[pos..][0..8]);
}

/// 4 bytes of `source` at `pos`, little-endian — the match confirm.
inline fn load32(source: []const u8, pos: usize) u32 {
    return readInt(u32, source[pos..][0..4]);
}

/// The finder's window (`§3.2.3`): the preset dictionary's tail followed by
/// the stream's own bytes, one conceptual region — the byte after the
/// dictionary's last is `source[0]`, so a match can start in the dictionary
/// and continue at the output's start. Positions are window positions: the
/// dictionary occupies `[0, dict.len)` and `source[i]` sits at `dict.len + i`.
///
/// `preset` is comptime because a stream without a dictionary is the common
/// case: `Window(false)` is `source` alone, and its accessors compile to the
/// same loads as a bare `source` (no branch on `dict.len` in the finder's hot
/// loops).
fn Window(comptime preset: bool) type {
    return struct {
        const Self = @This();

        /// The dictionary's last `history_len` bytes (`dictHistory`); empty
        /// when the stream has no preset dictionary.
        dict: []const u8,
        /// The stream's own bytes, the window's tail.
        source: []const u8,

        /// The window position of `source[index]`.
        inline fn at(self: Self, index: usize) usize {
            return if (preset) self.dict.len + index else index;
        }

        /// The byte at window position `pos`.
        inline fn byte(self: Self, pos: usize) u8 {
            if (preset and pos < self.dict.len) return self.dict[pos];
            return self.source[if (preset) pos - self.dict.len else pos];
        }

        /// The window's bytes at `[start, end)`. Both positions are inside
        /// the stream's own region (`start >= dict.len`), so this is a plain
        /// `source` slice; the finder's blocks and literal runs are always
        /// there.
        inline fn sourceSlice(self: Self, start: usize, end: usize) []const u8 {
            const offset = if (preset) self.dict.len else 0;
            assert(start >= offset);
            assert(end >= start);
            assert(end <= offset + self.source.len);
            return self.source[start - offset .. end - offset];
        }

        /// The 4 bytes at window position `pos` (`§3.2.5`'s match confirm).
        /// Only a dictionary position can straddle the two regions, and then
        /// by at most 3 bytes.
        inline fn load32At(self: Self, pos: usize) u32 {
            if (preset and pos < self.dict.len) {
                if (pos + 4 <= self.dict.len) return load32(self.dict, pos);
                var bytes: [4]u8 = undefined;
                for (&bytes, 0..) |*byte_at, i| byte_at.* = self.byte(pos + i);
                return readInt(u32, &bytes);
            }
            return load32(self.source, if (preset) pos - self.dict.len else pos);
        }

        /// The 8 bytes at window position `pos`, little-endian: the match
        /// length's compare unit. `pos + 8` is inside the window (the
        /// callers' bounds hold), so the straddle is at most 7 bytes.
        inline fn load64At(self: Self, pos: usize) u64 {
            if (preset and pos < self.dict.len) {
                if (pos + 8 <= self.dict.len) return load64(self.dict, pos);
                var bytes: [8]u8 = undefined;
                for (&bytes, 0..) |*byte_at, i| byte_at.* = self.byte(pos + i);
                return readInt(u64, &bytes);
            }
            return load64(self.source, if (preset) pos - self.dict.len else pos);
        }

        /// The number of bytes `a..` and `b..` match, up to `limit` — all
        /// window positions. `b` is always in `source` (the scan runs there);
        /// `a` can start in the dictionary and cross into the source, where
        /// the dictionary's continuation is the source's start (the
        /// dictionary is conceptually in front of the output). Compares 8
        /// bytes at a time and uses `@ctz` on the first differing u64 to find
        /// the exact mismatch byte. The caller guarantees `a < b` and that
        /// `b < limit <= dict.len + source.len` (the 8-byte loop bounds `b`,
        /// and `a` trails it).
        fn matchLength(self: Self, a: usize, b: usize, limit: usize) usize {
            assert(a < b);
            var p = a;
            var q = b;
            while (q + 8 <= limit) {
                const diff = self.load64At(p) ^
                    load64(self.source, if (preset) q - self.dict.len else q);
                if (diff != 0) return p - a + (@ctz(diff) >> 3);
                p += 8;
                q += 8;
            }
            while (q < limit) : ({
                p += 1;
                q += 1;
            }) {
                if (self.byte(p) != self.source[if (preset) q - self.dict.len else q]) {
                    return p - a;
                }
            }
            return p - a;
        }

        /// The candidate's window position when the table entry names a legal
        /// match source with the 4 bytes at `s_at`, or null. Entries are
        /// absolute stream positions (wrapping u32, `base`-relative to the
        /// window's first byte; the caller passes `s_absolute = base +% s_at`).
        /// A legal source sits before `s` (a distance of at least 1), within
        /// `history_len` (`§3.2.5`), and not before the window's front. The
        /// wrapping subtraction makes a stale entry — one the window slid
        /// past, or a zero-initialized slot — fail the distance cap; a
        /// wrapped-around entry (a stream past 4 GiB) still lands in-window,
        /// where the 4-byte confirm decides. Either way no candidate outside
        /// the window is ever emitted.
        inline fn matchCandidate(
            self: Self,
            s_at: usize,
            s_absolute: u32,
            entry: u32,
            expect: u32,
            comptime windowed: bool,
        ) ?usize {
            const distance = s_absolute -% entry;
            // One unsigned check rejects both 0 (wrapping to max) and every
            // distance past the cap (`§3.2.5`).
            if (distance -% 1 >= history_len) return null;
            // A windowed caller (the streaming Writer) drops bytes from the
            // front, so an entry can name a position no longer in `source`;
            // the one-shot paths never drop, and every entry is a position
            // the scan already passed.
            if (windowed and distance > s_at) return null;
            const candidate = s_at - distance;
            if (self.load32At(candidate) != expect) return null; // the confirm
            return candidate;
        }

        /// Hash the window's `[window_start, block_start)` into `table`, every
        /// `stride` positions, so a match can reach across the block boundary
        /// (`§3.2.3`). Entries are absolute stream positions (`base` is the
        /// absolute position of the window's first byte), matching the scan's
        /// stores. The 8-byte load reads a few bytes past the hashed 5, so the
        /// loop stops where that load would leave the window.
        fn primeTable(
            self: Self,
            window_start: usize,
            block_start: usize,
            table: *FinderTable,
            base: u32,
            comptime stride: usize,
        ) void {
            var pos = window_start;
            const len = if (preset) self.dict.len + self.source.len else self.source.len;
            while (pos < block_start and pos + 8 <= len) : (pos += stride) {
                table[hash5(self.load64At(pos))] = base +% @as(u32, @truncate(pos));
            }
        }
    };
}

/// Minimum match length the finder emits: a 3-byte match costs a length symbol
/// and a distance symbol for three bytes, so the fast level starts at 4. The
/// format's shortest length is 3 (`§3.2.5`), which is what the emitter's
/// chunking and its assert use.
const min_match_len: usize = 4;

/// `§3.2.5` — the shortest codable match length: length code 257.
const min_length: usize = 3;

/// Trailing bytes a block reserves so the 8-byte loads and the 3-position hash
/// cascade stay in bounds (klauspost's `inputMargin`).
const input_margin: usize = 11;

/// Blocks below this size skip match finding entirely (klauspost's
/// `minNonLiteralBlockSize`): `input_margin` bytes cannot start a match, and a
/// match needs `min_match_len` bytes.
const min_match_block_size: usize = 1 + 1 + input_margin;

/// One Huffman code: its wire bits (the numeral's MSB first on the wire,
/// `§3.1.1`) and its length. `writeCode` consumes exactly this, so a numeral
/// cannot be passed where wire bits are expected.
pub const Code = struct { bits: u16, len: u5 };

/// The wire bits of a canonical code: `§3.2.2` assigns the numeral and
/// `§3.1.1` transmits its MSB first, so the low `len` bits of the result are
/// the code in transmission order. (decode.zig's `wireBits` is the decoder's
/// half of the same transform.)
pub fn wireBits(code: u16, len: u5) u16 {
    return @bitReverse(code) >> @intCast(16 - @as(u6, len));
}

/// `§3.2.6` — the fixed literal/length codes, from the numerals the RFC spells
/// out: 0-143 are 8 bits, `00110000` through `10111111`; 144-255 are 9 bits,
/// `110010000` through `111111111`; 256-279 are 7 bits, `0000000` through
/// `0010111`; 280-287 are 8 bits, `11000000` through `11000111`. Values 286-287
/// "will never actually occur in the compressed data, but participate in the
/// code construction", so they are part of the table.
pub const fixed_literal_codes: [288]Code = blk: {
    var codes: [288]Code = undefined;
    for (0..144) |i| codes[i] = .{ .bits = wireBits(@intCast(0x30 + i), 8), .len = 8 };
    for (144..256) |i| codes[i] = .{ .bits = wireBits(@intCast(0x190 + (i - 144)), 9), .len = 9 };
    for (256..280) |i| codes[i] = .{ .bits = wireBits(@intCast(i - 256), 7), .len = 7 };
    for (280..288) |i| codes[i] = .{ .bits = wireBits(@intCast(0xC0 + (i - 280)), 8), .len = 8 };
    break :blk codes;
};

/// `§3.2.6` — "Distance codes 0-31 are represented by (fixed-length) 5-bit
/// codes", so the numeral is the symbol. 30-31 never occur.
pub const fixed_distance_codes: [32]Code = blk: {
    var codes: [32]Code = undefined;
    for (&codes, 0..) |*code, i| code.* = .{ .bits = wireBits(@intCast(i), 5), .len = 5 };
    break :blk codes;
};

/// `§3.2.5` — the longest match a length symbol can declare, 258 (length
/// code 285). Aliased from `decode.zig`, the one spelling of the RFC's
/// length and distance tables.
pub const max_match_len = decode.max_match_len;
const length_base = decode.length_base;
const length_extra = decode.length_extra;
const distance_base = decode.distance_base;
const distance_extra = decode.distance_extra;

/// A length symbol ready to emit: the merged-alphabet symbol (257-285), its
/// extra-bit count, and the extra-bit value.
pub const LengthSymbol = struct { symbol: u16, extra_bits: u5, extra_value: u16 };

/// `§3.2.5` — length -> its symbol and extra bits, derived at comptime from the
/// base/extra table above. Index = the length (3-258); 0-2 are unused. Code
/// 284's entry covers 227-258 by the table's own arithmetic, and code 285
/// overwrites 258 with zero extra bits, which is what the encoder emits: 258
/// is code 285, the one code with no extra bits.
const length_symbols: [max_match_len + 1]LengthSymbol = blk: {
    var table: [max_match_len + 1]LengthSymbol = undefined;
    for (length_base, length_extra, 0..) |base, extra, i| {
        const span = @as(usize, 1) << extra;
        for (@as(usize, base)..@as(usize, base) + span) |length| {
            table[length] = .{
                .symbol = @intCast(257 + i),
                .extra_bits = extra,
                .extra_value = @intCast(length - base),
            };
        }
    }
    break :blk table;
};

/// `§3.2.5` — distance -> its code, derived at comptime from the base/extra
/// table above. Distances are 1-32768, so index 0 is unused.
const distance_codes: [history_len + 1]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var table: [history_len + 1]u8 = undefined;
    for (distance_base, distance_extra, 0..) |base, extra, i| {
        const span = @as(usize, 1) << extra;
        for (@as(usize, base)..@as(usize, base) + span) |distance| {
            table[distance] = @intCast(i);
        }
    }
    break :blk table;
};

/// `§3.2.5` — the length symbol for `length` (3-258): the merged-alphabet
/// symbol, its extra-bit count, and the extra-bit value. Code 284's entry
/// covers 227-258 by the table's own arithmetic, and code 285 overwrites 258
/// with zero extra bits, which is what the encoder emits: 258 is code 285,
/// the one code with no extra bits.
pub fn lengthSymbol(length: usize) LengthSymbol {
    assert(length >= min_length);
    assert(length <= max_match_len);
    return length_symbols[length];
}

/// A distance symbol with its extra bits.
pub const DistanceSymbol = struct { symbol: u8, extra_bits: u5, extra: u16 };

/// `§3.2.5` — the distance symbol for `distance` (1-32768) and its extra bits.
pub fn distanceSymbol(distance: usize) DistanceSymbol {
    assert(distance >= 1);
    assert(distance <= history_len);
    const symbol = distance_codes[distance];
    return .{
        .symbol = symbol,
        .extra_bits = distance_extra[symbol],
        .extra = @intCast(distance - distance_base[symbol]),
    };
}

/// The bit writer (`§3.1.1`): bits fill a byte from bit 0 up, and a 9th bit
/// spills into bit 0 of the next byte. `bits`/`bit_count` carry the stream's
/// pending partial byte, which is what lets the streaming `Writer` emit one
/// block at a time: a block's bits continue at the previous block's bit
/// offset.
///
/// It has exactly two write operations, named for the packing rule each
/// implements: `writeBits` for a non-Huffman data element (LSB-of-value first:
/// block headers, extra bits, stored LEN/NLEN) and `writeCode` for a Huffman
/// code (MSB-of-code first; the code tables store the wire bits pre-reversed).
/// Mixing them up can survive a round trip through this package's decoder if both
/// sides share the mistake, but every other decoder misreads the stream, which
/// is why `just flate-oracle` decodes the encoder's output with python3's `zlib`.
pub const BitWriter = struct {
    target: []u8,
    /// Whole bytes written into `target`.
    pos: usize = 0,
    /// Pending bits, LSB first: bit 0 is the next bit on the wire.
    bits: u64 = 0,
    /// Valid bits in `bits` (0-63, and below 8 outside `writeBits`).
    bit_count: u6 = 0,

    /// A block's start, so a block that bails to stored can be rewound.
    const Snapshot = struct { pos: usize, bits: u64, bit_count: u6 };

    /// The stream's bit position: `pos` bytes are flushed, `bit_count` bits are
    /// pending.
    fn bitsWritten(self: *const BitWriter) u64 {
        return @as(u64, self.pos) * 8 + self.bit_count;
    }

    fn snapshot(self: *const BitWriter) Snapshot {
        return .{ .pos = self.pos, .bits = self.bits, .bit_count = self.bit_count };
    }

    fn restore(self: *BitWriter, snap: Snapshot) void {
        self.pos = snap.pos;
        self.bits = snap.bits;
        self.bit_count = snap.bit_count;
    }

    /// Write a data element that is not a Huffman code, LSB-of-value first
    /// (`§3.1.1`): the block header, extra bits, stored LEN/NLEN. Extra bits
    /// are an ordinary element, so they go out LSB first; `§3.2.5`'s
    /// "most-significant bit first" sentence describes the numeral.
    pub fn writeBits(self: *BitWriter, value: u32, n: u5) error{BufferTooSmall}!void {
        assert(n <= 32);
        assert(n == 32 or value >> n == 0);
        assert(self.bit_count < 8);
        self.bits |= @as(u64, value) << self.bit_count;
        self.bit_count += n;
        try self.flushBytes();
    }

    /// Write a Huffman code, MSB-of-code first (`§3.1.1`). `code` carries the
    /// wire bits (see `wireBits`), never the numeral.
    pub fn writeCode(self: *BitWriter, code: Code) error{BufferTooSmall}!void {
        self.bits |= @as(u64, code.bits) << self.bit_count;
        self.bit_count += code.len;
        try self.flushBytes();
    }

    /// Flush whole bytes into `target`. `error.BufferTooSmall` when the target
    /// is exhausted, which cannot happen when `target` is sized with
    /// `maxCompressedLength`.
    fn flushBytes(self: *BitWriter) error{BufferTooSmall}!void {
        while (self.bit_count >= 8) {
            if (self.pos == self.target.len) return error.BufferTooSmall;
            self.target[self.pos] = @truncate(self.bits);
            self.pos += 1;
            self.bits >>= 8;
            self.bit_count -= 8;
        }
    }

    /// Pad with zero bits to the next byte boundary (`§3.2.4`: a stored block
    /// ignores the bits up to the boundary; a decoder must not require them to
    /// be zero).
    fn alignToByte(self: *BitWriter) error{BufferTooSmall}!void {
        const pad: u4 = @intCast((8 - self.bitsWritten() % 8) % 8);
        if (pad != 0) try self.writeBits(0, pad);
    }

    /// Flush the final partial byte, padded with zero bits.
    pub fn finish(self: *BitWriter) error{BufferTooSmall}!void {
        if (self.bit_count == 0) return;
        if (self.pos == self.target.len) return error.BufferTooSmall;
        self.target[self.pos] = @truncate(self.bits);
        self.pos += 1;
        self.bits = 0;
        self.bit_count = 0;
    }
};

/// Emit `literal` as fixed-Huffman literal codes. Returns false when the
/// payload would reach the stored form's payload (`§3.2.4`'s 32 + 8 x len
/// bits), at which point the caller stores the block instead.
///
/// The check runs before the write, so a bailing block has never written past
/// the stored form's own bytes.
fn emitLiterals(
    literal: []const u8,
    w: *BitWriter,
    payload: *u64,
    payload_limit: u64,
) error{BufferTooSmall}!bool {
    for (literal) |byte| {
        const code = fixed_literal_codes[byte];
        if (payload.* + code.len >= payload_limit) return false;
        payload.* += code.len;
        try w.writeCode(code);
    }
    return true;
}

/// Emit one match as a `§3.2.5` length symbol and distance symbol, each with
/// its extra bits (LSB-of-value first). Lengths above 258 split into chunks:
/// the last chunk drops to 255 when a 258 would leave a 1- or 2-byte tail,
/// which cannot be coded (the shortest length symbol is 3). Returns false on
/// the stored-form threshold, as `emitLiterals`.
fn emitMatch(
    w: *BitWriter,
    distance: usize,
    length: usize,
    payload: *u64,
    payload_limit: u64,
) error{BufferTooSmall}!bool {
    assert(distance >= 1);
    assert(distance <= history_len);
    assert(length >= min_length);

    const d = distanceSymbol(distance);
    const distance_code = fixed_distance_codes[d.symbol];
    var remaining = length;
    while (true) {
        const chunk = if (remaining > max_match_len and remaining - max_match_len < min_length)
            255
        else
            @min(remaining, max_match_len);
        const l = length_symbols[chunk];
        const length_code = fixed_literal_codes[l.symbol];
        const cost = @as(u64, length_code.len) + l.extra_bits +
            distance_code.len + d.extra_bits;
        if (payload.* + cost >= payload_limit) return false;
        payload.* += cost;

        try w.writeCode(length_code);
        try w.writeBits(l.extra_value, l.extra_bits);
        try w.writeCode(distance_code);
        try w.writeBits(d.extra, d.extra_bits);

        remaining -= chunk;
        if (remaining == 0) return true;
    }
}

/// `§3.2.4` — emit `block` (at most `max_block_size` bytes) as a stored block:
/// BFINAL clear and BTYPE=00, then skip to the next byte boundary, then LEN and
/// NLEN (u16 little-endian, NLEN the one's complement of LEN) and LEN raw bytes.
/// `error.BufferTooSmall` if the target cannot hold it. This is the fallback
/// that makes `maxCompressedLength` provable: no block ever exceeds its stored
/// form.
pub fn emitStoredBlock(w: *BitWriter, block: []const u8) error{BufferTooSmall}!void {
    assert(block.len <= max_block_size);
    try w.writeBits(0, 1); // BFINAL clear: the final empty block ends the stream
    try w.writeBits(0, 2); // BTYPE = 00, stored
    try w.alignToByte();
    const len: u16 = @intCast(block.len);
    try w.writeBits(len, 16);
    try w.writeBits(~len, 16);
    // Byte-aligned after LEN/NLEN: the payload is a straight copy.
    assert(w.bit_count == 0);
    if (w.target.len - w.pos < block.len) return error.BufferTooSmall;
    fastmem.copy(u8, w.target[w.pos..][0..block.len], block);
    w.pos += block.len;
}

/// Encode one block's payload as fixed-Huffman symbols, greedily. Returns
/// false when the payload reached the stored form's payload (`§3.2.4`'s
/// 32 + 8 x len bits); the caller rewinds and stores the block.
///
/// The scan cascade is the klauspost `fastEncL1` shape: hash three positions
/// per step, confirm 4 bytes, extend backwards over the literals already
/// scanned and forwards to the block's end, and accelerate the skip as the
/// distance since the last emit grows.
///
/// `window` is the finder's window (`Window`): this block's history followed
/// by the block itself, so matches cross block boundaries exactly as the
/// format allows (`§3.2.3`) — and, with a preset dictionary, reach into the
/// dictionary in front of it. `block_start` and `block_end` are `source`
/// indices; the scan converts to window positions. `table` is the caller's
/// (see `FinderTable`): the streaming `Writer` and the one-shot `compress`
/// persist one table across the stream's blocks, so the per-block cost is the
/// history prime alone, never a 128-KiB re-zero. `base` is the absolute
/// stream position of the window's first byte.
fn encodeFixedBlock(
    comptime preset: bool,
    window: Window(preset),
    block_start: usize,
    block_end: usize,
    w: *BitWriter,
    table: *FinderTable,
    base: u32,
    comptime prime_stride: usize,
    comptime windowed: bool,
) error{BufferTooSmall}!bool {
    const block_len = block_end - block_start;
    // §3.2.4 — the stored alternative's payload is 32 + 8 x len bits; a block
    // is emitted fixed only while its payload stays below that. The
    // end-of-block symbol is part of the payload and is always emitted last,
    // so its 7 bits are reserved up front.
    const payload_limit: u64 = @as(u64, block_len) * 8 + 32;
    var payload: u64 = fixed_literal_codes[256].len;

    // The finder's window: the block's history followed by the block itself.
    // A block too small to scan needs no priming either: its bytes are all
    // literals, and its own history range is primed afresh by the next
    // scanning block.
    const window_start = window.at(block_start) - @min(window.at(block_start), history_len);

    var next_emit = block_start;
    var s = block_start;
    if (block_len >= min_match_block_size) {
        if (prime_stride != 0) {
            window.primeTable(window_start, window.at(block_start), table, base, prime_stride);
        }
        // Stop scanning this far from the end so the 8-byte loads and the
        // 3-position cascade stay in bounds; the tail becomes literals.
        const s_limit = block_end - input_margin;
        var cv = load64(window.source, s);

        scan: while (true) {
            var candidate: usize = 0;
            // Inner scan: three hash slots per step until a 4-byte confirm.
            inner: while (true) {
                const s_at = window.at(s);
                const s_absolute = base +% @as(u32, @truncate(s_at));
                const h0 = hash5(cv);
                const h1 = hash5(cv >> 8);
                const h2 = hash5(cv >> 16);
                const e0 = table[h0];
                table[h0] = s_absolute;
                const e1 = table[h1];
                table[h1] = s_absolute +% 1;
                const e2 = table[h2];
                table[h2] = s_absolute +% 2;

                if (window.matchCandidate(s_at, s_absolute, e0, @truncate(cv), windowed)) |c| {
                    candidate = c;
                    break :inner;
                }
                const hit1 = window.matchCandidate(
                    window.at(s + 1),
                    s_absolute +% 1,
                    e1,
                    @truncate(cv >> 8),
                    windowed,
                );
                if (hit1) |c| {
                    candidate = c;
                    s += 1;
                    break :inner;
                }
                const hit2 = window.matchCandidate(
                    window.at(s + 2),
                    s_absolute +% 2,
                    e2,
                    @truncate(cv >> 16),
                    windowed,
                );
                if (hit2) |c| {
                    candidate = c;
                    s += 2;
                    break :inner;
                }

                // No match here: accelerate the skip with the distance since
                // the last emit, so incompressible regions are crossed fast.
                const next_s = s + 3 + ((s - next_emit) >> 5);
                if (next_s > s_limit) break :scan;
                cv = load64(window.source, next_s);
                s = next_s;
            }

            // Backward extension: the match may start before the hash hit,
            // over the literals already scanned, shrinking the literal run.
            // The candidate may sit in the dictionary, where the byte before
            // it is the dictionary's.
            while (s > next_emit and candidate > window_start and
                window.byte(candidate - 1) == window.source[s - 1])
            {
                s -= 1;
                candidate -= 1;
            }

            if (!try emitLiterals(window.source[next_emit..s], w, &payload, payload_limit)) {
                return false;
            }

            // The match, extended greedily to the block's end: a match may
            // never run past it, or the next block would emit the same bytes
            // again. A candidate in the dictionary extends through its tail
            // and then at the output's start, exactly as the decoder's copy
            // does.
            const length = min_match_len +
                window.matchLength(
                    candidate + min_match_len,
                    window.at(s) + min_match_len,
                    window.at(block_end),
                );
            if (!try emitMatch(
                w,
                window.at(s) - candidate,
                length,
                &payload,
                payload_limit,
            )) return false;
            s += length;
            next_emit = s;

            if (s > s_limit) break :scan;
            cv = load64(window.source, s);
        }
    }

    // The trailing bytes (and, for a block below the match-finding threshold,
    // the whole block) are literals.
    if (!try emitLiterals(window.source[next_emit..block_end], w, &payload, payload_limit)) {
        return false;
    }

    // §3.2.7 — every block is terminated by the end-of-block symbol 256.
    try w.writeCode(fixed_literal_codes[256]);
    return true;
}

/// `§3.2.3` — the final empty fixed block every stream ends with: BFINAL=1,
/// BTYPE=01, end-of-block (`03 00` at a byte boundary). One function, so the
/// one-shot and streaming encoders cannot drift. No data block carries BFINAL,
/// which is what makes a mid-stream `flush` safe.
pub fn writeFinalEmptyBlock(w: *BitWriter) error{BufferTooSmall}!void {
    try w.writeBits(1, 1);
    try w.writeBits(1, 2);
    try w.writeCode(fixed_literal_codes[256]);
}

/// Encode `source[block_start..block_end]` as one block (fixed Huffman, or
/// stored when that is smaller) through `w`, for the streaming `Writer`. A
/// match can reach back into `source[0..block_start]`, up to 32768 bytes.
/// `table` is the `Writer`'s: zeroed once per stream and reused across blocks.
/// `base` is the absolute stream position of `source[0]` (the `Writer`'s window
/// base). Returns `error.BufferTooSmall` if `w`'s target cannot hold the block.
pub fn compressBlockStream(
    source: []const u8,
    block_start: usize,
    block_end: usize,
    w: *BitWriter,
    table: *FinderTable,
    base: u32,
) error{BufferTooSmall}!void {
    try compressBlockStateful(
        false,
        .{ .dict = &.{}, .source = source },
        block_start,
        block_end,
        w,
        table,
        base,
        stream_prime_stride,
        true,
    );
}

/// The block-at-a-time encode over a caller-managed finder table: the shared
/// entry behind the one-shot `compress` and the streaming `Writer`
/// (`compressBlockStream`). `window` is the finder's window (`Window`), with
/// the block at `source[block_start..block_end]`; `base` is the absolute
/// stream position of the window's first byte; entries older than the window
/// fail the distance cap, so the table needs no clearing between blocks.
fn compressBlockStateful(
    comptime preset: bool,
    window: Window(preset),
    block_start: usize,
    block_end: usize,
    w: *BitWriter,
    table: *FinderTable,
    base: u32,
    comptime prime_stride: usize,
    comptime windowed: bool,
) error{BufferTooSmall}!void {
    const start = w.snapshot();

    // §3.2.3 — BFINAL is clear on every data block: the stream ends with a
    // final empty fixed block. BTYPE = 01, whose two bits go out
    // LSB-of-value first.
    try w.writeBits(0, 1);
    try w.writeBits(1, 2);

    if (!try encodeFixedBlock(
        preset,
        window,
        block_start,
        block_end,
        w,
        table,
        base,
        prime_stride,
        windowed,
    )) {
        // The fixed payload did not beat the stored form: rewind the block's
        // bits and store it. Storing fits wherever the fixed attempt did —
        // `maxCompressedLength` reserves 5 bytes per block plus the ending.
        w.restore(start);
        try emitStoredBlock(w, window.source[block_start..block_end]);
    }
}

// ---------------------------------------------------------------------------
// Level 6: klauspost/compress's `fastEncL6` finder and its block pipeline.
// The scan and its two tables are a faithful port of `flate/level6.go`
// (attribution in THIRD_PARTY.md); the token list, the trees, and the block
// dispatch are in dynamic.zig. Byte-identity with the reference is the
// contract (`src/flate/README.md`), so the arithmetic below — including the
// "empty table entry" rejection — mirrors theirs, not the level-1 port's
// wrapping-position scheme.
// ---------------------------------------------------------------------------

/// klauspost's level-6 `inputMargin` (`12 - 1`): the scan stops this far
/// from the block's end so its 8-byte loads stay in bounds.
const input_margin_6: usize = 12 - 1;

/// klauspost's `minNonLiteralBlockSize` for level 6: below this the whole
/// block is literals, and the finder sets the token count to the block
/// length (which sends it to the literals-only block form).
const min_non_literal_block_size_6: usize = 1 + 1 + input_margin_6;

/// The scan's skip acceleration: `next_s = s + 1 + (s - next_emit) >> 7`.
const skip_log_6: u6 = 7;

/// klauspost's 4-byte hash multiplier (`hashLen(..., 4)`).
const prime4bytes: u32 = 2654435761;

/// klauspost's 7-byte hash multiplier.
const prime7bytes: u64 = 58295818150454627;

/// The finder's long-table entry: the two most recent positions with a
/// hash, as absolute stream positions (wrapping u32).
const EntryPrev = struct { cur: u32 = 0, prev: u32 = 0 };

/// The level-6 finder's tables (klauspost's `fastEncL6` pair): a 4-byte-hash
/// table and a 7-byte-hash table with two candidates per slot. 384 KiB,
/// zeroed once per stream.
pub const Finder6 = struct {
    table: [table_size]u32,
    b_table: [table_size]EntryPrev,

    /// Zero the tables. An entry of 0 names a position before the window
    /// (`finder_origin` is above the distance cap), so a cleared slot never
    /// yields a candidate — the sentinel the scan relies on.
    pub fn clear(self: *Finder6) void {
        fastmem.set(u32, &self.table, 0);
        fastmem.set(EntryPrev, &self.b_table, .{});
    }
};

/// The finder's absolute-position origin: klauspost starts `cur` at
/// `maxStoreBlockSize`, so a zero-initialized slot is out of reach of the
/// distance cap and can never be a candidate.
pub const finder_origin: u32 = 65535;

/// The 4-byte hash into the 15-bit table: klauspost's `hashLen(u, 15, 4)`.
inline fn hash4(u: u64) usize {
    return @intCast((@as(u32, @truncate(u)) *% prime4bytes) >> (32 - table_bits));
}

/// The 7-byte hash into the 15-bit table: klauspost's `hash7(u, 15)`.
inline fn hash7(u: u64) usize {
    return @intCast(((u << 8) *% prime7bytes) >> (64 - table_bits));
}

/// The 15-bit tables' hash mask, as the distance cap: klauspost's
/// `maxMatchOffset`.
const max_match_offset_6: i32 = 1 << 15;

/// A table entry's window position when it names a position the scan may
/// read at `s` — klauspost's `t = entry - cur; s - t < maxMatchOffset` gate,
/// made total. A cleared entry, an entry the window has slid past, and an
/// entry at or ahead of `s` all return null; the reference relies on the
/// first two being cleared by its buffer rebase and the third being
/// unreachable, and this port's checks accept exactly the same candidates.
inline fn candidateAt(entry: u32, s_abs: u32, s_at: usize, base: u32) ?usize {
    const distance: i32 = @bitCast(s_abs -% entry);
    if (distance < 1 or distance >= max_match_offset_6) return null;
    const t_at: usize = entry -% base;
    if (t_at >= s_at) return null;
    return t_at;
}

/// klauspost's `matchlen`: the match length between `s` and `t` (window
/// positions, `t < s`), capped at `max_match_len - 4` — the caller adds the
/// four confirmed bytes back. `limit` is the block's end position.
inline fn matchLen6(
    comptime preset: bool,
    window: Window(preset),
    s: usize,
    t: usize,
    limit: usize,
) usize {
    const s1 = @min(s + (max_match_len - 4), limit);
    return window.matchLength(t, s, s1);
}

/// klauspost's `matchlenLong`: the match length between `s` and `t`, extended
/// as far as the block allows.
inline fn matchLenLong6(
    comptime preset: bool,
    window: Window(preset),
    s: usize,
    t: usize,
    limit: usize,
) usize {
    return window.matchLength(t, s, limit);
}

/// Store `next_s` (and nothing else) in both tables: klauspost's
/// `e.table[nextHashS] = nextS; e.bTable[nextHashL] = {nextS, old cur}`.
inline fn storeAhead(
    finder: *Finder6,
    next_hash_s: usize,
    next_hash_l: usize,
    next_s: usize,
    base: u32,
) void {
    const entry: u32 = base +% @as(u32, @truncate(next_s));
    finder.table[next_hash_s] = entry;
    const slot = &finder.b_table[next_hash_l];
    // The old cur is read before the store: Zig lowers a struct-literal
    // assignment field-wise, so `slot.cur` inside the literal would already
    // be the new value.
    const prev = slot.cur;
    slot.* = .{ .cur = entry, .prev = prev };
}

/// The level-6 scan (klauspost's `fastEncL6.Encode`): fill `tokens` with the
/// block's literals and matches and leave both tables holding the block's
/// positions. `window` is the finder's window (history followed by the
/// block, `§3.2.3`), `block_start`/`block_end` are window positions, and
/// `base` is the absolute stream position of the window's first byte.
///
/// The labeled control flow is the reference's scan cascade, kept whole in
/// the parent for the same reason as the level-1 scan (`src/flate/AGENTS.md`,
/// Deviations): the pure logic is already extracted (`candidateAt`,
/// `matchLen6`, `matchLenLong6`, `storeAhead`).
fn encodeTokens6(
    comptime preset: bool,
    window: Window(preset),
    block_start: usize,
    block_end: usize,
    tokens: *dynamic.TokenList,
    finder: *Finder6,
    base: u32,
) void {
    const block_len = block_end - block_start;
    if (block_len < min_non_literal_block_size_6) {
        // The reference's marker: the count is the block length, and the
        // token array stays untouched. Only `compressBlock6` reads it, and it
        // handles this case before calling here; the dictionary priming
        // discards the list.
        tokens.n = @intCast(block_len);
        return;
    }
    var next_emit = block_start;
    var s = block_start;
    const s_limit = block_end - input_margin_6;
    var cv = window.load64At(s);
    var repeat: usize = 1;

    scan: while (true) {
        var next_s = s;
        var l: usize = 0;
        var t: usize = 0;
        inner: while (true) {
            const next_hash_s = hash4(cv);
            const next_hash_l = hash7(cv);
            s = next_s;
            next_s = s + 1 + ((s - next_emit) >> skip_log_6);
            if (next_s > s_limit) break :scan;
            const s_candidate = finder.table[next_hash_s];
            const l_candidate = finder.b_table[next_hash_l];
            const next = window.load64At(next_s);
            const s_abs = base +% @as(u32, @truncate(s));
            finder.table[next_hash_s] = s_abs;
            finder.b_table[next_hash_l] = .{ .cur = s_abs, .prev = l_candidate.cur };
            const next_hash_s_next = hash4(next);
            const next_hash_l_next = hash7(next);
            const cv32: u32 = @truncate(cv);
            const next32: u32 = @truncate(next);

            // The long table's current entry.
            if (candidateAt(l_candidate.cur, s_abs, s, base)) |tc| {
                t = tc;
                if (cv32 == window.load32At(tc)) {
                    // The long candidate confirms four bytes.
                    storeAhead(finder, next_hash_s_next, next_hash_l_next, next_s, base);
                    if (candidateAt(l_candidate.prev, s_abs, s, base)) |t2| {
                        if (cv32 == window.load32At(t2)) {
                            l = matchLen6(preset, window, s + 4, tc + 4, block_end) + 4;
                            const ml1 = matchLen6(preset, window, s + 4, t2 + 4, block_end) + 4;
                            if (ml1 > l) {
                                t = t2;
                                l = ml1;
                            }
                        }
                    }
                    break :inner;
                }
                // The current entry missed; the previous one may still hit.
                if (candidateAt(l_candidate.prev, s_abs, s, base)) |t2| {
                    if (cv32 == window.load32At(t2)) {
                        storeAhead(finder, next_hash_s_next, next_hash_l_next, next_s, base);
                        t = t2;
                        break :inner;
                    }
                }
            }

            // The short table's entry.
            if (candidateAt(s_candidate, s_abs, s, base)) |tc| {
                if (cv32 == window.load32At(tc)) {
                    t = tc;
                    l = matchLen6(preset, window, s + 4, tc + 4, block_end) + 4;
                    const next_candidate = finder.b_table[next_hash_l_next];
                    storeAhead(finder, next_hash_s_next, next_hash_l_next, next_s, base);
                    // The previous match's distance, checked at s+1.
                    const t2 = s - repeat + 1;
                    if (@as(u32, @truncate(cv >> 8)) == window.load32At(t2)) {
                        const ml = matchLen6(preset, window, s + 5, t2 + 4, block_end) + 4;
                        if (ml > l) {
                            t = t2;
                            l = ml;
                            s += 1;
                            break :inner;
                        }
                    }
                    // The long table's two entries at the next position.
                    const next_abs = base +% @as(u32, @truncate(next_s));
                    if (candidateAt(next_candidate.cur, next_abs, next_s, base)) |tn| {
                        if (next32 == window.load32At(tn)) {
                            const ml = matchLen6(preset, window, next_s + 4, tn + 4, block_end) + 4;
                            if (ml > l) {
                                t = tn;
                                s = next_s;
                                l = ml;
                            }
                        }
                        if (candidateAt(next_candidate.prev, next_abs, next_s, base)) |tn2| {
                            if (next32 == window.load32At(tn2)) {
                                const ml = matchLen6(
                                    preset,
                                    window,
                                    next_s + 4,
                                    tn2 + 4,
                                    block_end,
                                ) + 4;
                                if (ml > l) {
                                    t = tn2;
                                    s = next_s;
                                    l = ml;
                                    break :inner;
                                }
                            }
                        }
                    }
                    break :inner;
                }
            }
            cv = next;
        }

        // Extend the match: a confirmed four bytes when no length was
        // computed, or a 258-cap match that may run on.
        if (l == 0) {
            l = matchLenLong6(preset, window, s + 4, t + 4, block_end) + 4;
        } else if (l == max_match_len) {
            l += matchLenLong6(preset, window, s + l, t + l, block_end);
        }

        // Try to locate a better match by checking the end of the match: the
        // long table may hold a candidate whose first bytes mismatch but
        // whose tail runs on. The skipped bytes are recovered by the
        // backward extension below.
        if (s + l < s_limit) {
            const skip_beginning = 2;
            const slot = &finder.b_table[hash7(window.load64At(s + l))];
            const s2 = s + skip_beginning;
            const s2_i: i32 = @intCast(s2);
            var t2: i32 = @as(i32, @bitCast(slot.cur -% base)) -%
                @as(i32, @intCast(l)) +% skip_beginning;
            if (s2_i -% t2 < max_match_offset_6) {
                if (t2 >= 0 and t2 < s2_i) {
                    const l2 = matchLenLong6(preset, window, s2, @intCast(t2), block_end);
                    if (l2 > l) {
                        t = @intCast(t2);
                        l = l2;
                        s = s2;
                    }
                }
                // The previous candidate's offset is measured against the
                // possibly updated `l`: the reference reads the current value.
                t2 = @as(i32, @bitCast(slot.prev -% base)) -%
                    @as(i32, @intCast(l)) +% skip_beginning;
                if (t2 >= 0 and t2 < s2_i and s2_i -% t2 < max_match_offset_6) {
                    const l2 = matchLenLong6(preset, window, s2, @intCast(t2), block_end);
                    if (l2 > l) {
                        t = @intCast(t2);
                        l = l2;
                        s = s2;
                    }
                }
            }
        }

        // Extend backwards over the literals already scanned.
        while (t > 0 and s > next_emit and window.byte(t - 1) == window.byte(s - 1)) {
            s -= 1;
            t -= 1;
            l += 1;
        }
        if (next_emit < s) tokens.addLiterals(window.sourceSlice(next_emit, s));
        tokens.addMatchLong(l, s - t);
        repeat = s - t;
        s += l;
        next_emit = s;
        if (next_s >= s) s = next_s + 1;

        if (s >= s_limit) {
            // Index the positions after the match that the scan will never
            // visit: every second one, both tables.
            var i = next_s + 1;
            while (i + 8 < block_end) : (i += 2) {
                const ahead = window.load64At(i);
                const entry: u32 = base +% @as(u32, @truncate(i));
                finder.table[hash4(ahead)] = entry;
                const slot = &finder.b_table[hash7(ahead)];
                const prev = slot.cur;
                slot.* = .{ .cur = entry, .prev = prev };
            }
            break :scan;
        }

        // Store every second position in between, both tables, plus the
        // long entry one past it.
        var i = next_s + 1;
        while (i + 1 < s) : (i += 2) {
            const ahead = window.load64At(i);
            const entry: u32 = base +% @as(u32, @truncate(i));
            finder.table[hash4(ahead)] = entry;
            const slot = &finder.b_table[hash7(ahead)];
            const prev = slot.cur;
            slot.* = .{ .cur = entry, .prev = prev };
            const slot2 = &finder.b_table[hash7(ahead >> 8)];
            const prev2 = slot2.cur;
            slot2.* = .{ .cur = entry +% 1, .prev = prev2 };
        }
        cv = window.load64At(s);
    }

    // The trailing bytes are literals; a block that found nothing at all is
    // left with no tokens, which sends it to the stored form.
    if (next_emit < block_end) {
        if (tokens.n == 0) return;
        tokens.addLiterals(window.sourceSlice(next_emit, block_end));
    }
}

/// One level-6 block: the finder fills `tokens`, then the dispatch picks
/// stored, fixed, or dynamic (`dynamic.writeBlockFast`). `sync` marks the
/// stream's final block, whose emission differs (the end-of-block code is
/// written inline and no table is left open); a final block under 128 bytes
/// takes klauspost's tiny-block path: stored at 32 bytes or below,
/// literals-only above.
fn compressBlock6(
    comptime preset: bool,
    window: Window(preset),
    block_start: usize,
    block_end: usize,
    w: *BitWriter,
    tokens: *dynamic.TokenList,
    finder: *Finder6,
    emitter: *dynamic.BlockWriter,
    base: u32,
    sync: bool,
) error{BufferTooSmall}!void {
    const block_len = block_end - block_start;
    const block = window.sourceSlice(block_start, block_end);
    if (sync and block_len < 128) {
        if (block_len == 0) return;
        if (block_len <= 32) return emitter.writeStored(w, block);
        return emitter.writeBlockHuff(w, block, true);
    }
    // A block too small to scan has no matches: klauspost's finder marks it
    // by setting the token count, which only its own `storeFast` reads back
    // (and only at close, where blocks under 128 bytes are handled above).
    // Our streaming `flush` and `rebase` can emit such a block mid-stream, so
    // the stored form is chosen here instead.
    if (block_len < min_non_literal_block_size_6) return emitter.writeStored(w, block);
    tokens.reset();
    encodeTokens6(preset, window, block_start, block_end, tokens, finder, base);
    return emitter.writeBlockFast(w, tokens, block, sync);
}

/// The level-6 one-shot block loop: split `source` at `max_block_size`, run
/// the finder over each block, and end with the final empty fixed block —
/// the block boundaries and closing bytes klauspost's `NewWriter(w, 6)` +
/// `Write` + `Close` produce. A full final block is emitted mid-stream
/// (`sync` false), exactly as the reference's window fill does; only a
/// partial tail is the stream's final block.
fn compressBlocks6(
    comptime preset: bool,
    window: Window(preset),
    source: []const u8,
    target: []u8,
) error{BufferTooSmall}!usize {
    const base = finder_origin;
    var w: BitWriter = .{ .target = target };
    var finder: Finder6 = undefined;
    finder.clear();
    var emitter: dynamic.BlockWriter = .{};
    var tokens: dynamic.TokenList = .{};
    if (preset) {
        // The dictionary seeds the tables exactly as klauspost's
        // `fillWindow` does: a full scan over its tail, tokens discarded.
        // The scan sees the dictionary itself as the window's stream, so the
        // positions it stores (0..dict.len) are the window positions the
        // block scans use.
        const dict_window: Window(false) = .{ .dict = &.{}, .source = window.dict };
        encodeTokens6(false, dict_window, 0, window.dict.len, &tokens, &finder, base);
        tokens.reset();
    }
    var block_start: usize = 0;
    // A full block is emitted mid-stream only while input follows it: the
    // stream's last block — full or partial — is the final one (`sync`),
    // exactly as klauspost's `Write` and `Close` split them (their window
    // flush runs only when the next fill has data, so an exactly-full input
    // reaches `Close` and is processed with `sync`).
    while (source.len - block_start > max_block_size) {
        try compressBlock6(
            preset,
            window,
            window.at(block_start),
            window.at(block_start + max_block_size),
            &w,
            &tokens,
            &finder,
            &emitter,
            base,
            false,
        );
        block_start += max_block_size;
    }
    if (block_start < source.len) {
        try compressBlock6(
            preset,
            window,
            window.at(block_start),
            window.at(source.len),
            &w,
            &tokens,
            &finder,
            &emitter,
            base,
            true,
        );
    }
    // A final block that was exactly full was emitted mid-stream, so its
    // end-of-block code is still owed: the ending flushes it first, exactly
    // where klauspost's `close` reaches it through `writeStoredHeader(0,
    // true)`.
    try emitter.flushEob(&w);
    try writeFinalEmptyBlock(&w);
    try w.finish();
    assert(w.pos <= maxCompressedLength(source.len));
    return w.pos;
}

/// The streaming level-6 block encode for the `Writer`: `source` is the
/// window (history followed by the block), `block_start`/`block_end` are
/// window positions, and `base` is the absolute stream position of
/// `source[0]`. `prime_dict` is true on a stream's first block when the
/// window's front is a preset dictionary: the tables are seeded by the same
/// scan klauspost's `fillWindow` runs over the dictionary's tail.
///
/// Returns `error.BufferTooSmall` if `w`'s target cannot hold the block.
pub fn compressBlockStream6(
    source: []const u8,
    block_start: usize,
    block_end: usize,
    w: *BitWriter,
    finder: *Finder6,
    emitter: *dynamic.BlockWriter,
    base: u32,
    prime_dict: bool,
    sync: bool,
) error{BufferTooSmall}!void {
    const window: Window(false) = .{ .dict = &.{}, .source = source };
    var tokens: dynamic.TokenList = .{};
    if (prime_dict) {
        encodeTokens6(false, window, 0, block_start, &tokens, finder, base);
        tokens.reset();
    }
    try compressBlock6(
        false,
        window,
        block_start,
        block_end,
        w,
        &tokens,
        finder,
        emitter,
        base,
        sync,
    );
}

/// Whether `level` is implemented: 1 (fixed Huffman) and 6 (dynamic Huffman)
/// are; every other level (2-5, 7-9, and anything outside 1-9) returns
/// `error.Unimplemented`, never a silent alias of another level. The
/// containers' shared driver asks through this, so the rule lives once.
pub fn levelImplemented(level: u8) bool {
    return level == 1 or level == 6;
}

/// Encoder configuration. `.{}` is the default: level 1.
pub const Options = struct {
    /// The zlib-scale compression level, 1-9:
    ///
    ///   - 1 (the default): fixed-Huffman blocks from the level-1 match
    ///     finder, or a stored block when that is smaller.
    ///   - 6: klauspost/compress's level-6 class — their wider greedy match
    ///     finder, dynamic-Huffman blocks (`§3.2.7`), and the per-block
    ///     stored/fixed/dynamic dispatch. Byte-identical to
    ///     klauspost/compress's flate at level 6 (the pinned module version).
    ///   - 2-5 and 7-9 are not implemented: `error.Unimplemented`, never a
    ///     silent alias, and so is any level outside 1-9.
    level: u8 = 1,
    /// The stream's preset dictionary or `null` (`§3.2.3`): history in front
    /// of the stream, which the finder's table is primed from and a match can
    /// reach into. Raw deflate names no dictionary, so the caller vouches for
    /// the bytes on both sides; zlib's FDICT/DICTID is the checked form
    /// (RFC 1950 §2.2). A dictionary longer than 32 KiB contributes only its
    /// last 32 KiB.
    dict: ?[]const u8 = null,
};

/// Compress `source` as one raw deflate stream into `target` and return the
/// number of bytes written. A `target` of `maxCompressedLength(source.len)`
/// always suffices; a smaller one can return `error.BufferTooSmall`, leaving
/// `target` partly written. `error.Unimplemented` for an unimplemented level.
///
/// `options.dict` is the stream's preset dictionary or `null` (`§3.2.3`); see
/// `Options`.
///
/// The stream ends with an empty final block (BFINAL, `§3.2.3`), and every data
/// block is fixed Huffman, dynamic Huffman, or stored. The same input and
/// options always produce the same bytes. Allocates nothing; level 1 keeps a
/// 128 KiB match-finder table on the stack, level 6 its two tables (384 KiB),
/// a 256 KiB token list, and the tree scratch.
pub fn compress(
    source: []const u8,
    target: []u8,
    options: Options,
) error{ BufferTooSmall, Unimplemented }!usize {
    if (!levelImplemented(options.level)) return error.Unimplemented;
    // A preset dictionary is a second region in front of `source` (the caller
    // owns the source bytes, so they cannot be prepended to). The streaming
    // `Writer` owns a buffer and puts its dictionary inside it instead; both
    // reach the same finder through `Window`.
    if (options.dict != null) {
        const window: Window(true) = .{
            .dict = decode.dictHistory(options.dict),
            .source = source,
        };
        return compressBlocks(true, window, source, target, options);
    }
    const window: Window(false) = .{ .dict = &.{}, .source = source };
    return compressBlocks(false, window, source, target, options);
}

/// The one-shot block loop, shared by both window shapes and both levels:
/// split `source` at `max_block_size` (`§3.2.4`'s stored LEN cap, so any block
/// can fall back to stored), emit each block, and end the stream with the
/// final empty block.
fn compressBlocks(
    comptime preset: bool,
    window: Window(preset),
    source: []const u8,
    target: []u8,
    options: Options,
) error{ BufferTooSmall, Unimplemented }!usize {
    if (options.level == 6) return compressBlocks6(preset, window, source, target);

    var w: BitWriter = .{ .target = target };

    // One finder table for the whole stream, zeroed once (`FinderTable`):
    // entries are absolute stream positions (the dictionary's bytes are the
    // window's first ones), so the per-block cost is the strided history
    // prime alone. `fastmem.set` rather than `@splat`: a splat lowers to the
    // scalar compiler-rt memset on aarch64.
    var table: FinderTable = undefined;
    fastmem.set(u32, &table, 0);

    var block_start: usize = 0;
    while (block_start < source.len) {
        const block_end = @min(block_start + max_block_size, source.len);
        try compressBlockStateful(
            preset,
            window,
            block_start,
            block_end,
            &w,
            &table,
            0,
            stream_prime_stride,
            false,
        );
        block_start = block_end;
    }

    try writeFinalEmptyBlock(&w);
    try w.finish();

    // The sizing contract, as a postcondition: the stored fallback and the
    // block split keep every stream inside `maxCompressedLength`.
    assert(w.pos <= maxCompressedLength(source.len));
    return w.pos;
}

// ---------------------------------------------------------------------------
// Tests. Every decode goes through the decoder (decode.zig), with the
// sentinel overrun rule: the target is pre-filled and the bytes past the
// decoded length must be untouched.
// ---------------------------------------------------------------------------

/// Compress `input`, check the sizing contract and the final empty block, then
/// decode and prove the bytes past the decoded length are untouched
/// (`golden.checkDecode`: exact-cap, then slack, both sentinel-checked).
fn roundTrip(input: []const u8) !void {
    const allocator = testing.allocator;
    const bound = maxCompressedLength(input.len);
    const comp = try allocator.alloc(u8, bound);
    defer allocator.free(comp);
    const clen = try compress(input, comp, .{});
    try testing.expect(clen <= bound);
    try golden.expectFinalEmptyBlock(comp[0..clen]);

    const target = try allocator.alloc(u8, input.len + sentinel.len);
    defer allocator.free(target);
    try golden.checkDecode(target, comp[0..clen], input);
}

test "compress: options — every implemented level round-trips" {
    // Levels are the zlib scale: 1 (fixed Huffman) and 6 (dynamic Huffman)
    // are implemented, and `.{}` is level 1.
    var comp: [4096]u8 = undefined;
    var decoded: [4096]u8 = undefined;
    const input = "the quick brown fox jumps over the lazy dog. " ** 8;

    try testing.expectEqual(@as(u8, 1), (Options{}).level);
    for ([_]u8{ 1, 6 }) |level| {
        const n = try compress(input, &comp, .{ .level = level });
        const dn = try decode.decompress(comp[0..n], &decoded, null);
        try testing.expectEqualSlices(u8, input, decoded[0..dn]);
    }

    // The unimplemented levels: never a silent alias, and any level outside
    // 1-9 is rejected too (0 and 10 included).
    for ([_]u8{ 0, 2, 3, 4, 5, 7, 8, 9, 10, 255 }) |level| {
        try testing.expectError(
            error.Unimplemented,
            compress(input, &comp, .{ .level = level }),
        );
    }
}

test "compress: level 6 emits a dynamic-Huffman block for compressible text" {
    // Spec: rfc1951-deflate.txt §3.2.7 — a dynamic block's header carries
    // BTYPE = 10 (LSB-first bits 1,0) and the tree description; a fixed block
    // carries BTYPE = 01. The phrase repeats, so the finder finds matches and
    // the dynamic rung wins over both the fixed and stored forms: the stream
    // is smaller than level 1's for the same input, and its first block's
    // BTYPE is dynamic.
    const gpa = testing.allocator;
    const input = "the quick brown fox jumps over the lazy dog. " ** 400;
    const dynamic_comp = try gpa.alloc(u8, maxCompressedLength(input.len));
    defer gpa.free(dynamic_comp);
    const dynamic_len = try compress(input, dynamic_comp, .{ .level = 6 });
    const fixed_comp = try gpa.alloc(u8, maxCompressedLength(input.len));
    defer gpa.free(fixed_comp);
    const fixed_len = try compress(input, fixed_comp, .{ .level = 1 });
    try testing.expect(dynamic_len < fixed_len);

    // BFINAL=0, BTYPE=10: the first three bits are 1, 0, 0 (LSB first).
    try testing.expectEqual(@as(u8, 0b100), dynamic_comp[0] & 0b111);
    const target = try gpa.alloc(u8, input.len + sentinel.len);
    defer gpa.free(target);
    try golden.checkDecode(target, dynamic_comp[0..dynamic_len], input);
}

/// `bytes(range(64)) * 3`, the "mixed binary" parity case's input.
const mixed_binary_192 = blk: {
    var bytes: [192]u8 = undefined;
    for (0..3) |rep| {
        for (0..64) |i| bytes[rep * 64 + i] = @intCast(i);
    }
    break :blk bytes;
};

test "compress: level 6 emits klauspost's bytes (the pinned module version)" {
    // The parity pin, without the Go tool: klauspost/compress's flate at
    // level 6 (v1.18.1-0.20250402062133-8df4d013ff17, the module pin the
    // oracle vendors) produced exactly these bytes. `just flate-oracle`
    // re-derives them from the module itself over every shape; this test
    // keeps a small, readable slice of the pin in the unit suite. The cases
    // cover the tiny-block stored path (13 bytes), the final empty block, a
    // dynamic block with one distance code, a mixed binary block, and the
    // `03 00` ending every stream carries.
    const cases = [_]struct { name: []const u8, input: []const u8, want: []const u8 }{
        .{ .name = "empty", .input = "", .want = &[_]u8{ 0x03, 0x00 } },
        .{
            .name = "stored tiny block",
            .input = "hello, flate!",
            .want = &[_]u8{
                0x00, 0x0d, 0x00, 0xf2, 0xff, 0x68, 0x65, 0x6c, 0x6c, 0x6f,
                0x2c, 0x20, 0x66, 0x6c, 0x61, 0x74, 0x65, 0x21, 0x03, 0x00,
            },
        },
        .{
            .name = "dynamic phrase",
            .input = "the quick brown fox jumps over the lazy dog. " ** 4,
            .want = &[_]u8{
                0x2a, 0xc9, 0x48, 0x55, 0x28, 0x2c, 0xcd, 0x4c, 0xce, 0x56,
                0x48, 0x2a, 0xca, 0x2f, 0xcf, 0x53, 0x48, 0xcb, 0xaf, 0x50,
                0xc8, 0x2a, 0xcd, 0x2d, 0x28, 0x56, 0xc8, 0x2f, 0x4b, 0x2d,
                0x52, 0x00, 0x49, 0xe7, 0x24, 0x56, 0x55, 0x2a, 0xa4, 0xe4,
                0xa7, 0xeb, 0x29, 0x0c, 0x12, 0xc5, 0x80, 0x01, 0x00,
            },
        },
        .{
            .name = "one distance code",
            .input = "\x5a" ** 300,
            .want = &[_]u8{ 0x8a, 0x1a, 0x05, 0x44, 0x03, 0xc0, 0x00 },
        },
        .{
            .name = "mixed binary",
            .input = &mixed_binary_192,
            .want = &[_]u8{
                0x62, 0x60, 0x64, 0x62, 0x66, 0x61, 0x65, 0x63, 0xe7, 0xe0,
                0xe4, 0xe2, 0xe6, 0xe1, 0xe5, 0xe3, 0x17, 0x10, 0x14, 0x12,
                0x16, 0x11, 0x15, 0x13, 0x97, 0x90, 0x94, 0x92, 0x96, 0x91,
                0x95, 0x93, 0x57, 0x50, 0x54, 0x52, 0x56, 0x51, 0x55, 0x53,
                0xd7, 0xd0, 0xd4, 0xd2, 0xd6, 0xd1, 0xd5, 0xd3, 0x37, 0x30,
                0x34, 0x32, 0x36, 0x31, 0x35, 0x33, 0xb7, 0xb0, 0xb4, 0xb2,
                0xb6, 0xb1, 0xb5, 0xb3, 0x1f, 0x68, 0xfd, 0x80, 0x01, 0x00,
            },
        },
    };
    const gpa = testing.allocator;
    for (cases) |case| {
        var comp: [256]u8 = undefined;
        const n = try compress(case.input, &comp, .{ .level = 6 });
        try testing.expectEqualSlices(u8, case.want, comp[0..n]);
        const target = try gpa.alloc(u8, case.input.len + sentinel.len);
        defer gpa.free(target);
        golden.checkDecode(target, comp[0..n], case.input) catch |err| {
            print("FAIL: {s}\n", .{case.name});
            return err;
        };
    }
}

test "compress: level 6 with a preset dictionary emits klauspost's bytes" {
    // The dictionary path runs klauspost's `fillWindow` scan over the
    // dictionary's tail before the first block, so the tables hold its
    // positions. These bytes come from their `NewWriterDict(w, 6, dict)`; the
    // oracle's dictionary parity rows re-derive them from the module.
    const dict = "the quick brown fox jumps over the lazy dog. " ** 8;
    const source = ("she sells seashells by the seashore\n" ** 6) ++
        ("the quick brown fox jumps over the lazy dog. " ** 3);
    const want = &[_]u8{
        0x2a, 0xce, 0x48, 0x55, 0x28, 0x4e, 0xcd, 0xc9, 0x29, 0x56, 0x28, 0x4e,
        0x4d, 0x2c, 0xce, 0x00, 0xb3, 0x92, 0x2a, 0xc1, 0x66, 0x80, 0x05, 0xf2,
        0x8b, 0x52, 0xb9, 0x86, 0xa2, 0x9a, 0x41, 0x12, 0x17, 0x80, 0x01, 0x00,
    };
    var comp: [256]u8 = undefined;
    const n = try compress(source, &comp, .{ .level = 6, .dict = dict });
    try testing.expectEqualSlices(u8, want, comp[0..n]);

    const gpa = testing.allocator;
    const target = try gpa.alloc(u8, source.len + sentinel.len);
    defer gpa.free(target);
    try golden.checkDecodeDict(target, comp[0..n], dict, source);

    // The one-shot and streaming layers agree with the same dictionary.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var buf: writer.Buffer = undefined;
    var w: writer = .init(&out.writer, &buf, .{ .level = 6, .dict = dict });
    try w.writer.writeAll(source);
    try w.finish();
    try testing.expectEqualSlices(u8, comp[0..n], out.written());
}

test "compress: level 6 round-trips every shape" {
    // The dynamic path through the whole encoder for the corpus shapes at the
    // sizes that exercise the block split, the cross-block reach, and the
    // stored fallback.
    const gpa = testing.allocator;
    inline for (.{
        golden.Shape.text, golden.Shape.random, golden.Shape.html,
        golden.Shape.rle,  golden.Shape.mixed,
    }) |shape| {
        for ([_]usize{ 0, 1, 13, 32, 127, 128, 1000, 65535, 65536, 131071 }) |len| {
            const input = try golden.makeShape(gpa, shape, len);
            defer gpa.free(input);
            const comp = try gpa.alloc(u8, maxCompressedLength(len));
            defer gpa.free(comp);
            const clen = compress(input, comp, .{ .level = 6 }) catch |err| {
                print("FAIL: {s} len {d}: {s}\n", .{ @tagName(shape), len, @errorName(err) });
                return err;
            };
            try testing.expect(clen <= maxCompressedLength(len));
            try golden.expectFinalEmptyBlock(comp[0..clen]);
            const target = try gpa.alloc(u8, len + sentinel.len);
            defer gpa.free(target);
            golden.checkDecode(target, comp[0..clen], input) catch |err| {
                print("FAIL: {s} len {d}\n", .{ @tagName(shape), len });
                return err;
            };
        }
    }
}

test "matchCandidate: the position edge cases of the absolute-entry arithmetic" {
    // A uniform source (every byte equal) makes the 4-byte confirm always
    // pass, so each row isolates the accept/reject logic: distance 0,
    // exactly history_len, past the cap, a wrapped-around 4-GiB entry
    // landing in-window, an entry ahead of `s`, and the windowed front.
    // Spec: rfc1951-deflate.txt §3.2.5 (a distance is at most 32768).
    var src_buf: [70_000]u8 = undefined;
    fastmem.set(u8, &src_buf, 'a');
    const src: []const u8 = &src_buf;
    const s_index: usize = 40_000;
    const s_absolute: u32 = 40_000;
    const e = load32(src, s_index);
    const window: Window(false) = .{ .dict = &.{}, .source = src };

    // Distance 0 (entry == s): rejected.
    try testing.expectEqual(@as(?usize, null), window.matchCandidate(
        s_index,
        s_absolute,
        s_absolute,
        e,
        false,
    ));
    // Exactly history_len: accepted.
    try testing.expectEqual(
        @as(?usize, s_index - history_len),
        window.matchCandidate(s_index, s_absolute, s_absolute - history_len, e, false),
    );
    // history_len + 1: rejected.
    try testing.expectEqual(@as(?usize, null), window.matchCandidate(
        s_index,
        s_absolute,
        s_absolute - history_len - 1,
        e,
        false,
    ));
    // A wrapped-around entry: distance 16 lands in-window.
    try testing.expectEqual(
        @as(?usize, s_index - 16),
        window.matchCandidate(s_index, 5, math.maxInt(u32) - 10, e, false),
    );
    // An entry ahead of `s` (wraps to a huge distance): rejected.
    try testing.expectEqual(
        @as(?usize, null),
        window.matchCandidate(s_index, 100, 101, e, false),
    );
    // Windowed: a distance past the source front (into dropped history) is
    // rejected; equal to the front names position 0.
    try testing.expectEqual(
        @as(?usize, null),
        window.matchCandidate(10, 50_010, 100, e, true),
    );
    try testing.expectEqual(
        @as(?usize, 0),
        window.matchCandidate(10, 50_010, 50_000, e, true),
    );
}

test "matchCandidate: a garbage-filled table stays exact on the windowed path" {
    // The table is only hints: a stale entry fails the cap, a wrapped entry
    // lands in-window where the confirm decides, and the windowed check
    // rejects dropped history — every emitted match is byte-verified.
    var src_buf: [70_000]u8 = undefined;
    fastmem.set(u8, &src_buf, 'a');
    const src: []const u8 = &src_buf;
    const window: Window(false) = .{ .dict = &.{}, .source = src };
    var rng: DefaultPrng = .init(0xDEADBEEF);
    for (0..64) |i| {
        const s_index: usize = 1 + (i * 1000) % 60_000;
        const s_absolute: u32 = @truncate(500_000 + s_index);
        const entry = rng.random().int(u32);
        const candidate = window.matchCandidate(s_index, s_absolute, entry, 0, true);
        if (candidate) |c| {
            // Whatever the entry, an accepted candidate names a real
            // in-window position with four equal bytes.
            try testing.expect(c < s_index);
            try testing.expect(s_index - c <= history_len);
            try testing.expectEqual(load32(src, c), load32(src, s_index));
        }
    }
}

test "compress: empty input is the final empty block" {
    // Spec: rfc1951-deflate.txt §3.2.3 — "BFINAL is set if and only if this is
    // the last block of the data set"; our stream ends with the empty fixed
    // block `03 00`. Spec: §3.2.6 — the fixed end-of-block code is seven zero
    // bits.
    var target: [4]u8 = undefined;
    const n = try compress("", &target, .{});
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x03, 0x00 }, target[0..n]);
    try testing.expectEqual(@as(usize, 2), maxCompressedLength(0));

    var decoded: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try decode.decompress(target[0..n], &decoded, null));
}

test "compress: maxCompressedLength formula" {
    // input_len + 5 * ceil(input_len / 65535) + 2, with §3.2.4's 65535-byte
    // stored LEN cap as the block size.
    try testing.expectEqual(@as(usize, 2), maxCompressedLength(0));
    try testing.expectEqual(@as(usize, 1 + 5 + 2), maxCompressedLength(1));
    try testing.expectEqual(@as(usize, 65535 + 5 + 2), maxCompressedLength(65535));
    try testing.expectEqual(@as(usize, 65536 + 10 + 2), maxCompressedLength(65536));
    try testing.expectEqual(@as(usize, 131070 + 10 + 2), maxCompressedLength(131070));
    try testing.expectEqual(@as(usize, 131071 + 15 + 2), maxCompressedLength(131071));
    try testing.expectEqual(@as(usize, max_block_size), 65535);
    try testing.expectEqual(@as(usize, history_len), 32768);
}

test "compress: §3.2.4 stored fallback for incompressible input" {
    // Spec: rfc1951-deflate.txt §3.2.4 — a stored block is BFINAL/BTYPE=00
    // followed by the byte-aligned LEN/NLEN and the raw bytes. Random data
    // cannot beat the stored form, so the whole block is stored: the output is
    // input_len + 5 (one block) + 2 (the ending).
    const allocator = testing.allocator;
    const input = try golden.makeShape(allocator, .random, 4096);
    defer allocator.free(input);
    const comp = try allocator.alloc(u8, maxCompressedLength(input.len));
    defer allocator.free(comp);
    const clen = try compress(input, comp, .{});

    try testing.expectEqual(@as(u8, 0), comp[0] & 0b1); // BFINAL clear on data
    try testing.expectEqual(@as(u8, 0b00), (comp[0] >> 1) & 0b11); // BTYPE stored
    try testing.expectEqual(input.len + 5 + 2, clen);
    try roundTrip(input);
}

test "compress: round trips through our decoder (shapes)" {
    const allocator = testing.allocator;
    inline for (.{
        golden.Shape.text, golden.Shape.random, golden.Shape.html,
        golden.Shape.rle,  golden.Shape.mixed,
    }) |shape| {
        for ([_]usize{ 0, 1, 3, 4, 13, 64, 1000, 8192 }) |len| {
            const input = try golden.makeShape(allocator, shape, len);
            defer allocator.free(input);
            roundTrip(input) catch |err| {
                print("FAIL: shape {s} len {d}\n", .{ @tagName(shape), len });
                return err;
            };
        }
    }
}

test "compress: round trips across block boundaries" {
    // Sizes around the 65535-byte split, where the second block's matches may
    // reach back into the first (`§3.2.3`: "the backward distance may cross one
    // or more block boundaries").
    const allocator = testing.allocator;
    const sizes = [_]usize{
        65534, 65535, 65536, 65537, 131070, 131071, 131072, 196605, 196606,
    };
    inline for (.{
        golden.Shape.text, golden.Shape.random, golden.Shape.rle, golden.Shape.mixed,
    }) |shape| {
        for (sizes) |len| {
            const input = try golden.makeShape(allocator, shape, len);
            defer allocator.free(input);
            roundTrip(input) catch |err| {
                print("FAIL: shape {s} len {d}\n", .{ @tagName(shape), len });
                return err;
            };
        }
    }
}

test "compress: many blocks round trip (1 MiB)" {
    // Sixteen blocks of text (cross-block matches across many boundaries) and
    // of incompressible bytes (all stored), with the sizing contract checked
    // end to end.
    const allocator = testing.allocator;
    inline for (.{ golden.Shape.text, golden.Shape.mixed }) |shape| {
        const input = try golden.makeShape(allocator, shape, 1 << 20);
        defer allocator.free(input);
        roundTrip(input) catch |err| {
            print("FAIL: shape {s} len 1 MiB\n", .{@tagName(shape)});
            return err;
        };
    }
}

test "compress: maxCompressedLength bounds every emission" {
    // `compress` never writes past `maxCompressedLength`: every emission fits a
    // target of exactly that size, across the block-boundary sizes and the
    // adversarial shapes (a compressible block followed by an incompressible
    // one, which is where the stored fallback's alignment is worst).
    const allocator = testing.allocator;
    const sizes = [_]usize{
        0,     1,     2,     3,     4,      13,     100,    1024,
        65534, 65535, 65536, 65537, 131070, 131071, 131072, 196605,
    };
    inline for (.{
        golden.Shape.text, golden.Shape.random, golden.Shape.html,
        golden.Shape.rle,  golden.Shape.mixed,
    }) |shape| {
        for (sizes) |len| {
            const input = try golden.makeShape(allocator, shape, len);
            defer allocator.free(input);
            const bound = maxCompressedLength(len);
            const comp = try allocator.alloc(u8, bound);
            defer allocator.free(comp);
            const clen = compress(input, comp, .{}) catch |err| {
                print(
                    "FAIL: {s} len {d}: {s}\n",
                    .{ @tagName(shape), len, @errorName(err) },
                );
                return err;
            };
            try testing.expect(clen <= bound);
            try golden.expectFinalEmptyBlock(comp[0..clen]);
        }
    }

    // A compressible first block followed by an incompressible tail: the tail
    // is stored after a fixed block, which is the misaligned-stored case.
    inline for (.{ 1, 2, 3, 7, 8, 9, 15, 16, 17, 24, 25, 31, 33, 63, 100 }) |tail| {
        const input = try allocator.alloc(u8, 65535 + tail);
        defer allocator.free(input);
        fastmem.set(u8, input[0..65535], 0x41);
        var rng: DefaultPrng = .init(0xFEEDFACE);
        for (input[65535..]) |*b| b.* = rng.random().int(u8);
        const bound = maxCompressedLength(input.len);
        const comp = try allocator.alloc(u8, bound);
        defer allocator.free(comp);
        const clen = try compress(input, comp, .{});
        try testing.expect(clen <= bound);
        try roundTrip(input);
    }
}

test "compress: a target smaller than the output is BufferTooSmall" {
    // `error.BufferTooSmall` when `target` is too small.
    var target: [2]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, compress("hello, flate!", &target, .{}));
    // ... and the empty stream is the smallest legal output.
    try testing.expectEqual(@as(usize, 2), try compress("", &target, .{}));
}

test "compress: deterministic" {
    // The same input and the same block split produce the same bytes.
    const allocator = testing.allocator;
    const input = try golden.makeShape(allocator, .mixed, 70000);
    defer allocator.free(input);
    const bound = maxCompressedLength(input.len);
    const first = try allocator.alloc(u8, bound);
    defer allocator.free(first);
    const second = try allocator.alloc(u8, bound);
    defer allocator.free(second);
    const a = try compress(input, first, .{});
    const b = try compress(input, second, .{});
    try testing.expectEqual(a, b);
    try testing.expectEqualSlices(u8, first[0..a], second[0..b]);
}

test "compress: golang/go deflateTests inputs round trip" {
    // golden.zig's `deflate_cases` carry Go's `in` bytes alongside streams that
    // decode to them; the encoder is judged the other way round: its own stream
    // for the same input must decode to it (deflate mandates no canonical
    // form).
    for (golden.deflate_cases) |tc| {
        roundTrip(tc.want) catch |err| {
            print("FAIL: deflateTests input len {d}\n", .{tc.want.len});
            return err;
        };
    }
}

test "compress: golang/go testdata huffman-* inputs round trip" {
    // 242 KB of reference data (Go's `writeBlockHuff` inputs), through our
    // encoder and our decoder: the round trip covers real text, digits of pi,
    // random tails, and the degenerate 64-KiB single-byte runs.
    for (golden.huffman_fixtures) |fixture| {
        roundTrip(fixture.input) catch |err| {
            print("FAIL: {s}\n", .{fixture.name});
            return err;
        };
    }
}

test "compress: a match reaches back across a block boundary" {
    // Spec: rfc1951-deflate.txt §3.2.3 — "the backward distance may cross one
    // or more block boundaries". The second block is a copy of a window of the
    // first, so only the finder's history priming can find it: without
    // cross-block history the block is incompressible and costs a stored block
    // (31773 bytes). The distance is deliberately not 32768, which the
    // zero-initialized table's window_start entry would satisfy by accident.
    const allocator = testing.allocator;
    const copy_from = 65535 - history_len + 1000;
    const input = try allocator.alloc(u8, 65535 + (65535 - copy_from));
    defer allocator.free(input);
    var rng: DefaultPrng = .init(0xBADD_CAFE);
    for (input[0..65535]) |*b| b.* = rng.random().int(u8);
    fastmem.copy(u8, input[65535..], input[copy_from..65535]);

    const comp = try allocator.alloc(u8, maxCompressedLength(input.len));
    defer allocator.free(comp);
    const clen = try compress(input, comp, .{});
    // The first block is incompressible (stored: 65540 bytes); the second is
    // one match of 31768 bytes (~125 chunks of 258).
    try testing.expect(clen > 65540);
    try testing.expect(clen < 67000);
    try roundTrip(input);
}

test "compress: RFC 1951 and flate-notes micro-example outputs round trip" {
    // The decode-side micro-fixtures' payloads as encoder inputs: the RFC's
    // overlap example, the repeat-code example, std's micro-streams, and the
    // notes' two streams.
    for (golden.micro_cases) |tc| {
        roundTrip(tc.want) catch |err| {
            print("FAIL: {s}\n", .{tc.desc});
            return err;
        };
    }
}

test "fixed tables: §3.2.6's numerals are the canonical construction" {
    // Spec: rfc1951-deflate.txt §3.2.6 gives the fixed codes as numerals;
    // §3.2.2's construction assigns codes from lengths alone. The encoder's
    // table holds the numerals (pre-reversed for the wire) — this proves the
    // two agree symbol for symbol, including 286-287, which "will never
    // actually occur in the compressed data, but participate in the code
    // construction".
    var lens: [288]u4 = undefined;
    for (0..144) |i| lens[i] = 8;
    for (144..256) |i| lens[i] = 9;
    for (256..280) |i| lens[i] = 7;
    for (280..288) |i| lens[i] = 8;

    var count: [16]u16 = @splat(0);
    for (lens) |len| count[len] += 1;
    var next_code: [16]u16 = @splat(0);
    var code: u16 = 0;
    for (1..16) |bits| {
        code = (code + count[bits - 1]) << 1;
        next_code[bits] = code;
    }

    for (lens, 0..) |len, symbol| {
        const expected = wireBits(next_code[len], len);
        next_code[len] += 1;
        try testing.expectEqual(expected, fixed_literal_codes[symbol].bits);
        try testing.expectEqual(len, fixed_literal_codes[symbol].len);
    }
    // §3.2.6 — "Distance codes 0-31 are represented by (fixed-length) 5-bit
    // codes"; the numeral is the symbol.
    for (fixed_distance_codes, 0..) |entry, symbol| {
        try testing.expectEqual(@as(u5, 5), entry.len);
        try testing.expectEqual(wireBits(@intCast(symbol), 5), entry.bits);
    }
}

test "emit: flate-notes §3.2 stream 1 packing, byte-exact modulo BFINAL" {
    // Spec: docs/slop/research/flate-notes.md §3.2, stream 1 — "literal 'A', match
    // length 20 (code 269 = base 19 + extra 1) at distance 1 (code 0), EOB",
    // packed as `73 c4 06 00` with BFINAL set on that block. Our encoder never
    // sets BFINAL on a data block, so the same tokens are `72 c4 06 00`
    // followed by the final empty block: the packing — header bits, the
    // MSB-of-code literal and length codes, and the LSB-of-value length extra
    // bits — is byte-exact otherwise. The finder produces exactly these
    // tokens: one literal 'A', then a 20-byte match at distance 1.
    const allocator = testing.allocator;
    const input = [_]u8{'A'} ** 21;
    const comp = try allocator.alloc(u8, maxCompressedLength(input.len));
    defer allocator.free(comp);
    const clen = try compress(&input, comp, .{});
    const want = [_]u8{ 0x72, 0xc4, 0x06, 0x00, 0x03, 0x00 };
    try testing.expectEqualSlices(u8, &want, comp[0..clen]);
    try roundTrip(&input);

    // And the notes' own stream decodes to the same bytes through our decoder,
    // with BFINAL on its single block (golden.zig pins it too).
    var decoded: [32]u8 = undefined;
    const n = try decode.decompress(&[_]u8{ 0x73, 0xc4, 0x06, 0x00 }, &decoded, null);
    try testing.expectEqualSlices(u8, &input, decoded[0..n]);
}

test "emit: flate-notes §3.2 stream 2 tokens pack the distance extra bits LSB-first" {
    // Spec: docs/slop/research/flate-notes.md §3.2, stream 2 — "70 literals 'A',
    // then match length 3 (code 257, no extra) at distance 67 (code 12 = base
    // 65 + extra value 2, bits [0,1,0,0,0] LSB-first), EOB", packed as the
    // golden.zig hex with BFINAL set on the block. Our greedy finder cannot
    // produce this token sequence (on a run of 'A' it takes the longer match at
    // distance 1), so the tokens are emitted directly here: this is the
    // distance-side extra-bit-order pin. An MSB-first reading of those extra
    // bits would give distance 73, past the 70-byte history.
    var target: [128]u8 = undefined;
    var w: BitWriter = .{ .target = &target };
    try w.writeBits(1, 1); // BFINAL, matching the notes' stream
    try w.writeBits(1, 2); // BTYPE = 01, fixed
    var payload: u64 = 0;
    const limit: u64 = math.maxInt(u64);
    const run = [_]u8{'A'} ** 70;
    try testing.expect(try emitLiterals(&run, &w, &payload, limit));
    try testing.expect(try emitMatch(&w, 67, 3, &payload, limit));
    try w.writeCode(fixed_literal_codes[256]);
    try w.finish();

    const notes_stream = [_]u8{
        0x73, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74,
        0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74,
        0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74,
        0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74,
        0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74,
        0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0x04, 0x1a,
        0x01, 0x00,
    };
    try testing.expectEqualSlices(u8, &notes_stream, target[0..w.pos]);

    // The notes' stream decodes to 73 bytes of 'A' (70 literals + a 3-byte
    // match from distance 67); so must ours.
    var decoded: [80]u8 = undefined;
    sentinel.fill(&decoded);
    const n = try decode.decompress(target[0..w.pos], &decoded, null);
    try testing.expectEqual(@as(usize, 73), n);
    for (decoded[0..n]) |byte| try testing.expectEqual(@as(u8, 'A'), byte);
    try sentinel.expect(&decoded, n);
}

test "emit: a dictionary match reaches in front of the output" {
    // Spec: rfc1951-deflate.txt §3.2.3 — with a preset dictionary the history
    // starts at the dictionary's first byte. Hand-built tokens: BFINAL=1,
    // BTYPE=01, the literal 'x', then a match of length 6 at distance 5,
    // EOB. The window is ["abcd"]["x"], so the match reads 'a','b','c','d'
    // and then continues at the output's start ('x', 'a').
    var target: [64]u8 = undefined;
    var w: BitWriter = .{ .target = &target };
    try w.writeBits(1, 1); // BFINAL, matching the hand-built form
    try w.writeBits(1, 2); // BTYPE = 01, fixed
    var payload: u64 = 0;
    const limit: u64 = math.maxInt(u64);
    try testing.expect(try emitLiterals("x", &w, &payload, limit));
    try testing.expect(try emitMatch(&w, 5, 6, &payload, limit));
    try w.writeCode(fixed_literal_codes[256]);
    try w.finish();

    var decoded: [16]u8 = undefined;
    sentinel.fill(&decoded);
    const n = try decode.decompress(target[0..w.pos], &decoded, "abcd");
    try testing.expectEqual(@as(usize, 7), n);
    try testing.expectEqualSlices(u8, "xabcdxa", decoded[0..n]);
    try sentinel.expect(&decoded, n);

    // Without the dictionary (or with one too short for the reach) the
    // distance is past the history.
    try testing.expectError(
        error.InvalidMatch,
        decode.decompress(target[0..w.pos], &decoded, null),
    );
    try testing.expectError(
        error.InvalidMatch,
        decode.decompress(target[0..w.pos], &decoded, "ab"),
    );
}

test "compress: a preset dictionary is matchable history" {
    // §3.2.3 — the dictionary is history in front of the stream, so the finder
    // matches into its tail and the emitted distance reaches back before the
    // output's first byte. The source repeats the dictionary and continues
    // past it, so the match straddles the dictionary's end and the output's
    // start.
    const allocator = testing.allocator;
    const dict = "the quick brown fox jumps over the lazy dog. " ** 3;
    const source = "the quick brown fox jumps over the lazy dog. " ** 8;
    const comp = try allocator.alloc(u8, maxCompressedLength(source.len));
    defer allocator.free(comp);
    const plain = try allocator.alloc(u8, source.len + sentinel.len);
    defer allocator.free(plain);

    const with_dict = try compress(source, comp, .{ .dict = dict });
    sentinel.fill(plain);
    const n = try decode.decompress(comp[0..with_dict], plain[0..source.len], dict);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, plain[0..n]);
    try sentinel.expect(plain, n);

    // The dictionary carried the stream: without it the same source is a few
    // literals per repetition, with it the repetitions are matches.
    var plain_comp: [maxCompressedLength(source.len)]u8 = undefined;
    const without_dict = try compress(source, &plain_comp, .{});
    try testing.expect(with_dict < without_dict / 2);

    // The stream depends on the dictionary's bytes: without it (or with a
    // different one) the reach is past the supplied history.
    try testing.expectError(
        error.InvalidMatch,
        decode.decompress(comp[0..with_dict], plain, null),
    );
    try testing.expectError(
        error.InvalidMatch,
        decode.decompress(comp[0..with_dict], plain, "something else entirely"),
    );

    // An empty dictionary is no dictionary: byte-identical to `.{}`.
    var empty_comp: [maxCompressedLength(source.len)]u8 = undefined;
    const empty_dict = try compress(source, &empty_comp, .{ .dict = "" });
    try testing.expectEqualSlices(u8, plain_comp[0..without_dict], empty_comp[0..empty_dict]);
}

test "compress: a dictionary longer than 32 KiB contributes only its tail" {
    // §3.2.3's window is 32 KiB, so a longer dictionary's front is not
    // matchable while its tail is. The two sources below are the same length
    // and equally incompressible on their own; only the tail one can be
    // matched.
    const allocator = testing.allocator;
    const dict = try allocator.alloc(u8, history_len + 64);
    defer allocator.free(dict);
    var rng: DefaultPrng = .init(0xC0FFEE);
    for (dict) |*b| b.* = rng.random().int(u8);

    const comp = try allocator.alloc(u8, maxCompressedLength(64));
    defer allocator.free(comp);
    const plain = try allocator.alloc(u8, 64 + sentinel.len);
    defer allocator.free(plain);

    // The dictionary's last 64 bytes: one match at distance 64.
    const tail = dict[history_len..];
    const tail_len = try compress(tail, comp, .{ .dict = dict });
    sentinel.fill(plain);
    const n = try decode.decompress(comp[0..tail_len], plain[0..64], dict);
    try testing.expectEqual(@as(usize, 64), n);
    try testing.expectEqualSlices(u8, tail, plain[0..n]);
    try sentinel.expect(plain, n);

    // The dictionary's first 64 bytes are outside the window: nothing to
    // match, so the stream is the stored form.
    const front = dict[0..64];
    const front_len = try compress(front, comp, .{ .dict = dict });
    const front_plain = try compress(front, comp, .{});
    try testing.expectEqual(front_plain, front_len);
    try testing.expect(tail_len < front_len / 2);
}

test "emit: long matches split at 258 with a legal tail" {
    // Long matches split at 258 with the final chunk kept >= 3: the last chunk
    // drops to 255 when a 258 would leave a 1- or 2-byte tail, which cannot be
    // coded (the shortest length symbol is 3).
    // §3.2.5 — 258 is code 285, the one length code with zero extra bits.
    try testing.expectEqual(@as(u16, 285), length_symbols[258].symbol);
    try testing.expectEqual(@as(u5, 0), length_symbols[258].extra_bits);
    try testing.expectEqual(@as(u16, 257), length_symbols[3].symbol);
    try testing.expectEqual(@as(u16, 284), length_symbols[257].symbol);
    try testing.expectEqual(@as(u16, 269), length_symbols[20].symbol);
    try testing.expectEqual(@as(u16, 1), length_symbols[20].extra_value);

    // Every length 3-258 must have a symbol whose base + extra reconstructs it.
    for (3..259) |length| {
        const l = length_symbols[length];
        const base = length_base[l.symbol - 257];
        try testing.expectEqual(@as(u16, @intCast(length)), base + l.extra_value);
        try testing.expect(l.extra_value < (@as(u32, 1) << l.extra_bits));
    }
    // Every distance 1-32768 likewise.
    for (1..history_len + 1) |distance| {
        const d = distanceSymbol(distance);
        try testing.expectEqual(
            @as(u16, @intCast(distance)),
            distance_base[d.symbol] + d.extra,
        );
        try testing.expect(d.extra < (@as(u32, 1) << d.extra_bits));
    }

    // A run long enough to force the split, through the whole encoder.
    const allocator = testing.allocator;
    const input = try allocator.alloc(u8, 4000);
    defer allocator.free(input);
    fastmem.set(u8, input, 0x5A);
    try roundTrip(input);
}

test "compress: every length and distance code round trips" {
    // Sweep the encodable space: distances across all 30 codes (a pattern
    // repeated at each distance) and lengths across all 29 codes (runs of each
    // length), each through our encoder and our decoder. §3.2.5's tables.
    const allocator = testing.allocator;
    var input: [70000]u8 = undefined;
    var rng: DefaultPrng = .init(0x1234_5678);
    for (input[0..4096]) |*b| b.* = rng.random().int(u8);
    for (4096..input.len) |i| input[i] = input[i - 4096];

    const comp = try allocator.alloc(u8, maxCompressedLength(input.len));
    defer allocator.free(comp);
    const clen = try compress(&input, comp, .{});
    try testing.expect(clen <= maxCompressedLength(input.len));

    const back = try allocator.alloc(u8, input.len + sentinel.len);
    defer allocator.free(back);
    sentinel.fill(back);
    const n = try decode.decompress(comp[0..clen], back, null);
    try testing.expectEqual(input.len, n);
    try testing.expectEqualSlices(u8, input[0..n], back[0..n]);
    try sentinel.expect(back, n);

    // Runs of every length 3-258 at distance 1.
    for (3..259) |length| {
        const run = try allocator.alloc(u8, length + 1);
        defer allocator.free(run);
        fastmem.set(u8, run, 0x7E);
        try roundTrip(run);
    }
}
