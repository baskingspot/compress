//! brotli (RFC 7932) encoder at the reference's `q3` class: the quickly
//! hasher `H3` (16-bit buckets, a two-entry sweep, a five-byte hash, no
//! dictionary search) through the trivial meta-block emission — fresh trees
//! for all three alphabets, NBLTYPES 1/1/1, no context modeling, no block
//! splitting. The one-shot `compress` is byte-identical to the pinned
//! reference CLI's file form at `brotli -q 3` (window sized to the input);
//! `Writer.zig` is the same algorithm over a streaming `Io.Writer`.
//!
//! Ported from google/brotli v1.2.0 `c/enc/encode.c`, `c/enc/brotli_bit_stream.c`,
//! `c/enc/command.h`, and `c/enc/entropy_encode.c` (`THIRD_PARTY.md`); the C
//! is the port source of record (the Go port diverges below q5).
//!
//! Format: docs/specs/rfc7932-brotli.txt. API: README.md.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const fastmem = @import("fastmem");

const huffman = @import("encode_huffman.zig");
/// The matcher: the q3 hasher, the greedy scan, and the command record.
pub const match = @import("encode_match.zig");

/// The reference's `MAX_NUM_DELAYED_SYMBOLS`: below the block-split
/// qualities, the encoder buffers at most this many literals-and-commands
/// before flushing a meta-block.
pub const max_num_delayed_symbols = 0x2FFF;

/// The reference's `MAX_SIMPLE_DISTANCE_ALPHABET_SIZE`: the distance
/// histogram's scan length (NPOSTFIX 0, NDIRECT 0, the 62-bit large-window
/// maximum) — the reference scans 140 entries and declares 64.
pub const max_simple_distance_alphabet_size = 140;

/// §4's distance alphabet at NPOSTFIX 0 and NDIRECT 0:
/// `16 + NDIRECT + (48 << NPOSTFIX)`.
pub const distance_alphabet_size = 16 + 48;

/// The one-shot encoder's errors.
pub const Error = error{
    /// `target` cannot hold the stream.
    BufferTooSmall,
};

/// The largest stream `compress` can write for an `input_len`-byte input:
/// the q3 class's worst case, not §11.1's trivial-compressor bound.
///
/// Every meta-block is either stored uncompressed or kept compressed only
/// when it is no more than four bytes larger than its input (`encode.c`'s
/// `bytes + 4 < (*storage_ix >> 3)` rollback rule), so a meta-block costs at
/// most five bytes of header beyond its input. Every meta-block but the last
/// holds at least one full 16 KiB input block, so an `N`-byte input has at
/// most `1 + (N >> 14)` meta-blocks; add the one-byte stream header and the
/// one-byte empty final block. §11.1's `N + 3 * (N >> 16) + 5` is the
/// *trivial* compressor's bound (64 KiB blocks, a 3-byte header each) and is
/// too small for this class: `brotli -q 3` emits `N + 11` on a 128 KiB
/// adversarial input.
pub fn maxCompressedLength(input_len: usize) usize {
    return input_len + 5 * (input_len >> 14) + 7;
}

/// One-shot encode: one stream, header through last byte. `target` is a cap;
/// the return value is the compressed length. Nothing is allocated, and no
/// byte past the returned length is written.
///
/// Byte-identical to the pinned reference CLI's file form at `brotli -q 3`
/// with the window sized to the input (the CLI's own automatic-window rule),
/// and to the reference library's one-shot at the same quality and window.
/// The one divergence is the empty input: the reference *library* returns the
/// two-byte `06` shortcut, while the CLI's file form (the pin) writes the
/// window header plus the empty last meta-block.
///
/// Stack: the 256-KiB bucket table, the delayed-command buffer, and the
/// tree-build scratch are comptime locals — about 550 KiB. Give encoding
/// threads 1 MiB or more.
pub fn compress(source: []const u8, target: []u8) Error!usize {
    const lgwin = windowBitsFor(source.len);
    var hash: [match.bucket_size]u32 = undefined;
    var command_buffer: [max_commands]match.Command = undefined;
    var scratch: Scratch = undefined;
    var state: State = .{
        .matcher = .{
            .hasher = .{ .buckets = &hash },
            .window = .{ .bytes = source, .mask = std.math.maxInt(usize) },
            .lgwin = lgwin,
        },
        .commands = .{ .buffer = &command_buffer },
        .writer = .{ .sink = .{ .slice = target } },
        .scratch = &scratch,
        .max_metablock_size = maxMetablockSize(lgwin),
    };
    state.matcher.hasher.init();
    storeWindowBits(&state.writer, lgwin) catch |err| return oneShotError(err);
    state.run(source.len) catch |err| return oneShotError(err);
    assert(state.writer.pending_len == 0);
    return state.writer.bytePos();
}

/// Narrow the emission's error set to the one-shot's: the slice sink has no
/// output to fail, so `WriteFailed` cannot be raised here.
fn oneShotError(err: EmitError) Error {
    return switch (err) {
        error.BufferTooSmall => error.BufferTooSmall,
        error.WriteFailed => unreachable,
    };
}

/// The delayed-command buffer's cap: the reference flushes at
/// `max_num_delayed_symbols` symbols, and one 16-KiB input block can add at
/// most one command per four bytes (every match is at least four bytes long)
/// on top of that, plus the flush's insert-only command.
pub const max_commands = max_num_delayed_symbols + (1 << 14) / 4 + 1;

/// The reference's `MaxHashTableSize`-independent `H3` bucket count: the
/// table is always `1 << 16` entries, whatever the input's size.
pub const bucket_entries = match.bucket_size;

/// The CLI's automatic window (`c/tools/brotli.c`): the smallest `lgwin` in
/// 10..24 whose §9.1 window bound `(1 << lgwin) - 16` holds the whole input.
/// This is the pin the one-shot is byte-identical to.
pub fn windowBitsFor(input_len: usize) u6 {
    var lgwin: u6 = 10;
    while (lgwin < 24 and (@as(usize, 1) << @intCast(lgwin)) - 16 < input_len) lgwin += 1;
    return lgwin;
}

/// The reference's `MaxMetablockSize`: `1 << min(ComputeRbBits, 24)` where
/// `ComputeRbBits` is `1 + max(lgwin, lgblock)`.
pub fn maxMetablockSize(lgwin: u6) usize {
    const rb_bits = 1 + @max(@as(usize, lgwin), @as(usize, 14));
    return @as(usize, 1) << @intCast(@min(rb_bits, 24));
}

