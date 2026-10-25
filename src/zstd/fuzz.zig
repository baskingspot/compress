//! Fuzz targets for zstd (RFC 8878): the decoder's one-shot
//! `decode.decompress` and streaming `Reader`, and the encoder's one-shot
//! `encode.compress` and streaming `Writer`.
//!
//! Decode targets start from the golden fixtures (`golden.zig`), whose
//! expected output and verdict were checked against the C `zstd` CLI. A
//! checksummed fixture's trailer is the C library's XXH64 value,
//! cross-checked against std's `XxHash64`. The decode targets:
//! `fuzzGoldenCorpus` (the good fixtures), `fuzzCorruption` (bad frames and
//! mutations of good ones), `fuzzReaderMachinery` (random `Io.Reader` calls),
//! `fuzzChecksumAccounting` (the XXH64 trailer), and `fuzzAmplification`
//! (declared-size bombs).
//!
//! Encode targets attack our own encoder's output. There is no in-process
//! reference oracle — the CLI is not callable from a fuzz target — so the
//! byte class is pinned by the CLI-verified `encode_*` fixtures (`golden.zig`)
//! and the targets pin the invariants instead: `fuzzEncodeRoundTrip` (the
//! one-shot and the Writer, decoded back with the sentinel rule),
//! `fuzzEncodeByteClass` (determinism, the header forms and the window
//! ladder, the block-chain structure), `fuzzEncodeCorruption` (the decode
//! mutation taxonomy over real encoder output), `fuzzWriterMachinery` (random
//! `Io.Writer` calls and the poison lifecycle), and `fuzzEncodeAmplification`
//! (the `maxCompressedLength` bound and the `BufferTooSmall` boundary). Each
//! has a doc comment with the properties it checks.
//!
//! Run with `just fuzz <budget>` (ReleaseSafe only: a Debug-mode fuzz run hits
//! ziglang/zig#30655). Every target caps its per-iteration input and work
//! (`source_max`, `encode_max`, `out_max`) so a budget run finishes. Nothing
//! here allocates: every buffer is a stack local.
//!
//! Spec: docs/specs/rfc8878-zstd.txt (§3.1 frames, §3.1.1 the frame
//! and its checksum, §3.1.1.1 the header, §3.1.1.2 the block chain, §3.1.1.3
//! and §3.1.1.4 the entropy layers and execution, §3.1.2 skippable frames,
//! §4.1 and §4.2 the FSE and Huffman tables). Where this decoder differs from
//! the C reference, docs/slop/research/zstd-notes.md §4 records the decision; where
//! the encoder does, docs/slop/research/zstd-encoder-notes.md §5 does.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;
const Smith = testing.Smith;
const math = std.math;
const mem = std.mem;
const DefaultPrng = std.Random.DefaultPrng;
const XxHash64 = std.hash.XxHash64;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const readInt = @import("common.zig").readInt;
const block = @import("block.zig");
const block_compress = @import("block_compress.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const fse = @import("fse.zig");
const frame = @import("frame.zig");
const golden = @import("golden.zig");
const match_compress = @import("match_compress.zig");
const Reader = @import("Reader.zig");
const Writer = @import("Writer.zig");

// ---------------------------------------------------------------------------
// Shared harness
// ---------------------------------------------------------------------------

/// Bytes past a decode's cap checked on every one-shot decode: an
/// out-of-bounds write lands in this region.
const guard_len: usize = 256;

/// The corpus's widest decoded output: `frame_window_128k`'s 2 * 131072 + 3.
/// The targets' one-shot output buffers are this plus `guard_len`.
const out_max: usize = 262_147;

/// The corpus frames' declared window (`frame_raw`'s Window_Descriptor 0x48:
/// 512 KiB, `§3.1.1.1.2`) — the reader buffers below authorize it, and it is
/// the `checkWindow` boundary the mutations probe.
const fixture_window_len: usize = 512 * 1024;

/// The corpus's widest frame unit; the mutation buffers add room for a
/// skippable prefix, a duplicated unit, and markers.
const source_max: usize = 1024;
const mutation_max: usize = 2 * source_max + 64;

/// Marker bytes appended after a frame unit to prove the reader stops at the
/// unit's last byte: the frame is self-delimiting, so bytes after it are not
/// the reader's to consume.
const marker_len: usize = 8;
const marker_byte: u8 = 0xa5;

/// A Smith-chosen value in `[at_least, at_most]`. `Smith.valueRangeAtMost`
/// rejects `usize` (no fixed bitsize), so bounded lengths go through a `u32`
/// and widen here; every call site is inside a per-iteration cap.
fn rangeAtMost(smith: *Smith, at_least: usize, at_most: usize) usize {
    assert(at_least <= at_most);
    assert(at_most <= math.maxInt(u32));
    return smith.valueRangeAtMost(u32, @intCast(at_least), @intCast(at_most));
}

/// A nonzero byte to XOR with, so a flip always changes the byte.
fn flipValue(smith: *Smith) u8 {
    return @intCast(1 + rangeAtMost(smith, 0, 254));
}

/// How many `stream` calls decoding `plain_len` bytes may take: each call
/// either serves buffered bytes or fills the serving region with at least one
/// byte, so two calls per output byte plus slack for a stall is a generous
/// bound. More calls than this is a hang, not a timeout.
fn pumpLimit(plain_len: usize) usize {
    return 16 + 2 * plain_len;
}

/// Pump `r` into `w` until the clean end of the frame (the shape of
/// Reader.zig's own pump driver), bounded: a reader that neither serves bytes
/// nor fails is a hang, not a timeout.
fn pump(r: *Io.Reader, w: *Io.Writer, limit: usize) !void {
    var calls: usize = 0;
    while (true) {
        calls += 1;
        if (calls > limit) return error.PumpStalled;
        _ = r.stream(w, .unlimited) catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e| return e,
        };
    }
}

/// How `pumpCapped` stopped. `output_full` is the harness's own cap (a fixed
/// writer), not a codec failure.
const Stop = enum { end_of_stream, read_failed, output_full };

const Pumped = struct { served: usize, stop: Stop };

/// Pump `r` into the fixed writer `w` until the frame ends, the reader fails,
/// or `w` is full. The reader's coarse `error.ReadFailed` is reported as
/// `read_failed` (the detail is sticky in `r.err`); `error.WriteFailed` is the
/// output cap. More calls than `limit` is a hang, not a timeout.
fn pumpCapped(r: *Io.Reader, w: *Io.Writer, limit: usize) !Pumped {
    var calls: usize = 0;
    while (true) {
        calls += 1;
        if (calls > limit) return error.PumpStalled;
        _ = r.stream(w, .unlimited) catch |err| switch (err) {
            error.EndOfStream => return .{ .served = w.end, .stop = .end_of_stream },
            error.ReadFailed => return .{ .served = w.end, .stop = .read_failed },
            error.WriteFailed => return .{ .served = w.end, .stop = .output_full },
        };
    }
}

/// The clean end is sticky: repeated `stream` calls end in `EndOfStream`. A
/// zero-serve fill call may come first — the interface allows a zero return
/// that does not indicate frame end — so this drives the calls instead of
/// pinning the first one.
fn expectStickyEnd(r: *Reader) !void {
    var sink: Io.Writer.Discarding = .init(&.{});
    var calls: usize = 0;
    while (true) {
        calls += 1;
        if (calls > 4) return error.EndNotSticky;
        const n = r.reader.stream(&sink.writer, .unlimited) catch |err| {
            try testing.expectEqual(error.EndOfStream, err);
            return;
        };
        try testing.expectEqual(@as(usize, 0), n);
    }
}

/// A failure is sticky: repeated `stream` calls end in `ReadFailed` (a
/// zero-serve call may come first), with the detail still recorded in `err`.
fn expectStickyFailure(r: *Reader) !void {
    try testing.expect(r.err != null);
    var sink: Io.Writer.Discarding = .init(&.{});
    var calls: usize = 0;
    while (true) {
        calls += 1;
        if (calls > 4) return error.FailureNotSticky;
        _ = r.reader.stream(&sink.writer, .unlimited) catch |err| {
            try testing.expectEqual(error.ReadFailed, err);
            return;
        };
    }
}

/// The largest contiguous request the reader is guaranteed to serve:
/// `Block_Maximum_Size`, 128 KiB. The over-cap ops ask one byte past it.
fn windowTailLen() usize {
    return block.max_block_size;
}

/// The reader's whole caller buffer (window, block room, and staging). A
/// request of this size exceeds the serving region's `buffer.len - seek` once
/// the consumer has advanced, so the std fill routes it through the reader's
/// `rebase`.
fn bufferLen() usize {
    return @sizeOf(Reader.Buffer(fixture_window_len));
}

/// The only legal failure of a *valid* frame under a bounded contiguous
/// request: the serving region cannot hold what the consumer asked for
/// (`StreamTooLong`). Any other failure is a bug. The failure is sticky and
/// reports the detail beside the interface's coarse error.
fn expectContiguityStop(r: *Reader, err: anyerror) !void {
    try testing.expectEqual(error.ReadFailed, err);
    try testing.expectEqual(Reader.Error.StreamTooLong, r.err.?);
    try expectStickyFailure(r);
}

/// A failed one-shot decode where no specific error is pinned.
fn expectFailure(result: decode.DecompressError!usize) !void {
    if (result) |_| return error.ExpectedFailure else |_| {}
}

/// The same error name across the one-shot's and the reader's sets — the
/// reader's detail set is the one-shot's minus `BufferTooSmall` plus its own
/// names, so a shared failure must carry the same name.
fn sameErrorName(one_shot: decode.DecompressError, reader_detail: Reader.Error) bool {
    return mem.eql(u8, @errorName(one_shot), @errorName(reader_detail));
}

/// The frame's wire trailer, when it has one, must be the low 4 bytes of the
/// reference XXH64 over the decoded bytes (`§3.1.1`). The golden trailers are
/// the C library's own values (the CLI verified each with `zstd -t`), and the
/// reader's clean end means its running hash (`recordBlock`) agreed with
/// exactly these bytes.
fn expectTrailerConsistent(
    source: []const u8,
    end: usize,
    output: []const u8,
    has_checksum: bool,
) !void {
    if (!has_checksum) return;
    try testing.expect(end >= frame.checksum_len);
    const trailer = source[end - frame.checksum_len .. end];
    try testing.expectEqual(
        @as(u32, @truncate(XxHash64.hash(0, output))),
        readInt(u32, trailer[0..4]),
    );
}

// ---------------------------------------------------------------------------
// The corpus: the golden fixtures and the models their CLI verdicts pin
// ---------------------------------------------------------------------------

/// The decoded output of a corpus frame, in the shape that builds it without
/// copying a multi-hundred-KiB literal.
const Output = union(enum) {
    /// The fixture's decoded bytes, verbatim.
    static: []const u8,
    /// One byte repeated `count` times.
    splat: struct { byte: u8, count: usize },
    /// `count` copies of a phrase.
    repeat: struct { text: []const u8, count: usize },
    /// Two runs and a tail (`frame_window_*`: RLE blocks then a match).
    two_runs: struct {
        first_byte: u8,
        first_count: usize,
        second_byte: u8,
        second_count: usize,
        tail: []const u8,
    },
};

/// Build `output` into `buf` and return the used prefix.
fn materialize(output: Output, buf: []u8) []const u8 {
    switch (output) {
        .static => |bytes| {
            fastmem.copy(u8, buf[0..bytes.len], bytes);
            return buf[0..bytes.len];
        },
        .splat => |s| {
            fastmem.set(u8, buf[0..s.count], s.byte);
            return buf[0..s.count];
        },
        .repeat => |r| {
            var i: usize = 0;
            while (i < r.count) : (i += 1) {
                fastmem.copy(u8, buf[i * r.text.len ..][0..r.text.len], r.text);
            }
            return buf[0 .. r.count * r.text.len];
        },
        .two_runs => |t| {
            fastmem.set(u8, buf[0..t.first_count], t.first_byte);
            fastmem.set(u8, buf[t.first_count..][0..t.second_count], t.second_byte);
            const tail_at = t.first_count + t.second_count;
            fastmem.copy(u8, buf[tail_at..][0..t.tail.len], t.tail);
            return buf[0 .. tail_at + t.tail.len];
        },
    }
}

const Row = struct {
    desc: []const u8,
    source: []const u8,
    output: Output,
};

/// The good corpus: every committed frame whose CLI verdict is a decode, with
/// the expected bytes the verdict pins. The one-shot's identity, the cap
/// boundary, the reader's boundary, and the walk all run over this table.
const rows = [_]Row{
    .{ .desc = "frame_raw", .source = &golden.frame_raw, .output = .{ .static = "zstd raw" } },
    .{ .desc = "frame_raw_empty", .source = &golden.frame_raw_empty, .output = .{ .static = "" } },
    .{ .desc = "frame_rle", .source = &golden.frame_rle, .output = .{ .static = "AAAAAAAAAA" } },
    .{
        .desc = "frame_multi",
        .source = &golden.frame_multi,
        .output = .{ .static = "abcdefghIIIIII" },
    },
    .{
        .desc = "frame_pair",
        .source = &golden.frame_pair,
        .output = .{ .static = &golden.pair_literals },
    },
    .{
        .desc = "frame_pair_errata",
        .source = &golden.frame_pair_errata,
        .output = .{ .static = &golden.pair_errata_literals },
    },
    .{
        .desc = "frame_treeless",
        .source = &golden.frame_treeless,
        .output = .{ .static = &[_]u8{ 0, 1, 4, 5, 0, 0, 0, 0, 0 } },
    },
    .{
        .desc = "frame_repeat",
        .source = &golden.frame_repeat,
        .output = .{ .static = &golden.frame_repeat_expected },
    },
    .{
        .desc = "frame_temp_offset",
        .source = &golden.frame_temp_offset,
        .output = .{ .static = &golden.frame_temp_offset_expected },
    },
    .{
        .desc = "frame_corner",
        .source = &golden.frame_corner,
        .output = .{ .static = &golden.frame_corner_expected },
    },
    .{
        .desc = "frame_two_byte",
        .source = &golden.frame_two_byte,
        .output = .{ .static = &golden.frame_two_byte_expected },
    },
    .{
        .desc = "frame_zero_seq",
        .source = &golden.frame_zero_seq,
        .output = .{ .static = &golden.frame_zero_seq_expected },
    },
    .{
        .desc = "frame_zero_seq_2b",
        .source = &golden.frame_zero_seq_2b,
        .output = .{ .static = &golden.frame_zero_seq_expected },
    },
    .{
        .desc = "frame_sequences_predefined",
        .source = &golden.frame_sequences_predefined,
        .output = .{ .static = &golden.sequences_predefined_expected },
    },
    .{
        .desc = "frame_sequences_rle_match_lengths",
        .source = &golden.frame_sequences_rle_match_lengths,
        .output = .{ .static = &golden.sequences_rle_match_lengths_expected },
    },
    .{
        .desc = "frame_sequences_fse_offsets",
        .source = &golden.frame_sequences_fse_offsets,
        .output = .{ .static = &golden.sequences_fse_offsets_expected },
    },
    .{
        .desc = "frame_sequences_fse_all",
        .source = &golden.frame_sequences_fse_all,
        .output = .{ .static = &golden.sequences_fse_all_expected },
    },
    .{
        .desc = "frame_literals_1stream",
        .source = &golden.frame_literals_1stream,
        .output = .{ .static = &golden.literals_1stream_expected },
    },
    .{
        .desc = "frame_literals_4stream_sf1",
        .source = &golden.frame_literals_4stream_sf1,
        .output = .{ .static = &golden.literals_4stream_sf1_expected },
    },
    .{
        .desc = "frame_literals_4stream_sf2",
        .source = &golden.frame_literals_4stream_sf2,
        .output = .{ .static = &golden.literals_4stream_sf2_expected },
    },
    .{
        .desc = "frame_literals_fse_tree",
        .source = &golden.frame_literals_fse_tree,
        .output = .{ .static = &golden.literals_fse_tree_expected },
    },
    .{ .desc = "frame_fcs1", .source = &golden.frame_fcs1, .output = .{ .static = "01234567" } },
    .{
        .desc = "frame_fcs2",
        .source = &golden.frame_fcs2,
        .output = .{ .splat = .{ .byte = 'A', .count = 300 } },
    },
    .{
        .desc = "frame_fcs2_single_segment",
        .source = &golden.frame_fcs2_single_segment,
        .output = .{ .splat = .{ .byte = 'A', .count = 300 } },
    },
    .{ .desc = "frame_fcs4", .source = &golden.frame_fcs4, .output = .{ .static = "01234567" } },
    .{ .desc = "frame_fcs8", .source = &golden.frame_fcs8, .output = .{ .static = "01234567" } },
    .{
        .desc = "frame_unused_bit",
        .source = &golden.frame_unused_bit,
        .output = .{ .static = "abcd" },
    },
    .{
        .desc = "frame_checksum",
        .source = &golden.frame_checksum,
        .output = .{ .static = "abcd" },
    },
    .{
        .desc = "frame_checksum_empty",
        .source = &golden.frame_checksum_empty,
        .output = .{ .static = "" },
    },
    .{
        .desc = "frame_checksum_off",
        .source = &golden.frame_checksum_off,
        .output = .{ .static = "abcd" },
    },
    .{
        .desc = "frame_checksum_multi",
        .source = &golden.frame_checksum_multi,
        .output = .{ .repeat = .{ .text = golden.frame_checksum_multi_text, .count = 3000 } },
    },
    .{
        .desc = "frame_window_1k",
        .source = &golden.frame_window_1k,
        .output = .{ .two_runs = .{
            .first_byte = 'A',
            .first_count = 1024,
            .second_byte = 'B',
            .second_count = 1024,
            .tail = "BBB",
        } },
    },
    .{
        .desc = "frame_window_1k_span",
        .source = &golden.frame_window_1k_span,
        .output = .{ .two_runs = .{
            .first_byte = 'A',
            .first_count = 1024,
            .second_byte = 'B',
            .second_count = 1024,
            .tail = "0123456789BBB",
        } },
    },
    .{
        .desc = "frame_window_128k",
        .source = &golden.frame_window_128k,
        .output = .{ .two_runs = .{
            .first_byte = 'A',
            .first_count = 131072,
            .second_byte = 'B',
            .second_count = 131072,
            .tail = "BBB",
        } },
    },
    .{
        .desc = "frame_window_1152",
        .source = &golden.frame_window_1152,
        .output = .{ .static = "" },
    },
    .{
        .desc = "skippable_prefix",
        .source = &golden.skippable_prefix,
        .output = .{ .static = "zstd raw" },
    },
    .{
        .desc = "skippable_sixteen",
        .source = &golden.skippable_sixteen,
        .output = .{ .static = "" },
    },
    .{
        .desc = "skippable_around",
        .source = &golden.skippable_around,
        .output = .{ .static = "zstd raw" },
    },
    .{
        .desc = "frame_trailing_garbage",
        .source = &golden.frame_trailing_garbage,
        .output = .{ .static = "zstd raw" },
    },
    .{
        .desc = "frame_two_frames",
        .source = &golden.frame_two_frames,
        .output = .{ .static = "zstd raw" },
    },
};

/// The index of a good row by name, at comptime — the seeds below name their
/// rows instead of numbering them.
fn rowIndex(comptime desc: []const u8) usize {
    comptime {
        @setEvalBranchQuota(10_000);
        for (rows, 0..) |row, index| {
            if (mem.eql(u8, row.desc, desc)) return index;
        }
        @compileError("no good row named " ++ desc);
    }
}

comptime {
    for (rows) |row| {
        assert(row.source.len <= source_max);
        assert(row.source.len >= frame.magic_len);
    }
}

const BadRow = struct {
    desc: []const u8,
    source: []const u8,
    err: decode.DecompressError,
    /// The bytes the one-shot's failing decode wrote before the error: the
    /// sentinel floor, each one the count `decode.zig`'s tests pin.
    written: usize,
};

