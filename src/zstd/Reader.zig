//! `zstd.Reader`: a decompressing `Io.Reader` over one Zstandard frame
//! (RFC 8878). `streamFrame` and `streamAll` decode in one call.
//!
//! A `Reader` decodes one frame and stops at its exact end: the last byte of
//! the checksum trailer if the frame has one, else the last block's last
//! byte. Skippable frames before the frame are consumed and ignored. Later
//! bytes stay unread, so the caller can start another `Reader` there;
//! `streamAll` does this for a whole input.
//!
//! The caller owns the decode buffer, `Buffer(window_len)`. A frame whose
//! Window_Size exceeds `window_len` fails with `WindowTooLarge` before any
//! block is read. A contiguous `peek` or `take` of up to 128 KiB is always
//! served. A failed read returns `error.ReadFailed` and the detail is in
//! `err`. Decoding a compressed block uses a 128 KiB buffer on the stack.
//!
//! Format: docs/specs/rfc8878-zstd.txt

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
const block = @import("block.zig");
const common = @import("common.zig");
const readInt = common.readInt;
const writeInt = common.writeInt;
/// A parsed dictionary (§5), the value both directions take.
const Dictionary = @import("Dictionary.zig");
const frame = @import("frame.zig");
const golden = @import("golden.zig");
const xxh64 = @import("xxh64.zig");

/// The block staging room `Buffer(window_len)` adds on top of the serving
/// region: one block's whole content, staged because both backwards
/// bitstreams need the block's end first (`§3.1.1.3.2.1.2`). A frame the
/// buffer admits declares Window_Size ≤ `window_len` (`checkWindow`), so its
/// Block_Maximum_Size, "the smallest of: Window_Size, 128 KB"
/// (`§3.1.1.2.4`), is at most `min(window_len, max_block_size)`.
fn stagingLength(comptime window_len: usize) usize {
    return @min(window_len, block.max_block_size);
}

/// The caller-owned decode buffer for frames whose Window_Size is at most
/// `window_len` (`§3.1.1.1.2`). It holds `window_len` bytes of retained
/// history plus one maximum-size block (128 KiB, `§3.1.1.2.4`) as the
/// serving region, then room to stage one block's content (`stagingLength`):
/// `window_len + 128 KiB + min(window_len, 128 KiB)` bytes in all. `init`
/// takes a pointer to this exact type and reads the window cap from it, so
/// the buffer and the cap cannot disagree. `window_len` must be at least
/// 1 KiB, the smallest window the format allows; `Buffer(0)` does not
/// compile.
pub fn Buffer(comptime window_len: usize) type {
    comptime assert(window_len >= 1024);
    return [window_len + block.max_block_size + stagingLength(window_len)]u8;
}

/// The default window cap, 8 MiB. `§3.1.1.1.2` recommends that decoders
/// support Window_Size up to 8 MB, and `zstd -19` writes windowLog 23 (8 MiB)
/// for large inputs.
pub const default_window_len: usize = 8 * 1024 * 1024;

/// `Buffer(default_window_len)`: 8 MiB of window, 128 KiB serving, and
/// 128 KiB staging. That is larger than a typical 8 MiB thread stack, so
/// allocate it, as `streamFrameAlloc` does.
pub const DefaultBuffer = Buffer(default_window_len);

/// The reader's error set; `err` holds one of these once `state == .failed`.
/// It is the one-shot decoder's `DecompressError` (`frame.Error`) without
/// `BufferTooSmall` (the window is the caller's buffer, not a target cap, so
/// no decode can outgrow it), plus `WindowTooLarge`, `StreamTooLong`, and the
/// interface's `ReadFailed` and `EndOfStream`. The `Io.Reader` interface
/// itself reports only `error.ReadFailed` or `error.EndOfStream`.
pub const Error = error{
    BadMagic,
    ReservedBitSet,
    DictionaryRequired,
    DictionaryMismatch,
    BlockOversize,
    ReservedBlock,
    MalformedLiteralsHeader,
    LiteralsTooLarge,
    TreelessLiteralsFirst,
    MalformedHuffmanWeights,
    MalformedFseTable,
    MalformedSequencesHeader,
    RepeatModeFirst,
    ReservedModeBits,
    MissingStartBit,
    InvalidBitStream,
    BitstreamNotConsumed,
    ZeroOffset,
    OffsetTooFar,
    ContentSizeMismatch,
    WrongChecksum,
    Truncated,
    /// The frame declares a Window_Size larger than the buffer's `window_len`
    /// (`§3.1.1.1.2`: a decoder may reject a frame that "requests a memory
    /// size beyond the decoder's authorized range"). Reported once the header
    /// is parsed, before any block byte is read; the output is never
    /// truncated instead.
    WindowTooLarge,
    /// A contiguous request (`peek`, `take`, ...) is larger than the serving
    /// region can hold at the consumer's position. Requests of up to 128 KiB
    /// never hit this. A consumer can trigger it, so it is an error and not
    /// an assert.
    StreamTooLong,
    /// The input reader failed with `error.ReadFailed`.
    ReadFailed,
    /// The clean end of the frame. The interface reports it as
    /// `error.EndOfStream`; it is never recorded in `err`.
    EndOfStream,
};

comptime {
    // The set is the frame layer's, minus `BufferTooSmall`, plus the four
    // names this layer adds: a frame-layer error the reader forgot, or one it
    // invented, fails the build here (the `decode.zig` vocabulary check, one
    // layer up).
    @setEvalBranchQuota(100_000);
    const own = [_][]const u8{ "WindowTooLarge", "StreamTooLong", "ReadFailed", "EndOfStream" };
    const frame_set = @typeInfo(frame.Error).error_set.?;
    const mine = @typeInfo(Error).error_set.?;
    assert(mine.len == frame_set.len - 1 + own.len);
    for (frame_set) |want| {
        var found = false;
        for (mine) |entry| {
            if (mem.eql(u8, entry.name, want.name)) found = true;
        }
        // `BufferTooSmall` is the one name the reader does not carry: its
        // window is the caller's buffer, and every output path is bounded by
        // the room the block phase guarantees.
        assert(found == !mem.eql(u8, want.name, "BufferTooSmall"));
    }
    for (own) |name| {
        var found = false;
        for (mine) |entry| {
            if (mem.eql(u8, entry.name, name)) found = true;
        }
        assert(found);
    }
}

/// The frame's phase: the resume point across pump calls.
const Phase = union(enum) {
    /// The first frame unit's Magic_Number. The input's end here is
    /// `Truncated`: no frame unit began, so a zero-byte input is an error for a
    /// single reader. (`streamAll` checks for the input's end itself before it
    /// starts a reader, so for the walk an empty input is the clean end.)
    start,
    /// A skippable frame's User_Data (`§3.1.2`): `left` bytes still to skip,
    /// then the next unit's magic.
    skip: usize,
    /// The next frame unit's Magic_Number, after a skippable frame was
    /// consumed. The input's end here is the clean end: a stream of only
    /// skippable frames decodes to zero bytes.
    magic,
    /// The Frame_Header (`§3.1.1.1`), fed to the byte-fed parser.
    header,
    /// The block chain (`§3.1.1.2`).
    blocks,
    /// The last block is decoded; the frame end, meaning the Frame_Content_Size
    /// check and the Content_Checksum trailer (`§3.1.1.1.4`, `§3.1.1`), is next.
    trailer,
};

const Reader = @This();

reader: Io.Reader,
/// The frame's input, consumed exactly through the frame's last byte. Its
/// buffer must hold at least four bytes, the frame layer's largest fixed-size
/// read (the magic, a skippable frame's Frame_Size, or the checksum trailer;
/// the 3-byte Block_Header fits inside), unless the input ends sooner. A
/// smaller buffer trips the assert in `Io.Reader.fill`. std's decoder names
/// the same class of failure `InputBufferUndersize`.
input: *Io.Reader,
/// The block staging room: the last `stagingLength(window_len)` bytes of the
/// caller's buffer, where each block's content is staged before it is
/// decoded (`§3.1.1.3.2.1.2`). It lives in the caller's buffer so that the
/// reader needs no large stack local.
staging: []u8,
/// The window cap: the buffer type's `window_len`, stored at `init`.
window_len: usize,
/// The Frame_Header parse (`§3.1.1.1`), run across fills.
header: frame.HeaderParser = .{},
/// One frame's cross-block decode state (`frame.State`): the parsed header,
/// the two entropy layers' tables, the frame's decoded length, and the XXH64
/// fold. Present once the header is parsed.
frame_state: ?frame.State = null,
/// The dictionary (`§5`) a frame may start from: its ID is checked against
/// the frame's Dictionary_ID once the header is parsed, its tables seed the
/// frame state, and its content is the preset history. `null` is the
/// no-dictionary reader. Borrowed for the reader's life.
dict: ?*const Dictionary = null,
phase: Phase = .start,
/// The stream lifecycle (`src/internal/reader.zig`): `streaming` until the
/// frame's trailer is verified (`done`) or a failure sticks (`failed`,
/// details in `err`).
state: State = .streaming,
/// Detailed error once `state == .failed`; the interface reports
/// `error.ReadFailed`.
err: ?Error = null,

/// The `Io.Reader` entries, generated by `internal.reader.VTable`. `pump` is
/// this reader's fill and `rebase` its capacity policy; the generator supplies
/// the sticky-failure guard and the zero-length poll.
const vtable = VTable(Reader, pump, rebase).vtable;

/// Read one Zstandard frame from `input`, decoding through `buffer`.
/// Skippable frames before the frame are skipped. `window_len` is the largest
/// Window_Size the reader accepts, and `buffer` must be a
/// `Buffer(window_len)`, which the compiler checks at the call. `dict` seeds
/// the frame's starting state (`§5`): its entropy tables, its repeat offsets,
/// and its content as the preset history. `null` is the no-dictionary reader;
/// a frame that names a nonzero Dictionary_ID then fails `DictionaryRequired`
/// (or `DictionaryMismatch` when a non-matching dictionary was supplied).
/// `input` needs a buffer of at least four bytes. `init` reads nothing from
/// `input` and allocates nothing.
///
/// Read through `&r.reader` (`stream`, the `read` family, the `peek` family).
/// Once the trailer is verified, reads return `error.EndOfStream`. A
/// malformed frame or a failing `input` returns `error.ReadFailed`, and so
/// does every later read, with the detail in `err`. The reader consumes
/// `input` exactly through the frame's last byte and leaves any later bytes
/// unread.
pub fn init(
    comptime window_len: usize,
    input: *Io.Reader,
    buffer: *Buffer(window_len),
    dict: ?*const Dictionary,
) Reader {
    // The serving region is the buffer's front `window_len + max_block_size`
    // bytes; the staging room is its tail.
    const serving_len = window_len + block.max_block_size;
    return .{
        .reader = .{
            .buffer = buffer[0..serving_len],
            .seek = 0,
            .end = 0,
            .vtable = &vtable,
        },
        .staging = buffer[serving_len..],
        .input = input,
        .window_len = window_len,
        .dict = dict,
    };
}

