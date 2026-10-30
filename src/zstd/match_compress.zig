//! The zstd encoder's fast match finder — the C's `ZSTD_fast`
//! (`zstd_fast.c:192-423`), greedy, with the repcode pre-check and the
//! offset-2 immediate-repeat chain. It scans one block and emits its token
//! stream: the literals buffer (every sequence's literals plus the trailing
//! literals after the last match) and the sequence list. The block layer's
//! two consumers (`literals_compress`, `sequences_compress`) then count their
//! own histograms from that stream.
//!
//! The finder is a single-slot position table: one `u32` per hash, last
//! writer wins, and a candidate is verified with a 4-byte compare
//! (`ZSTD_match4Found`), so every emitted match is at least 4 bytes. The rep
//! pre-check at +2 (`zstd_fast.c:267-290`) lets a match against
//! Repeated_Offset1 two bytes ahead of the scan beat the table candidate; its
//! backward extension stops one short of the anchor, so the hot path never
//! emits a zero-literals repcode and never meets `§3.1.1.5`'s shift. After a
//! match the offset-2 chain drains back-to-back zero-literal repcode
//! sequences, swapping rep1/rep2 each time — the encoder's mirror of the
//! decoder's repeat-offset machine. The scan step starts at 2 and grows by
//! one byte every 128 unmatched bytes (`kStepIncr`), so incompressible data
//! is skipped progressively faster.
//!
//! Positions are offsets into the caller's `source` slice, and the caller
//! owns the table (it must be zeroed and sized `1 << hashLog`) and the reps;
//! a caller that moves its slice start rebases the table's entries by the
//! same amount (`block_compress.rebaseTable`) so they stay slice-relative. A
//! rep outside the block's addressable prefix is zeroed for the block and
//! restored after, so the emitted history stays decodable (`§3.1.1.4`).
//!
//! Format: docs/specs/rfc8878-zstd.txt §3.1.1.4 (offsets), §3.1.1.5
//! (the repeat offsets).
//! Lineage: facebook/zstd v1.5.7 `zstd_fast.c`
//! (`ZSTD_compressBlock_fast_noDict_generic`); attribution in THIRD_PARTY.md.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;
const builtin = @import("builtin");

const fastmem = @import("fastmem");

const common = @import("common.zig");
const readInt = common.readInt;
const sequences = @import("sequences.zig");
const sequences_compress = @import("sequences_compress.zig");
/// `§3.1.1.3.2.1.1` — the shortest match a sequence can carry (Table 17's
/// code 0 baseline). The finder's 4-byte verification keeps every match at
/// or above this.
pub const min_match_length: u32 = sequences_compress.min_match_length;

/// `ZSTD_hash4`'s prime (`zstd_compress_internal.h:902`).
const prime4bytes: u32 = 2654435761;
/// `ZSTD_hash5`'s prime (`zstd_compress_internal.h:933`).
const prime5bytes: u64 = 889523592379;
/// `ZSTD_hash6`'s prime (`zstd_compress_internal.h:936`).
const prime6bytes: u64 = 227718039650203;
/// `ZSTD_hash7`'s prime (`zstd_compress_internal.h:939`).
const prime7bytes: u64 = 58295818150454627;
/// `ZSTD_hash8`'s prime (`zstd_compress_internal.h:942`): the dfast long
/// table's hash width, 8 bytes at every level of the class.
const prime8bytes: u64 = 0xCF1BBCDCB7A56463;

/// `HASH_READ_SIZE` (`zstd_compress_internal.h:33`): the bytes a hash reads
/// and the scan loop's trailing margin.
pub const hash_read_size: usize = 8;

/// `kSearchStrength` (`zstd_compress_internal.h:32`): the scan accelerates by
/// one byte every `1 << (kSearchStrength - 1)` unmatched bytes.
const search_strength = 8;
const step_incr: usize = 1 << (search_strength - 1);

/// The scan's first step: `targetLength + !targetLength + 1` at the fast
/// levels' `targetLength` 0 (`zstd_fast.c:200`).
const step_size: usize = 2;

/// `REPCODE1_TO_OFFBASE` (`zstd_compress_internal.h:718`): the wire value of
/// the first repeat code, the only repcode this finder emits.
const repcode1_off_base: u32 = 1;

/// The finder's parameters, from the block layer's size ladder.
pub const Params = struct {
    /// The compression level that selected the scan: 1 is the `ZSTD_fast`
    /// class, 3 the `ZSTD_dfast` one. The block layer dispatches on it;
    /// levels 2 and 4-19 never reach a frame (the option gates them).
    level: u8,
    /// The frame's Window_Log (`§3.1.1.1.2`): the finder's reach.
    window_log: u6,
    /// The long table's width: `min(hashLog, windowLog + 1)`
    /// (`zstd_compress.c:1564`).
    hash_log: u6,
    /// The dfast small table's width: `chainLog`, clamped to the window the
    /// same way (`cycleLog > windowLog ⇒ chainLog -= cycleLog - windowLog`,
    /// `zstd_compress.c:1563-1567`). The fast finder has one table and never
    /// reads it.
    chain_log: u6,
    /// The hash width in bytes — 4 to 7 by the size class (the C's
    /// `minMatch`, `clevels.h`).
    mls: u3,

    /// Level 1's fast-finder parameters: one table and no chain.
    pub fn init(window_log: u6, hash_log: u6, mls: u3) Params {
        return .{
            .level = 1,
            .window_log = window_log,
            .hash_log = hash_log,
            .chain_log = 0,
            .mls = mls,
        };
    }

    /// The C's level ladder for a one-shot with a known source size: the
    /// size class picks (windowLog, chainLog, hashLog, minMatch) from
    /// `clevels.h`'s row for the level, then `ZSTD_adjustCParams_internal`
    /// (`zstd_compress.c:1473-1586`) shrinks the window to the next power of
    /// two covering the source, clamps the hash to that window plus one and
    /// the chain to the window, and floors the window at 10.
    pub fn forSource(level: u8, source_len: usize) Params {
        const row = classRow(level, source_len);
        // The adjust step's order (`ZSTD_adjustCParams_internal`,
        // `zstd_compress.c:1548-1580`): the window first shrinks to the
        // source's own log, the hash and chain are clamped to that window,
        // and only then is the window floored to 10
        // (`ZSTD_WINDOWLOG_ABSOLUTEMIN`) for the frame header. Clamping after
        // the floor would leave the tables wider than the C's for sources of
        // at most 512 bytes, where the floor is what moves the window.
        const source_log = nextPow2Log(source_len);
        const shrunk_window_log = @min(row.window_log, source_log);
        return .{
            .level = level,
            .window_log = @max(shrunk_window_log, 10),
            .hash_log = @min(row.hash_log, shrunk_window_log + 1),
            .chain_log = @min(row.chain_log, shrunk_window_log),
            .mls = row.mls,
        };
    }
};

/// One level's row of `clevels.h`'s four size-class tables: the columns the
/// finder reads (W, C, H, L — window, chain, hash, minMatch).
const Row = struct {
    window_log: u6,
    chain_log: u6,
    hash_log: u6,
    mls: u3,
};

/// `ZSTD_defaultCParameters[tableID][level]` (`clevels.h`): the row for a
/// size class. The class is `(rSize <= 256 KB) + (rSize <= 128 KB) +
/// (rSize <= 16 KB)` (`ZSTD_getCParams_internal`, `zstd_compress.c:7759`).
/// Only levels 1 (`ZSTD_fast`) and 3 (`ZSTD_dfast`) have a scan here; the
/// option gate rejects every other level before a frame starts.
fn classRow(level: u8, size: usize) Row {
    const big = size > 256 * 1024;
    const medium = size > 128 * 1024;
    const small = size > 16 * 1024;
    return switch (level) {
        1 => if (big)
            .{ .window_log = 19, .chain_log = 13, .hash_log = 14, .mls = 7 }
        else if (medium)
            .{ .window_log = 18, .chain_log = 13, .hash_log = 14, .mls = 6 }
        else if (small)
            .{ .window_log = 17, .chain_log = 12, .hash_log = 13, .mls = 6 }
        else
            .{ .window_log = 14, .chain_log = 14, .hash_log = 15, .mls = 5 },
        3 => if (big)
            .{ .window_log = 21, .chain_log = 16, .hash_log = 17, .mls = 5 }
        else if (medium)
            .{ .window_log = 18, .chain_log = 16, .hash_log = 16, .mls = 4 }
        else if (small)
            .{ .window_log = 17, .chain_log = 15, .hash_log = 16, .mls = 5 }
        else
            .{ .window_log = 14, .chain_log = 14, .hash_log = 15, .mls = 4 },
        else => unreachable,
    };
}

/// `ZSTD_highbit32(srcSize - 1) + 1` (`zstd_compress.c:1557-1558`): the
/// smallest power-of-two window log that covers `source_len`, floor 6 (the
/// C's `ZSTD_HASHLOG_MIN`).
pub fn nextPow2Log(source_len: usize) u6 {
    const usize_len = @bitSizeOf(usize);
    return switch (source_len) {
        0, 1 => 6,
        else => @max(@as(u6, @intCast(usize_len - @clz(source_len - 1))), 6),
    };
}

