//! FSE for the zstd encoder (RFC 8878 §4.1): the normalized counts a symbol
//! histogram implies, the encode-side table, the table description writer that
//! is the exact inverse of `fse.readDescription`, and the two-state bitstream
//! writer the Huffman weight series uses (`§4.2.1.2`).
//!
//! One implementation serves the same four contexts as the decoder: the
//! literals length, match length, and offset code tables of the sequences
//! section (`§3.1.1.3.2.1`: accuracy log caps 9, 9, 8; symbol counts 36, 53,
//! 32) and the Huffman weights (`§4.2.1.2`: cap 6, 256 symbols). The caller
//! passes the alphabet's limits; nothing here knows which context it serves.
//!
//! The encode table is §4.1.1's construction seen from the other side: its
//! symbol column is the decoding table's, and `step` is the inverse of
//! `fse.State.update` — given the state the decoder will hold after a symbol's
//! transition, it returns the state that symbol's cell belongs to and the bits
//! that walk the decoder between them. The writer's numbers follow the C
//! reference's (`FSE_normalizeCount`, `FSE_buildCTable_wksp`,
//! `FSE_writeNCount_generic`, `FSE_compress_usingCTable_generic`) unless a
//! `TEn` row in `docs/slop/research/zstd-encoder-notes.md` says otherwise; the byte
//! class they produce is the CLI's.
//!
//! Format: docs/specs/rfc8878-zstd.txt
//! Lineage: facebook/zstd v1.5.7 `fse_compress.c` (`FSE_normalizeCount`,
//! `FSE_buildCTable_wksp`, `FSE_writeNCount_generic`); attribution in
//! THIRD_PARTY.md.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const bits = @import("bits.zig");
const fse = @import("fse.zig");
const golden = @import("golden.zig");
const huff0 = @import("huff0.zig");

/// Everything the FSE encoder reports.
pub const Error = error{
    /// `target` cannot hold the bytes the writer produces.
    BufferTooSmall,
    /// The histogram cannot be normalized into a table of this accuracy: one
    /// symbol carries every count (the caller uses RLE_Mode instead), or the
    /// remainder cannot be absorbed (`FSE_normalizeCount`'s own error,
    /// `fse_compress.c:520-530`). The caller falls back to Predefined_Mode.
    NormalizationFailed,
    /// A two-state stream needs at least three symbols: the C's `srcSize <= 2`
    /// floor (`FSE_compress_usingCTable_generic`, `fse_compress.c:565`). The
    /// caller falls back to the direct weight form.
    NotCompressible,
};

/// §4.1.1 — "Accuracy_Log = low4bits + 5": the smallest accuracy log, and
/// `FSE_MIN_TABLELOG`.
pub const accuracy_log_min: u5 = 5;

/// The largest accuracy log any context uses (`§3.1.1.3.2.1` Table 15,
/// `§4.2.1.2`).
pub const accuracy_log_max: u5 = fse.accuracy_log_max;

/// "That expected number of symbols never exceeds 256" (`§4.1.1`).
pub const symbol_count_max = fse.symbol_count_max;

/// The largest table any context builds: `1 << accuracy_log_max` cells.
pub const table_size_max = fse.table_size_max;

/// The value a symbol below the accuracy log's resolution takes
/// (`§4.1.1`'s "less than 1" probability, worth one point). The C's
/// `ZSTD_useLowProbCount`: 1 until `nbSeq >= 2048`, then -1.
pub const LowProbability = enum(i16) {
    one = 1,
    minus_one = -1,
};

/// A normalized-count distribution (`§4.1.1`): the probability of each symbol
/// from 0 to `symbol_count - 1`, on a scale of `1 << accuracy_log`, with -1
/// for the "less than 1" probability. The sum, counting -1 as 1, is exactly
/// `1 << accuracy_log` — the budget the description must land on.
pub const Norm = struct {
    /// Only the first `symbol_count` entries are meaningful.
    counts: [symbol_count_max]i16,
    /// The number of symbols the distribution covers: the histogram's last
    /// nonzero symbol plus one.
    symbol_count: u16,
    accuracy_log: u5,
};

/// `FSE_optimalTableLog_internal` (`fse_compress.c:357-373`): the accuracy log
/// a distribution of `total` symbols over `max_symbol + 1` codes supports —
/// `highbit(total - 1) - minus`, raised to `FSE_minTableLog` when the alphabet
/// needs it, clamped into `[5, max_accuracy_log]`.
///
/// `minus` is the C's internal knob: 2 for the sequences tables
/// (`FSE_optimalTableLog`), 1 for the Huffman tree's depth (`HUF_optimalTableLog`,
/// `huf_compress.c:1285-1289`).
pub fn optimalAccuracyLog(max_accuracy_log: u5, total: u32, max_symbol: u16, minus: u2) u5 {
    assert(total >= 2);
    assert(max_symbol >= 1);
    assert(max_symbol < symbol_count_max);
    assert(max_accuracy_log >= accuracy_log_min);
    // The C's arithmetic wraps when `highbit(total - 1) < minus`; the wrap
    // leaves `table_log` at its cap, which the clamps below reach either way.
    const max_bits_source: u32 = @as(u32, highBit(total - 1)) -% @as(u32, minus);
    const min_bits: u32 = @min(
        @as(u32, highBit(total)) + 1,
        @as(u32, highBitU16(max_symbol)) + 2,
    );
    var table_log: u5 = max_accuracy_log;
    if (max_bits_source < table_log) table_log = @intCast(max_bits_source);
    if (min_bits > table_log) {
        // Every context's alphabet keeps `min_bits` under the cap (the widest
        // is the match length codes' 53: `highbit(52) + 2` is 7), so the
        // clamp never binds; it is here so a wider context cannot overrun the
        // caller's table.
        table_log = @intCast(@min(min_bits, @as(u32, max_accuracy_log)));
    }
    if (table_log < accuracy_log_min) table_log = accuracy_log_min;
    assert(table_log <= max_accuracy_log);
    return table_log;
}

