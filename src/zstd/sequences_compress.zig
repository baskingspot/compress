//! The sequences section of a compressed block for the zstd encoder
//! (`§3.1.1.3.2`): the header (Number_of_Sequences and
//! Symbol_Compression_Modes), the per-alphabet tables, and the interleaved
//! backward bitstream.
//!
//! The writer is the inverse of `sequences.decode`, mode for mode: the
//! count's 1/2/3-byte forms, the four Compression_Modes (`§3.1.1.3.2.1`,
//! Table 15), the description writer that reproduces `§4.1.1`'s table, and
//! the bitstream whose fields run in the reverse of the decoder's read order
//! (`§3.1.1.3.2.1.2`). The per-alphabet choice is the C's fast-strategy
//! ladder (`ZSTD_selectEncodingType`, `zstd_compress_sequences.c:157-235`):
//! RLE when one code carries every sequence (Predefined instead at two or
//! fewer sequences), Repeat while the previous table is valid,
//! Predefined below the alphabet's `defaultNormLog` threshold or when the
//! distribution is skewed, FSE otherwise.
//!
//! Repeat_Mode is reachable only after a previous Compressed_Block with a
//! nonzero sequence count, and the C only marks a table "valid" for it when a
//! *dictionary* loaded it (`ZSTD_dictNCountRepeat`, `zstd_compress.c:5044-5058`);
//! a frame built without a dictionary therefore never selects it, and neither
//! does this writer. The mode is implemented and round-trips all the same.
//!
//! Format: docs/research/specs/rfc8878-zstd.txt
//! Lineage: facebook/zstd v1.5.7 `zstd_compress_sequences.c`
//! (`ZSTD_selectEncodingType`, `ZSTD_buildCTable`, `ZSTD_encodeSequences_body`);
//! attribution in THIRD_PARTY.md.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const bits = @import("bits.zig");
const fse = @import("fse.zig");
const fse_compress = @import("fse_compress.zig");
const golden = @import("golden.zig");
const sequences = @import("sequences.zig");

/// Everything the sequences encoder reports.
pub const Error = error{
    /// `target` cannot hold the section the writer produces.
    BufferTooSmall,
} || fse_compress.Error;

/// One sequence, as the section carries it (`§3.1.1.3.2.1.1`): the literals
/// it copies, the match it copies, and the offset_value it copies them from.
/// The code tables are derived from these, so a caller never states a code
/// that disagrees with its value.
pub const Sequence = struct {
    /// The literals length: Table 16's codes 0-35, 0 to 131071 bytes.
    literals_length: u32,
    /// The match length: Table 17's codes 0-52, 3 to 131074 bytes.
    match_length: u32,
    /// `Offset_Value = (1 << offsetCode) + readNBits(offsetCode)`
    /// (`§3.1.1.3.2.1.1`), so a real offset is this minus 3
    /// (`§3.1.1.5`).
    offset_value: u32,
};

/// `§3.1.1.3.2.1.1` — the shortest match a sequence can carry: Table 17's
/// code 0 baseline.
pub const min_match_length: u32 = 3;

/// The alphabets, in the section's own order (`§3.1.1.3.2`): the header's
/// `[Literals_Length_Table] [Offset_Table] [Match_Length_Table]`, the
/// bitstream's initial-state order, and the flush order.
const Alphabet = sequences.Alphabet;
const alphabet_count = sequences.alphabet_count;

/// The sequences layer's cross-block state (`§3.1.1.3`): the three tables a
/// Repeat_Mode reuses. One per frame, threaded through the block loop; only a
/// Compressed_Block with a nonzero sequence count updates it, which is the
/// decoder's own rule.
pub const State = struct {
    /// Storage for the tables a block builds (the FSE_Compressed mode),
    /// double-buffered per alphabet: a block always builds into the slot
    /// `active` does not name, so an abandoned block — one the block layer
    /// reverts to Raw or RLE — never overwrites the table a later
    /// Repeat_Mode may reuse, and the revert restores only the small fields
    /// (`Header`), never the 12 KiB of table storage.
    built: std.EnumArray(Alphabet, [2]fse_compress.Table) = .initUndefined(),
    /// Which of each alphabet's two slots `tables` may resolve into. A
    /// build flips its alphabet's slot as it publishes the new table.
    active: std.EnumArray(Alphabet, u1) = .initFill(0),
    /// What each alphabet last resolved to, `null` until the frame's first
    /// sequences section with a nonzero count. Repeat_Mode reuses it, the way
    /// the decoder reuses its own resolved table.
    tables: std.EnumArray(Alphabet, ?Resolved) = .initFill(null),
    /// The C's `FSE_repeat_valid` per alphabet: a table that covers its whole
    /// alphabet, which only a dictionary's entropy tables are promoted to
    /// (`ZSTD_dictNCountRepeat`, `zstd_compress.c:5044-5058`). No dictionary
    /// exists in this package, so nothing sets it and Repeat_Mode is never
    /// selected — exactly the C's own no-dictionary behavior.
    repeat_valid: std.EnumSet(Alphabet) = .empty,

    /// The state's mutable fields apart from the table storage: everything a
    /// block's entropy attempt may redirect. The block layer snapshots one
    /// before the attempt and restores it for a block it does not keep; the
    /// `built` slots need no snapshot because an attempt writes only the
    /// inactive slots, which no live entry of `tables` resolves into.
    pub const Header = struct {
        active: std.EnumArray(Alphabet, u1),
        tables: std.EnumArray(Alphabet, ?Resolved),
        repeat_valid: std.EnumSet(Alphabet),
    };

    /// The state's current header, for the block layer's pre-attempt snapshot.
    pub fn header(state: *const State) Header {
        return .{
            .active = state.active,
            .tables = state.tables,
            .repeat_valid = state.repeat_valid,
        };
    }

    /// Restore a snapshotted header: the revert half of a block the ladder
    /// did not keep. The tables the snapshot's entries point into are the
    /// active slots, which the abandoned attempt never wrote.
    pub fn restore(state: *State, saved: *const Header) void {
        state.active = saved.active;
        state.tables = saved.tables;
        state.repeat_valid = saved.repeat_valid;
    }
};

