//! The zstd frame checksum: an incremental XXH64 (`State`) and a one-shot
//! `xxh64`.
//!
//! RFC 8878 §3.1.1: "The content checksum is the result of the XXH64() hash
//! function [XXHASH] digesting the original (decoded) data as input, and a
//! seed of zero. The low 4 bytes of the checksum are stored in little-endian
//! format." `frame.State.recordBlock` feeds `State.update` each block's output
//! once, in order, and `State.final` returns the 32 bits the trailer carries. A
//! frame without the checksum flag never folds and never verifies.
//!
//! The kernel follows Zig std's `xxhash.zig` (attribution in THIRD_PARTY.md)
//! with one change: the running byte count is a `u64`. std's `XxHash64` counts
//! in a `usize`, which wraps past 2^32 on 32-bit targets, and a checksummed
//! frame past 4 GiB is legitimate, so a wrapping count would reject a good
//! frame with `WrongChecksum`. `probe32.zig` runs that case on a 32-bit target.

const std = @import("std");
const mem = std.mem;
const rotl = std.math.rotl;
const testing = std.testing;
const assert = std.debug.assert;
const x86 = std.Target.x86;
const XxHash64 = std.hash.XxHash64;
const DefaultPrng = std.Random.DefaultPrng;
const builtin = @import("builtin");

const internal = @import("../internal/root.zig");
const ArrayBuffer = internal.array_buffer.ArrayBuffer;
const readInt = @import("common.zig").readInt;

/// `§3.1.1` — the seed: "a seed of zero".
pub const seed: u64 = 0;

/// XXH64's five primes (the reference constants).
const prime_1 = 0x9E3779B185EBCA87;
const prime_2 = 0xC2B2AE3D27D4EB4F;
const prime_3 = 0x165667B19E3779F9;
const prime_4 = 0x85EBCA77C2B2AE63;
const prime_5 = 0x27D4EB2F165667C5;

/// One XXH64 round: mix one 64-bit input word into an accumulator.
fn round(acc: u64, lane: u64) u64 {
    const a = acc +% (lane *% prime_2);
    const b = rotl(u64, a, 31);
    return b *% prime_1;
}

const U7X4 = @Vector(4, u7);
const U6X4 = @Vector(4, u6);

/// The four accumulators as one vector.
const LaneVec = @Vector(4, u64);
const Lane = [4]u64;

/// The four accumulators, folded one stripe (32 bytes) at a time. XXH64's four
/// accumulators are independent wrapping multiply/rotate chains, so the access
/// pattern is already parallel; the open question is the instruction shape,
/// which depends on the CPU:
///
/// - **Scalar** (the default): four independent 3-op chains saturate the
///   integer multipliers. On aarch64 an explicit `@Vector(4, u64)` compiles to
///   two 2-wide SVE2 chains (mla.d/xar/mul.d) with higher latency, which
///   measured 9.2 vs 18.7 GB/s in the decode path on neoverse_v3. LLVM's SLP
///   vectorizer packs the four isomorphic chains on its own — into that SVE2
///   shape on aarch64, and into one `vpmullq` round on AVX-512DQ x86_64 —
///   which is what the barriers in `foldStripe` prevent: on Intel's P-cores
///   `vpmullq` is a ~15-cycle sequence on the serial accumulator chain, and
///   four independent 3-cycle `imul`s measure twice as fast (15.5 vs 7.3 GB/s
///   on graniterapids, 15.1 vs 7.1 on sapphirerapids; the four-lane micro
///   grid is in the wave's results file).
/// - **Vector** (AVX-512DQ+VL): a round is `vpmullq/vpaddq/vprolq/vpmullq` per
///   32-byte stripe, 4 vector instructions for all four accumulators. It pays
///   only where `vpmullq` is fast — znver4 (19.1 vs 14.6 GB/s scalar;
///   znver5's scalar `imul` dual-issues and flips it back, 24.7 vs 20.4).
const Accumulator = if (use_vector_lanes) VectorAccumulator else ScalarAccumulator;

