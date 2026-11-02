//! flate.Reader: a decompressing `Io.Reader` over a raw deflate stream
//! (RFC 1951), such as the one `Writer` produces. It decodes straight from
//! `input` into a caller-provided 64-KiB window and allocates nothing.
//! `streamAll` pumps a whole stream in one call.
//!
//! The stream ends with `error.EndOfStream` after the last output byte. A
//! malformed stream or a failing `input` gives `error.ReadFailed`, with the
//! cause in `err`. Both are sticky: later reads repeat the result. The reader
//! consumes `input` exactly through the stream's last byte (the final block's
//! padded partial byte included) and leaves later bytes unread, so a
//! container can read its trailer from the same `input`.
//!
//! The window keeps the last 32 KiB of output as match history (`§3.2.3`), so
//! a contiguous request (`peek`, `take`) is guaranteed only up to 32 KiB. A
//! larger one that does not fit at the consumer's position returns
//! `error.ReadFailed` with `err == .StreamTooLong`. A preset dictionary
//! (`init`'s `dict`) is copied into the window in front of the output and
//! counts as history until the output slides it out.
//!
//! Format: docs/specs/rfc1951-deflate.txt

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;
const print = std.debug.print;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const State = internal.reader.State;
const VTable = internal.reader.VTable;
const common = @import("common.zig");
const readVarInt = common.readVarInt;
const readInt = common.readInt;
/// The checksum hook's type: a container's state plus its byte-fold function
/// (`Checksum.zig`). It is re-exported here so a container can name it
/// through this namespace (one type across build modules) and assign it to
/// `checksum` before the first read.
pub const Checksum = @import("Checksum.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const history_len = encode.history_len;
const max_block_size = encode.max_block_size;
const golden = @import("golden.zig");
const Writer = @import("Writer.zig");

/// `§3.2.5` — the longest match a symbol can declare (length code 285 is
/// 258), so the decoder stops this far short of a full window. The constant
/// lives with the code tables (decode.zig) and is aliased here.
const max_match_len = decode.max_match_len;

/// The widest peek any read takes: 16 bits, the stored block's LEN or NLEN
/// (`§3.2.4`). The Huffman tables peek at most 15.
const max_peek_bits: u6 = 16;

/// The caller-provided decode window, 2 * `history_len` = 64 KiB. The last
/// `history_len` bytes are the match history (`§3.2.3`) and the rest is fresh
/// output; a preset dictionary is copied into the window's front before the
/// first read, so it is history too. The reader keeps no other buffer of
/// decoded or compressed bytes.
pub const Buffer = [2 * history_len]u8;

/// The cause recorded in `Reader.err` beside the interface's coarse
/// `error.ReadFailed`. It holds every `decode.DecompressError` except
/// `BufferTooSmall` (the reader owns its window, so output cannot outgrow it),
/// plus the three below. `EndOfStream` is the clean end of the stream and is
/// never recorded in `err`.
pub const Error = error{
    Truncated,
    InvalidBlockType,
    WrongStoredBlockNlen,
    InvalidDynamicBlockHeader,
    OversubscribedHuffmanTree,
    IncompleteHuffmanTree,
    MissingEndOfBlockCode,
    InvalidCode,
    InvalidMatch,
    /// A contiguous request that the window cannot hold at the consumer's
    /// position.
    StreamTooLong,
    /// Reading `input` failed.
    ReadFailed,
    EndOfStream,
};

/// `Error` under a second name, for `Bits.ErrorSet`.
const ReaderError = Error;

/// Where the decoder is in the block structure (`§3.2.3`): a resume point, so
/// a window that fills mid-block picks up exactly where it stopped.
const Phase = union(enum) {
    /// BFINAL and BTYPE are next.
    block_header,
    /// Copying a stored block's payload: `remaining` bytes left (`§3.2.4`).
    stored_block: u16,
    /// Decoding symbols from a fixed-Huffman block (`§3.2.6`).
    fixed_block,
    /// A fixed block's match length is decoded; its distance is next.
    fixed_match: u16,
    /// Decoding symbols from a dynamic-Huffman block (`§3.2.7`).
    dynamic_block,
    /// A dynamic block's match length is decoded; its distance is next.
    dynamic_match: u16,
};

/// The bit reader (`§3.1.1`): LSB-first fill, straight from the input
/// `Io.Reader`. A Huffman block carries no compressed length, so there is
/// nothing to stage; the decoder reads bits as it needs them.
///
/// `input`'s position advances only in whole consumed bytes: `consumed` counts
/// the bits already consumed in the byte at the input's position, so a peek
/// never consumes and the stream's last partial byte is consumed exactly once
/// (`finish`). That is what makes the stream boundary exact.
const Bits = struct {
    /// The error set this bit source produces: the Reader's own, whose reads
    /// can fail. The tree machinery in decode.zig is generic over it.
    pub const ErrorSet = ReaderError;

    input: *Io.Reader,
    /// Bits already consumed in the byte at `input`'s position (0-7).
    consumed: u3 = 0,

    /// The next `n` bits, LSB-of-value first, buffering first. Bits past the
    /// end of the input read as zero; `take` is the gate that turns that into
    /// `error.Truncated`, so a truncated stream can never decode a symbol out
    /// of padding (decode.zig's rule). Public with `take` because decode.zig's
    /// tree machinery is generic over the bit source.
    pub fn peek(self: *Bits, n: u6) ErrorSet!u64 {
        assert(n <= max_peek_bits);
        try self.bufferBits(n);
        const buffered = self.input.buffer[self.input.seek..self.input.end];
        const window = if (buffered.len >= 8)
            readInt(u64, buffered[0..8])
        else
            readVarInt(u64, buffered[0..@min(buffered.len, 8)]);
        return (window >> self.consumed) & ((@as(u64, 1) << n) - 1);
    }

    /// Consume `n` bits. `error.Truncated` when the input ends first.
    pub fn take(self: *Bits, n: u6) ErrorSet!u64 {
        if (!try self.hasBits(n)) return error.Truncated;
        const value = try self.peek(n);
        self.consume(n);
        return value;
    }

    /// True when the next `n` bits exist in the input.
    fn hasBits(self: *Bits, n: u6) ErrorSet!bool {
        try self.bufferBits(n);
        return self.available() >= n;
    }

    /// Bits of the input not yet consumed, as far as the buffer shows.
    fn available(self: *const Bits) u64 {
        return @as(u64, self.input.end - self.input.seek) * 8 - self.consumed;
    }

    /// Buffer the bytes the next `n` bits come from, when the input has them.
    /// A short input is not an error here: `peek` zero-extends past it and
    /// `take` reports the shortage as `error.Truncated`.
    fn bufferBits(self: *Bits, n: u6) ErrorSet!void {
        const need = (@as(usize, self.consumed) + n + 7) / 8;
        if (self.input.end - self.input.seek >= need) return;
        self.input.fill(need) catch |err| switch (err) {
            error.EndOfStream => {},
            error.ReadFailed => return error.ReadFailed,
        };
    }

    /// Consume `n` bits (the caller has checked availability): whole consumed
    /// bytes leave `input`, the partial byte's consumed bits stay counted.
    fn consume(self: *Bits, n: u6) void {
        const total: u6 = self.consumed + n;
        self.input.toss(total / 8);
        self.consumed = @intCast(total % 8);
    }

    /// Skip to the next byte boundary: "any bits of input up to the next byte
    /// boundary are ignored" (`§3.2.4`). A decoder must not require the
    /// skipped bits to be zero.
    fn alignToByte(self: *Bits) ErrorSet!void {
        const skip: u6 = (8 - @as(u6, self.consumed)) % 8;
        if (skip != 0) _ = try self.take(skip);
    }

    /// The stream's last byte: the final block ends mid-byte and the format
    /// pads it (`§3.1.1`), so that byte belongs to the stream and the bytes
    /// after it do not.
    fn finish(self: *Bits) void {
        if (self.consumed == 0) return;
        assert(self.input.seek < self.input.end);
        self.input.toss(1);
        self.consumed = 0;
    }
};

/// A bit source over the bytes `input` already buffers, for a dynamic
/// block's header (`§3.2.7`): `Bits` checks the input and may fill it on
/// every read, which costs a small image as much as its pixels. It never
/// reads past the buffered bytes: a read that needs more is
/// `error.Truncated`, and the caller decodes the header again through
/// `Bits`, which fills. Every other error is the stream's, since every bit
/// it looked at was real.
const BufferedBits = struct {
    pub const ErrorSet = ReaderError;

    bytes: []const u8,
    /// Unconsumed bits, the next on the wire in bit 0. Bits above `count`
    /// are 0 or the next bits of `bytes`, so a refill's OR keeps them.
    bits: u64,
    /// Valid bits in `bits`.
    count: u32,
    /// The first byte of `bytes` not yet counted in `bits`.
    next: usize,

    fn init(b: *const Bits) BufferedBits {
        var self: BufferedBits = .{
            .bytes = b.input.buffer[b.input.seek..b.input.end],
            .bits = 0,
            .count = 0,
            .next = 0,
        };
        self.refill();
        const skip = @min(b.consumed, self.count);
        self.bits >>= @intCast(skip);
        self.count -= skip;
        return self;
    }

    /// Top `bits` up from `bytes`: eight bytes in one load while that many
    /// remain, byte by byte at the end. The header's symbols then decode
    /// from a register, not from a fresh load at a bit offset.
    fn refill(self: *BufferedBits) void {
        if (self.bytes.len - self.next >= 8) {
            self.bits |= readInt(u64, self.bytes[self.next..][0..8]) << @intCast(self.count);
            self.next += (63 - self.count) >> 3;
            self.count |= 56;
            return;
        }
        while (self.count <= 56 and self.next < self.bytes.len) {
            self.bits |= @as(u64, self.bytes[self.next]) << @intCast(self.count);
            self.next += 1;
            self.count += 8;
        }
    }

    pub fn peek(self: *BufferedBits, n: u6) ErrorSet!u64 {
        if (self.count < n) {
            self.refill();
            if (self.count < n) return error.Truncated;
        }
        return self.bits & ((@as(u64, 1) << n) - 1);
    }

    pub fn take(self: *BufferedBits, n: u6) ErrorSet!u64 {
        const value = try self.peek(n);
        self.bits >>= n;
        self.count -= n;
        return value;
    }

    /// Consume from `b` what this source consumed.
    fn commit(self: *const BufferedBits, b: *Bits) void {
        const used = self.next * 8 - self.count;
        b.input.toss(used / 8);
        b.consumed = @intCast(used % 8);
    }
};

const Reader = @This();

/// The `Io.Reader` interface: read the decoded bytes through `&r.reader`.
reader: Io.Reader,
bits: Bits,
/// Optional checksum hook, handed the decoded bytes as they enter the window
/// (literal stores, match copies, stored-block copies), each exactly once and
/// in stream order. A preset dictionary's bytes are not decoded output and
/// are never handed to it. A container sets it before the first read: a hook
/// set mid-stream sees only the bytes decoded after it. The container reads
/// its own state after `error.EndOfStream`; after `error.ReadFailed` the
/// digest is incomplete. Null costs one check per window fill and nothing per
/// byte. This module writes no trailer.
checksum: ?Checksum = null,
phase: Phase,
/// `§3.2.3` — "a distance cannot refer past the beginning of the output
/// stream" is a stream-wide rule, not a window one, so the total decoded
/// length is tracked beside the window's.
total_out: u64,
/// Whether the current block is the stream's last (`§3.2.3`).
final: bool,
/// The dynamic block's tables (`§3.2.7`), rebuilt per block.
literal: decode.LitDecoder,
distance: decode.DistDecoder,
/// The stream lifecycle (src/internal/reader.zig): `streaming` until the
/// final block's output is complete (`done`) or a failure sticks (`failed`,
/// details in `err`).
state: State,
/// Detailed error once `state == .failed`; the interface reports
/// `error.ReadFailed`.
err: ?Error = null,

/// The `Io.Reader` vtable, generated by `internal.reader.VTable`. The
/// generated entries own the sticky-state check and the zero-length poll;
/// `fill` decodes more output into the window and `rebase` makes room when a
/// request needs it.
const vtable = VTable(Reader, fill, rebase).vtable;

/// Start reading the raw deflate stream in `input`, with `buffer` as the
/// decode window. Read the decoded bytes through `&r.reader` (`stream`, the
/// `read` and `peek` families).
///
/// `dict` is the stream's preset dictionary or `null` (`§3.2.3`): its last
/// 32 KiB are copied into the window in front of the output, so a distance can
/// reach into them until the output pushes them out of the 32-KiB window. Raw
/// deflate names no dictionary, so the caller vouches for the bytes; zlib's
/// FDICT/DICTID is the checked form (RFC 1950 §2.2). A dictionary longer than
/// 32 KiB contributes only its last 32 KiB.
///
/// The stream ends with `error.EndOfStream` once the final block's output has
/// been consumed. A malformed stream or a failing `input` returns
/// `error.ReadFailed`, with the cause in `err`. Both outcomes are sticky: later
/// reads repeat the result.
///
/// `input`'s own buffer must hold at least 3 bytes: a 16-bit peek (a stored
/// block's LEN or NLEN) can start up to 7 bits into a byte, so it spans 3
/// bytes. An `Io.Reader.fixed` over a shorter slice is fine, since it already
/// holds the whole stream.
pub fn init(input: *Io.Reader, buffer: *Buffer, dict: ?[]const u8) Reader {
    const history = decode.dictHistory(dict);
    fastmem.copy(u8, buffer[0..history.len], history);
    return .{
        .reader = .{
            .buffer = buffer,
            .seek = history.len,
            .end = history.len,
            .vtable = &vtable,
        },
        .bits = .{ .input = input },
        .phase = .block_header,
        // The dictionary is decoded history for the reach check (`§3.2.3`):
        // a distance may reach into it before the output has produced
        // anything, and the window slides it out naturally.
        .total_out = history.len,
        .final = false,
        .literal = .{},
        .distance = .{},
        .state = .streaming,
    };
}

/// Decode into the window until it has no room for another symbol, or the
/// stream ends. Returns the bytes added — never zero without an error: a
/// caller that needs more either gets them or gets a failure.
fn fillWindow(r: *Reader) Error!usize {
    var added: usize = 0;
    // The checksum hook's mark: everything before it is already folded into
    // the container's state. Bytes enter the window only at `reader.end` (the
    // literal store, the match copy, the stored-block copy, all inside
    // `step`), so the pending bytes are one contiguous run at the window's
    // tail, in stream order. The run is flushed before a slide drops its
    // head and before this call returns, so the digest is exact whenever the
    // window is quiescent, in particular at `error.EndOfStream`, where a
    // container reads it. One hook call per window fill, never one per
    // symbol.
    var hashed_end = r.reader.end;
    while (r.state == .streaming) {
        // Room for the next write: a match may declare up to 258 bytes
        // (`§3.2.5`), so the decoder stops this far short of a full window and
        // slides the retained history forward. That is what guarantees a
        // contiguous request of `history_len` bytes: when the consumer holds no
        // more than that unconsumed, a slide leaves at least that much free.
        if (r.reader.buffer.len - r.reader.end < max_match_len) {
            r.flushChecksum(&hashed_end);
            const room = r.slide();
            hashed_end = r.reader.end;
            if (room < max_match_len) {
                // The window cannot take another symbol: the consumer has not
                // drained enough, so a request that needs more room returns
                // `error.StreamTooLong` instead of asserting.
                if (added == 0) return error.StreamTooLong;
                return added;
            }
        }
        added += try r.step();
    }
    r.flushChecksum(&hashed_end);
    if (added == 0) return error.EndOfStream;
    return added;
}

/// Hand the bytes decoded since the last flush to the checksum hook: one
/// contiguous run, in stream order, each byte exactly once. A no-op when the
/// hook is unset or the run is empty (the window is quiescent), which is what
/// keeps the raw module's cost at one check per window fill.
fn flushChecksum(r: *Reader, hashed_end: *usize) void {
    const checksum = r.checksum orelse return;
    if (hashed_end.* == r.reader.end) return;
    checksum.update(r.reader.buffer[hashed_end.*..r.reader.end]);
    hashed_end.* = r.reader.end;
}

/// Slide the window forward: keep the unconsumed bytes and the retained
/// history (`§3.2.3`'s 32-KiB reach), drop the rest. Returns the free space
/// afterwards.
fn slide(r: *Reader) usize {
    const seek = r.reader.seek;
    const end = r.reader.end;
    const unconsumed = end - seek;
    const keep = @max(unconsumed, @min(end, history_len));
    fastmem.move(u8, r.reader.buffer[0..keep], r.reader.buffer[end - keep ..][0..keep]);
    r.reader.seek = keep - unconsumed;
    r.reader.end = keep;
    return r.reader.buffer.len - keep;
}

/// One step of the decode: a block header, one symbol, or one stored chunk.
/// Returns the bytes added to the window (0 for a header or a block end). The
/// caller guarantees room for one symbol.
fn step(r: *Reader) Error!usize {
    switch (r.phase) {
        .block_header => {
            // §3.2.3 — BFINAL, then BTYPE, two bits LSB-of-value first.
            r.final = (try r.bits.take(1)) != 0;
            const block_type: decode.BlockType = @enumFromInt(
                @as(u2, @intCast(try r.bits.take(2))),
            );
            switch (block_type) {
                .stored => try r.readStoredHeader(),
                .fixed => r.phase = .fixed_block,
                .dynamic => {
                    try @call(.never_inline, readDynamicHeader, .{r});
                    r.phase = .dynamic_block;
                },
                .reserved => return error.InvalidBlockType,
            }
            return 0;
        },
        .stored_block => |remaining| return r.copyStored(remaining),
        else => return r.decodeSymbols(),
    }
}

/// `§3.2.7` — a dynamic block's header, from the buffered input when it
/// holds the whole header, and through `Bits` otherwise.
fn readDynamicHeader(r: *Reader) Error!void {
    var buffered: BufferedBits = .init(&r.bits);
    if (decode.readDynamicHeader(BufferedBits, &buffered, &r.literal, &r.distance)) |_| {
        buffered.commit(&r.bits);
    } else |err| switch (err) {
        error.Truncated => try decode.readDynamicHeader(Bits, &r.bits, &r.literal, &r.distance),
        else => return err,
    }
}

/// `§3.2.4` — a stored block: byte-aligned, LEN and NLEN (u16 little-endian,
/// NLEN the one's complement of LEN), then LEN raw bytes. At the byte
/// boundary the header is the next 32 bits LSB-first (`§3.1.1`), and the
/// payload follows at the next byte boundary.
fn readStoredHeader(r: *Reader) Error!void {
    try r.bits.alignToByte();
    const len: u16 = @intCast(try r.bits.take(16));
    const nlen: u16 = @intCast(try r.bits.take(16));
    if (len != ~nlen) return error.WrongStoredBlockNlen;
    r.phase = .{ .stored_block = len };
}

/// Copy the rest of a stored block's payload into the window, as much as fits:
/// the window slides and the copy resumes, so a block of any size decodes
/// without staging (`§3.2.4`, `§3.3`). A payload cut short is
/// `error.Truncated`.
fn copyStored(r: *Reader, remaining: u16) Error!usize {
    if (remaining == 0) {
        try r.endBlock();
        return 0;
    }
    const input = r.bits.input;
    if (input.seek == input.end) {
        input.fill(1) catch |err| switch (err) {
            error.EndOfStream => return error.Truncated,
            error.ReadFailed => return error.ReadFailed,
        };
    }
    const buffered = input.buffer[input.seek..input.end];
    const free = r.reader.buffer.len - r.reader.end;
    const copied = @min(@min(@as(usize, remaining), free), buffered.len);
    assert(copied > 0);
    fastmem.copy(u8, r.reader.buffer[r.reader.end..][0..copied], buffered[0..copied]);
    input.toss(copied);
    r.reader.end += copied;
    r.total_out += copied;
    r.phase = .{ .stored_block = remaining - @as(u16, @intCast(copied)) };
    return copied;
}

/// One symbol of a Huffman block (`§3.2.7`): a literal, a match whose length
/// is decoded here and whose distance is the next step, or the end-of-block
/// code. The block kind is in `phase`, so the resume point survives a slide.
fn decodeSymbols(r: *Reader) Error!usize {
    switch (r.phase) {
        .fixed_match => |length| return r.copyMatchStep(length, true),
        .dynamic_match => |length| return r.copyMatchStep(length, false),
        else => {},
    }
    if (r.fastPathReady()) return r.fastSymbols();
    const fixed = r.phase == .fixed_block;
    const literal = if (fixed) &decode.fixed_literal else &r.literal;
    const symbol = try literal.decode(Bits, &r.bits);
    if (symbol < 256) {
        r.reader.buffer[r.reader.end] = @intCast(symbol);
        r.reader.end += 1;
        r.total_out += 1;
        return 1;
    }
    if (symbol == 256) {
        // §3.2.7 — every block is terminated by the end-of-block symbol.
        try r.endBlock();
        return 0;
    }
    // §3.2.6: values 286-287 "will never actually occur in the compressed
    // data, but participate in the code construction".
    if (symbol > 285) return error.InvalidCode;
    const length = try decode.decodeLength(Bits, &r.bits, symbol);
    r.phase = if (fixed)
        .{ .fixed_match = @intCast(length) }
    else
        .{ .dynamic_match = @intCast(length) };
    return 0;
}

/// The input bytes the fast path needs buffered: one refill's 8-byte load
/// past the bytes already loaded. Below this, symbols take the slow path.
const fast_input_len = 16;
/// The window room the fast path needs: the longest match (`§3.2.5`), the
/// 16 bytes its chunked copy may write past the match's end, and the three
/// literals before it from the same refill.
const fast_room = max_match_len + 16 + 8;

/// Whether `fastSymbols` can run: the input has `fast_input_len` bytes
/// buffered and the window has `fast_room` free.
fn fastPathReady(r: *const Reader) bool {
    const input = r.bits.input;
    return input.end - input.seek >= fast_input_len and
        r.reader.buffer.len - r.reader.end >= fast_room;
}

/// The fast path through a Huffman block (`§3.2.7`): whole symbols, matches
/// included, decoded from a local 64-bit bit buffer loaded straight from the
/// input's buffered bytes, until the block ends, the input has fewer than
/// `fast_input_len` bytes left to load, or the window has less than
/// `fast_room` free. It stops only between symbols, writes `input`'s
/// position and `bits.consumed` back exactly, and checks what the slow path
/// checks, so the two decode the same streams the same way. Returns the
/// bytes added.
fn fastSymbols(r: *Reader) Error!usize {
    const fast = decode.fast;
    const lit_exceptional = fast.exceptional(.literal_length);
    const dist_exceptional = fast.exceptional(.distance);
    const input = r.bits.input;
    const fixed = r.phase == .fixed_block;
    const literal = if (fixed) &decode.fixed_literal else &r.literal;
    const distance = if (fixed) &decode.fixed_distance else &r.distance;
    const in = input.buffer[input.seek..input.end];
    const out = r.reader.buffer;
    const start = r.reader.end;
    var end = start;
    // The bit buffer holds `count` valid bits; `in` up to `ip` is loaded. Each
    // refill tops it up to at least 56 bits, enough for the widest symbol:
    // a 15-bit length code, 5 extra bits, a 15-bit distance code, and 13
    // extra bits. Bits above `count` are 0 or the next input bits, so the
    // OR of the next load leaves them as they are, and a refill never
    // changes the bits below `count`.
    var bits: u64 = readInt(u64, in[0..8]);
    // `ip` is the first input byte not yet counted in `bits`: a cursor
    // rather than an index, so the loop keeps no base pointer for `in`
    // live beside it. Every load of `ip[0..8]` follows a check that `ip`
    // is at most `in_last`, which keeps the load inside `in`.
    var ip: [*]const u8 = in.ptr + 7;
    var count: u32 = 56;
    bits >>= r.bits.consumed;
    count -= r.bits.consumed;
    var ended = false;
    // The output so far is `reach +% end` bytes.
    const reach = r.total_out -% start;
    // A refill loads `ip[0..8]`; a symbol may write `fast_room` bytes.
    // `fastPathReady` checked both once.
    const in_last = @intFromPtr(in.ptr) + in.len - 8;
    const out_last = out.len - fast_room;
    while (@intFromPtr(ip) <= in_last and end <= out_last) {
        bits |= readInt(u64, ip[0..8]) << @truncate(count);
        ip += (63 - count) >> 3;
        count |= 56;
        var e = literal.lookup[@intCast(bits & decode.LitDecoder.mask)];
        if (e & fast.literal != 0) {
            // Up to four literals from one refill: photographs are mostly
            // runs of literals. A literal decoded here has a code in the
            // primary table, at most 11 bits, so after three there are 23
            // bits left, enough to look up and resolve the next code.
            bits >>= @intCast(e & 0xF);
            count -= e & 0xF;
            out[end] = @truncate(e >> 4);
            end += 1;
            e = literal.lookup[@intCast(bits & decode.LitDecoder.mask)];
            if (e & fast.literal != 0) {
                bits >>= @intCast(e & 0xF);
                count -= e & 0xF;
                out[end] = @truncate(e >> 4);
                end += 1;
                e = literal.lookup[@intCast(bits & decode.LitDecoder.mask)];
                if (e & fast.literal != 0) {
                    bits >>= @intCast(e & 0xF);
                    count -= e & 0xF;
                    out[end] = @truncate(e >> 4);
                    end += 1;
                    e = literal.lookup[@intCast(bits & decode.LitDecoder.mask)];
                    if (e & fast.literal != 0) {
                        bits >>= @intCast(e & 0xF);
                        count -= e & 0xF;
                        out[end] = @truncate(e >> 4);
                        end += 1;
                        continue;
                    }
                }
            }
            // A length and its distance take up to 48 bits. The entry stays
            // valid across the refill, which only adds bits above `count`.
            if (count < 48) {
                if (@intFromPtr(ip) > in_last) break;
                bits |= readInt(u64, ip[0..8]) << @truncate(count);
                ip += (63 - count) >> 3;
                count |= 56;
            }
        }
        if (e & lit_exceptional != 0) {
            const code_len: u6 = @intCast(e & 0xF);
            if (code_len != 0) {
                // §3.2.6: values 286-287 never occur in the compressed data.
                if ((e >> 4) & 0xFFF != 256) return error.InvalidCode;
                bits >>= code_len;
                count -= code_len;
                ended = true;
                break;
            }
            // A code longer than the table's index, or none.
            const res = literal.resolve(bits) orelse return error.InvalidCode;
            e = fast.entry(.literal_length, res.symbol, @intCast(res.len));
            if (e & fast.literal != 0) {
                bits >>= @intCast(e & 0xF);
                count -= e & 0xF;
                out[end] = @truncate(e >> 4);
                end += 1;
                continue;
            }
            if (e & lit_exceptional != 0) {
                if (res.symbol != 256) return error.InvalidCode;
                bits >>= @intCast(res.len);
                count -= @intCast(res.len);
                ended = true;
                break;
            }
        }
        const len_total: u6 = @intCast((e >> 16) & 0x1F);
        // `len_total` is at most 20 bits, so the truncation keeps them all.
        const len_extra: u32 = @truncate(low(bits, len_total) >> @intCast(e & 0xF));
        const len: usize = (e >> 21) + len_extra;
        bits >>= len_total;
        count -= len_total;
        var d = distance.lookup[@intCast(bits & decode.DistDecoder.mask)];
        if (d & dist_exceptional != 0) {
            const res = distance.resolve(bits) orelse return error.InvalidCode;
            // §3.2.6: distance codes 30-31 never occur.
            if (res.symbol > 29) return error.InvalidCode;
            d = fast.entry(.distance, res.symbol, @intCast(res.len));
        }
        const dist_total: u6 = @intCast((d >> 9) & 0x1F);
        // `dist_total` is at most 28 bits, so the truncation keeps them all.
        const dist_extra: u32 = @truncate(low(bits, dist_total) >> @intCast(d & 0xF));
        const match_distance: usize = ((d >> 16) & 0x7FFF) + dist_extra;
        bits >>= dist_total;
        count -= dist_total;
        // §3.2.3 — no distance past the beginning of the output stream.
        if (match_distance > reach +% end) return error.InvalidMatch;
        assert(match_distance <= end);
        // 16 or 8 bytes at a time, past the match's end into the free
        // window: a chunk's source ends at or before its destination.
        if (match_distance >= 16) {
            var i: usize = 0;
            while (i < len) : (i += 16) {
                fastmem.copy(u8, out[end + i ..][0..16], out[end + i - match_distance ..][0..16]);
            }
        } else if (match_distance >= 8) {
            var i: usize = 0;
            while (i < len) : (i += 8) {
                fastmem.copy(u8, out[end + i ..][0..8], out[end + i - match_distance ..][0..8]);
            }
        } else {
            decode.copyMatch(out, end, match_distance, len);
        }
        end += len;
    }
    const used = (@intFromPtr(ip) - @intFromPtr(in.ptr)) * 8 - count;
    input.toss(used / 8);
    r.bits.consumed = @intCast(used % 8);
    const added = end - start;
    r.reader.end = end;
    r.total_out += added;
    if (ended) try r.endBlock();
    return added;
}

/// The low `n` bits of `bits`.
inline fn low(bits: u64, n: u6) u64 {
    return bits & ((@as(u64, 1) << n) - 1);
}

/// A match's distance (`§3.2.5`), then the copy: `§3.2.3`'s reach check
/// against the whole output, and the format's overlapping copy.
fn copyMatchStep(r: *Reader, length: u16, fixed: bool) Error!usize {
    const distance = if (fixed) &decode.fixed_distance else &r.distance;
    const symbol = try distance.decode(Bits, &r.bits);
    // §3.2.6: distance codes 30-31 "will never actually occur".
    if (symbol > 29) return error.InvalidCode;
    const match_distance = try decode.decodeDistance(Bits, &r.bits, symbol);
    // §3.2.3 — "a distance cannot refer past the beginning of the output
    // stream". The window always retains the last 32 KiB of the output, so a
    // distance that passes this check is in the window.
    if (match_distance > r.total_out) return error.InvalidMatch;
    const out_pos = r.reader.end;
    assert(match_distance <= out_pos);
    decode.copyMatch(r.reader.buffer, out_pos, match_distance, length);
    r.reader.end += length;
    r.total_out += length;
    r.phase = if (fixed) .fixed_block else .dynamic_block;
    return length;
}

/// A block ended. `§3.2.3` — BFINAL ends the stream; otherwise the next block
/// header follows at the current bit offset.
fn endBlock(r: *Reader) Error!void {
    if (!r.final) {
        r.phase = .block_header;
        return;
    }
    r.bits.finish();
    r.state = .done;
}

/// The one place a detailed failure becomes the interface's coarse error:
/// `error.ReadFailed` with the detail sticky in `err`, or the clean
/// `error.EndOfStream` once the final block's output is complete.
fn record(r: *Reader, result: Error!usize) Io.Reader.Error!usize {
    return result catch |err| switch (err) {
        error.EndOfStream => {
            r.state = .done;
            return error.EndOfStream;
        },
        else => return fail(r, err),
    };
}

/// Record `err` as the sticky failure and return `error.ReadFailed`. The
/// window's unconsumed bytes are dropped: no decoded output is trusted past an
/// error, so a failed reader serves the error and nothing else, buffered bytes
/// included.
fn fail(r: *Reader, err: Error) Io.Reader.Error {
    r.reader.seek = r.reader.end;
    return internal.reader.fail(Error, &r.state, &r.err, err);
}

/// The decode hook for the generated entries: runs `fillWindow` and maps its
/// detailed errors through `record`, so every failure is the interface's
/// `error.ReadFailed` with the cause sticky in `err`. The returned count is
/// ignored: the data lands in the window (the VTable's store-in-buffer mode),
/// not in the caller's writer.
fn fill(r: *Reader) Io.Reader.Error!usize {
    return r.record(r.fillWindow());
}

/// The rebase hook for the generated entries: make room for `capacity` more
/// buffered bytes by sliding the unconsumed bytes and the retained history to
/// the front. A slide leaves at least `history_len` bytes of room from the
/// consumer's position, so every request of at most `history_len` bytes is
/// served. A request the window cannot hold at the consumer's position
/// returns `error.ReadFailed` (`err == .StreamTooLong`) instead of asserting.
fn rebase(r: *Reader, capacity: usize) Io.Reader.RebaseError!void {
    _ = r.slide();
    if (r.reader.buffer.len - r.reader.seek < capacity) {
        return fail(r, error.StreamTooLong);
    }
}

// ---------------------------------------------------------------------------
// Tests. Every decode is checked with the sentinel overrun rule: the target is
// pre-filled with cycling sentinels and every byte past the decoded length
// must be untouched.
// ---------------------------------------------------------------------------

/// Decode `r` into `target` through a fixed writer, returning the length.
fn decodeInto(r: *Io.Reader, target: []u8) !usize {
    var w: Io.Writer = .fixed(target);
    _ = try r.streamRemaining(&w);
    return w.end;
}

/// Encode `source` with `Writer`, decode with `Reader`, expect identity.
fn roundTrip(source: []const u8) !void {
    const gpa = testing.allocator;
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf, .{});
    try w.writer.writeAll(source);
    try w.finish();

    const target = try gpa.alloc(u8, source.len + sentinel.len);
    defer gpa.free(target);
    sentinel.fill(target);
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(compressed.written());
    var r: Reader = .init(&fixed_in, &rbuf, null);
    const n = try decodeInto(&r.reader, target);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, target[0..n]);
    try sentinel.expect(target, n);
    // The whole stream is consumed, nothing after it.
    try testing.expectEqual(compressed.written().len, fixed_in.seek);
}

