//! `brotli.Reader`: a decompressing `Io.Reader` over one brotli stream
//! (RFC 7932). Read through `&r.reader`: the decoded stream is served from
//! the caller's buffer, and the stream ends with `error.EndOfStream` at its
//! exact last byte, so the input position at a clean end is the next stream's
//! first byte (`streamAll` walks them).
//!
//! The caller owns the decode buffer, `Buffer(window_wbits)`: a
//! `(1 << window_wbits)`-byte history ring — the decoded output *is* the
//! match history (`§8`), so the ring is both the window and the region the
//! reader serves from — plus the meta-block header arena. A stream whose
//! WBITS is above the instantiation fails `WindowTooLarge` before any
//! meta-block byte. A failed read returns `error.ReadFailed` and the detail
//! is in `err`. Nothing is allocated.
//!
//! Format: docs/research/specs/rfc7932-brotli.txt. API: README.md.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;

const fastmem = @import("fastmem");

const internal = @import("../internal/root.zig");
const State = internal.reader.State;
const VTable = internal.reader.VTable;
const bits = @import("bits.zig");
const command = @import("command.zig");
const decode = @import("decode.zig");
const frame = @import("frame.zig");
const golden = @import("golden.zig");

/// The caller-owned decode buffer: the history ring plus the meta-block
/// header arena. `window_wbits` is 10..24 (`§9.1`), and `init` reads the
/// window cap from this exact type, so the buffer and the cap cannot
/// disagree.
pub fn Buffer(comptime window_wbits: usize) type {
    comptime assert(window_wbits >= 10);
    comptime assert(window_wbits <= 24);
    return struct {
        /// `§9.1` — the `(1 << window_wbits)`-byte history ring. It is also
        /// the region the reader serves decoded bytes from, so the consumer
        /// must keep up within a window's worth of output; the reader stops
        /// (and later wraps) when the ring fills.
        ring: [1 << window_wbits]u8,
        /// `§9.2` — the meta-block header arena: the context models, the two
        /// maps, and the tree region (OQ8's comptime cap).
        header: frame.Header,
    };
}

/// The default window cap, 24 — the format's maximum (`§9.1`). Measured
/// (F9): the reference CLI's pipe form emits WBITS 24 for every stream it
/// writes, and its file form 10..19 by input size, so 24 decodes both
/// unconfigured. `Buffer(22)` (4.7 MiB rather than 16.7) decodes the file
/// family only.
pub const default_window_wbits: usize = 24;

/// `Buffer(default_window_wbits)`: a 16 MiB ring plus the tree region, about
/// 16.7 MiB — keep it in static or heap storage.
pub const DefaultBuffer = Buffer(default_window_wbits);

/// The reader's error set: the one-shot decoder's `DecompressError` without
/// `BufferTooSmall` (the ring is the caller's buffer, so no decode can
/// outgrow it), plus the names this layer adds. `err` holds one of these once
/// `state == .failed`; the `Io.Reader` interface itself reports only
/// `error.ReadFailed` or `error.EndOfStream`.
pub const Error = error{
    /// `§9.1` — WBITS is the invalid 0010001 pattern. The one-shot's name for
    /// the same wire pattern; at a start position the reader reports
    /// `BadStreamStart` instead (the walk's name for bytes that cannot begin
    /// a stream).
    BadWindowBits,
    /// The input ended before the stream did.
    Truncated,
    /// `§9.2` — the metadata meta-block's reserved bit is set.
    ReservedBit,
    /// `§9.2` — MNIBBLES > 4 with an all-zero last nibble.
    ExuberantNibble,
    /// `§9.2` — MSKIPBYTES > 1 with an all-zero last byte.
    ExuberantMetaNibble,
    /// Nonzero fill bits where the format requires zeros (`§9.2`, `§9.3`).
    BadPadding,
    /// `§3.4` — a simple code's symbol is at or past the alphabet size.
    SimpleHuffmanAlphabet,
    /// `§3.4` — a simple code repeats a symbol.
    SimpleHuffmanSame,
    /// `§3.5` — the code-length code is not a complete prefix code.
    BadCodeLengthCode,
    /// `§3.5` — a code-length sequence breaks the format's rules.
    BadHuffmanCode,
    /// `§6`, `§9.3` — a block count, or the meta-block length accounting.
    BadBlockLength,
    /// `§7.3` — a context map's zero-run overruns the map.
    ContextMapRepeat,
    /// `§4` — a special distance code resolves to zero or less.
    BadDistance,
    /// `§8` — a transform id above 120, or a word the transform empties.
    BadTransform,
    /// `§8` — a dictionary reference's word length is outside 4..24.
    BadDictionary,
    /// This decoder's instantiation (OQ8) — a meta-block declares more than
    /// 64 trees in a category.
    TooManyTrees,
    /// `§9.1` — the stream's WBITS is above the instantiated `window_wbits`.
    /// Reported once the header is parsed, before any meta-block byte.
    WindowTooLarge,
    /// The input at a start position cannot begin a stream (`§9.1`'s invalid
    /// 0010001 pattern, the reference family's large-window marker). The
    /// walk's name: `streamAll` reads a tail as the next stream, and this is
    /// why it refuses one.
    BadStreamStart,
    /// A contiguous request (`peek`, `take`, ...) is larger than the ring can
    /// hold at the consumer's position. A consumer can cause it, so it is an
    /// error and not an assert.
    StreamTooLong,
    /// The input reader failed with `error.ReadFailed`.
    ReadFailed,
    /// The clean end of the stream. The interface reports it as
    /// `error.EndOfStream`; it is never recorded in `err`.
    EndOfStream,
};

