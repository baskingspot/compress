//! The one-shot brotli decoder (RFC 7932): `decompress` decodes one stream
//! from a byte slice into a caller-owned buffer, with no heap allocation.
//!
//! The decoded output is the match history, so `target` *is* the window: a
//! match reads back from the bytes already produced (`§8`), which is why
//! `WindowTooLarge` is not in the error set. `target` is a cap, not a
//! promise — the format records no decoded length — so nothing is written
//! past it, and `BufferTooSmall` is returned before the write that would.
//!
//! The layer namespaces stay reachable under `decode`: the streaming `Reader`
//! is composed from the same code, and the golden tests (and the fuzz targets)
//! exercise it directly.
//!
//! Format: docs/specs/rfc7932-brotli.txt. API: README.md.

const std = @import("std");
const assert = std.debug.assert;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const fastmem = @import("fastmem");

const bits = @import("bits.zig");
/// The command stream (`§5`, `§6`, `§7.1`, `§7.2`, `§9.3`, `§10`): the
/// insert-and-copy alphabet, the three block switches, the context IDs, the
/// distance element, and the copy machinery.
pub const command = @import("command.zig");
/// The context models (`§7.1`, `§7.3`): the four modes and the two context
/// maps.
pub const context = @import("context.zig");
/// The static dictionary (`§8`): the 122,784-byte word table and its 121
/// transforms.
pub const dictionary = @import("dictionary.zig");
/// The distance layer (`§4`): the four-distance ring and the special codes.
pub const distance = @import("distance.zig");
/// The stream header and the meta-block ladder (`§9.1`, `§9.2`), with the
/// compressed meta-block header's completion.
pub const frame = @import("frame.zig");
const golden = @import("golden.zig");
/// The prefix codes (`§3`): both tree forms and the canonical decode tables.
pub const prefix = @import("huffman.zig");
const internal = @import("../internal/root.zig");

/// Everything `decompress` reports: the layers' own refusals composed, plus
/// this surface's `BufferTooSmall`. The streaming `Reader` reports the same
/// names in its `err` field, minus `BufferTooSmall` (its output is the
/// caller's `Buffer`).
pub const DecompressError = error{
    /// `target` cannot hold the decoded stream.
    BufferTooSmall,
    /// `§9.1` — WBITS is the invalid 0010001 pattern.
    BadWindowBits,
    /// The input ended before the stream did.
    Truncated,
    /// `§9.2` — the metadata meta-block's reserved bit is set.
    ReservedBit,
    /// `§9.2` — MNIBBLES > 4 with an all-zero last nibble.
    ExuberantNibble,
    /// `§9.2` — MSKIPBYTES > 1 with an all-zero last byte.
    ExuberantMetaNibble,
    /// Nonzero fill bits where the format requires zeros (`§9.2`, `§9.3`).
    BadPadding,
    /// `§3.4` — a simple code's symbol is at or past the alphabet size.
    SimpleHuffmanAlphabet,
    /// `§3.4` — a simple code repeats a symbol.
    SimpleHuffmanSame,
    /// `§3.5` — the code-length code is not a complete prefix code.
    BadCodeLengthCode,
    /// `§3.5` — a code-length sequence breaks the format's rules.
    BadHuffmanCode,
    /// `§6`, `§9.3` — a block count, or the meta-block length accounting.
    BadBlockLength,
    /// `§7.3` — a context map's zero-run overruns the map.
    ContextMapRepeat,
    /// `§4` — a special distance code resolves to zero or less.
    BadDistance,
    /// `§8` — a transform id above 120, or a word the transform empties.
    BadTransform,
    /// `§8` — a dictionary reference's word length is outside 4..24.
    BadDictionary,
    /// This decoder's instantiation — a meta-block declares more than
    /// 64 trees in a category.
    TooManyTrees,
};

