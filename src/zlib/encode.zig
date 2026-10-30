//! zlib.encode: one-shot zlib compression.
//!
//! `compress` writes one complete stream into a caller-provided target: the
//! 2-byte header (CM=8, CINFO=7, FLEVEL for the level, the minimal FCHECK,
//! FDICT set exactly when a preset dictionary is supplied) with the 4-byte
//! DICTID behind it when it is, flate's deflate body, and the 4-byte trailer,
//! which is the Adler-32 of `source` in big-endian order (`rfc1950-zlib.txt
//! §2.1`, `§2.2`). The Adler-32 is computed directly over `source` in one
//! pass, with no flate involvement. The same input and options always produce
//! the same bytes, and nothing is allocated. `maxCompressedLength` sizes the
//! target. The header and trailer helpers (`cmf`, `flgFor`, `writeHeader`,
//! `writeDictId`, `writeTrailer`) are public because the streaming `Writer`
//! is built from them too.
//!
//! The ordering and the size bound come from the shared container driver
//! (`src/internal/container.zig`, `EncodeHooks`), instantiated over
//! `framing.zig`.
//!
//! Format: docs/specs/rfc1950-zlib.txt

const std = @import("std");
const testing = std.testing;

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const adler32 = @import("adler32.zig");
const common = @import("common.zig");
const readInt = common.readInt;
const writeInt = common.writeInt;
const decode = @import("decode.zig");
const framing = @import("framing.zig");
/// Encoder configuration. `.{}` is the default: level 1. The level also
/// selects the header's FLEVEL bits (`flgFor`).
pub const Options = framing.Options;
/// The compression levels this encoder takes (flate's, re-exported).
pub const Level = framing.Level;
/// RFC 1950 §2.2 — the header's length: CMF and FLG.
pub const header_len = framing.header_len;
/// RFC 1950 §2.2 — the DICTID's length, behind a set FDICT flag: the
/// dictionary's Adler-32, most-significant byte first.
pub const dict_id_len = framing.dict_id_len;
/// RFC 1950 §2.2 — the trailer's length: ADLER32.
pub const trailer_len = framing.trailer_len;
const golden = @import("golden.zig");

/// The emitted CMF: CM = 8 ("deflate", `§2.2`) in the low four bits, CINFO = 7
/// (a 32-KiB window: CINFO is "the base-2 logarithm of the LZ77 window size,
/// minus eight", `§2.2`) in the high four. Fixed: the encoder exposes no
/// header knobs.
pub const cmf: u8 = 0x78;

/// The shared container driver over this module's framing
/// (`src/internal/container.zig`).
const Hooks = internal.container.EncodeHooks(framing);

/// The most bytes `compress` can write for `input_len` input bytes: the
/// 2-byte header, flate's worst-case deflate body, and the 4-byte trailer.
/// Size `compress`'s `target` to this to rule out `error.BufferTooSmall`.
pub fn maxCompressedLength(input_len: usize) usize {
    return Hooks.maxCompressedLength(input_len);
}

/// Write the 2-byte header into `target`: CMF is `cmf` and FLG is
/// `flgFor(level, fdict)`. `fdict` sets FDICT (bit 5) — the encoder sets it
/// exactly when a DICTID follows the header. Nothing else depends on the
/// clock or the environment, so the output is reproducible (`§2.2`).
pub fn writeHeader(target: *[header_len]u8, level: Level, fdict: bool) void {
    target[0] = cmf;
    target[1] = flgFor(level, fdict);
}

/// Write the 4-byte DICTID into `target`: the Adler-32 of the *whole*
/// dictionary, most-significant byte first (`§2.1`, `§2.2`). It names the
/// whole even when the dictionary is longer than the 32-KiB window, so a
/// decoder must be given every byte (only the tail is matchable).
pub fn writeDictId(target: *[dict_id_len]u8, dict: []const u8) void {
    writeInt(u32, target, adler32.adler32(1, dict));
}

