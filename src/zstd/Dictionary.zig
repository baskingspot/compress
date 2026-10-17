//! `zstd.Dictionary` (RFC 8878 §5): a parse-once, zero-copy value holding a
//! dictionary's entropy tables, repeat offsets, and content, handed to the
//! decoder to seed a frame's starting state and to the encoder to seed its
//! tables and match region.
//!
//! `parse` reads the formatted form — the `0xEC30A437` magic, the
//! Dictionary_ID, the four entropy-table descriptions in §5's order, the 12
//! repcode bytes, then the content — with the same readers the decoder uses
//! for a compressed block's tables, so the wire forms are shared and tested
//! once, and builds both directions' tables from that one parse: the
//! decoder's fused tables and the encoder's (`ZSTD_loadCEntropy`), with its
//! promotion rules deciding which tables a frame may reuse (`repeat_valid`).
//! `initRaw` is §5's raw-content form: content only, the default {1,4,8}
//! repeat offsets, and no ID. The value borrows `source` (no copy, no
//! allocation) and must outlive every call that uses it.
//!
//! Format: docs/research/specs/rfc8878-zstd.txt §5

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const fastmem = @import("fastmem");

const common = @import("common.zig");
const dfast_compress = @import("dfast_compress.zig");
const fse = @import("fse.zig");
const fse_compress = @import("fse_compress.zig");
const golden = @import("golden.zig");
const huff0 = @import("huff0.zig");
const huff0_compress = @import("huff0_compress.zig");
const match_compress = @import("match_compress.zig");
const sequences = @import("sequences.zig");

const Dictionary = @This();

/// `§5` — "Magic_Number: 4 bytes, little-endian format. Value: 0xEC30A437."
pub const magic: u32 = 0xEC30_A437;

/// The Magic_Number's 4 bytes (`§5`).
pub const magic_len = 4;
/// `§5` — "Dictionary_ID: 4 bytes, little-endian format. ... any value,
/// except 0 (which means no Dictionary_ID)".
pub const id_len = 4;
/// `§5` — "3 offset values, populating repeat offsets ... stored in order,
/// 4 bytes little-endian each, for a total of 12 bytes."
pub const repcodes_len = 12;

/// Everything `parse` reports. The first four names are this layer's; the
/// last two are the shared readers' (`huff0.readTree`, `fse.readDescription`)
/// for a table description that is cut short or malformed — the same names
/// the block layer reports for the same bytes.
pub const ParseError = error{
    /// The source ends before the magic, inside the Dictionary_ID, or inside
    /// the 12 repcode bytes. A table description cut short is its reader's
    /// own error instead (`MalformedHuffmanWeights`, `MalformedFseTable`):
    /// the description's length is decoded from its own bytes.
    Truncated,
    /// The first four bytes are not `0xEC30A437` LE: not the formatted form.
    BadDictionaryMagic,
    /// `§5` — the Dictionary_ID is 0, "which means no Dictionary_ID". The C
    /// reads a zero ID and keeps going (DT4); ours fails closed at the parse.
    InvalidDictionaryId,
    /// `§5` — a repeat offset is 0 or above the content size. The RFC's word
    /// is "the dictionary size"; the references enforce the content size,
    /// the only reading consistent with the trainer's output (DT2).
    InvalidDictionaryRepcode,
    /// `§4.2.1` — the literals tree description is cut short or its weights
    /// do not form a valid tree. Incomplete statistics are legal (§5's
    /// tables are the block forms): zero weights are accepted.
    MalformedHuffmanWeights,
    /// `§4.1.1` — one of the three FSE descriptions is cut short, exceeds its
    /// context's caps, or its budget does not land exactly. Zero-probability
    /// symbols are legal: the table may cover less than its whole alphabet.
    MalformedFseTable,
};