comptime {
    // The set callers match on is the README's list, name for name. A layer
    // that gains a name fails the build here, so the public vocabulary cannot
    // drift by accident; that every layer name is *in* the set is what the
    // `try`s in `decompress` prove (their return types are the layers'
    // composed sets).
    const vocabulary = [_][]const u8{
        "BufferTooSmall",
        "BadWindowBits",
        "Truncated",
        "ReservedBit",
        "ExuberantNibble",
        "ExuberantMetaNibble",
        "BadPadding",
        "SimpleHuffmanAlphabet",
        "SimpleHuffmanSame",
        "BadCodeLengthCode",
        "BadHuffmanCode",
        "BadBlockLength",
        "ContextMapRepeat",
        "BadDistance",
        "BadTransform",
        "BadDictionary",
        "TooManyTrees",
    };
    @setEvalBranchQuota(100_000);
    const set = @typeInfo(DecompressError).error_set.?;
    assert(set.len == vocabulary.len);
    for (vocabulary) |name| {
        var found = false;
        for (set) |entry| {
            if (std.mem.eql(u8, name, entry.name)) found = true;
        }
        assert(found);
    }
}

/// The state one decode threads through the layers: the current meta-block's
/// header (`§9.2`'s tail — the parameters, the context models, and the tree
/// region) and the command stream's state (`§4`'s four-distance ring,
/// "initialized ... at the beginning of the stream ... not reset at
/// meta-block boundaries", plus the distance tables each meta-block's
/// NPOSTFIX and NDIRECT derive).
///
/// About 691 KiB, nearly all of it the tree region, so `decompress` keeps it
/// on the stack; the streaming `Reader` keeps the same two fields, its header
/// arena in the caller's `Buffer`.
pub const State = struct {
    /// `§9.2`, `§3`, `§6`, `§7` — the current meta-block's header. Written by
    /// `frame.nextMetaBlock` before any read of it.
    header: frame.Header = undefined,
    /// `§4`, `§9.3` — the distance ring and the derived distance tables.
    commands: command.State = .{},
};

