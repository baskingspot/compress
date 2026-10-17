//! The driver shared by container codecs that wrap an inner codec: gzip and
//! zlib over flate. A container supplies its framing (header, trailer,
//! checksum, error sets) as a comptime type `F`; everything else lives here,
//! so this file holds no codec-specific state.
//!
//! Entry points: `ReaderHooks(F, Host)` and `WriterHooks(F, Host)` for
//! streaming, `EncodeHooks(F)` and `DecodeHooks(F, Host)` for the one-shot
//! functions, and `readExact`. The container's `Reader` and `Writer` are the
//! `Host` types: they declare the fields listed at the end of this header and
//! delegate their `init`, `finish`, and one-call pumps to the hooks.
//!
//! `F` must declare the members below. The hooks reference every function and
//! constant, so a missing or misspelled member is a compile error where the
//! container instantiates them. The type-only members (`Level`, `Header`,
//! `HeaderError`, `InnerReader`, `InnerWriter`) are not named by the driver;
//! they are checked where their values flow: a `HeaderError` must coerce into
//! `Error`, and an `initReader` result must fit the `inner` field.
//!
//! - `Options`: the public encoder knobs. `Options.level` is a numeric level;
//!   `levelImplemented(level)` says which levels the inner codec implements
//!   (the rest are not implemented).
//! - `Error`: the streaming reader's detail errors: the inner codec's reader
//!   errors, `EndOfStream`, and the framing's own.
//! - `DecompressError`: the one-shot decoder's errors: `Error` minus
//!   `StreamTooLong`, `ReadFailed`, and `EndOfStream`, plus `BufferTooSmall`.
//! - `HeaderError`, `TrailerError`: the header's and trailer's own failures,
//!   plus `Truncated` and `ReadFailed` for the input route.
//! - `Checksum`: the checksum state. `.{}` is its initial value, `hook()`
//!   returns the inner codec's checksum hook over it, and `fold(bytes)` folds
//!   a whole buffer for the one-shot path.
//! - `Header`: the header parse state; the reader carries one.
//! - `ReaderBuffer`, `WriterBuffer`: the caller-owned buffers, re-exported
//!   from the inner codec.
//! - `InnerReader`, `InnerWriter`: the inner codec's streaming types. The
//!   driver uses `inner.reader` (the embedded `Io.Reader`), `inner.writer`,
//!   `inner.err`, and `inner.checksum`.
//! - `initWriter(output, buffer, options)`: the inner codec's streaming
//!   writer constructor. It owns the block region's placement inside `buffer`
//!   (a preset dictionary starts it after the dictionary), and the driver
//!   takes the interface's serving region from `inner.writer.buffer`.
//! - `initReader(input, buffer, dict)`, `readHeader(header, input, dict)`:
//!   the inner codec's streaming constructor and the header parse. `dict` is
//!   the container's preset dictionary or null; a framing without a
//!   dictionary concept (gzip) ignores it. `readHeader` runs only while
//!   `headerDone` is false and consumes at least one byte per call.
//! - `checkTrailer(trailer, checksum)`: the trailer verification.
//! - `header_len`, `dict_id_len`, `trailer_len`: the fixed header's length,
//!   the preset dictionary's identifier field (0 for a framing with no
//!   dictionary concept), and the trailer's length.
//! - `writeHeader(target, options)`, `writeTrailer(target, checksum)`: write
//!   the deterministic header for `options` (returning its length, at most
//!   `header_len + dict_id_len` bytes) and the trailer bytes.
//! - `bodyCompress(source, target, options)`,
//!   `bodyMaxCompressedLength(input_len)`: the inner codec's one-shot
//!   compress and its length bound.
//!
//! Fields the driver names on `Host`. Reader: `reader`, `inner`, `input`,
//! `header`, `checksum`, `state`, `err`, `dict` (the container's preset
//! dictionary or null; a framing without a dictionary concept declares it and
//! leaves it null). Writer: `writer`, `output`, `inner`, `options`, `checksum`,
//! `header`.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const lifecycle = @import("reader.zig");