/// What one alphabet resolved to (`§3.1.1.3.2.1`'s four modes, from the
/// encoder's side): the decoder's own resolved table, which Repeat_Mode
/// reuses — "The table used in the previous Compressed_Block with
/// Number_Of_Sequences > 0 will be used again ... Note that this includes
/// RLE_Mode ... It also includes Predefined_Mode".
pub const Resolved = union(enum) {
    /// Predefined_Mode: the shared `§3.1.1.3.2.2` table, no bytes on the
    /// wire.
    predefined,
    /// RLE_Mode: one symbol, whose cell reads zero bits, so the state never
    /// moves and the encoder writes nothing for it.
    rle: u8,
    /// FSE_Compressed_Mode: the table this block built.
    fse: *const fse_compress.Table,
};

/// The table an alphabet's state machine runs on, `null` for RLE_Mode's
/// zero-bit cell.
fn machineOf(resolved: Resolved, alphabet: Alphabet) ?*const fse_compress.Table {
    return switch (resolved) {
        .predefined => &predefined_tables[@intFromEnum(alphabet)],
        .rle => null,
        .fse => |table| table,
    };
}

/// `§3.1.1.3.2.1.2` — the states' flush order, the reverse of the decoder's
/// initial-state reads: "Literals_Length_State, followed by Offset_State, and
/// finally Match_Length_State".
const flush_order = [alphabet_count]Alphabet{ .match_lengths, .offsets, .literals_lengths };

/// The per-alphabet table descriptions' order (`§3.1.1.3.2`).
const description_order = [alphabet_count]Alphabet{
    .literals_lengths,
    .offsets,
    .match_lengths,
};

/// The Predefined_Mode tables (`§3.1.1.3.2.2`), built once at comptime: a
/// Predefined alphabet costs no per-block table work.
const predefined_tables: [alphabet_count]fse_compress.Table = blk: {
    @setEvalBranchQuota(100_000);
    var tables: [alphabet_count]fse_compress.Table = undefined;
    const specs = .{
        .{
            .distribution = &sequences.literals_length_distribution,
            .accuracy_log = 6,
        },
        .{
            .distribution = &sequences.offset_distribution,
            .accuracy_log = 5,
        },
        .{
            .distribution = &sequences.match_length_distribution,
            .accuracy_log = 6,
        },
    };
    for (specs, 0..) |spec, index| {
        var norm: fse_compress.Norm = .{
            .counts = @splat(0),
            .symbol_count = @intCast(spec.distribution.len),
            .accuracy_log = spec.accuracy_log,
        };
        for (spec.distribution, 0..) |count, symbol| norm.counts[symbol] = count;
        tables[index] = fse_compress.buildTable(norm);
    }
    break :blk tables;
};

/// One alphabet's context (`§3.1.1.3.2.1`, Table 15; `§3.1.1.3.2.2`).
const AlphabetSpec = struct {
    /// The alphabet's last code.
    symbol_value_max: u16,
    /// "the maximum allowed accuracy log for literals length code and match
    /// length code tables is 9, and the maximum accuracy log for the offset
    /// code table is 8".
    accuracy_log_max: u5,
    /// The Predefined_Mode distribution's accuracy log, which is also
    /// `defaultNormLog` in the C's selection rule.
    accuracy_log_default: u5,
    /// `DefaultMaxOff`: the largest offset code the predefined distribution
    /// covers, past which Predefined_Mode is not allowed.
    default_symbol_max: u16,
    codes: []const sequences.Code,
};

const alphabet_specs = [alphabet_count]AlphabetSpec{
    .{
        .symbol_value_max = sequences.literals_length_code_max,
        .accuracy_log_max = 9,
        .accuracy_log_default = 6,
        .default_symbol_max = sequences.literals_length_code_max,
        .codes = &sequences.literals_length_codes,
    },
    .{
        .symbol_value_max = sequences.offset_code_max,
        .accuracy_log_max = 8,
        .accuracy_log_default = 5,
        .default_symbol_max = 28,
        .codes = &sequences.offset_codes,
    },
    .{
        .symbol_value_max = sequences.match_length_code_max,
        .accuracy_log_max = 9,
        .accuracy_log_default = 6,
        .default_symbol_max = sequences.match_length_code_max,
        .codes = &sequences.match_length_codes,
    },
};

fn specOf(alphabet: Alphabet) AlphabetSpec {
    return alphabet_specs[@intFromEnum(alphabet)];
}

/// The C's `LL_deltaCode` (`zstd_compress_internal.h:1010`): the code a
/// literals length above 63 maps to, `highbit(length) + 19`.
const literals_length_code_delta: u8 = 19;

/// The C's `ML_deltaCode` (`zstd_compress_internal.h:1041`): the code a match
/// length above 130 maps to, `highbit(length - 3) + 36`.
const match_length_code_delta: u8 = 36;

/// The literals length each value maps to (`ZSTD_LLcode`,
/// `zstd_compress_internal.h:1000-1012`): a table under 64, and
/// `highbit(length) + 19` above it.
fn literalsLengthCode(value: u32) u8 {
    if (value > 63) return highBit(value) + literals_length_code_delta;
    return literals_length_code_table[value];
}

