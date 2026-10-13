//! The brotli stream header (`§9.1`) and the meta-block ladder (`§9.2`):
//! WBITS and the window arithmetic, ISLAST/ISLASTEMPTY, MNIBBLES/MLEN, the
//! metadata and uncompressed meta-block forms, and the stream end with its
//! zero fill.
//!
//! The ladder stops where a compressed meta-block's own header begins. The
//! block-type counts (NBLTYPESL/I/D) and the prefix-code descriptions they
//! interleave with are one wire sequence, so they are the tree layer's to
//! read; the position after `nextMetaBlock` returns `.compressed` is
//! NBLTYPESL's first bit.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const fastmem = @import("fastmem");

const bits = @import("bits.zig");
const golden = @import("golden.zig");
const internal = @import("../internal/root.zig");

/// Everything the framing layer reports: the bit reader's own refusals plus
/// this layer's names. The names are the `decompress` error set's header and
/// ladder rows (`README.md`), name for name.
pub const Error = error{
    /// `§9.1` — WBITS is the invalid pattern 0010001.
    BadWindowBits,
    /// `§9.2` — the metadata meta-block's reserved bit is set.
    ReservedBit,
    /// `§9.2` — MNIBBLES > 4 with an all-zero last nibble.
    ExuberantNibble,
    /// `§9.2` — MSKIPBYTES > 1 with an all-zero last byte.
    ExuberantMetaNibble,
} || bits.Error;

/// `§9.1` — the stream header has exactly one field.
pub const StreamHeader = struct {
    /// WBITS, 10..24.
    wbits: u5,
    /// `§9.1` — "window size = (1 << WBITS) - 16": the maximum value of any
    /// non-dictionary reference backward distance (`§2`), 1,008 bytes to
    /// 16,777,200.
    window_size: u32,
};

/// `§9.1` — read WBITS. The 1..7-bit code is `0` for 16, `0011`..`1111`
/// (read low bit first) for 18..24, `0000001` for 17, and
/// `0100001`..`1110001` for 10..15; `0010001` "is invalid and must not be
/// used".
pub fn readStreamHeader(br: *bits.BitReader) Error!StreamHeader {
    if ((try br.take(1)) == 0) return window(16);
    const short = try br.take(3);
    if (short != 0) return window(@intCast(17 + short));
    const long = try br.take(3);
    if (long == 1) return error.BadWindowBits;
    if (long != 0) return window(@intCast(8 + long));
    return window(17);
}

/// The kind of meta-block the ladder found: the two forms that carry
/// uncompressed data. The empty forms do not produce a value at all —
/// `nextMetaBlock` returns `null` for them.
pub const Kind = enum {
    /// ISUNCOMPRESSED=1 (`§9.2`): MLEN bytes of literal data follow at the
    /// next byte boundary. "An uncompressed meta-block cannot be the last
    /// meta-block" (`§2`).
    uncompressed,
    /// The compressed form. Its header continues with NBLTYPESL at the
    /// current bit position; the tree layer owns everything from there.
    compressed,
};

/// A meta-block header (`§9.2`), as much as the framing layer reads.
pub const MetaBlock = struct {
    kind: Kind,
    /// MLEN: the meta-block's uncompressed length, 1..16777216 (`§2`).
    mlen: u32,
    /// ISLAST: the stream ends after this meta-block's data. The last
    /// byte's zero fill (`§9.3`) is the caller's check once the data is
    /// decoded — `bits.BitReader.alignToByte` — because for a non-empty
    /// meta-block it lies past the data, not in this header.
    is_last: bool,
};