/// Whether a container writer has written its header. The header is written
/// lazily, by the first entry that can emit a byte: a write that drains, a
/// flush, a rebase, or `finish`. A container's `Writer` keeps one in its
/// `header` field (the reader's header parse state is `F.Header`).
pub const Header = enum { pending, written };

/// The framing's largest header: its fixed part plus the preset dictionary's
/// identifier field (`dict_id_len` is 0 for a framing with no dictionary
/// concept). The driver sizes its header buffer and its one-shot bound from
/// this.
fn maxHeaderLen(comptime F: type) usize {
    return F.header_len + F.dict_id_len;
}

/// Reads exactly `target.len` bytes from `input` into `target`, consuming
/// them. Works with an input that delivers one byte per refill. Returns
/// `error.Truncated` if the input ends first and `error.ReadFailed` if the
/// input itself fails.
pub fn readExact(input: *Io.Reader, target: []u8) error{ Truncated, ReadFailed }!void {
    for (target) |*byte| {
        input.fill(1) catch |err| switch (err) {
            error.EndOfStream => return error.Truncated,
            error.ReadFailed => return error.ReadFailed,
        };
        byte.* = input.buffer[input.seek];
        input.toss(1);
    }
}

/// The streaming reader machinery for a container reader `Host`. `init`
/// builds a `Host` over an input; `streamOne` decodes one whole container. The
/// `Io.Reader` vtable entries are private to the driver. Each fill reads the
/// header once, then decodes through the inner codec's window, then reads and
/// verifies the trailer when the body ends cleanly. The container's own `init`
/// and one-call pump delegate here.
pub fn ReaderHooks(comptime F: type, comptime Host: type) type {
    return struct {
        const Self = @This();

        const vtable: Io.Reader.VTable = lifecycle.VTable(Host, pump, rebase).vtable;

        /// Returns a `Host` that decodes one container from `input`, with
        /// `buffer` as the decoded window. `dict` is the container's preset
        /// dictionary or `null`; a framing without a dictionary concept
        /// ignores it. `buffer` must outlive the `Host`.
        pub fn init(input: *Io.Reader, buffer: *F.ReaderBuffer, dict: ?[]const u8) Host {
            var host: Host = .{
                .reader = .{ .buffer = buffer, .seek = 0, .end = 0, .vtable = &vtable },
                .inner = F.initReader(input, buffer, dict),
                .input = input,
                .dict = dict,
            };
            // A framing that pre-seeds the window (a preset dictionary) starts
            // the interface's positions where the inner reader's are: one
            // window, one position, so the first fill does not overwrite the
            // pre-seeded bytes.
            host.reader.seek = host.inner.reader.seek;
            host.reader.end = host.inner.reader.end;
            return host;
        }

        /// The fill the generated entries call. Failures go through `record`,
        /// so the interface sees `error.ReadFailed` with the detail kept in
        /// `err`, or the clean `error.EndOfStream` once the trailer is
        /// verified.
        fn pump(r: *Host) Io.Reader.Error!usize {
            return record(r, fill(r));
        }

        /// The one place a detailed failure becomes the interface's coarse
        /// error: the clean end passes through, anything else goes to `fail`.
        fn record(r: *Host, result: F.Error!usize) Io.Reader.Error!usize {
            return result catch |err| switch (err) {
                error.EndOfStream => return error.EndOfStream,
                else => return fail(r, err),
            };
        }

        /// Records `err` as the sticky failure detail and returns the
        /// interface's coarse `error.ReadFailed`.
        fn fail(r: *Host, err: F.Error) Io.Reader.Error {
            return lifecycle.fail(F.Error, &r.state, &r.err, err);
        }

        /// One fill: the header parse (once), then the inner codec's window,
        /// then the trailer at the body's clean end.
        fn fill(r: *Host) F.Error!usize {
            if (!F.headerDone(&r.header)) {
                try F.readHeader(&r.header, r.input, r.dict);
                // The checksum hook is armed before the first body byte is
                // decoded: every decoded byte folds into the container's
                // checksum exactly once, in stream order.
                r.inner.checksum = r.checksum.hook();
            }
            // The window is the inner codec's: hand it the consumer's
            // position, fill, and take the (possibly slid) position back.
            // One region, one position, no staging copy.
            r.inner.reader.seek = r.reader.seek;
            r.inner.reader.end = r.reader.end;
            r.inner.reader.fillMore() catch |err| switch (err) {
                // The inner codec's clean end: the body is complete, and its
                // bit reader consumed the input exactly through the last
                // byte, so the trailer is next. A trailer error propagates to
                // `record`, which stores the specific error as the failure
                // detail.
                error.EndOfStream => {
                    try readTrailer(r);
                    return error.EndOfStream;
                },
                // `record` stores the detail, once.
                error.ReadFailed => return r.inner.err.?,
            };
            r.reader.seek = r.inner.reader.seek;
            r.reader.end = r.inner.reader.end;
            assert(r.reader.end > r.reader.seek);
            return r.reader.end - r.reader.seek;
        }

        /// Reads and verifies the trailer after the body's clean end, once,
        /// then sets the state to `done`. A mismatch is the framing's own
        /// error and a short trailer is `error.Truncated`. It does not return
        /// `error.EndOfStream`; each caller reports the clean end itself.
        fn readTrailer(r: *Host) F.TrailerError!void {
            var trailer: [F.trailer_len]u8 = undefined;
            try readExact(r.input, &trailer);
            try F.checkTrailer(&trailer, &r.checksum);
            r.state = .done;
        }

        /// The rebase hook for the generated entries: makes room for
        /// `capacity` more contiguous bytes by sliding the inner codec's
        /// window, with the consumer's position synced in. A request the
        /// window cannot hold at that position returns `error.ReadFailed` with
        /// `err == .StreamTooLong`; it never asserts.
        ///
        /// When the inner codec reports its clean end during the slide, that
        /// end is the body's end, so the trailer check runs before the clean
        /// end is reported: the same ending `fill` runs. Passing the inner end
        /// straight through would end the stream cleanly with the trailer
        /// unread and the state still `streaming`. The input stands exactly at
        /// the trailer's first byte, so the check consumes through the
        /// container's last byte.
        fn rebase(r: *Host, capacity: usize) Io.Reader.RebaseError!void {
            r.inner.reader.seek = r.reader.seek;
            r.inner.reader.end = r.reader.end;
            r.inner.reader.rebase(capacity) catch |err| switch (err) {
                error.EndOfStream => {
                    readTrailer(r) catch |trailer_err| return fail(r, trailer_err);
                    return error.EndOfStream;
                },
                error.ReadFailed => return fail(r, r.inner.err.?),
            };
            r.reader.seek = r.inner.reader.seek;
            r.reader.end = r.inner.reader.end;
            assert(r.reader.buffer.len - r.reader.seek >= capacity);
        }

        /// Decodes one complete container from `in` into `out` and returns the
        /// number of decoded bytes written. Consumes `in` through the
        /// container's last trailer byte; later bytes are left unconsumed. A
        /// malformed container or a failing `in` returns `error.ReadFailed`
        /// (the detail is not reported); a failing `out` returns
        /// `error.WriteFailed`. The window is a stack local of
        /// `@sizeOf(F.ReaderBuffer)` bytes; nothing is allocated.
        pub fn streamOne(
            in: *Io.Reader,
            out: *Io.Writer,
            dict: ?[]const u8,
        ) Io.Reader.StreamRemainingError!usize {
            var buffer: F.ReaderBuffer = undefined;
            var rr: Host = init(in, &buffer, dict);
            return rr.reader.streamRemaining(out);
        }
    };
}