/// One block's token stream: the literals in order and the sequences. The
/// block layer sizes both for the block's worst case and hands them to the
/// literals and sequences writers.
pub const Store = struct {
    /// The block's literals: every sequence's `literals_length` bytes, then
    /// the trailing literals after the last match (`§3.1.1.3.1`).
    literals: []u8,
    /// The block's sequences, in order.
    sequences: []sequences_compress.Sequence,
    literals_len: usize,
    sequence_count: usize,

    /// An empty token stream over the block's `literals` and `sequences`
    /// storage.
    pub fn init(literals: []u8, sequence_list: []sequences_compress.Sequence) Store {
        return .{
            .literals = literals,
            .sequences = sequence_list,
            .literals_len = 0,
            .sequence_count = 0,
        };
    }

    /// Append one sequence: its `literals_length` literals from
    /// `source[anchor..position]`, then the match.
    pub fn append(
        store: *Store,
        source: []const u8,
        anchor: usize,
        position: usize,
        offset_value: u32,
        match_length: u32,
    ) void {
        const literals_length = position - anchor;
        assert(match_length >= min_match_length);
        assert(literals_length <= 0xffff_ffff);
        assert(store.literals_len + literals_length <= store.literals.len);
        assert(store.sequence_count < store.sequences.len);
        fastmem.copy(
            u8,
            store.literals[store.literals_len..][0..literals_length],
            source[anchor..][0..literals_length],
        );
        store.literals_len += literals_length;
        store.sequences[store.sequence_count] = .{
            .literals_length = @intCast(literals_length),
            .match_length = match_length,
            .offset_value = offset_value,
        };
        store.sequence_count += 1;
    }

    /// Append the block's trailing literals (`ZSTD_storeLastLiterals`,
    /// `zstd_compress.c:3423-3424`): the bytes after the last match, which
    /// close the block's literal run.
    pub fn appendTrailing(store: *Store, source: []const u8, anchor: usize, iend: usize) void {
        const literals_length = iend - anchor;
        assert(store.literals_len + literals_length <= store.literals.len);
        fastmem.copy(
            u8,
            store.literals[store.literals_len..][0..literals_length],
            source[anchor..][0..literals_length],
        );
        store.literals_len += literals_length;
    }
};

/// Scan `source[block_start..][0..block_size]` and fill `store` with the
/// block's token stream. `hash_table` holds one position per hash and must be
/// zeroed; `rep` is the frame's repeat-offset history (`§3.1.1.5`, seeded
/// `{1, 4, 8}`), updated in place with the block's final rep1/rep2.
///
/// `source` holds the block's bytes and the history they may address, so a
/// match may read any byte before the block — but never before
/// `iend - (1 << window_log)`, where `iend` is the block's end: the finder's
/// candidates and reps are bounded by that prefix, so an emitted offset is
/// always below the declared Window_Size (`§3.1.1.4`).
pub fn find(
    source: []const u8,
    block_start: usize,
    block_size: usize,
    params: Params,
    hash_table: []u32,
    rep: *[3]u32,
    store: *Store,
) void {
    assert(block_size > 0);
    assert(block_start + block_size <= source.len);
    assert(hash_table.len == @as(usize, 1) << @intCast(params.hash_log));
    const iend = block_start + block_size;
    const window_size: usize = @as(usize, 1) << @intCast(params.window_log);
    // The block's prefix: the oldest byte an offset from this block may
    // address. The C derives it from the block's END
    // (`ZSTD_getLowestPrefixIndex(ms, endIndex, windowLog)`, `zstd_fast.c:204`),
    // not its start: a start-derived prefix lets a block whose end is past
    // the window emit offsets above the declared Window_Size (RFC 8878
    // §3.1.1.4), which strict decoders (klauspost) reject.
    const prefix_start: usize = if (iend > window_size) iend - window_size else 0;
    // A zeroed table slot means "no candidate": the C's window indices start
    // above zero, so entry 0 sits below every prefix, while this port's frame
    // offsets start at zero and would make it position 0. The candidate floor
    // is therefore at least 1 (`ZSTD_WINDOW_START_INDEX`'s effect,
    // `zstd_compress_internal.h:1334-1340`).
    const candidate_floor = @max(prefix_start, 1);
    var scan: Scan = .{
        .source = source,
        .iend = iend,
        .prefix_start = prefix_start,
        .candidate_floor = candidate_floor,
        .window_size = window_size,
        // The C skips the frame's very first position (`ip0 += (ip0 ==
        // prefixStart)`, `zstd_fast.c:252`): a match there has no history.
        .ip0 = if (block_start == prefix_start) block_start + 1 else block_start,
        .anchor = block_start,
        .ilimit = if (iend >= hash_read_size) iend - hash_read_size else 0,
        .params = params,
        .hash_table = hash_table,
        .store = store,
        .rep1 = rep[0],
        .rep2 = rep[1],
    };
    var offset_saved1: u32 = 0;
    var offset_saved2: u32 = 0;
    {
        // A rep that reaches before the prefix is invalid for this block and
        // is restored after it. The C measures the rep's reach from ip0's own
        // window floor, not the block's (`zstd_fast.c:238-243,355-372`).
        const window_low: usize = if (scan.ip0 > window_size) scan.ip0 - window_size else 0;
        const max_rep: u32 = @intCast(scan.ip0 - window_low);
        if (scan.rep2 > max_rep) {
            offset_saved2 = scan.rep2;
            scan.rep2 = 0;
        }
        if (scan.rep1 > max_rep) {
            offset_saved1 = scan.rep1;
            scan.rep1 = 0;
        }
    }
    // The scan is instantiated per hash width (the C's per-mls copies,
    // `zstd_fast.c:436-439`): the prime and the shift into the word's top
    // are comptime inside, constants in registers rather than per-probe
    // table loads.
    switch (params.mls) {
        5 => scan.scanBlock(5),
        6 => scan.scanBlock(6),
        7 => scan.scanBlock(7),
        else => unreachable,
    }
    // The restore rule (`zstd_fast.c:355-372`): the first valid rep wins its
    // slot, and an invalidated rep1 that became valid takes rep2's saved
    // value.
    offset_saved2 = if (offset_saved1 != 0 and scan.rep1 != 0) offset_saved1 else offset_saved2;
    rep[0] = if (scan.rep1 != 0) scan.rep1 else offset_saved1;
    rep[1] = if (scan.rep2 != 0) scan.rep2 else offset_saved2;
    store.appendTrailing(source, scan.anchor, iend);
}

// ---------------------------------------------------------------------------
// The dictionary's match region (`zstd_compress.c:4898-5038`, `zstd_fast.c`).
// A dictionary is virtual past: the emitted offsets count from the frame's
// start with the content behind it, so a match at content position `q` from
// source position `p` is `dict_len + p - q` (`§5`). The C keeps two shapes,
// and the CLI picks between them by the pledged source size: a source of at
// most 8 KiB attaches the dictionary as a *separate* match state
// (`ZSTD_compressBlock_fast_dictMatchState_generic`), anything larger copies
// the dictionary's table into the frame's own and runs the extDict scan
// (`ZSTD_compressBlock_fast_extDict_generic`); a streaming writer never
// knows its size, so it always attaches (`ZSTD_shouldAttachDict`,
// `zstd_compress.c:2309-2323`).
// ---------------------------------------------------------------------------

/// The largest match table a dictionary needs: the level-1 rows' largest
/// `hashLog` (15, the ≤ 16-KiB class).
pub const dict_table_entries_max = 1 << 15;

/// `ZSTD_SHORT_CACHE_TAG_BITS` (`zstd_compress_internal.h:1482`): the low 8
/// bits of a CDict table entry hold a hash tag, not part of the position.
pub const short_cache_tag_bits: u5 = 8;
const short_cache_tag_mask: u32 = (1 << short_cache_tag_bits) - 1;

/// The attach scan's step increment: the C's `1 << kSearchStrength` (`= 256`,
/// `zstd_fast.c:556`) — the attach generic grows its step twice as fast as
/// the pair-based scans, which use `1 << (kSearchStrength - 1)`.
const attach_step_incr: usize = 1 << search_strength;

/// The C's CDict match table (`ZSTD_fillHashTableForCDict`, `zstd_fast.c:13-50`):
/// one entry per hash of the dictionary's own width (`hashLog + 8` bits),
/// the low 8 a tag and the rest a content position (`ZSTD_writeTaggedIndex`,
/// `zstd_compress_internal.h:1485-1492`). The fill is `dtlm_full` — every
/// third position, plus positions 1 and 2 of each step when their slot is
/// still empty — the CLI's `-D` path (`zstd_compress.c:5591-5594`). The tag
/// lets a lookup reject a stale entry without touching the content.
pub const DictTable = struct {
    /// `(position << 8) | tag` per hash, zeroed before the fill.
    entries: [dict_table_entries_max]u32,
    /// The dictionary's own hash log: the table's index width, the tag's 8
    /// bits on top.
    hash_log: u5,
    /// The dictionary's own hash width in bytes (its class's `minMatch`),
    /// which may differ from the frame's.
    mls: u3,

    /// The table's live slice, `1 << hash_log` entries.
    pub fn slice(self: *DictTable) []u32 {
        return self.entries[0 .. @as(usize, 1) << @intCast(self.hash_log)];
    }

    /// The table's live slice, read-only.
    pub fn constSlice(self: *const DictTable) []const u32 {
        return self.entries[0 .. @as(usize, 1) << @intCast(self.hash_log)];
    }
};

/// The C's CDict parameters (`ZSTD_createCDict_advanced2`'s
/// `ZSTD_getCParamsFromCCtxParams(&cctxParams, ZSTD_CONTENTSIZE_UNKNOWN,
/// dictSize, ZSTD_cpm_createCDict)`): the level-1 row for the class
/// `dict_source_len + 499` — the C's `UNKNOWN + dictSize + 500` arithmetic
/// wraps to `dictSize + 499` — adjusted as if the source were the 513-byte
/// `minSrcSize`. `dict_source_len` is the whole dictionary file's length
/// (the C's `cdict->dictContentSize`), not just its content.
pub const DictParams = struct {
    window_log: u6,
    hash_log: u5,
    chain_log: u5,
    mls: u3,
};

/// The dictionary's own parameters, from its whole file length.
pub fn dictParams(level: u8, dict_source_len: usize) DictParams {
    const class = classRow(level, dict_source_len +% 499);
    const row: DictParams = .{
        .window_log = class.window_log,
        .hash_log = @intCast(class.hash_log),
        .chain_log = @intCast(class.chain_log),
        .mls = class.mls,
    };
    // `ZSTD_adjustCParams_internal` (`zstd_compress.c:1520-1586`): the
    // window shrinks to cover the 513-byte source and the dictionary, the
    // hash clamps to that window plus one, the chain log to the window.
    const source_len = 513;
    const total = source_len + dict_source_len;
    const src_log = @max(nextPow2Log(total), 6);
    const window_log = @min(row.window_log, src_log);
    const dict_and_window_log = dictAndWindowLog(window_log, source_len, dict_source_len);
    return .{
        .window_log = window_log,
        .hash_log = @intCast(@min(row.hash_log, dict_and_window_log + 1)),
        .chain_log = @intCast(@min(row.chain_log, dict_and_window_log)),
        .mls = row.mls,
    };
}