/// The input block size: the reference's `lgblock` is 14 below the
/// block-split qualities, so it feeds the matcher 16-KiB blocks.
pub const input_block_size = 1 << 14;

// ---------------------------------------------------------------------------
// §1.5.1 — the bit writer
// ---------------------------------------------------------------------------

/// The emission's failures: the one-shot's target running out of room (the
/// sizing pass proves it will not, before the first byte) and the streaming
/// sink's output failing.
pub const EmitError = error{ BufferTooSmall, WriteFailed };

/// Where a bit writer's whole bytes go.
pub const Sink = union(enum) {
    /// The one-shot's target. The sizing pass has already proved every
    /// meta-block fits, so the writes are asserted, never checked.
    slice: []u8,
    /// The streaming `Writer`: a bounded window flushed to `output`.
    stream: Stream,
    /// Counting only: the sizing pass, which must count exactly the bits
    /// the writing pass emits.
    count: void,

    /// The bytes left in a slice sink, if this is one: the streaming and
    /// counting sinks have no cap.
    pub fn room(self: *const Sink, written: usize) ?usize {
        return switch (self.*) {
            .slice => |target| target.len - written,
            else => null,
        };
    }

    pub const Stream = struct {
        output: *Io.Writer,
        buffer: []u8,
        len: usize = 0,

        pub fn byte(self: *Stream, b: u8) EmitError!void {
            if (self.len == self.buffer.len) try self.flush();
            self.buffer[self.len] = b;
            self.len += 1;
        }

        /// Hand the buffered bytes to the output. `finish` calls this after
        /// the last meta-block, so nothing is left behind.
        pub fn flush(self: *Stream) EmitError!void {
            if (self.len == 0) return;
            try self.output.writeAll(self.buffer[0..self.len]);
            self.len = 0;
        }
    };
};

/// §1.5.1's bit writer: integers pack least significant bit first into bytes
/// in increasing order, and the whole bytes go to `sink`. The writer counts
/// the same bits in every mode, so the sizing pass and the writing pass
/// agree byte for byte.
pub const BitWriter = struct {
    sink: Sink,
    /// Bits appended so far, the pending partial byte included: the wire
    /// position.
    bit_pos: usize = 0,
    /// Whole bytes handed to the sink.
    written: usize = 0,
    /// The pending bits, LSB first.
    bits: u64 = 0,
    /// The pending bit count, below eight between writes.
    pending_len: u7 = 0,

    /// A counting writer: no bytes, the same bit arithmetic.
    pub fn counting() BitWriter {
        return .{ .sink = .{ .count = {} } };
    }

    /// Append `n` bits of `value`, least significant first (§1.5.1).
    pub fn writeBits(self: *BitWriter, value: u64, n: u6) EmitError!void {
        assert(n <= 56);
        assert(n == 0 or (value >> @intCast(n)) == 0);
        self.bits |= value << @intCast(self.pending_len);
        self.pending_len += n;
        self.bit_pos += n;
        while (self.pending_len >= 8) {
            const byte: u8 = @truncate(self.bits);
            switch (self.sink) {
                .slice => |target| {
                    if (self.written >= target.len) return error.BufferTooSmall;
                    target[self.written] = byte;
                },
                .stream => |*stream| try stream.byte(byte),
                .count => {},
            }
            self.written += 1;
            self.bits >>= 8;
            self.pending_len -= 8;
        }
    }

    /// §9.2's zero fill: pad to the next byte boundary.
    pub fn byteAlign(self: *BitWriter) EmitError!void {
        if (self.pending_len != 0) try self.writeBits(0, @intCast(8 - self.pending_len));
    }

    /// The number of whole bytes on the wire.
    pub fn bytePos(self: *const BitWriter) usize {
        return self.written;
    }

    /// The writer's position, for a sizing pass that must rewind.
    pub const Mark = struct {
        bit_pos: usize,
        written: usize,
        bits: u64,
        pending_len: u7,
    };

    pub fn mark(self: *const BitWriter) Mark {
        return .{
            .bit_pos = self.bit_pos,
            .written = self.written,
            .bits = self.bits,
            .pending_len = self.pending_len,
        };
    }

    pub fn restore(self: *BitWriter, saved: Mark) void {
        self.bit_pos = saved.bit_pos;
        self.written = saved.written;
        self.bits = saved.bits;
        self.pending_len = saved.pending_len;
    }
};

/// §9.1's stream header: the `lgwin` 1..7-bit code (`EncodeWindowBits`).
pub fn storeWindowBits(w: *BitWriter, lgwin: u6) EmitError!void {
    if (lgwin == 16) {
        try w.writeBits(0, 1);
    } else if (lgwin == 17) {
        try w.writeBits(1, 7);
    } else if (lgwin > 17) {
        try w.writeBits(((@as(u64, lgwin) - 17) << 1) | 0x01, 4);
    } else {
        try w.writeBits(((@as(u64, lgwin) - 8) << 4) | 0x01, 7);
    }
}

// ---------------------------------------------------------------------------
// The tree-build scratch
// ---------------------------------------------------------------------------

/// The per-meta-block scratch: the three histograms, the three depth/bit
/// tables, the builder's node pool, and the code-length serialization.
pub const Scratch = struct {
    literal_histo: [256]u32 = @splat(0),
    command_histo: [704]u32 = @splat(0),
    distance_histo: [max_simple_distance_alphabet_size]u32 = @splat(0),
    literal_depth: [256]u8 = @splat(0),
    literal_bits: [256]u16 = @splat(0),
    command_depth: [704]u8 = @splat(0),
    command_bits: [704]u16 = @splat(0),
    distance_depth: [max_simple_distance_alphabet_size]u8 = @splat(0),
    distance_bits: [max_simple_distance_alphabet_size]u16 = @splat(0),
    /// The builder's node pool (`MAX_HUFFMAN_TREE_SIZE`).
    tree: [2 * 704 + 1]huffman.Node = undefined,
    /// §3.5's run-length serialization of a depth sequence.
    tree_symbols: [704]u8 = undefined,
    tree_extra_bits: [704]u8 = undefined,
    code_length_depth: [18]u8 = undefined,
    code_length_bits: [18]u16 = undefined,
};