/// Decode one brotli stream (`§9.1`'s header through the last meta-block's
/// last bit) from `source` into `target`, and return the decoded length.
///
/// The format records no decoded length, so `target` is a cap: the decoded
/// bytes are also the match history (`§8`), and a stream that would write
/// past the cap fails `error.BufferTooSmall` before that write. Bytes after
/// the stream's last byte are ignored, and the number consumed is not
/// reported; the C reference's one-shot decoder is also single-stream. Use
/// `brotli.Reader` for the stream boundary.
///
/// Zero bytes of input is `Truncated` (no stream began; the empty stream is
/// the single byte `06`), and a stream of only empty meta-blocks decodes to
/// zero bytes.
///
/// On any error `target` can hold partial output, which must not be used.
/// The state is about 691 KiB of stack, nearly all of it the meta-block tree
/// region, so give decoding threads 1 MiB or more. Nothing is allocated.
pub fn decompress(source: []const u8, target: []u8) DecompressError!usize {
    // The fields are initialized separately, never as one aggregate: a
    // `.{}` whole-struct store lowers to a memcpy of a 709,824-byte comptime
    // constant into the frame (the header's `undefined` bytes ride along),
    // a per-call fixed cost that dominated small streams. Written this way
    // the header stays untouched until `nextMetaBlock` fills it.
    var state: State = undefined;
    state.commands = .{};
    var br: bits.BitReader = .init(source);
    const stream = try frame.readStreamHeader(bits.BitReader, &br);
    var pos: usize = 0;
    while (true) {
        const meta = (try frame.nextMetaBlock(bits.BitReader, &br, &state.header)) orelse break;
        assert(pos <= target.len);
        // The window the command layer writes is exactly the target prefix
        // this meta-block fills, so the cap is checked before the call: a
        // stream larger than the caller's buffer never reaches a write, and
        // the command layer's own MLEN accounting stays the invalid-stream
        // class (`§9.3`), never this one.
        if (meta.mlen > target.len - pos) return error.BufferTooSmall;
        switch (meta.kind) {
            .uncompressed => {
                // `§9.2` — "the rest of the meta-block contains MLEN bytes
                // of literal data", at the next byte boundary.
                try br.takeBytes(target[pos..][0..meta.mlen]);
                pos += meta.mlen;
            },
            .compressed => pos = try command.decodeMetaBlock(
                bits.BitReader,
                &br,
                &state.header,
                &state.commands,
                target[0 .. pos + meta.mlen],
                pos,
                meta.mlen,
                stream.window_size,
            ),
        }
        if (meta.is_last) {
            // `§9.3` — "If the last command of the last non-empty meta-block
            // does not end on a byte boundary, the unused bits in the last
            // byte must be zeros."
            try br.alignToByte();
            break;
        }
    }
    assert(pos <= target.len);
    return pos;
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/specs/rfc7932-brotli.txt §1.5.1 (bit order),
// §9.1 (the header), §9.2 (the meta-block ladder), §9.3 (the last-byte
// fill), §8 (the dictionary class). The fixtures are `golden.zig`'s, each
// verified with the pinned CLI (brotli 1.2.0).
// ---------------------------------------------------------------------------

/// The README's Usage snippet, as written: the caller allocates a cap, the
/// decoded length is the return value, and exactly that many bytes reach the
/// writer.
fn decodeTo(gpa: Allocator, stream: []const u8, out: *Io.Writer) !void {
    const plain = try gpa.alloc(u8, 1024 * 1024); // a cap; brotli records no size
    defer gpa.free(plain);
    const n = try decompress(stream, plain);
    try out.writeAll(plain[0..n]);
}

/// Decode `source` into a sentinel-filled target and check the output and the
/// bytes past it: the shape every decode test runs.
fn expectDecode(source: []const u8, expected: []const u8) !void {
    var target: [4096]u8 = undefined;
    internal.sentinel.fill(&target);
    const n = try decompress(source, &target);
    try testing.expectEqual(expected.len, n);
    try testing.expectEqualSlices(u8, expected, target[0..n]);
    try internal.sentinel.expect(&target, n);
}

test "the layer types are reachable through the decode namespace" {
    // The layers the decoder is composed from stay reachable under `decode`
    // (OQ2): the streaming `Reader` is built from the same code, and the
    // golden tests (and the fuzz targets) exercise the same functions.
    // Referencing every public decl of each also keeps the surface honest: a
    // decl that no longer compiles fails here.
    testing.refAllDecls(command);
    testing.refAllDecls(context);
    testing.refAllDecls(dictionary);
    testing.refAllDecls(distance);
    testing.refAllDecls(frame);
    testing.refAllDecls(prefix);
}

test "README usage: one-shot decode over buffers the caller owns" {
    // The README's Usage snippet through its own shape: an allocator-owned
    // cap and the decoded length written out.
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try decodeTo(testing.allocator, golden.cli_text_q11.bytes, &out.writer);
    try testing.expectEqualStrings(golden.cli_text_q11.plain, out.written());

    // The snippet's error path: a cap too small for the stream is
    // `BufferTooSmall`, never a write past the cap.
    var small: [4]u8 = undefined;
    internal.sentinel.fill(&small);
    try testing.expectError(error.BufferTooSmall, decompress(golden.window_bound.bytes, &small));
    try internal.sentinel.expect(&small, 0);
}

test "empty input is Truncated, and the empty stream family decodes to nothing" {
    // RFC 7932 §10 — "If the stream ends before the completion of the last
    // meta-block, then the stream should be rejected as invalid": a zero-byte
    // input is no stream at all, and the empty *stream* is the one-byte `06`
    // family.
    var target: [64]u8 = undefined;
    internal.sentinel.fill(&target);
    try testing.expectError(error.Truncated, decompress(&[_]u8{}, &target));

    for (golden.empty_streams) |stream| {
        internal.sentinel.fill(&target);
        const n = try decompress(stream, &target);
        try testing.expectEqual(@as(usize, 0), n);
        try internal.sentinel.expect(&target, n);
    }

    // T5 — a metadata meta-block with ISLAST set ends the stream too.
    for (golden.last_metadata_streams) |stream| {
        internal.sentinel.fill(&target);
        const n = try decompress(stream, &target);
        try testing.expectEqual(@as(usize, 0), n);
        try internal.sentinel.expect(&target, n);
    }
}

test "metadata and uncompressed meta-blocks pass through" {
    // RFC 7932 §2 — a metadata meta-block's bytes are "not part of either the
    // sliding window or the uncompressed data" and are never literal context;
    // §9.2 — an uncompressed meta-block's MLEN bytes follow at the next byte
    // boundary.
    for (golden.metadata_streams) |stream| {
        try expectDecode(stream.bytes, stream.plain);
    }
    for (golden.uncompressed_streams) |stream| {
        try expectDecode(stream.bytes, stream.plain);
    }
    // The p1 of a compressed meta-block's first literal is the previous
    // uncompressed meta-block's last byte (§7.1).
    try expectDecode(golden.uncompressed_context.bytes, golden.uncompressed_context.plain);
    // §10 — a copy across a meta-block boundary, and the stream-scoped ring.
    try expectDecode(golden.cross_meta_block.bytes, golden.cross_meta_block.plain);
}

test "decompress decodes the golden corpus through the public entry point" {
    // The hand-built vectors of every layer, whole streams end to end: the
    // day-one ladder fixture, both prefix-code forms, the context map, the
    // command stream's ring and switches, the distance arithmetic, and the
    // dictionary class. Each vector was verified with the pinned CLI (brotli
    // 1.2.0) before landing (golden.zig records the verdicts).
    const cases = [_]golden.Stream{
        golden.hand_stream,
        golden.unordered_symbol_stream,
        golden.wide_symbol_stream,
        golden.high_literal_stream,
        golden.complex_tree_stream,
        golden.complex_single_stream,
        golden.repeat16_stream,
        golden.context_map_stream,
        golden.special_codes,
        golden.ring_init_second,
        golden.ring_init_third,
        golden.ring_init_last,
        golden.mlen_exact_insert,
        golden.block_switch_literal_t1,
        golden.block_switch_command,
        golden.distance_switch_t2,
        golden.ndirect,
        golden.npostfix,
        golden.distance_context,
        golden.context_mode_msb6,
        golden.context_mode_utf8,
        golden.context_mode_signed,
        golden.ring_no_push_zero,
        golden.dictionary_word,
        golden.dictionary_ferment,
        golden.dictionary_ferment_utf8,
        golden.dictionary_affix,
        golden.dictionary_omit,
        golden.dictionary_identity_24,
        golden.dictionary_empty,
        golden.window_bound,
    };
    for (cases) |case| try expectDecode(case.bytes, case.plain);
}

test "decompress decodes the CLI's own streams, every shape and quality" {
    // The pinned CLI's own output (brotli 1.2.0) over four inputs at the five
    // qualities slice 3 landed, with their plaintext: the encoder's round trip
    // is the decoder's conformance evidence. The text rows at q5 and up carry
    // dictionary references (F6), so they are the dictionary port's live
    // streams; every row decodes byte-exact.
    const cases = [_]golden.Stream{
        golden.cli_text_q1,
        golden.cli_text_q2,
        golden.cli_text_q5,
        golden.cli_text_q9,
        golden.cli_text_q11,
        golden.cli_repeat_q1,
        golden.cli_repeat_q2,
        golden.cli_repeat_q5,
        golden.cli_repeat_q9,
        golden.cli_repeat_q11,
        golden.cli_run_q1,
        golden.cli_run_q2,
        golden.cli_run_q5,
        golden.cli_run_q9,
        golden.cli_run_q11,
        golden.cli_digits_q1,
        golden.cli_digits_q2,
        golden.cli_digits_q5,
        golden.cli_digits_q9,
        golden.cli_digits_q11,
    };
    for (cases) |case| try expectDecode(case.bytes, case.plain);
}

test "decompress decodes the CLI's largest stream byte-exact" {
    // `cli_golden_q9_w16`: the pinned CLI's own output over the frozen
    // `.in` bytes (golden.zig's text at the commit that landed the fixture),
    // 34,382 bytes in 8,192. One stream pins the four §4/§3.5 rules the
    // oracle lane alone used to catch: the implicit-distance and
    // dictionary-reference push exclusions, the 16/17 repeat reset, and the
    // first-length-16 rule.
    const plain = golden.cli_golden_q9_w16.plain;
    const target = try testing.allocator.alloc(u8, plain.len);
    defer testing.allocator.free(target);
    internal.sentinel.fill(target);
    const n = try decompress(golden.cli_golden_q9_w16.bytes, target);
    try testing.expectEqual(plain.len, n);
    try testing.expectEqualSlices(u8, plain, target[0..n]);
    try internal.sentinel.expect(target, n);
}

test "decompress decodes RFC 7932 §11.1's trivial compressor's streams" {
    // RFC 7932 §11.1 — every N-byte input has a valid stream of at most
    // N + (3 * (N >> 16) + 5) bytes; the 100,000-byte case meets the bound
    // exactly and is decoded here through the public entry point.
    const source = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(source);
    for (source, 0..) |*byte, i| byte.* = @intCast((i * 7 + 3) & 0xFF);

    const bound = golden.trivialBound(source.len);
    const stream = try testing.allocator.alloc(u8, bound);
    defer testing.allocator.free(stream);
    const stream_len = golden.trivialCompress(source, stream);
    try testing.expectEqual(bound, stream_len);

    const target = try testing.allocator.alloc(u8, source.len);
    defer testing.allocator.free(target);
    internal.sentinel.fill(target);
    const n = try decompress(stream[0..stream_len], target);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, target[0..n]);
    try internal.sentinel.expect(target, n);
}