comptime {
    // The set is the README's: every one-shot name except `BufferTooSmall`,
    // plus the five this layer adds. A name the reader forgot, or one it
    // invented, fails the build here (the `decode.zig` vocabulary check, one
    // layer up).
    @setEvalBranchQuota(100_000);
    const own = [_][]const u8{
        "WindowTooLarge",
        "BadStreamStart",
        "StreamTooLong",
        "ReadFailed",
        "EndOfStream",
    };
    const one_shot = @typeInfo(decode.DecompressError).error_set.?;
    const mine = @typeInfo(Error).error_set.?;
    assert(mine.len == one_shot.len - 1 + own.len);
    for (one_shot) |want| {
        var found = false;
        for (mine) |entry| {
            if (std.mem.eql(u8, entry.name, want.name)) found = true;
        }
        // `BufferTooSmall` is the one name the reader does not carry: the
        // window is the caller's ring, and every output path is bounded by
        // its room.
        assert(found == !std.mem.eql(u8, want.name, "BufferTooSmall"));
    }
    for (own) |name| {
        var found = false;
        for (mine) |entry| {
            if (std.mem.eql(u8, entry.name, name)) found = true;
        }
        assert(found);
    }
}

/// The reader's position in the stream: the resume point across pump calls.
/// A meta-block's decode resumes at a byte of its own command stream
/// (`command.Cursor`), so these are the only phases.
const Phase = enum {
    /// `§9.1` — the stream header.
    header,
    /// `§9.2` — the meta-block ladder, and the dispatch on the form it found.
    meta_block,
    /// A compressed meta-block's command stream (`command.step`).
    commands,
    /// An uncompressed meta-block's payload (`§9.2`).
    payload,
    /// The last meta-block is decoded: `§9.3`'s zero fill, then the end.
    end,
};

const Reader = @This();

reader: Io.Reader,
/// The stream's input, consumed exactly through the stream's last byte.
/// Later bytes stay unread, so the caller can start another `Reader` there.
/// Its buffer must hold at least four bytes (the widest field the bit reader
/// assembles is 24 bits, and the peek table reads eight at a time);
/// `Io.Reader.fixed` always qualifies.
input: *Io.Reader,
/// The history ring: the buffer's front `1 << window_wbits` bytes, and the
/// same slice as `reader.buffer` (the region the consumer reads from).
ring: []u8,
/// The meta-block header arena, in the caller's buffer.
header: *frame.Header,
/// The bit reader over the input's current slice (`StreamBits` attaches a
/// fresh one whenever the input is pulled).
bit_reader: bits.BitReader = .init(&[_]u8{}),
/// The stream's produced count: `§8`'s window bound and dictionary class
/// compare against it, and it keeps growing after the ring wraps.
produced: u64 = 0,
/// `§9.1` — the stream's window size, `(1 << WBITS) - 16`, once the header
/// is parsed.
window_size: u32 = 0,
/// The window in flight: the ring, the position of the next output byte, the
/// produced count, and the meta-block's remaining MLEN. The command stream's
/// `step` owns it for a compressed meta-block; the payload phase owns it for
/// an uncompressed one.
window: command.Window,
/// The stream-scoped command state (`§4`'s four-distance ring and the
/// distance tables each meta-block derives).
commands: command.State = .{},
/// The command stream's resume point, while `phase == .commands`.
cursor: command.Cursor = undefined,
/// Whether the meta-block in flight is the stream's last (`§9.2`'s ISLAST).
is_last: bool = false,
phase: Phase = .header,
/// The stream lifecycle (`src/internal/reader.zig`): `streaming` until the
/// stream's last byte is decoded (`done`) or a failure sticks (`failed`,
/// details in `err`).
state: State = .streaming,
/// Detailed error once `state == .failed`; the interface reports
/// `error.ReadFailed`.
err: ?Error = null,

/// The `Io.Reader` entries, generated by `internal.reader.VTable`: the sticky
/// done/failed guard, the zero-length poll, and the fill-and-return-0 count
/// come from there. `pump` is this reader's fill; `rebase` owns the ring's
/// capacity policy.
const vtable = VTable(Reader, pump, rebase).vtable;

/// Wrap `input` (one brotli stream) with `buffer` for the history ring and
/// the meta-block trees. `window_wbits` is the largest WBITS the reader
/// accepts, and `buffer` must be a `Buffer(window_wbits)`, which the compiler
/// checks at the call. `input` needs a buffer of at least four bytes (the
/// widest field the bit reader assembles is 24 bits, and the peek table reads
/// eight at a time). `init` reads nothing from `input` and allocates nothing.
///
/// Read through `&r.reader` (`stream`, the `read` family, the `peek`
/// family). Once the stream's last byte is decoded, reads return
/// `error.EndOfStream`. A malformed stream or a failing `input` returns
/// `error.ReadFailed`, and so does every later read, with the detail in
/// `err`. The reader consumes `input` exactly through the stream's last byte
/// and leaves any later bytes unread.
pub fn init(comptime window_wbits: usize, input: *Io.Reader, buffer: *Buffer(window_wbits)) Reader {
    return .{
        .reader = .{
            .buffer = &buffer.ring,
            .seek = 0,
            .end = 0,
            .vtable = &vtable,
        },
        .input = input,
        .ring = &buffer.ring,
        .header = &buffer.header,
        .window = .{
            .bytes = &buffer.ring,
            .pos = 0,
            .produced = 0,
            .left = 0,
            .bound = 0,
        },
    };
}