// ---------------------------------------------------------------------------
// The stream state and the driver
// ---------------------------------------------------------------------------

/// One stream's encoder state: the reference's `BrotliEncoderState` reduced
/// to what the q3 class reads. The one-shot drives it over the input itself;
/// `Writer.zig` drives it over a ring.
pub const State = struct {
    matcher: match.Matcher,
    commands: match.Commands,
    /// The distance ring at the last meta-block boundary: an uncompressed
    /// meta-block's symbols never execute, so the ring rolls back
    /// (the reference's `saved_dist_cache_`).
    saved_dist_cache: [4]i32 = .{ 4, 11, 15, 16 },
    /// The bit writer. It lives by value here so neither driver has to keep
    /// a self-pointer honest across a move.
    writer: BitWriter,
    scratch: *Scratch,
    /// The input's absolute size: one past the last byte written.
    input_pos: usize = 0,
    /// One past the last position the matcher has seen.
    last_processed_pos: usize = 0,
    /// The start of the pending meta-block.
    last_flush_pos: usize = 0,
    /// The largest meta-block this window can emit.
    max_metablock_size: usize,

    /// The reference's `RemainingInputBlockSize`: how much input the matcher
    /// can still take before the current block is full.
    pub fn remainingInputBlock(self: *const State) usize {
        const delta = self.input_pos - self.last_processed_pos;
        if (delta >= input_block_size) return 0;
        return input_block_size - delta;
    }

    /// Feed `len` bytes of input, which the caller has already made visible
    /// in the window, and run the reference's `EncodeData` when it would:
    /// on a full input block, on `force_flush`, or at the stream's end.
    pub fn feed(self: *State, len: usize, is_last: bool, force_flush: bool) EmitError!void {
        self.input_pos += len;
        if (is_last or force_flush or self.remainingInputBlock() == 0) {
            try self.encodeData(is_last, force_flush);
        }
    }

    /// The reference's `EncodeData`: run the matcher over the input since the
    /// last call, then either merge the symbols into the pending meta-block
    /// or flush it.
    fn encodeData(self: *State, is_last: bool, force_flush: bool) EmitError!void {
        const bytes = self.input_pos - self.last_processed_pos;
        if (bytes == 0 and self.input_pos == 0) {
            // No input has been processed at all (the reference's `!data`):
            // the empty stream's last meta-block, byte-aligned.
            if (is_last) try self.emitEmpty();
            return;
        }
        if (bytes != 0) {
            // The reference's order, which is load-bearing: the hasher
            // stitches the *unadvanced* position first (its three bytes
            // belong to the previous block's tail, and they are the only
            // stores that can reach the last bytes of a block), then the
            // last command extends into the new input, and only then does
            // the matcher run over the reduced range.
            self.matcher.hasher.stitch(self.matcher.window, self.last_processed_pos, bytes);
            var position = self.last_processed_pos;
            var remaining = bytes;
            if (self.commands.len != 0 and self.commands.last_insert_len == 0) {
                self.extendLastCommand(&remaining, &position);
            }
            self.matcher.findReferences(position, remaining, &self.commands);
        }
        const max_length = self.max_metablock_size;
        const max_literals = max_length / 8;
        const max_commands_ = max_length / 8;
        const processed_bytes = self.input_pos - self.last_flush_pos;
        const next_input_fits = processed_bytes + input_block_size <= max_length;
        const should_flush = self.commands.literals + self.commands.len >= max_num_delayed_symbols;
        if (!is_last and !force_flush and !should_flush and next_input_fits and
            self.commands.literals < max_literals and self.commands.len < max_commands_)
        {
            // Merge with the next input block; everything happens later.
            self.last_processed_pos = self.input_pos;
            return;
        }
        if (self.commands.last_insert_len > 0) {
            assert(self.commands.len < self.commands.buffer.len);
            match.initInsertCommand(
                self.commands.last_insert_len,
                &self.commands.buffer[self.commands.len],
            );
            self.commands.len += 1;
            self.commands.literals += self.commands.last_insert_len;
            self.commands.last_insert_len = 0;
        }
        if (!is_last and self.input_pos == self.last_flush_pos) return;
        const metablock_size = self.input_pos - self.last_flush_pos;
        try self.writeMetaBlock(metablock_size, is_last);
        self.last_flush_pos = self.input_pos;
        self.last_processed_pos = self.input_pos;
        self.commands.reset();
        self.saved_dist_cache = self.matcher.dist_cache;
    }

    /// The one-shot's chunk walk: feed the input in the reference's 16-KiB
    /// blocks, ending with the last one (an empty input is one empty feed).
    /// The pin is the CLI's *file form*, which reads through a
    /// `kFileBufferSize` (512 KiB) buffer and calls the streaming encoder
    /// with PROCESS until a read hits end-of-file, then FINISH. A read that
    /// returns exactly the requested count does not hit EOF, so an input
    /// whose size is a positive multiple of 512 KiB is processed to its last
    /// byte as non-final, and the stream ends with the empty
    /// ISLAST+ISLASTEMPTY meta-block — one byte more than the reference
    /// *library*'s one-shot (`BrotliEncoderCompress`), which hands the whole
    /// input to FINISH and puts ISLAST on the last data meta-block. The CLI
    /// is the pin (the oracle compares against it); the divergence is
    /// recorded in the README and AGENTS.md.
    fn run(self: *State, total: usize) EmitError!void {
        const cli_read_buffer = 1 << 19;
        const final_chunk_is_last = total == 0 or total % cli_read_buffer != 0;
        var pos: usize = 0;
        while (true) {
            const room = self.remainingInputBlock();
            assert(room != 0);
            const copy = @min(room, total - pos);
            pos += copy;
            try self.feed(copy, final_chunk_is_last and pos == total, false);
            if (pos == total) break;
        }
        if (!final_chunk_is_last) try self.feed(0, true, false);
    }

    /// The reference's `WriteMetaBlockInternal`: the compressed form when it
    /// is worth it, the uncompressed form otherwise, and the sizing pass that
    /// decides — every form runs once as a counter and once for real, so the
    /// target's room is known before the first byte of the meta-block lands.
    fn writeMetaBlock(self: *State, bytes: usize, is_last: bool) EmitError!void {
        if (bytes == 0) {
            // The empty last meta-block: ISLAST and ISLASTEMPTY, byte-aligned.
            try self.writer.writeBits(3, 2);
            try self.writer.byteAlign();
            return;
        }
        if (!self.shouldCompress(bytes)) {
            self.matcher.dist_cache = self.saved_dist_cache;
            try self.emitChecked(bytes, is_last, storeUncompressed);
            return;
        }
        self.buildHistograms();
        const mark = self.writer.mark();
        const sink = self.writer.sink;
        self.writer.sink = .{ .count = {} };
        try self.storeTrivial(bytes, is_last);
        const compressed_bits = self.writer.bit_pos - mark.bit_pos;
        self.writer.restore(mark);
        self.writer.sink = sink;
        const compressed_bytes = (mark.bit_pos % 8 + compressed_bits) / 8;
        if (bytes + 4 < compressed_bytes) {
            // The compressed form does not pay; the reference restores the
            // distance ring and stores the bytes.
            self.matcher.dist_cache = self.saved_dist_cache;
            try self.emitChecked(bytes, is_last, storeUncompressed);
            return;
        }
        if (sink.room(mark.written)) |room| {
            if (compressed_bytes > room) return error.BufferTooSmall;
        }
        try self.storeTrivial(bytes, is_last);
    }

    /// Emit one meta-block form only when the target has room for it: the
    /// form runs once as a counter, then for real.
    fn emitChecked(
        self: *State,
        bytes: usize,
        is_last: bool,
        comptime emit: fn (*State, usize, bool) EmitError!void,
    ) EmitError!void {
        const mark = self.writer.mark();
        const sink = self.writer.sink;
        self.writer.sink = .{ .count = {} };
        try emit(self, bytes, is_last);
        const bits = self.writer.bit_pos - mark.bit_pos;
        self.writer.restore(mark);
        self.writer.sink = sink;
        const emitted_bytes = (mark.bit_pos % 8 + bits) / 8;
        if (sink.room(mark.written)) |room| {
            if (emitted_bytes > room) return error.BufferTooSmall;
        }
        try emit(self, bytes, is_last);
    }

    /// The empty stream's last meta-block: ISLAST and ISLASTEMPTY, then the
    /// zero fill — sized before it is written, like every other meta-block.
    fn emitEmpty(self: *State) EmitError!void {
        const mark = self.writer.mark();
        const sink = self.writer.sink;
        self.writer.sink = .{ .count = {} };
        try self.writer.writeBits(3, 2);
        try self.writer.byteAlign();
        const bits = self.writer.bit_pos - mark.bit_pos;
        self.writer.restore(mark);
        self.writer.sink = sink;
        const emitted_bytes = (mark.bit_pos % 8 + bits) / 8;
        if (sink.room(mark.written)) |room| {
            if (emitted_bytes > room) return error.BufferTooSmall;
        }
        try self.writer.writeBits(3, 2);
        try self.writer.byteAlign();
    }

    /// The reference's `ExtendLastCommand`: a copy whose match continues
    /// into the new input absorbs the continuation into its own length,
    /// instead of a new command starting mid-match. This is what makes a
    /// block boundary invisible to a match that spans it.
    fn extendLastCommand(self: *State, bytes: *usize, position: *usize) void {
        const last = &self.commands.buffer[self.commands.len - 1];
        const max_backward_distance = (@as(u64, 1) << self.matcher.lgwin) - 16;
        const last_copy_len: u64 = last.copy_len;
        const copy_start = self.last_processed_pos -% last_copy_len;
        const max_distance = @min(copy_start, max_backward_distance);
        const cmd_dist: u64 = @intCast(self.matcher.dist_cache[0]);
        const distance_code = restoreDistanceCode(last.*);
        if (distance_code < 16 or distance_code - 15 == cmd_dist) {
            if (cmd_dist <= max_distance) {
                while (bytes.* != 0 and
                    self.matcher.window.at(position.*) ==
                        self.matcher.window.at(position.* - @as(usize, @intCast(cmd_dist))))
                {
                    last.copy_len += 1;
                    last.copy_len_code += 1;
                    bytes.* -= 1;
                    position.* += 1;
                }
            }
            // The length code describes the produced length, so it must be
            // recomputed for the extended copy.
            last.cmd_prefix = match.lengthCode(
                last.insert_len,
                last.copy_len_code,
                (last.dist_prefix & 0x3FF) == 0,
            );
        }
    }

    /// The reference's `CommandRestoreDistanceCode` at NPOSTFIX 0 and
    /// NDIRECT 0: the intermediate distance code (a short code, or the
    /// distance plus 15). The decoder's §4 reconstruction adds 1 to the
    /// offset-and-extra sum; this adds the 16 short codes instead, which is
    /// the intermediate-code convention `ComputeDistanceCode` returns.
    fn restoreDistanceCode(cmd: match.Command) usize {
        const dcode = cmd.dist_prefix & 0x3FF;
        if (dcode < 16) return dcode;
        const nbits = cmd.dist_prefix >> 10;
        const hcode = dcode - 16;
        const offset = ((@as(u32, 2) + (hcode & 1)) << @intCast(nbits)) - 4;
        return offset + cmd.dist_extra + 16;
    }

    /// The reference's `ShouldCompress`: an entropy sample of literal-only
    /// meta-blocks refuses data that will not shrink.
    fn shouldCompress(self: *State, bytes: usize) bool {
        if (bytes <= 2) return false;
        if (self.commands.len < (bytes >> 8) + 2) {
            const literals: f64 = @floatFromInt(self.commands.literals);
            const byte_count: f64 = @floatFromInt(bytes);
            if (literals > 0.99 * byte_count) {
                var literal_histo: [256]u32 = @splat(0);
                const sample_rate = 13;
                const min_entropy = 7.92;
                const bit_cost_threshold = byte_count * min_entropy / sample_rate;
                const samples = (bytes + sample_rate - 1) / sample_rate;
                var pos = self.last_flush_pos;
                for (0..samples) |_| {
                    literal_histo[self.matcher.window.at(pos)] += 1;
                    pos += sample_rate;
                }
                if (bitsEntropy(&literal_histo) > bit_cost_threshold) return false;
            }
        }
        return true;
    }

    /// The reference's `BuildHistograms`: count the literals, commands, and
    /// distance symbols the pending meta-block emits.
    fn buildHistograms(self: *State) void {
        const scratch = self.scratch;
        fastmem.set(u32, &scratch.literal_histo, 0);
        fastmem.set(u32, &scratch.command_histo, 0);
        fastmem.set(u32, &scratch.distance_histo, 0);
        var pos = self.last_flush_pos;
        for (self.commands.buffer[0..self.commands.len]) |cmd| {
            scratch.command_histo[cmd.cmd_prefix] += 1;
            var remaining = cmd.insert_len;
            while (remaining != 0) : (remaining -= 1) {
                scratch.literal_histo[self.matcher.window.at(pos)] += 1;
                pos += 1;
            }
            pos += cmd.copy_len;
            if (cmd.copy_len != 0 and cmd.cmd_prefix >= 128) {
                scratch.distance_histo[cmd.dist_prefix & 0x3FF] += 1;
            }
        }
    }

    /// §9.2's compressed meta-block header.
    fn storeCompressedHeader(
        w: *BitWriter,
        is_last: bool,
        length: usize,
    ) EmitError!void {
        try w.writeBits(@intFromBool(is_last), 1);
        if (is_last) try w.writeBits(0, 1);
        const mlen = encodeMlen(length);
        try w.writeBits(mlen.nibbles, 2);
        try w.writeBits(mlen.bits, mlen.nbits);
        if (!is_last) try w.writeBits(0, 1);
    }

    /// §9.2 — `BrotliStoreMetaBlockTrivial`: the minimal header's 13 zero
    /// bits (NBLTYPES 1/1/1, NPOSTFIX 0, NDIRECT 0, one context mode,
    /// NTREESL/NTREESD 1), then three fresh trees, then the data.
    fn storeTrivial(self: *State, bytes: usize, is_last: bool) EmitError!void {
        try storeCompressedHeader(&self.writer, is_last, bytes);
        try self.writer.writeBits(0, 13);
        const scratch = self.scratch;
        try buildAndStoreHuffmanTree(
            &self.writer,
            &scratch.literal_histo,
            256,
            &scratch.tree,
            &scratch.literal_depth,
            &scratch.literal_bits,
            scratch,
        );
        try buildAndStoreHuffmanTree(
            &self.writer,
            &scratch.command_histo,
            704,
            &scratch.tree,
            &scratch.command_depth,
            &scratch.command_bits,
            scratch,
        );
        try buildAndStoreHuffmanTree(
            &self.writer,
            &scratch.distance_histo,
            distance_alphabet_size,
            &scratch.tree,
            &scratch.distance_depth,
            &scratch.distance_bits,
            scratch,
        );
        try self.storeData();
        if (is_last) try self.writer.byteAlign();
    }

    /// The reference's `StoreDataWithHuffmanCodes`: per command, the symbol
    /// and the extra bits, then the literals, then the distance — §10's
    /// decode order exactly.
    fn storeData(self: *State) EmitError!void {
        const w = &self.writer;
        const scratch = self.scratch;
        var pos = self.last_flush_pos;
        for (self.commands.buffer[0..self.commands.len]) |cmd| {
            const cmd_code = cmd.cmd_prefix;
            const cmd_depth = scratch.command_depth[cmd_code];
            try w.writeBits(scratch.command_bits[cmd_code], @intCast(cmd_depth));
            try storeCommandExtra(w, cmd);
            var remaining = cmd.insert_len;
            while (remaining != 0) : (remaining -= 1) {
                const literal = self.matcher.window.at(pos);
                const lit_depth = scratch.literal_depth[literal];
                try w.writeBits(scratch.literal_bits[literal], @intCast(lit_depth));
                pos += 1;
            }
            pos += cmd.copy_len;
            if (cmd.copy_len != 0 and cmd.cmd_prefix >= 128) {
                const dist_code = cmd.dist_prefix & 0x3FF;
                const dist_extra_bits = cmd.dist_prefix >> 10;
                const dist_depth = scratch.distance_depth[dist_code];
                try w.writeBits(scratch.distance_bits[dist_code], @intCast(dist_depth));
                try w.writeBits(cmd.dist_extra, @intCast(dist_extra_bits));
            }
        }
    }

    /// §9.2 — `BrotliStoreUncompressedMetaBlock`: ISUNCOMPRESSED can never
    /// sit on an ISLAST meta-block, so a final uncompressed block is
    /// followed by the empty ISLAST+ISLASTEMPTY pair. The skipped bits are
    /// zero-filled.
    fn storeUncompressed(self: *State, bytes: usize, is_last: bool) EmitError!void {
        const w = &self.writer;
        try w.writeBits(0, 1);
        const mlen = encodeMlen(bytes);
        try w.writeBits(mlen.nibbles, 2);
        try w.writeBits(mlen.bits, mlen.nbits);
        try w.writeBits(1, 1);
        try w.byteAlign();
        var pos = self.last_flush_pos;
        var remaining = bytes;
        while (remaining != 0) : (remaining -= 1) {
            try w.writeBits(self.matcher.window.at(pos), 8);
            pos += 1;
        }
        if (is_last) {
            try w.writeBits(3, 2);
            try w.byteAlign();
        }
    }
};