/// `§9.2`, `§10` — read the next meta-block header. Metadata meta-blocks are
/// skipped here: they are "not part of either the sliding window or the
/// uncompressed data", and "not used as context bytes for literals" (`§2`),
/// so nothing above this layer sees them. `null` means the stream ends at
/// the current position: ISLAST+ISLASTEMPTY, or a metadata meta-block with
/// ISLAST set, whose zero fill was verified.
pub fn nextMetaBlock(br: *bits.BitReader) Error!?MetaBlock {
    while (true) {
        const is_last = (try br.take(1)) != 0;
        if (is_last) {
            if ((try br.take(1)) != 0) {
                // §9.2: "the meta-block and the brotli stream ends at that
                // bit, with any remaining bits in the last byte of the
                // compressed stream filled with zeros".
                try br.alignToByte();
                return null;
            }
        }
        const mnibbles = try readMnibbles(br);
        if (mnibbles == 0) {
            try skipMetadata(br);
            // A metadata meta-block with ISLAST set ends the stream too:
            // §10's loop exits on ISLAST after skipping the metadata, and
            // both references implement it that way. The stream ends on the
            // byte boundary the metadata payload already reached.
            if (is_last) return null;
            continue;
        }
        const mlen = try readMlen(br, mnibbles);
        if (!is_last) {
            if ((try br.take(1)) != 0) {
                // §9.2: ISUNCOMPRESSED's skipped bits "must be all zeros"
                // (the references' PADDING_1 site).
                try br.alignToByte();
                return .{ .kind = .uncompressed, .mlen = mlen, .is_last = false };
            }
        }
        return .{ .kind = .compressed, .mlen = mlen, .is_last = is_last };
    }
}

/// `§9.2` — the 1..11-bit variable-length code shared by NBLTYPESL, NBLTYPESI,
/// NBLTYPESD, NTREESL, and NTREESD: the values 1..256, "as it appears in the
/// compressed data, where the bits are parsed from right to left". Returns
/// the count itself: the wire encodes count - 1, `0` being the single bit 0.
pub fn readCount(br: *bits.BitReader) Error!u32 {
    if ((try br.take(1)) == 0) return 1;
    const nbits = try br.take(3);
    if (nbits == 0) return 2;
    const extra = try br.take(@intCast(nbits));
    return (@as(u32, 1) << @intCast(nbits)) + extra + 1;
}

/// `§9.1` — the window arithmetic, for the 10..24 WBITS values.
fn window(wbits: u5) StreamHeader {
    assert(wbits >= 10);
    assert(wbits <= 24);
    return .{ .wbits = wbits, .window_size = (@as(u32, 1) << wbits) - 16 };
}

/// `§9.2` — the 2-bit MNIBBLES code: `11` is the metadata form (0 nibbles),
/// `00`/`01`/`10` are 4, 5, and 6 nibbles of MLEN-1.
fn readMnibbles(br: *bits.BitReader) Error!u32 {
    const code = try br.take(2);
    if (code == 3) return 0;
    return code + 4;
}

/// `§9.2` — MLEN-1, in MNIBBLES 4-bit nibbles, least significant first. With
/// MNIBBLES > 4 "the last nibble" (the most significant one, read last) must
/// not be zero.
fn readMlen(br: *bits.BitReader, mnibbles: u32) Error!u32 {
    assert(mnibbles >= 4);
    assert(mnibbles <= 6);
    var value: u32 = 0;
    var i: u32 = 0;
    while (i < mnibbles) : (i += 1) {
        const nibble = try br.take(4);
        if (mnibbles > 4 and i + 1 == mnibbles and nibble == 0) return error.ExuberantNibble;
        value |= nibble << @intCast(i * 4);
    }
    return value + 1;
}

