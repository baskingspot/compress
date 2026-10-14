//! The command stream (RFC 7932 §5, §9.3, §10): the insert-and-copy length
//! alphabet, the three block categories' switches (§6), the literal context
//! IDs (§7.1, §7.2), the distance element over §4's ring, and the execution
//! of literals and matches into the decoded window (§8's window/dictionary
//! class, §10's overlap rule).
//!
//! The command loop writes into a caller-owned linear window: for the
//! one-shot the decoded output *is* the match history (`§8`), so a match
//! reads back from `window[..pos]`. The streaming reader's ring wraps; its
//! slice instantiates `copyMatch` over contiguous segments and owns the wrap
//! and the resumability.
//!
//! The dictionary branch is §8's class boundary: a distance past the maximum
//! allowed distance resolves through `dictionary.transformedWord` (the word
//! table and the 121 transforms), and the transformed word writes like an
//! insert — its *produced* length is what §9.3's MLEN accounting counts.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const fastmem = @import("fastmem");

const bits = @import("bits.zig");
const context = @import("context.zig");
const decode = @import("decode.zig");
const dictionary = @import("dictionary.zig");
const distance = @import("distance.zig");
const frame = @import("frame.zig");
const golden = @import("golden.zig");
const huffman = @import("huffman.zig");
const internal = @import("../internal/root.zig");

/// The command layer's refusals.
pub const Error = error{
    /// §9.3 — the literals to insert, the copy length, or a dictionary
    /// word's length would exceed MLEN ("the stream should be rejected as
    /// invalid"). The reference reports it as `FORMAT_BLOCK_LENGTH_1` or
    /// `_2` depending on where the meta-block's accounting is checked; both
    /// are this class.
    BadBlockLength,
    /// §8 — a static dictionary reference's copy length is outside 4..24.
    BadDictionary,
};

/// The composed error set of the command stream for a bit source of `Bits`'s
/// kind: the bit reader's refusals, this layer's names, §4's, and the
/// dictionary layer's.
pub fn Errors(comptime Bits: type) type {
    return Bits.ErrorSet || Error || dictionary.Error || distance.Error;
}

// ---------------------------------------------------------------------------
// §5 — the insert-and-copy length alphabet
// ---------------------------------------------------------------------------

/// §5 — the insert length code table: the base length and extra bits of each
/// of the 24 insert codes.
const insert_base = [24]u32{
    0,  1,  2,  3,  4,   5,   6,   8,   10,   14,   18,   26,
    34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594,
};
const insert_extra = [24]u5{
    0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24,
};

/// §5 — the copy length code table, the same shape.
const copy_base = [24]u32{
    2,  3,  4,  5,  6,  7,   8,   9,   10,  12,  14,   18,
    22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118,
};
const copy_extra = [24]u5{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24,
};

/// §5 — one row of the RFC's insert-and-copy range table: the 64-symbol
/// range's start, the insert and copy length code bases, and whether the
/// range implies distance symbol 0.
const Range = struct {
    start: u16,
    insert: u5,
    copy: u5,
    implicit: bool,
};

/// §5's table, read off the RFC's diagram: the implicit-distance rows first
/// (0..127), then the rows that read a distance. Each range is 64 symbols:
/// "the copy length code within its range is determined by bits 0..2 ...
/// the insert length code within its range is determined by bits 3..5".
const ranges = [11]Range{
    .{ .start = 0, .insert = 0, .copy = 0, .implicit = true },
    .{ .start = 64, .insert = 0, .copy = 8, .implicit = true },
    .{ .start = 128, .insert = 0, .copy = 0, .implicit = false },
    .{ .start = 192, .insert = 0, .copy = 8, .implicit = false },
    .{ .start = 256, .insert = 8, .copy = 0, .implicit = false },
    .{ .start = 320, .insert = 8, .copy = 8, .implicit = false },
    .{ .start = 384, .insert = 0, .copy = 16, .implicit = false },
    .{ .start = 448, .insert = 16, .copy = 0, .implicit = false },
    .{ .start = 512, .insert = 8, .copy = 16, .implicit = false },
    .{ .start = 576, .insert = 16, .copy = 8, .implicit = false },
    .{ .start = 640, .insert = 16, .copy = 16, .implicit = false },
};

