//! Little-endian integer access for the gzip codec. RFC 1952 §2.1 stores
//! every multi-byte number least-significant byte first (the CRC32 and ISIZE
//! trailer fields, the FHCRC header field), so the byte order is fixed here
//! and call sites pass none. Both functions are `internal.int.little`'s.

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
