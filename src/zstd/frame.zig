//! The frame layer of a Zstandard stream (`§3.1`): the Magic_Number, the
//! Frame_Header, the block chain, the XXH64 Content_Checksum trailer, and
//! skippable frames.
//!
//! `classify` tells a Zstandard frame from a skippable frame (`§3.1.2`) or
//! garbage (`BadMagic`). `HeaderParser` parses the Frame_Header incrementally,
//! so a streaming reader can feed it across reads; `parseHeader` is the
//! whole-slice form. `State` is one frame's decode state. The one-shot decoder
//! runs `classify`, `parseHeader`, `State.init`, `State.decodeBlock` until
//! `last_block`, `State.checkContentSize`, and `State.verifyTrailer` when the
//! header sets the checksum flag. The streaming reader runs the same steps but
//! calls `block.decodeContent` and `State.recordBlock` itself, because its
//! output window slides. `window` holds the Window_Size arithmetic; how large a
//! window to accept is the caller's call (`checkWindow`).
//!
//! Format: docs/research/specs/rfc8878-zstd.txt

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const block = @import("block.zig");
const common = @import("common.zig");
const golden = @import("golden.zig");
const internal = @import("../internal/root.zig");
const literals = @import("literals.zig");
const sequences = @import("sequences.zig");
const xxh64 = @import("xxh64.zig");

/// Everything the frame layer reports: the block layer's composed set plus
/// this layer's own names. `zstd.decode.DecompressError` is this set, name
/// for name (`decode.zig` asserts it at comptime). `WindowTooLarge` is not in
/// it: only a caller with its own window limit (`checkWindow`) can raise that.
pub const Error = error{
    /// `§3.1`, `§3.1.2` — the 4-byte Magic_Number is neither the Zstandard
    /// magic nor one of the 16 skippable magics.
    BadMagic,
    /// `§3.1.1.1.1.4` — descriptor bit 3: "Its value must be zero. A decoder
    /// compliant with this specification version must ensure it is not set."
    ReservedBitSet,
    /// `§3.1.1.1.3`, `§5` — Dictionary_ID_Flag is set: the frame needs a
    /// dictionary this decoder does not have. Raised at the first
    /// Dictionary_ID byte, before any body byte; the ID is never skipped or
    /// interpreted.
    DictionaryRequired,
    /// `§3.1.1.1.4` — Frame_Content_Size against the frame's actual decoded
    /// total: a running bound (`recordBlock`, `§8`'s smaller-than-actual
    /// vector) and a frame-end check (`checkContentSize`).
    ContentSizeMismatch,
    /// `§3.1.1` — the Content_Checksum trailer does not match the XXH64 of the
    /// decoded bytes. A trailer that is present is always verified, although
    /// `§2` allows a decoder to ignore it.
    WrongChecksum,
} || block.Error;

/// `§3.1.1` — "Magic_Number: 4 bytes, little-endian format. Value:
/// 0xFD2FB528."
pub const magic: u32 = 0xFD2F_B528;

/// `§3.1.2` — "Magic_Number: 4 bytes, little-endian format. Value:
/// 0x184D2A5?, which means any value from 0x184D2A50 to 0x184D2A5F. All 16
/// values are valid to identify a skippable frame."
pub const skippable_magic_base: u32 = 0x184D_2A50;
/// The skippable magic's low four bits carry the frame's tag; the rest must
/// match `skippable_magic_base`.
pub const skippable_magic_mask: u32 = 0xFFFF_FFF0;

/// The Magic_Number's 4 bytes (`§3.1.1`, `§3.1.2`).
pub const magic_len = 4;
/// The skippable Frame_Size's 4 bytes (`§3.1.2`): "the size, in bytes, of the
/// following User_Data (without including the magic number nor the size field
/// itself)".
pub const frame_size_len = 4;
/// `§3.1.1` — "Content_Checksum: ... 4 bytes" ("The low 4 bytes of the
/// checksum are stored in little-endian format").
pub const checksum_len = 4;

/// What a frame unit's Magic_Number identifies (`§3.1`): a Zstandard frame
/// (compressed data) or a skippable frame (user metadata).
pub const Kind = enum { zstandard, skippable };

/// Classify the 4 bytes at the front of `source` (`§3.1`, `§3.1.2`): the
/// Zstandard frame magic, one of the 16 skippable magics, or `BadMagic`.
/// Fewer than 4 bytes is the input's end, `Truncated`. The one-shot and the
/// streaming reader both classify through this, so they agree on what a frame
/// is.
pub fn classify(source: []const u8) error{ BadMagic, Truncated }!Kind {
    if (source.len < magic_len) return error.Truncated;
    const value = common.readInt(u32, source[0..magic_len]);
    if (value == magic) return .zstandard;
    if (value & skippable_magic_mask == skippable_magic_base) return .skippable;
    return error.BadMagic;
}

/// `§3.1.1.1.2`'s Window_Size arithmetic: the four formulas a frame's window is
/// computed from. Every descriptor byte parses, so the formulas cannot fail;
/// the limit on what a caller accepts is `checkWindow`'s.
pub const window = struct {
    /// `windowLog = 10 + Exponent` — 10 to 41.
    pub fn windowLog(exponent: u5) u6 {
        return @as(u6, exponent) + 10;
    }

    /// `windowBase = 1 << windowLog`.
    pub fn windowBase(exponent: u5) u64 {
        return @as(u64, 1) << windowLog(exponent);
    }

    /// `windowAdd = (windowBase / 8) * Mantissa`.
    pub fn windowAdd(exponent: u5, mantissa: u3) u64 {
        return (windowBase(exponent) / 8) * mantissa;
    }

    /// `Window_Size = windowBase + windowAdd`, from the Window_Descriptor
    /// byte (`§3.1.1.1.2`, Table 6: bits 7-3 Exponent, bits 2-0 Mantissa).
    pub fn size(byte: u8) u64 {
        const exponent: u5 = @truncate(byte >> 3);
        const mantissa: u3 = @truncate(byte);
        return windowBase(exponent) + windowAdd(exponent, mantissa);
    }

    /// The Window_Descriptor byte declaring a window of exactly
    /// `1 << window_log` bytes (`§3.1.1.1.2`): the exponent in bits 7-3,
    /// mantissa 0 in bits 2-0. `size` of the result is that window, which
    /// the comptime check below pins for every encodable `window_log`.
    /// The format's Window_Log is 10 to 41; an encoder that declares
    /// `1 << window_log` with a nonzero mantissa would declare more than it
    /// retains, so the mantissa stays 0.
    pub fn descriptor(window_log: u6) u8 {
        assert(window_log >= 10);
        return @as(u8, window_log - 10) << 3;
    }

    /// `§3.1.1.1.2` — "The minimum Window_Size is 1 KB."
    pub const min_size: u64 = 1 << 10;
    /// `§3.1.1.1.2` — "The maximum Window_Size is (1<<41) + 7*(1<<38) bytes,
    /// which is 3.75 TB."
    pub const max_size: u64 = (1 << 41) + 7 * (1 << 38);
};