/// The streaming writer machinery for a container writer `Host`. `init`
/// builds a `Host` over an output, `finish` completes the container, and
/// `streamOne` encodes a whole input. The `Io.Writer` vtable entries are
/// private to the driver: they write the header before the first compressed
/// byte, set the checksum hook, and hand the data to the inner codec's writer,
/// which shares the interface's buffer. The container's own `init`, `finish`,
/// and one-call pump delegate here.
pub fn WriterHooks(comptime F: type, comptime Host: type) type {
    return struct {
        const Self = @This();

        const vtable: Io.Writer.VTable = .{
            .drain = drain,
            .flush = flush,
            .rebase = rebase,
        };

        /// Returns a `Host` that writes one container to `output`, with
        /// `buffer` as the compression window and `options` fixed for the
        /// writer's lifetime. An unimplemented level returns a poisoned
        /// writer whose every write and `finish` returns `error.WriteFailed`,
        /// matching `streamOne`, which rejects it before reading.
        pub fn init(output: *Io.Writer, buffer: *F.WriterBuffer, options: F.Options) Host {
            var host: Host = .{
                .writer = .failing,
                .output = output,
                .inner = F.initWriter(output, buffer, options),
                .options = options,
            };
            // The interface's serving region is the inner codec's block
            // region: the same bytes, which the generated entries hand out and
            // the encoder fills. A framing with a preset dictionary starts
            // that region after the dictionary (the inner writer knows where),
            // so it is taken from there, never recomputed here.
            if (F.levelImplemented(options.level)) {
                host.writer = .{
                    .buffer = host.inner.writer.buffer,
                    .end = 0,
                    .vtable = &vtable,
                };
            }
            return host;
        }

        /// Completes the container: writes the header if it is still pending,
        /// finishes the inner codec's stream, writes the trailer from the
        /// accumulated checksum, and flushes `output`. Terminal: the writer is
        /// poisoned afterwards, so later writes and `finish` calls return
        /// `error.WriteFailed`. A writer that already failed or finished
        /// returns `error.WriteFailed` here too, never a false success.
        pub fn finish(w: *Host) Io.Writer.Error!void {
            if (w.writer.vtable != &vtable) return error.WriteFailed;
            defer w.writer = .failing;
            try emitHeader(w);
            arm(w);
            commit(w);
            try w.inner.finish();
            var trailer: [F.trailer_len]u8 = undefined;
            F.writeTrailer(&trailer, &w.checksum);
            try w.output.writeAll(&trailer);
            try w.output.flush();
        }

        /// Writes the container's header to `output` unless it is already
        /// written. Every entry that can emit a byte calls it first, so the
        /// header precedes any compressed byte.
        fn emitHeader(w: *Host) Io.Writer.Error!void {
            if (w.header == .written) return;
            var header: [maxHeaderLen(F)]u8 = undefined;
            const n = F.writeHeader(&header, w.options);
            try w.output.writeAll(header[0..n]);
            w.header = .written;
        }

        /// Sets the inner codec's checksum hook if it is not set yet. It must
        /// be set before the first byte is emitted: a hook set mid-stream
        /// would see only later blocks. The hook points at this writer's
        /// checksum state, whose address is stable only once the caller has
        /// placed the writer, so it is set at the first entry, not in `init`
        /// (which returns the `Host` by value).
        fn arm(w: *Host) void {
            if (w.inner.checksum == null) w.inner.checksum = w.checksum.hook();
        }

        /// Copies the interface's `end` to the inner codec's writer. The two
        /// share one buffer region, and `std.Io.Writer`'s fast paths advance
        /// only the interface's `end`, so the inner writer must be told before
        /// it runs.
        fn commit(w: *Host) void {
            assert(w.writer.buffer.ptr == w.inner.writer.buffer.ptr);
            assert(w.writer.buffer.len == w.inner.writer.buffer.len);
            w.inner.writer.end = w.writer.end;
        }

        /// Copies the inner codec's buffer and `end` back to the interface
        /// after the inner codec ran, which may have emitted and slid the
        /// buffered bytes.
        fn adopt(w: *Host) void {
            w.writer.buffer = w.inner.writer.buffer;
            w.writer.end = w.inner.writer.end;
        }

        /// Called when `data` does not fit in the block region. Writes the
        /// header if it is pending, then lets the inner codec's `drain`
        /// consume from `data`: it tops up the block, emits it, and slides the
        /// window. Returns the bytes consumed from `data`, not counting the
        /// already buffered ones (the `std.Io.Writer.VTable.drain` contract).
        fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
            errdefer w.* = .failing;
            const self: *Host = @alignCast(@fieldParentPtr("writer", w));
            try emitHeader(self);
            arm(self);
            commit(self);
            const consumed = try self.inner.writer.writeSplat(data, splat);
            adopt(self);
            return consumed;
        }

        /// Emits the buffered partial block and flushes `output`. The writer
        /// stays usable: no data block carries BFINAL, so a mid-stream flush
        /// is always safe (RFC 1951 §3.2.3). The trailer is written only by
        /// `finish`.
        fn flush(w: *Io.Writer) Io.Writer.Error!void {
            errdefer w.* = .failing;
            const self: *Host = @alignCast(@fieldParentPtr("writer", w));
            try emitHeader(self);
            arm(self);
            commit(self);
            try self.inner.writer.flush();
            adopt(self);
        }

        /// Makes room for `capacity` more bytes in the region, keeping the
        /// most recent `preserve` buffered. The inner codec's `rebase` emits
        /// the front of the partly written block and slides the preserved tail
        /// to the front; it never discards input. A consumer that asks for a
        /// direct writable slice (`writableSliceGreedy`) on a full region
        /// lands here.
        fn rebase(w: *Io.Writer, preserve: usize, capacity: usize) Io.Writer.Error!void {
            errdefer w.* = .failing;
            const self: *Host = @alignCast(@fieldParentPtr("writer", w));
            try emitHeader(self);
            arm(self);
            commit(self);
            try self.inner.writer.rebase(preserve, capacity);
            adopt(self);
        }

        /// Reads `in` to its end, writes it to `out` as one complete container
        /// (the stream ending and the trailer included), and returns the
        /// number of input bytes consumed. An unimplemented level returns
        /// `error.ReadFailed` before any input is read; a failing `in` returns
        /// `error.ReadFailed` and a failing `out` returns `error.WriteFailed`.
        /// The window is a stack local of `@sizeOf(F.WriterBuffer)` bytes;
        /// nothing is allocated.
        pub fn streamOne(
            in: *Io.Reader,
            out: *Io.Writer,
            options: F.Options,
        ) Io.Reader.StreamRemainingError!usize {
            if (!F.levelImplemented(options.level)) return error.ReadFailed;
            var buffer: F.WriterBuffer = undefined;
            var ww: Host = init(out, &buffer, options);
            const n = try in.streamRemaining(&ww.writer);
            try finish(&ww);
            return n;
        }
    };
}

