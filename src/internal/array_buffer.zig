//! Fixed-capacity buffer backed by an array.
//!
//! Useful for building messages or accumulating bytes without heap allocation.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Alignment = std.mem.Alignment;

const fastmem = @import("fastmem");

pub fn ArrayBuffer(comptime T: type, comptime buffer_capacity: comptime_int) type {
    return ArrayBufferAligned(T, .of(T), buffer_capacity);
}

pub fn ArrayBufferAligned(
    comptime T: type,
    comptime alignment: Alignment,
    comptime buffer_capacity: comptime_int,
) type {
    return struct {
        const Self = @This();

        fn Buf(comptime is_const: bool) type {
            const a = alignment.toByteUnits();
            return if (is_const) []align(a) const T else []align(a) T;
        }

        pub const Index = std.math.IntFittingRange(0, buffer_capacity);
        pub const capacity: Index = @intCast(buffer_capacity);

        buffer: [capacity]T align(alignment.toByteUnits()),
        len: Index,

        pub const empty: Self = .{ .buffer = undefined, .len = 0 };

        pub fn constSlice(self: *const Self) []align(alignment.toByteUnits()) const T {
            return self.buffer[0..self.len];
        }

        pub fn slice(self: *Self) switch (@TypeOf(&self.buffer)) {
            *align(alignment.toByteUnits()) [capacity]T => Buf(false),
            *align(alignment.toByteUnits()) const [capacity]T => Buf(true),
            else => unreachable,
        } {
            return self.buffer[0..self.len];
        }

        pub fn unusedCapacitySlice(self: *Self) []align(alignment.toByteUnits()) T {
            return self.buffer[self.len..];
        }

        pub fn remainingCapacity(self: *const Self) Index {
            return capacity - self.len;
        }

        pub fn append(self: *Self, item: T) error{NoSpaceLeft}!void {
            if (self.remainingCapacity() == 0) return error.NoSpaceLeft;
            self.appendAssumeCapacity(item);
        }

        /// Append, assuming the caller has verified capacity.
        /// Callers with input-derived lengths must use `append` instead.
        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            assert(self.len < capacity);
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn appendSlice(self: *Self, items: []const T) error{NoSpaceLeft}!void {
            if (items.len > self.remainingCapacity()) return error.NoSpaceLeft;
            self.appendSliceAssumeCapacity(items);
        }

        /// Callers with input-derived lengths must use `appendSlice` instead.
        pub fn appendSliceAssumeCapacity(self: *Self, items: []const T) void {
            assert(items.len <= self.remainingCapacity());
            fastmem.copy(T, self.unusedCapacitySlice()[0..items.len], items);
            self.len += @intCast(items.len);
        }

        /// Return the element at index `i` of the slice.
        pub fn get(self: *const Self, i: usize) T {
            return self.constSlice()[i];
        }

        /// Set the value of the element at index `i` of the slice.
        pub fn set(self: *Self, i: usize, item: T) void {
            self.slice()[i] = item;
        }

        /// Set the length, e.g. after writing into the raw buffer or
        /// unusedCapacitySlice() out of band.
        ///
        /// Takes usize so callers never narrow before the check: IntFittingRange
        /// admits values above capacity, and an erased assert would accept them
        /// in ReleaseFast.
        pub fn resize(self: *Self, new_len: usize) void {
            if (new_len > capacity) @panic("ArrayBuffer.resize past capacity");
            self.resizeAssumeCapacity(new_len);
        }

        pub fn resizeAssumeCapacity(self: *Self, new_len: usize) void {
            assert(new_len <= capacity);
            self.len = @intCast(new_len);
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }
    };
}

test "append and slice" {
    var buf: ArrayBuffer(u8, 32) = .empty;

    try buf.appendSlice("hello");
    try testing.expectEqualStrings("hello", buf.constSlice());

    try buf.appendSlice(" world");
    try testing.expectEqualStrings("hello world", buf.constSlice());
}

test "appendAssumeCapacity" {
    var buf: ArrayBuffer(u8, 16) = .empty;

    buf.appendSliceAssumeCapacity("test");
    try testing.expectEqualStrings("test", buf.constSlice());
    try testing.expectEqual(12, buf.remainingCapacity());
}

test "append returns error on overflow" {
    var buf: ArrayBuffer(u8, 4) = .empty;

    try buf.appendSlice("hi");
    try testing.expectError(error.NoSpaceLeft, buf.appendSlice("hello"));
    try testing.expectEqualStrings("hi", buf.constSlice());
}

test "appendSliceAssumeCapacity to exact capacity" {
    var buf: ArrayBuffer(u8, 8) = .empty;

    buf.appendSliceAssumeCapacity("12345678");
    try testing.expectEqual(8, buf.len);
    try testing.expectEqual(0, buf.remainingCapacity());
}

test "resize boundary" {
    var buf: ArrayBuffer(u8, 8) = .empty;

    buf.resize(8);
    try testing.expectEqual(8, buf.len);
    buf.resize(0);
    try testing.expectEqual(0, buf.len);
}

test "clear resets length" {
    var buf: ArrayBuffer(u8, 16) = .empty;

    try buf.appendSlice("data");
    try testing.expectEqual(4, buf.len);

    buf.clear();
    try testing.expectEqual(0, buf.len);
    try testing.expectEqualStrings("", buf.constSlice());
}
