//! The static dictionary and its word transforms (RFC 7932 §8, Appendices A
//! and B): the 122,784-byte word table, the 121 transforms over the 21
//! elementary operations, and the word a distance past the window resolves
//! to.
//!
//! The data is generated, never hand-copied: `scripts/brotli_dictionary_gen.py`
//! parses the vendored RFC's Appendix A hex and Appendix B table into
//! `fixtures.dictionary_bin` (DICT, the committed `dictionary.bin.base64` decoded)
//! reference's deduplicated prefix/suffix-pool transform shape). The tests pin
//! both by the RFC's own CRC-32 check values: Appendix A's DICT at
//! 0x5136cb04, and Appendix B's flat 648-byte transform sequence — rebuilt
//! from the generated tables — at 0x3d965f81.
//!
//! A transformed word is built in a 38-byte scratch (§8's bound: the largest
//! base word, 24, plus the largest affix pair, 13, plus a terminating zero)
//! and written out by the command layer, which owns the §9.3 MLEN accounting.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const fastmem = @import("fastmem");

const fixtures = @import("fixtures");

const data = @import("dictionary_data.zig");

/// §8, Appendix A — DICT: "an array of bytes", 122,784 of them, the words a
/// static dictionary reference names.
pub const words: []const u8 = fixtures.dictionary_bin;

/// §8 — "The copy length for a static dictionary reference must be between 4
/// and 24": the base word lengths the table covers.
pub const min_word_len = 4;
pub const max_word_len = 24;

/// §8 — "a buffer of 38 bytes is sufficient to store any transformed words
/// (counting a terminating zero byte)": the largest base word plus the
/// largest prefix + suffix plus one. The terminator byte is not written; the
/// returned slice carries the length.
pub const scratch_len = 38;

/// §8 — the largest valid transform id: "If transform_id is greater than
/// 120 ... the compressed stream should be rejected as invalid".
pub const max_transform_id = data.transforms.len - 1;

/// This layer's refusal.
pub const Error = error{
    /// §8 — "If transform_id is greater than 120 ... the compressed stream
    /// should be rejected as invalid." The reference reports it as
    /// `FORMAT_TRANSFORM`, the same name an emptied word's guard uses (the
    /// caller applies that guard, which needs the distance).
    BadTransform,
};

/// §8 — DOFFSET[0..24]: "an array of byte-offset values for each length",
/// from the recursion `DOFFSET[length + 1] = DOFFSET[length] + length *
/// NWORDS[length]` over Appendix A's NDBITS.
const doffset: [25]u32 = blk: {
    var offsets: [25]u32 = @splat(0);
    for (0..24) |length| {
        const nwords: u32 = if (length < 4) 0 else @as(u32, 1) << data.ndbits[length];
        offsets[length + 1] = offsets[length] + @as(u32, @intCast(length)) * nwords;
    }
    break :blk offsets;
};

/// §8, Appendix B — the elementary transform ids in the generated table's
/// numbering (the C reference's `BrotliWordTransformType`,
/// `c/common/transform.h`): Identity 0, OmitLast1..9 1..9, FermentFirst 10,
/// FermentAll 11, OmitFirst1..9 12..20. The reference's Shift types (21, 22)
/// exist for custom transforms and Appendix B never uses them.
const omit_last_9 = 9;
const ferment_first = 10;
const ferment_all = 11;
const omit_first_1 = 12;
const omit_first_9 = 20;

/// §8, Appendix B — the largest number of bytes any transform adds to a base
/// word: "The maximum number of additional bytes that a transform may add to
/// a base word is 13" (transform 73, `" the "` + `" of the "`).
const max_affix = blk: {
    var most: usize = 0;
    for (data.transforms) |triplet| {
        const prefix = poolString(data.prefix_suffix_map[triplet[0]]);
        const suffix = poolString(data.prefix_suffix_map[triplet[2]]);
        most = @max(most, prefix.len + suffix.len);
    }
    break :blk most;
};