/// Decode one frame from `in` into `out` through `buffer`, and return the
/// number of bytes written. Skippable frames before the frame are skipped
/// (`§3.1.2`). `dict` seeds the frame's starting state (`§5`), as
/// `Reader.init`'s. `in` is consumed exactly through the frame's last byte
/// (the checksum trailer's, when the frame has one) and later bytes are left
/// unread. An empty `in` is an error, because it holds no frame. `in` needs a
/// buffer of at least four bytes. Failures are reported as `error.ReadFailed`
/// (a malformed frame or a failing `in`) or `error.WriteFailed` (a failing
/// `out`); a caller who needs the detail drives a `Reader` directly and reads
/// `err`. Does not allocate.
pub fn streamFrame(
    comptime window_len: usize,
    in: *Io.Reader,
    out: *Io.Writer,
    buffer: *Buffer(window_len),
    dict: ?*const Dictionary,
) Io.Reader.StreamRemainingError!usize {
    var rr: Reader = .init(window_len, in, buffer, dict);
    return rr.reader.streamRemaining(out);
}

/// Decode every frame in `in` into `out` through `buffer`, and return the
/// total number of bytes written. The output is the concatenation of the
/// frames (`§3.1`). Each frame is decoded as in `streamFrame`, starting where
/// the previous one ended. Skippable frames are skipped, so an input that
/// holds only skippable frames, or nothing at all, decodes to zero bytes. Any
/// other bytes where a frame starts are `BadMagic`, reported as
/// `error.ReadFailed`; they are not skipped. `dict` seeds every frame's
/// starting state (`§5`), as `Reader.init`'s. `in` needs a buffer of at least
/// four bytes. Other failures are reported as in `streamFrame`. Does not
/// allocate.
pub fn streamAll(
    comptime window_len: usize,
    in: *Io.Reader,
    out: *Io.Writer,
    buffer: *Buffer(window_len),
    dict: ?*const Dictionary,
) Io.Reader.StreamRemainingError!usize {
    var rr: Reader = undefined;
    var served: usize = 0;
    while (true) {
        // A clean end between units is the file's end; any byte where a unit
        // should start is parsed as one, so garbage returns an error.
        _ = in.peekByte() catch |err| switch (err) {
            error.EndOfStream => return served,
            else => |e| return e,
        };
        rr = .init(window_len, in, buffer, dict);
        served += try rr.reader.streamRemaining(out);
    }
}

/// The error set of `streamFrameAlloc` and `streamAllAlloc`: `streamFrame`'s
/// (`error.ReadFailed`, `error.WriteFailed`) plus `error.OutOfMemory` from the
/// buffer allocation.
pub const StreamAllocError = Io.Reader.StreamRemainingError || error{OutOfMemory};

/// `streamFrame` with the default 8 MiB window. Allocates a `DefaultBuffer`
/// (8 MiB + 256 KiB) from `allocator` for the call and frees it before
/// returning; the decoder itself allocates nothing. Returns
/// `error.OutOfMemory`, before reading any input, if the allocation fails. A
/// caller who wants a smaller window, or no allocation, uses `streamFrame`
/// with its own `Buffer(window_len)`.
pub fn streamFrameAlloc(
    allocator: mem.Allocator,
    in: *Io.Reader,
    out: *Io.Writer,
    dict: ?*const Dictionary,
) StreamAllocError!usize {
    const buffer = try allocator.create(DefaultBuffer);
    defer allocator.destroy(buffer);
    return streamFrame(default_window_len, in, out, buffer, dict);
}

/// `streamAll` with the default 8 MiB window. Allocates a `DefaultBuffer`
/// (8 MiB + 256 KiB) from `allocator` for the call and frees it before
/// returning; the decoder itself allocates nothing. Returns
/// `error.OutOfMemory`, before reading any input, if the allocation fails.
pub fn streamAllAlloc(
    allocator: mem.Allocator,
    in: *Io.Reader,
    out: *Io.Writer,
    dict: ?*const Dictionary,
) StreamAllocError!usize {
    const buffer = try allocator.create(DefaultBuffer);
    defer allocator.destroy(buffer);
    return streamAll(default_window_len, in, out, buffer, dict);
}

/// The vtable's fill. Passes `fillFrame`'s detailed errors through `record`,
/// so the interface sees `error.ReadFailed` (detail in `err`) or, once the
/// trailer is verified, the clean `error.EndOfStream`.
fn pump(r: *Reader) Io.Reader.Error!usize {
    return r.record(r.fillFrame());
}

/// The one place a detailed failure becomes the interface's coarse error.
fn record(r: *Reader, result: Error!usize) Io.Reader.Error!usize {
    return result catch |err| switch (err) {
        error.EndOfStream => {
            r.state = .done;
            return error.EndOfStream;
        },
        else => return r.fail(err),
    };
}

/// Record `err` as the sticky failure and return the interface's
/// `error.ReadFailed`. The serving region's unconsumed bytes are dropped, so
/// no partial output is trusted past an error (the flate reader does the
/// same).
fn fail(r: *Reader, err: Error) Io.Reader.Error {
    r.reader.seek = r.reader.end;
    return internal.reader.fail(Error, &r.state, &r.err, err);
}

/// One frame fill: the unit's magic, header, and blocks into the serving
/// region, until the frame's output is complete (the frame end is next, run
/// by the following fill or by `rebase`) or the region cannot take another
/// block. Returns the bytes added — never zero without an error, unless the
/// frame's output is complete.
fn fillFrame(r: *Reader) Error!usize {
    var added: usize = 0;
    while (r.state == .streaming) {
        switch (r.phase) {
            .start => {
                // The input ended before any frame unit began: a zero-byte
                // input is `Truncated`.
                const kind = (try r.readMagic()) orelse return error.Truncated;
                try r.beginUnit(kind);
            },
            .magic => {
                // The input ended after a skippable frame: the clean end, so a
                // stream of only skippable frames serves zero bytes (`§3.1.2`).
                const kind = (try r.readMagic()) orelse return error.EndOfStream;
                try r.beginUnit(kind);
            },
            .skip => |left| {
                try r.skipUserData(left);
                r.phase = .magic;
            },
            .header => try r.readHeader(),
            .blocks => {
                // Room for the next block's output: the frame's
                // Block_Maximum_Size (`§3.1.1.2.4`). A full serving region
                // slides, keeping the consumer's unconsumed bytes and the
                // retained history. If the slide cannot make room, return
                // what this fill has added so far, or `StreamTooLong` when
                // that is nothing. A consumer can cause this with a large
                // contiguous request, so it is an error and not an assert.
                const room_needed = r.blockRoom();
                if (r.reader.buffer.len - r.reader.end < room_needed) {
                    const room = r.slide();
                    if (room < room_needed) {
                        if (added == 0) return error.StreamTooLong;
                        return added;
                    }
                }
                added += try r.decodeBlock();
                // After the last block, return its bytes before running the
                // frame end (the Frame_Content_Size check and the checksum
                // trailer). A mismatch found at the frame end is then
                // reported by the next fill, after the frame's output has
                // been served, and the trailer is read exactly once, by the
                // first call that finds nothing more to add. `rebase` runs
                // the same frame end for a request that reaches past the
                // frame's tail.
                if (r.phase == .trailer) return added;
            },
            .trailer => try r.endFrame(),
        }
    }
    if (added == 0) return error.EndOfStream;
    return added;
}

/// The next frame unit's Magic_Number (`§3.1`, `§3.1.2`): its kind, or null
/// when the input ends at a unit boundary (an empty remainder — the caller
/// decides what that means). Fewer than four bytes left is the input's end
/// inside a unit: `Truncated`.
fn readMagic(r: *Reader) Error!?frame.Kind {
    r.input.fill(frame.magic_len) catch |err| switch (err) {
        error.EndOfStream => {
            if (r.input.seek == r.input.end) return null;
            return error.Truncated;
        },
        error.ReadFailed => return error.ReadFailed,
    };
    const bytes = r.input.buffer[r.input.seek..][0..frame.magic_len];
    const kind = frame.classify(bytes) catch |err| {
        // The four bytes are buffered: the classifier cannot see a short
        // slice, so `BadMagic` is the only failure left.
        assert(err == error.BadMagic);
        return error.BadMagic;
    };
    r.input.toss(frame.magic_len);
    return kind;
}

/// Start the frame unit whose Magic_Number was just read: a Zstandard frame's
/// Frame_Header is next; a skippable frame's Frame_Size — "the size, in
/// bytes, of the following User_Data (without including the magic number nor
/// the size field itself)" (`§3.1.2`) — is read, and its User_Data is next.
fn beginUnit(r: *Reader, kind: frame.Kind) Error!void {
    switch (kind) {
        .zstandard => r.phase = .header,
        .skippable => {
            const bytes = try r.readFixed(frame.frame_size_len);
            r.phase = .{ .skip = @intCast(readInt(u32, &bytes)) };
        },
    }
}

/// The Frame_Header (`§3.1.1.1`, Table 2), fed to the byte-fed parser: it
/// consumes as much as its current field needs, so a reader whose input
/// buffers only the magic's four bytes parses the 2-14 byte header across
/// fills. The input's end inside it is `Truncated`; the parser's own
/// refusals (the reserved bit, a Dictionary_ID) land where the frame layer
/// raises them. Once parsed, the header is checked against the buffer's
/// window (`WindowTooLarge`) and the block chain begins.
fn readHeader(r: *Reader) Error!void {
    while (!r.header.done()) {
        r.input.fill(1) catch |err| switch (err) {
            error.EndOfStream => return error.Truncated,
            error.ReadFailed => return error.ReadFailed,
        };
        const buffered = r.input.buffer[r.input.seek..r.input.end];
        const consumed = r.header.feed(buffered) catch |err| switch (err) {
            // The parser raises the header's own refusals (the reserved bit,
            // a Dictionary_ID) and nothing else, so `BufferTooSmall`, which
            // the reader's error set does not carry, cannot occur here.
            // Return an error rather than turn a broken invariant into
            // undefined behavior.
            error.BufferTooSmall => {
                assert(false);
                return error.Truncated;
            },
            else => |e| return e,
        };
        // `feed` consumes at least one byte while the header is incomplete,
        // so the loop always progresses (or fails).
        assert(consumed > 0);
        r.input.toss(consumed);
    }
    const header = r.header.header();
    // §3.1.1.1.3 + §5 — the Dictionary_ID check, before any block byte.
    try frame.checkDictionary(header, r.dict);
    // §3.1.1.1.2 — "a decoder is allowed to reject a compressed frame that
    // requests a memory size beyond the decoder's authorized range": the
    // caller's buffer is the authorization, checked once, before any block
    // byte is read.
    try frame.checkWindow(header, r.window_len);
    // In place through the optional's payload: the layer states' ~10 KiB of
    // table payload stays undefined until a block builds it (frame.State.init).
    r.frame_state = @as(frame.State, undefined);
    r.frame_state.?.init(header, r.dict);
    r.phase = .blocks;
}

