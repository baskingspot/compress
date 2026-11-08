//! Shims for the Zig 0.16 and 0.17 APIs. Private to the module: the barrel
//! does not export it, and the codecs reach it by relative import
//! (`@import("../compat.zig")`).

const std = @import("std");
const testing = std.testing;

/// Whether a byte array's `@bitCast` to a vector reads each lane in little
/// endian order. Zig 0.16 reads a lane in the target's order, so a big-endian
/// host gets a big-endian word; Zig 0.17 made the cast little-endian on every
/// target. Probe the behavior: the lane's value names the order.
pub const vector_bitcast_is_little_endian = blk: {
    const probe: [8]u8 = .{ 1, 0, 0, 0, 0, 0, 0, 0 };
    const lanes: @Vector(1, u64) = @bitCast(probe);
    break :blk lanes[0] == 0x0000_0000_0000_0001;
};

/// Whether a bool vector's element 0 is the integer's most significant bit
/// after `@bitCast`. Zig 0.16 on a big-endian target puts it there; Zig 0.17
/// made the cast endian-independent and puts it at the least significant bit
/// on every target. Probe the behavior, not the target: one element set, one
/// clear, and the cast says which end element 0 landed on.
pub const bool_vector_element0_is_msb = blk: {
    const probe: @Vector(2, u8) = .{ 1, 0 };
    const mask: u2 = @bitCast(probe == @as(@Vector(2, u8), @splat(1)));
    break :blk mask == 0b10;
};

/// The standard CRC-32 and CRC-32C (ISCSI). Zig 0.16 names the catalog's
/// entries after the algorithm (`Crc32`, `Crc32Iscsi`); Zig 0.17 names every
/// entry after the catalogue key (`@"CRC-32/ISO-HDLC"`, `@"CRC-32/ISCSI"`),
/// with the same parameters.
pub const Crc32 = if (@hasDecl(std.hash.crc, "Crc32"))
    std.hash.crc.Crc32
else
    std.hash.crc.@"CRC-32/ISO-HDLC";

/// The generic form, not 0.17's `@"CRC-32/ISCSI"`: that name resolves to
/// std's SSE4.2 kernel on an x86_64 target with the CRC instruction, and the
/// kernel is inline asm, which a comptime check cannot evaluate. The
/// polynomial and flags are the catalogue entry's, in the bytewise Zig
/// implementation. The tests are the only user.
pub const Crc32Iscsi = if (@hasDecl(std.hash.crc, "Crc32Iscsi"))
    std.hash.crc.Crc32Iscsi
else
    std.hash.crc.Generic(u32, .{
        .polynomial = 0x1edc6f41,
        .initial = 0xffffffff,
        .reflect_input = true,
        .reflect_output = true,
        .xor_output = 0xffffffff,
    });

/// An enum's backing integer.
///
/// Zig 0.17's `zig fmt` rewrites `@intFromEnum` to `@backingInt`, which Zig
/// 0.16 cannot parse. Every call site goes through this helper, and its body
/// stays out of the formatter's reach. It stands in for the builtin, so its
/// parameter is the builtin's: `anytype`, with the argument's own type as the
/// parameter type.
// zig fmt: off
pub fn enumToInt(e: anytype) @typeInfo(@TypeOf(e)).@"enum".tag_type {
    return @intFromEnum(e);
}

/// An enum from its backing integer, the inverse of `enumToInt`. `E` is
/// explicit because the caller's type is what the result coerces to; `raw`
/// is cast to `E`'s tag type, which is what Zig 0.17's builtin requires and
/// Zig 0.16's does not.
pub fn enumFromInt(comptime E: type, raw: anytype) E {
    return @enumFromInt(@as(@typeInfo(E).@"enum".tag_type, @intCast(raw)));
}
// zig fmt: on

/// The number of fields of an enum.
///
/// Zig 0.17 split a container's `fields` into parallel `field_names` and
/// `field_types` arrays. `T` is a type, not a `@typeInfo` result, because the
/// type-info struct moved from `std.builtin.Type` to `std.lang.Type` in the
/// same release and has no version-neutral name.
pub fn enumCount(comptime T: type) usize {
    const info = @typeInfo(T).@"enum";
    if (comptime @hasField(@TypeOf(info), "field_names")) return info.field_names.len;
    return info.fields.len;
}