/// Normalize a symbol histogram (`FSE_normalizeCount`, `fse_compress.c:465-533`):
/// the scaled-probability pass with the C's `rtbTable` rounding beats, the
/// low-probability cells, and the largest-symbol remainder fixup — or
/// `FSE_normalizeM2` when the remainder cannot be absorbed.
///
/// `histogram` must run from symbol 0 through `max_symbol`, `total` must be
/// its sum, and `max_symbol` the last symbol with a nonzero count. The
/// result's counts sum to exactly `1 << accuracy_log` with -1 counting as 1.
pub fn normalize(
    norm: *Norm,
    histogram: []const u32,
    total: u32,
    max_symbol: u16,
    accuracy_log: u5,
    low_probability: LowProbability,
) Error!void {
    assert(total >= 2);
    assert(histogram.len > max_symbol);
    assert(accuracy_log >= accuracy_log_min);
    assert(accuracy_log <= accuracy_log_max);
    // `tableLog < FSE_minTableLog(total, maxSymbolValue)` is the C's own
    // precondition (`fse_compress.c:470-471`); `optimalAccuracyLog` is what
    // keeps callers inside it.
    assert(accuracy_log >= minTableLog(total, max_symbol));

    norm.* = .{
        .counts = @splat(0),
        .symbol_count = max_symbol + 1,
        .accuracy_log = accuracy_log,
    };
    const low_prob_count: i16 = @intFromEnum(low_probability);
    const table_size: i32 = @as(i32, 1) << accuracy_log;
    // The C's rtbTable (`fse_compress.c:466`): the rounding beats that turn a
    // scaled probability into the nearest whole cell.
    const rtb_table = [8]u64{ 0, 473195, 504333, 520860, 550000, 700000, 750000, 830000 };
    const scale: u6 = 62 - @as(u6, accuracy_log);
    const step: u64 = (@as(u64, 1) << 62) / total;
    const v_step: u64 = @as(u64, 1) << (scale - 20);
    var still_to_distribute: i32 = table_size;
    var largest: u16 = 0;
    var largest_probability: i16 = 0;
    const low_threshold: u32 = total >> accuracy_log;

    for (0..@as(usize, max_symbol) + 1) |symbol| {
        const count = histogram[symbol];
        // "rle special case": one symbol carries every count, which is
        // RLE_Mode's to encode, never a table (`§3.1.1.3.2.1` Table 15).
        if (count == total) return error.NormalizationFailed;
        if (count == 0) continue;
        if (count <= low_threshold) {
            norm.counts[symbol] = low_prob_count;
            still_to_distribute -= 1;
            continue;
        }
        const scaled = @as(u64, count) * step;
        var probability: i16 = @intCast(scaled >> scale);
        if (probability < 8) {
            const rest_to_beat = v_step * rtb_table[@intCast(probability)];
            const rounded = scaled - (@as(u64, @intCast(probability)) << scale);
            probability += @intFromBool(rounded > rest_to_beat);
        }
        if (probability > largest_probability) {
            largest_probability = probability;
            largest = @intCast(symbol);
        }
        norm.counts[symbol] = probability;
        still_to_distribute -= probability;
    }

    // "corner case, need another normalization method": the remainder is too
    // large for the largest symbol to absorb.
    if (-still_to_distribute >= (norm.counts[largest] >> 1)) {
        try normalizeM2(norm, histogram, total, max_symbol, low_probability);
    } else {
        norm.counts[largest] += @intCast(still_to_distribute);
    }
    assert(sumsToBudget(norm));
}

/// `FSE_minTableLog` (`fse_compress.c:326-335`): the smallest accuracy log
/// that can give every symbol a cell.
fn minTableLog(total: u32, max_symbol: u16) u5 {
    assert(total > 1);
    const min_bits_source = highBit(total) + 1;
    const min_bits_symbols = highBitU16(max_symbol) + 2;
    return @min(min_bits_source, min_bits_symbols);
}

/// The C's `FSE_normalizeM2` (`fse_compress.c:386-464`): give every symbol at
/// least one point, then distribute the rest by scaled remainder. The caller
/// has already filled in the counts the first pass produced; every symbol the
/// first pass left is reassigned here.
fn normalizeM2(
    norm: *Norm,
    histogram: []const u32,
    total_in: u32,
    max_symbol: u16,
    low_probability: LowProbability,
) Error!void {
    const accuracy_log = norm.accuracy_log;
    const table_size: u32 = @as(u32, 1) << accuracy_log;
    const low_threshold: u32 = total_in >> accuracy_log;
    const low_one: u32 = (total_in * 3) >> (accuracy_log + 1);

    // "give every symbol at least one point".
    var remainder = placeLowSymbols(
        norm,
        histogram,
        max_symbol,
        low_threshold,
        low_one,
        low_probability,
    );
    var to_distribute: u32 = table_size - remainder.distributed;
    if (to_distribute == 0) return;

    // "risk of rounding to zero": with little left to distribute, the
    // threshold tightens and more of the waiting symbols take a single point.
    if (remainder.total / to_distribute > low_one) {
        const threshold = (remainder.total * 3) / (to_distribute * 2);
        placeRoundingSymbols(norm, histogram, max_symbol, threshold, &remainder);
        to_distribute = table_size - remainder.distributed;
    }

    if (remainder.distributed == @as(u32, max_symbol) + 1) {
        // "all values are pretty poor; probably incompressible data ... find
        // max, then give all remaining points to max".
        norm.counts[largestSymbol(histogram, max_symbol)] += @intCast(to_distribute);
        return;
    }
    if (remainder.total == 0) {
        // Every symbol was low enough for one of the thresholds: the
        // remainder walks the alphabet, one point at a time.
        var symbol: u16 = 0;
        while (to_distribute > 0) : (symbol = (symbol + 1) % (max_symbol + 1)) {
            if (norm.counts[symbol] > 0) {
                to_distribute -= 1;
                norm.counts[symbol] += 1;
            }
        }
        return;
    }
    try distributeRemainder(norm, histogram, max_symbol, remainder.total, to_distribute);
}

