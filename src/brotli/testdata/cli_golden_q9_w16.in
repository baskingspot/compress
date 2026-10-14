//! Golden wire vectors for the decoder's tests: whole streams and the bytes
//! they decode to.
//!
//! Provenance: the empty family is `brotli-notes.md` §7.2's hand-decoded
//! table (google/brotli v1.2.0's `tests/testdata/empty.compressed*`, not
//! vendored here); every other stream is a hand-built wire vector in the
//! §7.3 style, and the RFC 7932 §11.1 trivial-compressor shapes are generated
//! in the tests. Each hand-built vector was built by a §1.5.1 bit writer and
//! verified against the pinned CLI (brotli 1.2.0, the flake's) with
//! `brotli -d -c` — and the rejections with `brotli -d -v -c` — before
//! landing: a vector the reference refuses would be a broken fixture, not a
//! decoder bug. One fixture, `cli_golden_q9_w16`, is too large to inline:
//! its stream and the input text it decodes to live in `testdata/` and are
//! read with `@embedFile` (the shape the flate golden corpus uses).
//!
//! `Packer` is the test-side half of that writer, so a test can rebuild a
//! vector's fields or build a variant of it; `trivialCompress` is the one
//! wire builder that is not a `Packer` cascade, the RFC 7932 §11.1
//! reference compressor both the frame and the decode tests drive.

const std = @import("std");
const assert = std.debug.assert;

const fastmem = @import("fastmem");

/// A whole brotli stream and the bytes it decodes to.
pub const Stream = struct {
    /// The compressed bytes.
    bytes: []const u8,
    /// The decoded bytes.
    plain: []const u8,
};

/// The §1.5.1 bit writer the hand-built vectors are described with: integers
/// pack least significant bit first, prefix codes most significant bit
/// first (`code`).
pub const Packer = struct {
    bytes: [512]u8 = @splat(0),
    bit_len: usize = 0,

    pub fn pack(self: *Packer, value: u32, n: u5) void {
        var i: u5 = 0;
        while (i < n) : (i += 1) {
            const bit: u8 = @intCast((value >> i) & 1);
            self.bytes[self.bit_len / 8] |= bit << @intCast(self.bit_len % 8);
            self.bit_len += 1;
        }
    }

    /// Append a prefix code's bits: `wire` is the code in transmission order
    /// (`huffman.wireBits`), its first transmitted bit in bit 0.
    pub fn code(self: *Packer, wire: u16, len: u5) void {
        self.pack(wire, len);
    }

    pub fn slice(self: *const Packer) []const u8 {
        return self.bytes[0 .. (self.bit_len + 7) / 8];
    }
};

/// `§11.1`'s bound: `N + (3 * (N >> 16) + 5)`, the size of the stream
/// `trivialCompress` writes for an `N`-byte input.
///
/// RFC 7932 §11.1: "if an input of N bytes is transformed by appending a
/// special end-of-stream marker, then compressed using the uncompressed
/// meta-block format ... the resulting data will not be more than N + (3 *
/// (N >> 16) + 5) bytes long".
pub fn trivialBound(n: usize) usize {
    return n + 3 * (n >> 16) + 5;
}