/// The match length each value maps to (`ZSTD_MLcode`,
/// `zstd_compress_internal.h:1026-1041`): the table is indexed by the match
/// length less Table 17's code 0 baseline, and above 130 the code is
/// `highbit(base) + 36`.
fn matchLengthCode(match_length: u32) u8 {
    assert(match_length >= min_match_length);
    const base = match_length - min_match_length;
    if (base > 127) return highBit(base) + match_length_code_delta;
    return match_length_code_table[base];
}

/// `§3.1.1.3.2.1.1` — "Offset_Value = (1 << offsetCode) + readNBits(offsetCode)",
/// so the code is the value's highest set bit and the extra bits are the code
/// itself. A value of 1-3 is a repeat code (`§3.1.1.5`), which is the wire's
/// business, not the code table's: the code and the extra bits are the same
/// either way.
fn offsetCode(offset_value: u32) u5 {
    assert(offset_value >= 1);
    return highBit(offset_value);
}

/// The code a value maps to: the first band of `codes` whose range holds it.
/// The comptime tables below invert the band tables with this, so the two can
/// never disagree.
fn bandOf(codes: []const sequences.Code, value: u32) u8 {
    for (codes, 0..) |code, index| {
        const top = code.baseline + (@as(u32, 1) << code.extra_bits) - 1;
        if (value <= top) return @intCast(index);
    }
    unreachable;
}

/// Table 16's codes for lengths 0-63, derived from the band table itself.
const literals_length_code_table: [64]u8 = blk: {
    @setEvalBranchQuota(10_000);
    var table: [64]u8 = undefined;
    for (&table, 0..) |*slot, length| slot.* = bandOf(&sequences.literals_length_codes, length);
    break :blk table;
};

/// Table 17's codes for match lengths 3-130, indexed by the length less 3.
const match_length_code_table: [128]u8 = blk: {
    @setEvalBranchQuota(10_000);
    var table: [128]u8 = undefined;
    for (&table, 0..) |*slot, base| {
        slot.* = bandOf(&sequences.match_length_codes, base + min_match_length);
    }
    break :blk table;
};

/// The three codes a sequence maps to (`ZSTD_seqToCodes`,
/// `zstd_compress.c:2700-2717`).
const Codes = struct {
    literals_lengths: u8,
    offsets: u5,
    match_lengths: u8,
};

fn codesOf(sequence: Sequence) Codes {
    return .{
        .literals_lengths = literalsLengthCode(sequence.literals_length),
        .offsets = offsetCode(sequence.offset_value),
        .match_lengths = matchLengthCode(sequence.match_length),
    };
}

/// One alphabet's histogram over a block's codes.
const Stats = struct {
    counts: [sequences.match_length_code_max + 1]u32 = @splat(0),
    /// The largest code present.
    max_code: u16 = 0,
    /// The largest count: the C's `HIST_count` return.
    most_frequent: u32 = 0,

    fn add(stats: *Stats, code: u8) void {
        stats.counts[code] += 1;
    }

    /// The C's trailing scans (`hist.c:55-61`): the largest code and the
    /// largest count come from one pass over the counted codes afterwards,
    /// not from a tracked maximum per sequence.
    fn finish(stats: *Stats) void {
        for (stats.counts, 0..) |count_of, code| {
            if (count_of != 0) {
                stats.max_code = @intCast(code);
                if (count_of > stats.most_frequent) stats.most_frequent = count_of;
            }
        }
    }
};

/// The three alphabets' histograms in one pass over the sequences: the C
/// stores each sequence's three codes in the store at emit time
/// (`ZSTD_storeSeq`, `zstd_compress.c:2700-2717`); this port computes them
/// once here rather than once per consumer.
fn countStats(source: []const Sequence) [alphabet_count]Stats {
    var stats: [alphabet_count]Stats = @splat(.{});
    for (source) |sequence| {
        const codes = codesOf(sequence);
        stats[@intFromEnum(Alphabet.literals_lengths)].add(codes.literals_lengths);
        stats[@intFromEnum(Alphabet.offsets)].add(codes.offsets);
        stats[@intFromEnum(Alphabet.match_lengths)].add(codes.match_lengths);
    }
    for (&stats) |*stats_one| stats_one.finish();
    return stats;
}

/// Write a sequences section (`§3.1.1.3.2`) for `sequences`, updating `state`
/// with the tables this block resolved. Returns the section's length.
///
/// An empty block's section is the single zero byte ("there are no sequences.
/// The sequence section stops here", `§3.1.1.3.2.1`) and leaves the state
/// alone. Every other block resolves one table per alphabet, in the section's
/// order, and then writes one interleaved bitstream.
pub fn write(target: []u8, source: []const Sequence, state: *State) Error!usize {
    if (source.len == 0) {
        if (target.len < 1) return error.BufferTooSmall;
        target[0] = 0;
        return 1;
    }
    var cursor = try writeSequenceCount(target, source.len);
    const stats = countStats(source);
    var modes: [alphabet_count]sequences.Mode = undefined;
    for (description_order) |alphabet| {
        const index = @intFromEnum(alphabet);
        modes[index] = selectMode(alphabet, &stats[index], @intCast(source.len), state);
    }
    // The modes byte: "bits 7-6 Literal_Lengths_Mode, 5-4 Offsets_Mode, 3-2
    // Match_Lengths_Mode, 1-0 Reserved", and "The last field, Reserved, must
    // be all zeroes".
    if (cursor >= target.len) return error.BufferTooSmall;
    target[cursor] = (@as(u8, @intFromEnum(modes[@intFromEnum(Alphabet.literals_lengths)])) << 6) |
        (@as(u8, @intFromEnum(modes[@intFromEnum(Alphabet.offsets)])) << 4) |
        (@as(u8, @intFromEnum(modes[@intFromEnum(Alphabet.match_lengths)])) << 2);
    cursor += 1;

    var resolved: std.EnumArray(Alphabet, Resolved) = .initUndefined();
    for (description_order) |alphabet| {
        const index = @intFromEnum(alphabet);
        cursor += try writeTable(
            target[cursor..],
            alphabet,
            modes[index],
            &stats[index],
            @intCast(source.len),
            state,
            codeOf(alphabet, codesOf(source[source.len - 1])),
        );
        resolved.set(alphabet, state.tables.get(alphabet).?);
    }
    cursor += try writeBitstream(target[cursor..], source, &resolved);
    return cursor;
}

