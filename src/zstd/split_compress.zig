//! The zstd encoder's pre-block splitter — the C's `ZSTD_optimalBlockSize`
//! (`zstd_compress.c:4550-4583`) over `ZSTD_splitBlock`'s chunk fingerprint
//! (`zstd_preSplit.c`). Once a frame has saved at least 3 bytes net, a full
//! 128-KiB block is offered to the splitter, which cuts it at the first 8-KiB
//! chunk boundary whose byte fingerprint is too different from the block's
//! past — the `ZSTD_splitBlock_byChunks` family. The splitter's level comes
//! from the strategy: `splitLevels[ZSTD_fast] = 0` selects
//! `ZSTD_splitBlock_fromBorders`, and `splitLevels[ZSTD_dfast] = 1` selects
//! `ZSTD_splitBlock_byChunks` at level 0 (the 43-byte sampling rate at
//! `hashLog` 8). Only the dfast level is ported: the level-1 class's border
//! splitter is the encoder's documented TE8 difference, and its absence is
//! what makes the level-1 class's frames the CLI's on every row the oracle
//! pins.
//!
//! The splitter changes block *boundaries* only; every byte still goes
//! through the same ladder, so a split block is just a shorter block and the
//! frame decodes identically. It is not output-neutral, though: it decides
//! how many blocks a frame carries, which is why the class's byte parity
//! depends on it.
//!
//! Format: docs/research/specs/rfc8878-zstd.txt §3.1.1.2 (the block chain).
//! Lineage: facebook/zstd v1.5.7 `zstd_preSplit.c`; attribution in
//! THIRD_PARTY.md.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const fastmem = @import("fastmem");

/// `CHUNKSIZE` (`zstd_preSplit.c:153`): the splitter's granularity. Every
/// candidate boundary is a multiple of this.
const chunk_size: usize = 8 * 1024;

/// `HASHLOG_MAX` / the level-0 record's `hashLog` (`zstd_preSplit.c:31,173`):
/// the fingerprint's 256 slots, hashed from 2 bytes (at `hashLog` 8 the hash
/// is just the first byte).
const hash_log: u5 = 8;
const hash_size: usize = 1 << hash_log;

/// The level-0 record's sampling rate (`FP_RECORD(43)`, `zstd_preSplit.c:159`).
const sampling_rate: usize = 43;

/// `THRESHOLD_PENALTY` (`zstd_preSplit.c:25`): the comparison's starting
/// penalty, which relaxes by one per chunk until it reaches zero.
const threshold_penalty: i32 = 3;

/// `THRESHOLD_PENALTY_RATE` / `THRESHOLD_BASE` (`zstd_preSplit.c:23-24`).
const threshold_penalty_rate: u64 = 16;
const threshold_base: u64 = threshold_penalty_rate - 2;

/// One byte-distribution fingerprint (`zstd_preSplit.c:37-40`): the sampled
/// positions' counts per hash slot, and the sample count the C tracks
/// separately (`addEvents_generic`'s `limit / samplingRate`, which is one
/// less than the loop's increment count when the chunk does not divide).
const Fingerprint = struct {
    events: [hash_size]u32 = @splat(0),
    nb_events: usize = 0,
};

/// `FPStats` (`zstd_preSplit.c:41-44`): the accumulated past and the current
/// chunk.
const Stats = struct {
    past: Fingerprint = .{},
    new: Fingerprint = .{},
};

/// `recordFingerprint_generic` at level 0's parameters
/// (`zstd_preSplit.c:70-77,160`): zero the slots, then count the sampled
/// positions' first bytes. `src.len` is `chunk_size`.
fn recordFingerprint(fingerprint: *Fingerprint, src: []const u8) void {
    assert(src.len == chunk_size);
    fastmem.set(u32, &fingerprint.events, 0);
    fingerprint.nb_events = 0;
    // `limit = srcSize - HASHLENGTH + 1`: 2-byte hashes need one byte of
    // slack, and at hashLog 8 the hash of the pair is its first byte.
    const limit = src.len - 1;
    var n: usize = 0;
    while (n < limit) : (n += sampling_rate) {
        fingerprint.events[src[n]] += 1;
    }
    // The C's count, not the loop's: `limit / samplingRate`.
    fingerprint.nb_events = limit / sampling_rate;
}

