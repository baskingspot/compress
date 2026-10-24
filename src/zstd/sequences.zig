//! The sequences section of a compressed block (`§3.1.1.3.2`): the header
//! (Number_of_Sequences and Symbol_Compression_Modes), the per-alphabet decoding
//! tables, the interleaved backward bitstream, and Sequence Execution
//! (`§3.1.1.4`) with the repeat offsets (`§3.1.1.5`).
//!
//! `decode` takes the block's bytes after the literals section (the sequences
//! section runs to the block's end, `§3.1.1.3.2`), the decoded literals as the
//! copy source, the output region, and the frame's `State`, and returns the
//! bytes written and consumed. In the output region `target[0..history_len]` is
//! history a match may read, which the caller limits to the window (`§3.1.1.4`),
//! and the block's output follows it. An offset that reaches before `target[0]`
//! is `OffsetTooFar`. Declared sizes are bounds, not licenses (`§8`): nothing is
//! written past `target` or read past the literals or the section, and a huge
//! Number_of_Sequences stops at the end of `target`, since every match writes at
//! least 3 bytes. Nothing is allocated.
//!
//! Format: docs/specs/rfc8878-zstd.txt

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const bits = @import("bits.zig");
const fse = @import("fse.zig");
const golden = @import("golden.zig");
const literals = @import("literals.zig");

/// Everything the sequences layer reports.
pub const Error = error{
    /// The section's fixed-size fields — the Number_of_Sequences bytes, the
    /// Symbol_Compression_Modes byte, an RLE_Mode symbol byte — run past the
    /// block's remaining bytes (`§3.1.1.3.2.1`). The reference's
    /// `srcSize_wrong`; never `Truncated`, which is the input's end.
    MalformedSequencesHeader,
    /// `§3.1.1.3.2.1` — "The last field, Reserved, must be all zeroes."
    ReservedModeBits,
    /// `§3.1.1.3.2.1` — Repeat_Mode "used without any previous sequence
    /// table in the frame ... to repeat, this should be treated as
    /// corruption."
    RepeatModeFirst,
    /// A sequence's literals_length reaches past the literals section's
    /// Regenerated_Size — a declared size the section cannot supply.
    LiteralsTooLarge,
    /// A sequence or the trailing literals would write past the caller's
    /// `target` (`§3.1.1.2.4`'s Block_Maximum_Size is the caller's cap).
    BufferTooSmall,
    /// `§3.1.1.5` — the repeat-offset arithmetic reached offset 0: an
    /// offset_value of 3 with literals_length 0 means Repeated_Offset1 - 1
    /// byte, which is 0 when Repeated_Offset1 is 1. The C reference and std
    /// reject it too.
    ZeroOffset,
    /// `§3.1.1.4` — "all offsets leading to previously decoded data must be
    /// smaller than Window_Size": the offset reaches past the history the
    /// caller authorized.
    OffsetTooFar,
} || fse.Error;

/// `§3.1.1.3.2.1.1`, Table 16 — literals length codes 0-35, "They define
/// lengths from 0 to 131071 bytes."
pub const literals_length_code_max: u8 = 35;

/// `§3.1.1.3.2.1.1`, Table 17 — match length codes 0-52, "They define lengths
/// from 3 to 131074 bytes."
pub const match_length_code_max: u8 = 52;

/// `§3.1.1.3.2.1.1` — "A decoder is free to limit its maximum supported
/// value for N. Support for values of at least 22 is recommended. At the time
/// of this writing, the reference decoder supports a maximum N value of 31."
/// Ours is the reference's 31.
pub const offset_code_max: u5 = 31;

/// `§3.1.1.3.2.1.1` — an offset code's `Offset_Value = (1 << offsetCode) +
/// readNBits(offsetCode)`, "supporting back-reference distance up to
/// (2^(N+1)) - 4".
pub const offset_value_max: u32 = (@as(u32, 1) << offset_code_max) + 0x7fffffff;

/// The three symbol types of a sequences section (`§3.1.1.3.2`), in the
/// section's own order — the header's `[Literals_Length_Table]
/// [Offset_Table] [Match_Length_Table]`, and the bitstream's initial-state
/// order (`§3.1.1.3.2.1.2`).
pub const Alphabet = enum(u2) {
    literals_lengths = 0,
    offsets = 1,
    match_lengths = 2,
};

/// The alphabets' number.
pub const alphabet_count = @typeInfo(Alphabet).@"enum".fields.len;

/// `§3.1.1.3.2.1`, Table 15 — the four Compression_Modes of each symbol type.
pub const Mode = enum(u2) {
    predefined = 0,
    rle = 1,
    fse = 2,
    repeat = 3,
};

/// One `§3.1.1.3.2.1.1` code: "The [value] is equal to the decoded Baseline
/// plus the result of reading Number_of_Bits bits from the bitstream, as a
/// little-endian value."
pub const Code = struct {
    baseline: u32,
    /// The RFC's Number_of_Bits: the extra bits read *after* the code's own.
    extra_bits: u5,
};

/// `§3.1.1.3.2.1.1`, Table 16 — "Literals length codes are values ranging
/// from 0 to 35 ... Codes 0-15 are the literal length itself" with no extra
/// bits, then the baseline/extra-bits bands up to code 35's 65536 + 16 bits.
pub const literals_length_codes: [literals_length_code_max + 1]Code = blk: {
    @setEvalBranchQuota(10_000);
    var codes: [literals_length_code_max + 1]Code = undefined;
    for (codes[0..16], 0..) |*code, length| code.* = .{ .baseline = length, .extra_bits = 0 };
    const bands = [20]Code{
        .{ .baseline = 16, .extra_bits = 1 },
        .{ .baseline = 18, .extra_bits = 1 },
        .{ .baseline = 20, .extra_bits = 1 },
        .{ .baseline = 22, .extra_bits = 1 },
        .{ .baseline = 24, .extra_bits = 2 },
        .{ .baseline = 28, .extra_bits = 2 },
        .{ .baseline = 32, .extra_bits = 3 },
        .{ .baseline = 40, .extra_bits = 3 },
        .{ .baseline = 48, .extra_bits = 4 },
        .{ .baseline = 64, .extra_bits = 6 },
        .{ .baseline = 128, .extra_bits = 7 },
        .{ .baseline = 256, .extra_bits = 8 },
        .{ .baseline = 512, .extra_bits = 9 },
        .{ .baseline = 1024, .extra_bits = 10 },
        .{ .baseline = 2048, .extra_bits = 11 },
        .{ .baseline = 4096, .extra_bits = 12 },
        .{ .baseline = 8192, .extra_bits = 13 },
        .{ .baseline = 16384, .extra_bits = 14 },
        .{ .baseline = 32768, .extra_bits = 15 },
        .{ .baseline = 65536, .extra_bits = 16 },
    };
    for (bands, 16..) |band, index| codes[index] = band;
    break :blk codes;
};

/// `§3.1.1.3.2.1.1`, Table 17 — "Match length codes are values ranging from 0
/// to 52 ... Codes 0-31 are Match_Length_Code + 3" with no extra bits, then
/// the bands up to code 52's 65539 + 16 bits.
pub const match_length_codes: [match_length_code_max + 1]Code = blk: {
    @setEvalBranchQuota(10_000);
    var codes: [match_length_code_max + 1]Code = undefined;
    for (codes[0..32], 0..) |*code, symbol| code.* = .{ .baseline = symbol + 3, .extra_bits = 0 };
    const bands = [21]Code{
        .{ .baseline = 35, .extra_bits = 1 },
        .{ .baseline = 37, .extra_bits = 1 },
        .{ .baseline = 39, .extra_bits = 1 },
        .{ .baseline = 41, .extra_bits = 1 },
        .{ .baseline = 43, .extra_bits = 2 },
        .{ .baseline = 47, .extra_bits = 2 },
        .{ .baseline = 51, .extra_bits = 3 },
        .{ .baseline = 59, .extra_bits = 3 },
        .{ .baseline = 67, .extra_bits = 4 },
        .{ .baseline = 83, .extra_bits = 4 },
        .{ .baseline = 99, .extra_bits = 5 },
        .{ .baseline = 131, .extra_bits = 7 },
        .{ .baseline = 259, .extra_bits = 8 },
        .{ .baseline = 515, .extra_bits = 9 },
        .{ .baseline = 1027, .extra_bits = 10 },
        .{ .baseline = 2051, .extra_bits = 11 },
        .{ .baseline = 4099, .extra_bits = 12 },
        .{ .baseline = 8195, .extra_bits = 13 },
        .{ .baseline = 16387, .extra_bits = 14 },
        .{ .baseline = 32771, .extra_bits = 15 },
        .{ .baseline = 65539, .extra_bits = 16 },
    };
    for (bands, 32..) |band, index| codes[index] = band;
    break :blk codes;
};

/// The offset alphabet's code count: codes 0-31.
const offset_code_count = @as(usize, offset_code_max) + 1;

/// `§3.1.1.3.2.1.1` — "Offset_Value = (1 << offsetCode) + readNBits(offsetCode)",
/// so the offset code's Baseline is the `1 << code` term and its extra bits
/// are the code itself. Codes 0-31 are the reference's range; the predefined
/// offset table (`§3.1.1.3.2.2.3`) tops out at 28.
pub const offset_codes: [offset_code_count]Code = blk: {
    @setEvalBranchQuota(10_000);
    var codes: [offset_code_count]Code = undefined;
    for (&codes, 0..) |*code, symbol| {
        code.* = .{ .baseline = @as(u32, 1) << @intCast(symbol), .extra_bits = @intCast(symbol) };
    }
    break :blk codes;
};

/// `§3.1.1.3.2.2.1` — `literalsLength_defaultDistribution[36]`, "The decoding
/// table uses an accuracy log of 6 bits (64 states)", transcribed verbatim.
pub const literals_length_distribution = [36]i16{
    4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1,  1,  2,  2,
    2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1,
};

/// `§3.1.1.3.2.2.2` — `matchLengths_defaultDistribution[53]`, accuracy log 6.
pub const match_length_distribution = [53]i16{
    1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1,  1,  1,  1,  1,  1,  1,  1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  1,  1,  1,  1,  1,  1,  1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1,
};

