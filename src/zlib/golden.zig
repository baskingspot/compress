//! Golden fixtures for the zlib container, shared by every layer's tests:
//! `decode.zig` runs the one-shot decoder over them, `Reader.zig` the
//! streaming layer, and the `Writer.zig` and `encode.zig` tests reuse the
//! payloads.
//!
//! Sources:
//!   - golang/go `src/compress/zlib/reader_test.go` `zlibTests`
//!     (BSD-3-Clause; attribution in THIRD_PARTY.md), 14 vectors ported as
//!     hex. Its own comment says the golden bytes came from the C reference's
//!     `zpipe.c`. Outcomes differ from Go's where this module decided
//!     otherwise: an FDICT stream is `DictionaryRequired` before any body
//!     byte (never Go's `io.ErrUnexpectedEOF` or `ErrDictionary`), and a
//!     truncated trailer is `Truncated`.
//!   - Zig 0.16 std's zlib tests in `std/compress/flate/Decompress.zig` (MIT,
//!     in-tree): the stored "Hello world\n" stream, "zlib should not
//!     overshoot" (four bytes after the trailer stay unconsumed), and the
//!     bad-CM, bad-CINFO, truncated-header, and truncated-checksum failures.
//!     The fixed and dynamic streams are std's gzip vectors with zlib framing
//!     in place of gzip's (the bodies are std's, checked against the C
//!     reference). std accepts several streams this module rejects (no FCHECK
//!     check, no FDICT handling, no trailer comparison); the tests pin that
//!     by running std's decoder next to ours.
//!   - Header and dictionary emissions of C zlib, checked through python3's
//!     `zlib`: the FLEVEL/FCHECK header bands (`78 01`, `78 5e`, `78 9c`,
//!     `78 da`) and the dictionary + FLEVEL-0 corner's `78 3f` (FCHECK = 31).
//!
//! Every decode here runs the sentinel overrun check: the target is
//! pre-filled with a repeating sentinel pattern (`internal.sentinel`) and
//! every byte past the decoded length must be untouched.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const print = std.debug.print;

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const adler32 = @import("adler32.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const readInt = @import("common.zig").readInt;

/// Comptime hex decoding, so the ported vectors keep golang/go's own
/// hexstring spelling instead of a byte-list transcription.
fn hex(comptime text: []const u8) [text.len / 2]u8 {
    @setEvalBranchQuota(100_000);
    comptime assert(text.len % 2 == 0);
    var bytes: [text.len / 2]u8 = undefined;
    for (&bytes, 0..) |*byte, i| {
        byte.* = std.fmt.parseInt(u8, text[i * 2 ..][0..2], 16) catch unreachable;
    }
    return bytes;
}

/// What a golden stream must do.
pub const Expect = union(enum) {
    /// Decode to exactly these bytes.
    ok: []const u8,
    /// Reject the stream with any `DecompressError`.
    fail,
    /// Reject the stream with this specific error (the cases that pin a rule
    /// use this; the rest only have to fail).
    fail_with: decode.DecompressError,
};

/// One ported stream vector: Go's `desc`, `compressed`, and expected outcome.
pub const Case = struct {
    desc: []const u8,
    source: []const u8,
    expect: Expect,
    /// The dictionary the caller supplies to the decode, when the vector is a
    /// dictionary case: `null` is the no-dictionary call.
    dict: ?[]const u8 = null,
    /// What a fresh reader at the stream boundary finds in the trailing
    /// bytes, when the vector carries any: `null` when the stream is the
    /// whole source. This is the boundary policy's pin (`§2.2`: "Any data
    /// which may appear after ADLER32 are not part of the zlib stream"): the
    /// stream decodes, the trailing bytes are left unconsumed, and the next
    /// parse in a caller loop is the pinned outcome.
    trailing: ?Expect = null,
};

/// Go `zlibTests`' dictionary vector's dictionary: the 12 bytes
/// `"Hello World\n"`, whose Adler-32 is the stream's DICTID `1c 32 04 27`.
pub const dictionary = hex("48656c6c6f20576f726c640a");

/// Go `zlibTests`' "wrong dictionary" vector's dictionary: the 4 bytes
/// `"Hell"`, whose Adler-32 is not the stream's DICTID. Go reports
/// `ErrDictionary`; ours is the specific `DictionaryMismatch`.
pub const wrong_dictionary = hex("48656c6c");

/// The Go `zlibTests` dictionary vector: the FDICT header `78 bb`, the
/// DICTID `1c 32 04 27` (the Adler-32 of `dictionary`), and a
/// dict-compressed body. Go decodes it against the caller's dictionary and
/// fails `ErrDictionary` without one; ours is `DictionaryRequired` without
/// one and decodes to `"Hello, World!\n"` with it.
pub const dictionary_stream = hex("78bb1c320427f300b175201c452e0024120474");

/// Go's `zlibTests` (14 vectors, ported verbatim as hex) plus one case of
/// ours, the last: two empty streams back to back. RFC 1950 §2.2 (the header,
/// the trailer, the stream's end), §2.3 (decoder obligations).
pub const zlib_cases: []const Case = &.{
    // 1. "truncated empty": no stream began.
    .{ .desc = "truncated empty", .source = &hex(""), .expect = .{
        .fail_with = error.Truncated,
    } },
    // 2. "truncated dict": the FDICT header alone. Go reads the DICTID and
    // hits io.ErrUnexpectedEOF; the flag is refused before any DICTID byte
    // here (§2.3).
    .{ .desc = "truncated dict", .source = &hex("78bb"), .expect = .{
        .fail_with = error.DictionaryRequired,
    } },
    // 3. "truncated checksum": an FDICT stream with a DICTID, a stored body,
    // and no trailer. Go decodes against the caller's dictionary and hits
    // io.ErrUnexpectedEOF at the trailer; the FDICT refusal comes first here.
    .{
        .desc = "truncated checksum",
        .source = &hex("78bb00010001ca48cdc9c9d75128cf2fca49010400" ++ "00ffff"),
        .expect = .{ .fail_with = error.DictionaryRequired },
    },
    // 4. "empty": the C reference's empty stream, the bytes our own encoder
    // emits at `.fast` (the hostile-header pins in `fuzz.zig` carry them too).
    .{ .desc = "empty", .source = &hex("789c030000000001"), .expect = .{ .ok = "" } },
    // 5. "goodbye": the C reference's fixed-Huffman stream.
    .{
        .desc = "goodbye",
        .source = &hex("789c4bcfcf4f49aa4cd55128cf2fca49010028a5055e"),
        .expect = .{ .ok = "goodbye, world" },
    },
    // 6. "bad header (CINFO)": CM=8, CINFO=8 — "values of CINFO above 7 are
    // not allowed in this version" (§2.2).
    .{
        .desc = "bad header (CINFO)",
        .source = &hex("88980300000000" ++ "01"),
        .expect = .{ .fail_with = error.BadHeader },
    },
    // 7. "bad header (FCHECK)": 78 9f breaks the (CMF*256 + FLG) % 31 == 0
    // arithmetic (§2.2), and is the vector std's lax parse accepts.
    .{
        .desc = "bad header (FCHECK)",
        .source = &hex("789f030000000001"),
        .expect = .{ .fail_with = error.BadHeader },
    },
    // 8. "bad checksum": the body decodes, the trailer does not match
    // (§2.3: the check is a decoder MUST).
    .{
        .desc = "bad checksum",
        .source = &hex("789c0300000000ff"),
        .expect = .{ .fail_with = error.WrongChecksum },
    },
    // 9. "not enough data": the trailer is cut short.
    .{
        .desc = "not enough data",
        .source = &hex("789c03000000"),
        .expect = .{ .fail_with = error.Truncated },
    },
    // 10. "excess data is silently ignored": the empty stream followed by a
    // second header's first bytes and an invalid block-type byte. The
    // one-shot ignores everything past ADLER32 (§2.2); a fresh reader
    // at the boundary parses the second header and fails in its body.
    .{
        .desc = "excess data is silently ignored",
        .source = &hex("789c030000000001789cff"),
        .expect = .{ .ok = "" },
        .trailing = .{ .fail_with = error.InvalidBlockType },
    },
    // 11. "dictionary": Go decodes against the caller's dictionary; the
    // positive pin here supplies the same bytes and decodes the same output.
    .{
        .desc = "dictionary",
        .source = &dictionary_stream,
        .dict = &dictionary,
        .expect = .{ .ok = "Hello, World!\n" },
    },
    // 12. "wrong dictionary": Go's second dictionary vector — the same bytes
    // with a different caller-supplied dictionary. Go's one `ErrDictionary`
    // covers "no dictionary" and "wrong dictionary"; here the two are
    // distinct names, and this is the mismatch (`§2.2`: DICTID is the
    // dictionary's Adler-32).
    .{
        .desc = "wrong dictionary",
        .source = &dictionary_stream,
        .dict = &wrong_dictionary,
        .expect = .{ .fail_with = error.DictionaryMismatch },
    },
    // 13. "truncated zlib stream amid raw-block": a stored block whose LEN
    // declares 12 bytes with 6 present.
    .{
        .desc = "truncated zlib stream amid raw-block",
        .source = &hex("789c000c00f3ff68656c6c6f"),
        .expect = .{ .fail_with = error.Truncated },
    },
    // 14. "truncated zlib stream amid fixed-block".
    .{
        .desc = "truncated zlib stream amid fixed-block",
        .source = &hex("789cf248cd"),
        .expect = .{ .fail_with = error.Truncated },
    },
    // 15. The boundary the exact consumption exposes: two empty streams back
    // to back. Nothing in the format promises a second stream, but a caller
    // loop at the boundary decodes it.
    .{
        .desc = "empty stream x2 (the boundary is exact)",
        .source = &hex("789c030000000001789c030000000001"),
        .expect = .{ .ok = "" },
        .trailing = .{ .ok = "" },
    },
};

/// Zig 0.16 std's in-tree zlib vectors (MIT): the stored "Hello world\n"
/// stream, "zlib should not overshoot" (four bytes after the trailer stay
/// unconsumed), and the header failures. The fixed and dynamic streams are
/// std's gzip bodies with zlib's framing (header `78 9c`, the payload's
/// big-endian Adler-32), verified against the C reference.
pub const std_cases: []const Case = &.{
    .{
        .desc = "std: zlib stored block (type 0)",
        .source = &hex("789c010c00f3ff48656c6c6f20776f726c640a1cf20447"),
        .expect = .{ .ok = "Hello world\n" },
    },
    .{
        .desc = "std: zlib fixed block (type 1)",
        .source = &hex("789cf348cdc9c95728cf2fca49e102001cf20447"),
        .expect = .{ .ok = "Hello world\n" },
    },
    .{
        .desc = "std: zlib dynamic block (type 2)",
        .source = &hex("789c3dc6391100000c02302bb5521eff963816965c1e94cb6d01303304d3"),
        .expect = .{ .ok = "ABCDEABCD ABCDEABCD" },
    },
    // "zlib should not overshoot": the stream ends at ADLER32's last byte
    // (`8b 61 0f a4`); the four bytes behind it (`52 5a 94 12`) stay
    // unconsumed — a fresh reader at the boundary sees `52` as CM 2.
    .{
        .desc = "std: zlib should not overshoot",
        .source = &hex("789c73ce2fa82cca4ccf285108cfccc949cd55284bcc53084ece48ccccd65108" ++
            "cecc4b4f2cc82f4a5530b4b434d5b53403008b610fa4525a9412"),
        .expect = .{ .ok = "Copyright Willem van Schaik, Singapore 1995-96" },
        .trailing = .{ .fail_with = error.BadHeader },
    },
    .{
        .desc = "std: zlib header, wrong CM",
        .source = &hex("7994"),
        .expect = .{ .fail_with = error.BadHeader },
    },
    .{
        .desc = "std: zlib header, wrong CINFO",
        .source = &hex("8898"),
        .expect = .{ .fail_with = error.BadHeader },
    },
    .{
        .desc = "std: zlib truncated header",
        .source = &hex("78"),
        .expect = .{ .fail_with = error.Truncated },
    },
    .{
        .desc = "std: zlib truncated checksum",
        .source = &hex("78da030000"),
        .expect = .{ .fail_with = error.Truncated },
    },
};

/// The C reference's dictionary + FLEVEL-0 emission, as written by python3's
/// zlib: `zlib.compressobj(0, DEFLATED, 15, 9, Z_DEFAULT_STRATEGY, dict)` over
/// a 225-byte payload. The header is `78 3f`: FCHECK = 31, which is 0 mod 31
/// and fits the five-bit field, so it is conformant and must pass the FCHECK
/// check; FDICT is set, so the decode needs `fcheck31_dict`. DICTID
/// `fa 2c 0d 48` is that dictionary's Adler-32; the body is a stored block of
/// the payload; the trailer `d2 8c 50 c4` is the payload's Adler-32.
pub const fcheck31_dict_stream = hex(
    "783ffa2c0d4801e1001eff54686520717569636b2062726f776e20666f78206a" ++
        "756d7073206f76657220746865206c617a7920646f672e205468652071756963" ++
        "6b2062726f776e20666f78206a756d7073206f76657220746865206c617a7920" ++
        "646f672e2054686520717569636b2062726f776e20666f78206a756d7073206f" ++
        "76657220746865206c617a7920646f672e2054686520717569636b2062726f77" ++
        "6e20666f78206a756d7073206f76657220746865206c617a7920646f672e2054" ++
        "686520717569636b2062726f776e20666f78206a756d7073206f766572207468" ++
        "65206c617a7920646f672e20d28c50c4",
);

/// `fcheck31_dict_stream`'s dictionary: the 27 bytes
/// `"she sells seashells by the seashore\n"`, whose Adler-32 is that stream's
/// DICTID `fa 2c 0d 48`.
pub const fcheck31_dict = "she sells seashells by the seashore\n";

/// `fcheck31_dict_stream`'s payload: the 225 bytes the C reference compressed
/// against `fcheck31_dict` (a stored block, so the dictionary's only role is
/// the header's DICTID and the window it pre-seeds).
pub const fcheck31_plain = "The quick brown fox jumps over the lazy dog. " ** 5;

/// Decode `source` with the one-shot decoder, checking `expect` and the
/// sentinel overrun rule: `target` is `window[0..cap]`, and the bytes at and
/// past the cap must hold their sentinels — a decode never writes past its
/// cap, on success or failure. `dict` is the preset dictionary to supply
/// (`null` for a stream that names none).
pub fn checkOneShot(
    window: []u8,
    cap: usize,
    source: []const u8,
    dict: ?[]const u8,
    expect: Expect,
) !void {
    try testing.expect(cap <= window.len);
    sentinel.fill(window);
    const target = window[0..cap];
    switch (expect) {
        .ok => |want| {
            const n = try decode.decompress(source, target, dict);
            try testing.expectEqual(want.len, n);
            try testing.expectEqualSlices(u8, want, target[0..n]);
            try sentinel.expect(window, n);
        },
        .fail => {
            if (decode.decompress(source, target, dict)) |_| {
                return error.TestExpectedFailure;
            } else |_| {}
            try sentinel.expect(window, cap);
        },
        .fail_with => |want| {
            const got = decode.decompress(source, target, dict) catch |err| err;
            try testing.expectEqual(want, got);
            try sentinel.expect(window, cap);
        },
    }
}

/// Assert the deterministic header on an emitted stream: CMF = 0x78 (CM=8,
/// CINFO=7), FLG = the level's FLEVEL band plus the minimal FCHECK, FDICT
/// clear, and `(CMF*256 + FLG) % 31 == 0` (§2.2).
pub fn expectHeader(stream: []const u8, level: encode.Level) !void {
    try testing.expect(stream.len >= encode.header_len + encode.trailer_len);
    try testing.expectEqual(@as(u8, 0x78), stream[0]);
    try testing.expectEqual(encode.flgFor(level, false), stream[1]);
    try testing.expectEqual(
        @as(u16, 0),
        (@as(u16, stream[0]) * 256 + @as(u16, stream[1])) % 31,
    );
    // No dictionary: FDICT is clear.
    try testing.expectEqual(@as(u8, 0), stream[1] & decode.flg_fdict);
}

/// Assert the FDICT header on an emitted stream: CMF = 0x78, FLG = the
/// level's FLEVEL band plus FDICT plus the minimal FCHECK (§2.2), then the
/// 4-byte DICTID — the Adler-32 of the *whole* `dict`, most-significant byte
/// first (§2.1).
pub fn expectDictHeader(stream: []const u8, level: encode.Level, dict: []const u8) !void {
    try testing.expect(stream.len >= encode.header_len + encode.dict_id_len);
    try testing.expectEqual(@as(u8, 0x78), stream[0]);
    try testing.expectEqual(encode.flgFor(level, true), stream[1]);
    try testing.expect(stream[1] & decode.flg_fdict != 0);
    try testing.expectEqual(
        @as(u16, 0),
        (@as(u16, stream[0]) * 256 + @as(u16, stream[1])) % 31,
    );
    try testing.expectEqual(
        adler32.adler32(1, dict),
        readInt(u32, stream[encode.header_len..][0..encode.dict_id_len]),
    );
}

/// Assert the trailer on an emitted stream: the Adler-32 of `source`,
/// big-endian (§2.1, §2.2). The reference is std's Adler-32 kernel over the
/// same bytes, so this pins the container's byte accounting (every byte
/// exactly once, in order).
pub fn expectTrailer(stream: []const u8, source: []const u8) !void {
    try testing.expect(stream.len >= encode.trailer_len);
    const trailer = stream[stream.len - encode.trailer_len ..];
    try testing.expectEqual(
        std.hash.Adler32.hash(source),
        readInt(u32, trailer[0..4]),
    );
    try testing.expectEqual(
        adler32.adler32(1, source),
        readInt(u32, trailer[0..4]),
    );
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc1950-zlib.txt §2.1 (byte order), §2.2
// (the header, FLEVEL, FCHECK, the trailer), §2.3 (decoder obligations),
// §8.2 (the Adler-32 algorithm), §9 (the sample).
// ---------------------------------------------------------------------------

test "golden decode: golang/go zlibTests" {
    // The primary zlib conformance table, whose own comment says the golden
    // bytes came from the C reference's zpipe.c. Valid streams, the FDICT
    // vectors with this module's refusal, the excess-data boundary, and the
    // corrupt/truncated vectors with their pinned errors. Every decode is
    // sentinel-checked.
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, 2048 + @as(usize, sentinel.len));
    defer gpa.free(window);
    for (zlib_cases) |tc| {
        const cap = switch (tc.expect) {
            .ok => |want| want.len,
            else => window.len,
        };
        checkOneShot(window, cap, tc.source, tc.dict, tc.expect) catch |err| {
            print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
            return err;
        };
    }
}

test "golden decode: the std in-tree streams" {
    // Zig 0.16 std's zlib tests (MIT, in-tree): stored, fixed, dynamic, the
    // exact-consumption vector, and the header failures.
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, 512 + @as(usize, sentinel.len));
    defer gpa.free(window);
    for (std_cases) |tc| {
        const cap = switch (tc.expect) {
            .ok => |want| want.len,
            else => window.len,
        };
        checkOneShot(window, cap, tc.source, tc.dict, tc.expect) catch |err| {
            print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
            return err;
        };
    }
}

