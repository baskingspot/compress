//! LZ4 block codec: `encode.compressBlock` and `decode.decompressBlock` over
//! caller-owned buffers. Depends on `std`, `fastmem`, and the shared
//! `src/internal/` helpers; allocates nothing.
//!
//! The raw block has no framing or decoded-length field. The caller supplies
//! that length as `decompressBlock`'s `target.len`. No frame, legacy, HC, or
//! dictionary API.
//!
//! Format: docs/specs/lz4-block-format.md
//! Usage and sizing: `README.md`.

const std = @import("std");

const testing = std.testing;
pub const decode = @import("decode.zig");
pub const encode = @import("encode.zig");

test {
    _ = encode;
    _ = decode;
    _ = @import("golden.zig");
    _ = @import("fuzz.zig");
    testing.refAllDecls(@This());
}
