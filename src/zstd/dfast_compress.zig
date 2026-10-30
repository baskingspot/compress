//! The zstd encoder's double-fast match finder — the C's `ZSTD_dfast`
//! (`zstd_double_fast.c`), the level-3 class. It is the level-1 finder's
//! sibling: the same greedy token stream, the same repcode machine, and the
//! same block layer above it, but two position tables instead of one — a long
//! table keyed on 8 bytes (`ZSTD_hash8`) and a small one keyed on the class's
//! `minMatch` — and a scan that checks both candidates per position, arbitrates
//! a second long match at `ip + 1` against the short match it found, and steps
//! over incompressible data twice as fast (256-byte increments, the C's
//! `1 << kSearchStrength` for this strategy).
//!
//! The three scans mirror the C's three: `find` is
//! `ZSTD_compressBlock_doubleFast_noDict_generic`, `findDict` the
//! dictionary-as-separate-match-state variant
//! (`ZSTD_compressBlock_doubleFast_dictMatchState_generic`), and `findExtDict`
//! the dictionary-copied-into-the-frame variant
//! (`ZSTD_compressBlock_doubleFast_extDict_generic`). The CLI's `-D` path
//! builds a CDict from the level's parameters, so which variant a frame runs
//! is decided by the source size against `attachDictSizeCutoffs[dfast]` — 16
//! KB — exactly as level 1's 8-KB cutoff is (`match_compress.attachCutoff`).
//!
//! Positions are offsets into the caller's `source` slice, as in the level-1
//! finder; the caller owns both tables (zeroed, `1 << hash_log` and
//! `1 << chain_log` entries) and the reps. A zeroed table slot means "no
//! candidate": the scan never writes the frame's position 0 (its first probe
//! is position 1, and the complementary insertion keys on positions at least
//! 2), while the C's window indices start at `ZSTD_WINDOW_START_INDEX` — the
//! same convention `match_compress.find` documents. The attach scan's own
//! table does write position 0 (its first probe is the frame's first byte), so
//! there a zeroed slot also means "no candidate" and the frame's position 0 is
//! never taken — the level-1 port's `findDict` makes the same choice.
//!
//! Format: docs/specs/rfc8878-zstd.txt §3.1.1.4 (offsets), §3.1.1.5
//! (the repeat offsets).
//! Lineage: facebook/zstd v1.5.7 `zstd_double_fast.c`
//! (`ZSTD_compressBlock_doubleFast_*_generic` and
//! `ZSTD_fillDoubleHashTableForCDict`); attribution in THIRD_PARTY.md.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const match_compress = @import("match_compress.zig");
const Params = match_compress.Params;
const DictParams = match_compress.DictParams;
const Store = match_compress.Store;
const count = match_compress.count;
const countTwoSegments = match_compress.countTwoSegments;
const hashAt = match_compress.hashAt;
const hashAtWidth = match_compress.hashAtWidth;
const indexOverlapCheck = match_compress.indexOverlapCheck;
const maxLoadedContent = match_compress.maxLoadedContent;
const read32 = match_compress.read32;
const read32Virtual = match_compress.read32Virtual;
const read64 = match_compress.read64;
const read64At = match_compress.read64At;
const short_cache_tag_bits = match_compress.short_cache_tag_bits;
const tagsMatch = match_compress.tagsMatch;
const writeTaggedIndex = match_compress.writeTaggedIndex;
const sequences_compress = @import("sequences_compress.zig");

/// `§3.1.1.3.2.1.1` — the shortest match a sequence can carry.
pub const min_match_length: u32 = match_compress.min_match_length;

/// `HASH_READ_SIZE` (`zstd_compress_internal.h:33`): the bytes a hash reads
/// and the scan loop's trailing margin.
const hash_read_size: usize = match_compress.hash_read_size;

/// `kSearchStrength` (`zstd_compress_internal.h:32`): dfast's scan
/// accelerates by one byte every `1 << kSearchStrength` unmatched bytes —
/// twice the fast finder's increment (`zstd_double_fast.c:203`).
const search_strength = 8;
pub const step_incr: usize = 1 << search_strength;

/// `REPCODE1_TO_OFFBASE` (`zstd_compress_internal.h:718`): the wire value of
/// the first repeat code, the only repcode this finder emits.
const repcode1_off_base: u32 = 1;

/// The long table's capacity: the level-3 rows' largest `hashLog` (17, the
/// default row's `H`).
pub const long_table_entries_max = 1 << 17;

/// The small table's capacity: the level-3 rows' largest `chainLog` (16, the
/// default row's `C`).
pub const small_table_entries_max = 1 << 16;

/// The finder's two position tables: `long` holds 8-byte-hash entries, `small`
/// the class's `minMatch`-hash ones. Both hold frame offsets, last writer
/// wins; the level-1 finder has only `long` and leaves `small` empty.
pub const Tables = struct {
    long: []u32,
    small: []u32,

    /// The level-1 finder's tables: only the long table; `small` stays empty.
    pub fn init(long: []u32) Tables {
        return .{ .long = long, .small = &.{} };
    }
};

/// A found match: the sequence's bytes are `source[position..][0..length]`,
/// the offset value is the wire form (`§3.1.1.5`), and `position` already
/// carries any backward extension.
const Found = struct {
    position: usize,
    offset_value: u32,
    length: usize,
};