/// `§3.1.1.3.2.1`'s Number_of_Sequences forms: "if (byte0 < 128):
/// Number_of_Sequences = byte0. Uses 1 byte"; "if (byte0 < 255):
/// Number_of_Sequences = ((byte0 - 128) << 8) + byte1. Uses 2 bytes"; "if
/// (byte0 == 255): Number_of_Sequences = byte1 + (byte2 << 8) + 0x7F00. Uses
/// 3 bytes" — `zstd_compress.c:2942-2950`.
fn writeSequenceCount(target: []u8, count: usize) Error!usize {
    assert(count >= 1);
    assert(count <= 0x7f00 + 0xffff);
    if (count < 128) {
        if (target.len < 1) return error.BufferTooSmall;
        target[0] = @intCast(count);
        return 1;
    }
    if (count < 0x7f00) {
        if (target.len < 2) return error.BufferTooSmall;
        target[0] = @intCast((count >> 8) + 0x80);
        target[1] = @truncate(count);
        return 2;
    }
    if (target.len < 3) return error.BufferTooSmall;
    const rest = count - 0x7f00;
    target[0] = 0xff;
    target[1] = @truncate(rest);
    target[2] = @truncate(rest >> 8);
    return 3;
}

/// The C's fast-strategy mode ladder (`ZSTD_selectEncodingType`,
/// `zstd_compress_sequences.c:157-235`) with `strategy = ZSTD_fast`:
///
/// - one code carries every sequence: RLE, or Predefined at two or fewer
///   sequences ("RLE uses 1 byte, but set_basic uses 5-6 bits per symbol",
///   `:166-178`);
/// - a valid previous table and fewer than 1000 sequences: Repeat;
/// - below the alphabet's `dynamicFse_nbSeq_min` (`(1 << defaultNormLog) * 9
///   >> 3`: 36 offset, 72 lengths) or a skewed distribution
///   (`mostFrequent < nbSeq >> (defaultNormLog - 1)`): Predefined;
/// - otherwise FSE_Compressed.
fn selectMode(
    alphabet: Alphabet,
    stats: *const Stats,
    sequence_count: u32,
    state: *State,
) sequences.Mode {
    const spec = specOf(alphabet);
    // Predefined_Mode is not allowed for the offset alphabet once a code
    // above the default distribution's range appears
    // (`zstd_compress_sequences.c:2822`: `max <= DefaultMaxOff`).
    const default_allowed = stats.max_code <= spec.default_symbol_max;
    if (stats.most_frequent == sequence_count) {
        state.repeat_valid.remove(alphabet);
        if (default_allowed and sequence_count <= 2) return .predefined;
        return .rle;
    }
    if (default_allowed) {
        if (state.repeat_valid.contains(alphabet) and sequence_count < 1000) return .repeat;
        const dynamic_min = (@as(u32, 1) << spec.accuracy_log_default) * 9 >> 3;
        if (sequence_count < dynamic_min or
            stats.most_frequent < (sequence_count >> (spec.accuracy_log_default - 1)))
        {
            state.repeat_valid.remove(alphabet);
            return .predefined;
        }
    }
    return .fse;
}

/// Resolve one alphabet's table for this block and write its description
/// (`§3.1.1.3.2.1`'s four Compression_Modes): nothing for Predefined, the
/// symbol byte for RLE, and the `§4.1.1` description for FSE_Compressed.
/// Returns the bytes written.
fn writeTable(
    target: []u8,
    alphabet: Alphabet,
    mode: sequences.Mode,
    stats: *const Stats,
    sequence_count: u32,
    state: *State,
    last_code: u8,
) Error!usize {
    const spec = specOf(alphabet);
    switch (mode) {
        .predefined => {
            state.tables.set(alphabet, .predefined);
            return 0;
        },
        .rle => {
            if (target.len < 1) return error.BufferTooSmall;
            target[0] = @intCast(stats.max_code);
            state.tables.set(alphabet, .{ .rle = @intCast(stats.max_code) });
            return 1;
        },
        .repeat => {
            // No bytes: the decoder reuses its previous table
            // (`§3.1.1.3.2.1`), and this writer keeps the matching one.
            assert(state.tables.get(alphabet) != null);
            return 0;
        },
        .fse => {
            const accuracy_log = fse_compress.optimalAccuracyLog(
                spec.accuracy_log_max,
                sequence_count,
                stats.max_code,
                2,
            );
            var norm: fse_compress.Norm = undefined;
            // The C's last-symbol step (`zstd_compress_sequences.c:271-278`):
            // the last sequence's code is excluded from the distribution
            // when it appears more than once, and the low-probability
            // decision follows the decremented count (`ZSTD_useLowProbCount`
            // is evaluated on `nbSeq_1`, not `nbSeq`). The accuracy log stays
            // the one `FSE_optimalTableLog` chose for the full count.
            var counts = stats.counts;
            var count_1 = sequence_count;
            if (counts[last_code] > 1) {
                counts[last_code] -= 1;
                count_1 -= 1;
            }
            try fse_compress.normalize(
                &norm,
                &counts,
                count_1,
                stats.max_code,
                accuracy_log,
                if (count_1 >= 2048) .minus_one else .one,
            );
            const written = try fse_compress.writeDescription(target, &norm);
            // Build into the alphabet's inactive slot, then publish: an
            // abandoned block's build lands where no live table resolves,
            // so the block layer's revert is the header alone.
            const slot = 1 - state.active.get(alphabet);
            state.built.getPtr(alphabet)[slot] = fse_compress.buildTable(norm);
            state.active.set(alphabet, slot);
            state.tables.set(alphabet, .{ .fse = &state.built.getPtr(alphabet)[slot] });
            return written;
        },
    }
}

