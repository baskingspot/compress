//! The zstd encoder's block layer (`§3.1.1.2`): one block's emission — the
//! ladder that picks Raw, RLE, or Compressed, the 3-byte Block_Header, and
//! the checksum fold — over the match finder and the two entropy writers.
//!
//! The ladder is the C's `ZSTD_compressBlock_internal` /
//! `ZSTD_entropyCompressSeqStore` (`zstd_compress.c:2888-3060,4383-4444`):
//! a block under 7 bytes is stored raw without an attempt; the entropy
//! writers' output is kept only when it beats `minGain = (size >> 6) + 2`;
//! a block whose bytes are all one value becomes an RLE block once its
//! compressed form is under 25 bytes — except the frame's first block, which
//! is never RLE (the zstd ≤ 1.4.3 CLI convention); and an all-literals
//! block carries a `nbSeq == 0` sequences section. Raw and RLE blocks do not
//! contribute to the frame's cross-block state: the entropy tables and the
//! repeat offsets revert to what the previous block left
//! (`zstd_compress.c:4424-4433`, `§3.1.1.5`).
//!
//! The checksum rides the same funnel the decoder's `frame.State` uses: a
//! Raw block's fold rides its copy, chunk by chunk while the bytes are
//! cache-hot; Compressed and RLE blocks fold through `State.recordBlock`,
//! handed exactly the block's decoded bytes. Either way each byte reaches
//! XXH64 once, in order.
//!
//! Format: docs/research/specs/rfc8878-zstd.txt §3.1.1.2 (blocks), §3.1.1.5
//! (the repeat offsets), §3.1.1 (the checksum).
//! Lineage: facebook/zstd v1.5.7 `zstd_compress.c` (the block emission ladder,
//! `ZSTD_compressBlock_internal` / `ZSTD_entropyCompressSeqStore`); attribution
//! in THIRD_PARTY.md.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const block = @import("block.zig");
/// `§3.1.1.2.4` — Block_Maximum_Size's 128 KiB ceiling: the encoder's block
/// size, and the bound its scratch sizes from.
pub const max_block_size = block.max_block_size;
const common = @import("common.zig");
const literals = @import("literals.zig");
const literals_compress = @import("literals_compress.zig");
const match_compress = @import("match_compress.zig");
const sequences = @import("sequences.zig");
const sequences_compress = @import("sequences_compress.zig");
const xxh64 = @import("xxh64.zig");

/// The largest sequence count one block can carry: every match is at least
/// `min_match_length` bytes, so `max_block_size / 3 + 1` sequences cover the
/// worst case.
pub const max_sequences = max_block_size / match_compress.min_match_length + 1;

/// The match finder's table cap: `hashLog = min(class hashLog, windowLog + 1)`
/// with the ladder's largest class hashLog 15.
pub const hash_table_max = 1 << 15;

/// `MIN_CBLOCK_SIZE + 3 + 1 + 1` (`zstd_compress.c:3267-3273`): below this
/// the C does not even attempt compression.
pub const min_compressible_size = 2 + block.block_header_len + 1 + 1;

/// `rleMaxLength` (`zstd_compress.c:4112`): a block whose compressed form is
/// under 25 bytes and whose bytes are all one value becomes an RLE block.
const rle_max_length = 25;

/// The copy-and-fold chunk for a Raw block, mirroring the decoder's
/// (`block.zig`'s `raw_fold_chunk`): small enough that the source bytes are
/// still cache-resident when the fold reads them, large enough to amortize
/// the per-chunk call.
const raw_fold_chunk = 4 * 1024;

/// The per-block scratch the finder and the writers need, sized by the
/// caller: `literals` for the token stream's literals (a block's literals
/// are at most its size) and `sequences` for its sequence list (at most
/// `max_sequences` entries).
pub const Scratch = struct {
    literals: []u8,
    sequences: []sequences_compress.Sequence,
};