test "the target is a cap: BufferTooSmall before the write that would pass it" {
    // The README's contract — "returns `error.BufferTooSmall` before any write
    // that would pass the end". `mlen_exact_insert` is two meta-blocks
    // ("AAAA" then "B"): the first fits a 4-byte cap, the second does not, and
    // the first meta-block's bytes are the partial output a caller must not
    // use.
    var four: [4]u8 = undefined;
    internal.sentinel.fill(&four);
    try testing.expectError(
        error.BufferTooSmall,
        decompress(golden.mlen_exact_insert.bytes, &four),
    );
    try testing.expectEqualSlices(u8, "AAAA", &four);

    // Exactly the decoded length is enough, and one byte less is not.
    try expectDecode(golden.mlen_exact_insert.bytes, golden.mlen_exact_insert.plain);
    var three: [3]u8 = undefined;
    internal.sentinel.fill(&three);
    try testing.expectError(
        error.BufferTooSmall,
        decompress(golden.mlen_exact_insert.bytes, &three),
    );

    // A compressed meta-block larger than the cap fails before its first
    // write: nothing of the meta-block reaches the target.
    var tiny: [1]u8 = undefined;
    internal.sentinel.fill(&tiny);
    try testing.expectError(error.BufferTooSmall, decompress(golden.window_bound.bytes, &tiny));
    try testing.expectEqual(internal.sentinel.at(0), tiny[0]);
}

