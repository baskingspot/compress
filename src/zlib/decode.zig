//! zlib.decode: one-shot zlib decompression, plus the header and trailer
//! checks the streaming `Reader` shares.
//!
//! `decompress` decodes one complete zlib stream from `source` into `target`.
//! It runs the streaming `Reader` over the whole input and maps the recorded
//! failure back to `DecompressError`, so the one-shot and streaming layers
//! cannot disagree about a stream (driver: `src/internal/container.zig`,
//! `DecodeHooks`, instantiated over `framing.zig`). `checkHeader` tests the
//! two header bytes (CM, CINFO, FCHECK, FDICT) and `checkTrailer` compares
//! ADLER32, so both layers report the same specific errors.
//!
//! Format: docs/research/specs/rfc1950-zlib.txt (§2.2 header and trailer,
//! §2.3 decoder obligations).

const std = @import("std");
const testing = std.testing;

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const container = internal.container;
/// Read exactly `target.len` bytes from `input` and consume them, refilling
/// as needed. Input that ends first is `error.Truncated`; a failing input is
/// `error.ReadFailed`. This is the shared driver's `container.readExact`,
/// re-exported because the header and trailer reads are built from it.
pub const readExact = container.readExact;
const common = @import("common.zig");
const readInt = common.readInt;
const encode = @import("encode.zig");
/// RFC 1950 §2.2 — the header is 2 bytes (CMF and FLG) and the trailer is 4
/// (ADLER32). Defined in `encode.zig` and re-exported here so decoder-side
/// code need not reach across namespaces.
pub const header_len = encode.header_len;
pub const trailer_len = encode.trailer_len;
const framing = @import("framing.zig");
/// Everything `decompress` can return: flate's decode errors (`Truncated`,
/// `BufferTooSmall`, `InvalidBlockType`, ...) plus three of this module's:
/// `BadHeader` (CM is not 8, CINFO is above 7, or FCHECK is wrong; §2.2,
/// §2.3), `DictionaryRequired` (FDICT is set, and preset dictionaries are not
/// supported; §2.3), and `WrongChecksum` (ADLER32 does not match; §2.3).
/// `BufferTooSmall` means the stream does not fit in `target`.
pub const DecompressError = framing.DecompressError;
const golden = @import("golden.zig");
const Reader = @import("Reader.zig");

/// The failures `checkHeader` reports. Input that ends inside the header is
/// `Truncated`, reported by the code that reads the bytes (`readExact`).
pub const HeaderError = error{
    BadHeader,
    DictionaryRequired,
};

/// RFC 1950 §2.2 — the FLG bits: FCHECK in 0-4, FDICT is bit 5, FLEVEL in
/// 6-7. FDICT is the one the decoder acts on (`§2.3`); a decompressor "may
/// ignore FLEVEL and still be compliant" (`§2.3`).
pub const flg_fdict = 0x20;

/// Check the two header bytes (`§2.2`, `§2.3`). CM, CINFO, and FCHECK
/// problems are `BadHeader`; a set FDICT flag is `DictionaryRequired`. The
/// checks run in that order.
///
/// - CM (CMF's low four bits) must be 8: "another value could indicate the
///   presence of new features that would cause subsequent data to be
///   interpreted incorrectly" (`§2.3`).
/// - CINFO (CMF's high four bits) must be at most 7: "Values of CINFO above 7
///   are not allowed in this version of the specification" (`§2.2`).
/// - FCHECK is checked as `(CMF*256 + FLG) % 31 == 0`, not by recomputing the
///   value and comparing. C zlib and Go write FCHECK = 31 when FDICT is set
///   and FLEVEL is 0 (`78 3f`). That pair is valid (31 is 0 mod 31 and fits
///   the five-bit field), and a check that recomputes FCHECK would reject it
///   (`§2.2`).
/// - FDICT set is `DictionaryRequired`. RFC 1950 lets a decoder with no
///   dictionary registry reject such streams (`§2.3`). The four DICTID bytes
///   behind the flag are never read, so they are never mistaken for deflate
///   data.
pub fn checkHeader(cmf: u8, flg: u8) HeaderError!void {
    if (cmf & 0x0f != 8) return error.BadHeader;
    if (cmf >> 4 > 7) return error.BadHeader;
    if ((@as(u16, cmf) * 256 + @as(u16, flg)) % 31 != 0) return error.BadHeader;
    if (flg & flg_fdict != 0) return error.DictionaryRequired;
}