/// Write the interleaved bitstream (`ZSTD_encodeSequences_body`,
/// `zstd_compress_sequences.c:291-382`), the exact inverse of
/// `sequences.decode`'s walk:
///
/// 1. the three states initialize from the LAST sequence's codes;
/// 2. that sequence's extra bits go in first, at the stream's low end (the
///    decoder reads them last);
/// 3. then sequences `nbSeq-2 .. 0` write their transition bits in OF, ML,
///    LL order and their extra bits in LL, ML, OF order;
/// 4. the states flush ML, OF, LL — the order the decoder's initial-state
///    reads are reversed from — and the stream closes with its 1 bit.
fn writeBitstream(
    target: []u8,
    source: []const Sequence,
    resolved: *const std.EnumArray(Alphabet, Resolved),
) Error!usize {
    // The register-resident accumulator, for the same reason the Huffman
    // streams use it: six fields per sequence through a memory-resident
    // writer would pay a store-load round trip per field.
    var accumulator: bits.BackwardAccumulator = .init;
    var written: usize = 0;
    var states: [alphabet_count]u16 = undefined;
    const last = source.len - 1;
    {
        // An RLE alphabet's cell reads zero bits and never moves: it carries
        // no state at all.
        const last_codes = codesOf(source[last]);
        for (description_order) |alphabet| {
            const index = @intFromEnum(alphabet);
            const table = machineOf(resolved.get(alphabet), alphabet) orelse continue;
            states[index] = table.initState(codeOf(alphabet, last_codes));
        }
        try writeExtras(&accumulator, target, &written, source[last], last_codes);
    }
    var index = last;
    while (index > 0) {
        index -= 1;
        // "FSE_encodeSymbol(&stateOffsetBits, ofCode)" and the two that
        // follow: the transition bits, in the reverse of the decoder's
        // update order. A fixed two-flush schedule per sequence: the three
        // transitions (at most 9 + 8 + 9 bits — the alphabets' accuracy
        // logs) and the literals-length extra (at most 16) total 42 under
        // any flush residue; the match-length and offset extras (at most 16
        // and 31) take the second flush. The per-field fit checks — six
        // data-dependent branches per sequence — become two predictable
        // bounds branches.
        const codes = codesOf(source[index]);
        const transition_order = [alphabet_count]Alphabet{
            .offsets,
            .match_lengths,
            .literals_lengths,
        };
        try accumulator.flush(target, &written);
        inline for (transition_order) |alphabet| {
            const state_index = @intFromEnum(alphabet);
            const code = codeOf(alphabet, codes);
            switch (resolved.get(alphabet)) {
                .rle => |symbol| assert(code == symbol),
                else => |rest| {
                    const table = machineOf(rest, alphabet).?;
                    const transition = table.step(states[state_index], code);
                    accumulator.addUnchecked(transition.bits, transition.bit_count);
                    states[state_index] = transition.state;
                },
            }
        }
        accumulator.addUnchecked(
            source[index].literals_length,
            sequences.literals_length_codes[codes.literals_lengths].extra_bits,
        );
        try accumulator.flush(target, &written);
        accumulator.addUnchecked(
            source[index].match_length - min_match_length,
            sequences.match_length_codes[codes.match_lengths].extra_bits,
        );
        accumulator.addUnchecked(source[index].offset_value, codes.offsets);
    }
    // `FSE_flushCState` in the C's order: ML, OF, LL.
    for (flush_order) |alphabet| {
        const flush_index = @intFromEnum(alphabet);
        if (machineOf(resolved.get(alphabet), alphabet)) |table| {
            try accumulator.add(target, &written, states[flush_index], table.norm.accuracy_log);
        }
    }
    return accumulator.close(target, &written);
}

/// The sequence's raw extra bits (`§3.1.1.3.2.1.1`): each value's low
/// Number_of_Bits bits, in LL, ML, OF order — the reverse of the decoder's
/// read order, which takes offset first. `codes` are the caller's: one
/// `codesOf` per sequence serves the transitions and the extras both.
fn writeExtras(
    accumulator: *bits.BackwardAccumulator,
    target: []u8,
    written: *usize,
    sequence: Sequence,
    codes: Codes,
) error{BufferTooSmall}!void {
    try accumulator.add(
        target,
        written,
        sequence.literals_length,
        sequences.literals_length_codes[codes.literals_lengths].extra_bits,
    );
    try accumulator.add(
        target,
        written,
        sequence.match_length - min_match_length,
        sequences.match_length_codes[codes.match_lengths].extra_bits,
    );
    try accumulator.add(
        target,
        written,
        sequence.offset_value,
        codes.offsets,
    );
}

/// The code an alphabet's symbol takes, from the sequence's codes.
fn codeOf(alphabet: Alphabet, codes: Codes) u8 {
    return switch (alphabet) {
        .literals_lengths => codes.literals_lengths,
        .offsets => codes.offsets,
        .match_lengths => codes.match_lengths,
    };
}

