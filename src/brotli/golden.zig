//! Golden wire vectors for the decoder's tests: whole streams and the bytes
//! they decode to.
//!
//! Provenance: the empty family is `brotli-notes.md` §7.2's hand-decoded
//! table (google/brotli v1.2.0's `tests/testdata/empty.compressed*`, not
//! vendored here); the metadata and uncompressed streams are hand-built wire
//! vectors in the §7.3 style, and the RFC 7932 §11.1 trivial-compressor
//! shapes are generated in the tests. Every vector here was verified against
//! the pinned CLI (brotli 1.2.0, the flake's) with `brotli -d -c` before
//! landing: a vector the reference refuses would be a broken fixture, not a
//! decoder bug.

/// A whole brotli stream and the bytes it decodes to.
pub const Stream = struct {
    /// The compressed bytes.
    bytes: []const u8,
    /// The decoded bytes.
    plain: []const u8,
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
