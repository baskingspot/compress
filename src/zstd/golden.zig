//! Fixtures shared by every zstd layer's tests: the Appendix A FSE tables,
//! table descriptions and Huffman weights from real encoder output, literals
//! and sequences sections from real frames, and whole frames, good and
//! corrupt, for the block, frame, and streaming layers. Provenance is noted
//! beside each group. Helpers: `hex` (comptime hex literals), `buildFrame`
//! (assembles a frame from block contents), `expectDecoded` (the shared
//! decode check), and the corpus `Shape`/`fillShape` the encoder tests
//! rebuild their inputs from. "The CLI" in the comments below is the zstd CLI v1.5.7,
//! the reference decoder the fixtures were generated and checked with.
//!
//! Format: docs/research/specs/rfc8878-zstd.txt

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");

/// Comptime hex decoding, so the vectors keep the spelling of their source
/// (the CLI's own hex output, the research harness's dumps) instead of being
/// transcribed into byte lists.
fn hex(comptime text: []const u8) [text.len / 2]u8 {
    @setEvalBranchQuota(1_000_000);
    comptime assert(text.len % 2 == 0);
    var bytes: [text.len / 2]u8 = undefined;
    for (&bytes, 0..) |*byte, i| {
        byte.* = std.fmt.parseInt(u8, text[i * 2 ..][0..2], 16) catch unreachable;
    }
    return bytes;
}

/// Check a decode's result against the expectation: `written` equals
/// `expected.len`, the bytes match, and the sentinel past them is untouched,
/// so a write past `written` is caught. The caller sizes `target` and must
/// have sentinel-filled it before the decode. This is the shared tail of the
/// layers' decode-into-target helpers.
pub fn expectDecoded(target: []const u8, written: usize, expected: []const u8) !void {
    try testing.expectEqual(expected.len, written);
    try testing.expectEqualSlices(u8, expected, target[0..written]);
    try internal.sentinel.expect(target, written);
}

/// One row of an Appendix A table (`§4.1`'s Symbol / Num_Bits / Baseline).
pub const TableRow = struct {
    symbol: u8,
    num_bits: u5,
    baseline: u16,
};

// The `pair_*` fixtures are the RFC's Huffman worked example (`§4.2.2`),
// hand-built (`docs/research/zstd-notes.md` §5.4): a 19-byte frame whose
// literals stream is `01 0D` or `10 0D`, decoding to `00 01 04 05` and
// `00 01 05 04` respectively on both the CLI and Zig std. `pair_tree` is the
// direct-weights tree description, `pair_stream` the Table 25 stream, and
// `pair_errata_stream` the Table 26 stream (errata 8195), which no conformant
// decoder follows.
/// RFC 8878 §4.2.2 — the example's Huffman tree description: the direct
/// mode, `Number_of_Symbols = 5`, weights 4, 3, 2, 0, 1 (`§4.2.1.1`).
pub const pair_tree = [_]u8{ 0x84, 0x43, 0x20, 0x10 };
/// RFC 8878 §4.2.1.3 Table 25 — the codes of `pair_tree`: 4 -> 0000,
/// 5 -> 0001 (the RFC's §4.2.2 example swaps them; errata 8195).
pub const pair_stream = [_]u8{ 0x01, 0x0d };
/// The literals `pair_stream` decodes to: "0145" = symbols 0, 1, 4, 5.
pub const pair_literals = [_]u8{ 0, 1, 4, 5 };
/// The §4.2.2 example's own bytes (errata 8195): they decode to 0, 1, 5, 4
/// — the swapped assignment no decoder follows.
pub const pair_errata_stream = [_]u8{ 0x10, 0x0d };
pub const pair_errata_literals = [_]u8{ 0, 1, 5, 4 };
/// `pair_tree`'s `Max_Number_of_Bits` (`§4.2.1`: the completion lands on 16).
pub const pair_max_bits: u5 = 4;
/// The whole literals sections of the example and its errata variant
/// (`§3.1.1.3.1.1` Size_Format 00, one stream; Compressed_Size = 6 covers the
/// 4-byte tree and the stream): the 3-byte header, the tree, and the stream.
/// Decoding the section must give `pair_literals` / `pair_errata_literals`.
pub const pair_literals_section: [9]u8 = [3]u8{ 0x42, 0x80, 0x01 } ++ pair_tree ++ pair_stream;
pub const pair_errata_literals_section: [9]u8 =
    [3]u8{ 0x42, 0x80, 0x01 } ++ pair_tree ++ pair_errata_stream;

// The Appendix A tables below are the spec's A.1, A.2, and A.3 rows, minus
// each table's first data row, which is errata 6441's all-zero state-0
// duplicate (`docs/research/zstd-notes.md` §4): 64 + 64 + 32 real rows. The
// three `*_defaultDistribution` arrays of `§3.1.1.3.2.2` are not here. They
// live in `sequences.zig`, whose Predefined_Mode builds its tables from them
// and whose tests cross-check them against these rows.
pub const literals_length_table = [_]TableRow{
    .{ .symbol = 0, .num_bits = 4, .baseline = 0 },
    .{ .symbol = 0, .num_bits = 4, .baseline = 16 },
    .{ .symbol = 1, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 3, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 4, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 6, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 7, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 9, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 10, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 12, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 14, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 16, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 18, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 19, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 21, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 22, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 24, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 25, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 26, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 27, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 29, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 31, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 0, .num_bits = 4, .baseline = 32 },
    .{ .symbol = 1, .num_bits = 4, .baseline = 0 },
    .{ .symbol = 2, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 4, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 5, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 7, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 8, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 10, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 11, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 13, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 16, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 17, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 19, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 20, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 22, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 23, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 25, .num_bits = 4, .baseline = 0 },
    .{ .symbol = 25, .num_bits = 4, .baseline = 16 },
    .{ .symbol = 26, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 28, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 30, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 0, .num_bits = 4, .baseline = 48 },
    .{ .symbol = 1, .num_bits = 4, .baseline = 16 },
    .{ .symbol = 2, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 3, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 5, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 6, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 8, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 9, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 11, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 12, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 15, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 17, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 18, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 20, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 21, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 23, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 24, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 35, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 34, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 33, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 32, .num_bits = 6, .baseline = 0 },
};
pub const match_length_table = [_]TableRow{
    .{ .symbol = 0, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 1, .num_bits = 4, .baseline = 0 },
    .{ .symbol = 2, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 3, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 5, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 6, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 8, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 10, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 13, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 16, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 19, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 22, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 25, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 28, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 31, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 33, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 35, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 37, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 39, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 41, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 43, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 45, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 1, .num_bits = 4, .baseline = 16 },
    .{ .symbol = 2, .num_bits = 4, .baseline = 0 },
    .{ .symbol = 3, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 4, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 6, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 7, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 9, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 12, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 15, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 18, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 21, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 24, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 27, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 30, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 32, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 34, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 36, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 38, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 40, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 42, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 44, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 1, .num_bits = 4, .baseline = 32 },
    .{ .symbol = 1, .num_bits = 4, .baseline = 48 },
    .{ .symbol = 2, .num_bits = 4, .baseline = 16 },
    .{ .symbol = 4, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 5, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 7, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 8, .num_bits = 5, .baseline = 32 },
    .{ .symbol = 11, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 14, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 17, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 20, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 23, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 26, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 29, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 52, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 51, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 50, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 49, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 48, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 47, .num_bits = 6, .baseline = 0 },
    .{ .symbol = 46, .num_bits = 6, .baseline = 0 },
};
pub const offset_table = [_]TableRow{
    .{ .symbol = 0, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 6, .num_bits = 4, .baseline = 0 },
    .{ .symbol = 9, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 15, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 21, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 3, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 7, .num_bits = 4, .baseline = 0 },
    .{ .symbol = 12, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 18, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 23, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 5, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 8, .num_bits = 4, .baseline = 0 },
    .{ .symbol = 14, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 20, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 2, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 7, .num_bits = 4, .baseline = 16 },
    .{ .symbol = 11, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 17, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 22, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 4, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 8, .num_bits = 4, .baseline = 16 },
    .{ .symbol = 13, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 19, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 1, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 6, .num_bits = 4, .baseline = 16 },
    .{ .symbol = 10, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 16, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 28, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 27, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 26, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 25, .num_bits = 5, .baseline = 0 },
    .{ .symbol = 24, .num_bits = 5, .baseline = 0 },
};
// The two table descriptions below are the literals-length and offset
// descriptions from the first compressed block of a `zstd -1` frame of a
// synthetic mixed corpus: `zstd` v1.5.7's own `FSE_writeNCount` output. They
// pin the `§4.1.1` description reader against real encoder output, zero runs
// included. The `*_counts` arrays are what the reader must recover, and the
// description's byte count is what the section's next structure depends on.
pub const literals_length_description = [_]u8{
    0x14, 0x1f, 0x01, 0x20, 0x10, 0xb4, 0xd0, 0xbf, 0x00,
};
pub const literals_length_description_counts = [_]i16{
    496, 7, -1, -1, -1, -1, 0, -1, 0, -1, 0, 0,
    0,   0, 0,  0,  -1, -1, 0, 0,  0, 0,  0, 0,
    0,   0, 0,  0,  0,  0,  0, 0,  0, -1,
};
pub const offset_description = [_]u8{
    0x73, 0x10, 0x00, 0xe0, 0xa0, 0xa1, 0xd2, 0xd1, 0xb6, 0xd9, 0x48, 0x0d,
};
pub const offset_description_counts = [_]i16{
    6,  0, -1, 13, 25, 41, 57, 51, 26, 18, 12, 3,
    -1, 0, 0,  2,
};
// `weights_description` is the Huffman_Tree_Description of the first
// compressed block of a `zstd -3` frame of synthetic text, the reference
// encoder's `HUF_compressWeights` output: the header byte 19, then the 19-byte
// FSE-compressed series. `weights_expected` is the 122-weight series it
// decodes to under `§4.2.1.2`'s two-state, overflow-terminated decode (total
// 192, so the implied last weight is 7 and `Max_Number_of_Bits` is 8).
pub const weights_description = [_]u8{
    0x13, 0xb0, 0xa5, 0x99, 0x03, 0x0e, 0x89, 0x98, 0x90, 0x65, 0xde, 0x6a,
    0x21, 0x49, 0x93, 0x19, 0x06, 0x1f, 0x03, 0x60,
};
pub const weights_description_counts = [_]i16{ 26, 1, 1, 2, 1, 0, 0, 0, 1 };
// The `literals_*` sections are the literals sections of real `zstd` v1.5.7
// frames (`docs/research/zstd-notes.md` §5). Each is a single compressed block
// whose sequences section is the zero-sequence byte (`§3.1.1.3.2.1`), so the
// frame's decoded output is exactly its literals, and both the CLI's `zstd -d`
// and CPython 3.14's `compression.zstd` produce the expected bytes. The input
// in each case is the research harness's skewed-random corpus (a geometric
// byte distribution: Huffman-compressible, effectively match-free), recorded
// per fixture. The sizes are `§3.1.1.3.1.1`'s compressed Size_Formats as the
// encoder chose them.
/// A real `zstd -1` frame of the skewed-random corpus (120 bytes, seed 9):
/// Size_Format 00, one stream, rs = 120, cs = 37 — the 1-stream layout with
/// a real direct-weights tree.
pub const literals_1stream_section = hex(
    "824709855431111f26493580af02b85769fb0d42816b26c3a5925aa399d3662b" ++
        "002c31311d940d04",
);
pub const literals_1stream_expected = hex(
    "0301000100020103000000010200050100050101000303020101000100020001" ++
        "0001020000020002000106010100010102020101020100000400020200020001" ++
        "0100000301010403000001000000000001000100010201010100000001000003" ++
        "040101010000000003040001010102020202000400000000",
);

/// A real `zstd -19` frame of the skewed-random corpus (260 bytes, seed 0):
/// Size_Format 01, four streams, rs = 260, cs = 74 — the Jump_Table and the
/// `(Regenerated_Size+3)/4` segmentation with a real tree.
pub const literals_4stream_sf1_section = hex(
    "469012856543210d0012001200ebfdfa33eadf58c95ac7bd9d721b6a96b6e342" ++
        "59c82354866c270146722fa53f423e4ed12c848e32913d1900248dfa7d14c165" ++
        "0ecf4bf5efb414a843cae4757f",
);
pub const literals_4stream_sf1_expected = hex(
    "0000020102000001000100000001000003000001010001010002020101000300" ++
        "0100000000000000010103000200000000000001010000000000010000000101" ++
        "0001020102010000000100000202030005020202000001000100020400020101" ++
        "0403000000020401000201040100000300000100010001020100020001010400" ++
        "0100010300000000010000000000010103000102020505010002020000000100" ++
        "0203020002010300000104040100020001030102000003000000000204030000" ++
        "0000000000000000000100000101000000020200020102040000010105000102" ++
        "0100010200000100000000000000010101020100000002000000040000020002" ++
        "01000006",
);