/// The bad-frame corpus (`golden.zig` records the CLI's exit-1 verdict for
/// each): the pinned error and the written floor the one-shot's tests
/// establish. Rows where the C reference accepts the frame say so in a
/// comment.
const bad_rows = [_]BadRow{
    .{ .desc = "empty", .source = "", .err = error.Truncated, .written = 0 },
    .{ .desc = "frame_magic", .source = &golden.frame_magic, .err = error.Truncated, .written = 0 },
    .{
        .desc = "frame_reserved_bit",
        .source = &golden.frame_reserved_bit,
        .err = error.ReservedBitSet,
        .written = 0,
    },
    .{
        .desc = "frame_dictionary_id",
        .source = &golden.frame_dictionary_id,
        .err = error.DictionaryRequired,
        .written = 0,
    },
    .{
        .desc = "frame_dictionary_id_wide",
        .source = &golden.frame_dictionary_id_wide,
        .err = error.DictionaryRequired,
        .written = 0,
    },
    .{
        .desc = "frame_dictionary_id_truncated",
        .source = &golden.frame_dictionary_id_truncated,
        .err = error.Truncated,
        .written = 0,
    },
    .{
        .desc = "frame_reserved",
        .source = &golden.frame_reserved,
        .err = error.ReservedBlock,
        .written = 0,
    },
    .{
        .desc = "frame_oversize_raw",
        .source = &golden.frame_oversize_raw,
        .err = error.BlockOversize,
        .written = 0,
    },
    .{
        .desc = "frame_oversize_rle",
        .source = &golden.frame_oversize_rle,
        .err = error.BlockOversize,
        .written = 0,
    },
    .{
        .desc = "frame_single_segment_oversize",
        .source = &golden.frame_single_segment_oversize,
        .err = error.BlockOversize,
        .written = 0,
    },
    .{
        .desc = "frame_amplify_match",
        .source = &golden.frame_amplify_match,
        .err = error.BlockOversize,
        .written = 16,
    },
    .{
        .desc = "frame_oversize_literals",
        .source = &golden.frame_oversize_literals,
        .err = error.LiteralsTooLarge,
        .written = 0,
    },
    .{
        .desc = "frame_treeless_first",
        .source = &golden.frame_treeless_first,
        .err = error.TreelessLiteralsFirst,
        .written = 0,
    },
    .{
        .desc = "frame_repeat_first",
        .source = &golden.frame_repeat_first,
        .err = error.RepeatModeFirst,
        .written = 0,
    },
    .{
        .desc = "frame_no_sequences",
        .source = &golden.frame_no_sequences,
        .err = error.MalformedSequencesHeader,
        .written = 0,
    },
    .{
        .desc = "frame_short_sequences",
        .source = &golden.frame_short_sequences,
        .err = error.MalformedSequencesHeader,
        .written = 0,
    },
    .{
        .desc = "frame_short_raw",
        .source = &golden.frame_short_raw,
        .err = error.Truncated,
        .written = 0,
    },
    .{
        .desc = "frame_short_compressed",
        .source = &golden.frame_short_compressed,
        .err = error.Truncated,
        .written = 0,
    },
    .{
        .desc = "frame_truncated_header",
        .source = &golden.frame_truncated_header,
        .err = error.Truncated,
        .written = 0,
    },
    // A zero-size Compressed_Block. This decoder looks for the literals
    // header that is not there and returns an error; the C reference reads
    // the empty block as a no-op.
    .{
        .desc = "frame_empty_compressed",
        .source = &golden.frame_empty_compressed,
        .err = error.MalformedLiteralsHeader,
        .written = 0,
    },
    .{
        .desc = "frame_fcs_short",
        .source = &golden.frame_fcs_short,
        .err = error.ContentSizeMismatch,
        .written = 8,
    },
    .{
        .desc = "frame_fcs_long",
        .source = &golden.frame_fcs_long,
        .err = error.ContentSizeMismatch,
        .written = 8,
    },
    // Frame_Content_Size 2^64-1: a declaration like any other, checked
    // against the decode. The C reference skips the check because it reads
    // this value as ZSTD_CONTENTSIZE_UNKNOWN.
    .{
        .desc = "frame_fcs_max",
        .source = &golden.frame_fcs_max,
        .err = error.ContentSizeMismatch,
        .written = 4,
    },
    // A match one byte past the declared window: this decoder enforces
    // §3.1.1.4's bound where the C's whole-buffer decoder accepts it.
    .{
        .desc = "frame_window_1k_over",
        .source = &golden.frame_window_1k_over,
        .err = error.OffsetTooFar,
        .written = 2048,
    },
    .{
        .desc = "frame_window_128k_over",
        .source = &golden.frame_window_128k_over,
        .err = error.OffsetTooFar,
        .written = 262144,
    },
    .{
        .desc = "frame_checksum_corrupt",
        .source = &golden.frame_checksum_corrupt,
        .err = error.WrongChecksum,
        .written = 4,
    },
    .{
        .desc = "frame_checksum_truncated",
        .source = &golden.frame_checksum_truncated,
        .err = error.Truncated,
        .written = 4,
    },
    .{
        .desc = "frame_bad_magic",
        .source = &golden.frame_bad_magic,
        .err = error.BadMagic,
        .written = 0,
    },
    .{
        .desc = "skippable_bad_magic",
        .source = &golden.skippable_bad_magic,
        .err = error.BadMagic,
        .written = 0,
    },
    .{
        .desc = "skippable_truncated",
        .source = &golden.skippable_truncated,
        .err = error.Truncated,
        .written = 0,
    },
    // §3.1.2's field maximum: 4 GiB of User_Data with three bytes present.
    // User_Data is skipped by arithmetic, never staged.
    .{
        .desc = "skippable_huge",
        .source = &golden.skippable_huge,
        .err = error.Truncated,
        .written = 0,
    },
};

fn badIndex(comptime desc: []const u8) usize {
    comptime {
        @setEvalBranchQuota(10_000);
        for (bad_rows, 0..) |row, index| {
            if (mem.eql(u8, row.desc, desc)) return index;
        }
        @compileError("no bad row named " ++ desc);
    }
}

// ---------------------------------------------------------------------------
// The frame-structure model: the walk the mutations and boundary checks share
// ---------------------------------------------------------------------------

/// One complete frame unit's structure, walked with the public `frame` and
/// `block` API — the model the mutations classify against and the boundary
/// the reader's clean end is pinned to. `null` when the bytes do not form one
/// complete unit (a truncated chain, a partial skippable frame, a reserved
/// block, a missing trailer).
const FrameInfo = struct {
    /// The Zstandard frame's magic offset (after any leading skippable
    /// frames, `§3.1.2`).
    start: usize,
    header: frame.Header,
    /// The first Block_Header's offset and its parsed header.
    first_block_at: usize,
    first_block: block.Header,
    /// The first block's Block_Content offset.
    first_content_at: usize,
    /// How many blocks the chain carries.
    block_count: usize,
    /// The checksum trailer's offset, when the frame has one (`§3.1.1`).
    trailer_at: ?usize,
    /// The unit's last byte plus one: the reader's boundary.
    end: usize,
};

fn analyze(source: []const u8) ?FrameInfo {
    var cursor: usize = 0;
    while (true) {
        const kind = frame.classify(source[cursor..]) catch return null;
        if (kind == .zstandard) break;
        const head_len = frame.magic_len + frame.frame_size_len;
        if (source.len - cursor < head_len) return null;
        const user_len: usize =
            @intCast(readInt(u32, source[cursor + frame.magic_len ..][0..frame.frame_size_len]));
        if (source.len - cursor - head_len < user_len) return null;
        cursor += head_len + user_len;
    }
    const start = cursor;
    cursor += frame.magic_len;
    const header = frame.parseHeader(source[cursor..]) catch return null;
    cursor += header.bytes_consumed;
    var first_block: block.Header = undefined;
    var first_block_at: usize = 0;
    var first_content_at: usize = 0;
    var block_count: usize = 0;
    while (true) {
        const header_at = cursor;
        const bh = block.parseHeader(source[cursor..]) catch return null;
        if (block_count == 0) {
            first_block = bh;
            first_block_at = header_at;
            first_content_at = header_at + block.block_header_len;
        }
        block_count += 1;
        if (bh.block_type == .reserved) return null;
        cursor += block.block_header_len + block.contentLength(bh);
        if (cursor > source.len) return null;
        if (bh.last_block) break;
    }
    const trailer_at: ?usize = if (header.checksum) cursor else null;
    if (header.checksum) {
        if (source.len - cursor < frame.checksum_len) return null;
        cursor += frame.checksum_len;
    }
    return .{
        .start = start,
        .header = header,
        .first_block_at = first_block_at,
        .first_block = first_block,
        .first_content_at = first_content_at,
        .block_count = block_count,
        .trailer_at = trailer_at,
        .end = cursor,
    };
}

/// One unit sequence's boundary model: the first Zstandard frame's structure
/// when the sequence carries one, else the skippable-only span (`§3.1.2` —
/// a stream of only skippable frames is the clean end with zero bytes
/// served).
const Unit = struct {
    /// The first Zstandard frame, when there is one.
    frame: ?FrameInfo,
    /// The reader's boundary: the first frame's end, or the end of the
    /// skippable run.
    end: usize,
    /// Whether a checksum trailer is verified at the boundary.
    checksum: bool,
};

fn unitOf(source: []const u8) Unit {
    if (analyze(source)) |info| {
        return .{ .frame = info, .end = info.end, .checksum = info.header.checksum };
    }
    return .{ .frame = null, .end = source.len, .checksum = false };
}

// ---------------------------------------------------------------------------
// Target 1: the golden corpus through the one-shot and the walk
// ---------------------------------------------------------------------------

/// The `streamAll` walk's expected shape over a unit sequence.
const WalkKind = enum {
    /// Every frame unit decodes; the served bytes are the model's.
    all,
    /// Nothing but skippable frames (or nothing at all): the clean end with
    /// zero bytes served (`§3.1.2`).
    zero,
    /// The first unit decodes, then the walk returns an error on the bytes
    /// after it (the coarse `error.ReadFailed`; the detail is the walk's own
    /// reader's).
    first_then_fail,
};

const WalkRow = struct { desc: []const u8, source: []const u8, output: Output, kind: WalkKind };

/// The walk corpus: concatenated frames (the CLI decodes both),
/// skippable-only input (the clean end, zero bytes), and garbage after a unit
/// (an error, never silently skipped).
const walk_rows = [_]WalkRow{
    .{
        .desc = "frame_raw",
        .source = &golden.frame_raw,
        .output = .{ .static = "zstd raw" },
        .kind = .all,
    },
    .{
        .desc = "frame_two_frames",
        .source = &golden.frame_two_frames,
        .output = .{ .static = "zstd raw" ++ "second" },
        .kind = .all,
    },
    .{
        .desc = "skippable_prefix",
        .source = &golden.skippable_prefix,
        .output = .{ .static = "zstd raw" },
        .kind = .all,
    },
    .{
        .desc = "skippable_around",
        .source = &golden.skippable_around,
        .output = .{ .static = "zstd raw" },
        .kind = .all,
    },
    .{
        .desc = "frame_checksum_multi",
        .source = &golden.frame_checksum_multi,
        .output = .{ .repeat = .{ .text = golden.frame_checksum_multi_text, .count = 3000 } },
        .kind = .all,
    },
    .{
        .desc = "skippable_sixteen",
        .source = &golden.skippable_sixteen,
        .output = .{ .static = "" },
        .kind = .zero,
    },
    .{ .desc = "empty", .source = "", .output = .{ .static = "" }, .kind = .zero },
    .{
        .desc = "frame_trailing_garbage",
        .source = &golden.frame_trailing_garbage,
        .output = .{ .static = "zstd raw" },
        .kind = .first_then_fail,
    },
    .{
        .desc = "frame_checksum_corrupt",
        .source = &golden.frame_checksum_corrupt,
        .output = .{ .static = "abcd" },
        .kind = .first_then_fail,
    },
    .{
        .desc = "frame_fcs_max",
        .source = &golden.frame_fcs_max,
        .output = .{ .static = "abcd" },
        .kind = .first_then_fail,
    },
};

/// The reader over one frame unit, pumped to its clean end: identity against
/// the model, the trailer-verified clean end (no detail, state `done`), the
/// exact frame boundary with the markers unconsumed, and stickiness.
fn expectReaderIdentity(unit: Unit, framed: []const u8, expected: []const u8) !void {
    var got: [out_max]u8 = undefined;
    var fw: Io.Writer = .fixed(&got);
    var rbuf: Reader.Buffer(fixture_window_len) = undefined;
    var fixed_in: Io.Reader = .fixed(framed);
    var r: Reader = .init(fixture_window_len, &fixed_in, &rbuf, null);
    try pump(&r.reader, &fw, pumpLimit(expected.len));
    try testing.expectEqual(expected.len, fw.end);
    try testing.expectEqualSlices(u8, expected, got[0..fw.end]);
    try testing.expectEqual(@as(?Reader.Error, null), r.err);
    try testing.expectEqual(internal.reader.State.done, r.state);
    try testing.expectEqual(unit.end, fixed_in.seek);
    try expectTrailerConsistent(framed[0..unit.end], unit.end, expected, unit.checksum);
    try expectStickyEnd(&r);
}

/// The `streamAll` walk over a unit sequence, checked against its kind.
fn expectWalk(row: WalkRow) !void {
    var expected_buf: [out_max]u8 = undefined;
    const expected = materialize(row.output, &expected_buf);
    var got: [out_max]u8 = undefined;
    var fw: Io.Writer = .fixed(&got);
    var rbuf: Reader.Buffer(fixture_window_len) = undefined;
    var fixed_in: Io.Reader = .fixed(row.source);
    switch (row.kind) {
        .all => {
            const served = try Reader.streamAll(fixture_window_len, &fixed_in, &fw, &rbuf, null);
            try testing.expectEqual(expected.len, served);
            try testing.expectEqualSlices(u8, expected, fw.buffered());
            try testing.expectEqual(row.source.len, fixed_in.seek);
        },
        .zero => {
            const served = try Reader.streamAll(fixture_window_len, &fixed_in, &fw, &rbuf, null);
            try testing.expectEqual(@as(usize, 0), served);
            try testing.expectEqual(@as(usize, 0), fw.end);
            try testing.expectEqual(row.source.len, fixed_in.seek);
        },
        .first_then_fail => {
            try testing.expectError(
                error.ReadFailed,
                Reader.streamAll(fixture_window_len, &fixed_in, &fw, &rbuf, null),
            );
            try testing.expectEqualSlices(u8, expected, fw.buffered());
        },
    }
}

/// Seeds for `fuzzGoldenCorpus`: one per good row (the row index, a cap shape,
/// and a walk row), so the plain `zig build test` run replays every fixture.
const corpus: []const []const u8 = blk: {
    @setEvalBranchQuota(100_000);
    const seeds: [rows.len][24]u8 = init: {
        var built: [rows.len][24]u8 = undefined;
        for (&built, 0..) |*seed, index| {
            mem.writeInt(u64, seed[0..8], @intCast(index), .little);
            mem.writeInt(u64, seed[8..16], @intCast(index % 4), .little);
            mem.writeInt(u64, seed[16..24], @intCast(index % walk_rows.len), .little);
        }
        break :init built;
    };
    var slices: [rows.len][]const u8 = undefined;
    for (&slices, 0..) |*slice, index| slice.* = &seeds[index];
    const frozen = slices;
    break :blk &frozen;
};

/// The whole one-shot decoder over the golden corpus.
///
/// The corpus covers Raw, RLE, and compressed blocks, the literals size
/// formats, the sequences modes, the Frame_Content_Size forms, the window
/// fixtures, the checksum trailer, skippable frames, and bytes after the
/// frame. Each iteration decodes one fixture at the exact cap, below it, and
/// with slack. It checks that nothing past the cap was written, that a second
/// decode gives the same bytes, and that the streaming reader serves the same
/// bytes and stops at the same frame boundary. It also runs one `streamAll`
/// walk row. The expected bytes are the C CLI's own `zstd -d` output
/// (`golden.zig`), so the identity check is a differential against the C
/// library, not against a local encoder.
fn fuzzGoldenCorpus(_: void, smith: *Smith) anyerror!void {
    const row = rows[smith.index(rows.len)];
    const shape = rangeAtMost(smith, 0, 3);
    const walk = walk_rows[smith.index(walk_rows.len)];

    var expected_buf: [out_max]u8 = undefined;
    const expected = materialize(row.output, &expected_buf);
    const unit = unitOf(row.source);
    try testing.expect(unit.end <= row.source.len);

    var window: [out_max + guard_len]u8 = undefined;

    // The exact cap: identity, and the sentinel proves nothing past it moved.
    sentinel.fill(&window);
    const n = try decode.decompress(row.source, window[0..expected.len], null);
    try testing.expectEqual(expected.len, n);
    try testing.expectEqualSlices(u8, expected, window[0..n]);
    try sentinel.expect(&window, n);

    // Slack: the bytes past the decoded length are the caller's.
    sentinel.fill(&window);
    const m = try decode.decompress(row.source, &window, null);
    try testing.expectEqual(n, m);
    try testing.expectEqualSlices(u8, expected, window[0..m]);
    try sentinel.expect(&window, m);

    // Below the decoded length: `BufferTooSmall`, and the cap held.
    if (expected.len > 0) {
        const cap = switch (shape) {
            0 => expected.len - 1,
            1 => expected.len / 2,
            2 => 0,
            else => rangeAtMost(smith, 0, expected.len - 1),
        };
        sentinel.fill(&window);
        try testing.expectError(
            error.BufferTooSmall,
            decode.decompress(row.source, window[0..cap], null),
        );
        try sentinel.expect(&window, cap);
    }

    // Determinism: a second decode of the same bytes is the same bytes.
    sentinel.fill(&window);
    const again = try decode.decompress(row.source, window[0..expected.len], null);
    try testing.expectEqual(n, again);
    try testing.expectEqualSlices(u8, expected, window[0..again]);

    // The trailing-bytes boundary: markers after a frame unit are not part
    // of it (`§3.1` defines frames, not files). A skippable-only run has no
    // frame for the tail to be after: the markers are the next unit's bytes,
    // and a bad magic is `BadMagic`.
    var framed: [source_max + marker_len]u8 = undefined;
    fastmem.copy(u8, framed[0..row.source.len], row.source);
    fastmem.set(u8, framed[row.source.len..][0..marker_len], marker_byte);
    if (unit.frame != null) {
        sentinel.fill(&window);
        const f = try decode.decompress(
            framed[0 .. row.source.len + marker_len],
            window[0..expected.len],
            null,
        );
        try testing.expectEqual(expected.len, f);
        try testing.expectEqualSlices(u8, expected, window[0..f]);
        try sentinel.expect(&window, f);
    } else {
        sentinel.fill(&window);
        try testing.expectError(
            error.BadMagic,
            decode.decompress(
                framed[0 .. row.source.len + marker_len],
                window[0..expected.len],
                null,
            ),
        );
        try sentinel.expect(&window, expected.len);
    }

    // The streaming reader over the same unit plus markers: identity and the
    // exact boundary. A skippable-only run is checked without markers — the
    // markers would be the next unit's bytes, and a bad magic there is the
    // walk's own refusal, not the unit's boundary.
    const reader_framed = if (unit.frame != null)
        framed[0 .. row.source.len + marker_len]
    else
        row.source;
    try expectReaderIdentity(unit, reader_framed, expected);

    // The `streamAll` walk over the frame units.
    try expectWalk(walk);
}

test "zstd fuzz: golden corpus" {
    try testing.fuzz({}, fuzzGoldenCorpus, .{ .corpus = corpus });
}

// ---------------------------------------------------------------------------
// Target 2: the bad-frame corpus and the mutations
// ---------------------------------------------------------------------------

/// The outcome class a mutation pins: the original output, any failure, one
/// specific error, or `unknown` when only the universal properties apply.
const Expected = enum {
    /// The mutation must decode to exactly the row's expected output.
    exact_source,
    /// Any failure: a frame whose end is gone never decodes.
    fail_any,
    /// `error.Truncated`.
    fail_truncated,
    /// `error.BadMagic`.
    fail_bad_magic,
    /// `error.ReservedBitSet` (`§3.1.1.1.1.4`).
    fail_reserved_bit,
    /// `error.DictionaryRequired` (`§3.1.1.1.3`).
    fail_dictionary,
    /// `error.BlockOversize` (`§3.1.1.2.4`).
    fail_block_oversize,
    /// `error.ReservedBlock` (`§3.1.1.2.2`).
    fail_reserved_block,
    /// `error.ContentSizeMismatch` (`§3.1.1.1.4`).
    fail_content_size,
    /// `error.WrongChecksum` (`§3.1.1`).
    fail_wrong_checksum,
    /// Success or any failure. Only the universal properties are checked: the
    /// cap held, the one-shot and the reader agree, and a clean end is
    /// trailer-verified.
    unknown,
};

const Mutated = struct {
    len: usize,
    expected: Expected,
    /// The frame unit's end in the mutated bytes: the position a clean reader
    /// end must stop at for `exact_source`.
    frame_end: usize,
};

/// The mutation operators. Each keeps `buf[0..len]` in bounds and stays
/// inside the mutation buffer.
const Mutation = enum(u8) {
    /// Cut the unit at a Smith-chosen byte: inside the trailer is
    /// `Truncated` exactly, elsewhere the bits run out first.
    truncate,
    /// A flip inside the 4-byte Magic_Number (`§3.1`, `§3.1.2`): `BadMagic`,
    /// except that a flip of a skippable magic's tag nibble stays a valid
    /// skippable frame. One flipped byte can never turn either family's magic
    /// into the other's.
    flip_magic,
    /// Descriptor bit 3 (`§3.1.1.1.1.4`): "must ensure it is not set".
    set_reserved_bit,
    /// A Dictionary_ID_Flag bit (`§3.1.1.1.3`): refused at the first ID byte,
    /// before any body byte.
    set_dictionary_flag,
    /// Descriptor bit 4 (`§3.1.1.1.1.3`): "shall not interpret this bit", so
    /// the frame decodes identically.
    flip_unused_bit,
    /// A flip in the block chain: the body's business (`unknown`).
    flip_body,
    /// A flip inside the checksum trailer: the body is untouched, so the
    /// check must fail (`§3.1.1`).
    flip_trailer,
    /// Block type 3 (`§3.1.1.2.2`): "a compliant decoder must reject it".
    block_reserved_type,
    /// Block_Size 2^21 - 1: past Block_Maximum_Size for every fixture's
    /// window (`§3.1.1.2.4`).
    block_oversize,
    /// The Last_Block bit on the first block (`§3.1.1.2.1`): a one-block
    /// frame is unchanged, a chain stops early.
    last_block_first,
    /// A poked Window_Descriptor byte (`§3.1.1.1.2`): the window arithmetic
    /// against the block max and the offset bound.
    poke_window,
    /// A poked Frame_Content_Size byte (`§3.1.1.1.4`), classified against
    /// the single-segment window coupling.
    poke_fcs,
    /// A flip inside the first compressed block's content: the entropy
    /// layers' business.
    entropy_poke,
    /// Markers after the unit: ignored by the one-shot, unconsumed by the
    /// reader.
    append_markers,
    /// A second frame unit after the first: not consumed by one reader.
    duplicate_frame,
    /// A skippable frame before the unit (`§3.1.2`): consumed and ignored.
    skippable_prefix,
    /// A skippable frame declaring 4 GiB of User_Data with three bytes
    /// present: the walk runs out, nothing is staged.
    skippable_huge_prefix,
};