comptime {
    // §8 — DICTSIZE = DOFFSET[24] + 24 * NWORDS[24] is exactly Appendix A's
    // DICT, and the scratch is §8's bound over the generated tables.
    if (doffset[24] + 24 * (@as(u32, 1) << data.ndbits[24]) != words.len) {
        @compileError("dictionary.bin.base64 does not decode to the length NDBITS describes");
    }
    if (max_affix != 13) @compileError("Appendix B's affix bound moved");
    if (max_word_len + max_affix + 1 != scratch_len) {
        @compileError("the scratch is not §8's bound");
    }
    for (data.transforms) |triplet| {
        if (triplet[1] > omit_first_9) @compileError("elementary transform above OmitFirst9");
    }
}

/// §8, Appendix B — the length-prefixed string at `offset` in the generated
/// prefix/suffix pool: one length byte, then that many bytes.
fn poolString(offset: u16) []const u8 {
    const len = data.prefix_suffix[offset];
    return data.prefix_suffix[offset + 1 ..][0..len];
}

/// §8 — the transformed word for a static dictionary reference. `word_id` is
/// `distance - (max allowed distance + 1)` and `length` the copy length,
/// 4..24 (the caller's §8 check). The base word is
/// `DICT[DOFFSET[length] + index * length ..]` with `index = word_id %
/// NWORDS[length]`, and the transform is `word_id >> NDBITS[length]`.
///
/// The result is written into `scratch` and returned as a slice of it.
/// `error.BadTransform` when the transform id is above 120.
pub fn transformedWord(
    scratch: *[scratch_len]u8,
    word_id: u32,
    length: u32,
) Error![]const u8 {
    assert(length >= min_word_len);
    assert(length <= max_word_len);
    const shift = data.ndbits[length];
    const transform_id = word_id >> shift;
    if (transform_id > max_transform_id) return error.BadTransform;
    const index = word_id % (@as(u32, 1) << shift);
    const offset: usize = doffset[length] + index * length;
    assert(offset + length <= words.len);
    const base = words[offset..][0..length];
    // The reference's identity fast path (`decode.c`: `transform_idx ==
    // transforms->cutOffTransforms[0]`): the base word is the transformed
    // word, no prefix, suffix, or elementary step.
    if (transform_id == data.cut_off_transforms[0]) {
        fastmem.copy(u8, scratch[0..base.len], base);
        return scratch[0..base.len];
    }
    return applyTransform(scratch, base, @intCast(transform_id));
}

/// §8, Appendix B — `transform_i(word) = prefix_i + T_i(word) + suffix_i`:
/// write transform `transform_id`'s output for `word` into `scratch` and
/// return the written prefix. `word.len` is 4..24 and `transform_id` is
/// 1..120 (the identity fast path is `transformedWord`'s).
fn applyTransform(scratch: *[scratch_len]u8, word: []const u8, transform_id: u8) []const u8 {
    const triplet = data.transforms[transform_id];
    const elementary = triplet[1];
    var source = word;
    var len = word.len;
    if (elementary >= omit_first_1 and elementary <= omit_first_9) {
        // §8 — OmitFirstk: "the last (length(word) - k) bytes of word, or
        // empty string if length(word) < k".
        const skip: usize = elementary - omit_first_1 + 1;
        source = word[@min(skip, len)..];
        len -= @min(skip, len);
    } else if (elementary <= omit_last_9) {
        // §8 — Identity (0) or OmitLastk: "the first (length(word) - k)
        // bytes of word, or empty string if length(word) < k".
        len -|= @as(usize, elementary);
    }

    var out: usize = 0;
    const prefix = poolString(data.prefix_suffix_map[triplet[0]]);
    fastmem.copy(u8, scratch[out..][0..prefix.len], prefix);
    out += prefix.len;
    fastmem.copy(u8, scratch[out..][0..len], source[0..len]);
    const start = out;
    out += len;
    const region = scratch[start..out];
    switch (elementary) {
        ferment_first => {
            if (region.len > 0) _ = ferment(region, 0);
        },
        ferment_all => {
            var pos: usize = 0;
            while (pos < region.len) pos += ferment(region, pos);
        },
        else => {},
    }
    const suffix = poolString(data.prefix_suffix_map[triplet[2]]);
    fastmem.copy(u8, scratch[out..][0..suffix.len], suffix);
    out += suffix.len;
    assert(out <= scratch_len);
    return scratch[0..out];
}

