//! Shared helpers for the zstd codec: little-endian integer access. RFC 8878
//! stores every multi-byte field least-significant byte first
//! (`§3.1.1.3.1.1`: "For values spanning several bytes, the convention is
//! little endian" — the literals Jump_Table's u16 stream sizes, the frame
//! magic, the block header, Frame_Content_Size, and the checksum trailer), so
//! the helpers bake the endianness in and call sites carry no endian
//! argument (the gzip/zlib `common.zig` shape).
//!
//! M4 is decoder-only, so `readInt` is the whole surface; M5's encoder adds
//! the `writeInt` mirror. The body is `internal.int`'s, bound here.

const internal = @import("../internal/root.zig");

/// Reads an integer from memory with bit count specified by T.
/// The bit count of T must be evenly divisible by 8.
/// This function cannot fail and cannot cause undefined behavior.
/// Forces little-endianness.
pub const readInt = internal.int.little.readInt;