/// `§5` — the Dictionary_ID; 0 for a raw dictionary, which names none.
id: u32,
/// Whether the entropy tables are present. False for a raw dictionary
/// (`initRaw`): no tables, the default repeat offsets.
has_entropy: bool,
/// The literals Huffman tree description (`§4.2.1`), as parsed. The decode
/// table is built from it at the parse; the encode side's reuse rules read
/// the weights (zero weights and a short alphabet are unpromotable, not
/// illegal).
literals_tree: huff0.Tree,
/// The literals decode table a Treeless_Literals_Block reuses (`§5`'s
/// "Huffman table for literals ... populate the Repeat Stats literals
/// mode"). Meaningful only when `has_entropy`.
literals_table: huff0.DecodeTable,
/// The three sequences decoding tables (`§5`'s offsets, match lengths, and
/// literals lengths descriptions), fused for the sequences loop exactly as a
/// Repeat_Mode needs them. Meaningful only when `has_entropy`.
sequence_tables: [sequences.alphabet_count]sequences.SeqTable,
/// `§5`'s 12 repcode bytes: Repeated_Offset1/2/3 in place of the {1,4,8}
/// seed. {1,4,8} for a raw dictionary.
repeat_offsets: [3]u32,
/// The encode side's literals table (`HUF_readCTable`): the same tree in the
/// form a Treeless_Literals_Block encodes with. Meaningful only when
/// `has_entropy`.
literals_table_compress: huff0_compress.Table,
/// `ZSTD_loadCEntropy`'s `HUF_repeat_valid` promotion (`zstd_compress.c:5071-5079`):
/// the tree covers all 256 symbols with no zero weight, so the encoder may
/// reuse it blindly — the 6-literal floor and the unmeasured reuse a
/// Treeless block takes. False for a raw dictionary.
literals_repeat_valid: bool,
/// The encode side's three sequence tables (`FSE_buildCTable_wksp`), from
/// the same descriptions as `sequence_tables`. Meaningful only when
/// `has_entropy`.
sequence_tables_compress: [sequences.alphabet_count]fse_compress.Table,
/// `ZSTD_dictNCountRepeat`'s promotion per alphabet (`zstd_compress.c:5047-5059`):
/// the loaded table covers the whole alphabet the encoder may need, with no
/// zero-probability symbol, so the fast ladder's Repeat_Mode may reuse it.
/// Empty for a raw dictionary.
sequence_repeat_valid: std.EnumSet(sequences.Alphabet),
/// The whole dictionary file's length — the C's `cdict->dictContentSize`,
/// which the level's parameters are sized from. `content.len` for a raw
/// dictionary, which has no file around it.
source_len: usize,
/// The C's CDict match table (`match_compress.DictTable`): the content's
/// positions, filled once here the way `ZSTD_fillHashTableForCDict` fills a
/// `ZSTD_CDict`'s — so a frame that compresses against this dictionary never
/// re-hashes it. Empty (no entries) for a dictionary with no content. The
/// level-1 finder's table; the level-3 one is `match_dfast`.
match: match_compress.DictTable,
/// The C's CDict match tables for the level-3 finder
/// (`dfast_compress.DictTables`, filled by
/// `ZSTD_fillDoubleHashTableForCDict`): the long and small tables, both
/// tagged. A frame at level 3 looks up (attach) or copies (copy path) these
/// instead of `match`'s.
match_dfast: dfast_compress.DictTables,
/// `§5` — "The rest of the dictionary is its content. The content acts as a
/// 'past' in front of data to be compressed or decompressed, so it can be
/// referenced in sequence commands." Borrowed from the caller's bytes.
content: []const u8,