/// `§3.1.1.3.2.2.3` — `offsetCodes_defaultDistribution[29]`, accuracy log 5,
/// "supports a maximum N value of 28".
pub const offset_distribution = [29]i16{
    1,  1,  1,  1,  1,  1, 2, 2, 2, 1, 1, 1,
    1,  1,  1,  1,  1,  1, 1, 1, 1, 1, 1, 1,
    -1, -1, -1, -1, -1,
};

/// One alphabet's context (`§3.1.1.3.2.1`, Table 15; `§3.1.1.3.2.2`).
const AlphabetSpec = struct {
    /// The alphabet's last code (`§4.1.1`'s `maxSymbolValue`): the FSE
    /// description may not name a symbol past it, nor may RLE_Mode.
    symbol_value_max: u16,
    /// "the maximum allowed accuracy log for literals length code and match
    /// length code tables is 9, and the maximum accuracy log for the offset
    /// code table is 8" (`§3.1.1.3.2.1`).
    accuracy_log_max: u5,
    /// The Predefined_Mode distribution's accuracy log (`§3.1.1.3.2.2`).
    accuracy_log_default: u5,
    distribution: []const i16,
    codes: []const Code,
};

const alphabet_specs = [alphabet_count]AlphabetSpec{
    .{
        .symbol_value_max = literals_length_code_max,
        .accuracy_log_max = 9,
        .accuracy_log_default = 6,
        .distribution = &literals_length_distribution,
        .codes = &literals_length_codes,
    },
    .{
        .symbol_value_max = offset_code_max,
        .accuracy_log_max = 8,
        .accuracy_log_default = 5,
        .distribution = &offset_distribution,
        .codes = &offset_codes,
    },
    .{
        .symbol_value_max = match_length_code_max,
        .accuracy_log_max = 9,
        .accuracy_log_default = 6,
        .distribution = &match_length_distribution,
        .codes = &match_length_codes,
    },
};

/// The alphabets' contexts.
fn specOf(alphabet: Alphabet) AlphabetSpec {
    return alphabet_specs[@intFromEnum(alphabet)];
}

/// `§3.1.1.3.2.2`'s three distributions through `§4.1.1`'s construction: the
/// Predefined_Mode tables, built once at comptime — a Predefined alphabet
/// costs no per-block work.
const predefined_tables: [alphabet_count]fse.Table = blk: {
    @setEvalBranchQuota(100_000);
    var tables: [alphabet_count]fse.Table = undefined;
    for (alphabet_specs, 0..) |spec, index| {
        tables[index] = fse.buildTable(spec.distribution, spec.accuracy_log_default);
    }
    break :blk tables;
};

/// One sequences-loop decoding cell (`§3.1.1.3.2.1.2`): the FSE transition
/// fused with the code's value data. A sequence's decode is then one load
/// per alphabet instead of two dependent ones (state -> entry -> symbol,
/// then symbol -> code), and the one cell serves both the value read and
/// the state update, which the unfused `codeOf`/`State.update` pair loads
/// twice (the reference's `ZSTD_seqSymbol` shape).
const SeqEntry = struct {
    /// The code's Baseline: the value is `baseline + extra bits read`.
    baseline: u32,
    /// The FSE Baseline: the next state is `transition + num_bits read`.
    transition: u16,
    /// The code's Number_of_Bits — the extra bits read for the value.
    extra_bits: u5,
    /// The FSE state's Num_Bits — consumed at the state update.
    num_bits: u5,
};

/// A sequences decoding table: the FSE table's `1 << log` cells, each fused
/// with the alphabet's code. This is the form the decode loop reads, and the
/// form a dictionary carries one of per alphabet (`Dictionary`): a
/// Repeat_Mode points `State.tables` at it, in the frame's own storage or in
/// the dictionary's.
pub const SeqTable = struct {
    /// The table's Accuracy_Log (`§4.1`): a state indexes the first
    /// `1 << log` cells.
    log: u5,
    entries: [fse.table_size_max]SeqEntry,

    /// The cell a state value indexes.
    fn entry(self: *const SeqTable, state: u16) SeqEntry {
        assert(state < @as(u16, 1) << @intCast(self.log));
        return self.entries[state];
    }
};

/// Fuse an FSE decoding table with an alphabet's code table. Every symbol
/// the table holds is in the alphabet (the description reader's
/// symbol_value_max bound, RLE's byte check, the comptime distributions).
fn fuseTable(table: *const fse.Table, codes: []const Code) SeqTable {
    var fused: SeqTable = .{ .log = table.log, .entries = undefined };
    for (table.entries[0 .. @as(usize, 1) << @intCast(table.log)], 0..) |cell, i| {
        const code = codes[cell.symbol];
        fused.entries[i] = .{
            .baseline = code.baseline,
            .transition = cell.baseline,
            .extra_bits = code.extra_bits,
            .num_bits = cell.num_bits,
        };
    }
    return fused;
}

/// The Predefined_Mode tables, fused at comptime — a Predefined alphabet
/// costs no per-block work.
const predefined_seq_tables: [alphabet_count]SeqTable = blk: {
    var tables: [alphabet_count]SeqTable = undefined;
    for (alphabet_specs, 0..) |spec, index| {
        tables[index] = fuseTable(&predefined_tables[index], spec.codes);
    }
    break :blk tables;
};

/// `§3.1.1.3.2.1` — "RLE_Mode: The table description consists of a single
/// byte, which contains the symbol's value. This symbol will be used for all
/// sequences." One cell read with zero bits, so the state never moves (the
/// reference's `ZSTD_buildSeqTable_rle`); the code's Baseline and extra bits
/// come from the alphabet's code table, as for every other mode.
fn rleTable(symbol: u8) fse.Table {
    var table: fse.Table = .{ .log = 0, .entries = undefined };
    table.entries[0] = .{ .symbol = symbol, .num_bits = 0, .baseline = 0 };
    return table;
}

/// A parsed Sequences_Section_Header (`§3.1.1.3.2.1`).
pub const Header = struct {
    /// Number_of_Sequences: 0, 1-127, `((byte0 - 128) << 8) + byte1`, or
    /// `byte1 + (byte2 << 8) + 0x7F00` (at most 98047).
    sequence_count: u32,
    /// The count field's own length: 1-3 bytes.
    count_len: usize,
    /// The Symbol_Compression_Modes byte's three fields (Table 14), `null`
    /// when the count is zero: "The sequence section stops here", so no mode
    /// byte follows.
    modes: ?Modes,
};

/// `§3.1.1.3.2.1`, Table 14 — one mode per symbol type.
pub const Modes = struct {
    literals_lengths: Mode,
    offsets: Mode,
    match_lengths: Mode,

    fn mode(self: Modes, alphabet: Alphabet) Mode {
        return switch (alphabet) {
            .literals_lengths => self.literals_lengths,
            .offsets => self.offsets,
            .match_lengths => self.match_lengths,
        };
    }
};

/// Parse a Sequences_Section_Header (`§3.1.1.3.2.1`) from the front of a
/// compressed block's sequences section.
pub fn parseHeader(source: []const u8) Error!Header {
    if (source.len < 1) return error.MalformedSequencesHeader;
    const byte0 = source[0];
    var header: Header = .{ .sequence_count = 0, .count_len = 1, .modes = null };
    if (byte0 < 128) {
        // "if (byte0 < 128): Number_of_Sequences = byte0. Uses 1 byte" —
        // byte0 == 0 included: no sequences at all.
        header.sequence_count = byte0;
    } else if (byte0 < 255) {
        if (source.len < 2) return error.MalformedSequencesHeader;
        header.sequence_count = (@as(u32, byte0 - 128) << 8) + source[1];
        header.count_len = 2;
    } else {
        if (source.len < 3) return error.MalformedSequencesHeader;
        header.sequence_count = @as(u32, source[1]) + (@as(u32, source[2]) << 8) + 0x7F00;
        header.count_len = 3;
    }
    // The reference ends the section on a *decoded* zero in any form (the
    // 2-byte `80 00` count reaches here), and std rejects that corner; this
    // follows the reference.
    if (header.sequence_count == 0) return header;
    if (source.len < header.count_len + 1) return error.MalformedSequencesHeader;
    const modes_byte = source[header.count_len];
    // "The last field, Reserved, must be all zeroes."
    if (modes_byte & 0b11 != 0) return error.ReservedModeBits;
    header.modes = .{
        .literals_lengths = @enumFromInt(modes_byte >> 6),
        .offsets = @enumFromInt((modes_byte >> 4) & 0b11),
        .match_lengths = @enumFromInt((modes_byte >> 2) & 0b11),
    };
    return header;
}

/// One of a dictionary's three FSE table descriptions (§5): the table the
/// parse built, the description's normalized counts (the encode side's table
/// and its `ZSTD_dictNCountRepeat` promotion are built from the same parse),
/// and the bytes its description consumed.
pub const DictionaryTable = struct {
    table: SeqTable,
    description: fse.Description,
    bytes_consumed: usize,
};

/// Read one of a dictionary's FSE table descriptions (§5): "They are stored
/// in the following order: Huffman table for literals, FSE table for offsets,
/// FSE table for match lengths, and FSE table for literals lengths." The
/// description is the compressed-block form (`fse.readDescription`,
/// `§4.1.1`) read with the alphabet's own symbol and accuracy caps, fused
/// with the alphabet's codes — the exact table a Repeat_Mode reuses.
///
/// `source` is the dictionary from this table's first byte to its end (the
/// next table, the 12 repcode bytes, or the content). A description that
/// runs past it is `MalformedFseTable` (the reader's own name), never an
/// overread.
pub fn readDictionaryTable(
    alphabet: Alphabet,
    source: []const u8,
) error{MalformedFseTable}!DictionaryTable {
    const spec = specOf(alphabet);
    // `readDescription`'s declared set is shared with the bitstream readers;
    // every failure a *description* can hit is the malformed-table class.
    const description = fse.readDescription(
        source,
        spec.symbol_value_max,
        spec.accuracy_log_max,
    ) catch return error.MalformedFseTable;
    const table = fse.buildTable(
        description.counts[0..description.symbol_count],
        description.accuracy_log,
    );
    return .{
        .table = fuseTable(&table, spec.codes),
        .description = description,
        .bytes_consumed = description.bytes_consumed,
    };
}