/// The vector form pays only where a true 64-bit vector multiply exists AND is
/// fast: AVX-512DQ (`vpmullq`) with VL, so the four accumulators fit one ymm
/// register, on a core whose `vpmullq` is cheap. That is znver4 among the
/// fleet targets: Intel's P-cores run `vpmullq` as a multi-uop, ~15-cycle
/// sequence (scalar wins, measured), znver5's scalar `imul` dual-issues
/// (scalar wins, measured), baseline x86_64 synthesizes the multiply from
/// `vpmuludq`, and aarch64's SVE2 splits it into two serial 2-wide chains
/// (measured; the note above names the numbers).
const use_vector_lanes = builtin.cpu.arch == .x86_64 and
    x86.featureSetHas(builtin.cpu.features, .avx512dq) and
    x86.featureSetHas(builtin.cpu.features, .avx512vl) and
    mem.eql(u8, builtin.cpu.model.name, "znver4");

/// The scalar form: four `u64` accumulators, one stripe (32 bytes) at a time.
const ScalarAccumulator = struct {
    acc: Lane,

    fn init(seed_value: u64) ScalarAccumulator {
        return .{
            .acc = .{
                seed_value +% prime_1 +% prime_2,
                seed_value +% prime_2,
                seed_value,
                seed_value -% prime_1,
            },
        };
    }

    fn processStripe(self: *ScalarAccumulator, buf: []const u8) void {
        inline for (0..4) |i| {
            self.acc[i] = round(self.acc[i], readInt(u64, buf[i * 8 ..][0..8]));
        }
    }

    /// Fold every whole stripe of `input` and return the bytes consumed, a
    /// multiple of 32. The rest is the caller's tail.
    fn processStripes(self: *ScalarAccumulator, input: []const u8) usize {
        // The accumulators run as locals, so value semantics keep them in
        // registers across the loop whatever the caller's context. The loop is
        // unrolled four stripes per iteration, the sweet spot on neoverse_v3
        // (x8 spills, x2 pays full loop overhead). The input words pass
        // through an optimization barrier in `foldStripe` because the four
        // chains are isomorphic, and LLVM SLP-packs them into 2-wide u64 SVE2
        // (mla.d/xar/mul.d) when this is inlined into a big caller: two serial
        // chains of higher latency instead of four independent scalar ones,
        // which measured 9.4 vs 18.7 GB/s in the decode path on neoverse_v3.
        // Scalar is the right shape everywhere a vector form is not
        // comptime-selected; the barriers pin it.
        var acc = self.acc;
        var i: usize = 0;
        // x86_64 stays one stripe per iteration: unrolled, the 16 isomorphic
        // chains are enough for LLVM's SLP to pay the extract cost of the
        // per-lane barriers and pack the rounds back into `vpmullq`
        // (disassembly-checked on graniterapids). One stripe per iteration
        // keeps the multiply chains scalar; the loop overhead measured under
        // the barrier win (the four-lane micro grid, this wave's results).
        if (builtin.cpu.arch == .x86_64) {
            while (i + 32 <= input.len) : (i += 32) foldStripe(&acc, input[i..][0..32]);
            self.acc = acc;
            return i;
        }
        while (i + 128 <= input.len) : (i += 128) {
            inline for (0..4) |half| foldStripe(&acc, input[i + 32 * half ..][0..32]);
        }
        while (i + 32 <= input.len) : (i += 32) foldStripe(&acc, input[i..][0..32]);
        self.acc = acc;
        return i;
    }

    inline fn foldStripe(acc: *Lane, stripe: *const [32]u8) void {
        if (builtin.cpu.arch == .x86_64) {
            // x86_64: interleave load and round per lane, with a barrier on
            // each finished lane. LLVM's SLP packs the four isomorphic
            // chains into one `vpmullq` round whenever it can see them
            // together — the batched-load barrier variant included (the
            // extracts it emits to feed the barriers still pay): four
            // independent 3-cycle imuls beat one ~15-cycle vpmullq on the
            // serial accumulator chain on Intel (measured: 15.5 vs 7.3 GB/s
            // on graniterapids, 15.1 vs 7.1 on sapphirerapids; the
            // batched-load shape measured 6.2 there). The barrier must
            // cover the multiply's result, not its input.
            inline for (0..4) |j| {
                acc[j] = round(acc[j], readInt(u64, stripe[j * 8 ..][0..8]));
                mem.doNotOptimizeAway(acc[j]);
            }
            return;
        }
        var lane: Lane = undefined;
        inline for (0..4) |j| lane[j] = readInt(u64, stripe[j * 8 ..][0..8]);
        // Batched, not interleaved word by word: barriers between the
        // loads cost real throughput (measured 18.1 -> 14.8 GB/s).
        mem.doNotOptimizeAway(lane);
        inline for (0..4) |j| acc[j] = round(acc[j], lane[j]);
    }

    fn merge(self: *ScalarAccumulator) u64 {
        var acc = rotl(u64, self.acc[0], 1) +% rotl(u64, self.acc[1], 7) +%
            rotl(u64, self.acc[2], 12) +% rotl(u64, self.acc[3], 18);
        inline for (0..4) |i| acc = mergeAccumulator(acc, self.acc[i]);
        return acc;
    }

    fn mergeAccumulator(acc: u64, other: u64) u64 {
        const a = acc ^ round(0, other);
        const b = a *% prime_1;
        return b +% prime_4;
    }
};

