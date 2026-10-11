//! Shared helpers for the zlib container: big-endian integer access. RFC 1950
//! §2.1 stores every multi-byte number MOST-significant byte first — the
//! Adler-32 trailer (§2.2) — so the helpers bake the endianness in and call
//! sites carry no endian argument. The fuzz seeds' Smith serialization is
//! little-endian by that harness's format and does not use these helpers.
//! The bodies are `internal.int`'s, bound here.

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