/// §5 — one command's lengths and its distance class.
pub const Command = struct {
    /// The insert length: literals to read before the copy.
    insert_length: u32,
    /// The copy length, 2..16779333.
    copy_length: u32,
    /// §5 — "If the insert-and-copy length code is between 0 and 127, the
    /// distance code of the command is set to zero (the last distance
    /// reused)": no distance element follows.
    implicit_distance: bool,
    /// §7.2 — the distance context ID from the copy length: "0, 1, 2, and 3
    /// for copy lengths 2, 3, 4, and more than 4".
    distance_context: u2,
};

/// §5, §9.3 — read one command: the insert-and-copy length symbol and both
/// extra-bit fields. The copy extra bits are read even when §9.3's
/// last-command rule will ignore the copy.
pub fn readCommand(
    comptime Bits: type,
    br: *Bits,
    tree: *const huffman.CommandTree,
) Bits.ErrorSet!Command {
    const symbol = try tree.decode(Bits, br);
    const range = ranges[symbol >> 6];
    assert(range.start == symbol & ~@as(u16, 63));
    const insert_code = range.insert + @as(u4, @intCast((symbol >> 3) & 7));
    const copy_code = range.copy + @as(u4, @intCast(symbol & 7));
    const insert_length = insert_base[insert_code] + try br.take(insert_extra[insert_code]);
    const copy_length = copy_base[copy_code] + try br.take(copy_extra[copy_code]);
    assert(copy_length >= 2);
    return .{
        .insert_length = insert_length,
        .copy_length = copy_length,
        .implicit_distance = range.implicit,
        .distance_context = @intCast(@min(copy_length - 2, 3)),
    };
}

// ---------------------------------------------------------------------------
// §7.1 — the context ID tables
// ---------------------------------------------------------------------------

/// §7.1's Lut0: the first byte's contribution to the UTF8 context ID. The
/// RFC's own table, pinned by its CRC-32 check value (0x8e91efb7).
const lut0 = [256]u8{
    0,  0,  0,  0,  0,  0,  0,  0,  0,  4,  4,  0,  0,  4,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    8,  12, 16, 12, 12, 20, 12, 16, 24, 28, 12, 12, 32, 12, 36, 12,
    44, 44, 44, 44, 44, 44, 44, 44, 44, 44, 32, 32, 24, 40, 28, 12,
    12, 48, 52, 52, 52, 48, 52, 52, 52, 48, 52, 52, 52, 52, 52, 48,
    52, 52, 52, 52, 52, 48, 52, 52, 52, 52, 52, 24, 12, 28, 12, 12,
    12, 56, 60, 60, 60, 56, 60, 60, 60, 56, 60, 60, 60, 60, 60, 56,
    60, 60, 60, 60, 60, 56, 60, 60, 60, 60, 60, 24, 12, 28, 12, 0,
    0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
    0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
    0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
    0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,  0,  1,
    2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
    2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
    2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
    2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,  2,  3,
};

/// §7.1's Lut1: the second byte's UTF8 contribution. CRC-32 0xd01a32f4.
const lut1 = [256]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1,
    1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1,
    1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 1, 1, 1, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
};

/// §7.1's Lut2, used twice by the Signed mode. CRC-32 0x0dd7a0d6.
const lut2 = [256]u8{
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 7,
};

/// §7.1 — the literal context ID. `p1` is the last uncompressed byte and
/// `p2` the one before it, "regardless of whether these bytes are produced
/// by uncompressed meta-blocks, backward references, static dictionary
/// references, or by literal insertions"; both are zero at the stream's
/// start. The result is in 0..63.
pub fn literalContext(mode: context.Mode, p1: u8, p2: u8) u6 {
    return switch (mode) {
        .lsb6 => @intCast(p1 & 0x3f),
        .msb6 => @intCast(p1 >> 2),
        .utf8 => @intCast(lut0[p1] | lut1[p2]),
        .signed => @intCast((lut2[p1] << 3) | lut2[p2]),
    };
}

// ---------------------------------------------------------------------------
// §6 — the block switches
// ---------------------------------------------------------------------------

