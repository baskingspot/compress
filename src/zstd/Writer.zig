//! `zstd.Writer`: a compressing `Io.Writer` that produces one Zstandard
//! frame (RFC 8878). `streamAll` and `streamAllAlloc` compress a whole input
//! in one call.
//!
//! One `Writer` writes one frame. Input accumulates in the caller's
//! `Buffer(window_log)` and is emitted as blocks of up to `min(128 KiB,
//! 1 << window_log)` bytes when the block region fills, on `flush`, and on
//! `finish`. Matches reach back across block boundaries into the retained
//! history — `1 << window_log` bytes of earlier input that the buffer holds
//! (`§3.1.1.4`) — so a decoder reading the output so far decodes every byte
//! written: a block boundary is a decode boundary.
//!
//! The frame header is written with the first emission, never at `init`; a
//! `flush` with nothing buffered emits the header alone. Only `finish`
//! writes the frame's last block and its checksum trailer, and it is
//! required. The frame declares no Frame_Content_Size — a streaming writer
//! cannot know the length when the header goes out — so its
//! Window_Descriptor declares `1 << window_log` (`§3.1.1.1.2`) and its
//! frames are never single-segment.
//!
//! Format: docs/research/specs/rfc8878-zstd.txt

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const sentinel = internal.sentinel;
const block = @import("block.zig");
const block_compress = @import("block_compress.zig");
const decode = @import("decode.zig");
const dfast_compress = @import("dfast_compress.zig");
const Dictionary = @import("Dictionary.zig");
const encode = @import("encode.zig");
const frame = @import("frame.zig");
const golden = @import("golden.zig");
const match_compress = @import("match_compress.zig");
const Reader = @import("Reader.zig");
const sequences_compress = @import("sequences_compress.zig");
const split_compress = @import("split_compress.zig");
const common = @import("common.zig");
const writeInt = common.writeInt;

/// The frame's retained history: `1 << window_log` bytes, the frame's
/// Window_Size (`§3.1.1.1.2`).
fn historyLength(comptime window_log: usize) usize {
    return @as(usize, 1) << window_log;
}

/// The block region's length: `min(128 KiB, 1 << window_log)`. It is the
/// C's `ZSTD_getBlockSize`, and it is the frame's Block_Maximum_Size, "the
/// smallest of: Window_Size, 128 KB" (`§3.1.1.2.4`), so no block this writer
/// emits outgrows the window it declares.
fn blockLength(comptime window_log: usize) usize {
    return @min(block.max_block_size, historyLength(window_log));
}

/// The finder's long-table capacity: `1 << 17`, the widest long `hashLog` a
/// frame's own table can take — the level-3 rows' default class width, which
/// a frame that attaches a level-3 dictionary takes even under a small window
/// (an unknown source size clamps nothing in
/// `ZSTD_resetCCtx_byAttachingCDict`). The scans slice the table to the
/// frame's own width; the capacity is the dictionary's.
fn longTableEntries(comptime window_log: usize) usize {
    _ = window_log;
    return dfast_compress.long_table_entries_max;
}

/// The finder's small-table capacity: `1 << 16`, the level-3 rows' widest
/// `chainLog`, on the same reasoning as `longTableEntries`.
fn smallTableEntries(comptime window_log: usize) usize {
    _ = window_log;
    return dfast_compress.small_table_entries_max;
}

/// The sequence list's capacity: every sequence carries a match of at least
/// `min_match_length` bytes, so a block of `blockLength(window_log)` bytes
/// cannot hold more than that many.
fn sequenceCapacity(comptime window_log: usize) usize {
    return blockLength(window_log) / match_compress.min_match_length + 1;
}

/// The caller-owned encode buffer for a frame that declares a
/// `1 << window_log` window (`§3.1.1.1.2`). It holds the retained history
/// and the accumulating block as one contiguous slice — the match finder
/// reads across the boundary (`§3.1.1.4`) — plus the block's literals, the
/// compressed-block scratch, the finder's position table, and the block's
/// sequence list. Every array whose size the window implies lives here, so
/// the writer's own frame is KiB-scale and no allocation happens on any
/// path. `init` takes a pointer to this exact type and reads the window from
/// it, so the buffer and the declared window cannot disagree. `window_log`
/// must be 10 to 31, the format's Window_Log range; `Buffer(0)` does not
/// compile.
pub fn Buffer(comptime window_log: usize) type {
    comptime assert(window_log >= 10 and window_log <= 31);
    return struct {
        /// The finder's source: `historyLength(window_log)` bytes of
        /// retained history, then the accumulating block.
        window: [historyLength(window_log) + blockLength(window_log)]u8,
        /// The block's literals, in the order the finder extracts them.
        literals: [blockLength(window_log)]u8,
        /// The compressed block's output: the raw form's worst case
        /// (`blockLength(window_log) + block.block_header_len` bytes), so
        /// no block can outgrow it.
        target: [blockLength(window_log) + block.block_header_len]u8,
        /// The finder's position tables, one `u32` per hash, zeroed at
        /// `init`; a zeroed slot means "no candidate". A frame that attaches
        /// a dictionary uses the dictionary's own widths (up to 17 long and
        /// 16 small at level 3), so the capacity covers them at every
        /// window; the scans slice the live width.
        long_table: [longTableEntries(window_log)]u32,
        /// dfast's small table; the level-1 finder leaves it unused.
        small_table: [smallTableEntries(window_log)]u32,
        /// The block's sequence list.
        sequences: [sequenceCapacity(window_log)]sequences_compress.Sequence,
    };
}

/// The default window log, 19: a 512 KiB window, the largest level 1
/// declares. It stays inside the decoder's default 8 MiB window
/// (`Reader.default_window_len`), so a default `Reader` decodes any frame
/// this writer produces.
pub const default_window_log: usize = 19;

/// The level-3 default window log, 21: the dfast class's own window (the
/// `clevels.h` default row's `W`), which the CLI's `zstd -3` declares. A
/// level-3 `Writer` needs `Buffer(21)` to reach the class's window.
pub const level3_default_window_log: usize = 21;

/// The default window log for a level: `default_window_log` for level 1,
/// `level3_default_window_log` for level 3 (and for an unimplemented level,
/// which never writes a frame).
pub fn defaultWindowLog(level: u8) usize {
    return if (level == 3) level3_default_window_log else default_window_log;
}

/// `Buffer(default_window_log)`: about 2.2 MiB, larger than a typical thread
/// stack, so allocate it, as `streamAllAlloc` does.
pub const DefaultBuffer = Buffer(default_window_log);

const Writer = @This();