/// Skip a skippable frame's User_Data (`§3.1.2`): the bytes are skipped by
/// streaming through the input, never staged, so a 4 GiB Frame_Size costs the
/// walk and no memory. The input's end inside the User_Data is `Truncated`.
fn skipUserData(r: *Reader, count: usize) Error!void {
    var left = count;
    while (left > 0) {
        if (r.input.seek == r.input.end) {
            r.input.fill(1) catch |err| switch (err) {
                error.EndOfStream => return error.Truncated,
                error.ReadFailed => return error.ReadFailed,
            };
        }
        const take = @min(r.input.end - r.input.seek, left);
        r.input.toss(take);
        left -= take;
    }
}

/// Decode one block (`§3.1.1.2`): the 3-byte Block_Header off the input, the
/// Block_Content staged (both backwards bitstreams read from the block's end
/// toward its beginning, so the whole block is staged first — `§3.1.1.3.2.1.2`
/// "it is necessary to know the offset of the last byte"), then
/// `block.decodeContent`, and `State.recordBlock` with exactly the bytes the
/// block wrote. Returns the bytes written; moves the phase to `.trailer` when
/// the block is the frame's last (`§3.1.1.2.1`).
fn decodeBlock(r: *Reader) Error!usize {
    const header_bytes = try r.readFixed(block.block_header_len);
    const header = block.parseHeader(&header_bytes) catch |err| {
        // The three bytes are buffered: the parser cannot see a short slice.
        assert(err == error.Truncated);
        return error.Truncated;
    };
    // §3.1.1.2.2 — block type 3, Reserved: "This is not a block. ... a
    // compliant decoder must reject it." No Block_Content is read.
    if (header.block_type == .reserved) return error.ReservedBlock;
    // §3.1.1.2.4 — Block_Maximum_Size bounds "both the decompressed size and
    // the compressed size of any block in the frame": the *declared*
    // Block_Size is checked against it before any content byte is read, so an
    // oversized RLE block (its Block_Size is the repeat count, not the
    // content length) reports `BlockOversize` here, as the one-shot's
    // declared-size check does. Staging the one content byte first would
    // report the input's end instead. The check also bounds the staging read
    // below: content_len <= block_size <= blockRoom() <= staging.len.
    if (header.block_size > r.blockRoom()) return error.BlockOversize;
    const content_len = block.contentLength(header);
    assert(content_len <= r.staging.len);
    try r.readExact(r.staging[0..content_len]);
    // The block phase implies the header was parsed: the frame's state is
    // the one this block decodes through.
    assert(r.frame_state != null);
    const state = &r.frame_state.?;
    // What `decodeContent` can reach back into is what the serving region
    // still holds. That is not the frame's decoded total
    // (`state.decoded_len`), which keeps growing after the window slides: the
    // region holds the frame's last `retained_len` bytes, so the block layer
    // needs both numbers — `retained_len` for its region, `state.decoded_len`
    // for §5's dictionary boundary.
    const retained_len = r.reader.end;
    // A Raw block's bytes reach the checksum inside the copy
    // (`block.decodeContent`), so it records with `recordRawBlock`.
    const checksum: ?*xxh64.State = if (state.header.checksum) &state.checksum else null;
    const written = block.decodeContent(
        header,
        r.staging[0..content_len],
        r.reader.buffer,
        retained_len,
        state.header.window_size,
        state.decoded_len,
        state.dict_content,
        &state.literals,
        &state.sequences,
        checksum,
    ) catch |err| switch (err) {
        // The block phase guarantees the serving region's room (it slides
        // until Block_Maximum_Size is free, `§3.1.1.2.4`), so no decode can
        // outgrow it, which is why the reader's error set does not carry
        // this name. The failure is structurally impossible: assert where
        // assertions are live, and return an error rather than trust it
        // where they are not.
        error.BufferTooSmall => {
            assert(false);
            return error.BlockOversize;
        },
        else => |e| return e,
    };
    // Exactly the bytes this block wrote, in order, go into the checksum and
    // the frame's running total, so every decoded byte is hashed once, with
    // no second pass — for a Raw block the fold already happened inside the
    // copy, chunk by chunk, and only the accounting remains.
    if (header.block_type == .raw) {
        try state.recordRawBlock(written);
    } else {
        try state.recordBlock(r.reader.buffer[retained_len..][0..written]);
    }
    r.reader.end += written;
    if (header.last_block) r.phase = .trailer;
    return written;
}

/// The frame end, in one place (`§3.1.1.1.4`, `§3.1.1`): Frame_Content_Size
/// against the frame's decoded total ("It's allowed to represent a small
/// size (for example, 18) using any compatible variant", so the declaration
/// is a check on the decode, never a sizing hint), then the Content_Checksum
/// trailer, read and verified exactly once, which advances the input through
/// the frame's last byte. Reached from `fillFrame` (the block chain is
/// complete and the consumer needs bytes) and from `rebase` (a request that
/// reaches past the frame's tail). Both paths must come through here, or a
/// request at the tail could report the end with the trailer unread.
fn endFrame(r: *Reader) Error!void {
    assert(r.state == .streaming);
    assert(r.phase == .trailer);
    assert(r.frame_state != null);
    const state = &r.frame_state.?;
    try state.checkContentSize();
    if (state.header.checksum) {
        const trailer = try r.readFixed(frame.checksum_len);
        try state.verifyTrailer(&trailer);
    }
    r.state = .done;
}

/// The frame layer's fixed-size reads (`§3.1.1`, `§3.1.2`, `§3.1.1.2`): the
/// next `n` bytes of `input`, consumed — one `fill(n)`, so the input must
/// buffer `n` bytes (the frame layer's largest fixed-size read is four: the
/// magic, the skippable Frame_Size, the trailer; the 3-byte Block_Header fits
/// inside it) or end before them. Fewer bytes left is `Truncated`.
fn readFixed(r: *Reader, comptime n: usize) Error![n]u8 {
    r.input.fill(n) catch |err| switch (err) {
        error.EndOfStream => return error.Truncated,
        error.ReadFailed => return error.ReadFailed,
    };
    const bytes = r.input.buffer[r.input.seek..][0..n].*;
    r.input.toss(n);
    return bytes;
}

/// Read exactly `target.len` bytes from `input` into `target`, one input
/// buffer's worth at a time: the input's buffer may be as small as the
/// frame layer's four bytes, so a block's content is staged in chunks, never
/// with a single `fill(content_len)` (which would assert on a smaller input
/// buffer). A short input is `Truncated`.
fn readExact(r: *Reader, target: []u8) Error!void {
    var taken: usize = 0;
    while (taken < target.len) {
        if (r.input.seek == r.input.end) {
            r.input.fill(1) catch |err| switch (err) {
                error.EndOfStream => return error.Truncated,
                error.ReadFailed => return error.ReadFailed,
            };
        }
        const buffered = r.input.buffer[r.input.seek..r.input.end];
        const take = @min(buffered.len, target.len - taken);
        fastmem.copy(u8, target[taken..][0..take], buffered[0..take]);
        r.input.toss(take);
        taken += take;
    }
}

/// The room one block's output needs in the serving region: the frame's
/// Block_Maximum_Size — "the smallest of: Window_Size, 128 KB"
/// (`§3.1.1.2.4`). The block phase guarantees it, which is why the decode's
/// own `BufferTooSmall` can never fire here.
fn blockRoom(r: *const Reader) usize {
    assert(r.frame_state != null);
    const state = &r.frame_state.?;
    return @intCast(@min(state.header.window_size, @as(u64, block.max_block_size)));
}

/// The history the window retains: the frame's Window_Size, capped by the
/// caller's window (`checkWindow` enforced the cap) — `§3.1.1.4`'s "all
/// offsets leading to previously decoded data must be smaller than
/// Window_Size" is the match reach, so retaining that much is enough.
fn historyLength(r: *const Reader) usize {
    // Before a frame is parsed nothing is buffered, so the window itself is
    // the bound; `rebase` can run at that phase.
    const state = &(r.frame_state orelse return r.window_len);
    return @intCast(@min(state.header.window_size, @as(u64, r.window_len)));
}

/// Slide the serving region forward: keep the consumer's unconsumed bytes and
/// the retained history (`§3.1.1.4`'s window), drop the rest. Returns the free
/// room afterwards, which is at least Block_Maximum_Size once the history is
/// within the window; that is what guarantees a contiguous request of 128 KiB.
fn slide(r: *Reader) usize {
    const seek = r.reader.seek;
    const end = r.reader.end;
    const unconsumed = end - seek;
    const keep = @max(unconsumed, @min(end, r.historyLength()));
    fastmem.move(u8, r.reader.buffer[0..keep], r.reader.buffer[end - keep ..][0..keep]);
    r.reader.seek = keep - unconsumed;
    r.reader.end = keep;
    return r.reader.buffer.len - keep;
}