/// The block size the ladder's window implies (`zstd_compress.c:1816`):
/// `min(128 KiB, 1 << windowLog)`, so a small window's frame never carries a
/// block past its own Window_Size (`§3.1.1.2.4`).
pub fn blockSize(params: match_compress.Params) usize {
    return @min(max_block_size, @as(usize, 1) << @intCast(params.window_log));
}

/// Rebase the finder's table on a window slide: every entry that still
/// points into the window drops by `slide`, and every entry that pointed at
/// a dropped byte becomes zero — the table's "no candidate" value, which the
/// finder's `candidate_floor` never reads as a position. `slide` is at most
/// one block, because both callers slide right after an emission (the
/// Writer's `compact`, the one-shot's per-block base), so it fits the
/// entries' `u32` positions.
pub fn rebaseTable(hash_table: []u32, slide: usize) void {
    assert(slide > 0);
    assert(slide <= max_block_size);
    const drop: u32 = @intCast(slide);
    for (hash_table) |*entry| {
        entry.* = if (entry.* >= drop) entry.* - drop else 0;
    }
}

/// One frame's encoding state, threaded through its blocks: the entropy
/// layers' cross-block tables, the repeat offsets, and the checksum.
pub const State = struct {
    /// The Huffman tree a Treeless_Literals_Block reuses (`§3.1.1.3.1`), one
    /// per frame.
    literals: literals_compress.State = .{},
    /// The three sequence tables a Repeat_Mode reuses (`§3.1.1.3.2.1`), one
    /// per frame.
    sequences: sequences_compress.State = .{},
    /// `§3.1.1.5` — the repeat offsets, seeded {1, 4, 8}.
    rep: [3]u32 = sequences.repeat_offsets_start,
    /// `§3.1.1` — the decoded bytes' XXH64, folded per block exactly as the
    /// decoder's `frame.State` folds it: Raw blocks inside their copy
    /// (`writeRaw`), Compressed and RLE blocks through `recordBlock`.
    checksum: xxh64.State = .{},
    /// `§3.1.1.2.1` — the frame's first block is never RLE (the zstd ≤
    /// 1.4.3 CLI compatibility rule).
    first_block: bool = true,

    /// Fold one Compressed or RLE block's decoded bytes — the block's source
    /// region — into the checksum. The decoder's `frame.State.recordBlock`
    /// is the same fold on the same bytes; a Raw block folds through its own
    /// copy instead (`writeRaw`), the decoder's `recordRawBlock` discipline.
    pub fn recordBlock(state: *State, block_source: []const u8) void {
        state.checksum.update(block_source);
    }
};

/// Write one block — its 3-byte Block_Header and Block_Content — for
/// `source[block_start..][0..block_size]` into `target`, folding the block's
/// source bytes into the frame checksum. Returns the bytes written, which
/// `last_block` marks as the frame's last.
///
/// The block is Raw, RLE, or Compressed by the ladder above. `target` must
/// hold whatever the block turns out to need; the raw form —
/// `block_size + block_header_len` — always fits when the caller's bound is
/// `encode.maxCompressedLength`. A smaller target can still work when the
/// block compresses, and fails `error.BufferTooSmall` before any write that
/// would pass its end.
///
/// `hash_table` is the finder's position table (`1 << params.hash_log`,
/// zeroed) and belongs to the frame: its entries are frame offsets, so the
/// caller keeps one table across the frame's blocks.
pub fn writeBlock(
    state: *State,
    scratch: *Scratch,
    params: match_compress.Params,
    hash_table: []u32,
    source: []const u8,
    block_start: usize,
    block_size: usize,
    target: []u8,
    last_block: bool,
) error{BufferTooSmall}!usize {
    assert(block_size > 0);
    assert(block_start + block_size <= source.len);
    assert(block_size <= max_block_size);
    assert(scratch.literals.len >= block_size);
    // Every sequence carries a match of at least `min_match_length` bytes,
    // so `block_size / min_match_length + 1` entries cover the block; the
    // one-shot's `max_sequences` is that bound at `max_block_size`.
    assert(scratch.sequences.len >= block_size / match_compress.min_match_length + 1);
    if (target.len < block.block_header_len) return error.BufferTooSmall;
    const written = try if (block_size < min_compressible_size)
        writeRaw(state, target, source[block_start..][0..block_size], last_block)
    else
        writeCompressible(
            state,
            scratch,
            params,
            hash_table,
            source,
            block_start,
            block_size,
            target,
            last_block,
        );
    state.first_block = false;
    return written;
}