/// The index of the highest set bit; `value` must be nonzero.
fn highBit(value: u32) u5 {
    assert(value != 0);
    return @intCast(31 - @clz(value));
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc8878-zstd.txt §3.1.1.3.2 (the section),
// §3.1.1.3.2.1 (the header and the modes), §3.1.1.3.2.1.1 (Tables 16/17),
// §3.1.1.3.2.1.2 (the bitstream), §3.1.1.3.2.2 (the default distributions),
// §3.1.1.4 (sequence execution). Every round trip runs the landed decoder
// over the writer's bytes.
// ---------------------------------------------------------------------------

test "the code tables are Tables 16 and 17" {
    // RFC 8878 §3.1.1.3.2.1.1 — "Literals length codes are values ranging
    // from 0 to 35 ... They define lengths from 0 to 131071 bytes"; match
    // length codes 0-52 define 3 to 131074. The C's `LL_Code`/`ML_Code`
    // shortcut (`highbit + delta`) must agree with the band tables for every
    // value either can name.
    for (0..64) |value| {
        try testing.expectEqual(
            bandOf(&sequences.literals_length_codes, @intCast(value)),
            literalsLengthCode(@intCast(value)),
        );
    }
    for (64..131072) |value| {
        try testing.expectEqual(
            bandOf(&sequences.literals_length_codes, @intCast(value)),
            literalsLengthCode(@intCast(value)),
        );
    }
    for (3..131) |value| {
        try testing.expectEqual(
            bandOf(&sequences.match_length_codes, @intCast(value)),
            matchLengthCode(@intCast(value)),
        );
    }
    for (131..131075) |value| {
        try testing.expectEqual(
            bandOf(&sequences.match_length_codes, @intCast(value)),
            matchLengthCode(@intCast(value)),
        );
    }
    // The offset code is the value's highest bit: `Offset_Value =
    // (1 << offsetCode) + readNBits(offsetCode)`.
    for (1..4096) |value| {
        try testing.expectEqual(
            bandOf(&sequences.offset_codes, @intCast(value)),
            offsetCode(@intCast(value)),
        );
    }
}

test "writeSequenceCount covers the three forms' boundaries" {
    // RFC 8878 §3.1.1.3.2.1 — 127 is the last 1-byte count, 128 the first
    // 2-byte one, 0x7f00 the first 3-byte one, and the decoder's own reader
    // must recover each.
    var target: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try writeSequenceCount(&target, 127));
    try testing.expectEqualSlices(u8, &.{0x7f}, target[0..1]);
    try testing.expectEqual(@as(usize, 2), try writeSequenceCount(&target, 128));
    try testing.expectEqualSlices(u8, &.{ 0x80, 0x80 }, target[0..2]);
    try testing.expectEqual(@as(usize, 2), try writeSequenceCount(&target, 0x7eff));
    try testing.expectEqual(@as(usize, 3), try writeSequenceCount(&target, 0x7f00));
    try testing.expectEqualSlices(u8, &.{ 0xff, 0x00, 0x00 }, target[0..3]);
    for ([_]usize{ 1, 127, 128, 255, 0x7eff, 0x7f00, 0x7f00 + 0xffff }) |count| {
        const len = try writeSequenceCount(&target, count);
        // A nonzero count is followed by the modes byte, which the reader
        // needs to parse the header at all.
        target[len] = 0;
        const header = try sequences.parseHeader(target[0 .. len + 1]);
        try testing.expectEqual(@as(u32, @intCast(count)), header.sequence_count);
    }
}

test "a zero-sequence section is the single zero byte" {
    // RFC 8878 §3.1.1.3.2.1 — "there are no sequences. The sequence section
    // stops here", and the C writes the 1-byte form. The state is
    // untouched: "The FSE tables used in Repeat_Mode are not updated."
    var target: [8]u8 = undefined;
    var state: State = .{};
    const written = try write(&target, &.{}, &state);
    try testing.expectEqual(@as(usize, 1), written);
    try testing.expectEqualSlices(u8, &.{0x00}, target[0..1]);
    try testing.expect(state.tables.get(.literals_lengths) == null);
}

test "the writer's sections decode back through the landed decoder" {
    // RFC 8878 §3.1.1.3.2 — the round-trip gate: a section our writer
    // produces, decoded by `sequences.decode`, executes to the same bytes the
    // sequences describe. The shapes sweep every mode: a handful of sequences
    // (Predefined), one code repeated (RLE), a skewed long block (FSE), and
    // every offset form (Table 18's rules are the decoder's).
    var rng: DefaultPrng = .init(0x5E9);
    const random = rng.random();
    var source: [512]Sequence = undefined;
    for (0..200) |_| {
        const count = random.uintLessThan(usize, 40) + 1;
        // A real encoder only emits offsets its own output makes addressable
        // (`§3.1.1.4`): the offset never reaches past what the block has
        // produced, literals included.
        var produced: u32 = 0;
        for (source[0..count]) |*sequence| {
            const literals_length = random.uintLessThan(u32, 200);
            const match_length = random.uintLessThan(u32, 300) + min_match_length;
            const span = produced + literals_length;
            const offset = if (span == 0) 1 else random.uintLessThan(u32, @min(span, 4096)) + 1;
            sequence.* = .{
                .literals_length = literals_length,
                .match_length = match_length,
                .offset_value = offset + 3,
            };
            produced = span + match_length;
        }
        var target: [16384]u8 = undefined;
        var state: State = .{};
        const written = try write(&target, source[0..count], &state);
        // The decoder's own run, over a literals buffer with enough bytes.
        var literals_source: [16384]u8 = undefined;
        var literals_len: usize = 0;
        for (source[0..count]) |sequence| {
            for (0..sequence.literals_length) |_| {
                literals_source[literals_len] = @truncate(literals_len);
                literals_len += 1;
            }
        }
        var decoded: [64 * 1024]u8 = undefined;
        var decode_state: sequences.State = .{};
        const section = try sequences.decode(
            target[0..written],
            literals_source[0..literals_len],
            &decoded,
            0,
            &.{},
            0,
            &decode_state,
        );
        // Sequence Execution's own accounting: every literals byte is copied
        // exactly once, in order, and every match repeats the bytes at its
        // offset — the decoder's output is the check.
        var expected: [64 * 1024]u8 = undefined;
        var expected_len: usize = 0;
        var literals_consumed: usize = 0;
        for (source[0..count]) |sequence| {
            fastmem.copy(
                u8,
                expected[expected_len..][0..sequence.literals_length],
                literals_source[literals_consumed..][0..sequence.literals_length],
            );
            expected_len += sequence.literals_length;
            literals_consumed += sequence.literals_length;
            const offset = sequence.offset_value - 3;
            for (0..sequence.match_length) |index| {
                expected[expected_len + index] = expected[expected_len + index - offset];
            }
            expected_len += sequence.match_length;
        }
        // The trailing literals ("these bytes are added at the end of the
        // block") are part of the decoder's output too.
        const trailing = literals_len - literals_consumed;
        fastmem.copy(
            u8,
            expected[expected_len..][0..trailing],
            literals_source[literals_consumed..][0..trailing],
        );
        expected_len += trailing;
        try testing.expectEqual(expected_len, section.bytes_written);
        try testing.expectEqualSlices(u8, expected[0..expected_len], decoded[0..expected_len]);
    }
}

