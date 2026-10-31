//! zlib.decode: one-shot zlib decompression, plus the header and trailer
//! checks the streaming `Reader` shares.
//!
//! `decompress` decodes one complete zlib stream from `source` into `target`.
//! It runs the streaming `Reader` over the whole input and maps the recorded
//! failure back to `DecompressError`, so the one-shot and streaming layers
//! cannot disagree about a stream (driver: `src/internal/container.zig`,
//! `DecodeHooks`, instantiated over `framing.zig`). `checkHeader` tests the
//! two header bytes (CM, CINFO, FCHECK) and `checkDictionary` the FDICT
//! dictionary identity (`§2.2`); `checkTrailer` compares ADLER32, so both
//! layers report the same specific errors.
//!
//! Format: docs/specs/rfc1950-zlib.txt (§2.2 header, dictionary, and
//! trailer; §2.3 decoder obligations).

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const print = std.debug.print;
const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const container = internal.container;
/// Read exactly `target.len` bytes from `input` and consume them, refilling
/// as needed. Input that ends first is `error.Truncated`; a failing input is
/// `error.ReadFailed`. This is the shared driver's `container.readExact`,
/// re-exported because the header and trailer reads are built from it.
pub const readExact = container.readExact;
const adler32 = @import("adler32.zig");
const common = @import("common.zig");
const readInt = common.readInt;
const encode = @import("encode.zig");
/// RFC 1950 §2.2 — the header is 2 bytes (CMF and FLG), the preset
/// dictionary's DICTID 4 when FDICT is set, and the trailer 4 (ADLER32).
/// Defined in `encode.zig` and re-exported here so decoder-side code need not
/// reach across namespaces.
pub const header_len = encode.header_len;
pub const dict_id_len = encode.dict_id_len;
pub const trailer_len = encode.trailer_len;
const framing = @import("framing.zig");
/// Everything `decompress` can return: flate's decode errors (`Truncated`,
/// `BufferTooSmall`, `InvalidBlockType`, ...) plus this module's: `BadHeader`
/// (CM is not 8, CINFO is above 7, or FCHECK is wrong; §2.2, §2.3),
/// `DictionaryRequired` (FDICT is set and `dict` is null; §2.3),
/// `DictionaryMismatch` (`dict`'s Adler-32 is not the header's DICTID; §2.2),
/// and `WrongChecksum` (ADLER32 does not match; §2.3). `BufferTooSmall` means
/// the stream does not fit in `target`.
pub const DecompressError = framing.DecompressError;
const golden = @import("golden.zig");
const Reader = @import("Reader.zig");

/// The failures `checkHeader` and `checkDictionary` report. Input that ends
/// inside the header or the DICTID is `Truncated`, reported by the code that
/// reads the bytes (`readExact`).
pub const HeaderError = error{
    BadHeader,
    DictionaryRequired,
    DictionaryMismatch,
};

/// RFC 1950 §2.2 — the FLG bits: FCHECK in 0-4, FDICT is bit 5, FLEVEL in
/// 6-7. FDICT is the one the decoder acts on (`§2.3`): set, it names a preset
/// dictionary whose DICTID follows the header, and the caller's dictionary is
/// checked against it. FLEVEL "may be ignored" (`§2.3`).
pub const flg_fdict = 0x20;

/// Check the two header bytes (`§2.2`, `§2.3`). CM, CINFO, and FCHECK
/// problems are `BadHeader`; FDICT is not itself a failure — it is checked
/// against the caller's dictionary by `checkDictionary`. The checks run in
/// that order.
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
pub fn checkHeader(cmf: u8, flg: u8) error{BadHeader}!void {
    if (cmf & 0x0f != 8) return error.BadHeader;
    if (cmf >> 4 > 7) return error.BadHeader;
    if ((@as(u16, cmf) * 256 + @as(u16, flg)) % 31 != 0) return error.BadHeader;
}

