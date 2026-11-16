//! Comptime repetition of a byte string or an array: the `**` operator that
//! Zig 0.17 removed. Private to the module: the barrel does not export it, and
//! the codecs reach it by relative import (`@import("../repeat.zig")`).

const std = @import("std");
const testing = std.testing;

/// `s` repeated `n` times.
///
/// The result is a pointer to a comptime constant, not an array value: Zig
/// 0.17 requires the address-of operator to coerce an array value to a slice,
/// and every use here wants a slice. `comptime s` and `comptime n` make the
/// bytes a compile-time value either way.
pub fn repeatString(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    return repeatArray(u8, s, n);
}

/// `s` repeated `n` times, for an element type other than `u8`.
pub fn repeatArray(comptime T: type, comptime s: []const T, comptime n: usize) *const [s.len * n]T {
    const bytes = comptime repeatValue(T, s, n);
    return &bytes;
}

/// The recursion and `++` are deliberate. Copying into a `[len * n]T` costs
/// seconds per 64 KiB at comptime, because the comptime evaluator copies the
/// whole array on each write. `++` on two arrays is a builtin the compiler
/// folds, so a 64 KiB fill and a 1556-line repeat both evaluate in the time an
/// empty test takes.
fn repeatValue(comptime T: type, comptime s: []const T, comptime n: usize) [s.len * n]T {
    // The leaves of the recursion below, plus the comparisons.
    @setEvalBranchQuota(4 * n + 100);
    if (n == 0) return .{};
    if (n == 1) return s[0..s.len].*;
    const half = n / 2;
    return repeatValue(T, s, half) ++ repeatValue(T, s, n - half);
}

test "repeatString: the empty and single repeat, and an odd count" {
    try testing.expectEqual(0, repeatString("ab", 0).len);
    try testing.expectEqualStrings("ab", repeatString("ab", 1));
    try testing.expectEqualStrings("ababab", repeatString("ab", 3));
}

test "repeatArray: a non-byte element type" {
    try testing.expectEqualSlices(u4, &.{ 1, 1, 1 }, repeatArray(u4, &.{1}, 3));
}

test "repeatString: a fill past a block, every byte in place" {
    const filled = repeatString("\x5a", 65535);
    try testing.expectEqual(65535, filled.len);
    try testing.expectEqual('Z', filled[0]);
    try testing.expectEqual('Z', filled[filled.len - 1]);
}