/// The noDict scan's state: the loop's positions, the rep history, and the
/// parameters the tail needs.
const Scan = struct {
    source: []const u8,
    iend: usize,
    /// `ilimit` (`zstd_double_fast.c:104`): the last position the scan may
    /// probe, `iend - HASH_READ_SIZE`.
    ilimit: usize,
    prefix_start: usize,
    /// The lowest table entry that may be a candidate (`prefix_start`, and at
    /// least 1: a zeroed slot is "no candidate", and position 0 is never
    /// written).
    candidate_floor: usize,
    /// The declared Window_Size (`§3.1.1.1.2`): every emitted offset is
    /// strictly below it (`§3.1.1.4`).
    window_size: usize,
    /// The first unmatched byte: where the next sequence's literals start.
    anchor: usize,
    /// The scan position.
    ip: usize,
    params: Params,
    hash_long: []u32,
    hash_small: []u32,
    store: *Store,
    /// Repeated_Offset1 and Repeated_Offset2 (`§3.1.1.5`); the third is never
    /// selected by this finder and stays with the caller.
    rep1: u32,
    rep2: u32,

    /// The C's noDict scan (`zstd_double_fast.c:105-328`): an outer loop per
    /// match and an inner one per probe, the long and short candidates checked
    /// at the probe and the long one again at `ip + 1` when the short match
    /// wins. The labeled control flow is the C's `goto _match_stored` /
    /// `_search_next_long` / `_match_found` shape, kept whole on purpose (the
    /// house's `encodeBlock` precedent), over local scalars for the same
    /// reason the C is: the probe chain's state stays in registers.
    fn scanBlock(scan: *Scan, comptime mls: u4) void {
        const source = scan.source;
        const iend = scan.iend;
        const ilimit = scan.ilimit;
        const prefix_start = scan.prefix_start;
        const candidate_floor = scan.candidate_floor;
        const window_size = scan.window_size;
        const hash_log = scan.params.hash_log;
        const chain_log = scan.params.chain_log;
        const hash_long = scan.hash_long;
        const hash_small = scan.hash_small;
        const store = scan.store;
        assert(chain_log > 0);
        var ip = scan.ip;
        var anchor = scan.anchor;
        var rep1 = scan.rep1;
        var rep2 = scan.rep2;
        defer {
            scan.ip = ip;
            scan.anchor = anchor;
            scan.rep1 = rep1;
            scan.rep2 = rep2;
        }
        // The C's outer loop (`while (1)`): one iteration per match stored.
        // Its exits (`goto _cleanup`) end the block's scan, so they break the
        // labeled loop.
        scan_loop: while (true) {
            var step: usize = 1;
            var next_step: usize = ip + step_incr;
            var ip1 = ip + step;
            if (ip1 > ilimit) break :scan_loop; // `_cleanup`
            var hl0 = hashAt(source, ip, hash_log, 8);
            var idxl0: usize = hash_long[hl0];
            const matched: struct { found: Found, curr: usize } = match: {
                // The inner loop (`do ... while (ip1 <= ilimit)`).
                while (true) {
                    const hs0 = hashAt(source, ip, chain_log, mls);
                    const idxs0: usize = hash_small[hs0];
                    const curr = ip;
                    hash_long[hl0] = @intCast(curr);
                    hash_small[hs0] = @intCast(curr);
                    // The repcode pre-check at `ip + 1`
                    // (`zstd_double_fast.c:113-120`): a rep match one byte
                    // ahead of the probe stores immediately, with no backward
                    // extension and no rep shift.
                    if (rep1 > 0 and read32(source, ip + 1 - rep1) == read32(source, ip + 1)) {
                        const position = ip + 1;
                        const length = 4 + count(source, position + 4, position + 4 - rep1, iend);
                        ip = position;
                        break :match .{
                            .found = .{
                                .position = position,
                                .offset_value = repcode1_off_base,
                                .length = length,
                            },
                            .curr = curr,
                        };
                    }
                    const hl1 = hashAt(source, ip1, hash_log, 8);
                    // The long candidate at the probe (`:122-132`).
                    if (idxl0 >= candidate_floor and
                        read64(source, idxl0) == read64(source, ip))
                    {
                        const offset: u32 = @intCast(ip - idxl0);
                        var position = ip;
                        var match_position = idxl0;
                        var length = 8 + count(source, position + 8, match_position + 8, iend);
                        // The backward extension to the anchor and the
                        // candidate floor.
                        while (position > anchor and match_position > prefix_start and
                            source[position - 1] == source[match_position - 1])
                        {
                            position -= 1;
                            match_position -= 1;
                            length += 1;
                        }
                        rep2 = rep1;
                        rep1 = offset;
                        if (step < 4) hash_long[hl1] = @intCast(ip1);
                        ip = position;
                        break :match .{
                            .found = .{
                                .position = position,
                                .offset_value = offset + 3,
                                .length = length,
                            },
                            .curr = curr,
                        };
                    }
                    const idxl1: usize = hash_long[hl1];
                    // The short candidate at the probe (`:137-140`).
                    if (idxs0 >= candidate_floor and
                        read32(source, idxs0) == read32(source, ip))
                    {
                        // `_search_next_long` (`:143-165`): the short match is
                        // found; a long match at `ip + 1` that is longer
                        // replaces it.
                        var position = ip;
                        var match_position = idxs0;
                        var length = 4 + count(source, position + 4, match_position + 4, iend);
                        var offset: u32 = @intCast(ip - idxs0);
                        if (idxl1 > prefix_start and
                            read64(source, idxl1) == read64(source, ip1))
                        {
                            const long_length = 8 + count(source, ip1 + 8, idxl1 + 8, iend);
                            if (long_length > length) {
                                ip = ip1;
                                position = ip1;
                                match_position = idxl1;
                                length = long_length;
                                offset = @intCast(ip1 - idxl1);
                            }
                        }
                        while (position > anchor and match_position > prefix_start and
                            source[position - 1] == source[match_position - 1])
                        {
                            position -= 1;
                            match_position -= 1;
                            length += 1;
                        }
                        rep2 = rep1;
                        rep1 = offset;
                        if (step < 4) hash_long[hl1] = @intCast(ip1);
                        ip = position;
                        break :match .{
                            .found = .{
                                .position = position,
                                .offset_value = offset + 3,
                                .length = length,
                            },
                            .curr = curr,
                        };
                    }
                    // No match: advance the probe pair, growing the step
                    // every 256 unmatched bytes (`:183-193`).
                    if (ip1 >= next_step) {
                        step += 1;
                        next_step += step_incr;
                    }
                    ip = ip1;
                    ip1 += step;
                    hl0 = hl1;
                    idxl0 = idxl1;
                    // The C's `do ... while (ip1 <= ilimit)` exits to
                    // `_cleanup` (`:193-195`), which ends the scan.
                    if (ip1 > ilimit) break :scan_loop;
                }
            };
            // `_match_stored` (`:196-226`): store the sequence, then the
            // complementary insertion and the offset-2 chain.
            const found = matched.found;
            // RFC 8878 §3.1.1.4 — "all offsets leading to previously decoded
            // data must be smaller than Window_Size": the candidate floor and
            // the rep restore bound every emission.
            assert(ip - found.position < window_size or
                found.offset_value == repcode1_off_base);
            store.append(
                source,
                anchor,
                found.position,
                found.offset_value,
                @intCast(found.length),
            );
            ip = found.position + found.length;
            anchor = ip;
            if (ip <= ilimit) {
                // The complementary insertion (`:210-218`): both tables, at
                // the probe two bytes on and at the match's tail.
                const index_to_insert = matched.curr + 2;
                hash_long[hashAt(source, index_to_insert, hash_log, 8)] =
                    @intCast(index_to_insert);
                hash_long[hashAt(source, ip - 2, hash_log, 8)] = @intCast(ip - 2);
                hash_small[hashAt(source, index_to_insert, chain_log, mls)] =
                    @intCast(index_to_insert);
                hash_small[hashAt(source, ip - 1, chain_log, mls)] = @intCast(ip - 1);
                // `:220-232` — the offset-2 immediate-repeat chain: while
                // Repeated_Offset2 matches at the new position, emit
                // back-to-back zero-literal repcode sequences, swapping
                // rep1/rep2 each time (the decoder's §3.1.1.5 shift at
                // `literals_length == 0`).
                while (rep2 > 0 and ip <= ilimit and
                    read32(source, ip) == read32(source, ip - rep2))
                {
                    assert(rep2 < window_size);
                    const run_length = count(source, ip + 4, ip + 4 - rep2, iend) + 4;
                    const swap = rep1;
                    rep1 = rep2;
                    rep2 = swap;
                    hash_small[hashAt(source, ip, chain_log, mls)] = @intCast(ip);
                    hash_long[hashAt(source, ip, hash_log, 8)] = @intCast(ip);
                    store.append(source, anchor, ip, repcode1_off_base, @intCast(run_length));
                    ip += run_length;
                    anchor = ip;
                }
            }
        }
    }
};