/// The one-shot encoder for a container `F`: `maxCompressedLength` and
/// `compress`. `compress` writes the header, the inner codec's body, and a
/// trailer computed by folding the checksum directly over `source`. No heap
/// allocation.
pub fn EncodeHooks(comptime F: type) type {
    return struct {
        /// The worst-case container length for `input_len` source bytes: the
        /// largest header, the inner codec's worst-case body, and the fixed
        /// trailer.
        pub fn maxCompressedLength(input_len: usize) usize {
            return maxHeaderLen(F) + F.bodyMaxCompressedLength(input_len) + F.trailer_len;
        }

        /// Compresses `source` into `target` as one complete container and
        /// returns its length. Returns `error.BufferTooSmall` when `target`
        /// cannot hold the result: `maxCompressedLength(source.len)` is always
        /// enough, a smaller target may still fit when the body compresses
        /// under the bound, and `target`'s contents are unspecified after a
        /// failure. Returns `error.Unimplemented` for an unimplemented level.
        pub fn compress(
            source: []const u8,
            target: []u8,
            options: F.Options,
        ) error{ BufferTooSmall, Unimplemented }!usize {
            if (!F.levelImplemented(options.level)) return error.Unimplemented;
            // The header is written before the body is attempted, so the
            // check must come first: a target that cannot hold even the
            // framing is too small.
            if (target.len < maxHeaderLen(F) + F.trailer_len) return error.BufferTooSmall;
            const header_len = F.writeHeader(target[0..maxHeaderLen(F)], options);

            const body_len = try F.bodyCompress(source, target[header_len..], options);
            const trailer_at = header_len + body_len;
            // A body that compressed under the bound can still leave no room
            // for the trailer: report that before the overflowing write,
            // never after.
            if (target.len - trailer_at < F.trailer_len) return error.BufferTooSmall;
            var checksum: F.Checksum = .{};
            checksum.fold(source);
            F.writeTrailer(target[trailer_at..][0..F.trailer_len], &checksum);
            return trailer_at + F.trailer_len;
        }
    };
}