/// The vector form: the four accumulators as one `@Vector(4, u64)` (see the
/// `Accumulator` selection note). A round is all wrapping multiply, add, and
/// rotate, so it needs no shuffles, and the accumulators do not interact
/// until `merge`.
const VectorAccumulator = struct {
    lanes: LaneVec,

    fn init(seed_value: u64) VectorAccumulator {
        // The per-accumulator seed offsets: +P1+P2, +P2, +0, -P1.
        const offsets: LaneVec = .{
            @as(u64, prime_1) +% @as(u64, prime_2),
            prime_2,
            0,
            @as(u64, 0) -% @as(u64, prime_1),
        };
        return .{ .lanes = @as(LaneVec, @splat(seed_value)) +% offsets };
    }

    fn processStripe(self: *VectorAccumulator, buf: []const u8) void {
        self.lanes = roundVec(self.lanes, loadStripe(buf[0..32]));
    }

    /// Fold every whole stripe of `input` and return the bytes consumed, a
    /// multiple of 32. The rest is the caller's tail.
    fn processStripes(self: *VectorAccumulator, input: []const u8) usize {
        var lanes = self.lanes;
        var i: usize = 0;
        while (i + 128 <= input.len) : (i += 128) {
            inline for (0..4) |half| {
                lanes = roundVec(lanes, loadStripe(input[i + 32 * half ..][0..32]));
            }
        }
        while (i + 32 <= input.len) : (i += 32) {
            lanes = roundVec(lanes, loadStripe(input[i..][0..32]));
        }
        self.lanes = lanes;
        return i;
    }

    fn merge(self: *VectorAccumulator) u64 {
        // rotl each accumulator by 1, 7, 12, 18, then the scalar merge chain.
        const rots: U7X4 = .{ 1, 7, 12, 18 };
        const rotated = (self.lanes << @as(U6X4, @intCast(rots))) |
            (self.lanes >> @as(U6X4, @intCast(@as(U7X4, @splat(64)) - rots)));
        var acc = @reduce(.Add, rotated);
        const arr: Lane = self.lanes;
        inline for (0..4) |k| acc = mergeAccumulator(acc, arr[k]);
        return acc;
    }

    fn mergeAccumulator(acc: u64, other: u64) u64 {
        const a = acc ^ round(0, other);
        const b = a *% prime_1;
        return b +% prime_4;
    }
};

/// The four 64-bit words of one 32-byte stripe. They are little-endian on the
/// wire, so a big-endian host swaps the bytes of each word.
inline fn loadStripe(stripe: *const [32]u8) LaneVec {
    const raw: LaneVec = @bitCast(stripe.*);
    return if (builtin.cpu.arch.endian() == .little) raw else @byteSwap(raw);
}

/// The vector round: `rotl(acc + word * P2, 31) * P1` on all four accumulators.
inline fn roundVec(acc: LaneVec, lanes: LaneVec) LaneVec {
    const a = acc +% lanes *% @as(LaneVec, @splat(prime_2));
    const b = (a << @as(U6X4, @splat(31))) | (a >> @as(U6X4, @splat(33)));
    return b *% @as(LaneVec, @splat(prime_1));
}

