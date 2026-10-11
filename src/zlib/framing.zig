//! The zlib framing, as the shared container driver consumes it
//! (`src/internal/container.zig`): the 2-byte stream header, the trailer, the
//! Adler-32 state, and the error sets, bound to flate's streaming types. The
//! module's `Reader`/`Writer`/`encode`/`decode` instantiate the driver over
//! this type; it is not part of the public surface (the barrel exposes the
//! four namespaces, never this file).
//!
//! The contract is stated in full at `src/internal/container.zig`; the
//! functions here are the zlib halves — the two-byte header check
//! (`decode.checkHeader`, CM/CINFO/FCHECK/FDICT), the Adler-32 trailer check
//! (`decode.checkTrailer`), the deterministic emissions
//! (`encode.writeHeader`/`writeTrailer`), and flate's one-shot body.

const std = @import("std");
const Io = std.Io;

const flate = @import("../flate/root.zig");
const container = @import("../internal/container.zig");
const adler32 = @import("adler32.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");

/// The flate level type, re-exported: the container adds no levels of its
/// own (README, "API"). `.ratio` is flate's reserved seat — `error.Unimplemented`
/// here, never silent aliasing.
pub const Level = flate.encode.Level;

/// Encoder configuration. `.{}` is the default: the fast level.
pub const Options = struct {
    level: Level = .fast,
};

/// The detailed error recorded once the reader's `state == .failed`
/// (README, "API"): flate's decode detail set — minus `BufferTooSmall`, the
/// window is the caller's and flate owns it — plus this module's header and
/// trailer entries.
pub const Error = flate.Reader.Error || error{
    BadHeader,
    DictionaryRequired,
    WrongChecksum,
};

/// The one-shot decoder's error set (README, "API"): flate's decode detail
/// set plus this module's header and trailer entries. `BufferTooSmall` is
/// flate's (a stream that does not fit the caller's cap).
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

/// The container's checksum state folded through flate's hook: the Adler-32
/// over the decoded bytes (`§2.2`). RFC 1950's trailer carries no length
/// field beside it.
pub const Checksum = adler32.Checksum;

/// Whether the header has been parsed: the check runs once, before the first
/// body byte.
pub const Header = enum { pending, parsed };

/// The caller-provided window: flate's, re-exported — the container adds no
/// buffer of its own (OQ6). `[2 * history_len]u8`, 64 KiB.
pub const ReaderBuffer = flate.Reader.Buffer;

/// The caller-provided buffer: flate's, re-exported — the container adds no
/// buffer of its own (OQ6). `[max_block_size + history_len]u8`, 98303 bytes.
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

/// Check the stream header (`§2.2`, `§2.3`), consuming its two bytes: CM,
/// CINFO, FCHECK, and the FDICT refusal — before any body byte, never a
/// silent skip of the DICTID the flag announces (`§2.3`, ZD3/ZD4). A header
/// cut short by the input's end is `Truncated`.
pub fn readHeader(header: *Header, input: *Io.Reader) HeaderError!void {
    var bytes: [header_len]u8 = undefined;
    try container.readExact(input, &bytes);
    try decode.checkHeader(bytes[0], bytes[1]);
    header.* = .parsed;
}

/// Verify the 4-byte trailer against the folded Adler-32 (`§2.2`, `§2.3`):
/// "the Adler-32 checksum of the uncompressed data (excluding any dictionary
/// data)", stored "in most-significant-byte first (network) order". RFC 1950
/// makes the check a decoder MUST: "A compliant decompressor must check CMF,
/// FLG, and ADLER32, and provide an error indication if any of these have
/// incorrect values" (`§2.3`).
pub fn checkTrailer(trailer: *const [trailer_len]u8, checksum: *const Checksum) TrailerError!void {
    return decode.checkTrailer(trailer, checksum.final());
}

/// Emit the deterministic 2-byte header (OQ7) into its exact pointer.
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