/// The byte range a body mutation may touch: the first block up to the
/// trailer (or the unit's end).
fn bodyEnd(info: FrameInfo) usize {
    return info.trailer_at orelse info.end;
}

/// Read a Frame_Content_Size field (`§3.1.1.1.4`): the 2-byte form carries
/// the +256 offset.
fn readFcs(bytes: []const u8) u64 {
    return switch (bytes.len) {
        1 => bytes[0],
        2 => @as(u64, readInt(u16, bytes[0..2])) + 256,
        4 => readInt(u32, bytes[0..4]),
        8 => readInt(u64, bytes[0..8]),
        else => unreachable,
    };
}

/// Poke one Frame_Content_Size byte and classify (`§3.1.1.1.4`): a
/// non-single-segment frame's window is untouched, so the only new failure is
/// the size check; a single-segment frame's Window_Size *is* the FCS
/// (`§3.1.1.1.1.2`), so a smaller declaration can starve Block_Maximum_Size
/// and fail `BlockOversize` first, while a larger one still ends at the size
/// check.
fn pokeFcs(smith: *Smith, buf: []u8, info: FrameInfo) Mutated {
    const fcs_len = frame.fcsFieldSize(info.header.descriptor);
    if (fcs_len == 0) {
        // No Frame_Content_Size to poke: the body flip stands in.
        buf[rangeAtMost(smith, info.first_block_at, bodyEnd(info))] ^= flipValue(smith);
        return .{ .len = info.end, .expected = .unknown, .frame_end = info.end };
    }
    // The FCS is the header's last field, so it ends where the block chain
    // begins.
    const fcs_at = info.first_block_at - fcs_len;
    buf[fcs_at + rangeAtMost(smith, 0, fcs_len - 1)] ^= flipValue(smith);
    const new_fcs = readFcs(buf[fcs_at..][0..fcs_len]);
    const block_max: u64 = @min(new_fcs, @as(u64, block.max_block_size));
    const oversize = info.first_block.block_size > block_max;
    var expected: Expected = .fail_content_size;
    if (info.header.descriptor & frame.descriptor_single_segment != 0) {
        if (oversize) {
            expected = .fail_block_oversize;
        } else if (new_fcs < info.header.window_size) {
            // The window shrank: a match may now reach past it (`§3.1.1.4`),
            // so the failure's name is the decode's business.
            expected = .unknown;
        }
    }
    return .{ .len = info.end, .expected = expected, .frame_end = info.end };
}

/// Apply one Smith-chosen mutation to the row's frame unit in `buf` and
/// return the mutated length, the outcome class it pins, and the unit's end in
/// the mutated bytes.
fn mutate(smith: *Smith, buf: []u8, row: Row) Mutated {
    // The comptime-known prefix lengths below (the skippable-magic arrays)
    // drive fastmem's inline dispatch search past the default comptime
    // branch quota on the 32-bit baseline targets (where the search's
    // fallback table is the widest); raised once, here, for the whole body.
    @setEvalBranchQuota(1_000_000);
    const info = analyze(row.source).?;
    fastmem.copy(u8, buf[0..row.source.len], row.source);
    var len = row.source.len;
    var frame_end = info.end;
    var expected: Expected = .unknown;
    switch (smith.value(Mutation)) {
        .truncate => {
            const cut = rangeAtMost(smith, 0, row.source.len - 1);
            len = cut;
            if (cut >= frame_end) {
                // The unit is complete; only bytes after it were cut.
                expected = .exact_source;
            } else if (cut > 0 and cut == info.start) {
                // The cut removed the whole Zstandard frame and left only
                // complete skippable frames: the only-skippables clean end
                // with zero bytes served (`§3.1.2`).
                expected = .unknown;
            } else if (cut < info.first_block_at) {
                // Inside a leading skippable frame, the Magic_Number, or the
                // Frame_Header: the input ends before any body byte.
                expected = .fail_truncated;
            } else if (info.trailer_at) |trailer_at| {
                // The body's bits run out first; a cut inside the trailer
                // leaves the body intact and is `Truncated` exactly.
                expected = if (cut >= trailer_at) .fail_truncated else .fail_any;
            } else {
                expected = .fail_any;
            }
        },
        .flip_magic => {
            buf[rangeAtMost(smith, 0, frame.magic_len - 1)] ^= flipValue(smith);
            // One byte of either magic can never reach the other family,
            // but a skippable magic's low nibble is its tag (`§3.1.2`): a
            // flip that keeps the front in the skippable range (byte 0 into
            // 0x50-0x5f) leaves a valid frame unit, and the walk proceeds
            // to the frame behind it.
            const magic_now = readInt(u32, buf[0..frame.magic_len]);
            expected = if (magic_now & frame.skippable_magic_mask == frame.skippable_magic_base)
                .exact_source
            else
                .fail_bad_magic;
        },
        .set_reserved_bit => {
            buf[info.start + frame.magic_len] |= frame.descriptor_reserved;
            expected = .fail_reserved_bit;
        },
        .set_dictionary_flag => {
            // §3.1.1.1.3 — the DID field is read whole and a value of 0
            // means "no Dictionary_ID", so the flag alone is not enough for
            // the no-dictionary refusal: the field's first byte (low byte,
            // little-endian) is forced nonzero. The header is corrupt either
            // way, and the check fires before any body byte.
            const descriptor_at = info.start + frame.magic_len;
            const bit: u8 = @as(u8, 1) << @intCast(rangeAtMost(smith, 0, 1));
            buf[descriptor_at] |= bit;
            const window_len: usize = if (buf[descriptor_at] & frame.descriptor_single_segment == 0)
                1
            else
                0;
            buf[descriptor_at + 1 + window_len] |= 0x2a;
            expected = .fail_dictionary;
        },
        .flip_unused_bit => {
            buf[info.start + frame.magic_len] ^= frame.descriptor_unused;
            expected = .exact_source;
        },
        .flip_body => {
            buf[rangeAtMost(smith, info.first_block_at, bodyEnd(info))] ^= flipValue(smith);
            expected = .unknown;
        },
        .flip_trailer => {
            if (info.trailer_at) |trailer_at| {
                const at = trailer_at + rangeAtMost(smith, 0, frame.checksum_len - 1);
                buf[at] ^= flipValue(smith);
                expected = .fail_wrong_checksum;
            } else {
                buf[rangeAtMost(smith, info.first_block_at, bodyEnd(info))] ^= flipValue(smith);
                expected = .unknown;
            }
        },
        .block_reserved_type => {
            buf[info.first_block_at] |= 0b0000_0110;
            expected = .fail_reserved_block;
        },
        .block_oversize => {
            buf[info.first_block_at] |= 0b1111_1000;
            buf[info.first_block_at + 1] = 0xff;
            buf[info.first_block_at + 2] = 0xff;
            expected = .fail_block_oversize;
        },
        .last_block_first => {
            buf[info.first_block_at] |= 1;
            expected = if (info.block_count == 1) .exact_source else .unknown;
        },
        .poke_window => {
            if (info.header.descriptor & frame.descriptor_single_segment != 0) {
                // Single-segment: Window_Size is the FCS; the FCS poke is
                // the same mutation.
                return pokeFcs(smith, buf, info);
            }
            buf[info.start + frame.magic_len + 1] = smith.value(u8);
            expected = .unknown;
        },
        .poke_fcs => return pokeFcs(smith, buf, info),
        .entropy_poke => {
            if (info.first_block.block_type == .compressed and info.first_block.block_size > 0) {
                const at = info.first_content_at +
                    rangeAtMost(smith, 0, info.first_block.block_size - 1);
                buf[at] ^= flipValue(smith);
            } else {
                buf[rangeAtMost(smith, info.first_block_at, bodyEnd(info))] ^= flipValue(smith);
            }
            expected = .unknown;
        },
        .append_markers => {
            const extra = rangeAtMost(smith, 1, 64);
            fastmem.set(u8, buf[len..][0..extra], marker_byte);
            len += extra;
            expected = .exact_source;
        },
        .duplicate_frame => {
            fastmem.copy(u8, buf[len..][0..frame_end], buf[0..frame_end]);
            len += frame_end;
            expected = .exact_source;
        },
        .skippable_prefix => {
            const prefix = [_]u8{ 0x50, 0x2a, 0x4d, 0x18, 4, 0, 0, 0, 'm', 'e', 't', 'a' };
            fastmem.move(u8, buf[prefix.len..][0..row.source.len], buf[0..row.source.len]);
            fastmem.copy(u8, buf[0..prefix.len], &prefix);
            len += prefix.len;
            frame_end += prefix.len;
            expected = .exact_source;
        },
        .skippable_huge_prefix => {
            const prefix = [_]u8{ 0x51, 0x2a, 0x4d, 0x18, 0xff, 0xff, 0xff, 0xff, 'a', 'b', 'c' };
            fastmem.move(u8, buf[prefix.len..][0..row.source.len], buf[0..row.source.len]);
            fastmem.copy(u8, buf[0..prefix.len], &prefix);
            len += prefix.len;
            expected = .fail_truncated;
        },
    }
    return .{ .len = len, .expected = expected, .frame_end = frame_end };
}

/// The one-shot under the mutated bytes, checked against the mutation's
/// class. Every decode pre-fills the window with cycling sentinels and proves
/// the bytes at and past the cap are untouched.
fn checkOneShot(mutated: []const u8, expected_output: []const u8, meta: Mutated, cap: usize) !void {
    var window: [out_max + guard_len]u8 = undefined;
    sentinel.fill(&window);
    const target = window[0..cap];
    const result = decode.decompress(mutated, target, null);
    switch (meta.expected) {
        .exact_source => {
            const n = try result;
            try testing.expectEqual(expected_output.len, n);
            try testing.expectEqualSlices(u8, expected_output, target[0..n]);
            try sentinel.expect(&window, n);
        },
        .fail_any => {
            try expectFailure(result);
            try sentinel.expect(&window, cap);
        },
        .fail_truncated => {
            try testing.expectError(error.Truncated, result);
            try sentinel.expect(&window, cap);
        },
        .fail_bad_magic => {
            try testing.expectError(error.BadMagic, result);
            try sentinel.expect(&window, cap);
        },
        .fail_reserved_bit => {
            try testing.expectError(error.ReservedBitSet, result);
            try sentinel.expect(&window, cap);
        },
        .fail_dictionary => {
            try testing.expectError(error.DictionaryRequired, result);
            try sentinel.expect(&window, cap);
        },
        .fail_block_oversize => {
            try testing.expectError(error.BlockOversize, result);
            try sentinel.expect(&window, cap);
        },
        .fail_reserved_block => {
            try testing.expectError(error.ReservedBlock, result);
            try sentinel.expect(&window, cap);
        },
        .fail_content_size => {
            try testing.expectError(error.ContentSizeMismatch, result);
            try sentinel.expect(&window, cap);
        },
        .fail_wrong_checksum => {
            try testing.expectError(error.WrongChecksum, result);
            try sentinel.expect(&window, cap);
        },
        .unknown => {
            if (result) |n| {
                try testing.expect(n <= cap);
                try sentinel.expect(&window, n);
            } else |_| {
                try sentinel.expect(&window, cap);
            }
        },
    }
}

/// The reader's window cap is the one refusal the one-shot does not have
/// (`§3.1.1.1.2`: "a decoder is allowed to reject a compressed frame that
/// requests a memory size beyond the decoder's authorized range"): a pinned
/// frame-layer detail must hold unless the mutated frame's declared window
/// exceeds the reader buffer's, where `WindowTooLarge` is the reader's
/// answer and the pinned detail remains the one-shot's.
fn expectReaderDetail(
    detail: Reader.Error,
    want: Reader.Error,
    info: ?FrameInfo,
    expected: Expected,
) !void {
    // The reader's own refusal is the window cap, but it is checked after the
    // header's own refusals (the magic, the reserved bit, the Dictionary_ID):
    // a mutation that pins one of those keeps its name even when the mutated
    // header also declares a window past the buffer.
    const header_stage = switch (expected) {
        .fail_bad_magic, .fail_reserved_bit, .fail_dictionary => true,
        else => false,
    };
    if (!header_stage) {
        if (info) |i| {
            if (i.header.window_size > fixture_window_len) {
                try testing.expectEqual(Reader.Error.WindowTooLarge, detail);
                return;
            }
        }
    }
    try testing.expectEqual(want, detail);
}

/// The streaming reader under the mutated bytes, checked against the
/// mutation's class and the one-shot's uncapped verdict. The universal
/// property: the two decode paths agree — a reader failure on bytes the
/// uncapped one-shot decoded is the window cap (`WindowTooLarge`), the one
/// refusal only the reader has — and a clean end proves the trailer matched
/// the reference XXH64 of the reader's own output at the exact boundary.
fn checkReader(
    mutated: []const u8,
    expected_output: []const u8,
    meta: Mutated,
    info: ?FrameInfo,
    full: decode.DecompressError!usize,
    full_output: []const u8,
) !void {
    var got: [out_max]u8 = undefined;
    var fw: Io.Writer = .fixed(&got);
    var rbuf: Reader.Buffer(fixture_window_len) = undefined;
    var fixed_in: Io.Reader = .fixed(mutated);
    var r: Reader = .init(fixture_window_len, &fixed_in, &rbuf, null);
    const pumped = try pumpCapped(&r.reader, &fw, pumpLimit(out_max));
    const served = pumped.served;

    switch (pumped.stop) {
        .end_of_stream => {
            try testing.expect(meta.expected == .exact_source or meta.expected == .unknown);
            try testing.expectEqual(internal.reader.State.done, r.state);
            try testing.expectEqual(@as(?Reader.Error, null), r.err);
            if (meta.expected == .exact_source) {
                try testing.expectEqual(expected_output.len, served);
                try testing.expectEqualSlices(u8, expected_output, got[0..served]);
                try testing.expectEqual(meta.frame_end, fixed_in.seek);
            }
            if (full) |m| {
                try testing.expectEqual(m, served);
                try testing.expectEqualSlices(u8, full_output[0..m], got[0..served]);
            } else |err| switch (err) {
                // The reader has no output cap: it cannot end cleanly on
                // bytes the uncapped one-shot refused.
                else => return error.ReaderOutranOneShot,
            }
            if (info) |i| {
                try expectTrailerConsistent(
                    mutated,
                    fixed_in.seek,
                    got[0..served],
                    i.header.checksum,
                );
            }
            try expectStickyEnd(&r);
        },
        .read_failed => {
            try testing.expect(meta.expected != .exact_source);
            const detail = r.err.?;
            switch (meta.expected) {
                .fail_truncated => try expectReaderDetail(
                    detail,
                    Reader.Error.Truncated,
                    info,
                    meta.expected,
                ),
                .fail_bad_magic => try expectReaderDetail(
                    detail,
                    Reader.Error.BadMagic,
                    info,
                    meta.expected,
                ),
                .fail_reserved_bit => try expectReaderDetail(
                    detail,
                    Reader.Error.ReservedBitSet,
                    info,
                    meta.expected,
                ),
                .fail_dictionary => try expectReaderDetail(
                    detail,
                    Reader.Error.DictionaryRequired,
                    info,
                    meta.expected,
                ),
                .fail_block_oversize => try expectReaderDetail(
                    detail,
                    Reader.Error.BlockOversize,
                    info,
                    meta.expected,
                ),
                .fail_reserved_block => try expectReaderDetail(
                    detail,
                    Reader.Error.ReservedBlock,
                    info,
                    meta.expected,
                ),
                .fail_content_size => try expectReaderDetail(
                    detail,
                    Reader.Error.ContentSizeMismatch,
                    info,
                    meta.expected,
                ),
                .fail_wrong_checksum => try expectReaderDetail(
                    detail,
                    Reader.Error.WrongChecksum,
                    info,
                    meta.expected,
                ),
                // An unpinned mutation (`unknown`) or a cut frame
                // (`fail_any`): the detail is the mutation's business. The
                // agreement check below is the pin.
                .fail_any, .unknown => {},
                .exact_source => unreachable,
            }
            if (full) |_| {
                // The uncapped one-shot decoded these bytes: the reader's
                // only own refusal is the window cap.
                try testing.expectEqual(Reader.Error.WindowTooLarge, detail);
            } else |err| {
                if (err != error.BufferTooSmall) {
                    // The reader's only own refusal is the window cap: every
                    // other detail is the one-shot's, name for name. That
                    // includes an oversized RLE block whose content byte is
                    // missing: the reader checks the declared Block_Size
                    // before reading the content, as the one-shot does (the
                    // oversized-RLE-block test at the end of this file pins
                    // it).
                    try testing.expect(
                        sameErrorName(err, detail) or
                            detail == Reader.Error.WindowTooLarge,
                    );
                }
            }
            try expectStickyFailure(&r);
        },
        .output_full => {
            // Only an uncapped expansion past the harness window (an
            // unknown-class mutation): the cap is the writer's, not the
            // codec's.
            try testing.expectEqual(Expected.unknown, meta.expected);
            try testing.expectEqual(out_max, served);
            if (full) |m| {
                try testing.expectEqual(out_max, m);
            } else |err| {
                try testing.expectEqual(error.BufferTooSmall, err);
            }
        },
    }
}

/// Every committed negative fixture through the one-shot and the reader, with
/// the pinned error and the written floor.
fn fuzzBadRows(smith: *Smith) !void {
    const row = bad_rows[smith.index(bad_rows.len)];
    var window: [out_max + guard_len]u8 = undefined;
    sentinel.fill(&window);
    try testing.expectError(row.err, decode.decompress(row.source, window[0..out_max], null));
    try sentinel.expect(&window, row.written);

    // The streaming reader reports the same detail, stickily, before it can
    // serve past the failure.
    var got: [out_max]u8 = undefined;
    var fw: Io.Writer = .fixed(&got);
    var rbuf: Reader.Buffer(fixture_window_len) = undefined;
    var fixed_in: Io.Reader = .fixed(row.source);
    var r: Reader = .init(fixture_window_len, &fixed_in, &rbuf, null);
    const pumped = try pumpCapped(&r.reader, &fw, pumpLimit(out_max));
    try testing.expectEqual(Stop.read_failed, pumped.stop);
    try testing.expect(sameErrorName(row.err, r.err.?));
    try expectStickyFailure(&r);
}

/// The bad-frame corpus and Smith-chosen mutations of the good frames.
///
/// The mutations cover the header parse (the magic, the reserved bit, the
/// dictionary flag, the unused bit, the Frame_Content_Size forms and the
/// single-segment window coupling), the block header (the reserved type,
/// Block_Size past Block_Maximum_Size, Last_Block), the entropy bytes, the
/// checksum trailer, truncation at every position, and the skippable walk.
/// The properties: the committed fixtures' errors and written floors hold; a
/// mutation's class holds; the one-shot and the streaming reader agree on the
/// same bytes (same output, or the same named error, `WindowTooLarge`
/// excepted); a clean end is trailer-verified at the exact boundary; a failure
/// is sticky; and the cap held on every failure.
fn fuzzCorruption(_: void, smith: *Smith) anyerror!void {
    if (smith.boolWeighted(1, 3)) {
        try fuzzBadRows(smith);
        return;
    }
    const row = mutable_rows[smith.index(mutable_rows.len)];
    var expected_buf: [out_max]u8 = undefined;
    const expected = materialize(row.output, &expected_buf);

    var mut_buf: [mutation_max]u8 = undefined;
    const meta = mutate(smith, &mut_buf, row);
    try checkMutation(smith, mut_buf[0..meta.len], expected, meta);
}

