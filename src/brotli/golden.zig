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
//! decoder bug.
//!
//! `Packer` is the test-side half of that writer, so a test can rebuild a
//! vector's fields or build a variant of it.

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