/// The sequences layer's cross-block state (`§3.1.1.3`): the three decoding
/// tables a Repeat_Mode reuses and the three repeat offsets (`§3.1.1.5`).
/// One per frame, threaded through the block loop; only a Compressed_Block
/// with a nonzero sequence count updates it ("blocks that are not
/// Compressed_Block are skipped; they do not contribute to offset history"),
/// and a zero-count section leaves it alone. A dictionary (§5) seeds the
/// state instead of `frame.State.init`'s empty seats: `tables` point at the
/// dictionary's parsed tables, and `repeat_offsets` are its 12 bytes.
pub const State = struct {
    /// Storage for the tables a block builds (the FSE_Compressed and RLE
    /// modes), about 12 KB in all. Undefined until a mode writes a cell, so a
    /// new frame state does not pay to zero it (a per-frame memset of the
    /// table payloads measured as a real cost).
    built: [alphabet_count]SeqTable = undefined,
    /// The table each alphabet last decoded with, `null` until the frame's
    /// first sequences section with a nonzero count. "The table used in the
    /// previous Compressed_Block with Number_Of_Sequences > 0 will be used
    /// again ... It also includes Predefined_Mode ... and RLE_Mode", so every
    /// mode stores its resolved table here — Predefined by pointer to the
    /// comptime table (no per-block copy), the built modes into `built`.
    tables: [alphabet_count]?*const SeqTable = @splat(null),
    /// Repeated_Offset1/2/3 "sorted in recency order, with Repeated_Offset1
    /// meaning 'most recent one'" (`§3.1.1.5`), seeded {1, 4, 8} "for the
    /// first block ... unless a dictionary is used". A dictionary's 12
    /// repcode bytes replace the seed; a raw dictionary has none, so it
    /// keeps the default.
    repeat_offsets: [3]u32 = repeat_offsets_start,
};

/// `§3.1.1.5` — "For the first block, the starting offset history is
/// populated with the following values: Repeated_Offset1 (1), Repeated_Offset2
/// (4), and Repeated_Offset3 (8)".
pub const repeat_offsets_start = [3]u32{ 1, 4, 8 };

/// One decoded sequences section.
pub const Section = struct {
    /// The block's output: `bytes_written` bytes at `target[history_len..]`.
    bytes_written: usize,
    /// The section bytes consumed. Always all of `source` on success — the
    /// bitstream is the block's tail and "shall be entirely consumed"
    /// (`§3.1.1.3.2.1.2`) — returned so the block layer checks its derived
    /// `Sequences_Section_Size` against it (`§3.1.1.3.2`).
    bytes_consumed: usize,
};

/// Decode one sequences section: `source` is the block's bytes after the
/// literals section (`Sequences_Section_Size`, `§3.1.1.3.2`), `literals_bytes`
/// the decoded literals Sequence Execution copies from, and `target` the
/// caller's contiguous output region — `target[0..history_len]` is the
/// history a match may read (the caller caps it at the frame's Window_Size,
/// `§3.1.1.4`), `target[history_len..]` where this block's output is written.
/// `state` carries the frame's tables and repeat offsets across blocks.
///
/// `dict` is §5's dictionary content, conceptually in front of `target[0]`,
/// and `dict_limit` is the region-relative match position up to which it is
/// addressable — §5's Window_Size boundary, derived by the caller ("as long
/// as the amount of data decoded from this frame is less than or equal to
/// Window_Size, sequence commands may specify offsets ... to reference back
/// to the dictionary ... after the total output has surpassed Window_Size,
/// ... the dictionary is no longer accessible"). A match reaching into it
/// past that boundary, or deeper than the content holds, is `OffsetTooFar`.
/// The empty slice (no dictionary) refuses every reach, exactly as the
/// history bound did before dictionaries existed.
///
/// Every declared size is a bound: the output never exceeds `target`, the
/// literals read never exceeds `literals_bytes`, and no offset reaches past
/// the authorized history — the failures are `BufferTooSmall`,
/// `LiteralsTooLarge`, and `OffsetTooFar`, raised before the offending write.
pub fn decode(
    source: []const u8,
    literals_bytes: []const u8,
    target: []u8,
    history_len: usize,
    dict: []const u8,
    dict_limit: u64,
    state: *State,
) Error!Section {
    assert(history_len <= target.len);
    const header = try parseHeader(source);
    const modes = header.modes orelse
        return decodeEmpty(header, source, literals_bytes, target, history_len);
    // §3.1.1.3.2 — the layout is the header, then "[Literals_Length_Table]
    // [Offset_Table] [Match_Length_Table]", then the bitstream, which is the
    // section's remaining bytes.
    var tables: [alphabet_count]*const SeqTable = undefined;
    const bitstream = source[try resolveTables(source, header, modes, state, &tables)..];
    const written = try executeSequences(
        bitstream,
        header.sequence_count,
        &tables,
        &state.repeat_offsets,
        literals_bytes,
        target,
        history_len,
        dict,
        dict_limit,
    );
    return .{ .bytes_written = written, .bytes_consumed = source.len };
}

/// `§3.1.1.3.2`'s table-description order: "[Literals_Length_Table]
/// [Offset_Table] [Match_Length_Table]". The bitstream's initial-state order
/// is the same (`§3.1.1.3.2.1.2`); the state *updates* are not.
const description_order = [alphabet_count]Alphabet{ .literals_lengths, .offsets, .match_lengths };

/// `§3.1.1.3.2.1.2` — "Literals_Length_State is updated, followed by
/// Match_Length_State, and then Offset_State" — the description order with
/// match lengths and offsets swapped.
const update_order = [alphabet_count]Alphabet{ .literals_lengths, .match_lengths, .offsets };

/// A zero Number_of_Sequences (`§3.1.1.3.2.1`): "there are no sequences. The
/// sequence section stops here. Decompressed content is defined entirely as
/// Literals_Section content. The FSE tables used in Repeat_Mode are not
/// updated." The count is the whole section, so the block is its literals —
/// and bytes past the count are corruption: the reference's "extraneous data
/// present in the Sequences section", which is `BitstreamNotConsumed` here
/// (the section's exact-consumption rule, applied to a section with no
/// bitstream).
fn decodeEmpty(
    header: Header,
    source: []const u8,
    literals_bytes: []const u8,
    target: []u8,
    history_len: usize,
) Error!Section {
    if (source.len != header.count_len) return error.BitstreamNotConsumed;
    const written = try appendTrailingLiterals(literals_bytes, target, history_len, 0);
    return .{ .bytes_written = written, .bytes_consumed = source.len };
}

/// Resolve the three alphabets' decoding tables for this block (`§3.1.1.3.2`'s
/// optional per-symbol-type descriptions, in the section's own order) into
/// the frame state, returning where the bitstream starts.
fn resolveTables(
    source: []const u8,
    header: Header,
    modes: Modes,
    state: *State,
    tables: *[alphabet_count]*const SeqTable,
) Error!usize {
    var cursor = header.count_len + 1;
    assert(cursor <= source.len);
    for (description_order) |alphabet| {
        const consumed = try resolveTable(alphabet, source[cursor..], modes.mode(alphabet), state);
        cursor += consumed;
        // A description never reads past the bytes it was handed, so the
        // next table's slice and the bitstream's start are in the section.
        assert(cursor <= source.len);
        tables[@intFromEnum(alphabet)] = state.tables[@intFromEnum(alphabet)].?;
    }
    return cursor;
}

/// Resolve one alphabet's decoding table for this block (`§3.1.1.3.2.1`'s
/// four Compression_Modes, Table 15) into the frame state, returning the
/// bytes its description consumed.
///
/// `source` is the section's *remaining* bytes, never an exact-size slice: a
/// table description's own length is what `§4.1.1`'s reader recovers, and the
/// reference reads it through a window and validates the byte count after.
fn resolveTable(
    alphabet: Alphabet,
    source: []const u8,
    mode: Mode,
    state: *State,
) Error!usize {
    const index = @intFromEnum(alphabet);
    const spec = specOf(alphabet);
    switch (mode) {
        .predefined => {
            // "A predefined FSE ... distribution table is used, as defined in
            // Section 3.1.1.3.2.2. No distribution table will be present."
            // The comptime table is immutable and shared: point, never copy.
            state.tables[index] = &predefined_seq_tables[index];
            return 0;
        },
        .rle => {
            // "The table description consists of a single byte, which
            // contains the symbol's value."
            if (source.len < 1) return error.MalformedSequencesHeader;
            const symbol = source[0];
            // The reference rejects a symbol outside the context's alphabet
            // (`ZSTD_buildSeqTable`'s `symbol > max` check); the table such a
            // byte describes is not one of this context's.
            if (symbol > spec.symbol_value_max) return error.MalformedFseTable;
            state.built[index] = fuseTable(&rleTable(symbol), spec.codes);
            state.tables[index] = &state.built[index];
            return 1;
        },
        .fse => {
            // "Standard FSE compression. A distribution table will be
            // present." The description is the one zstd bitstream read
            // forward (`§4.1.1`), and it covers at most the alphabet.
            const description = try fse.readDescription(
                source,
                spec.symbol_value_max,
                spec.accuracy_log_max,
            );
            const fse_table = fse.buildTable(
                description.counts[0..description.symbol_count],
                description.accuracy_log,
            );
            state.built[index] = fuseTable(&fse_table, spec.codes);
            state.tables[index] = &state.built[index];
            return description.bytes_consumed;
        },
        .repeat => {
            // "The table used in the previous Compressed_Block with
            // Number_Of_Sequences > 0 will be used again ... If this mode is
            // used without any previous sequence table in the frame ... to
            // repeat, this should be treated as corruption."
            if (state.tables[index] == null) return error.RepeatModeFirst;
            return 0;
        },
    }
}

