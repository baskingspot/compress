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
//! Positions are frame offsets, and the caller owns the table (it must be
//! zeroed and sized `1 << hashLog`) and the reps. A rep outside the block's
//! addressable prefix is zeroed for the block and restored after, so the
//! emitted history stays decodable (`§3.1.1.4`).
//!
//! Format: docs/research/specs/rfc8878-zstd.txt §3.1.1.4 (offsets), §3.1.1.5
//! (the repeat offsets).

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const common = @import("common.zig");
const readInt = common.readInt;
const sequences = @import("sequences.zig");
const sequences_compress = @import("sequences_compress.zig");
/// `§3.1.1.3.2.1.1` — the shortest match a sequence can carry (Table 17's
/// code 0 baseline). The finder's 4-byte verification keeps every match at
/// or above this.
pub const min_match_length: u32 = sequences_compress.min_match_length;

/// `ZSTD_hash5`'s prime (`zstd_compress_internal.h:933`).
const prime5bytes: u64 = 889523592379;
/// `ZSTD_hash6`'s prime (`zstd_compress_internal.h:936`).
const prime6bytes: u64 = 227718039650203;
/// `ZSTD_hash7`'s prime (`zstd_compress_internal.h:939`).
const prime7bytes: u64 = 58295818150454627;

/// `HASH_READ_SIZE` (`zstd_compress_internal.h:33`): the bytes a hash reads
/// and the scan loop's trailing margin.
const hash_read_size: usize = 8;

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
    /// The frame's Window_Log (`§3.1.1.1.2`): the finder's reach.
    window_log: u6,
    /// The position table's width: `min(hashLog, windowLog + 1)`
    /// (`zstd_compress.c:1564`).
    hash_log: u6,
    /// The hash width in bytes — 5, 6, or 7 by the size class (the C's
    /// `minMatch`, `clevels.h`).
    mls: u3,

    /// The C's level-1 ladder for a one-shot with a known source size: the
    /// size class picks (windowLog, hashLog, minMatch) from `clevels.h`'s
    /// level-1 rows, then `ZSTD_adjustCParams_internal`
    /// (`zstd_compress.c:1473-1586`) clamps the window to the next power of
    /// two covering the source (floor 10) and the hash to `windowLog + 1`.
    pub fn forSource(source_len: usize) Params {
        // `ZSTD_getCParams_internal` (`zstd_compress.c:7759-7780`): the
        // class is `(rSize <= 256 KB) + (rSize <= 128 KB) + (rSize <= 16
        // KB)`, and level 1 is `ZSTD_fast` in every class.
        const window_log_class: u6 = if (source_len > 256 * 1024)
            19
        else if (source_len > 128 * 1024)
            18
        else if (source_len > 16 * 1024)
            17
        else
            14;
        const hash_log_class: u6 = if (source_len > 128 * 1024)
            14
        else if (source_len > 16 * 1024)
            13
        else
            15;
        // `mls` per the class: 5 under 16 KB, 6 up to 256 KB, 7 above
        // (`clevels.h`'s `L` column). The ≤ 16-KB class's 5 is what the C
        // uses, and it is the difference between the CLI's bytes and a
        // near-miss on inputs under 16 KB.
        const mls: u3 = if (source_len > 256 * 1024)
            7
        else if (source_len > 16 * 1024)
            6
        else
            5;
        const window_log = @max(@min(window_log_class, nextPow2Log(source_len)), 10);
        return .{
            .window_log = window_log,
            .hash_log = @min(hash_log_class, window_log + 1),
            .mls = mls,
        };
    }
};

