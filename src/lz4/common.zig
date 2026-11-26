//! Little-endian integer access for the LZ4 block format.

const internal = @import("../internal/root.zig");

/// Reads an integer from memory with bit count specified by T.
/// The bit count of T must be evenly divisible by 8.
/// This function cannot fail and cannot cause undefined behavior.
/// Forces little-endianness (the body is `internal.int`'s, bound here).
pub const readInt = internal.int.little.readInt;

/// Writes an integer to memory, storing it in twos-complement.
/// This function always succeeds, has defined behavior for all inputs, but
/// the integer bit width must be divisible by 8.
/// Forces little-endianness.
pub const writeInt = internal.int.little.writeInt;
