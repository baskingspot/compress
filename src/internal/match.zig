//! Overlapping LZ77 match copies with a SIMD fast path. The caller validates
//! the offset and the output bounds. A match may overlap its destination:
//! bytes just written are read again, in increasing address order.
//!
//! Small offsets replicate their pattern into a 16-byte register with `tbl` on
//! AArch64, `pshufb` on x86_64 with SSSE3, and a byte permute elsewhere. Larger
//! overlapping offsets copy 16-byte windows, whose source and destination do
//! not overlap. Non-overlapping matches go straight through fastmem.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Target = std.Target;
const builtin = @import("builtin");
const native_arch = builtin.target.cpu.arch;

const fastmem = @import("fastmem");

const sentinel = @import("sentinel.zig");

/// 16-byte vector type for the shuffle loads/stores. PascalCase because it's
/// a type alias (per Zig convention); ziglint's Z006 misfires on type-alias
/// consts and has no inline-ignore directive, so this is documented here.
const Vec16 = @Vector(16, u8);

/// Comptime shuffle mask for a given pattern size: `mask[i] = i % pattern_size`.
/// Used as the `tbl`/`pshufb` control word to replicate the first `pattern_size`
/// bytes across a 16-byte register. Every entry is `< pattern_size <= 16`, so
/// no index is out of range.
fn patternMask(comptime pattern_size: u8, comptime base: u8) Vec16 {
    var m: Vec16 = undefined;
    for (0..16) |i| m[i] = @intCast((@as(u16, base) + i) % pattern_size);
    return m;
}

/// Generation masks: `pattern_masks[offset-1][i] = i % offset`. Loaded once,
/// applied to the raw source bytes to produce the first 16-byte repeating
/// pattern. Mask bytes are all `< offset <= 16`, satisfying `tbl`/`pshufb`.
const pattern_masks: [16]Vec16 = blk: {
    var table: [16]Vec16 = undefined;
    for (1..17) |ps| table[ps - 1] = patternMask(@intCast(ps), 0);
    break :blk table;
};

/// Reshuffle masks: `reshuffle_masks[offset-1][i] = (16 + i) % offset`. Applied
/// to the current pattern vector to produce the *next* 16 bytes, advancing the
/// phase. For offsets that divide 16 (1, 2, 4, 8, 16) this equals the
/// generation mask, so the pattern is exactly periodic over 16 and re-storing
/// the same vector is correct; for other offsets it shifts the phase. Entries
/// are `< offset <= 16`, so all in range for `tbl`/`pshufb`.
const reshuffle_masks: [16]Vec16 = blk: {
    var table: [16]Vec16 = undefined;
    for (1..17) |ps| table[ps - 1] = patternMask(@intCast(ps), 16);
    break :blk table;
};

/// Load 16 bytes from `src` as a `Vec16` (unaligned). Using `align(1)` tells
/// the compiler the address may be unaligned, so it emits an unaligned vector
/// load (`ldur` on AArch64, `movdqu` on x86_64) rather than an aligned one.
inline fn loadVec(src: [*]const u8) Vec16 {
    const ptr: *align(1) const Vec16 = @ptrCast(src);
    return ptr.*;
}

/// Store 16 bytes of `v` to `dst` (unaligned).
inline fn storeVec(dst: [*]u8, v: Vec16) void {
    const ptr: *align(1) Vec16 = @ptrCast(dst);
    ptr.* = v;
}

/// Shuffle `v` by `mask` using the native SIMD instruction. On AArch64 this is
/// `tbl`; on x86_64 (SSSE3+) `pshufb`. The mask is picked at run time from
/// `pattern_masks` by `offset`, so it is not comptime-known: it goes to the
/// instruction as a register operand.
inline fn shuffleBytes(v: Vec16, mask: Vec16) Vec16 {
    switch (native_arch) {
        .aarch64 => {
            var out: Vec16 = undefined;
            asm volatile ("tbl %[out].16b, { %[v].16b }, %[mask].16b"
                : [out] "=w" (out),
                : [v] "w" (v),
                  [mask] "w" (mask),
            );
            return out;
        },
        .x86_64 => {
            // PSHUFB is a 2-operand instruction (SSSE3+): `pshufb dest, mask`
            // shuffles `dest` in place using `mask`. AT&T syntax (Zig's x86
            // default) is `pshufb %{mask}, %{out}`, src-first. We use `+x` so
            // `v` is read and written, then return it.
            // Gate on SSSE3: pshufb requires SSSE3, not just x86_64. Baseline
            // x86_64 (no SSSE3) falls through to the portable byte permute.
            if (comptime Target.x86.featureSetHas(builtin.cpu.features, .ssse3)) {
                var out = v;
                asm volatile ("pshufb %[mask], %[out]"
                    : [out] "+x" (out),
                    : [mask] "x" (mask),
                );
                return out;
            } else {
                const v_bytes: [16]u8 = v;
                const mask_bytes: [16]u8 = mask;
                var out: [16]u8 = undefined;
                for (0..16) |i| out[i] = v_bytes[mask_bytes[i]];
                return out;
            }
        },
        else => {
            // Portable fallback: a byte-wise permute. The compiler can often
            // recognize this as a shuffle on targets with a suitable instruction;
            // otherwise it stays a scalar loop (cold path for non-SIMD arches).
            const v_bytes: [16]u8 = v;
            const mask_bytes: [16]u8 = mask;
            var out: [16]u8 = undefined;
            for (0..16) |i| out[i] = v_bytes[mask_bytes[i]];
            return out;
        },
    }
}