/// Check the dictionary a set FDICT flag names (`§2.2`): read the 4-byte
/// DICTID (the dictionary's Adler-32, most-significant byte first) and compare
/// it with `dict`'s. With no dictionary supplied the stream is
/// `DictionaryRequired` before the DICTID is even read (`§2.3`: "A compliant
/// decompressor must give an error indication if FDICT is set and DICTID is
/// not the identifier of a known preset dictionary"); with one, a mismatched
/// identifier is `DictionaryMismatch`. Both are before any body byte.
///
/// DICTID names the *whole* dictionary, so a dictionary longer than 32 KiB
/// must be supplied in full even though only its last 32 KiB is matchable
/// (`deflateSetDictionary`'s tail cut; `§2.2`).
pub fn checkDictionary(
    input: *Io.Reader,
    dict: ?[]const u8,
) error{ DictionaryRequired, DictionaryMismatch, Truncated, ReadFailed }!void {
    const bytes = dict orelse return error.DictionaryRequired;
    var id: [dict_id_len]u8 = undefined;
    try readExact(input, &id);
    if (readInt(u32, &id) != adler32.adler32(1, bytes)) return error.DictionaryMismatch;
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
/// `dict` is the stream's preset dictionary or `null` (`§2.2`): the FDICT
/// flag's bytes. With FDICT set the dictionary must be supplied — its
/// Adler-32 is checked against the header's DICTID before any body byte
/// (`error.DictionaryRequired` when it is null, `error.DictionaryMismatch`
/// when it is wrong) — and it pre-seeds the decode window as history. With
/// FDICT clear the stream names no dictionary and `dict` is unused.
///
/// The other errors are `DecompressError`'s: `Truncated` when `source` ends
/// early (an empty `source` included), `BadHeader`, `WrongChecksum`, and
/// flate's errors for a malformed body. After any error, `target`'s contents
/// are unspecified. The Adler-32 is compared after the body is decoded, so
/// even `WrongChecksum` leaves unverified output in `target`.
///
/// Bytes after ADLER32 are ignored ("Any data which may appear after ADLER32
/// are not part of the zlib stream", `§2.2`), and the return value does not
/// say where the stream ended. Use the streaming `Reader` when the boundary
/// matters.
///
/// Uses about 68 KiB of stack (the 64 KiB decode window plus 4 KiB of reader
/// state). Allocates nothing.
pub fn decompress(source: []const u8, target: []u8, dict: ?[]const u8) DecompressError!usize {
    return Hooks.decompress(source, target, dict);
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/specs/rfc1950-zlib.txt §2.1 (byte order), §2.2
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

    // FDICT is not the header check's business: a set flag names a dictionary
    // whose DICTID follows the header, and `checkDictionary` judges it against
    // the caller's bytes (`§2.2`, `§2.3`). The FCHECK = 31 corner (`78 3f`,
    // C zlib's and Go's FDICT + FLEVEL-0 emission) satisfies the arithmetic
    // and passes here, as does the Go vector's `78 bb`.
    try checkHeader(0x78, 0xbb);
    try checkHeader(0x78, 0x3f);

    // The order the checks run in: a pair that is both FDICT and bad-FCHECK
    // is `BadHeader` (the classification `headerClass` in `fuzz.zig` uses).
    try testing.expectError(error.BadHeader, checkHeader(0x78, 0xbf));
}

test "decode: the one-shot decodes the golden table" {
    // The ported golang/go `zlibTests` and std's in-tree zlib vectors: every
    // case through the one-shot decoder, with the pinned outcome and the
    // sentinel overrun rule. The failing cases carry the specific errors
    // (FDICT without a dictionary -> DictionaryRequired, a wrong one ->
    // DictionaryMismatch, bad FCHECK -> BadHeader, truncated -> Truncated).
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, 2048 + @as(usize, sentinel.len));
    defer gpa.free(window);
    for (golden.zlib_cases) |tc| {
        const cap = switch (tc.expect) {
            .ok => |want| want.len,
            else => window.len,
        };
        golden.checkOneShot(window, cap, tc.source, tc.dict, tc.expect) catch |err| {
            print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
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
        golden.checkOneShot(window, cap, tc.source, tc.dict, tc.expect) catch |err| {
            print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
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
        golden.checkOneShot(window, want.len, tc.source, tc.dict, tc.expect) catch |err| {
            print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
            return err;
        };
    }
}

test "decode: a zero-byte input is Truncated, and so is every prefix" {
    // An empty input is `Truncated`: no stream began. The hostile-header pins
    // in `fuzz.zig` carry the same expectations; Go's "truncated empty", "not
    // enough data", and the two "amid raw/fixed-block" vectors are the ported
    // forms.
    try testing.expectError(error.Truncated, decompress("", &.{}, null));
    const empty_stream = "\x78\x9c\x03\x00\x00\x00\x00\x01";
    var i: usize = 0;
    while (i < empty_stream.len) : (i += 1) {
        try testing.expectError(error.Truncated, decompress(empty_stream[0..i], &.{}, null));
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
        try golden.checkOneShot(window, source.len, bad[0..len], null, .{
            .fail_with = error.WrongChecksum,
        });
    }

    // The intact stream decodes; the same bytes with one trailer byte
    // dropped are `Truncated`.
    try golden.checkOneShot(window, source.len, stream[0..len], null, .{ .ok = source });
    try golden.checkOneShot(window, source.len, stream[0 .. len - 1], null, .{
        .fail_with = error.Truncated,
    });
}

test "decode: the FCHECK = 31 corner stream is the reference's emission" {
    // A dictionary stream written by python3's zlib (the C reference):
    // `zlib.compressobj(0, DEFLATED, 15, 9, Z_DEFAULT_STRATEGY, dict)` with
    // the C reference's naive FCHECK emits the header `78 3f`: FCHECK = 31,
    // which is 0 mod 31 and fits the five-bit field. A validator that
    // recomputes FCHECK rejects the whole Go/C-zlib output family here; ours
    // passes the header and lands on the dictionary check, never
    // `BadHeader`.
    try checkHeader(golden.fcheck31_dict_stream[0], golden.fcheck31_dict_stream[1]);
    try testing.expectError(
        error.DictionaryRequired,
        decompress(&golden.fcheck31_dict_stream, &.{}, null),
    );
    // The C reference's own dictionary decodes the stream to its payload: the
    // dictionary is a stored body's window pre-seed, so only the DICTID and
    // the framing's accounting are exercised.
    const window = try testing.allocator.alloc(u8, golden.fcheck31_plain.len);
    defer testing.allocator.free(window);
    sentinel.fill(window);
    const n = try decompress(&golden.fcheck31_dict_stream, window, golden.fcheck31_dict);
    try testing.expectEqual(golden.fcheck31_plain.len, n);
    try testing.expectEqualSlices(u8, golden.fcheck31_plain, window[0..n]);
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
    try testing.expectError(error.InvalidBlockType, decompress(stream[0..len], &target, null));
}

test "decode: the empty target is a valid cap for an empty stream" {
    // `target` is a cap; an empty stream needs no room.
    var stream: [32]u8 = undefined;
    const len = try encode.compress("", &stream, .{});
    try testing.expectEqual(@as(usize, 0), try decompress(stream[0..len], &.{}, null));
}

test "decode: a bomb stream is capped, never an overrun" {
    // A stream that does not fit is `BufferTooSmall`; the bytes past the cap
    // are untouched.
    var stream: [512]u8 = undefined;
    const source = "A" ** 4096;
    const len = try encode.compress(source, &stream, .{});
    try testing.expect(len < stream.len);

    var window: [4096 + @as(usize, sentinel.len)]u8 = undefined;
    try golden.checkOneShot(&window, source.len - 1, stream[0..len], null, .{
        .fail_with = error.BufferTooSmall,
    });
    try golden.checkOneShot(&window, source.len, stream[0..len], null, .{ .ok = source });
}

test "decode: the dictionary mismatch matrix" {
    // RFC 1950 §2.2, §2.3 — FDICT set means the dictionary must be supplied
    // and its Adler-32 must be the header's DICTID. The four cases, on Go's
    // own dictionary vector (`golden.dictionary_stream`):
    //
    //   FDICT set, no dictionary    -> DictionaryRequired, before the DICTID
    //                                  is read (§2.3's error rule)
    //   FDICT set, wrong bytes      -> DictionaryMismatch, at the compare
    //   FDICT set, the right bytes  -> decodes
    //   FDICT clear, a dictionary   -> the stream names none; unused
    //
    // The first two fail before any body byte, so nothing is written to
    // `target`.
    const stream: []const u8 = &golden.dictionary_stream;
    var target: [64 + @as(usize, sentinel.len)]u8 = undefined;

    sentinel.fill(&target);
    try testing.expectError(error.DictionaryRequired, decompress(stream, &target, null));
    try sentinel.expect(&target, 0);

    sentinel.fill(&target);
    try testing.expectError(
        error.DictionaryMismatch,
        decompress(stream, &target, "not the dictionary"),
    );
    try sentinel.expect(&target, 0);
    // An empty dictionary is a dictionary whose Adler-32 (1) is not DICTID.
    try testing.expectError(error.DictionaryMismatch, decompress(stream, &target, ""));
    try sentinel.expect(&target, 0);

    sentinel.fill(&target);
    const n = try decompress(stream, &target, &golden.dictionary);
    try testing.expectEqualStrings("Hello, World!\n", target[0..n]);
    try sentinel.expect(&target, n);

    // FDICT clear: the stream names no dictionary and a supplied one is
    // unused, so one reader can walk a mixed sequence of streams.
    var plain_stream: [64]u8 = undefined;
    const source = "hello, zlib";
    const len = try encode.compress(source, &plain_stream, .{});
    sentinel.fill(&target);
    const m = try decompress(plain_stream[0..len], &target, &golden.dictionary);
    try testing.expectEqualStrings(source, target[0..m]);
    try sentinel.expect(&target, m);
}

test "decode: a dictionary stream whose reach fits its window" {
    // A stream whose distances reach into the dictionary decodes only with
    // the bytes the encoder used: raw flate's `InvalidMatch` is the body's
    // answer to a short history, and the container's DICTID compare catches a
    // different one first. The FCHECK = 31 corner's stream is a stored body,
    // so this is the `golden.dict_stream` shape at the container level.
    const dict = "she sells seashells by the seashore\n";
    const source = "she sells seashells she sells seashells by the seashore\n";
    var stream: [encode.maxCompressedLength(source.len)]u8 = undefined;
    const len = try encode.compress(source, &stream, .{ .level = .@"1", .dict = dict });

    var plain: [source.len + @as(usize, sentinel.len)]u8 = undefined;
    sentinel.fill(&plain);
    const n = try decompress(stream[0..len], plain[0..source.len], dict);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, plain[0..n]);
    try sentinel.expect(&plain, n);

    // The right DICTID but a window too short to reach the match: a truncated
    // dictionary cannot pass the compare (DICTID names the whole), so the
    // reach failure is unreachable through the container. This pins that the
    // compare runs first.
    try testing.expectError(
        error.DictionaryMismatch,
        decompress(stream[0..len], &plain, dict[0 .. dict.len - 1]),
    );
}