/// Decode every stream in `in` into `out` through `buffer`, and return the
/// total number of bytes written. The output is the concatenation of the
/// streams. Each stream is decoded as `init` describes, starting where the
/// previous one ended. An input that holds nothing at all decodes to zero
/// bytes (the walk's clean end); bytes at a start position that cannot begin
/// a stream fail `error.ReadFailed` (the cause is `BadStreamStart`). `in`
/// needs a buffer of at least four bytes (see `init`); `Io.Reader.fixed`
/// always qualifies. Does not allocate.
pub fn streamAll(
    comptime window_wbits: usize,
    in: *Io.Reader,
    out: *Io.Writer,
    buffer: *Buffer(window_wbits),
) Io.Reader.StreamRemainingError!usize {
    var rr: Reader = undefined;
    var served: usize = 0;
    while (true) {
        // A clean end between streams is the input's end; any byte where a
        // stream should start is parsed as one, so garbage returns an error.
        _ = in.peekByte() catch |err| switch (err) {
            error.EndOfStream => return served,
            else => |e| return e,
        };
        rr = .init(window_wbits, in, buffer);
        served += try rr.reader.streamRemaining(out);
    }
}

/// The vtable's fill: decode into the ring until it is full or the stream
/// ends. A full ring that the consumer has not drained returns zero added
/// bytes: its bytes are the consumer's until it consumes them.
fn pump(r: *Reader) Io.Reader.Error!usize {
    return r.record(r.fill());
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
/// `error.ReadFailed`. The ring's unconsumed bytes are dropped, so no partial
/// output is trusted past an error (the flate and zstd readers do the same).
fn fail(r: *Reader, err: Error) Io.Reader.Error {
    r.reader.seek = r.reader.end;
    return internal.reader.fail(Error, &r.state, &r.err, err);
}

/// One fill: the stream header, the meta-block ladder, and the meta-block in
/// flight, into the ring. Returns the bytes added; zero only when the ring is
/// full and the consumer has not drained it.
fn fill(r: *Reader) Error!usize {
    var added: usize = 0;
    while (true) {
        if (r.reader.end == r.ring.len) {
            // The ring is full: its bytes are output the consumer has not
            // read yet, so the reader can only wrap once they are gone.
            if (r.reader.seek < r.reader.end) return added;
            r.wrap();
        }
        switch (r.phase) {
            .header => {
                var stream_bits = r.streamBits();
                const header = frame.readStreamHeader(StreamBits, &stream_bits);
                const stream = header catch |err| switch (err) {
                    // `§9.1` — 0010001 "is invalid and must not be used". At
                    // a start position those bytes cannot begin a stream:
                    // the walk's refusal, which the one-shot names
                    // `BadWindowBits` (T3).
                    error.BadWindowBits => return error.BadStreamStart,
                    else => |e| return e,
                };
                // `§9.1` — the caller's buffer is the window authorization:
                // a stream whose WBITS is above it fails before any
                // meta-block byte.
                if (stream.window_size > @as(u32, @intCast(r.ring.len)) - 16) {
                    return error.WindowTooLarge;
                }
                r.window_size = stream.window_size;
                r.phase = .meta_block;
            },
            .meta_block => {
                var stream_bits = r.streamBits();
                const meta = (try frame.nextMetaBlock(StreamBits, &stream_bits, r.header)) orelse {
                    // `§9.2` — ISLAST+ISLASTEMPTY, or an ISLAST metadata
                    // meta-block: the stream ends here, its zero fill
                    // already checked by the ladder.
                    r.phase = .end;
                    continue;
                };
                r.window = .{
                    .bytes = r.ring,
                    .pos = r.reader.end,
                    .produced = r.produced,
                    .left = meta.mlen,
                    .bound = r.window_size,
                };
                switch (meta.kind) {
                    .uncompressed => r.phase = .payload,
                    .compressed => {
                        r.commands.beginMetaBlock(r.header);
                        r.cursor = .{ .blocks = command.Blocks.init(r.header) };
                        r.phase = .commands;
                    },
                }
                r.is_last = meta.is_last;
            },
            .commands => {
                r.window.pos = r.reader.end;
                r.window.produced = r.produced;
                const before = r.window.left;
                var stream_bits = r.streamBits();
                try command.step(
                    StreamBits,
                    &stream_bits,
                    r.header,
                    &r.commands,
                    &r.cursor,
                    &r.window,
                );
                r.reader.end = r.window.pos;
                r.produced = r.window.produced;
                added += before - r.window.left;
                if (r.window.left == 0) r.phase = if (r.is_last) .end else .meta_block;
            },
            .payload => {
                // `§9.2` — "the rest of the meta-block contains MLEN bytes of
                // literal data", at the next byte boundary.
                const n: u32 = @intCast(@min(r.window.left, r.ring.len - r.reader.end));
                var stream_bits = r.streamBits();
                try stream_bits.takeBytes(r.ring[r.reader.end..][0..n]);
                r.reader.end += n;
                r.produced += n;
                r.window.left -= n;
                added += n;
                if (r.window.left == 0) r.phase = if (r.is_last) .end else .meta_block;
            },
            .end => {
                var stream_bits = r.streamBits();
                // `§9.3` — "If the last command of the last non-empty
                // meta-block does not end on a byte boundary, the unused bits
                // in the last byte must be zeros."
                try stream_bits.alignToByte();
                // The stream ends at the byte the last bit is in: the bytes
                // the reader loaded past it belong to whatever follows (T4).
                stream_bits.tossConsumed();
                if (added > 0) return added;
                return error.EndOfStream;
            },
        }
        if (r.reader.end == r.ring.len) return added;
    }
}

/// Wrap the ring: the history stays in place and the serving window restarts
/// at its front. Valid only once the consumer has drained it, so the bytes it
/// overwrites are history, not output.
fn wrap(r: *Reader) void {
    assert(r.reader.end == r.ring.len);
    assert(r.reader.seek == r.reader.end);
    r.reader.seek = 0;
    r.reader.end = 0;
}

/// The bit source for this reader's input, for the layers that are generic
/// over `Bits`.
fn streamBits(r: *Reader) StreamBits {
    return .{ .r = r };
}

/// The `bits.BitReader` interface over the reader's input: the stream header,
/// the meta-block ladder, the prefix codes, and the command stream are
/// generic over this type exactly as they are over `bits.BitReader`, so the
/// streaming decode reads the same code paths as the one-shot.
///
/// Every read pulls more input when the loaded slice runs out. The input's
/// end turns a `take` into `Truncated` (`§10`) and a `peek` into the same
/// zero padding the one-shot sees at the stream's end; a failing input is
/// `ReadFailed`, the interface's own name.
const StreamBits = struct {
    pub const ErrorSet = bits.Error || error{ReadFailed};

    r: *Reader,

    /// The next `n` bits, least significant bit first (`§1.5.1`), without
    /// consuming them. Bits past the input's end read as zero: `take` is the
    /// gate that turns a starved read into `error.Truncated`, exactly as in
    /// `bits.BitReader`.
    pub fn peek(self: *StreamBits, n: u6) ErrorSet!u32 {
        while (self.r.bit_reader.availableBits() < n) {
            if (!try self.pull()) break;
        }
        return self.r.bit_reader.peek(n);
    }

    /// The next `n` bits, least significant bit first (`§1.5.1`).
    /// `error.Truncated` when the stream holds fewer than `n`.
    pub fn take(self: *StreamBits, n: u6) ErrorSet!u32 {
        while (self.r.bit_reader.availableBits() < n) {
            if (!try self.pull()) break;
        }
        return self.r.bit_reader.take(n);
    }

    /// Consume `n` bits a successful `peek` of at least `n` loaded: the
    /// peek pulled until the accumulator held `n` bits or the input ended,
    /// so the slice reader's own gate is exact. The prefix-code layer's
    /// consume (see `bits.BitReader.takeLoaded`).
    pub fn takeLoaded(self: *StreamBits, n: u6) ErrorSet!u32 {
        return self.r.bit_reader.takeLoaded(n);
    }

    /// Skip to the next byte boundary, checking that the skipped bits are
    /// zero (`§9.2`'s fill fields, `§9.3`'s last-byte fill).
    pub fn alignToByte(self: *StreamBits) ErrorSet!void {
        const skip: u6 = @intCast((8 - (self.r.bit_reader.bit_pos & 7)) & 7);
        if (skip != 0) {
            if (try self.take(skip) != 0) return error.BadPadding;
        }
    }

    /// Copy the next `target.len` bytes out — an uncompressed meta-block's
    /// payload (`§9.2`) — across as many input fills as it takes. Only valid
    /// at a byte boundary.
    pub fn takeBytes(self: *StreamBits, target: []u8) ErrorSet!void {
        assert(self.r.bit_reader.atByteBoundary());
        var done: usize = 0;
        // The whole bytes the accumulator already holds come out first: the
        // loaded slice only holds what has not been loaded. The count is
        // captured on entry — a `take` refills the accumulator from the
        // slice, so re-testing `bit_count` here would drain the whole
        // payload a byte at a time and never reach the bulk copy below.
        // The drain is `takeLoaded`, never `take`: refilling mid-drain
        // would both keep the loop from ending and leave the accumulator
        // holding bytes a later `pull` attaches past, which the bulk
        // copy's `rewind` cannot represent (`bit_pos/8 < source_base`).
        // Ending the drain with the accumulator empty keeps
        // `bit_pos/8 == loadedBytes` across a `pull`.
        const buffered = @min(target.len, self.r.bit_reader.bit_count / 8);
        while (done < buffered) : (done += 1) {
            target[done] = @intCast(try self.r.bit_reader.takeLoaded(8));
        }
        while (done < target.len) {
            const available = self.r.bit_reader.source.len - self.r.bit_reader.next_byte;
            if (available == 0) {
                if (!try self.pull()) return error.Truncated;
                continue;
            }
            const n = @min(target.len - done, available);
            try self.r.bit_reader.takeBytes(target[done..][0..n]);
            done += n;
        }
    }

    /// Skip `count` bytes — a metadata meta-block's payload, which is neither
    /// output, window, nor literal context (`§2`, `§9.2`). Only valid at a
    /// byte boundary.
    pub fn skipBytes(self: *StreamBits, count: u32) ErrorSet!void {
        assert(self.r.bit_reader.atByteBoundary());
        var left = count;
        // As in `takeBytes`: only the bytes buffered on entry drain
        // through the accumulator, and the drain is `takeLoaded` — a
        // refilling `take` would never let the loop end, and would leave
        // the accumulator holding bytes a later `pull` attaches past.
        const buffered: u32 = @intCast(@min(left, self.r.bit_reader.bit_count / 8));
        for (0..buffered) |_| {
            _ = try self.r.bit_reader.takeLoaded(8);
            left -= 1;
        }
        while (left > 0) {
            const available = self.r.bit_reader.source.len - self.r.bit_reader.next_byte;
            if (available == 0) {
                if (!try self.pull()) return error.Truncated;
                continue;
            }
            const n: u32 = @intCast(@min(left, available));
            try self.r.bit_reader.skipBytes(n);
            left -= n;
        }
    }

    /// Pull the next slice of the input into the bit reader. Returns false at
    /// the input's end, where the buffered bits are all that is left.
    ///
    /// Everything the accumulator holds is given back to the input first, so
    /// the read is forced even while the input's buffer still holds the byte
    /// the accumulator loaded from — a plain `fill(1)` would return on that
    /// byte and the caller's loop would make no progress.
    fn pull(self: *StreamBits) ErrorSet!bool {
        const br = &self.r.bit_reader;
        // The bytes of the current slice the accumulator has loaded, an
        // offset inside the input buffer (so a `usize` on every target).
        self.r.input.toss(@intCast(br.loadedBytes() - br.source_base));
        var filled = true;
        // Bytes the input buffers beyond the slice the reader holds are new
        // to it: it starts with an empty slice, and the walk's `peekByte` may
        // have primed a full buffer, so there is nothing to read. Otherwise
        // the caller asked for bits this slice cannot supply and a read is
        // forced — `fillMore` slides the reader's bytes down to make room.
        if (br.source.len >= self.r.input.end - self.r.input.seek) {
            const before = self.r.input.end - self.r.input.seek;
            while (self.r.input.end - self.r.input.seek <= before) {
                self.r.input.fillMore() catch |err| switch (err) {
                    error.EndOfStream => {
                        filled = false;
                        break;
                    },
                    error.ReadFailed => return error.ReadFailed,
                };
            }
        }
        // A fill may have slid the buffer's contents, so the reader
        // re-attaches either way: `attach` continues at the first byte it has
        // not loaded, which is `loadedBytes()` in its own count.
        br.attach(self.r.input.buffered(), br.loadedBytes());
        return filled;
    }

    /// Hand the input back the bytes the stream has consumed, so its position
    /// is the byte after the stream's last bit and whatever follows is the
    /// caller's (T4). Idempotent: a second call consumes nothing more.
    fn tossConsumed(self: *StreamBits) void {
        const br = &self.r.bit_reader;
        assert(br.bit_pos / 8 >= br.source_base);
        const consumed: u64 = br.bit_pos / 8;
        self.r.input.toss(@intCast(consumed - br.source_base));
        br.attach(self.r.input.buffered(), consumed);
    }
};

/// The rebase hook for the generated entries: make room for `capacity` more
/// contiguous bytes at the consumer's position. The ring serves a contiguous
/// run up to its end — the README's "up to the history ring's room at the
/// read position" — so a larger request is `StreamTooLong`, never an assert
/// (std's own `rebase` asserts here). Otherwise the reader decodes until the
/// request is buffered or the stream ends.
fn rebase(r: *Reader, capacity: usize) Io.Reader.RebaseError!void {
    // A full ring the consumer has drained restarts at its front here too:
    // `peek` and `take` reach this hook without a pump first.
    if (r.reader.end == r.ring.len and r.reader.seek == r.reader.end) r.wrap();
    if (capacity > r.ring.len - r.reader.seek) return r.fail(error.StreamTooLong);
    while (r.reader.end - r.reader.seek < capacity) {
        if (r.state != .streaming) return error.EndOfStream;
        const added = try r.record(r.fill());
        // `fill` returns zero only with the ring full of unconsumed bytes,
        // which the capacity check above rules out. A consumer cannot cause
        // this, so it is not an assert either.
        if (added == 0) return r.fail(error.StreamTooLong);
    }
}

// ---------------------------------------------------------------------------
// Tests. Spec: docs/research/specs/rfc7932-brotli.txt §9.1 (the header), §9.2
// (the meta-block ladder), §9.3 (the last-byte fill), §10 (the command
// stream's execution). The fixtures are `golden.zig`'s, each verified with
// the pinned CLI (brotli 1.2.0); every decode checks the output byte for byte
// and the input's exact boundary.
// ---------------------------------------------------------------------------

/// A test input that hands the reader one byte per fill, so every pull path
/// runs: the bit reader's seam mid-integer, the meta-block ladder across
/// fills, and the ring's flushes.
const Trickle = struct {
    source: []const u8,
    pos: usize = 0,
    reader: Io.Reader,

    fn init(source: []const u8, buffer: []u8) Trickle {
        return .{
            .source = source,
            .reader = .{ .buffer = buffer, .seek = 0, .end = 0, .vtable = &Trickle.vtable },
        };
    }

    const vtable: Io.Reader.VTable = .{ .stream = stream };

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const host: *Trickle = @alignCast(@fieldParentPtr("reader", r));
        if (host.pos == host.source.len) return error.EndOfStream;
        const n = @min(@as(usize, 1), @intFromEnum(limit));
        const written = try w.write(host.source[host.pos..][0..n]);
        host.pos += written;
        return written;
    }
};

