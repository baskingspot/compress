//! Little-endian integer access for brotli. The format is bit-oriented, but
//! the bit reader and the match finder assemble 64-bit words from bytes, so
//! the helper fixes the byte order and call sites pass no endian argument.
//! These are `internal.int.little`'s, bound here. The fuzz seeds use the
//! Smith harness's little-endian serialization and do not go through them.

const internal = @import("../internal/root.zig");

/// Reads an integer from memory with bit count specified by T.
/// The bit count of T must be evenly divisible by 8.
/// This function cannot fail and cannot cause undefined behavior.
/// Forces little-endianness.
pub const readInt = internal.int.little.readInt;
