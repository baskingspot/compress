//! Endian-bound integer access: the shared home of the codec `readInt`/
//! `writeInt` helpers (README.md). A codec's `common.zig` binds its one wire
//! endianness — little-endian for flate, gzip, and snappy; big-endian for
//! zlib — and re-exports the names, so call sites carry no endian argument
//! (the per-codec `common.zig` shape, with one body for every codec).
//! zstd's decoder-only `common.zig` binds `little` for `readInt` alone;
//! M5's encoder adds the `writeInt` mirror there.
//!
//! The operations are `std.mem`'s, bound: the width comes from `T`, the
//! byte order from the namespace.

const std = @import("std");
const mem = std.mem;

/// The two operations, bound to one endianness. A codec takes its binding
/// from `little`/`big` below; a codec with a second wire order instantiates
/// its own.
pub fn Int(comptime endian: std.builtin.Endian) type {
    return struct {
        /// Reads an integer from memory with bit count specified by T.
        /// The bit count of T must be evenly divisible by 8.
        /// This function cannot fail and cannot cause undefined behavior.
        /// Forces `endian`ness.
        pub inline fn readInt(
            comptime T: type,
            buffer: *const [@divExact(@typeInfo(T).int.bits, 8)]u8,
        ) T {
            return mem.readInt(T, buffer, endian);
        }

        /// Writes an integer to memory, storing it in twos-complement.
        /// This function always succeeds, has defined behavior for all
        /// inputs, but the integer bit width must be divisible by 8.
        /// Forces `endian`ness.
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
