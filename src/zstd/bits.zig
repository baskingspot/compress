//! The two bitstream readers the zstd entropy layers share.
//!
//! The **forward** reader is the one zstd bitstream read forward: the FSE
//! table description of `§4.1.1` ("A bitstream is read forward, in
//! little-endian fashion"), where the first bit of the first byte is the
//! least significant bit of the first field.
//!
//! The **backward** reader is every other bitstream — the FSE data streams
//! (`§4.1`) and the Huffman-coded streams (`§4.2.2`): "all FSE bitstreams are
//! read from end to beginning. Note that the order of the bits in the stream
//! is not reversed; they are simply read in the reverse order from which they
//! were written." The last byte's highest set bit is the final 1 bit that
//! marks where the useful bits end (`§4.2.2`: "a last byte of 0 is not
//! possible. And the final-bit-flag itself is not part of the useful
//! bitstream"); above it is zero padding, below it the stream runs backward,
//! most significant bit of each field first.
//!
//! The backward reader keeps an exact bit position: `remainingBits` counts
//! the bits not yet consumed, and a read that runs past the stream's start
//! drives it negative with the missing bits reading as zero. That is the
//! state the callers need, because the two consumption contracts differ:
//! the sequences stream and the Huffman streams must be "entirely and
//! exactly consumed" (`§4.2.2`, `§3.1.1.3.2.1.2`), while the FSE-compressed
//! Huffman weights terminate *on* the overflow — "if updating state after
//! decoding a symbol would require more bits than remain in the stream, it
//! is assumed that extra bits are zero. Then, symbols for each of the final
//! states are decoded and the process is complete" (`§4.2.1.2`).
//!
//! Format: docs/research/specs/rfc8878-zstd.txt

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const readInt = @import("common.zig").readInt;

/// The most bits one narrow read takes: a 9-bit FSE accuracy log, an 11-bit
/// Huffman code, or a 9-bit `§4.1.1` Table 20 field (`2 * threshold - 1` is
/// at most `2 * 256 - 1`).
pub const max_read_bits: u5 = 11;

/// The most bits one wide read takes: the offset alphabet's extra-bits
/// fields go to 31 (`§3.1.1.3.2.1.1`). A refill leaves the backward reader
/// holding at least 57 bits, so even the widest read never refills twice.
pub const max_read_bits_wide: u5 = 31;

/// The forward reader (`§4.1.1`): fields are read little-endian from the
/// first byte's low bit up.
pub const ForwardReader = struct {
    source: []const u8,
    /// The number of bits consumed so far, counted from the first byte's
    /// least significant bit.
    consumed_bits: usize,

    pub fn init(source: []const u8) ForwardReader {
        return .{ .source = source, .consumed_bits = 0 };
    }

    /// The next `count` bits, without consuming them: the first bit read is
    /// the value's least significant bit (`§4.1.1`).
    ///
    /// Bits past the source's end read as zero — the reference reads a
    /// description through a zero-padded window and then checks the byte
    /// count it consumed against the buffer it was given
    /// (`FSE_readNCount`'s `countSize > hbSize` rule), so the padding is the
    /// caller's to validate, not the reader's to refuse.
    pub fn peekBits(self: ForwardReader, count: u5) u16 {
        assert(count <= max_read_bits);
        var value: u16 = 0;
        var taken: u5 = 0;
        while (taken < count) {
            const index = self.consumed_bits + taken;
            const in_byte: u5 = @intCast(index & 7);
            const take = @min(@as(u5, 8) - in_byte, count - taken);
            const chunk = if (index >> 3 < self.source.len)
                @as(u16, self.source[index >> 3] >> @intCast(in_byte))
            else
                0;
            value |= (chunk & mask(take)) << @intCast(taken);
            taken += take;
        }
        return value;
    }

    /// Consume `count` bits a `peekBits` proved are there. Consumption may
    /// run past the source's end — `bytesConsumed` is what the caller
    /// validates — so this only adds.
    pub fn skipBits(self: *ForwardReader, count: u5) void {
        self.consumed_bits += count;
    }

    /// Read `count` bits.
    pub fn readBits(self: *ForwardReader, count: u5) u16 {
        const value = self.peekBits(count);
        self.skipBits(count);
        return value;
    }

    /// The whole bytes consumed: "The bitstream consumes a round number of
    /// bytes. Any remaining bit within the last byte is simply unused"
    /// (`§4.1.1`), so this rounds up.
    pub fn bytesConsumed(self: ForwardReader) usize {
        return (self.consumed_bits + 7) / 8;
    }
};