/// The FLG byte `compress` writes for `level` (`§2.2`): FLEVEL in bits 6-7,
/// FDICT (bit 5) set exactly when `fdict` is, FCHECK in bits 0-4. FLEVEL
/// follows the bands C zlib and Go use: level 1 gives 0 and level 6 gives 2.
/// It is only a hint ("not needed for decompression"). FCHECK is the smallest
/// value that makes `CMF*256 + FLG` a multiple of 31, as the RFC requires
/// ("CMF and FLG, when viewed as a 16-bit unsigned integer stored in MSB order
/// (CMF*256 + FLG), is a multiple of 31"), so the pair always passes
/// `decode.checkHeader`. C zlib's naive emission with FDICT and FLEVEL 0 gives
/// FCHECK = 31 (`78 3f`), which is 0 mod 31 and fits the field; this encoder's
/// is minimal, so the corner only arises when decoding.
pub fn flgFor(level: Level, fdict: bool) u8 {
    const flevel: u8 = switch (level) {
        .@"1" => 0,
        .@"6" => 2,
    };
    const fdict_bit: u8 = if (fdict) decode.flg_fdict else 0;
    return flevel << 6 | fdict_bit | fcheck(flevel, fdict);
}

/// The minimal FCHECK for `flevel` and `fdict`: `(31 - r) % 31` with `r` the
/// remainder of the header's partial value (FCHECK's five bits zero) modulo 31
/// (`§2.2`).
fn fcheck(flevel: u8, fdict: bool) u8 {
    const fdict_bit: u16 = if (fdict) decode.flg_fdict else 0;
    const partial = @as(u16, cmf) * 256 + @as(u16, flevel) * 64 + fdict_bit;
    const remainder = partial % 31;
    return @intCast((31 - remainder) % 31);
}

/// Emit the 4-byte trailer: the Adler-32 of the uncompressed data (excluding
/// any dictionary data), u32 most-significant-byte first (`§2.1`, `§2.2`).
pub fn writeTrailer(target: *[trailer_len]u8, adler: u32) void {
    writeInt(u32, target[0..4], adler);
}