/// §9.2 — `BrotliEncodeMlen`: the MNIBBLES 2-bit code and MLEN-1 in nibbles,
/// least significant nibble first.
const Mlen = struct {
    nibbles: u64,
    bits: u64,
    nbits: u6,
};

fn encodeMlen(length: usize) Mlen {
    assert(length > 0);
    assert(length <= 1 << 24);
    const lg: u32 = if (length == 1) 1 else match.log2FloorNonZero(length - 1) + 1;
    const mnibbles: u32 = (if (lg < 16) 16 else lg + 3) / 4;
    assert(mnibbles >= 4);
    assert(mnibbles <= 6);
    return .{
        .nibbles = mnibbles - 4,
        .bits = length - 1,
        .nbits = @intCast(mnibbles * 4),
    };
}

/// The reference's `StoreCommandExtra`: the insert and copy extra bits, as
/// one field (insert bits low).
fn storeCommandExtra(w: *BitWriter, cmd: match.Command) EmitError!void {
    const copy_len_code = cmd.copy_len_code;
    const inscode = match.insertLengthCode(cmd.insert_len);
    const copycode = match.copyLengthCode(copy_len_code);
    const ins_extra_bits = insert_extra[inscode];
    const ins_extra_value = cmd.insert_len - insert_base[inscode];
    const copy_extra_value = copy_len_code - copy_base[copycode];
    const bits = (@as(u64, copy_extra_value) << ins_extra_bits) | ins_extra_value;
    try w.writeBits(bits, @as(u6, ins_extra_bits) + copy_extra[copycode]);
}