/// `fpDistance` (`zstd_preSplit.c:118-130`) at the level's `hashLog`: the
/// sum over slots of the cross-product difference, in 64-bit arithmetic.
fn fpDistance(a: *const Fingerprint, b: *const Fingerprint) u64 {
    var distance: u64 = 0;
    for (0..hash_size) |n| {
        const left = @as(i64, a.events[n]) * @as(i64, @intCast(b.nb_events));
        const right = @as(i64, b.events[n]) * @as(i64, @intCast(a.nb_events));
        const difference = left - right;
        distance += @intCast(if (difference < 0) -difference else difference);
    }
    return distance;
}

/// `compareFingerprints` (`zstd_preSplit.c:135-147`): whether the new chunk
/// differs from the past by at least the threshold — `deviation >=
/// p50 * (THRESHOLD_BASE + penalty) / THRESHOLD_PENALTY_RATE`.
fn compareFingerprints(ref: *const Fingerprint, new: *const Fingerprint, penalty: i32) bool {
    assert(ref.nb_events > 0);
    assert(new.nb_events > 0);
    const p50 = @as(u64, ref.nb_events) * @as(u64, new.nb_events);
    const deviation = fpDistance(ref, new);
    const threshold = p50 * @as(u64, @intCast(@as(i64, threshold_base) + penalty)) /
        threshold_penalty_rate;
    return deviation >= threshold;
}

/// `mergeEvents` (`zstd_preSplit.c:149-156`): fold the new chunk into the
/// past.
fn mergeEvents(acc: *Fingerprint, new: *const Fingerprint) void {
    for (&acc.events, new.events) |*slot, count| slot.* += count;
    acc.nb_events += new.nb_events;
}

/// `ZSTD_splitBlock_byChunks` at the dfast level's resolved 0
/// (`zstd_preSplit.c:158-190`): the first 8-KiB chunk boundary whose chunk
/// fingerprint differs too much from the accumulated past, or `block.len`
/// when the whole block is one fingerprint.
pub fn splitBlockByChunks(block: []const u8) usize {
    assert(block.len == 128 * 1024);
    var stats: Stats = .{};
    recordFingerprint(&stats.past, block[0..chunk_size]);
    var penalty: i32 = threshold_penalty;
    var pos: usize = chunk_size;
    while (pos <= block.len - chunk_size) : (pos += chunk_size) {
        recordFingerprint(&stats.new, block[pos..][0..chunk_size]);
        if (compareFingerprints(&stats.past, &stats.new, penalty)) return pos;
        mergeEvents(&stats.past, &stats.new);
        if (penalty > 0) penalty -= 1;
    }
    return block.len;
}