/// Encode `source`, decode it through a Reader with the checksum hook set,
/// and prove the hook folded exactly `source` — every byte once, in stream
/// order — while the decoded bytes and the sentinel rule still hold. The
/// digest is read after the clean end (`error.EndOfStream`), the point a
/// container reads it.
fn roundTripWithChecksum(source: []const u8) !void {
    const gpa = testing.allocator;
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf, .{});
    try w.writer.writeAll(source);
    try w.finish();

    const target = try gpa.alloc(u8, source.len + sentinel.len);
    defer gpa.free(target);
    sentinel.fill(target);
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(compressed.written());
    var r: Reader = .init(&fixed_in, &rbuf, null);
    var digest: golden.TestChecksum = .init;
    r.checksum = digest.hook();
    const n = try decodeInto(&r.reader, target);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, target[0..n]);
    try sentinel.expect(target, n);
    try testing.expectEqual(compressed.written().len, fixed_in.seek);
    try testing.expectEqual(golden.TestChecksum.fold(source), digest.value);
}

test "Reader: the checksum hook folds every decoded byte exactly once, in order" {
    // The bytes that enter the window (the literal store, the match copy,
    // the stored-block copy) are folded as the window fills, before any slide
    // drops them. The synthetic fold is order-sensitive: a dropped, doubled,
    // or reordered byte changes the digest. The sizes span several window
    // fills (64 KiB each); the shapes cover all three entry paths: text
    // (literals and matches), random (stored blocks), and a single-byte run
    // (distance-1 overlapping matches).
    const gpa = testing.allocator;
    for ([_]usize{ 0, 1, 1000, 65535, 65536, 200_000 }) |len| {
        const source = try makeSource(gpa, len);
        defer gpa.free(source);
        roundTripWithChecksum(source) catch |err| {
            print("FAIL: len {d}\n", .{len});
            return err;
        };
    }
    var rng: DefaultPrng = .init(0xC0FFEE);
    const random_bytes = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(random_bytes);
    for (random_bytes) |*b| b.* = rng.random().int(u8);
    try roundTripWithChecksum(random_bytes);

    const run = try gpa.alloc(u8, 100_000);
    defer gpa.free(run);
    fastmem.set(u8, run, 0x41);
    try roundTripWithChecksum(run);
}