/// The `Io.Writer` interface: write the frame's input through `&w.writer`.
writer: Io.Writer,
/// The sink the frame is written to.
output: *Io.Writer,
/// The options given to `init`, fixed for the stream's lifetime.
options: encode.Options,
/// The caller's buffer, as slices: the finder's source (history then the
/// accumulating block), the block's literals, the compressed-block scratch,
/// the position tables, and the sequence list.
window: []u8,
literals: []u8,
target: []u8,
tables: block_compress.Tables,
sequences: []sequences_compress.Sequence,
/// The frame's window size, `1 << window_log`, stored at `init`.
window_len: usize,
/// The block region's length, `min(128 KiB, window_len)`.
block_len: usize,
/// Where the buffered block begins in `window`: the retained history's
/// length.
block_start: usize = 0,
/// The finder's parameters, from `window_log`.
params: match_compress.Params,
/// The frame's cross-block encoding state (`block_compress.State`): the
/// entropy layers' tables, the repeat offsets, and the XXH64 fold.
state: block_compress.State = .{},
/// The dictionary this frame compresses against, `null` for none: the
/// entropy seed, the match region, and the ID the header names.
dictionary: ?*const Dictionary = null,
/// The dictionary's match state as the blocks see it (`block_compress.Dict`).
dict: block_compress.Dict = .{},
/// The frame position of `window[0]`: 0 until `compact` slides the window.
/// It bounds the dictionary's validity (`§5`: the content stops being
/// addressable once the output passes Window_Size) and is the base the
/// attach scan's offsets count from.
frame_start: usize = 0,
/// The frame header goes out with the first emission, never at `init`.
header_written: bool = false,
/// The frame's block bytes emitted so far and the frame bytes produced so
/// far (the header and every block); the pre-splitter's `savings` is their
/// difference (`zstd_compress.c:4602,4837`).
block_consumed: i64 = 0,
block_produced: i64 = 0,
/// Set by `finish`: the next block emitted carries Last_Block
/// (`§3.1.1.2.1`).
final: bool = false,

/// The C's running `savings` (`consumed - produced`): the frame's input
/// consumed minus its output produced, the header included. The dfast
/// pre-splitter runs only once it is at least 3.
fn savings(w: *const Writer) i64 {
    return w.block_consumed - w.block_produced;
}

/// The shared writer machinery (`src/internal/writer.zig`): the generated
/// `drain`, `flush`, and `rebase` entries and the poisoned `finish`, over
/// this writer's `emitBlock` and `writeTrailer`. The stream ending is the
/// checksum trailer alone; the last *block* carries Last_Block, which
/// `finish` sets `final` for and `emitBlock` reads.
const Hooks = internal.writer.VTable(Writer, emitBlock, writeTrailer);

/// Start a Zstandard frame into `output`, accumulating input in `buffer`.
/// The frame declares a `1 << window_log` window and no Frame_Content_Size
/// (`§3.1.1.1.2`). `window_log` must be 10 to 31. `options` are fixed for
/// the stream's lifetime; changing `w.options` afterwards is not supported.
/// Write through `&w.writer`, then call `finish`. `init` writes nothing,
/// allocates nothing, and zeroes the finder's tables.
///
/// `options.level` must be 1 or 3 (the implemented classes); any other level
/// poisons the writer, so every write and `finish` returns
/// `error.WriteFailed` and `output` sees no byte.
pub fn init(
    comptime window_log: usize,
    output: *Io.Writer,
    buffer: *Buffer(window_log),
    options: encode.Options,
) Writer {
    const window_len = historyLength(window_log);
    const block_len = blockLength(window_log);
    var w: Writer = .{
        .writer = .{
            .buffer = buffer.window[0..block_len],
            .end = 0,
            .vtable = &Hooks.vtable,
        },
        .output = output,
        .options = options,
        .window = &buffer.window,
        .literals = &buffer.literals,
        .target = &buffer.target,
        .tables = .{ .long = &.{} },
        .sequences = &buffer.sequences,
        .window_len = window_len,
        .block_len = block_len,
        // The C's streaming class: an unknown source size picks the default
        // row's widths and minMatch, and the caller's window_log replaces
        // the row's windowLog. An unimplemented level never compresses (the
        // writer is poisoned below), so its parameters are the level-1 ones.
        .params = match_compress.forStreaming(
            if (encode.implemented(options.level)) options.level else 1,
            @intCast(window_log),
        ),
    };
    // The dictionary, when one is given: its entropy tables seed the frame's
    // state, its CDict tables are looked up by the attach scan, and its ID
    // goes into the header. A dictionary with no content attaches nothing but
    // still seeds the state and names the ID (the C's `cdictLen == 0`
    // carve-out).
    w.dictionary = options.dict;
    if (options.dict) |d| {
        block_compress.seedFromDict(&w.state, d);
        if (d.content.len > 0) {
            const dict_params = d.matchParams(options.level);
            w.dict = .{
                .content = d.content,
                .table = if (options.level == 1) &d.match else null,
                .dfast = if (options.level == 3) &d.match_dfast else null,
                .window_size = window_len,
                .low_limit = d.content.len,
                .dict_limit = d.content.len,
                .valid = true,
            };
            // The C's attach path takes the dictionary's own table widths and
            // `minMatch` for the frame (`ZSTD_resetCCtx_byAttachingCDict`
            // adjusts the CDict's parameters; with an unknown source size
            // nothing clamps them), keeping only the caller's window.
            w.params.hash_log = dict_params.hash_log;
            w.params.chain_log = dict_params.chain_log;
            w.params.mls = dict_params.mls;
        }
    }
    // The tables hold window-relative positions and start zeroed; a zeroed
    // slot is "no candidate" (the finders' candidate floors), as the C
    // zeroes its tables at reset. The scans take the frame's own widths,
    // whatever the buffer's capacity covers.
    assert(w.params.hash_log <= 17);
    assert(w.params.chain_log <= 16);
    w.tables = .{
        .long = buffer.long_table[0 .. @as(usize, 1) << @intCast(w.params.hash_log)],
        .small = if (options.level == 3)
            buffer.small_table[0 .. @as(usize, 1) << @intCast(w.params.chain_log)]
        else
            &.{},
    };
    fastmem.set(u32, w.tables.long, 0);
    if (w.tables.small.len > 0) fastmem.set(u32, w.tables.small, 0);
    // An unimplemented level must not silently alias the implemented ones:
    // poisoning the interface makes every write and `finish` return
    // `error.WriteFailed`, before a byte of output.
    if (!encode.implemented(options.level)) w.writer = .failing;
    return w;
}

/// Complete the frame: emit the buffered block as the frame's last block,
/// write the checksum trailer, and flush `output`. The frame is complete
/// only after this call, and the writer is unusable afterwards.
///
/// Returns `error.WriteFailed` if `output` fails. A writer that already
/// failed or already finished also returns `error.WriteFailed`, so a
/// truncated frame is never reported as complete. An empty writer still
/// writes a frame: the header, one raw zero-size last block, and the
/// checksum.
pub fn finish(w: *Writer) Io.Writer.Error!void {
    // The last block's header is the one thing the block layer cannot know
    // when the block is emitted, so `finish` records it and `emitBlock`
    // reads it.
    w.final = true;
    return Hooks.finish(w);
}