/// The finalize step over the tail (always under 32 bytes).
fn finalizeTail(unfinished: u64, byte_count: u64, partial: []const u8) u64 {
    assert(partial.len < 32);
    var acc = unfinished +% byte_count +% @as(u64, partial.len);

    var i: usize = 0;
    while (i + 8 <= partial.len) : (i += 8) {
        acc ^= round(0, readInt(u64, partial[i..][0..8]));
        acc = rotl(u64, acc, 27) *% prime_1;
        acc +%= prime_4;
    }
    if (i + 4 <= partial.len) {
        acc ^= @as(u64, readInt(u32, partial[i..][0..4])) *% prime_1;
        acc = rotl(u64, acc, 23) *% prime_2;
        acc +%= prime_3;
        i += 4;
    }
    while (i < partial.len) : (i += 1) {
        acc ^= @as(u64, partial[i]) *% prime_5;
        acc = rotl(u64, acc, 11) *% prime_1;
    }
    return avalanche(acc);
}

fn avalanche(value: u64) u64 {
    var result = value ^ (value >> 33);
    result *%= prime_2;
    result ^= result >> 29;
    result *%= prime_3;
    result ^= result >> 32;
    return result;
}

/// The frame's checksum state: an incremental XXH64 over the frame's decoded
/// bytes, fed once per block by `frame.State.recordBlock`. The running byte
/// count is a `u64` (see the module doc): a frame's output has no `usize`
/// bound, and a 32-bit wrap would reject a good frame with a false
/// `WrongChecksum`.
pub const State = struct {
    /// The four accumulators, seeded with zero (`§3.1.1`).
    accumulator: Accumulator,
    /// The under-one-stripe tail: the bytes not yet folded into the accumulators.
    buf: ArrayBuffer(u8, 32),
    /// The running total: **u64** — a checksummed frame past 2^32 is
    /// legitimate (the CLI writes them), and this count must not wrap on
    /// any target.
    byte_count: u64,

    /// A checksum before any byte: the §3.1.1 seed, an empty tail, count 0.
    pub const init: State = .{ .accumulator = .init(seed), .buf = .empty, .byte_count = 0 };

    /// Fold one contiguous run of decoded bytes into the checksum. Counting
    /// follows std's `XxHash64.update` with a `u64` count: buffered bytes are
    /// counted when their stripe is processed, not when they are buffered,
    /// because the buffered tail enters `final` through `buf_len` and an eager
    /// count would count it twice.
    pub fn update(self: *State, input: []const u8) void {
        if (input.len < self.buf.remainingCapacity()) {
            self.buf.appendSliceAssumeCapacity(input);
            return;
        }

        var i: usize = 0;

        if (self.buf.len > 0) {
            // The count that follows adds `i` input bytes, so it must read
            // the pre-append buffered count; the append moves `buf.len`.
            const previously_buffered = self.buf.len;
            i = self.buf.remainingCapacity();
            self.buf.appendSliceAssumeCapacity(input[0..i]);
            self.accumulator.processStripe(self.buf.constSlice());
            // The previously buffered bytes, now stripe-processed.
            self.byte_count += previously_buffered;
        }

        i += self.accumulator.processStripes(input[i..]);
        // The flush's input bytes plus the whole direct stripes.
        self.byte_count += i;

        const remaining_bytes = input[i..];
        self.buf.clear();
        self.buf.appendSliceAssumeCapacity(remaining_bytes);
    }

    /// The trailer's value (`§3.1.1`): "The low 4 bytes of the checksum are
    /// stored in little-endian format" — the digest's low 32 bits, compared
    /// against the wire's four bytes read little-endian.
    pub fn final(self: *State) u32 {
        const unfinished = if (self.byte_count < 32)
            seed +% prime_5
        else
            self.accumulator.merge();

        return @truncate(finalizeTail(unfinished, self.byte_count, self.buf.constSlice()));
    }
};

/// The one-shot digest `XXH64(bytes, seed)`. The frame paths fold through
/// `State` instead; this form is for the tests.
pub fn xxh64(seed_value: u64, bytes: []const u8) u64 {
    if (bytes.len < 32) return finalizeTail(seed_value +% prime_5, 0, bytes);
    var acc: Accumulator = .init(seed_value);
    const i = acc.processStripes(bytes);
    return finalizeTail(acc.merge(), @intCast(i), bytes[i..]);
}

