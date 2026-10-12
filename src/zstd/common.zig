//! Little-endian integer access for the zstd codec. RFC 8878 stores its
//! multi-byte fields least-significant byte first: the Magic_Number
//! (`§3.1.1`), the Block_Header (`§3.1.1.2`), Frame_Content_Size
//! (`§3.1.1.1.4`), the literals Jump_Table sizes (`§3.1.1.3.1.6`), and the
//! checksum trailer (`§3.1.1`). `readInt` is `internal.int`'s little-endian
//! reader, so call sites pass no endianness.

const internal = @import("../internal/root.zig");

/// Reads an integer from memory with bit count specified by T.
/// The bit count of T must be evenly divisible by 8.
/// This function cannot fail and cannot cause undefined behavior.
/// Forces little-endianness.
pub const readInt = internal.int.little.readInt;
