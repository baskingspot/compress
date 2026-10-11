//! The zstd frame checksum state over this module's own XXH64 kernel.
//!
//! RFC 8878 §3.1.1: "The content checksum is the result of the XXH64() hash
//! function [XXHASH] digesting the original (decoded) data as input, and a
//! seed of zero. The low 4 bytes of the checksum are stored in little-endian
//! format."
//!
//! The kernel is ours, ported from the XXH64 algorithm (xxHash's reference,
//! public domain; the port follows Zig std's `std/hash/xxhash.zig`, MIT —
//! THIRD_PARTY.md) with one deliberate change: **the running byte count is
//! `u64`**. std's `XxHash64` counts bytes in a `usize` (`xxhash.zig:14`,
//! `+=` at `:200`/`:204`), so a legitimate checksummed frame past 2^32 —
//! which the pinned zstd CLI writes by default and `zstd -t` accepts
//! (4,295,229,440 bytes in the closing review's probe) — wrapped on the
//! 32-bit targets: a ReleaseSafe panic and a ReleaseFast **false
//! `WrongChecksum`** through the reader (the M4 review's B1′, observed
//! directly on wasm32; a frame's output has no usize bound, the same fact
//! that made `frame.State.decoded_len` u64). The CRC-32 lesson applied in
//! reverse: the audit had verified std's kernel against the C library's
//! own trailers — every frame under test fit in a `usize` — but the
//! 64-bit counter is a correctness property, not a performance one, and
//! the day-one kernel boundary (the `src/gzip/crc32.zig` shape) is what
//! made this swap a file-local change.
//!
//! `std.hash.XxHash64` stays in the tests below as the reference oracle:
//! the differential sweep (every length class, the 32-byte boundaries, the
//! incremental splits) plus the canonical check value pin our kernel to it
//! where `usize` is wide enough, and the golden frames' CLI-verified
//! trailers pin it where it is not.
//!
//! Where it folds (OQ7): at the one per-block emission funnel
//! (`frame.State.recordBlock`), so every decoded byte is hashed exactly
//! once, in order, with no second pass and no buffer of our own. The
//! flag-off frame never folds and never verifies.

const std = @import("std");
const mem = std.mem;
const rotl = std.math.rotl;
const testing = std.testing;
const assert = std.debug.assert;

const fastmem = @import("fastmem");

/// `§3.1.1` — the seed: "a seed of zero".
pub const seed: u64 = 0;

/// XXH64's five primes (the reference constants).
const prime_1 = 0x9E3779B185EBCA87;
const prime_2 = 0xC2B2AE3D27D4EB4F;
const prime_3 = 0x165667B19E3779F9;
const prime_4 = 0x85EBCA77C2B2AE63;
const prime_5 = 0x27D4EB2F165667C5;

/// One round: the per-lane mixing step.
fn round(acc: u64, lane: u64) u64 {
    const a = acc +% (lane *% prime_2);
    const b = rotl(u64, a, 31);
    return b *% prime_1;
}

/// The four-lane accumulator, one stripe (32 bytes) at a time.
const Accumulator = struct {
    acc1: u64,
    acc2: u64,
    acc3: u64,
    acc4: u64,

    fn init(seed_value: u64) Accumulator {
        return .{
            .acc1 = seed_value +% prime_1 +% prime_2,
            .acc2 = seed_value +% prime_2,
            .acc3 = seed_value,
            .acc4 = seed_value -% prime_1,
        };
    }

    fn processStripe(self: *Accumulator, buf: []const u8) void {
        self.acc1 = round(self.acc1, mem.readInt(u64, buf[0..8], .little));
        self.acc2 = round(self.acc2, mem.readInt(u64, buf[8..16], .little));
        self.acc3 = round(self.acc3, mem.readInt(u64, buf[16..24], .little));
        self.acc4 = round(self.acc4, mem.readInt(u64, buf[24..32], .little));
    }

    /// The whole stripes of `input`, returning how many bytes were
    /// consumed (a multiple of 32, the rest is the caller's tail).
    fn processStripes(self: *Accumulator, input: []const u8) usize {
        var i: usize = 0;
        while (i + 32 <= input.len) : (i += 32) {
            self.processStripe(input[i..][0..32]);
        }
        return i;
    }

    fn merge(self: *Accumulator) u64 {
        var acc = rotl(u64, self.acc1, 1) +% rotl(u64, self.acc2, 7) +%
            rotl(u64, self.acc3, 12) +% rotl(u64, self.acc4, 18);
        acc = mergeAccumulator(acc, self.acc1);
        acc = mergeAccumulator(acc, self.acc2);
        acc = mergeAccumulator(acc, self.acc3);
        acc = mergeAccumulator(acc, self.acc4);
        return acc;
    }

    fn mergeAccumulator(acc: u64, other: u64) u64 {
        const a = acc ^ round(0, other);
        const b = a *% prime_1;
        return b +% prime_4;
    }
};

