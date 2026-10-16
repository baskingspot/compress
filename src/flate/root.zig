//! Raw DEFLATE (RFC 1951): the `compress.flate` namespace. An inflate for all
//! three block types (stored, fixed, and dynamic), a fixed-Huffman encoder, and
//! streaming `std.Io` adapters, all over caller-owned buffers with no heap
//! allocation. Imports only `std` and `fastmem`.
//!
//! - `encode.compress`, `encode.maxCompressedLength`: one-shot compression.
//! - `decode.decompress`, `decode.DecompressError`: one-shot decompression.
//! - `Writer`: a compressing `Io.Writer`; end the stream with `finish`.
//! - `Reader`: a decompressing `Io.Reader`.
//!
//! Usage and behavior: README.md.
//!
//! Format: docs/research/specs/rfc1951-deflate.txt

const std = @import("std");

/// One-shot compression: `compress`, `maxCompressedLength`, and the encoder's
/// `Options` and `Level`.
pub const encode = @import("encode.zig");
/// One-shot decompression: `decompress` and its error set, `DecompressError`.
pub const decode = @import("decode.zig");
/// A decompressing `Io.Reader` over a raw deflate stream. Make one with
/// `Reader.init` and read through `&r.reader`; it returns `error.EndOfStream`
/// once the final block's output has been consumed. The caller provides the
/// window (`Reader.Buffer`); nothing is allocated.
pub const Reader = @import("Reader.zig");
/// A compressing `Io.Writer` that produces a raw deflate stream. Make one with
/// `Writer.init`, write through `&w.writer`, and end the stream with `finish`.
/// The caller provides the buffer (`Writer.Buffer`); nothing is allocated.
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
