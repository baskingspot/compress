//! gzip.encode: the one-shot member encoder.
//!
//! `compress` writes one complete member into a caller-provided buffer: a
//! fixed 10-byte header, flate's one-shot deflate body, and the 8-byte
//! trailer (the CRC-32 of the input and its length mod 2^32, RFC 1952
//! §2.3.1). Size the buffer with `maxCompressedLength`. The same input and
//! options always produce the same bytes, and nothing is allocated.
//!
//! `writeHeader`, `writeTrailer`, and `xflFor` are public because the streaming
//! `Writer` is built from them. The order of header, body, and trailer is the
//! shared container driver's (`src/internal/container.zig`).
//!
//! Format: docs/research/specs/rfc1952-gzip.txt

const std = @import("std");
const testing = std.testing;

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const common = @import("common.zig");
const readInt = common.readInt;
const writeInt = common.writeInt;
const crc32 = @import("crc32.zig");
const decode = @import("decode.zig");
const framing = @import("framing.zig");
/// Encoder configuration. `.{}` is the default: level 1.
pub const Options = framing.Options;
/// RFC 1952 §2.3 — the fixed header's length.
pub const header_len = framing.header_len;
/// RFC 1952 §2.3 — the trailer's length.
pub const trailer_len = framing.trailer_len;
const golden = @import("golden.zig");

/// The shared container driver over this module's framing
/// (`src/internal/container.zig`).
const Hooks = internal.container.EncodeHooks(framing);

/// The largest member `compress` can produce for `input_len` bytes: the
/// 10-byte header, flate's worst-case deflate body, and the 8-byte trailer. A
/// `target` of this size always fits the member.
pub fn maxCompressedLength(input_len: usize) usize {
    return Hooks.maxCompressedLength(input_len);
}

/// Write the 10-byte member header into `target`: ID1/ID2/CM fixed, FLG=0 (no
/// optional fields, reserved bits clear, `§2.3.1.2`), MTIME=0 ("no time stamp
/// is available", `§2.3.1`), XFL from `level` (see `xflFor`), and OS=255
/// (unknown; `§2.3.1.2` suggests "255 for OS"). For a given level the header
/// is the same every time: nothing in it depends on the clock or the
/// environment. Multi-byte fields are little-endian (`§2.1`).
pub fn writeHeader(target: *[header_len]u8, level: u8) void {
    target[0] = 0x1f; // ID1
    target[1] = 0x8b; // ID2
    target[2] = 8; // CM: deflate
    target[3] = 0; // FLG: no optional fields, reserved bits clear
    writeInt(u32, target[4..8], 0); // MTIME
    target[8] = xflFor(level); // XFL, informational (§2.3.1)
    target[9] = 255; // OS: unknown
}

/// Write the 8-byte trailer into `target`: `crc`, the CRC-32 of the
/// uncompressed data (ISO 3309), then `len`, its length mod 2^32 (ISIZE); both
/// u32 little-endian (`§2.1`, `§2.3.1`).
pub fn writeTrailer(target: *[trailer_len]u8, crc: u32, len: u32) void {
    writeInt(u32, target[0..4], crc);
    writeInt(u32, target[4..8], len);
}

/// The XFL byte for `level` (`§2.3.1`: 2 means "maximum compression", 4
/// means "fastest algorithm"): 4 for levels 0 and 1, 2 for level 9, and 0
/// for the rest. These are the bands C zlib and Go use. The field is
/// informational (`§2.3.1.2`) and reflects the requested level, not what the
/// encoder did with it.
pub fn xflFor(level: u8) u8 {
    return switch (level) {
        0, 1 => 4,
        9 => 2,
        else => 0,
    };
}