/// Decode and execute every sequence of the section (`§3.1.1.3.2.1.2`'s
/// loop, `§3.1.1.4`'s copies), then append the trailing literals; returns
/// the block's output length. `bitstream` is the section's bytes after the
/// table descriptions.
fn executeSequences(
    bitstream: []const u8,
    sequence_count: u32,
    tables: *const [alphabet_count]*const SeqTable,
    repeat_offsets: *[3]u32,
    literals_bytes: []const u8,
    target: []u8,
    history_len: usize,
    dict: []const u8,
    dict_limit: u64,
) Error!usize {
    // §3.1.1.3.2.1.2 — "The bitstream starts with initial FSE state values
    // ... It starts with Literals_Length_State, followed by Offset_State, and
    // finally Match_Length_State", each reading its table's Accuracy_Log bits
    // from the section's tail.
    var reader: bits.BackwardReader = try .init(bitstream);
    var states: [alphabet_count]u16 = undefined;
    for (description_order) |alphabet| {
        // "To obtain the initial state value, consume Accuracy_Log bits from
        // the stream as a little-endian value" (`§4.1`).
        states[@intFromEnum(alphabet)] =
            reader.readBits(tables[@intFromEnum(alphabet)].log);
    }

    var produced: usize = 0;
    var literals_consumed: usize = 0;
    var sequence_index: u32 = 0;
    while (sequence_index < sequence_count) : (sequence_index += 1) {
        // §3.1.1.3.2.1.2 — the sequence's symbol cells: "Decoding starts by
        // reading the Number_of_Bits required to decode offset. It does the
        // same for Match_Length and then for Literals_Length." The fused
        // cell is one load per alphabet and serves the state update too.
        const offset_cell = tables[@intFromEnum(Alphabet.offsets)]
            .entry(states[@intFromEnum(Alphabet.offsets)]);
        const match_cell = tables[@intFromEnum(Alphabet.match_lengths)]
            .entry(states[@intFromEnum(Alphabet.match_lengths)]);
        const literal_cell = tables[@intFromEnum(Alphabet.literals_lengths)]
            .entry(states[@intFromEnum(Alphabet.literals_lengths)]);
        const offset_value = offset_cell.baseline + readExtra(&reader, offset_cell.extra_bits);
        const match_length = match_cell.baseline + readExtra(&reader, match_cell.extra_bits);
        const literals_length = literal_cell.baseline + readExtra(&reader, literal_cell.extra_bits);
        // A read past the stream's start: the section promised more bits than
        // it holds, which is the exact-consumption rule read the other way.
        if (reader.overran()) return error.InvalidBitStream;
        const offset = try resolveOffset(literals_length, offset_value, repeat_offsets);
        const written = history_len + produced;
        assert(written <= target.len);
        produced += try executeSequence(
            literals_length,
            match_length,
            offset,
            literals_bytes,
            literals_consumed,
            target,
            written,
            dict,
            dict_limit,
        );
        literals_consumed += literals_length;
        // §3.1.1.3.2.1.2 — "If it is not the last sequence in the block, the
        // next operation is to update states ... Literals_Length_State is
        // updated, followed by Match_Length_State, and then Offset_State."
        // §4.1: "the decoder should consume Num_Bits bits from the stream as
        // a little-endian value and add it to Baseline."
        if (sequence_index + 1 < sequence_count) {
            states[@intFromEnum(Alphabet.literals_lengths)] =
                literal_cell.transition + reader.readBits(literal_cell.num_bits);
            states[@intFromEnum(Alphabet.match_lengths)] =
                match_cell.transition + reader.readBits(match_cell.num_bits);
            states[@intFromEnum(Alphabet.offsets)] =
                offset_cell.transition + reader.readBits(offset_cell.num_bits);
        }
    }
    // "At the end, the bitstream shall be entirely consumed; otherwise, the
    // bitstream is considered corrupted."
    if (!reader.isConsumed()) return error.BitstreamNotConsumed;
    // §3.1.1.3.2 — "When all sequences are decoded, if there are literals
    // left in the Literals_Section, these bytes are added at the end of the
    // block."
    const written = history_len + produced;
    assert(written <= target.len);
    produced += try appendTrailingLiterals(literals_bytes, target, written, literals_consumed);
    return produced;
}

/// Read one code's extra bits (`§3.1.1.3.2.1.1`'s Number_of_Bits). The
/// backward reader's 64-bit window covers the widest field — the offset
/// alphabet's 31 — in one read, most significant bit first.
fn readExtra(reader: *bits.BackwardReader, count: u5) u32 {
    assert(count <= offset_code_max);
    return reader.readBits32(count);
}

/// `§3.1.1.4` + `§3.1.1.5` — the offset a sequence's offset_value selects,
/// updating the repeat offsets.
///
/// An offset_value above 3 is a literal offset ("if Offset_Value > 3, then
/// the offset is Offset_Value - 3"), whatever its value: "When the sequence's
/// offset_value does not refer to one of the Repeated_Offsets ... the
/// Repeated_Offsets' values are shifted back one, and Repeated_Offset1 takes
/// on the value of the offset that was just used" — the equal-offsets rule.
/// Below 4 the repeat offsets are selected, with the literals_length == 0
/// shift.
fn resolveOffset(literals_length: u32, offset_value: u32, repeat_offsets: *[3]u32) Error!u32 {
    assert(offset_value >= 1);
    if (offset_value > 3) {
        const offset = offset_value - 3;
        shiftRepeatOffsets(repeat_offsets, offset);
        return offset;
    }
    // §3.1.1.5 — "when the current sequence's literals_length is 0, repeated
    // offsets are shifted by 1, so an offset_value of 1 means
    // Repeated_Offset2, an offset_value of 2 means Repeated_Offset3, and an
    // offset_value of 3 means Repeated_Offset1 - 1_byte."
    const selected = if (literals_length == 0) offset_value else offset_value - 1;
    if (selected == 3) {
        // The "Repeated_Offset1 - 1_byte" corner: a nonzero offset is not
        // guaranteed. Repeated_Offset1 == 1 gives 0, which the C reference and
        // std reject (klauspost does not).
        assert(repeat_offsets[0] >= 1);
        const offset = repeat_offsets[0] - 1;
        if (offset == 0) return error.ZeroOffset;
        shiftRepeatOffsets(repeat_offsets, offset);
        return offset;
    }
    return useRepeatOffset(repeat_offsets, selected);
}

/// `§3.1.1.5` — "the Repeated_Offsets' values are shifted back one, and
/// Repeated_Offset1 takes on the value of the offset that was just used."
fn shiftRepeatOffsets(repeat_offsets: *[3]u32, offset: u32) void {
    repeat_offsets[2] = repeat_offsets[1];
    repeat_offsets[1] = repeat_offsets[0];
    repeat_offsets[0] = offset;
}

/// `§3.1.1.5` — selecting a repeat offset reorders the three "so that
/// Repeated_Offset1 takes on the value of the used Repeated_Offset, and the
/// existing values are pushed back from the first Repeated_Offset through to
/// the Repeated_Offset selected": a swap for Repeated_Offset2, a rotation for
/// Repeated_Offset3, and no change for Repeated_Offset1.
fn useRepeatOffset(repeat_offsets: *[3]u32, selected: u32) u32 {
    assert(selected < 3);
    switch (selected) {
        0 => {},
        1 => {
            const used = repeat_offsets[1];
            repeat_offsets[1] = repeat_offsets[0];
            repeat_offsets[0] = used;
        },
        2 => {
            const used = repeat_offsets[2];
            repeat_offsets[2] = repeat_offsets[1];
            repeat_offsets[1] = repeat_offsets[0];
            repeat_offsets[0] = used;
        },
        else => unreachable,
    }
    return repeat_offsets[0];
}

/// Execute one sequence's copies (`§3.1.1.4`) and return the bytes written:
/// `literals_length` from the literals, then `match_length` from the history
/// at `offset` — the caller's output region, or the dictionary when the
/// offset reaches in front of it (`§5`). `written` is the output position the
/// sequence starts at, from the caller's region's start.
fn executeSequence(
    literals_length: u32,
    match_length: u32,
    offset: u32,
    literals_bytes: []const u8,
    literals_consumed: usize,
    target: []u8,
    written: usize,
    dict: []const u8,
    dict_limit: u64,
) Error!usize {
    assert(literals_consumed <= literals_bytes.len);
    assert(written <= target.len);
    // The amplification limits: neither copy may run past the literals
    // section's Regenerated_Size or the caller's target, and the checks come
    // before the writes.
    if (literals_length > literals_bytes.len - literals_consumed) return error.LiteralsTooLarge;
    const sequence_length = literals_length + match_length;
    if (sequence_length > target.len - written) return error.BufferTooSmall;
    fastmem.copy(
        u8,
        target[written..][0..literals_length],
        literals_bytes[literals_consumed..][0..literals_length],
    );
    // "The offset is defined as from the current position (after copying the
    // literals)", and "all offsets leading to previously decoded data must
    // be smaller than Window_Size" — the caller's history is that bound. An
    // offset past the history reads the dictionary instead (§5), when it is
    // addressable at the match.
    const match_start = written + literals_length;
    if (offset <= match_start) {
        copyMatch(target, match_start, offset, match_length);
    } else {
        try copyMatchDict(
            target,
            match_start,
            offset - match_start,
            match_length,
            dict,
            dict_limit,
        );
    }
    return sequence_length;
}

/// `§5` — a match whose source reaches into the dictionary content: the
/// dictionary's last `reach` bytes, then the output's own start when the
/// match straddles the boundary (the C's "span extDict &
/// currentPrefixSegment"). `dict_limit` is the caller's region-relative
/// match position bound: the reach is refused (`OffsetTooFar`) once the
/// frame's decoded total has passed Window_Size, and when it is deeper than
/// the content holds. The caller has checked that
/// `target[match_start..][0..match_length]` fits.
fn copyMatchDict(
    target: []u8,
    match_start: usize,
    reach: usize,
    match_length: u32,
    dict: []const u8,
    dict_limit: u64,
) Error!void {
    assert(reach > 0);
    assert(match_start + match_length <= target.len);
    if (@as(u64, match_start) > dict_limit) return error.OffsetTooFar;
    if (reach > dict.len) return error.OffsetTooFar;
    const from_dict = @min(@as(usize, match_length), reach);
    const dict_start = dict.len - reach;
    fastmem.copy(
        u8,
        target[match_start..][0..from_dict],
        dict[dict_start..][0..from_dict],
    );
    if (from_dict == match_length) return;
    // The match continues at the output's start; that copy may observe its
    // own writes (its distance equals its position), which `copyMatch`
    // handles.
    const rest = match_length - @as(u32, @intCast(from_dict));
    copyMatch(target, match_start + from_dict, match_start + from_dict, rest);
}