/// Corpus source bytes: repetitive text with a rotating tail, so blocks are
/// both compressible and varied.
fn makeSource(gpa: mem.Allocator, len: usize) ![]u8 {
    const buf = try gpa.alloc(u8, len);
    var rng: DefaultPrng = .init(0xC0FFEE);
    for (buf, 0..) |*b, i| {
        b.* = if (i % 3 == 0) @truncate(i / 7) else rng.random().int(u8);
    }
    return buf;
}

test "Reader: the buffer types are the documented sizes" {
    // The Reader's window is 2 * history_len = 64 KiB, and the Writer's buffer
    // is its window, max_block_size + history_len = 98303 bytes, and a block's
    // scratch, 426,636 bytes in all. Callers size stacks from these, so a
    // change must be deliberate.
    try testing.expectEqual(@as(usize, 65536), @sizeOf(Buffer));
    try testing.expectEqual(@as(usize, 2 * history_len), @sizeOf(Buffer));
    try testing.expectEqual(@as(usize, 426636), @sizeOf(Writer.Buffer));
    const Window = @FieldType(Writer.Buffer, "window");
    try testing.expectEqual(@as(usize, max_block_size + history_len), @sizeOf(Window));
    try testing.expectEqual(@as(usize, 32768), history_len);
    try testing.expectEqual(@as(usize, 65535), max_block_size);
}