/// §6 — the three categories' block-switch state for one meta-block: the
/// (previous, current) type pair per category and the current block's
/// remaining symbol count. "The previous and current block types are
/// initialized to 1 and 0, respectively, at the end of the meta-block
/// header."
// §10's pseudocode has the assignment reversed; the reference and this
// package follow §6, and the difference is visible on real bytes (the first
// switch's symbol 0 selects type 1, not 0) — see the register's T1.
pub const Blocks = struct {
    /// `[category][0]` is the previous block type, `[category][1]` the
    /// current.
    types: [3][2]u16 = .{ .{ 1, 0 }, .{ 1, 0 }, .{ 1, 0 } },
    /// The remaining symbol count of the current block, from the header's
    /// first count or a switch's count (`§6`, `§10`).
    counts: [3]u32,

    /// The header's first counts: BLEN = 16777216 for a single-type category
    /// (`§10`), so its count never reaches zero within a meta-block.
    pub fn init(header: *const frame.Header) Blocks {
        return .{ .counts = header.first_block_count };
    }

    /// The current block type of `cat`.
    fn current(self: *const Blocks, cat: frame.Category) u16 {
        return self.types[@intFromEnum(cat)][1];
    }
};

/// §6, §10 — consume one symbol of `cat`: read a block switch when the
/// current block's count is spent, then decrement.
fn consumeSymbol(
    comptime Bits: type,
    br: *Bits,
    header: *const frame.Header,
    blocks: *Blocks,
    cat: frame.Category,
) Errors(Bits)!void {
    const index = @intFromEnum(cat);
    if (blocks.counts[index] == 0) try switchBlock(Bits, br, header, blocks, cat);
    blocks.counts[index] -= 1;
}

/// §6 — resolve a block type symbol: 0 is the previous type, 1 the current
/// plus one ("if the current block type is the maximal possible, then a
/// block type symbol of 1 results in wrapping to a new block type of 0"),
/// and 2.. are the types 0..255. The type tree's declared alphabet is
/// NBLTYPES + 2, so the explicit symbols are always below the maximum and
/// only symbol 1 can wrap.
fn resolveBlockType(symbol: u16, previous: u16, current: u16, max_types: u16) u16 {
    var block_type: u32 = switch (symbol) {
        0 => previous,
        1 => current + 1,
        else => symbol - 2,
    };
    if (block_type >= max_types) block_type -= max_types;
    assert(block_type < max_types);
    return @intCast(block_type);
}

/// §6 — read a block switch: the type code, then the count code and its
/// extra bits. Symbol 0 selects the previous type, symbol 1 the current plus
/// one ("if the current block type is the maximal possible, then a block
/// type symbol of 1 results in wrapping to a new block type of 0"), and
/// 2..257 the types 0..255.
fn switchBlock(
    comptime Bits: type,
    br: *Bits,
    header: *const frame.Header,
    blocks: *Blocks,
    cat: frame.Category,
) Errors(Bits)!void {
    const index = @intFromEnum(cat);
    const max_types = header.block_types[index];
    if (max_types == 1) {
        // §9.3 — a single-type category's switch "appears only if
        // NBLTYPESx >= 2", and §10 gives it the count 16777216: one
        // meta-block cannot produce that many symbols, so this re-arm is
        // unreachable for any stream and keeps the count honest without
        // reading a switch that is not on the wire.
        blocks.counts[index] = 1 << 24;
        return;
    }
    const symbol = try header.trees.block_type[index].decode(Bits, br);
    const previous = blocks.types[index][0];
    const current = blocks.types[index][1];
    blocks.types[index][0] = current;
    blocks.types[index][1] = resolveBlockType(symbol, previous, current, max_types);
    blocks.counts[index] = try frame.readBlockCount(Bits, br, &header.trees.block_count[index]);
}

// ---------------------------------------------------------------------------
// §10 — the copy machinery
// ---------------------------------------------------------------------------

/// §10 — "move backwards distance bytes in the uncompressed data, and copy
/// CLEN bytes from this position to the uncompressed stream". A reference
/// may overlap the bytes it is writing: "if the last 2 bytes decoded have
/// values X and Y, a string reference with <length = 5, distance = 2> adds
/// X,Y,X,Y,X". The overlapping case replicates the `distance`-byte pattern,
/// so it is not `fastmem.move`: a move copies as through a temporary and
/// preserves the source, which is a different string.
///
/// `match_distance >= 1`, `match_distance <= pos`, and
/// `pos + length <= window.len` are the caller's guarantees; the match is a
/// window read, never a dictionary one (§8).
pub fn copyMatch(window: []u8, pos: usize, match_distance: u32, length: u32) void {
    assert(match_distance > 0);
    assert(match_distance <= pos);
    const back: usize = match_distance;
    const len: usize = length;
    assert(pos <= window.len);
    assert(len <= window.len - pos);

    if (back >= len) {
        fastmem.copy(u8, window[pos..][0..len], window[pos - back ..][0..len]);
        return;
    }
    if (back == 1) {
        // The one-byte run: every byte is the one before it.
        fastmem.set(u8, window[pos..][0..len], window[pos - 1]);
        return;
    }
    // Overlapping: write one period, then double the written region until
    // `len` bytes are out. Every copy's destination starts at or past its
    // source's end, so each is a plain `fastmem.copy`.
    fastmem.copy(u8, window[pos..][0..back], window[pos - back ..][0..back]);
    var written: usize = back;
    while (written < len) {
        const n = @min(written, len - written);
        fastmem.copy(u8, window[pos + written ..][0..n], window[pos..][0..n]);
        written += n;
    }
}