/// `§3.1.1.4` — "match_length bytes are copied from previous decoded data.
/// The offset to copy from is determined by offset_value". An offset below
/// the match length replicates the offset-byte pattern, so the copy observes
/// its own writes; the caller has checked every bound. `offset` is a `usize`
/// because a dictionary-straddling match's continuation offset is a region
/// position, which a 32-bit offset value does not bound.
fn copyMatch(target: []u8, match_start: usize, offset: usize, match_length: u32) void {
    assert(offset > 0);
    assert(offset <= match_start);
    // A sequence's match is at least 3 bytes (`§3.1.1.3.2.1.1`); the
    // dictionary-straddling continuation is the match's tail after its
    // dictionary part and can be shorter.
    assert(match_length >= 1);
    assert(match_start + match_length <= target.len);
    const distance: usize = offset;
    const length: usize = match_length;
    const source = match_start - distance;
    // The common case: the match lies entirely before the output position,
    // one vectorized copy.
    if (distance >= length) {
        fastmem.copy(u8, target[match_start..][0..length], target[source..][0..length]);
        return;
    }
    // A 1-byte period is a fill.
    if (distance == 1) {
        fastmem.set(u8, target[match_start..][0..length], target[source]);
        return;
    }
    // A period that divides the chunk broadcasts into a register and fills.
    if (distance <= 16 and (distance & (distance - 1)) == 0 and
        length >= 2 * overlap_chunk)
    {
        copyOverlapFill(target.ptr + match_start, distance, length);
        return;
    }
    // Overlapping (distance < length): the match replicates the `distance`
    // bytes at the source, so the copy must see its own writes — a memmove
    // would copy the bytes that were there before. Doubling: copy the
    // pattern's first `distance` bytes (the source is final), then copy the
    // final prefix onto the space just past it, each step at most doubling
    // what is in place. Every copy's destination starts at or after its
    // source's end, so `fastmem.copy`'s non-overlap rule holds.
    const first = @min(distance, length);
    fastmem.copy(u8, target[match_start..][0..first], target[source..][0..first]);
    var copied: usize = first;
    while (copied < length) {
        const chunk = @min(copied, length - copied);
        fastmem.copy(
            u8,
            target[match_start + copied ..][0..chunk],
            target[match_start..][0..chunk],
        );
        copied += chunk;
    }
}

/// The fill kernel's width: one comptime-width vector store per loop trip.
/// 32 bytes is the floor (two NEON pairs, one AVX register); a CPU with
/// wider vectors fills wider.
const overlap_chunk = @max(32, std.simd.suggestVectorLength(u8) orelse 16);

/// The register-fill kernel for an overlap whose period divides the chunk
/// (offset 2, 4, 8, or 16; offset 1 is `fastmem.set`): the pattern
/// broadcasts into one vector register once, and the loop is stores only,
/// so no load ever waits on a store the loop just made. The register holds
/// the period's phase at a chunk boundary, which only the chunk-aligned
/// stores may use; the tail is a memory copy one chunk back (the chunk
/// width is a multiple of the period, so the phase lines up), reading bytes
/// the loop already wrote. `dst - period` is the match's own source, which
/// the caller's `offset <= match_start` bound keeps in bounds.
fn copyOverlapFill(dst: [*]u8, distance: usize, length: usize) void {
    assert(distance >= 2);
    assert(distance <= 16);
    assert((distance & (distance - 1)) == 0);
    assert(length >= 2 * overlap_chunk);
    switch (distance) {
        inline 2, 4, 8, 16 => |period| {
            // The period as one integer, broadcast to the chunk width; the
            // array->int->vector->array bitcasts are inverse mappings, so
            // the byte order cancels on any host.
            const Word = std.meta.Int(.unsigned, 8 * period);
            const Vec = @Vector(overlap_chunk / period, Word);
            const word: Word = @bitCast((dst - period)[0..period].*);
            const wide: Vec = @splat(word);
            const fill: [overlap_chunk]u8 = @bitCast(wide);
            var copied: usize = 0;
            while (copied + overlap_chunk <= length) : (copied += overlap_chunk) {
                dst[copied..][0..overlap_chunk].* = fill;
            }
            if (copied < length) {
                const tail = dst[length - overlap_chunk ..][0..overlap_chunk];
                const tail_src = (dst - overlap_chunk)[length - overlap_chunk ..][0..overlap_chunk];
                fastmem.copy(u8, tail, tail_src);
            }
        },
        else => unreachable,
    }
}

/// `§3.1.1.3.2` — "When all sequences are decoded, if there are literals left
/// in the Literals_Section, these bytes are added at the end of the block."
/// Returns the bytes appended; a target that cannot hold them fails
/// `BufferTooSmall` before any write.
fn appendTrailingLiterals(
    literals_bytes: []const u8,
    target: []u8,
    written: usize,
    literals_consumed: usize,
) Error!usize {
    assert(literals_consumed <= literals_bytes.len);
    assert(written <= target.len);
    const trailing = literals_bytes[literals_consumed..];
    if (trailing.len > target.len - written) return error.BufferTooSmall;
    fastmem.copy(u8, target[written..][0..trailing.len], trailing);
    return trailing.len;
}

/// One fixture block: the two sections of a compressed block (`§3.1.1.3`).
/// The fixtures live in `golden.zig`: each block's literals and sequences
/// sections, the expected output, and the whole frames built from them. Each
/// frame was verified with the pinned zstd CLI v1.5.7. It is a magic, a
/// descriptor 0x00 (no Frame_Content_Size, no checksum), a 512 KB window
/// descriptor, then one or more compressed blocks of raw literals and the
/// sequences section under test.
const FixtureBlock = struct {
    literals_section: []const u8,
    sequences_section: []const u8,
};

/// Decode a fixture's blocks in order, running the literals layer and then this
/// one with both states and the history threaded through, and check each
/// block's output. The target is sentinel-filled and every byte past the last
/// block's output must be untouched.
fn expectBlocks(blocks: []const FixtureBlock, expected: []const []const u8) !void {
    var target: [4096]u8 = undefined;
    internal.sentinel.fill(&target);
    var literals_scratch: [1024]u8 = undefined;
    var literals_state: literals.State = .{};
    var sequences_state: State = .{};
    var produced: usize = 0;
    for (blocks, expected) |block, want| {
        const literals_section = try literals.decode(
            block.literals_section,
            &literals_scratch,
            &literals_state,
        );
        const section = try decode(
            block.sequences_section,
            literals_section.bytes,
            &target,
            produced,
            &.{},
            0,
            &sequences_state,
        );
        // The section runs to the block's end: the bitstream is the tail and
        // "shall be entirely consumed" (`§3.1.1.3.2.1.2`).
        try testing.expectEqual(block.sequences_section.len, section.bytes_consumed);
        try testing.expectEqualSlices(u8, want, target[produced..][0..section.bytes_written]);
        produced += section.bytes_written;
    }
    try internal.sentinel.expect(&target, produced);
}

/// Decode one section and expect `err`, proving nothing was written into the
/// block's output region (`target[history_len..]`): the failure came before
/// the offending write.
fn expectError(
    err: Error,
    section: []const u8,
    literals_bytes: []const u8,
    history_len: usize,
) !void {
    var target: [512]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    try testing.expectError(
        err,
        decode(section, literals_bytes, &target, history_len, &.{}, 0, &state),
    );
    try internal.sentinel.expect(&target, history_len);
}

test "parseHeader reads the three Number_of_Sequences forms" {
    // RFC 8878 §3.1.1.3.2.1 — "if (byte0 < 128): Number_of_Sequences =
    // byte0. Uses 1 byte"; "if (byte0 < 255): Number_of_Sequences =
    // ((byte0 - 128) << 8) + byte1. Uses 2 bytes"; "if (byte0 == 255):
    // Number_of_Sequences = byte1 + (byte2 << 8) + 0x7F00. Uses 3 bytes."
    const one = try parseHeader(&.{ 0x7f, 0x00 });
    try testing.expectEqual(@as(u32, 127), one.sequence_count);
    try testing.expectEqual(@as(usize, 1), one.count_len);
    const two = try parseHeader(&.{ 0x80, 0x80, 0x00 });
    try testing.expectEqual(@as(u32, 128), two.sequence_count);
    try testing.expectEqual(@as(usize, 2), two.count_len);
    const last_two = try parseHeader(&.{ 0xfe, 0xff, 0x00 });
    try testing.expectEqual(@as(u32, 32511), last_two.sequence_count);
    const three = try parseHeader(&.{ 0xff, 0x00, 0x00, 0x00 });
    try testing.expectEqual(@as(u32, 0x7f00), three.sequence_count);
    try testing.expectEqual(@as(usize, 3), three.count_len);
    const most = try parseHeader(&.{ 0xff, 0xff, 0xff, 0x00 });
    try testing.expectEqual(@as(u32, 0x7f00 + 0xffff), most.sequence_count);
}

test "parseHeader ends the section on a zero count, decoded or literal" {
    // RFC 8878 §3.1.1.3.2.1 — "if (byte0 == 0): there are no sequences. The
    // sequence section stops here." The reference ends it on the *decoded*
    // count too, so the 2-byte `80 00` is the same case; std rejects that
    // corner, ours follows the reference. No mode byte follows either form.
    const literal = try parseHeader(&.{0x00});
    try testing.expectEqual(@as(u32, 0), literal.sequence_count);
    try testing.expectEqual(@as(usize, 1), literal.count_len);
    try testing.expect(literal.modes == null);
    const decoded = try parseHeader(&.{ 0x80, 0x00 });
    try testing.expectEqual(@as(u32, 0), decoded.sequence_count);
    try testing.expectEqual(@as(usize, 2), decoded.count_len);
    try testing.expect(decoded.modes == null);
}