/// The compressible block's path: scan the token stream, attempt the entropy
/// sections, and pick the block form the ladder keeps.
fn writeCompressible(
    state: *State,
    scratch: *Scratch,
    params: match_compress.Params,
    hash_table: []u32,
    source: []const u8,
    block_start: usize,
    block_size: usize,
    target: []u8,
    last_block: bool,
) error{BufferTooSmall}!usize {
    const block_source = source[block_start..][0..block_size];
    var store: match_compress.Store = .{
        .literals = scratch.literals,
        .sequences = scratch.sequences,
    };
    // The find and the entropy attempt both mutate the cross-block state; a
    // block that is not kept reverts it below. The reps must be captured
    // BEFORE the find: `find` updates them in place as it emits matches,
    // and RFC 8878 §3.1.1.5 skips non-Compressed blocks for offset history
    // — a Raw/RLE revert that restores the post-find values is a no-op and
    // leaves the history advanced (the C restores `dRepOriginal`, captured
    // before its find: zstd_compress.c:4155-4160).
    const literals_before = state.literals;
    const sequences_before = state.sequences;
    const rep_before = state.rep;
    match_compress.find(source, block_start, block_size, params, hash_table, &state.rep, &store);
    const compressed_size = writeEntropy(
        state,
        &store,
        block_size,
        target[block.block_header_len..],
    );
    // A block whose compressed form is under 25 bytes and whose bytes are
    // all one value is an RLE block — including when the entropy path
    // bailed to raw (`zstd_compress.c:4424-4433`).
    const keep_rle = !state.first_block and
        (compressed_size orelse 0) < rle_max_length and
        isRle(block_source);
    if (keep_rle or compressed_size == null) {
        state.literals = literals_before;
        state.sequences = sequences_before;
        state.rep = rep_before;
        if (keep_rle) return writeRle(state, target, block_source, last_block);
        return writeRaw(state, target, block_source, last_block);
    }
    const size = compressed_size.?;
    writeBlockHeader(target[0..block.block_header_len], last_block, .compressed, size);
    state.recordBlock(block_source);
    return block.block_header_len + size;
}

/// The entropy attempt (`ZSTD_entropyCompressSeqStore`): the literals
/// section, then the sequences section, kept only when the total beats the
/// minGain margin (`zstd_compress.c:3033`). Null when the block should be
/// stored instead — either writer bailing out (the C's `cSize == 0`), or
/// the margin.
fn writeEntropy(
    state: *State,
    store: *const match_compress.Store,
    block_size: usize,
    target: []u8,
) ?usize {
    const literals_len = literals_compress.write(
        store.literals[0..store.literals_len],
        target,
        &state.literals,
    ) catch return null;
    const sequences_len = sequences_compress.write(
        target[literals_len..],
        store.sequences[0..store.sequence_count],
        &state.sequences,
    ) catch return null;
    const compressed_size = literals_len + sequences_len;
    if (compressed_size >= block_size - minGain(block_size)) return null;
    return compressed_size;
}

/// `ZSTD_minGain` (`zstd_compress_internal.h:677-683`) at the fast levels:
/// `(srcSize >> 6) + 2`. The margin is also the safety that keeps a
/// Compressed block's size under a single-segment frame's Block_Maximum_Size.
fn minGain(source_len: usize) usize {
    return (source_len >> 6) + 2;
}