/// Decode `stream` through a streaming `Reader` over a
/// `Buffer(window_wbits)` and check the output and the boundary: the bytes
/// served are exactly `expected`, and the input is consumed through the
/// stream's last byte (T4).
fn expectStream(
    comptime window_wbits: usize,
    stream: []const u8,
    expected: []const u8,
    buffer: *Buffer(window_wbits),
) !void {
    var fixed_in: Io.Reader = .fixed(stream);
    var r: Reader = .init(window_wbits, &fixed_in, buffer);
    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    _ = try r.reader.streamRemaining(&plain.writer);
    try testing.expectEqual(expected.len, plain.written().len);
    try testing.expectEqualSlices(u8, expected, plain.written());
    try testing.expect(r.err == null);
    try testing.expectEqual(stream.len, fixed_in.seek);
    // The clean end is sticky.
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
}

/// Decode `stream` through a streaming `Reader` and expect the named refusal,
/// with nothing trusted past it.
fn expectStreamError(
    comptime window_wbits: usize,
    stream: []const u8,
    want: Error,
    buffer: *Buffer(window_wbits),
) !void {
    var fixed_in: Io.Reader = .fixed(stream);
    var r: Reader = .init(window_wbits, &fixed_in, buffer);
    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    try testing.expectError(error.ReadFailed, r.reader.streamRemaining(&plain.writer));
    try testing.expectEqual(want, r.err.?);
    // The failure is sticky.
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, r.reader.stream(&sink.writer, .unlimited));
}