/// §8 — the RFC's Ferment: "case-flip" the UTF-8 sequence at `word[pos]`,
/// returning the sequence's length (1..3). A one-byte sequence flips the
/// ASCII letter's bit 5, a two-byte sequence the second byte's, and a
/// three-byte sequence the third byte's bits 0 and 2 (`^ 5`); the two
/// bounds guards are the RFC's — the reference's `ToUpperCase` drops them
/// and writes into its ring-buffer slack, where the suffix or the next
/// word overwrites the byte, so the emitted bytes agree.
fn ferment(word: []u8, pos: usize) usize {
    if (word[pos] < 0xC0) {
        if (word[pos] >= 'a' and word[pos] <= 'z') word[pos] ^= 32;
        return 1;
    }
    if (word[pos] < 0xE0) {
        if (pos + 1 < word.len) word[pos + 1] ^= 32;
        return 2;
    }
    if (pos + 2 < word.len) word[pos + 2] ^= 5;
    return 3;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "dictionary: RFC 7932 Appendix A's DICT by its CRC-32" {
    // RFC 7932 Appendix A — "the length is 122,784 bytes and the CRC-32 of
    // the byte sequence is 0x5136cb04".
    try testing.expectEqual(@as(usize, 122784), words.len);
    try testing.expectEqual(@as(u32, 0x5136cb04), std.hash.crc.Crc32.hash(words));
    // The hex's opening words: "time", "down", "life", "left".
    try testing.expectEqualStrings("timedownlifeleft", words[0..16]);
}

test "dictionary: RFC 7932 Appendix B's flat transform sequence by its CRC-32" {
    // RFC 7932 Appendix B — the transforms "converted to a series of bytes,
    // where each transform is the prefix sequence of bytes plus a
    // terminating zero byte, a single-byte value identifying the transform,
    // and the suffix sequence of bytes plus a terminating zero. ... The
    // length of that sequence is 648 bytes, and the CRC-32 is 0x3d965f81."
    // The flat sequence numbers the elementary transforms the RFC's way
    // ("0 for Identity, 1 for FermentFirst, 2 for FermentAll, 3 to 11 for
    // OmitFirst1 to OmitFirst9, and 12 to 20 for OmitLast1 to OmitLast9"),
    // the generated table the C reference's way, so the test maps back.
    var flat: [648]u8 = undefined;
    var at: usize = 0;
    for (data.transforms) |triplet| {
        const prefix = poolString(data.prefix_suffix_map[triplet[0]]);
        const suffix = poolString(data.prefix_suffix_map[triplet[2]]);
        fastmem.copy(u8, flat[at..][0..prefix.len], prefix);
        at += prefix.len;
        flat[at] = 0;
        at += 1;
        flat[at] = rfcType(triplet[1]);
        at += 1;
        fastmem.copy(u8, flat[at..][0..suffix.len], suffix);
        at += suffix.len;
        flat[at] = 0;
        at += 1;
    }
    try testing.expectEqual(flat.len, at);
    try testing.expectEqual(@as(u32, 0x3d965f81), std.hash.crc.Crc32.hash(&flat));
}

/// RFC 7932 Appendix B's elementary numbering, which the flat sequence (and
/// its CRC) uses, from the C reference's numbering the generated table uses.
fn rfcType(elementary: u8) u8 {
    return switch (elementary) {
        0 => 0, // Identity
        10 => 1, // FermentFirst
        11 => 2, // FermentAll
        12...20 => elementary - 9, // OmitFirst1..9 -> 3..11
        1...9 => elementary + 11, // OmitLast1..9 -> 12..20
        else => unreachable,
    };
}

test "dictionary: RFC 7932 §8's DOFFSET recursion" {
    // §8 — "DOFFSET[0] = 0; DOFFSET[length + 1] = DOFFSET[length] + length *
    // NWORDS[length]; DICTSIZE = DOFFSET[24] + 24 * NWORDS[24]".
    try testing.expectEqual(@as(u32, 0), doffset[4]);
    try testing.expectEqual(@as(u32, 4096), doffset[5]);
    try testing.expectEqual(@as(u32, 122016), doffset[24]);
    try testing.expectEqual(
        @as(u32, 122784),
        doffset[24] + 24 * (@as(u32, 1) << data.ndbits[24]),
    );
}

test "dictionary: RFC 7932 §8's word selection" {
    // §8 — "word_id = distance - (max allowed distance + 1); index = word_id
    // % NWORDS[length]; base_word = DICT[offset(length, index)..];
    // transform_id = word_id >> NDBITS[length]".
    var scratch: [scratch_len]u8 = undefined;
    // The first four-byte word is "time" (word_id 0: transform 0, index 0);
    // the next is "down".
    try testing.expectEqualStrings("time", try transformedWord(&scratch, 0, 4));
    try testing.expectEqualStrings("down", try transformedWord(&scratch, 1, 4));
    // NWORDS[4] = 1 << 10 = 1024: word_id 1024 is transform 1 (["", Identity,
    // " "]) of the first word.
    try testing.expectEqualStrings("time ", try transformedWord(&scratch, 1024, 4));
    // The last word of the last length: NWORDS[24] = 32, so the last valid
    // word_id is 120 * 32 + 31 and 121 * 32 is transform 121.
    try testing.expectEqualStrings(
        " \xe0\xa4\xbd\xe0\xa4\x95\xe0\xa5\x8d\xe0\xa4\xb0\xe0\xa4\xbf" ++
            "\xe0\xa4\xaf\xe0\xa4\xa4\xe0\xa4\xbe='",
        try transformedWord(&scratch, 120 * 32 + 31, 24),
    );
    try testing.expectError(error.BadTransform, transformedWord(&scratch, 121 * 32, 24));
}

test "dictionary: RFC 7932 §8, Appendix B's transform classes" {
    // The elementary transforms over DICT's first four-byte word ("time"),
    // with the transform ids of Appendix B's table (word_id = transform_id *
    // NWORDS[4] + index, index 0): Identity 0, OmitFirst1 3, FermentFirst 9,
    // OmitLast1 12, FermentAll 44, OmitLast9 64, and the longest affix pair,
    // transform 73 (" the " + Identity + " of the "). The expectations were
    // verified against the pinned CLI over the full 121 x 21 sweep.
    var scratch: [scratch_len]u8 = undefined;
    const cases = [_]struct { transform: u32, want: []const u8 }{
        .{ .transform = 0, .want = "time" },
        .{ .transform = 3, .want = "ime" },
        .{ .transform = 9, .want = "Time" },
        .{ .transform = 12, .want = "tim" },
        .{ .transform = 44, .want = "TIME" },
        .{ .transform = 64, .want = "" },
        .{ .transform = 73, .want = " the time of the " },
    };
    for (cases) |case| {
        try testing.expectEqualStrings(
            case.want,
            try transformedWord(&scratch, case.transform * 1024, 4),
        );
    }

    // The Ferment UTF-8 sequences: a two-byte sequence flips the second
    // byte's bit 5 ("\xc3\xa1rea" -> "\xc3\x81rea", Área), and a three-byte
    // sequence flips the third byte's `^ 5` ("\xe2\x80\x99s" ->
    // "\xe2\x80\x9cS" under FermentAll, which also uppercases the 's').
    try testing.expectEqualStrings(
        "\xc3\x81rea",
        try transformedWord(&scratch, 9 * 1024 + 894, 5),
    );
    try testing.expectEqualStrings(
        "\xe2\x80\x9cS",
        try transformedWord(&scratch, 44 * 1024 + 527, 4),
    );
}

test "dictionary: RFC 7932 §8's transformed-word bound" {
    // §8 — "The maximum number of additional bytes that a transform may add
    // to a base word is 13. Since the largest base word is 24 bytes long, a
    // buffer of 38 bytes is sufficient to store any transformed words
    // (counting a terminating zero byte)": every transform of every word
    // length fits the scratch, and the longest output is 24 + 13.
    var scratch: [scratch_len]u8 = undefined;
    var longest: usize = 0;
    for (min_word_len..max_word_len + 1) |length| {
        for (0..data.transforms.len) |transform_id| {
            const word_id = transform_id * (@as(u32, 1) << data.ndbits[length]);
            const word = try transformedWord(&scratch, @intCast(word_id), @intCast(length));
            longest = @max(longest, word.len);
        }
    }
    try testing.expectEqual(@as(usize, 13), max_affix);
    try testing.expectEqual(max_word_len + max_affix, longest);
    try testing.expect(longest < scratch_len);
}