test "parseHeader maps the Symbol_Compression_Modes fields" {
    // RFC 8878 §3.1.1.3.2.1, Table 14 — "bits 7-6 Literal_Lengths_Mode,
    // 5-4 Offsets_Mode, 3-2 Match_Lengths_Mode, 1-0 Reserved"; Table 15's
    // enumeration is Predefined, RLE, FSE_Compressed, Repeat.
    const header = try parseHeader(&.{ 0x01, 0b10_01_11_00 });
    const modes = header.modes.?;
    try testing.expectEqual(Mode.fse, modes.literals_lengths);
    try testing.expectEqual(Mode.rle, modes.offsets);
    try testing.expectEqual(Mode.repeat, modes.match_lengths);
    const predefined = try parseHeader(&.{ 0x01, 0x00 });
    try testing.expectEqual(Mode.predefined, predefined.modes.?.literals_lengths);
    // "The last field, Reserved, must be all zeroes."
    try testing.expectError(error.ReservedModeBits, parseHeader(&.{ 0x01, 0x01 }));
    try testing.expectError(error.ReservedModeBits, parseHeader(&.{ 0x01, 0b11_11_11_11 }));
}

test "parseHeader fails on a short section" {
    // RFC 8878 §3.1.1.3.2.1 — the header's fields are fixed-size, so a
    // section that ends inside one is corruption, never a short read of the
    // input (the reference's `srcSize_wrong`).
    try testing.expectError(error.MalformedSequencesHeader, parseHeader(&.{}));
    try testing.expectError(error.MalformedSequencesHeader, parseHeader(&.{0x80}));
    try testing.expectError(error.MalformedSequencesHeader, parseHeader(&.{ 0xff, 0x00 }));
    // A nonzero count with no mode byte.
    try testing.expectError(error.MalformedSequencesHeader, parseHeader(&.{0x01}));
    try testing.expectError(error.MalformedSequencesHeader, parseHeader(&.{ 0x80, 0x80 }));
}

test "the code tables are Tables 16 and 17" {
    // RFC 8878 §3.1.1.3.2.1.1 — "Literals length codes are values ranging
    // from 0 to 35 ... They define lengths from 0 to 131071 bytes"; match
    // length codes 0-52 define 3 to 131074. Codes 0-15 (literals) and 0-31
    // (matches) carry the length itself, the bands above them the
    // baseline/extra-bits pairs.
    try testing.expectEqual(@as(u32, 0), literals_length_codes[0].baseline);
    try testing.expectEqual(@as(u32, 15), literals_length_codes[15].baseline);
    try testing.expectEqual(@as(u5, 0), literals_length_codes[15].extra_bits);
    try testing.expectEqual(@as(u32, 16), literals_length_codes[16].baseline);
    try testing.expectEqual(@as(u5, 1), literals_length_codes[16].extra_bits);
    try testing.expectEqual(@as(u32, 64), literals_length_codes[25].baseline);
    try testing.expectEqual(@as(u5, 6), literals_length_codes[25].extra_bits);
    // Code 35 tops out at 65536 + (1 << 16) - 1 = 131071.
    try testing.expectEqual(@as(u32, 65536), literals_length_codes[35].baseline);
    try testing.expectEqual(@as(u5, 16), literals_length_codes[35].extra_bits);
    const ll_top = literals_length_codes[35];
    try testing.expectEqual(
        @as(u32, 131071),
        ll_top.baseline + (@as(u32, 1) << ll_top.extra_bits) - 1,
    );
    try testing.expectEqual(@as(u32, 3), match_length_codes[0].baseline);
    try testing.expectEqual(@as(u32, 34), match_length_codes[31].baseline);
    try testing.expectEqual(@as(u5, 0), match_length_codes[31].extra_bits);
    try testing.expectEqual(@as(u32, 35), match_length_codes[32].baseline);
    try testing.expectEqual(@as(u5, 1), match_length_codes[32].extra_bits);
    try testing.expectEqual(@as(u32, 131), match_length_codes[43].baseline);
    try testing.expectEqual(@as(u5, 7), match_length_codes[43].extra_bits);
    try testing.expectEqual(@as(u32, 65539), match_length_codes[52].baseline);
    try testing.expectEqual(
        @as(u32, 131074),
        match_length_codes[52].baseline + (@as(u32, 1) << match_length_codes[52].extra_bits) - 1,
    );
    // "Offset_Value = (1 << offsetCode) + readNBits(offsetCode)": the
    // baseline is the shift, the extra bits are the code.
    try testing.expectEqual(@as(u32, 1), offset_codes[0].baseline);
    try testing.expectEqual(@as(u5, 0), offset_codes[0].extra_bits);
    try testing.expectEqual(@as(u32, 8), offset_codes[3].baseline);
    try testing.expectEqual(@as(u5, 3), offset_codes[3].extra_bits);
    try testing.expectEqual(@as(u32, 1 << 31), offset_codes[31].baseline);
    try testing.expectEqual(@as(u5, 31), offset_codes[31].extra_bits);
    try testing.expectEqual(
        offset_value_max,
        offset_codes[31].baseline + ((@as(u32, 1) << 31) - 1),
    );
}

test "the predefined tables use §3.1.1.3.2.2's accuracy logs" {
    // RFC 8878 §3.1.1.3.2.2 — the literals length and match length default
    // distributions "use an accuracy log of 6 bits (64 states)", the offset
    // codes' 5 bits (32 states). Appendix A's rows pin the tables themselves
    // (fse.zig's cross-check builds them from these distributions).
    const ll_table = predefined_tables[@intFromEnum(Alphabet.literals_lengths)];
    const ml_table = predefined_tables[@intFromEnum(Alphabet.match_lengths)];
    const offset_table = predefined_tables[@intFromEnum(Alphabet.offsets)];
    try testing.expectEqual(@as(u5, 6), ll_table.log);
    try testing.expectEqual(@as(u5, 5), offset_table.log);
    try testing.expectEqual(@as(u5, 6), ml_table.log);
    // The offset table's last cell is one of the distribution's "less than
    // 1" symbols (Appendix A.3's state 31 is symbol 24) — the retreat from
    // the end of the table.
    try testing.expectEqual(@as(u8, 24), offset_table.entry(31).symbol);
}

test "resolveTable stores every mode's table for Repeat_Mode" {
    // RFC 8878 §3.1.1.3.2.1 — Repeat reuses "the table used in the previous
    // Compressed_Block with Number_Of_Sequences > 0 ... Note that this
    // includes RLE_Mode ... It also includes Predefined_Mode, in which case
    // Repeat_Mode will have the same outcome as Predefined_Mode", so every
    // mode's resolved table lands in the frame state — and Repeat with
    // nothing to repeat is corruption. RLE_Mode's symbol byte is bounded by
    // the context's alphabet (the reference's `symbol > max` check).
    var state: State = .{};
    try testing.expectError(error.RepeatModeFirst, resolveTable(.offsets, &.{}, .repeat, &state));
    try testing.expectEqual(@as(usize, 0), try resolveTable(.offsets, &.{}, .predefined, &state));
    try testing.expectEqual(@as(usize, 0), try resolveTable(.offsets, &.{}, .repeat, &state));
    try testing.expectEqual(
        predefined_tables[@intFromEnum(Alphabet.offsets)].log,
        state.tables[@intFromEnum(Alphabet.offsets)].?.log,
    );
    try testing.expectEqual(@as(usize, 1), try resolveTable(.offsets, &.{7}, .rle, &state));
    const rle = state.tables[@intFromEnum(Alphabet.offsets)].?;
    try testing.expectEqual(offset_codes[7].baseline, rle.entry(0).baseline);
    try testing.expectEqual(offset_codes[7].extra_bits, rle.entry(0).extra_bits);
    try testing.expectEqual(@as(u5, 0), rle.entry(0).num_bits);
    // One past each alphabet's last code (31, 35, 52).
    try testing.expectError(
        error.MalformedFseTable,
        resolveTable(.offsets, &.{32}, .rle, &state),
    );
    try testing.expectError(
        error.MalformedFseTable,
        resolveTable(.literals_lengths, &.{36}, .rle, &state),
    );
    try testing.expectError(
        error.MalformedFseTable,
        resolveTable(.match_lengths, &.{53}, .rle, &state),
    );
    // And a symbol byte the section does not hold.
    try testing.expectError(
        error.MalformedSequencesHeader,
        resolveTable(.offsets, &.{}, .rle, &state),
    );
}

test "readExtra reads fields wider than the reader's 11-bit chunk" {
    // RFC 8878 §3.1.1.3.2.1.1 — an offset code's Number_of_Bits is the code
    // itself, so a table's symbol 31 asks for 31 bits; the backward reader
    // takes 11 at a time, and the first chunk read is the value's high bits.
    // The stream is 0x12 0x34 0x56 0x78 0x01: its last byte's highest set
    // bit is bit 0, so the 32 bits below it are useful, read from bit 31
    // down.
    var reader = try bits.BackwardReader.init(&.{ 0x12, 0x34, 0x56, 0x78, 0x01 });
    try testing.expectEqual(@as(u32, 0x3c2b1a09), readExtra(&reader, 31));
    try testing.expectEqual(@as(i32, 1), reader.remainingBits());
    var split = try bits.BackwardReader.init(&.{ 0x12, 0x34, 0x56, 0x78, 0x01 });
    try testing.expectEqual(@as(u32, 0x7856), readExtra(&split, 16));
    try testing.expectEqual(@as(u32, 0x3412), readExtra(&split, 16));
    try testing.expect(split.isConsumed());
    // A read of exactly the chunk width stays on the direct path.
    var direct = try bits.BackwardReader.init(&.{ 0x34, 0x78, 0x01 });
    try testing.expectEqual(@as(u32, 0x7834 >> 5), readExtra(&direct, 11));
}