/// The C's `normalizeM2` bookkeeping (`fse_compress.c:392-393`): the total the
/// waiting symbols still carry and the points already given out.
const Remainder = struct {
    total: u32,
    distributed: u32,
};

/// The C's two low thresholds (`fse_compress.c:394-414`): a symbol at or
/// under `low_threshold` takes the low-probability cell, one at or under
/// `low_one` a single point, and the rest wait for the scaled pass.
fn placeLowSymbols(
    norm: *Norm,
    histogram: []const u32,
    max_symbol: u16,
    low_threshold: u32,
    low_one: u32,
    low_probability: LowProbability,
) Remainder {
    var remainder: Remainder = .{ .total = 0, .distributed = 0 };
    for (0..@as(usize, max_symbol) + 1) |symbol| {
        const count = histogram[symbol];
        if (count == 0) {
            norm.counts[symbol] = 0;
            continue;
        }
        if (count <= low_threshold) {
            norm.counts[symbol] = @intFromEnum(low_probability);
            remainder.distributed += 1;
            continue;
        }
        if (count <= low_one) {
            norm.counts[symbol] = 1;
            remainder.distributed += 1;
            continue;
        }
        norm.counts[symbol] = not_yet_assigned;
        remainder.total += count;
    }
    return remainder;
}

/// The C's "risk of rounding to zero" pass (`fse_compress.c:419-430`): with
/// the threshold tightened, every waiting symbol at or under it takes a
/// single point.
fn placeRoundingSymbols(
    norm: *Norm,
    histogram: []const u32,
    max_symbol: u16,
    threshold: u32,
    remainder: *Remainder,
) void {
    for (0..@as(usize, max_symbol) + 1) |symbol| {
        if (norm.counts[symbol] != not_yet_assigned) continue;
        const count = histogram[symbol];
        if (count > threshold) continue;
        norm.counts[symbol] = 1;
        remainder.distributed += 1;
        remainder.total -= count;
    }
}

/// The C's `NOT_YET_ASSIGNED` marker (`fse_compress.c:390`): a symbol the
/// secondary method has not placed yet.
const not_yet_assigned: i16 = -2;

/// The symbol with the largest count, the C's "give all remaining points to
/// max" choice.
fn largestSymbol(histogram: []const u32, max_symbol: u16) u16 {
    var max_value: u16 = 0;
    var max_count: u32 = 0;
    for (0..@as(usize, max_symbol) + 1) |symbol| {
        if (histogram[symbol] > max_count) {
            max_value = @intCast(symbol);
            max_count = histogram[symbol];
        }
    }
    return max_value;
}

/// The C's scaled-remainder pass (`fse_compress.c:452-464`): each waiting
/// symbol takes its share of the points left, scaled by its count, and never
/// less than one.
fn distributeRemainder(
    norm: *Norm,
    histogram: []const u32,
    max_symbol: u16,
    total: u32,
    to_distribute: u32,
) Error!void {
    const v_step_log: u6 = 62 - @as(u6, norm.accuracy_log);
    const mid: u64 = (@as(u64, 1) << (v_step_log - 1)) - 1;
    const r_step: u64 = (((@as(u64, 1) << v_step_log) * to_distribute) + mid) / total;
    var running: u64 = mid;
    for (0..@as(usize, max_symbol) + 1) |symbol| {
        if (norm.counts[symbol] != not_yet_assigned) continue;
        const end = running + @as(u64, histogram[symbol]) * r_step;
        const weight = (end >> v_step_log) - (running >> v_step_log);
        // The C returns its generic error here; the caller's accuracy log is
        // at least `minTableLog`, which is what keeps the weight nonzero.
        if (weight < 1) return error.NormalizationFailed;
        norm.counts[symbol] = @intCast(weight);
        running = end;
    }
}

/// Whether the counts sum to exactly the budget, with -1 counting as 1: the
/// property `§4.1.1`'s description depends on.
fn sumsToBudget(norm: *const Norm) bool {
    var sum: i32 = 0;
    for (norm.counts[0..norm.symbol_count]) |count| {
        sum += if (count < 0) -count else count;
    }
    return sum == @as(i32, 1) << norm.accuracy_log;
}

