//! Snappy codec: a block encoder and decoder, plus a streaming `Reader` and
//! `Writer` over `std.Io`. Depends on `std`, `fastmem`, and the shared
//! `src/internal/` helpers; allocates nothing.
//!
//!   - `snappy.encode`: `compressBlock`, `maxCompressedLength`,
//!     `max_block_size`.
//!   - `snappy.decode`: `decompressBlock`, `decompressedBlockLength`,
//!     `DecompressError`.
//!   - `snappy.Writer` and `snappy.Reader`: the streaming layer over a framed
//!     stream of length-prefixed blocks (`Buffer`, `init`, `finish`,
//!     `streamAll`).
//!
//! Format: https://github.com/google/snappy/blob/main/format_description.txt
//! Usage, sizing, and the stream framing: `README.md`.

const std = @import("std");

pub const decode = @import("decode.zig");
pub const encode = @import("encode.zig");
pub const Reader = @import("Reader.zig");
pub const Writer = @import("Writer.zig");

test {
    _ = encode;
    _ = decode;
    _ = Writer;
    _ = Reader;
    _ = @import("golden.zig");
    _ = @import("fuzz.zig");
    std.testing.refAllDecls(@This());
}