/// The vtable's rebase hook: make room for `capacity` more contiguous bytes
/// by sliding the window, keeping the consumer's position. A request the
/// window cannot hold at the consumer's position fails with `StreamTooLong`,
/// unless the frame is at its tail. Then the frame end runs, once, and only
/// after it is the clean end reported: a request that reaches past the
/// frame's last byte must not report the end of the stream while the checksum
/// trailer is still unread. (The over-the-end tests drive both a good and a
/// corrupted trailer.)
fn rebase(r: *Reader, capacity: usize) Io.Reader.RebaseError!void {
    _ = r.slide();
    if (r.reader.buffer.len - r.reader.seek >= capacity) return;
    if (r.phase == .trailer) {
        r.endFrame() catch |err| return r.fail(err);
        return error.EndOfStream;
    }
    return r.fail(error.StreamTooLong);
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/specs/rfc8878-zstd.txt §3.1 (frames), §3.1.1
// (the frame and its checksum), §3.1.1.1 (the header), §3.1.1.2 (the block
// chain), §3.1.1.4 (offsets and the window), §3.1.2 (skippable frames). The
// fixtures are `golden.zig`'s. Every decode is sentinel-checked: the target
// is pre-filled and the bytes past the served length must be untouched.
// ---------------------------------------------------------------------------

/// The fixtures' window: their standard Frame_Header_Descriptor declares a
/// 512-KiB window (`§3.1.1.1.2`), so one buffer covers every fixture whose
/// frame declares at most that.
const fixture_buffer_len = 512 * 1024;

/// Decode `source` through a fresh reader into `target` (sentinel-filled),
/// returning the served length and leaving the reader in `r`. The shape the
/// streaming decode tests run.
fn decodeInto(r: *Reader, target: []u8) !usize {
    sentinel.fill(target);
    var w: Io.Writer = .fixed(target);
    const served = try r.reader.streamRemaining(&w);
    try testing.expectEqual(@as(?Error, null), r.err);
    return served;
}

/// A parsed dictionary on the heap: a `Dictionary` value is 947,824 bytes
/// (the documented size), and `parse`'s own frame is another ~5.5 MiB, so a
/// test holding several by value overflows a thread stack. The caller owns
/// the value and destroys it through `testing.allocator`.
fn parseDictionary(source: []const u8) !*Dictionary {
    const dict = try testing.allocator.create(Dictionary);
    errdefer testing.allocator.destroy(dict);
    dict.* = try Dictionary.parse(source);
    return dict;
}

/// `parseDictionary` for §5's raw-content form.
fn initRawDictionary(content: []const u8) !*Dictionary {
    const dict = try testing.allocator.create(Dictionary);
    dict.* = Dictionary.initRaw(content);
    return dict;
}

/// One good fixture through the streaming layer: the bytes, and the output
/// the one-shot decoder's tests expect.
const Case = struct {
    desc: []const u8,
    source: []const u8,
    expected: []const u8,
};

const stream_cases = [_]Case{
    .{ .desc = "frame_raw", .source = &golden.frame_raw, .expected = "zstd raw" },
    .{ .desc = "frame_raw_empty", .source = &golden.frame_raw_empty, .expected = "" },
    .{ .desc = "frame_rle", .source = &golden.frame_rle, .expected = "AAAAAAAAAA" },
    .{ .desc = "frame_multi", .source = &golden.frame_multi, .expected = "abcdefghIIIIII" },
    .{ .desc = "frame_pair", .source = &golden.frame_pair, .expected = &golden.pair_literals },
    .{
        .desc = "frame_pair_errata",
        .source = &golden.frame_pair_errata,
        .expected = &golden.pair_errata_literals,
    },
    .{
        .desc = "frame_treeless",
        .source = &golden.frame_treeless,
        .expected = &[_]u8{ 0, 1, 4, 5, 0, 0, 0, 0, 0 },
    },
    .{
        .desc = "frame_repeat",
        .source = &golden.frame_repeat,
        .expected = &golden.frame_repeat_expected,
    },
    .{
        .desc = "frame_temp_offset",
        .source = &golden.frame_temp_offset,
        .expected = &golden.frame_temp_offset_expected,
    },
    .{
        .desc = "frame_corner",
        .source = &golden.frame_corner,
        .expected = &golden.frame_corner_expected,
    },
    .{
        .desc = "frame_two_byte",
        .source = &golden.frame_two_byte,
        .expected = &golden.frame_two_byte_expected,
    },
    .{
        .desc = "frame_zero_seq",
        .source = &golden.frame_zero_seq,
        .expected = &golden.frame_zero_seq_expected,
    },
    .{
        .desc = "frame_zero_seq_2b",
        .source = &golden.frame_zero_seq_2b,
        .expected = &golden.frame_zero_seq_expected,
    },
    .{
        .desc = "frame_sequences_predefined",
        .source = &golden.frame_sequences_predefined,
        .expected = &golden.sequences_predefined_expected,
    },
    .{
        .desc = "frame_sequences_rle_match_lengths",
        .source = &golden.frame_sequences_rle_match_lengths,
        .expected = &golden.sequences_rle_match_lengths_expected,
    },
    .{
        .desc = "frame_sequences_fse_offsets",
        .source = &golden.frame_sequences_fse_offsets,
        .expected = &golden.sequences_fse_offsets_expected,
    },
    .{
        .desc = "frame_sequences_fse_all",
        .source = &golden.frame_sequences_fse_all,
        .expected = &golden.sequences_fse_all_expected,
    },
    .{
        .desc = "frame_literals_1stream",
        .source = &golden.frame_literals_1stream,
        .expected = &golden.literals_1stream_expected,
    },
    .{
        .desc = "frame_literals_4stream_sf1",
        .source = &golden.frame_literals_4stream_sf1,
        .expected = &golden.literals_4stream_sf1_expected,
    },
    .{
        .desc = "frame_literals_4stream_sf2",
        .source = &golden.frame_literals_4stream_sf2,
        .expected = &golden.literals_4stream_sf2_expected,
    },
    .{
        .desc = "frame_literals_fse_tree",
        .source = &golden.frame_literals_fse_tree,
        .expected = &golden.literals_fse_tree_expected,
    },
    .{ .desc = "frame_fcs1", .source = &golden.frame_fcs1, .expected = "01234567" },
    .{ .desc = "frame_fcs4", .source = &golden.frame_fcs4, .expected = "01234567" },
    .{ .desc = "frame_fcs8", .source = &golden.frame_fcs8, .expected = "01234567" },
    .{ .desc = "frame_unused_bit", .source = &golden.frame_unused_bit, .expected = "abcd" },
    .{ .desc = "frame_checksum", .source = &golden.frame_checksum, .expected = "abcd" },
    .{ .desc = "frame_checksum_empty", .source = &golden.frame_checksum_empty, .expected = "" },
    .{ .desc = "frame_checksum_off", .source = &golden.frame_checksum_off, .expected = "abcd" },
};

test "Reader: the buffer type is the documented window, block, and staging" {
    // RFC 8878 §3.1.1.1.2 — "It is recommended to support Window_Size up to
    // 8 MB": the default window is 8 MiB, and the buffer is the window plus
    // Block_Maximum_Size (§3.1.1.2.4 — "128 KB") plus the block staging room
    // (`stagingLength`: one block's content at most, the smaller of the
    // window and 128 KB).
    try testing.expectEqual(@as(usize, 8 * 1024 * 1024), default_window_len);
    try testing.expectEqual(@as(usize, 128 * 1024), block.max_block_size);
    try testing.expectEqual(
        @as(usize, 8 * 1024 * 1024 + 128 * 1024 + 128 * 1024),
        @sizeOf(DefaultBuffer),
    );
    // A window below Block_Maximum_Size stages its own size, not 128 KiB.
    try testing.expectEqual(@as(usize, 1024 + 128 * 1024 + 1024), @sizeOf(Buffer(1024)));
    try testing.expectEqual(@as(usize, 1152 + 128 * 1024 + 1152), @sizeOf(Buffer(1152)));
    try testing.expectEqual(@as(usize, 128 * 1024), stagingLength(128 * 1024));
}

test "Reader: the error set mirrors DecompressError minus BufferTooSmall" {
    // `err`'s type is the `DecompressError` set minus `BufferTooSmall` (the
    // window is the caller's buffer, not a target cap), plus the interface's
    // `ReadFailed`/`EndOfStream` and this layer's `WindowTooLarge` and
    // `StreamTooLong`.
    const mine = @typeInfo(Error).error_set.?;
    for (@typeInfo(frame.Error).error_set.?) |want| {
        if (mem.eql(u8, want.name, "BufferTooSmall")) continue;
        var found = false;
        for (mine) |entry| {
            if (mem.eql(u8, entry.name, want.name)) found = true;
        }
        try testing.expect(found);
    }
    var has_buffer_too_small = false;
    for (mine) |entry| {
        if (mem.eql(u8, entry.name, "BufferTooSmall")) has_buffer_too_small = true;
    }
    try testing.expect(!has_buffer_too_small);
}

test "Reader: the CLI's dictionary frames decode through the streaming layer" {
    // §5 — the same fixtures as the one-shot's: the dictionary seeds the
    // frame's state through the streaming path too (the header check, the
    // tables, the repcodes, and the content), and the reader consumes the
    // frame exactly. Each expectation is the CLI's own `-D` decode.
    // The dictionaries live on the heap (`parseDictionary`): each value is
    // 947,824 bytes (the documented size), and five by value — plus a
    // `parse` call's own frame — is ~19 MiB of stack, past macOS's thread
    // stack.
    const gpa = testing.allocator;
    const trained = try parseDictionary(golden.dict_trained);
    defer gpa.destroy(trained);
    const id_100 = try parseDictionary(golden.dict_100);
    defer gpa.destroy(id_100);
    const zero_weight = try parseDictionary(golden.dict_zero_weight);
    defer gpa.destroy(zero_weight);
    const raw = try initRawDictionary(golden.dict_s02);
    defer gpa.destroy(raw);
    const rows = [_]struct { source: []const u8, dict: *const Dictionary, expected: []const u8 }{
        .{ .source = golden.dict_frame_s00, .dict = trained, .expected = golden.dict_s00 },
        .{ .source = golden.dict_frame_s00_noid, .dict = trained, .expected = golden.dict_s00 },
        .{ .source = golden.dict_frame_s01_r100, .dict = id_100, .expected = golden.dict_s01 },
        .{ .source = golden.dict_frame_s01_raw, .dict = raw, .expected = golden.dict_s01 },
        .{ .source = golden.dict_frame_zw, .dict = zero_weight, .expected = golden.dict_s00 },
        .{ .source = golden.dict_frame_big, .dict = trained, .expected = golden.dict_big },
    };
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var target: [300 * 1024]u8 = undefined;
    for (rows) |row| {
        var fixed_in: Io.Reader = .fixed(row.source);
        var r: Reader = .init(fixture_buffer_len, &fixed_in, &rbuf, row.dict);
        const n = try decodeInto(&r, &target);
        try testing.expectEqual(row.expected.len, n);
        try testing.expectEqualSlices(u8, row.expected, target[0..n]);
        try sentinel.expect(&target, n);
        try testing.expectEqual(row.source.len, fixed_in.seek);
        try testing.expectEqual(State.done, r.state);
    }
    // §5's boundary, through the reader: the match at exactly Window_Size
    // decodes, one byte past it is `OffsetTooFar` with the RLE output left
    // behind (a failed reader's bytes are not trusted, but the sentinel
    // proves the refused copy wrote nothing).
    const boundary = try parseDictionary(&golden.dict_boundary);
    defer gpa.destroy(boundary);
    var ok_in: Io.Reader = .fixed(&golden.dict_frame_boundary);
    var ok: Reader = .init(fixture_buffer_len, &ok_in, &rbuf, boundary);
    const n = try decodeInto(&ok, &target);
    try testing.expectEqual(golden.dict_boundary_expected.len, n);
    try testing.expectEqualSlices(u8, golden.dict_boundary_expected, target[0..n]);
    try sentinel.expect(&target, n);
    sentinel.fill(&target);
    var over_in: Io.Reader = .fixed(&golden.dict_frame_boundary_after);
    var over: Reader = .init(fixture_buffer_len, &over_in, &rbuf, boundary);
    var over_out: Io.Writer = .fixed(&target);
    try testing.expectError(error.ReadFailed, over.reader.streamRemaining(&over_out));
    try testing.expectEqual(Error.OffsetTooFar, over.err.?);
    try testing.expectEqual(State.failed, over.state);
    try sentinel.expect(&target, 1025);
}

test "Reader: the dictionary matrix fails the stream the same way" {
    // DD9/DD10 — the header's Dictionary_ID against the reader's dictionary:
    // none supplied is `DictionaryRequired`, a different one is
    // `DictionaryMismatch`, both raised once the header is parsed and before
    // any block byte; the failure is sticky, as every reader failure is. A
    // frame with no ID field decodes either way.
    const trained = try Dictionary.parse(golden.dict_trained);
    const other = try Dictionary.parse(golden.dict_100);
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var target: [300 * 1024]u8 = undefined;
    const cases = [_]struct { dict: ?*const Dictionary, want: Error }{
        .{ .dict = null, .want = error.DictionaryRequired },
        .{ .dict = &other, .want = error.DictionaryMismatch },
    };
    for (cases) |case| {
        sentinel.fill(&target);
        var fixed_in: Io.Reader = .fixed(golden.dict_frame_s00);
        var r: Reader = .init(fixture_buffer_len, &fixed_in, &rbuf, case.dict);
        var out: Io.Writer = .fixed(&target);
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out));
        try testing.expectEqual(case.want, r.err.?);
        try testing.expectEqual(State.failed, r.state);
        // The failure is sticky: every later read reports it.
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out));
        // No body byte was read past the header, and nothing was written.
        try sentinel.expect(&target, 0);
    }
    // The no-ID frame without a dictionary fails in the entropy layer (the
    // CLI's "Data corruption detected"), and a supplied dictionary fixes it.
    var noid_in: Io.Reader = .fixed(golden.dict_frame_s00_noid);
    var noid: Reader = .init(fixture_buffer_len, &noid_in, &rbuf, null);
    var noid_out: Io.Writer = .fixed(&target);
    try testing.expectError(error.ReadFailed, noid.reader.streamRemaining(&noid_out));
    try testing.expectEqual(Error.RepeatModeFirst, noid.err.?);
    var fixed_in: Io.Reader = .fixed(golden.dict_frame_s00_noid);
    var r: Reader = .init(fixture_buffer_len, &fixed_in, &rbuf, &trained);
    const n = try decodeInto(&r, &target);
    try testing.expectEqualSlices(u8, golden.dict_s00, target[0..n]);
    try sentinel.expect(&target, n);
}