/// Compress everything `in` yields into one complete Zstandard frame in
/// `out`, and return the number of input bytes consumed. The frame is
/// finished and `out` is flushed before the call returns; `in` is consumed
/// exactly through its end. Writes through `buffer`, a
/// `Buffer(window_log)` the caller owns (about 2.2 MiB at the default
/// `window_log`), so this needs no large stack local of its own.
///
/// Returns `error.WriteFailed` if `out` fails or if `options.level` is not
/// implemented (the writer is poisoned at `init`, so nothing is written),
/// and `error.ReadFailed` if `in` fails. Does not allocate.
pub fn streamAll(
    comptime window_log: usize,
    in: *Io.Reader,
    out: *Io.Writer,
    buffer: *Buffer(window_log),
    options: encode.Options,
) Io.Reader.StreamRemainingError!usize {
    var ww: Writer = .init(window_log, out, buffer, options);
    const n = try in.streamRemaining(&ww.writer);
    try ww.finish();
    return n;
}

/// The error set of `streamAllAlloc`: `streamAll`'s (`error.ReadFailed`,
/// `error.WriteFailed`) plus `error.OutOfMemory` from the buffer allocation.
pub const StreamAllocError = Io.Reader.StreamRemainingError || error{OutOfMemory};

/// `streamAll` with the default window log for the level: 19 for level 1,
/// 21 for level 3 (the dfast class's window). Allocates one `DefaultBuffer`
/// (about 2.2 MiB) or `Buffer(level3_default_window_log)` (about 3.6 MiB)
/// from `allocator` for the call and frees it before returning; the writer
/// itself allocates nothing. Returns `error.OutOfMemory`, before reading any
/// input, if the allocation fails. A caller who wants a different window, or
/// no allocation, uses `streamAll` with its own `Buffer(window_log)`.
pub fn streamAllAlloc(
    allocator: mem.Allocator,
    in: *Io.Reader,
    out: *Io.Writer,
    options: encode.Options,
) StreamAllocError!usize {
    if (options.level == 3) {
        const buffer = try allocator.create(Buffer(level3_default_window_log));
        defer allocator.destroy(buffer);
        return streamAll(level3_default_window_log, in, out, buffer, options);
    }
    const buffer = try allocator.create(DefaultBuffer);
    defer allocator.destroy(buffer);
    return streamAll(default_window_log, in, out, buffer, options);
}

/// Emit the first `emit_len` bytes of the buffered block as one zstd block,
/// then slide the window past them: the emitted bytes become history, so
/// nothing moves until the history grows past `window_len` (`compact`). The
/// generated entries in `src/internal/writer.zig` rely on the unemitted tail
/// ending up at the front of the block region (`writer.end -= emit_len`).
///
/// A full 128-KiB block whose frame has already saved at least 3 bytes is
/// offered to the dfast pre-splitter (`split_compress`), which can cut it
/// into several blocks — the C's own `ZSTD_compress_frameChunk` loop — so one
/// call may write more than one block; every emitted byte still leaves
/// `writer.end -= emit_len`.
///
/// A zero-length emission still writes the frame header if it is not out
/// yet — a `flush` with nothing buffered emits the header alone — and, when
/// `finish` set `final`, the frame's empty last block, because `§3.1.1.2`
/// requires "at least 1 block" in every frame.
fn emitBlock(w: *Writer, emit_len: usize) Io.Writer.Error!void {
    assert(emit_len <= w.writer.end);
    try writeHeader(w);
    if (emit_len == 0) {
        if (w.final) try writeEmptyLastBlock(w);
        return;
    }
    var scratch: block_compress.Scratch = .{
        .literals = w.literals,
        .sequences = w.sequences,
    };
    w.dict.frame_start = w.frame_start;
    var emitted: usize = 0;
    while (emitted < emit_len) {
        const remaining = emit_len - emitted;
        const size = split_compress.optimalBlockSize(
            w.params.level,
            w.window[0 .. w.block_start + emit_len],
            w.block_start + emitted,
            remaining,
            w.block_len,
            w.savings(),
        );
        const written = block_compress.writeBlock(
            &w.state,
            &w.dict,
            &scratch,
            w.params,
            w.tables,
            // The finder's source: the retained history, then the block. Its
            // prefix bounds every emitted offset to the declared window
            // (`§3.1.1.4`).
            w.window[0 .. w.block_start + emit_len],
            w.block_start + emitted,
            size,
            w.target,
            w.final and emitted + size == emit_len,
        ) catch unreachable; // `target` is the raw form's worst case
        assert(written <= w.target.len);
        try w.output.writeAll(w.target[0..written]);
        w.block_consumed += @intCast(size);
        w.block_produced += @intCast(written);
        emitted += size;
    }

    w.writer.end -= emit_len;
    w.block_start += emit_len;
    if (w.block_start + w.block_len > w.window.len) w.compact();
    w.writer.buffer = w.window[w.block_start..][0..w.block_len];
}

/// Write the frame header (`§3.1.1.1`): the Magic_Number, the
/// Frame_Header_Descriptor, and the Window_Descriptor. The descriptor names
/// no dictionary and sets the checksum flag; its Frame_Content_Size_Flag is
/// 0, and Single_Segment_Flag with it, so FCS_Field_Size is 0
/// (`§3.1.1.1.1.1`) — the streaming form cannot know the frame's length when
/// the header goes out, and the window is declared instead. The C writes the
/// same six bytes for `zstd -1` over a pipe.
fn writeHeader(w: *Writer) Io.Writer.Error!void {
    if (w.header_written) return;
    var header: [stream_header_len_max]u8 = undefined;
    writeInt(u32, header[0..frame.magic_len], frame.magic);
    const dict_id: u32 = if (w.dictionary) |d| d.id else 0;
    const dict_id_code: u2 = @intFromBool(dict_id > 0) +
        @as(u2, @intFromBool(dict_id >= 256)) +
        @as(u2, @intFromBool(dict_id >= 65536));
    header[frame.magic_len] = frame.descriptor_checksum | @as(u8, dict_id_code);
    header[frame.magic_len + 1] = frame.window.descriptor(w.params.window_log);
    var cursor: usize = frame.magic_len + 2;
    switch (dict_id_code) {
        0 => {},
        1 => {
            header[cursor] = @truncate(dict_id);
            cursor += 1;
        },
        2 => {
            writeInt(u16, header[cursor..][0..2], @truncate(dict_id));
            cursor += 2;
        },
        else => {
            writeInt(u32, header[cursor..][0..4], dict_id);
            cursor += 4;
        },
    }
    try w.output.writeAll(header[0..cursor]);
    w.header_written = true;
    // The C counts the frame header in the frame's produced bytes with the
    // first block (`ZSTD_compress_frameChunk`'s `cSize + fhSize`).
    w.block_produced += @intCast(cursor);
}

/// `§3.1.1.2` — "Each frame must have at least 1 block": the frame an empty
/// writer produces is the header, one raw zero-size Last_Block, and the
/// checksum, the same block bytes the one-shot's empty frame carries.
fn writeEmptyLastBlock(w: *Writer) Io.Writer.Error!void {
    var header: [block.block_header_len]u8 = undefined;
    block_compress.writeBlockHeader(&header, true, .raw, 0);
    try w.output.writeAll(&header);
}