test "the mode ladder follows the C's thresholds" {
    // RFC 8878 §3.1.1.3.2.1 (Table 15) — the fast strategy's ladder
    // (`ZSTD_selectEncodingType`, `zstd_compress_sequences.c:157-235`):
    // Predefined over RLE at two or fewer sequences, RLE when one code
    // carries all, Predefined below 72 (lengths) / 36 (offsets) sequences or
    // when `mostFrequent < nbSeq >> (defaultNormLog - 1)`, FSE above.
    var state: State = .{};
    var stats: Stats = .{};
    // One code carrying all 40 sequences, with another code present: RLE.
    stats.counts[3] = 40;
    stats.counts[5] = 1;
    stats.max_code = 5;
    stats.most_frequent = 40;
    try testing.expectEqual(
        sequences.Mode.rle,
        selectMode(.literals_lengths, &stats, 40, &state),
    );
    // The same shape at two sequences: Predefined, "since RLE uses 1 byte,
    // but set_basic uses 5-6 bits per symbol").
    try testing.expectEqual(
        sequences.Mode.predefined,
        selectMode(.literals_lengths, &stats, 2, &state),
    );
    // A spread distribution under the threshold: Predefined.
    stats = .{};
    stats.counts[1] = 20;
    stats.counts[2] = 20;
    stats.max_code = 2;
    stats.most_frequent = 20;
    try testing.expectEqual(
        sequences.Mode.predefined,
        selectMode(.literals_lengths, &stats, 40, &state),
    );
    // A flat distribution over the threshold: Predefined too
    // (`mostFrequent < nbSeq >> (defaultNormLog - 1)`, 100 >> 5 = 3).
    stats = .{};
    stats.counts[1] = 2;
    stats.counts[2] = 2;
    stats.max_code = 30;
    stats.most_frequent = 2;
    try testing.expectEqual(
        sequences.Mode.predefined,
        selectMode(.literals_lengths, &stats, 100, &state),
    );
    // A distribution with a dominant code over the threshold: FSE_Compressed.
    stats = .{};
    stats.counts[1] = 50;
    stats.counts[2] = 50;
    stats.max_code = 2;
    stats.most_frequent = 50;
    try testing.expectEqual(
        sequences.Mode.fse,
        selectMode(.literals_lengths, &stats, 100, &state),
    );
    // The offset alphabet's default distribution stops at code 28: a larger
    // code disallows Predefined, whatever the counts.
    stats.max_code = 29;
    try testing.expectEqual(
        sequences.Mode.fse,
        selectMode(.offsets, &stats, 100, &state),
    );
    try testing.expectEqual(
        sequences.Mode.fse,
        selectMode(.offsets, &stats, 10, &state),
    );
    // A valid previous table and under 1000 sequences: Repeat (the C's
    // `FSE_repeat_valid`, which only a dictionary sets).
    state.repeat_valid.insert(.literals_lengths);
    stats.max_code = 2;
    try testing.expectEqual(
        sequences.Mode.repeat,
        selectMode(.literals_lengths, &stats, 100, &state),
    );
    // At 1000 sequences the ladder skips Repeat.
    try testing.expectEqual(
        sequences.Mode.fse,
        selectMode(.literals_lengths, &stats, 1000, &state),
    );
}

