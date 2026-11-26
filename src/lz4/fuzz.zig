//! Fuzz targets for the LZ4 block codec:
//!
//!   - `fuzzBlockDecode`: arbitrary bytes into `decompressBlock`, with a
//!     sentinel overrun check and an encode/decode round trip after success.
//!   - `fuzzBlockRoundTrip`: structured shapes through both directions, with
//!     the compressed-size bound and exact decoded output checked.
//!
//! Run with `just fuzz <budget>` in ReleaseSafe. Per-iteration caps keep a
//! corrupt length from turning into unbounded work. The codec allocates
//! nothing.
//!
//! Spec: docs/specs/lz4-block-format.md, "Compressed block format" and "Safe
//! decoding".

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Smith = testing.Smith;
const math = std.math;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const decode = @import("decode.zig");
const encode = @import("encode.zig");

const source_max: usize = 8 * 1024;
const block_max: usize = 128 * 1024;
const guard_len: usize = 256;

fn rangeAtMost(smith: *Smith, at_least: usize, at_most: usize) usize {
    assert(at_least <= at_most);
    assert(at_most <= math.maxInt(u32));
    return smith.valueRangeAtMost(u32, @intCast(at_least), @intCast(at_most));
}

fn blockRoundTrip(bytes: []const u8) !void {
    assert(bytes.len <= block_max);
    var compressed: [encode.maxCompressedLength(block_max)]u8 = undefined;
    const compressed_len = try encode.compressBlock(bytes, &compressed);
    try testing.expect(compressed_len <= encode.maxCompressedLength(bytes.len));

    var window: [block_max + guard_len]u8 = undefined;
    sentinel.fill(window[0 .. bytes.len + guard_len]);
    const decoded_len = try decode.decompressBlock(
        compressed[0..compressed_len],
        window[0..bytes.len],
    );
    try testing.expectEqual(bytes.len, decoded_len);
    try testing.expectEqualSlices(u8, bytes, window[0..decoded_len]);
    try sentinel.expect(window[0 .. bytes.len + guard_len], bytes.len);
}

/// Arbitrary block decode. Every outcome is either `DecompressionFailed` or
/// exactly `target.len` bytes that survive a re-encode round trip. The sentinel
/// region is checked after both outcomes.
fn fuzzBlockDecode(_: void, smith: *Smith) anyerror!void {
    var source_buf: [source_max]u8 = undefined;
    const source = source_buf[0..smith.slice(&source_buf)];
    const target_len = rangeAtMost(smith, 0, block_max);

    var window: [block_max + guard_len]u8 = undefined;
    sentinel.fill(window[0 .. target_len + guard_len]);
    const target = window[0..target_len];
    if (decode.decompressBlock(source, target)) |decoded_len| {
        try testing.expectEqual(target_len, decoded_len);
        try blockRoundTrip(target);
    } else |err| {
        try testing.expectEqual(error.DecompressionFailed, err);
    }
    try sentinel.expect(window[0 .. target_len + guard_len], target_len);
}

test "lz4 fuzz: block decode" {
    try testing.fuzz({}, fuzzBlockDecode, .{});
}

const Shape = enum(u8) { random, run, phrase, mixed };

fn buildShape(smith: *Smith, buf: []u8) usize {
    const shape = smith.value(Shape);
    const len = rangeAtMost(smith, 0, buf.len);
    if (len == 0) return 0;
    switch (shape) {
        .random => smith.bytes(buf[0..len]),
        .run => fastmem.set(u8, buf[0..len], smith.value(u8)),
        .phrase => {
            const phrase_len = rangeAtMost(smith, 1, @min(len, 64));
            smith.bytes(buf[0..phrase_len]);
            var i = phrase_len;
            while (i < len) : (i += phrase_len) {
                const n = @min(phrase_len, len - i);
                fastmem.copy(u8, buf[i..][0..n], buf[0..n]);
            }
        },
        .mixed => {
            var i: usize = 0;
            while (i < len) {
                const n = @min(rangeAtMost(smith, 1, 128), len - i);
                if (smith.boolWeighted(1, 1)) {
                    fastmem.set(u8, buf[i..][0..n], smith.value(u8));
                } else {
                    smith.bytes(buf[i..][0..n]);
                }
                i += n;
            }
        },
    }
    return len;
}

/// Structured round trips drive the three-position match scan, long overlap,
/// the 64 KiB segment transition, and literal-only output. The property is
/// identity, the documented compressed bound, and no decode overrun.
fn fuzzBlockRoundTrip(_: void, smith: *Smith) anyerror!void {
    var input_buf: [block_max]u8 = undefined;
    try blockRoundTrip(input_buf[0..buildShape(smith, &input_buf)]);
}

test "lz4 fuzz: block round trip" {
    try testing.fuzz({}, fuzzBlockRoundTrip, .{});
}
