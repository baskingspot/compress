//! zstd (RFC 8878): a decoder in pure Zig. `zstd.decode` is the one-shot
//! decoder and `zstd.Reader` is a decompressing `std.Io.Reader` over one frame.
//! There is no encoder. No decode path allocates, and the only imports are
//! `std` and `fastmem`. This is the `zcompress.zstd` namespace.
//!
//! The source files, from the bottom up:
//!
//! - `bits.zig`: the bitstream readers.
//! - `fse.zig` and `huff0.zig`: the two entropy decoders.
//! - `literals.zig` and `sequences.zig`: the two sections of a compressed block.
//! - `block.zig`: the block header and the per-block decode.
//! - `frame.zig` and `xxh64.zig`: the frame header, the block chain, skippable
//!   frames, and the checksum.
//! - `decode.zig` and `Reader.zig`: the one-shot and streaming decoders.
//!
//! Format: docs/research/specs/rfc8878-zstd.txt

const std = @import("std");

const bits = @import("bits.zig");
const block = @import("block.zig");
const common = @import("common.zig");
const fse = @import("fse.zig");
const frame = @import("frame.zig");
const huff0 = @import("huff0.zig");
const literals = @import("literals.zig");
const sequences = @import("sequences.zig");
const xxh64 = @import("xxh64.zig");

/// The one-shot decoder: `decompress` and its error set, plus the layer
/// namespaces it is built from (`frame`, `block`, `literals`, `sequences`,
/// `fse`, and `window`).
pub const decode = @import("decode.zig");

/// The streaming decoder: an `Io.Reader` that decompresses one Zstandard
/// frame, the caller-owned window buffer `Reader.Buffer`, and the
/// `streamFrame` and `streamAll` pumps.
pub const Reader = @import("Reader.zig");

test {
    _ = bits;
    _ = block;
    _ = common;
    _ = fse;
    _ = frame;
    _ = huff0;
    _ = literals;
    _ = sequences;
    _ = xxh64;
    _ = decode;
    _ = Reader;
    _ = @import("golden.zig");
    _ = @import("fuzz.zig");
    std.testing.refAllDecls(@This());
}