/// `ZSTD_dictAndWindowLog` (`zstd_compress.c:1435-1465`): the window log that
/// covers both the source and the dictionary.
fn dictAndWindowLog(window_log: u6, source_len: usize, dict_size: usize) u6 {
    if (dict_size == 0) return window_log;
    const window_size: u64 = @as(u64, 1) << @intCast(window_log);
    const dict_and_window_size = dict_size + window_size;
    if (window_size >= dict_size + source_len) return window_log;
    if (dict_and_window_size >= @as(u64, 1) << 31) return 31;
    const high: u6 = @intCast(@bitSizeOf(u64) - @clz(dict_and_window_size - 1));
    return @intCast(@min(@as(u7, high) + 1, 31));
}

/// The frame's parameters with the dictionary attached
/// (`ZSTD_resetCCtx_byAttachingCDict`, `zstd_compress.c:2343-2350`): the
/// source-size ladder for the window, and the frame's tables clamped to the
/// window the dictionary's own parameters shrink to
/// (`ZSTD_adjustCParams_internal` with the source size, before its floor) —
/// the dictionary's widths, in the C's own order.
pub fn forSourceAttached(level: u8, source_len: usize, dict: DictParams) Params {
    const plain = Params.forSource(level, source_len);
    const adjusted_window_log = @min(dict.window_log, nextPow2Log(source_len));
    return .{
        .level = level,
        .window_log = plain.window_log,
        .hash_log = @intCast(@min(dict.hash_log, adjusted_window_log + 1)),
        .chain_log = @intCast(@min(dict.chain_log, adjusted_window_log)),
        .mls = dict.mls,
    };
}

/// The frame's parameters with the dictionary copied
/// (`ZSTD_resetCCtx_byCopyingCDict`, `zstd_compress.c:2404-2416`): the
/// window from `srcSize + dictSize`'s class, the dictionary's own table
/// widths and `minMatch`.
pub fn forSourceCopied(
    level: u8,
    source_len: usize,
    dict_source_len: usize,
    dict: DictParams,
) Params {
    const total = source_len + dict_source_len;
    const row = classRow(level, total);
    const window_log = @max(@min(row.window_log, nextPow2Log(total)), 10);
    return .{
        .level = level,
        .window_log = window_log,
        .hash_log = dict.hash_log,
        .chain_log = dict.chain_log,
        .mls = dict.mls,
    };
}

/// `attachDictSizeCutoffs` (`zstd_compress.c:2296-2307`): the source size at
/// or below which a dictionary is attached as a separate match state rather
/// than copied into the frame's own tables. The CLI's `-D` path builds a
/// CDict from the level's parameters, so the cutoff follows the strategy:
/// 8 KB for `ZSTD_fast` (level 1), 16 KB for `ZSTD_dfast` (level 3).
pub fn attachCutoff(level: u8) usize {
    return switch (level) {
        1 => 8 * 1024,
        3 => 16 * 1024,
        else => unreachable,
    };
}

/// The C's streaming class for an unknown source size
/// (`ZSTD_getCParams(level, ZSTD_CONTENTSIZE_UNKNOWN, 0)`): the default
/// row's widths and `minMatch`, with the caller's window log in place of the
/// row's (the `Writer`'s class; a source size would shrink the window).
pub fn forStreaming(level: u8, window_log: u6) Params {
    const row = classRow(level, std.math.maxInt(usize));
    return .{
        .level = level,
        .window_log = window_log,
        .hash_log = @intCast(@min(row.hash_log, window_log + 1)),
        .chain_log = @intCast(@min(row.chain_log, window_log)),
        .mls = row.mls,
    };
}

/// `ZSTD_hashPtr` at a runtime width: the dictionary table's hash is the
/// dictionary's own `minMatch` and `hashLog + 8` bits, which need not match
/// the frame's (`zstd_fast.c:512,547`).
pub inline fn hashAtWidth(source: []const u8, position: usize, hash_bits: u5, mls: u4) usize {
    assert(position + hash_read_size <= source.len);
    const word = readInt(u64, source[position..][0..8]);
    const shift: u6 = @intCast(64 - @as(u7, hash_bits));
    return switch (mls) {
        4 => @intCast((read32(source, position) *% prime4bytes) >>
            @intCast(32 - @as(u7, hash_bits))),
        5 => @intCast(((word << 24) *% prime5bytes) >> shift),
        6 => @intCast(((word << 16) *% prime6bytes) >> shift),
        7 => @intCast(((word << 8) *% prime7bytes) >> shift),
        8 => @intCast((word *% prime8bytes) >> shift),
        else => unreachable,
    };
}

/// `ZSTD_writeTaggedIndex`: the position in the high bits, the hash's tag in
/// the low 8.
pub inline fn writeTaggedIndex(table: []u32, hash_and_tag: usize, position: usize) void {
    assert(position >> (@as(u6, 32) - short_cache_tag_bits) == 0);
    const slot = hash_and_tag >> short_cache_tag_bits;
    const tag: u32 = @intCast(hash_and_tag & short_cache_tag_mask);
    table[slot] = (@as(u32, @intCast(position)) << short_cache_tag_bits) | tag;
}

/// `ZSTD_comparePackedTags`: whether a table entry's tag is the hash's.
pub inline fn tagsMatch(entry: u32, hash_and_tag: usize) bool {
    const tag: u32 = @intCast(hash_and_tag & short_cache_tag_mask);
    return (entry & short_cache_tag_mask) == tag;
}

/// `ZSTD_index_overlap_check` (`zstd_compress_internal.h:1429-1431`): whether
/// the 4 bytes at `index` stay inside one region — false when they would
/// straddle the dictionary's end, where the C would read across two buffers.
pub inline fn indexOverlapCheck(prefix_lowest_index: usize, index: usize) bool {
    return (prefix_lowest_index -% 1) -% index >= 3;
}

/// `ZSTD_loadDictionaryContent`'s truncation (`zstd_compress.c:4944-4949`):
/// the table is filled from the last `1 << MIN(MAX(hashLog + 3, chainLog +
/// 1), 31)` content bytes only; the whole content stays addressable.
pub fn maxLoadedContent(params: DictParams) usize {
    const bits = @min(@max(@as(u6, params.hash_log) + 3, @as(u6, params.chain_log) + 1), 31);
    return @as(usize, 1) << @intCast(bits);
}

/// Fill the CDict match table over `content` (`ZSTD_fillHashTableForCDict`):
/// every third position of the loaded range, then positions 1 and 2 of each
/// step when their slot is still empty. Positions within the last 8 bytes are
/// not hashed: the hash reads 8.
pub fn fillDictTable(table: *DictTable, content: []const u8, params: DictParams) void {
    assert(params.hash_log <= 15);
    table.hash_log = params.hash_log;
    table.mls = params.mls;
    const entries = table.slice();
    fastmem.set(u32, entries, 0);
    if (content.len <= hash_read_size) return;
    const hash_bits: u5 = params.hash_log + short_cache_tag_bits;
    const loaded = maxLoadedContent(params);
    var position = if (content.len > loaded) content.len - loaded else 0;
    // `ip + 3 < (end - 8) + 2`: the last step start whose positions 1 and 2
    // still leave a full 8-byte hash read.
    while (position + 3 < content.len - 6) : (position += 3) {
        writeTaggedIndex(
            entries,
            hashAtWidth(content, position, hash_bits, params.mls),
            position,
        );
        for (1..3) |offset| {
            const extra = position + offset;
            const hash_and_tag = hashAtWidth(content, extra, hash_bits, params.mls);
            // "not yet filled": a zeroed slot, the C's own sentinel.
            if (entries[hash_and_tag >> short_cache_tag_bits] == 0) {
                writeTaggedIndex(entries, hash_and_tag, extra);
            }
        }
    }
}

/// The 4 bytes at virtual index `index`: the dictionary's content below
/// `dict_len`, the source at or above it. Callers guard the read with
/// `indexOverlapCheck` so it never straddles the boundary.
pub inline fn read32At(dict: []const u8, source: []const u8, index: usize) u32 {
    if (index < dict.len) {
        assert(index + 4 <= dict.len);
        return read32(dict, index);
    }
    assert(index - dict.len + 4 <= source.len);
    return read32(source, index - dict.len);
}

/// The 8 bytes at virtual index `index`: the dictionary's content below its
/// length, the source at or above it. The caller keeps the read inside one
/// region.
pub inline fn read64At(dict: []const u8, source: []const u8, index: usize) u64 {
    if (index < dict.len) {
        assert(index + 8 <= dict.len);
        return read64(dict, index);
    }
    assert(index - dict.len + 8 <= source.len);
    return read64(source, index - dict.len);
}

/// `ZSTD_count_2segments` (`zstd_compress_internal.h:1000-1013`): the common
/// bytes between the source at `ip_start` and a match that begins in the
/// dictionary at `dict_start`, up to `iend` — the dictionary's tail first,
/// then the source's own start once the match runs off the dictionary's end
/// (the layout the decoder's `copyMatchDict` mirrors).
pub fn countTwoSegments(
    source: []const u8,
    ip_start: usize,
    dict: []const u8,
    dict_start: usize,
    iend: usize,
    source_start: usize,
) usize {
    const dict_part = @min(dict.len - dict_start, iend - ip_start);
    const matched = countTwo(source, ip_start, dict, dict_start, dict_part);
    if (matched < dict_part) return matched;
    return matched + count(source, ip_start + matched, source_start, iend);
}

/// The dictionary's match region: the content (virtual past) and the CDict
/// table over it.
pub const DictRegion = struct {
    content: []const u8,
    table: *const DictTable,

    /// The table's candidate for the bytes at `source[position]`: the C's
    /// `dictTagsMatch`, the `dictMatchIndex > dictStartIndex` exclusion of
    /// content position 0, and the tag check. `null` when the slot is empty
    /// or its tag disagrees.
    ///
    /// `mls` is the *frame's* hash width, not the dictionary's: the C's
    /// lookup hashes with `cParams->minMatch` (`zstd_fast.c:547`) while the
    /// table was filled with the CDict's own (`:22`). The two agree for a
    /// source whose size class picks the dictionary's width (every one-shot
    /// fixture here); when they differ, the lookups hash into the wrong
    /// slots, which is the reference's own behavior and therefore the parity
    /// target.
    inline fn candidate(region: DictRegion, source: []const u8, position: usize, mls: u3) ?usize {
        const table = region.table;
        const hash_bits: u5 = table.hash_log + short_cache_tag_bits;
        const hash_and_tag = hashAtWidth(source, position, hash_bits, mls);
        const entry = table.constSlice()[hash_and_tag >> short_cache_tag_bits];
        if (!tagsMatch(entry, hash_and_tag)) return null;
        const index = entry >> short_cache_tag_bits;
        if (index == 0) return null;
        return index;
    }
};