/// Compare the 4-byte trailer with `adler`, the Adler-32 of the decoded
/// bytes. The trailer is a big-endian u32 (`§2.2`). Returns
/// `error.WrongChecksum` on a mismatch. RFC 1950 makes this check mandatory
/// for a decoder: "A compliant decompressor must check CMF, FLG, and ADLER32,
/// and provide an error indication if any of these have incorrect values"
/// (`§2.3`).
pub fn checkTrailer(trailer: *const [trailer_len]u8, adler: u32) error{WrongChecksum}!void {
    if (readInt(u32, trailer[0..4]) != adler) return error.WrongChecksum;
}

/// The shared container driver over this module's framing and streaming
/// reader (`src/internal/container.zig`).
const Hooks = container.DecodeHooks(framing, Reader);

/// Decode one complete zlib stream from `source` into `target` and return the
/// decoded length. `target` is a cap, not a size hint: the format stores no
/// decoded length, so the caller sizes it from outside knowledge. A stream
/// that decodes to more than `target.len` bytes returns
/// `error.BufferTooSmall`, and nothing is written past `target`.
///
/// The other errors are `DecompressError`'s: `Truncated` when `source` ends
/// early (an empty `source` included), `BadHeader`, `DictionaryRequired`,
/// `WrongChecksum`, and flate's errors for a malformed body. After any error,
/// `target`'s contents are unspecified. The Adler-32 is compared after the
/// body is decoded, so even `WrongChecksum` leaves unverified output in
/// `target`.
///
/// Bytes after ADLER32 are ignored ("Any data which may appear after ADLER32
/// are not part of the zlib stream", `§2.2`), and the return value does not
/// say where the stream ended. Use the streaming `Reader` when the boundary
/// matters.
///
/// Uses about 68 KiB of stack (the 64 KiB decode window plus 4 KiB of reader
/// state). Allocates nothing.
pub fn decompress(source: []const u8, target: []u8) DecompressError!usize {
    return Hooks.decompress(source, target);
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc1950-zlib.txt §2.1 (byte order), §2.2
// (the header, FCHECK, FLEVEL, the trailer), §2.3 (decoder obligations).
// Every decode is sentinel-checked.
// ---------------------------------------------------------------------------

test "decode: the header check is the §2.2 arithmetic" {
    // RFC 1950 §2.3 — CM: "another value could indicate the presence of new
    // features that would cause subsequent data to be interpreted
    // incorrectly". §2.2 — CINFO above 7 is not allowed; FCHECK is
    // `(CMF*256 + FLG) % 31 == 0`.
    try testing.expectError(error.BadHeader, checkHeader(0x09, 0x15)); // CM 9
    try testing.expectError(error.BadHeader, checkHeader(0x88, 0x98)); // CINFO 8
    try testing.expectError(error.BadHeader, checkHeader(0x78, 0x9f)); // FCHECK
    try testing.expectError(error.BadHeader, checkHeader(0x78, 0x00)); // FCHECK

    // Conformant pairs decode: any CINFO at most 7, any FLEVEL band (`§2.3`:
    // FLEVEL may be ignored), and any FCHECK that satisfies the arithmetic.
    try checkHeader(0x78, 0x9c); // CINFO 7, FLEVEL 2
    try checkHeader(0x78, 0x01); // CINFO 7, FLEVEL 0
    try checkHeader(0x78, 0x5e); // CINFO 7, FLEVEL 1
    try checkHeader(0x78, 0xda); // CINFO 7, FLEVEL 3
    try checkHeader(0x08, 0x1d); // CINFO 0 (a 256-byte window) is legal

    // FDICT set is the dictionary refusal, before any body byte (§2.3). The
    // FCHECK = 31 corner: `78 3f` (C zlib's and Go's FDICT + FLEVEL-0
    // emission) satisfies the arithmetic and must land on
    // `DictionaryRequired`, never `BadHeader`.
    try testing.expectError(error.DictionaryRequired, checkHeader(0x78, 0xbb));
    try testing.expectError(error.DictionaryRequired, checkHeader(0x78, 0x3f));

    // The order the checks run in: a pair that is both FDICT and bad-FCHECK
    // is `BadHeader` (the classification `headerClass` in `fuzz.zig` uses).
    try testing.expectError(error.BadHeader, checkHeader(0x78, 0xbf));
}

test "decode: the one-shot decodes the golden table" {
    // The ported golang/go `zlibTests` and std's in-tree zlib vectors: every
    // case through the one-shot decoder, with the pinned outcome and the
    // sentinel overrun rule. The failing cases carry the specific errors
    // (FDICT -> DictionaryRequired, bad FCHECK -> BadHeader, truncated ->
    // Truncated).
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, 2048 + @as(usize, sentinel.len));
    defer gpa.free(window);
    for (golden.zlib_cases) |tc| {
        const cap = switch (tc.expect) {
            .ok => |want| want.len,
            else => window.len,
        };
        golden.checkOneShot(window, cap, tc.source, tc.expect) catch |err| {
            std.debug.print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
            return err;
        };
    }
}