/// §5's insert-length bases, shared with the emission.
const insert_base = match.insert_base;
const insert_extra = match.insert_extra;
const copy_base = match.copy_base;
const copy_extra = match.copy_extra;

// ---------------------------------------------------------------------------
// The tree emission
// ---------------------------------------------------------------------------

/// §3.4's simple form: the two-bit form code, NSYM-1, the symbols in
/// depth-sorted order, and the tree-select bit at NSYM 4.
fn storeSimpleHuffmanTree(
    w: *BitWriter,
    depths: []const u8,
    symbols: []usize,
    max_bits: u6,
) EmitError!void {
    try w.writeBits(1, 2);
    try w.writeBits(symbols.len - 1, 2);
    // The reference's in-place selection sort: by depth, ascending.
    for (0..symbols.len) |i| {
        for (i + 1..symbols.len) |j| {
            if (depths[symbols[j]] < depths[symbols[i]]) {
                const tmp = symbols[j];
                symbols[j] = symbols[i];
                symbols[i] = tmp;
            }
        }
    }
    for (symbols) |symbol| try w.writeBits(symbol, max_bits);
    if (symbols.len == 4) try w.writeBits(@intFromBool(depths[symbols[0]] == 1), 1);
}

/// §3.5's static code for the code-length code's own lengths: symbols 0-5
/// with the fixed bit patterns.
const code_length_order = [18]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
const code_length_symbols = [6]u8{ 0, 7, 3, 2, 1, 15 };
const code_length_bit_lengths = [6]u8{ 2, 4, 3, 2, 2, 4 };