/// `§11.1`'s C++, ported: `[12]` (an empty metadata meta-block, which aligns
/// the next header to a byte boundary), then 65536-byte uncompressed
/// meta-blocks, then the final partial block, then `[3]` (ISLAST +
/// ISLASTEMPTY). The C++'s `append(1, c)` truncates `c` to a byte.
///
/// The caller guarantees `target.len >= trivialBound(source.len)`; returns
/// the stream length.
pub fn trivialCompress(source: []const u8, target: []u8) usize {
    assert(target.len >= trivialBound(source.len));
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

/// `trivialCompress` for a comptime-known input, returning the stream inline.
pub fn trivialCompressToBuf(comptime source: []const u8) [trivialBound(source.len)]u8 {
    var out: [trivialBound(source.len)]u8 = undefined;
    const n = trivialCompress(source, &out);
    assert(n <= out.len);
    return out;
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

/// RFC 7932 §9.2, §7.2 of the notes — the empty stream family: one stream
/// header, ISLAST=1, ISLASTEMPTY=1, zero fill, and nothing else. The
/// one-byte forms cover WBITS 16 (`06`) and 18..24 (`33`..`3f`); WBITS 17
/// and 10..15 need a second byte for the ISLAST/ISLASTEMPTY pair.
pub const empty_streams = [_][]const u8{
    &.{0x06}, // WBITS 16
    &.{ 0x81, 0x01 }, // WBITS 17
    &.{ 0xA1, 0x01 }, // WBITS 10
    &.{ 0xB1, 0x01 }, // WBITS 11
    &.{ 0xC1, 0x01 }, // WBITS 12
    &.{ 0xD1, 0x01 }, // WBITS 13
    &.{ 0xE1, 0x01 }, // WBITS 14
    &.{ 0xF1, 0x01 }, // WBITS 15
    &.{0x33}, // WBITS 18
    &.{0x35}, // WBITS 19
    &.{0x37}, // WBITS 20
    &.{0x39}, // WBITS 21
    &.{0x3B}, // WBITS 22
    &.{0x3D}, // WBITS 23
    &.{0x3F}, // WBITS 24
};

/// RFC 7932 §9.2 and T5 of the notes — the last-metadata corner: a metadata
/// meta-block with ISLAST=1 ends the stream after its payload, so the
/// last-empty form is not the only terminator. `1a` carries no metadata
/// byte; `81 16 00 58` carries one.
pub const last_metadata_streams = [_][]const u8{
    &.{0x1A},
    &.{ 0x81, 0x16, 0x00, 0x58 },
};

/// RFC 7932 §9.2 — metadata meta-blocks skipped in the middle of a stream.
/// The first is a metadata block with a 2-byte payload and no other
/// meta-block; the other two sit between uncompressed meta-blocks, which
/// the payload's bytes must not become (they are neither output nor
/// context).
pub const metadata_streams = [_]Stream{
    .{ .bytes = &.{ 0xAC, 0x00, 'X', 'Y', 0x03 }, .plain = "" },
    .{
        .bytes = &.{ 0x10, 0x00, 0x10, 'h', 'i', 0x06, 0x08, 0x00, 0x08, 'h', 'o', 0x03 },
        .plain = "hiho",
    },
    .{
        .bytes = &.{
            0x10, 0x00, 0x10, 'h',  'i', 0x56, 0x00, 'X',
            'Y',  0x08, 0x00, 0x08, 'h', 'o',  0x03,
        },
        .plain = "hiho",
    },
};

/// RFC 7932 §9.2 — uncompressed meta-blocks: MLEN bytes pass through at the
/// next byte boundary, and "an uncompressed meta-block cannot be the last
/// meta-block" (§2), so each is followed by the last-empty terminator.
pub const uncompressed_streams = [_]Stream{
    .{ .bytes = &.{ 0x10, 0x00, 0x10, 'h', 'i', 0x03 }, .plain = "hi" },
    .{
        .bytes = &.{ 0x20, 0x00, 0x10, 'a', 'b', 'c', 0x10, 0x00, 0x08, 'd', 'e', 'f', 0x03 },
        .plain = "abcdef",
    },
};

/// RFC 7932 §9.2, §3.4, §7.1-§7.3, and `brotli-notes.md` §7.3 — the
/// compressed meta-block header's full ladder in nine bytes, with all three
/// NBLTYPES and NTREES = 1: WBITS 16, a last MLEN=1 compressed meta-block,
/// NPOSTFIX 0/NDIRECT 0, LSB6, and three simple NSYM = 1 codes — literal 65
/// in 8 bits, insert-and-copy 8 in 10 bits, distance 0 in 6 bits (the
/// ALPHABET_BITS widths of T7) — whose symbols consume no bits at all, so
/// the single command's literal and its IaC code come from the trees.
pub const hand_stream: Stream = .{
    .bytes = &.{ 0x02, 0x00, 0x00, 0x00, 0x44, 0x50, 0x20, 0x10, 0x00 },
    .plain = "A",
};

/// RFC 7932 §3.4 — the simple form's sorted-order rule: the literal tree's
/// two symbols are presented unordered (66, 65), and the one literal bit is
/// 0, which is 65's code because equal-length codes are assigned in sorted
/// symbol order.
pub const unordered_symbol_stream: Stream = .{
    .bytes = &.{ 0x02, 0x00, 0x00, 0x00, 0x94, 0x50, 0x50, 0x20, 0x10, 0x00 },
    .plain = "A",
};

/// RFC 7932 §3.4 and T7 — ALPHABET_BITS is the width of the largest symbol,
/// not a floor-log: the literal symbols {200, 65} packed in 8 bits decode to
/// `A`, and the same construction packed in 7 bits (`floor_log_stream`) is
/// corrupt in both references.
pub const wide_symbol_stream: Stream = .{
    .bytes = &.{ 0x02, 0x00, 0x00, 0x00, 0x14, 0x72, 0x50, 0x20, 0x10, 0x00 },
    .plain = "A",
};
pub const floor_log_stream = [_]u8{ 0x02, 0x00, 0x00, 0x00, 0x14, 0x32, 0x18, 0x08, 0x04, 0x00 };

/// RFC 7932 §3.4 — a simple literal code with symbol 0 as its one symbol.
/// The notes' `hal.br` case: a literal field of "256" in an 8-bit alphabet
/// reads as 0, which is the unreachability half of T7.
pub const high_literal_stream: Stream = .{
    .bytes = &.{ 0x02, 0x00, 0x00, 0x00, 0x04, 0x40, 0x20, 0x10, 0x00 },
    .plain = &.{0x00},
};

/// RFC 7932 §3.4 — the two rejections, each proven by the CLI (the C reports
/// `FORMAT_SIMPLE_HUFFMAN_SAME (-5)` and `FORMAT_SIMPLE_HUFFMAN_ALPHABET
/// (-4)`): a duplicate symbol (65, 65), and an insert-and-copy symbol 704
/// against the 704-symbol alphabet.
pub const duplicate_symbol_streams = [_][]const u8{
    &.{ 0x02, 0x00, 0x00, 0x00, 0x54, 0x50, 0x50, 0x20, 0x10, 0x00 },
};
pub const out_of_alphabet_streams = [_][]const u8{
    &.{ 0x02, 0x00, 0x00, 0x00, 0x44, 0x50, 0x00, 0x1B, 0x00 },
};

/// RFC 7932 §3.5 — the complex form. `complex_tree_stream` decodes the
/// literal `A` through a code whose lengths are 1 for symbols 65 and 66 and
/// 0 elsewhere, carried by a code-length code over {0, 1, 17} whose 17
/// repeats a zero 65 times; `complex_single_stream` is the single-symbol
/// code-length code ("that symbol results in no bits being emitted ... and
/// no bits consumed"), with lengths 1 for symbols 0 and 1 and a 0x00
/// literal; `repeat16_stream` is four length-2 codes for literals 10..13
/// with a 16 repeat, decoding 0x0A.
pub const complex_tree_stream: Stream = .{
    .bytes = &.{
        0x02, 0x00, 0x00, 0x00, 0x30, 0xE0, 0xD8,
        0xF7, 0x7D, 0xDF, 0xF7, 0x2B, 0x10, 0x08,
        0x00,
    },
    .plain = "A",
};
pub const complex_single_stream: Stream = .{
    .bytes = &.{
        0x02, 0x00, 0x00, 0x00, 0x70, 0x00, 0x00,
        0x00, 0x00, 0x04, 0x02, 0x01, 0x00,
    },
    .plain = &.{0x00},
};
pub const repeat16_stream: Stream = .{
    .bytes = &.{
        0x02, 0x00, 0x00, 0x00, 0xC0, 0x01, 0x8C,
        0x7D, 0x11, 0x08, 0x04, 0x00,
    },
    .plain = &.{0x0A},
};

/// RFC 7932 §7.3 and §9.2 — a context map: NTREESL = 2, RLEMAX = 1, a map
/// tree over the three-symbol RLE alphabet, 31 two-zero runs, and the IMTF
/// bit set. The raw map is [1, 1, 0, ...]; the inverse move-to-front
/// transform makes it [1, 0, 0, ...], so the first literal (context ID 0)
/// uses tree 1 and the second (LSB6 of p1 = 65 is 1) uses tree 0 — `BA`,
/// where a decoder that ignored the IMTF bit would emit `BB`.
pub const context_map_stream: Stream = .{
    .bytes = &.{
        0x22, 0x00, 0x00, 0x00, 0x11, 0x92, 0xFC, 0x24, 0x49, 0x92, 0x24, 0x49,
        0x92, 0x24, 0x49, 0x92, 0x24, 0x49, 0x52, 0x04, 0x85, 0x50, 0x40, 0x10,
        0x00,
    },
    .plain = "BA",
};

// ---------------------------------------------------------------------------
// The command stream: the §4 ring and distance codes, §5/§6/§7.1/§7.2, and
// §9.3/§10's execution. Every hand-built vector was built by the §1.5.1 bit
// writer in the scratch builder and verified against the pinned CLI (brotli
// 1.2.0) before landing: `brotli -d -c` for the legal ones, `brotli -d -v -c`
// for the refusals, whose reason each comment records.
// ---------------------------------------------------------------------------

/// RFC 7932 §4, §10 — the fourth-to-last distance (16) and the
/// overlapping run: insert 16 bytes, copy 2 at distance 16, copy 5 at
/// distance 2. Verified with the pinned CLI
/// (brotli 1.2.0), which decodes to the plain bytes.
pub const special_codes: Stream = .{
    .bytes = &.{
        0xC2, 0x02, 0x00, 0x00, 0x34, 0x4C, 0x8C, 0xCC, 0x8C, 0x1A, 0x04, 0xA1,
        0x1A, 0xA0, 0x82, 0xD6, 0x83, 0xD6, 0x33,
    },
    .plain = "00112233001122330000000",
};

/// RFC 7932 §4 — code 1 is the second-to-last distance (11). Verified with the pinned CLI
/// (brotli 1.2.0), which decodes to the plain bytes.
pub const ring_init_second: Stream = .{
    .bytes = &.{
        0x82, 0x01, 0x00, 0x00, 0x14, 0x4C, 0x4C, 0x00, 0x14, 0x41, 0xAA, 0x02,
    },
    .plain = "0101010101001",
};

/// RFC 7932 §4 — code 2 is the third-to-last distance (15). Verified with the pinned CLI
/// (brotli 1.2.0), which decodes to the plain bytes.
pub const ring_init_third: Stream = .{
    .bytes = &.{
        0x02, 0x02, 0x00, 0x00, 0x14, 0x4C, 0x4C, 0x20, 0x14, 0x42, 0xAA, 0x2A,
    },
    .plain = "01010101010101001",
};

/// RFC 7932 §4 — code 0 is the last distance (4). Verified with the pinned CLI
/// (brotli 1.2.0), which decodes to the plain bytes.
pub const ring_init_last: Stream = .{
    .bytes = &.{
        0xA2, 0x00, 0x00, 0x00, 0x14, 0x4C, 0x4C, 0x80, 0x12, 0x80, 0x02,
    },
    .plain = "010101",
};

/// RFC 7932 §9.3 — the insert reaches MLEN: the copy is ignored and its distance element is
/// not on the wire (the next meta-block's header follows immediately). Verified with the pinned CLI
/// (brotli 1.2.0), which decodes to the plain bytes.
pub const mlen_exact_insert: Stream = .{
    .bytes = &.{
        0x30, 0x00, 0x00, 0x00, 0x44, 0x50, 0x9C, 0x16, 0x00, 0x00, 0x00, 0x40,
        0x00, 0x00, 0x00, 0x80, 0x10, 0x0A, 0x04, 0x02, 0x00,
    },
    .plain = "AAAAB",
};

/// RFC 7932 §9.3 — the literals to insert would exceed MLEN (the CLI's
/// FORMAT_BLOCK_LENGTH_2 (-10)). Verified with the pinned CLI
/// (brotli 1.2.0), which refuses it.
pub const mlen_insert_overrun: Stream = .{
    .bytes = &.{
        0x22, 0x00, 0x00, 0x00, 0x44, 0x50, 0x60, 0x10, 0x00,
    },
    .plain = "",
};

/// RFC 7932 §9.3 — the copy length would exceed MLEN (the CLI's
/// FORMAT_BLOCK_LENGTH_2 (-10)). Verified with the pinned CLI
/// (brotli 1.2.0), which refuses it.
pub const mlen_copy_overrun: Stream = .{
    .bytes = &.{
        0x42, 0x00, 0x00, 0x00, 0x44, 0x50, 0x24, 0x12, 0x10,
    },
    .plain = "",
};

/// RFC 7932 §4 — code 4 (last - 1) resolves to zero (the CLI's
/// FORMAT_DISTANCE (-16)). Verified with the pinned CLI
/// (brotli 1.2.0), which refuses it.
pub const negative_special: Stream = .{
    .bytes = &.{
        0x82, 0x00, 0x00, 0x00, 0x44, 0x50, 0x01, 0x82, 0x48, 0x11, 0xD0, 0x00,
    },
    .plain = "",
};

/// RFC 7932 §6, T1 — the literal switch's symbol 0 selects the previous type, which
/// §6 initializes to 1. Verified with the pinned CLI
/// (brotli 1.2.0), which decodes to the plain bytes.
pub const block_switch_literal_t1: Stream = .{
    .bytes = &.{
        0xC2, 0x00, 0x20, 0x8A, 0x02, 0x00, 0x00, 0xA1, 0x04, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xF8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x27, 0x82, 0x42, 0xA8, 0x20, 0x40, 0x24, 0xA0, 0x08,
    },
    .plain = "AAABBBB",
};

/// RFC 7932 §6 — the insert-and-copy switch, symbol 1 = current + 1.
/// Verified with the pinned CLI (brotli 1.2.0), which decodes to the plain
/// bytes.
pub const block_switch_command: Stream = .{
    .bytes = &.{
        0xC2, 0x00, 0x40, 0x14, 0x05, 0x00, 0x00, 0x11, 0x14, 0x88, 0x04, 0x04,
        0x01, 0x09,
    },
    .plain = "AAAAAAA",
};

/// RFC 7932 §6, T2 — the distance switch is read only when a distance is read:
/// the implicit-distance command passes with the count spent. Verified with the pinned CLI
/// (brotli 1.2.0), which decodes to the plain bytes.
pub const distance_switch_t2: Stream = .{
    .bytes = &.{
        0xE2, 0x00, 0x80, 0x28, 0x0A, 0x00, 0x80, 0x50, 0xFA, 0x2B, 0xAC, 0xAC,
        0x04, 0x00, 0x10, 0x48, 0x02, 0x0A, 0x68, 0x2B, 0x00,
    },
    .plain = "XYXYXYYY",
};

/// RFC 7932 §4 — NDIRECT = 4: codes 16..19 are distances 1..4 with no extra
/// bits. Verified with the pinned CLI (brotli 1.2.0), which decodes to the
/// plain bytes.
pub const ndirect: Stream = .{
    .bytes = &.{
        0xE2, 0x00, 0x00, 0x10, 0x64, 0x98, 0xD8, 0x58, 0x01, 0x92, 0x49, 0x49,
        0x26, 0x35, 0x01,
    },
    .plain = "abcabcca",
};

/// RFC 7932 §4 — NPOSTFIX = 1, NDIRECT = 2: the postfix arithmetic. Verified with the pinned CLI
/// (brotli 1.2.0), which decodes to the plain bytes.
pub const npostfix: Stream = .{
    .bytes = &.{
        0x62, 0x01, 0x00, 0x05, 0x64, 0x98, 0xD8, 0x58, 0x01, 0xB2, 0x4A, 0x45,
        0x24, 0xB5, 0x06,
    },
    .plain = "abcababcabab",
};

/// RFC 7932 §7.2 — copy lengths 2 and 3 select distance context IDs 0 and 1.
/// Verified with the pinned CLI (brotli 1.2.0), which decodes to the plain
/// bytes.
pub const distance_context: Stream = .{
    .bytes = &.{
        0x02, 0x01, 0x00, 0x00, 0x42, 0xE9, 0x3A, 0x4C, 0x6C, 0x8C, 0x4C, 0x05,
        0x02, 0x4A, 0x44, 0x01, 0xC5, 0x2E,
    },
    .plain = "abcdababa",
};

/// RFC 7932 §7.1 — mode MSB6: p1 = 'A' is context 16. Verified with the pinned CLI
/// (brotli 1.2.0), which decodes to the plain bytes.
pub const context_mode_msb6: Stream = .{
    .bytes = &.{
        0x62, 0x00, 0x00, 0x40, 0xA1, 0x04, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x20, 0x82, 0x42, 0x28, 0x20, 0x09, 0x28,
    },
    .plain = "ABAB",
};

/// RFC 7932 §7.1 — mode UTF8: p1 = 'A' is context 48. Verified with the pinned CLI
/// (brotli 1.2.0), which decodes to the plain bytes.
pub const context_mode_utf8: Stream = .{
    .bytes = &.{
        0x62, 0x00, 0x00, 0x80, 0xA1, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08,
        0x00, 0x20, 0x82, 0x42, 0x28, 0x20, 0x09, 0x28,
    },
    .plain = "ABAB",
};

/// RFC 7932 §7.1 — mode Signed: p1 = 'A' is context 24. Verified with the pinned CLI
/// (brotli 1.2.0), which decodes to the plain bytes.
pub const context_mode_signed: Stream = .{
    .bytes = &.{
        0x62, 0x00, 0x00, 0xC0, 0xA1, 0x04, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00,
        0x00, 0x20, 0x82, 0x42, 0x28, 0x20, 0x09, 0x28,
    },
    .plain = "ABAB",
};

/// RFC 7932 §8 — a well-formed dictionary reference: one literal 'A', then
/// the dictionary word "time" (length 4, transform 0, the identity).
/// Verified with the pinned CLI (brotli 1.2.0), which decodes to the plain
/// bytes.
pub const dictionary_word: Stream = .{
    .bytes = &.{
        0x82, 0x00, 0x00, 0x00, 0x44, 0x50, 0x28, 0x12, 0x50,
    },
    .plain = "Atime",
};

/// RFC 7932 §8, Appendix B — transform 9 (["", FermentFirst, ""]) of the
/// first four-byte word "time": "Time". Hand-built from the RFC's own
/// tables and verified with the pinned CLI (brotli 1.2.0), which decodes to
/// the plain bytes.
pub const dictionary_ferment: Stream = .{
    .bytes = &.{
        0x62, 0x00, 0x00, 0x00, 0x44, 0x50, 0x08, 0x12, 0x26, 0x01, 0x01,
    },
    .plain = "Time",
};

/// RFC 7932 §8, Appendix B — transform 44 (["", FermentAll, ""]) over a
/// three-byte UTF-8 sequence: the word "\xe2\x80\x99s" becomes
/// "\xe2\x80\x9cS" (the third byte's `^ 5`, then the ASCII 's'). Verified
/// with the pinned CLI (brotli 1.2.0), which decodes to the plain bytes.
pub const dictionary_ferment_utf8: Stream = .{
    .bytes = &.{
        0x62, 0x00, 0x00, 0x00, 0x44, 0x50, 0x08, 0x12, 0xEA, 0x84, 0x0C,
    },
    .plain = "\xe2\x80\x9cS",
};

/// RFC 7932 §8, Appendix B — transform 73, the longest affix pair (" the "
/// + " of the "): the word "time" becomes " the time of the ". Verified
/// with the pinned CLI (brotli 1.2.0), which decodes to the plain bytes.
pub const dictionary_affix: Stream = .{
    .bytes = &.{
        0x02, 0x02, 0x00, 0x00, 0x44, 0x50, 0x08, 0x12, 0x2C, 0x01, 0x09,
    },
    .plain = " the time of the ",
};

/// RFC 7932 §8, Appendix B — transform 54 (["", OmitFirst9, ""]) of the
/// last 24-byte word (index 31 of 32): its first three Devanagari sequences
/// are dropped. Verified with the pinned CLI (brotli 1.2.0), which decodes
/// to the plain bytes.
pub const dictionary_omit: Stream = .{
    .bytes = &.{
        0xC2, 0x01, 0x00, 0x00, 0x44, 0x50, 0x10, 0x13, 0xA1, 0xC6, 0x01,
    },
    .plain = "\xe0\xa4\xb0\xe0\xa4\xbf\xe0\xa4\xaf\xe0\xa4\xa4\xe0\xa4\xbe",
};

/// RFC 7932 §8, Appendix B — the identity transform of a 24-byte word (the
/// longest length, the first word of its group): the reference's
/// `cutOffTransforms[0]` fast path. Verified with the pinned CLI (brotli
/// 1.2.0), which decodes to the plain bytes.
pub const dictionary_identity_24: Stream = .{
    .bytes = &.{
        0xE2, 0x02, 0x00, 0x00, 0x44, 0x50, 0x10, 0x13, 0x90, 0x00,
    },
    .plain = "<script type=\"text/javas",
};

/// RFC 7932 §8, Appendix B — a transform that empties its word (OmitFirst9
/// of a nine-byte word): the reference accepts it when the distance is
/// above 120, so the command produces nothing and the next command's
/// literal fills MLEN. Verified with the pinned CLI (brotli 1.2.0), which
/// decodes to the plain bytes.
pub const dictionary_empty: Stream = .{
    .bytes = &.{
        0x02, 0x00, 0x00, 0x00, 0x44, 0x50, 0x1D, 0x82, 0x48, 0xAC, 0x08, 0xB0,
    },
    .plain = "A",
};

/// RFC 7932 §8 — a dictionary reference whose transform id is 121: the
/// CLI's FORMAT_TRANSFORM (-11) refusal. Verified with the pinned CLI
/// (brotli 1.2.0, `brotli -d -v -c`), which refuses it.
pub const dictionary_transform: Stream = .{
    .bytes = &.{
        0x62, 0x00, 0x00, 0x00, 0x44, 0x50, 0x08, 0x12, 0x2D, 0x01, 0x19,
    },
    .plain = "",
};

/// RFC 7932 §8 — a dictionary reference with copy length 3 ("The copy
/// length for a static dictionary reference must be between 4 and 24"):
/// the CLI's FORMAT_DICTIONARY (-12). Verified with the pinned CLI
/// (brotli 1.2.0, `brotli -d -v -c`), which refuses it.
pub const dictionary_length: Stream = .{
    .bytes = &.{
        0x62, 0x00, 0x00, 0x00, 0x44, 0x50, 0x24, 0x12, 0x50,
    },
    .plain = "",
};

/// RFC 7932 §9.3 — a dictionary reference whose word would exceed MLEN:
/// `dictionary_word` with MLEN 4, so the one literal 'A' plus "time" does
/// not fit. The CLI reports FORMAT_BLOCK_LENGTH_2 (-10) and refuses it;
/// verified with the pinned CLI (brotli 1.2.0, `brotli -d -v -c`).
pub const dictionary_mlen_overrun: Stream = .{
    .bytes = &.{
        0x62, 0x00, 0x00, 0x00, 0x44, 0x50, 0x28, 0x12, 0x50,
    },
    .plain = "",
};

/// RFC 7932 §10, §4 — a copy across a meta-block boundary, and the stream-scoped
/// distance ring: the second meta-block's implicit distance is the first's
/// push. Verified with the pinned CLI
/// (brotli 1.2.0), which decodes to the plain bytes.
pub const cross_meta_block: Stream = .{
    .bytes = &.{
        0x50, 0x00, 0x00, 0x00, 0x24, 0x5E, 0x9E, 0x5E, 0x64, 0x12, 0x91, 0x16,
        0x02, 0x00, 0x00, 0x20, 0xF0, 0x22, 0x80, 0x80, 0x00,
    },
    .plain = "xyzxyzxyz",
};

/// RFC 7932 §7.1 — the context's p1 comes from an uncompressed meta-block's last
/// byte. Verified with the pinned CLI
/// (brotli 1.2.0), which decodes to the plain bytes.
pub const uncompressed_context: Stream = .{
    .bytes = &.{
        0x00, 0x00, 0x10, 0x41, 0x31, 0x00, 0x00, 0xA0, 0x50, 0x02, 0x00, 0x04,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x10, 0x58, 0x91, 0x15, 0x90, 0x04, 0x14,
    },
    .plain = "AYYYY",
};

/// RFC 7932 §4 — a distance symbol 0 is not pushed: the next code 1 still reads the
/// original second-to-last distance. Verified with the pinned CLI
/// (brotli 1.2.0), which decodes to the plain bytes.
pub const ring_no_push_zero: Stream = .{
    .bytes = &.{
        0xC2, 0x01, 0x00, 0x00, 0x14, 0x4C, 0x4C, 0x01, 0x02, 0x50, 0x01, 0xC1,
        0x54, 0x45,
    },
    .plain = "010101010101001",
};

/// RFC 7932 §8 — the maximum allowed distance is min(window size, produced): with
/// WBITS 10 the window is 1008, so a distance of 1500 after 2000 produced
/// bytes is a dictionary reference (the word "lose"), not a window read —
/// the produced count alone would call it a window read. Verified with the
/// pinned CLI (brotli 1.2.0), which decodes 'A' × 2000 + 'lose'.
pub const window_bound: Stream = .{
    .bytes = &.{
        0xA1, 0x98, 0x3E, 0x00, 0x00, 0x11, 0x14, 0xE2, 0x05, 0xE8, 0xF8, 0x77,
    },
    .plain = "A" ** 2000 ++ "lose",
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 1 -c`):
/// 'the quick brown fox jumps over the lazy dog\n' ** 3.
pub const cli_text_q1: Stream = .{
    .bytes = &.{
        0x8F, 0x41, 0x00, 0x00, 0x80, 0xAA, 0xAA, 0xAA, 0xEA, 0xFF, 0xAE, 0x97,
        0x13, 0x9F, 0xAF, 0xBA, 0xAD, 0xA2, 0xCB, 0x0E, 0x1B, 0x70, 0x81, 0x63,
        0xB8, 0xE1, 0x40, 0x38, 0x18, 0xCE, 0x06, 0x63, 0x9D, 0x21, 0xAD, 0xD3,
        0x69, 0xB4, 0xE5, 0x65, 0x84, 0xE8, 0x74, 0x0A, 0x0C, 0x5D, 0x84, 0x95,
        0xEB, 0x00, 0x6D, 0xDD, 0xB1, 0xD0, 0x89, 0xFF, 0x07, 0x45, 0x96, 0x01,
        0x77, 0xFF,
    },
    .plain = "the quick brown fox jumps over the lazy dog\n" ** 3,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 2 -c`):
/// 'the quick brown fox jumps over the lazy dog\n' ** 3.
pub const cli_text_q2: Stream = .{
    .bytes = &.{
        0x1F, 0x83, 0x00, 0x00, 0x80, 0xAA, 0xAA, 0xAA, 0xEA, 0xFF, 0xAE, 0x97,
        0x13, 0x9F, 0xAF, 0xBA, 0xAD, 0xA2, 0xCB, 0x3E, 0x00, 0x07, 0x63, 0x41,
        0x24, 0x26, 0x89, 0x01, 0xEE, 0xB4, 0x89, 0xD5, 0xE9, 0x34, 0xDA, 0xF2,
        0x32, 0x42, 0x74, 0x3A, 0x05, 0x86, 0x2E, 0xC2, 0xCA, 0x75, 0x80, 0xB6,
        0xEE, 0xD0, 0x64, 0x47, 0x99, 0xF8, 0x7F, 0x50, 0x64, 0x99, 0xF6,
    },
    .plain = "the quick brown fox jumps over the lazy dog\n" ** 3,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 5 -c`):
/// 'the quick brown fox jumps over the lazy dog\n' ** 3.
pub const cli_text_q5: Stream = .{
    .bytes = &.{
        0x1F, 0x83, 0x00, 0x00, 0x44, 0xF3, 0xA4, 0xDD, 0x32, 0x75, 0x5E, 0x89,
        0x43, 0xE4, 0xA9, 0x1C, 0x7F, 0x8E, 0x22, 0x11, 0x6E, 0x65, 0x65, 0x66,
        0x12, 0x9C, 0x11, 0x4E, 0x79, 0x1A, 0x02, 0x2F, 0xF2, 0xAA, 0x7D, 0x80,
        0x5B, 0x14, 0xE4, 0xB2, 0xD8, 0xFF, 0xE0, 0x19, 0x8D, 0x07,
    },
    .plain = "the quick brown fox jumps over the lazy dog\n" ** 3,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 9 -c`):
/// 'the quick brown fox jumps over the lazy dog\n' ** 3.
pub const cli_text_q9: Stream = .{
    .bytes = &.{
        0x1F, 0x83, 0x00, 0x00, 0x44, 0xF3, 0xA4, 0xDD, 0x32, 0x75, 0x5E, 0x89,
        0x43, 0xE4, 0xA9, 0x1C, 0x7F, 0x8E, 0x22, 0x11, 0x6E, 0x65, 0x65, 0x66,
        0x12, 0x9C, 0x11, 0x4E, 0x79, 0x1A, 0x02, 0x2F, 0xF2, 0xAA, 0x7D, 0x80,
        0x5B, 0x14, 0xE4, 0xB2, 0xD8, 0xFF, 0xE0, 0x19, 0x8D, 0x07,
    },
    .plain = "the quick brown fox jumps over the lazy dog\n" ** 3,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 11 -c`):
/// 'the quick brown fox jumps over the lazy dog\n' ** 3.
pub const cli_text_q11: Stream = .{
    .bytes = &.{
        0x1F, 0x83, 0x00, 0x88, 0x8C, 0x94, 0x6E, 0xE6, 0x22, 0xD0, 0x83, 0xF5,
        0x97, 0xB4, 0x1E, 0xA0, 0x68, 0x04, 0xE4, 0x1B, 0x5A, 0x18, 0x6C, 0xC0,
        0x81, 0x43, 0x02, 0x79, 0x9B, 0xC8, 0x1D, 0x3A, 0xAD, 0x70, 0x36, 0x3B,
        0x1E, 0x27, 0x2A, 0x2C, 0x05, 0x1B, 0xE1, 0x65, 0xF5, 0x87, 0x49, 0x51,
    },
    .plain = "the quick brown fox jumps over the lazy dog\n" ** 3,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 9 -w 10 -c`):
/// 'the quick brown fox jumps over the lazy dog\n' ** 100, 4,400 bytes of
/// output in a 49-byte stream whose declared window is 1,008 bytes (`§9.1`).
/// One copy of 4,355 bytes at distance 45, so a streaming reader with a
/// `Buffer(10)` (a 1,024-byte ring) wraps its ring under the copy and reads
/// the match out of the ring's previous pass — the ring's live vector.
pub const cli_small_window: Stream = .{
    .bytes = &.{
        0xA1, 0x78, 0x89, 0x00, 0x20, 0x9A, 0x27, 0xED, 0x96, 0xA9, 0xF3, 0x4A,
        0x1C, 0x22, 0x4F, 0xE5, 0xF8, 0x73, 0x14, 0x89, 0x7E, 0x2B, 0x2B, 0x33,
        0x93, 0xE0, 0x8C, 0x70, 0xCA, 0xD3, 0x10, 0x78, 0x91, 0x57, 0xED, 0x03,
        0xDC, 0xA2, 0x20, 0xF7, 0x45, 0x00, 0x28, 0xF6, 0x3F, 0x78, 0x46, 0xE3,
        0x01,
    },
    .plain = "the quick brown fox jumps over the lazy dog\n" ** 100,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 1 -c`):
/// 'abcdefgh' ** 20.
pub const cli_repeat_q1: Stream = .{
    .bytes = &.{
        0x8F, 0x4F, 0x00, 0x00, 0x80, 0xAA, 0xAA, 0xAA, 0xEA, 0xFF, 0x70, 0x3A,
        0xF3, 0xB2, 0xC0, 0x01, 0x5C, 0xFC, 0x4A, 0x97, 0xE6, 0x1B, 0x1B, 0x8C,
        0x39, 0x76, 0x14, 0x50, 0x4E, 0xF7, 0x1E, 0x32,
    },
    .plain = "abcdefgh" ** 20,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 2 -c`):
/// 'abcdefgh' ** 20.
pub const cli_repeat_q2: Stream = .{
    .bytes = &.{
        0x1F, 0x9F, 0x00, 0x00, 0x80, 0xAA, 0xAA, 0xAA, 0xEA, 0xFF, 0x70, 0x3A,
        0xF3, 0xB2, 0x0C, 0xC0, 0xC1, 0x58, 0x10, 0x89, 0x49, 0x62, 0x80, 0x3B,
        0x6D, 0x76, 0x91, 0x40, 0x39, 0xDD, 0x39,
    },
    .plain = "abcdefgh" ** 20,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 5 -c`):
/// 'abcdefgh' ** 20.
pub const cli_repeat_q5: Stream = .{
    .bytes = &.{
        0x1F, 0x9F, 0x00, 0x00, 0xC4, 0x01, 0xC7, 0x80, 0xB8, 0x3E, 0x74, 0x0B,
        0x87, 0x04, 0xCA, 0xE9, 0x0E,
    },
    .plain = "abcdefgh" ** 20,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 9 -c`):
/// 'abcdefgh' ** 20.
pub const cli_repeat_q9: Stream = .{
    .bytes = &.{
        0x1F, 0x9F, 0x00, 0x00, 0xC4, 0x01, 0xC7, 0x80, 0xB8, 0x3E, 0x74, 0x0B,
        0x87, 0x04, 0xCA, 0xE9, 0x0E,
    },
    .plain = "abcdefgh" ** 20,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 11 -c`):
/// 'abcdefgh' ** 20.
pub const cli_repeat_q11: Stream = .{
    .bytes = &.{
        0x1F, 0x9F, 0x00, 0xF8, 0xC5, 0x01, 0xC7, 0x80, 0xB8, 0x3E, 0x74, 0x0B,
        0x07, 0x48, 0xA0, 0x9C, 0xEE,
    },
    .plain = "abcdefgh" ** 20,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 1 -c`):
/// 'A' ** 300.
pub const cli_run_q1: Stream = .{
    .bytes = &.{
        0x8F, 0x95, 0x00, 0x00, 0x20, 0x82, 0xD8, 0x00, 0x0E, 0x5C, 0xC3, 0x09,
        0x7D, 0x36, 0x80, 0x0B, 0x70, 0x58, 0x1E, 0x1B,
    },
    .plain = "A" ** 300,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 2 -c`):
/// 'A' ** 300.
pub const cli_run_q2: Stream = .{
    .bytes = &.{
        0x1F, 0x2B, 0x01, 0x00, 0x20, 0x82, 0x06, 0xE0, 0x60, 0x2C, 0x88, 0xC4,
        0x24, 0x31, 0xC0, 0x9D, 0x36, 0xA3, 0xCB, 0x04,
    },
    .plain = "A" ** 300,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 5 -c`):
/// 'A' ** 300.
pub const cli_run_q5: Stream = .{
    .bytes = &.{
        0x1F, 0x2B, 0x01, 0x00, 0x24, 0x82, 0x62, 0xB1, 0x40, 0xCA,
    },
    .plain = "A" ** 300,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 9 -c`):
/// 'A' ** 300.
pub const cli_run_q9: Stream = .{
    .bytes = &.{
        0x1F, 0x2B, 0x01, 0x00, 0x24, 0x82, 0x62, 0xB1, 0x40, 0xCA,
    },
    .plain = "A" ** 300,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 11 -c`):
/// 'A' ** 300.
pub const cli_run_q11: Stream = .{
    .bytes = &.{
        0x1F, 0x2B, 0x01, 0xF8, 0x25, 0x82, 0x62, 0xB1, 0x40, 0xA0, 0x0C,
    },
    .plain = "A" ** 300,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 1 -c`):
/// '0123456789' ** 40.
pub const cli_digits_q1: Stream = .{
    .bytes = &.{
        0x8F, 0xC7, 0x00, 0x00, 0x80, 0xAA, 0xAA, 0xAA, 0xEA, 0xFF, 0x78, 0xE5,
        0x55, 0x16, 0x38, 0x80, 0x8B, 0x5F, 0x29, 0x32, 0xC5, 0x07, 0x76, 0x00,
        0x6B, 0x7C, 0x02, 0x94, 0xD3, 0xD9, 0xFB, 0xDA, 0xC7,
    },
    .plain = "0123456789" ** 40,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 2 -c`):
/// '0123456789' ** 40.
pub const cli_digits_q2: Stream = .{
    .bytes = &.{
        0x1F, 0x8F, 0x01, 0x00, 0x80, 0xAA, 0xAA, 0xAA, 0xEA, 0xFF, 0x78, 0xE5,
        0x55, 0x96, 0x01, 0x38, 0x18, 0x0B, 0x22, 0x31, 0x49, 0x0C, 0x70, 0xA7,
        0xCD, 0x45, 0x00, 0x02, 0xE5, 0x74, 0xF6, 0x9E, 0x02,
    },
    .plain = "0123456789" ** 40,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 5 -c`):
/// '0123456789' ** 40.
pub const cli_digits_q5: Stream = .{
    .bytes = &.{
        0x1F, 0x8F, 0x01, 0x00, 0xC4, 0x0D, 0xC6, 0xE6, 0x25, 0x8D, 0x20, 0x30,
        0x14, 0x80, 0x40, 0x39, 0x9D, 0xBD, 0x07,
    },
    .plain = "0123456789" ** 40,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 9 -c`):
/// '0123456789' ** 40.
pub const cli_digits_q9: Stream = .{
    .bytes = &.{
        0x1F, 0x8F, 0x01, 0x00, 0xC4, 0x0D, 0xC6, 0xE6, 0x25, 0x8D, 0x20, 0x30,
        0x14, 0x80, 0x40, 0x39, 0x9D, 0xBD, 0x07,
    },
    .plain = "0123456789" ** 40,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 11 -c`):
/// '0123456789' ** 40.
pub const cli_digits_q11: Stream = .{
    .bytes = &.{
        0x1F, 0x8F, 0x01, 0xF8, 0xC5, 0x0D, 0xC6, 0xE6, 0x25, 0x8D, 0x20, 0x30,
        0x14, 0x00, 0x08, 0x94, 0xD3, 0xD9, 0x7B,
    },
    .plain = "0123456789" ** 40,
};

/// The pinned CLI's own output (brotli 1.2.0, `brotli -q 9 -w 16 -c`): the
/// largest CLI fixture, over this file's own text at the commit that landed
/// it, frozen as `testdata/cli_golden_q9_w16.in` (later edits to this file do
/// not move it). One stream carries the four rules the oracle lane alone used
/// to catch — an implicit-distance command followed by a distance read, a
/// dictionary reference followed by distance code 0 (§4's push exclusions), a
/// code-length run of 17 next to a 16, and an alphabet whose first length
/// symbol is 16 (§3.5's "the previous length is taken to be 8") — and each
/// mutant of those four fails the tests that decode it. Which shapes a stream
/// carries is the encoder's choice, not a property of the format: at `-q 11`
/// this text's stream drops the first-length-16 tree, so the pair is frozen
/// at the quality that carries all four. The stream is the CLI's byte-exact
/// encode of the `.in` bytes — `brotli -d -c` returns them unchanged — and
/// the tests decode it through both layers.
pub const cli_golden_q9_w16: Stream = .{
    .bytes = @embedFile("testdata/cli_golden_q9_w16.br"),
    .plain = @embedFile("testdata/cli_golden_q9_w16.in"),
};