test "Repeat_Mode's section carries no table and reuses the previous one" {
    // RFC 8878 §3.1.1.3.2.1 — "The table used in the previous
    // Compressed_Block with Number_Of_Sequences > 0 will be used again ...
    // If this mode is used without any previous sequence table in the frame
    // ... to repeat, this should be treated as corruption." The writer only
    // selects it behind the C's `FSE_repeat_valid`, so these two blocks are
    // the shape a dictionary-loaded table would take: the first resolves real
    // tables, the second carries the Repeat byte and no table bytes, and its
    // codes are a subset of the first block's (what a valid table means).
    var first: [64]Sequence = undefined;
    for (&first, 0..) |*sequence, index| {
        sequence.* = .{
            // Every offset is addressable: the literals alone cover it
            // (`§3.1.1.4`).
            .literals_length = @intCast(40 + index),
            .match_length = @intCast(20 + index),
            .offset_value = @intCast(30 + index + 3),
        };
    }
    var second: [32]Sequence = undefined;
    for (&second, 0..) |*sequence, index| {
        sequence.* = first[index];
    }
    var target: [4096]u8 = undefined;
    var state: State = .{};
    const first_len = try write(&target, &first, &state);
    // The tables the first block resolved are now the frame's.
    for (description_order) |alphabet| {
        try testing.expect(state.tables.get(alphabet) != null);
        state.repeat_valid.insert(alphabet);
    }
    var second_target: [4096]u8 = undefined;
    const second_len = try write(&second_target, &second, &state);
    // The modes byte is all three Repeat, and no table bytes follow it: the
    // count is 1 byte, the modes byte the second, and the bitstream starts
    // right after.
    try testing.expectEqual(@as(u8, 0xfc), second_target[1]);
    const header = try sequences.parseHeader(second_target[0..second_len]);
    try testing.expectEqual(sequences.Mode.repeat, header.modes.?.literals_lengths);
    try testing.expectEqual(sequences.Mode.repeat, header.modes.?.offsets);
    try testing.expectEqual(sequences.Mode.repeat, header.modes.?.match_lengths);
    // And the decoder runs both blocks with the same tables.
    var literals_source: [8192]u8 = undefined;
    var literals_len: usize = 0;
    for (first) |sequence| {
        for (0..sequence.literals_length) |_| {
            literals_source[literals_len] = @truncate(literals_len);
            literals_len += 1;
        }
    }
    var decoded: [64 * 1024]u8 = undefined;
    var decode_state: sequences.State = .{};
    const first_section = try sequences.decode(
        target[0..first_len],
        literals_source[0..literals_len],
        &decoded,
        0,
        &.{},
        0,
        &decode_state,
    );
    const second_section = try sequences.decode(
        second_target[0..second_len],
        literals_source[0..literals_len],
        &decoded,
        first_section.bytes_written,
        &.{},
        0,
        &decode_state,
    );
    // The second block's output is its own sequences' execution, and the
    // decoder accepted the Repeat section whole.
    try testing.expect(second_section.bytes_written > 0);
    try testing.expectEqual(second_len, second_section.bytes_consumed);
}

/// One decoded section's sequences, read back out of the section by walking
/// the tables the decoder itself resolved.
const DecodedSequences = struct {
    sequences: [512]Sequence = undefined,
    count: usize = 0,
};

/// Walk a Predefined_Mode section with the decoder's own tables and recover
/// each sequence's values: the fixture's three alphabets carry no table bytes
/// and use the `§3.1.1.3.2.2` distributions, so the tables are the public
/// comptime ones.
fn decodePredefinedSequences(section: []const u8) !DecodedSequences {
    var result: DecodedSequences = .{};
    const header = try sequences.parseHeader(section);
    try testing.expectEqual(sequences.Mode.predefined, header.modes.?.literals_lengths);
    try testing.expectEqual(sequences.Mode.predefined, header.modes.?.offsets);
    try testing.expectEqual(sequences.Mode.predefined, header.modes.?.match_lengths);
    const tables = [alphabet_count]fse.Table{
        fse.buildTable(&sequences.literals_length_distribution, 6),
        fse.buildTable(&sequences.offset_distribution, 5),
        fse.buildTable(&sequences.match_length_distribution, 6),
    };
    var reader = try bits.BackwardReader.init(section[header.count_len + 1 ..]);
    var states: [alphabet_count]u16 = undefined;
    for (description_order) |alphabet| {
        const index = @intFromEnum(alphabet);
        states[index] = reader.readBits(tables[index].log);
    }
    while (result.count < header.sequence_count) : (result.count += 1) {
        // The decoder's read order: offset, match length, literals length.
        const offset_index = @intFromEnum(Alphabet.offsets);
        const match_index = @intFromEnum(Alphabet.match_lengths);
        const literal_index = @intFromEnum(Alphabet.literals_lengths);
        const offset_cell = tables[offset_index].entry(states[offset_index]);
        const match_cell = tables[match_index].entry(states[match_index]);
        const literal_cell = tables[literal_index].entry(states[literal_index]);
        const offset_code = offset_cell.symbol;
        const match_code = match_cell.symbol;
        const literal_code = literal_cell.symbol;
        const offset_value = sequences.offset_codes[offset_code].baseline +
            reader.readBits32(sequences.offset_codes[offset_code].extra_bits);
        const match_length = sequences.match_length_codes[match_code].baseline +
            reader.readBits32(sequences.match_length_codes[match_code].extra_bits);
        const literals_length = sequences.literals_length_codes[literal_code].baseline +
            reader.readBits32(sequences.literals_length_codes[literal_code].extra_bits);
        result.sequences[result.count] = .{
            .literals_length = literals_length,
            .match_length = match_length,
            .offset_value = offset_value,
        };
        if (result.count + 1 < header.sequence_count) {
            states[@intFromEnum(Alphabet.literals_lengths)] =
                literal_cell.baseline + reader.readBits(literal_cell.num_bits);
            states[@intFromEnum(Alphabet.match_lengths)] =
                match_cell.baseline + reader.readBits(match_cell.num_bits);
            states[@intFromEnum(Alphabet.offsets)] =
                offset_cell.baseline + reader.readBits(offset_cell.num_bits);
        }
    }
    try testing.expect(reader.isConsumed());
    return result;
}

test "the writer reproduces the reference encoder's own sequences section" {
    // RFC 8878 §3.1.1.3.2 — a real `zstd -5` frame's Predefined-mode section
    // (`golden.sequences_predefined_section`) re-encoded from the sequences
    // its own bits carry. The values are read back out of the reference bytes
    // with the decoder's tables, so the writer is pinned against the
    // reference's whole section: the count, the modes byte, the initial-state
    // choices, and every transition and extra bit must land where the CLI put
    // them.
    const section = golden.sequences_predefined_section;
    const decoded = try decodePredefinedSequences(&section);
    try testing.expect(decoded.count > 0);
    var target: [4096]u8 = undefined;
    var state: State = .{};
    const written = try write(&target, decoded.sequences[0..decoded.count], &state);
    try testing.expectEqualSlices(u8, &section, target[0..written]);
}