/// §3.5 — `BrotliStoreHuffmanTreeOfHuffmanTreeToBitMask`: HSKIP and the
/// code-length code's own lengths, in the fixed order, with trailing zeros
/// dropped.
fn storeCodeLengthCode(w: *BitWriter, num_codes: usize, depths: []const u8) EmitError!void {
    var skip_some: usize = 0;
    var codes_to_store: usize = code_length_order.len;
    if (num_codes > 1) {
        while (codes_to_store > 0) : (codes_to_store -= 1) {
            if (depths[code_length_order[codes_to_store - 1]] != 0) break;
        }
    }
    if (depths[code_length_order[0]] == 0 and depths[code_length_order[1]] == 0) {
        skip_some = 2;
        if (depths[code_length_order[2]] == 0) skip_some = 3;
    }
    try w.writeBits(skip_some, 2);
    var i = skip_some;
    while (i < codes_to_store) : (i += 1) {
        const l = depths[code_length_order[i]];
        try w.writeBits(code_length_symbols[l], @intCast(code_length_bit_lengths[l]));
    }
}

/// §3.5 — `BrotliStoreHuffmanTreeToBitMask`: the serialized depth sequence
/// under the code-length code, plus the 16/17 repeats' extra bits.
fn storeTreeToBitMask(
    w: *BitWriter,
    symbols: []const u8,
    extra_bits: []const u8,
    depths: []const u8,
    bits: []const u16,
) EmitError!void {
    for (symbols, extra_bits) |symbol, extra| {
        try w.writeBits(bits[symbol], @intCast(depths[symbol]));
        switch (symbol) {
            16 => try w.writeBits(extra, 2),
            17 => try w.writeBits(extra, 3),
            else => {},
        }
    }
}

/// §3.5 — `BrotliStoreHuffmanTree`: the complex form. The depth sequence is
/// run-length serialized, the code-length code is built over the 18 symbols
/// (tree limit 5), and both are emitted.
fn storeHuffmanTree(
    w: *BitWriter,
    depths: []const u8,
    tree: []huffman.Node,
    scratch: *Scratch,
) EmitError!void {
    var tree_size: usize = 0;
    huffman.writeHuffmanTree(depths, &scratch.tree_symbols, &scratch.tree_extra_bits, &tree_size);
    var histogram: [18]u32 = @splat(0);
    for (scratch.tree_symbols[0..tree_size]) |symbol| histogram[symbol] += 1;
    var num_codes: usize = 0;
    var code: usize = 0;
    for (histogram, 0..) |count, i| {
        if (count != 0) {
            if (num_codes == 0) {
                code = i;
                num_codes = 1;
            } else if (num_codes == 1) {
                num_codes = 2;
                break;
            }
        }
    }
    const cl_depth = &scratch.code_length_depth;
    fastmem.set(u8, cl_depth, 0);
    huffman.createTree(&histogram, 5, tree, cl_depth);
    huffman.convertBitDepthsToSymbols(cl_depth, &scratch.code_length_bits);
    try storeCodeLengthCode(w, num_codes, cl_depth);
    if (num_codes == 1) cl_depth[code] = 0;
    try storeTreeToBitMask(
        w,
        scratch.tree_symbols[0..tree_size],
        scratch.tree_extra_bits[0..tree_size],
        cl_depth,
        &scratch.code_length_bits,
    );
}

/// The reference's `BuildAndStoreHuffmanTree`: count the used symbols; one
/// symbol takes the four-bit form, up to four the simple form, and the rest
/// the complex form.
fn buildAndStoreHuffmanTree(
    w: *BitWriter,
    histogram: []const u32,
    alphabet_size: u16,
    tree: []huffman.Node,
    depths: []u8,
    bits: []u16,
    scratch: *Scratch,
) EmitError!void {
    var count: usize = 0;
    var s4: [4]usize = @splat(0);
    for (histogram, 0..) |count_i, i| {
        if (count_i != 0) {
            if (count < 4) {
                s4[count] = i;
            } else if (count > 4) {
                break;
            }
            count += 1;
        }
    }
    var max_bits: u6 = 0;
    var counter = alphabet_size - 1;
    while (counter != 0) : (counter >>= 1) max_bits += 1;
    if (count <= 1) {
        try w.writeBits(1, 4);
        try w.writeBits(s4[0], max_bits);
        depths[s4[0]] = 0;
        bits[s4[0]] = 0;
        return;
    }
    fastmem.set(u8, depths[0..histogram.len], 0);
    huffman.createTree(histogram, 15, tree, depths);
    huffman.convertBitDepthsToSymbols(depths[0..histogram.len], bits[0..histogram.len]);
    if (count <= 4) {
        try storeSimpleHuffmanTree(w, depths, s4[0..count], max_bits);
    } else {
        try storeHuffmanTree(w, depths[0..histogram.len], tree, scratch);
    }
}

