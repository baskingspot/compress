//! brotli (RFC 7932) decoder in pure Zig. The layers are in place — the bit
//! reader (`bits.zig`), the stream header and meta-block ladder (`frame.zig`),
//! the two prefix code forms and their decode tables (`huffman.zig`), the
//! context modes and maps (`context.zig`), the distance layer
//! (`distance.zig`), the command stream (`command.zig`), and the static
//! dictionary with its word transforms (`dictionary.zig`) — and `decode.zig`
//! composes them into the one-shot `decompress`, with `Reader.zig` the
//! streaming form over `std.Io`. Imports only `std` and `fastmem`; no heap
//! allocation on any decode path.
//!
//! Format: docs/specs/rfc7932-brotli.txt. API: README.md.

const std = @import("std");

const testing = std.testing;
const bits = @import("bits.zig");
const command = @import("command.zig");
const context = @import("context.zig");
/// One-shot decompression: `decompress` and its error set,
/// `DecompressError`.
pub const decode = @import("decode.zig");
/// One-shot compression: `compress`, `maxCompressedLength`, and the
/// encoder's `Options` (the reference's `q3` class).
pub const encode = @import("encode.zig");
const dictionary = @import("dictionary.zig");
const distance = @import("distance.zig");
const frame = @import("frame.zig");
const huffman = @import("huffman.zig");
/// Streaming decompression: `Reader`, its `Buffer`, and `streamAll`.
pub const Reader = @import("Reader.zig");
/// Streaming compression: `Writer`, its `Buffer`, and `streamAll` — the
/// encoder's `q3` class over an `Io.Writer`.
pub const Writer = @import("Writer.zig");

test {
    _ = bits;
    _ = command;
    _ = context;
    _ = decode;
    _ = encode;
    _ = @import("encode_huffman.zig");
    _ = @import("encode_match.zig");
    _ = dictionary;
    _ = distance;
    _ = frame;
    _ = huffman;
    _ = Reader;
    _ = Writer;
    _ = @import("golden.zig");
    _ = @import("fuzz.zig");
    testing.refAllDecls(@This());
}
