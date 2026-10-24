//! Bitstream readers and writers for the zstd entropy layers.
//!
//! `ForwardReader` reads the FSE table description, the one zstd bitstream that
//! runs forward, from the first byte's least significant bit (`§4.1.1`).
//! `BackwardReader` (FSE-coded streams) and `BackwardFastReader` (Huffman-coded
//! streams) read the others from the last byte toward the first (`§4.1`,
//! `§4.2.2`). The last byte's highest set bit is a marker, not data; the stream
//! is the bits below it, read most significant bit first.
//!
//! `ForwardWriter` and `BackwardWriter` are the encoders' exact inverses: a
//! field written at a position is read back as the same value, so the bytes a
//! writer produces are the bytes the matching reader consumes. The backward
//! writer owns the end marker (`close`), which is why every stream it writes
//! has a nonzero last byte.
//!
//! The backward readers keep an exact bit position. A read past the start of the
//! stream returns zeros and leaves `remainingBits` negative instead of failing,
//! because callers differ: sequence and Huffman streams must end at exactly zero
//! (`§4.2.2`, `§3.1.1.3.2.1.2`), while a Huffman weight series ends on the
//! overflow (`§4.2.1.2`).
//!
//! Format: docs/specs/rfc8878-zstd.txt
//! Lineage (the writer inverses): facebook/zstd v1.5.7 `huf_compress.c`
//! (`HUF_compress1X_usingCTable_internal`) and `fse_compress.c`
//! (`FSE_compress_usingCTable`); attribution in THIRD_PARTY.md.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const readInt = @import("common.zig").readInt;
const writeInt = @import("common.zig").writeInt;

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

    /// Consume `count` bits. Consuming past the end of `source` is allowed; the
    /// caller validates `bytesConsumed`.
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

