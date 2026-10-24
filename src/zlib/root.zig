//! zlib streams (RFC 1950) over the flate module: the 2-byte header, the
//! Adler-32 trailer, and a `std.Io` streaming layer. This is the
//! `compress.zlib` namespace. It imports `std`, `fastmem`, and `flate` (by
//! relative path) and allocates no heap memory.
//!
//! The public surface is four names:
//!
//!   - `encode`: one-shot compression (`encode.compress`).
//!   - `decode`: one-shot decompression (`decode.decompress`).
//!   - `Writer`: a compressing `std.Io.Writer`.
//!   - `Reader`: a decompressing `std.Io.Reader`.
//!
//! Usage and contracts: README.md. Format: docs/specs/rfc1950-zlib.txt

const std = @import("std");

/// One-shot compression: `compress` and `maxCompressedLength`, plus the
/// header and trailer helpers the streaming `Writer` is built from.
pub const encode = @import("encode.zig");
/// One-shot decompression: `decompress` and `DecompressError`, plus the header
/// and trailer checks the streaming `Reader` is built from.
pub const decode = @import("decode.zig");
/// A decompressing `Io.Reader` over one zlib stream. Read through
/// `&r.reader`. The clean end is `error.EndOfStream`, reported only after the
/// trailer checks out; on any failure the interface returns `error.ReadFailed`
/// and the cause is in `r.err`. The caller provides `Reader.Buffer`. Nothing
/// is allocated.
pub const Reader = @import("Reader.zig");
/// A compressing `Io.Writer` that produces one zlib stream. Write through
/// `&w.writer`, then call `finish` to complete the stream. The caller
/// provides `Writer.Buffer`. Nothing is allocated.
pub const Writer = @import("Writer.zig");

test {
    _ = encode;
    _ = decode;
    _ = Writer;
    _ = Reader;
    _ = @import("adler32.zig");
    _ = @import("golden.zig");
    _ = @import("fuzz.zig");
    std.testing.refAllDecls(@This());
}