test "resolveOffset follows §3.1.1.5's rules, never Table 18's cells" {
    // RFC 8878 §3.1.1.5 — the rules are the source: Table 18's worked
    // example carries errata 6442 (its second-to-last row's offset_value is
    // 3, not 1) and its last row's Repeated_Offset3 cell contradicts the
    // rotation rule. Every expectation below is derived from the rule text
    // and the reference decoder's `ZSTD_decodeSequence`, not from the table's
    // cells.
    //
    // The starting values are "Repeated_Offset1 (1), Repeated_Offset2 (4),
    // and Repeated_Offset3 (8)".
    var offsets: [3]u32 = repeat_offsets_start;
    // "When the sequence's offset_value does not refer to one of the
    // Repeated_Offsets ... the Repeated_Offsets' values are shifted back
    // one, and Repeated_Offset1 takes on the value of the offset that was
    // just used."
    try testing.expectEqual(@as(u32, 1111), try resolveOffset(11, 1114, &offsets));
    try testing.expectEqualSlices(u32, &.{ 1111, 1, 4 }, &offsets);
    // "when the sequence's offset_value refers to one of the Repeated_Offsets
    // ... the Repeated_Offsets are reordered, so that Repeated_Offset1 takes
    // on the value of the used Repeated_Offset": offset_value 1 is
    // Repeated_Offset1 itself, so nothing moves.
    try testing.expectEqual(@as(u32, 1111), try resolveOffset(22, 1, &offsets));
    try testing.expectEqualSlices(u32, &.{ 1111, 1, 4 }, &offsets);
    try testing.expectEqual(@as(u32, 2222), try resolveOffset(22, 2225, &offsets));
    try testing.expectEqualSlices(u32, &.{ 2222, 1111, 1 }, &offsets);
    // The equal-offsets rule: offset_value 1114 resolves to 1111, which is
    // Repeated_Offset1 — still a shift, because the offset_value is above 3.
    try testing.expectEqual(@as(u32, 1111), try resolveOffset(111, 1114, &offsets));
    try testing.expectEqualSlices(u32, &.{ 1111, 2222, 1111 }, &offsets);
    try testing.expectEqual(@as(u32, 3333), try resolveOffset(33, 3336, &offsets));
    try testing.expectEqualSlices(u32, &.{ 3333, 1111, 2222 }, &offsets);
    // offset_value 2 with a nonzero literals length selects
    // Repeated_Offset2: "the existing values are pushed back from the first
    // Repeated_Offset through to the Repeated_Offset selected" — a swap.
    try testing.expectEqual(@as(u32, 1111), try resolveOffset(22, 2, &offsets));
    try testing.expectEqualSlices(u32, &.{ 1111, 3333, 2222 }, &offsets);
    // offset_value 3 selects Repeated_Offset3: the "single-stepped wrapping
    // rotation", Repeated_Offset3 to the front.
    try testing.expectEqual(@as(u32, 2222), try resolveOffset(33, 3, &offsets));
    try testing.expectEqualSlices(u32, &.{ 2222, 1111, 3333 }, &offsets);
    // "when the current sequence's literals_length is 0, repeated offsets
    // are shifted by 1, so an offset_value of 3 means Repeated_Offset1 -
    // 1_byte": the resolved offset is inserted at the front.
    try testing.expectEqual(@as(u32, 2221), try resolveOffset(0, 3, &offsets));
    try testing.expectEqualSlices(u32, &.{ 2221, 2222, 1111 }, &offsets);
    // And offset_value 1 with literals_length 0 means Repeated_Offset2,
    // which leaves Repeated_Offset3 alone (the table's last row says 3333).
    try testing.expectEqual(@as(u32, 2222), try resolveOffset(0, 1, &offsets));
    try testing.expectEqualSlices(u32, &.{ 2222, 2221, 1111 }, &offsets);
    // offset_value 2 with literals_length 0 means Repeated_Offset3.
    try testing.expectEqual(@as(u32, 1111), try resolveOffset(0, 2, &offsets));
    try testing.expectEqualSlices(u32, &.{ 1111, 2222, 2221 }, &offsets);
}

test "resolveOffset refuses the offset-0 corner" {
    // RFC 8878 §3.1.1.5 — "an offset_value of 3 means Repeated_Offset1 -
    // 1_byte"; with the seeded Repeated_Offset1 == 1 that is offset 0. The C
    // reference and std reject it; klauspost substitutes offset 1.
    var offsets: [3]u32 = repeat_offsets_start;
    try testing.expectError(error.ZeroOffset, resolveOffset(0, 3, &offsets));
    // The refusal leaves the repeats untouched; once Repeated_Offset1 is
    // above 1 the same code is legal.
    try testing.expectEqualSlices(u32, &repeat_offsets_start, &offsets);
    offsets = .{ 5, 4, 8 };
    try testing.expectEqual(@as(u32, 4), try resolveOffset(0, 3, &offsets));
    try testing.expectEqualSlices(u32, &.{ 4, 5, 4 }, &offsets);
}

test "copyMatch replicates an overlapping match" {
    // RFC 8878 §3.1.1.4 — "an offset of 6 and a match length of 3 means that
    // 3 bytes should be copied from 6 bytes back"; an offset below the match
    // length replicates the pattern, and the copy must observe its own
    // writes (a memmove's would not).
    var target: [32]u8 = undefined;
    fastmem.set(u8, &target, 0);
    // A two-byte pattern at offset 2, matched for 7 bytes: the copy must see
    // its own writes, so the pattern repeats.
    fastmem.copy(u8, target[0..2], "AB");
    copyMatch(&target, 2, 2, 7);
    try testing.expectEqualSlices(u8, "ABABABA", target[2..9]);
    // An offset of 1 replicates a single byte.
    fastmem.copy(u8, target[9..12], "xyz");
    copyMatch(&target, 12, 1, 8);
    try testing.expectEqualSlices(u8, "zzzzzzzz", target[12..20]);
    // An offset at least the match's length is a plain copy.
    fastmem.copy(u8, target[20..24], "abcd");
    copyMatch(&target, 24, 4, 4);
    try testing.expectEqualSlices(u8, "abcd", target[24..28]);
}

test "copyMatch fills a long match at a period dividing the chunk" {
    // The fill kernel (offset 1/2/4/8/16, length >= 2 * overlap_chunk) and
    // the doubling loop around it: every distance below and across the
    // chunk boundary, with lengths that stop short of, land on, and pass a
    // whole chunk (so the tail store runs at every phase). The expected
    // bytes are the offset-periodic repetition of the match's source. Regresion
    // guard for the fill tail's phase: the tail copies one chunk back in
    // memory, not the phase-0 register.
    var rng: DefaultPrng = .init(0x5eed);
    const random = rng.random();
    for (1..overlap_chunk + 2) |offset| {
        // Distinct bytes: a repeated period must come from the copy, not
        // from a coincidence in the source.
        for ([_]usize{
            2 * overlap_chunk,
            3 * overlap_chunk,
            3 * overlap_chunk + 1,
            4 * overlap_chunk + 7,
        }) |length| {
            var target: [4096]u8 = undefined;
            fastmem.set(u8, &target, 0);
            const match_start = 64;
            for (0..match_start) |i| target[i] = random.int(u8);
            if (offset >= 2) target[match_start - offset] = 1;
            const source = target[match_start - offset ..][0..offset];
            copyMatch(&target, match_start, @intCast(offset), @intCast(length));
            for (0..length) |i| {
                try testing.expectEqual(source[i % offset], target[match_start + i]);
            }
            // Nothing past the match's end was touched.
            try testing.expectEqual(@as(u8, 0), target[match_start + length]);
        }
    }
}

test "decode reads a real frame's Predefined-mode sequences section" {
    // RFC 8878 §3.1.1.3.2.2 — all three alphabets in Predefined_Mode: the
    // tables come from the default distributions and no table bytes are
    // present. golden.zig's fixture is the first compressed block of a real
    // `zstd -5` frame, so the CLI's own output is the expectation.
    const blocks = [_]FixtureBlock{.{
        .literals_section = &golden.sequences_predefined_literals,
        .sequences_section = &golden.sequences_predefined_section,
    }};
    try expectBlocks(&blocks, &.{&golden.sequences_predefined_expected});
}

test "decode reads a real frame's RLE-mode match lengths" {
    // RFC 8878 §3.1.1.3.2.1 — "RLE_Mode: The table description consists of
    // a single byte, which contains the symbol's value. This symbol will be
    // used for all sequences": the match length code is fixed, so every
    // match length comes from that one code's baseline and extra bits.
    const blocks = [_]FixtureBlock{.{
        .literals_section = &golden.sequences_rle_match_lengths_literals,
        .sequences_section = &golden.sequences_rle_match_lengths_section,
    }};
    try expectBlocks(&blocks, &.{&golden.sequences_rle_match_lengths_expected});
}

test "decode reads a real frame's FSE-compressed offset table" {
    // RFC 8878 §3.1.1.3.2.1 — FSE_Compressed_Mode for one alphabet beside
    // Predefined for the others: one distribution table is present, and its
    // description is the §4.1.1 reader's.
    const blocks = [_]FixtureBlock{.{
        .literals_section = &golden.sequences_fse_offsets_literals,
        .sequences_section = &golden.sequences_fse_offsets_section,
    }};
    try expectBlocks(&blocks, &.{&golden.sequences_fse_offsets_expected});
}

test "decode reads a real frame's all-FSE sequences section" {
    // RFC 8878 §3.1.1.3.2.1 + §3.1.1.3.2.1.2 — three distribution tables
    // then the interleaved bitstream: 19 sequences of literals-length,
    // offset, and match-length codes with their extra bits.
    const blocks = [_]FixtureBlock{.{
        .literals_section = &golden.sequences_fse_all_literals,
        .sequences_section = &golden.sequences_fse_all_section,
    }};
    try expectBlocks(&blocks, &.{&golden.sequences_fse_all_expected});
}

test "decode executes the corner fixture: offsets, rotation, trailing literals" {
    // RFC 8878 §3.1.1.4 + §3.1.1.5 — six RLE-mode sequences over 32
    // literals: offsets 5, 6, 7, then 7 again (an offset_value above 3 that
    // equals Repeated_Offset1, the equal-offsets rule), 9, and 12, with two
    // literals left over that "are added at the end of the block".
    const blocks = [_]FixtureBlock{.{
        .literals_section = &golden.corner_literals,
        .sequences_section = &golden.corner_section,
    }};
    try expectBlocks(&blocks, &.{&golden.corner_expected});
}