pub fn structFieldCount(comptime T: type) usize {
    const info = @typeInfo(T).@"struct";
    if (comptime @hasField(@TypeOf(info), "field_names")) return info.field_names.len;
    return info.fields.len;
}

pub fn structFieldName(comptime T: type, comptime i: usize) [:0]const u8 {
    const info = @typeInfo(T).@"struct";
    if (comptime @hasField(@TypeOf(info), "field_names")) return info.field_names[i];
    return info.fields[i].name;
}

pub fn StructFieldType(comptime T: type, comptime i: usize) type {
    const info = @typeInfo(T).@"struct";
    if (comptime @hasField(@TypeOf(info), "field_names")) return info.field_types[i];
    return info.fields[i].type;
}

/// An error set's error names, in declaration order.
///
/// Zig 0.16 spells this `error_set.?` with one `Error` struct per entry;
/// Zig 0.17 moved it to `err_set.error_names`. The result is always a slice
/// of plain names, so a caller compares strings without a version branch.
pub fn errorNames(comptime E: type) []const []const u8 {
    // The whole body is comptime: the result is a slice into a comptime
    // array, which Zig materializes in static memory. Built at runtime, the
    // array would die with the frame.
    return comptime errorNamesOf(E);
}

fn errorNamesOf(comptime E: type) []const []const u8 {
    const set = @typeInfo(E).error_set;
    @setEvalBranchQuota(10_000);
    // Zig 0.16's payload is the optional name slice itself; Zig 0.17's is a
    // struct with the names one field down.
    if (comptime @typeInfo(@TypeOf(set)) == .optional) {
        const errors = set orelse return &.{};
        const plain: [errors.len][]const u8 = blk: {
            var out: [errors.len][]const u8 = undefined;
            for (errors, 0..) |entry, i| out[i] = entry.name;
            break :blk out;
        };
        return &plain;
    } else {
        const names = set.error_names orelse return &.{};
        const plain: [names.len][]const u8 = blk: {
            var out: [names.len][]const u8 = undefined;
            for (names, 0..) |name, i| out[i] = name;
            break :blk out;
        };
        return &plain;
    }
}

/// `s` repeated `n` times: the `**` operator that Zig 0.17 removed.
///
/// The result is a pointer to a comptime constant, not an array value: Zig
/// 0.17 requires the address-of operator to coerce an array value to a slice,
/// and every use here wants a slice. `comptime s` and `comptime n` make the
/// bytes a compile-time value either way.
pub fn repeatString(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    return repeatArray(u8, s, n);
}

pub fn repeatArray(comptime T: type, comptime s: []const T, comptime n: usize) *const [s.len * n]T {
    const bytes = comptime repeatValue(T, s, n);
    return &bytes;
}

/// The recursion and `++` are deliberate. Copying into a `[len * n]T` costs
/// seconds per 64 KiB at comptime, because the comptime evaluator copies the
/// whole array on each write. `++` on two arrays is a builtin the compiler
/// folds, so a 64 KiB fill and `"line\n" ** 1556` both evaluate in the time
/// an empty test takes.
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

test "enumToInt and enumFromInt round trip" {
    const Category = enum(u2) { literal, command, distance, plain = 3 };
    try testing.expectEqual(2, enumToInt(Category.distance));
    try testing.expectEqual(Category.plain, enumFromInt(Category, 3));
    try testing.expectEqual(4, enumCount(Category));
}

test "the struct field accessors agree with @field" {
    const Point = struct { x: u8, y: u16, z: bool };
    try testing.expectEqual(3, structFieldCount(Point));
    try testing.expectEqualStrings("y", structFieldName(Point, 1));
    try testing.expectEqual(u16, StructFieldType(Point, 1));
}

test "errorNames lists every error, in order" {
    const Sample = error{ Alpha, Beta, Gamma };
    const names = errorNames(Sample);
    try testing.expectEqual(3, names.len);
    try testing.expectEqualStrings("Alpha", names[0]);
    try testing.expectEqualStrings("Gamma", names[2]);
}