test "Reader: the golden fixtures decode through the streaming layer" {
    // The one-shot decoder's fixtures, through the streaming interface: each
    // decodes to the golden output and consumes exactly its own bytes
    // (`§3.1.1`: the frame ends at the last block's last byte, or at the
    // trailer's when the flag is set).
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var target: [300 * 1024]u8 = undefined;
    for (stream_cases) |tc| {
        var fixed_in: Io.Reader = .fixed(tc.source);
        var r: Reader = .init(fixture_buffer_len, &fixed_in, &rbuf, null);
        const n = decodeInto(&r, &target) catch |err| {
            print("\nFAIL ({s}): {s}\n", .{ tc.desc, @errorName(err) });
            return err;
        };
        try testing.expectEqual(tc.expected.len, n);
        try testing.expectEqualSlices(u8, tc.expected, target[0..n]);
        try sentinel.expect(&target, n);
        try testing.expectEqual(tc.source.len, fixed_in.seek);
        try testing.expectEqual(State.done, r.state);
    }

    // The CLI's own multi-block, checksummed, single-segment frame: 135000
    // bytes over two Compressed_Blocks with the XXH64 trailer (`§3.1.1`).
    const expected = golden.frame_checksum_multi_text ** 3000;
    var big_in: Io.Reader = .fixed(&golden.frame_checksum_multi);
    var big: Reader = .init(fixture_buffer_len, &big_in, &rbuf, null);
    const n = try decodeInto(&big, &target);
    try testing.expectEqual(expected.len, n);
    try testing.expectEqualSlices(u8, expected, target[0..n]);
    try sentinel.expect(&target, n);
    try testing.expectEqual(golden.frame_checksum_multi.len, big_in.seek);
    try testing.expectEqual(State.done, big.state);
}

test "Reader: the negative corners fail with the detail in err" {
    // The frame layer's negative corners through the streaming layer: every
    // one is `error.ReadFailed` with the specific detail in `err`, and
    // sticky. `written` is what the frame serves before the failure. The
    // frame-end checks (Frame_Content_Size and the checksum trailer) run
    // after the frame's output is complete (`§3.1.1.1.4`, `§3.1.1`), so a
    // frame whose output falls short of its declared size, or whose trailer
    // is corrupt, still serves its bytes before the failure; the one-shot's
    // tests pin the same counts. Every other corner fails before or inside
    // the pump call that would serve, and the reader drops what it buffered
    // (no partial output is trusted past an error, as in the flate reader),
    // so the sentinel past `written` holds.
    const CaseNeg = struct { desc: []const u8, source: []const u8, want: Error, written: usize };
    const cases = [_]CaseNeg{
        // §3.1.1.1.1.4 — descriptor bit 3.
        .{
            .desc = "frame_reserved_bit",
            .source = &golden.frame_reserved_bit,
            .want = error.ReservedBitSet,
            .written = 0,
        },
        // §3.1.1.1.3 — Dictionary_ID_Flag set.
        .{
            .desc = "frame_dictionary_id",
            .source = &golden.frame_dictionary_id,
            .want = error.DictionaryRequired,
            .written = 0,
        },
        .{
            .desc = "frame_dictionary_id_wide",
            .source = &golden.frame_dictionary_id_wide,
            .want = error.DictionaryRequired,
            .written = 0,
        },
        .{
            .desc = "frame_dictionary_id_truncated",
            .source = &golden.frame_dictionary_id_truncated,
            .want = error.Truncated,
            .written = 0,
        },
        // §3.1.1.2.4 — Block_Maximum_Size, and §3.1.1.2.2 — the reserved type.
        .{
            .desc = "frame_reserved",
            .source = &golden.frame_reserved,
            .want = error.ReservedBlock,
            .written = 0,
        },
        .{
            .desc = "frame_oversize_raw",
            .source = &golden.frame_oversize_raw,
            .want = error.BlockOversize,
            .written = 0,
        },
        .{
            .desc = "frame_oversize_rle",
            .source = &golden.frame_oversize_rle,
            .want = error.BlockOversize,
            .written = 0,
        },
        .{
            .desc = "frame_single_segment_oversize",
            .source = &golden.frame_single_segment_oversize,
            .want = error.BlockOversize,
            .written = 0,
        },
        .{
            .desc = "frame_amplify_match",
            .source = &golden.frame_amplify_match,
            .want = error.BlockOversize,
            .written = 0,
        },
        .{
            .desc = "frame_oversize_literals",
            .source = &golden.frame_oversize_literals,
            .want = error.LiteralsTooLarge,
            .written = 0,
        },
        // §3.1.1.3.1.1 / §3.1.1.3.2.1 — the first-block entropy corners.
        .{
            .desc = "frame_treeless_first",
            .source = &golden.frame_treeless_first,
            .want = error.TreelessLiteralsFirst,
            .written = 0,
        },
        .{
            .desc = "frame_repeat_first",
            .source = &golden.frame_repeat_first,
            .want = error.RepeatModeFirst,
            .written = 0,
        },
        .{
            .desc = "frame_empty_compressed",
            .source = &golden.frame_empty_compressed,
            .want = error.MalformedLiteralsHeader,
            .written = 0,
        },
        .{
            .desc = "frame_no_sequences",
            .source = &golden.frame_no_sequences,
            .want = error.MalformedSequencesHeader,
            .written = 0,
        },
        // §3.1.1.2 — the input's end inside the frame.
        .{
            .desc = "frame_short_raw",
            .source = &golden.frame_short_raw,
            .want = error.Truncated,
            .written = 0,
        },
        .{
            .desc = "frame_short_compressed",
            .source = &golden.frame_short_compressed,
            .want = error.Truncated,
            .written = 0,
        },
        .{
            .desc = "frame_truncated_header",
            .source = &golden.frame_truncated_header,
            .want = error.Truncated,
            .written = 0,
        },
        .{
            .desc = "frame_checksum_truncated",
            .source = &golden.frame_checksum_truncated,
            .want = error.Truncated,
            .written = 4,
        },
        // §3.1.1.1.4 — Frame_Content_Size against the decode.
        .{
            .desc = "frame_fcs_short",
            .source = &golden.frame_fcs_short,
            .want = error.ContentSizeMismatch,
            .written = 0,
        },
        .{
            .desc = "frame_fcs_long",
            .source = &golden.frame_fcs_long,
            .want = error.ContentSizeMismatch,
            .written = 8,
        },
        .{
            .desc = "frame_fcs_max",
            .source = &golden.frame_fcs_max,
            .want = error.ContentSizeMismatch,
            .written = 4,
        },
        // §3.1.1.4 — the declared window bound.
        .{
            .desc = "frame_window_1k_over",
            .source = &golden.frame_window_1k_over,
            .want = error.OffsetTooFar,
            .written = 0,
        },
        // §3.1.1 — the XXH64 trailer.
        .{
            .desc = "frame_checksum_corrupt",
            .source = &golden.frame_checksum_corrupt,
            .want = error.WrongChecksum,
            .written = 4,
        },
        // §3.1 / §3.1.2 — the magic, and the skippable frame's own corners.
        .{
            .desc = "frame_bad_magic",
            .source = &golden.frame_bad_magic,
            .want = error.BadMagic,
            .written = 0,
        },
        .{
            .desc = "skippable_bad_magic",
            .source = &golden.skippable_bad_magic,
            .want = error.BadMagic,
            .written = 0,
        },
        .{
            .desc = "skippable_truncated",
            .source = &golden.skippable_truncated,
            .want = error.Truncated,
            .written = 0,
        },
        .{
            .desc = "skippable_huge",
            .source = &golden.skippable_huge,
            .want = error.Truncated,
            .written = 0,
        },
    };
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var target: [1024]u8 = undefined;
    for (cases) |tc| {
        var fixed_in: Io.Reader = .fixed(tc.source);
        var r: Reader = .init(fixture_buffer_len, &fixed_in, &rbuf, null);
        sentinel.fill(&target);
        var w: Io.Writer = .fixed(&target);
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&w));
        try testing.expectEqual(tc.want, r.err.?);
        // Exactly the bytes the frame produced before the failure were
        // served, and the bytes past them are untouched: no partial output is
        // trusted past the error, and nothing was written past what was
        // reported (the sentinel rule).
        if (w.end != tc.written) {
            print("\nFAIL ({s}): served {d}, want {d}\n", .{ tc.desc, w.end, tc.written });
            return error.TestUnexpectedResult;
        }
        try sentinel.expect(&target, w.end);
        // The failure is sticky, and the interface keeps reporting it.
        var sink: Io.Writer.Discarding = .init(&.{});
        try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
        try testing.expectError(error.ReadFailed, r.reader.peek(1));
    }
}

test "Reader: the frame boundary is exact at the frame's last byte" {
    // The reader consumes `input` exactly through the frame's last byte (the
    // checksum trailer's last byte when the flag is set, `§3.1.1`, the last
    // block's last byte otherwise) and stops there. Marker bytes behind the
    // frame are not the reader's to consume.
    const cases = [_]struct { desc: []const u8, source: []const u8, expected: []const u8 }{
        .{ .desc = "checksummed", .source = &golden.frame_checksum, .expected = "abcd" },
        .{ .desc = "unchecksummed", .source = &golden.frame_raw, .expected = "zstd raw" },
    };
    const markers = 8;
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var framed: [64 + markers]u8 = undefined;
    var target: [64]u8 = undefined;
    for (cases) |tc| {
        fastmem.copy(u8, framed[0..tc.source.len], tc.source);
        fastmem.set(u8, framed[tc.source.len..], 0xaa);
        var fixed_in: Io.Reader = .fixed(framed[0 .. tc.source.len + markers]);
        var r: Reader = .init(fixture_buffer_len, &fixed_in, &rbuf, null);
        const n = try decodeInto(&r, &target);
        try testing.expectEqualStrings(tc.expected, target[0..n]);
        try sentinel.expect(&target, n);
        try testing.expectEqual(tc.source.len, fixed_in.seek);
    }
}