/// Parse a formatted dictionary (`§5`) from `source`.
///
/// The entropy tables are read with the same parsers a compressed block's
/// tables go through (`huff0.readTree`, then `fse.readDescription` for
/// offsets, match lengths, and literals lengths with the caps 31/8, 52/9,
/// 35/9), and the tables are built once here — nothing re-parses per frame
/// or block. The returned value borrows `source`: the content slice and the
/// table descriptions are never copied, so keep the bytes alive as long as
/// the value is used.
///
/// Errors are `ParseError`'s: a malformed piece fails with its own name,
/// raised before any table is handed out.
pub fn parse(source: []const u8) ParseError!Dictionary {
    if (source.len < magic_len) return error.Truncated;
    if (common.readInt(u32, source[0..magic_len]) != magic) return error.BadDictionaryMagic;
    if (source.len < magic_len + id_len) return error.Truncated;
    const id = common.readInt(u32, source[magic_len..][0..id_len]);
    if (id == 0) return error.InvalidDictionaryId;
    var cursor: usize = magic_len + id_len;

    // §5 — "They are stored in the following order: Huffman table for
    // literals, FSE table for offsets, FSE table for match lengths, and FSE
    // table for literals lengths." Each description's own length is decoded
    // from its bytes, so a source that ends inside one is that reader's
    // malformed-table error, not an overread.
    // `readTree`'s declared set is shared with the Huffman stream decoder;
    // every failure a *description* can hit is the malformed-weights class
    // (§4.2.1.1: the description's own length field is what a cut-short one
    // breaks).
    const tree = huff0.readTree(source[cursor..]) catch return error.MalformedHuffmanWeights;
    cursor += tree.bytes_consumed;
    var dictionary: Dictionary = .{
        .id = id,
        .has_entropy = true,
        .literals_tree = tree,
        .literals_table = huff0.buildTable(&tree),
        .literals_table_compress = huff0_compress.tableOfTree(&tree),
        .literals_repeat_valid = literalsPromoted(&tree),
        .sequence_tables = undefined,
        .sequence_tables_compress = undefined,
        .sequence_repeat_valid = .empty,
        .repeat_offsets = undefined,
        .content = undefined,
        .match_dfast = undefined,
        .source_len = source.len,
        .match = undefined,
    };
    // The three FSE descriptions, in §5's order. Their normalized counts
    // build both directions' tables; the promotion needs the content size
    // for the offsets rule, so it waits until the repcode bytes have named
    // the content's start.
    var descriptions: [sequences.alphabet_count]fse.Description = undefined;
    inline for (.{
        sequences.Alphabet.offsets,
        sequences.Alphabet.match_lengths,
        sequences.Alphabet.literals_lengths,
    }) |alphabet| {
        const parsed = try sequences.readDictionaryTable(alphabet, source[cursor..]);
        cursor += parsed.bytes_consumed;
        const index = @intFromEnum(alphabet);
        dictionary.sequence_tables[index] = parsed.table;
        dictionary.sequence_tables_compress[index] = fse_compress.buildTable(
            encodeNorm(alphabet, &parsed.description),
        );
        descriptions[index] = parsed.description;
    }

    // §5 — "It is finally followed by 3 offset values, populating repeat
    // offsets (instead of using {1,4,8}), stored in order, 4 bytes
    // little-endian each, for a total of 12 bytes. Each repeat offset must
    // have a value less than the dictionary size." The content starts after
    // them, and the references enforce the *content* size (DT2).
    if (source.len - cursor < repcodes_len) return error.Truncated;
    const content = source[cursor + repcodes_len ..];
    inline for (0..3) |index| {
        const rep = common.readInt(u32, source[cursor + index * 4 ..][0..4]);
        if (rep == 0 or rep > content.len) return error.InvalidDictionaryRepcode;
        dictionary.repeat_offsets[index] = rep;
    }
    dictionary.content = content;
    for ([_]sequences.Alphabet{
        .offsets,
        .match_lengths,
        .literals_lengths,
    }) |alphabet| {
        const index = @intFromEnum(alphabet);
        if (repeatPromoted(alphabet, &descriptions[index], content.len)) {
            dictionary.sequence_repeat_valid.insert(alphabet);
        }
    }
    match_compress.fillDictTable(&dictionary.match, content, dictionary.matchParams(1));
    dfast_compress.fillDictTables(&dictionary.match_dfast, content, dictionary.matchParams(3));
    return dictionary;
}

/// The dictionary's own parameters for a level (the C's CDict cParams),
/// which a frame's window, hash widths, and match width are drawn from
/// (`ZSTD_resetCCtx_byAttachingCDict` / `..._byCopyingCDict`).
pub fn matchParams(self: *const Dictionary, level: u8) match_compress.DictParams {
    return match_compress.dictParams(level, self.source_len);
}

