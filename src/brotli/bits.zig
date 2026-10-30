//! The brotli bit reader (`§1.5`, `§1.5.1`). Data elements fill bytes in
//! order of increasing bit number, so the first bit read is bit 0 of the
//! first byte of the stream; integer values are packed least significant bit
//! first, and multi-byte numbers are stored least significant byte first
//! (`§1.5`). Prefix codes pack most significant bit first — the tree layer's
//! reading of the bits this reader hands out.
//!
//! Every read the input cannot satisfy is `error.Truncated`, never a value
//! decoded out of padding: a stream that ends before its last bit is invalid
//! (`§10`).

const std = @import("std");
const assert = std.debug.assert;
const common = @import("common.zig");
const testing = std.testing;

const fastmem = @import("fastmem");

/// The bit reader's error set. The frame layer composes it with its own
/// names.
pub const Error = error{
    /// The input ended before the read did. `§10`: "If the stream ends
    /// before the completion of the last meta-block, then the stream should
    /// be rejected as invalid."
    Truncated,
    /// A fill field the format requires to be zero was not (`§9.2`'s
    /// ISLASTEMPTY, metadata and uncompressed block boundaries; `§9.3`'s
    /// last-byte fill).
    BadPadding,
};

/// The widest `take` serves. The format's widest element is 24 bits (MLEN-1,
/// MSKIPLEN-1, and the distance and length extra bits); 32 is headroom, and
/// the refill below keeps a read of that width exact while the bits remain.
pub const max_read_bits: u6 = 32;

