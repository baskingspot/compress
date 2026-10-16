//! gzip (RFC 1952) over the flate module: the member framing, the CRC-32 and
//! size trailer, and the `std.Io` streaming layer. This is the
//! `compress.gzip` namespace. It imports `std`, `fastmem`, and flate (by
//! relative path), and it never allocates.
//!
//! The public surface is four namespaces: `encode` (one-shot compress),
//! `decode` (one-shot decompress), `Writer` (streaming compress), and `Reader`
//! (streaming decompress). Usage and contracts: README.md.
//!
//! Format: docs/research/specs/rfc1952-gzip.txt

const std = @import("std");

pub const encode = @import("encode.zig");
pub const decode = @import("decode.zig");
/// A decompressing `Io.Reader` over one gzip member. Read through
/// `&r.reader`; it returns `error.EndOfStream` once the trailer is verified,
/// and after a failure `r.err` holds the specific error. It allocates
/// nothing; the caller provides `Reader.Buffer`.
pub const Reader = @import("Reader.zig");
/// A compressing `Io.Writer` that produces one gzip member. Write through
/// `&w.writer` and end the member with `finish`. It allocates nothing; the
/// caller provides `Writer.Buffer`.
pub const Writer = @import("Writer.zig");

test {
    _ = encode;
    _ = decode;
    _ = Writer;
    _ = Reader;
    _ = @import("crc32.zig");
    _ = @import("golden.zig");
    _ = @import("fuzz.zig");
    std.testing.refAllDecls(@This());
}