test "Reader: the buffer's size is the README's figure" {
    // The README's figures: the ring is `1 << window_wbits` bytes, the tree
    // region is the meta-block header arena (`frame.Header`, 707,204 bytes at
    // OQ8's cap). `Buffer(24)` is 16,777,216 + 707,204 = 17,484,420 bytes,
    // about 16.7 MiB; `Buffer(22)` is about 4.7.
    try testing.expectEqual(@as(usize, 707_204), @sizeOf(frame.Header));
    try testing.expectEqual(@as(usize, 17_484_420), @sizeOf(DefaultBuffer));
    try testing.expectEqual(@as(usize, 4_901_508), @sizeOf(Buffer(22)));
}

test "Reader: the error vocabulary is the README's list" {
    // The comptime block above checks the names one for one; this pins the
    // count, so a name that vanished along with its README line cannot pass.
    // 17 one-shot names, minus `BufferTooSmall`, plus this layer's five.
    try testing.expectEqual(@as(usize, 21), @typeInfo(Error).error_set.?.len);
}

test "Reader: the README's streaming snippet decodes a stream" {
    // The README's Usage snippet, as written: `DefaultBuffer` (16.7 MiB, in
    // static or heap storage), `init`, and `streamRemaining` through the
    // `Io.Reader` interface; on ReadFailed, `err` says why.
    const buffer = try testing.allocator.create(DefaultBuffer);
    defer testing.allocator.destroy(buffer);
    var in: Io.Reader = .fixed(golden.cli_text_q11.bytes);
    var r: Reader = .init(default_window_wbits, &in, buffer);
    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    _ = try r.reader.streamRemaining(&plain.writer);
    try testing.expectEqualStrings(golden.cli_text_q11.plain, plain.written());
    try testing.expect(r.err == null);
    try testing.expectEqual(golden.cli_text_q11.bytes.len, in.seek);
}