/// Write the Content_Checksum (`§3.1.1`): "the low 4 bytes of the checksum
/// are stored in little-endian format" — the XXH64 of every input byte, seed
/// zero, folded per block by the block layer.
fn writeTrailer(w: *Writer) Io.Writer.Error!void {
    var trailer: [frame.checksum_len]u8 = undefined;
    writeInt(u32, &trailer, w.state.checksum.final());
    try w.output.writeAll(&trailer);
}

/// The frame header's length: the magic, the descriptor, and the
/// Window_Descriptor, with no Frame_Content_Size field.
/// The streaming frame header's cap: the magic, the descriptor, the window
/// descriptor, and the widest 4-byte Dictionary_ID field.
const stream_header_len_max = frame.magic_len + 1 + 1 + 4;

/// Slide the history and the buffered block to the front of the window,
/// trimming the history to `window_len` — the farthest a match may reach
/// (`§3.1.1.4`). The caller re-derives the block region from `block_start`.
/// The finder's table holds window-relative positions, so every entry drops
/// by the bytes the slide discarded (`block_compress.rebaseTable`).
fn compact(w: *Writer) void {
    const keep = @min(w.block_start, w.window_len);
    const slide = w.block_start - keep;
    if (slide != 0) {
        fastmem.move(u8, w.window[0..keep], w.window[slide..][0..keep]);
        fastmem.move(
            u8,
            w.window[keep..][0..w.writer.end],
            w.window[w.block_start..][0..w.writer.end],
        );
        block_compress.rebaseTable(w.tables, slide);
        w.frame_start += slide;
    }
    w.block_start = keep;
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc8878-zstd.txt §3.1.1 (the frame and
// its checksum), §3.1.1.1 (the header's forms), §3.1.1.2 (the block chain),
// §3.1.1.4 (offsets and the window), §3.1.1.5 (the repeat offsets). Every
// frame is decoded back through the landed `Reader` (the windowed path) and
// its bytes past the decoded length checked; the CLI v1.5.7 verdicts on the
// recorded fixtures are in `golden.zig`.
// ---------------------------------------------------------------------------

/// The encode buffer, on the heap: `Buffer(19)` is about 1.4 MiB and the
/// decode buffer adds 768 KiB, so the tests keep both off the stack.
fn makeBuffer(comptime window_log: usize) !*Buffer(window_log) {
    return testing.allocator.create(Buffer(window_log));
}

fn makeReaderBuffer(comptime window_len: usize) !*Reader.Buffer(window_len) {
    return testing.allocator.create(Reader.Buffer(window_len));
}

/// Encode `source` through a `Writer` at `window_log` in `chunk`-sized
/// writes (`chunk == 0` means one write), decode the frame through the
/// landed `Reader` at the same window log, and require identity with the
/// sentinel rule. Returns the frame's length.
fn expectRoundTrip(comptime window_log: usize, source: []const u8, chunk: usize) !usize {
    return expectRoundTripLevel(window_log, source, chunk, .{});
}

/// `expectRoundTrip` at an explicit level: the frame's options are threaded
/// through, so a level-3 writer (and a dictionary) round-trips the same way.
fn expectRoundTripLevel(
    comptime window_log: usize,
    source: []const u8,
    chunk: usize,
    options: encode.Options,
) !usize {
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const buffer = try makeBuffer(window_log);
    defer gpa.destroy(buffer);
    var w: Writer = .init(window_log, &out.writer, buffer, options);
    var pos: usize = 0;
    const step = if (chunk == 0) @max(source.len, 1) else chunk;
    while (pos < source.len) {
        const n = @min(step, source.len - pos);
        try w.writer.writeAll(source[pos..][0..n]);
        pos += n;
    }
    try w.finish();

    const plain = try gpa.alloc(u8, source.len + sentinel.len);
    defer gpa.free(plain);
    sentinel.fill(plain);
    const rbuffer = try makeReaderBuffer(historyLength(window_log));
    defer gpa.destroy(rbuffer);
    var fixed: Io.Reader = .fixed(out.written());
    var r: Reader = .init(historyLength(window_log), &fixed, rbuffer, options.dict);
    var plain_out: Io.Writer = .fixed(plain);
    const written = try r.reader.streamRemaining(&plain_out);
    try testing.expectEqual(source.len, written);
    try testing.expectEqualSlices(u8, source, plain[0..written]);
    try sentinel.expect(plain, written);
    return out.written().len;
}

test "Writer: the empty frame is the header, one empty last block, and the checksum" {
    // RFC 8878 §3.1.1.2 — "Each frame must have at least 1 block": a
    // `finish` with nothing written is the 6-byte streaming header, a raw
    // zero-size Last_Block, and the XXH64 of nothing — 13 bytes, and the
    // same 13 the one-shot writes with its single-segment header.
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const buffer = try makeBuffer(default_window_log);
    defer gpa.destroy(buffer);
    var w: Writer = .init(default_window_log, &out.writer, buffer, .{});
    try w.finish();
    try testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x28, 0xb5, 0x2f, 0xfd, // Magic_Number
            0x04, // descriptor: no FCS, not single-segment, checksum
            0x48, // Window_Descriptor: exponent 9, so a 512 KiB window
            0x01, 0x00, 0x00, // raw, last, size 0
            0x99, 0xe9, 0xd8, 0x51, // XXH64("") low 4 bytes, little-endian
        },
        out.written(),
    );
}

test "Writer: the frame header declares the window and no Frame_Content_Size" {
    // RFC 8878 §3.1.1.1.1.1 — "When Frame_Content_Size_Flag is 0,
    // FCS_Field_Size depends on Single_Segment_Flag: if Single_Segment_Flag
    // is set, FCS_Field_Size is 1, otherwise 0": the streaming form's flag
    // and single-segment bit are both clear, so the header is the magic, the
    // descriptor, and the Window_Descriptor — and `§3.1.1.1.2`'s arithmetic
    // gives back exactly `1 << window_log`.
    const gpa = testing.allocator;
    inline for (.{ 10, 15, 19, 22 }) |window_log| {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const buffer = try makeBuffer(window_log);
        defer gpa.destroy(buffer);
        var w: Writer = .init(window_log, &out.writer, buffer, .{});
        try w.writer.writeAll("hello, zstd");
        try w.finish();
        const header = try frame.parseHeader(out.written()[frame.magic_len..]);
        try testing.expectEqual(@as(usize, 2), header.bytes_consumed);
        try testing.expectEqual(frame.descriptor_checksum, header.descriptor);
        try testing.expectEqual(@as(?u64, null), header.content_size);
        try testing.expectEqual(@as(u64, 1) << window_log, header.window_size);
        try testing.expect(header.checksum);
    }
}