/// The capped and uncapped checks every mutation gets: the class pin at a cap
/// the class can land on, the cap invariant, the determinism pin, and the
/// one-shot/reader agreement. Shared by the decode-side and encode-side
/// corruption targets.
fn checkMutation(smith: *Smith, mutated: []const u8, expected: []const u8, meta: Mutated) !void {
    const info = analyze(mutated);

    // The cap: the expected length for the pinned classes (so `exact_source`
    // can succeed and the pinned failures land where the class says), a
    // Smith-chosen cap otherwise.
    const cap = switch (meta.expected) {
        .exact_source,
        .fail_any,
        .fail_truncated,
        .fail_bad_magic,
        .fail_reserved_bit,
        .fail_dictionary,
        .fail_block_oversize,
        .fail_reserved_block,
        .fail_content_size,
        .fail_wrong_checksum,
        => expected.len,
        .unknown => rangeAtMost(smith, 0, out_max),
    };

    // The capped one-shot: the class pin and the cap invariant.
    try checkOneShot(mutated, expected, meta, cap);

    // The uncapped verdict: the reader's reference, and the determinism pin
    // (a second decode of the same bytes is the same bytes).
    var full_window: [out_max + guard_len]u8 = undefined;
    sentinel.fill(&full_window);
    const full = decode.decompress(mutated, full_window[0..out_max], null);
    const full_len = full catch out_max;
    try sentinel.expect(&full_window, full_len);
    {
        var window: [out_max + guard_len]u8 = undefined;
        sentinel.fill(&window);
        const capped = decode.decompress(mutated, window[0..cap], null);
        if (capped) |n| {
            if (full) |m| {
                try testing.expectEqual(n, m);
                try testing.expectEqualSlices(u8, window[0..n], full_window[0..m]);
            } else |_| {
                // The uncapped decode can only fail where the capped one
                // did, plus the cap itself: a capped success on bytes the
                // full window refused is a contradiction.
                return error.CapDisagreement;
            }
        } else |err| {
            // A capped failure other than the cap itself must reproduce
            // uncapped.
            if (err != error.BufferTooSmall) try testing.expectError(err, full);
        }
    }

    try checkReader(mutated, expected, meta, info, full, full_window[0..out_max]);
}

/// The rows the mutations may pick: those whose unit is a complete Zstandard
/// frame (the all-skippable row has no header to poke).
const mutable_rows: []const Row = blk: {
    @setEvalBranchQuota(100_000);
    var built: [rows.len]Row = undefined;
    var count: usize = 0;
    for (rows) |row| {
        if (analyze(row.source) != null) {
            built[count] = row;
            count += 1;
        }
    }
    const frozen = built;
    break :blk frozen[0..count];
};

fn mutableIndex(comptime desc: []const u8) usize {
    comptime {
        @setEvalBranchQuota(10_000);
        for (mutable_rows, 0..) |row, index| {
            if (mem.eql(u8, row.desc, desc)) return index;
        }
        @compileError("no mutable row named " ++ desc);
    }
}

/// A `fuzzCorruption` seed that selects the bad row `desc`. `corrupt_corpus`
/// seeds every bad row, then one mutation per operator (`mutationSeed`) over
/// the row that exercises it.
fn badSeed(comptime desc: []const u8) [16]u8 {
    var seed: [16]u8 = undefined;
    mem.writeInt(u64, seed[0..8], 1, .little);
    mem.writeInt(u64, seed[8..16], badIndex(desc), .little);
    return seed;
}

fn mutationSeed(comptime row: []const u8, comptime mutation: Mutation, comptime param: u64) [32]u8 {
    var seed: [32]u8 = undefined;
    mem.writeInt(u64, seed[0..8], 0, .little);
    mem.writeInt(u64, seed[8..16], mutableIndex(row), .little);
    mem.writeInt(u64, seed[16..24], @intFromEnum(mutation), .little);
    mem.writeInt(u64, seed[24..32], param, .little);
    return seed;
}

const corrupt_corpus: []const []const u8 = &.{
    &badSeed("empty"),
    &badSeed("frame_magic"),
    &badSeed("frame_reserved_bit"),
    &badSeed("frame_dictionary_id"),
    &badSeed("frame_dictionary_id_wide"),
    &badSeed("frame_dictionary_id_truncated"),
    &badSeed("frame_reserved"),
    &badSeed("frame_oversize_raw"),
    &badSeed("frame_oversize_rle"),
    &badSeed("frame_single_segment_oversize"),
    &badSeed("frame_amplify_match"),
    &badSeed("frame_oversize_literals"),
    &badSeed("frame_treeless_first"),
    &badSeed("frame_repeat_first"),
    &badSeed("frame_no_sequences"),
    &badSeed("frame_short_sequences"),
    &badSeed("frame_short_raw"),
    &badSeed("frame_short_compressed"),
    &badSeed("frame_truncated_header"),
    &badSeed("frame_empty_compressed"),
    &badSeed("frame_fcs_short"),
    &badSeed("frame_fcs_long"),
    &badSeed("frame_fcs_max"),
    &badSeed("frame_window_1k_over"),
    &badSeed("frame_window_128k_over"),
    &badSeed("frame_checksum_corrupt"),
    &badSeed("frame_checksum_truncated"),
    &badSeed("frame_bad_magic"),
    &badSeed("skippable_bad_magic"),
    &badSeed("skippable_truncated"),
    &badSeed("skippable_huge"),
    &mutationSeed("frame_checksum", .truncate, 20),
    &mutationSeed("frame_raw", .flip_magic, 0),
    &mutationSeed("frame_raw", .set_reserved_bit, 0),
    &mutationSeed("frame_raw", .set_dictionary_flag, 0),
    &mutationSeed("frame_raw", .flip_unused_bit, 0),
    &mutationSeed("frame_pair", .flip_body, 0),
    &mutationSeed("frame_checksum", .flip_trailer, 0),
    &mutationSeed("frame_raw", .block_reserved_type, 0),
    &mutationSeed("frame_raw", .block_oversize, 0),
    &mutationSeed("frame_multi", .last_block_first, 0),
    &mutationSeed("frame_window_1k", .poke_window, 0),
    &mutationSeed("frame_fcs4", .poke_fcs, 0),
    &mutationSeed("frame_literals_1stream", .entropy_poke, 0),
    &mutationSeed("frame_raw", .append_markers, 0),
    &mutationSeed("frame_checksum", .duplicate_frame, 0),
    &mutationSeed("frame_raw", .skippable_prefix, 0),
    &mutationSeed("frame_raw", .skippable_huge_prefix, 0),
    // Regression seed: a single-segment Frame_Content_Size poke that grows the
    // window past what the reader's buffer authorizes. The one-shot fails
    // `ContentSizeMismatch` and the reader `WindowTooLarge` (the one place the
    // two paths differ), and both must be the class the mutation pins.
    &mutationSeed("frame_checksum_multi", .poke_fcs, 3),
    // Regression seeds: a cut exactly at the leading skippable frame's end,
    // which is a clean end with zero bytes served and not a failure, and the
    // zero-byte cut, which is `Truncated` (no unit began).
    &mutationSeed("skippable_around", .truncate, 10),
    &mutationSeed("skippable_prefix", .truncate, 0),
    &mutationSeed("frame_raw", .truncate, 0),
    // Regression seed: a flip of the leading skippable magic's tag nibble
    // leaves a valid skippable frame, so the walk proceeds and the frame
    // behind it decodes (not `BadMagic`).
    &mutationSeed("skippable_around", .flip_magic, 0),
};

test "zstd fuzz: corruption" {
    try testing.fuzz({}, fuzzCorruption, .{ .corpus = corrupt_corpus });
}

// ---------------------------------------------------------------------------
// Target 3: the reader's consumer machinery
// ---------------------------------------------------------------------------

/// The consumer operations `fuzzReaderMachinery` mixes: the `Io.Reader` calls
/// a caller can make on the reader.
const ReadOp = enum(u8) {
    peek,
    take,
    discard_all,
    read_slice_all,
    stream_fixed,
    /// The interface's zero-length request (a poll). Mid-frame it is a
    /// zero-byte serve; on a done reader it reports `EndOfStream`. Both are
    /// legal; nothing may be lost either way.
    poll,
    /// A request past the contiguous-read cap: served when the window has
    /// room, `StreamTooLong` when it does not — never an assert.
    over_cap_take,
    /// A peek past the cap with no `left` guard: at the frame's tail the
    /// trailer must be verified before the clean end is reported (a clean
    /// `EndOfStream` always means the trailer was verified).
    over_end_peek,
    /// A peek of nearly the whole buffer: past `buffer.len - seek` as soon
    /// as the consumer has advanced, so the std fill routes it through the
    /// reader's `rebase`, whose trailer branch must also verify the trailer.
    over_buffer_peek,
};

/// Smith-chosen sequences of `Io.Reader` calls over the streaming reader.
///
/// Covers the vtable surface (`peek`/`take`/`discardAll`/`readSliceAll`/
/// `stream`), the serving region's slide and its retained history, the
/// contiguous-request cap, trailer verification at the clean end through both
/// `fill` and `rebase`, and the frame boundary: a frame unit followed by
/// markers stops exactly at the unit's last byte under every call. The input
/// is sometimes an `Io.Reader.Limited` with a small buffer (down to the
/// reader's 4-byte minimum), so the header and the block staging cross fills.
fn fuzzReaderMachinery(_: void, smith: *Smith) anyerror!void {
    const row = rows[smith.index(rows.len)];
    var expected_buf: [out_max]u8 = undefined;
    const expected = materialize(row.output, &expected_buf);
    const unit = unitOf(row.source);

    // Markers after the frame unit: the reader must stop at the unit's last
    // byte whatever the consumer ops do. A skippable-only run is checked
    // bare — markers behind it are the next unit's bytes, and a bad magic
    // there is the walk's own refusal.
    var framed: [source_max + marker_len]u8 = undefined;
    fastmem.copy(u8, framed[0..row.source.len], row.source);
    const framed_len = if (unit.frame != null) blk: {
        fastmem.set(u8, framed[row.source.len..][0..marker_len], marker_byte);
        break :blk row.source.len + marker_len;
    } else row.source.len;

    // The input side: sometimes a chunked reader with a small buffer (the
    // 4-byte minimum is the frame layer's largest fixed-size read), so the
    // header and the block staging cross fills.
    var chunk_buf: [64]u8 = undefined;
    var fixed_in: Io.Reader = .fixed(framed[0..framed_len]);
    var limited: Io.Reader.Limited = undefined;
    const chunked = smith.boolWeighted(1, 3);
    const input_reader: *Io.Reader = if (chunked) blk: {
        limited = .init(&fixed_in, .unlimited, chunk_buf[0..rangeAtMost(smith, 4, chunk_buf.len)]);
        break :blk &limited.interface;
    } else &fixed_in;

    var rbuf: Reader.Buffer(fixture_window_len) = undefined;
    var r: Reader = .init(fixture_window_len, input_reader, &rbuf, null);

    var pos: usize = 0;
    var ops: usize = 0;
    var stalls: usize = 0;
    var dead = false;
    while (pos < expected.len and ops < 64) : (ops += 1) {
        const left = expected.len - pos;
        switch (smith.value(ReadOp)) {
            .peek => {
                // The reader serves any contiguous request of at most
                // Block_Maximum_Size, so a failure here is the contiguity
                // stop, not a decode error.
                const n = @min(left, rangeAtMost(smith, 1, windowTailLen()));
                if (r.reader.peek(n)) |served| {
                    try testing.expectEqualSlices(u8, expected[pos..][0..n], served);
                } else |err| {
                    try expectContiguityStop(&r, err);
                    dead = true;
                    break;
                }
            },
            .take => {
                const n = @min(left, rangeAtMost(smith, 1, windowTailLen()));
                if (r.reader.take(n)) |served| {
                    try testing.expectEqualSlices(u8, expected[pos..][0..n], served);
                    pos += n;
                } else |err| {
                    try expectContiguityStop(&r, err);
                    dead = true;
                    break;
                }
            },
            .discard_all => {
                const n = @min(left, rangeAtMost(smith, 1, out_max));
                r.reader.discardAll(n) catch |err| {
                    try expectContiguityStop(&r, err);
                    dead = true;
                    break;
                };
                pos += n;
            },
            .read_slice_all => {
                var tmp: [8 * 1024]u8 = undefined;
                const n = @min(left, rangeAtMost(smith, 1, tmp.len));
                r.reader.readSliceAll(tmp[0..n]) catch |err| {
                    try expectContiguityStop(&r, err);
                    dead = true;
                    break;
                };
                try testing.expectEqualSlices(u8, expected[pos..][0..n], tmp[0..n]);
                pos += n;
            },
            .stream_fixed => {
                // `stream` may serve from the window or fill it; the bytes
                // land in the fixed writer, so the served count is what it
                // holds. The limit is at least one byte, so `EndOfStream`
                // here means the window is drained *and* the frame is done:
                // every byte the frame decodes must have been served by then.
                var tmp: [4 * 1024]u8 = undefined;
                var fw: Io.Writer = .fixed(&tmp);
                const n = @min(left, rangeAtMost(smith, 1, tmp.len));
                if (r.reader.stream(&fw, .limited(n))) |served| {
                    try testing.expectEqualSlices(
                        u8,
                        expected[pos..][0..served],
                        fw.buffered()[0..served],
                    );
                    pos += served;
                    if (served == 0) {
                        stalls += 1;
                        if (stalls > 8) return error.PumpStalled;
                    }
                } else |err| switch (err) {
                    error.EndOfStream => {
                        try testing.expectEqual(expected.len, pos);
                        break;
                    },
                    else => |e| {
                        try expectContiguityStop(&r, e);
                        dead = true;
                        break;
                    },
                }
            },
            .poll => {
                // A zero-length request: the interface's own poll. Mid-frame
                // it is a zero-byte serve; on a done reader it reports
                // `EndOfStream`. The vtable answers it without filling, so
                // nothing is lost either way.
                if (smith.boolWeighted(3, 1)) continue;
                var sink: Io.Writer.Discarding = .init(&.{});
                if (r.reader.stream(&sink.writer, .limited(0))) |served| {
                    try testing.expectEqual(@as(usize, 0), served);
                } else |err| switch (err) {
                    error.EndOfStream => {},
                    else => |e| {
                        try expectContiguityStop(&r, e);
                        dead = true;
                        break;
                    },
                }
            },
            .over_cap_take => {
                const n = windowTailLen() + 1 + rangeAtMost(smith, 0, windowTailLen() - 1);
                if (left <= n) continue;
                if (r.reader.take(n)) |served| {
                    try testing.expectEqualSlices(u8, expected[pos..][0..n], served);
                    pos += n;
                } else |err| {
                    // Past what the window can hold at the consumer's
                    // position: the read fails, stickily, with the contiguity
                    // detail.
                    try expectContiguityStop(&r, err);
                    dead = true;
                    break;
                }
            },
            .over_end_peek => {
                // A peek past the contiguity cap with no `left` guard: at
                // the frame's tail it must verify the trailer before
                // reporting the clean end, because a clean `EndOfStream`
                // always means the trailer was verified. The unserved
                // decoded bytes stay in the window; the code after the loop
                // drains them.
                const n = windowTailLen() + 1 + rangeAtMost(smith, 0, windowTailLen() - 1);
                if (r.reader.peek(n)) |served| {
                    try testing.expect(n <= left);
                    try testing.expectEqualSlices(u8, expected[pos..][0..n], served);
                } else |err| switch (err) {
                    error.EndOfStream => {
                        // The frame ended through the trailer check, so the
                        // clean end is real: no detail, state done, the input
                        // stopped exactly at the frame's last byte (on the
                        // plain fixed reader), every unserved decoded byte
                        // still in the window.
                        try testing.expectEqual(@as(?Reader.Error, null), r.err);
                        try testing.expectEqual(internal.reader.State.done, r.state);
                        if (!chunked) try testing.expectEqual(unit.end, fixed_in.seek);
                        try testing.expectEqual(left, r.reader.end - r.reader.seek);
                        try expectTrailerConsistent(
                            framed[0..unit.end],
                            unit.end,
                            expected,
                            unit.checksum,
                        );
                        break;
                    },
                    else => |e| {
                        try expectContiguityStop(&r, e);
                        dead = true;
                        break;
                    },
                }
            },
            .over_buffer_peek => {
                // A peek of nearly the whole buffer: the std fill routes a
                // request past `buffer.len - seek` through the reader's
                // `rebase`, whose trailer branch must verify the trailer
                // rather than pass the frame's end through.
                const n = bufferLen() - rangeAtMost(smith, 0, windowTailLen());
                if (r.reader.peek(n)) |served| {
                    try testing.expect(n <= left);
                    try testing.expectEqualSlices(u8, expected[pos..][0..n], served);
                } else |err| switch (err) {
                    error.EndOfStream => {
                        try testing.expectEqual(@as(?Reader.Error, null), r.err);
                        try testing.expectEqual(internal.reader.State.done, r.state);
                        if (!chunked) try testing.expectEqual(unit.end, fixed_in.seek);
                        try testing.expectEqual(left, r.reader.end - r.reader.seek);
                        try expectTrailerConsistent(
                            framed[0..unit.end],
                            unit.end,
                            expected,
                            unit.checksum,
                        );
                        break;
                    },
                    else => |e| {
                        try expectContiguityStop(&r, e);
                        dead = true;
                        break;
                    },
                }
            },
        }
    }
    if (dead) return; // the sticky failure was asserted where it happened

    // Finish whatever the op budget left: `discardAll` takes any size (it is
    // not a contiguous request), so the clean end always runs.
    if (pos < expected.len) {
        r.reader.discardAll(expected.len - pos) catch |err| {
            try expectContiguityStop(&r, err);
            return;
        };
    }

    // The clean end is sticky, and the input stopped exactly at the unit's
    // last byte (the markers are the caller's). The `Limited` input may have
    // buffered ahead, so the exact position is only pinned on the plain
    // fixed reader.
    try testing.expectEqual(@as(?Reader.Error, null), r.err);
    try expectStickyEnd(&r);
    if (!chunked) try testing.expectEqual(unit.end, fixed_in.seek);
}

/// An op record: the op and its one parameter, the 16-byte serialized unit
/// every op in the loop consumes.
const OpRecord = struct { op: ReadOp, param: u64 };

/// A reader-machinery seed: the row, the chunked flag, then one record per op.
fn opSeed(
    comptime row: []const u8,
    comptime chunked: bool,
    comptime records: []const OpRecord,
) [16 + 16 * records.len]u8 {
    var seed: [16 + 16 * records.len]u8 = undefined;
    mem.writeInt(u64, seed[0..8], rowIndex(row), .little);
    mem.writeInt(u64, seed[8..16], @intFromBool(chunked), .little);
    for (records, 0..) |record, index| {
        mem.writeInt(u64, seed[16 + 16 * index ..][0..8], @intFromEnum(record.op), .little);
        mem.writeInt(u64, seed[16 + 16 * index + 8 ..][0..8], record.param, .little);
    }
    return seed;
}

const reader_corpus: []const []const u8 = &.{
    // The frame tail: one byte consumed, then the whole-buffer peek, which
    // the std fill routes through the reader's `rebase`.
    &opSeed("frame_checksum", false, &.{
        .{ .op = .take, .param = 0 },
        .{ .op = .over_buffer_peek, .param = 0 },
    }),
    &opSeed("frame_checksum_off", false, &.{
        .{ .op = .take, .param = 0 },
        .{ .op = .over_buffer_peek, .param = 0 },
    }),
    // The over-the-end peek through the fill path.
    &opSeed("frame_checksum", false, &.{
        .{ .op = .take, .param = 0 },
        .{ .op = .over_end_peek, .param = 0 },
    }),
    // A chunked input at the 4-byte minimum over a compressed fixture.
    &opSeed("frame_pair", true, &.{
        .{ .op = .peek, .param = 0 },
        .{ .op = .take, .param = 0 },
        .{ .op = .read_slice_all, .param = 0 },
        .{ .op = .discard_all, .param = 0 },
    }),
    // The long fixture: over-cap takes, a stream, and the poll.
    &opSeed("frame_window_128k", false, &.{
        .{ .op = .take, .param = 0 },
        .{ .op = .over_cap_take, .param = 0 },
        .{ .op = .stream_fixed, .param = 0 },
        .{ .op = .poll, .param = 0 },
        .{ .op = .discard_all, .param = 0 },
    }),
    &opSeed("frame_checksum_multi", false, &.{
        .{ .op = .peek, .param = 0 },
        .{ .op = .stream_fixed, .param = 0 },
        .{ .op = .over_cap_take, .param = 0 },
    }),
    &opSeed("skippable_prefix", false, &.{
        .{ .op = .take, .param = 0 },
        .{ .op = .poll, .param = 0 },
    }),
    // The all-skippable run: no frame unit to carry the boundary, so the
    // clean end is the end of the skippable walk (a regression seed: this
    // input once crashed the target).
    &opSeed("skippable_sixteen", false, &.{}),
};

test "zstd fuzz: reader machinery" {
    try testing.fuzz({}, fuzzReaderMachinery, .{ .corpus = reader_corpus });
}

// ---------------------------------------------------------------------------
// Target 4: checksum accounting
// ---------------------------------------------------------------------------

const checksum_rows = [_]Row{
    .{
        .desc = "frame_checksum",
        .source = &golden.frame_checksum,
        .output = .{ .static = "abcd" },
    },
    .{
        .desc = "frame_checksum_empty",
        .source = &golden.frame_checksum_empty,
        .output = .{ .static = "" },
    },
    .{
        .desc = "frame_checksum_multi",
        .source = &golden.frame_checksum_multi,
        .output = .{ .repeat = .{ .text = golden.frame_checksum_multi_text, .count = 3000 } },
    },
    // The flag-off control: the same frame with no trailer to verify.
    .{
        .desc = "frame_checksum_off",
        .source = &golden.frame_checksum_off,
        .output = .{ .static = "abcd" },
    },
};