/// Write the distribution's table description (`§4.1.1`), the exact inverse of
/// `fse.readDescription` (`FSE_writeNCount_generic`, `fse_compress.c:234-329`):
/// the accuracy nibble, then each probability in Table 20's descending widths,
/// with 2-bit repeat flags for zero runs and the C's 16-bit shortcut for runs
/// of 24 or more. Returns the bytes written.
pub fn writeDescription(target: []u8, norm: *const Norm) Error!usize {
    assert(norm.accuracy_log >= accuracy_log_min);
    assert(norm.accuracy_log <= accuracy_log_max);
    assert(norm.symbol_count >= 2);
    assert(sumsToBudget(norm));
    var writer = bits.ForwardWriter.init(target);
    // "Table Size": Accuracy_Log = low4bits + 5.
    try writer.writeBits(norm.accuracy_log - accuracy_log_min, 4);

    // The budget is `1 << Accuracy_Log` points; `remaining` starts one above
    // it and lands on exactly 1 when the distribution is complete.
    var remaining: i32 = (@as(i32, 1) << norm.accuracy_log) + 1;
    var threshold: i32 = @as(i32, 1) << norm.accuracy_log;
    var field_bits: u5 = norm.accuracy_log + 1;
    var symbol: u32 = 0;
    var previous_zero = false;

    while (symbol < norm.symbol_count and remaining > 1) {
        if (previous_zero) {
            var start = symbol;
            while (symbol < norm.symbol_count and norm.counts[symbol] == 0) symbol += 1;
            // Trailing zeros need no flags: the budget is already spent.
            if (symbol == norm.symbol_count) break;
            // The C's fast path: eight 3-flags at once.
            while (symbol >= start + 24) {
                start += 24;
                try writer.writeBits(0xffff, 16);
            }
            while (symbol >= start + 3) {
                start += 3;
                try writer.writeBits(3, 2);
            }
            try writer.writeBits(@intCast(symbol - start), 2);
        }
        const count = norm.counts[symbol];
        symbol += 1;
        // "count++ for extra accuracy": the wire value is the probability
        // plus one, and a value at or above the threshold carries the offset
        // the decoder's Table 20 bracket subtracts.
        const max = (2 * threshold - 1) - remaining;
        remaining -= if (count < 0) -@as(i32, count) else count;
        var encoded: i32 = count + 1;
        if (encoded >= threshold) encoded += max;
        // "Small values use 1 fewer bit": the narrow form consumes one bit
        // less, which is why the width drops when the value is under `max`.
        try writer.writeBits(@intCast(encoded), field_bits - @intFromBool(encoded < max));
        previous_zero = encoded == 1;
        if (remaining < 1) return error.NormalizationFailed;
        while (remaining < threshold) {
            field_bits -= 1;
            threshold >>= 1;
        }
    }
    if (remaining != 1) return error.NormalizationFailed;
    try writer.finish();
    return writer.bytesWritten();
}

/// The C's `symbolTT` (`fse_compress.c:176-215`): the packed transform that
/// turns a state into the symbol's cell and its transition bits.
pub const Transform = struct {
    /// `(max_bits_out << 16) - min_state_plus`, wrapping: the C's
    /// `deltaNbBits`, whose u32 borrow is what selects the one-fewer-bit
    /// form.
    delta_nb_bits: u32,
    /// The C's `deltaFindState`: where the symbol's cells start in the
    /// state-sorted list, less the shifted state. It is signed because the
    /// C's own `total - count` goes negative for the first symbols; the sum
    /// it lands in is never.
    find_state: i32,
};

/// A symbol's step in the encoder's backward walk.
pub const Transition = struct {
    /// The state whose cell holds `symbol`: the state the decoder must be in
    /// before the transition.
    state: u16,
    /// The transition's extra bits: `destination - baseline(state)`.
    bits: u32,
    /// How many bits `bits` occupies: `num_bits(state)`.
    bit_count: u5,
};

/// The encode-side table (`FSE_buildCTable_wksp`, `fse_compress.c:68-225`):
/// the normalized counts, the symbol transform, and the per-symbol state list.
pub const Table = struct {
    norm: Norm,
    /// One transform per symbol, `symbol_count` of them meaningful.
    transforms: [symbol_count_max]Transform,
    /// Per symbol, its cells' state values biased by `1 << accuracy_log`
    /// (the C's `tableSize+u`), in state order.
    next_states: [table_size_max]u16,
    /// Per symbol, the first state whose cell holds it: the C's
    /// `FSE_initCState2` start (`fse_compress.c:147-160`).
    first_states: [symbol_count_max]u16,
    /// `1 << accuracy_log`, the bias `next_states` carries.
    bias: u16,

    /// The state the encoder starts a symbol series from: the smallest state
    /// whose cell holds `symbol` (`FSE_initCState2`). The decoder reads it as
    /// the stream's initial state.
    pub fn initState(self: *const Table, symbol: u8) u16 {
        assert(symbol < self.norm.symbol_count);
        assert(self.norm.counts[symbol] != 0);
        return self.first_states[symbol];
    }

    /// The C's `FSE_encodeSymbol` (`fse_compress.h:159-166`): the inverse of
    /// `fse.State.update`. `destination` is the state the decoder will hold
    /// after the symbol's transition; the result is the state whose cell holds
    /// `symbol` and the bits that walk the decoder between the two.
    pub fn step(self: *const Table, destination: u16, symbol: u8) Transition {
        assert(symbol < self.norm.symbol_count);
        assert(self.norm.counts[symbol] != 0);
        assert(destination < self.bias);
        const value: u32 = @as(u32, self.bias) + destination;
        const transform = self.transforms[symbol];
        const bit_count: u5 = @intCast((value +% transform.delta_nb_bits) >> 16);
        assert(bit_count <= accuracy_log_max);
        const index = @as(i32, @intCast(value >> bit_count)) + transform.find_state;
        assert(index >= 0);
        assert(index < self.bias);
        const state = self.next_states[@intCast(index)] - self.bias;
        return .{
            .state = state,
            .bits = value & mask32(bit_count),
            .bit_count = bit_count,
        };
    }
};

/// Build the encode table from a normalized distribution. The symbol column is
/// §4.1.1's own construction — the same one `fse.buildTable` builds for the
/// decoder — so the two tables are one table seen from its two sides.
pub fn buildTable(norm: Norm) Table {
    assert(norm.symbol_count >= 2);
    assert(norm.accuracy_log >= accuracy_log_min);
    assert(norm.accuracy_log <= accuracy_log_max);
    assert(sumsToBudget(&norm));
    const log = norm.accuracy_log;
    const table_size: u16 = @as(u16, 1) << @intCast(log);
    var table: Table = .{
        .norm = norm,
        .transforms = undefined,
        .next_states = undefined,
        .first_states = undefined,
        .bias = table_size,
    };

    var starts: [symbol_count_max + 1]u16 = undefined;
    var symbol_of: [table_size_max]u8 = undefined;
    buildSymbolColumn(&norm, table_size, &starts, &symbol_of);

    // The per-symbol state lists (`fse_compress.c:169-174`): the states that
    // hold each symbol, in state order, biased by the table size.
    var cursors: [symbol_count_max + 1]u16 = starts;
    for (0..table_size) |state| {
        const symbol = symbol_of[state];
        const slot = cursors[symbol];
        table.next_states[slot] = @intCast(table_size + state);
        if (slot == starts[symbol]) table.first_states[symbol] = @intCast(state);
        cursors[symbol] = slot + 1;
    }
    buildTransforms(&table, log, table_size);
    return table;
}

