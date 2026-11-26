//! Hand-composed LZ4 block fixtures from docs/specs/lz4-block-format.md.
//! The table covers both token fields, the final-sequence grammar, overlap,
//! and corrupt-input refusals. The sweep checks every small offset against an
//! independently constructed expected output and a decode-overrun sentinel.

const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const decode = @import("decode.zig");
const decompressBlock = decode.decompressBlock;
const repeat = @import("../repeat.zig");

const guard_len = 256;

const DecodeCase = struct {
    desc: []const u8,
    source: []const u8,
    decoded_len: usize,
    want: []const u8,
    want_err: bool,
};

fn checkDecodeCase(buffer: []u8, case: DecodeCase) !void {
    testing.expect(case.decoded_len + guard_len <= buffer.len) catch {
        return error.TestUnexpectedSize;
    };
    sentinel.fill(buffer[0 .. case.decoded_len + guard_len]);
    const target = buffer[0..case.decoded_len];
    if (case.want_err) {
        try testing.expectError(error.DecompressionFailed, decompressBlock(case.source, target));
    } else {
        const written = try decompressBlock(case.source, target);
        try testing.expectEqual(case.decoded_len, written);
        try testing.expectEqualSlices(u8, case.want, target);
    }
    try sentinel.expect(buffer[0 .. case.decoded_len + guard_len], case.decoded_len);
}

const valid_cases = valid: {
    @setEvalBranchQuota(10_000);
    break :valid [_]DecodeCase{
        .{
            .desc = "empty input is one zero token",
            .source = "\x00",
            .decoded_len = 0,
            .want = "",
            .want_err = false,
        },
        .{
            .desc = "the final token ignores its match bits",
            .source = "\x0f",
            .decoded_len = 0,
            .want = "",
            .want_err = false,
        },
        .{
            .desc = "the final literal token ignores its match bits",
            .source = "\x3fabc",
            .decoded_len = 3,
            .want = "abc",
            .want_err = false,
        },
        .{
            .desc = "literal length 15 has a zero extension",
            .source = "\xf0\x00123456789abcdef",
            .decoded_len = 15,
            .want = "123456789abcdef",
            .want_err = false,
        },
        .{
            .desc = "literal length 48 from the specification",
            .source = "\xf0\x21" ++ repeat.repeatString(".", 48),
            .decoded_len = 48,
            .want = repeat.repeatString(".", 48),
            .want_err = false,
        },
        .{
            .desc = "literal length 280 from the specification",
            .source = "\xf0\xff\x0a" ++ repeat.repeatString(".", 280),
            .decoded_len = 280,
            .want = repeat.repeatString(".", 280),
            .want_err = false,
        },
        .{
            .desc = "a four-byte match and an empty final sequence",
            .source = "\x40abcd\x04\x00\x00",
            .decoded_len = 8,
            .want = "abcdabcd",
            .want_err = false,
        },
        .{
            .desc = "one trailing literal and a late last match are accepted",
            .source = "\x40abcd\x04\x00\x10z",
            .decoded_len = 9,
            .want = "abcdabcdz",
            .want_err = false,
        },
        .{
            .desc = "match length 19 has a zero extension",
            .source = "\x1fA\x01\x00\x00\x00",
            .decoded_len = 20,
            .want = repeat.repeatString("A", 20),
            .want_err = false,
        },
        .{
            .desc = "a match length crosses the 255 extension",
            .source = "\x1fA\x01\x00\xff\x00\x00",
            .decoded_len = 275,
            .want = repeat.repeatString("A", 275),
            .want_err = false,
        },
        .{
            .desc = "a zero-literal match follows another match",
            .source = "\x40abcd\x04\x00\x00\x04\x00\x00",
            .decoded_len = 12,
            .want = "abcdabcdabcd",
            .want_err = false,
        },
    };
};

fn invalid(desc: []const u8, source: []const u8, decoded_len: usize) DecodeCase {
    return .{
        .desc = desc,
        .source = source,
        .decoded_len = decoded_len,
        .want = "",
        .want_err = true,
    };
}

const invalid_cases = [_]DecodeCase{
    invalid("empty source", "", 0),
    invalid("missing literal extension", "\xf0", 0),
    invalid("truncated literal extension", "\xf0\xff", 0),
    invalid("truncated literals", "\x30ab", 3),
    invalid("literals overflow the expected output", "\x30abc", 2),
    invalid("missing offset", "\x10A", 5),
    invalid("truncated offset", "\x10A\x01", 5),
    invalid("zero offset", "\x10A\x00\x00\x00", 5),
    invalid("offset before output start", "\x10A\x02\x00\x00", 5),
    invalid("offset before an empty output", "\x00\x01\x00\x00", 4),
    invalid("missing match extension", "\x1fA\x01\x00", 20),
    invalid("truncated match extension", "\x1fA\x01\x00\xff", 275),
    invalid("missing final literal sequence", "\x10A\x01\x00", 5),
    invalid("match overflows the expected output", "\x11A\x01\x00\x00", 5),
    invalid("final sequence falls short", "\x10A\x01\x00\x00", 6),
    invalid("trailing token after final literals", "\x30abc\x00", 3),
};