/// `ZSTD_optimalBlockSize` (`zstd_compress.c:4550-4583`): the block size to
/// emit for a chunk of `remaining` bytes at `source[chunk_start..]`, given
/// the frame's running `savings` (`consumed - produced`, the header
/// included). The pre-splitter's own level resolves through
/// `splitLevels[strategy]`: dfast (1) runs the chunk splitter, and level 1
/// (fast, 0) runs the border splitter — which this port does not carry, the
/// documented TE8 difference — so a level-1 frame keeps its full blocks.
///
/// `block_size_max` is the frame's block size, `min(128 KiB, 1 << window_log)`;
/// the splitter only ever sees full 128-KiB blocks (`srcSize < 128 KB ||
/// blockSizeMax < 128 KB` returns the plain size) and only once the frame has
/// saved at least 3 bytes net.
pub fn optimalBlockSize(
    level: u8,
    source: []const u8,
    chunk_start: usize,
    remaining: usize,
    block_size_max: usize,
    savings: i64,
) usize {
    const full: usize = 128 * 1024;
    if (remaining < full or block_size_max < full) return @min(remaining, block_size_max);
    // "do not split incompressible data though: require verified savings to
    // allow pre-splitting. Note: as a consequence, the first full block is
    // not split."
    if (savings < 3) return full;
    return switch (level) {
        3 => splitBlockByChunks(source[chunk_start..][0..full]),
        else => full,
    };
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc8878-zstd.txt §3.1.1.2 (block
// boundaries are decode boundaries). The splitter's own shape is pinned by
// the CLI: a block it cuts decodes to the same bytes, and the split position
// is a multiple of the 8-KiB chunk.
// ---------------------------------------------------------------------------

test "the chunk splitter cuts at an 8-KiB boundary, or not at all" {
    // The splitter's contract: a returned position is either the block's end
    // (no split) or a multiple of the chunk size, and every block it returns
    // is at least one chunk (the C's BLOCKSIZE_MIN discipline keeps the
    // pieces well above the format's minimum).
    var block: [128 * 1024]u8 = undefined;
    // A block whose two halves are very different: 64 KiB of one byte value,
    // then 64 KiB of random-ish bytes — the fingerprint comparison fires at
    // the first chunk boundary inside the second half.
    fastmem.set(u8, block[0 .. 64 * 1024], 0x5a);
    var rng: std.Random.DefaultPrng = .init(0x5CEBE1);
    for (block[64 * 1024 ..]) |*byte| byte.* = rng.random().int(u8);
    const split = splitBlockByChunks(&block);
    try testing.expect(split == block.len or split % chunk_size == 0);
    try testing.expect(split >= chunk_size);
    // The same bytes throughout: one fingerprint, no split.
    fastmem.set(u8, &block, 0x41);
    try testing.expectEqual(block.len, splitBlockByChunks(&block));
    // Two halves of one shape (an RLE run of one value, then of another): the
    // fingerprints differ from the boundary chunk on, so the cut lands at the
    // boundary — the first chunk that is not the past's shape.
    fastmem.set(u8, block[0 .. 64 * 1024], 0x41);
    fastmem.set(u8, block[64 * 1024 ..], 0x42);
    try testing.expectEqual(@as(usize, 64 * 1024), splitBlockByChunks(&block));
}

test "the optimal block size obeys the savings and size gates" {
    var block: [128 * 1024]u8 = undefined;
    fastmem.set(u8, block[0 .. 64 * 1024], 0x5a);
    var rng: std.Random.DefaultPrng = .init(0x1234);
    for (block[64 * 1024 ..]) |*byte| byte.* = rng.random().int(u8);
    // A partial chunk, or a small block size, never reaches the splitter.
    try testing.expectEqual(
        @as(usize, 1024),
        optimalBlockSize(3, &block, 0, 1024, 128 * 1024, 1000),
    );
    try testing.expectEqual(
        @as(usize, 64 * 1024),
        optimalBlockSize(3, &block, 0, 128 * 1024, 64 * 1024, 1000),
    );
    // No verified savings: the full block, whatever the content.
    try testing.expectEqual(
        @as(usize, 128 * 1024),
        optimalBlockSize(3, &block, 0, 128 * 1024, 128 * 1024, 2),
    );
    // Level 1 keeps its full blocks (the TE8 difference).
    try testing.expectEqual(
        @as(usize, 128 * 1024),
        optimalBlockSize(1, &block, 0, 128 * 1024, 128 * 1024, 1000),
    );
    // Level 3 with savings: the splitter decides.
    try testing.expectEqual(
        splitBlockByChunks(&block),
        optimalBlockSize(3, &block, 0, 128 * 1024, 128 * 1024, 1000),
    );
}