/// The backward reader (`§4.1`, `§4.2.2`).
///
/// The bit window is cached: `container` holds the stream bits
/// `[remaining_bits - held, remaining_bits - 1]` with the next bit to read
/// top-aligned at bit 63 and zeros below the held bits, so a peek is a shift
/// and `skipBits` a shift-and-subtract; `refill`'s one 8-byte load
/// amortizes over the 57+ bits it covers. Reloading per read instead — the
/// same load with no cache — serializes every symbol's load address on the
/// previous read's consume; the cache is the reference's `BIT_DStream`
/// container shape (reload-per-read measured against it on the
/// sequence-heavy corpus: 98 µs vs 83 µs per 64 KiB frame at level 19).
pub const BackwardReader = struct {
    source: []const u8,
    /// The write-order index one past the next bit to read — the number of
    /// bits not yet consumed. It goes negative when a read runs past the
    /// stream's start; those bits read as zero.
    remaining_bits: i32,
    /// The next `held` stream bits, top-aligned; zeros below.
    container: u64,
    /// How many container bits are real stream bits (0-64).
    held: u7,

    /// The last byte's highest set bit is the final 1 bit (`§4.2.2`); a last
    /// byte of zero has no start bit at all.
    pub fn init(source: []const u8) error{MissingStartBit}!BackwardReader {
        if (source.len == 0) return error.MissingStartBit;
        const last = source[source.len - 1];
        if (last == 0) return error.MissingStartBit;
        // Bits below the final 1 bit of the last byte, plus every bit of the
        // bytes before it: `§4.2.2`'s "between 0 and 7 useful bits".
        const useful: i32 = @intCast(8 * (source.len - 1) + highBit(last));
        return .{
            .source = source,
            .remaining_bits = useful,
            .container = 0,
            .held = 0,
        };
    }

    /// The next `count` bits, without consuming them. The first bit read is
    /// the value's most significant bit; bits past the stream's start read
    /// as zero.
    pub fn peekBits(self: *BackwardReader, count: u5) u16 {
        assert(count <= max_read_bits);
        return @intCast(self.peekWindow(count));
    }

    /// The next `count` bits, without consuming them — the wide form for the
    /// sequences section's extra bits (up to 31, `§3.1.1.3.2.1.1`).
    pub fn peekBits32(self: *BackwardReader, count: u5) u32 {
        assert(count <= max_read_bits_wide);
        return @intCast(self.peekWindow(count));
    }

    /// The window both peeks share: the container's top `count` bits. The
    /// container is zero below its held bits, so a read wider than what is
    /// held — only possible once the whole stream is held — zero-fills,
    /// which is exactly the overflow condition the callers test for
    /// (`§4.2.1.2`).
    fn peekWindow(self: *BackwardReader, count: u6) u64 {
        if (count == 0) return 0;
        if (self.held < count) self.refill();
        // count >= 1 above, so the right shift is 33-63 — a u7
        // intermediate, because 64 itself escapes a u6.
        return self.container >> @intCast(@as(u7, 64) - count);
    }

    /// Reload the container to cover the 57-64 stream bits ending at the
    /// current position (fewer near the stream's start, where the load
    /// zero-pads and `held` caps at what the stream holds).
    fn refill(self: *BackwardReader) void {
        // Past the stream's start nothing is left to load, and the
        // container's stale bits must not read again.
        if (self.remaining_bits <= 0) {
            self.container = 0;
            self.held = 0;
            return;
        }
        if (self.remaining_bits <= self.held) return;
        const position: u32 = @intCast(self.remaining_bits - 1);
        const byte = position >> 3;
        const bit: u3 = @intCast(position & 7);
        // The 8 bytes ending at `byte`, little-endian, put the next bit at
        // window bit 56 + bit; the left shift top-aligns it at bit 63. Near
        // the stream's start a partial load shifted to the top keeps the
        // same math, and the zero fill below is the read-as-zero rule.
        const window: u64 = if (byte >= 7)
            readInt(u64, self.source[byte - 7 ..][0..8])
        else blk: {
            var w: u64 = 0;
            for (self.source[0 .. byte + 1], 0..) |b, j| w |= @as(u64, b) << @intCast(8 * j);
            break :blk w << @intCast(8 * (7 - byte));
        };
        self.container = window << @intCast(7 - bit);
        self.held = @intCast(@min(self.remaining_bits, @as(i32, 57) + bit));
    }

    /// Consume `count` bits.
    pub fn skipBits(self: *BackwardReader, count: u5) void {
        assert(count <= max_read_bits_wide);
        self.remaining_bits -= count;
        // A peek refills until `held >= count` or everything left is held,
        // so a skip past the held bits is always a skip past the stream's
        // start; the left shift keeps the next unconsumed bit top-aligned.
        if (count <= self.held) {
            self.container <<= count;
            self.held -= count;
        } else {
            self.container = 0;
            self.held = 0;
        }
    }

    /// Read `count` bits.
    pub fn readBits(self: *BackwardReader, count: u5) u16 {
        const value = self.peekBits(count);
        self.skipBits(count);
        return value;
    }

    /// Read `count` bits — the wide form (`peekBits32`).
    pub fn readBits32(self: *BackwardReader, count: u5) u32 {
        const value = self.peekBits32(count);
        self.skipBits(count);
        return value;
    }

    /// The bits not yet consumed; negative once a read ran past the stream's
    /// start.
    pub fn remainingBits(self: BackwardReader) i32 {
        return self.remaining_bits;
    }

    /// A read ran past the stream's start (`§4.2.1.2`'s overflow).
    pub fn overran(self: BackwardReader) bool {
        return self.remaining_bits < 0;
    }

    /// Every bit consumed and none left over: the exact end `§4.2.2` and
    /// `§3.1.1.3.2.1.2` demand.
    pub fn isConsumed(self: BackwardReader) bool {
        return self.remaining_bits == 0;
    }
};