test "Writer: the zero-data flush writes the header alone" {
    // The lazy header's corner: a `flush` with nothing buffered emits the
    // header and no block, and the writer stays usable. Nothing else reaches
    // `output` before the block region fills or `flush` is called.
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const buffer = try makeBuffer(default_window_log);
    defer gpa.destroy(buffer);
    var w: Writer = .init(default_window_log, &out.writer, buffer, .{});
    try testing.expectEqual(@as(usize, 0), out.written().len);
    try w.writer.flush();
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x04, 0x48 },
        out.written(),
    );
    // The header is written once, whatever mix of writes and flushes
    // follows.
    const phrase = "the quick brown fox jumps over the lazy dog. ";
    try w.writer.writeAll(phrase ** 8);
    try w.writer.flush();
    try testing.expect(out.written().len > 6);
    try w.finish();
    const plain = try gpa.alloc(u8, phrase.len * 8 + sentinel.len);
    defer gpa.free(plain);
    sentinel.fill(plain);
    const written = try decode.decompress(out.written(), plain[0 .. phrase.len * 8], null);
    try testing.expectEqual(@as(usize, phrase.len * 8), written);
    try testing.expectEqualSlices(u8, phrase ** 8, plain[0..written]);
    try sentinel.expect(plain, written);
}

test "Writer: round-trips through the landed Reader" {
    // RFC 8878 §3.1.1 — the frame's decoded output is the source, byte for
    // byte, over every corpus shape and across the sizes that straddle the
    // block and window boundaries: the empty frame, one block, blocks that
    // fill the region exactly, and multi-block streams that slide the
    // window.
    var source: [600 * 1024]u8 = undefined;
    const sizes = [_]usize{
        0,      1,      6,      7,      8,      31,     32,     100,
        255,    256,    1024,   4096,   16384,  32768,  65536,  131071,
        131072, 131073, 200000, 262144, 300000, 524288, 524289, 600 * 1024,
    };
    for ([_]golden.Shape{ .text, .rle, .random, .skewlit }) |shape| {
        for (sizes) |size| {
            golden.fillShape(shape, source[0..size]);
            _ = expectRoundTrip(default_window_log, source[0..size], 0) catch |err| {
                std.debug.print("FAIL: {s} size {d}\n", .{ @tagName(shape), size });
                return err;
            };
        }
    }
    for ([_]golden.Shape{ .html, .mixed, .words, .zeros }) |shape| {
        for ([_]usize{ 100, 4096, 65536, 131072, 300000 }) |size| {
            golden.fillShape(shape, source[0..size]);
            _ = expectRoundTrip(default_window_log, source[0..size], 0) catch |err| {
                std.debug.print("FAIL: {s} size {d}\n", .{ @tagName(shape), size });
                return err;
            };
        }
    }
}

test "Writer: single-byte writes and every block size round-trip" {
    // The write sizes a caller actually uses: one byte at a time through the
    // `drain` path, and the small window logs whose block region is far
    // below 128 KiB.
    var source: [40 * 1024]u8 = undefined;
    golden.fillShape(.text, &source);
    _ = try expectRoundTrip(default_window_log, source[0..37], 1);
    _ = try expectRoundTrip(default_window_log, source[0..4096], 1);
    _ = try expectRoundTrip(default_window_log, &source, 1);
    golden.fillShape(.mixed, &source);
    inline for (.{ 10, 12, 14, 17 }) |window_log| {
        _ = try expectRoundTrip(window_log, source[0..3000], 1);
        _ = try expectRoundTrip(window_log, &source, 997);
    }
}

test "Writer: the block split follows the block region, not the write sizes" {
    // A block boundary is where the block region fills, so the same input
    // produces the same frame whatever the caller's write sizes were — and
    // the frame's blocks are exactly the region's length, as the CLI's are
    // (§3.1.1.2.4's Block_Maximum_Size).
    const gpa = testing.allocator;
    const source = try gpa.alloc(u8, 3 * block_compress.max_block_size + 17);
    defer gpa.free(source);
    golden.fillShape(.random, source);

    var one: Io.Writer.Allocating = .init(gpa);
    defer one.deinit();
    const buffer = try makeBuffer(default_window_log);
    defer gpa.destroy(buffer);
    var w: Writer = .init(default_window_log, &one.writer, buffer, .{});
    try w.writer.writeAll(source);
    try w.finish();

    var chunked: Io.Writer.Allocating = .init(gpa);
    defer chunked.deinit();
    var w2: Writer = .init(default_window_log, &chunked.writer, buffer, .{});
    var pos: usize = 0;
    var step: usize = 1;
    while (pos < source.len) {
        const n = @min(source.len - pos, step);
        try w2.writer.writeAll(source[pos..][0..n]);
        pos += n;
        step = (step * 3 + 1) % 100_000;
    }
    try w2.finish();
    try testing.expectEqualSlices(u8, one.written(), chunked.written());

    // The block chain: incompressible input cannot beat the raw form, so
    // each block's Block_Size is its uncompressed length — three exactly
    // the block region's length, the last one the remainder, carrying
    // Last_Block (`§3.1.1.2.1`, `§3.1.1.2.2`).
    var cursor = headerLenFor(one.written());
    var blocks: usize = 0;
    while (true) {
        const header = try block.parseHeader(one.written()[cursor..]);
        blocks += 1;
        try testing.expectEqual(block.BlockType.raw, header.block_type);
        if (!header.last_block) {
            try testing.expectEqual(block_compress.max_block_size, header.block_size);
        } else {
            try testing.expectEqual(@as(usize, 17), header.block_size);
        }
        cursor += block.block_header_len + block.contentLength(header);
        if (header.last_block) break;
    }
    try testing.expectEqual(@as(usize, 4), blocks);
    try testing.expectEqual(one.written().len - frame.checksum_len, cursor);
    _ = try expectRoundTrip(default_window_log, source, 0);
    // The same split for a compressible shape, decoded back.
    golden.fillShape(.text, source);
    _ = try expectRoundTrip(default_window_log, source, 0);
}

test "Writer: flush mid-stream ends at a block boundary" {
    // The flush contract (EQ7): a mid-stream `flush` emits the buffered data
    // as one complete block and leaves the writer usable, so the bytes
    // written so far are a whole number of blocks — a decoder reading them
    // decodes every byte written. Only `finish` writes Last_Block.
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const buffer = try makeBuffer(default_window_log);
    defer gpa.destroy(buffer);
    var w: Writer = .init(default_window_log, &out.writer, buffer, .{});
    try w.writer.writeAll("hello, ");
    try w.writer.flush();
    const first = out.written().len;
    try testing.expect(first > 6);

    // The chain so far: complete blocks, none of them last, ending exactly
    // at the flush's byte count.
    var cursor = headerLenFor(out.written());
    var blocks: usize = 0;
    while (cursor < out.written().len) {
        const header = try block.parseHeader(out.written()[cursor..]);
        try testing.expect(!header.last_block);
        cursor += block.block_header_len + block.contentLength(header);
        blocks += 1;
    }
    try testing.expectEqual(@as(usize, 1), blocks);
    try testing.expectEqual(out.written().len, cursor);

    // A second flush with nothing buffered changes nothing, and the frame
    // still decodes to the concatenation.
    try w.writer.flush();
    try testing.expectEqual(first, out.written().len);
    try w.writer.writeAll("zstd");
    try w.finish();
    const plain = try gpa.alloc(u8, @as(usize, 11) + sentinel.len);
    defer gpa.free(plain);
    sentinel.fill(plain);
    const written = try decode.decompress(out.written(), plain[0..11], null);
    try testing.expectEqualStrings("hello, zstd", plain[0..written]);
    try sentinel.expect(plain, written);
}