/// `ZSTD_noCompressBlock` (`zstd_compress.c:4778-4790`): the 3-byte header
/// and the bytes verbatim. The checksum fold rides the copy, chunk by chunk,
/// the decoder's Raw-block discipline (`block.decodeRaw`).
fn writeRaw(
    state: *State,
    target: []u8,
    block_source: []const u8,
    last_block: bool,
) error{BufferTooSmall}!usize {
    if (target.len < block.block_header_len + block_source.len) return error.BufferTooSmall;
    writeBlockHeader(target[0..block.block_header_len], last_block, .raw, block_source.len);
    const out = target[block.block_header_len..][0..block_source.len];
    var done: usize = 0;
    while (done < block_source.len) {
        const chunk = @min(block_source.len - done, raw_fold_chunk);
        fastmem.copy(u8, out[done..][0..chunk], block_source[done..][0..chunk]);
        state.checksum.update(block_source[done..][0..chunk]);
        done += chunk;
    }
    return block.block_header_len + block_source.len;
}

/// `ZSTD_rleCompressBlock` (`zstd_compress_internal.h:660-670`): a header
/// whose Block_Size is the repeat count, and the one content byte. The
/// checksum folds through `recordBlock` (the decoder's RLE path).
fn writeRle(
    state: *State,
    target: []u8,
    block_source: []const u8,
    last_block: bool,
) error{BufferTooSmall}!usize {
    assert(block_source.len > 0);
    if (target.len < block.block_header_len + 1) return error.BufferTooSmall;
    writeBlockHeader(target[0..block.block_header_len], last_block, .rle, block_source.len);
    target[block.block_header_len] = block_source[0];
    state.recordBlock(block_source);
    return block.block_header_len + 1;
}

/// `§3.1.1.2` — the 3-byte Block_Header: Last_Block in bit 0, Block_Type in
/// bits 1-2, Block_Size in bits 3-23, little-endian. `target` must be
/// exactly `block.block_header_len` bytes.
pub fn writeBlockHeader(
    target: []u8,
    last_block: bool,
    block_type: block.BlockType,
    block_size: usize,
) void {
    assert(target.len == block.block_header_len);
    assert(block_size <= 0x1fffff);
    const header: u24 = @intFromBool(last_block) +
        (@as(u24, @intFromEnum(block_type)) << 1) +
        (@as(u24, @intCast(block_size)) << 3);
    common.writeInt(u24, target[0..block.block_header_len], header);
}