/// `§9.2` — a metadata meta-block: the reserved bit, MSKIPBYTES, MSKIPLEN-1,
/// zero fill to the byte boundary, then MSKIPLEN bytes skipped. Those bytes
/// are never output, never window, and never literal context (`§2`).
fn skipMetadata(br: *bits.BitReader) Error!void {
    if ((try br.take(1)) != 0) return error.ReservedBit;
    const mskip_bytes = try br.take(2);
    var mskip_len: u32 = 0;
    if (mskip_bytes != 0) {
        var value: u32 = 0;
        var i: u32 = 0;
        while (i < mskip_bytes) : (i += 1) {
            const byte = try br.take(8);
            if (mskip_bytes > 1 and i + 1 == mskip_bytes and byte == 0) {
                return error.ExuberantMetaNibble;
            }
            value |= byte << @intCast(i * 8);
        }
        mskip_len = value + 1;
    }
    try br.alignToByte();
    try br.skipBytes(mskip_len);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Drive the ladder over a stream whose meta-blocks are all of the
/// entropy-free kinds, collecting the output. Test-only: the real decode loop
/// arrives with the command layer, and `error.Compressed` is this helper's
/// marker for a stream that layer cannot decode yet.
fn decodeEntropyFree(source: []const u8, target: []u8) !usize {
    var br: bits.BitReader = .init(source);
    _ = try readStreamHeader(&br);
    var out_pos: usize = 0;
    while (try nextMetaBlock(&br)) |meta| {
        switch (meta.kind) {
            .uncompressed => {
                if (out_pos + meta.mlen > target.len) return error.BufferTooSmall;
                try br.takeBytes(target[out_pos..][0..meta.mlen]);
                out_pos += meta.mlen;
            },
            .compressed => return error.Compressed,
        }
    }
    return out_pos;
}

test "stream header: every WBITS value from RFC 7932 §9.1's table" {
    // RFC 7932 §9.1 — the table's patterns, read right to left. Each entry
    // is the byte holding the pattern (the stream's first byte), its WBITS,
    // and the window size (1 << WBITS) - 16.
    const cases = [_]struct { byte: u8, wbits: u5, window_size: u32 }{
        .{ .byte = 0x21, .wbits = 10, .window_size = 1008 },
        .{ .byte = 0x31, .wbits = 11, .window_size = 2032 },
        .{ .byte = 0x41, .wbits = 12, .window_size = 4080 },
        .{ .byte = 0x51, .wbits = 13, .window_size = 8176 },
        .{ .byte = 0x61, .wbits = 14, .window_size = 16368 },
        .{ .byte = 0x71, .wbits = 15, .window_size = 32752 },
        .{ .byte = 0x00, .wbits = 16, .window_size = 65520 },
        .{ .byte = 0x01, .wbits = 17, .window_size = 131056 },
        .{ .byte = 0x03, .wbits = 18, .window_size = 262128 },
        .{ .byte = 0x05, .wbits = 19, .window_size = 524272 },
        .{ .byte = 0x07, .wbits = 20, .window_size = 1048560 },
        .{ .byte = 0x09, .wbits = 21, .window_size = 2097136 },
        .{ .byte = 0x0B, .wbits = 22, .window_size = 4194288 },
        .{ .byte = 0x0D, .wbits = 23, .window_size = 8388592 },
        .{ .byte = 0x0F, .wbits = 24, .window_size = 16777200 },
    };
    for (cases) |case| {
        const source = [_]u8{case.byte};
        var br: bits.BitReader = .init(&source);
        const header = try readStreamHeader(&br);
        try testing.expectEqual(case.wbits, header.wbits);
        try testing.expectEqual(case.window_size, header.window_size);
    }
}

test "stream header: 0010001 is refused, a starved header is truncated" {
    // RFC 7932 §9.1: "bit pattern 0010001 is invalid and must not be used" —
    // the reference family's large-window extension marker, out of scope.
    var invalid: bits.BitReader = .init(&[_]u8{0x11});
    try testing.expectError(error.BadWindowBits, readStreamHeader(&invalid));

    // RFC 7932 §10: a stream that ends before its last bit is invalid.
    var empty: bits.BitReader = .init(&[_]u8{});
    try testing.expectError(error.Truncated, readStreamHeader(&empty));
}

test "empty streams: RFC 7932 §9.2's last-empty forms decode to nothing" {
    // brotli-notes.md §7.2's hand-decoded family, re-verified against the
    // pinned CLI (brotli 1.2.0): every byte string is a whole stream that
    // decodes to zero bytes. The sentinel proves nothing was written.
    var target: [64]u8 = undefined;
    for (golden.empty_streams) |stream| {
        internal.sentinel.fill(&target);
        const n = try decodeEntropyFree(stream, &target);
        try testing.expectEqual(@as(usize, 0), n);
        try internal.sentinel.expect(&target, n);
    }
}

test "metadata: the ISLAST corner and the payload skip" {
    // brotli-notes.md §7.2 / T5: a metadata meta-block with ISLAST=1 ends
    // the stream (the last-empty form is not the only terminator).
    var target: [8]u8 = undefined;
    for (golden.last_metadata_streams) |stream| {
        internal.sentinel.fill(&target);
        const n = try decodeEntropyFree(stream, &target);
        try testing.expectEqual(@as(usize, 0), n);
        try internal.sentinel.expect(&target, n);
    }

    // A metadata payload in the middle of a stream is skipped: its bytes are
    // neither output nor literal context (§2).
    var wide: [16]u8 = undefined;
    for (golden.metadata_streams) |stream| {
        internal.sentinel.fill(&wide);
        const n = try decodeEntropyFree(stream.bytes, &wide);
        try testing.expectEqual(stream.plain.len, n);
        try testing.expectEqualSlices(u8, stream.plain, wide[0..n]);
        try internal.sentinel.expect(&wide, n);
    }
}

test "metadata: the 65,536-block empty chain decodes to nothing" {
    // brotli-notes.md §7.2's `.17` fixture (google/brotli's
    // `empty.compressed.17`, re-verified against the pinned CLI): WBITS 17,
    // ISLAST=0, then 65,536 empty metadata meta-blocks, then the last-empty
    // terminator — 65,538 bytes. The first block's header is completed by
    // the byte boundary, the rest are the one-byte `06` form.
    var stream: [65538]u8 = undefined;
    stream[0] = 0x01; // WBITS 17, ISLAST=0
    stream[1] = 0x03; // the first metadata header, completed by the boundary
    fastmem.set(u8, stream[2..65537], 0x06);
    stream[65537] = 0x03;
    var target: [4]u8 = undefined;
    internal.sentinel.fill(&target);
    const n = try decodeEntropyFree(&stream, &target);
    try testing.expectEqual(@as(usize, 0), n);
    try internal.sentinel.expect(&target, n);
}

test "uncompressed meta-blocks pass their bytes through" {
    // RFC 7932 §9.2: "the rest of the meta-block contains MLEN bytes of
    // literal data" at the next byte boundary.
    var target: [16]u8 = undefined;
    for (golden.uncompressed_streams) |stream| {
        internal.sentinel.fill(&target);
        const n = try decodeEntropyFree(stream.bytes, &target);
        try testing.expectEqual(stream.plain.len, n);
        try testing.expectEqualSlices(u8, stream.plain, target[0..n]);
        try internal.sentinel.expect(&target, n);
    }

    // The same header with MLEN = 100 (MNIBBLES=4, MLEN-1 = 99), the largest
    // 4-nibble length, and a payload that is not constant.
    var long_target: [128]u8 = undefined;
    var hundred: [104]u8 = undefined;
    const long_header = [_]u8{ 0x30, 0x06, 0x10 };
    fastmem.copy(u8, hundred[0..3], &long_header);
    for (hundred[3..103], 0..) |*byte, i| byte.* = @intCast(i);
    hundred[103] = 0x03;
    internal.sentinel.fill(&long_target);
    const long_n = try decodeEntropyFree(&hundred, &long_target);
    try testing.expectEqual(@as(usize, 100), long_n);
    for (long_target[0..long_n], 0..) |byte, i| {
        try testing.expectEqual(@as(u8, @intCast(i)), byte);
    }
    try internal.sentinel.expect(&long_target, long_n);
}

test "uncompressed meta-blocks: the RFC 7932 §11.1 trivial compressor's streams" {
    // RFC 7932 §11.1: every N-byte input has a valid stream of at most
    // N + (3 * (N >> 16) + 5) bytes. The C++ is ported below and its output
    // decoded by the ladder; the 100,000-byte case meets the bound exactly
    // (100,008 bytes), the fixture the research measured through both
    // oracles.
    var source: [100_000]u8 = undefined;
    for (&source, 0..) |*byte, i| byte.* = @intCast((i * 7 + 3) & 0xFF);

    const stream = try testing.allocator.alloc(u8, trivialBound(source.len));
    defer testing.allocator.free(stream);
    const stream_len = trivialCompress(&source, stream);
    try testing.expectEqual(trivialBound(source.len), stream_len);

    const target = try testing.allocator.alloc(u8, source.len);
    defer testing.allocator.free(target);
    internal.sentinel.fill(target);
    const n = try decodeEntropyFree(stream[0..stream_len], target);
    try testing.expectEqual(@as(usize, source.len), n);
    try testing.expectEqualSlices(u8, &source, target[0..n]);
    try internal.sentinel.expect(target, n);

    // The research's small fixture: "hello world" (11 bytes) in 16 bytes.
    const hello = trivialCompressToBuf("hello world");
    try testing.expectEqual(@as(usize, 16), hello.len);
    var small: [16]u8 = undefined;
    internal.sentinel.fill(&small);
    const small_n = try decodeEntropyFree(&hello, &small);
    try testing.expectEqual(@as(usize, 11), small_n);
    try testing.expectEqualSlices(u8, "hello world", small[0..small_n]);
    try internal.sentinel.expect(&small, small_n);
}

/// `§11.1`'s bound: `N + (3 * (N >> 16) + 5)`.
fn trivialBound(n: usize) usize {
    return n + 3 * (n >> 16) + 5;
}

/// `§11.1`'s C++, ported: `[12]` (an empty metadata meta-block, which aligns
/// the next header to a byte boundary), then 65536-byte uncompressed
/// meta-blocks, then the final partial block, then `[3]` (ISLAST +
/// ISLASTEMPTY). The C++'s `append(1, c)` truncates `c` to a byte.
fn trivialCompress(source: []const u8, target: []u8) usize {
    var w: ByteWriter = .{ .target = target };
    if (source.len == 0) {
        w.byte(0x06);
        return w.pos;
    }
    w.byte(12);
    var i: usize = 0;
    while (i + 65535 < source.len) : (i += 65536) {
        w.byte(248);
        w.byte(255);
        w.byte(15);
        w.bytes(source[i..][0..65536]);
    }
    if (i < source.len) {
        const r = source.len - i - 1;
        w.byte(@truncate((r & 31) << 3));
        w.byte(@truncate(r >> 5));
        w.byte(@truncate(8 + (r >> 13)));
        w.bytes(source[i..][0 .. r + 1]);
    }
    w.byte(3);
    return w.pos;
}

const ByteWriter = struct {
    target: []u8,
    pos: usize = 0,

    fn byte(self: *ByteWriter, value: u8) void {
        self.target[self.pos] = value;
        self.pos += 1;
    }

    fn bytes(self: *ByteWriter, values: []const u8) void {
        fastmem.copy(u8, self.target[self.pos..][0..values.len], values);
        self.pos += values.len;
    }
};

fn trivialCompressToBuf(comptime source: []const u8) [trivialBound(source.len)]u8 {
    var out: [trivialBound(source.len)]u8 = undefined;
    const n = trivialCompress(source, &out);
    assert(n <= out.len);
    return out;
}

test "meta-block ladder: a compressed header stops at NBLTYPESL" {
    // A compressed meta-block whose MLEN is the format's maximum: ISLAST=0,
    // MNIBBLES=6, MLEN-1 = 0xFFFFFF, ISUNCOMPRESSED=0. The ladder reads the
    // header through ISUNCOMPRESSED and returns; NBLTYPESL is next on the
    // wire, and it is the tree layer's to read.
    var br: bits.BitReader = .init(&[_]u8{ 0xF8, 0xFF, 0xFF, 0x0F });
    _ = try readStreamHeader(&br);
    const meta = (try nextMetaBlock(&br)).?;
    try testing.expectEqual(Kind.compressed, meta.kind);
    try testing.expectEqual(@as(u32, 16_777_216), meta.mlen);
    try testing.expect(!meta.is_last);

    // The same header with ISLAST=1: ISUNCOMPRESSED is not present at all
    // (§9.2), and the ladder reports the last meta-block.
    var last: bits.BitReader = .init(&[_]u8{ 0xF2, 0xFF, 0xFF, 0x1F });
    _ = try readStreamHeader(&last);
    const last_meta = (try nextMetaBlock(&last)).?;
    try testing.expectEqual(Kind.compressed, last_meta.kind);
    try testing.expectEqual(@as(u32, 16_777_216), last_meta.mlen);
    try testing.expect(last_meta.is_last);
}

test "meta-block ladder: the named refusals" {
    // RFC 7932 §9.2 — the reserved bit must be zero.
    var reserved: bits.BitReader = .init(&[_]u8{0x3A});
    _ = try readStreamHeader(&reserved);
    try testing.expectError(error.ReservedBit, nextMetaBlock(&reserved));

    // RFC 7932 §9.2 — MNIBBLES > 4 with an all-zero last nibble.
    var nibble: bits.BitReader = .init(&[_]u8{ 0x2A, 0x00, 0x00, 0x00 });
    _ = try readStreamHeader(&nibble);
    try testing.expectError(error.ExuberantNibble, nextMetaBlock(&nibble));

    // RFC 7932 §9.2 — MSKIPBYTES > 1 with an all-zero last byte.
    var meta_nibble: bits.BitReader = .init(&[_]u8{ 0xCC, 0x00, 0x00 });
    _ = try readStreamHeader(&meta_nibble);
    try testing.expectError(error.ExuberantMetaNibble, nextMetaBlock(&meta_nibble));

    // RFC 7932 §9.2 — ISLASTEMPTY's fill bits must be zero.
    var fill: bits.BitReader = .init(&[_]u8{0x0E});
    _ = try readStreamHeader(&fill);
    try testing.expectError(error.BadPadding, nextMetaBlock(&fill));

    // RFC 7932 §9.2 — a metadata block's fill bits must be zero.
    var meta_fill: bits.BitReader = .init(&[_]u8{ 0x8C, 0x03 });
    _ = try readStreamHeader(&meta_fill);
    try testing.expectError(error.BadPadding, nextMetaBlock(&meta_fill));

    // RFC 7932 §9.2 — ISUNCOMPRESSED's skipped bits must be zero.
    var uncompressed_fill: bits.BitReader = .init(&[_]u8{ 0x10, 0x00, 0x30, 'h', 'i', 0x03 });
    _ = try readStreamHeader(&uncompressed_fill);
    try testing.expectError(error.BadPadding, nextMetaBlock(&uncompressed_fill));
}

test "meta-block ladder: a stream that ends inside its header is truncated" {
    // RFC 7932 §10: "If the stream ends before the completion of the last
    // meta-block, then the stream should be rejected as invalid." Every
    // prefix of a metadata stream, and an uncompressed block missing its
    // payload byte, must be refused.
    const stream = golden.last_metadata_streams[1];
    for (0..stream.len - 1) |n| {
        var br: bits.BitReader = .init(stream[0..n]);
        _ = readStreamHeader(&br) catch continue;
        const result = nextMetaBlock(&br);
        try testing.expectError(error.Truncated, result);
    }

    // An uncompressed meta-block whose payload stops one byte short: the
    // declared MLEN is 2, the input holds one payload byte and no
    // terminator. (A failed decode may have written output up to the
    // failure point; the sentinel rule is the successful decode's.)
    const short = [_]u8{ 0x10, 0x00, 0x10, 'h', 0x03 };
    var target: [8]u8 = undefined;
    try testing.expectError(error.Truncated, decodeEntropyFree(&short, &target));
}

test "readCount: every value of RFC 7932 §9.2's variable-length code" {
    // RFC 7932 §9.2 — the code for NBLTYPESL/I/D and NTREESL/NTREESD, read
    // right to left: 0 → 1, 0001 → 2, x0011 → 3..4, xx0101 → 5..8,
    // xxx0111 → 9..16, xxxx1001 → 17..32, xxxxx1011 → 33..64,
    // xxxxxx1101 → 65..128, xxxxxxx1111 → 129..256.
    for (1..257) |count| {
        var packer: Packer = .{};
        packer.packCount(@intCast(count));
        var br: bits.BitReader = .init(packer.slice());
        try testing.expectEqual(@as(u32, @intCast(count)), try readCount(&br));
        // Exactly the table's bits were consumed, no more (the last packed
        // byte's padding bits are not the code's).
        try testing.expectEqual(@as(u64, packer.bit_len), br.bit_pos);
    }
}

/// Test-side bit packer: appends an integer's low bits, least significant
/// first (`§1.5.1`), so a test can build a wire vector from a value.
const Packer = struct {
    bytes: [4]u8 = @splat(0),
    bit_len: usize = 0,

    fn pack(self: *Packer, value: u32, n: u5) void {
        var i: u5 = 0;
        while (i < n) : (i += 1) {
            const bit: u8 = @intCast((value >> i) & 1);
            self.bytes[self.bit_len / 8] |= bit << @intCast(self.bit_len % 8);
            self.bit_len += 1;
        }
    }

    /// The inverse of `readCount`: the §9.2 table read forward.
    fn packCount(self: *Packer, count: u32) void {
        assert(count >= 1);
        assert(count <= 256);
        if (count == 1) {
            self.pack(0, 1);
            return;
        }
        if (count == 2) {
            self.pack(1, 1);
            self.pack(0, 3);
            return;
        }
        const value = count - 1;
        var nbits: u5 = 1;
        while ((@as(u32, 1) << (nbits + 1)) <= value) : (nbits += 1) {}
        self.pack(1, 1);
        self.pack(nbits, 3);
        self.pack(value - (@as(u32, 1) << nbits), nbits);
    }

    fn slice(self: *const Packer) []const u8 {
        return self.bytes[0 .. (self.bit_len + 7) / 8];
    }
};