/// Scan `source[block_start..][0..block_size]` with the dfast finder and fill
/// `store` with the block's token stream. `hash_long` and `hash_small` hold
/// one position per hash and must be zeroed; `rep` is the frame's
/// repeat-offset history (`§3.1.1.5`, seeded `{1, 4, 8}`), updated in place
/// with the block's final rep1/rep2.
///
/// The offsets' window bound and the candidate floor are the level-1
/// finder's (`match_compress.find`): a match may read any byte before the
/// block, never before `iend - (1 << window_log)`.
pub fn find(
    source: []const u8,
    block_start: usize,
    block_size: usize,
    params: Params,
    hash_long: []u32,
    hash_small: []u32,
    rep: *[3]u32,
    store: *Store,
) void {
    assert(block_size > 0);
    assert(block_start + block_size <= source.len);
    assert(hash_long.len == @as(usize, 1) << @intCast(params.hash_log));
    assert(hash_small.len == @as(usize, 1) << @intCast(params.chain_log));
    const iend = block_start + block_size;
    const window_size: usize = @as(usize, 1) << @intCast(params.window_log);
    // The block's prefix, derived from the block's END
    // (`ZSTD_getLowestPrefixIndex(ms, endIndex, windowLog)`,
    // `zstd_double_fast.c:101`): a start-derived prefix lets a block whose
    // end is past the window emit offsets above the declared Window_Size
    // (RFC 8878 §3.1.1.4).
    const prefix_start: usize = if (iend > window_size) iend - window_size else 0;
    var scan: Scan = .{
        .source = source,
        .iend = iend,
        .ilimit = if (iend >= hash_read_size) iend - hash_read_size else 0,
        .prefix_start = prefix_start,
        .candidate_floor = @max(prefix_start, 1),
        .window_size = window_size,
        // The C skips the frame's very first position (`ip += ((ip -
        // prefixLowest) == 0)`, `zstd_double_fast.c:136`): a match there has
        // no history.
        .ip = if (block_start == prefix_start) block_start + 1 else block_start,
        .anchor = block_start,
        .params = params,
        .hash_long = hash_long,
        .hash_small = hash_small,
        .store = store,
        .rep1 = rep[0],
        .rep2 = rep[1],
    };
    var offset_saved1: u32 = 0;
    var offset_saved2: u32 = 0;
    {
        // A rep that reaches before the prefix is invalid for this block and
        // is restored after it (`zstd_double_fast.c:139-146`), measured from
        // the scan's own window floor.
        const window_low: usize = if (scan.ip > window_size) scan.ip - window_size else 0;
        const max_rep: u32 = @intCast(scan.ip - window_low);
        if (scan.rep2 > max_rep) {
            offset_saved2 = scan.rep2;
            scan.rep2 = 0;
        }
        if (scan.rep1 > max_rep) {
            offset_saved1 = scan.rep1;
            scan.rep1 = 0;
        }
    }
    switch (params.mls) {
        4 => scan.scanBlock(4),
        5 => scan.scanBlock(5),
        6 => scan.scanBlock(6),
        7 => scan.scanBlock(7),
        else => unreachable,
    }
    // The restore rule (`zstd_double_fast.c:283-291`): the first valid rep
    // wins its slot, and an invalidated rep1 that became valid takes rep2's
    // saved value.
    offset_saved2 = if (offset_saved1 != 0 and scan.rep1 != 0) offset_saved1 else offset_saved2;
    rep[0] = if (scan.rep1 != 0) scan.rep1 else offset_saved1;
    rep[1] = if (scan.rep2 != 0) scan.rep2 else offset_saved2;
    store.appendTrailing(source, scan.anchor, iend);
}

/// The complementary insertion's four writes (`zstd_double_fast.c:210-218`,
/// `:483-489`, `:742-749`): the probe's two-byte tail and the match's last two
/// bytes into both tables. `probe` and `tail` are `source` positions;
/// `table_base` maps them into the table's own space — 0 for the scans whose
/// tables hold frame offsets, `dict.len` for the extDict scan, whose tables
/// hold virtual indices.
fn insertEdges(
    comptime mls: u4,
    source: []const u8,
    probe: usize,
    tail: usize,
    table_base: usize,
    params: Params,
    hash_long: []u32,
    hash_small: []u32,
) void {
    const index_to_insert = table_base + probe + 2;
    hash_long[hashAt(source, probe + 2, params.hash_log, 8)] = @intCast(index_to_insert);
    hash_long[hashAt(source, tail - 2, params.hash_log, 8)] = @intCast(table_base + tail - 2);
    hash_small[hashAt(source, probe + 2, params.chain_log, mls)] =
        @intCast(index_to_insert);
    hash_small[hashAt(source, tail - 1, params.chain_log, mls)] =
        @intCast(table_base + tail - 1);
}

/// The offset-2 immediate-repeat chain (`zstd_double_fast.c:220-232`,
/// `:492-508`, `:755-771`): while Repeated_Offset2 matches at the scan
/// position, emit back-to-back zero-literal repcode sequences, swapping
/// rep1/rep2 each time (the decoder's §3.1.1.5 shift at `literals_length ==
/// 0`), and insert the position into both tables. `table_base` maps the
/// slice positions into the tables' own space (0 for the frame-offset scans,
/// `dict.len` for the extDict one), `frame_start` maps them into the virtual
/// space `dict` is addressed in, `overlap_limit` is the region boundary the
/// rep's 4 bytes may not straddle, and `floor` the lowest addressable index.
fn chainRep(
    comptime mls: u4,
    source: []const u8,
    dict: []const u8,
    iend: usize,
    ilimit: usize,
    ip: *usize,
    anchor: *usize,
    rep1: *u32,
    rep2: *u32,
    table_base: usize,
    frame_start: usize,
    overlap_limit: usize,
    floor: usize,
    params: Params,
    hash_long: []u32,
    hash_small: []u32,
    store: *Store,
) void {
    const dict_len = dict.len;
    while (ip.* <= ilimit) {
        const current2 = table_base + ip.*;
        const rep_reachable = rep2.* > 0 and rep2.* <= current2;
        const rep_index2 = if (rep_reachable) current2 - rep2.* else 0;
        // The rep must land in the dictionary or in the frame's own decoded
        // bytes, above the floor and off the region boundary.
        const rep_holds = rep_reachable and
            (rep_index2 < dict_len or rep2.* <= ip.*) and
            rep_index2 >= floor and
            indexOverlapCheck(overlap_limit, rep_index2);
        if (!rep_holds or
            read32Virtual(dict, source, rep_index2, frame_start) != read32(source, ip.*))
        {
            break;
        }
        const run_length = 4 + if (rep_index2 < dict_len)
            countFromDict(source, dict, ip.* + 4, rep_index2 + 4, iend)
        else
            count(source, ip.* + 4, ip.* + 4 - rep2.*, iend);
        const swap = rep1.*;
        rep1.* = rep2.*;
        rep2.* = swap;
        hash_small[hashAt(source, ip.*, params.chain_log, mls)] =
            @intCast(table_base + ip.*);
        hash_long[hashAt(source, ip.*, params.hash_log, 8)] = @intCast(table_base + ip.*);
        store.append(source, anchor.*, ip.*, repcode1_off_base, @intCast(run_length));
        ip.* += run_length;
        anchor.* = ip.*;
    }
}