test "golden decode: valid block vectors" {
    // docs/specs/lz4-block-format.md, Compressed block format and End of block
    // conditions §1. The late-match case deliberately breaks §2 and §3.
    var buffer: [512 + guard_len]u8 = undefined;
    for (valid_cases) |case| {
        checkDecodeCase(&buffer, case) catch |err| {
            print("\nFAIL: {s}\n", .{case.desc});
            return err;
        };
    }
}

test "golden decode: corrupt and inconsistent blocks fail" {
    // docs/specs/lz4-block-format.md, Safe decoding and Large lengths.
    var buffer: [512 + guard_len]u8 = undefined;
    for (invalid_cases) |case| {
        checkDecodeCase(&buffer, case) catch |err| {
            print("\nFAIL: {s}\n", .{case.desc});
            return err;
        };
    }
}

/// Append a token extension for a length whose nibble is 15.
fn putExtendedLength(target: []u8, length: usize) usize {
    var remaining = length - 15;
    var written: usize = 0;
    while (remaining >= 255) : (remaining -= 255) {
        target[written] = 255;
        written += 1;
    }
    target[written] = @intCast(remaining);
    return written + 1;
}

test "golden decode: length, offset, and suffix sweep" {
    // docs/specs/lz4-block-format.md, Compressed block format: offset and
    // matchlength. The expected match is built one byte at a time, independent
    // of the decoder's SIMD copy machinery.
    const prefix = "abcdefghijklmnopqrstuvwxyz012345";
    const suffix = "ABCDEFGH";
    var source_buf: [256]u8 = undefined;
    var want_buf: [128]u8 = undefined;
    var got_buf: [128 + guard_len]u8 = undefined;

    for (4..41) |match_len| {
        for (1..33) |offset| {
            for (0..9) |suffix_len| {
                const decoded_len = prefix.len + match_len + suffix_len;
                const match_code = match_len - 4;
                var in_pos: usize = 0;
                source_buf[in_pos] = 0xf0 | @as(u8, @intCast(@min(match_code, 15)));
                in_pos += 1;
                in_pos += putExtendedLength(source_buf[in_pos..], prefix.len);
                internal.constant.copyInto(prefix, source_buf[in_pos..][0..prefix.len]);
                in_pos += prefix.len;
                source_buf[in_pos] = @truncate(offset);
                source_buf[in_pos + 1] = 0;
                in_pos += 2;
                if (match_code >= 15) {
                    in_pos += putExtendedLength(source_buf[in_pos..], match_code);
                }
                source_buf[in_pos] = @intCast(suffix_len << 4);
                in_pos += 1;
                fastmem.copy(u8, source_buf[in_pos..][0..suffix_len], suffix[0..suffix_len]);
                in_pos += suffix_len;

                internal.constant.copyInto(prefix, want_buf[0..prefix.len]);
                for (0..match_len) |i| {
                    want_buf[prefix.len + i] = want_buf[prefix.len + i - offset];
                }
                fastmem.copy(
                    u8,
                    want_buf[prefix.len + match_len ..][0..suffix_len],
                    suffix[0..suffix_len],
                );

                const case: DecodeCase = .{
                    .desc = "sweep",
                    .source = source_buf[0..in_pos],
                    .decoded_len = decoded_len,
                    .want = want_buf[0..decoded_len],
                    .want_err = false,
                };
                checkDecodeCase(&got_buf, case) catch |err| {
                    print("\nFAIL length={d} offset={d} suffix={d}: {s}\n", .{
                        match_len, offset, suffix_len, @errorName(err),
                    });
                    return err;
                };
            }
        }
    }
}

test "golden decode: offset 65535" {
    // docs/specs/lz4-block-format.md, Compressed block format: the maximum
    // offset is 65535. A 65,535-byte literal is followed by a four-byte match
    // back to its first four bytes and the final empty token.
    const literal_len = 65535;
    const extension_len = 257;
    const source_len = 1 + extension_len + literal_len + 2 + 1;
    const decoded_len = literal_len + 4;
    const source = try testing.allocator.alloc(u8, source_len);
    defer testing.allocator.free(source);
    var in_pos: usize = 0;
    source[in_pos] = 0xf0;
    in_pos += 1;
    fastmem.set(u8, source[in_pos..][0 .. extension_len - 1], 255);
    in_pos += extension_len - 1;
    source[in_pos] = 240;
    in_pos += 1;
    fastmem.set(u8, source[in_pos..][0..literal_len], '.');
    internal.constant.copyInto("abcd", source[in_pos..][0..4]);
    in_pos += literal_len;
    source[in_pos] = 255;
    source[in_pos + 1] = 255;
    in_pos += 2;
    source[in_pos] = 0;
    in_pos += 1;
    try testing.expectEqual(source_len, in_pos);

    const buffer = try testing.allocator.alloc(u8, decoded_len + guard_len);
    defer testing.allocator.free(buffer);
    sentinel.fill(buffer);
    const written = try decompressBlock(source, buffer[0..decoded_len]);
    try testing.expectEqual(decoded_len, written);
    try testing.expectEqualSlices(u8, "abcd", buffer[0..4]);
    try testing.expectEqualSlices(u8, "abcd", buffer[literal_len..decoded_len]);
    try sentinel.expect(buffer, decoded_len);
}