/// LSB-first bit reader over `source` (`§1.5.1`).
///
/// `bit_pos` is the source of truth for availability: `take` refuses a read
/// the input cannot satisfy, so no decoded value is ever assembled from
/// past-the-end padding.
pub const BitReader = struct {
    /// The bit source's error set, under the name the generic decode
    /// helpers expect (`Bits.ErrorSet`).
    pub const ErrorSet = Error;

    source: []const u8,
    /// The stream byte `source[0]` is. `bit_pos` counts from the stream's
    /// start, so a reader can be handed a fresh slice of the same stream
    /// anywhere (`attach`); the one-shot's single slice keeps it at zero.
    /// u64: a stream's compressed input can run past 2^32 bytes, where the
    /// stream position does not fit a 32-bit `usize` (`just check-32`).
    source_base: u64,
    /// Next source byte not yet loaded into `bits`, relative to `source`.
    /// A slice is at most an input buffer, so a `usize` is exact here.
    next_byte: usize,
    /// Unconsumed bits, LSB first: bit 0 is the next bit on the wire.
    bits: u64,
    /// Valid bits in `bits` (0-64).
    // u64, not the u7 its range fits: the hot loops keep the reader in
    // registers, and a byte-sized field next to the output byte stores
    // defeats the alias analysis that promotion needs.
    bit_count: u64,
    /// Absolute bit offset of the next unconsumed bit. u64 so the position
    /// arithmetic cannot overflow a 32-bit `usize` on a large input.
    bit_pos: u64,

    pub fn init(source: []const u8) BitReader {
        return .{
            .source = source,
            .source_base = 0,
            .next_byte = 0,
            .bits = 0,
            .bit_count = 0,
            .bit_pos = 0,
        };
    }

    /// Bits of `source` not yet consumed.
    pub fn availableBits(self: *const BitReader) u64 {
        return (self.source_base + self.source.len) * 8 - self.bit_pos;
    }

    /// The stream byte after the last one loaded into `bits`. The bytes
    /// before it are the accumulator's; the streaming reader gives the input
    /// that many bytes back before it reads more (`brotli.Reader`).
    pub fn loadedBytes(self: *const BitReader) u64 {
        return self.source_base + self.next_byte;
    }

    /// True at a byte boundary: where the uncompressed payload and the
    /// metadata bytes begin (`§9.2`).
    pub fn atByteBoundary(self: *const BitReader) bool {
        return self.bit_pos % 8 == 0;
    }

    /// The next `n` bits as an unsigned integer, least significant bit first
    /// (`§1.5.1`), without consuming them. Bits past the end of the input
    /// read as zero: `take` is the gate that turns a starved read into
    /// `error.Truncated`, so a value assembled from padding is never trusted.
    /// The prefix-code layer's peek table (`huffman.zig`) reads codes this
    /// way — a code may end before the stream's last byte, whose fill bits
    /// are still zeros on the wire.
    pub inline fn peek(self: *BitReader, n: u6) Error!u32 {
        assert(n <= max_read_bits);
        self.refill();
        return @intCast(self.bits & ((@as(u64, 1) << n) - 1));
    }

    /// The next `n` bits as an unsigned integer, least significant bit first
    /// (`§1.5.1`). `error.Truncated` when the input holds fewer than `n`.
    pub inline fn take(self: *BitReader, n: u6) Error!u32 {
        assert(n <= max_read_bits);
        self.refill();
        // After a refill the accumulator holds every bit the stream has
        // left (up to 63), and `n <= max_read_bits`, so a short accumulator
        // *is* a short stream: no decoded value is ever assembled from
        // past-the-end padding, and the check is one compare.
        if (self.bit_count < n) return error.Truncated;
        const value: u32 = @intCast(self.bits & ((@as(u64, 1) << n) - 1));
        self.drop(n);
        return value;
    }

    /// Consume `n` bits a `peek` of at least `n` has already loaded,
    /// returning their value: the accumulator's count is the whole check
    /// (after a refill it is every bit the stream has left, up to 63, so a
    /// short count is a short stream — `take`'s gate with the refill
    /// already done). The prefix-code layer's consume: a `peek` of a code's
    /// maximum length covers the code's bits. Also the byte-granular
    /// drain: unlike `take`, it never refills, so it empties exactly the
    /// buffered bytes.
    pub inline fn takeLoaded(self: *BitReader, n: u6) Error!u32 {
        assert(n <= max_read_bits);
        if (self.bit_count < n) return error.Truncated;
        const value: u32 = @intCast(self.bits & ((@as(u64, 1) << n) - 1));
        self.drop(n);
        return value;
    }

    /// Consume `n` bits `peek` has already loaded.
    fn drop(self: *BitReader, n: u6) void {
        assert(n <= max_read_bits);
        assert(self.bit_count >= n);
        self.bits >>= n;
        self.bit_count -= n;
        self.bit_pos += n;
    }

    /// Skip to the next byte boundary. The skipped bits are a fill field the
    /// format requires to be zero — `§9.2`'s ISLASTEMPTY, metadata and
    /// uncompressed block boundaries, `§9.3`'s last-byte fill — so a nonzero
    /// fill is `error.BadPadding`.
    pub fn alignToByte(self: *BitReader) Error!void {
        const skip: u6 = @intCast((8 - (self.bit_pos & 7)) & 7);
        if (skip != 0) {
            if (try self.take(skip) != 0) return error.BadPadding;
        }
        self.rewind();
    }

    /// Copy the next `target.len` bytes out — an uncompressed meta-block's
    /// payload (`§9.2`). Only valid at a byte boundary.
    pub fn takeBytes(self: *BitReader, target: []u8) Error!void {
        assert(self.atByteBoundary());
        self.rewind();
        if (self.source.len - self.next_byte < target.len) return error.Truncated;
        fastmem.copy(u8, target, self.source[self.next_byte..][0..target.len]);
        self.next_byte += target.len;
        self.bit_pos += @as(u64, target.len) * 8;
    }

    /// Skip `count` bytes — a metadata meta-block's payload, which is
    /// neither output, window, nor literal context (`§2`, `§9.2`). Only
    /// valid at a byte boundary.
    pub fn skipBytes(self: *BitReader, count: u32) Error!void {
        assert(self.atByteBoundary());
        self.rewind();
        if (self.source.len - self.next_byte < count) return error.Truncated;
        self.next_byte += count;
        self.bit_pos += @as(u64, count) * 8;
    }

    /// Load whole bytes while the accumulator has room. Afterwards `bits`
    /// holds `min(availableBits(), 64)` bits, so a `take` of up to
    /// `max_read_bits` is exact whenever that many bits remain. The room
    /// path is one unaligned eight-byte load, masked so the accumulator
    /// stays zero above `bit_count` (the peek-reads-padding rule); the
    /// slice's last seven bytes load a byte at a time.
    inline fn refill(self: *BitReader) void {
        if (self.bit_count > max_read_bits) return;
        if (self.source.len - self.next_byte >= 8) {
            // The whole bytes that fit above the held bits: 3..7, since
            // `bit_count` is 0..32 here. `bits` keeps its high zeroes, so
            // a peek past the loaded bits still reads zero padding.
            const add: u64 = (63 - self.bit_count) >> 3;
            const window = common.readInt(u64, self.source[self.next_byte..][0..8]);
            const loaded = window & ((@as(u64, 1) << @intCast(add << 3)) - 1);
            self.bits |= loaded << @intCast(self.bit_count);
            // `add` is 3..7 (the comment above), and `bit_count` is u64 here
            // for the register promotion: the slice index stays `usize`, so
            // the bounded add casts — this is the 32-bit seam `check-32`
            // pins.
            self.next_byte += @as(usize, @intCast(add));
            self.bit_count += add << 3;
            return;
        }
        while (self.bit_count <= max_read_bits and self.next_byte < self.source.len) {
            self.bits |= @as(u64, self.source[self.next_byte]) << @intCast(self.bit_count);
            self.next_byte += 1;
            self.bit_count += 8;
        }
    }

    /// Drop the buffered whole bytes back to `source`. Valid only at a byte
    /// boundary, where the buffered bits are whole unconsumed bytes, so
    /// rewinding loses nothing.
    pub fn rewind(self: *BitReader) void {
        assert(self.bit_pos % 8 == 0);
        assert(self.bit_count % 8 == 0);
        assert(self.bit_pos / 8 >= self.source_base);
        // The absolute position minus the slice's base is an offset inside
        // the slice, so it fits a `usize` on every target.
        self.next_byte = @intCast(self.bit_pos / 8 - self.source_base);
        self.bits = 0;
        self.bit_count = 0;
    }

    /// Continue over a fresh slice of the same stream: `base` is the stream
    /// byte `source[0]` is, and the slice must cover every byte the
    /// accumulator has not loaded (`loadedBytes()`). The bits already
    /// buffered stay put, so the streaming reader hands this reader a new
    /// window of its input without losing the partial byte
    /// (`brotli.Reader`).
    pub fn attach(self: *BitReader, source: []const u8, base: u64) void {
        const loaded = self.loadedBytes();
        assert(base <= loaded);
        assert(base + source.len >= loaded);
        self.source = source;
        self.source_base = base;
        // As in `rewind`: the difference is an offset inside the new slice.
        self.next_byte = @intCast(loaded - base);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "bit reader: RFC 7932 §1.5.1's packing example" {
    // RFC 7932 §1.5.1: "consider packing the following data elements into a
    // sequence of 3 bytes: 3-bit integer value 6, 4-bit integer value 2,
    // prefix code 110, prefix code 10, 12-bit integer value 3628" — the
    // bytes are printed as `11100010 11000101 10010110`, first byte last.
    const source = [_]u8{ 0x96, 0xC5, 0xE2 };
    var br: BitReader = .init(&source);
    try testing.expectEqual(@as(u32, 6), try br.take(3));
    try testing.expectEqual(@as(u32, 2), try br.take(4));
    // The prefix codes are packed most significant bit first: the wire bits
    // `1,1,0` are the code 110, which as an LSB-first integer is 3.
    try testing.expectEqual(@as(u32, 3), try br.take(3));
    // The wire bits `1,0` are the code 10.
    try testing.expectEqual(@as(u32, 1), try br.take(2));
    try testing.expectEqual(@as(u32, 3628), try br.take(12));
    try testing.expectEqual(@as(u64, 0), br.availableBits());
}

test "bit reader: take refuses a read the input cannot satisfy" {
    // RFC 7932 §10: a stream that ends before its last bit is invalid.
    var empty: BitReader = .init(&[_]u8{});
    try testing.expectError(error.Truncated, empty.take(1));

    var one: BitReader = .init(&[_]u8{0xFF});
    try testing.expectEqual(@as(u32, 0xFF), try one.take(8));
    try testing.expectError(error.Truncated, one.take(1));

    // A read that spans the last byte is refused whole: nothing is consumed.
    var two: BitReader = .init(&[_]u8{ 0x00, 0x00 });
    try testing.expectEqual(@as(u32, 0), try two.take(12));
    try testing.expectEqual(@as(u64, 4), two.availableBits());
    try testing.expectError(error.Truncated, two.take(5));
    try testing.expectEqual(@as(u32, 0), try two.take(4));
}

test "bit reader: cross-byte integers are little-endian bit order" {
    // RFC 7932 §1.5: multi-byte numbers are stored least significant byte
    // first. As bits, the second byte continues above the first (§1.5.1).
    const source = [_]u8{ 0x01, 0x02 };
    var br: BitReader = .init(&source);
    try testing.expectEqual(@as(u32, 0x0201), try br.take(16));

    // A read split anywhere reassembles to the same integer.
    const wide = [_]u8{ 0xAB, 0xCD, 0xEF };
    var whole: BitReader = .init(&wide);
    const all = try whole.take(24);
    var split: BitReader = .init(&wide);
    const low = try split.take(3);
    const high = try split.take(21);
    try testing.expectEqual(all, low | (high << 3));
}

test "bit reader: alignToByte accepts zero fill and rejects nonzero fill" {
    // RFC 7932 §9.2: "0..7 bits: fill bits until the next byte boundary,
    // must be all zeros" — a nonzero fill "should be rejected as invalid".
    var zero_fill: BitReader = .init(&[_]u8{0b0000_0110});
    try testing.expectEqual(@as(u32, 6), try zero_fill.take(3));
    try zero_fill.alignToByte();
    try testing.expectEqual(@as(u64, 0), zero_fill.availableBits());

    var nonzero: BitReader = .init(&[_]u8{0b0000_1110});
    try testing.expectEqual(@as(u32, 6), try nonzero.take(3));
    try testing.expectError(error.BadPadding, nonzero.alignToByte());

    // Already at a boundary: nothing to skip, nothing to check.
    var aligned: BitReader = .init(&[_]u8{0xFF});
    try aligned.alignToByte();
    try testing.expectEqual(@as(u32, 0xFF), try aligned.take(8));
}

test "bit reader: attach continues over a fresh slice without losing bits" {
    // The streaming reader's seam: the loaded slice runs out mid-integer, and
    // the bits already buffered survive the switch to the next slice.
    const first = [_]u8{0b1010_0110};
    const rest = [_]u8{ 0b0000_1111, 0b0101_0101 };
    var br: BitReader = .init(&first);
    try testing.expectEqual(@as(u32, 0b110), try br.take(3));
    // `attach` takes the slice that begins at the byte holding the next
    // unconsumed bit (here the same byte, nothing consumed whole yet), so the
    // three buffered bits stay put and the next reads continue across it.
    br.attach(&first, 0);
    try testing.expectEqual(@as(u32, 0b10100), try br.take(5));
    // Now the first slice is spent: the reader hands over the rest.
    br.attach(&rest, 1);
    try testing.expectEqual(@as(u32, 0b1111), try br.take(4));
    try testing.expectEqual(@as(u32, 0b0000), try br.take(4));
    try testing.expectEqual(@as(u32, 0b0101_0101), try br.take(8));
    try testing.expectError(error.Truncated, br.take(1));
    try testing.expectEqual(@as(u64, 0), br.availableBits());

    // A byte-aligned attach: the whole buffered bytes are given back by
    // `rewind` and re-read from the new slice.
    const bytes = [_]u8{ 0b0000_0110, 0x5A };
    var aligned: BitReader = .init(&bytes);
    try testing.expectEqual(@as(u32, 0b110), try aligned.take(3));
    try aligned.alignToByte();
    aligned.rewind();
    try testing.expectEqual(@as(usize, 1), aligned.next_byte);
    aligned.attach(bytes[1..], 1);
    try testing.expectEqual(@as(u32, 0x5A), try aligned.take(8));
}

test "bit reader: the stream position arithmetic is 64-bit" {
    // A reader whose stream has already run past 2^32 bytes: `source_base`,
    // `loadedBytes` and `rewind` count from the stream's start in u64, and
    // only the offset inside the slice narrows to `usize` — the arithmetic
    // that must not wrap on a 32-bit target (`just check-32`).
    const source = [_]u8{0xA5};
    const base: u64 = (@as(u64, 1) << 32) + 7;
    var br: BitReader = .{
        .source = &source,
        .source_base = base,
        .next_byte = 1,
        .bits = 0,
        .bit_count = 0,
        .bit_pos = base * 8,
    };
    try testing.expectEqual(@as(u64, 8), br.availableBits());
    try testing.expectEqual(base + 1, br.loadedBytes());
    br.rewind();
    try testing.expectEqual(@as(usize, 0), br.next_byte);
    try testing.expectEqual(@as(u32, 0xA5), try br.take(8));
    try testing.expectEqual(@as(u64, 0), br.availableBits());
    try testing.expectEqual(base + 1, br.loadedBytes());
}

test "bit reader: takeBytes and skipBytes read at a byte boundary" {
    const source = [_]u8{ 0b0000_0110, 'h', 'i', 'j' };
    var br: BitReader = .init(&source);
    try testing.expectEqual(@as(u32, 6), try br.take(3));
    try br.alignToByte();

    var word: [2]u8 = undefined;
    try br.takeBytes(&word);
    try testing.expectEqualSlices(u8, "hi", &word);
    try br.skipBytes(1);
    try testing.expectEqual(@as(u64, 0), br.availableBits());

    // A starved read leaves the position untouched.
    var short: BitReader = .init(&[_]u8{0x00});
    try short.alignToByte();
    try testing.expectError(error.Truncated, short.takeBytes(&word));
    try testing.expectEqual(@as(u32, 0x00), try short.take(8));
    try testing.expectError(error.Truncated, short.skipBytes(1));
}