/// Copy `length` bytes from `target[pos - offset ..]` to `target[pos ..]`,
/// handling overlap (RLE). The caller guarantees `offset > 0`,
/// `offset <= pos`, and `pos + length <= target.len`; the asserts at the top
/// check them. This is the hot path for LZ77 match copies.
pub fn copyMatch(target: []u8, pos: usize, offset: usize, length: usize) void {
    assert(offset > 0);
    assert(offset <= pos);
    assert(pos + length <= target.len);

    // Non-overlapping: a single vectorized memcpy. The common case for matches
    // into earlier, distinct data.
    if (offset >= length) {
        fastmem.copy(u8, target[pos..][0..length], target[pos - offset ..][0..length]);
        return;
    }

    if (offset <= 16) {
        // Build the 16-byte pattern source safely. The repeating pattern is the
        // first `offset` bytes at `target[pos-offset]`; loading a full 16 bytes
        // there could overread past `target.len` near the tail (the output buffer
        // is sized to the decompressed length, with no slop). So copy just the
        // `offset` source bytes into a zero-padded 16-byte buffer — the shuffle
        // mask only references indices `< offset`, so the padding is never used.
        var src16: [16]u8 = @splat(0);
        fastmem.copy(u8, src16[0..offset], target[pos - offset ..][0..offset]);
        const pattern0: Vec16 = src16;
        var pattern = shuffleBytes(pattern0, pattern_masks[offset - 1]);
        const reshuffle = reshuffle_masks[offset - 1];
        const end = pos + length;
        var p = pos;
        while (p + 16 <= end) : (p += 16) {
            storeVec(target.ptr + p, pattern);
            pattern = shuffleBytes(pattern, reshuffle);
        }
        // Tail: the remaining (< 16) bytes are the leading bytes of the current
        // pattern window — `pattern[i]` is exactly the byte for this position.
        // A vector cannot be indexed at run time, so coerce to an
        // array first.
        const pattern_bytes: [16]u8 = pattern;
        const tail = end - p;
        var i: usize = 0;
        while (i < tail) : (i += 1) {
            target[p + i] = pattern_bytes[i];
        }
        return;
    }

    // offset > 16 but < length: overlapping, but the 16-byte source window
    // starting at pos-offset does not overlap the 16-byte store at pos, so a
    // forward 16-byte-chunk memcpy is safe and vectorizes.
    var p = pos;
    const end = pos + length;
    while (p + 16 <= end) : (p += 16) {
        storeVec(target.ptr + p, loadVec(target.ptr + (p - offset)));
    }
    const tail = end - p;
    if (tail > 0) {
        fastmem.copy(u8, target[p..][0..tail], target[p - offset ..][0..tail]);
    }
}

// Every collapsing offset against a byte-at-a-time copy, at positions that push
// each branch: the 16-byte pattern path, the 16-byte window path, and the
// non-overlapping memcpy. A wrong phase mask passes a round trip and fails here.
test "copyMatch: every overlapping offset matches a byte copy" {
    const guard_len = 64;
    var buffer: [1024 + guard_len]u8 = undefined;
    var reference: [1024 + guard_len]u8 = undefined;
    for (1..65) |offset| {
        for ([_]usize{ 1, 2, 3, 7, 15, 16, 17, 31, 32, 33, 63, 64, 65, 100, 200 }) |length| {
            for ([_]usize{ 0, 1, 7, 16, 40 }) |slack| {
                const pos = offset + slack;
                const end = pos + length;
                // The store path writes through a many-pointer, so a slice
                // ending at `end` does not trap an overrun by itself. The
                // sentinel past `end` does.
                sentinel.fill(&buffer);
                for (buffer[0..pos], 0..) |*byte, i| byte.* = @truncate(i *% 37 +% 11);
                @memcpy(&reference, &buffer);
                copyMatch(buffer[0..end], pos, offset, length);
                for (0..length) |i| reference[pos + i] = reference[pos + i - offset];
                try testing.expectEqualSlices(u8, reference[0..end], buffer[0..end]);
                try sentinel.expect(&buffer, end);
            }
        }
    }
}
