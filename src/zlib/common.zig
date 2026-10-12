//! Big-endian integer access for the zlib container. RFC 1950 §2.1 stores
//! multi-byte numbers most-significant byte first (the Adler-32 trailer,
//! §2.2), so these helpers fix the byte order and call sites pass no endian
//! argument. They are `internal.int.big`'s, bound here. The fuzz seeds in
//! `fuzz.zig` use the Smith harness's little-endian serialization and do not
//! go through them.

const internal = @import("../internal/root.zig");

/// Reads an integer from memory with bit count specified by T.
/// The bit count of T must be evenly divisible by 8.
/// This function cannot fail and cannot cause undefined behavior.
/// Forces big-endianness.
pub const readInt = internal.int.big.readInt;

/// Writes an integer to memory, storing it in twos-complement.
/// This function always succeeds, has defined behavior for all inputs, but
/// the integer bit width must be divisible by 8.
/// Forces big-endianness.
pub const writeInt = internal.int.big.writeInt;