test "Reader: the error set mirrors DecompressError minus BufferTooSmall" {
    // `Reader.Error` is the `DecompressError` set minus `BufferTooSmall` (the
    // Reader owns its window), plus the interface's `ReadFailed`/`EndOfStream`
    // and the contiguity cap's `StreamTooLong`.
    const mine = @typeInfo(Error).error_set.?;
    for (@typeInfo(decode.DecompressError).error_set.?) |want| {
        if (mem.eql(u8, want.name, "BufferTooSmall")) continue;
        var found = false;
        for (mine) |entry| {
            if (mem.eql(u8, entry.name, want.name)) found = true;
        }
        try testing.expect(found);
    }
}

test "Reader: round-trips through Writer" {
    try roundTrip("");
    try roundTrip("a");
    try roundTrip("hello, flate");
    try roundTrip("the quick brown fox jumps over the lazy dog. " ** 1000);
    try roundTrip("a" ** (max_block_size - 1));
    try roundTrip("b" ** max_block_size);
    try roundTrip("c" ** (max_block_size + 1));
    try roundTrip("d" ** (3 * max_block_size + 17));
}

test "Reader: multi-block inputs round-trip" {
    // Sizes around the 65535-byte split, where the second block's matches may
    // reach back into the first (`§3.2.3`: "the backward distance may cross
    // one or more block boundaries").
    const gpa = testing.allocator;
    const sizes = [_]usize{ 65534, 65535, 65536, 131070, 131071, 200_000 };
    for (sizes) |len| {
        const source = try makeSource(gpa, len);
        defer gpa.free(source);
        roundTrip(source) catch |err| {
            print("FAIL: len {d}\n", .{len});
            return err;
        };
    }
    // Incompressible input: every block is stored, so the Reader's stored-block
    // resume across window slides is exercised on a multi-block stream.
    var rng: DefaultPrng = .init(0xC0FFEE);
    const random_bytes = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(random_bytes);
    for (random_bytes) |*b| b.* = rng.random().int(u8);
    try roundTrip(random_bytes);
}

