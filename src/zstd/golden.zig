//! Fixtures shared by every zstd layer's tests: the Appendix A FSE tables,
//! table descriptions and Huffman weights from real encoder output, literals
//! and sequences sections from real frames, and whole frames, good and
//! corrupt, for the block, frame, and streaming layers. Provenance is noted
//! beside each group. Helpers: `hex` (comptime hex literals), `buildFrame`
//! (assembles a frame from block contents), and `expectDecoded` (the shared
//! decode check). "The CLI" in the comments below is the zstd CLI v1.5.7,
//! the reference decoder the fixtures were generated and checked with.
//!
//! Format: docs/research/specs/rfc8878-zstd.txt

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const internal = @import("../internal/root.zig");

/// Comptime hex decoding, so the vectors keep the spelling of their source
/// (the CLI's own hex output, the research harness's dumps) instead of being
/// transcribed into byte lists.
fn hex(comptime text: []const u8) [text.len / 2]u8 {
    @setEvalBranchQuota(100_000);
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