// The formulas' extremes, pinned at comptime: the descriptor's all-zero and
// all-one bytes must land exactly on the spec's stated minimum and maximum.
comptime {
    assert(window.size(0x00) == window.min_size);
    assert(window.size(0xff) == window.max_size);
    assert(window.windowLog(0) == 10);
    assert(window.windowLog(31) == 41);
    // `descriptor` is `size`'s inverse for a mantissa of 0: the byte an
    // encoder writes for `1 << window_log` parses back to that window.
    for (10..32) |window_log| {
        assert(window.size(window.descriptor(window_log)) == @as(u64, 1) << window_log);
    }
}

/// The Frame_Header_Descriptor's fields (`§3.1.1.1.1`, Table 3).
pub const descriptor_fcs_flag_mask: u8 = 0xc0;
pub const descriptor_single_segment: u8 = 0x20;
pub const descriptor_unused: u8 = 0x10;
pub const descriptor_reserved: u8 = 0x08;
pub const descriptor_checksum: u8 = 0x04;
pub const descriptor_dictionary_flag_mask: u8 = 0x03;

/// `§3.1.1.1.1.1`, Table 4 — FCS_Field_Size from the descriptor: 1 when
/// Frame_Content_Size_Flag is 0 and Single_Segment_Flag is set, 0 when the
/// flag is 0 and it is not, else 2 / 4 / 8.
pub fn fcsFieldSize(descriptor: u8) usize {
    const flag: u2 = @truncate((descriptor & descriptor_fcs_flag_mask) >> 6);
    return switch (flag) {
        0 => if (descriptor & descriptor_single_segment != 0) 1 else 0,
        1 => 2,
        2 => 4,
        3 => 8,
    };
}

/// `§3.1.1.1.1.6`, Table 5 — DID_Field_Size from the descriptor.
pub fn didFieldSize(descriptor: u8) usize {
    const flag: u2 = @truncate(descriptor & descriptor_dictionary_flag_mask);
    return switch (flag) {
        0 => 0,
        1 => 1,
        2 => 2,
        3 => 4,
    };
}

/// A parsed Frame_Header (`§3.1.1.1`, Table 2): the descriptor's fields and
/// the two sizes they imply.
pub const Header = struct {
    /// The raw Frame_Header_Descriptor byte (`§3.1.1.1.1`, Table 3), kept
    /// whole so every bit's provenance stays visible at the call site.
    descriptor: u8,
    /// `§3.1.1.1.2` — Window_Size: the window arithmetic's value, or
    /// Frame_Content_Size itself when Single_Segment_Flag is set.
    window_size: u64,
    /// `§3.1.1.1.4` — Frame_Content_Size; `null` when FCS_Field_Size is 0.
    /// Single_Segment_Flag makes it necessarily present. It is only checked
    /// against the decoded length (`State.recordBlock`,
    /// `State.checkContentSize`), never used to size anything.
    content_size: ?u64,
    /// `§3.1.1.1.1.5` — Content_Checksum_Flag: the 4-byte trailer.
    checksum: bool,
    /// The Frame_Header's length, 2-14 bytes (`§3.1.1.1`): the descriptor
    /// plus its optional fields. The block chain starts here.
    bytes_consumed: usize,
};

/// The Frame_Header parser (`§3.1.1.1`, Table 2): a state machine fed bytes in
/// field order (the descriptor, the Window_Descriptor, the Dictionary_ID, the
/// Frame_Content_Size). It stages nothing, since the header is at most 14 bytes
/// and each field accumulates in its own scalar, so a reader whose input
/// buffer holds only the magic's 4 bytes can still parse the header across
/// reads. `parseHeader` drives it over a whole slice.
pub const HeaderParser = struct {
    stage: Stage = .descriptor,
    /// The Frame_Header_Descriptor byte, once read.
    descriptor: u8 = 0,
    /// The current field's bytes consumed so far, and its little-endian
    /// value (the Window_Descriptor's one byte, the FCS's up to eight).
    taken: usize = 0,
    value: u64 = 0,
    /// The two sizes the header implies; 0 / `null` until their fields are
    /// complete.
    window_size: u64 = 0,
    content_size: ?u64 = null,
    /// The Frame_Header's bytes consumed (`§3.1.1.1`: 2-14).
    total: usize = 0,

    /// The field being consumed, in Table 2's order.
    pub const Stage = enum { descriptor, window, dictionary, fcs, done };

    /// Whether the header is complete.
    pub fn done(parser: *const HeaderParser) bool {
        return parser.stage == .done;
    }

    /// The parsed header. Only legal once `done`.
    pub fn header(parser: *const HeaderParser) Header {
        assert(parser.done());
        return .{
            .descriptor = parser.descriptor,
            .window_size = parser.window_size,
            .content_size = parser.content_size,
            .checksum = parser.descriptor & descriptor_checksum != 0,
            .bytes_consumed = parser.total,
        };
    }

    /// Feed `bytes` to the parser and return the bytes consumed. The parser
    /// consumes as much as the current field needs; a caller with more input
    /// feeds again (the streaming route), and a caller holding the whole
    /// header feeds once. Every stage of a non-empty slice either consumes a
    /// byte or fails, so a driver always makes progress. The input ending
    /// inside the header is the driver's `Truncated`: the parser is just not
    /// `done` yet. Fails with `ReservedBitSet` or `DictionaryRequired`.
    pub fn feed(parser: *HeaderParser, bytes: []const u8) Error!usize {
        var consumed: usize = 0;
        while (consumed < bytes.len and parser.stage != .done) {
            consumed += try parser.step(bytes[consumed..]);
        }
        return consumed;
    }

    /// One field's worth of progress; `bytes` is non-empty.
    fn step(parser: *HeaderParser, bytes: []const u8) Error!usize {
        assert(bytes.len > 0);
        switch (parser.stage) {
            .descriptor => {
                // §3.1.1.1.1.4 — "Its value must be zero. A decoder
                // compliant with this specification version must ensure it
                // is not set." Bit 4 is deliberately not tested: "shall not
                // interpret this bit" (§3.1.1.1.1.3).
                if (bytes[0] & descriptor_reserved != 0) return error.ReservedBitSet;
                parser.descriptor = bytes[0];
                parser.total += 1;
                // §3.1.1.1.2 — "The Window_Descriptor byte is optional.
                // When Single_Segment_Flag is set, Window_Descriptor is not
                // present."
                parser.stage = if (bytes[0] & descriptor_single_segment == 0)
                    .window
                else
                    parser.afterWindow();
                return 1;
            },
            .window => {
                parser.window_size = window.size(bytes[0]);
                parser.total += 1;
                parser.stage = parser.afterWindow();
                return 1;
            },
            .dictionary => {
                // §3.1.1.1.3 + §5 — the frame references a dictionary. The
                // refusal lands at the first Dictionary_ID byte, before any
                // body byte, and no byte of the ID is interpreted.
                return error.DictionaryRequired;
            },
            .fcs => {
                const need = fcsFieldSize(parser.descriptor);
                assert(need > 0);
                const take = @min(need - parser.taken, bytes.len);
                for (bytes[0..take], 0..) |byte, index| {
                    parser.value |= @as(u64, byte) << @intCast(8 * (parser.taken + index));
                }
                parser.taken += take;
                parser.total += take;
                if (parser.taken < need) return take;
                // §3.1.1.1.4 — "When FCS_Field_Size is 2, the offset of 256
                // is added"; 1, 4, and 8 bytes are read directly.
                parser.content_size = if (need == 2) parser.value + 256 else parser.value;
                // §3.1.1.1.2 — "In this case, Window_Size is
                // Frame_Content_Size."
                if (parser.descriptor & descriptor_single_segment != 0) {
                    parser.window_size = parser.content_size.?;
                }
                parser.stage = .done;
                return take;
            },
            .done => unreachable,
        }
    }

    /// The stage after the descriptor or the Window_Descriptor: the
    /// Dictionary_ID when the flag is set, else the Frame_Content_Size when
    /// one is present, else the header is done.
    fn afterWindow(parser: *const HeaderParser) Stage {
        if (parser.descriptor & descriptor_dictionary_flag_mask != 0) return .dictionary;
        if (fcsFieldSize(parser.descriptor) > 0) return .fcs;
        return .done;
    }
};