/// `ZSTD_loadCEntropy`'s literals promotion (`zstd_compress.c:5071-5079`):
/// "We only set the loaded table as valid if it contains all non-zero
/// weights. Otherwise, we set it to check" — and the tree must reach the
/// full alphabet (`maxSymbolValue == 255`, the issue #3724 fix).
fn literalsPromoted(tree: *const huff0.Tree) bool {
    if (tree.symbol_count != huff0.symbol_count_max) return false;
    for (tree.weights[0..tree.symbol_count]) |weight| {
        if (weight == 0) return false;
    }
    return true;
}

/// The encode-side table's normalized counts (`FSE_buildCTable_wksp`): the
/// C builds the offsets table over `MaxOff` — "fill all offset symbols to
/// avoid garbage at the end of table" — and the other two over the
/// description's own last symbol. Symbols past the description carry the
/// zero `readDescription` wrote.
fn encodeNorm(alphabet: sequences.Alphabet, description: *const fse.Description) fse_compress.Norm {
    return .{
        .counts = description.counts,
        .symbol_count = if (alphabet == .offsets)
            @as(u16, sequences.offset_code_max) + 1
        else
            description.symbol_count,
        .accuracy_log = description.accuracy_log,
    };
}

/// `ZSTD_dictNCountRepeat` (`zstd_compress.c:5047-5059`): "Mark dictionaries
/// with zero probability symbols as FSE_repeat_check and only dictionaries
/// with 100% valid symbols can be assumed valid." The offsets table's
/// requirement is representability, not the full alphabet: every offset up
/// to `dictContentSize + 128 KiB` — the farthest a match into the dictionary
/// can reach — must have a code.
fn repeatPromoted(
    alphabet: sequences.Alphabet,
    description: *const fse.Description,
    content_len: usize,
) bool {
    const needed: u16 = switch (alphabet) {
        .literals_lengths => sequences.literals_length_code_max,
        .match_lengths => sequences.match_length_code_max,
        .offsets => @intCast(@min(offcodeMax(content_len), sequences.offset_code_max)),
    };
    if (description.symbol_count - 1 < needed) return false;
    for (description.counts[0 .. @as(usize, needed) + 1]) |count| {
        if (count == 0) return false;
    }
    return true;
}

/// `ZSTD_highbit32(dictContentSize + 128 KB)` (`zstd_compress.c:5134-5136`):
/// the largest offset code a match into the dictionary can need.
fn offcodeMax(content_len: usize) u16 {
    const max_offset = content_len + 128 * 1024;
    return @intCast(@bitSizeOf(usize) - 1 - @clz(max_offset));
}