/// The lean backward reader for the Huffman streams (`§4.2.2`): the same
/// exact-position contract as `BackwardReader`, in the reference's
/// `BIT_DStream` shape — the container is the window's bytes *unshifted*
/// and `used` counts the window bits already consumed, so a peek is two
/// shifts and a skip is one add; the reload walks the window toward the
/// stream's start and is the caller's cadence, not a per-peek branch.
///
/// The Huffman loops reload once per batch of five symbols (five 11-bit
/// codes = 55 bits, always under a fresh window's 57-64), so the batch's
/// peeks and skips carry no checks at all. The measured difference against
/// `BackwardReader`'s top-aligned container (whose skip shifts the
/// container, serializing the next peek behind it): 0.93 vs 1.34 ns/symbol
/// on the level-19 literals streams (neoverse_v3, the corpus's `skewlit`
/// shape's streams). The FSE layers keep
/// `BackwardReader` (its wide peeks and auto-refill are the shape the
/// sequences loop is tuned around).
pub const BackwardFastReader = struct {
    source: []const u8,
    /// The window's lowest byte in the stream; the container holds
    /// `source[pos..][0..8]` little-endian, zero-padded past the stream's
    /// end (the padding above the final 1 bit reads as zero, `§4.2.2`).
    pos: usize,
    /// The window's bytes, little-endian; the next unread bit is bit
    /// `63 - used`.
    container: u64,
    /// Window bits consumed from the top. May reach 64 only at the stream's
    /// start (the whole stream held); past it reads are the caller's bug or
    /// a corrupt stream the end checks catch.
    used: u32,
    /// The bits not yet consumed; negative once a read ran past the
    /// stream's start. The exact end contract's counter.
    remaining_bits: i32,

    /// The last byte's highest set bit is the final 1 bit (`§4.2.2`); a
    /// last byte of zero has no start bit at all.
    pub fn init(source: []const u8) error{MissingStartBit}!BackwardFastReader {
        if (source.len == 0) return error.MissingStartBit;
        const last = source[source.len - 1];
        if (last == 0) return error.MissingStartBit;
        const useful: i32 = @intCast(8 * (source.len - 1) + highBit(last));
        const pos = source.len -| 8;
        // The window's top is the last byte's bit 7 (loadWindow top-aligns
        // a short stream); skip the zero padding above the final 1 bit and
        // the flag itself.
        const used: u32 = 8 - @as(u32, highBit(last)); // padding + flag
        return .{
            .source = source,
            .pos = pos,
            .container = loadWindow(source, pos),
            .used = used,
            .remaining_bits = useful,
        };
    }

    /// The bits not yet consumed; negative once a read ran past the
    /// stream's start.
    pub fn remainingBits(self: BackwardFastReader) i32 {
        return self.remaining_bits;
    }

    /// A read ran past the stream's start (`§4.2.1.2`'s overflow).
    pub fn overran(self: BackwardFastReader) bool {
        return self.remaining_bits < 0;
    }

    /// Every bit consumed and none left over: the exact end `§4.2.2`
    /// demands.
    pub fn isConsumed(self: BackwardFastReader) bool {
        return self.remaining_bits == 0;
    }

    /// A reload's guarantee: with at least `batch_bits` unconsumed, a
    /// `reload` leaves at least 57 window bits live (the window refills to
    /// 64 minus the sub-byte remainder), and a batch of reads summing under
    /// `batch_bits` never needs a check.
    pub const batch_bits: i32 = 55;

    /// Walk the window toward the stream's start past the consumed bytes.
    pub fn reload(self: *BackwardFastReader) void {
        const drop = @min(self.used >> 3, self.pos);
        self.pos -= drop;
        self.used -= drop * 8;
        self.container = loadWindow(self.source, self.pos);
    }

    /// The next `count` bits without consuming them, the batch form: the
    /// caller's `reload` covered the whole batch, so no check runs here.
    /// The first bit read is the value's most significant bit.
    pub fn peekFast(self: *const BackwardFastReader, count: u6) u16 {
        assert(count >= 1);
        assert(count <= max_read_bits);
        assert(self.used + count <= 64);
        return @intCast((self.container << @intCast(self.used)) >> @intCast(@as(u7, 64) - count));
    }

    /// Consume `count` bits a `peekFast` returned: one add per counter.
    pub fn skipFast(self: *BackwardFastReader, count: u6) void {
        assert(count <= max_read_bits);
        self.used += count;
        self.remaining_bits -= count;
    }

    /// The next `count` bits without consuming them, the careful form for
    /// the stream's last partial batch: reloads when the window cannot
    /// cover the read. Past the stream's start the window is the whole
    /// stream and reads zero-fill — the corrupt stream's symbols come out
    /// of the padding and the end checks catch the overrun, exactly as
    /// `BackwardReader`'s; the clamp only keeps the shift defined past it.
    pub fn peekBits(self: *BackwardFastReader, count: u5) u16 {
        assert(count >= 1);
        assert(count <= max_read_bits);
        if (self.used > 64 - @as(u32, max_read_bits)) self.reload();
        // The whole stream held and drained: the read-as-zero rule
        // (`§4.2.1.2`), exact — the differential sweep against
        // `BackwardReader` pins it.
        if (self.used >= 64) return 0;
        return @intCast((self.container << @intCast(self.used)) >> @intCast(@as(u7, 64) - count));
    }

    /// Consume `count` bits a `peekBits` returned.
    pub fn skipBits(self: *BackwardFastReader, count: u5) void {
        assert(count <= max_read_bits);
        self.used += count;
        self.remaining_bits -= count;
    }
};

