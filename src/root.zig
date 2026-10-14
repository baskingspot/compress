//! zcompress: fast, self-contained compression codecs in pure Zig.
//!
//! One module; each codec is a namespace under it. Codecs import only `std`
//! and `fastmem`, plus the shared `src/internal/` by relative import (gzip and
//! zlib also import `flate`), so a codec directory can be copied out together
//! with `src/internal/`.

const std = @import("std");

/// brotli (RFC 7932) decoder: one-shot `decode.decompress` and the streaming
/// `Reader`. The decoder lands in layers — the bit reader, the stream header
/// and meta-block ladder, the prefix codes, the context models, the distance
/// layer, the command stream, and the static dictionary with its word
/// transforms are in place, and the public surface follows with the layers
/// that compose them. API: `src/brotli/README.md`. Format:
/// docs/research/specs/rfc7932-brotli.txt.
pub const brotli = @import("brotli/root.zig");
/// Raw DEFLATE (RFC 1951): one-shot `encode.compress` and `decode.decompress`,
/// and the streaming `Reader` and `Writer`. Caller-owned buffers, no heap
/// allocation. API: `src/flate/README.md`. Format:
/// docs/research/specs/rfc1951-deflate.txt.
pub const flate = @import("flate/root.zig");
/// gzip (RFC 1952) over `flate`: one-shot `encode.compress` and
/// `decode.decompress`, and the streaming `Reader` and `Writer`. Caller-owned
/// buffers, no heap allocation. API: `src/gzip/README.md`. Format:
/// docs/research/specs/rfc1952-gzip.txt.
pub const gzip = @import("gzip/root.zig");
/// Snappy blocks: `encode.compressBlock` and `decode.decompressBlock` over
/// caller-owned buffers, and a streaming `Reader` and `Writer` over a
/// length-prefixed framing of this package's own. No heap allocation. API:
/// `src/snappy/README.md`. Format:
/// docs/research/specs/snappy-format-description.txt.
pub const snappy = @import("snappy/root.zig");
/// zlib (RFC 1950) over `flate`: one-shot `encode.compress` and
/// `decode.decompress`, and the streaming `Reader` and `Writer`. Caller-owned
/// buffers, no heap allocation. API: `src/zlib/README.md`. Format:
/// docs/research/specs/rfc1950-zlib.txt.
pub const zlib = @import("zlib/root.zig");
/// zstd (RFC 8878) decoder: one-shot `decode.decompress` and the streaming
/// `Reader`, with XXH64 frame checksum verification. There is no encoder.
/// API: `src/zstd/README.md`. Format: docs/research/specs/rfc8878-zstd.txt.
pub const zstd = @import("zstd/root.zig");

test {
    _ = brotli;
    _ = flate;
    _ = snappy;
    _ = gzip;
    _ = zlib;
    _ = zstd;
    // The consumer surface, spelled the way a consumer spells it: names are
    // reached through the codec namespaces, and nothing is flat at the root.
    _ = flate.encode.Level;
    _ = flate.decode.decompress;
    _ = flate.Reader.streamAll;
    _ = flate.Writer.streamAll;
    _ = gzip.encode.Level;
    _ = gzip.decode.decompress;
    _ = gzip.Reader.streamAll;
    _ = gzip.Writer.streamAll;
    _ = snappy.encode.compressBlock;
    _ = snappy.decode.decompressBlock;
    _ = snappy.Reader.streamAll;
    _ = snappy.Writer.streamAll;
    _ = zlib.encode.Level;
    _ = zlib.decode.decompress;
    _ = zlib.Reader.streamAll;
    _ = zlib.Writer.streamAll;
    _ = zstd.decode.max_block_size;
    _ = zstd.decode.decompress;
    _ = zstd.Reader.streamAll;
    std.testing.refAllDecls(@This());
}