/// `§4.1.1`'s table construction, the symbol column both sides share: the
/// "less than 1" symbols' single cells "starting from the end of the table
/// and retreating", then the rest spread with `position += (tableSize >> 1) +
/// (tableSize >> 3) + 3; position &= tableSize - 1`, "a position is skipped
/// if it is already occupied by a 'less than 1' probability symbol. Position
/// does not reset between symbols." `starts[symbol]` is where the symbol's
/// cells begin in the state-sorted list (the C's `cumul[]`,
/// `fse_compress.c:110-125`).
fn buildSymbolColumn(
    norm: *const Norm,
    table_size: u16,
    starts: *[symbol_count_max + 1]u16,
    symbol_of: *[table_size_max]u8,
) void {
    const table_mask: u16 = table_size - 1;
    const step: u16 = (table_size >> 1) + (table_size >> 3) + 3;
    var high_threshold: u16 = table_size - 1;
    starts[0] = 0;
    for (1..@as(usize, norm.symbol_count) + 1) |index| {
        const count = norm.counts[index - 1];
        if (count == -1) {
            starts[index] = starts[index - 1] + 1;
            symbol_of[high_threshold] = @intCast(index - 1);
            high_threshold -= 1;
        } else {
            assert(count >= 0);
            starts[index] = starts[index - 1] + @as(u16, @intCast(count));
        }
    }
    var position: u16 = 0;
    for (0..norm.symbol_count) |symbol| {
        const count = norm.counts[symbol];
        if (count <= 0) continue;
        var placed: i16 = 0;
        while (placed < count) : (placed += 1) {
            symbol_of[position] = @intCast(symbol);
            position = (position + step) & table_mask;
            while (position > high_threshold) position = (position + step) & table_mask;
        }
    }
    assert(position == 0);
}

/// The C's `symbolTT` (`fse_compress.c:176-215`): per symbol, the packed
/// transform `step` runs. The running total is the number of cells the
/// symbols before this one hold, which is what `find_state` offsets from.
fn buildTransforms(table: *Table, log: u5, table_size: u16) void {
    var total: u32 = 0;
    for (0..table.norm.symbol_count) |symbol| {
        const count = table.norm.counts[symbol];
        if (count == 0) {
            // "filling nonetheless, for compatibility with FSE_getMaxNbBits()".
            table.transforms[symbol] = .{
                .delta_nb_bits = (@as(u32, log + 1) << 16) - table_size,
                .find_state = 0,
            };
            continue;
        }
        if (count == -1 or count == 1) {
            table.transforms[symbol] = .{
                .delta_nb_bits = (@as(u32, log) << 16) - table_size,
                .find_state = @as(i32, @intCast(total)) - 1,
            };
            total += 1;
            continue;
        }
        const max_bits_out: u5 = log - highBitU16(@intCast(count - 1));
        const min_state_plus: u32 = @as(u32, @intCast(count)) << max_bits_out;
        table.transforms[symbol] = .{
            // The subtraction borrows for a symbol whose cells straddle the
            // table's midpoint; the borrow is the transform's own encoding of
            // the one-fewer-bit form.
            .delta_nb_bits = (@as(u32, max_bits_out) << 16) -% min_state_plus,
            .find_state = @as(i32, @intCast(total)) - @as(i32, @intCast(count)),
        };
        total += @as(u32, @intCast(count));
    }
    assert(total == table_size);
}

/// The encode table for RLE_Mode (`§3.1.1.3.2.1`: "The table description
/// consists of a single byte, which contains the symbol's value. This symbol
/// will be used for all sequences."): one cell, zero transition bits, the
/// state fixed at 0. The C's `FSE_buildCTable_rle` (`fse_compress.c:544-566`).
pub fn buildRleTable(symbol: u8) Table {
    var table: Table = .{
        .norm = .{ .counts = @splat(0), .symbol_count = symbol + 1, .accuracy_log = 0 },
        .transforms = @splat(.{ .delta_nb_bits = 0, .find_state = 0 }),
        .next_states = @splat(1),
        .first_states = @splat(0),
        .bias = 1,
    };
    table.norm.counts[symbol] = 1;
    return table;
}

/// FSE-compress a symbol series into one backward bitstream with two
/// interleaved states (`FSE_compress_usingCTable_generic`, `fse_compress.c:551-640`):
/// the inverse of `§4.2.1.2`'s weight decode. State1 takes the even indices
/// and State2 the odd, the series is written in reverse, and State2 is flushed
/// before State1 so the decoder reads State1's state first.
///
/// Returns the stream's length. The caller has already established that every
/// symbol has a nonzero probability in `table`.
pub fn compressSymbols(target: []u8, source: []const u8, table: *const Table) Error!usize {
    // "srcSize <= 2": fewer than three symbols cannot carry two initial
    // states and a transition.
    if (source.len <= 2) return error.NotCompressible;
    var writer = bits.BackwardWriter.init(target);
    var state1: u16 = undefined;
    var state2: u16 = undefined;
    if (source.len % 2 == 1) {
        state1 = table.initState(source[source.len - 1]);
        state2 = table.initState(source[source.len - 2]);
    } else {
        state2 = table.initState(source[source.len - 1]);
        state1 = table.initState(source[source.len - 2]);
    }
    var index = source.len - 3;
    while (true) : (index -= 1) {
        const symbol = source[index];
        if (index % 2 == 0) {
            try encodeSymbol(&writer, table, &state1, symbol);
        } else {
            try encodeSymbol(&writer, table, &state2, symbol);
        }
        if (index == 0) break;
    }
    try writer.writeBits(state2, table.norm.accuracy_log);
    try writer.writeBits(state1, table.norm.accuracy_log);
    try writer.close();
    return writer.bytesWritten();
}