/// The copy path's table (`ZSTD_copyCDictTableIntoCCtx`, `zstd_compress.c:2384-2397`):
/// the dictionary's entries with their tags stripped, so the frame's own scan
/// sees plain virtual positions.
pub fn copyDictTable(hash_table: []u32, table: *const DictTable) void {
    assert(hash_table.len == @as(usize, 1) << @intCast(table.hash_log));
    for (hash_table, table.constSlice()) |*entry, tagged| entry.* = tagged >> short_cache_tag_bits;
}

/// A found match: the sequence's bytes are `source[position..][0..length]`,
/// the offset value is the wire form (`§3.1.1.5`), and `position` already
/// carries any backward extension.
const DictFound = struct {
    position: usize,
    offset_value: u32,
    length: usize,
};

/// The byte at virtual index `index`: the dictionary's content below its
/// length, the source at or above it.
pub inline fn byteAt(dict: []const u8, source: []const u8, index: usize) u8 {
    return if (index < dict.len) dict[index] else source[index - dict.len];
}

/// An extDict candidate the scan accepted: where its bytes live and how far
/// its backward extension may reach.
const Candidate = struct {
    /// The virtual index of the match's start.
    position: usize,
    /// Whether the match begins in the dictionary.
    dict: bool,
    /// The lowest virtual index the backward extension may reach: the
    /// dictionary's candidate floor for a dictionary match (the C's
    /// `dictStart`), the prefix's start for a source one (`prefixStart`).
    floor: usize,
};

/// The extDict scan's candidate test (`zstd_fast.c:827-833`): a table entry
/// at or above the candidate floor whose 4 bytes equal the source's at `ip0`.
inline fn extCandidate(
    dict: []const u8,
    source: []const u8,
    index: usize,
    ip0: usize,
    prefix_start_index: usize,
    dict_start_index: usize,
) ?Candidate {
    if (index < dict_start_index) return null;
    if (index < dict.len) {
        // A dictionary position: the table's fill only inserts positions
        // with a full 8-byte read.
        assert(index + hash_read_size <= dict.len);
        if (read32(dict, index) != read32(source, ip0)) return null;
        return .{ .position = index, .dict = true, .floor = dict_start_index };
    }
    const position = index - dict.len;
    if (position + 4 > source.len) return null;
    if (read32(source, position) != read32(source, ip0)) return null;
    return .{ .position = position, .dict = false, .floor = prefix_start_index - dict.len };
}

/// The forward length of a match whose bytes begin in the dictionary at
/// `dict_match` (the C's `ZSTD_count_2segments` call sites,
/// `zstd_fast.c:836,921,965`). A dictionary match that runs off the
/// content's end continues at the frame's own start — the decoder's
/// `copyMatchDict` wrap — so the continuation counts against `source[0]`,
/// never against a source position a dictionary index would alias.
fn countFromDict(
    source: []const u8,
    dict: []const u8,
    ip_start: usize,
    dict_match: usize,
    iend: usize,
) usize {
    if (dict_match >= dict.len) return count(source, ip_start, 0, iend);
    return countTwoSegments(source, ip_start, dict, dict_match, iend, 0);
}

/// The 4 bytes at a virtual index, where `dict_len + frame_start + p` names
/// `source[p]`: the dictionary's content below its length, the frame's output
/// above it. The callers guard the read with `indexOverlapCheck` so it never
/// straddles the dictionary's end.
pub inline fn read32Virtual(
    dict: []const u8,
    source: []const u8,
    index: usize,
    frame_start: usize,
) u32 {
    if (index < dict.len) {
        assert(index + 4 <= dict.len);
        return read32(dict, index);
    }
    const position = index - dict.len - frame_start;
    assert(position + 4 <= source.len);
    return read32(source, position);
}

/// `ZSTD_compressBlock_fast_dictMatchState_generic` (`zstd_fast.c:483-700`):
/// the attach path — the dictionary as a separate match state, its CDict
/// table consulted per position through its tag, and a dictionary candidate
/// taken only where the frame's own table has none. The frame's own table
/// holds *source* positions with 0 as "no candidate" (the C's virtual
/// convention, whose zeroed slot also sits below every candidate; position 0
/// is never taken, the landed noDict port's rule). The repcode pre-check
/// probes `ip0 + 1` (`:566`), and the scan's step starts at 1.
///
/// `frame_start` is the frame position of `source[0]`: 0 for the one-shot,
/// the writer's retained-history origin otherwise. A frame's dictionary is
/// only addressable while its output stays within Window_Size (`§5`), and a
/// writer that reaches that far has not slid its window yet, so the attach
/// scan always sees `frame_start == 0` in this package; the parameter keeps
/// the rep arithmetic honest rather than implied.
pub fn findDict(
    source: []const u8,
    block_start: usize,
    block_size: usize,
    params: Params,
    hash_table: []u32,
    dict: DictRegion,
    frame_start: usize,
    rep: *[3]u32,
    store: *Store,
) void {
    // The scan is instantiated per hash width, as the C's per-mls copies are.
    const args: DictScanArgs = .{
        .source = source,
        .block_start = block_start,
        .block_size = block_size,
        .params = params,
        .hash_table = hash_table,
        .dict = dict,
        .frame_start = frame_start,
        .rep = rep,
        .store = store,
    };
    switch (params.mls) {
        5 => scanDict(5, args),
        6 => scanDict(6, args),
        7 => scanDict(7, args),
        else => unreachable,
    }
}

/// The attach scan's arguments, grouped so the per-width dispatch stays one
/// line per instantiation (the C's `ZSTD_GEN_FAST_FN` shape).
const DictScanArgs = struct {
    source: []const u8,
    block_start: usize,
    block_size: usize,
    params: Params,
    hash_table: []u32,
    dict: DictRegion,
    frame_start: usize,
    rep: *[3]u32,
    store: *Store,
};

/// `findDict`'s scan, specialized on the frame's hash width.
fn scanDict(comptime mls: u3, args: DictScanArgs) void {
    const source = args.source;
    const block_start = args.block_start;
    const block_size = args.block_size;
    const params = args.params;
    const hash_table = args.hash_table;
    const dict = args.dict;
    const frame_start = args.frame_start;
    const rep = args.rep;
    const store = args.store;
    assert(block_size > 0);
    assert(block_start + block_size <= source.len);
    assert(hash_table.len == @as(usize, 1) << @intCast(params.hash_log));
    const dict_len = dict.content.len;
    assert(dict_len > 0);
    const iend = block_start + block_size;
    const ilimit = if (iend >= hash_read_size) iend - hash_read_size else 0;
    // The virtual index of `source[p]`: the C's `base`-relative index, with
    // the dictionary below it.
    const virtual_offset = dict_len + frame_start;
    var ip0 = block_start;
    var anchor = block_start;
    var rep1 = rep[0];
    var rep2 = rep[1];
    // The C's `_start` label: the outer loop runs while `ip1 <= ilimit`, and
    // `ip1 = ip0 + stepSize` (1) after every match.
    while (ip0 + 1 <= ilimit) {
        var step: usize = 1;
        var next_step: usize = ip0 + attach_step_incr;
        var ip1 = ip0 + 1;
        var hash0 = hashAt(source, ip0, params.hash_log, mls);
        var dict_index0 = dict.candidate(source, ip0, mls);
        var match_index = hash_table[hash0];
        // The last position whose hash was written before a match (`curr` in
        // the C): the fill below uses it, and the backward extension does not
        // move it.
        var current0 = ip0;
        const found: DictFound = find: {
            while (true) {
                // The rep is a frame offset; the byte it names is in the
                // source slice when it stays above the slice's start, in the
                // dictionary when it reaches below the frame's start, and
                // nowhere when it falls between (output a writer has
                // compacted away). A rep larger than the whole virtual past
                // cannot happen for a formatted dictionary (the parse bounds
                // it by the content) or for a rep born in the frame; a *raw*
                // dictionary shorter than the default {1,4,8} can carry one,
                // and the C's own assert admits it only in debug builds.
                const rep_reachable = rep1 <= virtual_offset + ip0 + 1;
                const rep_index = if (rep_reachable) virtual_offset + ip0 + 1 - rep1 else 0;
                const rep_holds = rep_index < dict_len or rep1 <= ip0 + 1;
                const hash1 = hashAt(source, ip1, params.hash_log, mls);
                const dict_index1 = dict.candidate(source, ip1, mls);
                hash_table[hash0] = @intCast(ip0);
                // The repcode pre-check at `ip0 + 1` (`zstd_fast.c:566`).
                if (rep_reachable and rep_holds and rep1 > 0 and
                    indexOverlapCheck(dict_len, rep_index) and
                    read32Virtual(dict.content, source, rep_index, frame_start) ==
                        read32(source, ip0 + 1))
                {
                    const position = ip0 + 1;
                    const length = 4 + if (rep_index < dict_len)
                        countFromDict(source, dict.content, position + 4, rep_index + 4, iend)
                    else
                        count(source, position + 4, position + 4 - rep1, iend);
                    break :find .{
                        .position = position,
                        .offset_value = repcode1_off_base,
                        .length = length,
                    };
                }
                if (dict_index0) |index| {
                    // "To replicate extDict parse behavior, we only use
                    // dict matches when the normal matchIndex is invalid"
                    // (`zstd_fast.c:585-586`).
                    if (match_index == 0 and
                        read32(dict.content, index) == read32(source, ip0))
                    {
                        const offset: u32 = @intCast(virtual_offset + ip0 - index);
                        var position = ip0;
                        var content_position = index;
                        var length: usize = 4 + countTwoSegments(
                            source,
                            ip0 + 4,
                            dict.content,
                            index + 4,
                            iend,
                            0,
                        );
                        // The backward extension, bounded by the anchor and
                        // the content's start.
                        while (position > anchor and content_position > 0 and
                            source[position - 1] == dict.content[content_position - 1])
                        {
                            position -= 1;
                            content_position -= 1;
                            length += 1;
                        }
                        rep2 = rep1;
                        rep1 = offset;
                        break :find .{
                            .position = position,
                            .offset_value = offset + 3,
                            .length = length,
                        };
                    }
                }
                if (match_index >= 1 and match_index + 4 <= source.len and
                    read32(source, match_index) == read32(source, ip0))
                {
                    const offset: u32 = @intCast(ip0 - match_index);
                    var position = ip0;
                    var match_position = match_index;
                    var length: usize = 4 + count(source, ip0 + 4, match_position + 4, iend);
                    while (position > anchor and match_position > 0 and
                        source[position - 1] == source[match_position - 1])
                    {
                        position -= 1;
                        match_position -= 1;
                        length += 1;
                    }
                    rep2 = rep1;
                    rep1 = offset;
                    break :find .{
                        .position = position,
                        .offset_value = offset + 3,
                        .length = length,
                    };
                }
                // The pair's next position.
                dict_index0 = dict_index1;
                match_index = hash_table[hash1];
                if (ip1 >= next_step) {
                    step += 1;
                    next_step += attach_step_incr;
                }
                ip0 = ip1;
                ip1 = ip1 + step;
                if (ip1 > ilimit) {
                    // `_cleanup`: the scan leaves with the reps as they are.
                    store.appendTrailing(source, anchor, iend);
                    rep[0] = rep1;
                    rep[1] = rep2;
                    return;
                }
                current0 = ip0;
                hash0 = hash1;
            }
        };
        store.append(source, anchor, found.position, found.offset_value, @intCast(found.length));
        ip0 = found.position + found.length;
        anchor = ip0;
        if (ip0 <= ilimit) {
            // Fill the table at the match's edges (`zstd_fast.c:668-670`).
            hash_table[hashAt(source, current0 + 2, params.hash_log, mls)] =
                @intCast(current0 + 2);
            hash_table[hashAt(source, ip0 - 2, params.hash_log, mls)] =
                @intCast(ip0 - 2);
            // The immediate-rep chain (`zstd_fast.c:672-687`).
            while (ip0 <= ilimit) {
                const rep_reachable = rep2 <= virtual_offset + ip0;
                const rep_index2 = if (rep_reachable) virtual_offset + ip0 - rep2 else 0;
                const rep_holds = rep_index2 < dict_len or rep2 <= ip0;
                if (rep2 == 0 or !rep_reachable or !rep_holds or
                    !indexOverlapCheck(dict_len, rep_index2) or
                    read32Virtual(dict.content, source, rep_index2, frame_start) !=
                        read32(source, ip0))
                {
                    break;
                }
                const run_length = 4 + if (rep_index2 < dict_len)
                    countFromDict(source, dict.content, ip0 + 4, rep_index2 + 4, iend)
                else
                    count(source, ip0 + 4, ip0 + 4 - rep2, iend);
                const swap = rep1;
                rep1 = rep2;
                rep2 = swap;
                hash_table[hashAt(source, ip0, params.hash_log, mls)] = @intCast(ip0);
                store.append(source, anchor, ip0, repcode1_off_base, @intCast(run_length));
                ip0 += run_length;
                anchor = ip0;
            }
        }
    }
    store.appendTrailing(source, anchor, iend);
    rep[0] = rep1;
    rep[1] = rep2;
}