/// `ZSTD_highbit32(srcSize - 1) + 1` (`zstd_compress.c:1557-1558`): the
/// smallest power-of-two window log that covers `source_len`, floor 6 (the
/// C's `ZSTD_HASHLOG_MIN`).
fn nextPow2Log(source_len: usize) u6 {
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
    literals_len: usize = 0,
    sequence_count: usize = 0,

    /// Append one sequence: its `literals_length` literals from
    /// `source[anchor..position]`, then the match.
    fn append(
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
    fn appendTrailing(store: *Store, source: []const u8, anchor: usize, iend: usize) void {
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
/// `source` is the frame's bytes, so a match may read any byte before the
/// block — but only the `1 << window_log` bytes in front of it, and never
/// before `block_start - (1 << window_log)`: the finder's candidates and
/// reps are bounded by that prefix, so an emitted offset always addresses
/// retained history (`§3.1.1.4`).
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
    // address (`ZSTD_getLowestPrefixIndex`, `zstd_compress_internal.h:1390`).
    const prefix_start: usize = if (block_start > window_size) block_start - window_size else 0;
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
        // is restored after it (`zstd_fast.c:238-243,355-372`).
        const max_rep: u32 = @intCast(scan.ip0 - prefix_start);
        if (scan.rep2 > max_rep) {
            offset_saved2 = scan.rep2;
            scan.rep2 = 0;
        }
        if (scan.rep1 > max_rep) {
            offset_saved1 = scan.rep1;
            scan.rep1 = 0;
        }
    }
    scan.scanBlock();
    // The restore rule (`zstd_fast.c:355-372`): the first valid rep wins its
    // slot, and an invalidated rep1 that became valid takes rep2's saved
    // value.
    offset_saved2 = if (offset_saved1 != 0 and scan.rep1 != 0) offset_saved1 else offset_saved2;
    rep[0] = if (scan.rep1 != 0) scan.rep1 else offset_saved1;
    rep[1] = if (scan.rep2 != 0) scan.rep2 else offset_saved2;
    store.appendTrailing(source, scan.anchor, iend);
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

    /// The C's pipelined scan (`zstd_fast.c:255-353`): positions advance in
    /// adjacent pairs, and the step between pairs grows by one every 128
    /// unmatched bytes. The labeled control flow is the C's `goto _start` /
    /// `goto _offset` / `goto _match` shape, kept whole on purpose (the
    /// house's `encodeBlock` precedent).
    fn scanBlock(scan: *Scan) void {
        const source = scan.source;
        const hash_table = scan.hash_table;
        scan_loop: while (true) {
            var step: usize = step_size;
            var next_step: usize = scan.ip0 + step_incr;
            var ip1 = scan.ip0 + 1;
            var ip2 = scan.ip0 + step;
            var ip3 = ip2 + 1;
            if (ip3 >= scan.ilimit) break :scan_loop;
            var hash0 = hashAt(source, scan.ip0, scan.params);
            var hash1 = hashAt(source, ip1, scan.params);
            var match_index: usize = hash_table[hash0];
            inner: while (true) {
                // The repcode pre-check at ip2: Repeated_Offset1 two bytes
                // ahead beats the table candidate at ip0.
                const rep_value = read32(source, ip2 - scan.rep1);
                scan.current0 = scan.ip0;
                hash_table[hash0] = @intCast(scan.ip0);
                if (scan.rep1 > 0 and read32(source, ip2) == rep_value) {
                    scan.ip0 = ip2;
                    var match_position = scan.ip0 - scan.rep1;
                    var base_length: usize = 4;
                    // One byte of backward extension at most, which stops at
                    // anchor + 1: the sequence keeps its literals.
                    if (source[scan.ip0 - 1] == source[match_position - 1]) {
                        scan.ip0 -= 1;
                        match_position -= 1;
                        base_length += 1;
                    }
                    hash_table[hash1] = @intCast(ip1);
                    scan.emitMatch(match_position, repcode1_off_base, base_length);
                    continue :scan_loop;
                }
                if (match4Found(source, scan.ip0, match_index, scan.candidate_floor)) {
                    hash_table[hash1] = @intCast(ip1);
                    scan.matchAt(match_index);
                    continue :scan_loop;
                }
                // The pair's second half: ip0 moves to ip1.
                match_index = hash_table[hash1];
                hash0 = hash1;
                hash1 = hashAt(source, ip2, scan.params);
                scan.ip0 = ip1;
                ip1 = ip2;
                ip2 = ip3;
                scan.current0 = scan.ip0;
                hash_table[hash0] = @intCast(scan.ip0);
                if (match4Found(source, scan.ip0, match_index, scan.candidate_floor)) {
                    // "Avoid writing an index if it's >= position where
                    // search will resume": a match is at least 4 bytes, so
                    // the scan resumes at ip0 + 4 (`zstd_fast.c:314-320`).
                    if (step <= 4) hash_table[hash1] = @intCast(ip1);
                    scan.matchAt(match_index);
                    continue :scan_loop;
                }
                match_index = hash_table[hash1];
                hash0 = hash1;
                hash1 = hashAt(source, ip2, scan.params);
                scan.ip0 = ip1;
                ip1 = ip2;
                ip2 = scan.ip0 + step;
                ip3 = ip1 + step;
                if (ip2 >= next_step) {
                    step += 1;
                    next_step += step_incr;
                }
                if (ip3 >= scan.ilimit) break :inner;
            }
        }
    }

    /// `_offset` (`zstd_fast.c:389-401`): a literal-offset match. The reps
    /// shift, the match extends backward to the anchor and the prefix, and
    /// the forward count closes it.
    fn matchAt(scan: *Scan, match_position: usize) void {
        // The table only ever holds positions the scan has passed, so a
        // candidate is always behind the current position: one table per
        // frame, blocks scanned in order.
        assert(match_position < scan.ip0);
        const offset: u32 = @intCast(scan.ip0 - match_position);
        scan.rep2 = scan.rep1;
        scan.rep1 = offset;
        var match = match_position;
        var base_length: usize = 4;
        while (scan.ip0 > scan.anchor and match > scan.prefix_start and
            scan.source[scan.ip0 - 1] == scan.source[match - 1])
        {
            scan.ip0 -= 1;
            match -= 1;
            base_length += 1;
        }
        scan.emitMatch(match, offset + 3, base_length);
    }

    /// `_match` (`zstd_fast.c:402-420`): count the forward length, store the
    /// sequence, refill the table at the match's edges, and drain the
    /// offset-2 chain. `scan.ip0` and `match_position` already include the
    /// backward extension, and `base_length` is the bytes it counted.
    fn emitMatch(scan: *Scan, match_position: usize, offset_value: u32, base_length: usize) void {
        const source = scan.source;
        const match_length = base_length + count(
            source,
            scan.ip0 + base_length,
            match_position + base_length,
            scan.iend,
        );
        assert(match_length >= 4);
        scan.store.append(
            source,
            scan.anchor,
            scan.ip0,
            offset_value,
            @intCast(match_length),
        );
        scan.ip0 += match_length;
        scan.anchor = scan.ip0;
        if (scan.ip0 <= scan.ilimit) {
            // Fill the table at the match's edges (`zstd_fast.c:404-408`):
            // the last position written before the match, two bytes on, and
            // the position two before the new scan start.
            const current = scan.current0;
            scan.hash_table[hashAt(source, current + 2, scan.params)] = @intCast(current + 2);
            scan.hash_table[hashAt(source, scan.ip0 - 2, scan.params)] = @intCast(scan.ip0 - 2);
            scan.drainChain();
        }
    }

    /// `zstd_fast.c:410-420` — the offset-2 immediate-repeat chain: while
    /// Repeated_Offset2 matches at the new position, emit back-to-back
    /// zero-literal repcode sequences, swapping rep1/rep2 each time (the
    /// swap is the decoder's `§3.1.1.5` shift at `literals_length == 0`).
    fn drainChain(scan: *Scan) void {
        const source = scan.source;
        while (scan.rep2 > 0 and scan.ip0 <= scan.ilimit and
            read32(source, scan.ip0) == read32(source, scan.ip0 - scan.rep2))
        {
            const run_length = count(
                source,
                scan.ip0 + 4,
                scan.ip0 + 4 - scan.rep2,
                scan.iend,
            ) + 4;
            const swap = scan.rep1;
            scan.rep1 = scan.rep2;
            scan.rep2 = swap;
            scan.hash_table[hashAt(source, scan.ip0, scan.params)] = @intCast(scan.ip0);
            scan.store.append(
                source,
                scan.anchor,
                scan.ip0,
                repcode1_off_base,
                @intCast(run_length),
            );
            scan.ip0 += run_length;
            scan.anchor = scan.ip0;
        }
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
/// keeping the top `hash_log` bits.
inline fn hashAt(source: []const u8, position: usize, params: Params) usize {
    assert(position + hash_read_size <= source.len);
    const word = readInt(u64, source[position..][0..8]);
    const shift: u6 = @intCast(64 - @as(u7, params.hash_log));
    return switch (params.mls) {
        5 => @intCast(((word << 24) *% prime5bytes) >> shift),
        6 => @intCast(((word << 16) *% prime6bytes) >> shift),
        7 => @intCast(((word << 8) *% prime7bytes) >> shift),
        else => unreachable,
    };
}

/// A 4-byte read, the C's `MEM_read32`. The caller keeps the 4-byte margin.
inline fn read32(source: []const u8, position: usize) u32 {
    assert(position + 4 <= source.len);
    return readInt(u32, source[position..][0..4]);
}

/// `ZSTD_count` (`zstd_compress_internal.h:854-875`): the common bytes
/// between `current` and `match` up to `iend`, eight at a time with the
/// word-XOR machinery the flate finder uses, then the 4/2/1-byte tail.
/// `match < current` and both reads stay inside `iend`.
fn count(source: []const u8, current_start: usize, match_start: usize, iend: usize) usize {
    var current = current_start;
    var match = match_start;
    while (current + 8 <= iend) {
        const difference = readInt(u64, source[current..][0..8]) ^
            readInt(u64, source[match..][0..8]);
        if (difference != 0) return current - current_start + (@ctz(difference) >> 3);
        current += 8;
        match += 8;
    }
    if (current + 4 <= iend and read32(source, current) == read32(source, match)) {
        current += 4;
        match += 4;
    }
    if (current + 2 <= iend and
        readInt(u16, source[current..][0..2]) == readInt(u16, source[match..][0..2]))
    {
        current += 2;
        match += 2;
    }
    if (current < iend and source[current] == source[match]) current += 1;
    return current - current_start;
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc8878-zstd.txt §3.1.1.3.2.1 (the
// sequences a token stream must carry), §3.1.1.4 (offsets), §3.1.1.5 (the
// repeat offsets). Every token stream is executed by the test's own decoder
// — the §3.1.1.4/§3.1.1.5 rules, independent of the finder — and must
// reproduce the block byte for byte.
// ---------------------------------------------------------------------------

/// Execute a token stream the way `§3.1.1.4` says: literals first, then the
/// match at the resolved offset, whose copy may overlap the bytes it writes
/// (the copy reads bytes this execution has already written). Proves the
/// stream is a faithful encoding of the block, offsets and all.
fn expectTokensReproduce(
    source: []const u8,
    block_start: usize,
    block_size: usize,
    window_log: u6,
    store: *const Store,
    rep_seed: [3]u32,
) !void {
    const iend = block_start + block_size;
    const window_size: usize = @as(usize, 1) << @intCast(window_log);
    const prefix_start: usize = if (block_start > window_size) block_start - window_size else 0;
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
        // after the block's prefix.
        try testing.expect(offset <= position - prefix_start);
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
    var store: Store = .{ .literals = &literals, .sequences = &sequence_buffer };
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
    const params: Params = .{ .window_log = 17, .hash_log = 13, .mls = 6 };
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
    const params: Params = .{ .window_log = 10, .hash_log = 11, .mls = 6 };
    var hash_table: [1 << 11]u32 = @splat(0);
    var literals: [2048]u8 = undefined;
    var sequence_buffer: [1024]sequences_compress.Sequence = undefined;
    var store: Store = .{ .literals = &literals, .sequences = &sequence_buffer };
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
    const params: Params = .{ .window_log = 12, .hash_log = 13, .mls = 6 };
    var hash_table: [1 << 13]u32 = @splat(0);
    var literals: [2048]u8 = undefined;
    var sequence_buffer: [512]sequences_compress.Sequence = undefined;
    var store: Store = .{ .literals = &literals, .sequences = &sequence_buffer };
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
    const params: Params = .{ .window_log = 10, .hash_log = 11, .mls = 6 };
    var hash_table: [1 << 11]u32 = @splat(0);
    var literals: [8192]u8 = undefined;
    var sequence_buffer: [4096]sequences_compress.Sequence = undefined;
    var store: Store = .{ .literals = &literals, .sequences = &sequence_buffer };
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