// ---------------------------------------------------------------------------
// The dictionary's match region (`zstd_double_fast.c:328-778`). A dictionary
// is virtual past, exactly as the level-1 finder's (`match_compress.zig`): the
// C keeps two shapes and the CLI picks between them by the pledged source size
// against `attachDictSizeCutoffs[dfast]` — 16 KB — the attach path below, the
// copy path (`findExtDict`) above it.
// ---------------------------------------------------------------------------

/// The C's CDict match tables for dfast (`ZSTD_fillDoubleHashTableForCDict`,
/// `zstd_double_fast.c:14-50`): the long (8-byte hash, `hashLog + 8` bits) and
/// small (`minMatch` hash, `chainLog + 8` bits) tables, each entry a content
/// position with its hash's 8-bit tag in the low bits (`ZSTD_writeTaggedIndex`).
/// The capacity is the level-3 rows' largest widths, 17 and 16; the
/// dictionary's own widths slice it.
pub const DictTables = struct {
    /// `(position << 8) | tag` per long hash, zeroed before the fill.
    long: [long_table_entries_max]u32,
    /// `(position << 8) | tag` per small hash, zeroed before the fill.
    small: [small_table_entries_max]u32,
    /// The dictionary's own long hash log: the table's index width, the tag's
    /// 8 bits on top.
    long_hash_log: u5,
    /// The dictionary's own small hash log.
    small_hash_log: u5,
    /// The dictionary's own hash width in bytes (its class's `minMatch`),
    /// which may differ from the frame's.
    mls: u3,

    /// The long table's live slice, `1 << long_hash_log` entries.
    pub fn longSlice(self: *DictTables) []u32 {
        return self.long[0 .. @as(usize, 1) << @intCast(self.long_hash_log)];
    }

    /// The long table's live slice, read-only.
    pub fn constLongSlice(self: *const DictTables) []const u32 {
        return self.long[0 .. @as(usize, 1) << @intCast(self.long_hash_log)];
    }

    /// The small table's live slice, `1 << small_hash_log` entries.
    pub fn smallSlice(self: *DictTables) []u32 {
        return self.small[0 .. @as(usize, 1) << @intCast(self.small_hash_log)];
    }

    /// The small table's live slice, read-only.
    pub fn constSmallSlice(self: *const DictTables) []const u32 {
        return self.small[0 .. @as(usize, 1) << @intCast(self.small_hash_log)];
    }
};

/// Fill the CDict's dfast tables over `content`
/// (`ZSTD_fillDoubleHashTableForCDict` with `ZSTD_dtlm_full`, the CLI's `-D`
/// path): every third position into both tables, positions 1 and 2 of each
/// step into the long table only while its slot is still empty. Positions
/// within the last 8 bytes are not hashed: the hash reads 8.
pub fn fillDictTables(tables: *DictTables, content: []const u8, params: DictParams) void {
    assert(params.hash_log <= 17);
    assert(params.chain_log <= 16);
    tables.long_hash_log = params.hash_log;
    tables.small_hash_log = params.chain_log;
    tables.mls = params.mls;
    const long = tables.longSlice();
    const small = tables.smallSlice();
    fastmem.set(u32, long, 0);
    fastmem.set(u32, small, 0);
    if (content.len <= hash_read_size) return;
    const long_bits: u5 = params.hash_log + short_cache_tag_bits;
    const small_bits: u5 = params.chain_log + short_cache_tag_bits;
    const loaded = maxLoadedContent(params);
    var position = if (content.len > loaded) content.len - loaded else 0;
    // `ip + fastHashFillStep - 1 <= iend` (`zstd_double_fast.c:37`): the last
    // step start whose positions 1 and 2 still leave a full 8-byte hash read.
    while (position + 2 <= content.len - hash_read_size) : (position += 3) {
        for (0..3) |offset| {
            const at = position + offset;
            const long_hash_and_tag = hashAtWidth(content, at, long_bits, 8);
            if (offset == 0) {
                writeTaggedIndex(small, hashAtWidth(content, at, small_bits, params.mls), at);
            }
            // "not yet filled": a zeroed slot, the C's own sentinel.
            if (offset == 0 or long[long_hash_and_tag >> short_cache_tag_bits] == 0) {
                writeTaggedIndex(long, long_hash_and_tag, at);
            }
        }
    }
}

/// The copy path's tables (`ZSTD_copyCDictTableIntoCCtx`,
/// `zstd_compress.c:2384-2397`): the dictionary's entries with their tags
/// stripped, so the frame's own scan sees plain positions.
pub fn copyDictTables(hash_long: []u32, hash_small: []u32, tables: *const DictTables) void {
    assert(hash_long.len == @as(usize, 1) << @intCast(tables.long_hash_log));
    assert(hash_small.len == @as(usize, 1) << @intCast(tables.small_hash_log));
    for (hash_long, tables.constLongSlice()) |*entry, tagged| {
        entry.* = tagged >> short_cache_tag_bits;
    }
    for (hash_small, tables.constSmallSlice()) |*entry, tagged| {
        entry.* = tagged >> short_cache_tag_bits;
    }
}

