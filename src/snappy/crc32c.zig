//! The framed stream's checksum: CRC-32C (Castagnoli), slice-by-16.
//!
//! The snappy framing format stores a masked CRC-32C of the uncompressed
//! bytes of every data chunk (`framing_format.txt` §3). The polynomial is
//! Castagnoli's, reflected, 0x82F63B78; the conditioning is the standard
//! CRC-32 one (init 0xFFFFFFFF, final complement), so `crc32c(0, b)` equals
//! `std.hash.crc.Crc32Iscsi.hash(b)`. `mask` is the format's stored value.
//!
//! std's bytewise `Crc32Iscsi` stays in the tests as the reference.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const assert = std.debug.assert;
const Crc32Iscsi = std.hash.crc.Crc32Iscsi;

const common = @import("common.zig");

/// The reflected Castagnoli polynomial (RFC 3720 §12.1's CRC-32C).
const poly: u32 = 0x82F6_3B78;

/// The slice width: sixteen bytes per step, sixteen tables (16 KiB).
const slice_count = 16;

/// The slice-by-16 tables, built by the same recurrence as the ISO CRC-32
/// kernel (`src/gzip/crc32.zig`): `tables[0]` is the CRC of a single byte,
/// and `tables[k][x]` is the CRC of `x` followed by `k` zero bytes.
const tables: [slice_count][256]u32 = blk: {
    @setEvalBranchQuota(200_000);
    var t: [slice_count][256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| {
            c = if (c & 1 != 0) (c >> 1) ^ poly else c >> 1;
        }
        t[0][i] = c;
    }
    for (1..slice_count) |k| {
        for (0..256) |i| {
            t[k][i] = (t[k - 1][i] >> 8) ^ t[0][t[k - 1][i] & 0xff];
        }
    }
    break :blk t;
};

comptime {
    // The standard check value (RFC 3720 §B.4).
    assert(crc32c(0, "123456789") == 0xE306_9283);
    // A 17-byte pin crosses one full slice plus a one-byte tail.
    assert(crc32c(0, "123456789ABCDEFGH") == Crc32Iscsi.hash("123456789ABCDEFGH"));
}

/// The raw running state's step: no conditioning, the kernel's inner form.
fn foldRaw(raw: u32, bytes: []const u8) u32 {
    var crc = raw;
    var rest = bytes;
    while (rest.len >= slice_count) {
        const w0 = common.readInt(u32, rest[0..4]);
        const w1 = common.readInt(u32, rest[4..8]);
        const w2 = common.readInt(u32, rest[8..12]);
        const w3 = common.readInt(u32, rest[12..16]);
        crc ^= w0;
        crc = tables[15][crc & 0xff] ^ tables[14][(crc >> 8) & 0xff] ^
            tables[13][(crc >> 16) & 0xff] ^ tables[12][crc >> 24] ^
            tables[11][w1 & 0xff] ^ tables[10][(w1 >> 8) & 0xff] ^
            tables[9][(w1 >> 16) & 0xff] ^ tables[8][w1 >> 24] ^
            tables[7][w2 & 0xff] ^ tables[6][(w2 >> 8) & 0xff] ^
            tables[5][(w2 >> 16) & 0xff] ^ tables[4][w2 >> 24] ^
            tables[3][w3 & 0xff] ^ tables[2][(w3 >> 8) & 0xff] ^
            tables[1][(w3 >> 16) & 0xff] ^ tables[0][w3 >> 24];
        rest = rest[slice_count..];
    }
    for (rest) |byte| {
        crc = tables[0][(crc ^ byte) & 0xff] ^ (crc >> 8);
    }
    return crc;
}

/// The CRC-32C of `bytes`, continuing from `crc` (0 starts). This is the
/// finalized digest, so `crc32c(crc, "")` is `crc`.
pub fn crc32c(crc: u32, bytes: []const u8) u32 {
    return foldRaw(crc ^ 0xffff_ffff, bytes) ^ 0xffff_ffff;
}

/// The format's stored form of a CRC-32C: rotate right by 15, then add
/// 0xa282ead8 with wrapping (`framing_format.txt` §3).
pub fn mask(checksum: u32) u32 {
    const rotated = (checksum >> 15) | (checksum << 17);
    return rotated +% 0xa282_ead8;
}

test "crc32c: the standard check value and the mask" {
    const checksum = crc32c(0, "123456789");
    try testing.expectEqual(@as(u32, 0xE306_9283), checksum);
    // Python's crc32c/crcmod and the Go reference agree on the masked value.
    try testing.expectEqual(@as(u32, 0xC78A_B0E5), mask(checksum));
}

test "crc32c: a length sweep agrees with std's bytewise kernel" {
    var bytes: [1024]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0xC2C);
    prng.random().bytes(&bytes);
    for (0..bytes.len + 1) |len| {
        try testing.expectEqual(Crc32Iscsi.hash(bytes[0..len]), crc32c(0, bytes[0..len]));
    }
}

test "crc32c: a continuation equals one pass" {
    var bytes: [257]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0x32C);
    prng.random().bytes(&bytes);
    const split = 100;
    const first = crc32c(0, bytes[0..split]);
    try testing.expectEqual(crc32c(0, &bytes), crc32c(first, bytes[split..]));
}