test "Reader: a multi-frame file is a caller loop at the boundary" {
    // RFC 8878 §3.1 — frames concatenate: "The output of the decompression is
    // the concatenation of all the frames". One frame per reader, the caller
    // loops at the boundary (`streamAll` is the same walk, one call down).
    const gpa = testing.allocator;
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var fixed_in: Io.Reader = .fixed(&golden.frame_two_frames);
    var first: Io.Writer.Allocating = .init(gpa);
    defer first.deinit();
    var second: Io.Writer.Allocating = .init(gpa);
    defer second.deinit();
    try testing.expectEqual(
        @as(usize, 8),
        try streamFrame(fixture_buffer_len, &fixed_in, &first.writer, &rbuf, null),
    );
    try testing.expectEqualStrings("zstd raw", first.written());
    try testing.expectEqual(@as(usize, golden.frame_raw.len), fixed_in.seek);
    try testing.expectEqual(
        @as(usize, 6),
        try streamFrame(fixture_buffer_len, &fixed_in, &second.writer, &rbuf, null),
    );
    try testing.expectEqualStrings("second", second.written());
    try testing.expectEqual(@as(usize, golden.frame_two_frames.len), fixed_in.seek);
}

test "Reader: streamAll walks every frame to the input's end" {
    // RFC 8878 §3.1 — the walk: every frame decoded, in order, at the exact
    // boundary, stopping at the last frame's last byte.
    const gpa = testing.allocator;
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var fixed_in: Io.Reader = .fixed(&golden.frame_two_frames);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try testing.expectEqual(
        @as(usize, 14),
        try streamAll(fixture_buffer_len, &fixed_in, &out.writer, &rbuf, null),
    );
    try testing.expectEqualStrings("zstd rawsecond", out.written());
    try testing.expectEqual(@as(usize, golden.frame_two_frames.len), fixed_in.seek);

    // A checksummed frame between two others: each frame's trailer verified
    // at its own boundary, the walk's total the concatenation.
    var framed: [golden.frame_raw.len * 2 + golden.frame_checksum.len]u8 = undefined;
    fastmem.copy(u8, framed[0..golden.frame_raw.len], &golden.frame_raw);
    fastmem.copy(
        u8,
        framed[golden.frame_raw.len..][0..golden.frame_checksum.len],
        &golden.frame_checksum,
    );
    fastmem.copy(
        u8,
        framed[golden.frame_raw.len + golden.frame_checksum.len ..],
        &golden.frame_raw,
    );
    var walk_in: Io.Reader = .fixed(&framed);
    var walk_out: Io.Writer.Allocating = .init(gpa);
    defer walk_out.deinit();
    try testing.expectEqual(
        @as(usize, 8 + 4 + 8),
        try streamAll(fixture_buffer_len, &walk_in, &walk_out.writer, &rbuf, null),
    );
    try testing.expectEqualStrings("zstd rawabcdzstd raw", walk_out.written());
    try testing.expectEqual(@as(usize, framed.len), walk_in.seek);
}

test "Reader: the allocator conveniences own the default buffer" {
    // `streamFrameAlloc`/`streamAllAlloc` allocate the default window from
    // the caller's allocator, drive the caller-buffered pumps, and free the
    // buffer before returning. `testing.allocator` makes the allocation
    // visible: a buffer the convenience forgot to free fails this test at its
    // end.
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var walk_in: Io.Reader = .fixed(&golden.frame_two_frames);
    try testing.expectEqual(@as(usize, 14), try streamAllAlloc(gpa, &walk_in, &out.writer, null));
    try testing.expectEqualStrings("zstd rawsecond", out.written());
    try testing.expectEqual(@as(usize, golden.frame_two_frames.len), walk_in.seek);

    // One frame per call, the exact boundary (`streamFrame`'s semantics with
    // the buffer allocated for the call).
    var one_in: Io.Reader = .fixed(&golden.frame_two_frames);
    out.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 8), try streamFrameAlloc(gpa, &one_in, &out.writer, null));
    try testing.expectEqualStrings("zstd raw", out.written());
    try testing.expectEqual(@as(usize, golden.frame_raw.len), one_in.seek);

    // A small-window frame through the convenience's default window: the
    // buffer is the cap, not a floor: `frame_window_1k` declares 1 KB and
    // decodes through the 8 MiB default unchanged.
    var small_in: Io.Reader = .fixed(&golden.frame_window_1k);
    out.clearRetainingCapacity();
    try testing.expectEqual(
        @as(usize, 2048 + 3),
        try streamAllAlloc(gpa, &small_in, &out.writer, null),
    );
    try testing.expectEqual(golden.frame_window_1k.len, small_in.seek);

    // The walk's cardinality rules ride the convenience: the empty input is
    // the clean end with zero frames served, while one frame's pump over a
    // zero-byte input is `ReadFailed` (no frame unit began).
    var empty_in: Io.Reader = .fixed("");
    out.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 0), try streamAllAlloc(gpa, &empty_in, &out.writer, null));
    var empty_frame_in: Io.Reader = .fixed("");
    try testing.expectError(
        error.ReadFailed,
        streamFrameAlloc(gpa, &empty_frame_in, &out.writer, null),
    );

    // The allocation's own failure: a failing allocator surfaces
    // `error.OutOfMemory` before any input byte is read.
    var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    var oom_in: Io.Reader = .fixed(&golden.frame_raw);
    try testing.expectError(
        error.OutOfMemory,
        streamAllAlloc(failing.allocator(), &oom_in, &out.writer, null),
    );
    try testing.expectEqual(@as(usize, 0), oom_in.seek);
}

test "Reader: skippable frames are skipped in every layer" {
    // RFC 8878 §3.1.2 — "skippable frames simply need to be skipped, and
    // their content ignored, resuming decoding after the skippable frame";
    // "All 16 values are valid to identify a skippable frame". Before a
    // frame, around a frame, and in the walk.
    const gpa = testing.allocator;
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    // A skippable frame before the frame: consumed and ignored, and the
    // frame's own boundary is the input's end.
    {
        var fixed_in: Io.Reader = .fixed(&golden.skippable_prefix);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectEqual(
            @as(usize, 8),
            try streamFrame(fixture_buffer_len, &fixed_in, &out.writer, &rbuf, null),
        );
        try testing.expectEqualStrings("zstd raw", out.written());
        try testing.expectEqual(golden.skippable_prefix.len, fixed_in.seek);
    }
    // A skippable frame after the frame: one reader ends at the Zstandard
    // frame's last byte — the trailing skippable is the next unit's — and
    // the walk consumes it and reaches the clean end with zero more bytes.
    {
        var fixed_in: Io.Reader = .fixed(&golden.skippable_around);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try testing.expectEqual(
            @as(usize, 8),
            try streamFrame(fixture_buffer_len, &fixed_in, &out.writer, &rbuf, null),
        );
        try testing.expectEqualStrings("zstd raw", out.written());
        try testing.expectEqual(@as(usize, 27), fixed_in.seek);
        try testing.expectEqual(
            @as(usize, 0),
            try streamFrame(fixture_buffer_len, &fixed_in, &out.writer, &rbuf, null),
        );
        try testing.expectEqual(golden.skippable_around.len, fixed_in.seek);

        var walk_in: Io.Reader = .fixed(&golden.skippable_around);
        var walk_out: Io.Writer.Allocating = .init(gpa);
        defer walk_out.deinit();
        try testing.expectEqual(
            @as(usize, 8),
            try streamAll(fixture_buffer_len, &walk_in, &walk_out.writer, &rbuf, null),
        );
        try testing.expectEqualStrings("zstd raw", walk_out.written());
        try testing.expectEqual(golden.skippable_around.len, walk_in.seek);
    }

    // §3.1.2 — a stream of only skippable frames is the clean end with zero
    // bytes served (the CLI decodes all sixteen to zero bytes cleanly), for
    // the walk and for a reader driven directly.
    var only_in: Io.Reader = .fixed(&golden.skippable_sixteen);
    var only_out: Io.Writer.Allocating = .init(gpa);
    defer only_out.deinit();
    try testing.expectEqual(
        @as(usize, 0),
        try streamAll(fixture_buffer_len, &only_in, &only_out.writer, &rbuf, null),
    );
    try testing.expectEqual(@as(usize, 0), only_out.written().len);
    try testing.expectEqual(golden.skippable_sixteen.len, only_in.seek);

    var direct_in: Io.Reader = .fixed(&golden.skippable_sixteen);
    var direct: Reader = .init(fixture_buffer_len, &direct_in, &rbuf, null);
    var direct_out: Io.Writer.Allocating = .init(gpa);
    defer direct_out.deinit();
    try testing.expectEqual(
        @as(usize, 0),
        try direct.reader.streamRemaining(&direct_out.writer),
    );
    try testing.expectEqual(@as(?Error, null), direct.err);
    try testing.expectEqual(State.done, direct.state);
    try testing.expectEqual(golden.skippable_sixteen.len, direct_in.seek);
}

test "Reader: the cardinality rules for the empty input" {
    // A zero-byte input is `Truncated` for one reader (no frame unit began;
    // the CLI fails with "unexpected end of file") and the clean end, with
    // zero frames served, for the walk.
    const gpa = testing.allocator;
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var fixed_in: Io.Reader = .fixed("");
    var r: Reader = .init(fixture_buffer_len, &fixed_in, &rbuf, null);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
    try testing.expectEqual(Error.Truncated, r.err.?);

    // The pump reports the coarse failure (its error set is the interface's
    // pair); the detail above is the reader's.
    var frame_in: Io.Reader = .fixed("");
    try testing.expectError(
        error.ReadFailed,
        streamFrame(fixture_buffer_len, &frame_in, &out.writer, &rbuf, null),
    );

    var walk_in: Io.Reader = .fixed("");
    try testing.expectEqual(
        @as(usize, 0),
        try streamAll(fixture_buffer_len, &walk_in, &out.writer, &rbuf, null),
    );
    try testing.expectEqual(@as(usize, 0), out.written().len);
}

test "Reader: trailing garbage fails at the next unit's classify" {
    // The walk: any byte where a frame unit should start is parsed as one,
    // so trailing garbage is `BadMagic` and is not skipped.
    const gpa = testing.allocator;
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var fixed_in: Io.Reader = .fixed(&golden.frame_trailing_garbage);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try testing.expectError(
        error.ReadFailed,
        streamAll(fixture_buffer_len, &fixed_in, &out.writer, &rbuf, null),
    );
    try testing.expectEqualStrings("zstd raw", out.written());

    // The same through the manual loop: the frame decodes, the next reader
    // fails the classify.
    var loop_in: Io.Reader = .fixed(&golden.frame_trailing_garbage);
    var loop_out: Io.Writer.Allocating = .init(gpa);
    defer loop_out.deinit();
    _ = try streamFrame(fixture_buffer_len, &loop_in, &loop_out.writer, &rbuf, null);
    try testing.expectEqual(@as(usize, golden.frame_raw.len), loop_in.seek);
    var next: Reader = .init(fixture_buffer_len, &loop_in, &rbuf, null);
    try testing.expectError(error.ReadFailed, next.reader.streamRemaining(&loop_out.writer));
    try testing.expectEqual(Error.BadMagic, next.err.?);
}