test "Reader: golden golang/go vectors through the streaming reader" {
    // The same fixtures the one-shot decoder is judged against, through the
    // streaming interface: valid streams decode to the golden output and
    // consume exactly their own bytes; rejected streams return
    // `error.ReadFailed` with the specific error in `err` where the table pins
    // one.
    const gpa = testing.allocator;
    for (golden.stream_cases) |tc| {
        switch (tc.expect) {
            .ok => |want| {
                const target = try gpa.alloc(u8, want.len + sentinel.len);
                defer gpa.free(target);
                sentinel.fill(target);
                var rbuf: Buffer = undefined;
                var fixed_in: Io.Reader = .fixed(tc.source);
                var r: Reader = .init(&fixed_in, &rbuf, null);
                const n = decodeInto(&r.reader, target) catch |err| {
                    print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
                    return err;
                };
                try testing.expectEqualSlices(u8, want, target[0..n]);
                try sentinel.expect(target, n);
                // The Reader stops at the stream's last byte. Go's vectors
                // carry at most one byte of padding after it (the "spanning
                // repeater code" vector's trailing zero), which must NOT be
                // consumed. `decodeInto` already proved the clean end of
                // stream.
                try testing.expect(fixed_in.seek <= tc.source.len);
                try testing.expect(fixed_in.seek + 1 >= tc.source.len);
            },
            else => {
                var rbuf: Buffer = undefined;
                var fixed_in: Io.Reader = .fixed(tc.source);
                var r: Reader = .init(&fixed_in, &rbuf, null);
                var out: Io.Writer.Allocating = .init(gpa);
                defer out.deinit();
                try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
                switch (tc.expect) {
                    .fail_with => |want_err| {
                        if (r.err.? != want_err) {
                            print("\nFAIL ({s}): {s}, want {s}\n", .{
                                tc.desc, @errorName(r.err.?), @errorName(want_err),
                            });
                            return error.TestUnexpectedResult;
                        }
                    },
                    else => {},
                }
                // The failure is sticky.
                var sink: Io.Writer.Discarding = .init(&.{});
                try testing.expectError(
                    error.ReadFailed,
                    r.reader.stream(&sink.writer, .unlimited),
                );
            },
        }
    }
}