// ---------------------------------------------------------------------------
// Tests. `std.hash.XxHash64` is the reference: the differential sweep pins
// this kernel to it on every length class, and the canonical check value plus
// the golden frames' CLI-verified trailers pin it outright. std's kernel wraps
// past 2^32 bytes on a 32-bit target, so there `probe32.zig`'s CLI-verified
// frame is the check.
// ---------------------------------------------------------------------------

test "xxh64: the canonical check value" {
    // XXH64's own reference check: XXH64("") with seed 0 is 0xEF46DB3751D8E999.
    // Its low 32 bits are the trailer of an empty checksummed frame
    // (`golden.frame_checksum_empty`).
    try testing.expectEqual(@as(u64, 0xEF46DB3751D8E999), xxh64(0, ""));
    try testing.expectEqual(
        @as(u64, 0xEF46DB3751D8E999),
        XxHash64.hash(0, ""),
    );
}

test "xxh64: both lane forms agree on the stripe path" {
    // The comptime selection (`use_vector_lanes`) picks one accumulator per
    // target; both forms are pinned here on every host, so the form a
    // target does NOT select stays differentially tested. Drive the stripe
    // loops directly (multiples of 32 exercise processStripes end to end,
    // the 32-byte residue covers processStripe's flush shape).
    var bytes: [1024]u8 = undefined;
    var rng: DefaultPrng = .init(0x1A3E_5EED);
    rng.random().bytes(&bytes);
    var len: usize = 32;
    while (len <= bytes.len) : (len += 32) {
        var scalar: ScalarAccumulator = .init(seed);
        var vector: VectorAccumulator = .init(seed);
        try testing.expectEqual(
            scalar.processStripes(bytes[0..len]),
            vector.processStripes(bytes[0..len]),
        );
        scalar.processStripe(bytes[0..32]);
        vector.processStripe(bytes[0..32]);
        try testing.expectEqual(scalar.merge(), vector.merge());
    }
}

test "xxh64: the differential sweep against std's kernel" {
    // Every length class and every 32-byte boundary crossing, deterministic
    // bytes: the kernel must agree with std's exactly wherever both are
    // defined (std's is defined while the total fits its usize, which on a
    // 64-bit host is everywhere).
    var bytes: [512]u8 = undefined;
    var rng: DefaultPrng = .init(0xBEEF_C0DE);
    rng.random().bytes(&bytes);
    for (0..bytes.len + 1) |len| {
        try testing.expectEqual(
            XxHash64.hash(0, bytes[0..len]),
            xxh64(0, bytes[0..len]),
        );
        // A nonzero seed too: the seed arithmetic is part of the kernel.
        try testing.expectEqual(
            XxHash64.hash(0x5EED, bytes[0..len]),
            xxh64(0x5EED, bytes[0..len]),
        );
    }
}

test "xxh64: the incremental state equals the one-shot" {
    // The frame paths fold per block: the digest must be independent of
    // where the runs are cut, across the stripe boundaries.
    const bytes = "checksums ride the codec boundary " ** 40;
    var state: State = .init;
    var at: usize = 0;
    while (at < bytes.len) : (at += 7) {
        state.update(bytes[at..][0..@min(7, bytes.len - at)]);
    }
    const one_shot = xxh64(seed, bytes);
    try testing.expectEqual(@as(u32, @truncate(one_shot)), state.final());
    try testing.expectEqual(XxHash64.hash(seed, bytes), one_shot);
}

test "xxh64: the golden frames' trailers" {
    // The CLI-verified frame's checksum through this kernel
    // (golden.zig's `frame_checksum`, `zstd -t`-good). The empty and
    // multi-block frames' trailers are checked in `frame.zig`'s tests.
    const golden = @import("golden.zig");
    const expected: u32 = blk: {
        const frame_bytes = golden.frame_checksum;
        const trailer = frame_bytes[frame_bytes.len - 4 ..];
        break :blk readInt(u32, trailer[0..4]);
    };
    // golden.frame_checksum decodes to "abcd" (the literals 61 62 63 64);
    // the trailer is the low 4 bytes of XXH64("abcd", 0), little-endian.
    var state: State = .init;
    state.update("abcd");
    try testing.expectEqual(expected, state.final());
}