/// A real `zstd -19` frame of the skewed-random corpus (1030 bytes, seed 2):
/// Size_Format 10, four streams, rs = 1030, cs = 268 — the 14-bit sizes and
/// a real Jump_Table at realistic magnitudes.
pub const literals_4stream_sf2_section = hex(
    "6a403004888765431110400040004000f94b5bc940528712fbbf96b00205afae" ++
        "9502dc928ea4b6efb95ea771b56b1cf2e015f7908a60d225bb04218f0f5215f9" ++
        "6124a9284bddf955dcaeed7738e071e77bda8f3e217268a9481ee09acde92328" ++
        "2d7c9be9b66f579f033c3a875650d393bdfc9aa20ef0ab0d527cb39322246f06" ++
        "6ea9b271e3f97433c0fc814f69412e019ba58acdd3924b9d7b943ccb60d034dd" ++
        "8fed536ac7f28dbabb1f1d1184b46eb803b26bf0dce1f1ce55c1c2a8f0efbabc" ++
        "d38ceb18900147037a9b340b70a78d014dc3ff792ed399720ddda3d67f80ef1c" ++
        "b488da53ba051aaa88853c19ad964388045dbfcf703a407a540e80d43be9eafd" ++
        "1d170d5b8ac1c90d06f811e6a9b39871",
);
pub const literals_4stream_sf2_expected = hex(
    "0000020000010000030000000700000400000100000000000100010001010000" ++
        "0100010000030101010000000000020000010000010102010002010301010202" ++
        "0203000400000000000203010101010205000000000300000002040502010000" ++
        "0100020201000001020200050301010204000000010000030101000000050000" ++
        "0002040000030001010000010001010100000300010200000101000000010100" ++
        "0002000000010000000001000100010102020300000102020100010000060001" ++
        "0201010001010000010101000000050108000100040201000101000000000000" ++
        "0000000001000302010400000101020209020201010001000102010000000000" ++
        "0002020100000205010001020102000000000900000000000200060000020001" ++
        "0000010200000000020000000300010000030001000201010102010001000009" ++
        "0200010000000202040301020200000100020001000000000301020500010001" ++
        "0101000000000006000000010103010200010100000000000201000000010002" ++
        "0200000001020001010501010001040000020000010300000006000000020000" ++
        "0000010101000001000100000000010001000100000102000200010001000000" ++
        "0004010001020105030000000001020000020001000200010100000600000000" ++
        "0202030101020100010400000203040200000000010300000000000100010200" ++
        "0000010000030001000102000001000006000100020001020200010001000000" ++
        "0107000103000007000207000300000101000003000200010200000100000002" ++
        "0100000101000001000000000000000401010300040100050101010100000200" ++
        "0001000000030000000400000100000200000005000101000001000207000001" ++
        "0000040001000001010001020405030300000103000000000001000001000001" ++
        "0000010103000100000000020100030000010001010201020000000001000100" ++
        "0300000000000100000102000102000105000500020100020000000202010300" ++
        "0000010000020000010102010000020201000102000000020001000301010102" ++
        "0100020001000000030002000301000200000101020000000200040300000000" ++
        "0006000005000100000202000005000301020100010004000103010000030000" ++
        "0100000000000001000000010101000001020200000100000001010206030000" ++
        "0201010300000001020600000001020000040002000000000100000000000101" ++
        "0000010502030404000002010001010100010300020200000002040100030301" ++
        "0101040001080000010000010201020000000100010103030100010500000200" ++
        "0001000000000600000000000000000001010001010300000001000001040001" ++
        "0100000201020002000001020002010000020000000200000000000000000000" ++
        "040001020001",
);

/// A hand-built section around the real FSE-compressed weight series of
/// `weights_description`: Size_Format 01, four streams, rs = 10, cs = 30 (the
/// 20-byte description plus the 6-byte Jump_Table and four 1-byte streams).
/// Its streams decode `weights_expected`'s weight-8 symbol (98, `0x62`, the
/// shortest code) ten times through `§4.2.1.3`'s assignment; the CLI and
/// CPython agree.
pub const literals_fse_tree_section = hex(
    "a6800713b0a599030e89989065de6a21499319061f03600100010001000f0f0f03",
);
pub const literals_fse_tree_expected = [_]u8{0x62} ** 10;

pub const weights_expected = [_]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 4, 8, 2, 3, 4, 0, 2, 1, 1, 0, 0,
    4, 3, 1, 3, 3, 0, 3, 3, 3, 0, 0, 0,
    0, 1,
};

// The `sequences_*` fixtures are sections of four real `zstd` v1.5.7 frames,
// each the first (and only) compressed block of its frame, so the CLI's own
// `zstd -d` output is exactly the block's output. The corpora are short words
// and a low-entropy byte mix; the fixture bytes are the record. `_literals` is
// the block's literals section (`§3.1.1.3.1`), `_section` its sequences
// section (`§3.1.1.3.2`), and `_expected` the block's decoded output. The four
// cover the Predefined, RLE, and FSE_Compressed modes; the hand-built
// `first_block_*` / `repeat_1_*` pair below covers Repeat. `sequences.zig`'s
// tests run the literals and sequences layers over them.
/// A `zstd -5` frame of a 77-byte words corpus: a Literals_Block_Type 0
/// literals section (Size_Format 1, rs = 43) and 6 sequences, all three
/// alphabets Predefined; the output is 77 bytes.
pub const sequences_predefined_literals = hex(
    "b402746865206c69746572616c20646f67206d617463686a756d70736f766572" ++
        "6666736574666f78206c617a79",
);
pub const sequences_predefined_section = hex(
    "06004a098d92e92802374fc7ecf3b52401",
);
pub const sequences_predefined_expected = hex(
    "746865206c69746572616c2074686520646f67206d6174636820746865206a75" ++
        "6d707320646f67206c69746572616c206f766572206f766572206f6666736574" ++
        "2074686520666f78206c617a79",
);

/// A `zstd -3` frame of a 120-byte mix corpus: a Literals_Block_Type 2
/// literals section (Size_Format 0, rs = 104, cs = 49) and 4 sequences
/// (LL Predefined, OF Predefined, ML RLE); the output is 120 bytes.
pub const sequences_rle_match_lengths_literals = hex(
    "82460c09e0e952eeb41f003002931e7ac705b774efa78121f4ca66e061a5c76e" ++
        "f16a2b05029cc16c798adb9aa411a41138dcb804",
);
pub const sequences_rle_match_lengths_section = hex(
    "04040158614e99210464d903",
);
pub const sequences_rle_match_lengths_expected = hex(
    "6166676666676164636165686163626168616161686666666762676464616666" ++
        "6167656764676361636162626868686264646566666867666264646564626268" ++
        "6761646763646168676866646265626168616364636168616464686468646262" ++
        "646667656667656462626668666264646468636464626266",
);

/// A `zstd -5` frame of an 82-byte words corpus: a Literals_Block_Type 0
/// literals section (Size_Format 1, rs = 49) and 6 sequences
/// (LL Predefined, OF FSE_Compressed, ML Predefined); the output is 82 bytes.
pub const sequences_fse_offsets_literals = hex(
    "14036c69746572616c206c617a7920746865207a7374646f66667365746a756d" ++
        "70732077696e646f776d61746368206f766572",
);
pub const sequences_fse_offsets_section = hex(
    "062010661f000124416a3902f096316826",
);
pub const sequences_fse_offsets_expected = hex(
    "6c69746572616c206c617a7920746865207a737464206c617a79206f66667365" ++
        "7420746865206c617a79206a756d70732077696e646f7720746865206f666673" ++
        "6574206c617a79206d61746368206f766572",
);

/// A `zstd -5` frame of a 185-byte words corpus: a Literals_Block_Type 2
/// literals section (Size_Format 0, rs = 72, cs = 62) and 19 sequences, all
/// three alphabets FSE_Compressed; the output is 185 bytes.
pub const sequences_fse_all_literals = hex(
    "82840f1490c70d6cd92ea945e8f1c6efdae6ffff9fcf7fe59d5cca266a32959c" ++
        "a65f6cf98087a9bbb4ab353921269c34bf1bec81dc1bc483256f4bf4b46bdb05" ++
        "04",
);
pub const sequences_fse_all_section = hex(
    "13a870334b4b6b0f1044a5f5104086591c3771941ce0d336ec19a7fe6c628af5" ++
        "e54c04a5acad8648e8585306",
);
pub const sequences_fse_all_expected = hex(
    "62726f776e2077696e646f7720646f67206c617a79206c617a79206d61746368" ++
        "207a7374642062726f776e206a756d7073206a756d70732077696e646f772065" ++
        "6e74726f707920717569636b20666f78207468652062726f776e2062726f776e" ++
        "206c617a792062726f776e20646f67207468652073657175656e636520666f78" ++
        "20746865207a7374642073657175656e6365207a737464206a756d7073207468" ++
        "6520646f67206d617463682077696e646f77206f6666736574",
);
// Whole frames for the block layer: hand-built Zstandard frames around the blocks above, each
// decoded with the CLI (`zstd -d`). Each is `§3.1`'s Magic_Number, `§3.1.1.1.1`'s
// Frame_Header_Descriptor 0x00 (no Frame_Content_Size, no checksum, no dictionary, not
// Single_Segment), `§3.1.1.1.2`'s Window_Descriptor, then the blocks of `§3.1.1.2`, each as a
// 3-byte little-endian Block_Header and its Block_Content. The block tests walk them with
// nothing but this module, and `block.zig`'s fixture helper reads each frame's declared window
// back out of its descriptor. The bytes below are the record.
//
// Four groups, with the CLI's verdict for each:
//
// - **The fast paths** (`frame_raw*`, `frame_rle*`, `frame_multi`): Raw and RLE blocks, a
//   zero-size Raw block, and an RLE block at exactly Block_Maximum_Size. The CLI decodes each
//   to the bytes the tests expect.
// - **The window fixtures** (`frame_window_*`): two RLE blocks and a compressed block whose
//   match reaches exactly Window_Size back, in 1 KB and 128 KB variants, so the decoded length
//   passes both Window_Size and Block_Maximum_Size. The CLI decodes all of them, the `*_over`
//   siblings included: its whole-buffer decoder checks the bytes it still has, not the declared
//   window. This decoder enforces the addressable-span reading of `§3.1.1.4`, the history
//   region plus the block's own writes (stated precisely in `block.zig`'s module doc), so the
//   `*_over` pair is `OffsetTooFar` while `frame_window_1k_span` (an offset past the declared
//   window at ten literals in, still inside the addressable span) is accepted, as the CLI
//   accepts it.
// - **The section fixtures, framed** (`frame_sequences_*`, `frame_literals_*`, `frame_pair*`,
//   `frame_treeless`, `frame_repeat`, `frame_temp_offset`, `frame_two_byte`, `frame_corner`,
//   `frame_zero_seq*`): each carries a section fixture or pair from above as its block
//   content, and the CLI decodes each to the matching expectation.
// - **The negative corners** (`frame_reserved`, `frame_oversize_*`, `frame_short_*`,
//   `frame_truncated_header`, `frame_treeless_first`, `frame_repeat_first`,
//   `frame_no_sequences`, `frame_short_sequences`, `frame_empty_compressed`): the CLI exits 1
//   on every one but the last. It reads `frame_empty_compressed` as a no-op; this decoder
//   returns `MalformedLiteralsHeader`.
/// `§3.1` — "The Magic_Number is 0xFD2FB528", stored little-endian.
pub const frame_magic = [4]u8{ 0x28, 0xb5, 0x2f, 0xfd };
/// `§3.1.1.1.1` — the fixture frames' Frame_Header_Descriptor: no Frame_Content_Size,
/// no Content_Checksum, no dictionary, not Single_Segment.
pub const frame_descriptor = 0x00;

/// A fixture frame's block (`§3.1.1.2.2`): the Block_Type and the
/// Block_Content. `buildFrame` sets Last_Block on the final block — a
/// fixture frame's chain always ends with it (`§3.1.1.2.1`).
pub const FixtureBlock = struct {
    block_type: FixtureBlockType,
    content: []const u8,
};

/// The Block_Type field (`§3.1.1.2.2`, Table 10). Spelled here so the
/// fixture module stays below the block layer it feeds.
pub const FixtureBlockType = enum(u2) {
    raw = 0,
    rle = 1,
    compressed = 2,
};

/// A fixture frame's encoded length: the magic, the descriptor, the
/// Window_Descriptor, then each block's 3-byte Block_Header and its content.
fn frameLen(comptime blocks: []const FixtureBlock) usize {
    var len = frame_magic.len + 2;
    for (blocks) |b| len += 3 + b.content.len;
    return len;
}

/// Assemble a fixture frame (`§3.1`): the magic, the fixtures' descriptor
/// (`frame_descriptor`), the Window_Descriptor, then each block's 3-byte
/// little-endian Block_Header (`§3.1.1.2`, Table 9: Last_Block in bit 0,
/// Block_Type in bits 1-2, Block_Size in bits 3-23) and its Block_Content.
/// The shared fixture-builder: a frame composed of committed section
/// fixtures is derived from them, never transcribed beside them, so the two
/// spellings cannot drift. Comptime only — the frames are consts.
pub fn buildFrame(
    comptime window_descriptor: u8,
    comptime blocks: []const FixtureBlock,
) [frameLen(blocks)]u8 {
    @setEvalBranchQuota(10_000);
    var out: [frameLen(blocks)]u8 = undefined;
    var cursor: usize = 0;
    for (frame_magic) |byte| {
        out[cursor] = byte;
        cursor += 1;
    }
    out[cursor] = frame_descriptor;
    out[cursor + 1] = window_descriptor;
    cursor += 2;
    for (blocks, 0..) |b, index| {
        const last: u24 = if (index + 1 == blocks.len) 1 else 0;
        const header = last |
            (@as(u24, @intFromEnum(b.block_type)) << 1) |
            (@as(u24, b.content.len) << 3);
        out[cursor] = @truncate(header);
        out[cursor + 1] = @truncate(header >> 8);
        out[cursor + 2] = @truncate(header >> 16);
        cursor += 3;
        for (b.content) |byte| {
            out[cursor] = byte;
            cursor += 1;
        }
    }
    assert(cursor == out.len);
    return out;
}

/// The benchmark corpus shapes, restated from `bench/zig/corpus.zig` so the
/// codec tests pin the same bytes the bench corpus generates (`just
/// corpus`); `zeros` is the tests' addition (the RLE shape at byte 0). One
/// definition, shared by every encoder layer's tests.
pub const Shape = enum { text, html, rle, random, mixed, skewlit, words, zeros };

/// Fill `buf` with one corpus shape.
pub fn fillShape(shape: Shape, buf: []u8) void {
    switch (shape) {
        .text => fill(buf, "the quick brown fox jumps over the lazy dog. "),
        .html => fill(buf, "<div class=\"row\"><span>hello</span><span>flate</span></div>"),
        .rle, .zeros => fastmem.set(u8, buf, if (shape == .rle) 0x41 else 0),
        .random => {
            var rng: DefaultPrng = .init(0xC0FFEE);
            for (buf) |*byte| byte.* = rng.random().int(u8);
        },
        .mixed => {
            var rng: DefaultPrng = .init(0x5A4BEEF);
            for (buf, 0..) |*byte, index| {
                byte.* = @truncate(rng.random().int(u8) ^ @as(u8, @truncate(index)));
            }
        },
        .skewlit => {
            var rng: DefaultPrng = .init(0x5CEBE1);
            for (buf) |*byte| {
                const x: u16 = rng.random().int(u8);
                byte.* = @truncate(x * x >> 10);
            }
        },
        .words => {
            var rng: DefaultPrng = .init(0xD1C710);
            var index: usize = 0;
            while (index < buf.len) {
                const word = dictionary[rng.random().uintLessThan(usize, dictionary.len)];
                const length = @min(word.len, buf.len - index);
                fastmem.copy(u8, buf[index..][0..length], word[0..length]);
                index += length;
                if (index < buf.len) {
                    buf[index] = ' ';
                    index += 1;
                }
            }
        },
    }
}