/// `ZSTD_compressBlock_fast_extDict_generic` (`zstd_fast.c:709-970`): the
/// copy path — the dictionary's table copied into the frame's own (tags
/// stripped) and the content run as the window's extDict, with every read
/// split across the two regions. `prefix_start_index` is the C's
/// `prefixStartIndex` (the virtual index where the source begins, which
/// rises with the window floor) and `dict_start_index` its
/// `ZSTD_getLowestMatchIndex`: the lowest table entry that may be a
/// candidate, which rises once the frame's output passes the window and the
/// dictionary stops being addressable (`§5`,
/// `zstd_compress_internal.h:1099-1145`).
pub fn findExtDict(
    source: []const u8,
    block_start: usize,
    block_size: usize,
    params: Params,
    hash_table: []u32,
    dict: []const u8,
    prefix_start_index: usize,
    dict_start_index: usize,
    rep: *[3]u32,
    store: *Store,
) void {
    // The scan is instantiated per hash width, as the C's per-mls copies are.
    const args: ExtScanArgs = .{
        .source = source,
        .block_start = block_start,
        .block_size = block_size,
        .params = params,
        .hash_table = hash_table,
        .dict = dict,
        .prefix_start_index = prefix_start_index,
        .dict_start_index = dict_start_index,
        .rep = rep,
        .store = store,
    };
    switch (params.mls) {
        5 => scanExt(5, args),
        6 => scanExt(6, args),
        7 => scanExt(7, args),
        else => unreachable,
    }
}

/// The extDict scan's arguments, grouped as `DictScanArgs` is.
const ExtScanArgs = struct {
    source: []const u8,
    block_start: usize,
    block_size: usize,
    params: Params,
    hash_table: []u32,
    dict: []const u8,
    prefix_start_index: usize,
    dict_start_index: usize,
    rep: *[3]u32,
    store: *Store,
};

/// `findExtDict`'s scan, specialized on the frame's hash width.
fn scanExt(comptime mls: u3, args: ExtScanArgs) void {
    const source = args.source;
    const block_start = args.block_start;
    const block_size = args.block_size;
    const params = args.params;
    const hash_table = args.hash_table;
    const dict = args.dict;
    const prefix_start_index = args.prefix_start_index;
    const dict_start_index = args.dict_start_index;
    const rep = args.rep;
    const store = args.store;
    assert(block_size > 0);
    assert(block_start + block_size <= source.len);
    assert(hash_table.len == @as(usize, 1) << @intCast(params.hash_log));
    assert(dict.len > 0);
    assert(prefix_start_index >= dict.len);
    // `dict_start_index` can sit above `prefix_start_index` once the window
    // has slid past the dictionary (`ZSTD_getLowestMatchIndex` against a
    // `lowLimit` that has outrun `dictLimit`): every dictionary entry is then
    // below the floor and only the frame's own positions are candidates.
    const iend = block_start + block_size;
    const ilimit = if (iend >= hash_read_size) iend - hash_read_size else 0;
    var ip0 = block_start;
    var anchor = block_start;
    var rep1 = rep[0];
    var rep2 = rep[1];
    var current0: usize = 0;
    // The rep invalidation (`zstd_fast.c:765-771`): a rep that reaches before
    // the candidate floor is zeroed for the block and restored after it.
    var offset_saved1: u32 = 0;
    var offset_saved2: u32 = 0;
    {
        const max_rep: u32 = @intCast(dict.len + ip0 - dict_start_index);
        if (rep2 >= max_rep) {
            offset_saved2 = rep2;
            rep2 = 0;
        }
        if (rep1 >= max_rep) {
            offset_saved1 = rep1;
            rep1 = 0;
        }
    }
    scan_loop: while (true) {
        var step: usize = step_size;
        var next_step: usize = ip0 + step_incr;
        var ip1 = ip0 + 1;
        var ip2 = ip0 + step;
        var ip3 = ip2 + 1;
        if (ip3 >= ilimit) break :scan_loop;
        var hash0 = hashAt(source, ip0, params.hash_log, mls);
        var hash1 = hashAt(source, ip1, params.hash_log, mls);
        var match_index = hash_table[hash0];
        const found: DictFound = find: {
            while (true) {
                // The repcode pre-check at ip2, guarded so the 4 bytes stay
                // inside one region (`zstd_fast.c:791-799`).
                const rep_reachable = rep1 <= dict.len + ip2;
                const rep_index = if (rep_reachable) dict.len + ip2 - rep1 else 0;
                current0 = dict.len + ip0;
                hash_table[hash0] = @intCast(current0);
                if (rep_reachable and rep1 > 0 and indexOverlapCheck(dict.len, rep_index) and
                    read32Virtual(dict, source, rep_index, 0) == read32(source, ip2))
                {
                    var position = ip2;
                    var length: usize = 4;
                    // The one-byte backward extension (`zstd_fast.c:812-815`).
                    if (position > anchor and rep_index > 0 and
                        source[position - 1] == byteAt(dict, source, rep_index - 1))
                    {
                        position -= 1;
                        length += 1;
                    }
                    break :find .{
                        .position = position,
                        .offset_value = repcode1_off_base,
                        .length = length + if (rep_index < dict.len)
                            countFromDict(source, dict, position + length, rep_index + length, iend)
                        else
                            count(source, position + length, position + length - rep1, iend),
                    };
                }
                const candidate = extCandidate(
                    dict,
                    source,
                    match_index,
                    ip0,
                    prefix_start_index,
                    dict_start_index,
                );
                if (candidate) |match| {
                    break :find extTail(
                        source,
                        dict,
                        ip0,
                        anchor,
                        match_index,
                        match,
                        &rep1,
                        &rep2,
                        iend,
                    );
                }
                // The pair's second half.
                match_index = hash_table[hash1];
                hash0 = hash1;
                hash1 = hashAt(source, ip2, params.hash_log, mls);
                ip0 = ip1;
                ip1 = ip2;
                ip2 = ip3;
                current0 = dict.len + ip0;
                hash_table[hash0] = @intCast(current0);
                const candidate2 = extCandidate(
                    dict,
                    source,
                    match_index,
                    ip0,
                    prefix_start_index,
                    dict_start_index,
                );
                if (candidate2) |match| {
                    // "Avoid writing an index if it's >= position where
                    // search will resume" (`zstd_fast.c:314-320`).
                    if (step <= 4) hash_table[hash1] = @intCast(dict.len + ip1);
                    break :find extTail(
                        source,
                        dict,
                        ip0,
                        anchor,
                        match_index,
                        match,
                        &rep1,
                        &rep2,
                        iend,
                    );
                }
                match_index = hash_table[hash1];
                hash0 = hash1;
                hash1 = hashAt(source, ip2, params.hash_log, mls);
                ip0 = ip1;
                ip1 = ip2;
                ip2 = ip0 + step;
                ip3 = ip1 + step;
                if (ip2 >= next_step) {
                    step += 1;
                    next_step += step_incr;
                }
                if (ip3 >= ilimit) break :scan_loop;
            }
        };
        store.append(source, anchor, found.position, found.offset_value, @intCast(found.length));
        ip0 = found.position + found.length;
        anchor = ip0;
        // "write next hash table entry": the pipelined hash1 was already
        // calculated, and the match ran past ip1 (`zstd_fast.c:945-947`).
        if (ip1 < ip0) hash_table[hash1] = @intCast(dict.len + ip1);
        if (ip0 <= ilimit) {
            hash_table[hashAt(source, current0 + 2 - dict.len, params.hash_log, mls)] =
                @intCast(current0 + 2);
            hash_table[hashAt(source, ip0 - 2, params.hash_log, mls)] =
                @intCast(dict.len + ip0 - 2);
            // The immediate-rep chain (`zstd_fast.c:957-968`).
            while (ip0 <= ilimit) {
                const rep_reachable = rep2 <= dict.len + ip0;
                const rep_index2 = if (rep_reachable) dict.len + ip0 - rep2 else 0;
                if (!rep_reachable or rep2 == 0 or
                    !indexOverlapCheck(dict.len, rep_index2) or
                    read32Virtual(dict, source, rep_index2, 0) != read32(source, ip0))
                {
                    break;
                }
                const run_length = 4 + if (rep_index2 < dict.len)
                    countFromDict(source, dict, ip0 + 4, rep_index2 + 4, iend)
                else
                    count(source, ip0 + 4, ip0 + 4 - rep2, iend);
                const swap = rep1;
                rep1 = rep2;
                rep2 = swap;
                hash_table[hashAt(source, ip0, params.hash_log, mls)] =
                    @intCast(dict.len + ip0);
                store.append(source, anchor, ip0, repcode1_off_base, @intCast(run_length));
                ip0 += run_length;
                anchor = ip0;
            }
        }
    }
    offset_saved2 = if (offset_saved1 != 0 and rep1 != 0) offset_saved1 else offset_saved2;
    rep[0] = if (rep1 != 0) rep1 else offset_saved1;
    rep[1] = if (rep2 != 0) rep2 else offset_saved2;
    store.appendTrailing(source, anchor, iend);
}