test "Reader: the golden corpus decodes byte-exact through the streaming path" {
    // Every hand-built vector of every layer, whole streams end to end, plus
    // the CLI's own streams (F6's dictionary-bearing text rows among them).
    // The default buffer covers the CLI's pipe family, which is WBITS 24
    // (F9); the vectors are the same ones `decode.zig` decodes in one shot.
    const buffer = try testing.allocator.create(DefaultBuffer);
    defer testing.allocator.destroy(buffer);
    const cases = [_]golden.Stream{
        golden.hand_stream,
        golden.unordered_symbol_stream,
        golden.wide_symbol_stream,
        golden.high_literal_stream,
        golden.complex_tree_stream,
        golden.complex_single_stream,
        golden.repeat16_stream,
        golden.context_map_stream,
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
        golden.ring_no_push_zero,
        golden.dictionary_word,
        golden.dictionary_ferment,
        golden.dictionary_ferment_utf8,
        golden.dictionary_affix,
        golden.dictionary_omit,
        golden.dictionary_identity_24,
        golden.dictionary_empty,
        golden.window_bound,
        golden.cli_text_q1,
        golden.cli_text_q2,
        golden.cli_text_q5,
        golden.cli_text_q9,
        golden.cli_text_q11,
        golden.cli_repeat_q1,
        golden.cli_repeat_q2,
        golden.cli_repeat_q5,
        golden.cli_repeat_q9,
        golden.cli_repeat_q11,
        golden.cli_run_q1,
        golden.cli_run_q2,
        golden.cli_run_q5,
        golden.cli_run_q9,
        golden.cli_run_q11,
        golden.cli_digits_q1,
        golden.cli_digits_q2,
        golden.cli_digits_q5,
        golden.cli_digits_q9,
        golden.cli_digits_q11,
        golden.cli_small_window,
        golden.cli_golden_q9_w16,
    };
    for (cases) |case| try expectStream(default_window_wbits, case.bytes, case.plain, buffer);

    // The metadata and uncompressed forms, and the empty family: nothing
    // decoded, or bytes that pass through untouched.
    for (golden.metadata_streams) |case| {
        try expectStream(default_window_wbits, case.bytes, case.plain, buffer);
    }
    for (golden.uncompressed_streams) |case| {
        try expectStream(default_window_wbits, case.bytes, case.plain, buffer);
    }
    for (golden.empty_streams) |stream| {
        try expectStream(default_window_wbits, stream, "", buffer);
    }
    for (golden.last_metadata_streams) |stream| {
        try expectStream(default_window_wbits, stream, "", buffer);
    }
}

test "Reader: a small ring wraps under a long copy" {
    // `cli_small_window` declares WBITS 10 (1,008 bytes, §9.1) and holds one
    // 4,355-byte copy at distance 45, so a `Buffer(10)` — a 1,024-byte ring —
    // wraps its ring under the copy and reads the match out of the ring's
    // previous pass (§10). The default buffer decodes the same stream.
    var small: Buffer(10) = undefined;
    try expectStream(10, golden.cli_small_window.bytes, golden.cli_small_window.plain, &small);
    const big = try testing.allocator.create(DefaultBuffer);
    defer testing.allocator.destroy(big);
    try expectStream(
        default_window_wbits,
        golden.cli_small_window.bytes,
        golden.cli_small_window.plain,
        big,
    );
}