/// The backward reader for FSE-coded streams (`§4.1`, `§4.2.2`): bits come out
/// most significant first, from the end of `source` toward its start.
///
/// `init` finds the final 1 bit. Reads never fail: past the start of the stream
/// they return zeros, and `overran` reports that this happened. Callers use
/// `isConsumed` where the stream must end exactly.
pub const BackwardReader = struct {
    // The bit window is cached. `container` holds the stream bits
    // `[remaining_bits - held, remaining_bits - 1]` with the next bit to read
    // top-aligned at bit 63 and zeros below the held bits, so a peek is a shift
    // and `skipBits` is a shift and a subtract. One 8-byte load in `refill`
    // covers 57 or more bits. Loading on every read instead serializes each
    // symbol's load address behind the previous read's consume, which measured
    // 98 µs against 83 µs per 64 KiB frame at level 19 on the sequence-heavy
    // corpus. The cache is the shape of the reference's `BIT_DStream` container.
    source: []const u8,
    /// The write-order index one past the next bit to read — the number of
    /// bits not yet consumed. It goes negative when a read runs past the
    /// stream's start; those bits read as zero.
    remaining_bits: i32,
    /// The next `held` stream bits, top-aligned; zeros below.
    container: u64,
    /// How many container bits are real stream bits (0-64).
    held: u7,

    /// Start reading `source` from its end. The last byte's highest set bit is
    /// the final 1 bit, which is not data (`§4.2.2`). Returns `MissingStartBit`
    /// if `source` is empty or its last byte is zero.
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

/// A leaner backward reader for the Huffman-coded streams (`§4.2.2`), with the
/// same exact-position contract as `BackwardReader`.
///
/// The caller decides when the window reloads. Call `reload` once per batch,
/// while at least `batch_bits` bits remain, then use `peekFast` and `skipFast`
/// for reads totalling at most `batch_bits`; they do no checks. `peekBits` and
/// `skipBits` check and reload as needed, for the last partial batch of a stream.
pub const BackwardFastReader = struct {
    // The container holds the window's bytes unshifted and `used` counts the
    // window bits already consumed, so a peek is two shifts and a skip is one
    // add. The Huffman loops reload once per batch of five symbols (five 11-bit
    // codes are 55 bits, under the 57-64 a fresh window holds), so reads inside a
    // batch need no checks. Against `BackwardReader`'s top-aligned container,
    // whose skip shifts the container and serializes the next peek behind it,
    // this measured 0.93 vs 1.34 ns/symbol on the level-19 literals streams
    // (neoverse_v3, the corpus's `skewlit` shape). The FSE layers keep
    // `BackwardReader`: its wide peeks and auto-refill are what the sequences
    // loop is tuned around. The shape follows the reference's `BIT_DStream`.
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

    /// Start reading `source` from its end. The last byte's highest set bit is
    /// the final 1 bit, which is not data (`§4.2.2`). Returns `MissingStartBit`
    /// if `source` is empty or its last byte is zero.
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

/// `(1 << count) - 1` for `count` up to 32.
fn mask64(count: u5) u64 {
    return (@as(u64, 1) << @intCast(count)) - 1;
}

/// The forward writer (`§4.1.1`): fields go out little-endian from the first
/// byte's low bit up, the exact inverse of `ForwardReader`.
///
/// Only the description writer uses it, so it stays small: a field is at
/// most 16 bits (`Table 20`'s widest), and a byte leaves the accumulator
/// as soon as it is full.
pub const ForwardWriter = struct {
    target: []u8,
    /// Whole bytes written to `target`.
    written: usize = 0,
    /// Pending bits, lowest first: bit 0 is the next bit on the wire.
    bits: u32 = 0,
    /// Pending bits in `bits`, below 8 outside `writeBits`.
    bit_count: u5 = 0,

    pub fn init(target: []u8) ForwardWriter {
        return .{ .target = target };
    }

    /// Write the low `count` bits of `value`, least significant bit first.
    /// `error.BufferTooSmall` when `target` is exhausted.
    pub fn writeBits(self: *ForwardWriter, value: u16, count: u5) error{BufferTooSmall}!void {
        assert(count <= 16);
        assert(self.bit_count < 8);
        assert(count == 16 or value >> @intCast(count) == 0);
        self.bits |= @as(u32, value) << self.bit_count;
        self.bit_count += count;
        while (self.bit_count >= 8) {
            if (self.written == self.target.len) return error.BufferTooSmall;
            self.target[self.written] = @truncate(self.bits);
            self.written += 1;
            self.bits >>= 8;
            self.bit_count -= 8;
        }
    }

    /// Flush the final partial byte, zero-filled above its bits: "The
    /// bitstream consumes a round number of bytes. Any remaining bit within
    /// the last byte is simply unused" (`§4.1.1`).
    pub fn finish(self: *ForwardWriter) error{BufferTooSmall}!void {
        if (self.bit_count == 0) return;
        if (self.written == self.target.len) return error.BufferTooSmall;
        self.target[self.written] = @truncate(self.bits);
        self.written += 1;
        self.bits = 0;
        self.bit_count = 0;
    }

    /// The bytes the stream occupies: whole bytes before `finish`, the
    /// rounded-up byte count after it.
    pub fn bytesWritten(self: *const ForwardWriter) usize {
        return self.written + @intFromBool(self.bit_count != 0);
    }
};

/// The backward writer for FSE-coded and Huffman-coded streams (`§4.1`,
/// `§4.2.2`): the exact inverse of `BackwardReader` and `BackwardFastReader`.
///
/// The caller writes its fields in the reverse of the order the decoder reads
/// them, each field's low bit at the lowest free position; `close` writes the
/// final 1 bit and the zero fill. The bits a reader returns for a field are
/// the bits the writer passed, so the two are inverses bit for bit — the
/// property the round-trip tests pin.
pub const BackwardWriter = struct {
    target: []u8,
    /// Whole bytes written to `target`.
    written: usize = 0,
    /// Pending bits, lowest first: bit 0 is the next bit on the wire.
    bits: u64 = 0,
    /// Pending bits in `bits`. A flush keeps it below 8, and the widest field
    /// is 31 bits, so no field ever straddles a flush it cannot fit.
    bit_count: u6 = 0,

    pub fn init(target: []u8) BackwardWriter {
        return .{ .target = target };
    }

    /// Write the low `count` bits of `value`, least significant bit at the
    /// lowest free position. The widest field is the offset alphabet's 31
    /// extra bits (`§3.1.1.3.2.1.1`); a Huffman code and an FSE state are at
    /// most 11. `error.BufferTooSmall` when `target` is exhausted.
    pub fn writeBits(self: *BackwardWriter, value: u32, count: u5) error{BufferTooSmall}!void {
        assert(count <= max_read_bits_wide);
        if (@as(u32, self.bit_count) + count > flush_bits) try self.flushBytes();
        assert(@as(u32, self.bit_count) + count <= 64);
        self.bits |= (@as(u64, value) & mask64(count)) << @intCast(self.bit_count);
        self.bit_count += count;
    }

    /// Close the stream (`§4.2.2`): "The last bit is used as a marker to
    /// signal the end of the stream", and the bits above it are zero fill.
    /// The last byte is therefore never zero.
    pub fn close(self: *BackwardWriter) error{BufferTooSmall}!void {
        try self.writeBits(1, 1);
        const bytes = (self.bit_count + 7) / 8;
        if (self.written + bytes > self.target.len) return error.BufferTooSmall;
        var index: usize = 0;
        while (index < bytes) : (index += 1) {
            self.target[self.written + index] = @truncate(self.bits >> @intCast(8 * index));
        }
        self.written += bytes;
        self.bits = 0;
        self.bit_count = 0;
    }

    /// The stream's length in bytes; meaningful once `close` has run.
    pub fn bytesWritten(self: *const BackwardWriter) usize {
        assert(self.bit_count == 0);
        return self.written;
    }

    /// Flush once the pending bits reach this: with a field of at most 31
    /// bits and a sub-byte remainder of at most 7, the widest write still
    /// fits the container, and a flush never has more than 7 whole bytes.
    const flush_bits: u32 = 56;

    /// Move the whole pending bytes into `target`, keeping the sub-byte
    /// remainder. Flushing early never changes the stream's bits, only when
    /// bytes leave the accumulator.
    fn flushBytes(self: *BackwardWriter) error{BufferTooSmall}!void {
        const bytes = self.bit_count >> 3;
        if (self.written + bytes > self.target.len) return error.BufferTooSmall;
        var index: usize = 0;
        while (index < bytes) : (index += 1) {
            self.target[self.written + index] = @truncate(self.bits >> @intCast(8 * index));
        }
        self.written += bytes;
        self.bits >>= @intCast(8 * bytes);
        self.bit_count &= 7;
    }
};

/// A register-resident `BackwardWriter` for the hot bitstream loops (the
/// Huffman literals streams, the sequences bitstream): the same accumulate
/// and flush-whole-bytes discipline, with the state carried in the loop's
/// locals. A `BackwardWriter`'s fields spill to the stack across its flush
/// call — a store-load round trip per field — which the hot loops cannot
/// afford; this shape costs a shift-or per field and one 8-byte store per
/// flush. The bytes produced are the writer's, exactly: the flush fires at
/// the same pending-bit bound and moves only whole bytes, so the bit stream
/// — and therefore the byte stream — is identical. The 8-byte store can
/// leave up to 7 scratch bytes past the whole bytes; the next store or the
/// close's end-mark byte (which always writes at least one) overwrites them,
/// so only bytes past the returned length can ever hold scratch.
pub const BackwardAccumulator = struct {
    /// Pending bits, lowest first: bit 0 is the next bit on the wire.
    bits: u64,
    /// Pending bits in `bits`, at most `flush_bits` between fields.
    bit_count: u32,

    pub const init: BackwardAccumulator = .{ .bits = 0, .bit_count = 0 };

    /// `BackwardWriter.writeBits`: append the low `count` bits of `value`,
    /// flushing first when they would not fit. `written` is the count of
    /// whole bytes already in `target`, threaded by the caller.
    pub inline fn add(
        self: *BackwardAccumulator,
        target: []u8,
        written: *usize,
        value: u32,
        count: u6,
    ) error{BufferTooSmall}!void {
        assert(count <= max_read_bits_wide);
        if (self.bit_count + count > BackwardWriter.flush_bits) {
            const bytes = self.bit_count >> 3;
            if (written.* + 8 <= target.len) {
                writeInt(u64, target[written.*..][0..8], self.bits);
            } else {
                if (written.* + bytes > target.len) return error.BufferTooSmall;
                for (0..bytes) |index| {
                    target[written.* + index] = @truncate(self.bits >> @intCast(8 * index));
                }
            }
            written.* += bytes;
            self.bits >>= @intCast(8 * bytes);
            self.bit_count &= 7;
        }
        assert(self.bit_count + count <= 64);
        self.bits |= (@as(u64, value) & mask64(@intCast(count))) << @intCast(self.bit_count);
        self.bit_count += count;
    }

    /// Flush the pending whole bytes unconditionally: the caller drives a
    /// fixed flush schedule (a group's fields are bounded, so no per-field
    /// check is needed) and the per-flush branch is the bounds check alone —
    /// predictable until the target's end, where the per-field `add` check
    /// would mispredict on the data's bit lengths. Flushing early moves only
    /// whole bytes, so the stream is the `add` schedule's, exactly.
    pub inline fn flush(
        self: *BackwardAccumulator,
        target: []u8,
        written: *usize,
    ) error{BufferTooSmall}!void {
        const bytes = self.bit_count >> 3;
        if (written.* + 8 <= target.len) {
            writeInt(u64, target[written.*..][0..8], self.bits);
        } else {
            if (written.* + bytes > target.len) return error.BufferTooSmall;
            for (0..bytes) |index| {
                target[written.* + index] = @truncate(self.bits >> @intCast(8 * index));
            }
        }
        written.* += bytes;
        self.bits >>= @intCast(8 * bytes);
        self.bit_count &= 7;
    }

    /// Append the low `count` bits of `value` with no flush: the caller's
    /// fixed schedule guarantees they fit (`bit_count + count <= 64`).
    pub inline fn addUnchecked(self: *BackwardAccumulator, value: u32, count: u6) void {
        assert(self.bit_count + count <= 64);
        self.bits |= (@as(u64, value) & mask64(@intCast(count))) << @intCast(self.bit_count);
        self.bit_count += count;
    }

    /// `BackwardWriter.close`: the single 1-bit end mark, then the zero fill
    /// to the byte boundary, so the last byte is never zero. Returns the
    /// stream's length in bytes.
    pub inline fn close(
        self: *BackwardAccumulator,
        target: []u8,
        written: *usize,
    ) error{BufferTooSmall}!usize {
        // writeBits(1, 1): the bound can be met exactly, and the mark still
        // fits the container without a flush (bit_count is at most 56).
        self.bits |= @as(u64, 1) << @intCast(self.bit_count);
        self.bit_count += 1;
        const bytes = (self.bit_count + 7) / 8;
        if (written.* + bytes > target.len) return error.BufferTooSmall;
        for (0..bytes) |index| {
            target[written.* + index] = @truncate(self.bits >> @intCast(8 * index));
        }
        return written.* + bytes;
    }
};

test "BackwardAccumulator and BackwardWriter produce the same bytes" {
    // The accumulator is the writer's register-resident twin: over random
    // field series of every width a stream carries, both byte sequences and
    // both lengths agree, and the bytes past the accumulator's scratch
    // stores end up written over or past the length.
    var rng: std.Random.DefaultPrng = .init(0xACC0);
    const random = rng.random();
    var expected: [512]u8 = undefined;
    var target: [512]u8 = undefined;
    for (0..200) |_| {
        var writer: BackwardWriter = .init(&expected);
        var acc: BackwardAccumulator = .init;
        var written: usize = 0;
        const count = random.uintLessThan(usize, 64) + 1;
        for (0..count) |_| {
            const width = random.uintLessThan(u5, max_read_bits_wide) + 1;
            const value = random.uintLessThan(u32, @as(u32, 1) << @intCast(width));
            try writer.writeBits(value, width);
            try acc.add(&target, &written, value, width);
        }
        try writer.close();
        const length = try acc.close(&target, &written);
        try testing.expectEqual(writer.bytesWritten(), length);
        try testing.expectEqualSlices(u8, expected[0..length], target[0..length]);
    }
}

test "BackwardWriter and BackwardReader are inverses, field for field" {
    // RFC 8878 §4.1 — a field written at a position reads back as the same
    // value: the writer's low bit is the reader's last bit of the field. The
    // sweep covers every width a stream uses (1 to 31 bits) and a stream long
    // enough to flush mid-field several times.
    var rng: std.Random.DefaultPrng = .init(0xBACC);
    var target: [256]u8 = undefined;
    for (0..200) |_| {
        var writer = BackwardWriter.init(&target);
        var fields: [64]struct { value: u32, count: u5 } = undefined;
        const count = rng.random().uintLessThan(usize, fields.len) + 1;
        for (fields[0..count]) |*field| {
            const width = rng.random().uintLessThan(u5, max_read_bits_wide) + 1;
            field.* = .{
                .value = rng.random().uintLessThan(u32, @as(u32, 1) << width),
                .count = width,
            };
            try writer.writeBits(field.value, field.count);
        }
        try writer.close();
        const stream = target[0..writer.bytesWritten()];
        // The last byte carries the end marker, so it is never zero.
        try testing.expect(stream[stream.len - 1] != 0);
        var reader = try BackwardReader.init(stream);
        // The reader meets the fields in the reverse of the write order.
        for (fields[0..count], 0..) |_, index| {
            const last = fields[count - 1 - index];
            try testing.expectEqual(last.value, reader.readBits32(last.count));
        }
        try testing.expect(reader.isConsumed());
    }
}

test "ForwardWriter and ForwardReader are inverses" {
    // RFC 8878 §4.1.1 — the description's bitstream: a field written at a
    // position reads back as the same value, and the byte count rounds up.
    var target: [32]u8 = undefined;
    var writer = ForwardWriter.init(&target);
    try writer.writeBits(0b1011, 4);
    try writer.writeBits(0b0101, 4);
    try writer.writeBits(0b100, 3);
    try writer.writeBits(0b00110, 5);
    // The description writer's zero-run shortcut is one 16-bit write of
    // eight 3-valued 2-bit flags; the reader takes them two bits at a time.
    try writer.writeBits(0xffff, 16);
    try writer.finish();
    var reader = ForwardReader.init(target[0..writer.bytesWritten()]);
    try testing.expectEqual(@as(u16, 0b1011), reader.readBits(4));
    try testing.expectEqual(@as(u16, 0b0101), reader.readBits(4));
    try testing.expectEqual(@as(u16, 0b100), reader.readBits(3));
    try testing.expectEqual(@as(u16, 0b00110), reader.readBits(5));
    for (0..8) |_| try testing.expectEqual(@as(u16, 3), reader.readBits(2));
    try testing.expectEqual(@as(usize, 4), reader.bytesConsumed());
    try testing.expectEqual(@as(usize, 4), writer.bytesWritten());
}

test "the writers stop at the target's end" {
    // The encoders' targets are caller-sized, so an exhausted target is an
    // error, never a write past it.
    var none: [0]u8 = undefined;
    var forward = ForwardWriter.init(&none);
    try testing.expectError(error.BufferTooSmall, forward.writeBits(0xff, 8));
    var backward = BackwardWriter.init(&none);
    try testing.expectError(error.BufferTooSmall, backward.close());
    var one: [1]u8 = undefined;
    var tight = BackwardWriter.init(&one);
    try tight.writeBits(0, 8);
    try testing.expectError(error.BufferTooSmall, tight.close());
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
    // RFC 8878 §4.2.2 — the hand-built stream `01 0D` (`golden.pair_stream`):
    // the last byte 0x0d has its final 1 bit at bit 3, and the useful bits run
    // down from bit 2.
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