/// One `FSE_encodeSymbol` step: write the transition bits and move the state.
inline fn encodeSymbol(
    writer: *bits.BackwardWriter,
    table: *const Table,
    state: *u16,
    symbol: u8,
) error{BufferTooSmall}!void {
    const transition = table.step(state.*, symbol);
    state.* = transition.state;
    try writer.writeBits(transition.bits, transition.bit_count);
}

/// The index of the highest set bit; `value` must be nonzero.
fn highBit(value: u32) u5 {
    assert(value != 0);
    return @intCast(31 - @clz(value));
}

/// The index of the highest set bit; `value` must be nonzero.
fn highBitU16(value: u16) u5 {
    assert(value != 0);
    return @intCast(15 - @clz(value));
}

/// `(1 << count) - 1` for `count` up to 32.
fn mask32(count: u5) u32 {
    return (@as(u32, 1) << @intCast(count)) - 1;
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/specs/rfc8878-zstd.txt §4.1 (the FSE state
// machine), §4.1.1 (the table description and the table construction),
// §3.1.1.3.2.1 (the sequences contexts' caps), §4.2.1.2 (the weights context).
// The byte-exact expectations are the reference encoder's own descriptions
// (`golden.zig`'s provenance).
// ---------------------------------------------------------------------------

/// A Norm from a plain count array, for the fixture tests.
fn normOf(counts: []const i16, accuracy_log: u5) Norm {
    var norm: Norm = .{
        .counts = @splat(0),
        .symbol_count = @intCast(counts.len),
        .accuracy_log = accuracy_log,
    };
    for (counts, 0..) |count, symbol| norm.counts[symbol] = count;
    return norm;
}

test "optimalAccuracyLog follows the C's ladder" {
    // `FSE_optimalTableLog` (fse_compress.c:357-373): `highbit(total-1) - 2`
    // clamped into [5, cap]. The survey's ladder (zstd-encoder-notes §1.5):
    // nbSeq 249 -> 6, 561 -> 7, 1201 -> 8, 2526 -> 9 (the literals length
    // context's cap).
    try testing.expectEqual(@as(u5, 6), optimalAccuracyLog(9, 249, 30, 2));
    try testing.expectEqual(@as(u5, 7), optimalAccuracyLog(9, 561, 30, 2));
    try testing.expectEqual(@as(u5, 8), optimalAccuracyLog(9, 1201, 30, 2));
    try testing.expectEqual(@as(u5, 9), optimalAccuracyLog(9, 2526, 30, 2));
    // The offset context's cap is 8, so 2526 lands there.
    try testing.expectEqual(@as(u5, 8), optimalAccuracyLog(8, 2526, 20, 2));
    // A distribution whose count is under `1 << minus` keeps the cap: the
    // C's subtraction wraps, and the wrapped value never falls under a cap
    // (the floor is FSE_MIN_TABLELOG = 5, not a reduction).
    try testing.expectEqual(@as(u5, 9), optimalAccuracyLog(9, 2, 2, 2));
    // 40 symbols over 36 codes asks for 3 bits and is raised to
    // `min(highbit(40) + 1, highbit(35) + 2)` = 6.
    try testing.expectEqual(@as(u5, 6), optimalAccuracyLog(9, 40, 35, 2));
    // The Huffman weights' context uses the "minus 1" variant and a cap of 6
    // (huf_compress.c:1285-1289, `MAX_FSE_TABLELOG_FOR_HUFF_HEADER`).
    try testing.expectEqual(@as(u5, 6), optimalAccuracyLog(6, 200, 11, 1));
    try testing.expectEqual(@as(u5, 5), optimalAccuracyLog(6, 20, 11, 1));
}

test "normalize lands on the budget and gives every present symbol a cell" {
    // RFC 8878 §4.1.1 — the distribution's points must land exactly on
    // `1 << Accuracy_Log`, with -1 worth one point, and a symbol with
    // a nonzero count must never normalize to zero.
    var rng: DefaultPrng = .init(0xF5E0);
    const random = rng.random();
    var histogram: [256]u32 = undefined;
    for (0..300) |_| {
        const max_symbol = random.uintLessThan(u16, 40) + 1;
        const total = random.uintLessThan(u32, 4000) + 2;
        var remaining = total;
        for (histogram[0 .. max_symbol + 1]) |*count| {
            // A skewed draw: most symbols small, a few large, so both the
            // low-probability path and the largest-symbol fixup are hit.
            const draw = random.uintLessThan(u32, 20);
            const value = if (draw < 14) 0 else random.uintLessThan(u32, remaining + 1);
            count.* = @min(value, remaining);
            remaining -= count.*;
        }
        if (remaining > 0) histogram[0] += remaining;
        var last: u16 = max_symbol;
        while (last > 0 and histogram[last] == 0) last -= 1;
        // A single-symbol histogram is RLE_Mode's, never a table's.
        if (last == 0) continue;
        const accuracy_log = optimalAccuracyLog(9, total, last, 2);
        var norm: Norm = undefined;
        normalize(
            &norm,
            &histogram,
            total,
            last,
            accuracy_log,
            if (total >= 2048) .minus_one else .one,
        ) catch |err| switch (err) {
            error.NormalizationFailed => continue,
            else => return err,
        };
        try testing.expect(sumsToBudget(&norm));
        for (histogram[0 .. last + 1], 0..) |count, symbol| {
            if (count == 0) continue;
            try testing.expect(norm.counts[symbol] != 0);
        }
    }
}

test "normalize refuses the single-symbol distribution" {
    // RFC 8878 §3.1.1.3.2.1 Table 15 — FSE_Compressed "must not be used when
    // only one symbol is present": the caller uses RLE_Mode instead, so the
    // normalizer's rle special case is an error here.
    var histogram = [_]u32{0} ** 4;
    histogram[2] = 100;
    var norm: Norm = undefined;
    try testing.expectError(
        error.NormalizationFailed,
        normalize(&norm, &histogram, 100, 2, 5, .one),
    );
}

test "writeDescription reproduces the reference encoder's own descriptions" {
    // RFC 8878 §4.1.1 — the description writer against `zstd` v1.5.7's own
    // `FSE_writeNCount` bytes (`golden.zig`'s provenance): the accuracy
    // nibble, Table 20's descending widths, the zero runs, and the 16-bit
    // shortcut must land byte for byte. The counts are what the reference
    // decoder recovers, so this is the writer's inverse in both directions.
    const cases = .{
        .{
            .counts = &golden.literals_length_description_counts,
            .accuracy_log = 9,
            .expected = golden.literals_length_description[0..],
        },
        .{
            .counts = &golden.offset_description_counts,
            .accuracy_log = 8,
            .expected = golden.offset_description[0..],
        },
        .{
            .counts = &golden.weights_description_counts,
            .accuracy_log = 5,
            .expected = golden.weights_description[1..5],
        },
    };
    inline for (cases) |case| {
        var target: [128]u8 = undefined;
        const norm = normOf(case.counts, case.accuracy_log);
        const written = try writeDescription(&target, &norm);
        // The expected slice is the description's own bytes: for the weights
        // fixture that is the prefix of the series `weights_description[0]`
        // counts, the rest being the weight stream.
        try testing.expectEqualSlices(u8, case.expected, target[0..written]);
    }
}

test "writeDescription and readDescription are inverses over every accuracy log" {
    // RFC 8878 §4.1.1 — the round-trip gate: our writer's bytes through our
    // reader must give back the distribution the writer was given, for every
    // accuracy log and symbol count. The sweep covers short and long
    // alphabets, low-probability cells, and zero runs of every length.
    var rng: DefaultPrng = .init(0xD3C2);
    const random = rng.random();
    var histogram: [256]u32 = undefined;
    var target: [256]u8 = undefined;
    // The sweep must actually reach every accuracy log and a wide spread of
    // symbol counts, or "every" in the test's name is a guess.
    var logs_seen: [accuracy_log_max + 1]bool = @splat(false);
    var shortest: u16 = symbol_count_max;
    var longest: u16 = 0;
    for (0..600) |_| {
        const max_symbol = random.uintLessThan(u16, 60) + 1;
        const total = random.uintLessThan(u32, 5000) + 2;
        var remaining = total;
        for (histogram[0 .. max_symbol + 1]) |*count| {
            const draw = random.uintLessThan(u32, 24);
            const value = if (draw < 16) 0 else random.uintLessThan(u32, remaining + 1);
            count.* = @min(value, remaining);
            remaining -= count.*;
        }
        if (remaining > 0) histogram[0] += remaining;
        var last: u16 = max_symbol;
        while (last > 0 and histogram[last] == 0) last -= 1;
        if (last == 0) continue;
        const accuracy_log = optimalAccuracyLog(9, total, last, 2);
        var norm: Norm = undefined;
        normalize(
            &norm,
            &histogram,
            total,
            last,
            accuracy_log,
            if (total >= 2048) .minus_one else .one,
        ) catch continue;
        logs_seen[accuracy_log] = true;
        shortest = @min(shortest, norm.symbol_count);
        longest = @max(longest, norm.symbol_count);
        const written = try writeDescription(&target, &norm);
        const description = try fse.readDescription(target[0..written], last, 9);
        try testing.expectEqual(accuracy_log, description.accuracy_log);
        try testing.expectEqual(norm.symbol_count, description.symbol_count);
        try testing.expectEqualSlices(
            i16,
            norm.counts[0..norm.symbol_count],
            description.counts[0..description.symbol_count],
        );
    }
    for (logs_seen[accuracy_log_min..]) |seen| try testing.expect(seen);
    try testing.expect(shortest <= 3);
    try testing.expect(longest >= 40);
}

test "the encode table's symbol column is the decoding table's" {
    // RFC 8878 §4.1.1 — the two tables are one construction seen from its two
    // sides: `buildTable`'s symbol column must equal `fse.buildTable`'s, and
    // `step` must be `fse.State.update`'s inverse — the source state's cell
    // holds the symbol, its Num_Bits is the transition's width, and the bits
    // are `destination - baseline`.
    var rng: DefaultPrng = .init(0x7AB1);
    const random = rng.random();
    var histogram: [256]u32 = undefined;
    for (0..200) |_| {
        const max_symbol = random.uintLessThan(u16, 30) + 1;
        const total = random.uintLessThan(u32, 3000) + 2;
        var remaining = total;
        for (histogram[0 .. max_symbol + 1]) |*count| {
            const draw = random.uintLessThan(u32, 16);
            const value = if (draw < 11) 0 else random.uintLessThan(u32, remaining + 1);
            count.* = @min(value, remaining);
            remaining -= count.*;
        }
        if (remaining > 0) histogram[0] += remaining;
        var last: u16 = max_symbol;
        while (last > 0 and histogram[last] == 0) last -= 1;
        if (last == 0) continue;
        const accuracy_log = optimalAccuracyLog(9, total, last, 2);
        var norm: Norm = undefined;
        normalize(
            &norm,
            &histogram,
            total,
            last,
            accuracy_log,
            if (total >= 2048) .minus_one else .one,
        ) catch continue;
        const table = buildTable(norm);
        const decoding = fse.buildTable(norm.counts[0..norm.symbol_count], accuracy_log);
        const table_size: u16 = @as(u16, 1) << @intCast(accuracy_log);
        // `next_states` is slot-indexed, and a symbol's slots are its cells
        // in state order: the symbol column is the decoding table's when
        // every slot's state carries its symbol (the C's `cumul[]`).
        var slot: u16 = 0;
        for (norm.counts[0..norm.symbol_count], 0..) |count, symbol| {
            if (count == 0) continue;
            const cells: u16 = if (count == -1) 1 else @intCast(count);
            for (0..cells) |_| {
                const state = table.next_states[slot] - table.bias;
                try testing.expectEqual(
                    @as(u8, @intCast(symbol)),
                    decoding.entries[state].symbol,
                );
                slot += 1;
            }
        }
        try testing.expectEqual(table_size, slot);
        for (norm.counts[0..norm.symbol_count], 0..) |count, symbol| {
            if (count == 0) continue;
            // The start state is the smallest state with the symbol.
            var first: u16 = table_size;
            for (0..table_size) |state| {
                if (decoding.entries[state].symbol == symbol) {
                    first = @intCast(state);
                    break;
                }
            }
            try testing.expectEqual(first, table.initState(@intCast(symbol)));
            for (0..table_size) |destination| {
                const transition = table.step(@intCast(destination), @intCast(symbol));
                const cell = decoding.entry(transition.state);
                try testing.expectEqual(@as(u8, @intCast(symbol)), cell.symbol);
                try testing.expectEqual(cell.num_bits, transition.bit_count);
                try testing.expectEqual(
                    @as(u32, @intCast(destination)) - cell.baseline,
                    transition.bits,
                );
            }
        }
    }
}

test "compressSymbols round-trips through readTree's weight decode" {
    // RFC 8878 §4.2.1.2 — "the series of weights is compressed using FSE":
    // the two-state stream through the decoder's own walk. The series must
    // complete to a power of two for `readTree` to accept it, so the sweep
    // builds valid ones directly: `k` weights of 1 and `m` of 2 with
    // `k + m` a power of two complete with an implied last weight, and their
    // deepest level (the weight-1 cells) is even and at least two.
    var rng: DefaultPrng = .init(0x515E);
    const random = rng.random();
    var series: [255]u8 = undefined;
    var histogram: [16]u32 = undefined;
    var target: [512]u8 = undefined;
    var description: [512]u8 = undefined;
    for (0..200) |_| {
        // A valid weight multiset: `ones` symbols of weight 1 and `twos` of
        // weight 2 with `ones + 2 * twos` a power of two, so the completion
        // gives an implied last weight and the deepest level is even.
        const power = random.uintLessThan(u4, 6) + 2; // the Kraft sum is 2^power
        const kraft = @as(usize, 1) << power;
        const ones = (random.uintLessThan(usize, @max(kraft / 4, 1)) + 1) * 2;
        const twos = (kraft - ones) / 2;
        const length = ones + twos;
        for (series[0..ones]) |*weight| weight.* = 1;
        for (series[ones..length]) |*weight| weight.* = 2;
        fastmem.set(u32, &histogram, 0);
        var max_symbol: u16 = 0;
        for (series[0..length]) |weight| {
            histogram[weight] += 1;
            if (weight > max_symbol) max_symbol = weight;
        }
        const accuracy_log = optimalAccuracyLog(6, @intCast(length), max_symbol, 1);
        var norm: Norm = undefined;
        try normalize(&norm, &histogram, @intCast(length), max_symbol, accuracy_log, .one);
        const table = buildTable(norm);
        const written = try writeDescription(&target, &norm);
        const stream = try compressSymbols(target[written..], series[0..length], &table);
        // The series as the decoder sees it: the length byte, the description,
        // the stream. `readTree` must recover the weights and the completion's
        // implied last weight (`§4.2.1`).
        description[0] = @intCast(written + stream);
        fastmem.copy(u8, description[1..][0 .. written + stream], target[0 .. written + stream]);
        const tree = try huff0.readTree(description[0 .. 1 + written + stream]);
        try testing.expectEqual(@as(u16, @intCast(length + 1)), tree.symbol_count);
        try testing.expectEqual(@as(u5, power + 1), tree.max_bits);
        try testing.expectEqualSlices(u8, series[0..length], tree.weights[0..length]);
    }
}

test "compressSymbols reproduces the reference encoder's weight stream" {
    // RFC 8878 §4.2.1.2 — the C's own `HUF_compressWeights` output: the
    // golden tree's weight series (122 weights, decoded from the reference
    // bytes) re-encoded must reproduce the reference's description and
    // stream byte for byte. This is the two-state writer pinned against the
    // CLI's bytes.
    const series = golden.weights_expected[0..golden.weights_expected.len];
    var histogram: [16]u32 = @splat(0);
    var max_symbol: u16 = 0;
    for (series) |weight| {
        histogram[weight] += 1;
        if (weight > max_symbol) max_symbol = weight;
    }
    const accuracy_log = optimalAccuracyLog(6, @intCast(series.len), max_symbol, 1);
    var norm: Norm = undefined;
    try normalize(&norm, &histogram, @intCast(series.len), max_symbol, accuracy_log, .one);
    const table = buildTable(norm);
    var target: [256]u8 = undefined;
    const written = try writeDescription(&target, &norm);
    const stream = try compressSymbols(target[written..], series, &table);
    // The reference's series bytes: `weights_description[0]` is the series
    // length, then the description and the stream.
    try testing.expectEqual(
        @as(usize, golden.weights_description[0]),
        written + stream,
    );
    try testing.expectEqualSlices(
        u8,
        golden.weights_description[1..],
        target[0 .. written + stream],
    );
    // And the reference's own tree comes back out.
    const tree = try huff0.readTree(&golden.weights_description);
    try testing.expectEqualSlices(
        u8,
        golden.weights_expected[0..],
        tree.weights[0..golden.weights_expected.len],
    );
}