/// The 8 stream bytes at `pos`, little-endian. A short stream's window is
/// top-aligned: the bytes past the stream's end (above the final 1 bit) are
/// the zero padding `§4.2.2` gives them, and the bytes below the stream's
/// start read as the zero fill an overrun reads.
inline fn loadWindow(source: []const u8, pos: usize) u64 {
    if (pos + 8 <= source.len) return readInt(u64, source[pos..][0..8]);
    var window: u64 = 0;
    for (source[pos..], 0..) |b, j| window |= @as(u64, b) << @intCast(8 * j);
    return window << @intCast(8 * (8 - (source.len - pos)));
}

/// `(1 << count) - 1`, for `count` up to `max_read_bits`.
fn mask(count: u5) u16 {
    return (@as(u16, 1) << @intCast(count)) - 1;
}

/// The index of the highest set bit; `value` must be nonzero.
fn highBit(value: u8) u3 {
    assert(value != 0);
    return @intCast(7 - @clz(value));
}

test "ForwardReader reads fields little-endian from the first byte's low bit" {
    // RFC 8878 §4.1.1 — "A bitstream is read forward, in little-endian
    // fashion": the first field is the low bits of the first byte.
    var reader = ForwardReader.init(&.{ 0b1011_0101, 0b0011_0100 });
    try testing.expectEqual(@as(u16, 0b0101), reader.readBits(4));
    try testing.expectEqual(@as(u16, 0b1011), reader.readBits(4));
    // A field may cross the byte boundary: the second byte's low 3 bits are
    // 100 and the 5 above them 00110, least significant bit first.
    try testing.expectEqual(@as(u16, 0b100), reader.readBits(3));
    try testing.expectEqual(@as(u16, 0b00110), reader.readBits(5));
    try testing.expectEqual(@as(usize, 2), reader.bytesConsumed());
    // Past the source's end the bits read as zero; the caller checks the
    // byte count it consumed (the reference's own padding rule).
    try testing.expectEqual(@as(u16, 0), reader.readBits(1));
    try testing.expectEqual(@as(usize, 3), reader.bytesConsumed());
}