fn checksumIndex(comptime desc: []const u8) usize {
    comptime {
        @setEvalBranchQuota(10_000);
        for (checksum_rows, 0..) |row, index| {
            if (mem.eql(u8, row.desc, desc)) return index;
        }
        @compileError("no checksum row named " ++ desc);
    }
}

/// The XXH64 content checksum, intact and corrupted.
///
/// The wire trailer is the C library's own XXH64 value (`§3.1.1`; the CLI
/// wrote it and `zstd -t` verifies it), so it must equal std's `XxHash64` over
/// the decoded bytes. The reader's clean end proves its per-block running hash
/// (`frame.State.recordBlock`) agreed with that reference over the same bytes,
/// in order, across blocks. A corrupted trailer byte must fail `WrongChecksum`
/// on both paths, stickily, with the output cap held.
fn fuzzChecksumAccounting(_: void, smith: *Smith) anyerror!void {
    const row = checksum_rows[smith.index(checksum_rows.len)];
    var expected_buf: [out_max]u8 = undefined;
    const expected = materialize(row.output, &expected_buf);
    const info = analyze(row.source).?;
    const trailer_at = info.trailer_at orelse {
        // The flag-off control: no trailer, so the frame is the whole story.
        try testing.expect(!info.header.checksum);
        var window: [out_max + guard_len]u8 = undefined;
        sentinel.fill(&window);
        const n = try decode.decompress(row.source, window[0..expected.len], null);
        try testing.expectEqual(expected.len, n);
        try testing.expectEqualSlices(u8, expected, window[0..n]);
        try sentinel.expect(&window, n);
        return;
    };

    // The reference: the wire trailer against std's one-shot hash.
    try testing.expectEqual(
        @as(u32, @truncate(XxHash64.hash(0, expected))),
        readInt(u32, row.source[trailer_at..][0..frame.checksum_len]),
    );

    // The one-shot: identity, the trailer consistent, the sentinel clean.
    var window: [out_max + guard_len]u8 = undefined;
    sentinel.fill(&window);
    const n = try decode.decompress(row.source, window[0..expected.len], null);
    try testing.expectEqual(expected.len, n);
    try testing.expectEqualSlices(u8, expected, window[0..n]);
    try sentinel.expect(&window, n);

    // The reader: the same bytes, the clean end's running hash against the
    // reference.
    try expectReaderIdentity(unitOf(row.source), row.source, expected);

    // A corrupted trailer byte fails `WrongChecksum` on both paths.
    var corrupted: [source_max]u8 = undefined;
    fastmem.copy(u8, corrupted[0..row.source.len], row.source);
    const at = trailer_at + rangeAtMost(smith, 0, frame.checksum_len - 1);
    corrupted[at] ^= flipValue(smith);
    const bad = corrupted[0..row.source.len];
    var bad_window: [out_max + guard_len]u8 = undefined;
    sentinel.fill(&bad_window);
    try testing.expectError(
        error.WrongChecksum,
        decode.decompress(bad, bad_window[0..expected.len], null),
    );
    try sentinel.expect(&bad_window, expected.len);

    var got: [out_max]u8 = undefined;
    var fw: Io.Writer = .fixed(&got);
    var rbuf: Reader.Buffer(fixture_window_len) = undefined;
    var fixed_in: Io.Reader = .fixed(bad);
    var r: Reader = .init(fixture_window_len, &fixed_in, &rbuf, null);
    const pumped = try pumpCapped(&r.reader, &fw, pumpLimit(expected.len));
    try testing.expectEqual(Stop.read_failed, pumped.stop);
    try testing.expectEqual(Reader.Error.WrongChecksum, r.err.?);
    try expectStickyFailure(&r);
}

fn checksumSeed(comptime desc: []const u8, comptime param: u64) [16]u8 {
    var seed: [16]u8 = undefined;
    mem.writeInt(u64, seed[0..8], checksumIndex(desc), .little);
    mem.writeInt(u64, seed[8..16], param, .little);
    return seed;
}

const checksum_corpus: []const []const u8 = &.{
    &checksumSeed("frame_checksum", 0),
    &checksumSeed("frame_checksum_empty", 0),
    &checksumSeed("frame_checksum_multi", 0),
    &checksumSeed("frame_checksum_off", 0),
    &checksumSeed("frame_checksum", 1),
    &checksumSeed("frame_checksum_multi", 2),
};

test "zstd fuzz: checksum accounting" {
    try testing.fuzz({}, fuzzChecksumAccounting, .{ .corpus = checksum_corpus });
}

// ---------------------------------------------------------------------------
// Target 5: the amplification limits
// ---------------------------------------------------------------------------

/// A bomb row: the frame's full decoded output when it completes, or the
/// failure it pins and the bytes written before it.
const BombRow = struct {
    desc: []const u8,
    source: []const u8,
    output: ?Output,
    fail: ?struct {
        err: decode.DecompressError,
        /// The bytes the decode wrote before the error.
        written: usize,
        /// The smallest cap at which the pinned error (rather than the cap
        /// itself) fires: below it the failing declaration does not fit and
        /// `BufferTooSmall` is the refusal.
        min_cap: usize,
    },
};

/// The bombs: small frames whose declared sizes are orders of magnitude past
/// their bytes. The ratio is asserted for the rows that decode.
const bomb_rows = [_]BombRow{
    // §3.1.1.2.2 — an RLE block: 131072 bytes from a 10-byte frame.
    .{
        .desc = "frame_rle_max",
        .source = &golden.frame_rle_max,
        .output = .{ .splat = .{ .byte = 0x5a, .count = 131072 } },
        .fail = null,
    },
    // A 28-byte frame decoding 262147 bytes: two RLE blocks then a match at
    // exactly Window_Size (§3.1.1.4).
    .{
        .desc = "frame_window_128k",
        .source = &golden.frame_window_128k,
        .output = .{ .two_runs = .{
            .first_byte = 'A',
            .first_count = 131072,
            .second_byte = 'B',
            .second_count = 131072,
            .tail = "BBB",
        } },
        .fail = null,
    },
    // The CLI's own multi-block checksummed frame: 135000 bytes from 82.
    .{
        .desc = "frame_checksum_multi",
        .source = &golden.frame_checksum_multi,
        .output = .{ .repeat = .{ .text = golden.frame_checksum_multi_text, .count = 3000 } },
        .fail = null,
    },
    // §3.1.1.2.4 — a declared 1026-byte match over a 16-byte history: past
    // Block_Maximum_Size, refused before the second block's write.
    .{
        .desc = "frame_amplify_match",
        .source = &golden.frame_amplify_match,
        .output = null,
        .fail = .{ .err = error.BlockOversize, .written = 16, .min_cap = 1040 },
    },
    // §3.1.1.3.1.3 — an RLE literals section regenerating 4096 from one byte
    // in a 1 KB window: the declared size is refused, nothing written.
    .{
        .desc = "frame_oversize_literals",
        .source = &golden.frame_oversize_literals,
        .output = null,
        .fail = .{ .err = error.LiteralsTooLarge, .written = 0, .min_cap = 0 },
    },
    // §3.1.1.2.4 + §3.1.1.1.2 — a Raw block of 131073 in a 512-KiB window:
    // Block_Maximum_Size is the bound.
    .{
        .desc = "frame_oversize_raw",
        .source = &golden.frame_oversize_raw,
        .output = null,
        .fail = .{ .err = error.BlockOversize, .written = 0, .min_cap = 0 },
    },
    // The window bounds Block_Maximum_Size (§3.1.1.2.4): an RLE block of 1025
    // in a 1 KB window.
    .{
        .desc = "frame_oversize_rle",
        .source = &golden.frame_oversize_rle,
        .output = null,
        .fail = .{ .err = error.BlockOversize, .written = 0, .min_cap = 0 },
    },
    // The same bound in a single-segment frame, whose window is its content
    // size: FCS 4 carrying a 5-byte block.
    .{
        .desc = "frame_single_segment_oversize",
        .source = &golden.frame_single_segment_oversize,
        .output = null,
        .fail = .{ .err = error.BlockOversize, .written = 0, .min_cap = 0 },
    },
    // Frame_Content_Size 2^64-1 against a 4-byte block: checked as a
    // declaration, never used to size anything.
    .{
        .desc = "frame_fcs_max",
        .source = &golden.frame_fcs_max,
        .output = null,
        .fail = .{ .err = error.ContentSizeMismatch, .written = 4, .min_cap = 4 },
    },
    // §3.1.2 — 4 GiB of declared User_Data with three bytes present: skipped
    // by arithmetic, never staged.
    .{
        .desc = "skippable_huge",
        .source = &golden.skippable_huge,
        .output = null,
        .fail = .{ .err = error.Truncated, .written = 0, .min_cap = 0 },
    },
};

fn bombIndex(comptime desc: []const u8) usize {
    comptime {
        @setEvalBranchQuota(10_000);
        for (bomb_rows, 0..) |row, index| {
            if (mem.eql(u8, row.desc, desc)) return index;
        }
        @compileError("no bomb row named " ++ desc);
    }
}

/// Declared sizes against the output cap.
///
/// The one-shot's `target` is a cap, not a promise: every declared size is a
/// bound the decode checks before the write that would pass the cap (failing
/// `BufferTooSmall`), and no declaration sizes anything. A bomb-shaped frame
/// is decoded into caps below its decoded length (including zero and
/// `len - 1`), at the exact length, and with slack, with the sentinel proving
/// the cap held. The failure rows pin their error and written floor under
/// every cap, including a cap below `min_cap` (where the cap itself is the
/// refusal). The frames that decode are asserted to be a small fraction of the
/// bytes they decode to.
fn fuzzAmplification(_: void, smith: *Smith) anyerror!void {
    const row = bomb_rows[smith.index(bomb_rows.len)];
    const shape = rangeAtMost(smith, 0, 3);
    var window: [out_max + guard_len]u8 = undefined;

    if (row.output) |output| {
        var expected_buf: [out_max]u8 = undefined;
        const expected = materialize(output, &expected_buf);
        // The bomb property: the frame's bytes are a small fraction of its
        // output (an amplification a cap that ignored the decoded length
        // would turn into a real overrun).
        try testing.expect(row.source.len * 8 <= expected.len);

        var caps: [3]usize = .{ 0, expected.len, out_max };
        switch (shape) {
            0 => caps[0] = 0,
            1 => caps[0] = expected.len / 2,
            2 => caps[0] = expected.len - 1,
            else => caps[0] = rangeAtMost(smith, 0, expected.len - 1),
        }
        for (caps) |cap| {
            sentinel.fill(&window);
            if (cap < expected.len) {
                try testing.expectError(
                    error.BufferTooSmall,
                    decode.decompress(row.source, window[0..cap], null),
                );
                try sentinel.expect(&window, cap);
            } else {
                const n = try decode.decompress(row.source, window[0..cap], null);
                try testing.expectEqual(expected.len, n);
                try testing.expectEqualSlices(u8, expected, window[0..n]);
                try sentinel.expect(&window, n);
            }
        }
        return;
    }

    const fail = row.fail.?;
    const caps = [_]usize{ 0, fail.min_cap, out_max };
    for (caps) |cap| {
        sentinel.fill(&window);
        if (cap < fail.min_cap) {
            // The declared size the failing block needs first is past the
            // cap: the cap is the refusal, before any write.
            try testing.expectError(
                error.BufferTooSmall,
                decode.decompress(row.source, window[0..cap], null),
            );
            try sentinel.expect(&window, cap);
        } else {
            try testing.expectError(fail.err, decode.decompress(row.source, window[0..cap], null));
            try sentinel.expect(&window, @min(cap, fail.written));
        }
    }
}

fn bombSeed(comptime desc: []const u8, comptime shape: u64) [16]u8 {
    var seed: [16]u8 = undefined;
    mem.writeInt(u64, seed[0..8], bombIndex(desc), .little);
    mem.writeInt(u64, seed[8..16], shape, .little);
    return seed;
}

const amplification_corpus: []const []const u8 = &.{
    &bombSeed("frame_rle_max", 0),
    &bombSeed("frame_window_128k", 1),
    &bombSeed("frame_checksum_multi", 2),
    &bombSeed("frame_amplify_match", 0),
    &bombSeed("frame_oversize_literals", 1),
    &bombSeed("frame_oversize_raw", 2),
    &bombSeed("frame_oversize_rle", 3),
    &bombSeed("frame_single_segment_oversize", 0),
    &bombSeed("frame_fcs_max", 1),
    &bombSeed("skippable_huge", 2),
};

test "zstd fuzz: amplification caps" {
    try testing.fuzz({}, fuzzAmplification, .{ .corpus = amplification_corpus });
}

// ---------------------------------------------------------------------------
// The encode side: the one-shot, the streaming Writer, and their invariants
// ---------------------------------------------------------------------------

/// The encode targets' largest Smith-built source: 256 KiB + 1, one byte past
/// the one-shot ladder's 256-KiB window class, so a frame carries up to three
/// 128-KiB blocks (`block_compress.blockSize` is `min(128 KiB, 1 <<
/// window_log)`) and the later blocks can reuse the earlier ones' entropy
/// tables (Treeless_Literals_Block, Repeat_Mode).
const encode_max: usize = 256 * 1024 + 1;

/// `encode.maxCompressedLength` at `encode_max`: the largest frame an encode
/// target's one-shot writes.
const encode_bound: usize = encode.maxCompressedLength(encode_max);

/// The decode buffer an encode target's frame is checked in: the source cap
/// plus the sentinel guard.
const encode_out_max: usize = encode_max + guard_len;

/// The corruption target's source cap: over 128 KiB, so a frame carries two
/// blocks (the second reusing the first's entropy tables) while the mutation
/// buffer stays stack-sized. A doubled frame covers `duplicate_frame`.
const corrupt_encode_max: usize = 150_000;
const corrupt_frame_max: usize = encode.maxCompressedLength(corrupt_encode_max);
const encode_mutation_max: usize = 2 * corrupt_frame_max + 64;

/// The Writer-machinery target's write budget and op budget: one default
/// block region's worth, so blocks emit and the window slides mid-stream.
const machinery_max: usize = 192 * 1024;
const machinery_ops_max: usize = 32;

/// The Writer's mid-stream flush budget: every flush ends the current block,
/// and every extra block costs its 3-byte Block_Header beyond the
/// `maxCompressedLength` bound (which budgets only the block region's own
/// split), so the Writer's sinks carry headroom for `flush_budget` extra
/// blocks plus the empty last block.
const flush_budget: usize = 16;

/// The round-trip Writer's sink: the one-shot bound plus the flush headroom.
const writer_out_max: usize = encode_bound + 3 * (flush_budget + 4) + 8;

/// The machinery target's sink: the worst case over the window ladder — one
/// 3-byte header per 1-KiB block region (the smallest window), one per
/// mid-stream flush, and the final empty block.
const machinery_out_max: usize = 10 +
    3 * (machinery_max / 1024 + machinery_ops_max + 2) +
    machinery_max;

/// The byte-class target's largest source: 530000 crosses the one-shot's
/// single-segment boundary (512 KiB), where the header gains a
/// Window_Descriptor and the 8-byte Frame_Content_Size form.
const class_max: usize = 530_000;
const class_bound: usize = encode.maxCompressedLength(class_max);

/// The sizes the encode targets draw from: the one-shot ladder's window
/// boundaries (`match_compress.Params.forSource`: `nextPow2`, floor 1 KiB),
/// the Frame_Content_Size form boundaries (256, 65536 + 256), and the 128-KiB
/// block boundary — each with its one-byte neighbours.
const encode_sizes = [_]usize{
    0,      1,      2,     3,     6,     7,      8,      15,     16,
    17,     31,     32,    33,    63,    64,     65,     100,    127,
    128,    129,    255,   256,   257,   511,    512,    513,    1023,
    1024,   1025,   2047,  2048,  2049,  4095,   4096,   4097,   8191,
    8192,   8193,   16383, 16384, 16385, 32767,  32768,  32769,  65535,
    65536,  65537,  65791, 65792, 65793, 131071, 131072, 131073, 262143,
    262144, 262145,
};

/// The corruption target's sizes: the header-mutation classes on small
/// frames, and over 128 KiB for the entropy classes' two-block frames.
const corrupt_sizes = [_]usize{
    0, 1, 7, 8, 100, 255, 256, 1024, 4096, 16384, 65536, 131071, 131072, 131073, 150_000,
};

/// The byte-class target's sizes, up to the one-shot's single-segment
/// boundary: 524288 is the largest single-segment frame, 524289 the first
/// windowed one.
const class_sizes = [_]usize{
    0,     1,      100,    255,    256,    257,    1024,   65791,  65792,
    65793, 131072, 131073, 262144, 262145, 524288, 524289, 530000,
};

/// The sizes the `maxCompressedLength` tightness check covers: the ladder's
/// boundary classes and the format's form boundaries, to 1 GiB (above 512 KiB
/// the window class repeats, so the classes repeat with it).
const bound_sizes = [_]usize{
    0,      1,      255,    256,    257,    1023,    1024,    1025,    65535,
    65536,  65537,  65791,  65792,  65793,  131071,  131072,  131073,  262143,
    262144, 262145, 524287, 524288, 524289, 1 << 20, 1 << 24, 1 << 30,
};

/// The encode targets' source model: the corpus shapes plus the patterns that
/// drive the match finder and the entropy writers.
const EncodeInput = enum(u8) {
    /// A `golden.Shape`: the corpus shapes the golden fixtures share.
    corpus,
    /// PRNG bytes from one Smith-chosen seed: incompressible, the Raw
    /// fallback.
    uniform,
    /// A repeated random phrase of 1-64 bytes: long matches at one distance —
    /// the repcode and offset-2 chains, across block boundaries.
    period,
    /// PRNG bytes masked to a 2-16 symbol alphabet: Huffman-heavy literals.
    alphabet,
    /// PRNG bytes turned into short runs: RLE-adjacent blocks.
    runs,
};

/// The `corpus` kind's shapes, in `golden.Shape` order.
const encode_shapes = [_]golden.Shape{
    .text, .html, .rle, .random, .mixed, .skewlit, .words, .zeros,
};

/// Fill `buf` with one Smith-chosen input. `content` seeds the model (a
/// `DefaultPrng` seed, or the shape index for `corpus`), so a target's Smith
/// consumption does not depend on the kind.
fn fillEncodeInput(kind: EncodeInput, content: u64, buf: []u8) void {
    switch (kind) {
        .corpus => golden.fillShape(encode_shapes[@intCast(content % encode_shapes.len)], buf),
        .uniform => {
            var rng: DefaultPrng = .init(content);
            const rand = rng.random();
            rand.bytes(buf);
        },
        .period => {
            const period: usize = 1 + @as(usize, @intCast(content & 63));
            var phrase: [64]u8 = undefined;
            var rng: DefaultPrng = .init(content);
            const rand = rng.random();
            rand.bytes(phrase[0..period]);
            var at: usize = 0;
            while (at < buf.len) : (at += period) {
                const n = @min(period, buf.len - at);
                fastmem.copy(u8, buf[at..][0..n], phrase[0..n]);
            }
        },
        .alphabet => {
            const bits: u3 = @intCast(1 + content % 4);
            const mask: u8 = (@as(u8, 1) << bits) - 1;
            var rng: DefaultPrng = .init(content);
            const rand = rng.random();
            rand.bytes(buf);
            for (buf) |*byte| byte.* &= mask;
        },
        .runs => {
            var rng: DefaultPrng = .init(content);
            const rand = rng.random();
            var at: usize = 0;
            while (at < buf.len) {
                const byte = rand.int(u8);
                const run = 1 + rand.uintAtMost(usize, 15);
                const n = @min(run, buf.len - at);
                fastmem.set(u8, buf[at..][0..n], byte);
                at += n;
            }
        },
    }
}

/// The ladder index of `size`, at comptime: a seed that names a size the
/// ladder does not carry fails the build, not the run.
fn sizeIndex(comptime ladder: []const usize, comptime size: usize) usize {
    comptime {
        for (ladder, 0..) |entry, index| {
            if (entry == size) return index;
        }
        @compileError("no ladder entry for the seed's size");
    }
}

/// The `content` word that selects `shape` for the `corpus` kind.
fn shapeContent(comptime shape: golden.Shape) u64 {
    comptime {
        for (encode_shapes, 0..) |entry, index| {
            if (entry == shape) return index;
        }
        @compileError("shape not in encode_shapes");
    }
}

/// An encode-target seed: the kind, the size (by ladder index), the content
/// seed, and the target's mode word — the values the target consumes, in
/// order, before it fills the source.
fn encodeSeed(
    comptime ladder: []const usize,
    comptime kind: EncodeInput,
    comptime size: usize,
    comptime content: u64,
    comptime mode: u64,
) [32]u8 {
    var seed: [32]u8 = undefined;
    mem.writeInt(u64, seed[0..8], @intFromEnum(kind), .little);
    mem.writeInt(u64, seed[8..16], sizeIndex(ladder, size), .little);
    mem.writeInt(u64, seed[16..24], content, .little);
    mem.writeInt(u64, seed[24..32], mode, .little);
    return seed;
}

/// A Smith-chosen size from `ladder`, jittered by up to four bytes so the
/// boundaries' shoulders are hit too.
fn ladderSize(smith: *Smith, comptime ladder: []const usize, comptime max: usize) usize {
    const base = ladder[smith.index(ladder.len)];
    return @min(base + rangeAtMost(smith, 0, 4), max);
}