/// The extDict match tail (`zstd_fast.c:918-943`): the backward extension to
/// the anchor and the candidate's floor, the rep shift, and the offset code.
fn extTail(
    source: []const u8,
    dict: []const u8,
    ip0: usize,
    anchor: usize,
    match_index: usize,
    match: Candidate,
    rep1: *u32,
    rep2: *u32,
    iend: usize,
) DictFound {
    const offset: u32 = @intCast(dict.len + ip0 - match_index);
    var position = ip0;
    var match_position = match.position;
    var length: usize = 4;
    while (position > anchor and match_position > match.floor and
        source[position - 1] ==
            (if (match.dict) dict[match_position - 1] else source[match_position - 1]))
    {
        position -= 1;
        match_position -= 1;
        length += 1;
    }
    rep2.* = rep1.*;
    rep1.* = offset;
    const extended = if (match.dict)
        countFromDict(source, dict, position + length, match_position + length, iend)
    else
        count(source, position + length, match_position + length, iend);
    return .{
        .position = position,
        .offset_value = offset + 3,
        .length = length + extended,
    };
}

/// The scan's mutable state: the loop's positions, the rep history, and the
/// last position whose hash was written before a match (`current0` in the C),
/// grouped so the match tail is one helper instead of a dozen scalars.
const Scan = struct {
    source: []const u8,
    iend: usize,
    /// `ilimit` (`zstd_fast.c:212`): the last position the pipelined loop can
    /// hash, `iend - HASH_READ_SIZE`.
    ilimit: usize,
    prefix_start: usize,
    /// The lowest table entry that may be a candidate (`prefix_start`, and at
    /// least 1: a zeroed slot is "no candidate").
    candidate_floor: usize,
    /// The declared Window_Size (`§3.1.1.1.2`): every emitted offset is
    /// strictly below it (`§3.1.1.4`).
    window_size: usize,
    /// The first unmatched byte: where the next sequence's literals start.
    anchor: usize,
    /// The scan position.
    ip0: usize,
    /// The last position written to the table before the current match.
    current0: usize = 0,
    params: Params,
    hash_table: []u32,
    store: *Store,
    /// Repeated_Offset1 and Repeated_Offset2 (`§3.1.1.5`); the third is
    /// never selected by this finder and stays with the caller.
    rep1: u32,
    rep2: u32,

    /// What a found match hands to the shared tail: the candidate's position
    /// (already backward-extended), the wire offset value, and the bytes the
    /// extension counted.
    const Found = struct {
        position: usize,
        offset_value: u32,
        base_length: usize,
    };

    /// The C's pipelined scan (`zstd_fast.c:255-353`): positions advance in
    /// adjacent pairs, and the step between pairs grows by one every 128
    /// unmatched bytes. The labeled control flow is the C's `goto _start` /
    /// `goto _offset` / `goto _match` shape, kept whole on purpose (the
    /// house's `encodeBlock` precedent), and it is one function over local
    /// scalars for the same reason the C is: the probe chain's state —
    /// positions, reps, the anchor — must stay in registers, not round-trip
    /// a state struct through memory every probe (measured: the out-of-line
    /// match tail alone cost the match-dense shapes ~13%). The `scan` fields
    /// are loaded once on entry and stored once on exit; the byte stream the
    /// scan emits is unchanged.
    fn scanBlock(scan: *Scan, comptime mls: u3) void {
        const source = scan.source;
        const iend = scan.iend;
        const ilimit = scan.ilimit;
        const prefix_start = scan.prefix_start;
        const candidate_floor = scan.candidate_floor;
        const window_size = scan.window_size;
        const hash_log = scan.params.hash_log;
        const hash_table = scan.hash_table;
        const store = scan.store;
        var ip0 = scan.ip0;
        var anchor = scan.anchor;
        var rep1 = scan.rep1;
        var rep2 = scan.rep2;
        var current0 = scan.current0;
        defer {
            scan.ip0 = ip0;
            scan.anchor = anchor;
            scan.rep1 = rep1;
            scan.rep2 = rep2;
            scan.current0 = current0;
        }
        scan_loop: while (true) {
            var step: usize = step_size;
            var next_step: usize = ip0 + step_incr;
            var ip1 = ip0 + 1;
            var ip2 = ip0 + step;
            var ip3 = ip2 + 1;
            if (ip3 >= ilimit) break :scan_loop;
            var hash0 = hashAt(source, ip0, hash_log, mls);
            var hash1 = hashAt(source, ip1, hash_log, mls);
            var match_index: usize = hash_table[hash0];
            const found: Found = find: {
                while (true) {
                    // The repcode pre-check at ip2: Repeated_Offset1 two
                    // bytes ahead beats the table candidate at ip0.
                    const rep_value = read32(source, ip2 - rep1);
                    current0 = ip0;
                    hash_table[hash0] = @intCast(ip0);
                    if (rep1 > 0 and read32(source, ip2) == rep_value) {
                        ip0 = ip2;
                        var match_position = ip0 - rep1;
                        var base_length: usize = 4;
                        // One byte of backward extension at most, which stops
                        // at anchor + 1: the sequence keeps its literals.
                        if (source[ip0 - 1] == source[match_position - 1]) {
                            ip0 -= 1;
                            match_position -= 1;
                            base_length += 1;
                        }
                        hash_table[hash1] = @intCast(ip1);
                        break :find .{
                            .position = match_position,
                            .offset_value = repcode1_off_base,
                            .base_length = base_length,
                        };
                    }
                    if (match4Found(source, ip0, match_index, candidate_floor)) {
                        hash_table[hash1] = @intCast(ip1);
                        break :find matchAt(
                            source,
                            &ip0,
                            anchor,
                            prefix_start,
                            &rep1,
                            &rep2,
                            match_index,
                        );
                    }
                    // The pair's second half: ip0 moves to ip1.
                    match_index = hash_table[hash1];
                    hash0 = hash1;
                    hash1 = hashAt(source, ip2, hash_log, mls);
                    ip0 = ip1;
                    ip1 = ip2;
                    ip2 = ip3;
                    current0 = ip0;
                    hash_table[hash0] = @intCast(ip0);
                    if (match4Found(source, ip0, match_index, candidate_floor)) {
                        // "Avoid writing an index if it's >= position where
                        // search will resume": a match is at least 4 bytes,
                        // so the scan resumes at ip0 + 4
                        // (`zstd_fast.c:314-320`).
                        if (step <= 4) hash_table[hash1] = @intCast(ip1);
                        break :find matchAt(
                            source,
                            &ip0,
                            anchor,
                            prefix_start,
                            &rep1,
                            &rep2,
                            match_index,
                        );
                    }
                    match_index = hash_table[hash1];
                    hash0 = hash1;
                    hash1 = hashAt(source, ip2, hash_log, mls);
                    ip0 = ip1;
                    ip1 = ip2;
                    ip2 = ip0 + step;
                    ip3 = ip1 + step;
                    if (ip2 >= next_step) {
                        step += 1;
                        next_step += step_incr;
                    }
                    // The C's `do ... while (ip3 < ilimit)` exits to
                    // `_cleanup` (`zstd_fast.c:348-350`), which leaves the
                    // scan loop; only a match's `goto _start` re-enters it
                    // (with `step` reset).
                    if (ip3 >= ilimit) break :scan_loop;
                }
            };
            // `_match` (`zstd_fast.c:402-420`): count the forward length,
            // store the sequence, refill the table at the match's edges, and
            // drain the offset-2 chain. `ip0` and `found.position` already
            // include the backward extension, and `base_length` is the bytes
            // it counted.
            const match_position = found.position;
            // RFC 8878 §3.1.1.4 — "all offsets leading to previously decoded
            // data must be smaller than Window_Size": the candidate floor
            // and the rep restore bound every emission.
            assert(ip0 - match_position < window_size);
            const match_length = found.base_length + count(
                source,
                ip0 + found.base_length,
                match_position + found.base_length,
                iend,
            );
            assert(match_length >= 4);
            store.append(source, anchor, ip0, found.offset_value, @intCast(match_length));
            ip0 += match_length;
            anchor = ip0;
            if (ip0 <= ilimit) {
                // Fill the table at the match's edges (`zstd_fast.c:404-408`):
                // the last position written before the match, two bytes on,
                // and the position two before the new scan start.
                hash_table[hashAt(source, current0 + 2, hash_log, mls)] = @intCast(current0 + 2);
                hash_table[hashAt(source, ip0 - 2, hash_log, mls)] = @intCast(ip0 - 2);
                // `zstd_fast.c:410-420` — the offset-2 immediate-repeat
                // chain: while Repeated_Offset2 matches at the new position,
                // emit back-to-back zero-literal repcode sequences, swapping
                // rep1/rep2 each time (the swap is the decoder's §3.1.1.5
                // shift at `literals_length == 0`).
                while (rep2 > 0 and ip0 <= ilimit and
                    read32(source, ip0) == read32(source, ip0 - rep2))
                {
                    // The chain emits at rep2, the same strict window bound.
                    assert(rep2 < window_size);
                    const run_length = count(source, ip0 + 4, ip0 + 4 - rep2, iend) + 4;
                    const swap = rep1;
                    rep1 = rep2;
                    rep2 = swap;
                    hash_table[hashAt(source, ip0, hash_log, mls)] = @intCast(ip0);
                    store.append(source, anchor, ip0, repcode1_off_base, @intCast(run_length));
                    ip0 += run_length;
                    anchor = ip0;
                }
            }
        }
    }

    /// `_offset` (`zstd_fast.c:389-401`): a literal-offset match's own part
    /// before the shared tail — the reps shift, and the match extends
    /// backward to the anchor and the prefix. A leaf over the scan's locals
    /// (inline, so nothing spills); the forward count is the tail's.
    inline fn matchAt(
        source: []const u8,
        ip0: *usize,
        anchor: usize,
        prefix_start: usize,
        rep1: *u32,
        rep2: *u32,
        match_index: usize,
    ) Found {
        // The table only ever holds positions the scan has passed, so a
        // candidate is always behind the current position: one table per
        // frame, blocks scanned in order.
        assert(match_index < ip0.*);
        const offset: u32 = @intCast(ip0.* - match_index);
        rep2.* = rep1.*;
        rep1.* = offset;
        var match = match_index;
        var base_length: usize = 4;
        while (ip0.* > anchor and match > prefix_start and
            source[ip0.* - 1] == source[match - 1])
        {
            ip0.* -= 1;
            match -= 1;
            base_length += 1;
        }
        return .{
            .position = match,
            .offset_value = offset + 3,
            .base_length = base_length,
        };
    }
};

