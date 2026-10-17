//! zstd (RFC 8878): a fast encoder and a complete decoder in pure Zig.
//! `zstd.encode` and `zstd.decode` are the one-shots; `zstd.Reader` is a
//! decompressing `std.Io.Reader` and `zstd.Writer` a compressing
//! `std.Io.Writer`, each over one frame. No encode or decode path allocates,
//! and the only imports are `std` and `fastmem`. This is the
//! `compress.zstd` namespace.
//!
//! The source files, from the bottom up:
//!
//! - `bits.zig`: the bitstream readers and their writer inverses.
//! - `fse.zig`, `huff0.zig` and `fse_compress.zig`, `huff0_compress.zig`:
//!   the two entropy coders' decode and encode sides.
//! - `literals.zig` and `sequences.zig`, `literals_compress.zig` and
//!   `sequences_compress.zig`: the two sections of a compressed block.
//! - `match_compress.zig`: the encoder's fast match finder.
//! - `block.zig` and `block_compress.zig`: the block header, the per-block
//!   decode, and the encoder's block emission ladder.
//! - `frame.zig` and `xxh64.zig`: the frame header, the block chain, skippable
//!   frames, and the checksum.
//! - `Dictionary.zig`: the parse-once dictionary (§5) both directions take.
//! - `encode.zig`, `decode.zig`, `Reader.zig`, and `Writer.zig`: the
//!   one-shots and the streaming decoder and encoder.
//!
//! Format: docs/research/specs/rfc8878-zstd.txt

const std = @import("std");

const bits = @import("bits.zig");
const block = @import("block.zig");
const block_compress = @import("block_compress.zig");
const common = @import("common.zig");
const dfast_compress = @import("dfast_compress.zig");
const fse = @import("fse.zig");
const fse_compress = @import("fse_compress.zig");
const frame = @import("frame.zig");
const huff0 = @import("huff0.zig");
const huff0_compress = @import("huff0_compress.zig");
const literals = @import("literals.zig");
const literals_compress = @import("literals_compress.zig");
const match_compress = @import("match_compress.zig");
const sequences = @import("sequences.zig");
const sequences_compress = @import("sequences_compress.zig");
const split_compress = @import("split_compress.zig");
const xxh64 = @import("xxh64.zig");

/// The one-shot encoder: `compress`, `maxCompressedLength`, and their
/// options.
pub const encode = @import("encode.zig");

/// The one-shot decoder: `decompress` and its error set, plus the layer
/// namespaces it is built from (`frame`, `block`, `literals`, `sequences`,
/// `fse`, and `window`).
pub const decode = @import("decode.zig");

/// The streaming decoder: an `Io.Reader` that decompresses one Zstandard
/// frame, the caller-owned window buffer `Reader.Buffer`, and the
/// `streamFrame` and `streamAll` pumps.
pub const Reader = @import("Reader.zig");

/// The streaming encoder: an `Io.Writer` that compresses into one Zstandard
/// frame, the caller-owned `Writer.Buffer`, and the `streamAll` and
/// `streamAllAlloc` pumps.
pub const Writer = @import("Writer.zig");

/// A parsed dictionary (RFC 8878 §5): `parse` reads the formatted form,
/// `initRaw` takes format-free content. The value is handed to either
/// direction (the decode side today) and borrows the caller's bytes.
pub const Dictionary = @import("Dictionary.zig");

test {
    _ = bits;
    _ = block;
    _ = block_compress;
    _ = common;
    _ = dfast_compress;
    _ = fse;
    _ = fse_compress;
    _ = frame;
    _ = huff0;
    _ = huff0_compress;
    _ = literals;
    _ = literals_compress;
    _ = match_compress;
    _ = sequences;
    _ = sequences_compress;
    _ = split_compress;
    _ = xxh64;
    _ = encode;
    _ = decode;
    _ = Reader;
    _ = Writer;
    _ = Dictionary;
    _ = @import("golden.zig");
    _ = @import("fuzz.zig");
    std.testing.refAllDecls(@This());
}