test "decode: the std in-tree vectors and the divergence pins" {
    // Zig 0.16 std's container tests (MIT, in-tree) as decoder goldens, plus
    // the divergence pins: std checks neither FCHECK nor FDICT
    // (`std/compress/flate/Decompress.zig:310-314`), so it accepts `78 9f`
    // and misparses an FDICT stream's DICTID as deflate data; ours rejects
    // both, per `§2.2` and `§2.3`.
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, 512 + @as(usize, sentinel.len));
    defer gpa.free(window);
    for (golden.std_cases) |tc| {
        const cap = switch (tc.expect) {
            .ok => |want| want.len,
            else => window.len,
        };
        golden.checkOneShot(window, cap, tc.source, tc.expect) catch |err| {
            std.debug.print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
            return err;
        };
    }
}

test "decode: the one-shot decodes the golden table's trailing-byte cases" {
    // Bytes after ADLER32 are ignored by the one-shot: the stream decodes
    // identically with markers, a truncated next stream, or a whole second
    // stream behind it (`§2.2`: "Any data which may appear after ADLER32 are
    // not part of the zlib stream").
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, 128 + @as(usize, sentinel.len));
    defer gpa.free(window);
    for (golden.zlib_cases) |tc| {
        if (tc.trailing == null) continue;
        const want = switch (tc.expect) {
            .ok => |bytes| bytes,
            else => continue,
        };
        golden.checkOneShot(window, want.len, tc.source, tc.expect) catch |err| {
            std.debug.print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
            return err;
        };
    }
}

test "decode: a zero-byte input is Truncated, and so is every prefix" {
    // An empty input is `Truncated`: no stream began. The hostile-header pins
    // in `fuzz.zig` carry the same expectations; Go's "truncated empty", "not
    // enough data", and the two "amid raw/fixed-block" vectors are the ported
    // forms.
    try testing.expectError(error.Truncated, decompress("", &.{}));
    const empty_stream = "\x78\x9c\x03\x00\x00\x00\x00\x01";
    var i: usize = 0;
    while (i < empty_stream.len) : (i += 1) {
        try testing.expectError(error.Truncated, decompress(empty_stream[0..i], &.{}));
    }
}

