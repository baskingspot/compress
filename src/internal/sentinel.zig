//! The decode-overrun sentinel. A decode test pre-fills its target with
//! `fill`, decodes, then calls `expect` to prove the bytes past the decoded
//! length are untouched.
//!
//! The pattern cycles through `[base, base + len)` with period 37. The period
//! is prime so a mis-copied byte lands at an unrelated phase; a power of two
//! could mask a copy that is off by 8 bytes. The range and period match
//! golang/snappy's `notPresentBase`/`notPresentLen`.

const std = @import("std");
const testing = std.testing;

const fastmem = @import("fastmem");

/// The first sentinel byte; the cycle is `[base, base + len)`.
pub const base: u8 = 0xa0;
/// The cycle length, in bytes.
pub const len: u8 = 37;

/// The sentinel byte at absolute index `i`.
pub fn at(i: usize) u8 {
    return base + @as(u8, @intCast(i % len));
}

/// Fills `target` with the sentinel cycle, so that `target[i] == at(i)` for
/// every `i`. A target shorter than one cycle gets the start of it. Pass
/// `expect` the same slice.
pub fn fill(target: []u8) void {
    var i: usize = 0;
    while (i + len <= target.len) : (i += len) {
        fastmem.copy(u8, target[i..][0..len], &pattern);
    }
    fastmem.copy(u8, target[i..], pattern[0 .. target.len - i]);
}

/// Test helper: checks that every byte of `target` from `decoded_len` on
/// still holds its sentinel value. A byte that does not means the decode wrote
/// past the length it was allowed; the check returns `error.TestExpectedEqual`
/// at the first such byte. `target` must have been filled with `fill`, and
/// `decoded_len` must not exceed `target.len`.
pub fn expect(target: []const u8, decoded_len: usize) !void {
    for (target[decoded_len..], decoded_len..) |byte, i| {
        try testing.expectEqual(at(i), byte);
    }
}

/// The cycle, materialized once so fills are chunked copies.
const pattern: [len]u8 = blk: {
    var bytes: [len]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = base + @as(u8, @intCast(i));
    break :blk bytes;
};