test "Writer: matches reach back across emitted blocks and the sliding window" {
    // RFC 8878 §3.1.1.4 — "all offsets leading to previously decoded data
    // must be smaller than Window_Size": the second half of this stream is a
    // copy of the first, so it compresses only through the retained history
    // — across block boundaries, and across the window slides a 4 KiB window
    // forces on a 40 KiB stream.
    const gpa = testing.allocator;
    const window_log = 12;
    const period = historyLength(window_log) / 2;
    const source = try gpa.alloc(u8, 40 * 1024);
    defer gpa.free(source);
    var rng: DefaultPrng = .init(0x0DDBA11);
    for (source[0..period]) |*byte| byte.* = rng.random().int(u8);
    var offset: usize = period;
    while (offset < source.len) : (offset += period) {
        const n = @min(period, source.len - offset);
        fastmem.copy(u8, source[offset..][0..n], source[0..n]);
    }
    // The 4 KiB window slides eight times over this stream; every repeat is
    // a match at distance `period`, reachable only through the retained
    // history.
    const frame_len = try expectRoundTrip(window_log, source, 4096);
    try testing.expect(frame_len < source.len / 4);
}

test "Writer: the one-shot and the Writer agree on every block byte" {
    // The two encoders share the block layer, and for an input over 256 KiB
    // they also share the finder's parameters (the one-shot's size ladder
    // picks windowLog 19, hashLog 14, minMatch 7; the writer's streaming
    // class is the same). Only the header form differs: the one-shot
    // declares the exact Frame_Content_Size, the writer declares the window.
    const gpa = testing.allocator;
    var source: [600 * 1024]u8 = undefined;
    golden.fillShape(.text, &source);

    const one_shot = try gpa.alloc(u8, encode.maxCompressedLength(source.len));
    defer gpa.free(one_shot);
    const one_shot_len = try encode.compress(&source, one_shot, .{});

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const buffer = try makeBuffer(default_window_log);
    defer gpa.destroy(buffer);
    var w: Writer = .init(default_window_log, &out.writer, buffer, .{});
    try w.writer.writeAll(&source);
    try w.finish();

    const one_shot_header = headerLenFor(one_shot[0..one_shot_len]);
    const writer_header = headerLenFor(out.written());
    try testing.expectEqual(@as(usize, 10), one_shot_header);
    try testing.expectEqual(@as(usize, 6), writer_header);
    try testing.expectEqualSlices(
        u8,
        one_shot[one_shot_header .. one_shot_len - frame.checksum_len],
        out.written()[writer_header .. out.written().len - frame.checksum_len],
    );
    try testing.expectEqualSlices(
        u8,
        one_shot[one_shot_len - frame.checksum_len .. one_shot_len],
        out.written()[out.written().len - frame.checksum_len ..],
    );
}

test "Writer: the CLI's own streaming frames, byte for byte" {
    // RFC 8878 §3.1.1.1.1.1 — the FCS-unknown header form, and the class the
    // C picks when the source size is unknown: the CLI's `zstd -1` over a
    // pipe and this writer's frames are the same bytes, header, blocks, and
    // trailer, on every recorded fixture. Each decodes through our decoder
    // back to the shape. The empty input is the one case the CLI writes
    // differently — it knows the length at the frame's end, so its empty
    // frame is the single-segment 13 bytes the one-shot writes.
    const gpa = testing.allocator;
    var source: [300 * 1024]u8 = undefined;
    const cases = [_]struct {
        name: []const u8,
        shape: golden.Shape,
        size: usize,
        expected: []const u8,
    }{
        .{
            .name = "text-1024",
            .shape = .text,
            .size = 1024,
            .expected = &golden.encode_stream_text_1024,
        },
        .{
            .name = "html-32768",
            .shape = .html,
            .size = 32768,
            .expected = &golden.encode_stream_html_32768,
        },
        .{
            .name = "rle-65536",
            .shape = .rle,
            .size = 65536,
            .expected = &golden.encode_stream_rle_65536,
        },
        .{
            .name = "text-131073",
            .shape = .text,
            .size = 131073,
            .expected = &golden.encode_stream_text_131073,
        },
        .{
            .name = "words-4096",
            .shape = .words,
            .size = 4096,
            .expected = &golden.encode_stream_words_4096,
        },
    };
    for (cases) |case| {
        const input = source[0..case.size];
        golden.fillShape(case.shape, input);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const buffer = try makeBuffer(default_window_log);
        defer gpa.destroy(buffer);
        var w: Writer = .init(default_window_log, &out.writer, buffer, .{});
        try w.writer.writeAll(input);
        try w.finish();
        try testing.expectEqual(case.expected.len, out.written().len);
        try testing.expectEqualSlices(u8, case.expected, out.written());
        const plain = try gpa.alloc(u8, input.len + sentinel.len);
        defer gpa.free(plain);
        sentinel.fill(plain);
        const written = try decode.decompress(case.expected, plain[0..input.len], null);
        try testing.expectEqual(input.len, written);
        try testing.expectEqualSlices(u8, input, plain[0..written]);
        try sentinel.expect(plain, written);
    }
}

test "Writer: a small window still compresses against a dictionary" {
    // RFC 8878 §5 — the dictionary's own `hashLog` (15 for a small
    // dictionary) decides the frame's table width even under a 1-KiB
    // window: `ZSTD_resetCCtx_byAttachingCDict` adjusts the CDict's
    // parameters and an unknown source size clamps nothing, so the buffer's
    // table capacity must cover the dictionary's width, not the window's.
    const gpa = testing.allocator;
    const trained = try Dictionary.parse(golden.dict_trained);
    var source: [8 * 1024]u8 = undefined;
    golden.fillShape(.text, &source);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const buffer = try gpa.create(Buffer(10));
    defer gpa.destroy(buffer);
    var w: Writer = .init(10, &out.writer, buffer, .{ .dict = &trained });
    try w.writer.writeAll(&source);
    try w.finish();
    const plain = try gpa.alloc(u8, source.len + sentinel.len);
    defer gpa.free(plain);
    sentinel.fill(plain);
    const written = try decode.decompress(out.written(), plain[0..source.len], &trained);
    try testing.expectEqual(source.len, written);
    try testing.expectEqualSlices(u8, &source, plain[0..written]);
    try sentinel.expect(plain, written);
}

