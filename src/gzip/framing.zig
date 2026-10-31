//! The gzip framing as the shared container driver consumes it
//! (`src/internal/container.zig`): the member header, the trailer, the CRC-32
//! state, and the error sets, bound to flate's streaming types. `Reader`,
//! `Writer`, `encode`, and `decode` instantiate the driver over this type. It
//! is not part of the public surface.
//!
//! `src/internal/container.zig` documents what a framing type must provide.
//! The functions here are gzip's half: the byte-fed header parser
//! (`decode.HeaderParser`), the trailer check (`decode.checkTrailer`), the
//! header and trailer writers (`encode.writeHeader`, `encode.writeTrailer`),
//! and flate's one-shot body.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const flate = @import("../flate/root.zig");
const crc32 = @import("crc32.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");

/// The inner codec's compression levels (flate's type, re-exported).
pub const Level = flate.encode.Level;

/// Encoder configuration. `.{}` is the default: level 1.
// ast-grep-ignore: public-struct-field-default -- options bag: call sites override one knob
pub const Options = struct {
    /// The compression level.
    level: Level = .@"1",
};

/// The failure detail a reader records in `err` once its state is `.failed`:
/// flate's reader errors plus the header and trailer errors below. There is no
/// `BufferTooSmall`: output goes through a fixed window, not a sized target.
pub const Error = InnerReader.Error || error{
    BadHeader,
    HeaderTooLong,
    WrongHeaderChecksum,
    WrongChecksum,
    WrongSize,
};

/// The one-shot decoder's errors: flate's `DecompressError` plus the header
/// and trailer errors below. `BufferTooSmall` (flate's) means the decoded
/// member does not fit the caller's `target`.
pub const DecompressError = flate.decode.DecompressError || error{
    BadHeader, // ID1/ID2/CM wrong, or a reserved FLG bit (§2.3.1.2)
    HeaderTooLong, // FNAME/FCOMMENT over the 512-byte cap
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

/// The checksum state: the CRC-32 and the length mod 2^32 (the trailer's
/// ISIZE, `§2.3.1`) of the uncompressed bytes, folded in as they pass through
/// flate's checksum hook.
pub const Checksum = crc32.Checksum;

/// The header parse state (`§2.3.1`), run once, before the first body byte.
pub const Header = decode.HeaderParser;

/// A header parse before its first byte: the shared driver's initial seat.
pub const reader_header_init: Header = .init;

/// The caller-provided decode window: flate's `Reader.Buffer`, 64 KiB
/// (`[2 * history_len]u8`). gzip adds no buffer of its own.
pub const ReaderBuffer = InnerReader.Buffer;

/// The caller-provided encode buffer: flate's `Writer.Buffer`, 98303 bytes
/// (`[max_block_size + history_len]u8`). gzip adds no buffer of its own.
pub const WriterBuffer = InnerWriter.Buffer;

/// The inner codec's streaming types, as the driver reads them.
pub const InnerReader = flate.Reader;
pub const InnerWriter = flate.Writer;

/// RFC 1952 §2.3 — the fixed header's length.
pub const header_len = 10;

/// gzip has no dictionary concept (RFC 1952 has no FDICT-equivalent field),
/// so there is no dictionary identifier field. The shared driver still hands
/// the container's preset dictionary to `initReader` and `readHeader`; both
/// ignore it, and gzip's reader carries the driver's `dict` field as null.
pub const dict_id_len = 0;

/// RFC 1952 §2.3.1 — the trailer's length.
pub const trailer_len = 8;

/// Wrap `input` with `buffer` as the inner flate reader's window.
pub fn initReader(
    input: *Io.Reader,
    buffer: *ReaderBuffer,
    dict: ?[]const u8,
) InnerReader {
    return InnerReader.init(input, buffer, dict);
}

/// Wrap `output` with `buffer` as the inner flate writer's window and
/// `options`' level fixed for the member's lifetime.
pub fn initWriter(output: *Io.Writer, buffer: *WriterBuffer, options: Options) InnerWriter {
    return InnerWriter.init(output, buffer, .{ .level = options.level });
}

/// Whether the header is complete.
pub fn headerDone(header: *const Header) bool {
    return header.done();
}

/// Parse the member header from `input` (`§2.3.1`), feeding the parser from
/// the input's buffered bytes and consuming them as it goes. The optional
/// fields are skipped as they stream past, never stored. A header cut short
/// by the end of the input is `Truncated`.
pub fn readHeader(header: *Header, input: *Io.Reader, dict: ?[]const u8) HeaderError!void {
    _ = dict; // gzip has no dictionary concept (RFC 1952 §2.3.1)
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
/// little-endian (`§2.1`). `WrongChecksum` and `WrongSize` are separate
/// errors so the caller learns which half failed (Go reports one error).
pub fn checkTrailer(trailer: *const [trailer_len]u8, checksum: *const Checksum) TrailerError!void {
    return decode.checkTrailer(trailer, checksum.final(), checksum.len);
}

/// Write the fixed 10-byte header (`encode.writeHeader`) into `target` and
/// return its length. The shared driver sizes `target` to `header_len +
/// dict_id_len`; gzip has no dictionary, so it is always 10 bytes.
pub fn writeHeader(target: []u8, options: Options) usize {
    assert(target.len >= header_len);
    encode.writeHeader(target[0..header_len], options.level);
    return header_len;
}

/// Write the 8-byte trailer (CRC-32, then ISIZE; both u32 little-endian,
/// `§2.1`, `§2.3.1`) from the folded checksum state.
pub fn writeTrailer(target: *[trailer_len]u8, checksum: *const Checksum) void {
    encode.writeTrailer(target, checksum.final(), checksum.len);
}

/// The deflate body through flate's one-shot encoder.
pub fn bodyCompress(
    source: []const u8,
    target: []u8,
    options: Options,
) error{BufferTooSmall}!usize {
    return flate.encode.compress(source, target, .{ .level = options.level });
}

/// The worst-case deflate body length (flate's bound).
pub fn bodyMaxCompressedLength(input_len: usize) usize {
    return flate.encode.maxCompressedLength(input_len);
}