/// Repeat `phrase` over `buf`.
fn fill(buf: []u8, phrase: []const u8) void {
    var index: usize = 0;
    while (index < buf.len) {
        const length = @min(phrase.len, buf.len - index);
        fastmem.copy(u8, buf[index..][0..length], phrase[0..length]);
        index += length;
    }
}

/// The `words` shape's vocabulary, the same 64 words `bench/zig/corpus.zig`
/// pins.
const dictionary = [_][]const u8{
    "the",  "of",    "and",  "a",     "to",    "in",    "is",   "you",
    "that", "it",    "he",   "was",   "for",   "on",    "are",  "as",
    "with", "his",   "they", "at",    "be",    "this",  "have", "from",
    "or",   "one",   "had",  "by",    "word",  "but",   "not",  "what",
    "all",  "were",  "we",   "when",  "your",  "can",   "said", "there",
    "use",  "an",    "each", "which", "she",   "do",    "how",  "their",
    "if",   "will",  "up",   "other", "about", "out",   "many", "then",
    "them", "these", "so",   "some",  "her",   "would", "make", "like",
};

/// A single Raw block of 8 bytes (`§3.1.1.2.2`); the CLI decodes it to those bytes.
pub const frame_raw = hex("28b52ffd00484100007a73746420726177");

/// A zero-size Raw block (`§3.1.1.2.3`) — the `empty-block.zst` shape, and the CLI's own
/// empty-input frame.
pub const frame_raw_empty = hex("28b52ffd0048010000");

/// A single RLE block, 10 bytes from one content byte (`§3.1.1.2.2`).
pub const frame_rle = hex("28b52ffd004853000041");

/// An RLE block at exactly Block_Maximum_Size — 128 KB from one byte (`§3.1.1.2.4`).
pub const frame_rle_max = hex("28b52ffd00480300105a");

/// Three blocks — Raw, Raw, RLE — with Last_Block on the third (`§3.1.1.2.1`).
pub const frame_multi = hex("28b52ffd0048200000616263642000006566676833000049");

/// A 1 KB window (descriptor 0x00), two 1024-byte RLE blocks, then a compressed block whose
/// match reaches offset 1024 — exactly Window_Size — from position 2048 (`§3.1.1.4`).
pub const frame_window_1k = hex("28b52ffd00000220004102200042450000000154000a0003" ++
    "04");

/// The same frame with the match at offset 1025, one byte past the window: the CLI decodes it,
/// ours refuses it.
pub const frame_window_1k_over = hex("28b52ffd00000220004102200042450000000154000a0004" ++
    "04");

/// The addressable-span fixture: the same two 1024-byte RLE blocks, then a compressed block
/// with ten raw literals (`0123456789`) and its match at offset 1025 — one byte past the
/// declared 1 KB Window_Size, but inside the bytes addressable at the match: the block's
/// 1024-byte history region plus its own ten literals. The CLI decodes it to 1024 + 1024 +
/// 10 + 3 bytes (`... BBB 0123456789 BBB`, exit 0); ours accepts it too, because the bound is
/// the addressable span, not the declared window.
pub const frame_window_1k_span = hex("28b52ffd00000220004102200042950000503031323334353637383901" ++
    "540a0a000404");

/// A 128 KB window (descriptor 0x38), two 131072-byte RLE blocks, then a match at offset 131072
/// — Window_Size and Block_Maximum_Size both — from position 262144.
pub const frame_window_128k = hex("28b52ffd003802001041020010424d000000015400110003" ++
    "0002");

/// The same frame with the match at offset 131073: the CLI decodes it, ours refuses it.
pub const frame_window_128k_over = hex("28b52ffd003802001041020010424d000000015400110004" ++
    "0002");

/// A 1152-byte window (Window_Descriptor 0x01: exponent 0, mantissa 1 — `windowBase` 1024 plus
/// `windowAdd` 128, the first window above `§3.1.1.1.2`'s 1-KB minimum), one zero-size Raw
/// block: the streaming reader's cap boundary, one byte past a `Buffer(1024)`'s window. The
/// CLI decodes it to zero bytes (`zstd -t` exits 0, `Window Size: 1152 B`).
pub const frame_window_1152 = hex("28b52ffd0001010000");

/// A 1 KB-window frame whose compressed block declares a 1026-byte match length (code 45, 9
/// extra bits) over a 16-byte history: past Block_Maximum_Size, refused by the CLI and by us.
pub const frame_amplify_match = hex("28b52ffd0000800000303132333435363738396162636465" ++
    "6645000000015400032dff1f");

/// A 1 KB-window frame whose compressed block carries an RLE literals section regenerating 4096
/// bytes: past Block_Maximum_Size, refused by the CLI and by us.
pub const frame_oversize_literals = hex("28b52ffd00002d00000d00017800");

/// Block 2's literals section is Treeless (`§3.1.1.3.1.1`) and decodes five symbol-0 bytes
/// through the Huffman tree of block 1 (the `pair_*` example).
pub const frame_treeless = hex("28b52ffd004854000042800184432010010d002d00005340" ++
    "003f00");

/// The Table 25 frame of the `pair_*` Huffman example: the literals section, then a zero-count
/// sequences section.
pub const frame_pair = hex("28b52ffd004855000042800184432010010d00");

/// The errata-8195 variant of `frame_pair`: the §4.2.2 example's swapped stream, decoding to
/// `00 01 05 04`.
pub const frame_pair_errata = hex("28b52ffd004855000042800184432010100d00");

// The hand-built multi-block fixtures below are whole frames
// (`docs/research/zstd-notes.md` §5.4): each is the magic, a descriptor 0x00
// (no Frame_Content_Size, no checksum), a 512 KB window descriptor, then one
// or more compressed blocks of raw literals and the sequences section in
// question. `zstd -d` decodes every one of them to the bytes the tests
// expect, so the fixtures are conformant frames and not self-consistent
// guesses. The sections and the frames are the same data: `buildFrame`
// derives each frame from its sections.
/// The shared first block of the three multi-block fixtures
/// (`frame_repeat`, `frame_temp_offset`, `frame_two_byte`): 17 raw literals
/// and the six-sequence RLE-mode section (`§3.1.1.3.2`), decoding to 22
/// bytes — the 22-byte history whose offsets 5 and 6 end the repeats at
/// {6, 5, 1}.
pub const first_block_literals: [17]u8 = hex("80202122232425262728292a2b2c2d2e2f");
pub const first_block_section: [6]u8 = hex("025405030041");
pub const first_block_expected: [22]u8 = hex("202122232420212225262728292225262a2b2c2d2e2f");

/// The Repeat_Mode fixture: the second block's modes byte is 0xfc (all three
/// alphabets Repeat, `§3.1.1.3.2.1`), so it carries no table bytes and reuses
/// the first block's three RLE tables — and, because the offset history
/// carries across blocks, its offsets continue the first block's.
pub const repeat_1_literals: [17]u8 = hex("80303132333435363738393a3b3c3d3e3f");
pub const repeat_1_section: [3]u8 = hex("02fc53");
pub const repeat_1_expected: [22]u8 = hex("30313233342e2f3035363738392e2f303a3b3c3d3e3f");

/// Block 2's modes byte is 0xfc — all three alphabets Repeat (`§3.1.1.3.2.1`) — and its
/// offsets continue block 1's history.
pub const frame_repeat = buildFrame(0x48, &.{
    .{ .block_type = .compressed, .content = &(first_block_literals ++ first_block_section) },
    .{ .block_type = .compressed, .content = &(repeat_1_literals ++ repeat_1_section) },
});

/// The decoded output of `frame_repeat`: the CLI's own `zstd -d` bytes.
pub const frame_repeat_expected = hex("202122232420212225262728292225262a2b2c2d2e2f3031" ++
    "3233342e2f3035363738392e2f303a3b3c3d3e3f");

/// The tempOffset fixture, three blocks: the first two sequences lay down a
/// 22-byte history (offsets 5 and 6, so the repeats end at {6, 5, 1}); the
/// second block's sequences all have literals_length 0 (LL symbol 0) and
/// offset_value 3 or 2, the two shifted repeat codes; the third block's all
/// have offset_value 1, the Repeated_Offset2 selection whose swap alternates
/// the offsets.
pub const temp_offset_1_literals: [9]u8 = hex("403031323334353637");
pub const temp_offset_1_section: [6]u8 = hex("04540001031a");
pub const temp_offset_1_expected: [32]u8 = hex(
    "2b2c2d2e2f2b2c2d2e2f2b2c2e2f2b2c2e2f2f2b2c2e2f2f3031323334353637",
);
pub const temp_offset_2_literals: [9]u8 = hex("4038393a3b3c3d3e3f");
pub const temp_offset_2_section: [6]u8 = hex("035400000001");
pub const temp_offset_2_expected: [17]u8 = hex("34353636373436363738393a3b3c3d3e3f");

/// Three blocks: block 2's literals_length is 0 for every sequence (the shifted repeat
/// selection) and reaches into block 1, block 3's walk the Repeated_Offset2 swap (`§3.1.1.5`).
pub const frame_temp_offset = buildFrame(0x48, &.{
    .{ .block_type = .compressed, .content = &(first_block_literals ++ first_block_section) },
    .{ .block_type = .compressed, .content = &(temp_offset_1_literals ++ temp_offset_1_section) },
    .{ .block_type = .compressed, .content = &(temp_offset_2_literals ++ temp_offset_2_section) },
});

/// The decoded output of `frame_temp_offset`: the CLI's own `zstd -d` bytes.
pub const frame_temp_offset_expected = hex("202122232420212225262728292225262a2b2c2d2e2f2b2c" ++
    "2d2e2f2b2c2d2e2f2b2c2e2f2b2c2e2f2f2b2c2e2f2f3031" ++
    "32333435363734353636373436363738393a3b3c3d3e3f");

/// The corner fixture: RLE modes with LL symbol 5, ML symbol 0, OF symbol 3
/// (three extra bits, so offset_value 8-15), six sequences over 32 literals.
/// Offsets 5, 6, 7, 7 (the equal-offsets rule), 9, 12; two trailing
/// literals. Modes byte 0x54 = RLE|RLE|RLE.
pub const corner_literals: [34]u8 = hex(
    "0402202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d" ++
        "3e3f",
);
pub const corner_section: [8]u8 = hex("0654050300a71404");
pub const corner_expected: [50]u8 = hex(
    "202122232420212225262728292225262a2b2c2d2e25262a2f30313233262a2f" ++
        "343536373833262a393a3b3c3d3536373e3f",
);

/// The corner fixture: six RLE-mode sequences with two trailing literals (`§3.1.1.4`,
/// `§3.1.1.3.2`).
pub const frame_corner = buildFrame(0x48, &.{
    .{ .block_type = .compressed, .content = &(corner_literals ++ corner_section) },
});

/// The decoded output of `frame_corner`: the CLI's own `zstd -d` bytes.
pub const frame_corner_expected = hex("202122232420212225262728292225262a2b2c2d2e25262a" ++
    "2f30313233262a2f343536373833262a393a3b3c3d353637" ++
    "3e3f");

/// The two-byte Number_of_Sequences fixture: the second block's count is
/// 128, the first count that needs the 2-byte form (`80 80`), and its 128
/// sequences all have literals_length 0 with offset_value 1 — the shifted
/// Repeated_Offset2 selection, whose swap alternates offsets 5 and 6 as the
/// history's own bytes are consumed. The block's 384 bytes start with block
/// 1's tail (12 bytes) and settle into the six-byte cycle `----./` (62
/// times), then its 8 literals are trailing (the CLI's output, verbatim).
pub const two_byte_1_literals: [9]u8 = hex("403031323334353637");
pub const two_byte_1_section: [7]u8 = hex("80805400000001");
pub const two_byte_1_expected: [392]u8 = hex(
    "2b2c2d2d2e2f2c2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
        "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d" ++
        "2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f" ++
        "2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
        "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d" ++
        "2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f" ++
        "2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
        "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d" ++
        "2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f" ++
        "2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
        "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d" ++
        "2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f" ++
        "3031323334353637",
);

/// Block 2's Number_of_Sequences is 128, the first count that needs the 2-byte form
/// (`§3.1.1.3.2.1`).
pub const frame_two_byte = buildFrame(0x48, &.{
    .{ .block_type = .compressed, .content = &(first_block_literals ++ first_block_section) },
    .{ .block_type = .compressed, .content = &(two_byte_1_literals ++ two_byte_1_section) },
});

/// The decoded output of `frame_two_byte`: the CLI's own `zstd -d` bytes.
pub const frame_two_byte_expected = hex("202122232420212225262728292225262a2b2c2d2e2f2b2c" ++
    "2d2d2e2f2c2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
    "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
    "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
    "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
    "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
    "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
    "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
    "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
    "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
    "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
    "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
    "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
    "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
    "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
    "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d" ++
    "2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f2d2d2d2d2e2f3031" ++
    "323334353637");

/// The zero-count fixture: the 1-byte zero (the section stops after the
/// count) and the 2-byte `80 00` that decodes to zero, a corner the reference
/// accepts and std rejects.
pub const zero_literals: [9]u8 = hex("402021222324252627");
pub const zero_section: [1]u8 = hex("00");
pub const zero_two_byte_section: [2]u8 = hex("8000");
pub const zero_expected: [8]u8 = hex("2021222324252627");

/// A zero-count sequences section: the block is its literals (`§3.1.1.3.2.1`).
pub const frame_zero_seq = buildFrame(0x48, &.{
    .{ .block_type = .compressed, .content = &(zero_literals ++ zero_section) },
});

/// The decoded output of `frame_zero_seq`: the CLI's own `zstd -d` bytes.
pub const frame_zero_seq_expected = hex("2021222324252627");

/// The 2-byte `80 00` count that decodes to zero: the CLI accepts it and std rejects it.
pub const frame_zero_seq_2b = buildFrame(0x48, &.{
    .{ .block_type = .compressed, .content = &(zero_literals ++ zero_two_byte_section) },
});