test "Reader: an uncompressed payload crosses the ring's end" {
    // RFC 7932 §9.2 — an uncompressed meta-block's MLEN bytes follow at the
    // next byte boundary, and a ring writes them in segments. §11.1's trivial
    // compressor declares WBITS 16 (a 65,536-byte ring), so a 70,020-byte
    // payload fills the ring once and crosses its end with a second segment.
    const plain = "the quick brown fox jumps over the lazy dog\n" ** 1556;
    var compressed: [golden.trivialBound(plain.len)]u8 = undefined;
    const len = golden.trivialCompress(plain, &compressed);
    var medium: Buffer(16) = undefined;
    try expectStream(16, compressed[0..len], plain, &medium);
}

test "Reader: a stream above the instantiation fails WindowTooLarge" {
    // RFC 7932 §9.1 / OQ4 — the caller's buffer is the window authorization:
    // the CLI's pipe family is WBITS 24 (F9), so a `Buffer(10)` refuses it
    // before any meta-block byte, with nothing served.
    var small: Buffer(10) = undefined;
    try expectStreamError(10, golden.cli_text_q11.bytes, error.WindowTooLarge, &small);
    // The same stream decodes under a buffer that admits it.
    const big = try testing.allocator.create(DefaultBuffer);
    defer testing.allocator.destroy(big);
    try expectStream(
        default_window_wbits,
        golden.cli_text_q11.bytes,
        golden.cli_text_q11.plain,
        big,
    );
}

test "Reader: the walk decodes concatenated streams and refuses a bad tail" {
    // T4 — one stream per `Reader`, `streamAll` walks at the boundary: a
    // doubled stream decodes twice, zero bytes is the walk's clean end, and
    // a tail that cannot begin a stream is `BadStreamStart` (§9.1's 0010001
    // pattern, the reference family's large-window marker).
    const stream = golden.hand_stream.bytes;
    var small: Buffer(16) = undefined;
    var framed: Io.Writer.Allocating = .init(testing.allocator);
    defer framed.deinit();
    try framed.writer.writeAll(stream);
    try framed.writer.writeAll(stream);

    var in: Io.Reader = .fixed(framed.written());
    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    const served = try streamAll(16, &in, &plain.writer, &small);
    try testing.expectEqual(2 * golden.hand_stream.plain.len, served);
    try testing.expectEqualStrings(
        golden.hand_stream.plain ++ golden.hand_stream.plain,
        plain.written(),
    );

    // Zero bytes is the walk's clean end (zero streams).
    var empty: Io.Reader = .fixed("");
    try testing.expectEqual(@as(usize, 0), try streamAll(16, &empty, &plain.writer, &small));

    // A tail that cannot begin a stream: the walk reports ReadFailed, and a
    // `Reader` driven there holds the cause.
    var tail: Io.Writer.Allocating = .init(testing.allocator);
    defer tail.deinit();
    try tail.writer.writeAll(stream);
    try tail.writer.splatBytesAll(&[_]u8{0x11}, 3);
    var tail_in: Io.Reader = .fixed(tail.written());
    try testing.expectError(error.ReadFailed, streamAll(16, &tail_in, &plain.writer, &small));
    var tail_in2: Io.Reader = .fixed(tail.written());
    var r: Reader = .init(16, &tail_in2, &small);
    var sink: Io.Writer.Allocating = .init(testing.allocator);
    defer sink.deinit();
    // A plain `Reader` decodes the stream's own bytes and stops at its end.
    _ = try r.reader.streamRemaining(&sink.writer);
    try testing.expectEqualStrings(golden.hand_stream.plain, sink.written());
    // The next one starts at the tail, where the bytes cannot begin a stream.
    var r2: Reader = .init(16, &tail_in2, &small);
    try testing.expectError(error.ReadFailed, r2.reader.streamRemaining(&sink.writer));
    try testing.expectEqual(Error.BadStreamStart, r2.err.?);

    // The one-shot names the same wire pattern `BadWindowBits` (T3).
    var target: [64]u8 = undefined;
    try testing.expectError(error.BadWindowBits, decode.decompress(&[_]u8{0x11}, &target));
}

test "Reader: the boundary is exact, and a second stream stays unread" {
    // The README's boundary rule: a `Reader` consumes `input` exactly through
    // the stream's last byte and leaves the rest unconsumed.
    var framed: [64]u8 = undefined;
    const stream = golden.hand_stream.bytes;
    fastmem.copy(u8, framed[0..stream.len], stream);
    fastmem.set(u8, framed[stream.len..], 0xFF);
    var small: Buffer(16) = undefined;
    var in: Io.Reader = .fixed(framed[0 .. stream.len + 8]);
    var r: Reader = .init(16, &in, &small);
    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    _ = try r.reader.streamRemaining(&plain.writer);
    try testing.expectEqualStrings(golden.hand_stream.plain, plain.written());
    try testing.expectEqual(stream.len, in.seek);
    // The bytes after the stream are still the input's.
    try testing.expectEqual(@as(u8, 0xFF), (try in.peekByte()));
}

test "Reader: the machinery — polls, peeks, and the ring's room" {
    // The zero-length poll answers 0 without filling; a contiguous request
    // past the ring's room at the read position is `StreamTooLong`, never an
    // assert (std's own `rebase` asserts here).
    var small: Buffer(10) = undefined;
    var in: Io.Reader = .fixed(golden.cli_small_window.bytes);
    var r: Reader = .init(10, &in, &small);
    const peeked = try r.reader.peek(4);
    try testing.expectEqualSlices(u8, golden.cli_small_window.plain[0..4], peeked);
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectEqual(@as(usize, 0), try r.reader.stream(&sink.writer, .limited(0)));
    try testing.expect(r.err == null);
    try testing.expectError(error.ReadFailed, r.reader.peek(small.ring.len + 1));
    try testing.expectEqual(Error.StreamTooLong, r.err.?);
    try testing.expectError(error.ReadFailed, r.reader.peek(1));
}

