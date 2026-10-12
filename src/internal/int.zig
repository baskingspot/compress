//! Integer access with the byte order fixed by the namespace: `little` and
//! `big`, each an `Int(endian)` with `readInt` and `writeInt`. The width comes
//! from the integer type, so call sites carry no endian argument.
//!
//! A codec's `common.zig` binds the one order its wire format uses and
//! re-exports the functions it needs: `little` for flate, gzip, snappy, and
//! zstd, `big` for zlib. Both functions are `std.mem.readInt` and
//! `std.mem.writeInt` with the endian argument filled in.

const std = @import("std");
const mem = std.mem;

/// `readInt` and `writeInt` for one byte order. Use the ready-made `little`
/// and `big` bindings below.
pub fn Int(comptime endian: std.builtin.Endian) type {
    return struct {
        /// Reads an integer from memory with bit count specified by T.
        /// The bit count of T must be evenly divisible by 8.
        /// This function cannot fail and cannot cause undefined behavior.
        /// Reads in `endian` byte order.
        pub inline fn readInt(
            comptime T: type,
            buffer: *const [@divExact(@typeInfo(T).int.bits, 8)]u8,
        ) T {
            return mem.readInt(T, buffer, endian);
        }

        /// Writes an integer to memory, storing it in twos-complement.
        /// This function always succeeds, has defined behavior for all
        /// inputs, but the integer bit width must be divisible by 8.
        /// Writes in `endian` byte order.
        pub inline fn writeInt(
            comptime T: type,
            buffer: *[@divExact(@typeInfo(T).int.bits, 8)]u8,
            value: T,
        ) void {
            return mem.writeInt(T, buffer, value, endian);
        }
    };
}

/// Little-endian: the wire order of flate (RFC 1951 §3.1.1), gzip (RFC 1952
/// §2.1), and snappy's `u32-le` framing.
pub const little = Int(.little);

/// Big-endian (network order): the wire order of zlib (RFC 1950 §2.1).
pub const big = Int(.big);