/// Compress `source` into `target` as one complete gzip member and return the
/// member's length. Returns `error.BufferTooSmall` when `target` cannot hold
/// it: size `target` with `maxCompressedLength`, though a smaller `target` can
/// still fit when the data compresses well. `target`'s contents are
/// unspecified after an error. Returns `error.Unimplemented` for a reserved
/// level (2-5 and 7-9, or anything outside 1-9).
///
/// Allocates nothing. Level 1 uses about 128 KiB of stack (flate's
/// match-finder table), level 6 about 700 KiB.
pub fn compress(
    source: []const u8,
    target: []u8,
    options: Options,
) error{ BufferTooSmall, Unimplemented }!usize {
    return Hooks.compress(source, target, options);
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc1952-gzip.txt §2.1 (byte order), §2.3
// (the member), §2.3.1 (the fixed header, XFL, OS, the trailer).
// ---------------------------------------------------------------------------

test "encode: the emitted member is the deterministic one" {
    // RFC 1952 §2.3.1 — ID1/ID2/CM fixed, FLG=0 (no optional fields,
    // reserved bits clear), MTIME=0, OS=255; XFL is informational.
    var target: [256]u8 = undefined;
    const source = "the quick brown fox jumps over the lazy dog. " ** 4;
    const len = try compress(source, &target, .{});
    const member = target[0..len];

    try testing.expectEqual(@as(u8, 0x1f), member[0]);
    try testing.expectEqual(@as(u8, 0x8b), member[1]);
    try testing.expectEqual(@as(u8, 8), member[2]);
    try testing.expectEqual(@as(u8, 0), member[3]);
    try testing.expectEqual(@as(u32, 0), readInt(u32, member[4..8]));
    try testing.expectEqual(@as(u8, 4), member[8]);
    try testing.expectEqual(@as(u8, 255), member[9]);

    // §2.3.1 — the trailer is the CRC-32 of the uncompressed data (ISO 3309)
    // and ISIZE, the input size mod 2^32, both little-endian (§2.1).
    try testing.expectEqual(
        crc32.crc32(0, source),
        readInt(u32, member[len - 8 ..][0..4]),
    );
    try testing.expectEqual(
        @as(u32, @truncate(source.len)),
        readInt(u32, member[len - 4 ..][0..4]),
    );
    // The reference kernel agrees (std.hash.crc.Crc32 is the same algorithm).
    try testing.expectEqual(std.hash.crc.Crc32.hash(source), crc32.crc32(0, source));
}

test "encode: the empty member is the golden bytes" {
    // RFC 1952 §2.3.1 — an empty payload is a valid member: the fixed header,
    // the final empty fixed block (`03 00`, how flate ends every stream), and
    // the zero CRC-32 and ISIZE. The hostile-header pins in fuzz.zig use the
    // same bytes.
    var target: [maxCompressedLength(0)]u8 = undefined;
    const len = try compress("", &target, .{});
    try testing.expectEqualSlices(u8, &[_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0xff, // header
        0x03, 0x00, // final empty fixed block
        0x00, 0x00, 0x00, 0x00, // CRC-32 of nothing
        0x00, 0x00, 0x00, 0x00, // ISIZE 0
    }, target[0..len]);
}

test "encode: XFL follows the level bands" {
    // RFC 1952 §2.3.1 — XFL 4 is "compressor used fastest algorithm", 2
    // "maximum compression"; the bands are C zlib's and Go's.
    const cases = [_]struct { level: u8, xfl: u8 }{
        .{ .level = 0, .xfl = 4 },
        .{ .level = 1, .xfl = 4 },
        .{ .level = 2, .xfl = 0 },
        .{ .level = 8, .xfl = 0 },
        .{ .level = 9, .xfl = 2 },
    };
    for (cases) |case| try testing.expectEqual(case.xfl, xflFor(case.level));

    // The implemented levels emit a member carrying the matching byte.
    var target: [64]u8 = undefined;
    for ([_]u8{ 1, 6 }) |level| {
        const len = try compress("x", &target, .{ .level = level });
        try testing.expectEqual(xflFor(level), target[8]);
        try testing.expect(len > 0);
    }
}

test "encode: a reserved level is unimplemented, never aliased" {
    // Levels 2-5 and 7-9 (and anything outside 1-9) are reserved:
    // `error.Unimplemented`, and nothing is written to `target`.
    var target: [64]u8 = undefined;
    for ([_]u8{ 0, 2, 5, 7, 9, 10 }) |level| {
        sentinel.fill(&target);
        try testing.expectError(error.Unimplemented, compress("x", &target, .{ .level = level }));
        try sentinel.expect(&target, 0);
    }
}

test "encode: a small target fails, an exact one fits" {
    // A target smaller than `maxCompressedLength` may still fit; when it does
    // not, the result is `error.BufferTooSmall` and `target`'s contents are
    // unspecified. Nothing is ever written past the target.
    const source = "hello world\n";
    var member: [maxCompressedLength(source.len)]u8 = undefined;
    const len = try compress(source, &member, .{});

    // The exact member length fits (the body compressed under the bound).
    var exact: [maxCompressedLength(source.len) + 8]u8 = undefined;
    sentinel.fill(&exact);
    const exact_len = try compress(source, exact[0..len], .{});
    try testing.expectEqual(len, exact_len);
    try testing.expectEqualSlices(u8, member[0..len], exact[0..len]);
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
    // `compress` never produces more than `maxCompressedLength` bytes.
    // Random bytes take the stored fallback, runs the match finder.
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
    // Incompressible bytes across four block splits: the bound is tight at
    // the stored fallback's worst case, at both implemented levels.
    const noise = try testing.allocator.alloc(u8, 3 * 65535);
    defer testing.allocator.free(noise);
    var prng: std.Random.DefaultPrng = .init(0x5EED);
    prng.random().bytes(noise);
    const target = try testing.allocator.alloc(u8, maxCompressedLength(noise.len));
    defer testing.allocator.free(target);
    for ([_]u8{ 1, 6 }) |level| {
        const len = try compress(noise, target, .{ .level = level });
        try testing.expectEqual(maxCompressedLength(noise.len), len);
    }
}

test "encode: the golden outputs re-encode to decodable members" {
    // The ported golang/go `gunzipTests` payloads must round-trip through
    // this module's own encoder and decoder.
    var member: [512]u8 = undefined;
    var plain: [512]u8 = undefined;
    for (golden.gunzip_cases) |tc| {
        const source = switch (tc.expect) {
            .ok => |bytes| bytes,
            else => continue, // Reject cases have no payload to re-encode.
        };
        if (maxCompressedLength(source.len) > member.len) continue;
        const len = try compress(source, &member, .{});
        sentinel.fill(&plain);
        const decoded = try decode.decompress(member[0..len], plain[0..source.len]);
        try testing.expectEqual(source.len, decoded);
        try testing.expectEqualSlices(u8, source, plain[0..decoded]);
        try sentinel.expect(&plain, decoded);
    }
}