test "Writer: the with-dictionary frames are the CLI's pipe-form bytes" {
    // RFC 8878 §5 — the streaming form's parity class with a dictionary: the
    // CLI never knows a pipe's length, so it always attaches the dictionary
    // (`ZSTD_shouldAttachDict`), and our `Writer`'s frame reproduces
    // `zstd -D dict-trained.bin -1 -c` byte for byte on every recorded
    // fixture. Each decodes back through our decoder with the dictionary.
    const gpa = testing.allocator;
    const trained = try Dictionary.parse(golden.dict_trained);
    var source: [300 * 1024]u8 = undefined;
    const cases = [_]struct {
        name: []const u8,
        shape: golden.Shape,
        size: usize,
        expected: []const u8,
    }{
        .{
            .name = "text-8193",
            .shape = .text,
            .size = 8193,
            .expected = &golden.dict_encode_stream_text_8193,
        },
        .{
            .name = "html-65536",
            .shape = .html,
            .size = 65536,
            .expected = &golden.dict_encode_stream_html_65536,
        },
        .{
            .name = "text-265000",
            .shape = .text,
            .size = 265000,
            .expected = &golden.dict_encode_stream_text_265000,
        },
    };
    for (cases) |case| {
        const input = source[0..case.size];
        golden.fillShape(case.shape, input);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const buffer = try makeBuffer(default_window_log);
        defer gpa.destroy(buffer);
        var w: Writer = .init(default_window_log, &out.writer, buffer, .{ .dict = &trained });
        try w.writer.writeAll(input);
        try w.finish();
        try testing.expectEqual(case.expected.len, out.written().len);
        try testing.expectEqualSlices(u8, case.expected, out.written());
        const plain = try gpa.alloc(u8, input.len + sentinel.len);
        defer gpa.free(plain);
        sentinel.fill(plain);
        const written = try decode.decompress(out.written(), plain[0..input.len], &trained);
        try testing.expectEqual(input.len, written);
        try testing.expectEqualSlices(u8, input, plain[0..written]);
        try sentinel.expect(plain, written);
    }
}

test "Writer: a finished or failed writer never reports a false success" {
    // `finish` after a failed write, after `finish`, and writes after
    // `finish` must all report `error.WriteFailed` — a truncated frame must
    // not be reported as complete.
    const gpa = testing.allocator;

    // Finish after a failed write: the write buffers fine (it fits the block
    // region), the emission fails into the full fixed output, and `finish`
    // must report it — twice, not a false success the second time.
    var small: [8]u8 = undefined;
    var fixed_out: Io.Writer = .fixed(&small);
    const buffer = try makeBuffer(default_window_log);
    defer gpa.destroy(buffer);
    var w: Writer = .init(default_window_log, &fixed_out, buffer, .{});
    try w.writer.writeAll("a" ** 4096);
    try testing.expectError(error.WriteFailed, w.finish());
    try testing.expectError(error.WriteFailed, w.finish());

    // Write and finish after finish.
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var w2: Writer = .init(default_window_log, &out.writer, buffer, .{});
    try w2.writer.writeAll("hello, zstd");
    try w2.finish();
    try testing.expectError(error.WriteFailed, w2.writer.writeAll("more"));
    try testing.expectError(error.WriteFailed, w2.finish());
}

test "Writer: level 3 round-trips through the landed Reader" {
    // RFC 8878 §3.1.1 — the dfast class's streaming frames decode to the
    // source through the landed `Reader`, over the shapes and the sizes that
    // straddle the block and window boundaries.
    var source: [600 * 1024]u8 = undefined;
    const sizes = [_]usize{
        0,      1,      6,      7,      8,      31,     32,     100,
        255,    256,    1024,   4096,   16384,  32768,  65536,  131071,
        131072, 131073, 200000, 262144, 300000, 524288, 524289, 600 * 1024,
    };
    for ([_]golden.Shape{ .text, .rle, .random, .skewlit }) |shape| {
        for (sizes) |size| {
            golden.fillShape(shape, source[0..size]);
            _ = try expectRoundTripLevel(
                level3_default_window_log,
                source[0..size],
                0,
                .{ .level = 3 },
            );
        }
    }
    for ([_]golden.Shape{ .html, .mixed, .words, .zeros }) |shape| {
        for ([_]usize{ 100, 4096, 65536, 131072, 300000 }) |size| {
            golden.fillShape(shape, source[0..size]);
            _ = try expectRoundTripLevel(
                level3_default_window_log,
                source[0..size],
                0,
                .{ .level = 3 },
            );
        }
    }
    // Chunked writes, the single-byte path included.
    golden.fillShape(.text, &source);
    _ = try expectRoundTripLevel(level3_default_window_log, source[0..37], 1, .{ .level = 3 });
    _ = try expectRoundTripLevel(level3_default_window_log, source[0..4096], 1, .{ .level = 3 });
    golden.fillShape(.mixed, &source);
    inline for (.{ 14, 17, 21 }) |window_log| {
        _ = try expectRoundTripLevel(window_log, source[0..3000], 1, .{ .level = 3 });
        _ = try expectRoundTripLevel(window_log, &source, 997, .{ .level = 3 });
    }
}

test "Writer: level 3 attaches a dictionary and round-trips it" {
    // RFC 8878 §5 — a streaming writer never knows its length, so a level-3
    // writer always attaches the dictionary as a separate match state
    // (`ZSTD_shouldAttachDict`), at the dictionary's own table widths.
    const trained = try Dictionary.parse(golden.dict_trained);
    var source: [300 * 1024]u8 = undefined;
    for ([_]golden.Shape{ .text, .rle, .random, .words }) |shape| {
        for ([_]usize{ 0, 100, 4096, 8192, 16385, 65536, 200000 }) |size| {
            golden.fillShape(shape, source[0..size]);
            _ = try expectRoundTripLevel(
                level3_default_window_log,
                source[0..size],
                0,
                .{ .level = 3, .dict = &trained },
            );
        }
    }
}

test "Writer: the level-3 pumps take the class's window" {
    // `streamAllAlloc` at level 3 allocates `Buffer(21)` — the dfast class's
    // own window, the `clevels.h` default row's `W` — and the frame declares
    // it: 2 MiB, the window the CLI's `zstd -3` pipe form declares.
    const gpa = testing.allocator;
    var source: [64 * 1024]u8 = undefined;
    golden.fillShape(.text, &source);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var in: Io.Reader = .fixed(&source);
    const consumed = try streamAllAlloc(gpa, &in, &out.writer, .{ .level = 3 });
    try testing.expectEqual(source.len, consumed);
    const header = try frame.parseHeader(out.written()[frame.magic_len..]);
    try testing.expectEqual(@as(u64, 1) << 21, header.window_size);
    try testing.expectEqual(@as(?u64, null), header.content_size);
    try testing.expectEqual(
        @as(usize, 21),
        defaultWindowLog(3),
    );
    try testing.expectEqual(@as(usize, 19), defaultWindowLog(1));
    try testing.expectEqual(@as(usize, 19), defaultWindowLog(2));
}

test "Writer: the unimplemented levels are rejected, never silently aliased" {
    // Levels 2 and 4-19 are not implemented: they poison the writer at
    // `init`, so every write and `finish` returns
    // `error.WriteFailed` and the sink sees nothing.
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const buffer = try makeBuffer(default_window_log);
    defer gpa.destroy(buffer);
    for ([_]u8{ 0, 2, 4, 19, 20 }) |level| {
        var w: Writer = .init(default_window_log, &out.writer, buffer, .{ .level = level });
        try testing.expectError(error.WriteFailed, w.writer.writeAll("hello, zstd"));
        try testing.expectError(error.WriteFailed, w.finish());
        try testing.expectEqual(@as(usize, 0), out.written().len);
    }
}

