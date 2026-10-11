//! Shared helpers for the gzip codec: little-endian integer access. RFC 1952
//! §2.1 stores every multi-byte number least-significant byte first — the
//! CRC32 and ISIZE trailer and the FHCRC header field (§2.3.1) — so the
//! helpers bake the endianness in and call sites carry no endian argument.
//! The bodies are `internal.int`'s, bound here.

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