// ---------------------------------------------------------------------------
// §9.3, §10 — the command loop
// ---------------------------------------------------------------------------

/// The state that spans a meta-block's commands and, for the ring, the
/// stream: §4's four-distance ring, "initialized ... at the beginning of the
/// stream ... and it is not reset at meta-block boundaries", and the
/// distance tables the current meta-block's NPOSTFIX/NDIRECT derive.
pub const State = struct {
    ring: distance.Ring = .{},
    tables: distance.Tables = .{},
};

/// §9.3, §10 — decode one compressed meta-block's command stream into
/// `window`, whose `[0..start)` is the stream's decoded prefix (the match
/// history) and whose `[start..start + mlen)` is this meta-block's room.
/// Returns the position after the meta-block, `start + mlen`.
///
/// `start + mlen <= window.len` is the caller's guarantee: the one-shot
/// checks its target's cap before the call, so the MLEN accounting here is
/// §9.3's invalid-stream class, never a write past the caller's buffer.
pub fn decodeMetaBlock(
    comptime Bits: type,
    br: *Bits,
    header: *const frame.Header,
    state: *State,
    window: []u8,
    start: usize,
    mlen: u32,
    window_size: u32,
) Errors(Bits)!usize {
    assert(start <= window.len);
    assert(mlen <= window.len - start);
    state.tables.init(
        header.npostfix,
        header.ndirect,
        16 + @as(u16, header.ndirect) + (@as(u16, 48) << header.npostfix),
    );
    var blocks: Blocks = .init(header);
    var pos = start;
    const end = start + mlen;
    while (pos < end) {
        // §9.3 — the insert-and-copy block switch, before the length code.
        try consumeSymbol(Bits, br, header, &blocks, .command);
        const command = try readCommand(
            Bits,
            br,
            &header.trees.command[blocks.current(.command)],
        );

        // §9.3 — "if the number of literals to insert ... would cause MLEN
        // to be exceeded, then the stream should be rejected as invalid".
        if (command.insert_length > end - pos) return error.BadBlockLength;
        pos = try insertLiterals(Bits, br, header, &blocks, window, pos, command.insert_length);

        // §9.3 — "If the total number of uncompressed bytes produced after
        // the insert part of the last command equals MLEN, then the copy
        // length of the last command is ignored ... In this case, the copy
        // length of the last command can have any value": the distance
        // element is not read either.
        if (pos == end) break;

        pos = try applyCopy(
            Bits,
            br,
            header,
            &blocks,
            state,
            command,
            window,
            pos,
            end,
            window_size,
        );
    }
    assert(pos == end);
    return pos;
}

/// §9.3 — the insert half of a command: `insert_length` literals, each
/// decoded with the tree its literal block type and §7.1 context ID select.
/// The caller guarantees the room (`pos + insert_length <= window.len`) and
/// has checked the MLEN accounting.
fn insertLiterals(
    comptime Bits: type,
    br: *Bits,
    header: *const frame.Header,
    blocks: *Blocks,
    window: []u8,
    pos: usize,
    insert_length: u32,
) Errors(Bits)!usize {
    assert(pos <= window.len);
    assert(insert_length <= window.len - pos);
    var p = pos;
    var i: u32 = 0;
    while (i < insert_length) : (i += 1) {
        // §9.3 — the literal block switch, before each literal.
        try consumeSymbol(Bits, br, header, blocks, .literal);
        const block_type = blocks.current(.literal);
        const p1 = if (p >= 1) window[p - 1] else 0;
        const p2 = if (p >= 2) window[p - 2] else 0;
        const cid = literalContext(header.context.modes[block_type], p1, p2);
        const tree_index = header.context.literal_map[@as(usize, block_type) * 64 + cid];
        const literal = try header.trees.literal[tree_index].decode(Bits, br);
        window[p] = @intCast(literal);
        p += 1;
    }
    return p;
}