/// `ZSTD_isRLE` (`zstd_compress.c:3572-3589`): whether every byte of the
/// block is the same value.
fn isRle(block_source: []const u8) bool {
    assert(block_source.len > 0);
    const value: u64 = @as(u64, block_source[0]) * 0x0101_0101_0101_0101;
    var index: usize = 0;
    while (index + 8 <= block_source.len) : (index += 8) {
        if (common.readInt(u64, block_source[index..][0..8]) != value) return false;
    }
    while (index < block_source.len) : (index += 1) {
        if (block_source[index] != block_source[0]) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc8878-zstd.txt §3.1.1.2 (the block
// header and the three types), §3.1.1.2.3 (RLE), §3.1.1.2.4 (Block_Size and
// the minGain margin), §3.1.1 (the checksum). Every block the layer emits is
// decoded back through the landed decoder (`block.decode`) and its bytes
// past the write checked.
// ---------------------------------------------------------------------------

/// Fill `buf` with repetitions of `phrase`.
fn fill(buf: []u8, phrase: []const u8) void {
    var index: usize = 0;
    while (index < buf.len) {
        const length = @min(phrase.len, buf.len - index);
        fastmem.copy(u8, buf[index..][0..length], phrase[0..length]);
        index += length;
    }
}

/// The block-layer test rig: a frame state, the scratch, and the table.
const Rig = struct {
    state: State = .{},
    literals: [max_block_size]u8 = undefined,
    sequence_buffer: [max_sequences]sequences_compress.Sequence = undefined,
    hash_table: [hash_table_max]u32 = @splat(0),
    params: match_compress.Params,

    fn scratch(rig: *Rig) Scratch {
        return .{ .literals = &rig.literals, .sequences = &rig.sequence_buffer };
    }

    /// The finder's table slice, `1 << hash_log` entries as `find` requires.
    fn table(rig: *Rig) []u32 {
        return rig.hash_table[0 .. @as(usize, 1) << @intCast(rig.params.hash_log)];
    }
};

/// Emit the frame's first block from `source` and decode it back through
/// `block.decode`, checking the output against the source and the bytes past
/// it. The block layer's own round trip, one layer below the one-shot.
fn expectBlockRoundTrip(rig: *Rig, source: []const u8, block_size: usize) !void {
    var target: [max_block_size + 64]u8 = undefined;
    internal.sentinel.fill(&target);
    var scratch = rig.scratch();
    const written = try writeBlock(
        &rig.state,
        &scratch,
        rig.params,
        rig.table(),
        source,
        0,
        block_size,
        &target,
        true,
    );
    try testing.expect(written <= target.len);
    var decoded: [max_block_size]u8 = undefined;
    internal.sentinel.fill(&decoded);
    var literals_state: literals.State = .{};
    var sequences_state: sequences.State = .{};
    const section = try block.decode(
        target[0..written],
        &decoded,
        0,
        @as(u64, 1) << rig.params.window_log,
        &literals_state,
        &sequences_state,
        null,
    );
    try testing.expect(section.last_block);
    try testing.expectEqual(written, section.bytes_consumed);
    try testing.expectEqual(block_size, section.bytes_written);
    try testing.expectEqualSlices(u8, source[0..block_size], decoded[0..section.bytes_written]);
    try internal.sentinel.expect(&decoded, section.bytes_written);
}

test "the reps do not advance across a raw or rle block" {
    // RFC 8878 §3.1.1.5 — blocks that are not Compressed_Blocks are
    // skipped; they do not contribute to offset history. The find mutates
    // the reps in place as it emits matches, so a Raw or RLE revert must
    // restore the values captured BEFORE the find (the C's dRepOriginal,
    // zstd_compress.c:4155-4160); a capture after the find restores the
    // advanced values and the revert is a no-op. Found by the encode-side
    // fuzz wave: the next block's repcodes decoded to the wrong distances.
    var rig: Rig = .{ .params = .{ .window_log = 10, .hash_log = 11, .mls = 6 } };
    var scratch = rig.scratch();
    var target: [max_block_size + 64]u8 = undefined;

    // Block one, compressible: the find advances the reps past their
    // start values.
    const phrase = "advance the reps, then bail to raw. ";
    var block_one: [128]u8 = undefined;
    for (&block_one, 0..) |*byte, index| byte.* = phrase[index % phrase.len];
    _ = try writeBlock(
        &rig.state,
        &scratch,
        rig.params,
        rig.table(),
        &block_one,
        0,
        block_one.len,
        &target,
        false,
    );
    const reps_after_block_one = rig.state.rep;

    // Block two: noise with one planted 6-byte match. The match makes the
    // find emit (and advance the reps), but one match in 256 bytes of noise
    // saves under the minGain margin (256>>6 + 2 = 6), so the entropy
    // attempt bails to Raw.
    var noise: [256]u8 = undefined;
    var rng: std.Random.DefaultPrng = .init(0xBADC0DE);
    rng.random().bytes(&noise);
    fastmem.copy(u8, noise[10..16], "abcdef");
    fastmem.copy(u8, noise[110..116], "abcdef");
    var second: [max_block_size + 64]u8 = undefined;
    internal.sentinel.fill(&second);
    var scratch_two = rig.scratch();
    const written = try writeBlock(
        &rig.state,
        &scratch_two,
        rig.params,
        rig.table(),
        &noise,
        0,
        noise.len,
        &second,
        true,
    );
    // A Raw block: the header's type bits are 0 (last_block alone), and
    // the bytes are the source verbatim.
    try testing.expectEqual(@as(u8, 1), second[0] & 0b111);
    try testing.expectEqual(noise.len, written - block.block_header_len);

    // The revert: the reps are block one's exit values, not advanced by
    // the match the abandoned attempt emitted. With the capture after the
    // find, the planted match leaves its offset in the history here.
    try testing.expectEqual(reps_after_block_one, rig.state.rep);
}

test "the ladder stores tiny and incompressible blocks raw" {
    // RFC 8878 §3.1.1.2.2 — a Raw_Block holds the bytes verbatim. The C
    // refuses to attempt compression below 7 bytes (`zstd_compress.c:3267`)
    // and keeps the compressed form only past the minGain margin.
    var rig: Rig = .{ .params = .{ .window_log = 10, .hash_log = 11, .mls = 6 } };
    var tiny: [6]u8 = undefined;
    for (&tiny, 0..) |*byte, index| byte.* = @intCast(index);
    try expectBlockRoundTrip(&rig, &tiny, tiny.len);
    // The block header's type is Raw.
    var target: [64]u8 = undefined;
    var scratch = rig.scratch();
    const written = try writeBlock(
        &rig.state,
        &scratch,
        rig.params,
        rig.table(),
        &tiny,
        0,
        tiny.len,
        &target,
        true,
    );
    try testing.expectEqual(block.BlockType.raw, (try block.parseHeader(&target)).block_type);
    try testing.expectEqual(@as(usize, 3 + 6), written);
}

test "the ladder picks RLE after the first block and Raw for noise" {
    // RFC 8878 §3.1.1.2.3 — "Block_Content ... consists of a single byte,
    // repeated Block_Size times". The first block of a frame is never RLE
    // (the compatibility rule above); a later all-one-value block is, and an
    // incompressible one is
    // Raw.
    var rig: Rig = .{ .params = .{ .window_log = 13, .hash_log = 13, .mls = 6 } };
    var source: [6 * 1024]u8 = undefined;
    // Block 0: text, so the first block is Compressed and its table entries
    // cannot match the run that follows.
    fill(source[0..512], "the quick brown fox jumps over the lazy dog. ");
    // Block 1: a one-byte run.
    fastmem.set(u8, source[512..1024], 0x41);
    // Block 2: noise.
    var rng: std.Random.DefaultPrng = .init(0xBEEF);
    for (source[1024..5120]) |*byte| byte.* = rng.random().int(u8);
    var scratch = rig.scratch();
    var target: [max_block_size + 64]u8 = undefined;
    const first_written = try writeBlock(
        &rig.state,
        &scratch,
        rig.params,
        rig.table(),
        &source,
        0,
        512,
        &target,
        false,
    );
    const first_header = try block.parseHeader(&target);
    try testing.expectEqual(block.BlockType.compressed, first_header.block_type);
    try testing.expect(first_written < 512);
    // The run: RLE, and the header's Block_Size is the repeat count.
    var second: [max_block_size + 64]u8 = undefined;
    const written = try writeBlock(
        &rig.state,
        &scratch,
        rig.params,
        rig.table(),
        &source,
        512,
        512,
        &second,
        false,
    );
    const header = try block.parseHeader(&second);
    try testing.expectEqual(block.BlockType.rle, header.block_type);
    try testing.expectEqual(@as(usize, 512), header.block_size);
    try testing.expectEqual(@as(usize, 4), written);
    try testing.expectEqual(@as(u8, 0x41), second[3]);
    // Noise: a Raw block whose size is the block's.
    var noise_target: [max_block_size + 64]u8 = undefined;
    const noise_written = try writeBlock(
        &rig.state,
        &scratch,
        rig.params,
        rig.table(),
        &source,
        1024,
        4096,
        &noise_target,
        false,
    );
    try testing.expectEqual(block.BlockType.raw, (try block.parseHeader(&noise_target)).block_type);
    try testing.expectEqual(@as(usize, 3 + 4096), noise_written);
}

test "a compressible block is Compressed and decodes back" {
    // RFC 8878 §3.1.1.3 — the Compressed_Block path: literals then
    // sequences, the block header's size the compressed length.
    var rig: Rig = .{ .params = .{ .window_log = 15, .hash_log = 13, .mls = 6 } };
    var source: [16 * 1024]u8 = undefined;
    const phrase = "the quick brown fox jumps over the lazy dog. ";
    var index: usize = 0;
    while (index < source.len) {
        const chunk = @min(phrase.len, source.len - index);
        fastmem.copy(u8, source[index..][0..chunk], phrase[0..chunk]);
        index += chunk;
    }
    try expectBlockRoundTrip(&rig, &source, source.len);
    // The same block again with a fresh table: the finder's table is
    // per-frame state, and a second scan of the same region is not a shape
    // the one-shot produces.
    var fresh: Rig = .{ .params = rig.params };
    var target: [max_block_size + 64]u8 = undefined;
    var scratch = fresh.scratch();
    const written = try writeBlock(
        &fresh.state,
        &scratch,
        fresh.params,
        fresh.table(),
        &source,
        0,
        source.len,
        &target,
        true,
    );
    const header = try block.parseHeader(&target);
    try testing.expectEqual(block.BlockType.compressed, header.block_type);
    try testing.expect(written < source.len);
}

test "an all-literals block carries the nbSeq == 0 section" {
    // RFC 8878 §3.1.1.3.2.1 — "there are no sequences. The sequence section
    // stops here" (the one-byte section), for a block the finder cannot
    // match: a skew the finder's 4-byte hash misses but the literals'
    // Huffman coding wins on.
    var rig: Rig = .{ .params = .{ .window_log = 15, .hash_log = 13, .mls = 6 } };
    var source: [4096]u8 = undefined;
    var rng: std.Random.DefaultPrng = .init(0x5CEBE1);
    for (&source) |*byte| {
        const x: u16 = rng.random().int(u8);
        byte.* = @truncate(x * x >> 10);
    }
    try expectBlockRoundTrip(&rig, &source, source.len);
}

test "the checksum funnel folds every block exactly once" {
    // RFC 8878 §3.1.1 — the Content_Checksum is the XXH64 of the decoded
    // bytes, in order. The block layer's fold must agree with the one-shot
    // fold of the whole source, whatever mix of Raw, RLE, and Compressed
    // blocks it emits.
    var rig: Rig = .{ .params = .{ .window_log = 15, .hash_log = 13, .mls = 6 } };
    var source: [24 * 1024]u8 = undefined;
    for (source[0..8192], 0..) |*byte, index| byte.* = @truncate((index * 7) % 41);
    fastmem.set(u8, source[8192..16384], 0x5a);
    var rng: std.Random.DefaultPrng = .init(0x1234);
    for (source[16384..]) |*byte| byte.* = rng.random().int(u8);
    var target: [max_block_size + 64]u8 = undefined;
    var scratch = rig.scratch();
    var offset: usize = 0;
    while (offset < source.len) {
        const size = @min(@as(usize, 8192), source.len - offset);
        _ = try writeBlock(
            &rig.state,
            &scratch,
            rig.params,
            rig.table(),
            &source,
            offset,
            size,
            &target,
            offset + size == source.len,
        );
        offset += size;
    }
    var expected: xxh64.State = .{};
    expected.update(&source);
    try testing.expectEqual(expected.final(), rig.state.checksum.final());
}