/// Parse a whole Frame_Header from the front of `source`, the bytes *after*
/// the Magic_Number (`§3.1.1.1`). The streaming reader drives `HeaderParser`
/// directly instead. Fewer bytes than the header needs is the input's end:
/// `Truncated`. The parser's own errors are `ReservedBitSet` and
/// `DictionaryRequired`.
pub fn parseHeader(source: []const u8) Error!Header {
    var parser: HeaderParser = .{};
    const consumed = try parser.feed(source);
    if (!parser.done()) return error.Truncated;
    assert(consumed <= source.len);
    return parser.header();
}

/// `§3.1.1.1.2` — "a decoder is allowed to reject a compressed frame that
/// requests a memory size beyond the decoder's authorized range": the
/// streaming reader's cap, checked once the header is parsed and before any
/// block byte is read. The one-shot applies no cap — its history is `target`
/// itself — so `WindowTooLarge` is not in `zstd.decode.DecompressError`.
pub fn checkWindow(header: Header, max_window_size: u64) error{WindowTooLarge}!void {
    if (header.window_size > max_window_size) return error.WindowTooLarge;
}

/// One frame's decode state, kept across its blocks: the parsed header, the
/// literals and sequences layers' cross-block states, the decoded length so
/// far, and the checksum.
///
/// `recordBlock` is where decoded bytes reach the checksum — handed exactly
/// the bytes each block wrote, in order — except Raw blocks, whose bytes the
/// copy folds chunk by chunk while they are cache-hot (`block.decodeContent`;
/// those record with `recordRawBlock`). Either way each byte is folded once,
/// in order.
pub const State = struct {
    /// The parsed Frame_Header (`§3.1.1.1`).
    header: Header,
    /// The Huffman tree a Treeless_Literals_Block reuses (`§3.1.1.3`), one
    /// per frame.
    literals: literals.State = .{},
    /// The three decoding tables and the repeat offsets a Repeat_Mode reuses
    /// (`§3.1.1.3`, `§3.1.1.5`), one per frame.
    sequences: sequences.State = .{},
    /// `§3.1.1` — the decoded bytes' XXH64, folded per block. A frame without
    /// the checksum flag folds nothing, since nothing will be verified.
    checksum: xxh64.State = .{},
    /// The frame's decoded length so far: the block layer's `decoded_len` on
    /// the one-shot's contiguous path, and the running total that
    /// Frame_Content_Size is checked against (`§3.1.1.1.4`) everywhere. A
    /// `u64`, not a `usize`: a frame's output has no `usize` bound (about
    /// 131 KB of RLE blocks decodes to over 4 GiB), so the total must not wrap
    /// on 32-bit targets, where a wrap would panic in safe builds and be
    /// undefined behavior in ReleaseFast. Hostile input gets an error, never a
    /// crash.
    decoded_len: u64 = 0,

    /// Start a new frame in `state`, initializing it in place. A `State` is
    /// about 16 KiB, mostly decoding-table payload that stays undefined until a
    /// block builds it. Returning one by value copied the whole aggregate,
    /// undefined payload included, which was a measurable cost on 32-64 KiB
    /// frames.
    pub fn init(state: *State, header: Header) void {
        state.header = header;
        state.literals.has_table = false;
        state.sequences.tables = @splat(null);
        state.sequences.repeat_offsets = sequences.repeat_offsets_start;
        state.checksum = .{};
        state.decoded_len = 0;
    }

    /// Decode one block from the front of `source` (its Block_Header) into
    /// `target` and record its output. This is the one-shot's step:
    /// `target[0..decoded_len]` is the frame's output so far, so the frame's
    /// decoded length is also the block's position in `target`. Returns the
    /// errors of `block.decode`, plus `ContentSizeMismatch` from the record.
    ///
    /// The streaming reader's output window slides, so it does not use this.
    /// It parses the Block_Header itself, stages the content, calls
    /// `block.decodeContent` with the length it has retained, and then calls
    /// `recordBlock`.
    pub fn decodeBlock(state: *State, source: []const u8, target: []u8) Error!block.Section {
        const header = try block.parseHeader(source);
        // A Raw block's bytes reach the checksum inside the copy (see
        // `block.decodeContent`), so it records with `recordRawBlock`.
        const checksum: ?*xxh64.State = if (state.header.checksum) &state.checksum else null;
        const written = try block.decodeContent(
            header,
            source[block.block_header_len..],
            target,
            // The one-shot's target is the caller-bounded history, so the
            // running total is bounded by target.len: the usize the block
            // layer's history accounting takes.
            @intCast(state.decoded_len),
            state.header.window_size,
            &state.literals,
            &state.sequences,
            checksum,
        );
        if (header.block_type == .raw) {
            try state.recordRawBlock(written);
        } else {
            // The output slice is taken with the pre-call `decoded_len`: the
            // bytes this block just wrote, which `recordBlock` then folds
            // and counts.
            const output = target[@intCast(state.decoded_len)..][0..written];
            try state.recordBlock(output);
        }
        return .{
            .bytes_written = written,
            .bytes_consumed = block.block_header_len + block.contentLength(header),
            .last_block = header.last_block,
        };
    }

    /// Record a Raw block, whose output the copy already folded into the
    /// checksum chunk by chunk (`block.decodeContent`): only the accounting
    /// remains — the decoded total and the Frame_Content_Size running bound.
    pub fn recordRawBlock(state: *State, bytes_written: usize) error{ContentSizeMismatch}!void {
        state.decoded_len += bytes_written;
        if (state.header.content_size) |declared| {
            if (state.decoded_len > declared) return error.ContentSizeMismatch;
        }
    }

    /// Record one decoded block: fold its output into the checksum (when the
    /// frame has one), add its length to the decoded total, and enforce
    /// Frame_Content_Size as a running bound. Raw blocks are the exception:
    /// their fold rides the copy (`block.decodeContent`), so they record
    /// with `recordRawBlock`. A frame that has produced more
    /// bytes than it declared fails at that block with `ContentSizeMismatch`,
    /// so a header that understates the size cannot keep the frame decoding
    /// until its end (`§3.1.1.1.4`, `§8`'s smaller-than-actual vector).
    ///
    /// `output` is exactly the bytes the block just wrote, taken with the
    /// length that block call used: `target[decoded_len..][0..bytes_written]`
    /// for the one-shot, `serving[retained_len..][0..bytes_written]` for the
    /// streaming reader. Call it once per block, in order.
    pub fn recordBlock(state: *State, output: []const u8) error{ContentSizeMismatch}!void {
        if (state.header.checksum) state.checksum.update(output);
        state.decoded_len += output.len;
        if (state.header.content_size) |declared| {
            if (state.decoded_len > declared) return error.ContentSizeMismatch;
        }
    }

    /// The frame end's check (`§3.1.1.1.4`): Frame_Content_Size against the
    /// frame's actual decoded total. `recordBlock` catches the running
    /// overshoot; this catches a frame that stopped short of what it declared.
    pub fn checkContentSize(state: *const State) error{ContentSizeMismatch}!void {
        if (state.header.content_size) |declared| {
            if (state.decoded_len != declared) return error.ContentSizeMismatch;
        }
    }

    /// The frame end's trailer step (`§3.1.1`, `§3.1.1.1.1.5`): compare the
    /// 4-byte Content_Checksum against the digest folded so far ("The low 4
    /// bytes of the checksum are stored in little-endian format") and return
    /// `WrongChecksum` on a mismatch.
    ///
    /// The caller calls this only when the header's checksum flag is set (a
    /// frame without the flag has no trailer and folded nothing), and passes
    /// exactly `checksum_len` bytes. Input that ends before the trailer is the
    /// caller's `Truncated`. A decode that fails earlier never gets here, so it
    /// reports the decode's error, not the checksum's. `state` is a mutable
    /// pointer only because `xxh64.State.final` takes one; verifying does not
    /// change the digest.
    pub fn verifyTrailer(state: *State, trailer: []const u8) error{WrongChecksum}!void {
        assert(state.header.checksum);
        assert(trailer.len == checksum_len);
        if (common.readInt(u32, trailer[0..checksum_len]) != state.checksum.final()) {
            return error.WrongChecksum;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc8878-zstd.txt §3.1 (the frame), §3.1.1
// (the header, the checksum), §3.1.1.1.1-§3.1.1.1.4 (the descriptor and its
// fields), §3.1.1.2 (the block chain), §3.1.2 (skippable frames). The
// fixture frames are `golden.zig`'s, each verified by the pinned zstd v1.5.7
// (the CLI decodes the good ones byte-exact and exits 1 on the negative
// corners).
// ---------------------------------------------------------------------------

/// Walk a whole fixture frame the way the one-shot does, one layer down: the
/// magic, the header, the block chain through `State`, and the trailer. The
/// fixture is the frame unit entire, so the walk must land exactly on its
/// end. `progress` records the decoded length after the last block that
/// succeeded, so a failing walk can prove nothing past it was written.
fn decodeFrame(bytes: []const u8, target: []u8, progress: *usize) !usize {
    progress.* = 0;
    try testing.expectEqual(Kind.zstandard, try classify(bytes));
    const header = try parseHeader(bytes[magic_len..]);
    var state: State = undefined;
    state.init(header);
    var cursor = magic_len + header.bytes_consumed;
    while (true) {
        const section = state.decodeBlock(bytes[cursor..], target) catch |err| {
            // A post-write check, Frame_Content_Size's running bound, fails
            // after the block was written, so the sentinel's floor is the
            // frame's decoded length, not the last successful block's. The
            // walk's target bounds the frame's output, so the u64 total always
            // fits the usize this test helper tracks.
            progress.* = @intCast(state.decoded_len);
            return err;
        };
        cursor += section.bytes_consumed;
        progress.* = @intCast(state.decoded_len);
        if (section.last_block) break;
    }
    try state.checkContentSize();
    // §3.1.1 — the frame ends at the last block's last byte, or at the
    // Content_Checksum trailer's when the flag is set.
    if (header.checksum) {
        if (bytes.len - cursor < checksum_len) return error.Truncated;
        try state.verifyTrailer(bytes[cursor..][0..checksum_len]);
        cursor += checksum_len;
    }
    try testing.expectEqual(bytes.len, cursor);
    // The helper's target bounds the frame's output, so the u64 total fits.
    return @intCast(state.decoded_len);
}

/// Decode a fixture frame and check its output, with the sentinel overrun
/// check every decode test runs.
fn expectFrame(bytes: []const u8, expected: []const u8) !void {
    var target: [300 * 1024]u8 = undefined;
    internal.sentinel.fill(&target);
    var progress: usize = 0;
    const written = try decodeFrame(bytes, &target, &progress);
    try golden.expectDecoded(&target, written, expected);
}

/// Walk a fixture frame expecting `err`, proving the failure came before the
/// offending write: the bytes past what the blocks that did decode wrote are
/// untouched.
fn expectFrameError(err: Error, bytes: []const u8) !void {
    var target: [300 * 1024]u8 = undefined;
    internal.sentinel.fill(&target);
    var progress: usize = 0;
    if (decodeFrame(bytes, &target, &progress)) |_| {
        return error.TestExpectedError;
    } else |actual| {
        try testing.expectEqual(err, actual);
        try internal.sentinel.expect(&target, progress);
    }
}

test "classify reads §3.1's two magic families" {
    // RFC 8878 §3.1 — "The Magic_Number is 0xFD2FB528", little-endian; §3.1.2
    // — "Value: 0x184D2A5?, which means any value from 0x184D2A50 to
    // 0x184D2A5F. All 16 values are valid to identify a skippable frame."
    try testing.expectEqual(Kind.zstandard, try classify(&golden.frame_magic));
    try testing.expectEqual(Kind.zstandard, try classify(&golden.frame_raw));
    for (0..16) |tag| {
        const value: u32 = skippable_magic_base + @as(u32, @intCast(tag));
        const skippable = [_]u8{
            @truncate(value),
            @truncate(value >> 8),
            @truncate(value >> 16),
            @truncate(value >> 24),
        };
        try testing.expectEqual(Kind.skippable, try classify(&skippable));
    }
    // The neighbors outside the range: 0x184D2A4F and 0x184D2A60 are
    // neither family (the CLI exits 1 on an out-of-range magic).
    try testing.expectError(error.BadMagic, classify(&.{ 0x4f, 0x2a, 0x4d, 0x18 }));
    try testing.expectError(error.BadMagic, classify(&.{
        0x60, 0x2a, 0x4d, 0x18,
    }));
    // A flipped Zstandard magic is neither family (the corruption set's
    // flipped-magic row).
    try testing.expectError(error.BadMagic, classify(&golden.frame_bad_magic));
    // A short or empty input is the input's end, not a wrong magic.
    try testing.expectError(error.Truncated, classify(&.{}));
    try testing.expectError(error.Truncated, classify(&.{ 0x28, 0xb5 }));
}

test "parseHeader reads every FCS form" {
    // RFC 8878 §3.1.1.1.1.1, Table 4 — "When Frame_Content_Size_Flag is 0,
    // FCS_Field_Size depends on Single_Segment_Flag: if Single_Segment_Flag
    // is set, FCS_Field_Size is 1. Otherwise, FCS_Field_Size is 0;
    // Frame_Content_Size is not provided." Table 7 — 1 / 2 / 4 / 8 bytes,
    // little-endian, "When FCS_Field_Size is 2, the offset of 256 is added."
    // Flag 0 without Single_Segment_Flag: absent, and the header is the
    // descriptor plus the Window_Descriptor.
    const absent = try parseHeader(&.{ 0x00, 0x00 });
    try testing.expectEqual(@as(?u64, null), absent.content_size);
    try testing.expectEqual(@as(usize, 2), absent.bytes_consumed);
    try testing.expect(!absent.checksum);
    // Flag 0 with Single_Segment_Flag: one byte (0-255), and Window_Size is
    // that value.
    const one = try parseHeader(&.{ 0x20, 0x08 });
    try testing.expectEqual(@as(?u64, 8), one.content_size);
    try testing.expectEqual(@as(u64, 8), one.window_size);
    try testing.expectEqual(@as(usize, 2), one.bytes_consumed);
    // Flag 1: two bytes, plus the 256 offset — 0x2c 0x00 is 300.
    const two = try parseHeader(&.{ 0x40, 0x00, 0x2c, 0x00 });
    try testing.expectEqual(@as(?u64, 300), two.content_size);
    try testing.expectEqual(@as(usize, 4), two.bytes_consumed);
    // The form's floor: 0x00 0x00 is 256, not 0.
    try testing.expectEqual(@as(?u64, 256), (try parseHeader(&.{ 0x40, 0x00, 0, 0 })).content_size);
    // Flag 2: four bytes, little-endian.
    const four = try parseHeader(&.{ 0x80, 0x00, 0x78, 0x56, 0x34, 0x12 });
    try testing.expectEqual(@as(?u64, 0x12345678), four.content_size);
    try testing.expectEqual(@as(usize, 6), four.bytes_consumed);
    // Flag 3: eight bytes, little-endian — "It's allowed to represent a
    // small size (for example, 18) using any compatible variant", so the
    // value is not range-checked against the form.
    const eight = try parseHeader(&.{ 0xc0, 0x00, 0x12, 0, 0, 0, 0, 0, 0, 0 });
    try testing.expectEqual(@as(?u64, 0x12), eight.content_size);
    try testing.expectEqual(@as(usize, 10), eight.bytes_consumed);
    // The descriptor's checksum bit (§3.1.1.1.1.5) rides along: same bytes,
    // flag set.
    const flagged = try parseHeader(&.{ 0xc4, 0x00, 1, 0, 0, 0, 0, 0, 0, 0 });
    try testing.expect(flagged.checksum);
}

test "parseHeader: Single_Segment_Flag skips the Window_Descriptor" {
    // RFC 8878 §3.1.1.1.1.2 — "In this case, Window_Descriptor byte is
    // skipped, but Frame_Content_Size is necessarily present. ... the decoder
    // must allocate a memory segment of a size equal to or larger than
    // Frame_Content_Size"; §3.1.1.1.2 — "When Single_Segment_Flag is set,
    // Window_Descriptor is not present. In this case, Window_Size is
    // Frame_Content_Size."
    const single = try parseHeader(&.{ 0x60, 0x2c, 0x00 });
    try testing.expectEqual(@as(?u64, 300), single.content_size);
    try testing.expectEqual(@as(u64, 300), single.window_size);
    try testing.expectEqual(@as(usize, 3), single.bytes_consumed);
    // The same bytes without the flag are a descriptor, a Window_Descriptor
    // (0x2c -> exponent 5, mantissa 4 -> 4 KB), and a 4-byte FCS that is not
    // there.
    try testing.expectError(error.Truncated, parseHeader(&.{ 0x40, 0x2c, 0x00 }));
    // The zero-size single-segment frame: Window_Size 0, so no block may
    // carry content (Block_Maximum_Size is 0, §3.1.1.2.4) — the CLI's own
    // empty-input frame is this shape.
    const empty = try parseHeader(&.{ 0x20, 0x00 });
    try testing.expectEqual(@as(?u64, 0), empty.content_size);
    try testing.expectEqual(@as(u64, 0), empty.window_size);
}

test "window reads §3.1.1.1.2's descriptor arithmetic" {
    // RFC 8878 §3.1.1.1.2 — "windowLog = 10 + Exponent; windowBase = 1 <<
    // windowLog; windowAdd = (windowBase / 8) * Mantissa; Window_Size =
    // windowBase + windowAdd. The minimum Window_Size is 1 KB. The maximum
    // Window_Size is (1<<41) + 7*(1<<38) bytes, which is 3.75 TB."
    try testing.expectEqual(@as(u64, 1024), window.size(0x00));
    // Mantissa alone: descriptor 0x07 is 1 KB + 7/8 KB.
    try testing.expectEqual(@as(u64, 1024 + 7 * 128), window.size(0x07));
    // Exponent alone: 0x38 is exponent 7 -> 128 KB; 0x48 is exponent 9 ->
    // 512 KB (the fixture frames' window); 0x58 is exponent 11 -> 2 MB (the
    // CLI's level-3 pin); 0x68 is exponent 13 -> 8 MB (the level-19 pin and
    // §3.1.1.1.2's recommendation).
    try testing.expectEqual(@as(u64, 128 * 1024), window.size(0x38));
    try testing.expectEqual(@as(u64, 512 * 1024), window.size(0x48));
    try testing.expectEqual(@as(u64, 2 * 1024 * 1024), window.size(0x58));
    try testing.expectEqual(@as(u64, 8 * 1024 * 1024), window.size(0x68));
    try testing.expectEqual(@as(u64, 8 * 1024 * 1024), window.windowBase(13));
    try testing.expectEqual(@as(u64, 0), window.windowAdd(13, 0));
    try testing.expectEqual(@as(u6, 23), window.windowLog(13));
    // The extremes: the spec's own numbers, not a formula re-derivation.
    try testing.expectEqual(window.min_size, window.size(0x00));
    try testing.expectEqual(window.max_size, window.size(0xff));
    // The spec's "3.75 TB" is binary: 15 * 2^38 bytes, which the formula's
    // maximum lands on exactly.
    try testing.expectEqual(@as(u64, 15 * (1 << 38)), window.max_size);
    try testing.expectEqual(@as(u64, 1 << 41), window.windowBase(31));
    try testing.expectEqual(@as(u64, 7 * (1 << 38)), window.windowAdd(31, 7));
}

test "parseHeader: the unused bit is never interpreted, the reserved bit fails" {
    // RFC 8878 §3.1.1.1.1.3 — "A decoder compliant with this specification
    // version shall not interpret this bit. It might be used in a future
    // version to signal a property that is not mandatory to properly decode
    // the frame." The CLI decodes a frame with bit 4 set (verified: exit 0),
    // so the bit is accepted with either value and never read.
    const plain = try parseHeader(&.{ 0x00, 0x00 });
    const unused = try parseHeader(&.{ descriptor_unused, 0x00 });
    try testing.expectEqual(plain.window_size, unused.window_size);
    try testing.expectEqual(plain.content_size, unused.content_size);
    try testing.expectEqual(plain.checksum, unused.checksum);
    // RFC 8878 §3.1.1.1.1.4 — "This bit is reserved for some future feature.
    // Its value must be zero. A decoder compliant with this specification
    // version must ensure it is not set." The CLI exits 1 ("Unsupported
    // frame parameter") on the same frame.
    try testing.expectError(error.ReservedBitSet, parseHeader(&.{ 0x08, 0x00 }));
    // Every descriptor byte with bit 3 set, whatever the other flags say: the
    // check lands at the descriptor byte, before any other field, so no
    // combination of the rest can rescue it.
    for (0..256) |byte| {
        if (byte & descriptor_reserved == 0) continue;
        try testing.expectError(
            error.ReservedBitSet,
            parseHeader(&.{ @intCast(byte), 0x00, 0x00, 0x00, 0x00, 0x00 }),
        );
    }
}

test "parseHeader refuses dictionaries at the first Dictionary_ID byte" {
    // RFC 8878 §3.1.1.1.3 — the Dictionary_ID "contains the ID of the
    // dictionary required to properly decode the frame"; §5 leaves
    // acquisition out of band and §2 demands "an unambiguous error code".
    // This decoder refuses at the first Dictionary_ID byte, before any body
    // byte; the CLI fails both fixtures with "Dictionary mismatch".
    try testing.expectError(error.DictionaryRequired, parseHeader(&.{ 0x01, 0x00, 0x2a }));
    try testing.expectError(error.DictionaryRequired, parseHeader(&.{ 0x02, 0x00, 0x2a, 0x2b }));
    try testing.expectError(error.DictionaryRequired, parseHeader(&.{
        0x03, 0x00, 0x44, 0x33, 0x22, 0x11,
    }));
    // The refusal is not gated on the whole field being present: the first
    // byte alone is enough, and the rest of the ID is never read.
    try testing.expectError(error.DictionaryRequired, parseHeader(&.{ 0x03, 0x00, 0x44 }));
    // A header cut before the first Dictionary_ID byte is the input's end
    // (`Truncated`), the same rule as everywhere else in the frame — the CLI
    // agrees on both shapes ("premature end" for the cut one, "Dictionary
    // mismatch" for the complete one).
    try testing.expectError(error.Truncated, parseHeader(&.{ 0x03, 0x00 }));
    try testing.expectError(error.Truncated, parseHeader(&.{0x01}));
    try testing.expectError(error.Truncated, parseHeader(&.{0x00}));
    // The DID field sizes themselves (Table 5), and the header's 14-byte
    // maximum: 1 descriptor + 1 window + 4 DID + 8 FCS.
    try testing.expectEqual(@as(usize, 0), didFieldSize(0x00));
    try testing.expectEqual(@as(usize, 1), didFieldSize(0x01));
    try testing.expectEqual(@as(usize, 2), didFieldSize(0x02));
    try testing.expectEqual(@as(usize, 4), didFieldSize(0x03));
    try testing.expectEqual(@as(usize, 14), 1 + 1 + 4 + 8);
}

test "parseHeader is byte-fed" {
    // The streaming reader's shape: its input buffer holds only the 4 bytes
    // the magic needs, so the 2-14 byte header arrives a chunk at a time. The
    // parser must consume as much as it can and no more, and the same header
    // must parse identically however the bytes are cut.
    const bytes = [_]u8{ 0x84, 0x00, 0x78, 0x56, 0x34, 0x12 };
    const whole = try parseHeader(&bytes);
    var parser: HeaderParser = .{};
    var cursor: usize = 0;
    while (cursor < bytes.len) {
        const consumed = try parser.feed(bytes[cursor..][0..1]);
        try testing.expectEqual(@as(usize, 1), consumed);
        cursor += consumed;
    }
    try testing.expect(parser.done());
    try testing.expectEqual(whole.descriptor, parser.header().descriptor);
    try testing.expectEqual(whole.window_size, parser.header().window_size);
    try testing.expectEqual(whole.content_size, parser.header().content_size);
    try testing.expectEqual(whole.checksum, parser.header().checksum);
    try testing.expectEqual(whole.bytes_consumed, parser.header().bytes_consumed);
    // The parser stops at the header's end: the block chain's first bytes are
    // not consumed (the one-shot's cursor depends on that).
    var slack: HeaderParser = .{};
    const with_block = bytes ++ [_]u8{0xff};
    const consumed = try slack.feed(&with_block);
    try testing.expectEqual(bytes.len, consumed);
    // An input end inside the header leaves the parser not-done, which is the
    // driver's `Truncated`.
    var short: HeaderParser = .{};
    try testing.expectEqual(@as(usize, 1), try short.feed(&.{0x84}));
    try testing.expect(!short.done());
}

test "checkWindow bounds the frame's Window_Size" {
    // RFC 8878 §3.1.1.1.2 — "In order to protect decoders from unreasonable
    // memory requirements, a decoder is allowed to reject a compressed frame
    // that requests a memory size beyond the decoder's authorized range. ...
    // it's recommended for decoders to support values of Window_Size up to
    // 8 MB". The cap is the caller's; the one-shot never applies one.
    const header = try parseHeader(&.{ 0x00, 0x48 }); // 512 KB
    try checkWindow(header, 512 * 1024);
    try checkWindow(header, 8 * 1024 * 1024);
    try testing.expectError(error.WindowTooLarge, checkWindow(header, 512 * 1024 - 1));
    try testing.expectError(error.WindowTooLarge, checkWindow(header, 0));
    // The single-segment form's window is its FCS, so the cap sees the same
    // number the decoder would have to materialize.
    const single = try parseHeader(&.{ 0x60, 0x2c, 0x00 }); // FCS 300
    try checkWindow(single, 300);
    try testing.expectError(error.WindowTooLarge, checkWindow(single, 299));
}

test "the frame walk decodes the fast-path fixtures" {
    // RFC 8878 §3.1.1.2 — the block chain, and §3.1.1.2.1's Last_Block ends
    // it. Raw and RLE blocks take no entropy path but land in the output (and
    // so in the checksum) like any other.
    try expectFrame(&golden.frame_raw, "zstd raw");
    try expectFrame(&golden.frame_raw_empty, "");
    try expectFrame(&golden.frame_rle, "AAAAAAAAAA");
    try expectFrame(&golden.frame_multi, "abcdefghIIIIII");
    // §3.1.1.2.4 — an RLE block at exactly Block_Maximum_Size: 128 KB from
    // one content byte.
    const run = [_]u8{0x5a} ** block.max_block_size;
    var target: [block.max_block_size + 8]u8 = undefined;
    internal.sentinel.fill(&target);
    var progress: usize = 0;
    const written = try decodeFrame(&golden.frame_rle_max, &target, &progress);
    try testing.expectEqual(block.max_block_size, written);
    try testing.expectEqualSlices(u8, &run, target[0..written]);
    try internal.sentinel.expect(&target, written);
}

test "the frame walk decodes the golden fixture frames" {
    // RFC 8878 §3.1.1.3 — the compressed blocks' fixtures, framed as whole
    // frames and decoded here through the frame layer: the hand-built Huffman
    // pair, the literals families, the sequences pairs, and the hand-built
    // corners. Each expectation is the CLI's own `zstd -d` bytes.
    try expectFrame(&golden.frame_pair, &golden.pair_literals);
    try expectFrame(&golden.frame_pair_errata, &golden.pair_errata_literals);
    try expectFrame(&golden.frame_treeless, &.{ 0, 1, 4, 5, 0, 0, 0, 0, 0 });
    try expectFrame(&golden.frame_repeat, &golden.frame_repeat_expected);
    try expectFrame(&golden.frame_temp_offset, &golden.frame_temp_offset_expected);
    try expectFrame(&golden.frame_corner, &golden.frame_corner_expected);
    try expectFrame(&golden.frame_two_byte, &golden.frame_two_byte_expected);
    try expectFrame(&golden.frame_zero_seq, &golden.frame_zero_seq_expected);
    try expectFrame(&golden.frame_zero_seq_2b, &golden.frame_zero_seq_expected);
    try expectFrame(&golden.frame_sequences_predefined, &golden.sequences_predefined_expected);
    try expectFrame(
        &golden.frame_sequences_rle_match_lengths,
        &golden.sequences_rle_match_lengths_expected,
    );
    try expectFrame(&golden.frame_sequences_fse_offsets, &golden.sequences_fse_offsets_expected);
    try expectFrame(&golden.frame_sequences_fse_all, &golden.sequences_fse_all_expected);
    try expectFrame(&golden.frame_literals_1stream, &golden.literals_1stream_expected);
    try expectFrame(&golden.frame_literals_4stream_sf1, &golden.literals_4stream_sf1_expected);
    try expectFrame(&golden.frame_literals_4stream_sf2, &golden.literals_4stream_sf2_expected);
    try expectFrame(&golden.frame_literals_fse_tree, &golden.literals_fse_tree_expected);
}

test "the frame walk carries the window accounting across blocks" {
    // RFC 8878 §3.1.1.4 — "all offsets leading to previously decoded data
    // must be smaller than Window_Size": the two window fixtures' decoded
    // lengths pass both Window_Size and Block_Maximum_Size, so the frame
    // layer's one running counter is what the block layer's history is
    // re-based against.
    var target: [300 * 1024]u8 = undefined;
    internal.sentinel.fill(&target);
    var progress: usize = 0;
    var written = try decodeFrame(&golden.frame_window_1k, &target, &progress);
    try testing.expectEqual(@as(usize, 2048 + 3), written);
    try testing.expectEqualSlices(u8, "BBB", target[2048..2051]);
    try internal.sentinel.expect(&target, written);
    written = try decodeFrame(&golden.frame_window_128k, &target, &progress);
    try testing.expectEqual(@as(usize, 2 * 131072 + 3), written);
    try testing.expectEqualSlices(u8, "BBB", target[262144..262147]);
    try internal.sentinel.expect(&target, written);
    // The addressable span: ten literals move the match position past the
    // 1 KB window, and the offset reads a byte the declared window alone
    // would not admit. The CLI decodes it too.
    internal.sentinel.fill(&target);
    written = try decodeFrame(&golden.frame_window_1k_span, &target, &progress);
    try testing.expectEqual(@as(usize, 2048 + 10 + 3), written);
    try testing.expectEqualSlices(u8, "0123456789BBB", target[2048..2061]);
    try internal.sentinel.expect(&target, written);
    // The one-byte-past siblings: `OffsetTooFar`. The CLI decodes both,
    // because its whole-buffer decoder checks the bytes it still has rather
    // than the declared window.
    try expectFrameError(error.OffsetTooFar, &golden.frame_window_1k_over);
    try expectFrameError(error.OffsetTooFar, &golden.frame_window_128k_over);
}

test "the checksum folds each block's output exactly once, in order" {
    // RFC 8878 §3.1.1 — "The content checksum is the result of the XXH64()
    // hash function digesting the original (decoded) data as input, and a
    // seed of zero. The low 4 bytes of the checksum are stored in
    // little-endian format." The fixtures' trailers are the CLI's own bytes
    // (each verified with `zstd -t`), so the fold is pinned against the C
    // library's XXH64, not against our own arithmetic.
    try expectFrame(&golden.frame_checksum, "abcd");
    try expectFrame(&golden.frame_checksum_empty, "");
    // The flag is the only difference the trailer makes: the checksum-off
    // sibling is the same frame with descriptor bit 2 clear and no trailer
    // (the CLI's own `--check`/`--no-check` pair differs in exactly those
    // bytes), and it decodes to the same output.
    try expectFrame(&golden.frame_checksum_off, "abcd");
    // The multi-block CLI frame: 135000 decoded bytes over two compressed
    // blocks, folded in order with no second pass.
    var target: [block.max_block_size * 2]u8 = undefined;
    internal.sentinel.fill(&target);
    var progress: usize = 0;
    const written = try decodeFrame(&golden.frame_checksum_multi, &target, &progress);
    const expected = golden.frame_checksum_multi_text ** 3000;
    try testing.expectEqual(expected.len, written);
    try testing.expectEqualSlices(u8, expected, target[0..written]);
    try internal.sentinel.expect(&target, written);
    // A mismatched trailer is `WrongChecksum` (the CLI exits 1 with
    // "Restored data doesn't match checksum"), and a trailer cut short is the
    // input's end.
    try expectFrameError(error.WrongChecksum, &golden.frame_checksum_corrupt);
    try expectFrameError(error.Truncated, &golden.frame_checksum_truncated);
}

test "the fold is independent of the block boundaries" {
    // The digest over a frame's blocks in order is the digest over the
    // concatenation, whatever the boundaries. `recordBlock` is the path for
    // everything but Raw blocks (whose fold rides the copy), and it is
    // handed exactly the bytes each block wrote.
    const first = "the quick brown fox ";
    const second = "jumps over the lazy dog";
    var state: State = undefined;
    state.init(.{
        .descriptor = descriptor_checksum,
        .window_size = 1024,
        .content_size = null,
        .checksum = true,
        .bytes_consumed = 2,
    });
    try state.recordBlock(first);
    try state.recordBlock(second);
    try testing.expectEqual(@as(usize, first.len + second.len), state.decoded_len);
    try testing.expectEqual(
        @as(u32, @truncate(xxh64.xxh64(0, first ++ second))),
        state.checksum.final(),
    );
    // A flag-off frame folds nothing at all: the state's digest stays the
    // empty-payload value, which is what makes the branch a real saving
    // rather than a cosmetic one.
    var plain: State = undefined;
    plain.init(.{
        .descriptor = 0,
        .window_size = 1024,
        .content_size = null,
        .checksum = false,
        .bytes_consumed = 2,
    });
    try plain.recordBlock(first);
    try testing.expectEqual(@as(u32, 0x51D8E999), plain.checksum.final());
}

test "a checksummed raw-block frame folds inside the copy" {
    // The Raw-block fold rides the copy chunk by chunk
    // (`block.decodeContent`), not `recordBlock`: a frame of two Raw blocks
    // whose sizes straddle the fold chunk must still verify its trailer —
    // the digest is boundary-independent — and a flipped content byte in
    // either block must fail `WrongChecksum`.
    const first_len = 40 * 1024 + 513;
    const second_len = 25 * 1024 + 7;
    const total = first_len + second_len;
    var data: [total]u8 = undefined;
    var rng: DefaultPrng = .init(0xf01d);
    rng.random().bytes(&data);

    // Magic, then the descriptor (four-byte FCS, Content_Checksum set), the
    // window descriptor (exponent 6: 64 KiB), the FCS, the two Raw blocks,
    // and the trailer.
    var bytes: [magic_len + 2 + 4 + 2 * block.block_header_len + total + checksum_len]u8 =
        undefined;
    var at: usize = 0;
    std.mem.writeInt(u32, bytes[at..][0..4], magic, .little);
    at += magic_len;
    bytes[at] = 0x80 | descriptor_checksum;
    bytes[at + 1] = 0x30;
    at += 2;
    std.mem.writeInt(u32, bytes[at..][0..4], total, .little);
    at += 4;
    var src: usize = 0;
    for ([_]usize{ first_len, second_len }, 0..) |size, i| {
        const last: u24 = if (i == 1) 1 else 0;
        std.mem.writeInt(u24, bytes[at..][0..3], last | @as(u24, @intCast(size)) << 3, .little);
        at += block.block_header_len;
        fastmem.copy(u8, bytes[at..][0..size], data[src..][0..size]);
        src += size;
        at += size;
    }
    std.mem.writeInt(u32, bytes[at..][0..4], @truncate(xxh64.xxh64(0, &data)), .little);
    at += checksum_len;

    const framed = bytes[0..at];
    var target: [total]u8 = undefined;
    internal.sentinel.fill(&target);
    var progress: usize = 0;
    const written = try decodeFrame(framed, &target, &progress);
    try testing.expectEqual(total, written);
    try golden.expectDecoded(&target, written, &data);

    // A flipped byte in either block's content fails the trailer.
    const first_content = magic_len + 2 + 4 + block.block_header_len;
    const second_content = first_content + block.block_header_len + first_len;
    for ([_]usize{ first_content, second_content + 40 }) |flip| {
        var bad: [bytes.len]u8 = undefined;
        fastmem.copy(u8, &bad, &bytes);
        bad[flip] ^= 0x01;
        try testing.expectError(error.WrongChecksum, decodeFrame(&bad, &target, &progress));
    }
}

test "Frame_Content_Size is a running bound, and the frame end closes it" {
    // RFC 8878 §3.1.1.1.4 — "Frame_Content_Size ... is the original
    // (uncompressed) size"; §8 names the smaller-than-actual FCS as an
    // attack vector. Both fixtures are one 8-byte Raw block whose header
    // declares 4 and 12: the first fails at that block (the running bound),
    // the second at the frame end. The CLI exits 1 on both.
    try expectFrameError(error.ContentSizeMismatch, &golden.frame_fcs_short);
    try expectFrameError(error.ContentSizeMismatch, &golden.frame_fcs_long);
    // The matching declaration decodes: the same shape with FCS 8.
    try expectFrame(&golden.frame_fcs4, "01234567");
    // The 8-byte form's maximum is a declaration like any other — nothing is
    // sized from it, and it is checked against the decode. The C reserves
    // 2^64-1 as its `ZSTD_CONTENTSIZE_UNKNOWN` sentinel and skips the check
    // (the CLI decodes this frame); the RFC has no such value, so ours is
    // `ContentSizeMismatch` — the divergence `golden.zig` records beside the
    // fixture.
    try expectFrameError(error.ContentSizeMismatch, &golden.frame_fcs_max);
}

test "the descriptor corners decode as the CLI does" {
    // RFC 8878 §3.1.1.1.1.1 — every FCS form, and §3.1.1.1.1.2's
    // single-segment Window_Size = Frame_Content_Size. The CLI decodes each
    // of these byte-exact.
    const run = [_]u8{'A'} ** 300;
    try expectFrame(&golden.frame_fcs1, "01234567");
    try expectFrame(&golden.frame_fcs2, &run);
    try expectFrame(&golden.frame_fcs2_single_segment, &run);
    try expectFrame(&golden.frame_fcs4, "01234567");
    try expectFrame(&golden.frame_fcs8, "01234567");
    // §3.1.1.1.1.3 — the unused bit is accepted (the CLI exits 0 on it).
    try expectFrame(&golden.frame_unused_bit, "abcd");
    // §3.1.1.1.1.4 + §3.1.1.1.3 — the reserved bit and the dictionary ID
    // (the CLI exits 1 on both).
    try expectFrameError(error.ReservedBitSet, &golden.frame_reserved_bit);
    try expectFrameError(error.DictionaryRequired, &golden.frame_dictionary_id);
    try expectFrameError(error.DictionaryRequired, &golden.frame_dictionary_id_wide);
    try expectFrameError(error.Truncated, &golden.frame_dictionary_id_truncated);
    // §3.1.1.2.4's window/block coupling: a single-segment frame's
    // Window_Size is its FCS, so a block larger than it is `BlockOversize`
    // ("Src size is incorrect" to the C).
    try expectFrameError(error.BlockOversize, &golden.frame_single_segment_oversize);
}