test "Reader: a truncated frame is Truncated at every prefix" {
    // RFC 8878 §3.1.1 — a frame cut off anywhere (header, block, trailer) is
    // the input's end, `Truncated`, never a clean end. The checksummed
    // fixture: every strict prefix fails, the whole frame decodes.
    const gpa = testing.allocator;
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (1..golden.frame_checksum.len) |prefix| {
        var fixed_in: Io.Reader = .fixed(golden.frame_checksum[0..prefix]);
        var r: Reader = .init(fixture_buffer_len, &fixed_in, &rbuf, null);
        out.clearRetainingCapacity();
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
        try testing.expectEqual(Error.Truncated, r.err.?);
    }
    // The unchecksummed fixture: the prefix that ends at the last block's
    // last byte is the frame's clean end (§3.1.1 — no trailer to read).
    for (1..golden.frame_raw.len) |prefix| {
        var fixed_in: Io.Reader = .fixed(golden.frame_raw[0..prefix]);
        var r: Reader = .init(fixture_buffer_len, &fixed_in, &rbuf, null);
        out.clearRetainingCapacity();
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
        try testing.expectEqual(Error.Truncated, r.err.?);
    }
}

test "Reader: the window cap is the buffer's" {
    // RFC 8878 §3.1.1.1.2 — "a decoder is allowed to reject a compressed
    // frame that requests a memory size beyond the decoder's authorized
    // range": the caller's buffer type is the authorization, and the cap is
    // exact. `frame_window_1152` declares 1152 bytes (1024 + 128, the first
    // window above the 1-KB minimum); `frame_window_1k` declares 1024.
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    {
        var rbuf: Buffer(1024) = undefined;
        var fixed_in: Io.Reader = .fixed(&golden.frame_window_1152);
        var r: Reader = .init(1024, &fixed_in, &rbuf, null);
        try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&out.writer));
        try testing.expectEqual(Error.WindowTooLarge, r.err.?);
        // The cap is checked once the header is parsed and before any block
        // byte: the magic and the two header bytes were consumed, no more.
        try testing.expectEqual(@as(usize, 6), fixed_in.seek);
        var sink: Io.Writer.Discarding = .init(&.{});
        try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
    }
    {
        // The same frame with a buffer whose window is exactly its
        // declaration: the cap is inclusive.
        var rbuf: Buffer(1152) = undefined;
        var fixed_in: Io.Reader = .fixed(&golden.frame_window_1152);
        var r: Reader = .init(1152, &fixed_in, &rbuf, null);
        try testing.expectEqual(@as(usize, 0), try r.reader.streamRemaining(&out.writer));
        try testing.expectEqual(@as(?Error, null), r.err);
        try testing.expectEqual(golden.frame_window_1152.len, fixed_in.seek);
    }
    {
        // The minimum legal window, exactly declared.
        var rbuf: Buffer(1024) = undefined;
        var fixed_in: Io.Reader = .fixed(&golden.frame_window_1k);
        var r: Reader = .init(1024, &fixed_in, &rbuf, null);
        try testing.expectEqual(@as(usize, 2048 + 3), try r.reader.streamRemaining(&out.writer));
        try testing.expectEqual(@as(?Error, null), r.err);
        try testing.expectEqual(golden.frame_window_1k.len, fixed_in.seek);
        try testing.expectEqualSlices(u8, "BBB", out.written()[2048..2051]);
    }
    {
        // The addressable-span rule: ten literals move the match position
        // past the window, and offset 1025 is inside the span, so the reader
        // accepts it, as the one-shot and the CLI do.
        out.clearRetainingCapacity();
        var rbuf: Buffer(1024) = undefined;
        var fixed_in: Io.Reader = .fixed(&golden.frame_window_1k_span);
        var r: Reader = .init(1024, &fixed_in, &rbuf, null);
        try testing.expectEqual(
            @as(usize, 2048 + 10 + 3),
            try r.reader.streamRemaining(&out.writer),
        );
        try testing.expectEqual(@as(?Error, null), r.err);
        try testing.expectEqual(golden.frame_window_1k_span.len, fixed_in.seek);
        try testing.expectEqualSlices(u8, "0123456789BBB", out.written()[2048..2061]);
    }
}

test "Reader: the window slides to serve a frame larger than the buffer" {
    // RFC 8878 §3.1.1.4 — the window is the match reach: a frame whose output
    // exceeds the buffer decodes through the slide, which keeps the retained
    // history and the consumer's unconsumed bytes. `frame_window_128k` is
    // 262147 bytes with a 128-KiB window; the serving region is exactly
    // window + Block_Maximum_Size (262144), so every slide matters. The
    // expected output is the fixture's own shape — two 131072-byte RLE
    // blocks, 'A' then 'B', and a match copying "BBB" — and the canaries
    // around the buffer prove the reader stayed inside it.
    const gpa = testing.allocator;
    const Guarded = struct {
        before: [64]u8,
        buffer: Buffer(128 * 1024),
        after: [64]u8,
    };
    const expected_len = 2 * 131072 + 3;
    const reference = try gpa.alloc(u8, expected_len);
    defer gpa.free(reference);
    fastmem.set(u8, reference[0..131072], 'A');
    fastmem.set(u8, reference[131072..][0..131072], 'B');
    fastmem.copy(u8, reference[2 * 131072 ..], "BBB");

    const served = try gpa.alloc(u8, expected_len + @as(usize, sentinel.len));
    defer gpa.free(served);
    var guarded: Guarded = undefined;
    sentinel.fill(&guarded.before);
    sentinel.fill(&guarded.after);
    var fixed_in: Io.Reader = .fixed(&golden.frame_window_128k);
    var r: Reader = .init(128 * 1024, &fixed_in, &guarded.buffer, null);
    const n = try decodeInto(&r, served);
    try testing.expectEqual(expected_len, n);
    try testing.expectEqualSlices(u8, reference, served[0..n]);
    try sentinel.expect(served, n);
    try testing.expectEqual(golden.frame_window_128k.len, fixed_in.seek);
    // The window is the caller's and the reader's writes stayed inside it.
    try sentinel.expect(&guarded.before, 0);
    try sentinel.expect(&guarded.after, 0);
}

test "Reader: a contiguous request past the window fails" {
    // Any contiguous request of at most 128 KiB is served (the slide always
    // frees Block_Maximum_Size, §3.1.1.2.4). A request beyond what the window
    // can hold at the consumer's position returns `error.ReadFailed` with
    // `err == .StreamTooLong`, never an assert.
    var rbuf: Buffer(128 * 1024) = undefined;
    var fixed_in: Io.Reader = .fixed(&golden.frame_window_128k);
    var r: Reader = .init(128 * 1024, &fixed_in, &rbuf, null);
    // The guaranteed floor: a whole Block_Maximum_Size of contiguous output.
    try testing.expectEqual(block.max_block_size, (try r.reader.peek(block.max_block_size)).len);
    // Drain everything the pump buffered, so only the retained history stands
    // behind the next request: one byte more than the floor cannot fit.
    try r.reader.discardAll(r.reader.end - r.reader.seek);
    try testing.expectError(error.ReadFailed, r.reader.peek(block.max_block_size + 1));
    try testing.expectEqual(Error.StreamTooLong, r.err.?);
    // The failure is sticky, and the interface keeps reporting it.
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
    try testing.expectError(error.ReadFailed, r.reader.peek(1));
}

test "Reader: a checksummed raw-block frame folds inside the copy" {
    // The streaming reader's Raw blocks fold into the checksum inside the
    // copy (`block.decodeContent`), not in `recordBlock`: two Raw blocks
    // whose sizes straddle the fold chunk must verify their trailer after
    // the window has slid, and a flipped content byte fails with
    // `WrongChecksum`.
    const first_len = 40 * 1024 + 513;
    const second_len = 25 * 1024 + 7;
    const total = first_len + second_len;
    var data: [total]u8 = undefined;
    var rng: DefaultPrng = .init(0xf01d);
    rng.random().bytes(&data);

    var framed: [4 + 2 + 4 + 6 + total + 4]u8 = undefined;
    var at: usize = 0;
    fastmem.copy(u8, framed[at..][0..4], &[_]u8{ 0x28, 0xB5, 0x2F, 0xFD });
    at += 4;
    // Descriptor: four-byte FCS and the Content_Checksum flag; window
    // descriptor exponent 6 (64 KiB); then the FCS.
    framed[at] = 0x84;
    framed[at + 1] = 0x30;
    at += 2;
    writeInt(u32, framed[at..][0..4], total);
    at += 4;
    var src: usize = 0;
    for ([_]usize{ first_len, second_len }, 0..) |size, i| {
        const last: u24 = if (i == 1) 1 else 0;
        writeInt(u24, framed[at..][0..3], last | @as(u24, @intCast(size)) << 3);
        at += 3;
        fastmem.copy(u8, framed[at..][0..size], data[src..][0..size]);
        src += size;
        at += size;
    }
    writeInt(u32, framed[at..][0..4], @truncate(xxh64.xxh64(0, &data)));
    at += 4;

    const window_len = 64 * 1024;
    var rbuf: Buffer(window_len) = undefined;
    var fixed_in: Io.Reader = .fixed(framed[0..at]);
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(
        total,
        try streamAll(window_len, &fixed_in, &out.writer, &rbuf, null),
    );
    try testing.expectEqualSlices(u8, &data, out.written());

    // A flipped byte in the second block's content fails the trailer.
    framed[4 + 2 + 4 + 3 + first_len + 3 + 100] ^= 0x01;
    var bad_in: Io.Reader = .fixed(framed[0..at]);
    var r: Reader = .init(window_len, &bad_in, &rbuf, null);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&sink.writer));
    try testing.expectEqual(Error.WrongChecksum, r.err.?);
}

