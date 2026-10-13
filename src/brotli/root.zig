//! brotli (RFC 7932) decoder in pure Zig. The decoder lands in layers: the
//! bit reader (`bits.zig`), the stream header and meta-block ladder with the
//! compressed meta-block header's completion (`frame.zig`), the two prefix
//! code forms and their decode tables (`huffman.zig`), and the context modes
//! and maps (`context.zig`) are here; the block switches, the command
//! stream, and the static dictionary follow. The public surface —
//! `brotli.decode` and `brotli.Reader` — arrives with the layers that
//! compose them. Imports only `std` and `fastmem`; no heap allocation on any
//! decode path.
//!
//! Format: docs/research/specs/rfc7932-brotli.txt. API: README.md.

const std = @import("std");

const bits = @import("bits.zig");
const context = @import("context.zig");
const frame = @import("frame.zig");
const huffman = @import("huffman.zig");

test {
    _ = bits;
    _ = context;
    _ = frame;
    _ = huffman;
    _ = @import("golden.zig");
    std.testing.refAllDecls(@This());
}