test "Reader: truncated streams fail and stay failed" {
    // Spec: rfc1951-deflate.txt §3.2.3 — the stream ends at BFINAL, so any
    // input that ends before it is `error.Truncated`, never a clean end.
    const gpa = testing.allocator;
    for (golden.truncated_cases) |tc| {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(tc.source);
        var r: Reader = .init(&fixed_in, &rbuf, null);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
        try testing.expectEqual(Error.Truncated, r.err.?);
        var sink: Io.Writer.Discarding = .init(&.{});
        try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
    }

    // Every prefix of a two-block stream: none may decode cleanly.
    const full = golden.truncated_streams_data;
    var len: usize = 0;
    while (len < full.len) : (len += 1) {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(full[0..len]);
        var r: Reader = .init(&fixed_in, &rbuf, null);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
        try testing.expectEqual(Error.Truncated, r.err.?);
    }
}

test "Reader: golang/go huffman-* fixtures decode through the stream" {
    // The fixtures are a single non-final block (Go's `writeBlockHuff`), so
    // verbatim each is a truncated stream — and with BFINAL set on that block
    // it decodes to `.input`, exactly as the one-shot decoder does.
    const gpa = testing.allocator;
    for (golden.huffman_fixtures) |fixture| {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(fixture.golden);
        var r: Reader = .init(&fixed_in, &rbuf, null);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
        try testing.expectEqual(Error.Truncated, r.err.?);

        const completed = try gpa.alloc(u8, fixture.golden.len);
        defer gpa.free(completed);
        fastmem.copy(u8, completed, fixture.golden);
        completed[0] |= 1; // BFINAL on the fixture's single block header

        const target = try gpa.alloc(u8, fixture.input.len + sentinel.len);
        defer gpa.free(target);
        sentinel.fill(target);
        var rbuf2: Buffer = undefined;
        var fixed_in2: Io.Reader = .fixed(completed);
        var r2: Reader = .init(&fixed_in2, &rbuf2, null);
        const n = decodeInto(&r2.reader, target) catch |err| {
            print("\nFAIL: {s}: {s}\n", .{ fixture.name, @errorName(err) });
            return err;
        };
        try testing.expectEqual(fixture.input.len, n);
        try testing.expectEqualSlices(u8, fixture.input, target[0..n]);
        try sentinel.expect(target, n);
        try testing.expectEqual(completed.len, fixed_in2.seek);
    }
}

test "Reader: consumes input exactly through the stream's last byte" {
    // The Reader consumes `input` exactly through the stream's last byte (the
    // final block's partial byte included) and stops there; bytes after the
    // stream are not consumed. Marker bytes follow each stream in the input,
    // and after the decode the input's position is exactly the stream's
    // length.
    const gpa = testing.allocator;
    inline for (.{ "", "a", "the quick brown fox jumps over the lazy dog. " ** 40 }) |source| {
        var compressed: Io.Writer.Allocating = .init(gpa);
        defer compressed.deinit();
        var wbuf: Writer.Buffer = undefined;
        var w: Writer = .init(&compressed.writer, &wbuf, .{});
        try w.writer.writeAll(source);
        try w.finish();

        const markers = 64;
        const buffer = try gpa.alloc(u8, compressed.written().len + markers);
        defer gpa.free(buffer);
        fastmem.copy(u8, buffer[0..compressed.written().len], compressed.written());
        fastmem.set(u8, buffer[compressed.written().len..], 0xAA);

        var fixed_in: Io.Reader = .fixed(buffer);
        var rbuf: Buffer = undefined;
        var r: Reader = .init(&fixed_in, &rbuf, null);
        const out = try r.reader.allocRemaining(gpa, .unlimited);
        defer gpa.free(out);
        try testing.expectEqualStrings(source, out);
        try testing.expectEqual(compressed.written().len, fixed_in.seek);
    }

    // The same through a `File.Reader`-shaped input: a chunked source whose
    // buffer is refilled as the decode consumes it. The bit reader's lookahead
    // must not read past the stream into the next chunk.
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf, .{});
    const source = try makeSource(gpa, 100_000);
    defer gpa.free(source);
    try w.writer.writeAll(source);
    try w.finish();

    const buffer = try gpa.alloc(u8, compressed.written().len + 8);
    defer gpa.free(buffer);
    fastmem.copy(u8, buffer[0..compressed.written().len], compressed.written());
    fastmem.set(u8, buffer[compressed.written().len..], 0xAA);
    // An 8-byte input buffer: the stream cannot be seen in one piece, so the
    // decode runs on refills mid-symbol. The marker bytes must never reach
    // the decoder as stream bytes.
    var small: [8]u8 = undefined;
    var inner: Io.Reader = .fixed(buffer);
    var chunked: Io.Reader.Limited = .init(&inner, .unlimited, &small);
    var rbuf: Buffer = undefined;
    var r: Reader = .init(&chunked.interface, &rbuf, null);
    const out = try r.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(out);
    try testing.expectEqualSlices(u8, source, out);
}

test "Reader: a 32-KiB peek is served at any position" {
    // Any contiguous request (peek/take family) of at most 32 KiB is served:
    // the window holds 64 KiB and slides forward keeping the 32-KiB history
    // tail, so a full-history peek always fits.
    const gpa = testing.allocator;
    const source = try makeSource(gpa, 200_000);
    defer gpa.free(source);
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf, .{});
    try w.writer.writeAll(source);
    try w.finish();

    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(compressed.written());
    var r: Reader = .init(&fixed_in, &rbuf, null);
    // At the start: the request needs the whole window behind it.
    try testing.expectEqualSlices(u8, source[0..history_len], try r.reader.peek(history_len));
    try r.reader.discardAll(60_000);
    // Deep into the stream, where the window must slide to serve it.
    try testing.expectEqualSlices(
        u8,
        source[60_000..][0..history_len],
        try r.reader.peek(history_len),
    );
    // And again after a partial consume, which moves the consumer's position.
    try r.reader.discardAll(1);
    try testing.expectEqualSlices(
        u8,
        source[60_001..][0..history_len],
        try r.reader.peek(history_len),
    );
}

test "Reader: a request past the window fails with StreamTooLong" {
    // A request beyond what the window can hold at the consumer's position
    // returns `error.ReadFailed` (`err == .StreamTooLong`) and never asserts.
    // At position 60000 with the window's retained 32-KiB tail, 40000
    // contiguous bytes do not fit.
    const gpa = testing.allocator;
    const source = try makeSource(gpa, 200_000);
    defer gpa.free(source);
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf, .{});
    try w.writer.writeAll(source);
    try w.finish();

    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(compressed.written());
    var r: Reader = .init(&fixed_in, &rbuf, null);
    _ = try r.reader.peek(history_len);
    try r.reader.discardAll(60_000);
    try testing.expectError(error.ReadFailed, r.reader.peek(40_000));
    try testing.expectEqual(Error.StreamTooLong, r.err.?);
    // The failure is sticky, and the interface keeps reporting it.
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectError(error.ReadFailed, r.reader.peek(1));
}

test "Reader: a consumer scanning for a delimiter past the window fails" {
    // The `fillMore` path (the `peek`/`take`-delimiter family): a consumer
    // scanning for a delimiter inside a line longer than the window asks the
    // machinery for more contiguous bytes than the window can hold beside the
    // retained history. It must return `error.ReadFailed` with `err ==
    // .StreamTooLong`, never assert and never spin.
    const gpa = testing.allocator;
    const line_len = 100_000;
    const source = try gpa.alloc(u8, 100 + line_len + 1);
    defer gpa.free(source);
    fastmem.set(u8, source, 'a');
    source[99] = '\n';
    source[source.len - 1] = '\n';

    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf, .{});
    try w.writer.writeAll(source);
    try w.finish();

    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(compressed.written());
    var r: Reader = .init(&fixed_in, &rbuf, null);
    // `takeDelimiterExclusive` leaves the delimiter buffered; the consumer
    // steps over it.
    try testing.expectEqualStrings("a" ** 99, try r.reader.takeDelimiterExclusive('\n'));
    r.reader.toss(1);
    try testing.expectError(error.ReadFailed, r.reader.takeDelimiterExclusive('\n'));
    try testing.expectEqual(Error.StreamTooLong, r.err.?);
}