test "ForwardReader rounds its byte count up: a description consumes whole bytes" {
    // RFC 8878 §4.1.1 — "The bitstream consumes a round number of bytes. Any
    // remaining bit within the last byte is simply unused."
    var reader = ForwardReader.init(&.{0xff});
    _ = reader.readBits(4);
    try testing.expectEqual(@as(usize, 1), reader.bytesConsumed());
    _ = reader.readBits(1);
    try testing.expectEqual(@as(usize, 1), reader.bytesConsumed());
    try testing.expectEqual(@as(u16, 0b111), reader.readBits(3));
    try testing.expectEqual(@as(usize, 1), reader.bytesConsumed());
    try testing.expectEqual(@as(u16, 0), reader.peekBits(0));
    // A peek past the end reads zero without consuming.
    try testing.expectEqual(@as(u16, 0), reader.peekBits(1));
    try testing.expectEqual(@as(usize, 1), reader.bytesConsumed());
}

test "BackwardReader skips the padding and the final 1 bit, then reads MSB first" {
    // RFC 8878 §4.2.2 — the hand-built T1 pair's `01 0D` stream
    // (docs/research/zstd-notes.md §5.4): the last byte 0x0d has its final 1
    // bit at bit 3, and the useful bits run down from bit 2.
    var reader = try BackwardReader.init(&.{ 0x01, 0x0d });
    try testing.expectEqual(@as(i32, 11), reader.remainingBits());
    // 1 | 01 | 0000 | 0001 — the Table 25 codes for 0, 1, 4, 5 read in
    // forward order (the stream is written in reverse).
    try testing.expectEqual(@as(u16, 1), reader.readBits(1));
    try testing.expectEqual(@as(u16, 0b01), reader.readBits(2));
    try testing.expectEqual(@as(u16, 0b0000), reader.readBits(4));
    try testing.expectEqual(@as(u16, 0b0001), reader.readBits(4));
    try testing.expect(reader.isConsumed());
}

test "BackwardReader: a peek does not consume, a skip does" {
    // RFC 8878 §4.1 — the Huffman decode peeks a full code width and then
    // discards only the code's own bits.
    var reader = try BackwardReader.init(&.{0b0000_0001});
    // One byte: the final 1 bit is bit 0, so nothing below it is useful.
    try testing.expectEqual(@as(i32, 0), reader.remainingBits());
    try testing.expect(reader.isConsumed());
    var wide = try BackwardReader.init(&.{ 0b0000_0010, 0b0000_0011 });
    // 0x03's highest set bit is bit 1, so two useful bits are below it, then
    // all eight bits of 0x02: 10 | 00000010.
    try testing.expectEqual(@as(u16, 0b1000_0001), wide.peekBits(8));
    wide.skipBits(2);
    // The next eight bits run past the stream's start, so the last one
    // reads as zero.
    try testing.expectEqual(@as(u16, 0b0000_0100), wide.peekBits(8));
    try testing.expectEqual(@as(i32, 7), wide.remainingBits());
}