/// §9.3, §4, §8 — the copy half of a command: the distance element (unless
/// §5's implicit distance), §4's reconstruction, §8's window/dictionary
/// class, and §10's match or dictionary word. Returns the position after the
/// copy. `end` is the meta-block's end: the produced length — the copy length
/// or the transformed word's — is checked against it before any write, since
/// "the copy length, or the resulting dictionary word length would cause
/// MLEN to be exceeded" is invalid (§9.3).
fn applyCopy(
    comptime Bits: type,
    br: *Bits,
    header: *const frame.Header,
    blocks: *Blocks,
    state: *State,
    command: Command,
    window: []u8,
    pos: usize,
    end: usize,
    window_size: u32,
) Errors(Bits)!usize {
    assert(pos < end);
    assert(end <= window.len);
    // §8 — "a maximum backward distance value, which is the minimum of the
    // window size and the number of uncompressed bytes produced": the
    // command's literals are already out, so they count.
    const max_allowed: u32 = if (pos < window_size) @intCast(pos) else window_size;

    var symbol: u16 = 0;
    var resolved: u32 = undefined;
    if (command.implicit_distance) {
        // §5 — "the distance code of the command is set to zero (the last
        // distance reused)": no distance element is read.
        resolved = state.ring.get(3);
    } else {
        // §9.3 — the distance block switch, before the distance code, and
        // only when a distance is read (erratum 6977, T2).
        try consumeSymbol(Bits, br, header, blocks, .distance);
        const block_type = blocks.current(.distance);
        const tree_index = header.context.distance_map[
            @as(usize, block_type) * 4 + command.distance_context
        ];
        symbol = try header.trees.distance[tree_index].decode(Bits, br);
        if (symbol < 16) {
            resolved = try distance.special(&state.ring, symbol);
        } else {
            const dextra = try br.take(state.tables.extra_bits[symbol]);
            resolved = state.tables.resolve(symbol, dextra);
        }
    }

    if (resolved > max_allowed) {
        // §8 — a distance past the produced data "is treated as a reference
        // to a word in the static dictionary", and "the copy length for a
        // static dictionary reference must be between 4 and 24".
        if (command.copy_length < dictionary.min_word_len or
            command.copy_length > dictionary.max_word_len)
        {
            return error.BadDictionary;
        }
        var scratch: [dictionary.scratch_len]u8 = undefined;
        const word = try dictionary.transformedWord(
            &scratch,
            resolved - max_allowed - 1,
            command.copy_length,
        );
        // The reference's emptiness guard (`decode.c:2247`): a transform that
        // empties the word is invalid when the distance code is at most 120.
        // No RFC stream can reach it — the smallest emptying transform is
        // OmitFirst4 (id 34), so an emptied word's word_id is at least
        // 34 * 1024 — but the reference's reading is the port's.
        if (word.len == 0 and resolved <= 120) return error.BadTransform;
        if (word.len > end - pos) return error.BadBlockLength;
        fastmem.copy(u8, window[pos..][0..word.len], word);
        return pos + word.len;
    }

    if (command.copy_length > end - pos) return error.BadBlockLength;

    // §4, §10 — "if distance code is not zero, and distance is not a static
    // dictionary reference, push distance to the ring buffer of last
    // distances": an implicit distance is not a symbol and never pushes.
    if (!command.implicit_distance and symbol != 0) state.ring.push(resolved);

    copyMatch(window, pos, resolved, command.copy_length);
    return pos + command.copy_length;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "command stream: the RFC 7932 §5 insert-and-copy range table" {
    // RFC 7932 §5's diagram, at every range's corners: bits 0..2 are the
    // copy length code within its range, bits 3..5 the insert length code.
    const corners = [_]struct { symbol: u16, insert: u5, copy: u5, implicit: bool }{
        .{ .symbol = 0, .insert = 0, .copy = 0, .implicit = true },
        .{ .symbol = 63, .insert = 7, .copy = 7, .implicit = true },
        .{ .symbol = 64, .insert = 0, .copy = 8, .implicit = true },
        .{ .symbol = 127, .insert = 7, .copy = 15, .implicit = true },
        .{ .symbol = 128, .insert = 0, .copy = 0, .implicit = false },
        .{ .symbol = 191, .insert = 7, .copy = 7, .implicit = false },
        .{ .symbol = 192, .insert = 0, .copy = 8, .implicit = false },
        .{ .symbol = 255, .insert = 7, .copy = 15, .implicit = false },
        .{ .symbol = 256, .insert = 8, .copy = 0, .implicit = false },
        .{ .symbol = 319, .insert = 15, .copy = 7, .implicit = false },
        .{ .symbol = 320, .insert = 8, .copy = 8, .implicit = false },
        .{ .symbol = 383, .insert = 15, .copy = 15, .implicit = false },
        .{ .symbol = 384, .insert = 0, .copy = 16, .implicit = false },
        .{ .symbol = 447, .insert = 7, .copy = 23, .implicit = false },
        .{ .symbol = 448, .insert = 16, .copy = 0, .implicit = false },
        .{ .symbol = 511, .insert = 23, .copy = 7, .implicit = false },
        .{ .symbol = 512, .insert = 8, .copy = 16, .implicit = false },
        .{ .symbol = 575, .insert = 15, .copy = 23, .implicit = false },
        .{ .symbol = 576, .insert = 16, .copy = 8, .implicit = false },
        .{ .symbol = 639, .insert = 23, .copy = 15, .implicit = false },
        .{ .symbol = 640, .insert = 16, .copy = 16, .implicit = false },
        .{ .symbol = 703, .insert = 23, .copy = 23, .implicit = false },
    };
    for (corners) |corner| {
        const range = ranges[corner.symbol >> 6];
        try testing.expectEqual(corner.implicit, range.implicit);
        const insert = range.insert + @as(u4, @intCast((corner.symbol >> 3) & 7));
        const copy = range.copy + @as(u4, @intCast(corner.symbol & 7));
        try testing.expectEqual(corner.insert, insert);
        try testing.expectEqual(corner.copy, copy);
    }
}

test "block types: RFC 7932 §6's resolution and T1's ring init" {
    // §6 — "The previous and current block types are initialized to 1 and 0,
    // respectively, at the end of the meta-block header."
    var header: frame.Header = undefined;
    header.first_block_count = .{ 3, 4, 5 };
    const blocks = Blocks.init(&header);
    for (0..3) |cat| {
        try testing.expectEqual(@as(u16, 1), blocks.types[cat][0]);
        try testing.expectEqual(@as(u16, 0), blocks.types[cat][1]);
    }
    try testing.expectEqualSlices(u32, &[_]u32{ 3, 4, 5 }, &blocks.counts);

    // §6 — symbol 0 selects the previous type, symbol 1 the current + 1, and
    // 2.. the types 0..: with the header's (previous, current) = (1, 0) the
    // first switch's symbol 0 lands on type 1, not 0 (T1).
    try testing.expectEqual(@as(u16, 1), resolveBlockType(0, 1, 0, 4));
    try testing.expectEqual(@as(u16, 1), resolveBlockType(1, 1, 0, 4));
    try testing.expectEqual(@as(u16, 0), resolveBlockType(2, 1, 0, 4));
    try testing.expectEqual(@as(u16, 2), resolveBlockType(4, 1, 0, 4));
    // "If the current block type is the maximal possible, then a block type
    // symbol of 1 results in wrapping to a new block type of 0."
    try testing.expectEqual(@as(u16, 0), resolveBlockType(1, 2, 3, 4));
    try testing.expectEqual(@as(u16, 1), resolveBlockType(1, 2, 0, 4));
}

test "command stream: RFC 7932 §5's command decode" {
    // A single-symbol command tree: the symbol consumes no bits, so the
    // extra-bit fields are the only wire content. Symbol 8 is insert 1,
    // copy 2, implicit (the day-one fixture); symbol 423 is insert 4 and
    // copy 2118 with 24 copy extra bits; symbol 482 is insert 2000 with 10
    // insert extra bits.
    var packer: golden.Packer = .{};
    var br: bits.BitReader = .init(packer.slice());
    var tree: huffman.CommandTree = undefined;
    try tree.build(&[_]u4{0} ** 704);
    // A zero-length single-symbol tree is `single`, built by readTree's
    // simple form; here set it directly (the tree's `single` field).
    tree.single = 8;
    const one = try readCommand(bits.BitReader, &br, &tree);
    try testing.expectEqual(@as(u32, 1), one.insert_length);
    try testing.expectEqual(@as(u32, 2), one.copy_length);
    try testing.expect(one.implicit_distance);
    try testing.expectEqual(@as(u2, 0), one.distance_context);

    tree.single = 423;
    packer = .{};
    packer.pack(0, 24);
    br = .init(packer.slice());
    const wide = try readCommand(bits.BitReader, &br, &tree);
    try testing.expectEqual(@as(u32, 4), wide.insert_length);
    try testing.expectEqual(@as(u32, 2118), wide.copy_length);
    try testing.expect(!wide.implicit_distance);
    try testing.expectEqual(@as(u64, 24), br.bit_pos);

    tree.single = 482;
    packer = .{};
    packer.pack(910, 10);
    br = .init(packer.slice());
    const long = try readCommand(bits.BitReader, &br, &tree);
    try testing.expectEqual(@as(u32, 2000), long.insert_length);
    try testing.expectEqual(@as(u32, 4), long.copy_length);
    // §7.2 — copy length 4 is context ID 2.
    try testing.expectEqual(@as(u2, 2), long.distance_context);
}

test "command stream: RFC 7932 §5's length tables" {
    // The insert table's ranges (base, base + (1 << extra) - 1) are the
    // RFC's; the last one reaches the format's longest insert.
    try testing.expectEqual(@as(u32, 0), insert_base[0]);
    try testing.expectEqual(@as(u32, 22594), insert_base[23]);
    try testing.expectEqual(@as(u32, 16799809), insert_base[23] + (@as(u32, 1) << 24) - 1);
    // The copy table's: lengths 2..16779333.
    try testing.expectEqual(@as(u32, 2), copy_base[0]);
    try testing.expectEqual(@as(u32, 2118), copy_base[23]);
    try testing.expectEqual(@as(u32, 16779333), copy_base[23] + (@as(u32, 1) << 24) - 1);
}

test "context IDs: RFC 7932 §7.1's four modes" {
    // The formulas: LSB6 = p1 & 0x3f, MSB6 = p1 >> 2, UTF8 =
    // Lut0[p1] | Lut1[p2], Signed = (Lut2[p1] << 3) | Lut2[p2].
    try testing.expectEqual(@as(u6, 1), literalContext(.lsb6, 0x41, 0));
    try testing.expectEqual(@as(u6, 16), literalContext(.msb6, 0x41, 0));
    try testing.expectEqual(@as(u6, 48), literalContext(.utf8, 0x41, 0));
    try testing.expectEqual(@as(u6, 24), literalContext(.signed, 0x41, 0));
    // The stream start's (0, 0) is context 0 in every mode.
    for ([_]context.Mode{ .lsb6, .msb6, .utf8, .signed }) |mode| {
        try testing.expectEqual(@as(u6, 0), literalContext(mode, 0, 0));
    }
    // UTF8's second byte and Signed's shift are live: p2 = 0x80 is Lut1 0
    // and Lut2 4 (0x80 < 0xC0 is the continuation-byte row).
    try testing.expectEqual(@as(u6, 48), literalContext(.utf8, 0x41, 0x80));
    try testing.expectEqual(@as(u6, 24 + 4), literalContext(.signed, 0x41, 0x80));
}

test "context IDs: RFC 7932 §7.1's Lut tables by their Appendix C CRCs" {
    // RFC 7932 §7.1 — "The lengths and the CRC-32 check values (see
    // Appendix C) of each of these tables": 0x8e91efb7, 0xd01a32f4,
    // 0x0dd7a0d6.
    const crc = std.hash.crc.Crc32.hash;
    try testing.expectEqual(@as(u32, 0x8e91efb7), crc(&lut0));
    try testing.expectEqual(@as(u32, 0xd01a32f4), crc(&lut1));
    try testing.expectEqual(@as(u32, 0x0dd7a0d6), crc(&lut2));
}

test "command stream: RFC 7932 §10's overlap example in copyMatch" {
    // RFC 7932 §10 — "if the last 2 bytes decoded have values X and Y, a
    // string reference with <length = 5, distance = 2> adds X,Y,X,Y,X".
    var window: [16]u8 = @splat(0);
    fastmem.copy(u8, window[0..2], "XY");
    copyMatch(&window, 2, 2, 5);
    try testing.expectEqualSlices(u8, "XYXYXYX", window[0..7]);

    // Non-overlapping: an exact copy.
    fastmem.copy(u8, window[0..4], "abcd");
    copyMatch(&window, 4, 4, 4);
    try testing.expectEqualSlices(u8, "abcdabcd", window[0..8]);

    // The single-byte run.
    fastmem.set(u8, &window, 0);
    window[0] = 0x5A;
    copyMatch(&window, 1, 1, 15);
    for (window) |byte| try testing.expectEqual(@as(u8, 0x5A), byte);
}

test "command stream: every distance and length pair replicates §10's run" {
    // The overlap sweep against a byte-at-a-time reference: for every
    // distance 1..16 and length 1..40, the copy equals the LZ77 reading —
    // the forward byte loop that `copyMatch`'s doubling must reproduce.
    var want: [64]u8 = undefined;
    var got: [64]u8 = undefined;
    const pos = 16;
    for (1..17) |d| {
        for (1..41) |len| {
            for (&want, 0..) |*byte, i| byte.* = @intCast(i % 251);
            fastmem.copy(u8, &got, &want);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                want[pos + i] = want[pos + i - d];
            }
            copyMatch(&got, pos, @intCast(d), @intCast(len));
            try testing.expectEqualSlices(u8, want[0 .. pos + len], got[0 .. pos + len]);
        }
    }
}