// ---------------------------------------------------------------------------
// Target 6: the encode round trip
// ---------------------------------------------------------------------------

/// The encode round-trip: the one-shot and the streaming `Writer` over
/// Smith-driven inputs, decoded back through the landed one-shot decoder with
/// the sentinel rule.
///
/// The one-shot path checks the `maxCompressedLength` bound, the trailer
/// against std's XXH64, identity at the exact cap and with slack, and a
/// Smith-chosen smaller cap: either a shorter frame that still decodes to the
/// source, or `BufferTooSmall` with the cap held. The Writer path drives the
/// manual `init`/write/`flush`/`finish` sequence — Smith-chosen write chunks
/// (single bytes included), mid-stream flushes, and the zero-data flush —
/// then checks the bound, the trailer, and identity. The empty writer's frame
/// is checked on every iteration.
fn fuzzEncodeRoundTrip(_: void, smith: *Smith) anyerror!void {
    const kind = smith.value(EncodeInput);
    var size = ladderSize(smith, &encode_sizes, encode_max);
    const content = smith.value(u64);
    const mode = rangeAtMost(smith, 0, 3);
    // The implemented levels: 1 (fast) and 3 (dfast). Both round-trip; only
    // the bytes differ.
    const level: encode.Level = if (smith.boolWeighted(1, 1)) .@"3" else .@"1";
    // Single-byte writes only where the loop stays cheap.
    if (mode == 2) size = @min(size, 4096);

    var source: [encode_max]u8 = undefined;
    fillEncodeInput(kind, content, source[0..size]);

    try expectOneShotEncodeRoundTrip(smith, source[0..size], level);
    try expectWriterEncodeRoundTrip(smith, source[0..size], mode, level);
}

/// The one-shot's frame for `source`: the bound, the trailer, identity at the
/// exact cap and with slack, and a Smith-chosen smaller cap.
fn expectOneShotEncodeRoundTrip(smith: *Smith, source: []const u8, level: encode.Level) !void {
    var compressed: [encode_bound]u8 = undefined;
    const bound = encode.maxCompressedLength(source.len);
    const written = try encode.compress(source, compressed[0..bound], .{ .level = level });
    try testing.expect(written <= bound);
    try expectTrailerConsistent(compressed[0..written], written, source, true);

    var plain: [encode_out_max]u8 = undefined;
    sentinel.fill(&plain);
    const n = try decode.decompress(compressed[0..written], plain[0..source.len], null);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, plain[0..n]);
    try sentinel.expect(&plain, n);
    sentinel.fill(&plain);
    const m = try decode.decompress(compressed[0..written], &plain, null);
    try testing.expectEqual(n, m);
    try testing.expectEqualSlices(u8, source, plain[0..m]);
    try sentinel.expect(&plain, m);

    // A Smith-chosen smaller cap: a shorter frame (the ladder may fall back
    // per block) that still decodes to the source, or `BufferTooSmall` with
    // the cap held.
    const cap = rangeAtMost(smith, 0, written);
    sentinel.fill(&compressed);
    if (encode.compress(source, compressed[0..cap], .{ .level = level })) |short| {
        // A successful emission writes its frame into the target's front; a
        // block whose entropy attempt fails partway can leave bytes past the
        // returned length inside the target (the C's encoder does the same),
        // so the checked property is the cap: nothing past the slice.
        try testing.expect(short <= cap);
        try sentinel.expect(&compressed, cap);
        sentinel.fill(&plain);
        const d = try decode.decompress(compressed[0..short], plain[0..source.len], null);
        try testing.expectEqual(source.len, d);
        try testing.expectEqualSlices(u8, source, plain[0..d]);
        try sentinel.expect(&plain, d);
    } else |err| {
        try testing.expectEqual(error.BufferTooSmall, err);
        try sentinel.expect(&compressed, cap);
    }
}

/// The Writer's frame for `source`, in `mode`'s write pattern: the empty
/// writer's 13-byte frame, the bound, the trailer, and identity.
fn expectWriterEncodeRoundTrip(
    smith: *Smith,
    source: []const u8,
    mode: usize,
    level: encode.Level,
) !void {
    var out: [writer_out_max]u8 = undefined;
    var fw: Io.Writer = .fixed(&out);
    var buffer: Writer.Buffer(Writer.default_window_log) = undefined;

    // The empty writer: the header, one raw zero-size Last_Block, and the
    // checksum — 13 bytes that decode to nothing.
    {
        var empty: [32]u8 = undefined;
        var efw: Io.Writer = .fixed(&empty);
        var ew: Writer = .init(Writer.default_window_log, &efw, &buffer, .{ .level = level });
        try ew.finish();
        try expectTrailerConsistent(empty[0..efw.end], efw.end, "", true);
        var nothing: [guard_len]u8 = undefined;
        sentinel.fill(&nothing);
        const zero = try decode.decompress(empty[0..efw.end], &nothing, null);
        try testing.expectEqual(@as(usize, 0), zero);
        try sentinel.expect(&nothing, 0);
    }

    var w: Writer = .init(Writer.default_window_log, &fw, &buffer, .{ .level = level });
    var pos: usize = 0;
    var flushes: usize = 0;
    switch (mode) {
        0 => {
            try w.writer.writeAll(source);
            pos = source.len;
        },
        1, 3 => {
            // Mode 3's zero-data flush: the header alone reaches the sink
            // before the first byte.
            if (mode == 3) try w.writer.flush();
            while (pos < source.len) {
                const n = @min(source.len - pos, rangeAtMost(smith, 1, 4096));
                try w.writer.writeAll(source[pos..][0..n]);
                pos += n;
                if (flushes < flush_budget and smith.boolWeighted(1, 3)) {
                    try w.writer.flush();
                    flushes += 1;
                }
            }
        },
        else => {
            while (pos < source.len) {
                try w.writer.writeAll(source[pos..][0..1]);
                pos += 1;
            }
        },
    }
    try w.finish();
    const written = fw.end;
    // The unflushed stream stays inside the one-shot's bound; a mid-stream
    // flush ends a block early, and each extra block costs its 3-byte header
    // beyond the bound's own split.
    try testing.expect(written <= writer_out_max);
    if (mode == 0 or mode == 2) {
        try testing.expect(written <= encode.maxCompressedLength(source.len));
    }
    try expectTrailerConsistent(out[0..written], written, source, true);

    var plain: [encode_out_max]u8 = undefined;
    sentinel.fill(&plain);
    const n = try decode.decompress(out[0..written], plain[0..source.len], null);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, plain[0..n]);
    try sentinel.expect(&plain, n);
}

/// Seeds for `fuzzEncodeRoundTrip`: the corpus shapes across the ladder's
/// classes, the pattern kinds that drive the finder, and every writer mode.
const encode_roundtrip_corpus: []const []const u8 = &.{
    &encodeSeed(&encode_sizes, .corpus, 0, shapeContent(.text), 0),
    &encodeSeed(&encode_sizes, .corpus, 100, shapeContent(.words), 0),
    &encodeSeed(&encode_sizes, .corpus, 257, shapeContent(.html), 1),
    &encodeSeed(&encode_sizes, .corpus, 1024, shapeContent(.mixed), 3),
    &encodeSeed(&encode_sizes, .corpus, 4096, shapeContent(.skewlit), 0),
    &encodeSeed(&encode_sizes, .corpus, 16384, shapeContent(.rle), 1),
    &encodeSeed(&encode_sizes, .corpus, 65536, shapeContent(.zeros), 2),
    &encodeSeed(&encode_sizes, .corpus, 131073, shapeContent(.text), 1),
    &encodeSeed(&encode_sizes, .corpus, 262145, shapeContent(.text), 0),
    &encodeSeed(&encode_sizes, .uniform, 262145, 0x9E3779B97F4A7C15, 1),
    &encodeSeed(&encode_sizes, .period, 262145, 17, 0),
    &encodeSeed(&encode_sizes, .alphabet, 8192, 3, 1),
    &encodeSeed(&encode_sizes, .runs, 4096, 0xC0FFEE, 2),
    &encodeSeed(&encode_sizes, .uniform, 131072, 1, 0),
};

test "zstd fuzz: encode round trip" {
    try testing.fuzz({}, fuzzEncodeRoundTrip, .{ .corpus = encode_roundtrip_corpus });
}

// ---------------------------------------------------------------------------
// Target 7: the encode byte class
// ---------------------------------------------------------------------------

/// The encode byte-class invariants: the properties the pinned CLI v1.5.7
/// fixtures stand in for (there is no in-process reference oracle).
///
/// The one-shot's emission is deterministic (two runs, byte for byte), its
/// header declares the exact Frame_Content_Size in its smallest form, its
/// single-segment bit and window follow the ladder (single-segment exactly
/// when the source fits the window; the window is the FCS itself then, the
/// 512-KiB class otherwise), its descriptor sets the checksum and nothing
/// else, its block chain's headers are structurally legal (no reserved type,
/// Block_Size inside Block_Maximum_Size, the first block never RLE, Last_Block
/// exactly on the last block, the chain ending at the trailer), and the frame
/// decodes through the one-shot to the source with the trailer verified. The
/// `Writer` on the same source declares the FCS-unknown header form, and
/// where the two encoders' parameters coincide (over 256 KiB) their block
/// bodies are byte-identical.
fn fuzzEncodeByteClass(_: void, smith: *Smith) anyerror!void {
    const kind = smith.value(EncodeInput);
    const size = ladderSize(smith, &class_sizes, class_max);
    const content = smith.value(u64);

    var source: [class_max]u8 = undefined;
    fillEncodeInput(kind, content, source[0..size]);

    var one_shot: [class_bound]u8 = undefined;
    var streamed: [class_bound]u8 = undefined;
    const one_shot_len = try oneShotByteClass(source[0..size], &one_shot);
    const streamed_len = try writerByteClass(source[0..size], &streamed);
    if (size > 256 * 1024) {
        // The finder's parameters coincide (`Params.forSource` picks windowLog
        // 19, hashLog 14, minMatch 7 over 256 KiB; the Writer's streaming
        // class is the same), so only the header form differs: the block
        // bodies and the trailer are the same bytes.
        const one_shot_header = headerLenFor(one_shot[0..one_shot_len]);
        const streamed_header = headerLenFor(streamed[0..streamed_len]);
        try testing.expectEqualSlices(
            u8,
            one_shot[one_shot_header .. one_shot_len - frame.checksum_len],
            streamed[streamed_header .. streamed_len - frame.checksum_len],
        );
        try testing.expectEqualSlices(
            u8,
            one_shot[one_shot_len - frame.checksum_len .. one_shot_len],
            streamed[streamed_len - frame.checksum_len .. streamed_len],
        );
    }
}

/// The one-shot's frame for `source` into `out`: determinism, the header
/// forms, the block-chain structure, identity, and the trailer. Returns the
/// frame's length.
fn oneShotByteClass(source: []const u8, out: []u8) !usize {
    const bound = encode.maxCompressedLength(source.len);
    const written = try encode.compress(source, out[0..bound], .{});
    try testing.expect(written <= bound);
    {
        var again: [class_bound]u8 = undefined;
        const m = try encode.compress(source, again[0..bound], .{});
        try testing.expectEqual(written, m);
        try testing.expectEqualSlices(u8, out[0..written], again[0..m]);
    }

    const frame_bytes = out[0..written];
    try testing.expectEqual(frame.magic, readInt(u32, frame_bytes[0..frame.magic_len]));
    const header = try frame.parseHeader(frame_bytes[frame.magic_len..]);
    try testing.expectEqual(@as(?u64, source.len), header.content_size);
    try testing.expect(header.checksum);
    const single = header.descriptor & frame.descriptor_single_segment != 0;
    try testing.expectEqual(source.len <= (@as(usize, 1) << 19), single);
    // §3.1.1.1.1.1 — the descriptor is the FCS flag, the single-segment bit,
    // and the checksum flag; nothing else.
    try testing.expectEqual(
        (@as(u8, fcsCode(source.len)) << 6) |
            (@as(u8, @intFromBool(single)) << 5) |
            frame.descriptor_checksum,
        header.descriptor,
    );
    // §3.1.1.1.1.1 — the smallest FCS form that carries the exact size.
    try testing.expectEqual(fcsLen(source.len), frame.fcsFieldSize(header.descriptor));
    // §3.1.1.1.1.2 — single-segment: Window_Size is Frame_Content_Size;
    // windowed: the level-1 class's 512-KiB window.
    const window_size: u64 = if (single) source.len else @as(u64, 1) << 19;
    try testing.expectEqual(window_size, header.window_size);
    if (!single) {
        const window_byte = frame_bytes[frame.magic_len + 1];
        try testing.expectEqual(frame.window.descriptor(19), window_byte);
        try testing.expectEqual(@as(u64, 1) << 19, frame.window.size(window_byte));
    }

    // §3.1.1.2 — the block chain: legal headers, Block_Maximum_Size, the
    // first block never RLE (the zstd ≤ 1.4.3 CLI convention), Last_Block
    // exactly on the last block, the
    // chain ending at the trailer.
    var cursor = frame.magic_len + header.bytes_consumed;
    var blocks: usize = 0;
    const block_max = @min(header.window_size, @as(u64, block.max_block_size));
    while (true) {
        const bh = try block.parseHeader(frame_bytes[cursor..]);
        try testing.expect(bh.block_type != .reserved);
        try testing.expect(@as(u64, bh.block_size) <= block_max);
        if (blocks == 0) try testing.expect(bh.block_type != .rle);
        blocks += 1;
        cursor += block.block_header_len + block.contentLength(bh);
        try testing.expect(cursor <= written - frame.checksum_len);
        if (bh.last_block) break;
    }
    try testing.expect(blocks >= 1);
    try testing.expectEqual(written - frame.checksum_len, cursor);

    // The one-shot decodes the frame to the source, markers after it are not
    // part of it, and the trailer is the XXH64 of the source.
    var framed: [class_bound + marker_len]u8 = undefined;
    fastmem.copy(u8, framed[0..written], frame_bytes);
    fastmem.set(u8, framed[written..][0..marker_len], marker_byte);
    var plain: [class_max + guard_len]u8 = undefined;
    sentinel.fill(&plain);
    const n = try decode.decompress(framed[0 .. written + marker_len], plain[0..source.len], null);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, plain[0..n]);
    try sentinel.expect(&plain, n);
    try expectTrailerConsistent(frame_bytes, written, source, true);
    return written;
}

/// The Writer's frame for `source` into `out`: the FCS-unknown header form,
/// identity, and the bound. Returns the frame's length.
fn writerByteClass(source: []const u8, out: []u8) !usize {
    var fw: Io.Writer = .fixed(out);
    var buffer: Writer.Buffer(Writer.default_window_log) = undefined;
    var fixed_in: Io.Reader = .fixed(source);
    const consumed = try Writer.streamAll(Writer.default_window_log, &fixed_in, &fw, &buffer, .{});
    try testing.expectEqual(source.len, consumed);
    const written = fw.end;
    try testing.expect(written <= encode.maxCompressedLength(source.len));

    // §3.1.1.1.1.1 — the streaming form: no Frame_Content_Size, not
    // single-segment, the checksum flag alone; the window is declared.
    const header = try frame.parseHeader(out[frame.magic_len..written]);
    try testing.expectEqual(frame.descriptor_checksum, header.descriptor);
    try testing.expectEqual(@as(?u64, null), header.content_size);
    try testing.expectEqual(@as(u64, 1) << Writer.default_window_log, header.window_size);
    try testing.expect(header.checksum);

    var plain: [class_max + guard_len]u8 = undefined;
    sentinel.fill(&plain);
    const n = try decode.decompress(out[0..written], plain[0..source.len], null);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, plain[0..n]);
    try sentinel.expect(&plain, n);
    try expectTrailerConsistent(out[0..written], written, source, true);
    return written;
}

/// The descriptor's Frame_Content_Size_Flag the one-shot writes for a source
/// of `source_len` (`§3.1.1.1.1.1`): the smallest form that carries the exact
/// size.
fn fcsCode(source_len: usize) u2 {
    var code: u2 = 0;
    if (source_len >= 256) code += 1;
    if (source_len >= 65536 + 256) code += 1;
    if (source_len >= 0xffff_ffff) code += 1;
    return code;
}

/// `§3.1.1.1.1.1`, Table 4 — the FCS_Field_Size of the smallest form that
/// carries `source_len`.
fn fcsLen(source_len: usize) usize {
    return switch (fcsCode(source_len)) {
        0 => 1,
        1 => 2,
        2 => 4,
        else => 8,
    };
}

/// The frame header's length, from the parsed descriptor: the magic, the
/// descriptor, the optional Window_Descriptor, and the Frame_Content_Size
/// field (`§3.1.1.1`).
fn headerLenFor(frame_bytes: []const u8) usize {
    const header = frame.parseHeader(frame_bytes[frame.magic_len..]) catch unreachable;
    return frame.magic_len + header.bytes_consumed;
}

/// Seeds for `fuzzEncodeByteClass`: every header-form class (the FCS forms
/// 1/2/4, the single-segment boundary, the windowed form) and every block
/// form the ladder picks.
const byte_class_corpus: []const []const u8 = &.{
    &encodeSeed(&class_sizes, .corpus, 0, shapeContent(.text), 0),
    &encodeSeed(&class_sizes, .corpus, 1, shapeContent(.text), 0),
    &encodeSeed(&class_sizes, .corpus, 255, shapeContent(.text), 0),
    &encodeSeed(&class_sizes, .corpus, 256, shapeContent(.text), 0),
    &encodeSeed(&class_sizes, .corpus, 257, shapeContent(.text), 0),
    &encodeSeed(&class_sizes, .corpus, 65791, shapeContent(.text), 0),
    &encodeSeed(&class_sizes, .corpus, 65792, shapeContent(.text), 0),
    &encodeSeed(&class_sizes, .corpus, 65793, shapeContent(.text), 0),
    &encodeSeed(&class_sizes, .corpus, 131072, shapeContent(.rle), 0),
    &encodeSeed(&class_sizes, .corpus, 262144, shapeContent(.mixed), 0),
    &encodeSeed(&class_sizes, .corpus, 262145, shapeContent(.text), 0),
    &encodeSeed(&class_sizes, .corpus, 524288, shapeContent(.text), 0),
    &encodeSeed(&class_sizes, .corpus, 524289, shapeContent(.text), 0),
    &encodeSeed(&class_sizes, .corpus, 530000, shapeContent(.random), 0),
    &encodeSeed(&class_sizes, .period, 524289, 33, 0),
    &encodeSeed(&class_sizes, .uniform, 262145, 7, 0),
};

test "zstd fuzz: encode byte class" {
    try testing.fuzz({}, fuzzEncodeByteClass, .{ .corpus = byte_class_corpus });
}

// ---------------------------------------------------------------------------
// Target 8: the corruption taxonomy over our own frames
// ---------------------------------------------------------------------------

/// The mutation operators over our own frames. Each keeps `buf[0..len]` in
/// bounds and stays inside the mutation buffer.
const EncodeMutation = enum(u8) {
    /// Cut the frame at a Smith-chosen byte: inside the header or the
    /// trailer is `Truncated` exactly; inside the body the bits run out first
    /// (any failure).
    truncate,
    /// A flip inside the 4-byte Magic_Number: `BadMagic`.
    flip_magic,
    /// Descriptor bit 3 (`§3.1.1.1.1.4`): `ReservedBitSet`.
    set_reserved_bit,
    /// A Dictionary_ID_Flag bit (`§3.1.1.1.3`): `DictionaryRequired`.
    set_dictionary_flag,
    /// Descriptor bit 4 (`§3.1.1.1.1.3`): ignored, so the frame decodes
    /// identically.
    flip_unused_bit,
    /// A flip in the first compressed block's content: the entropy layers'
    /// business (`unknown`).
    entropy_poke,
    /// A flip inside the checksum trailer (`§3.1.1`): `WrongChecksum`.
    flip_trailer,
    /// Block type 3 (`§3.1.1.2.2`): `ReservedBlock`.
    block_reserved_type,
    /// Block_Size 2^21 - 1: `BlockOversize` (`§3.1.1.2.4`).
    block_oversize,
    /// The Last_Block bit on the first block (`§3.1.1.2.1`): a one-block
    /// frame is unchanged; a chain that stops early fails the exact
    /// Frame_Content_Size — or, when the frame declares none (the Writer's),
    /// the trailer check's business.
    last_block_first,
    /// A poked Frame_Content_Size byte (`§3.1.1.1.4`), classified against the
    /// single-segment window coupling; a frame that declares none gets a body
    /// flip instead.
    poke_fcs,
    /// Markers after the frame: ignored by the one-shot, unconsumed by the
    /// reader.
    append_markers,
    /// A second copy of the frame: not consumed by one reader.
    duplicate_frame,
    /// A skippable frame before the frame (`§3.1.2`): consumed and ignored.
    skippable_prefix,
};