/// The finalize step over the tail (always under 32 bytes).
fn finalizeTail(unfinished: u64, byte_count: u64, partial: []const u8) u64 {
    assert(partial.len < 32);
    var acc = unfinished +% byte_count +% @as(u64, partial.len);

    var i: usize = 0;
    while (i + 8 <= partial.len) : (i += 8) {
        acc ^= round(0, mem.readInt(u64, partial[i..][0..8], .little));
        acc = rotl(u64, acc, 27) *% prime_1;
        acc +%= prime_4;
    }
    if (i + 4 <= partial.len) {
        acc ^= @as(u64, mem.readInt(u32, partial[i..][0..4], .little)) *% prime_1;
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

/// The frame's checksum state: the incremental XXH64 over the frame's
/// decoded bytes, folded per block by `frame.State.recordBlock` (OQ7). The
/// running byte count is `u64` (see the module doc) — a frame's output has
/// no `usize` bound, and the 32-bit targets' wrap is the false checksum
/// rejection the kernel exists to prevent.
pub const State = struct {
    /// The four lanes, seeded with zero (`§3.1.1`).
    accumulator: Accumulator = .init(seed),
    /// The under-one-stripe tail: the bytes not yet folded into the lanes.
    /// Always under 32 bytes, so `usize` here is bounded by the stripe.
    buf: [32]u8 = undefined,
    buf_len: usize = 0,
    /// The running total: **u64** — a checksummed frame past 2^32 is
    /// legitimate (the CLI writes them), and this count must not wrap on
    /// any target.
    byte_count: u64 = 0,

    /// Fold one contiguous run of decoded bytes. The counting follows the
    /// reference's shape exactly (std's `XxHash64.update`, in u64): the
    /// buffered bytes are counted when their stripe is processed, never when
    /// they are buffered — the buffered tail enters `final` through
    /// `buf_len`, so an eager count would double it.
    pub fn update(self: *State, input: []const u8) void {
        if (input.len < 32 - self.buf_len) {
            fastmem.copy(u8, self.buf[self.buf_len..][0..input.len], input);
            self.buf_len += input.len;
            return;
        }

        var i: usize = 0;

        if (self.buf_len > 0) {
            i = 32 - self.buf_len;
            fastmem.copy(u8, self.buf[self.buf_len..][0..i], input[0..i]);
            self.accumulator.processStripe(self.buf[0..32]);
            // The previously buffered bytes, now stripe-processed.
            self.byte_count += self.buf_len;
        }

        i += self.accumulator.processStripes(input[i..]);
        // The flush's input bytes plus the whole direct stripes.
        self.byte_count += i;

        const remaining_bytes = input[i..];
        fastmem.copy(u8, self.buf[0..remaining_bytes.len], remaining_bytes);
        self.buf_len = remaining_bytes.len;
    }

    /// The trailer's value (`§3.1.1`): "The low 4 bytes of the checksum are
    /// stored in little-endian format" — the digest's low 32 bits, compared
    /// against the wire's four bytes read little-endian.
    pub fn final(self: *State) u32 {
        const unfinished = if (self.byte_count < 32)
            seed +% prime_5
        else
            self.accumulator.merge();

        return @truncate(finalizeTail(unfinished, self.byte_count, self.buf[0..self.buf_len]));
    }
};

/// The one-shot digest `XXH64(bytes, seed)`, the `crc32(crc, bytes)` shape:
/// the tests' and the oracle's form. The frame paths fold through `State`.
pub fn xxh64(seed_value: u64, bytes: []const u8) u64 {
    if (bytes.len < 32) {
        return finalizeTail(seed_value +% prime_5, 0, bytes);
    }
    var accumulator: Accumulator = .init(seed_value);
    const i = accumulator.processStripes(bytes);
    return finalizeTail(accumulator.merge(), @intCast(i), bytes[i..]);
}

// ---------------------------------------------------------------------------
// Tests. The reference oracle is `std.hash.XxHash64` (the kernel M4's audit
// verified against the C library's own trailers): the differential sweep
// pins this kernel to it on every length class, and the canonical check
// value plus the golden frames' CLI-verified trailers pin it outright.
// ---------------------------------------------------------------------------

test "xxh64: the canonical check value" {
    // XXH64's own reference check: XXH64("") with seed 0 is 0xEF46DB3751D8E999
    // (the value the notes' audit pinned, and the one the zstd trailers
    // cross-checked).
    try testing.expectEqual(@as(u64, 0xEF46DB3751D8E999), xxh64(0, ""));
    try testing.expectEqual(
        @as(u64, 0xEF46DB3751D8E999),
        std.hash.XxHash64.hash(0, ""),
    );
}

test "xxh64: the differential sweep against std's kernel" {
    // Every length class and every 32-byte boundary crossing, deterministic
    // bytes: the kernel must agree with the reference oracle exactly
    // wherever both are defined (std's is defined while the total fits its
    // usize — on this host, everywhere).
    var bytes: [512]u8 = undefined;
    var rng: std.Random.DefaultPrng = .init(0xBEEF_C0DE);
    rng.random().bytes(&bytes);
    for (0..bytes.len + 1) |len| {
        try testing.expectEqual(
            std.hash.XxHash64.hash(0, bytes[0..len]),
            xxh64(0, bytes[0..len]),
        );
        // A nonzero seed too: the seed arithmetic is part of the kernel.
        try testing.expectEqual(
            std.hash.XxHash64.hash(0x5EED, bytes[0..len]),
            xxh64(0x5EED, bytes[0..len]),
        );
    }
}

test "xxh64: the incremental state equals the one-shot" {
    // The frame paths fold per block: the digest must be independent of
    // where the runs are cut, across the stripe boundaries.
    const bytes = "checksums ride the codec boundary " ** 40;
    var state: State = .{};
    var at: usize = 0;
    while (at < bytes.len) : (at += 7) {
        state.update(bytes[at..][0..@min(7, bytes.len - at)]);
    }
    const one_shot = xxh64(seed, bytes);
    try testing.expectEqual(@as(u32, @truncate(one_shot)), state.final());
    try testing.expectEqual(std.hash.XxHash64.hash(seed, bytes), one_shot);
}

test "xxh64: the golden frames' trailers" {
    // The differential pin the audit established, now through this kernel:
    // the CLI-verified frames' checksums (golden.zig's `frame_checksum`,
    // `frame_checksum_empty`, `frame_checksum_multi`, each `zstd -t`-good).
    const golden = @import("golden.zig");
    const expected: u32 = blk: {
        const frame_bytes = golden.frame_checksum;
        const trailer = frame_bytes[frame_bytes.len - 4 ..];
        break :blk mem.readInt(u32, trailer[0..4], .little);
    };
    // golden.frame_checksum decodes to "abcd" (the literals 61 62 63 64);
    // the trailer is the low 4 bytes of XXH64("abcd", 0), little-endian.
    var state: State = .{};
    state.update("abcd");
    try testing.expectEqual(expected, state.final());
}