test "the stream ends at its last byte; trailing bytes are the caller's" {
    // The README's boundary rule — "`decompress` ignores whatever follows the
    // stream's last byte" — where both references fail closed by default
    // (T4).
    var framed: [32]u8 = undefined;
    const stream = golden.hand_stream.bytes;
    fastmem.copy(u8, framed[0..stream.len], stream);
    fastmem.set(u8, framed[stream.len..], 0xFF);
    try expectDecode(framed[0 .. stream.len + 8], golden.hand_stream.plain);

    // A second stream there is not decoded either: one call, one stream.
    fastmem.copy(u8, framed[stream.len..][0..stream.len], stream);
    try expectDecode(framed[0 .. 2 * stream.len], golden.hand_stream.plain);
}

test "the last byte's fill must be zero (RFC 7932 §9.3)" {
    // The day-one fixture's 70 bits leave two fill bits in its ninth byte;
    // setting bit 7 is the CLI's FORMAT_PADDING_2 (-15), verified with the
    // pinned CLI (`brotli -d -v -c`), and our `BadPadding`.
    var filled = [_]u8{ 0x02, 0x00, 0x00, 0x00, 0x44, 0x50, 0x20, 0x10, 0x80 };
    var target: [8]u8 = undefined;
    internal.sentinel.fill(&target);
    try testing.expectError(error.BadPadding, decompress(&filled, &target));

    // The zero-fill form decodes: the fixture itself.
    filled[8] = 0x00;
    try expectDecode(&filled, golden.hand_stream.plain);
}