/// The `sequences_predefined` literals and sequences sections as one compressed block
/// (`§3.1.1.3`); the CLI decodes it to `sequences_predefined_expected`.
pub const frame_sequences_predefined = buildFrame(0x48, &.{
    .{
        .block_type = .compressed,
        .content = &(sequences_predefined_literals ++ sequences_predefined_section),
    },
});

/// The `sequences_rle_match_lengths` literals and sequences sections as one compressed block;
/// the CLI decodes it to `sequences_rle_match_lengths_expected`.
pub const frame_sequences_rle_match_lengths = buildFrame(0x48, &.{
    .{
        .block_type = .compressed,
        .content = &(sequences_rle_match_lengths_literals ++ sequences_rle_match_lengths_section),
    },
});

/// The `sequences_fse_offsets` literals and sequences sections as one compressed block; the CLI
/// decodes it to `sequences_fse_offsets_expected`.
pub const frame_sequences_fse_offsets = buildFrame(0x48, &.{
    .{
        .block_type = .compressed,
        .content = &(sequences_fse_offsets_literals ++ sequences_fse_offsets_section),
    },
});

/// The `sequences_fse_all` literals and sequences sections as one compressed block; the CLI
/// decodes it to `sequences_fse_all_expected`.
pub const frame_sequences_fse_all = buildFrame(0x48, &.{
    .{
        .block_type = .compressed,
        .content = &(sequences_fse_all_literals ++ sequences_fse_all_section),
    },
});

/// The `literals_1stream` section followed by a zero-count sequences section (`§3.1.1.3.2.1`);
/// the CLI decodes it to `literals_1stream_expected`.
pub const frame_literals_1stream = buildFrame(0x48, &.{
    .{
        .block_type = .compressed,
        .content = &(literals_1stream_section ++ zero_section),
    },
});

/// The `literals_4stream_sf1` section followed by a zero-count sequences section; the CLI
/// decodes it to `literals_4stream_sf1_expected`.
pub const frame_literals_4stream_sf1 = buildFrame(0x48, &.{
    .{
        .block_type = .compressed,
        .content = &(literals_4stream_sf1_section ++ zero_section),
    },
});

/// The `literals_4stream_sf2` section followed by a zero-count sequences section; the CLI
/// decodes it to `literals_4stream_sf2_expected`.
pub const frame_literals_4stream_sf2 = buildFrame(0x48, &.{
    .{
        .block_type = .compressed,
        .content = &(literals_4stream_sf2_section ++ zero_section),
    },
});

/// The `literals_fse_tree` section followed by a zero-count sequences section; the CLI decodes
/// it to `literals_fse_tree_expected`.
pub const frame_literals_fse_tree = buildFrame(0x48, &.{
    .{
        .block_type = .compressed,
        .content = &(literals_fse_tree_section ++ zero_section),
    },
});

/// Block type 3, Reserved (`§3.1.1.2.2`): the CLI exits 1.
pub const frame_reserved = hex("28b52ffd004827000061626364");

/// A Raw block declaring 128 KB + 1 in a 512 KB-window frame (`§3.1.1.2.4`): the CLI exits 1.
pub const frame_oversize_raw = hex("28b52ffd0048090010");

/// An RLE block of 1025 in a 1 KB-window frame — the window/block coupling, the window the
/// smaller term: the CLI exits 1.
pub const frame_oversize_rle = hex("28b52ffd00000b200041");

/// A Treeless literals section as the frame's first block: no previous tree (`§3.1.1.3.1.1`),
/// the CLI exits 1.
pub const frame_treeless_first = hex("28b52ffd00482d00005340003f00");

/// Repeat_Mode as the frame's first sequences section: no previous tables (`§3.1.1.3.2.1`),
/// the CLI exits 1.
pub const frame_repeat_first = hex("28b52ffd00482500000002fc53");

/// A compressed block that is only its literals section: the sequences section's header is
/// missing (`§3.1.1.3.2.1`), the CLI exits 1.
pub const frame_no_sequences = hex("28b52ffd00480d000000");

/// A sequences section cut inside its fixed-size header: the CLI exits 1.
pub const frame_short_sequences = hex("28b52ffd00481500000001");

/// A Raw block declaring 10 bytes with 5 present — the input ends inside the frame
/// (`§3.1.1.2`), the CLI exits 1.
pub const frame_short_raw = hex("28b52ffd00485100006162636465");

/// A compressed block declaring 10 bytes with 5 present: the CLI exits 1.
pub const frame_short_compressed = hex("28b52ffd00485500006162636465");

/// A zero-size compressed block (`§3.1.1.2.3`): the CLI reads it as a no-op, ours returns
/// `MalformedLiteralsHeader` for the missing literals header.
pub const frame_empty_compressed = hex("28b52ffd0048050000");

/// A 1-byte Block_Header — the input ends inside the frame (`§3.1.1.2`), the CLI exits 1.
pub const frame_truncated_header = hex("28b52ffd004801");

// The frame layer's fixtures: hand-built frames for every Frame_Header corner of `§3.1.1.1`,
// the checksum trailer of `§3.1.1`, the skippable frames of `§3.1.2`, and one real multi-block
// frame from the CLI. Each was run through the CLI and its verdict recorded: `zstd -d -c`
// decodes the good ones byte-exact, `zstd -t` verifies the checksummed ones (the C library's
// XXH64 against std's, through the trailer), and `zstd -d` exits 1 on every negative corner.
// The bytes below are generator output, not hand transcriptions. The research behind these
// fixtures is in `docs/research/zstd-notes.md` §3 (the checksum) and §5.4 (the corruption set).
//
// The groups:
//
// - **The descriptor forms** (`frame_fcs1`/`frame_fcs2`/`frame_fcs2_single_segment`/`frame_fcs4`/
//   `frame_fcs8`): FCS_Field_Size 1/2/4/8 (`§3.1.1.1.1.1`, Table 4), the 2-byte form's +256
//   offset (`§3.1.1.1.4`), and Single_Segment_Flag's Window_Size = Frame_Content_Size
//   (`§3.1.1.1.1.2`). Each carries the smallest block its declared window allows.
// - **The flag corners** (`frame_unused_bit`, `frame_reserved_bit`, `frame_dictionary_id*`):
//   descriptor bit 4 accepted and never interpreted (`§3.1.1.1.1.3`; the CLI exits 0), bit 3
//   refused (`§3.1.1.1.1.4`; the CLI exits 1 "Unsupported frame parameter"), and
//   Dictionary_ID_Flag refused at the first ID byte (`§3.1.1.1.3`; the CLI exits 1 "Dictionary
//   mismatch", with the ID byte present and, in `frame_dictionary_id_truncated`, without it).
// - **The checksum trailer** (`frame_checksum`, `frame_checksum_empty`, `frame_checksum_corrupt`,
//   `frame_checksum_truncated`, `frame_checksum_multi`): the low 4 bytes of `XXH64(decoded, 0)`,
//   little-endian (`§3.1.1`). The trailers are the C library's own values: `zstd -t` verifies
//   each good one and fails the corrupt one with "Restored data doesn't match checksum".
//   `frame_checksum_multi` is the CLI's `zstd -3` of `frame_checksum_multi_text` repeated 3000
//   times: 135000 bytes over two compressed blocks, single-segment, FCS 135000, trailer
//   `23 6b a1 cc`.
// - **Frame_Content_Size as a check** (`frame_fcs_short`, `frame_fcs_long`, `frame_fcs_max`):
//   the same 8-byte block with a 4- and a 12-byte declaration, and the 8-byte form's maximum
//   (`§3.1.1.1.4`; the CLI exits 1 on the first two and accepts the last as its
//   `ZSTD_CONTENTSIZE_UNKNOWN` sentinel, a divergence recorded beside the fixture).
// - **The window/block coupling** (`frame_single_segment_oversize`): a single-segment frame
//   whose FCS, hence Window_Size, is smaller than its block (`§3.1.1.2.4`; the CLI exits 1
//   "Src size is incorrect").
// - **The boundary set** (`frame_trailing_garbage`, `frame_two_frames`): bytes after a complete
//   frame. The CLI fails the first ("unsupported format") and decodes both frames of the
//   second; the one-shot's rule is one frame by exact consumption, with trailing bytes
//   ignored.
// - **The skippable set** (`skippable_*`): `§3.1.2`'s 16 magics, a frame between skippables,
//   the out-of-range 0x184D2A60 magic (the CLI exits 1 "unsupported format"), a truncated
//   User_Data, and a 4 GiB Frame_Size, which checks that the bytes are skipped by arithmetic
//   and never staged.
/// `§3.1.1.1.1.1` — FCS_Field_Size 1, Single_Segment_Flag set: descriptor 0x20, FCS 8, one Raw
/// block of 8 (Window_Size 8 is Block_Maximum_Size, `§3.1.1.2.4`).
pub const frame_fcs1 = hex("28b52ffd20084100003031323334353637");

/// `§3.1.1.1.4` — FCS_Field_Size 2: descriptor 0x40, a 1 KB window, FCS 300 (field 44, +256),
/// one RLE block of 300 `A`s.
pub const frame_fcs2 = hex("28b52ffd40002c0063090041");

/// `§3.1.1.1.1.2` — Single_Segment_Flag with the 2-byte FCS: descriptor 0x60, FCS 300, and
/// Window_Size is that 300.
pub const frame_fcs2_single_segment = hex("28b52ffd602c0063090041");

/// `§3.1.1.1.4` — FCS_Field_Size 4: descriptor 0x80, a 1 KB window, FCS 8.
pub const frame_fcs4 = hex("28b52ffd8000080000004100003031323334353637");

/// `§3.1.1.1.4` — FCS_Field_Size 8: descriptor 0xC0, a 1 KB window, FCS 8.
pub const frame_fcs8 = hex("28b52ffdc00008000000000000004100003031323334353637");

/// `§3.1.1.1.1.3` — descriptor bit 4 set: "A decoder ... shall not interpret this bit"; the CLI
/// decodes it to "abcd".
pub const frame_unused_bit = hex("28b52ffd100021000061626364");

/// `§3.1.1.1.1.4` — descriptor bit 3 set: "must ensure it is not set"; the CLI exits 1.
pub const frame_reserved_bit = hex("28b52ffd080021000061626364");

/// `§3.1.1.1.1.6` — Dictionary_ID_Flag 1: a 1-byte ID, refused at that byte; the CLI exits 1
/// "Dictionary mismatch".
pub const frame_dictionary_id = hex("28b52ffd01002a21000061626364");

/// Dictionary_ID_Flag 3: a 4-byte ID, the same refusal at its first byte.
pub const frame_dictionary_id_wide = hex("28b52ffd03004433221121000061626364");

/// Dictionary_ID_Flag 1 with the input ending before the ID byte: the header is cut short, which
/// is `Truncated` (the CLI exits 1 "premature end"), not `DictionaryRequired`.
pub const frame_dictionary_id_truncated = hex("28b52ffd0100");

/// `§3.1.1` — Content_Checksum_Flag: the trailer is the low 4 bytes of `XXH64("abcd", 0)`.
pub const frame_checksum = hex("28b52ffd040021000061626364cc925dd2");

/// The empty payload's checksum: the low 4 bytes of `XXH64("", 0)`.
pub const frame_checksum_empty = hex("28b52ffd040001000099e9d851");

/// `frame_checksum` with the Content_Checksum_Flag clear and no trailer. The
/// CLI's checksum-on and `--no-check` frames differ only in descriptor bit 2
/// and the four trailer bytes, and this pair is that comparison. Both decode
/// to "abcd".
pub const frame_checksum_off = hex("28b52ffd000021000061626364");

/// The same trailer with its last byte flipped: `WrongChecksum`; the CLI exits 1 "Restored data
/// doesn't match checksum".
pub const frame_checksum_corrupt = hex("28b52ffd040021000061626364cc925dd3");

/// The trailer's last byte missing: the input ends inside the frame (`Truncated`).
pub const frame_checksum_truncated = hex("28b52ffd040021000061626364cc925d");

/// The CLI's own multi-block frame: `zstd -3` of `frame_checksum_multi_text` repeated 3000
/// times. Descriptor 0xa4 — FCS_Field_Size 4, Single_Segment_Flag, Content_Checksum_Flag — FCS
/// 135000, two Compressed_Blocks, trailer `23 6b a1 cc`.
pub const frame_checksum_multi = hex("28b52ffda4580f0200c40100c40274686520717569636b2062726f77" ++
    "6e20666f78206a756d7073206f76657220746865206c617a7920646f" ++
    "672e0200ccff5065c01066194500000868010054f78110236ba1cc");

/// The decoded content of `frame_checksum_multi`, repeated 3000 times (135000 bytes).
pub const frame_checksum_multi_text: []const u8 = "the quick brown fox jumps over the lazy dog. ";

/// `§3.1.1.1.4` — Frame_Content_Size 4 against an 8-byte block: the running bound trips at that
/// block; the CLI exits 1.
pub const frame_fcs_short = hex("28b52ffd8000040000004100003031323334353637");

/// Frame_Content_Size 12 against an 8-byte block: the frame-end check trips; the CLI exits 1.
pub const frame_fcs_long = hex("28b52ffd80000c0000004100003031323334353637");

/// The 8-byte form's maximum, 2^64-1, against a 4-byte block: the declaration is checked
/// against the decode like any other (`§3.1.1.1.4`), so ours fails `ContentSizeMismatch` and
/// writes nothing past the block. The C accepts this one frame shape: it reserves
/// 2^64-1 as `ZSTD_CONTENTSIZE_UNKNOWN` and skips the check — a sentinel the RFC does not
/// have (Table 7's 8-byte range is "0 - 2^(64) - 1"), recorded here as the divergence the
/// fixture pins. `zstd -d -c` exits 0 and decodes it to "abcd".
pub const frame_fcs_max = hex("28b52ffdc000ffffffffffffffff21000061626364");

/// `§3.1.1.2.4` — a single-segment frame whose FCS (hence Window_Size) is 4 carrying a 5-byte
/// Raw block: `BlockOversize`; the CLI exits 1 "Src size is incorrect".
pub const frame_single_segment_oversize = hex("28b52ffd20042900006162636465");

/// `frame_raw`'s magic with its first byte flipped: neither magic family, `BadMagic` (the
/// CLI exits 1 "unsupported format").
pub const frame_bad_magic = hex("29b52ffd00484100007a73746420726177");