test "Reader: a zero-length stream poll does not fail the stream" {
    // std calls vtable stream at limit 0 when the buffer is nonempty: the
    // poll must answer 0 without filling (a fill could fail StreamTooLong
    // on a valid stream with buffered output).
    const gpa = testing.allocator;
    const src = "the quick brown fox jumps over the lazy dog. " ** 6000;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&out.writer, &wbuf, .{});
    try w.writer.writeAll(src);
    try w.finish();

    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(out.written());
    var r: Reader = .init(&fixed_in, &rbuf, null);
    _ = try r.reader.peek(1);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectEqual(@as(usize, 0), try r.reader.stream(&sink.writer, .limited(0)));
    try testing.expect(r.err == null);
    const got = try r.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(got);
    try testing.expectEqualSlices(u8, src, got);
}

test "Reader: a stream ends cleanly and stickily" {
    // The reader ends cleanly with `error.EndOfStream`, stickily, once the
    // final block's output has been consumed.
    const gpa = testing.allocator;
    const source = "the quick brown fox jumps over the lazy dog. " ** 100;
    var compressed: Io.Writer.Allocating = .init(gpa);
    defer compressed.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&compressed.writer, &wbuf, .{});
    try w.writer.writeAll(source);
    try w.finish();

    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(compressed.written());
    var r: Reader = .init(&fixed_in, &rbuf, null);
    const out = try r.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(out);
    try testing.expectEqualStrings(source, out);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectEqual(@as(?Error, null), r.err);
}

test "Reader: random consumer machinery sequences stay correct" {
    // Mixed peek/take/discardAll/readSliceAll/stream operations over randomly
    // chunked streams. This catches interactions in the vtable machinery:
    // contiguity, slide accounting, the sticky end.
    const gpa = testing.allocator;
    var rng: DefaultPrng = .init(4242);
    const rand = rng.random();
    // 200 KB is three window fills, so every iteration slides the window and
    // crosses blocks; the op mix is what the iterations buy.
    const input = try gpa.alloc(u8, 200_000);
    defer gpa.free(input);
    for (input, 0..) |*b, i| b.* = @truncate((i / 7) *% 31 +% rand.uintLessThan(u8, 3));

    var iter: usize = 0;
    while (iter < 50) : (iter += 1) {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var wbuf: Writer.Buffer = undefined;
        var w: Writer = .init(&out.writer, &wbuf, .{});
        var p: usize = 0;
        while (p < input.len) {
            const n = @min(input.len - p, rand.intRangeAtMost(usize, 1, 90_000));
            try w.writer.writeAll(input[p..][0..n]);
            if (rand.uintLessThan(u8, 4) == 0) try w.writer.flush();
            p += n;
        }
        try w.finish();

        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(out.written());
        var r: Reader = .init(&fixed_in, &rbuf, null);
        var pos: usize = 0;
        while (pos < input.len) {
            const left = input.len - pos;
            switch (rand.uintLessThan(u8, 5)) {
                0 => {
                    const n = @min(left, rand.intRangeAtMost(usize, 1, history_len));
                    try testing.expectEqualSlices(u8, input[pos..][0..n], try r.reader.peek(n));
                },
                1 => {
                    const n = @min(left, rand.intRangeAtMost(usize, 1, history_len));
                    try testing.expectEqualSlices(u8, input[pos..][0..n], try r.reader.take(n));
                    pos += n;
                },
                2 => {
                    const n = @min(left, rand.intRangeAtMost(usize, 1, 200_000));
                    try r.reader.discardAll(n);
                    pos += n;
                },
                3 => {
                    var tmp: [100_000]u8 = undefined;
                    const n = @min(left, rand.intRangeAtMost(usize, 1, tmp.len));
                    try r.reader.readSliceAll(tmp[0..n]);
                    try testing.expectEqualSlices(u8, input[pos..][0..n], tmp[0..n]);
                    pos += n;
                },
                else => {
                    var tmp: [5000]u8 = undefined;
                    var fw: Io.Writer = .fixed(&tmp);
                    const n = @min(left, rand.intRangeAtMost(usize, 0, 5000));
                    _ = try r.reader.stream(&fw, .limited(n));
                    // `stream` may serve from the buffer or fill it; the bytes
                    // land in `fw` or stay buffered. Only the served count is
                    // contractual.
                    const served = @min(n, fw.end);
                    try testing.expectEqualSlices(
                        u8,
                        input[pos..][0..served],
                        fw.buffered()[0..served],
                    );
                    pos += served;
                },
            }
        }
        // The clean end of stream is sticky.
        var sink: Io.Writer.Discarding = .init(&.{});
        try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
    }
}

test "Reader: a corrupt stream fails and stays failed" {
    // Every failure path is sticky and reports the detail beside the coarse
    // `error.ReadFailed`: a bad block type, a bad stored header, a bad
    // distance, and garbage.
    const gpa = testing.allocator;
    const cases = [_]struct { source: []const u8, want: Error }{
        // §3.2.3 — BTYPE 11 is "reserved (error)".
        .{ .source = &[_]u8{0b0000_0111}, .want = error.InvalidBlockType },
        // §3.2.4 — NLEN must be the one's complement of LEN.
        .{
            .source = &[_]u8{ 0x01, 0x03, 0x00, 0xFD, 0xFF, 'a', 'b', 'c' },
            .want = error.WrongStoredBlockNlen,
        },
        // §3.2.3 — a match at distance 1 with nothing decoded yet: a distance
        // before the start of the output. BFINAL=1, BTYPE=01, length code 257
        // (3 bytes), distance code 0. zlib reports this as "invalid distance
        // too far back".
        .{ .source = &[_]u8{ 0x03, 0x02 }, .want = error.InvalidMatch },
        // A truncated stored payload.
        .{ .source = &[_]u8{ 0x01, 0x0C, 0x00, 0xF3, 0xFF, 'h', 'i' }, .want = error.Truncated },
        // Garbage: a dynamic block header whose precode tree is empty.
        .{
            .source = &[_]u8{ 0x05, 0x00, 0x00, 0x00, 0x00 },
            .want = error.InvalidDynamicBlockHeader,
        },
    };
    for (cases) |tc| {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(tc.source);
        var r: Reader = .init(&fixed_in, &rbuf, null);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
        try testing.expectEqual(tc.want, r.err.?);
        var sink: Io.Writer.Discarding = .init(&.{});
        try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
    }
}