/// `ZSTD_match4Found` (`zstd_fast.c:103-125`): the candidate holds the same
/// 4 bytes and lies at or past the candidate floor. `match_index` is a table
/// entry, so it may be 0 from an unwritten slot, which the floor refuses.
inline fn match4Found(
    source: []const u8,
    position: usize,
    match_index: usize,
    candidate_floor: usize,
) bool {
    return read32(source, position) == read32(source, match_index) and
        match_index >= candidate_floor;
}

/// `ZSTD_hashPtr` (`zstd_compress_internal.h:930-948`): the `mls` bytes at
/// `position` shifted into the word's top, multiplied by the width's prime,
/// keeping the top `hash_log` bits. `mls` 8 is the dfast long table's own
/// width (`ZSTD_hash8Ptr`), hashed at every level of the class.
pub inline fn hashAt(
    source: []const u8,
    position: usize,
    hash_log: u6,
    comptime mls: u4,
) usize {
    assert(position + hash_read_size <= source.len);
    const word = readInt(u64, source[position..][0..8]);
    const shift: u6 = @intCast(64 - @as(u7, hash_log));
    // Comptime `mls`: the scan is specialized per width (the C's per-mls
    // instantiations, `zstd_fast.c:436-439`), so the prime is a loop-invariant
    // constant in a register, not a per-probe table load.
    return switch (mls) {
        4 => @intCast((read32(source, position) *% prime4bytes) >>
            @intCast(32 - @as(u7, hash_log))),
        5 => @intCast(((word << 24) *% prime5bytes) >> shift),
        6 => @intCast(((word << 16) *% prime6bytes) >> shift),
        7 => @intCast(((word << 8) *% prime7bytes) >> shift),
        8 => @intCast((word *% prime8bytes) >> shift),
        else => unreachable,
    };
}

/// A 4-byte read, the C's `MEM_read32`. The caller keeps the 4-byte margin.
pub inline fn read32(source: []const u8, position: usize) u32 {
    assert(position + 4 <= source.len);
    return readInt(u32, source[position..][0..4]);
}

/// An 8-byte read, the C's `MEM_read64`. The caller keeps the 8-byte margin.
pub inline fn read64(source: []const u8, position: usize) u64 {
    assert(position + 8 <= source.len);
    return readInt(u64, source[position..][0..8]);
}

/// The forward-extension vector width: the CPU's byte-vector suggestion, so
/// a stripe compare is one instruction on NEON (16) and AVX-512 (64).
const count_vec_len = std.simd.suggestVectorLengthForCpu(u8, builtin.cpu) orelse 8;
const CountVec = @Vector(count_vec_len, u8);

/// `ZSTD_count` (`zstd_compress_internal.h:854-875`): the common bytes
/// between `current` and `match` up to `iend`, a stripe at a time — the
/// word-XOR machinery the flate finder uses, widened to a vector compare —
/// then the 8/4/2/1-byte tail. `match < current` and both reads stay inside
/// `iend`. Long matches dominate the compressible shapes (a 32 KiB html
/// block is one extension), so the stripe width is what matters; the first
/// difference is the lowest set mask bit (lane i is bit i, bytes in order).
pub fn count(source: []const u8, current_start: usize, match_start: usize, iend: usize) usize {
    return countTwo(source, current_start, source, match_start, iend - current_start);
}