/// The dictionary's match region for dfast: the content (virtual past) and
/// the CDict's two tagged tables.
pub const DictRegion = struct {
    content: []const u8,
    tables: *const DictTables,

    /// The long table's candidate for the bytes at `source[position]`: the
    /// tag check, the content position 0 exclusion (`dictMatchL > dictStart`),
    /// and the hash's 8-byte width — which the fill used too. `null` when the
    /// slot is empty or its tag disagrees.
    inline fn candidateLong(region: DictRegion, source: []const u8, position: usize) ?usize {
        const tables = region.tables;
        const hash_bits: u5 = tables.long_hash_log + short_cache_tag_bits;
        const hash_and_tag = hashAtWidth(source, position, hash_bits, 8);
        const entry = tables.constLongSlice()[hash_and_tag >> short_cache_tag_bits];
        if (!tagsMatch(entry, hash_and_tag)) return null;
        const index = entry >> short_cache_tag_bits;
        if (index == 0) return null;
        return index;
    }

    /// The small table's candidate: as `candidateLong`, but hashed with the
    /// *frame's* `minMatch` (`zstd_double_fast.c:343`) while the table was
    /// filled with the CDict's own (`:26`) — the level-1 finder documents the
    /// same asymmetry.
    inline fn candidateSmall(
        region: DictRegion,
        source: []const u8,
        position: usize,
        mls: u4,
    ) ?usize {
        const tables = region.tables;
        const hash_bits: u5 = tables.small_hash_log + short_cache_tag_bits;
        const hash_and_tag = hashAtWidth(source, position, hash_bits, mls);
        const entry = tables.constSmallSlice()[hash_and_tag >> short_cache_tag_bits];
        if (!tagsMatch(entry, hash_and_tag)) return null;
        const index = entry >> short_cache_tag_bits;
        if (index == 0) return null;
        return index;
    }
};

/// `ZSTD_compressBlock_doubleFast_dictMatchState_generic`
/// (`zstd_double_fast.c:332-553`): the attach path — the dictionary as a
/// separate match state, its CDict tables consulted per position through
/// their tags, and a dictionary candidate taken only where the frame's own
/// table has none. The frame's own tables hold source positions with 0 as "no
/// candidate"; the probe advances by `((ip - anchor) >> kSearchStrength) + 1`,
/// not the noDict scan's probe pairs.
///
/// `frame_start` is the frame position of `source[0]`: 0 for the one-shot, the
/// writer's retained-history origin otherwise (see `match_compress.findDict`).
pub fn findDict(
    source: []const u8,
    block_start: usize,
    block_size: usize,
    params: Params,
    hash_long: []u32,
    hash_small: []u32,
    dict: DictRegion,
    frame_start: usize,
    rep: *[3]u32,
    store: *Store,
) void {
    const args: DictScanArgs = .{
        .source = source,
        .block_start = block_start,
        .block_size = block_size,
        .params = params,
        .hash_long = hash_long,
        .hash_small = hash_small,
        .dict = dict,
        .frame_start = frame_start,
        .rep = rep,
        .store = store,
    };
    switch (params.mls) {
        4 => scanDict(4, args),
        5 => scanDict(5, args),
        6 => scanDict(6, args),
        7 => scanDict(7, args),
        else => unreachable,
    }
}

/// The attach scan's arguments, grouped so the per-width dispatch stays one
/// line per instantiation (the C's `ZSTD_GEN_DFAST_FN` shape).
const DictScanArgs = struct {
    source: []const u8,
    block_start: usize,
    block_size: usize,
    params: Params,
    hash_long: []u32,
    hash_small: []u32,
    dict: DictRegion,
    frame_start: usize,
    rep: *[3]u32,
    store: *Store,
};