test "decode: the trailer check is specific" {
    // RFC 1950 §2.3 — "A compliant decompressor must check CMF, FLG, and
    // ADLER32". A corrupt trailer byte is `WrongChecksum`; a trailer byte
    // missing is `Truncated`.
    var stream: [64]u8 = undefined;
    const source = "hello world\n";
    const len = try encode.compress(source, &stream, .{});
    const window = try testing.allocator.alloc(u8, 64 + @as(usize, sentinel.len));
    defer testing.allocator.free(window);

    for (0..trailer_len) |at| {
        var bad = stream;
        bad[len - trailer_len + at] ^= 0x80;
        try golden.checkOneShot(window, source.len, bad[0..len], .{
            .fail_with = error.WrongChecksum,
        });
    }

    // The intact stream decodes; the same bytes with one trailer byte
    // dropped are `Truncated`.
    try golden.checkOneShot(window, source.len, stream[0..len], .{ .ok = source });
    try golden.checkOneShot(window, source.len, stream[0 .. len - 1], .{
        .fail_with = error.Truncated,
    });
}

test "decode: the FCHECK = 31 corner stream is the reference's emission" {
    // A dictionary stream written by python3's zlib (the C reference):
    // `zlib.compressobj(0, DEFLATED, 15, 9, Z_DEFAULT_STRATEGY, dict)` with
    // the C reference's naive FCHECK emits the header `78 3f`: FCHECK = 31,
    // which is 0 mod 31 and fits the five-bit field. A validator that
    // recomputes FCHECK rejects the whole Go/C-zlib output family here; ours
    // lands on the dictionary refusal, never `BadHeader`.
    try testing.expectError(
        error.DictionaryRequired,
        decompress(&golden.fcheck31_dict_stream, &.{}),
    );
    // The FCHECK arithmetic accepts the pair; the FDICT flag is the refusal.
    try testing.expectError(
        error.DictionaryRequired,
        checkHeader(golden.fcheck31_dict_stream[0], golden.fcheck31_dict_stream[1]),
    );
}

test "decode: a corrupt body fails with flate's detail" {
    // RFC 1950 §2.2 — CM=8's "deflate" method is the RFC 1951 document; the
    // body is flate's rules unchanged, and its failures are the module's own
    // (`Truncated`, `InvalidBlockType`, ...).
    var stream: [256]u8 = undefined;
    const source = "the quick brown fox jumps over the lazy dog. " ** 4;
    const len = try encode.compress(source, &stream, .{});
    // BTYPE=11 (reserved, `rfc1951-deflate.txt §3.2.3`) in the first body
    // byte: the body's first three bits are BFINAL, BTYPE.
    stream[header_len] |= 0b110;
    var target: [256]u8 = undefined;
    try testing.expectError(error.InvalidBlockType, decompress(stream[0..len], &target));
}

test "decode: the empty target is a valid cap for an empty stream" {
    // `target` is a cap; an empty stream needs no room.
    var stream: [32]u8 = undefined;
    const len = try encode.compress("", &stream, .{});
    try testing.expectEqual(@as(usize, 0), try decompress(stream[0..len], &.{}));
}

test "decode: a bomb stream is capped, never an overrun" {
    // A stream that does not fit is `BufferTooSmall`; the bytes past the cap
    // are untouched.
    var stream: [512]u8 = undefined;
    const source = "A" ** 4096;
    const len = try encode.compress(source, &stream, .{});
    try testing.expect(len < stream.len);

    var window: [4096 + @as(usize, sentinel.len)]u8 = undefined;
    try golden.checkOneShot(&window, source.len - 1, stream[0..len], .{
        .fail_with = error.BufferTooSmall,
    });
    try golden.checkOneShot(&window, source.len, stream[0..len], .{ .ok = source });
}