/// An input that hands over one byte per read into a 4-byte buffer, so the
/// decoder never has `fast_input_len` bytes buffered and every symbol takes
/// the slow path.
const OneByte = struct {
    data: []const u8,
    buffer: [4]u8 = undefined,
    reader: Io.Reader,

    fn init(o: *OneByte, data: []const u8) void {
        o.* = .{
            .data = data,
            .reader = .{
                .vtable = &.{ .stream = stream },
                .buffer = &o.buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const o: *OneByte = @fieldParentPtr("reader", r);
        if (o.data.len == 0) return error.EndOfStream;
        const n = try w.write(o.data[0..limit.minInt(1)]);
        o.data = o.data[n..];
        return n;
    }
};

/// The bytes `input` decodes to, or the decode error.
fn decodeAll(gpa: mem.Allocator, input: *Io.Reader) !union(enum) { ok: []u8, err: Error } {
    var rbuf: Buffer = undefined;
    var r: Reader = .init(input, &rbuf, null);
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    _ = r.reader.streamRemaining(&out.writer) catch |err| switch (err) {
        error.ReadFailed => {
            out.deinit();
            return .{ .err = r.err.? };
        },
        else => return err,
    };
    return .{ .ok = try out.toOwnedSlice() };
}

test "Reader: the fast path decodes what the slow path decodes" {
    // RFC 1951 §3.2.5-§3.2.7: the fast path (whole symbols from a local bit
    // buffer) and the slow path (one symbol per step through `Bits`) must
    // agree on every stream, valid or not: the same bytes, or the same
    // error. The fixed input takes the fast path wherever 16 bytes are
    // buffered; the one-byte input never does.
    const gpa = testing.allocator;
    const source = try makeSource(gpa, 300_000);
    defer gpa.free(source);
    // Matches at every distance class, 1 to 32768, and literal runs.
    var rng: DefaultPrng = .init(0x5EED);
    var i: usize = 40_000;
    while (i < source.len) : (i += 1 + rng.random().uintLessThan(usize, 64)) {
        const dist = @min(i, @as(usize, 1) << rng.random().uintLessThan(u5, 16));
        const len = @min(source.len - i, 3 + rng.random().uintLessThan(usize, 256));
        for (0..len) |k| source[i + k] = source[i + k - dist];
        i += len;
    }
    var streams: std.ArrayList([]u8) = .empty;
    defer {
        for (streams.items) |x| gpa.free(x);
        streams.deinit(gpa);
    }
    for ([_]encode.Level{ .@"1", .@"6" }) |level| {
        const target = try gpa.alloc(u8, encode.maxCompressedLength(source.len));
        defer gpa.free(target);
        const n = try encode.compress(source, target, .{ .level = level });
        try streams.append(gpa, try gpa.dupe(u8, target[0..n]));
    }
    for (golden.stream_cases) |tc| try streams.append(gpa, try gpa.dupe(u8, tc.source));
    // Corrupt copies: a flipped bit anywhere hits a table, a distance, a
    // length, or a block boundary.
    const goods = [2][]const u8{ streams.items[0], streams.items[1] };
    for (goods) |good| {
        for (0..40) |_| {
            const bad = try gpa.dupe(u8, good);
            bad[rng.random().uintLessThan(usize, bad.len)] ^= @as(u8, 1) << rng.random().int(u3);
            try streams.append(gpa, bad);
        }
    }
    for (streams.items, 0..) |stream, k| {
        var fixed_in: Io.Reader = .fixed(stream);
        const fast = try decodeAll(gpa, &fixed_in);
        defer if (fast == .ok) gpa.free(fast.ok);
        var one: OneByte = undefined;
        one.init(stream);
        const slow = try decodeAll(gpa, &one.reader);
        defer if (slow == .ok) gpa.free(slow.ok);
        try testing.expectEqual(std.meta.activeTag(slow), std.meta.activeTag(fast));
        switch (slow) {
            .ok => |want| try testing.expectEqualSlices(u8, want, fast.ok),
            .err => |want| try testing.expectEqual(want, fast.err),
        }
        if (k < 2) try testing.expectEqualSlices(u8, source, fast.ok);
    }
}

/// Decode the raw deflate stream in `in` into `out` and return the number of
/// bytes written. `in` is consumed exactly through the stream's last byte (the
/// final partial byte included); bytes after the stream are left unread.
/// `dict` is the stream's preset dictionary or `null` (`§3.2.3`); see
/// `Reader.init`.
///
/// Returns `error.ReadFailed` for a malformed stream or a failing `in`, and
/// `error.WriteFailed` when `out` fails. The cause of a decode failure is not
/// reported; use `Reader` directly to read `err`. Allocates nothing: the
/// `Reader` and its 64-KiB window are locals on the caller's stack.
pub fn streamAll(
    in: *Io.Reader,
    out: *Io.Writer,
    dict: ?[]const u8,
) Io.Reader.StreamRemainingError!usize {
    var buf: Buffer = undefined;
    var rr: Reader = .init(in, &buf, dict);
    return rr.reader.streamRemaining(out);
}

test "Reader: a preset dictionary pre-seeds the window" {
    // `§3.2.3` — the dictionary's tail is the window's front, so a match may
    // reach into it until the output pushes it out of the 32-KiB window. The
    // dictionary's bytes are not decoded output: the checksum hook never sees
    // them.
    const gpa = testing.allocator;
    const dict = "the quick brown fox jumps over the lazy dog. " ** 3;
    const source = "the quick brown fox jumps over the lazy dog. " ** 8;

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var wbuf: Writer.Buffer = undefined;
    var w: Writer = .init(&out.writer, &wbuf, .{ .level = .@"1", .dict = dict });
    try w.writer.writeAll(source);
    try w.finish();

    const target = try gpa.alloc(u8, source.len + sentinel.len);
    defer gpa.free(target);
    sentinel.fill(target);
    var rbuf: Buffer = undefined;
    var fixed_in: Io.Reader = .fixed(out.written());
    var r: Reader = .init(&fixed_in, &rbuf, dict);
    var digest: golden.TestChecksum = .init;
    r.checksum = digest.hook();
    const n = try decodeInto(&r.reader, target);
    try testing.expectEqual(source.len, n);
    try testing.expectEqualSlices(u8, source, target[0..n]);
    try sentinel.expect(target, n);
    try testing.expectEqual(out.written().len, fixed_in.seek);
    try testing.expectEqual(golden.TestChecksum.fold(source), digest.value);
    try testing.expectEqual(@as(?Error, null), r.err);

    // The serving guarantee survives the pre-seeded window: a 32-KiB
    // contiguous request is served at any position, the dictionary's bytes
    // included in the retained history. The source is long enough to slide
    // the window past the dictionary.
    const long = try gpa.alloc(u8, 100_000);
    defer gpa.free(long);
    for (long, 0..) |*b, i| b.* = @truncate(i / 7);
    var long_out: Io.Writer.Allocating = .init(gpa);
    defer long_out.deinit();
    var long_wbuf: Writer.Buffer = undefined;
    var long_w: Writer = .init(&long_out.writer, &long_wbuf, .{ .level = .@"1", .dict = dict });
    try long_w.writer.writeAll(long);
    try long_w.finish();
    var long_rbuf: Buffer = undefined;
    var long_in: Io.Reader = .fixed(long_out.written());
    var long_r: Reader = .init(&long_in, &long_rbuf, dict);
    try testing.expectEqualSlices(u8, long[0..history_len], try long_r.reader.peek(history_len));
    try long_r.reader.discardAll(60_000);
    try testing.expectEqualSlices(
        u8,
        long[60_000..][0..history_len],
        try long_r.reader.peek(history_len),
    );
    try testing.expectEqual(@as(?Error, null), long_r.err);
}

test "Reader: a dictionary stream without its dictionary is InvalidMatch" {
    // The golden fixtures are python3's zlib streams against a preset
    // dictionary. A reader with no dictionary (or a shorter one) cannot serve
    // the distance: the failure is flate's `InvalidMatch`, the window's own
    // name for a reach past the history.
    const gpa = testing.allocator;
    const target = try gpa.alloc(u8, golden.dict_straddle_plain.len + sentinel.len);
    defer gpa.free(target);

    const cases = [_]struct { stream: []const u8, dict: ?[]const u8 }{
        .{ .stream = &golden.dict_stream, .dict = null },
        .{ .stream = &golden.dict_stream, .dict = "abc" },
        .{ .stream = &golden.dict_straddle_stream, .dict = null },
        .{ .stream = &golden.dict_straddle_stream, .dict = "abc" },
    };
    for (cases) |tc| {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(tc.stream);
        var r: Reader = .init(&fixed_in, &rbuf, tc.dict);
        var sink: Io.Writer.Discarding = .init(&.{});
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&sink.writer));
        try testing.expectEqual(Error.InvalidMatch, r.err.?);
    }

    // With the right dictionary the same streams decode, one byte at a time:
    // the pre-seeded window is contiguous with the output, so the straddling
    // match's continuation reads the output's own start.
    for ([_]struct { stream: []const u8, dict: []const u8, want: []const u8 }{
        .{
            .stream = &golden.dict_stream,
            .dict = golden.dict_stream_dict,
            .want = golden.dict_stream_plain,
        },
        .{
            .stream = &golden.dict_straddle_stream,
            .dict = golden.dict_straddle_dict,
            .want = golden.dict_straddle_plain,
        },
    }) |tc| {
        var rbuf: Buffer = undefined;
        var fixed_in: Io.Reader = .fixed(tc.stream);
        var r: Reader = .init(&fixed_in, &rbuf, tc.dict);
        sentinel.fill(target);
        const n = try decodeInto(&r.reader, target);
        try testing.expectEqual(tc.want.len, n);
        try testing.expectEqualSlices(u8, tc.want, target[0..n]);
        try sentinel.expect(target, n);
    }
}