/// `findDict`'s scan, specialized on the frame's hash width.
fn scanDict(comptime mls: u4, args: DictScanArgs) void {
    const source = args.source;
    const block_start = args.block_start;
    const block_size = args.block_size;
    const params = args.params;
    const hash_long = args.hash_long;
    const hash_small = args.hash_small;
    const dict = args.dict;
    const frame_start = args.frame_start;
    const rep = args.rep;
    const store = args.store;
    assert(block_size > 0);
    assert(block_start + block_size <= source.len);
    assert(hash_long.len == @as(usize, 1) << @intCast(params.hash_log));
    assert(hash_small.len == @as(usize, 1) << @intCast(params.chain_log));
    const dict_len = dict.content.len;
    assert(dict_len > 0);
    const hash_log = params.hash_log;
    const chain_log = params.chain_log;
    const iend = block_start + block_size;
    const ilimit = if (iend >= hash_read_size) iend - hash_read_size else 0;
    // The frame's own tables hold *virtual* indices — the C's `curr = ip -
    // base`, whose base sits the dictionary's content in front of the frame —
    // so the frame's position 0 is a candidate like any other, exactly as
    // `ZSTD_compressBlock_doubleFast_dictMatchState_generic`'s
    // `matchIndexL >= prefixLowestIndex` reads it, and a zeroed slot still
    // means "never written".
    const window_size: usize = @as(usize, 1) << @intCast(params.window_log);
    const prefix_start: usize = if (iend > window_size) iend - window_size else 0;
    const virtual_offset = dict_len + frame_start;
    const virtual_prefix = virtual_offset + prefix_start;
    var ip = block_start;
    var anchor = block_start;
    var rep1 = rep[0];
    var rep2 = rep[1];
    // The C's `ip += (dictAndPrefixLength == 0)`: a match at the frame's very
    // first position has no history.
    if (virtual_offset + ip == 0) ip += 1;
    // The main search loop (`:361`): the C's `while (ip < ilimit)`, because
    // the repcode check reads `ip + 1`.
    while (ip < ilimit) {
        const curr = virtual_offset + ip;
        const probe = ip;
        const hl = hashAt(source, ip, hash_log, 8);
        const hs = hashAt(source, ip, chain_log, mls);
        const idxl: usize = hash_long[hl];
        const idxs: usize = hash_small[hs];
        const dict_long = dict.candidateLong(source, ip);
        const dict_small = dict.candidateSmall(source, ip, mls);
        hash_long[hl] = @intCast(curr);
        hash_small[hs] = @intCast(curr);
        var found: Found = undefined;
        matched: {
            // The repcode pre-check at `ip + 1` (`:349-357`).
            const rep_reachable = rep1 <= virtual_offset + ip + 1;
            const rep_index = if (rep_reachable) virtual_offset + ip + 1 - rep1 else 0;
            const rep_holds = rep_index < dict_len or rep1 <= ip + 1;
            if (rep1 > 0 and rep_reachable and rep_holds and
                indexOverlapCheck(dict_len, rep_index) and
                read32Virtual(dict.content, source, rep_index, frame_start) ==
                    read32(source, ip + 1))
            {
                const position = ip + 1;
                const length = 4 + if (rep_index < dict_len)
                    countFromDict(source, dict.content, position + 4, rep_index + 4, iend)
                else
                    count(source, position + 4, position + 4 - rep1, iend);
                ip = position;
                found = .{
                    .position = position,
                    .offset_value = repcode1_off_base,
                    .length = length,
                };
                break :matched;
            }
            // The long candidate at the probe (`:366-390`): the frame's own
            // table first (the C's `matchIndexL >= prefixLowestIndex`), the
            // dictionary's when its bytes do not match.
            if (idxl >= virtual_prefix and
                readVirtual64(dict.content, source, idxl, frame_start) == read64(source, ip))
            {
                const offset: u32 = @intCast(curr - idxl);
                const in_dict = idxl < dict_len;
                const floor = if (in_dict) 0 else virtual_prefix;
                var position = ip;
                var match_index = idxl;
                var length = 8 + countFromVirtual(
                    source,
                    dict.content,
                    ip + 8,
                    match_index + 8,
                    iend,
                    frame_start,
                );
                while (position > anchor and match_index > floor and
                    source[position - 1] ==
                        byteAtVirtual(dict.content, source, match_index - 1, frame_start))
                {
                    position -= 1;
                    match_index -= 1;
                    length += 1;
                }
                found = .{
                    .position = position,
                    .offset_value = offset + 3,
                    .length = length,
                };
                break :matched;
            }
            if (dict_long) |index| {
                if (index + 8 <= dict_len and
                    read64At(dict.content, source, index) == read64(source, ip))
                {
                    const offset: u32 = @intCast(curr - index);
                    var position = ip;
                    var content_position = index;
                    var length = 8 + countTwoSegments(
                        source,
                        ip + 8,
                        dict.content,
                        index + 8,
                        iend,
                        0,
                    );
                    while (position > anchor and content_position > 0 and
                        source[position - 1] == dict.content[content_position - 1])
                    {
                        position -= 1;
                        content_position -= 1;
                        length += 1;
                    }
                    found = .{
                        .position = position,
                        .offset_value = offset + 3,
                        .length = length,
                    };
                    break :matched;
                }
            }
            // The short candidate at the probe (`:392-405`): the frame's own
            // table first (the C's strict `> prefixLowestIndex`), the
            // dictionary's only when the frame's has no candidate at all —
            // the C's `else if`, not a fallback on the bytes' mismatch.
            var short_index: usize = 0;
            var short_in_dict = false;
            if (idxs > virtual_prefix) {
                if (readVirtual32(dict.content, source, idxs, frame_start) == read32(source, ip)) {
                    short_index = idxs;
                }
            } else if (dict_small) |index| {
                if (index + 4 <= dict_len and
                    read32(dict.content, index) == read32(source, ip))
                {
                    short_index = index;
                    short_in_dict = true;
                }
            }
            if (short_index != 0) {
                // `_search_next_long` (`:409-460`): a long match at `ip + 1`
                // is checked before the short match is explored.
                const hl3 = hashAt(source, ip + 1, hash_log, 8);
                const idxl3: usize = hash_long[hl3];
                const dict_long3 = dict.candidateLong(source, ip + 1);
                hash_long[hl3] = @intCast(curr + 1);
                var position = ip;
                var match_index = short_index;
                var in_dict = short_in_dict;
                var offset: u32 = 0;
                var length: usize = 0;
                if (idxl3 >= virtual_prefix and
                    readVirtual64(dict.content, source, idxl3, frame_start) ==
                        read64(source, ip + 1))
                {
                    length = 8 + countFromVirtual(
                        source,
                        dict.content,
                        ip + 9,
                        idxl3 + 8,
                        iend,
                        frame_start,
                    );
                    ip += 1;
                    position = ip;
                    match_index = idxl3;
                    in_dict = false;
                    offset = @intCast(ip + virtual_offset - idxl3);
                } else if (dict_long3) |index| {
                    if (index + 8 <= dict_len and
                        read64At(dict.content, source, index) == read64(source, ip + 1))
                    {
                        length = 8 + countTwoSegments(
                            source,
                            ip + 1 + 8,
                            dict.content,
                            index + 8,
                            iend,
                            0,
                        );
                        ip += 1;
                        position = ip;
                        match_index = index;
                        in_dict = true;
                        offset = @intCast(curr + 1 - index);
                    }
                }
                if (length == 0) {
                    // No long +1 match: explore the short match found.
                    if (in_dict) {
                        length = 4 + countTwoSegments(
                            source,
                            ip + 4,
                            dict.content,
                            match_index + 4,
                            iend,
                            0,
                        );
                        offset = @intCast(curr - match_index);
                    } else {
                        length = 4 + countFromVirtual(
                            source,
                            dict.content,
                            ip + 4,
                            match_index + 4,
                            iend,
                            frame_start,
                        );
                        offset = @intCast(curr - match_index);
                    }
                }
                const floor = if (in_dict) 0 else virtual_prefix;
                while (position > anchor and match_index > floor and
                    source[position - 1] ==
                        byteAtVirtual(dict.content, source, match_index - 1, frame_start))
                {
                    position -= 1;
                    match_index -= 1;
                    length += 1;
                }
                found = .{
                    .position = position,
                    .offset_value = offset + 3,
                    .length = length,
                };
                break :matched;
            }
            // No candidate matched: the probe advances by the C's
            // `((ip - anchor) >> kSearchStrength) + 1` (`:407-410`).
            ip += ((ip - anchor) >> search_strength) + 1;
            continue;
        }
        // `_match_found` + `_match_stored` (`:462-508`).
        if (found.offset_value > 3) {
            rep2 = rep1;
            rep1 = found.offset_value - 3;
        }
        store.append(source, anchor, found.position, found.offset_value, @intCast(found.length));
        ip = found.position + found.length;
        anchor = ip;
        if (ip <= ilimit) {
            insertEdges(mls, source, probe, ip, virtual_offset, params, hash_long, hash_small);
            chainRep(
                mls,
                source,
                dict.content,
                iend,
                ilimit,
                &ip,
                &anchor,
                &rep1,
                &rep2,
                virtual_offset,
                frame_start,
                virtual_prefix,
                0,
                params,
                hash_long,
                hash_small,
                store,
            );
        }
    }
    store.appendTrailing(source, anchor, iend);
    rep[0] = rep1;
    rep[1] = rep2;
}