// ---------------------------------------------------------------------------
// The entropy sample
// ---------------------------------------------------------------------------

/// The reference's `kBrotliLog2Table`: log2 of 0..255, 16 digits, as
/// `c/enc/fast_log.c` prints them. The entropy sample's threshold comparison
/// is a floating-point one, so the table is a wire constant.
const log2_table = [256]f64{
    0.0000000000000000, 0.0000000000000000, 1.0000000000000000, 1.5849625007211563,
    2.0000000000000000, 2.3219280948873622, 2.5849625007211561, 2.8073549220576042,
    3.0000000000000000, 3.1699250014423126, 3.3219280948873626, 3.4594316186372978,
    3.5849625007211565, 3.7004397181410922, 3.8073549220576037, 3.9068905956085187,
    4.0000000000000000, 4.0874628412503400, 4.1699250014423122, 4.2479275134435852,
    4.3219280948873626, 4.3923174227787607, 4.4594316186372973, 4.5235619560570131,
    4.5849625007211570, 4.6438561897747244, 4.7004397181410926, 4.7548875021634691,
    4.8073549220576037, 4.8579809951275728, 4.9068905956085187, 4.9541963103868758,
    5.0000000000000000, 5.0443941193584534, 5.0874628412503400, 5.1292830169449664,
    5.1699250014423122, 5.2094533656289501, 5.2479275134435852, 5.2854022188622487,
    5.3219280948873626, 5.3575520046180838, 5.3923174227787607, 5.4262647547020979,
    5.4594316186372973, 5.4918530963296748, 5.5235619560570131, 5.5545888516776376,
    5.5849625007211570, 5.6147098441152083, 5.6438561897747244, 5.6724253419714961,
    5.7004397181410926, 5.7279204545631996, 5.7548875021634691, 5.7813597135246599,
    5.8073549220576046, 5.8328900141647422, 5.8579809951275719, 5.8826430493618416,
    5.9068905956085187, 5.9307373375628867, 5.9541963103868758, 5.9772799234999168,
    6.0000000000000000, 6.0223678130284544, 6.0443941193584534, 6.0660891904577721,
    6.0874628412503400, 6.1085244567781700, 6.1292830169449672, 6.1497471195046822,
    6.1699250014423122, 6.1898245588800176, 6.2094533656289510, 6.2288186904958804,
    6.2479275134435861, 6.2667865406949019, 6.2854022188622487, 6.3037807481771031,
    6.3219280948873626, 6.3398500028846252, 6.3575520046180838, 6.3750394313469254,
    6.3923174227787607, 6.4093909361377026, 6.4262647547020979, 6.4429434958487288,
    6.4594316186372973, 6.4757334309663976, 6.4918530963296748, 6.5077946401986964,
    6.5235619560570131, 6.5391588111080319, 6.5545888516776376, 6.5698556083309478,
    6.5849625007211570, 6.5999128421871278, 6.6147098441152083, 6.6293566200796095,
    6.6438561897747244, 6.6582114827517955, 6.6724253419714961, 6.6865005271832185,
    6.7004397181410926, 6.7142455176661224, 6.7279204545631996, 6.7414669864011465,
    6.7548875021634691, 6.7681843247769259, 6.7813597135246599, 6.7944158663501062,
    6.8073549220576046, 6.8201789624151887, 6.8328900141647422, 6.8454900509443757,
    6.8579809951275719, 6.8703647195834048, 6.8826430493618416, 6.8948177633079437,
    6.9068905956085187, 6.9188632372745955, 6.9307373375628867, 6.9425145053392399,
    6.9541963103868758, 6.9657842846620879, 6.9772799234999168, 6.9886846867721664,
    7.0000000000000000, 7.0112272554232539, 7.0223678130284544, 7.0334230015374501,
    7.0443941193584534, 7.0552824355011898, 7.0660891904577721, 7.0768155970508308,
    7.0874628412503400, 7.0980320829605272, 7.1085244567781700, 7.1189410727235076,
    7.1292830169449664, 7.1395513523987937, 7.1497471195046822, 7.1598713367783891,
    7.1699250014423122, 7.1799090900149345, 7.1898245588800176, 7.1996723448363644,
    7.2094533656289499, 7.2191685204621621, 7.2288186904958804, 7.2384047393250794,
    7.2479275134435861, 7.2573878426926521, 7.2667865406949019, 7.2761244052742384,
    7.2854022188622487, 7.2946207488916270, 7.3037807481771031, 7.3128829552843557,
    7.3219280948873626, 7.3309168781146177, 7.3398500028846252, 7.3487281542310781,
    7.3575520046180838, 7.3663222142458160, 7.3750394313469254, 7.3837042924740519,
    7.3923174227787607, 7.4008794362821844, 7.4093909361377026, 7.4178525148858991,
    7.4262647547020979, 7.4346282276367255, 7.4429434958487288, 7.4512111118323299,
    7.4594316186372973, 7.4676055500829976, 7.4757334309663976, 7.4838157772642564,
    7.4918530963296748, 7.4998458870832057, 7.5077946401986964, 7.5156998382840436,
    7.5235619560570131, 7.5313814605163119, 7.5391588111080319, 7.5468944598876373,
    7.5545888516776376, 7.5622424242210728, 7.5698556083309478, 7.5774288280357487,
    7.5849625007211570, 7.5924570372680806, 7.5999128421871278, 7.6073303137496113,
    7.6147098441152083, 7.6220518194563764, 7.6293566200796095, 7.6366246205436487,
    7.6438561897747244, 7.6510516911789290, 7.6582114827517955, 7.6653359171851765,
    7.6724253419714961, 7.6794800995054464, 7.6865005271832185, 7.6934869574993252,
    7.7004397181410926, 7.7073591320808825, 7.7142455176661224, 7.7210991887071856,
    7.7279204545631996, 7.7347096202258388, 7.7414669864011465, 7.7481928495894605,
    7.7548875021634691, 7.7615512324444795, 7.7681843247769260, 7.7747870596011737,
    7.7813597135246599, 7.7879025593914317, 7.7944158663501062, 7.8008998999203047,
    7.8073549220576037, 7.8137811912170374, 7.8201789624151887, 7.8265484872909159,
    7.8328900141647422, 7.8392037880969445, 7.8454900509443757, 7.8517490414160571,
    7.8579809951275719, 7.8641861446542798, 7.8703647195834048, 7.8765169465650002,
    7.8826430493618416, 7.8887432488982591, 7.8948177633079437, 7.9008668079807496,
    7.9068905956085187, 7.9128893362299619, 7.9188632372745955, 7.9248125036057813,
    7.9307373375628867, 7.9366379390025711, 7.9425145053392399, 7.9483672315846778,
    7.9541963103868758, 7.9600019320680806, 7.9657842846620879, 7.9715435539507720,
    7.9772799234999168, 7.9829935746943104, 7.9886846867721664, 7.9943534368588578,
};