/// `frame_raw` plus `zzzz`: the frame decodes and the tail is ignored (the one-shot's boundary
/// rule; the CLI exits 1 "unsupported format" on the tail).
pub const frame_trailing_garbage = hex("28b52ffd00484100007a737464207261777a7a7a7a");

/// Two complete frames back to back: the one-shot decodes the first and ignores the second (a
/// multi-frame file is `Reader.streamAll`'s walk); the CLI decodes both (14 bytes).
pub const frame_two_frames = hex("28b52ffd00484100007a7374642072617728b52ffd00483100007365" ++
    "636f6e64");

/// `§3.1.2` — a skippable frame (magic 0x184D2A53) before a good frame: skipped, then decoded.
pub const skippable_prefix = hex("532a4d18040000006d65746128b52ffd00484100007a737464207261" ++
    "77");

/// `§3.1.2` — sixteen skippable frames, all 16 magics: "All 16 values are valid"; the CLI
/// decodes to zero bytes cleanly, since an input of only skippable frames is a clean end.
pub const skippable_sixteen = hex("502a4d1803000000404040512a4d1803000000414141522a4d180300" ++
    "0000424242532a4d1803000000434343542a4d180300000044444455" ++
    "2a4d1803000000454545562a4d1803000000464646572a4d18030000" ++
    "00474747582a4d1803000000484848592a4d18030000004949495a2a" ++
    "4d18030000004a4a4a5b2a4d18030000004b4b4b5c2a4d1803000000" ++
    "4c4c4c5d2a4d18030000004d4d4d5e2a4d18030000004e4e4e5f2a4d" ++
    "18030000004f4f4f");

/// `§3.1.2` — a good frame between two skippable frames: both are skipped, the frame decodes.
pub const skippable_around = hex("502a4d1802000000616128b52ffd00484100007a737464207261775f" ++
    "2a4d18020000006262");

/// 0x184D2A60: one past the skippable range and not the Zstandard magic — `BadMagic`; the CLI
/// exits 1 "unsupported format".
pub const skippable_bad_magic = hex("602a4d1803000000616263");

/// A skippable frame declaring 10 User_Data bytes with 3 present: `Truncated`.
pub const skippable_truncated = hex("502a4d180a000000616263");

/// A skippable frame declaring 4 GiB of User_Data (`§3.1.2`'s field maximum) with 3 present:
/// `Truncated`, and no memory touched — the bytes are skipped by arithmetic, never staged.
pub const skippable_huge = hex("512a4d18ffffffff616263");

// The dictionary fixtures (RFC 8878 §5). The trained dictionaries are the
// pinned CLI v1.5.7's `zstd --train -r <dir>` output over 24 seeded
// corpus-shaped samples (`docs/research/dictionary-notes.md` §1.1: the
// research's from-scratch byte-level parse and klauspost's InspectDictionary
// agree on every field, and both dictionaries round-trip through the CLI
// byte-exact). The two incomplete-statistics dictionaries are the C's own
// `tests/dict-files/zero-weight-dict` and
// `tests/golden-dictionaries/http-dict-missing-symbols` (dual BSD-3/GPL-2
// data fixtures, attributed in THIRD_PARTY.md).
//
// Each `dict_frame_*` is the CLI's own `zstd -D <dict> -1 <file> -o <frame>`
// output, and the CLI's `zstd -D <dict> -d` decodes it to the plaintext
// beside it (verified at commit time; the mismatch rows record the CLI's
// verdicts too). `dict_frame_s00_noid` is the `--no-dictID` form: a legal
// frame that is undecodable without the dictionary and carries no DID, so
// the mismatch check cannot see the dependency (the CLI fails it with "Data
// corruption detected", not "Dictionary mismatch").

/// The trained dictionary (14,493 bytes): ID 574546390, a 256-symbol
/// literals tree, an 18-symbol offsets table, the full 53/36-symbol length
/// tables, the trainer's default {1,4,8} repcodes, and 14,378 content bytes
/// from offset 115.
pub const dict_trained: []const u8 = @embedFile("testdata/dict-trained.bin");
/// A second trained dictionary (8,192 bytes): ID 100 (the CLI's
/// `--dictID=100`), 8,042 content bytes from offset 150 — the mismatch
/// matrix's other seat, and `dict_frame_s01_r100`'s dictionary.
pub const dict_100: []const u8 = @embedFile("testdata/dict-100.bin");
/// The C's `zero-weight-dict` (153 bytes): ID 16720127, 120 zero-weight
/// symbols in its literals tree — an incomplete statistics dictionary the
/// v1.5.6+ C and ours accept (DD11), 11 content bytes from offset 142.
pub const dict_zero_weight: []const u8 = @embedFile("testdata/dict-zero-weight.bin");
/// The C's `http-dict-missing-symbols` (1,000 bytes): ID 1386686301, zero
/// weights in the literals tree and zero-probability symbols in the offsets
/// (12 symbols) and match-length (47) tables, 842 content bytes from offset
/// 158.
pub const dict_missing_symbols: []const u8 = @embedFile("testdata/dict-missing-symbols.bin");

/// `dict_frame_s00`'s plaintext (735 bytes): a corpus-shaped sample.
pub const dict_s00: []const u8 = @embedFile("testdata/dict-s00.txt");
/// `dict_frame_s01_r100`'s and `dict_frame_s01_raw`'s plaintext (1,078
/// bytes).
pub const dict_s01: []const u8 = @embedFile("testdata/dict-s01.txt");
/// The raw dictionary `dict_frame_s01_raw` was compressed against (702
/// bytes): format-free content, no ID.
pub const dict_s02: []const u8 = @embedFile("testdata/dict-s02.txt");
/// `dict_frame_big`'s plaintext (23,640 bytes): the corpus samples
/// concatenated, a multi-block frame.
pub const dict_big: []const u8 = @embedFile("testdata/dict-big.txt");

/// The CLI's `-D dict-trained.bin -1` frame for `dict_s00` (229 bytes):
/// single-segment, the exact Frame_Content_Size, the 4-byte DID form, and
/// the checksum. The CLI decodes it with `-D`; without one it fails
/// "Dictionary mismatch".
pub const dict_frame_s00: []const u8 = @embedFile("testdata/dict-s00.zst");
/// The same frame with `--no-dictID` (183 bytes): DID flag 0, so it decodes
/// with or without a supplied dictionary — and fails as corruption without
/// one, because its first block is Treeless from the dictionary's tree.
pub const dict_frame_s00_noid: []const u8 = @embedFile("testdata/dict-s00-noid.zst");
/// The CLI's `-D dict-100.bin -1` frame for `dict_s01` (244 bytes): the
/// 1-byte DID form (ID 100).
pub const dict_frame_s01_r100: []const u8 = @embedFile("testdata/dict-s01-r100.zst");
/// The CLI's raw-dictionary frame for `dict_s01` (300 bytes): `-D
/// dict_s02.txt`, DID flag 0. The CLI decodes it only with `dict_s02`; any
/// other dictionary fails as corruption.
pub const dict_frame_s01_raw: []const u8 = @embedFile("testdata/dict-s01-raw.zst");
/// The CLI's `-D dict-zero-weight.bin -1` frame for `dict_s00` (357 bytes):
/// the incomplete-statistics dictionary's own frame, decoded with it.
pub const dict_frame_zw: []const u8 = @embedFile("testdata/dict-zw.zst");
/// The CLI's `-D dict-trained.bin -1` frame for `dict_big` (3,783 bytes):
/// several blocks, so the dictionary's tables seed block 0 and the frame's
/// own state carries the rest.
pub const dict_frame_big: []const u8 = @embedFile("testdata/dict-big.zst");

// The §5 expiry fixtures (DT1). Hand-built frames whose single sequence
// reaches into the dictionary's content: `dict_frame_boundary` at a match
// position exactly Window_Size (allowed: §5's "less than or equal to
// Window_Size"), and `dict_frame_boundary_after` one byte past it (refused:
// the dictionary is gone). Both are a 1 KiB Window_Descriptor (0x00), a
// 1-byte Dictionary_ID 42, an RLE block of 1024 'A's (the compressed
// sibling's history), then a Compressed block whose literals section is
// empty and whose one Predefined-table sequence is LL 0 / ML 3 / offset
// 1027 — three bytes into the dictionary's `XYZ` content. The `_after`
// sibling inserts one more RLE byte first, so the match position is 1025.
//
// The pinned CLI v1.5.7 decodes *both* (its whole-buffer decoder checks the
// history it holds, not Window_Size): the first to 1024 'A' + "XYZ", the
// second to 1025 'A' + "YZA" — it reads the dictionary across the boundary
// (the T12 class). This decoder fails the second with `OffsetTooFar`: §5's
// boundary enforced as written (DT1's fail-closed decision).

/// The boundary fixtures' dictionary: a formatted dictionary (ID 42) whose
/// tables are the RFC's own fixtures (`pair_tree`, `offset_description`,
/// `literals_length_description`) and whose content is three bytes, "XYZ".
/// Its repcodes are {1,2,3}, all inside the content.
pub const dict_boundary = hex("37a430ec2a00000084432010731000e0a0a1d2d1b6d9480d" ++
    "141f012010b4d0bf00141f012010b4d0bf0001000000020000000300000058595a");
/// The boundary fixture's expected output: the RLE block's 1024 'A's and the
/// three dictionary bytes the match reads.
pub const dict_boundary_expected = [_]u8{'A'} ** 1024 ++ "XYZ";
/// `dict_frame_boundary` (21 bytes): the match at position 1024, exactly
/// Window_Size.
pub const dict_frame_boundary = hex("28b52ffd01002a022000413d000000010006001908");
/// The boundary dictionary's short sibling: the same tables and ID, but two
/// content bytes and the repcodes {1,2,2}. The fixture frame's reach (three
/// bytes) is past its content, which is `OffsetTooFar` here; the pinned CLI
/// decodes it, reading a byte in front of the content (the DT1 class).
pub const dict_boundary_short = hex("37a430ec2a00000084432010731000e0a0a1d2d1b6d9480d" ++
    "141f012010b4d0bf00141f012010b4d0bf000100000002000000020000005859");
/// `dict_frame_boundary_after` (26 bytes): one RLE byte more, so the match
/// is at position 1025 and the dictionary is out of reach.
pub const dict_frame_boundary_after = hex("28b52ffd01002a022000410a0000413d000000010006001908");
/// `dict_frame_boundary_straddle` (21 bytes): the same frame with the reach
/// one byte deep (offset 1025), so the match copies the dictionary's last
/// byte and then the output's first two — the boundary-straddling case
/// ("span extDict & currentPrefixSegment"). The pinned CLI decodes it to
/// 1024 'A' + "ZAA".
pub const dict_frame_boundary_straddle = hex("28b52ffd01002a022000413d000000010004001908");
/// The straddle fixture's expected output.
pub const dict_boundary_straddle_expected = [_]u8{'A'} ** 1024 ++ "ZAA";
/// The pinned CLI's verdict on `dict_frame_boundary_after`: it decodes,
/// reading "YZA" (the dictionary's last two bytes, then the output's first).
pub const dict_boundary_after_cli = [_]u8{'A'} ** 1025 ++ "YZA";

// The `encode_*` fixtures are the CLI's own level-1 frames (`zstd -1 -q -k -f`,
// the pinned v1.5.7) for the corpus shapes at sizes that fit a fixture: the
// text, html, and rle shapes at the corpus sizes 32 KiB and 64 KiB, the
// `words` and `skewlit` shapes' first 4 KiB (the entropy paths the fast-class
// shapes starve), the tiny class's 100- and 1024-byte text (mls 5, the
// one-byte Frame_Content_Size form), and a 600 KB text frame (the windowed,
// multi-block form). `src/zstd/encode.zig`'s tests rebuild each input, encode
// it, and require these exact bytes: our level-1 emission reproduces the
// CLI's whole frame on every one of them, and each decodes through our
// decoder and the CLI byte for byte.
//
// The CLI's verdicts: `zstd -t` clean and `zstd -d -c` byte-exact on all
// eleven (v1.5.7), the same checks the frame fixtures above record. The inputs are the
// `bench/zig/corpus.zig` shapes (the text/html/rle 32 KiB and 64 KiB blobs
// are `bench/corpus-gen`'s, whose SHA256SUMS anchor they share). The
// `encode_stream_*` group below is the same CLI over the same shapes read
// from a pipe, where the frame's size is unknown.

/// The CLI's `zstd -1` frame for the 100-byte input: 67 bytes.
pub const encode_text_100 = hex("28b52ffd2464b50100c40274686520717569636b2062726f776e2066" ++
    "6f78206a756d7073206f76657220746865206c617a7920646f672e02" ++
    "0080ea008630cb0b55f94a");

/// The CLI's `zstd -1` frame for the 1024-byte input: 69 bytes.
pub const encode_text_1024 = hex("28b52ffd640003bd0100c40274686520717569636b2062726f776e20" ++
    "666f78206a756d7073206f76657220746865206c617a7920646f672e" ++
    "0200cca12ac06867193bf59c43");

/// The CLI's `zstd -1` frame for the 32768-byte input: 68 bytes.
pub const encode_text_32768 = hex("28b52ffd64007fb50100d40274686520717569636b2062726f776e20" ++
    "666f78206a756d7073206f76657220746865206c617a7920646f672e" ++
    "20010085fee1aecafda32693");

/// The CLI's `zstd -1` frame for the 65536-byte input: 69 bytes.
pub const encode_text_65536 = hex("28b52ffd6400ffbd0100d40274686520717569636b2062726f776e20" ++
    "666f78206a756d7073206f76657220746865206c617a7920646f672e" ++
    "20010085fe435d95012864d40c");

/// The CLI's `zstd -1` frame for the 32768-byte input: 72 bytes.
pub const encode_html_32768 = hex("28b52ffd64007fd50100c4023c64697620636c6173733d22726f7722" ++
    "3e3c7370616e3e68656c6c6f3c2f7370616e666c6174652f6469763e" ++
    "0300c2bf575b83a755ee7c0207cc1117");

/// The CLI's `zstd -1` frame for the 65536-byte input: 72 bytes.
pub const encode_html_65536 = hex("28b52ffd6400ffd50100c4023c64697620636c6173733d22726f7722" ++
    "3e3c7370616e3e68656c6c6f3c2f7370616e666c6174652f6469763e" ++
    "0300c27fafb4064fabdcf9044a9164a6");