/// `ZSTD_compressBlock_doubleFast_extDict_generic`
/// (`zstd_double_fast.c:589-778`): the copy path — the dictionary's tables
/// copied into the frame's own (tags stripped) and the content run as the
/// window's extDict, with every read split across the two regions.
/// `prefix_start_index` is the C's `prefixStartIndex` (the virtual index where
/// the source begins, which rises with the window floor) and
/// `dict_start_index` its `ZSTD_getLowestMatchIndex`: the lowest table entry
/// that may be a candidate, which rises once the frame's output passes the
/// window and the dictionary stops being addressable (`§5`,
/// `zstd_compress_internal.h:1099-1145`).
pub fn findExtDict(
    source: []const u8,
    block_start: usize,
    block_size: usize,
    params: Params,
    hash_long: []u32,
    hash_small: []u32,
    dict: []const u8,
    prefix_start_index: usize,
    dict_start_index: usize,
    rep: *[3]u32,
    store: *Store,
) void {
    const args: ExtScanArgs = .{
        .source = source,
        .block_start = block_start,
        .block_size = block_size,
        .params = params,
        .hash_long = hash_long,
        .hash_small = hash_small,
        .dict = dict,
        .prefix_start_index = prefix_start_index,
        .dict_start_index = dict_start_index,
        .rep = rep,
        .store = store,
    };
    switch (params.mls) {
        4 => scanExt(4, args),
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
    hash_long: []u32,
    hash_small: []u32,
    dict: []const u8,
    prefix_start_index: usize,
    dict_start_index: usize,
    rep: *[3]u32,
    store: *Store,
};

/// `findExtDict`'s scan, specialized on the frame's hash width.
fn scanExt(comptime mls: u4, args: ExtScanArgs) void {
    const source = args.source;
    const block_start = args.block_start;
    const block_size = args.block_size;
    const params = args.params;
    const hash_long = args.hash_long;
    const hash_small = args.hash_small;
    const dict = args.dict;
    const prefix_start_index = args.prefix_start_index;
    const dict_start_index = args.dict_start_index;
    const rep = args.rep;
    const store = args.store;
    assert(block_size > 0);
    assert(block_start + block_size <= source.len);
    assert(hash_long.len == @as(usize, 1) << @intCast(params.hash_log));
    assert(hash_small.len == @as(usize, 1) << @intCast(params.chain_log));
    assert(dict.len > 0);
    assert(prefix_start_index >= dict.len);
    // `dict_start_index` can sit above `prefix_start_index` once the window
    // has slid past the dictionary: every dictionary entry is then below the
    // floor and only the frame's own positions are candidates.
    const hash_log = params.hash_log;
    const chain_log = params.chain_log;
    const iend = block_start + block_size;
    const ilimit = if (iend >= hash_read_size) iend - hash_read_size else 0;
    // The virtual index of `source[p]`: the dictionary's content is below it.
    const virtual_offset = dict.len;
    var ip = block_start;
    var anchor = block_start;
    var rep1 = rep[0];
    var rep2 = rep[1];
    // The C's `while (ip < ilimit)`, because the repcode check reads `ip + 1`.
    while (ip < ilimit) {
        const curr = virtual_offset + ip;
        const hs = hashAt(source, ip, chain_log, mls);
        const hl = hashAt(source, ip, hash_log, 8);
        const match_index: usize = hash_small[hs];
        const match_long_index: usize = hash_long[hl];
        hash_small[hs] = @intCast(curr);
        hash_long[hl] = @intCast(curr);
        const probe = ip;
        var found: Found = undefined;
        matched: {
            // The repcode pre-check at `ip + 1` (`:617-627`): the C's
            // `ZSTD_index_overlap_check(prefixStartIndex, repIndex) &
            // (offset_1 <= curr+1 - dictStartIndex)`.
            const rep_reaches = rep1 > 0 and curr >= dict_start_index and
                rep1 <= curr + 1 - dict_start_index;
            const rep_index = if (rep_reaches) curr + 1 - rep1 else 0;
            if (rep_reaches and indexOverlapCheck(prefix_start_index, rep_index) and
                read32Virtual(dict, source, rep_index, 0) == read32(source, ip + 1))
            {
                const position = ip + 1;
                const length = 4 + if (rep_index < dict.len)
                    countFromDict(source, dict, position + 4, rep_index + 4, iend)
                else
                    count(source, position + 4, position + 4 - rep1, iend);
                ip = position;
                found = .{
                    .position = position,
                    .offset_value = repcode1_off_base,
                    .length = length,
                };
                break :matched;
            }
            // The long candidate at the probe (`:629-641`).
            if (match_long_index > dict_start_index and
                readVirtual64(dict, source, match_long_index, 0) == read64(source, ip))
            {
                const in_dict = match_long_index < dict.len;
                const low_match = if (in_dict) dict_start_index else prefix_start_index;
                const offset: u32 = @intCast(curr - match_long_index);
                var position = ip;
                var match_position = match_long_index;
                var length = 8 + countFromVirtual(
                    source,
                    dict,
                    ip + 8,
                    match_long_index + 8,
                    iend,
                    0,
                );
                while (position > anchor and match_position > low_match and
                    source[position - 1] ==
                        (if (in_dict)
                            dict[match_position - 1]
                        else
                            source[match_position - dict.len - 1]))
                {
                    position -= 1;
                    match_position -= 1;
                    length += 1;
                }
                found = .{
                    .position = position,
                    .offset_value = offset + 3,
                    .length = length,
                };
                break :matched;
            }
            // The short candidate at the probe, then the long one at `ip + 1`
            // (`:642-673`).
            if (match_index > dict_start_index and
                readVirtual32(dict, source, match_index, 0) == read32(source, ip))
            {
                const hl3 = hashAt(source, ip + 1, hash_log, 8);
                const match_index3: usize = hash_long[hl3];
                hash_long[hl3] = @intCast(curr + 1);
                var position = ip;
                var match_position = match_index;
                var offset: u32 = 0;
                var length: usize = 0;
                if (match_index3 > dict_start_index and
                    readVirtual64(dict, source, match_index3, 0) == read64(source, ip + 1))
                {
                    length = 8 + countFromVirtual(
                        source,
                        dict,
                        ip + 9,
                        match_index3 + 8,
                        iend,
                        0,
                    );
                    ip += 1;
                    position = ip;
                    match_position = match_index3;
                    offset = @intCast(curr + 1 - match_index3);
                } else {
                    length = 4 + countFromVirtual(source, dict, ip + 4, match_index + 4, iend, 0);
                    offset = @intCast(curr - match_index);
                }
                const in_dict = match_position < dict.len;
                const low_match = if (in_dict) dict_start_index else prefix_start_index;
                while (position > anchor and match_position > low_match and
                    source[position - 1] ==
                        (if (in_dict)
                            dict[match_position - 1]
                        else
                            source[match_position - dict.len - 1]))
                {
                    position -= 1;
                    match_position -= 1;
                    length += 1;
                }
                found = .{
                    .position = position,
                    .offset_value = offset + 3,
                    .length = length,
                };
                break :matched;
            }
            // No candidate matched: the probe advances by the C's
            // `((ip - anchor) >> kSearchStrength) + 1` (`:674-677`).
            ip += ((ip - anchor) >> search_strength) + 1;
            continue;
        }
        // `_match_found` + `_match_stored` (`:679-712`).
        if (found.offset_value > 3) {
            rep2 = rep1;
            rep1 = found.offset_value - 3;
        }
        store.append(source, anchor, found.position, found.offset_value, @intCast(found.length));
        ip = found.position + found.length;
        anchor = ip;
        if (ip <= ilimit) {
            insertEdges(mls, source, probe, ip, virtual_offset, params, hash_long, hash_small);
            chainRep(
                mls,
                source,
                dict,
                iend,
                ilimit,
                &ip,
                &anchor,
                &rep1,
                &rep2,
                virtual_offset,
                0,
                prefix_start_index,
                dict_start_index,
                params,
                hash_long,
                hash_small,
                store,
            );
        }
    }
    store.appendTrailing(source, anchor, iend);
    rep[0] = rep1;
    rep[1] = rep2;
}

/// The 4 bytes at a virtual index, where the dictionary's content is below
/// `dict.len` and `source[frame_start]` names virtual `dict.len + frame_start`.
/// The callers keep every index inside one region.
inline fn readVirtual32(
    dict: []const u8,
    source: []const u8,
    index: usize,
    frame_start: usize,
) u32 {
    if (index < dict.len) {
        assert(index + 4 <= dict.len);
        return read32(dict, index);
    }
    assert(index - dict.len - frame_start + 4 <= source.len);
    return read32(source, index - dict.len - frame_start);
}

/// The 8 bytes at a virtual index; the caller keeps the read inside one
/// region.
inline fn readVirtual64(
    dict: []const u8,
    source: []const u8,
    index: usize,
    frame_start: usize,
) u64 {
    if (index < dict.len) {
        assert(index + 8 <= dict.len);
        return read64(dict, index);
    }
    assert(index - dict.len - frame_start + 8 <= source.len);
    return read64(source, index - dict.len - frame_start);
}

/// The byte at a virtual index.
inline fn byteAtVirtual(
    dict: []const u8,
    source: []const u8,
    index: usize,
    frame_start: usize,
) u8 {
    if (index < dict.len) return dict[index];
    return source[index - dict.len - frame_start];
}

/// `ZSTD_count_2segments` over a virtual start: the match begins at virtual
/// index `match_index` (in the dictionary or the source) and the source
/// position `ip_start` is the first byte to compare, up to `iend`. A match
/// that runs off the dictionary's end continues at the frame's own start —
/// the decoder's `copyMatchDict` wrap.
fn countFromVirtual(
    source: []const u8,
    dict: []const u8,
    ip_start: usize,
    match_index: usize,
    iend: usize,
    frame_start: usize,
) usize {
    if (match_index >= dict.len) {
        return count(source, ip_start, match_index - dict.len - frame_start, iend);
    }
    return countTwoSegments(source, ip_start, dict, match_index, iend, 0);
}

/// The forward length of a match whose bytes begin in the dictionary at
/// `dict_match` (the C's `ZSTD_count_2segments` call sites): a dictionary
/// match that runs off the content's end continues at the frame's own start —
/// the decoder's `copyMatchDict` wrap — so the continuation counts against
/// `source[0]`, never against a source position a dictionary index would
/// alias.
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

// ---------------------------------------------------------------------------
// Tests. Spec: docs/specs/rfc8878-zstd.txt §3.1.1.3.2.1 (the
// sequences a token stream must carry), §3.1.1.4 (offsets), §3.1.1.5 (the
// repeat offsets). Every token stream is executed by the shared test decoder
// (`match_compress.expectTokensReproduce`) and must reproduce the block byte
// for byte; the CLI byte pins live one layer up, in `encode.zig`'s fixtures.
// ---------------------------------------------------------------------------

/// Scan a block with the dfast finder and check the token stream reproduces
/// it. The tables are sized from the parameters, the way the callers slice
/// them.
fn expectFind(source: []const u8, params: Params, rep_seed: [3]u32, block_start: usize) !void {
    var hash_long: [long_table_entries_max]u32 = @splat(0);
    var hash_small: [small_table_entries_max]u32 = @splat(0);
    try testing.expect(params.hash_log <= 17);
    try testing.expect(params.chain_log <= 16);
    var literals: [256 * 1024]u8 = undefined;
    var sequence_buffer: [256 * 1024 / 4 + 1]sequences_compress.Sequence = undefined;
    var store: Store = .init(&literals, &sequence_buffer);
    var rep = rep_seed;
    find(
        source,
        block_start,
        source.len - block_start,
        params,
        hash_long[0 .. @as(usize, 1) << @intCast(params.hash_log)],
        hash_small[0 .. @as(usize, 1) << @intCast(params.chain_log)],
        &rep,
        &store,
    );
    try match_compress.expectTokensReproduce(
        source,
        block_start,
        source.len - block_start,
        params.window_log,
        &store,
        rep_seed,
    );
}

test "the dfast finder emits sequences that reproduce the block" {
    // RFC 8878 §3.1.1.4 — a sequence copies its literals then its match at
    // the offset; the streams the dfast scan emits must reproduce the block
    // exactly, for every `mls` the level-3 rows take (4, 5, 6, 7) and for a
    // block in the middle of a frame (the prefix bound and the rep
    // invalidation both apply).
    const params: Params = .{
        .level = 3,
        .window_log = 17,
        .hash_log = 13,
        .chain_log = 12,
        .mls = 6,
    };
    var rng: DefaultPrng = .init(0xD0FA57);
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
        for ([_]u3{ 4, 5, 6, 7 }) |mls| {
            var scan_params = params;
            scan_params.mls = mls;
            try expectFind(source[0..length], scan_params, .{ 1, 4, 8 }, 0);
        }
    }
    // A block in the middle of a frame: the prefix bound and the rep
    // invalidation both apply.
    try expectFind(&source, params, .{ 1, 4, 8 }, 64 * 1024);
    try expectFind(&source, params, .{ 100, 40000, 8 }, 64 * 1024);
}