/// The corruption taxonomy over our own encoder's frames: the decode-side
/// mutation classes, seeded with real encoder output (real Huffman trees and
/// FSE tables, real repeat modes, both header forms).
///
/// Each iteration builds one frame — the one-shot's FCS-known form from a
/// Smith source, or the Writer's FCS-unknown form — copies it into the
/// mutation buffer, applies one mutation, and pins the class the decode-side
/// taxonomy pins for it. The universal properties are the decode side's: the
/// cap held (sentinel), the one-shot and the reader agree (same bytes or the
/// same named error), a clean reader end is trailer-verified at the exact
/// frame boundary, and a failure is sticky.
fn fuzzEncodeCorruption(_: void, smith: *Smith) anyerror!void {
    const kind = smith.value(EncodeInput);
    const size = ladderSize(smith, &corrupt_sizes, corrupt_encode_max);
    const content = smith.value(u64);
    const writer_frame = smith.boolWeighted(1, 3);
    const mutation = smith.value(EncodeMutation);

    var source: [corrupt_encode_max]u8 = undefined;
    fillEncodeInput(kind, content, source[0..size]);

    var frame_buf: [corrupt_frame_max]u8 = undefined;
    const frame_len = if (writer_frame)
        try streamFrame(source[0..size], &frame_buf)
    else
        try encode.compress(source[0..size], &frame_buf, .{});

    var mut_buf: [encode_mutation_max]u8 = undefined;
    const meta = mutateEncodeFrame(smith, &mut_buf, frame_buf[0..frame_len], mutation);
    try checkMutation(smith, mut_buf[0..meta.len], source[0..size], meta);
}

/// The Writer's frame for `source` into `out`, one write and one `finish`
/// (the chunking is the machinery target's business). Returns its length.
fn streamFrame(source: []const u8, out: []u8) !usize {
    var fw: Io.Writer = .fixed(out);
    var buffer: Writer.Buffer(Writer.default_window_log) = undefined;
    var w: Writer = .init(Writer.default_window_log, &fw, &buffer, .{});
    try w.writer.writeAll(source);
    try w.finish();
    return fw.end;
}

/// Apply one Smith-chosen mutation to `frame_bytes` in `buf` and return the
/// mutated length, the outcome class it pins, and the frame's end in the
/// mutated bytes.
fn mutateEncodeFrame(
    smith: *Smith,
    buf: []u8,
    frame_bytes: []const u8,
    mutation: EncodeMutation,
) Mutated {
    // Our own frames always analyze: a frame that does not is an encoder bug,
    // not input.
    const info = analyze(frame_bytes).?;
    assert(frame_bytes.len <= buf.len);
    fastmem.copy(u8, buf[0..frame_bytes.len], frame_bytes);
    var len = frame_bytes.len;
    var frame_end = info.end;
    var expected: Expected = .unknown;
    switch (mutation) {
        .truncate => {
            const cut = rangeAtMost(smith, 0, frame_bytes.len - 1);
            len = cut;
            if (cut >= frame_end) {
                expected = .exact_source;
            } else if (cut < info.first_block_at) {
                // Inside the Magic_Number or the Frame_Header: the input ends
                // before any body byte.
                expected = .fail_truncated;
            } else if (info.trailer_at) |trailer_at| {
                // A cut inside the trailer leaves the body intact and is
                // `Truncated` exactly; earlier the body's bits run out first.
                expected = if (cut >= trailer_at) .fail_truncated else .fail_any;
            } else {
                expected = .fail_any;
            }
        },
        .flip_magic => {
            buf[rangeAtMost(smith, 0, frame.magic_len - 1)] ^= flipValue(smith);
            expected = .fail_bad_magic;
        },
        .set_reserved_bit => {
            buf[info.start + frame.magic_len] |= frame.descriptor_reserved;
            expected = .fail_reserved_bit;
        },
        .set_dictionary_flag => {
            // §3.1.1.1.3 — the DID field is read whole and a value of 0
            // means "no Dictionary_ID", so the flag alone is not enough for
            // the no-dictionary refusal: the field's first byte (low byte,
            // little-endian) is forced nonzero. The header is corrupt either
            // way, and the check fires before any body byte.
            const descriptor_at = info.start + frame.magic_len;
            const bit: u8 = @as(u8, 1) << @intCast(rangeAtMost(smith, 0, 1));
            buf[descriptor_at] |= bit;
            const window_len: usize = if (buf[descriptor_at] & frame.descriptor_single_segment == 0)
                1
            else
                0;
            buf[descriptor_at + 1 + window_len] |= 0x2a;
            expected = .fail_dictionary;
        },
        .flip_unused_bit => {
            buf[info.start + frame.magic_len] ^= frame.descriptor_unused;
            expected = .exact_source;
        },
        .entropy_poke => {
            if (info.first_block.block_type == .compressed and info.first_block.block_size > 0) {
                const at = info.first_content_at +
                    rangeAtMost(smith, 0, info.first_block.block_size - 1);
                buf[at] ^= flipValue(smith);
            } else {
                buf[rangeAtMost(smith, info.first_block_at, bodyEnd(info))] ^= flipValue(smith);
            }
            expected = .unknown;
        },
        .flip_trailer => {
            if (info.trailer_at) |trailer_at| {
                const at = trailer_at + rangeAtMost(smith, 0, frame.checksum_len - 1);
                buf[at] ^= flipValue(smith);
                expected = .fail_wrong_checksum;
            } else {
                buf[rangeAtMost(smith, info.first_block_at, bodyEnd(info))] ^= flipValue(smith);
                expected = .unknown;
            }
        },
        .block_reserved_type => {
            buf[info.first_block_at] |= 0b0000_0110;
            expected = .fail_reserved_block;
        },
        .block_oversize => {
            buf[info.first_block_at] |= 0b1111_1000;
            buf[info.first_block_at + 1] = 0xff;
            buf[info.first_block_at + 2] = 0xff;
            expected = .fail_block_oversize;
        },
        .last_block_first => {
            buf[info.first_block_at] |= 1;
            expected = if (info.header.content_size == null)
                .unknown
            else if (info.block_count == 1)
                .exact_source
            else
                .fail_content_size;
        },
        .poke_fcs => {
            const fcs_len = frame.fcsFieldSize(info.header.descriptor);
            if (fcs_len == 0) {
                // The Writer declares no Frame_Content_Size: the body flip
                // stands in.
                buf[rangeAtMost(smith, info.first_block_at, bodyEnd(info))] ^= flipValue(smith);
                expected = .unknown;
            } else {
                // The FCS is the header's last field, so it ends where the
                // block chain begins.
                const fcs_at = info.first_block_at - fcs_len;
                buf[fcs_at + rangeAtMost(smith, 0, fcs_len - 1)] ^= flipValue(smith);
                const new_fcs = readFcs(buf[fcs_at..][0..fcs_len]);
                const block_max: u64 = @min(new_fcs, @as(u64, block.max_block_size));
                const oversize = info.first_block.block_size > block_max;
                expected = .fail_content_size;
                if (info.header.descriptor & frame.descriptor_single_segment != 0) {
                    if (oversize) {
                        expected = .fail_block_oversize;
                    } else if (new_fcs < info.header.window_size) {
                        // The window shrank: a match may now reach past it
                        // (`§3.1.1.4`), so the failure's name is the decode's
                        // business.
                        expected = .unknown;
                    }
                }
            }
        },
        .append_markers => {
            const extra = rangeAtMost(smith, 1, 64);
            fastmem.set(u8, buf[len..][0..extra], marker_byte);
            len += extra;
            expected = .exact_source;
        },
        .duplicate_frame => {
            if (frame_end <= buf.len - len) {
                fastmem.copy(u8, buf[len..][0..frame_end], buf[0..frame_end]);
                len += frame_end;
            }
            expected = .exact_source;
        },
        .skippable_prefix => {
            const prefix = [_]u8{ 0x50, 0x2a, 0x4d, 0x18, 4, 0, 0, 0, 'm', 'e', 't', 'a' };
            fastmem.move(u8, buf[prefix.len..][0..frame_bytes.len], buf[0..frame_bytes.len]);
            fastmem.copy(u8, buf[0..prefix.len], &prefix);
            len += prefix.len;
            frame_end += prefix.len;
            expected = .exact_source;
        },
    }
    return .{ .len = len, .expected = expected, .frame_end = frame_end };
}

/// A corruption seed: the kind, the size, the content seed, the frame form
/// (the one-shot's or the Writer's), the mutation, and the mutation's first
/// parameter.
fn corruptionSeed(
    comptime kind: EncodeInput,
    comptime size: usize,
    comptime content: u64,
    comptime writer: bool,
    comptime mutation: EncodeMutation,
    comptime param: u64,
) [48]u8 {
    var seed: [48]u8 = undefined;
    mem.writeInt(u64, seed[0..8], @intFromEnum(kind), .little);
    mem.writeInt(u64, seed[8..16], sizeIndex(&corrupt_sizes, size), .little);
    mem.writeInt(u64, seed[16..24], content, .little);
    mem.writeInt(u64, seed[24..32], @intFromBool(writer), .little);
    mem.writeInt(u64, seed[32..40], @intFromEnum(mutation), .little);
    mem.writeInt(u64, seed[40..48], param, .little);
    return seed;
}

/// Seeds for `fuzzEncodeCorruption`: one per operator over a source that
/// exercises it, on both frame forms.
const encode_corruption_corpus: []const []const u8 = &.{
    &corruptionSeed(.corpus, 4096, shapeContent(.text), false, .truncate, 0),
    &corruptionSeed(.corpus, 4096, shapeContent(.text), false, .flip_magic, 0),
    &corruptionSeed(.corpus, 4096, shapeContent(.text), false, .set_reserved_bit, 0),
    &corruptionSeed(.corpus, 4096, shapeContent(.text), false, .set_dictionary_flag, 0),
    &corruptionSeed(.corpus, 4096, shapeContent(.text), false, .flip_unused_bit, 0),
    &corruptionSeed(.corpus, 4096, shapeContent(.text), false, .entropy_poke, 0),
    &corruptionSeed(.corpus, 1024, shapeContent(.mixed), false, .flip_trailer, 0),
    &corruptionSeed(.corpus, 4096, shapeContent(.text), false, .block_reserved_type, 0),
    &corruptionSeed(.corpus, 4096, shapeContent(.text), false, .block_oversize, 0),
    &corruptionSeed(.corpus, 131073, shapeContent(.text), false, .last_block_first, 0),
    &corruptionSeed(.corpus, 4096, shapeContent(.text), false, .last_block_first, 0),
    &corruptionSeed(.corpus, 131073, shapeContent(.text), false, .poke_fcs, 0),
    &corruptionSeed(.corpus, 4096, shapeContent(.text), false, .append_markers, 0),
    &corruptionSeed(.corpus, 4096, shapeContent(.text), false, .duplicate_frame, 0),
    &corruptionSeed(.corpus, 4096, shapeContent(.text), false, .skippable_prefix, 0),
    &corruptionSeed(.period, 150_000, 17, true, .truncate, 0),
    &corruptionSeed(.corpus, 131073, shapeContent(.words), true, .last_block_first, 0),
    &corruptionSeed(.corpus, 4096, shapeContent(.text), true, .poke_fcs, 0),
    &corruptionSeed(.corpus, 4096, shapeContent(.text), true, .flip_trailer, 0),
    // Regression seed (the fuzzer's own input, the raw Smith data): a Writer
    // frame for an alphabet-shaped 150-KB source whose DID flag is forced on.
    // The DID poke shifts the header, so the mutated header also parses a
    // window past the reader's buffer — and the reader's Dictionary_ID check
    // precedes its window check, so the detail is `DictionaryRequired`, not
    // the window override's `WindowTooLarge`.
    &corruption_did_seed,
};

/// The fuzz-found regression input behind the corpus row above
/// (`fuzzEncodeCorruption`'s Smith data, verbatim).
const corruption_did_seed = [_]u8{
    0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0e, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xca, 0xb5, 0xe7, 0xdf, 0x1a, 0x77, 0x95, 0x0b, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

test "zstd fuzz: encode corruption" {
    try testing.fuzz({}, fuzzEncodeCorruption, .{ .corpus = encode_corruption_corpus });
}

// ---------------------------------------------------------------------------
// Target 9: the Writer's consumer machinery and poison lifecycle
// ---------------------------------------------------------------------------

/// The `Io.Writer` operations `fuzzWriterMachinery` mixes: the same set as
/// Writer.zig's "random write machinery sequences stay correct" test.
const WriteOp = enum(u8) {
    write_splat_all,
    write_vec_all,
    splat_bytes_all,
    writable_slice,
    byte_and_flush,
    write_all,
    /// A bare flush: the zero-data flush when nothing is buffered.
    flush,
};

/// The Writer's consumer machinery: Smith-chosen `Io.Writer` operation
/// sequences against a model of the bytes written.
///
/// Covers `drain`/`rebase`/`flush` accounting under the full `Io.Writer`
/// contract (`writeSplatAll` with a splat count, `writeVecAll`,
/// `splatBytesAll`, `writableSliceGreedy` + `advance` — which lands on
/// `rebase` when the block region is full — `writeByte`, plain writes, bare
/// flushes, and mid-stream flushes), the block emissions and window slides
/// the operations force, the final empty last block, and the exact frame
/// boundary through the streaming reader. The window log is Smith-chosen from
/// the small classes to the default, so the block region, the slide, and the
/// emission cadence all vary. The poison lifecycle runs after the frame: a
/// writer at an unimplemented level, a sink that fills mid-frame, `finish`
/// twice, and a write after `finish` must all report `error.WriteFailed`, and
/// a finished or failed writer never reports a false success.
fn fuzzWriterMachinery(_: void, smith: *Smith) anyerror!void {
    switch (rangeAtMost(smith, 0, 3)) {
        0 => try machineryCase(10, smith),
        1 => try machineryCase(12, smith),
        2 => try machineryCase(14, smith),
        else => try machineryCase(19, smith),
    }
    try writerPoison(smith);
}

/// One machinery frame at `window_log`: the op sequence, the model, the
/// identity decode, and the exact boundary.
fn machineryCase(comptime window_log: usize, smith: *Smith) !void {
    var out: [machinery_out_max]u8 = undefined;
    var fw: Io.Writer = .fixed(&out);
    var buffer: Writer.Buffer(window_log) = undefined;
    var w: Writer = .init(window_log, &fw, &buffer, .{});

    var model: [machinery_max]u8 = undefined;
    var model_len: usize = 0;

    var a: [1024]u8 = undefined;
    var b: [8192]u8 = undefined;
    var pattern: [7]u8 = undefined;
    smith.bytes(&a);
    smith.bytes(&b);
    smith.bytes(&pattern);

    var remaining = machinery_max;
    var ops: usize = 0;
    while (ops < machinery_ops_max and !smith.eosWeightedSimple(15, 1)) : (ops += 1) {
        const op = smith.value(WriteOp);
        const a_len = rangeAtMost(smith, 0, a.len);
        const b_len = rangeAtMost(smith, 0, b.len);
        const p_len = rangeAtMost(smith, 1, pattern.len);
        const splat = rangeAtMost(smith, 0, 2048);
        const byte = smith.value(u8);
        const flush_now = smith.boolWeighted(1, 1);
        const max_written: usize = switch (op) {
            .write_splat_all => a_len + b_len + p_len * splat,
            .write_vec_all => a_len + b_len,
            .splat_bytes_all => p_len * splat,
            .writable_slice => b_len,
            .byte_and_flush => 1,
            .write_all => b_len,
            .flush => 0,
        };
        if (max_written > remaining) continue;
        remaining -= max_written;

        switch (op) {
            .write_splat_all => {
                var data = [_][]const u8{ a[0..a_len], b[0..b_len], pattern[0..p_len] };
                try w.writer.writeSplatAll(&data, splat);
                try appendModel(&model, &model_len, a[0..a_len]);
                try appendModel(&model, &model_len, b[0..b_len]);
                for (0..splat) |_| try appendModel(&model, &model_len, pattern[0..p_len]);
            },
            .write_vec_all => {
                var data = [_][]const u8{ a[0..a_len], b[0..b_len] };
                try w.writer.writeVecAll(&data);
                try appendModel(&model, &model_len, a[0..a_len]);
                try appendModel(&model, &model_len, b[0..b_len]);
            },
            .splat_bytes_all => {
                try w.writer.splatBytesAll(pattern[0..p_len], splat);
                for (0..splat) |_| try appendModel(&model, &model_len, pattern[0..p_len]);
            },
            .writable_slice => {
                // The File.Reader simple-mode path: a direct write into the
                // block region, which lands on `rebase` when it is full.
                const dest = try w.writer.writableSliceGreedy(1);
                const n = @min(dest.len, b_len);
                fastmem.copy(u8, dest[0..n], b[0..n]);
                w.writer.advance(n);
                try appendModel(&model, &model_len, b[0..n]);
            },
            .byte_and_flush => {
                try w.writer.writeByte(byte);
                try appendModel(&model, &model_len, &[_]u8{byte});
                if (flush_now) try w.writer.flush();
            },
            .write_all => {
                try w.writer.writeAll(b[0..b_len]);
                try appendModel(&model, &model_len, b[0..b_len]);
            },
            .flush => try w.writer.flush(),
        }
    }
    try w.finish();
    const frame_len = fw.end;
    // The sink is sized for the window ladder's worst case (the 1-KiB block
    // region), the op budget's flushes, and the final empty block; the
    // one-shot's `maxCompressedLength` budgets only a 128-KiB region's split.
    try testing.expect(frame_len <= machinery_out_max);

    // Identity through the one-shot, with the sentinel.
    var plain: [machinery_max + guard_len]u8 = undefined;
    sentinel.fill(&plain);
    const n = try decode.decompress(out[0..frame_len], plain[0..model_len], null);
    try testing.expectEqual(model_len, n);
    try testing.expectEqualSlices(u8, model[0..model_len], plain[0..n]);
    try sentinel.expect(&plain, n);

    // The exact frame boundary through the streaming reader.
    try expectFrameBoundary(out[0..frame_len], model[0..model_len]);
}

/// Append `bytes` to the model; the op budget keeps the model inside its
/// buffer, so an overflow is a bug, not input.
fn appendModel(model: []u8, len: *usize, bytes: []const u8) !void {
    if (bytes.len > model.len - len.*) return error.ModelOverflow;
    fastmem.copy(u8, model[len.*..][0..bytes.len], bytes);
    len.* += bytes.len;
}

/// The frame's exact end through the streaming reader: identity against the
/// model, the clean end (no detail, state `done`), the trailer verified, and
/// the input consumed through the frame's last byte — markers after it are
/// the caller's.
fn expectFrameBoundary(frame_bytes: []const u8, expected: []const u8) !void {
    var framed: [machinery_out_max + marker_len]u8 = undefined;
    fastmem.copy(u8, framed[0..frame_bytes.len], frame_bytes);
    fastmem.set(u8, framed[frame_bytes.len..][0..marker_len], marker_byte);
    var got: [machinery_max + guard_len]u8 = undefined;
    var fw: Io.Writer = .fixed(&got);
    var rbuf: Reader.Buffer(fixture_window_len) = undefined;
    var fixed_in: Io.Reader = .fixed(framed[0 .. frame_bytes.len + marker_len]);
    var r: Reader = .init(fixture_window_len, &fixed_in, &rbuf, null);
    try pump(&r.reader, &fw, pumpLimit(expected.len));
    try testing.expectEqual(expected.len, fw.end);
    try testing.expectEqualSlices(u8, expected, got[0..fw.end]);
    try testing.expectEqual(@as(?Reader.Error, null), r.err);
    try testing.expectEqual(internal.reader.State.done, r.state);
    try testing.expectEqual(frame_bytes.len, fixed_in.seek);
    try expectTrailerConsistent(frame_bytes, frame_bytes.len, expected, true);
    try expectStickyEnd(&r);
}

/// The poison lifecycle: a sink that fills mid-frame, `finish` twice, and a
/// write after `finish` — every one reports `error.WriteFailed`, and no false
/// success.
fn writerPoison(smith: *Smith) !void {
    var buffer: Writer.Buffer(10) = undefined;
    switch (rangeAtMost(smith, 0, 2)) {
        // The sink fills mid-frame: the buffered block's emission fails and
        // `finish` reports it — twice, never a false success — and the writer
        // stays poisoned.
        0 => {
            var out: [8]u8 = undefined;
            var fw: Io.Writer = .fixed(&out);
            var w: Writer = .init(10, &fw, &buffer, .{});
            try w.writer.writeAll("a" ** 512);
            try testing.expectError(error.WriteFailed, w.finish());
            try testing.expectError(error.WriteFailed, w.finish());
            try testing.expectError(error.WriteFailed, w.writer.writeAll("more"));
            try testing.expect(fw.end <= out.len);
        },
        // `finish` twice and a write after `finish` on a healthy writer: the
        // frame is complete, the later calls fail, and the sink does not
        // grow.
        1 => {
            var out: [256]u8 = undefined;
            var fw: Io.Writer = .fixed(&out);
            var w: Writer = .init(10, &fw, &buffer, .{});
            try w.writer.writeAll("hello, zstd");
            try w.finish();
            const complete = fw.end;
            try testing.expectError(error.WriteFailed, w.writer.writeAll("more"));
            try testing.expectError(error.WriteFailed, w.finish());
            try testing.expectEqual(complete, fw.end);
        },
        // A write after `finish` on an empty writer: the empty frame is
        // written, the later write fails, and the frame still decodes to
        // nothing.
        else => {
            var out: [64]u8 = undefined;
            var fw: Io.Writer = .fixed(&out);
            var w: Writer = .init(10, &fw, &buffer, .{});
            try w.finish();
            const complete = fw.end;
            try testing.expectError(error.WriteFailed, w.writer.writeAll("late"));
            try testing.expectEqual(complete, fw.end);
            var nothing: [guard_len]u8 = undefined;
            sentinel.fill(&nothing);
            const n = try decode.decompress(out[0..complete], &nothing, null);
            try testing.expectEqual(@as(usize, 0), n);
            try sentinel.expect(&nothing, 0);
        },
    }
}

/// A machinery seed: the window-log choice, then one record per operation
/// (the op, the slice lengths, the splat count, the byte, and the flush flag),
/// a stop flag, and the poison case. Each op consumes its record whatever the
/// op turns out to be, so the seed layout is fixed.
fn machinerySeed(
    comptime log_choice: u64,
    comptime records: []const [7]u64,
    comptime poison: u64,
) [8 + 64 * records.len + 16]u8 {
    var seed: [8 + 64 * records.len + 16]u8 = undefined;
    mem.writeInt(u64, seed[0..8], log_choice, .little);
    for (records, 0..) |record, index| {
        const at = 8 + 64 * index;
        mem.writeInt(u64, seed[at..][0..8], 0, .little); // eos: continue
        for (record, 0..) |value, field| {
            mem.writeInt(u64, seed[at + 8 + 8 * field ..][0..8], value, .little);
        }
    }
    const stop = 8 + 64 * records.len;
    mem.writeInt(u64, seed[stop..][0..8], 16, .little); // eos: stop
    mem.writeInt(u64, seed[stop + 8 ..][0..8], poison, .little);
    return seed;
}

/// Seeds for `fuzzWriterMachinery`: every op, every window class, and every
/// poison case.
const machinery_corpus: []const []const u8 = &.{
    // One write at the default window: the frame is one block at `finish`.
    &machinerySeed(3, &.{
        .{ @intFromEnum(WriteOp.write_all), 0, 4096, 1, 0, 0, 0 },
    }, 2),
    // The small window: the block region fills four times over one write.
    &machinerySeed(0, &.{
        .{ @intFromEnum(WriteOp.write_all), 0, 4096, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.writable_slice), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.byte_and_flush), 0, 0, 1, 0, 0x5a, 1 },
        .{ @intFromEnum(WriteOp.splat_bytes_all), 0, 0, 7, 512, 0, 0 },
        .{ @intFromEnum(WriteOp.flush), 0, 0, 1, 0, 0, 0 },
    }, 1),
    // The splat path across the slide: the window compacts repeatedly.
    &machinerySeed(1, &.{
        .{ @intFromEnum(WriteOp.write_splat_all), 1024, 8192, 7, 2048, 0, 0 },
    }, 0),
    // Vector writes and byte writes at the 16-KiB class.
    &machinerySeed(2, &.{
        .{ @intFromEnum(WriteOp.write_vec_all), 1024, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.byte_and_flush), 0, 0, 1, 0, 0xa5, 1 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.flush), 0, 0, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
    }, 3),
    // Many writes at the default window: a block emits when the region fills.
    &machinerySeed(3, &.{
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
        .{ @intFromEnum(WriteOp.write_all), 0, 8192, 1, 0, 0, 0 },
    }, 1),
    // The zero-data flush alone.
    &machinerySeed(3, &.{
        .{ @intFromEnum(WriteOp.flush), 0, 0, 1, 0, 0, 0 },
    }, 0),
};