test "decompress reports the layers' named refusals" {
    // One vector per corruption class, each verified with the pinned CLI
    // (`brotli -d -v -c`): the CLI's FORMAT_* reason is the class name.
    var target: [4096]u8 = undefined;
    internal.sentinel.fill(&target);
    // RFC 7932 §9.1 — 0010001 is "invalid and must not be used" (T3).
    try testing.expectError(error.BadWindowBits, decompress(&[_]u8{0x11}, &target));
    // RFC 7932 §3.4 — a duplicate symbol, and a symbol past the alphabet.
    try testing.expectError(
        error.SimpleHuffmanSame,
        decompress(golden.duplicate_symbol_streams[0], &target),
    );
    try testing.expectError(
        error.SimpleHuffmanAlphabet,
        decompress(golden.out_of_alphabet_streams[0], &target),
    );
    // RFC 7932 §9.3 — the three MLEN overruns are one class (F4): the
    // insert, the copy, and a dictionary word that runs past MLEN.
    try testing.expectError(
        error.BadBlockLength,
        decompress(golden.mlen_insert_overrun.bytes, &target),
    );
    try testing.expectError(
        error.BadBlockLength,
        decompress(golden.mlen_copy_overrun.bytes, &target),
    );
    try testing.expectError(
        error.BadBlockLength,
        decompress(golden.dictionary_mlen_overrun.bytes, &target),
    );
    // RFC 7932 §4 — a special code resolving to zero (FORMAT_DISTANCE).
    try testing.expectError(error.BadDistance, decompress(golden.negative_special.bytes, &target));
    // RFC 7932 §8 — a dictionary length outside 4..24, and a transform id
    // above 120.
    try testing.expectError(
        error.BadDictionary,
        decompress(golden.dictionary_length.bytes, &target),
    );
    try testing.expectError(
        error.BadTransform,
        decompress(golden.dictionary_transform.bytes, &target),
    );
    // RFC 7932 §9.2 — the metadata reserved bit, the exuberant nibble, and a
    // nonzero fill where the format requires zeros. (The ladder's own tests
    // cover the rest of the family; this pins them through `decompress`.)
    try testing.expectError(error.ReservedBit, decompress(&[_]u8{0x3A}, &target));
    try testing.expectError(
        error.ExuberantNibble,
        decompress(&[_]u8{ 0x2A, 0x00, 0x00, 0x00 }, &target),
    );
    try testing.expectError(error.BadPadding, decompress(&[_]u8{0x0E}, &target));
}

test "a stream cut short anywhere is Truncated, never a short decode" {
    // RFC 7932 §10 — "If the stream ends before the completion of the last
    // meta-block, then the stream should be rejected as invalid": every
    // strict prefix of a valid stream fails, and none of them is accepted as
    // a shorter stream. The CLI reports "truncated input" for the same
    // prefixes (brotli 1.2.0).
    const streams = [_][]const u8{
        golden.hand_stream.bytes,
        golden.cli_text_q11.bytes,
        golden.window_bound.bytes,
        golden.cross_meta_block.bytes,
        golden.last_metadata_streams[1],
    };
    for (streams) |stream| {
        var target: [4096]u8 = undefined;
        for (0..stream.len) |n| {
            internal.sentinel.fill(&target);
            try testing.expectError(error.Truncated, decompress(stream[0..n], &target));
        }
    }
    // The empty family's one-byte forms too: a prefix of `06` is no stream.
    var target: [8]u8 = undefined;
    for (golden.empty_streams) |stream| {
        for (0..stream.len) |n| {
            internal.sentinel.fill(&target);
            try testing.expectError(error.Truncated, decompress(stream[0..n], &target));
        }
    }
}