/// The CLI's `zstd -1` frame for the 32768-byte input: 23 bytes.
pub const encode_rle_32768 = hex("28b52ffd64007f4d00001041410100fbff0eb0d5612c2c");

/// The CLI's `zstd -1` frame for the 65536-byte input: 24 bytes.
pub const encode_rle_65536 = hex("28b52ffd6400ff5500001041410100fb7f1d6001cf99e954");

/// The CLI's `zstd -1` frame for the 4096-byte input: 1530 bytes.
pub const encode_words_4096 = hex("28b52ffd64000f652f0046f16c1690256d038090440b9ff68743a225" ++
    "7debffffc1f5c71c64006500670043303fa224cea57b8feaf4dce1ca" ++
    "5f8995bce98f0e33f65cb420d8e959a93a5c5449ac54e8348d689a1b" ++
    "5596004c20000b9a2e8992bbb883a042953daa6ca51daa2c5a55102c" ++
    "a0caa615dd3417eeb983685a094dcb492b60ea283fa5c20ea214e02a" ++
    "fa041e5496973ccd89153a7d880d027d8ad6bbce880a589d231562e4" ++
    "e425c1d16ab806a669cc870e2d54f963d395c34b8516bc900ea2c47a" ++
    "ec389bceb3c3d50f2a54861ea8b25095377fc35940a7e5e93a25a4ca" ++
    "8e73cfcbcf0a824b856895fd40ab21ade740031d98e7c0f4c3756c31" ++
    "9b0ff8acf960749e20586439b73b1b57e45468351f0e1a31233eea66" ++
    "5a29fc68ba956603336c83a022f8d3c708f419c4ce3c3054f7ba82e0" ++
    "42f514e74335ee48a7980f2d6fb98bee38571a7a603a0842238815aa" ++
    "4a12e4cff34a9747f905176e05ac88dc8a7df8c02198e7ef1c10fd28" ++
    "683ea4f993d8d33d3a23ef87e9fc46b19e0b1003ef38d3bdf07e1f98" ++
    "de2d07068d4ed3793c9dedbc4ea9143b2fd143730e14a22a3f62e4ad" ++
    "34c179094e85c38c3e073aa0a10541a0f9fd06d1238e73398a43f71e" ++
    "8231a8628ca83324224992a4ed2208202010100d6a33ef031240e033" ++
    "635207455312992773f51ff8769a5ec07308e2b5eb098995b1c1a988" ++
    "d3c3d326b87ca1ee07d8594c429b0406a152f3139241b695f1935668" ++
    "02512c057085f5f320b993e8076788082b8757b43ecd2ffdfcd041c4" ++
    "d66fed81178319b2a1b7ad9a0aac14c02b78601bbc3c059e9502811c" ++
    "ed3c291c7fd77711a40e7d86ad0c29ce90474655f25b16d415830931" ++
    "2a10c4446e51fa0ce35a59d13ad90f35770d5f1add4fb28e772de418" ++
    "f56f47eae1761a6e5d0405e207d57102d95369402f2ebbe50e9607c9" ++
    "3e37c352d94f27b53ab40593018b8712176d6031654fe4a22bd91141" ++
    "c1c593841abd318d6d42eb330c9d651760ff16a10388c18c126b9476" ++
    "bdb2034a1eb7986c975ff267f870927f61cf03174ed0cf6602165802" ++
    "125471cfbe30519dd879b41bad488d4d043ea836254de0f43a90b014" ++
    "9a2a73d2c33b8562116b8f01509c9d195f288344ef398223cc81b591" ++
    "b37d1104706728b4cd42e88c3f404f68e1d42ceeb3c9c072552df759" ++
    "f27524fd676183f39a4d61b72f18feb76bfaa06df2ef108a396b6b2c" ++
    "89a25d6f102f6e82c8c5abb187b3b2142f535cfbe8bd27ffb5e9258c" ++
    "68d879023a2cffd42b01ddec6a6d0efbcae0eab506e67841fc88dcd7" ++
    "694cfde934a79985d2e3094de300df0455c2147369f69f44c1ac4088" ++
    "3801589aa80f14860835f76004451686a4a53bad4d6b2d7525df25e2" ++
    "ad99630d16a8a51c9cf699a12f04dbbe9cd0943303459c81e7dcd294" ++
    "fd7aeeb367a4c5e768dcbb3a51bce13698ea201716f1badf36f05c51" ++
    "1c2001625e047aa2572b5ae3715114369182693caa4658b6d5d3288a" ++
    "fb33fc387603333f5b2be27474af6ad7932786a716f3860730d32711" ++
    "059b632a5fdad8c518a6ccdb8a27890f4ff622849a0ceeedf3f77c52" ++
    "baa7886ffcfd6491eb4f2db24f0fa3e6c8532c69356bfe087b8f0706" ++
    "a6f898307c7e8aa596f1710cfc3ca8193a05ffd1e546fabfade8f9dc" ++
    "82edd55a917a79799016e3947385ef110399f25b61628247f4d3058f" ++
    "849d0613fbd40ff14b29d4458778d6da49eefd35f3bd0a44674e8f25" ++
    "41ae2061163e28b75a8fc2981d8c838fec0dbc054b23c426164f6885" ++
    "190f4bfa020936e9d077693d4c7e04735b339f535f627d6992f478cd" ++
    "d3efdc22db45132e77e36d79554bf6dc30e74fbc548e0c361dbb9d3e" ++
    "50d7f5d0e592a704a0cb8baffcdee485cbef3dfc2c15a34126092b63" ++
    "7ca17b215fe662c3bf25bc18cd124a3aafd869ceacd4434d5d244060" ++
    "b78c3c0fd3037bfff0bb040db44fc22a6d37c5d963e115e3ad889da2" ++
    "739b4fb2a50e4d1cf4d80916b9b817bb8c1f252ad948d090aaddbc95" ++
    "0d3c6e56cedb525d8c6152297847434606553202a6edd649a3eeaf55" ++
    "f374e82b8c7cbc8a41bd2bfe1e5d61e690fc1548ccc88d5e6201d9bb" ++
    "4e8f7d6a956eade2d87975241844c44274499b4f009bc1ec40ad5d13" ++
    "e007594bf36b1dfd9fabc495692b018b56c5");

/// The CLI's `zstd -1` frame for the 4096-byte input: 2934 bytes.
pub const encode_skewlit_4096 = hex("28b52ffd64000f455b000a008d2d121080ad0efcddaf1443c1a0e874" ++
    "f8966c9902d002d002d40256836ac1e20e01e84f62b767f79e831952" ++
    "6f12d03ca38248a02d52d36cacf79468a7d109524738351937a7ce4b" ++
    "924405f8c5b56470ff658b0234ec31fac863042174c144d503fd106a" ++
    "cd86b35d2f25e957434659ff4fb83cb853aa6d48f2ec59b94b6517d7" ++
    "f33d98825a0414fd95c2e47803c80178bd09bc76fee1ddd5974526ae" ++
    "165851f5125675a0c980796373950893db70516a683adf4707a79c7a" ++
    "0f34d270f44a3fd380804a766b7082a3bd205e70eb2b3988e0fc8864" ++
    "5a1c5e8b8d87a7d9ce11e1f13030952248d466fb6c949dfce21e23be" ++
    "c44bcbaadbe6f9a0b80b50ed24468d60a8c709613ffa155bf315b9fc" ++
    "6f9333ca9d4628461cb2aa3dedd024be80326b550a05759153295ab0" ++
    "3f3b42893c8f8b7ec09303ce5250012426a93a964134802036c8abfe" ++
    "144ad1b8a57e9a2edd1f9e782545e0ef3381199224e8cbe948dfa115" ++
    "f75d0f4b8ddbf40ca8faa9168868e38d232ead892c1140917e9f40a9" ++
    "ef90c94d8bc4eed769b4947e2ee9827d52e4657980e4d16fad34aae5" ++
    "a1b5b9558bc53063b9e287a38760b9123f877ee720c279136d2169a1" ++
    "2924f3822864fb982c55b806ff68f90bea40cc11fd1ef78fa0698b40" ++
    "b90471b0b4867023029471d55610ea03a0e82884fba2f3d03e91018f" ++
    "7ffafbdc87601f1411b40f47255d2c4a93f6e63c5a79f6a3371edbea" ++
    "65555be7e753a6c801a2d6bc9c28d00c052a0f056070a8a94cb9ab31" ++
    "8aec87507b64e4a81c0d041087fae8a70a0c61af7f2fc25378cfb948" ++
    "2b81288b18c085483e835ef3a200e61689c574e8a09bf5b28ad48b73" ++
    "8a4d340f099cb51d34994504d13f92cb72f0d874b0caeaedd486e8ca" ++
    "92e89ea677c492df23a4600c3e6c5aed137ef15d56e481a87fa2472d" ++
    "2f868f9a032939c04f5fb714ea24283b9e073eee394269a22462cc0c" ++
    "e81f1a9174b94673b6c49c8b6eb74d702d207da7a1699489e9bfbac1" ++
    "2f919e00782528fd6a005767d878a1048c223ca7950a0a73d033ba7e" ++
    "313618a576fc732ac7fedb1d860b35990c4758fed20d7008aad02949" ++
    "a5bffdd7541b49a47115f9a9128e488890169e8d138ac6911ee3b442" ++
    "74e4343d75fce9e40c03d11e8da5ade54c12361610bd1fd837ce2125" ++
    "4a1e56f82aadd43b1792ed10e0e2a2f8b7613adad828e8497e5cfb6c" ++
    "0f58a9730622e58282f482db242c88429c9c07824a4715971f7152ae" ++
    "3f873403c745fb8201b8267d65ed1d0aafab8e8c093858d4653f9142" ++
    "afdf9b53668eb70cb0a7428e1e4c4882428d7cb05a79e7c9af039ba4" ++
    "c91d19f3dac012c832e32c50d7c59873993714186093b04531f53755" ++
    "bd22af95879a29c89c5ed038d419ad8f600afa3f7937fefd7be68524" ++
    "1a36579ae28285245bca841d259b5e53e2cf86ad3497a1cf5b4f6212" ++
    "a6a0cf0b67b03f3cb26124d592005eb364714ea28025e1cd9f92f4f0" ++
    "409f5174d0a7515e106443374b29af2d3ce0a523086a73a3d79d3251" ++
    "e56df87dede4d04a8a5395dbdfc8a9fa713abc9148a85b8a3c5e55a4" ++
    "47c44c85844c74de033d30b97364eedca2181d5246c03e4e2fc11f67" ++
    "62a821c909819c1a99dee11ee0421d808ae63cc976372e85a4c23c20" ++
    "74c93f10f766aed0759eb886c015e113b2912bc5a309a4143e0ae259" ++
    "2ae278657f5ba1be6893879528f4a557526ac3c928c64d37b42ecf04" ++
    "22ea882a74892b133506f496980918009cacfa360c7d2ee52ce07cc1" ++
    "18f8b9930659f519a45c0d946fca5f4280a2b2e636fb7f308d56e4dd" ++
    "e1a46d2b294c01e2ac6380411dbda45903df447b9f42e70c68486c23" ++
    "06b401760ede7a68501f3e633fad3e0b22883c025429e3a81448c553" ++
    "0d7660a93a7e17bb9c8e5c2f5c46ef654afe3d155bc8aac82dd3a9e3" ++
    "e6ceff5dc5953a12e8335d56ca65e8721ee9faf46cd2566fdaeb1977" ++
    "3c65d17b45cc704cb84ceedeebaa53c5a45e9ee4fa1f6079f44d307c" ++
    "522b481927c8ed3bd0bd70984a38c681517f6ce62de859e29bf0bd45" ++
    "9b48cac9a658d5b9c0ddca38d81ed4b80ed500a31080e8983b0f5d26" ++
    "d2943443ac436f298b6f584b23bbdc8a792aeb9c6e02a2a33d0e84fe" ++
    "d6025e4bb9602725ab407e1c4f4c5ccb70eec5ce3d2525b3c950f1df" ++
    "bb861938048a05e54d4753a6b0b820426d404fca2e059939b60fec80" ++
    "7031b44285ca4562c35ed393de201d42198ce9997ad8b08da0a415ed" ++
    "9b8409414adc6304db53e4d2db53a958e29bf6724d64c34628fb5b2d" ++
    "50c58e3192223664383ad1cd5736f82121bb0b920ee55b9aa6339452" ++
    "99b747d8c4dc29d8141f447f6999db927705645bbd7a4cf295020cb4" ++
    "42236f3026181a4462688e5eb150624aeec06080f0c554e70f599a8b" ++
    "4da30b64115dad68b19489eeba79293de940fb497105de331817740d" ++
    "c2a11561a9038c613a0318eb046af3a16055dc6fd32e7194e4c0bc85" ++
    "24e12c854cdd6061638c3ac020e75ca310134ee537fdc2582951b1bb" ++
    "22a89d435264a451b4e43d7c773ddb8597da7091fd3a47783035b3e5" ++
    "759530516cfe0e4022d0c73b021ab742bef72320be5b07158f4ed8d4" ++
    "bf1b7b961f136839596bc81f7f0acc6ba9f7252ca9b8185658f5d38b" ++
    "f8a347ee818d5c321a784fdf01a0f7473bbd6824214ff046300f5141" ++
    "41fb2c34d1021ca3c8a61ec2d10f31df8f342abaa844cbe5b7cbf2cb" ++
    "72dca682212fb94bc42a5ced57ae9491dbabf6b98d6a8008c6b3b181" ++
    "99c95f5cf03d64a4b7a0054ca5b2b8cf1ceacd566eed53c1f5a8f9fa" ++
    "f40e3976efb38019c0b9019a816e98442e0397cf7a46075b07b8ceac" ++
    "08cfcde897fe5001603f70d737f55c158058828103a34d46e14a078d" ++
    "b0b43f42503853693859c1090d19fe702f91c81118b4ecdd056ab2ec" ++
    "50a6c5358231d5bc4d17dc6314da8a73d7ca97045c6041aabebcb4aa" ++
    "beddc267b353e8e00ebd7a5d28e83ef8e81f85d64d6619216503272b" ++
    "14555f1f266a33ed469882698b5695ec9f159d3031e9232a6315b017" ++
    "1e61f8b84aa17d3567366821e8d2e4b6461a3ffb5300960f788977ae" ++
    "86cd44d13bebd247dde0749834a32588158a011cba9918e347e643c3" ++
    "580c13a47740b5766d36197e682fa33e17740fce2e5f895b626082b2" ++
    "ea69d5a84d08a608e010421b4ec4b1a56f36c562041336fb5535847e" ++
    "b35c54e0a648a08e446e983165fea30344b60a0a4324e3b46cab7c53" ++
    "974e8c94d20c3e271d90c0e31815debe99eff4bb66c1800684bdbb6c" ++
    "9a3442a637bf9bf2ef19bc3026e69bac37993537e5a12001aaedd154" ++
    "15f45b88a444e16a502e53aaeab41b63c05e77d35d177e29309e002b" ++
    "9ec3539639424e587120c4053ee03a88b1692a3504506043afc61969" ++
    "a21c1692688e42e0530ae01461b764aa030d15368703565823f6e172" ++
    "d2b5ae55c77dc76a8d6994ee9e7cd63f0bace55a7bb07dc4bebaa4d1" ++
    "913c52160522ca2b8003751227ea04b3b6fa28b0afbe12aae0de3038" ++
    "08e7e54ea8e09261de9dc63d65626d8146a688abba30fe8c66c1a67c" ++
    "a21e5994a958f186a3291964f693e7d0a11f894e94bc17bc5da2d365" ++
    "879c86afce20334968a6dd4ab4ce985214640d4cad7b2087b8a60bb1" ++
    "3784c642a5f6a27c5805a78113979e5523aec01aab888ffbf9ee9330" ++
    "55178f69c499483b1d4cc40f81470488de0b2a0d13f340018fa0c139" ++
    "2747d845186b9a41ddcf804fc6bd0e336aef3c471342ed480b6ac012" ++
    "c9537572540c6570d6b7da15db6fab5ed73ca40ab0b9972c18f70460" ++
    "a9121c09702f468f0460fb00e865b6b4b0b25a7e6d0afd9d95a015d7" ++
    "f3d7f2446a27d4ba034446c3977b06172e5441368aac5345553338f8" ++
    "27e0d1b51e6f8b2493c4ab5475804534a133a78e4cd4632af6901548" ++
    "a8ee948441b85c89b518ee62361c28d84015259631fce84794e6d0fc" ++
    "cf993bd18d1b33d443b14bd173f984b40047e0a524d54dc76916291a" ++
    "c6520df10405464fb39a16cc62facc471a587c7bb02b07b4600b501f" ++
    "cb0eadb3afbc0e8900c1c144ecd0bb4129882d6fa77623dd9fbf2392" ++
    "59f86fbbfdeab247ab3cec9dcd2f248288ce3063a46d02da94f21f19" ++
    "19157efbd849f64600d8cf5816ce26c702004002873f");