test "golden decode: the FCHECK = 31 corner passes the check and lands on the dictionary" {
    // RFC 1950 §2.2 requires only that (CMF*256 + FLG) be a multiple of 31;
    // the C reference's naive emission writes FCHECK = 31 in the FDICT +
    // FLEVEL-0 corner (`78 3f`), which a validator that recomputes FCHECK
    // rejects. The header check must accept it, and the FDICT flag must send
    // the decode to the dictionary check: without one it is
    // `DictionaryRequired`, and with the C reference's own dictionary the
    // stream decodes.
    try testing.expectEqual(@as(u16, 0), 0x783f % 31);
    try decode.checkHeader(fcheck31_dict_stream[0], fcheck31_dict_stream[1]);
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, 256 + @as(usize, sentinel.len));
    defer gpa.free(window);
    try checkOneShot(window, window.len, &fcheck31_dict_stream, null, .{
        .fail_with = error.DictionaryRequired,
    });
    try checkOneShot(window, fcheck31_plain.len, &fcheck31_dict_stream, fcheck31_dict, .{
        .ok = fcheck31_plain,
    });
}

test "golden decode: the oracle-verified emissions" {
    // The C-reference emissions, checked through python3's zlib: the level
    // bands' FLEVEL values, the dict + FLEVEL-0 corner's `78 3f`, and the
    // DICTID and trailer byte order (both big-endian, §2.1).
    const data = "The quick brown fox jumps over the lazy dog. " ** 5;
    // Level bands: {0,1} -> FLEVEL 0 (`78 01`), {2-5} -> 1 (`78 5e`),
    // {6,-1} -> 2 (`78 9c`), {7-9} -> 3 (`78 da`).
    try testing.expectEqual(@as(u8, 0x01), encode.flgFor(.@"0", false));
    try testing.expectEqual(@as(u8, 0x01), encode.flgFor(.@"1", false));
    try testing.expectEqual(@as(u8, 0x5e), encode.flgFor(.@"3", false));
    try testing.expectEqual(@as(u8, 0x9c), encode.flgFor(.fast, false));
    try testing.expectEqual(@as(u8, 0x9c), encode.flgFor(.@"6", false));
    try testing.expectEqual(@as(u8, 0xda), encode.flgFor(.@"9", false));

    // The dictionary stream: DICTID is the dictionary's Adler-32, and the
    // trailer is the payload's — both stored most-significant-byte first.
    try testing.expectEqual(
        @as(u32, 0xFA2C0D48),
        readInt(u32, fcheck31_dict_stream[2..6]),
    );
    try testing.expectEqual(@as(u32, 0xFA2C0D48), adler32.adler32(1, fcheck31_dict));
    try testing.expectEqual(
        std.hash.Adler32.hash(data),
        readInt(u32, fcheck31_dict_stream[fcheck31_dict_stream.len - 4 ..]),
    );
    // The payload's Adler-32 is the value C zlib writes: 0xd28c50c4.
    try testing.expectEqual(@as(u32, 0xD28C50C4), std.hash.Adler32.hash(data));
}