test "decode threads the repeat offsets and the history across blocks" {
    // RFC 8878 §3.1.1.5 — "each block gets its starting offset history from
    // the ending values of the most recent Compressed_Block": block 2's
    // literals_length is 0 for every sequence (the shifted selection), and
    // its offsets reach into block 1's output; block 3's offset_value 1
    // sequences walk the Repeated_Offset2 swap.
    const blocks = [_]FixtureBlock{
        .{
            .literals_section = &golden.first_block_literals,
            .sequences_section = &golden.first_block_section,
        },
        .{
            .literals_section = &golden.temp_offset_1_literals,
            .sequences_section = &golden.temp_offset_1_section,
        },
        .{
            .literals_section = &golden.temp_offset_2_literals,
            .sequences_section = &golden.temp_offset_2_section,
        },
    };
    try expectBlocks(&blocks, &.{
        &golden.first_block_expected,
        &golden.temp_offset_1_expected,
        &golden.temp_offset_2_expected,
    });
}

test "decode reuses the previous tables in Repeat mode" {
    // RFC 8878 §3.1.1.3.2.1 — "The table used in the previous
    // Compressed_Block with Number_Of_Sequences > 0 will be used again ...
    // Note that this includes RLE_Mode, so if Repeat_Mode follows RLE_Mode,
    // the same symbol will be repeated." Block 2's modes byte is 0xfc (all
    // three Repeat) and carries no table bytes.
    const blocks = [_]FixtureBlock{
        .{
            .literals_section = &golden.first_block_literals,
            .sequences_section = &golden.first_block_section,
        },
        .{
            .literals_section = &golden.repeat_1_literals,
            .sequences_section = &golden.repeat_1_section,
        },
    };
    try expectBlocks(&blocks, &.{ &golden.first_block_expected, &golden.repeat_1_expected });
}

test "decode reads the 2-byte Number_of_Sequences form over 128 sequences" {
    // RFC 8878 §3.1.1.3.2.1 — `80 80` is 128, the first count that needs
    // the 2-byte form, and each of the 128 sequences copies three bytes at
    // the alternating repeat offsets.
    const blocks = [_]FixtureBlock{
        .{
            .literals_section = &golden.first_block_literals,
            .sequences_section = &golden.first_block_section,
        },
        .{
            .literals_section = &golden.two_byte_1_literals,
            .sequences_section = &golden.two_byte_1_section,
        },
    };
    try expectBlocks(&blocks, &.{ &golden.first_block_expected, &golden.two_byte_1_expected });
}

test "decode ends a zero-count section on the literals" {
    // RFC 8878 §3.1.1.3.2.1 — "there are no sequences. The sequence section
    // stops here. Decompressed content is defined entirely as
    // Literals_Section content." Both the 1-byte zero and the 2-byte
    // decoded-zero form end the same way, and neither updates the frame's
    // tables.
    const blocks = [_]FixtureBlock{
        .{
            .literals_section = &golden.zero_literals,
            .sequences_section = &golden.zero_section,
        },
        .{
            .literals_section = &golden.zero_literals,
            .sequences_section = &golden.zero_two_byte_section,
        },
    };
    try expectBlocks(&blocks, &.{ &golden.zero_expected, &golden.zero_expected });
    var state: State = .{};
    var target: [64]u8 = undefined;
    internal.sentinel.fill(&target);
    const section = try decode(
        &golden.zero_section,
        &golden.zero_expected,
        &target,
        0,
        &.{},
        0,
        &state,
    );
    try testing.expectEqual(golden.zero_expected.len, section.bytes_written);
    try testing.expectEqual(@as(usize, 1), section.bytes_consumed);
    try testing.expect(state.tables[0] == null);
    try testing.expectEqualSlices(u32, &repeat_offsets_start, &state.repeat_offsets);
    try internal.sentinel.expect(&target, section.bytes_written);
}

test "decode rejects the mode corners" {
    // RFC 8878 §3.1.1.3.2.1 — the Reserved field "must be all zeroes", and
    // Repeat "used without any previous sequence table in the frame ... to
    // repeat ... should be treated as corruption". The RLE symbol byte is
    // outside the alphabet when it exceeds the context's last code.
    try expectError(error.ReservedModeBits, &.{ 0x01, 0x55, 0x00, 0x01 }, &.{}, 0);
    try expectError(error.RepeatModeFirst, &.{ 0x01, 0xfc, 0x01 }, &.{}, 0);
    try expectError(error.MalformedFseTable, &.{ 0x01, 0x54, 0x00, 0x20, 0x00, 0x01 }, &.{}, 0);
    // An RLE symbol byte the section does not hold.
    try expectError(error.MalformedSequencesHeader, &.{ 0x01, 0x54, 0x00 }, &.{}, 0);
    // A truncated FSE description: the modes byte puts the literals length
    // table in FSE_Compressed_Mode and the section ends before its
    // description does (`§4.1.1`).
    try expectError(error.MalformedFseTable, &.{ 0x01, 0xa4, 0x10 }, &.{}, 0);
}

test "decode fails on the sequence bounds" {
    // RFC 8878 §3.1.1.4 + §8 — a match that would reach before the
    // authorized history is `OffsetTooFar`, a match that would write past
    // the target is `BufferTooSmall`, and a literals_length past the
    // section's Regenerated_Size is `LiteralsTooLarge`; each fails before
    // the write it refuses.
    // OF symbol 3 with extra bits 7: offset_value 15, offset 12.
    const far = [_]u8{ 0x01, 0x54, 0x00, 0x03, 0x00, 0x0f };
    try expectError(error.OffsetTooFar, &far, &.{}, 0);
    // The same sequence with a 12-byte history is legal; with only 11 the
    // caller's cap (the frame's Window_Size) still refuses it.
    var target: [64]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    const section = try decode(&far, &.{}, &target, 12, &.{}, 0, &state);
    try testing.expectEqual(@as(usize, 3), section.bytes_written);
    try internal.sentinel.expect(&target, 15);
    try testing.expectError(error.OffsetTooFar, decode(&far, &.{}, &target, 11, &.{}, 0, &state));
    // literals_length 5 (LL symbol 5) with a 4-byte literals section.
    const five = [_]u8{ 0x01, 0x54, 0x05, 0x00, 0x00, 0x01 };
    try expectError(error.LiteralsTooLarge, &five, &.{ 1, 2, 3, 4 }, 0);
    // The same section with a target of 7 bytes: 5 literals + a 3-byte
    // match needs 8, and the check comes before the write.
    var small: [7]u8 = undefined;
    internal.sentinel.fill(&small);
    var small_state: State = .{};
    try testing.expectError(
        error.BufferTooSmall,
        decode(&.{ 0x01, 0x54, 0x05, 0x00, 0x00, 0x01 }, "abcde", &small, 0, &.{}, 0, &small_state),
    );
    try internal.sentinel.expect(&small, 0);
}

test "a Number_of_Sequences past the block cannot amplify" {
    // RFC 8878 §8 — the named vector is "the encoding of Number_of_Sequences
    // values that cause the decoder to read into the block header (and
    // beyond)". The count here is the 3-byte form's maximum (98047) over an
    // 8-byte section, and every sequence's match writes at least 3 bytes, so
    // the loop is bounded by the target: 21 sequences fill the 63 bytes
    // available and the 22nd is refused. The sentinel proves the last byte
    // was not written.
    const section = [_]u8{ 0xff, 0xff, 0xff, 0x54, 0x00, 0x00, 0x00, 0x01 };
    var target: [72]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    try testing.expectError(
        error.BufferTooSmall,
        decode(&section, &.{}, &target, 8, &.{}, 0, &state),
    );
    try internal.sentinel.expect(&target, 71);
}

test "decode fails on the bitstream's ends" {
    // RFC 8878 §3.1.1.3.2.1.2 — "the last byte of the compressed bitstream
    // cannot be zero", the stream must hold every bit the codes ask for, and
    // "at the end, the bitstream shall be entirely consumed".
    // A zero last byte has no start bit (`§4.2.2`).
    try expectError(error.MissingStartBit, &.{ 0x01, 0x54, 0x05, 0x00, 0x00, 0x00 }, "abcde", 0);
    // No bitstream at all.
    try expectError(error.MissingStartBit, &.{ 0x01, 0x54, 0x05, 0x00, 0x00 }, "abcde", 0);
    // One sequence whose match needs 3 extra bits over a 1-bit stream: the
    // reads run past the stream's start (`InvalidBitStream`).
    try expectError(error.InvalidBitStream, &.{ 0x01, 0x54, 0x05, 0x03, 0x00, 0x01 }, "abcde", 0);
    // A bit left over at the end: the section must consume the stream
    // whole. The sequence itself executed (5 literals and a 3-byte match at
    // the seeded Repeated_Offset1), so its output stands and only the
    // section end is refused.
    var target: [64]u8 = undefined;
    internal.sentinel.fill(&target);
    var state: State = .{};
    try testing.expectError(
        error.BitstreamNotConsumed,
        decode(&.{ 0x01, 0x54, 0x05, 0x00, 0x00, 0x02 }, "abcde", &target, 0, &.{}, 0, &state),
    );
    // offset_value 1 with a nonzero literals length is the seeded
    // Repeated_Offset1, so the match replicates the last literal.
    try testing.expectEqualSlices(u8, "abcdeeee", target[0..8]);
    try internal.sentinel.expect(&target, 8);
}

test "a zero-count section with bytes past the count is corruption" {
    // RFC 8878 §3.1.1.3.2.1 — "the sequence section stops here", and the
    // reference reads that as "extraneous data present in the Sequences
    // section" (its `zeroSeq_extraneous.zst` fixture is the sibling pin).
    try expectError(error.BitstreamNotConsumed, &.{ 0x00, 0x00 }, &.{}, 0);
    try expectError(error.BitstreamNotConsumed, &.{ 0x80, 0x00, 0x00 }, &.{}, 0);
}