test "the level-3 rows carry the class's widths" {
    // `clevels.h`'s level-3 rows through `ZSTD_adjustCParams_internal`: the
    // four size classes, the window's shrink to the source, the hash and
    // chain clamps to that window, and the floor at 10. The chain log is the
    // level's addition to the level-1 `Params`.
    const small = Params.forSource(3, 100);
    try testing.expectEqual(@as(u6, 10), small.window_log);
    try testing.expectEqual(@as(u6, 8), small.hash_log);
    try testing.expectEqual(@as(u6, 7), small.chain_log);
    try testing.expectEqual(@as(u3, 4), small.mls);
    const mid = Params.forSource(3, 32768);
    try testing.expectEqual(@as(u6, 15), mid.window_log);
    try testing.expectEqual(@as(u6, 16), mid.hash_log);
    try testing.expectEqual(@as(u6, 15), mid.chain_log);
    try testing.expectEqual(@as(u3, 5), mid.mls);
    const medium = Params.forSource(3, 200000);
    try testing.expectEqual(@as(u6, 18), medium.window_log);
    try testing.expectEqual(@as(u6, 16), medium.hash_log);
    try testing.expectEqual(@as(u6, 16), medium.chain_log);
    try testing.expectEqual(@as(u3, 4), medium.mls);
    const big = Params.forSource(3, 600000);
    try testing.expectEqual(@as(u6, 20), big.window_log);
    try testing.expectEqual(@as(u6, 17), big.hash_log);
    try testing.expectEqual(@as(u6, 16), big.chain_log);
    try testing.expectEqual(@as(u3, 5), big.mls);
    // The attach cutoff follows the strategy: 8 KB at level 1, 16 KB at
    // level 3 (`attachDictSizeCutoffs`).
    try testing.expectEqual(@as(usize, 8 * 1024), match_compress.attachCutoff(1));
    try testing.expectEqual(@as(usize, 16 * 1024), match_compress.attachCutoff(3));
}
