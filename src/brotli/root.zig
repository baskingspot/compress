//! brotli (RFC 7932) decoder in pure Zig. The decoder lands in layers: the
//! bit reader (`bits.zig`) and the stream header and meta-block ladder
//! (`frame.zig`) are here, and the prefix codes, block switches, context
//! maps, distances, command stream, and the static dictionary follow. The
//! public surface — `brotli.decode` and `brotli.Reader` — arrives with the
//! layers that compose them. Imports only `std` and `fastmem`; no heap
//! allocation on any decode path.
//!
//! Format: docs/research/specs/rfc7932-brotli.txt. API: README.md.

const std = @import("std");

const bits = @import("bits.zig");
const frame = @import("frame.zig");

test {
    _ = bits;
    _ = frame;
    _ = @import("golden.zig");
    std.testing.refAllDecls(@This());
}
