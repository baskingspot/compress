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
const assert = std.debug.assert;

const flate = @import("../flate/root.zig");
const container = @import("../internal/container.zig");
const adler32 = @import("adler32.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");

/// Whether the inner codec implements `level` (flate's rule, re-exported):
/// 1 and 6 are implemented; every other level returns `error.Unimplemented`.
pub const levelImplemented = flate.encode.levelImplemented;

/// Encoder configuration. `.{}` is the default: level 1, no dictionary.
pub const Options = struct {
    /// The zlib-scale compression level: 1 or 6 (flate's implemented
    /// levels). Any other level selects `error.Unimplemented`.
    level: u8 = 1,
    /// The stream's preset dictionary or `null` (`§2.2`): on encode it sets
    /// FDICT and writes the Adler-32 of the whole slice as DICTID; on decode
    /// it is checked against the header's DICTID before any body byte.
    dict: ?[]const u8 = null,
};

/// The failure detail a `Reader` records in `err` once its state is
/// `.failed`: flate's reader errors (without `BufferTooSmall`, since the
/// decode window is fixed) plus this module's header and trailer errors.
pub const Error = flate.Reader.Error || error{
    BadHeader,
    DictionaryRequired,
    DictionaryMismatch,
    WrongChecksum,
};

/// The one-shot decoder's error set: flate's decode errors plus this module's
/// header and trailer errors. `BufferTooSmall` is flate's: the stream does not
/// fit the caller's `target`.
pub const DecompressError = flate.decode.DecompressError || error{
    BadHeader, // CM != 8, CINFO > 7, or FCHECK (§2.2, §2.3)
    DictionaryRequired, // FDICT set and no dictionary supplied (§2.3)
    DictionaryMismatch, // FDICT set and `dict`'s Adler-32 is not DICTID (§2.2)
    WrongChecksum, // ADLER32 mismatch (§2.2, §2.3)
};

/// The header check's own failures, plus `Truncated` and `ReadFailed` for
/// the input route: a header cut short by the input's end is `Truncated`.
pub const HeaderError = error{
    BadHeader,
    DictionaryRequired,
    DictionaryMismatch,
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

/// RFC 1950 §2.2 — the preset dictionary's identifier field: DICTID, the
/// dictionary's Adler-32 in MSB order, behind a set FDICT flag.
pub const dict_id_len = 4;

/// RFC 1950 §2.2 — the trailer's length: ADLER32.
pub const trailer_len = 4;

/// Wrap `input` with `buffer` as the inner flate reader's window, pre-seeded
/// with `dict`'s last 32 KiB when a dictionary is supplied.
pub fn initReader(
    input: *Io.Reader,
    buffer: *ReaderBuffer,
    dict: ?[]const u8,
) InnerReader {
    return flate.Reader.init(input, buffer, dict);
}

/// The stream's preset dictionary, or null when there is none: an empty slice
/// is no dictionary, the C reference's `PRESET_DICT` gate (`deflate.c` sets it
/// only when bytes were inserted), so `null` and `""` encode alike. On decode
/// the flag comes from the stream, and an empty dictionary is a dictionary
/// whose Adler-32 cannot match a real DICTID.
fn dictionary(options: Options) ?[]const u8 {
    const bytes = options.dict orelse return null;
    return if (bytes.len > 0) bytes else null;
}

/// Wrap `output` with `buffer` as the inner flate writer's window and
/// `options`' level and dictionary fixed for the stream's lifetime.
pub fn initWriter(output: *Io.Writer, buffer: *WriterBuffer, options: Options) InnerWriter {
    return flate.Writer.init(output, buffer, .{
        .level = options.level,
        .dict = dictionary(options),
    });
}

/// Whether the header has been checked.
pub fn headerDone(header: *const Header) bool {
    return header.* == .parsed;
}

/// Read and check the stream header (`§2.2`, `§2.3`): CM, CINFO, and FCHECK,
/// before any body byte. When FDICT is set the dictionary's identity is
/// checked next (`§2.2`): the 4-byte DICTID is the Adler-32 of the *whole*
/// dictionary in MSB order, and `dict` must supply those bytes — FDICT with
/// no dictionary is `DictionaryRequired` before the DICTID is even read, and a
/// dictionary whose Adler-32 is not the DICTID is `DictionaryMismatch`. RFC
/// 1950 §2.3 requires the error: "A compliant decompressor must give an error
/// indication if FDICT is set and DICTID is not the identifier of a known
/// preset dictionary." A header cut short by the end of the input is
/// `Truncated`.
pub fn readHeader(header: *Header, input: *Io.Reader, dict: ?[]const u8) HeaderError!void {
    var bytes: [header_len]u8 = undefined;
    try container.readExact(input, &bytes);
    try decode.checkHeader(bytes[0], bytes[1]);
    if (bytes[1] & decode.flg_fdict != 0) try decode.checkDictionary(input, dict);
    header.* = .parsed;
}

/// Verify the 4-byte trailer against the running Adler-32 (`§2.2`, `§2.3`);
/// see `decode.checkTrailer`.
pub fn checkTrailer(trailer: *const [trailer_len]u8, checksum: *const Checksum) TrailerError!void {
    return decode.checkTrailer(trailer, checksum.final());
}

/// Write the stream header for `options` into `target` and return its length:
/// the 2-byte CMF/FLG pair (`encode.writeHeader`, FDICT set exactly when a
/// non-empty dictionary is used), followed by the 4-byte DICTID when one is.
/// The shared driver sizes `target` to `header_len + dict_id_len`.
pub fn writeHeader(target: []u8, options: Options) usize {
    assert(target.len >= header_len + dict_id_len);
    const dict = dictionary(options);
    encode.writeHeader(target[0..header_len], options.level, dict != null);
    if (dict) |bytes| {
        encode.writeDictId(target[header_len..][0..dict_id_len], bytes);
        return header_len + dict_id_len;
    }
    return header_len;
}

/// Emit the 4-byte trailer — the Adler-32, big-endian (`§2.1`, `§2.2`) —
/// from the folded checksum state.
pub fn writeTrailer(target: *[trailer_len]u8, checksum: *const Checksum) void {
    encode.writeTrailer(target, checksum.final());
}

/// The deflate body through flate's one-shot encoder, with `options`'
/// dictionary as the window's preset history.
pub fn bodyCompress(
    source: []const u8,
    target: []u8,
    options: Options,
) error{ BufferTooSmall, Unimplemented }!usize {
    return flate.encode.compress(source, target, .{
        .level = options.level,
        .dict = dictionary(options),
    });
}

/// The worst-case deflate body length (flate's bound).
pub fn bodyMaxCompressedLength(input_len: usize) usize {
    return flate.encode.maxCompressedLength(input_len);
}