/// An RLE-only frame: 32,770 four-byte blocks, each one RLE block of
/// 128 KiB. A 131 KB input decodes to 4,295,229,440 bytes (262,144 past
/// 2^32), which exposes 32-bit wraps in the decoded-length and checksum byte
/// counts. The `checksum` switch adds the Content_Checksum_Flag (the
/// descriptor's 0x04) and the four trailer bytes (the low 32 bits of XXH64
/// over the decoded 0x5A bytes, little-endian: 0xB7494A5E, the value the
/// CLI's own checksum of the same bytes produces).
fn buildHugeRleFrame(target: []u8, checksum: bool) usize {
    const block_count = 32_770;
    const block_size = 128 * 1024;
    var at: usize = 0;
    fastmem.copy(u8, target[0..4], &[_]u8{ 0x28, 0xB5, 0x2F, 0xFD });
    target[4] = if (checksum) 0x04 else 0x00;
    target[5] = 0x38; // Window_Descriptor: exponent 7, mantissa 0 (128 KiB).
    at = 6;
    var block_index: usize = 0;
    while (block_index < block_count) : (block_index += 1) {
        const last: u24 = if (block_index + 1 == block_count) 1 else 0;
        const header: u24 = last | (1 << 1) | (@as(u24, block_size) << 3);
        target[at] = @truncate(header);
        target[at + 1] = @truncate(header >> 8);
        target[at + 2] = @truncate(header >> 16);
        target[at + 3] = 0x5A;
        at += 4;
    }
    if (checksum) {
        fastmem.copy(u8, target[at..][0..4], &[_]u8{ 0x5E, 0x4A, 0x49, 0xB7 });
        at += 4;
    }
    return at;
}

/// Drive the reader's pump directly, accumulating the served count in a
/// u64: `streamAll` routes through std's `streamRemaining`, whose own
/// offset accumulation is a usize that wraps past 2^32. A 32-bit caller
/// cannot route around that std limit, so the boundary tests drive the pump
/// themselves. The per-call counts are small on every target; only the
/// total needs the width.
fn drainU64(r: *Reader, served: *u64) !void {
    var sink: Io.Writer.Discarding = .init(&.{});
    while (true) {
        const n = r.reader.stream(&sink.writer, .unlimited) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        served.* += n;
    }
}

test "Reader: the frame total runs past 2^32 without wrapping" {
    // The frame's decoded total must be a u64. An RLE-only frame (4 input
    // bytes per 128 KiB block) decodes past 2^32 bytes from a 131 KB input,
    // so a usize total would panic in Debug/ReleaseSafe and be undefined
    // behavior in ReleaseFast on every 32-bit target. The direct drive below
    // runs on the 32-bit targets themselves (`just check-32`), where the wrap
    // is observable. On a 64-bit host `usize` is `u64` and cannot show a
    // revert, so the comptime type pin catches one on every host.
    comptime {
        assert(@FieldType(frame.State, "decoded_len") == u64);
    }
    const block_count = 32_770;
    const block_size = 128 * 1024;
    var frame_buf: [6 + 4 * block_count]u8 = undefined;
    const len = buildHugeRleFrame(&frame_buf, false);
    try testing.expectEqual(@as(usize, 6 + 4 * block_count), len);

    var fixed_in: Io.Reader = .fixed(frame_buf[0..len]);
    var window: Reader.Buffer(128 * 1024) = undefined;
    var r: Reader = .init(128 * 1024, &fixed_in, &window, null);
    var served: u64 = 0;
    try drainU64(&r, &served);
    try testing.expectEqual(@as(u64, block_count) * block_size, served);
    try testing.expectEqual(@as(usize, frame_buf.len), fixed_in.seek);
    try testing.expectEqual(@as(?Error, null), r.err);
}

test "Reader: the checksum fold runs past 2^32 without wrapping" {
    // The same frame with the Content_Checksum_Flag set, which is a
    // legitimate frame: the CLI writes the checksum by default and `zstd -t`
    // accepts it. std's XxHash64 counts bytes in a usize, so on the 32-bit
    // targets it would panic in ReleaseSafe and report a false
    // `WrongChecksum` in ReleaseFast. `xxh64.zig` has its own kernel with a
    // u64 byte count, so this frame verifies its checksum on every target.
    // The comptime pin catches a revert on every host.
    comptime {
        assert(@FieldType(xxh64.State, "byte_count") == u64);
    }
    const block_count = 32_770;
    const block_size = 128 * 1024;
    var frame_buf: [6 + 4 * block_count + 4]u8 = undefined;
    const len = buildHugeRleFrame(&frame_buf, true);
    try testing.expectEqual(@as(usize, 10 + 4 * block_count), len);

    var fixed_in: Io.Reader = .fixed(frame_buf[0..len]);
    var window: Reader.Buffer(128 * 1024) = undefined;
    var r: Reader = .init(128 * 1024, &fixed_in, &window, null);
    var served: u64 = 0;
    try drainU64(&r, &served);
    try testing.expectEqual(@as(u64, block_count) * block_size, served);
    try testing.expectEqual(@as(usize, frame_buf.len), fixed_in.seek);
    // The clean end is the trailer's verification: no detail, the state done.
    try testing.expectEqual(@as(?Error, null), r.err);
}

test "Reader: an over-the-end request still checks the trailer" {
    // The rebase path: an over-the-end peek at a frame's tail goes through
    // `rebase`, where the frame end (`§3.1.1`'s trailer, read and verified
    // exactly once) must run before the clean end is reported. Reporting the
    // end with the trailer unread would accept a corrupted checksum. RFC 8878
    // §3.1.1: "the result of the XXH64() hash function digesting the original
    // (decoded) data as input, and a seed of zero. The low 4 bytes of the
    // checksum are stored in little-endian format."
    //
    // `frame_checksum_multi` is 135000 bytes with a 135000-byte window
    // (single-segment), so the buffer is window + Block_Maximum_Size; the
    // take lands the frame's whole output in the buffer with the trailer
    // unread, and the over-the-end peek cannot be satisfied beside the
    // retained history.
    const take_len = 135000;
    const peek_len = 140000;

    // The good trailer: the request reports the clean end, the input stands
    // exactly at the frame's last byte, and the state is done with no error.
    {
        var rbuf: Buffer(take_len) = undefined;
        var fixed_in: Io.Reader = .fixed(&golden.frame_checksum_multi);
        var r: Reader = .init(take_len, &fixed_in, &rbuf, null);
        _ = try r.reader.take(take_len);
        try testing.expectError(error.EndOfStream, r.reader.peek(peek_len));
        try testing.expectEqual(golden.frame_checksum_multi.len, fixed_in.seek);
        try testing.expectEqual(State.done, r.state);
        try testing.expectEqual(@as(?Error, null), r.err);
    }

    // The corrupted trailer: the same request fails `ReadFailed` with the
    // specific error, on every trailer byte.
    for (0..frame.checksum_len) |at| {
        var bad: [golden.frame_checksum_multi.len]u8 = undefined;
        fastmem.copy(u8, &bad, &golden.frame_checksum_multi);
        bad[bad.len - frame.checksum_len + at] ^= 0x01;
        var rbuf: Buffer(take_len) = undefined;
        var fixed_in: Io.Reader = .fixed(&bad);
        var r: Reader = .init(take_len, &fixed_in, &rbuf, null);
        _ = try r.reader.take(take_len);
        try testing.expectError(error.ReadFailed, r.reader.peek(peek_len));
        try testing.expectEqual(Error.WrongChecksum, r.err.?);
        try testing.expectEqual(State.failed, r.state);
    }
}

test "Reader: a chunked input refills across the header and a block" {
    // The reader's input must buffer at least 4 bytes, the frame layer's
    // largest fixed-size read (the magic, a skippable frame's Frame_Size, or
    // the checksum; the 3-byte block header fits inside it). A 4-byte input
    // buffer is therefore the minimum, and the header parse, the block
    // staging, and the trailer read all run on refills. The marker bytes
    // behind the frame must never reach the decoder.
    const gpa = testing.allocator;
    const markers = 8;
    const framed = try gpa.alloc(u8, golden.frame_checksum_multi.len + markers);
    defer gpa.free(framed);
    fastmem.copy(u8, framed[0..golden.frame_checksum_multi.len], &golden.frame_checksum_multi);
    fastmem.set(u8, framed[golden.frame_checksum_multi.len..], 0xaa);

    var small: [4]u8 = undefined;
    var inner: Io.Reader = .fixed(framed);
    var chunked: Io.Reader.Limited = .init(&inner, .unlimited, &small);
    var rbuf: Buffer(135000) = undefined;
    var r: Reader = .init(135000, &chunked.interface, &rbuf, null);
    const out = try r.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(out);
    try testing.expectEqual(135000, out.len);
    try testing.expectEqualStrings(golden.frame_checksum_multi_text ** 3000, out);
    try testing.expectEqual(@as(?Error, null), r.err);
    // The logical input position — the inner's position less the chunked
    // reader's still-buffered bytes — is the frame's last byte.
    const buffered = chunked.interface.end - chunked.interface.seek;
    try testing.expectEqual(golden.frame_checksum_multi.len, inner.seek - buffered);
}

test "Reader: a zero-length poll does not fail the stream" {
    // The zero-length poll: std calls `vtable.stream` at limit 0 when the
    // buffer is nonempty, and the poll must answer 0 without filling (a fill
    // could fail `StreamTooLong` on a valid stream).
    const gpa = testing.allocator;
    var rbuf: Buffer(fixture_buffer_len) = undefined;
    var fixed_in: Io.Reader = .fixed(&golden.frame_checksum_multi);
    var r: Reader = .init(fixture_buffer_len, &fixed_in, &rbuf, null);
    _ = try r.reader.peek(1);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectEqual(@as(usize, 0), try r.reader.stream(&sink.writer, .limited(0)));
    try testing.expectEqual(@as(?Error, null), r.err);
    const got = try r.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(got);
    try testing.expectEqualStrings(golden.frame_checksum_multi_text ** 3000, got);
}

test "Reader: random consumer machinery sequences stay correct" {
    // Mixed peek/take/discardAll/readSliceAll/stream operations over the
    // multi-block, checksummed fixture: the driver class that catches vtable
    // machinery interactions (contiguity, slide accounting, the sticky end).
    // The frame's output is 135000 bytes over a 135000-byte window, so the
    // driver's positions exercise the slide.
    var rng: DefaultPrng = .init(4242);
    const rand = rng.random();
    const input = golden.frame_checksum_multi_text ** 3000;
    var rbuf: Buffer(135000) = undefined;

    var iter: usize = 0;
    while (iter < 8) : (iter += 1) {
        var fixed_in: Io.Reader = .fixed(&golden.frame_checksum_multi);
        var r: Reader = .init(135000, &fixed_in, &rbuf, null);
        var pos: usize = 0;
        while (pos < input.len) {
            const left = input.len - pos;
            switch (rand.uintLessThan(u8, 5)) {
                0 => {
                    const n = @min(left, rand.intRangeAtMost(usize, 1, block.max_block_size));
                    try testing.expectEqualSlices(u8, input[pos..][0..n], try r.reader.peek(n));
                },
                1 => {
                    const n = @min(left, rand.intRangeAtMost(usize, 1, block.max_block_size));
                    try testing.expectEqualSlices(u8, input[pos..][0..n], try r.reader.take(n));
                    pos += n;
                },
                2 => {
                    const n = @min(left, rand.intRangeAtMost(usize, 1, input.len));
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
                    // `stream` may serve from the buffer or fill it; the
                    // bytes land in `fw` or stay buffered. Only the served
                    // count is contractual.
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
        // The clean end of the frame is sticky.
        var sink: Io.Writer.Discarding = .init(&.{});
        try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
    }
}