/// A raw-content dictionary (`§5`): "Zstandard is compatible with 'raw
/// content' dictionaries, free of any format restriction ... These
/// dictionaries function as if they were just the content part of a
/// formatted dictionary." Content only: no tables (so no Treeless literals
/// or Repeat sequences from the first block), the default {1,4,8} repeat
/// offsets, and no Dictionary_ID — it never satisfies a frame that declares
/// one (DT5: the C's shape; klauspost's ID-assigning raw form is not
/// ported).
///
/// Infallible and format-free: any bytes parse, and §5's 8-byte floor is not
/// enforced (the references accept shorter content too). The value borrows
/// `content`.
pub fn initRaw(content: []const u8) Dictionary {
    var dictionary: Dictionary = .{
        .id = 0,
        .has_entropy = false,
        .literals_tree = undefined,
        .literals_table = undefined,
        .literals_table_compress = undefined,
        .literals_repeat_valid = false,
        .sequence_tables = undefined,
        .sequence_tables_compress = undefined,
        .sequence_repeat_valid = .empty,
        .repeat_offsets = sequences.repeat_offsets_start,
        .content = content,
        .source_len = content.len,
        .match = undefined,
        .match_dfast = undefined,
    };
    match_compress.fillDictTable(&dictionary.match, content, dictionary.matchParams(1));
    dfast_compress.fillDictTables(&dictionary.match_dfast, content, dictionary.matchParams(3));
    return dictionary;
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc8878-zstd.txt §5 (the dictionary
// format), §4.2.1 (the literals tree), §4.1.1 (the FSE descriptions). The
// trained fixtures are `golden.zig`'s, each trained and checked with the
// pinned zstd v1.5.7 CLI; the field expectations come from the research's
// independent from-scratch parse (docs/research/dictionary-notes.md §1.1).
// ---------------------------------------------------------------------------

test "parse reads the trained dictionaries" {
    // §5 — the magic, the ID, the four table descriptions, the 12 repcode
    // bytes, the content. The fixture's fields are the research's §1.1 table:
    // ID 574546390, a 256-symbol literals tree, an 18-symbol offsets table,
    // full 53- and 36-symbol length tables, the trainer's default {1,4,8}
    // reps, and 14,378 content bytes from offset 115.
    const dictionary = try parse(golden.dict_trained);
    try testing.expectEqual(@as(u32, 574_546_390), dictionary.id);
    try testing.expect(dictionary.has_entropy);
    try testing.expectEqual(@as(u16, 256), dictionary.literals_tree.symbol_count);
    try testing.expectEqual(@as(usize, 115), golden.dict_trained.len - dictionary.content.len);
    try testing.expectEqual(@as(usize, 14_378), dictionary.content.len);
    try testing.expectEqual([3]u32{ 1, 4, 8 }, dictionary.repeat_offsets);
    // §5's table order is literals Huffman, offsets, match lengths, literal
    // lengths; the trained dictionary's offsets table covers 18 symbols
    // (the dictionary size's offset code range), the other two their whole
    // alphabets (53 and 36).
    try testing.expectEqual(@as(u5, 8), dictionary.sequence_tables[1].log);
    try testing.expectEqual(@as(u5, 9), dictionary.sequence_tables[2].log);
    try testing.expectEqual(@as(u5, 9), dictionary.sequence_tables[0].log);
    // The second trained dictionary (the CLI's `--dictID=100` variant): the
    // mismatch matrix's other seat, and the 1-byte DID form's dictionary.
    const second = try parse(golden.dict_100);
    try testing.expectEqual(@as(u32, 100), second.id);
    try testing.expectEqual(@as(usize, 8_042), second.content.len);
    try testing.expectEqual([3]u32{ 1, 4, 8 }, second.repeat_offsets);
    // Two dictionaries, two IDs: the mismatch matrix's second seat.
    try testing.expect(second.id != dictionary.id);
}

test "parse accepts the incomplete statistics the references ship" {
    // DD11 — a dictionary with zero weights and tables short of the
    // alphabet is legal: the C through v1.5.5 errored on the tree, v1.5.6+
    // does not, and the format has no version field (issue #3724). The C's
    // `zero-weight-dict` is the pin: 120 zero weights in its tree and FSE
    // tables that stop short of their alphabets (offsets at symbol 17).
    const zero_weight = try parse(golden.dict_zero_weight);
    try testing.expect(zero_weight.has_entropy);
    try testing.expectEqual(@as(u16, 256), zero_weight.literals_tree.symbol_count);
    try testing.expect(zero_weight.sequence_tables[1].log <= 8);
    // The C's `http-dict-missing-symbols` is *not* accepted: its literals
    // tree completes to Max_Number_of_Bits 12 (the C's HUF_readStats reads
    // it as tableLog 12, its internal HUF_TABLELOG_MAX), where RFC 8878
    // §4.2.1 "limits the maximum code length to 11 bits". klauspost rejects
    // it too ("tableLog too big"); ours is RFC-strict (DT9).
    try testing.expectError(error.MalformedHuffmanWeights, parse(golden.dict_missing_symbols));
}

test "parse rejects each malformed piece with its own name" {
    // §5 — the magic. Fewer than four bytes cannot carry it (`Truncated`);
    // four wrong bytes are `BadDictionaryMagic`.
    try testing.expectError(error.Truncated, parse(&.{}));
    try testing.expectError(error.Truncated, parse(&.{ 0x37, 0xa4, 0x30 }));
    try testing.expectError(error.BadDictionaryMagic, parse(&.{ 0x38, 0xa4, 0x30, 0xec }));
    try testing.expectError(error.BadDictionaryMagic, parse(&golden.frame_magic));
    // §5 — the ID: cut short is `Truncated`; zero is `InvalidDictionaryId`
    // (DT4: the C reads it, ours fails closed).
    try testing.expectError(error.Truncated, parse(&.{ 0x37, 0xa4, 0x30, 0xec, 0x01 }));
    const zero_id = [_]u8{ 0x37, 0xa4, 0x30, 0xec, 0, 0, 0, 0 };
    try testing.expectError(error.InvalidDictionaryId, parse(&zero_id));
    // §5's tables: an empty description is the literals reader's malformed
    // name, and a source that ends inside the three FSE descriptions is the
    // FSE reader's (the trained fixture truncated after each piece).
    const after_id = [_]u8{ 0x37, 0xa4, 0x30, 0xec, 1, 0, 0, 0 };
    try testing.expectError(error.MalformedHuffmanWeights, parse(&after_id));
    const tree_len = 1 + golden.dict_trained[8]; // the FSE-weight form's header byte
    try testing.expectError(
        error.MalformedHuffmanWeights,
        parse(golden.dict_trained[0 .. 8 + tree_len - 1]),
    );
    try testing.expectError(
        error.MalformedFseTable,
        parse(golden.dict_trained[0 .. 8 + tree_len + 1]),
    );
    // The 12 repcode bytes: a source that ends before them is `Truncated`.
    const before_reps = golden.dict_trained[0 .. golden.dict_trained.len - 14_378 - 1];
    try testing.expectError(error.Truncated, parse(before_reps));
    // §5 — "Each repeat offset must have a value less than the dictionary
    // size": a zero byte, and a value above the content size, are both
    // `InvalidDictionaryRepcode`. The trained fixture's bytes are patched at
    // the first repcode byte to build each.
    var patched: [golden.dict_trained.len]u8 = undefined;
    const reps_at = golden.dict_trained.len - 14_378 - repcodes_len;
    for ([_]u32{ 0, 14_379, 0xffff_ffff }) |bad| {
        fastmem.copy(u8, &patched, golden.dict_trained);
        common.writeInt(u32, patched[reps_at..][0..4], bad);
        try testing.expectError(error.InvalidDictionaryRepcode, parse(&patched));
    }
}

test "the trained dictionary promotes all four tables, the incomplete ones degrade" {
    // `ZSTD_loadCEntropy`'s promotion rules (`zstd_compress.c:5047-5079`):
    // the literals tree is `repeat_valid` only on 256 symbols with no zero
    // weight, each FSE table only on full coverage with no zero count (the
    // offsets table over the alphabet a match into the content can need).
    // The trainer writes complete statistics by design, so all four promote;
    // an incomplete-statistics dictionary is legal and promotes only what
    // covers, which is what "degrade honestly" means (DD11, DE2).
    const trained = try parse(golden.dict_trained);
    try testing.expect(trained.literals_repeat_valid);
    try testing.expect(trained.sequence_repeat_valid.contains(.offsets));
    try testing.expect(trained.sequence_repeat_valid.contains(.match_lengths));
    try testing.expect(trained.sequence_repeat_valid.contains(.literals_lengths));
    // The offsets promotion is representability, not the full alphabet: the
    // trained dictionary's content (14,378 bytes) needs codes up to
    // `highbit(14378 + 128 KiB)` = 17, and its 18-symbol table covers them.
    try testing.expectEqual(@as(u16, 17), offcodeMax(trained.content.len));
    try testing.expect(trained.sequence_tables_compress[1].norm.counts[17] != 0);

    // The C's `zero-weight-dict`: 120 zero weights in the tree, so the
    // literals table is `check`, never reused blindly — the promotion that
    // matters most, since the 6-literal floor and the unmeasured reuse hang
    // on it. Its FSE tables still promote: an 11-byte content needs offset
    // codes only up to `highbit(11 + 128 KiB)` = 17, which its tables cover,
    // and the length alphabets are fully covered. The CLI's own `-1` frame
    // for this dictionary is `golden.dict_frame_zw`, which the encoder's
    // tests re-emit byte for byte — the honest degradation.
    const zero_weight = try parse(golden.dict_zero_weight);
    try testing.expect(!zero_weight.literals_repeat_valid);
    try testing.expect(zero_weight.sequence_repeat_valid.contains(.offsets));
    try testing.expect(zero_weight.sequence_repeat_valid.contains(.match_lengths));
    try testing.expect(zero_weight.sequence_repeat_valid.contains(.literals_lengths));
    // A raw dictionary has no tables to promote and keeps the defaults.
    const raw = initRaw("raw content, not a formatted dictionary");
    try testing.expect(!raw.literals_repeat_valid);
    try testing.expectEqual(@as(usize, 0), raw.sequence_repeat_valid.count());
    try testing.expectEqual([3]u32{ 1, 4, 8 }, raw.repeat_offsets);
}

test "initRaw is infallible, format-free, and seeds the defaults" {
    // §5 — "raw content dictionaries, free of any format restriction, except
    // that they must be at least 8 bytes. These dictionaries function as if
    // they were just the content part of a formatted dictionary." Ours does
    // not enforce the floor (the C's raw path accepts shorter content too).
    const raw = initRaw("raw content, not a formatted dictionary");
    try testing.expectEqual(@as(u32, 0), raw.id);
    try testing.expect(!raw.has_entropy);
    try testing.expectEqual([3]u32{ 1, 4, 8 }, raw.repeat_offsets);
    try testing.expectEqualStrings("raw content, not a formatted dictionary", raw.content);
    // Any bytes, including a formatted dictionary's own: `initRaw` is the
    // caller's word that the bytes are content.
    const as_raw = initRaw(golden.dict_trained);
    try testing.expectEqual(@as(u32, 0), as_raw.id);
    try testing.expectEqualSlices(u8, golden.dict_trained, as_raw.content);
    const empty = initRaw("");
    try testing.expectEqual(@as(usize, 0), empty.content.len);
}

test "the value's size is the documented tables, no heap" {
    // The README documents the value's size ("about 910 KiB"): the literals
    // tree and decode table, the three fused sequences tables, the repcodes,
    // the content slice, the encode side's entropy tables
    // (`ZSTD_loadCEntropy`), and the CDict match tables the encoder looks up
    // (`ZSTD_fillHashTableForCDict` for level 1, the long+small pair of
    // `ZSTD_fillDoubleHashTableForCDict` for level 3) — the tables the C
    // keeps in a `ZSTD_CDict` rather than a frame. This pins the figure the
    // README quotes, so a table type that grows fails here.
    try testing.expectEqual(@as(usize, 947_824), @sizeOf(Dictionary));
}

test "parse reads a dictionary the decoder's own parsers built" {
    // A hand-built formatted dictionary: magic, ID 7, a direct-weights
    // literals tree, three FSE descriptions from the RFC's Appendix A
    // fixtures (`golden`), the repcodes {1, 4, 8}, and content. This pins
    // the byte offsets the parse walks: each description's length is its
    // own, so the content starts exactly after the 12th repcode byte.
    const source = [_]u8{ 0x37, 0xa4, 0x30, 0xec, 7, 0, 0, 0 } ++
        golden.pair_tree ++
        golden.offset_description ++
        golden.literals_length_description ++
        golden.literals_length_description ++
        [_]u8{ 1, 0, 0, 0, 4, 0, 0, 0, 8, 0, 0, 0 } ++
        "content!";
    const dictionary = try parse(source);
    try testing.expectEqual(@as(u32, 7), dictionary.id);
    try testing.expectEqualStrings("content!", dictionary.content);
    try testing.expectEqual([3]u32{ 1, 4, 8 }, dictionary.repeat_offsets);
    // Five transmitted weights plus the implied last one.
    try testing.expectEqual(@as(u16, 6), dictionary.literals_tree.symbol_count);
}