/// Compress `source` as one complete zlib stream into `target` and return the
/// stream's length. Returns `error.BufferTooSmall` when `target` cannot hold
/// the stream: size it with `maxCompressedLength`, although a smaller target
/// can still fit when the data compresses under the bound. After an error,
/// `target`'s contents are unspecified; nothing is written past its end.
///
/// `options.dict` is the stream's preset dictionary or `null` (`§2.2`): FDICT
/// is set and the dictionary's Adler-32 written as DICTID, and the compressor
/// matches into the dictionary's last 32 KiB. A dictionary longer than 32 KiB
/// contributes only its tail to the window while DICTID names the whole.
///
/// Uses about 128 KiB of stack (flate's match-finder table). Allocates
/// nothing.
pub fn compress(
    source: []const u8,
    target: []u8,
    options: Options,
) error{BufferTooSmall}!usize {
    return Hooks.compress(source, target, options);
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/specs/rfc1950-zlib.txt §2.1 (byte order), §2.2
// (the header, the trailer, FCHECK, FLEVEL), §2.3 (decoder obligations).
// ---------------------------------------------------------------------------

test "encode: the emitted stream is the deterministic one" {
    // RFC 1950 §2.2 — CMF: CM=8 ("deflate"), CINFO=7 (a 32-KiB window);
    // FLG: FLEVEL by band, the minimal FCHECK, FDICT clear. The pair is a
    // multiple of 31 as one MSB-order u16 (§2.2).
    var target: [256]u8 = undefined;
    const source = "the quick brown fox jumps over the lazy dog. " ** 4;
    const len = try compress(source, &target, .{});
    const stream = target[0..len];

    try testing.expectEqual(@as(u8, 0x78), stream[0]);
    try testing.expectEqual(@as(u8, 0x01), stream[1]); // FLEVEL 0, FCHECK 1
    const header = @as(u16, stream[0]) * 256 + @as(u16, stream[1]);
    try testing.expectEqual(@as(u16, 0), header % 31);
    try testing.expectEqual(@as(u8, 0), stream[1] & 0x20); // FDICT clear

    // §2.2 — the trailer is the Adler-32 of the uncompressed data, stored
    // most-significant-byte first (§2.1). The reference kernel agrees.
    try testing.expectEqual(
        std.hash.Adler32.hash(source),
        readInt(u32, stream[len - trailer_len ..][0..4]),
    );
    try testing.expectEqual(
        adler32.adler32(1, source),
        readInt(u32, stream[len - trailer_len ..][0..4]),
    );
}

test "encode: the empty stream is the golden bytes" {
    // RFC 1950 §2.2 — an empty payload is a valid stream: the header (the
    // default level 1's FLEVEL 0 band), the final empty fixed block
    // (`03 00`, flate's uniform ending), and the Adler-32 of nothing, 1. The
    // hostile-header pins in `fuzz.zig` carry the same bytes.
    var target: [maxCompressedLength(0)]u8 = undefined;
    const len = try compress("", &target, .{});
    try testing.expectEqualSlices(u8, &[_]u8{
        0x78, 0x01, // header: CM=8, CINFO=7, FLEVEL 0, FCHECK 1
        0x03, 0x00, // final empty fixed block
        0x00, 0x00, 0x00, 0x01, // Adler-32 of nothing
    }, target[0..len]);
}

test "encode: FLEVEL follows the level bands" {
    // RFC 1950 §2.2 — FLEVEL is informational ("not needed for
    // decompression"); the bands are C zlib's and Go's: level 1 -> 0, level
    // 6 -> 2. python3's zlib (the C reference) writes 78 01 at level 1 and
    // 78 9c at level 6.
    const cases = [_]struct { level: Level, flg: u8 }{
        .{ .level = .@"1", .flg = 0x01 },
        .{ .level = .@"6", .flg = 0x9c },
    };
    for (cases) |case| try testing.expectEqual(case.flg, flgFor(case.level, false));

    // Each level emits a stream carrying the matching byte.
    var target: [64]u8 = undefined;
    for (std.enums.values(Level)) |level| {
        const len = try compress("x", &target, .{ .level = level });
        try testing.expectEqual(flgFor(level, false), target[1]);
        const header = @as(u16, target[0]) * 256 + @as(u16, target[1]);
        try testing.expectEqual(@as(u16, 0), header % 31);
        try testing.expectEqual(@as(u8, 0), target[1] & 0x20);
        try testing.expect(len > 0);
    }
}

test "encode: a small target fails, an exact one fits" {
    // A target smaller than `maxCompressedLength` may still fit; when it does
    // not, the result is `error.BufferTooSmall` and `target`'s contents are
    // unspecified. Nothing is ever written past the target.
    const source = "hello world\n";
    var stream: [maxCompressedLength(source.len)]u8 = undefined;
    const len = try compress(source, &stream, .{});

    // The exact stream length fits (the body compressed under the bound).
    var exact: [maxCompressedLength(source.len) + 8]u8 = undefined;
    sentinel.fill(&exact);
    const exact_len = try compress(source, exact[0..len], .{});
    try testing.expectEqual(len, exact_len);
    try testing.expectEqualSlices(u8, stream[0..len], exact[0..len]);
    // The trailing sentinels are untouched: no write past the target.
    try sentinel.expect(&exact, len);

    // One byte short: BufferTooSmall, and the sentinel past the target holds.
    var short: [maxCompressedLength(source.len) + 8]u8 = undefined;
    sentinel.fill(&short);
    try testing.expectError(error.BufferTooSmall, compress(source, short[0 .. len - 1], .{}));
    try sentinel.expect(&short, len - 1);

    // Too small for even the framing.
    var tiny: [header_len + trailer_len - 1]u8 = undefined;
    sentinel.fill(&tiny);
    try testing.expectError(error.BufferTooSmall, compress(source, &tiny, .{}));
    try sentinel.expect(&tiny, 0);
}

test "encode: the bound holds for every shape" {
    // `compress` never writes more than `maxCompressedLength`. Random bytes
    // take the stored fallback, runs the match finder.
    const cases = [_][]const u8{
        "",
        "a",
        "hello world\n",
        "the quick brown fox jumps over the lazy dog. " ** 100,
        "\x00\x01\x02\x03\x04\x05\x06\x07" ** 64,
    };
    for (cases) |source| {
        const target = try testing.allocator.alloc(u8, maxCompressedLength(source.len));
        defer testing.allocator.free(target);
        var rng: std.Random.DefaultPrng = .init(0xC0FFEE);
        for (target) |*byte| byte.* = rng.random().int(u8);
        const len = try compress(source, target, .{});
        try testing.expect(len <= maxCompressedLength(source.len));
    }
    // Incompressible bytes across four block splits: the stored fallback hits
    // flate's body bound exactly, at both implemented levels. The container's
    // bound reserves the DICTID's 4 bytes on top of it, used or not.
    const noise = try testing.allocator.alloc(u8, 3 * 65535);
    defer testing.allocator.free(noise);
    var prng: std.Random.DefaultPrng = .init(0x5EED);
    prng.random().bytes(noise);
    const target = try testing.allocator.alloc(u8, maxCompressedLength(noise.len));
    defer testing.allocator.free(target);
    for (std.enums.values(Level)) |level| {
        const len = try compress(noise, target, .{ .level = level });
        try testing.expectEqual(
            header_len + framing.bodyMaxCompressedLength(noise.len) + trailer_len,
            len,
        );
        try testing.expectEqual(maxCompressedLength(noise.len) - dict_id_len, len);
    }
}

test "encode: the golden payloads re-encode to decodable streams" {
    // The ported golang/go and std payloads: each must round-trip through
    // this module's own two halves — the container's framing must not
    // disturb the body flate's fixtures pin.
    var stream: [512]u8 = undefined;
    var plain: [512]u8 = undefined;
    for (golden.zlib_cases) |tc| {
        const source = switch (tc.expect) {
            .ok => |bytes| bytes,
            else => continue, // Reject cases have no payload to re-encode.
        };
        if (maxCompressedLength(source.len) > stream.len) continue;
        const len = try compress(source, &stream, .{});
        sentinel.fill(&plain);
        const decoded = try decode.decompress(stream[0..len], plain[0..source.len], null);
        try testing.expectEqual(source.len, decoded);
        try testing.expectEqualSlices(u8, source, plain[0..decoded]);
        try sentinel.expect(&plain, decoded);
    }
}

test "encode: the dictionary header is FDICT plus the whole dictionary's Adler-32" {
    // RFC 1950 §2.2 — FDICT is bit 5 of FLG and the 4-byte DICTID that
    // follows is "the Adler-32 checksum of this sequence of bytes",
    // most-significant byte first (§2.1). The trailer still covers the
    // payload only: the dictionary's bytes are never part of ADLER32.
    var stream: [256]u8 = undefined;
    const source = "she sells seashells";
    const dict = "she sells seashells by the seashore\n";
    const len = try compress(source, &stream, .{ .dict = dict });

    try testing.expectEqual(@as(u8, 0x78), stream[0]);
    try testing.expectEqual(flgFor(.@"1", true), stream[1]);
    try testing.expectEqual(@as(u16, 0), (@as(u16, stream[0]) * 256 + stream[1]) % 31);
    try testing.expectEqual(adler32.adler32(1, dict), readInt(u32, stream[2..6]));
    try testing.expectEqual(
        adler32.adler32(1, source),
        readInt(u32, stream[len - 4 ..][0..4]),
    );

    // The FLEVEL bands hold with FDICT set, and FCHECK stays the minimal one:
    // with FLEVEL 0 and FDICT the partial value is already 0 mod 31, so the
    // header is `78 20` — the C reference's naive arithmetic writes `78 3f`
    // there, and both are conformant (§2.2).
    try testing.expectEqual(@as(u8, 0x20), flgFor(.@"1", true));
    try testing.expectEqual(@as(u8, 0x01), flgFor(.@"1", false));
    try testing.expectEqual(@as(u16, 0), (@as(u16, 0x78) * 256 + flgFor(.@"1", true)) % 31);
    for (std.enums.values(Level)) |level| {
        const flg = flgFor(level, true);
        try testing.expect(flg & decode.flg_fdict != 0);
        try testing.expectEqual(@as(u16, 0), (@as(u16, 0x78) * 256 + flg) % 31);
        const n = try compress("x", &stream, .{ .level = level, .dict = dict });
        try testing.expectEqual(flg, stream[1]);
        try testing.expect(n > 6);
    }
}

test "encode: a dictionary round-trips and carries the stream" {
    // §2.2 — the dictionary is fed to the compressor before any output, so a
    // source repeating it compresses against it. The emitted distances reach
    // into the dictionary's bytes: the same stream without them is a raw
    // flate `InvalidMatch`, and the DICTID check catches a different
    // dictionary before any body byte.
    const source = "she sells seashells by the seashore\n" ** 8;
    const dict = "she sells seashells by the seashore\n";
    var stream: [maxCompressedLength(source.len)]u8 = undefined;
    var plain: [source.len + @as(usize, sentinel.len)]u8 = undefined;

    const len = try compress(source, &stream, .{ .dict = dict });
    sentinel.fill(&plain);
    const n = try decode.decompress(stream[0..len], plain[0..source.len], dict);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, plain[0..n]);
    try sentinel.expect(&plain, n);

    // The dictionary carried it: without one the same source costs matches
    // within its own repetitions (and the no-dictionary decode above fails
    // with flate's `InvalidMatch`, the proof that the stream references the
    // preset history).
    var plain_stream: [maxCompressedLength(source.len)]u8 = undefined;
    const plain_len = try compress(source, &plain_stream, .{});
    try testing.expect(len * 2 < plain_len);

    // No dictionary: `DictionaryRequired`, before any body byte.
    try testing.expectError(
        error.DictionaryRequired,
        decode.decompress(stream[0..len], &plain, null),
    );
    // A different dictionary: the DICTID compare, `DictionaryMismatch`.
    try testing.expectError(
        error.DictionaryMismatch,
        decode.decompress(stream[0..len], &plain, "a different dictionary"),
    );
    // FDICT clear, dictionary supplied: the stream names none, so the
    // parameter is unused and the stream decodes.
    sentinel.fill(&plain);
    const m = try decode.decompress(plain_stream[0..plain_len], plain[0..source.len], dict);
    try testing.expectEqual(source.len, m);
    try testing.expectEqualSlices(u8, source, plain[0..m]);
    try sentinel.expect(&plain, m);
}

