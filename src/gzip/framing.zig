//! The gzip framing, as the shared container driver consumes it
//! (`src/internal/container.zig`): the member header, the trailer, the
//! CRC-32 state, and the error sets, bound to flate's streaming types. The
//! module's `Reader`/`Writer`/`encode`/`decode` instantiate the driver over
//! this type; it is not part of the public surface (the barrel exposes the
//! four namespaces, never this file).
//!
//! The contract is stated in full at `src/internal/container.zig`; the
//! functions here are the gzip halves — the byte-fed header parser
//! (`decode.HeaderParser`), the CRC-32 trailer check (`decode.checkTrailer`),
//! the deterministic emissions (`encode.writeHeader`/`writeTrailer`), and
//! flate's one-shot body.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const flate = @import("../flate/root.zig");
const crc32 = @import("crc32.zig");
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
    HeaderTooLong,
    WrongHeaderChecksum,
    WrongChecksum,
    WrongSize,
};

/// The one-shot decoder's error set (README, "API"): flate's decode detail
/// set plus this module's header and trailer entries. `BufferTooSmall` is
/// flate's (a member that does not fit the caller's cap).
pub const DecompressError = flate.decode.DecompressError || error{
    BadHeader, // ID1/ID2/CM wrong, or a reserved FLG bit (§2.3.1.2)
    HeaderTooLong, // FNAME/FCOMMENT past the 512-byte cap (T7)
    WrongHeaderChecksum, // FHCRC mismatch (§2.3.1)
    WrongChecksum, // CRC32 mismatch (§2.3.1)
    WrongSize, // ISIZE mismatch (§2.3.1)
};

/// The header parse's own failures, plus `Truncated` and `ReadFailed` for
/// the input route: a header cut short by the input's end is `Truncated`.
pub const HeaderError = error{
    BadHeader,
    HeaderTooLong,
    WrongHeaderChecksum,
    Truncated,
    ReadFailed,
};

/// The trailer's own failures, plus `Truncated` and `ReadFailed` for the
/// input route.
pub const TrailerError = error{
    Truncated,
    ReadFailed,
    WrongChecksum,
    WrongSize,
};

/// The container's checksum state folded through flate's hook: CRC-32 over
/// the decoded bytes and the decoded length mod 2^32, the trailer's ISIZE
/// (`§2.3.1`).
pub const Checksum = crc32.Checksum;

/// The header parse state (`§2.3.1`), run once, before the first body byte.
pub const Header = decode.HeaderParser;

/// The caller-provided window: flate's, re-exported — the container adds no
/// buffer of its own (OQ6). `[2 * history_len]u8`, 64 KiB.
pub const ReaderBuffer = flate.Reader.Buffer;

/// The caller-provided buffer: flate's, re-exported — the container adds no
/// buffer of its own (OQ6). `[max_block_size + history_len]u8`, 98303 bytes.
pub const WriterBuffer = flate.Writer.Buffer;

/// The inner codec's streaming types, as the driver reads them.
pub const InnerReader = flate.Reader;
pub const InnerWriter = flate.Writer;

/// RFC 1952 §2.3 — the fixed header's length.
pub const header_len = 10;

/// RFC 1952 §2.3.1 — the trailer's length.
pub const trailer_len = 8;

/// The writer's serving region: flate's block size (the front region of the
/// caller's `Writer.Buffer`).
pub const writer_region_len = flate.encode.max_block_size;

/// Wrap `input` with `buffer` as the inner flate reader's window.
pub fn initReader(input: *Io.Reader, buffer: *ReaderBuffer) InnerReader {
    return flate.Reader.init(input, buffer);
}

/// Wrap `output` with `buffer` as the inner flate writer's window and
/// `options`' level fixed for the member's lifetime.
pub fn initWriter(output: *Io.Writer, buffer: *WriterBuffer, options: Options) InnerWriter {
    return flate.Writer.init(output, buffer, .{ .level = options.level });
}

/// Whether the header is complete.
pub fn headerDone(header: *const Header) bool {
    return header.done();
}

/// Parse the member header from `input` (`§2.3.1`), feeding the parser from
/// the input's buffered bytes and consuming them as it goes: the optional
/// fields are skipped streaming, never staged (T7, OQ6). A header cut short
/// by the input's end is `Truncated`.
pub fn readHeader(header: *Header, input: *Io.Reader) HeaderError!void {
    while (!header.done()) {
        input.fill(1) catch |err| switch (err) {
            error.EndOfStream => return error.Truncated,
            error.ReadFailed => return error.ReadFailed,
        };
        const buffered = input.buffer[input.seek..input.end];
        const consumed = try header.feed(buffered);
        // `feed` consumes at least one byte while the header is incomplete,
        // so the loop always progresses (or fails).
        assert(consumed > 0);
        input.toss(consumed);
    }
}

/// Verify the 8-byte trailer against the folded checksum state (`§2.3.1`):
/// CRC-32 (ISO 3309) and ISIZE, the input size mod 2^32, both u32
/// little-endian (`§2.1`). The two are kept separate — Go collapses both
/// into `ErrChecksum` (`gunzip.go:267`); ours report which half failed (T4).
pub fn checkTrailer(trailer: *const [trailer_len]u8, checksum: *const Checksum) TrailerError!void {
    return decode.checkTrailer(trailer, checksum.final(), checksum.len);
}

/// Emit the deterministic 10-byte header (OQ7) into its exact pointer.
pub fn writeHeader(target: *[header_len]u8, level: Level) void {
    encode.writeHeader(target, level);
}

/// Emit the 8-byte trailer — CRC-32 and ISIZE, both u32 little-endian
/// (`§2.1`, `§2.3.1`) — from the folded checksum state.
pub fn writeTrailer(target: *[trailer_len]u8, checksum: *const Checksum) void {
    encode.writeTrailer(target, checksum.final(), checksum.len);
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