test "golden decode: the std divergence pins" {
    // Zig 0.16 std's zlib parse checks CM and CINFO only
    // (`std/compress/flate/Decompress.zig:310-314`): no FCHECK validation,
    // no FDICT handling, and its footer is read into `container_metadata`
    // and never compared. Running std's own decoder here pins both
    // divergences: std accepts `78 9f`, which ours rejects `BadHeader`, and
    // it misparses an FDICT stream's DICTID as deflate data (the Go
    // dictionary vector fails `OversubscribedHuffmanTree`), where ours is
    // the specific `DictionaryRequired` before any body byte.
    var buf: [64]u8 = undefined;
    const bad_fcheck = "\x78\x9f\x03\x00\x00\x00\x00\x01";
    try testing.expectEqual(@as(usize, 0), try stdDecode(bad_fcheck, &buf));
    try testing.expectError(error.BadHeader, decode.decompress(bad_fcheck, &buf, null));

    try testing.expectError(error.ReadFailed, stdDecode(&dictionary_stream, &buf));
    try testing.expectError(
        error.DictionaryRequired,
        decode.decompress(&dictionary_stream, &buf, null),
    );
}

/// std's in-tree zlib decoder over `source` (the divergence pins run it to
/// show what std accepts). Returns the decoded length into `target`, or the
/// interface's coarse error.
fn stdDecode(source: []const u8, target: []u8) !usize {
    var input: std.Io.Reader = .fixed(source);
    var output: std.Io.Writer = .fixed(target);
    var decompress: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
    return decompress.reader.streamRemaining(&output);
}