test "command stream: the golden vectors decode byte-exact" {
    // Every hand-built vector was verified against the pinned CLI before
    // landing (brotli 1.2.0: `brotli -d -c`); the CLI-generated streams are
    // the encoder's own output. Each decode proves the sentinel: bytes past
    // the decoded length are untouched.
    const cases = [_]golden.Stream{
        golden.hand_stream,
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
        golden.cross_meta_block,
        golden.uncompressed_context,
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
    for (cases) |case| {
        var target: [4096]u8 = undefined;
        internal.sentinel.fill(&target);
        const n = try decode.decompress(case.bytes, &target);
        try testing.expectEqual(case.plain.len, n);
        try testing.expectEqualSlices(u8, case.plain, target[0..n]);
        try internal.sentinel.expect(&target, n);
    }
}

test "command stream: the CLI's own streams decode byte-exact" {
    // Generated by the pinned CLI (brotli 1.2.0) and stored with their
    // plaintext; the round trip is the encoder's own conformance evidence.
    // The text at q5 and up references the dictionary (F6): the encoder
    // emits dictionary words only on text, at q4 and up, so the text rows
    // are the dictionary port's live conformance streams.
    const cases = [_]golden.Stream{
        golden.cli_text_q1,
        golden.cli_text_q2,
        golden.cli_text_q5,
        golden.cli_text_q9,
        golden.cli_text_q11,
        golden.cli_repeat_q5,
        golden.cli_repeat_q11,
        golden.cli_run_q9,
        golden.cli_digits_q5,
        golden.cli_digits_q11,
    };
    for (cases) |case| {
        var target: [4096]u8 = undefined;
        internal.sentinel.fill(&target);
        const n = try decode.decompress(case.bytes, &target);
        try testing.expectEqual(case.plain.len, n);
        try testing.expectEqualSlices(u8, case.plain, target[0..n]);
        try internal.sentinel.expect(&target, n);
    }
}

test "command stream: RFC 7932 §9.3's MLEN accounting refusals" {
    // RFC 7932 §9.3 — "In any other case, if the number of literals to
    // insert, the copy length, or the resulting dictionary word length would
    // cause MLEN to be exceeded, then the stream should be rejected as
    // invalid." The CLI reports FORMAT_BLOCK_LENGTH_2 (-10) for both (F4).
    var target: [64]u8 = undefined;
    internal.sentinel.fill(&target);
    try testing.expectError(
        error.BadBlockLength,
        decode.decompress(golden.mlen_insert_overrun.bytes, &target),
    );
    try testing.expectError(
        error.BadBlockLength,
        decode.decompress(golden.mlen_copy_overrun.bytes, &target),
    );

    // RFC 7932 §4 — a special code resolving to zero (the CLI's
    // FORMAT_DISTANCE (-16)).
    try testing.expectError(
        error.BadDistance,
        decode.decompress(golden.negative_special.bytes, &target),
    );
}

test "command stream: RFC 7932 §8's dictionary class refusals" {
    // A length outside 4..24 is the CLI's FORMAT_DICTIONARY (-12), and a
    // transform id above 120 the CLI's FORMAT_TRANSFORM (-11); both vectors
    // were verified with the pinned CLI (`brotli -d -v -c`).
    var target: [4096]u8 = undefined;
    internal.sentinel.fill(&target);
    try testing.expectError(
        error.BadDictionary,
        decode.decompress(golden.dictionary_length.bytes, &target),
    );
    try testing.expectError(
        error.BadTransform,
        decode.decompress(golden.dictionary_transform.bytes, &target),
    );
}