/// The CLI's `zstd -1` frame for the 495-byte `words` input: 274 bytes. The
/// smallest corpus prefix whose frame the FSE last-symbol count decrement
/// (`zstd_compress_sequences.c:271-278`) changes: without it the norm, the
/// built table, and the whole bitstream differ.
pub const encode_words_495 = hex("28b52ffd64ef0025080036d12915a0256903807c6fe052b6f7b2b4442cfd" ++
    "ffeffeab1a23002300230094c5a21262e194cd2aba399c70cd3da2593d0e" ++
    "2d1794027e4739d313f6883ec054b4093d75984e19545f6e9a83680e57a7" ++
    "ec018a1cc042d3bd68702eee112fa7ac9db294651e4527abe6400719ce88" ++
    "5e987bbbdac9d4dc61cab306d5e09abed151c69a8b26a44cad02a38cb542" ++
    "9f539653b9e6d9310b372d9726d3e3293bcc3547be2c21ee09b1287b0303" ++
    "242010128224ec01db49303fe268a352d434085831494e03aa85f68ee04b" ++
    "36e21b308d4b32087e0d3acf8801b1e3be254931e0f188be0585427bee4b" ++
    "6c4a9418c4cc754a09da6ab878c7c1ece747b7c536d5d39d5f768f090005" ++
    "7b81a3e1");
/// The CLI's `zstd -1` frame for the scan-exit input: 1733 bytes. The input
/// (`encode.zig`'s `fillScanExitInput`) is the corpus phrase (whose scan runs
/// at step 2) followed by PRNG noise (which grows the step), with an 8-byte
/// repeat planted in the block's last 16 bytes. The C's scan exits at
/// `ip3 >= ilimit` without rescanning (`zstd_fast.c:348-350`); a restart with
/// the step reset to 2 reaches the planted repeat and finds a match the C
/// never visits (1729 bytes, a different frame).
pub const encode_scan_exit = hex("28b52ffd640007bd3500c46a74686520717569636b2062726f776e20666f" ++
    "78206a756d7073206f76657220746865206c617a7920646f672e78f9047a" ++
    "eeb52e80a531eb89146c99a0f6c61443bf17dfb287084dd25a92244a0a62" ++
    "794d61ed24956ee8862f1ad705bf777d24c22dd830445deada524f2b13c7" ++
    "ebf8d08e1336b5850c30b8ce9dee04316e9d004332382972aed282b0d0a0" ++
    "6c72aee87bfa3fd29db6a29a5834188424f1595f06b40e01a15043189d0e" ++
    "acb3cecdbc966fe7bacfe74b0cacd5b1a79d75ce1a3a462a7ed8a4b7c284" ++
    "e081ea06ebcb9302a3ae5e9528d187d85ee4b64d309ee0e4b7ac2fe1accf" ++
    "42bc05e609cfa5aaac4915f892459f9fc56606681f5efba1fb255cbe0e0b" ++
    "8a830a69f9118dde198bf829920b6672bdb0079e6204840f1859b5285719" ++
    "c0641f8b6dff13ba15895672c275d377c3a4734fd8621ac9f06dcab1cce8" ++
    "4cb95385a47393e6a86b9540fdecd7ec89b9ada9556b39062cbc2ab34326" ++
    "0678dd01aa158e121cc5911700153f823ba78ca354cfe0e1e2598c575a4c" ++
    "030cc67e852556e20a6f88f5a74483fcbdd8b8471f2e0dcf9aeb2bc69811" ++
    "c2731724189b3b06e48639aa23b6b6307750a96b96bb3322b053193a7ce0" ++
    "484ae5219ef8a7fc6ba8cf56c78c72ac35a54f2b4d1b1f83b08c77135a1d" ++
    "8da0c6d7224e944caa945744815a86e3f2654ceb8085a12d70595e11c9fb" ++
    "06f4249d3ac39a61feec0ff53b0f51624cb1defe52cb42f36b983fd0f175" ++
    "9e271ea75b8e6ccb3c7bf521d33232836ec0f1a7267db6e06cf061095e56" ++
    "8b1a77b5002663df10284cb8c56c9df8118cba475e66586ad6f2f9b55337" ++
    "685f06ff9d5e73598e56cb64a27a2a8ca48df22199ac438f57860781c482" ++
    "cf3716e7c4a76321820b4bf453e39bed20898e5e0b852efade197c1cfaf8" ++
    "a03bc37458c8abdc9b06729d1f0d47b2775876ae8bdf86ec9e894f3bb80e" ++
    "dc148a39759099ea8518a1c0d811dafbe7e53e3c9bf201c9238fbaf8c4ad" ++
    "e58c8d9c6f9e596f45b754b68c1af34b317b29be43d627317b6b79f14170" ++
    "f4138655bdfd757b879bf6805e1e04b8f51edb8766437127c3fe2ad69192" ++
    "0484252fda4f0f04ab6630343109ee463f1d10d4a8eadc3ffaad85c99c3e" ++
    "ae2a28282e679ec5de1f187f4abae729dce04217c8d9b04283bdff59a6af" ++
    "12126c7a23e8f0f917c9eb8e85fd7c0fe24b53639015c92079f1648c614a" ++
    "ce8362ec34d1fe0600216f7baf002783ebd6b9ea6d6432674ca6931c4982" ++
    "6040a611b23d6b67105d807cacafa272c74524ce11e037d137f9f15509e4" ++
    "6f5c095c07390f72af6f9584035469a15f1af9d3cc91d5d9b00c9ca9d87a" ++
    "f0ae6ca62bc9b958481c6dcee885e5e8c0836f4b2cb9dfb039663b83312e" ++
    "cc9b17e93fb10c62f6cc6591249123b819d03b83411c416436470b385813" ++
    "4c9b7d0a9168a78c7222c1704c65eed4f6831213027903d2044507a0f22f" ++
    "b9c198c62ceb715fa4f1982764f05141f78c9df28849cbf223438bd06fd4" ++
    "443fb4f36ac102fdf581e9fbabcaf9e276b9a3b0ee5e1388bdf48a939a4a" ++
    "188e85f0aefbd9fcb55a5feb1fe9ca697371d3387f23dd567ec436a07626" ++
    "375dd8a7ed72af258f367d8dc87183b4640db14aba20fb0ecbcc83066e9d" ++
    "35790d13c01eafa714473252926b247a03ec11b923cdfaedd74b039edb1d" ++
    "a6a6f9f44a4e304babe551ee061387edb6d623491eab726ec7fc6bc22fa6" ++
    "ff8ce5392b48e010eac4d6ef2e5e48d7eeacba2a46bdbe10659ec9dcdec9" ++
    "045c7325f14227514b971f613ff9de11eb6db81b6cfab349098d6342b761" ++
    "df0d568a2c98a8ce46d8e656a7ece4b0d5c04fe9bd29b051c9c51bf3ffa5" ++
    "62f89cd3db96ce2fc73926109242b0413dd3cccfc91020c4c5e7a49b2f4f" ++
    "ff33d59b0fc015298e55ef38413acf23c8db57ae4dee81dcb1662258d7c8" ++
    "aab14d4ca518e9979e61180ec1e4d2ea152392ee0cdc9d53ae2cc4f9abb8" ++
    "a1612fc71186bcb528c040ba807108d704933cf15779cb6643262796bce2" ++
    "931829606f40cfc50f2c22b2d45ac0f5a28a0493b39ae0a048027c8ff9ee" ++
    "ab75437246c1ba0ad7b1aec41802ff9dae5499d5fe558fb3a9b03ed325c8" ++
    "5314be429e90e141935eb8cf5f6f10156d001faa9da6666fa0f8986b8eb4" ++
    "ea0b6646f07e0ba882b7a6a9b176c28512041b94dfe26566d57cf3d45f17" ++
    "1bf45ac3390c74322bb61b6954be87f68f7c7f0c76eac3e065abddaf26f3" ++
    "40ec4a9d5a5596bf7ab6c26af6eb6f9b3dda6f3d77a11ed9a37f8775c836" ++
    "b0b18fc898a3fa8514872a480832dc58a3ae8448d1f1f9342a8880b540e0" ++
    "45b5890f57af7dcebd0a41880a4c077c0c20589a197f921ebb2e7e789831" ++
    "3f8c8ccca011dd62fd31b4a362ccb4d4d817173046ad5796bf7468652071" ++
    "75696300bc365d23007302004c5029c0106619a06e2f25");

// The `encode_stream_*` fixtures are the CLI's own `zstd -1` frames for the
// same shapes read from a **pipe** (`cat SHAPE | zstd -1`), where the size is
// unknown: the streaming class (`ZSTD_getCParams(1, ZSTD_CONTENTSIZE_UNKNOWN,
// 0)`: windowLog 19, hashLog 14, minMatch 7) and the FCS-unknown six-byte
// header. `Writer` at `default_window_log` reproduces each one byte for byte
// (its test requires it), and each decodes through our decoder and the CLI to
// the shape. The CLI's verdicts: `zstd -t` clean and `zstd -d -c` byte-exact
// on all five (v1.5.7). The empty input is the one case the CLI writes
// differently: it knows the length at the frame's end, so its empty frame is
// the single-segment 13 bytes the one-shot writes, while the `Writer` keeps
// the FCS-unknown form for every frame.

/// The CLI's `zstd -1` frame for the 1024-byte text shape read from a pipe: 67 bytes.
pub const encode_stream_text_1024 =
    hex("28b52ffd0448b50100d40274686520717569636b2062726f776e20666f78206a" ++
        "756d7073206f76657220746865206c617a7920646f672e200100850e2b55063b" ++
        "f59c43");

/// The CLI's `zstd -1` frame for the 32-KiB html shape read from a pipe: 71 bytes.
pub const encode_stream_html_32768 =
    hex("28b52ffd0448d50100c4023c64697620636c6173733d22726f77223e3c737061" ++
        "6e3e68656c6c6f3c2f7370616e666c6174652f6469763e0300c2bf575b83a755" ++
        "ee7c0207cc1117");

/// The CLI's `zstd -1` frame for the 64-KiB rle shape read from a pipe: 23 bytes.
pub const encode_stream_rle_65536 =
    hex("28b52ffd04485500001041410100fb7f1d6001cf99e954");

/// The CLI's `zstd -1` frame for the 131073-byte text shape (two blocks): 72 bytes.
pub const encode_stream_text_131073 =
    hex("28b52ffd0448bc0100d40274686520717569636b2062726f776e20666f78206a" ++
        "756d7073206f76657220746865206c617a7920646f672e20010085fe87b92a03" ++
        "090000683300dc84");