test "Writer: random write machinery sequences stay correct" {
    // Mixed writeSplatAll/writeVecAll/writableSliceGreedy+advance/writeByte/
    // flush sequences, decoded with the one-shot decoder: this catches
    // `drain` and `rebase` accounting errors under the full vtable contract
    // (multi-slice data with splat, partial straddling takes, direct-slice
    // writes onto a full block region).
    const gpa = testing.allocator;
    var rng: DefaultPrng = .init(99);
    const rand = rng.random();

    var iter: usize = 0;
    while (iter < 40) : (iter += 1) {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var expect: std.ArrayList(u8) = .empty;
        defer expect.deinit(gpa);
        const buffer = try makeBuffer(default_window_log);
        defer gpa.destroy(buffer);
        var w: Writer = .init(default_window_log, &out.writer, buffer, .{});

        var ops: usize = 0;
        while (ops < 8) : (ops += 1) {
            var a: [3000]u8 = undefined;
            var b: [40000]u8 = undefined;
            var pattern: [7]u8 = undefined;
            rand.bytes(&a);
            rand.bytes(&b);
            rand.bytes(&pattern);
            const a_len = rand.uintAtMost(usize, a.len);
            const b_len = rand.uintAtMost(usize, b.len);
            const p_len = rand.intRangeAtMost(usize, 1, pattern.len);
            const splat = rand.uintAtMost(usize, 30000);
            switch (rand.uintLessThan(u8, 5)) {
                0 => {
                    var data = [_][]const u8{ a[0..a_len], b[0..b_len], pattern[0..p_len] };
                    try w.writer.writeSplatAll(&data, splat);
                    try expect.appendSlice(gpa, a[0..a_len]);
                    try expect.appendSlice(gpa, b[0..b_len]);
                    for (0..splat) |_| try expect.appendSlice(gpa, pattern[0..p_len]);
                },
                1 => {
                    var data = [_][]const u8{ a[0..a_len], b[0..b_len] };
                    try w.writer.writeVecAll(&data);
                    try expect.appendSlice(gpa, a[0..a_len]);
                    try expect.appendSlice(gpa, b[0..b_len]);
                },
                2 => {
                    try w.writer.splatBytesAll(pattern[0..p_len], splat);
                    for (0..splat) |_| try expect.appendSlice(gpa, pattern[0..p_len]);
                },
                3 => {
                    // The File.Reader simple-mode path: a direct write into
                    // the block region, which lands on `rebase` when it is
                    // full.
                    const dest = try w.writer.writableSliceGreedy(1);
                    const n = @min(dest.len, b_len);
                    for (dest[0..n], b[0..n]) |*d, x| d.* = x;
                    w.writer.advance(n);
                    try expect.appendSlice(gpa, b[0..n]);
                },
                else => {
                    try w.writer.writeByte(pattern[0]);
                    try expect.append(gpa, pattern[0]);
                    if (rand.boolean()) try w.writer.flush();
                },
            }
        }
        try w.finish();

        const target = try gpa.alloc(u8, expect.items.len + sentinel.len);
        defer gpa.free(target);
        sentinel.fill(target);
        const n = try decode.decompress(out.written(), target, null);
        try testing.expectEqual(expect.items.len, n);
        try testing.expectEqualSlices(u8, expect.items, target[0..n]);
        try sentinel.expect(target, n);
    }
}

test "Writer: the streamAll pumps round-trip a whole input" {
    // `streamAll` and `streamAllAlloc` are the Reader's mirror: consume `in`
    // exactly, write one finished frame, return the input's length.
    const gpa = testing.allocator;
    const source = try gpa.alloc(u8, 300 * 1024);
    defer gpa.free(source);
    golden.fillShape(.mixed, source);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const buffer = try makeBuffer(default_window_log);
    defer gpa.destroy(buffer);
    var fixed_in: Io.Reader = .fixed(source);
    const consumed = try streamAll(default_window_log, &fixed_in, &out.writer, buffer, .{});
    try testing.expectEqual(source.len, consumed);
    // `in` is consumed exactly: the frame's end is the input's end.
    try testing.expectEqual(@as(usize, 0), fixed_in.bufferedLen());

    const allocated = try streamAllAlloc(gpa, &fixed_in, &out.writer, .{});
    try testing.expectEqual(@as(usize, 0), allocated);

    const plain = try gpa.alloc(u8, source.len + sentinel.len);
    defer gpa.free(plain);
    sentinel.fill(plain);
    const written = try decode.decompress(out.written(), plain[0..source.len], null);
    try testing.expectEqual(source.len, written);
    try testing.expectEqualSlices(u8, source, plain[0..written]);
    try sentinel.expect(plain, written);
}

test "Writer: the buffer sizes are the documented ones" {
    // The caller sizes thread stacks and allocations from these figures
    // (the README's), so they are pinned here: the history, the block
    // region, the literals, the emission target, the finder's tables, and
    // the sequence list, all from `window_log`.
    try testing.expectEqual(@as(usize, 1024), historyLength(10));
    try testing.expectEqual(@as(usize, 1024), blockLength(10));
    try testing.expectEqual(@as(usize, 128 * 1024), blockLength(19));
    try testing.expectEqual(@as(usize, 1) << 17, longTableEntries(19));
    try testing.expectEqual(@as(usize, 1) << 16, smallTableEntries(19));
    try testing.expectEqual(@as(usize, 131072 / 3 + 1), sequenceCapacity(19));
    // The default buffer, field by field, plus whatever alignment pads.
    const expected = 1024 * 1024 / 2 + 128 * 1024 + // history | block
        128 * 1024 + // literals
        128 * 1024 + 3 + // target
        (1 << 17) * 4 + // long table (the level-3 dictionary's widest hashLog)
        (1 << 16) * 4 + // small table (the level-3 dictionary's widest chainLog)
        (131072 / 3 + 1) * @sizeOf(sequences_compress.Sequence); // sequences
    // The sum, plus the alignment padding before the u32 tables.
    try testing.expectEqual(expected + 1, @sizeOf(DefaultBuffer));
    try testing.expectEqual(@as(usize, 2_228_232), @sizeOf(DefaultBuffer));
    // A small window keeps the same table capacity: the dictionary's widths
    // do not follow the window.
    try testing.expectEqual(@as(usize, 1) << 17, longTableEntries(10));
    try testing.expectEqual(@as(usize, 1) << 16, smallTableEntries(10));
}

/// The frame header's length, from the parsed descriptor: the magic, the
/// descriptor, the optional Window_Descriptor, and the Frame_Content_Size
/// field (`§3.1.1.1`).
fn headerLenFor(frame_bytes: []const u8) usize {
    const header = frame.parseHeader(frame_bytes[frame.magic_len..]) catch unreachable;
    return frame.magic_len + header.bytes_consumed;
}