test "Reader: a peek-driven consumer reads across the ring" {
    // A consumer that reads at its own pace instead of draining: the reader
    // fills the ring, the consumer reads half of it, and the ring wraps when
    // it is drained.
    var small: Buffer(10) = undefined;
    var in: Io.Reader = .fixed(golden.cli_small_window.bytes);
    var r: Reader = .init(10, &in, &small);
    const plain = golden.cli_small_window.plain;
    var pos: usize = 0;
    while (pos < plain.len) {
        const chunk = try r.reader.peek(@min(plain.len - pos, 512));
        try testing.expectEqualSlices(u8, plain[pos..][0..chunk.len], chunk);
        r.reader.toss(chunk.len);
        pos += chunk.len;
    }
    var sink: Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.EndOfStream, r.reader.stream(&sink.writer, .unlimited));
}

test "Reader: a one-byte-at-a-time input decodes byte-exact" {
    // Every pull path runs: the bit reader's seam mid-integer, the ladder
    // across fills, and the ring's flushes with the input arriving in
    // one-byte chunks.
    var trickle_buffer: [4]u8 = undefined;
    var small: Buffer(10) = undefined;
    var input: Trickle = .init(golden.cli_small_window.bytes, &trickle_buffer);
    var r: Reader = .init(10, &input.reader, &small);
    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    _ = try r.reader.streamRemaining(&plain.writer);
    try testing.expectEqualStrings(golden.cli_small_window.plain, plain.written());
    try testing.expectEqual(golden.cli_small_window.bytes.len, input.pos);
}

test "Reader: the ring's bytes past the output are untouched" {
    // The streaming sentinel check: the ring is pre-filled, a small stream is
    // decoded through it, and the bytes past the produced output are still
    // the sentinel — nothing writes past what the stream decoded.
    var small: Buffer(16) = undefined;
    internal.sentinel.fill(&small.ring);
    var in: Io.Reader = .fixed(golden.hand_stream.bytes);
    var r: Reader = .init(16, &in, &small);
    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    _ = try r.reader.streamRemaining(&plain.writer);
    try testing.expectEqualStrings(golden.hand_stream.plain, plain.written());
    try internal.sentinel.expect(&small.ring, golden.hand_stream.plain.len);
}

test "Reader: the layers' named refusals through the streaming path" {
    // One vector per corruption class, each verified with the pinned CLI
    // (`brotli -d -v -c`): the CLI's FORMAT_* reason is the class name.
    const buffer = try testing.allocator.create(DefaultBuffer);
    defer testing.allocator.destroy(buffer);
    const cases = [_]struct { stream: []const u8, want: Error }{
        // RFC 7932 §9.1 — 0010001 is "invalid and must not be used" (T3).
        .{ .stream = &[_]u8{0x11}, .want = error.BadStreamStart },
        // RFC 7932 §3.4 — a duplicate symbol, and a symbol past the alphabet.
        .{ .stream = golden.duplicate_symbol_streams[0], .want = error.SimpleHuffmanSame },
        .{ .stream = golden.out_of_alphabet_streams[0], .want = error.SimpleHuffmanAlphabet },
        // RFC 7932 §9.3 — all three MLEN overruns are one class (F4).
        .{ .stream = golden.mlen_insert_overrun.bytes, .want = error.BadBlockLength },
        .{ .stream = golden.mlen_copy_overrun.bytes, .want = error.BadBlockLength },
        .{ .stream = golden.dictionary_mlen_overrun.bytes, .want = error.BadBlockLength },
        // RFC 7932 §4 — a special code resolving to zero.
        .{ .stream = golden.negative_special.bytes, .want = error.BadDistance },
        // RFC 7932 §8 — a dictionary length outside 4..24, and a transform
        // id above 120.
        .{ .stream = golden.dictionary_length.bytes, .want = error.BadDictionary },
        .{ .stream = golden.dictionary_transform.bytes, .want = error.BadTransform },
        // RFC 7932 §9.2 — the metadata reserved bit, the exuberant nibble.
        .{ .stream = &[_]u8{0x3A}, .want = error.ReservedBit },
        .{ .stream = &[_]u8{ 0x2A, 0x00, 0x00, 0x00 }, .want = error.ExuberantNibble },
        // RFC 7932 §9.3 — a nonzero fill in the last byte.
        .{ .stream = &[_]u8{0x0E}, .want = error.BadPadding },
    };
    for (cases) |case| try expectStreamError(default_window_wbits, case.stream, case.want, buffer);
}

test "Reader: a stream cut short anywhere is Truncated, never a short decode" {
    // RFC 7932 §10 — "If the stream ends before the completion of the last
    // meta-block, then the stream should be rejected as invalid": every
    // strict prefix of a valid stream fails through the streaming path too.
    var small: Buffer(10) = undefined;
    const stream = golden.cli_small_window.bytes;
    for (0..stream.len) |n| {
        try expectStreamError(10, stream[0..n], error.Truncated, &small);
    }
    // The empty family's one-byte forms too: a prefix of `06` is no stream.
    // The default buffer, because a prefix can starve the header into a
    // WBITS above a smaller ring (which is `WindowTooLarge`, not `Truncated`).
    const medium = try testing.allocator.create(DefaultBuffer);
    defer testing.allocator.destroy(medium);
    for (golden.empty_streams) |empty| {
        for (0..empty.len) |n| {
            try expectStreamError(default_window_wbits, empty[0..n], error.Truncated, medium);
        }
    }
}
