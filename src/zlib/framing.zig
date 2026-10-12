//! zlib's half of the shared container driver (`src/internal/container.zig`):
//! the 2-byte header, the trailer, the Adler-32 state, and the error sets,
//! bound to flate's streaming types. `Reader`, `Writer`, `encode`, and
//! `decode` instantiate the driver over this file. It is internal: the barrel
//! does not export it, and the driver's file documents what a framing must
//! provide.
//!
//! The header and trailer logic lives in `decode.checkHeader`,
//! `decode.checkTrailer`, `encode.writeHeader`, and `encode.writeTrailer`.
//! The functions here forward to them, and the body goes through flate's
//! one-shot encoder.

const std = @import("std");
const Io = std.Io;

const flate = @import("../flate/root.zig");
const container = @import("../internal/container.zig");
const adler32 = @import("adler32.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");

/// The flate level type, re-exported: the container adds no levels of its
/// own. `.ratio` is not implemented and is never treated as another level.
pub const Level = flate.encode.Level;

/// Encoder configuration. `.{}` is the default: the fast level.
pub const Options = struct {
    level: Level = .fast,
};

/// The failure detail a `Reader` records in `err` once its state is
/// `.failed`: flate's reader errors (without `BufferTooSmall`, since the
/// decode window is fixed) plus this module's header and trailer errors.
pub const Error = flate.Reader.Error || error{
    BadHeader,
    DictionaryRequired,
    WrongChecksum,
};

/// The one-shot decoder's error set: flate's decode errors plus this module's
/// header and trailer errors. `BufferTooSmall` is flate's: the stream does not
/// fit the caller's `target`.
pub const DecompressError = flate.decode.DecompressError || error{
    BadHeader, // CM != 8, CINFO > 7, or FCHECK (§2.2, §2.3)
    DictionaryRequired, // FDICT set: no preset-dictionary support (§2.3)
    WrongChecksum, // ADLER32 mismatch (§2.2, §2.3)
};

/// The header check's own failures, plus `Truncated` and `ReadFailed` for
/// the input route: a header cut short by the input's end is `Truncated`.
pub const HeaderError = error{
    BadHeader,
    DictionaryRequired,
    Truncated,
    ReadFailed,
};

/// The trailer's own failures, plus `Truncated` and `ReadFailed` for the
/// input route.
pub const TrailerError = error{
    Truncated,
    ReadFailed,
    WrongChecksum,
};

/// The container's checksum state, folded through flate's hook: the Adler-32
/// over the uncompressed bytes (`§2.2`). The trailer has no length field.
pub const Checksum = adler32.Checksum;

/// Whether the header has been parsed: the check runs once, before the first
/// body byte.
pub const Header = enum { pending, parsed };

/// The caller-provided decode window: flate's, re-exported; the container adds
/// no buffer of its own. `[2 * history_len]u8`, 64 KiB.
pub const ReaderBuffer = flate.Reader.Buffer;

/// The caller-provided compression buffer: flate's, re-exported; the container
/// adds no buffer of its own. `[max_block_size + history_len]u8`, 98303 bytes.
pub const WriterBuffer = flate.Writer.Buffer;

/// The inner codec's streaming types, as the driver reads them.
pub const InnerReader = flate.Reader;
pub const InnerWriter = flate.Writer;

/// RFC 1950 §2.2 — the header's length: CMF and FLG.
pub const header_len = 2;

/// RFC 1950 §2.2 — the trailer's length: ADLER32.
pub const trailer_len = 4;

/// The writer's serving region: flate's block size (the front region of the
/// caller's `Writer.Buffer`).
pub const writer_region_len = flate.encode.max_block_size;

/// Wrap `input` with `buffer` as the inner flate reader's window.
pub fn initReader(input: *Io.Reader, buffer: *ReaderBuffer) InnerReader {
    return flate.Reader.init(input, buffer);
}

/// Wrap `output` with `buffer` as the inner flate writer's window and
/// `options`' level fixed for the stream's lifetime.
pub fn initWriter(output: *Io.Writer, buffer: *WriterBuffer, options: Options) InnerWriter {
    return flate.Writer.init(output, buffer, .{ .level = options.level });
}

/// Whether the header has been checked.
pub fn headerDone(header: *const Header) bool {
    return header.* == .parsed;
}

/// Read and check the 2-byte stream header (`§2.2`, `§2.3`): CM, CINFO,
/// FCHECK, and the FDICT refusal, before any body byte. A set FDICT flag is
/// refused, never skipped past its DICTID. A header cut short by the end of
/// the input is `Truncated`.
pub fn readHeader(header: *Header, input: *Io.Reader) HeaderError!void {
    var bytes: [header_len]u8 = undefined;
    try container.readExact(input, &bytes);
    try decode.checkHeader(bytes[0], bytes[1]);
    header.* = .parsed;
}

/// Verify the 4-byte trailer against the running Adler-32 (`§2.2`, `§2.3`);
/// see `decode.checkTrailer`.
pub fn checkTrailer(trailer: *const [trailer_len]u8, checksum: *const Checksum) TrailerError!void {
    return decode.checkTrailer(trailer, checksum.final());
}

/// Write the 2-byte header for `level` into `target` (see
/// `encode.writeHeader`).
pub fn writeHeader(target: *[header_len]u8, level: Level) void {
    encode.writeHeader(target, level);
}

/// Emit the 4-byte trailer — the Adler-32, big-endian (`§2.1`, `§2.2`) —
/// from the folded checksum state.
pub fn writeTrailer(target: *[trailer_len]u8, checksum: *const Checksum) void {
    encode.writeTrailer(target, checksum.final());
}

/// The deflate body through flate's one-shot encoder.
pub fn bodyCompress(
    source: []const u8,
    target: []u8,
    options: Options,
) error{ BufferTooSmall, Unimplemented }!usize {
    return flate.encode.compress(source, target, .{ .level = options.level });
}

/// The worst-case deflate body length (flate's bound).
pub fn bodyMaxCompressedLength(input_len: usize) usize {
    return flate.encode.maxCompressedLength(input_len);
}