test "encode: an empty dictionary is no dictionary" {
    // The C reference sets PRESET_DICT only when bytes were inserted
    // (`deflate.c`), so `\"\"` and `null` encode alike — the documented
    // spelling is `null`.
    var with_empty: [128]u8 = undefined;
    var with_null: [128]u8 = undefined;
    const source = "the quick brown fox jumps over the lazy dog. " ** 2;
    const a = try compress(source, &with_empty, .{ .dict = "" });
    const b = try compress(source, &with_null, .{});
    try testing.expectEqual(b, a);
    try testing.expectEqualSlices(u8, with_null[0..b], with_empty[0..a]);
    try testing.expectEqual(@as(u8, 0), with_empty[1] & decode.flg_fdict);
}

test "encode: the DICTID names the whole dictionary, the window its tail" {
    // §2.2 with a dictionary longer than the 32-KiB window: only the last
    // 32 KiB is matchable (`deflateSetDictionary`'s tail cut) while DICTID is
    // the Adler-32 of the whole, so a decoder must be given every byte.
    var dict: [32768 + 64]u8 = undefined;
    var rng: std.Random.DefaultPrng = .init(0xC0FFEE);
    for (&dict) |*b| b.* = rng.random().int(u8);
    const source = dict[dict.len - 64 ..]; // the dictionary's tail: matchable

    var stream: [maxCompressedLength(source.len)]u8 = undefined;
    const len = try compress(source, &stream, .{ .dict = &dict });
    try testing.expectEqual(adler32.adler32(1, &dict), readInt(u32, stream[2..6]));
    try testing.expect(len < 32); // one match, not 64 literals

    var plain: [64 + @as(usize, sentinel.len)]u8 = undefined;
    sentinel.fill(&plain);
    const n = try decode.decompress(stream[0..len], plain[0..source.len], &dict);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, plain[0..n]);
    try sentinel.expect(&plain, n);

    // The tail alone (the bytes the window used) and the front alone both
    // fail the DICTID compare: the identifier is the whole's.
    try testing.expectError(
        error.DictionaryMismatch,
        decode.decompress(stream[0..len], &plain, dict[64..]),
    );
    try testing.expectError(
        error.DictionaryMismatch,
        decode.decompress(stream[0..len], &plain, dict[0..32768]),
    );
}