/// The reference's `FastLog2`: the table below 256, `log2` above.
fn fastLog2(v: usize) f64 {
    if (v < log2_table.len) return log2_table[v];
    return @log2(@as(f64, @floatFromInt(v)));
}

/// The reference's `BrotliBitsEntropy`: the population's entropy in bits,
/// floored at one bit per sample.
fn bitsEntropy(population: []const u32) f64 {
    var sum: usize = 0;
    var retval: f64 = 0;
    for (population) |p| {
        sum += p;
        retval -= @as(f64, @floatFromInt(p)) * fastLog2(p);
    }
    if (sum != 0) retval += @as(f64, @floatFromInt(sum)) * fastLog2(sum);
    if (retval < @as(f64, @floatFromInt(sum))) retval = @as(f64, @floatFromInt(sum));
    return retval;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const decode = @import("decode.zig");

/// Encode `source`, decode the stream through the one-shot decoder, and
/// expect identity, with the sentinel rule on the target: the cap is exact,
/// and the byte past the returned length must be untouched.
fn roundTrip(source: []const u8) !void {
    const cap = maxCompressedLength(source.len);
    const target = try testing.allocator.alloc(u8, cap + 1);
    defer testing.allocator.free(target);
    fastmem.set(u8, target, 0xA5);
    const written = try compress(source, target);
    try testing.expect(written <= cap);
    try testing.expectEqual(@as(u8, 0xA5), target[written]);
    const plain = try testing.allocator.alloc(u8, source.len + 1);
    defer testing.allocator.free(plain);
    fastmem.set(u8, plain, 0xA5);
    const decoded = try decode.decompress(target[0..written], plain[0..source.len]);
    try testing.expectEqual(source.len, decoded);
    try testing.expectEqualSlices(u8, source, plain[0..decoded]);
    try testing.expectEqual(@as(u8, 0xA5), plain[decoded]);
}

test "the empty input is the window header plus the empty last meta-block" {
    // The pinned CLI's file form on an empty file: WBITS 10, ISLAST and
    // ISLASTEMPTY, zero fill — `a1 01`.
    var target: [8]u8 = @splat(0);
    const written = try compress("", &target);
    try testing.expectEqualSlices(u8, &.{ 0xa1, 0x01 }, target[0..written]);
}

test "a one-byte input is stored uncompressed" {
    // `bytes <= 2` never compresses (the reference's `ShouldCompress`).
    var target: [16]u8 = @splat(0);
    const written = try compress("A", &target);
    try testing.expectEqualSlices(u8, &.{ 0x21, 0x00, 0x00, 0x04, 0x41, 0x03 }, target[0..written]);
}

test "the window is sized to the input" {
    try testing.expectEqual(@as(u6, 10), windowBitsFor(0));
    try testing.expectEqual(@as(u6, 10), windowBitsFor(1008));
    try testing.expectEqual(@as(u6, 11), windowBitsFor(1009));
    try testing.expectEqual(@as(u6, 12), windowBitsFor(2048));
    try testing.expectEqual(@as(u6, 17), windowBitsFor(65536));
    try testing.expectEqual(@as(u6, 18), windowBitsFor(131072));
    try testing.expectEqual(@as(u6, 19), windowBitsFor(262144));
    try testing.expectEqual(@as(u6, 24), windowBitsFor(1 << 24));
}

test "round trip: shapes through the one-shot" {
    const shapes = [_][]const u8{
        "",
        "A",
        "hello world",
        "the quick brown fox jumps over the lazy dog. " ** 200,
        "\x5a" ** 3000,
        "abcabcabcabcabcabc",
    };
    for (shapes) |shape| try roundTrip(shape);
}

test "round trip: a multi-meta-block input" {
    // 300 KiB crosses the 16-KiB input-block cadence several times and the
    // window-by-size ladder.
    var source: [300 * 1024]u8 = undefined;
    for (&source, 0..) |*byte, i| byte.* = @truncate((i * 7) ^ (i >> 5));
    try roundTrip(&source);
}

test "round trip: incompressible data takes the uncompressed path" {
    var source: [64 * 1024]u8 = undefined;
    var rng: std.Random.DefaultPrng = .init(0x5eed);
    rng.random().bytes(&source);
    try roundTrip(&source);
}

test "maxCompressedLength bounds the stream" {
    // The empty input's two-byte stream and the one-byte input's six.
    try testing.expect(maxCompressedLength(0) >= 2);
    try testing.expect(maxCompressedLength(1) >= 6);
    // The bound is the reference's own worst case: the CLI emitted `N + 11`
    // on a 128-KiB adversarial input, past §11.1's trivial bound.
    try testing.expect(maxCompressedLength(1 << 17) >= (1 << 17) + 11);
}

test "a target smaller than the stream is BufferTooSmall, never a short write" {
    var target: [4]u8 = @splat(0xA5);
    try testing.expectError(error.BufferTooSmall, compress("hello world", &target));
    // Nothing past the cap was touched.
    for (target) |byte| try testing.expectEqual(@as(u8, 0xA5), byte);
    // The exact-size target fits.
    var exact: [16]u8 = @splat(0);
    const written = try compress("hello world", &exact);
    try testing.expectEqual(@as(usize, 16), written);
}
