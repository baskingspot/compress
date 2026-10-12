//! zstd (RFC 8878): a decoder in pure Zig, with the encoder's entropy layers
//! landing beside it. `zstd.decode` is the one-shot decoder and `zstd.Reader`
//! is a decompressing `std.Io.Reader` over one frame; the encoder's kernels
//! (`*_compress.zig`) are internal until `zstd.encode` and `zstd.Writer`
//! land. No decode path allocates, and the only imports are `std` and
//! `fastmem`. This is the `zcompress.zstd` namespace.
//!
//! The source files, from the bottom up:
//!
//! - `bits.zig`: the bitstream readers and their writer inverses.
//! - `fse.zig`, `huff0.zig` and `fse_compress.zig`, `huff0_compress.zig`:
//!   the two entropy coders' decode and encode sides.
//! - `literals.zig` and `sequences.zig`, `literals_compress.zig` and
//!   `sequences_compress.zig`: the two sections of a compressed block.
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
const fse_compress = @import("fse_compress.zig");
const frame = @import("frame.zig");
const huff0 = @import("huff0.zig");
const huff0_compress = @import("huff0_compress.zig");
const literals = @import("literals.zig");
const literals_compress = @import("literals_compress.zig");
const sequences = @import("sequences.zig");
const sequences_compress = @import("sequences_compress.zig");
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
    _ = fse_compress;
    _ = frame;
    _ = huff0;
    _ = huff0_compress;
    _ = literals;
    _ = literals_compress;
    _ = sequences;
    _ = sequences_compress;
    _ = xxh64;
    _ = decode;
    _ = Reader;
    _ = @import("golden.zig");
    _ = @import("fuzz.zig");
    std.testing.refAllDecls(@This());
}