/// The one-shot decoder for a container reader `Host`. `decompress` runs the
/// whole container through the streaming reader over
/// `Io.Reader.fixed(source)` and maps the interface's coarse errors back to
/// the framing's detail set. No heap allocation: the reader's window is a
/// stack local. The `Host` is built through `ReaderHooks`'s own `init`, so a
/// container's public `init` (with its own parameter list) need not match the
/// driver's.
pub fn DecodeHooks(comptime F: type, comptime Host: type) type {
    const hooks = ReaderHooks(F, Host);

    return struct {
        /// Decodes one complete container from `source` into `target` and
        /// returns the decoded length. `target` is a cap, not an exact size.
        /// `dict` is the container's preset dictionary or `null`; a framing
        /// without a dictionary concept ignores it. The trailer is verified
        /// against the bytes the decode produced. Bytes after the trailer are
        /// ignored: the call does not report how much of `source` it consumed,
        /// so a caller that needs the container boundary uses the streaming
        /// reader. Returns `error.BufferTooSmall` before writing past
        /// `target`; a corrupt or truncated container returns the framing's
        /// own error.
        pub fn decompress(
            source: []const u8,
            target: []u8,
            dict: ?[]const u8,
        ) F.DecompressError!usize {
            var input: Io.Reader = .fixed(source);
            var output: Io.Writer = .fixed(target);
            var buffer: F.ReaderBuffer = undefined;
            var reader: Host = hooks.init(&input, &buffer, dict);
            _ = reader.reader.streamRemaining(&output) catch |err| switch (err) {
                // The output cap: `Io.Writer.fixed` reports `WriteFailed`
                // before writing past `target`, and the one-shot's name for
                // that is `BufferTooSmall`.
                error.WriteFailed => return error.BufferTooSmall,
                // The detail recorded beside the interface's coarse
                // `ReadFailed`.
                error.ReadFailed => return detail(&reader),
            };
            return output.end;
        }

        /// The detail recorded in `err` for a streaming failure. Three entries
        /// cannot occur on this path, so they are unreachable here:
        /// `StreamTooLong` (the one-shot consumer never asks for contiguous
        /// bytes), `ReadFailed` (the input is a fixed slice), and
        /// `EndOfStream` (`streamRemaining` consumes the clean end itself).
        fn detail(reader: *const Host) F.DecompressError {
            const recorded = reader.err.?;
            return switch (recorded) {
                error.StreamTooLong, error.ReadFailed, error.EndOfStream => unreachable,
                else => |err| err,
            };
        }
    };
}