/// The CLI's `zstd -1` frame for the 4-KiB words shape read from a pipe: 1666 bytes.
pub const encode_stream_words_4096 =
    hex("28b52ffd0448ad33000a7cf00f16a0256931803c6d045eee665e5693a4adaaaa" ++
        "d1ffac01f200fa00f9007911a9679b2c1e6417e600e635c17b9b2c2e659b97e9" ++
        "a92fd996b28bb21df3b297ecac4464192e82873bf5411372e73ab90fb273ac74" ++
        "a90289b8945d65ef325de94dbc28db37f152362174c937b1402212af7359b273" ++
        "69d93e903e6984d04b63d9397742e8321d4958cff61c0f62f2ac67445cec8d24" ++
        "3c88c98377055770c961a40b732c3b233dc8ae426fe2c33de44baf09cef138d2" ++
        "9156bae4302177c6bbec41f69abc6c87bb4a9dd704afc92bdb2b70e451f25c72" ++
        "b80244bc74050f3951b653a18b2080ec2a653b96edb6772e3597ed7a36214494" ++
        "ed7b2bbd26031ae92278ef5273c96113a81e25cf657a115c01642b9de7d4d704" ++
        "57a9b3d2b90a9d63b847c9f3401aef25db976ca7d704039807d26598d384d048" ++
        "c2a58c483df7821c239d8bc9e20a1cb9ec0a10f1c0d44fda44d95ef2bd95ce65" ++
        "7a31595cf292b4d2036993c5b6a7547218c05c049b401520e252b39e6de0c844" ++
        "9621a0253b0fb70967a7945dca2e82cb7613a8ae60db3b55861c735c94edb9af" ++
        "c9804eda84d0b677c67b4d3ec84ad97429db4d7c943c44ea48e5ca00cc657b51" ++
        "b6975db64496612ff9908f237d4d5e6a1e6eefb2abd04ae752f306d719cbce85" ++
        "f9704496a108aec0910b2482485de9ac7762d906909de34176d226b20c63d9be" ++
        "2698c8325c989b7076ae52e7d42a75aa0c3792f0904357b645a45e72f8a4d9b8" ++
        "4c5fb2332177e84c1c93976d7b67a597ec9c4257e0087dd290844d38bb18c4e4" ++
        "a9527a57b64bb613429b2c889042cf2e357a76058e6ce228792e8253f592c303" ++
        "4bae77d2d6e02a658410d95eb28295c61cc0ac74ce7d104394ed00e61cebd9de" ++
        "2939a42a992cde3bf50a1c3179ee655740a4da989b2c26caf60a20bb40222684" ++
        "c876a54d8e26504d088df79a60c94e29bb02bcb16c3f79830c97f026841e48c3" ++
        "655740435ef2527661aeb7c9e22a65bb26c791ae1738f2de480f77c9d704dbde" ++
        "b94022ce31bdf426bef740ba983e8ef41c2f6d7bb7ed019847c9a3e64177058e" ++
        "14c15e852ed32bb888cc52677ab82b19d0269c9dd7e48d6567001340f6901359" ++
        "869b28dbdb84b353d8def9a49d632c5b135ca683983c89e73e9046d1b34dfca4" ++
        "8d245c1a9c2350bad46471052bed6b522f652b9d7b058e0cb23ac3e527cdf632" ++
        "13cef0863c97ce5de78194789d735cacf749dbf6f426caf63225614d0664271f" ++
        "48f69ab4ad00119817e627ed32dd04aacb9ad40bf3544c0033dc00665b007311" ++
        "a90154cadec4f5acce4b0f62f26cea269c9db245baa49e5dc16b820bf35256f2" ++
        "a4dd03e90a2e572011268b4fda00e63a572983ec7244f649bbb46c83b16c2f35" ++
        "97b291844b9eba57b94a9d9184cbae2a268b2325db877b13af52b67a0f7711a9" ++
        "261f486b993ee4b601810ba8b198634e1943323322329224e921040882301048" ++
        "62f50111200408214c7a2853019fef345df012378f5e692455da0c2d0391ae67" ++
        "2046a8937a60da599158201d4f4eca9975d5fa2de81abba5ab3e8e49028a1600" ++
        "03ae930d21dcd6fbcfbe322d5f491a870258078a6bee28912fc0c8aba1393e49" ++
        "184cf8956adb196c0b83207c8364336b8e2b8cc5f5469e49636cd4ec20de2780" ++
        "006277943230fe01dd0ec14c0a217c65759fe70256f8141353dbd32a37a125b8" ++
        "e41a55de6d0ade75642c1ef00b3be6df6825774787e5d785b39b2d704d41f746" ++
        "a96bdf4daa23548f1ce3e4b4c902153a04e61f92e941d7aebb2866d2c60538b7" ++
        "fe927aef42355f3688f1b3f7297792a1ab6dcb0cc57e83d7bd7df1e3829710fb" ++
        "8864cce0241e429601dc49e21d2261f0f12e8a51d3e9dd36e9a5a45310fb01a6" ++
        "31503f98666c387549fbbae24fa4d85aedea4b63bb09046d8a889b451382e27c" ++
        "8f34d44fd4f9b2e015a1cf3cc0e981a7802c67e720e7983621b658f130c0018d" ++
        "d8c0ae717e538e0c30ee8c484355da228b9a9746f527fe6c0239a7cc57de0bca" ++
        "b359c39dd7e528abe87dfe0682a14119a1cd261dddf404f69a4ba17950a913f5" ++
        "95c576356de78cd47c6f656f54f07027b7102d114ff08917fb9c173c3d8082e3" ++
        "a5eb39a11406ab47e15fe2ddabcb7a393c2b6d2d15180aea2c14eac40da69879" ++
        "958709195d02314c646fc640cc35d973b9e3f2263829f64f1f1f2b1c06e72e51" ++
        "dcc8968aafdcba534daaa3170b906ce8d1da82f61c50b0f920003e23e9140077" ++
        "7e04fe0545432790eab91e944c02f2265c8ec1384ff5a61a0308a78a15f2726d" ++
        "4074f99a7811fb11a7de04d4d15b892dfe13c9c604701814fdc04fccac6a018b" ++
        "56c5");
/// The CLI's `zstd -1` frame for the 600000-byte input: 120 bytes.
pub const encode_text_600000 = hex("28b52ffd8448c0270900bc0100d40274686520717569636b2062726f" ++
    "776e20666f78206a756d7073206f76657220746865206c617a792064" ++
    "6f672e20010085fe87b92a034c000008680100fcff3910024c000008" ++
    "200100fcff3910024c000008690100fcff3910024d000008790100bc" ++
    "273910024d285484");

/// The input witness: the class that catches the clamp-order-85B fix's revert
/// (the M5 verification witnesses, recorded from the finder sweeps).
pub const clamp_order_85b_source = hex("7370616e3e68656c6c6f3c2f7370616e3e3c7370616e3e666c617465" ++
    "3c2f7370616e3e3c2f6469763e3c64697620636c6173733d22726f77" ++
    "223e3c7370616e3e68656c6c6f3c2f7370616e3e3c7370616e3e666c" ++
    "61");

/// The pinned CLI v1.5.7 output, `zstd -1 --check` on the witness.
pub const clamp_order_85b_frame = hex("28b52ffd2455f5010014037370616e3e68656c6c6f3c2f7370616e3e" ++
    "3c7370616e3e666c6174652f6469763e3c64697620636c6173733d22" ++
    "726f772203005e7d90a9cc28623a01e7f7b916");

/// The input witness: the class that catches the clamp-order-94B fix's revert
/// (the M5 verification witnesses, recorded from the finder sweeps).
pub const clamp_order_94b_source = hex("726520686572206174207468617420776861742077697468206f7574" ++
    "20666f72206275742066726f6d207768656e206974206f7220746861" ++
    "7420696e206f746865722077697468207768656e2061207468652062" ++
    "79207573652074686973");

/// The pinned CLI v1.5.7 output, `zstd -1 --check` on the witness.
pub const clamp_order_94b_frame = hex("28b52ffd245e150200d2440d11b0351d744866b3855b461c350c0b19" ++
    "9d08a5d8a9980331b18709f11cb136a9b35b13e219b01bd788cfc635" ++
    "365be706f6868f385d0300520dbe53e3e02a4b7768c6e4");

/// The input witness: the class that catches the tree-tie-584B fix's revert
/// (the M5 verification witnesses, recorded from the finder sweeps).
pub const tree_tie_584b_source = hex("01020504050208040a010401040100040300050b0102021112070008" ++
    "010e05130912030b010303030c0a04010100000c0c060a0201050402" ++
    "0902020c150b0005100e00030900040b0101000b01040313020c0811" ++
    "1304040012000100030400000304020c040400130400030402040204" ++
    "000404050104110a01020012121505040b040401051401020702020b" ++
    "020214040500020105050a0303020f0414020c000b0002030101090d" ++
    "0205001211041214020a0d080b10030e001400090406050801000500" ++
    "0400130b08000200030f04040e00010201030004010c01140700030b" ++
    "050f030603010105031414030005030e05030d0114130d0a05030203" ++
    "070e0100040310020112000a040300050f030b020b10060404100301" ++
    "09040104020204050909040203020215000300100d02010701010103" ++
    "0403030012010111000f060f00010208140405010208010e13021204" ++
    "050400010303050b010f040e0301020100000c1409020f0102020105" ++
    "0102040b05010001011014000501040304020c130203020e07111300" ++
    "0f06050e03000314050400140103070501030109020f000d020c0302" ++
    "040401100f130107000b0a0710130a0502040f0a0505050214011304" ++
    "0600000311040c0304010503120201030d1300110701020500070702" ++
    "0800110f03000204041111030112080001071304030c000401020503" ++
    "020106001301070212030e0101050304150905040b0102030e040101" ++
    "0c03020302020101100c130604020200130404090b0a02040704130e" ++
    "030401120000021303040f0404020401000902010c050215");

/// The pinned CLI v1.5.7 output, `zstd -1 --check` on the witness.
pub const tree_tie_584b_frame = hex("28b52ffd644801d5090086a44d94555554232223312222233047004b" ++
    "004900aba7d6b4a54cc5dfbc0249b29240cefaf7bef78ef69fdedb3d" ++
    "2ed98f10e114f93423cd3778c5513381d30e7db14470ce469e38b669" ++
    "9c0ca80a0a2b09d2d2d4fcf13c890bad5719fd30d4dbf3037dfcc161" ++
    "6a6cd47c62097bf863515c170140890057e19a5372910e6c94f14ae2" ++
    "e167962b7ec3eb0483f6d52854f06169850f230088a6e448b22a6020" ++
    "dd999da61bb5892a366f11e828845921320efef5296046079a55ccb4" ++
    "57f25c54600c21a5a88b4eefb3960e722cf3b2d8d2e890cec6d2c50d" ++
    "9ab2b9d793a28242594f423923308690c9ec9b646101c7bc40eb81d6" ++
    "6187f1fd8d1b754b7817e8e525ccf0a3b50fd039c8d6f5215fb834af" ++
    "217017593869215ac0bacaeff8a870424223c8dfd94026b494555990" ++
    "2180d9c4c5fb1cf1161c31b5aa0823003ff252fb");

/// The input witness: the class that catches the tree-tie-890B fix's revert
/// (the M5 verification witnesses, recorded from the finder sweeps).
pub const tree_tie_890b_source = hex("020304030302090303000403030703040b02020b090806030c030900" ++
    "050b020300030304050507060301000104010003000408010e010202" ++
    "07050800000404010d050602020101030207020e0f0f02020d04050f" ++
    "030a0f0201040203020e04000a0303040201040303030004000b0800" ++
    "010a01020c05010204000304020500020e0209010d02000505040301" ++
    "0005000105030c070c0004010401020002030b030a00030307010003" ++
    "0008030802020b03050803040b0400030a0907020102020001010401" ++
    "030601040902020307020501070f030004060e0100030201040f0203" ++
    "0d00090c080005090301090204050802090301040b0a000308040307" ++
    "040f010d00000305040300030d0104010b030e06040204020400030d" ++
    "0b030208030f0f0f0701050305070701050409010805020205010300" ++
    "0c0a000902060d02040101050305030108010e040f000108040c0302" ++
    "0403010b0d03020e04040f05030401030204090203050a0101000a03" ++
    "0d0c0304030b0600000f00020e0604050d000107030e03070e0e0c04" ++
    "0706040405040100040e0a0a00010108010204050307040e030f0307" ++
    "0506040301040d0c040e0f09060a0f040503010805030d0d09050c00" ++
    "05000f090107050204020402010f05060b070301040a0c030e0e0203" ++
    "00030a04010402010804020f0404010e050202060005050004070101" ++
    "0d0402030a0002040305010300020309010203040802000200050200" ++
    "090102010202010102060106010d030a010302080c0f04040205000e" ++
    "00060500000e030303040500010e010c03010601030a02060102040f" ++
    "050204020203000302000f030405050d0c010e04010005030e030a03" ++
    "0101020406050c0004040b0c0506010d0a04040404010f0302000503" ++
    "0001090403050a010101010000060f09010e02050404030f03020c0b" ++
    "010907000f04010b010100080405090503000804070205020d0c0000" ++
    "04000607030203070802010b0d030001040e01050001050402060703" ++
    "08000103020e000d0404000402050a0e040100020a040706030f0307" ++
    "000001020101000f0204020302060f0106020304030c050403030f03" ++
    "000b000b030b010b0305020203040c00020406040901050106000308" ++
    "0305040103050403020504080303020c010f08070202050104030a04" ++
    "0702030d06010105020d090004050801020c030f0c00000a07000005" ++
    "0103030900000d0203010b080c04030b01010b05030f");

/// The pinned CLI v1.5.7 output, `zstd -1 --check` on the witness.
pub const tree_tie_890b_frame = hex("28b52ffd647a027d0d00a6f76a8e333332111111111064006b006600" ++
    "4d673d22f039055683db7102f3e45a360ce2bddca25c5a61318fc11e" ++
    "7171579e9f09c6c5d5e857ad87a3a8abde7b59a6249c28fb6c9fbd4d" ++
    "7654f76c224ef5d3a6841a6ab20575f86fa2424b44f1793c47835075" ++
    "7b6ea90d1b03314a5bee607ff6a87d3735ce7109ba9e081809dd9cd3" ++
    "07159c8c1e5c2f053942d0c7d70fc20d42c1c8813b7580bab481e2db" ++
    "1c9391a4dcf19a77a51fd5a7d0afcd05978e28e87291ef011d236666" ++
    "b525385e0ca15c0c29258bba1cef7d0f900bcfe3f9e5ed303df8c223" ++
    "e5f4a8a877d0a326ccd8714efeab8823818d2449f98373ad4efc7f72" ++
    "08ca947fa6c04b9a18b9c6239a5375a7d573fb567a094a4c401b22ae" ++
    "6e1b6d058656fd931135890f0141c996e5586b5dc55d0e7766f91d71" ++
    "7fc8f0550db485f8a75eb0e789e72264434e87022ab1ef5b8123ad66" ++
    "02c955c8e21b51e89e6dd8ac2d90cd249b52d4374e8b04c70d273eab" ++
    "0d22d1d416affa65be2c3cc0e2387867eeb65c585c56e664bf8cef02" ++
    "2650f74d23cb2d381984938e47a4fafd67a8e68403e88b2ba2733e85" ++
    "15c17500fb664eabe162ae5117230b9f16068b69009bcdcfd6");