test "BackwardReader: a zero last byte has no start bit" {
    // RFC 8878 §4.2.2 — "a last byte of 0 is not possible".
    try testing.expectError(error.MissingStartBit, BackwardReader.init(&.{ 0x01, 0x00 }));
    try testing.expectError(error.MissingStartBit, BackwardReader.init(&.{}));
}

test "BackwardReader: reads past the stream's start are zero and overrun" {
    // RFC 8878 §4.2.1.2 — "if updating state after decoding a symbol would
    // require more bits than remain in the stream, it is assumed that extra
    // bits are zero".
    var reader = try BackwardReader.init(&.{0b0000_0001});
    try testing.expectEqual(@as(u16, 0), reader.remainingBits());
    try testing.expectEqual(@as(u16, 0b000), reader.readBits(3));
    try testing.expectEqual(@as(i32, -3), reader.remainingBits());
    try testing.expect(reader.overran());
    try testing.expectEqual(@as(u16, 0b0_0000_0000), reader.readBits(10));
    try testing.expectEqual(@as(i32, -13), reader.remainingBits());
    try testing.expect(!reader.isConsumed());
}

test "BackwardFastReader: the lean reader agrees with BackwardReader bit for bit" {
    // The differential sweep: pseudo-random streams (valid start bit, every
    // length class across the 8-byte window), pseudo-random read widths —
    // both readers must return the same bits, the same remaining count, and
    // the same overrun/consumed verdicts, past the stream's start included
    // (the read-as-zero rule and the exact end contract, §4.2.2).
    var rng: std.Random.DefaultPrng = .init(0xB17E);
    var source: [40]u8 = undefined;
    for (0..200) |_| {
        const len = rng.random().uintLessThan(usize, source.len) + 1;
        rng.random().bytes(source[0..len]);
        // A nonzero last byte: the start bit both readers anchor on.
        source[len - 1] |= @as(u8, 1) << rng.random().int(u3);
        var slow = try BackwardReader.init(source[0..len]);
        var fast = try BackwardFastReader.init(source[0..len]);
        try testing.expectEqual(slow.remainingBits(), fast.remainingBits());
        // Reads run well past the start: the overrun side is the contract's
        // interesting half.
        while (true) {
            const count = rng.random().uintLessThan(u5, max_read_bits) + 1;
            try testing.expectEqual(slow.peekBits(count), fast.peekBits(count));
            slow.skipBits(count);
            fast.skipBits(count);
            try testing.expectEqual(slow.remainingBits(), fast.remainingBits());
            try testing.expectEqual(slow.overran(), fast.overran());
            if (slow.remainingBits() < -32) break;
        }
        try testing.expectEqual(slow.isConsumed(), fast.isConsumed());
    }
}

test "BackwardFastReader: the batch cadence matches the careful path" {
    // §4.2.2 — a stream decoded in reload-separated batches must equal the
    // same stream decoded carefully, bits and end position alike.
    var rng: std.Random.DefaultPrng = .init(0xBA7C4);
    var source: [64]u8 = undefined;
    for (0..100) |_| {
        const len = rng.random().uintLessThan(usize, source.len) + 1;
        rng.random().bytes(source[0..len]);
        source[len - 1] |= @as(u8, 1) << rng.random().int(u3);
        var batched = try BackwardFastReader.init(source[0..len]);
        var careful = try BackwardFastReader.init(source[0..len]);
        while (batched.remainingBits() >= BackwardFastReader.batch_bits) {
            batched.reload();
            for (0..5) |_| {
                const count = rng.random().uintLessThan(u5, max_read_bits) + 1;
                try testing.expectEqual(careful.peekBits(count), batched.peekFast(count));
                careful.skipBits(count);
                batched.skipFast(count);
            }
        }
        while (!careful.overran()) {
            const count = rng.random().uintLessThan(u5, max_read_bits) + 1;
            try testing.expectEqual(careful.peekBits(count), batched.peekBits(count));
            careful.skipBits(count);
            batched.skipBits(count);
        }
        try testing.expectEqual(careful.remainingBits(), batched.remainingBits());
    }
}
