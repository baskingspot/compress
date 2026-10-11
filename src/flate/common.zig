//! Shared helpers for the flate codec: little-endian integer access. Every
//! byte-aligned integer access in this package is little-endian — the
//! encoder's hash loads, the stored-block headers, and the bit reader's
//! window (deflate packs bits into bytes LSB-first, RFC 1951 §3.1.1, and
//! stores multi-byte numbers least-significant byte first, §3.1) — so the
//! helpers bake the endianness in and call sites carry no endian argument.
//! The `readInt`/`writeInt` bodies are `internal.int`'s, bound here.

const mem = @import("std").mem;
const internal = @import("../internal/root.zig");

/// Reads an integer from memory with bit count specified by T.
/// The bit count of T must be evenly divisible by 8.
/// This function cannot fail and cannot cause undefined behavior.
/// Forces little-endianness.
pub const readInt = internal.int.little.readInt;

/// Writes an integer to memory, storing it in twos-complement.
/// This function always succeeds, has defined behavior for all inputs, but
/// the integer bit width must be divisible by 8.
/// Forces little-endianness.
pub const writeInt = internal.int.little.writeInt;

/// Reads an integer from `bytes` with size equal to `bytes.len`. The return
/// type must be large enough to store the result.
/// Forces little-endianness.
pub inline fn readVarInt(comptime T: type, bytes: []const u8) T {
    return mem.readVarInt(T, bytes, .little);
}