/// `count` over two regions: the dictionary's content and the source are
/// separate caller buffers, and a match that begins in one may run into the
/// other (`ZSTD_count_2segments`). `limit` is the bytes the count may consume
/// from `a_start`; the caller guarantees `b_start + limit` stays inside `b`.
fn countTwo(
    a: []const u8,
    a_start: usize,
    b: []const u8,
    b_start: usize,
    limit: usize,
) usize {
    var current = a_start;
    var match = b_start;
    const iend = a_start + limit;
    assert(a_start <= a.len);
    assert(iend <= a.len);
    assert(match + limit <= b.len);
    // The first word peels off the common short extension (most matches end
    // within their first eight unchecked bytes): a stripe compare's mask
    // chain costs more than the one word-XOR that resolves them, and the
    // vector loop pays for itself only past it (measured on the words
    // shape's short matches).
    if (current + 8 <= iend) {
        const difference = readInt(u64, a[current..][0..8]) ^ readInt(u64, b[match..][0..8]);
        if (difference != 0) return @ctz(difference) >> 3;
        current += 8;
        match += 8;
    }
    while (current + count_vec_len <= iend) {
        const va: CountVec = a[current..][0..count_vec_len].*;
        const vb: CountVec = b[match..][0..count_vec_len].*;
        const mask: @Int(.unsigned, count_vec_len) = @bitCast(va != vb);
        if (mask != 0) return current - a_start + @ctz(mask);
        current += count_vec_len;
        match += count_vec_len;
    }
    while (current + 8 <= iend) {
        const difference = readInt(u64, a[current..][0..8]) ^ readInt(u64, b[match..][0..8]);
        if (difference != 0) return current - a_start + (@ctz(difference) >> 3);
        current += 8;
        match += 8;
    }
    if (current + 4 <= iend and read32(a, current) == read32(b, match)) {
        current += 4;
        match += 4;
    }
    if (current + 2 <= iend and
        readInt(u16, a[current..][0..2]) == readInt(u16, b[match..][0..2]))
    {
        current += 2;
        match += 2;
    }
    if (current < iend and a[current] == b[match]) current += 1;
    return current - a_start;
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/specs/rfc8878-zstd.txt §3.1.1.3.2.1 (the
// sequences a token stream must carry), §3.1.1.4 (offsets), §3.1.1.5 (the
// repeat offsets). Every token stream is executed by the test's own decoder
// — the §3.1.1.4/§3.1.1.5 rules, independent of the finder — and must
// reproduce the block byte for byte.
// ---------------------------------------------------------------------------

/// Execute a token stream the way `§3.1.1.4` says: literals first, then the
/// match at the resolved offset, whose copy may overlap the bytes it writes
/// (the copy reads bytes this execution has already written). Proves the
/// stream is a faithful encoding of the block, offsets and all. Shared with
/// the dfast finder's tests (`dfast_compress.zig`).
pub fn expectTokensReproduce(
    source: []const u8,
    block_start: usize,
    block_size: usize,
    window_log: u6,
    store: *const Store,
    rep_seed: [3]u32,
) !void {
    const iend = block_start + block_size;
    const window_size: usize = @as(usize, 1) << @intCast(window_log);
    const prefix_start: usize = if (iend > window_size) iend - window_size else 0;
    var rep = rep_seed;
    var position = block_start;
    var literals_used: usize = 0;
    for (store.sequences[0..store.sequence_count]) |sequence| {
        const literals_length = sequence.literals_length;
        try testing.expectEqualSlices(
            u8,
            source[position..][0..literals_length],
            store.literals[literals_used..][0..literals_length],
        );
        position += literals_length;
        literals_used += literals_length;
        const offset = try resolveOffset(&rep, sequence.literals_length, sequence.offset_value);
        try testing.expect(offset >= 1);
        // RFC 8878 §3.1.1.4 — the offset addresses retained history: at or
        // after the block's prefix, and strictly below the declared window.
        try testing.expect(offset <= position - prefix_start);
        try testing.expect(offset < window_size);
        try testing.expect(sequence.match_length >= min_match_length);
        var copied: u32 = 0;
        while (copied < sequence.match_length) : (copied += 1) {
            try testing.expectEqual(
                source[position + copied],
                source[position + copied - offset],
            );
        }
        position += sequence.match_length;
    }
    try testing.expectEqualSlices(
        u8,
        source[position..iend],
        store.literals[literals_used..store.literals_len],
    );
    try testing.expectEqual(store.literals_len - literals_used, iend - position);
}

/// `§3.1.1.4` + `§3.1.1.5` — the offset an offset_value selects, updating the
/// repeats. The test's own reading of the rules: an offset_value above 3 is
/// `Offset_Value - 3`; below 4 it selects a repeat with the
/// `literals_length == 0` shift.
fn resolveOffset(repeat_offsets: *[3]u32, literals_length: u32, offset_value: u32) !u32 {
    if (offset_value > 3) {
        const offset = offset_value - 3;
        repeat_offsets[2] = repeat_offsets[1];
        repeat_offsets[1] = repeat_offsets[0];
        repeat_offsets[0] = offset;
        return offset;
    }
    const selected = if (literals_length == 0) offset_value else offset_value - 1;
    if (selected == 3) return error.ZeroOffset;
    const offset = repeat_offsets[selected];
    if (selected == 1) {
        repeat_offsets[1] = repeat_offsets[0];
        repeat_offsets[0] = offset;
    } else if (selected == 2) {
        repeat_offsets[2] = repeat_offsets[1];
        repeat_offsets[1] = repeat_offsets[0];
        repeat_offsets[0] = offset;
    }
    return offset;
}

/// Scan a block and check the token stream reproduces it. The finder's
/// outputs are bounded by the caller's buffers, which this sizes from the
/// block.
fn expectFind(source: []const u8, params: Params, rep_seed: [3]u32, block_start: usize) !void {
    var hash_table: [1 << 16]u32 = @splat(0);
    try testing.expect(params.hash_log <= 16);
    var literals: [256 * 1024]u8 = undefined;
    var sequence_buffer: [256 * 1024 / 4 + 1]sequences_compress.Sequence = undefined;
    var store: Store = .init(&literals, &sequence_buffer);
    var rep = rep_seed;
    find(
        source,
        block_start,
        source.len - block_start,
        params,
        hash_table[0 .. @as(usize, 1) << @intCast(params.hash_log)],
        &rep,
        &store,
    );
    try expectTokensReproduce(
        source,
        block_start,
        source.len - block_start,
        params.window_log,
        &store,
        rep_seed,
    );
}

test "the finder emits sequences that reproduce the block" {
    // RFC 8878 §3.1.1.4 — a sequence copies its literals then its match at
    // the offset; the streams the finder emits must reproduce the block
    // exactly, for every shape the ladder's classes cover.
    const params: Params = .init(17, 13, 6);
    var rng: DefaultPrng = .init(0xF00D);
    const random = rng.random();
    var source: [128 * 1024]u8 = undefined;
    const shapes = 5;
    for (0..40) |round| {
        const length = 8 + random.uintLessThan(usize, source.len - 8);
        const shape = round % shapes;
        for (source[0..length], 0..) |*byte, index| {
            byte.* = switch (shape) {
                0 => random.int(u8),
                1 => @truncate(index % 7),
                2 => 0x41,
                3 => if (index % 40 < 20) 'a' else 'b',
                else => @truncate((index * 31) % 251),
            };
        }
        try expectFind(source[0..length], params, .{ 1, 4, 8 }, 0);
    }
    // A block in the middle of a frame: the prefix bound and the rep
    // invalidation both apply.
    try expectFind(&source, params, .{ 1, 4, 8 }, 64 * 1024);
    try expectFind(&source, params, .{ 100, 40000, 8 }, 64 * 1024);
}

test "the rep pre-check wins two bytes ahead and keeps its literals" {
    // RFC 8878 §3.1.1.5 — the pre-check lets Repeated_Offset1 match at
    // ip0 + 2; its backward extension stops one short of the anchor, so the
    // emitted sequence always carries at least one literal (the hot path
    // never meets the literals_length == 0 shift).
    var source: [1024]u8 = undefined;
    // "xyzw" then the same four bytes again: after the first match at offset
    // 4, the next position matches rep1 at +2.
    const pattern = "xyzwxyzwxyzwxyzw";
    fastmem.copy(u8, source[0..pattern.len], pattern);
    var index: usize = pattern.len;
    while (index < source.len) : (index += 1) source[index] = @truncate(index);
    const params: Params = .init(10, 11, 6);
    var hash_table: [1 << 11]u32 = @splat(0);
    var literals: [2048]u8 = undefined;
    var sequence_buffer: [1024]sequences_compress.Sequence = undefined;
    var store: Store = .init(&literals, &sequence_buffer);
    var rep = [3]u32{ 1, 4, 8 };
    find(&source, 0, source.len, params, &hash_table, &rep, &store);
    try expectTokensReproduce(&source, 0, source.len, params.window_log, &store, .{ 1, 4, 8 });
    // Every sequence has literals, and every offset_value is either a real
    // offset (above 3) or repcode 1.
    for (store.sequences[0..store.sequence_count]) |sequence| {
        try testing.expect(sequence.offset_value == 1 or sequence.offset_value > 3);
        if (sequence.offset_value == 1) try testing.expect(sequence.literals_length >= 1);
    }
}

test "the offset-2 chain emits zero-literal repcodes that decode" {
    // RFC 8878 §3.1.1.5 — back-to-back repeats at the older offset are
    // emitted as zero-literal repcode sequences with the rep swap. The block
    // starts at 64 with rep1 = 1: the first match uses the table's offset-4
    // candidate ("abcd" repeated) and ends where the one-byte run of 'd'
    // starts, because the run byte differs from the byte four back. The run
    // then matches at rep2 = 1, so the chain drains it.
    var source: [512]u8 = undefined;
    fastmem.set(u8, source[0..64], 0x5a);
    const pattern = "abcdabcdabcdabcd";
    fastmem.copy(u8, source[64..][0..pattern.len], pattern);
    fastmem.set(u8, source[64 + pattern.len .. 64 + pattern.len + 200], 'd');
    const tail = "xyz!";
    fastmem.copy(u8, source[264..][0..tail.len], tail);
    const params: Params = .init(12, 13, 6);
    var hash_table: [1 << 13]u32 = @splat(0);
    var literals: [2048]u8 = undefined;
    var sequence_buffer: [512]sequences_compress.Sequence = undefined;
    var store: Store = .init(&literals, &sequence_buffer);
    var rep = [3]u32{ 1, 4, 8 };
    find(&source, 64, source.len - 64, params, &hash_table, &rep, &store);
    try expectTokensReproduce(
        &source,
        64,
        source.len - 64,
        params.window_log,
        &store,
        .{ 1, 4, 8 },
    );
    // The chain's sequences: zero literals, repcode 1, matches that start at
    // the offset-2 distance.
    var chained: usize = 0;
    for (store.sequences[0..store.sequence_count]) |sequence| {
        if (sequence.literals_length == 0) {
            try testing.expectEqual(@as(u32, 1), sequence.offset_value);
            chained += 1;
        }
    }
    try testing.expect(chained > 0);
}

test "the finder refuses candidates that reach before the prefix" {
    // RFC 8878 §3.1.1.4 — a match may not address bytes before the window's
    // retained prefix. The block starts deep in the source with a small
    // window, so the table's stale early positions are out of reach.
    var source: [64 * 1024]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = @truncate(index % 8);
    const params: Params = .init(10, 11, 6);
    var hash_table: [1 << 11]u32 = @splat(0);
    var literals: [8192]u8 = undefined;
    var sequence_buffer: [4096]sequences_compress.Sequence = undefined;
    var store: Store = .init(&literals, &sequence_buffer);
    var rep = [3]u32{ 1, 4, 8 };
    const block_start = 60 * 1024;
    find(
        &source,
        block_start,
        source.len - block_start,
        params,
        &hash_table,
        &rep,
        &store,
    );
    try expectTokensReproduce(
        &source,
        block_start,
        source.len - block_start,
        params.window_log,
        &store,
        .{ 1, 4, 8 },
    );
}

test "every emission stays strictly below the declared Window_Size" {
    // RFC 8878 §3.1.1.4 — "all offsets leading to previously decoded data
    // must be smaller than Window_Size". The prefix is derived from the
    // block's END (`zstd_fast.c:204`); a prefix from its start lets a block
    // whose end is past the window emit offsets up to Window_Size plus the
    // block's own offset. This input plants a marker that is only reachable
    // through the too-far prefix, so a regression moves the maximum offset
    // above the window: klauspost's decoder rejects such a frame ("match
    // offset bigger than current history") even though our decoder, the CLI,
    // and libzstd accept it.
    const allocator = testing.allocator;
    const total: usize = 600 * 1024;
    const source = try allocator.alloc(u8, total);
    defer allocator.free(source);
    var rng: DefaultPrng = .init(42);
    rng.random().bytes(source);
    // A unique 64-byte run at 100, repeated inside the windowed block that
    // starts at 512 KiB, at block offset 200.
    const marker = source[100..164];
    fastmem.copy(u8, source[512 * 1024 + 200 ..][0..64], marker);
    const params: Params = .forSource(1, total);
    const window_size: usize = @as(usize, 1) << @intCast(params.window_log);
    const hash_table = try allocator.alloc(u32, @as(usize, 1) << @intCast(params.hash_log));
    defer allocator.free(hash_table);
    fastmem.set(u32, hash_table, 0);
    const literals = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(literals);
    const seqs = try allocator.alloc(sequences_compress.Sequence, 128 * 1024 / 3 + 1);
    defer allocator.free(seqs);
    var rep = [3]u32{ 1, 4, 8 };
    var block_start: usize = 0;
    var max_offset: usize = 0;
    while (block_start < total) {
        const size = @min(128 * 1024, total - block_start);
        var store: Store = .init(literals, seqs);
        find(source, block_start, size, params, hash_table, &rep, &store);
        for (store.sequences[0..store.sequence_count]) |sequence| {
            if (sequence.offset_value > 3) {
                max_offset = @max(max_offset, sequence.offset_value - 3);
            }
        }
        block_start += size;
    }
    try testing.expect(max_offset < window_size);
}