test "zstd fuzz: writer machinery" {
    try testing.fuzz({}, fuzzWriterMachinery, .{ .corpus = machinery_corpus });
}

// ---------------------------------------------------------------------------
// Target 10: the encode amplification limits
// ---------------------------------------------------------------------------

/// The raw fallback's worst case for a `source_len`-byte source: the header
/// form and block split the one-shot's ladder picks (`§3.1.1.1.1.1`,
/// `§3.1.1.1.4`, `§3.1.1.2.4`), every block stored Raw, and the trailer.
/// `maxCompressedLength` must cover it on every size, or the encoder has an
/// input it cannot encode at its own bound.
fn rawWorstCase(source_len: usize) usize {
    const params = match_compress.Params.forSource(1, source_len);
    const block_size = block_compress.blockSize(params);
    const single_segment = (@as(u64, 1) << params.window_log) >= source_len;
    const fcs_len: usize = if (source_len < 256)
        1
    else if (source_len < 65536 + 256)
        2
    else if (source_len < 0xffff_ffff)
        4
    else
        8;
    const header_len = frame.magic_len + 1 + @as(usize, @intFromBool(!single_segment)) + fcs_len;
    const blocks = @max(1, (source_len + block_size - 1) / block_size);
    return header_len + block.block_header_len * blocks + source_len + frame.checksum_len;
}

/// The encode-side amplification limits: the `maxCompressedLength` bound on
/// every emission, the `BufferTooSmall` boundary, and the fallback ladder's
/// worst case.
///
/// The incompressible source is the ladder's worst case: every block falls
/// back to the raw form, so the frame's bytes are exactly the raw need
/// (`header + 3 * blocks + source + trailer`) — the check that
/// `maxCompressedLength` is tight enough for the fallback, and that one byte
/// under the raw need fails `BufferTooSmall` with the cap held. Every
/// emission is decoded back (identity, trailer verified), a Smith-chosen cap
/// either succeeds with a shorter decodable frame or fails `BufferTooSmall`
/// with the cap held, and the bound covers every size on the ladder.
fn fuzzEncodeAmplification(_: void, smith: *Smith) anyerror!void {
    const kind = smith.value(EncodeInput);
    const size = ladderSize(smith, &encode_sizes, encode_max);
    const content = smith.value(u64);
    const raw_case = rangeAtMost(smith, 0, 3);

    var source: [encode_max]u8 = undefined;
    if (raw_case == 0) {
        // The raw fallback's worst case: incompressible bytes.
        golden.fillShape(.random, source[0..size]);
    } else {
        fillEncodeInput(kind, content, source[0..size]);
    }

    var target: [encode_bound + guard_len]u8 = undefined;
    const bound = encode.maxCompressedLength(size);
    const written = try encode.compress(source[0..size], target[0..bound], .{});
    try testing.expect(written <= bound);
    try expectTrailerConsistent(target[0..written], written, source[0..size], true);
    // The dfast class's frames stay inside the same bound (its block size is
    // the same or larger, and its header form no larger).
    {
        var level3: [encode_bound + guard_len]u8 = undefined;
        const written3 = try encode.compress(
            source[0..size],
            level3[0..bound],
            .{ .level = .@"3" },
        );
        try testing.expect(written3 <= bound);
        try expectTrailerConsistent(level3[0..written3], written3, source[0..size], true);
    }

    // The raw need of this frame: the header, one 3-byte Block_Header per
    // block, the source bytes, and the trailer. No emission exceeds it — the
    // raw form is the ladder's ceiling.
    const info = analyze(target[0..written]).?;
    const header_len = frame.magic_len + info.header.bytes_consumed;
    const raw_need = header_len +
        block.block_header_len * info.block_count + size + frame.checksum_len;
    try testing.expect(raw_need <= bound);
    try testing.expect(written <= raw_need);

    if (raw_case == 0) {
        // The incompressible shape is the raw fallback exactly: every block
        // stored Raw, so the frame's length is the raw need.
        try testing.expectEqual(raw_need, written);
        var cursor = frame.magic_len + info.header.bytes_consumed;
        while (true) {
            const bh = try block.parseHeader(target[cursor..]);
            try testing.expectEqual(block.BlockType.raw, bh.block_type);
            cursor += block.block_header_len + block.contentLength(bh);
            if (bh.last_block) break;
        }
        // The frame-header write gates on the 18-byte cap
        // (`encode.zig`'s `frame_header_len_max`, the dictionary frame's
        // worst header) whatever the frame's own header form is, so a target
        // under it fails even when the frame's bytes would fit. At or above
        // it the exact raw need succeeds; one byte under fails with the cap
        // held.
        const header_gate = encode.frame_header_len_max;
        const exact_cap = @max(raw_need, header_gate);
        sentinel.fill(&target);
        if (raw_need >= header_gate) {
            const exact = try encode.compress(source[0..size], target[0..raw_need], .{});
            try testing.expectEqual(raw_need, exact);
            try sentinel.expect(&target, exact);
        } else {
            try testing.expectError(
                error.BufferTooSmall,
                encode.compress(source[0..size], target[0..raw_need], .{}),
            );
            try sentinel.expect(&target, raw_need);
        }
        sentinel.fill(&target);
        try testing.expectError(
            error.BufferTooSmall,
            encode.compress(source[0..size], target[0 .. exact_cap - 1], .{}),
        );
        try sentinel.expect(&target, exact_cap - 1);
    }

    // A Smith-chosen cap: a shorter frame that still decodes to the source,
    // or `BufferTooSmall` with the cap held.
    const cap = rangeAtMost(smith, 0, bound);
    sentinel.fill(&target);
    var plain: [encode_out_max]u8 = undefined;
    if (encode.compress(source[0..size], target[0..cap], .{})) |short| {
        // A successful emission writes its frame into the target's front; a
        // block whose entropy attempt fails partway can leave bytes past the
        // returned length inside the target (the C's encoder does the same),
        // so the checked property is the cap: nothing past the slice.
        try testing.expect(short <= cap);
        try sentinel.expect(&target, cap);
        sentinel.fill(&plain);
        const n = try decode.decompress(target[0..short], plain[0..size], null);
        try testing.expectEqual(size, n);
        try testing.expectEqualSlices(u8, source[0..size], plain[0..n]);
        try sentinel.expect(&plain, n);
    } else |err| {
        try testing.expectEqual(error.BufferTooSmall, err);
        try sentinel.expect(&target, cap);
    }

    // Every size on the ladder: the bound covers the raw fallback's worst
    // case (the header form and block split the ladder picks).
    for (bound_sizes) |ladder_size| {
        try testing.expect(rawWorstCase(ladder_size) <= encode.maxCompressedLength(ladder_size));
    }
}

/// Seeds for `fuzzEncodeAmplification`: the raw-fallback class (the pinned
/// tight case) and the compressible classes, at the ladder's boundaries.
const encode_amplification_corpus: []const []const u8 = &.{
    &encodeSeed(&encode_sizes, .corpus, 0, shapeContent(.text), 0),
    &encodeSeed(&encode_sizes, .corpus, 1, shapeContent(.text), 0),
    &encodeSeed(&encode_sizes, .corpus, 7, shapeContent(.text), 0),
    &encodeSeed(&encode_sizes, .corpus, 1024, shapeContent(.text), 1),
    &encodeSeed(&encode_sizes, .corpus, 65537, shapeContent(.text), 2),
    &encodeSeed(&encode_sizes, .corpus, 131073, shapeContent(.text), 0),
    &encodeSeed(&encode_sizes, .corpus, 262145, shapeContent(.text), 0),
    &encodeSeed(&encode_sizes, .uniform, 262145, 0x1234, 0),
    &encodeSeed(&encode_sizes, .uniform, 131073, 0x5678, 3),
    &encodeSeed(&encode_sizes, .corpus, 16385, shapeContent(.zeros), 0),
};

test "zstd fuzz: encode amplification" {
    try testing.fuzz({}, fuzzEncodeAmplification, .{ .corpus = encode_amplification_corpus });
}

// ---------------------------------------------------------------------------
// Deterministic tests: fixed inputs, not driven by the fuzzer
// ---------------------------------------------------------------------------

test "zstd fuzz: the corpus decodes to its models" {
    // Every row's expected bytes, through the one-shot at the exact cap and
    // with slack: a wrong table entry fails here rather than inside a budget
    // run, and every row's structure analyzes (the mutations' model).
    for (rows) |row| {
        const unit = unitOf(row.source);
        var expected_buf: [out_max]u8 = undefined;
        const expected = materialize(row.output, &expected_buf);
        var window: [out_max + guard_len]u8 = undefined;
        sentinel.fill(&window);
        const n = try decode.decompress(row.source, window[0..expected.len], null);
        try testing.expectEqual(expected.len, n);
        try testing.expectEqualSlices(u8, expected, window[0..n]);
        try sentinel.expect(&window, n);
        sentinel.fill(&window);
        const m = try decode.decompress(row.source, &window, null);
        try testing.expectEqual(n, m);
        try testing.expectEqualSlices(u8, expected, window[0..m]);
        try sentinel.expect(&window, m);
        // The unit's boundary is inside the source, and a frame-carrying
        // unit's structure round-trips through the walk model.
        try testing.expect(unit.end <= row.source.len);
        if (unit.frame) |info| try testing.expect(info.end == unit.end);
    }
}

test "zstd fuzz: the bad-frame corpus pins its errors and floors" {
    for (bad_rows) |row| {
        var window: [out_max + guard_len]u8 = undefined;
        sentinel.fill(&window);
        try testing.expectError(row.err, decode.decompress(row.source, window[0..out_max], null));
        try sentinel.expect(&window, row.written);
    }
}

test "zstd fuzz: the reader's 4-byte input precondition" {
    // The reader's input must buffer at least 4 bytes, the frame layer's
    // largest fixed-size read, or end before then. A `Limited` at exactly four
    // bytes must still decode the checksummed frame byte-exact: the 4-byte
    // magic and trailer reads are what the minimum exists for.
    var chunk_buf: [4]u8 = undefined;
    var fixed_in: Io.Reader = .fixed(&golden.frame_checksum);
    var limited: Io.Reader.Limited = .init(&fixed_in, .unlimited, &chunk_buf);
    var got: [out_max]u8 = undefined;
    var fw: Io.Writer = .fixed(&got);
    var rbuf: Reader.Buffer(fixture_window_len) = undefined;
    var r: Reader = .init(fixture_window_len, &limited.interface, &rbuf, null);
    try pump(&r.reader, &fw, pumpLimit(4));
    try testing.expectEqualSlices(u8, "abcd", got[0..fw.end]);
    try testing.expectEqual(@as(?Reader.Error, null), r.err);
    try testing.expectEqual(internal.reader.State.done, r.state);
    try testing.expectEqual(golden.frame_checksum.len, fixed_in.seek);
    try expectStickyEnd(&r);
}

test "zstd fuzz: the codec's rebase runs the trailer step at the frame's tail" {
    // Consume one byte, then ask for the whole buffer: the std fill routes the
    // request through the reader's `rebase`, whose trailer branch must read
    // and verify the trailer (`§3.1.1`) before reporting the clean end, and
    // must fail `WrongChecksum` when the trailer is corrupt.
    const buffer_len = bufferLen();
    {
        var fixed_in: Io.Reader = .fixed(&golden.frame_checksum);
        var rbuf: Reader.Buffer(fixture_window_len) = undefined;
        var r: Reader = .init(fixture_window_len, &fixed_in, &rbuf, null);
        const first = try r.reader.take(1);
        try testing.expectEqual(@as(u8, 'a'), first[0]);
        try testing.expectError(error.EndOfStream, r.reader.peek(buffer_len));
        try testing.expectEqual(@as(?Reader.Error, null), r.err);
        try testing.expectEqual(internal.reader.State.done, r.state);
        try testing.expectEqual(golden.frame_checksum.len, fixed_in.seek);
    }
    {
        // The same shape over the corrupted trailer: the check must run and
        // refuse, not pass the end through.
        var fixed_in: Io.Reader = .fixed(&golden.frame_checksum_corrupt);
        var rbuf: Reader.Buffer(fixture_window_len) = undefined;
        var r: Reader = .init(fixture_window_len, &fixed_in, &rbuf, null);
        _ = try r.reader.take(1);
        try testing.expectError(error.ReadFailed, r.reader.peek(buffer_len));
        try testing.expectEqual(Reader.Error.WrongChecksum, r.err.?);
        try expectStickyFailure(&r);
    }
    {
        // The fill path at the same tail: an over-cap peek from a fresh
        // reader decodes to the frame's end and reports the clean end only
        // after the trailer was verified (the frame is checksummed).
        var fixed_in: Io.Reader = .fixed(&golden.frame_checksum);
        var rbuf: Reader.Buffer(fixture_window_len) = undefined;
        var r: Reader = .init(fixture_window_len, &fixed_in, &rbuf, null);
        try testing.expectError(error.EndOfStream, r.reader.peek(windowTailLen() + 1));
        try testing.expectEqual(@as(?Reader.Error, null), r.err);
        try testing.expectEqual(internal.reader.State.done, r.state);
        try testing.expectEqual(golden.frame_checksum.len, fixed_in.seek);
    }
}

test "zstd fuzz: the checksum reference pins the empty and multi-block frames" {
    // §3.1.1 — the empty payload's XXH64: std's canonical check value
    // (docs/slop/research/zstd-notes.md §3), and the trailer the C library wrote
    // for it.
    try testing.expectEqual(
        @as(u64, 0xEF46_DB37_51D8_E999),
        XxHash64.hash(0, ""),
    );
    const empty_info = analyze(&golden.frame_checksum_empty).?;
    try testing.expectEqual(
        @as(u32, 0x51D8_E999),
        readInt(u32, golden.frame_checksum_empty[empty_info.trailer_at.?..][0..frame.checksum_len]),
    );
    // The multi-block frame's trailer is over all 135000 bytes in order.
    const multi_info = analyze(&golden.frame_checksum_multi).?;
    const multi_expected = golden.frame_checksum_multi_text ** 3000;
    try testing.expectEqual(
        @as(u32, @truncate(XxHash64.hash(0, multi_expected))),
        readInt(
            u32,
            golden.frame_checksum_multi[multi_info.trailer_at.?..][0..frame.checksum_len],
        ),
    );
}

test "zstd fuzz: the exceed-only table corner" {
    // §4.1.1 — the FSE distribution's symbol-count rule is the reference's
    // exceed-only reading (docs/slop/research/zstd-notes.md §4). A distribution
    // that spends its budget before the context's last symbol is legal (the
    // reference encoder emits them), while a description that runs past its
    // context is corruption. The golden descriptions are the reference
    // encoder's own bytes.
    const weights = try fse.readDescription(golden.weights_description[1..], 255, 6);
    try testing.expectEqual(@as(u16, 9), weights.symbol_count);
    try testing.expectEqual(@as(u5, 5), weights.accuracy_log);
    const literals_lengths = try fse.readDescription(&golden.literals_length_description, 35, 9);
    try testing.expectEqual(@as(u16, 34), literals_lengths.symbol_count);
    // The same description against a context that ends at symbol 2: the
    // distribution covers 9 symbols, so it must be refused, not truncated.
    try testing.expectError(
        error.MalformedFseTable,
        fse.readDescription(golden.weights_description[1..], 2, 6),
    );
    // The budget-exactness half: a description cut inside its fields cannot
    // land on the table size.
    try testing.expectError(
        error.MalformedFseTable,
        fse.readDescription(golden.weights_description[1..4], 255, 6),
    );
}

test "zstd fuzz: an oversized RLE block fails the same way on both paths" {
    // An RLE block whose declared Block_Size is past Block_Maximum_Size, with
    // its content byte missing. Both paths must report `BlockOversize`
    // (`§3.1.1.2.4`): the declared-size check runs before the content is read,
    // so the reader must not report the input's end (`Truncated`) first.
    // `checkReader` enforces the same agreement on mutated frames.
    const source = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x48, 0xfb, 0xff, 0xff };
    var target: [1024]u8 = undefined;
    sentinel.fill(&target);
    try testing.expectError(error.BlockOversize, decode.decompress(&source, &target, null));
    try sentinel.expect(&target, 0);

    var rbuf: Reader.Buffer(fixture_window_len) = undefined;
    var fixed_in: Io.Reader = .fixed(&source);
    var r: Reader = .init(fixture_window_len, &fixed_in, &rbuf, null);
    var got: [1024]u8 = undefined;
    var fw: Io.Writer = .fixed(&got);
    const pumped = try pumpCapped(&r.reader, &fw, 64);
    try testing.expectEqual(Stop.read_failed, pumped.stop);
    try testing.expectEqual(Reader.Error.BlockOversize, r.err.?);
    try expectStickyFailure(&r);
}

test "zstd fuzz: the raw fallback fits maxCompressedLength on every class" {
    // The bound is the encoder's promise to every caller that sizes a target
    // with it: no source on the ladder may need more than the bound even when
    // every block falls back to the raw form (the incompressible case).
    for (bound_sizes) |size| {
        try testing.expect(rawWorstCase(size) <= encode.maxCompressedLength(size));
    }
    // §3.1.1.1.4 + §3.1.1.2.4 — the bound's exact-tight case is the windowed
    // 8-byte-FCS form: the 14-byte header, the raw headers of the blocks that
    // do not divide evenly, the source, and the trailer land exactly on the
    // bound. The form needs a size at or above 2^32 - 1, which only a 64-bit
    // `usize` can hold (and only it can encode such a source anyway).
    if (@bitSizeOf(usize) >= 64) {
        // The dictionary's 4-byte Dictionary_ID field is the bound's only
        // slack on a no-dictionary frame: the exact-tight no-dictionary case
        // sits 4 bytes under the bound.
        const tight = 0xffff_ffff;
        try testing.expectEqual(encode.maxCompressedLength(tight), rawWorstCase(tight) + 4);
    }
}
