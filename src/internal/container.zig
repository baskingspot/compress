//! The container driver: the framing-agnostic machinery a container codec
//! over an inner codec shares (README.md, "The Io codec pattern book"). gzip
//! and zlib over flate are the two instantiations; a second container family
//! (a frame over a raw stream) rides the same driver.
//!
//! The framing arrives as a comptime `Framing` type the container spells
//! out, so this file imports only `std` and holds no codec-specific state:
//! the header, the trailer, the checksum, and the error sets stay in the
//! codec's own directory. What lives here, once, is everything that is not
//! framing: the inner-window position sync (`commit`/`adopt`, the fill
//! hand-off), the lazy header emission, the trailer read at the body's clean
//! end, the checksum hook arming, the lifecycle funnel, the poison check,
//! the stack-buffered one-call pumps, and the one-shot compress/decompress
//! drivers. The pattern book's "A wrapper's rebase routes the inner end
//! through the same ending as fill" entry is `ReaderHooks.rebase` below.
//!
//! The `Framing` contract, in full. Every function and constant is
//! referenced from here, so a missing or misspelled member fails the
//! container's instantiation, not a runtime call. The type-only members
//! (`Level`, `Header`, `HeaderError`, `InnerReader`, `InnerWriter`) are
//! structural: the driver names their values, not their types, so they are
//! checked where the value flows (a `HeaderError` must coerce into
//! `Error`, an `initReader` result into the `inner` field):
//!
//! - `Level`, `Options` — the public encoder knobs (`Options.level` is a
//!   `Level`, and `Level` has a `.ratio` seat).
//! - `Error` — the streaming reader's detail set; it contains the inner
//!   codec's reader error set, `EndOfStream`, and the framing's own entries.
//! - `DecompressError` — the one-shot decoder's detail set; it contains
//!   `Error`'s non-interface entries and `BufferTooSmall`.
//! - `HeaderError` — the header's own failures, plus `Truncated` and
//!   `ReadFailed` for the input route.
//! - `TrailerError` — the trailer's own failures, plus `Truncated` and
//!   `ReadFailed` for the input route.
//! - `Checksum` — the container's checksum state, with `.{}` its initial
//!   value, `hook()` the flate checksum hook over it, and `fold(bytes)` the
//!   direct one-shot fold.
//! - `Header` — the header parse state; the reader carries one.
//! - `ReaderBuffer`, `WriterBuffer` — the caller-owned buffers the container
//!   re-exports from the inner codec.
//! - `InnerReader`, `InnerWriter` — the inner codec's streaming types; the
//!   driver reads `inner.reader` (the embedded `Io.Reader`), `inner.writer`,
//!   `inner.err`, and `inner.checksum`.
//! - `header_len`, `trailer_len`, `writer_region_len` — the framing lengths
//!   and the writer's serving region (`max_block_size`).
//! - `initReader(input, buffer)`, `initWriter(output, buffer, options)` —
//!   the inner codec's streaming constructors.
//! - `headerDone(header)`, `readHeader(header, input)` — the header parse:
//!   `readHeader` runs only while `headerDone` is false and consumes at
//!   least one byte per call.
//! - `checkTrailer(trailer, checksum)` — the trailer verification.
//! - `writeHeader(target, level)`, `writeTrailer(target, checksum)` — the
//!   deterministic emissions.
//! - `bodyCompress(source, target, options)`,
//!   `bodyMaxCompressedLength(input_len)` — the inner codec's one-shot
//!   body.
//!
//! The `Host` type each hooks namespace is instantiated over carries the
//! fields the driver names: the reader has `reader`, `inner`, `input`,
//! `header`, `checksum`, `state`, `err`; the writer has `writer`, `output`,
//! `inner`, `options`, `checksum`, `header`. The container declares them —
//! they are its public state — and delegates its `init`/`finish`/pumps here.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const lifecycle = @import("reader.zig");

/// Whether the container's fixed header has reached the output: the header
/// is lazy, so the first entry that can emit a byte — a write that drains, a
/// flush, a rebase, or `finish` — writes it first. Both containers' writers
/// carry this field.
pub const Header = enum { pending, written };

/// Read exactly `target.len` bytes from `input`, consuming them: the header
/// and trailer route, one refill at a time (the input's buffer may deliver
/// one byte). A short input is `Truncated`; the input's own failure is
/// `ReadFailed`.
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

/// The streaming reader machinery for a container reader `Host`: `init`, the
/// generated `Io.Reader` vtable entries, the fill funnel (the header once,
/// then the inner codec's window, then the trailer at the body's clean end),
/// and the stack-buffered one-call pump. The container's public `init`
/// delegates here; the vtable entries are private to the driver.
pub fn ReaderHooks(comptime F: type, comptime Host: type) type {
    return struct {
        const Self = @This();

        const vtable: Io.Reader.VTable = lifecycle.VTable(Host, pump, rebase).vtable;

        pub fn init(input: *Io.Reader, buffer: *F.ReaderBuffer) Host {
            return .{
                .reader = .{ .buffer = buffer, .seek = 0, .end = 0, .vtable = &vtable },
                .inner = F.initReader(input, buffer),
                .input = input,
            };
        }

        /// The generated entries' fill: the detailed errors through `record`
        /// (the pattern book's funnel), so the interface sees
        /// `error.ReadFailed` with the detail sticky in `err`, or the clean
        /// `error.EndOfStream` once the trailer is verified.
        fn pump(r: *Host) Io.Reader.Error!usize {
            return record(r, fill(r));
        }

        /// The one place a detailed failure becomes the interface's coarse
        /// error.
        fn record(r: *Host, result: F.Error!usize) Io.Reader.Error!usize {
            return result catch |err| switch (err) {
                error.EndOfStream => return error.EndOfStream,
                else => return fail(r, err),
            };
        }

        /// Fail closed, stickily: the detail is recorded beside the state and
        /// the interface's coarse `error.ReadFailed` is returned.
        fn fail(r: *Host, err: F.Error) Io.Reader.Error {
            return lifecycle.fail(F.Error, &r.state, &r.err, err);
        }

        /// One fill: the header parse (once), then the inner codec's window,
        /// then the trailer at the body's clean end.
        fn fill(r: *Host) F.Error!usize {
            if (!F.headerDone(&r.header)) {
                try F.readHeader(&r.header, r.input);
                // The checksum hook is armed before the first body byte is
                // decoded: every decoded byte folds into the container's
                // checksum exactly once, in stream order.
                r.inner.checksum = r.checksum.hook();
            }
            // The window is the inner codec's: hand it the consumer's
            // position, fill, and take the (possibly slid) position back —
            // one region, one position, no staging copy.
            r.inner.reader.seek = r.reader.seek;
            r.inner.reader.end = r.reader.end;
            r.inner.reader.fillMore() catch |err| switch (err) {
                // The inner codec's clean end: the body is complete, and its
                // bit reader consumed the input exactly through the last
                // byte — the trailer is next (the exact-consumption
                // contract). `record` owns the failing: the specific trailer
                // error propagates to it, so the detail lands beside the
                // state, not the coarse error over it.
                error.EndOfStream => {
                    try readTrailer(r);
                    return error.EndOfStream;
                },
                // The detail is recorded by `record`'s funnel, once.
                error.ReadFailed => return r.inner.err.?,
            };
            r.reader.seek = r.inner.reader.seek;
            r.reader.end = r.inner.reader.end;
            assert(r.reader.end > r.reader.seek);
            return r.reader.end - r.reader.seek;
        }

        /// Read and verify the trailer at the body's clean end, exactly once,
        /// then the reader is `done` (sticky); a mismatch is the framing's
        /// specific error, a short trailer `Truncated`.
        fn readTrailer(r: *Host) F.TrailerError!void {
            var trailer: [F.trailer_len]u8 = undefined;
            try readExact(r.input, &trailer);
            try F.checkTrailer(&trailer, &r.checksum);
            r.state = .done;
        }

        /// The generated entries' rebase hook: make room for `capacity` more
        /// contiguous bytes by sliding the inner codec's window, with the
        /// consumer's position synced in. A request the window cannot hold at
        /// the consumer's position fails closed with `error.ReadFailed`
        /// (`err == .StreamTooLong`), never an assert (the pattern book's
        /// contiguity rule).
        ///
        /// The pattern book's wrapper-rebase rule lives here, once: the inner
        /// codec's sticky end is the body's clean end, so the trailer check
        /// runs before the clean end is reported — the same ending `fill`
        /// runs. The input stands exactly at the trailer's first byte (the
        /// exact-consumption contract), so the check consumes exactly through
        /// the container's last byte. A `readTrailer` that only ends the
        /// stream is `TrailerError!void` in truth: no trailing
        /// `return error.EndOfStream`, and both call sites report the clean
        /// end themselves.
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

        /// Stream one complete container from `in` through a stack-buffered
        /// `Host` into `out`, returning the decoded bytes served. Consumes
        /// `in` exactly through the container's last trailer byte; bytes
        /// after it are left unconsumed. Zero allocation: the window is a
        /// stack local.
        pub fn streamOne(in: *Io.Reader, out: *Io.Writer) Io.Reader.StreamRemainingError!usize {
            var buffer: F.ReaderBuffer = undefined;
            var rr: Host = init(in, &buffer);
            return rr.reader.streamRemaining(out);
        }
    };
}

/// The streaming writer machinery for a container writer `Host`: `init` (the
/// `.ratio` poison seat included), the `Io.Writer` vtable entries, the
/// position sync between the interface's serving region and the inner
/// codec's block region, the lazy header emission, the checksum hook arming,
/// `finish`, and the stack-buffered one-call pump.
pub fn WriterHooks(comptime F: type, comptime Host: type) type {
    return struct {
        const Self = @This();

        const vtable: Io.Writer.VTable = .{
            .drain = drain,
            .flush = flush,
            .rebase = rebase,
        };

        /// Wrap `output` with `buffer` as the compression window and
        /// `options` fixed for the container's lifetime. A `.ratio` level
        /// poisons the interface (every write and `finish` reports
        /// `error.WriteFailed`), matching `streamOne`'s upfront rejection —
        /// the inner codec's reserved seat, never silent aliasing.
        pub fn init(output: *Io.Writer, buffer: *F.WriterBuffer, options: F.Options) Host {
            if (options.level == .ratio) {
                return .{
                    .writer = .failing,
                    .output = output,
                    .inner = F.initWriter(output, buffer, options),
                    .options = options,
                };
            }
            return .{
                .writer = .{
                    .buffer = buffer[0..F.writer_region_len],
                    .end = 0,
                    .vtable = &vtable,
                },
                .output = output,
                .inner = F.initWriter(output, buffer, options),
                .options = options,
            };
        }

        /// Complete the container: emit the header if it is still pending,
        /// complete the deflate stream through the inner codec, write the
        /// trailer from the checksum state the hook accumulated, and flush
        /// `output`. Terminal: the writer is poisoned afterwards, and a
        /// failed or finished writer reports `error.WriteFailed` instead of a
        /// false success (the pattern book's poison check).
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

        /// The lazily written header: the first entry that can emit writes
        /// the container's deterministic header before any compressed byte
        /// reaches `output`.
        fn emitHeader(w: *Host) Io.Writer.Error!void {
            if (w.header == .written) return;
            var header: [F.header_len]u8 = undefined;
            F.writeHeader(&header, w.options.level);
            try w.output.writeAll(&header);
            w.header = .written;
        }

        /// Arm the checksum hook before the first byte is emitted: a hook set
        /// mid-stream would see only later blocks. The state's address is
        /// stable once the caller's writer is placed, so arming happens at
        /// the first entry, not in `init` (which cannot take its own
        /// address).
        fn arm(w: *Host) void {
            if (w.inner.checksum == null) w.inner.checksum = w.checksum.hook();
        }

        /// Hand the front's buffer position to the codec: the two share one
        /// region, and `std.Io.Writer`'s fast paths move only the front's
        /// `end`.
        fn commit(w: *Host) void {
            assert(w.writer.buffer.ptr == w.inner.writer.buffer.ptr);
            assert(w.writer.buffer.len == w.inner.writer.buffer.len);
            w.inner.writer.end = w.writer.end;
        }

        /// Take the codec's (possibly rebased) region back as the front's.
        fn adopt(w: *Host) void {
            w.writer.buffer = w.inner.writer.buffer;
            w.writer.end = w.inner.writer.end;
        }

        /// The block region is full: emit the header if pending and let the
        /// inner codec's `drain` consume from `data` (it tops up the block,
        /// emits it, and slides the window). The returned count is the bytes
        /// consumed from `data`, excluding the buffered ones
        /// (`std/Io/Writer.zig`'s drain contract).
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

        /// Emit the buffered partial block and flush `output`, keeping the
        /// writer usable: no data block carries BFINAL, so a mid-stream flush
        /// is always safe (`rfc1951-deflate.txt §3.2.3`). The trailer is
        /// never written before `finish`.
        fn flush(w: *Io.Writer) Io.Writer.Error!void {
            errdefer w.* = .failing;
            const self: *Host = @alignCast(@fieldParentPtr("writer", w));
            try emitHeader(self);
            arm(self);
            commit(self);
            try self.inner.writer.flush();
            adopt(self);
        }

        /// Make room for `capacity` more bytes in the region, keeping the
        /// most recent `preserve` buffered: the inner codec's `rebase` emits
        /// the front of the partly written block and slides the tail to the
        /// front, never discarding input (the pattern book's rebase rule). A
        /// consumer can ask for a direct writable slice into the region via
        /// `writableSliceGreedy`; when the region is full, that call lands
        /// here.
        fn rebase(w: *Io.Writer, preserve: usize, capacity: usize) Io.Writer.Error!void {
            errdefer w.* = .failing;
            const self: *Host = @alignCast(@fieldParentPtr("writer", w));
            try emitHeader(self);
            arm(self);
            commit(self);
            try self.inner.writer.rebase(preserve, capacity);
            adopt(self);
        }

        /// Stream everything from `in` through a stack-buffered `Host` into
        /// `out`, returning the bytes consumed and encoded. Consumes `in`
        /// exactly through its end, then finishes the container (the deflate
        /// ending and the trailer are load-bearing). `.ratio` lands as
        /// `error.ReadFailed` upfront. Zero allocation.
        pub fn streamOne(
            in: *Io.Reader,
            out: *Io.Writer,
            options: F.Options,
        ) Io.Reader.StreamRemainingError!usize {
            if (options.level == .ratio) return error.ReadFailed;
            var buffer: F.WriterBuffer = undefined;
            var ww: Host = init(out, &buffer, options);
            const n = try in.streamRemaining(&ww.writer);
            try finish(&ww);
            return n;
        }
    };
}

/// The one-shot encoder driver for a container `Framing`: the worst-case
/// bound and `compress` — the framing header, the inner codec's body, the
/// trailer from a direct fold over `source`. Zero heap allocation.
pub fn EncodeHooks(comptime F: type) type {
    return struct {
        /// The worst-case container length: the fixed header, the inner
        /// codec's worst-case body, and the fixed trailer.
        pub fn maxCompressedLength(input_len: usize) usize {
            return F.header_len + F.bodyMaxCompressedLength(input_len) + F.trailer_len;
        }

        /// Compress `source` as one complete container into `target` and
        /// return its length. `error.BufferTooSmall` when `target` cannot
        /// hold it (size `target` with `maxCompressedLength`; a smaller
        /// target may still fit when the body compresses under the bound,
        /// and its contents are unspecified on failure).
        /// `error.Unimplemented` for the reserved `.ratio` level.
        pub fn compress(
            source: []const u8,
            target: []u8,
            options: F.Options,
        ) error{ BufferTooSmall, Unimplemented }!usize {
            if (options.level == .ratio) return error.Unimplemented;
            // The header is written before the body is attempted, so the
            // check must come first: a target that cannot hold even the
            // framing is too small.
            if (target.len < F.header_len + F.trailer_len) return error.BufferTooSmall;
            F.writeHeader(target[0..F.header_len], options.level);

            const body_len = try F.bodyCompress(source, target[F.header_len..], options);
            const trailer_at = F.header_len + body_len;
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

/// The one-shot decoder driver for a container reader `Host`: `decompress`
/// routes the whole container through the streaming reader over
/// `Io.Reader.fixed(source)` and maps the interface's coarse errors back to
/// the framing's detail set. Zero heap allocation: the streaming reader's
/// window is a stack local.
pub fn DecodeHooks(comptime F: type, comptime Host: type) type {
    return struct {
        /// Decode one complete container from `source` into `target`.
        /// `target` is a cap; the return is the decoded length. The
        /// container is located by exact consumption: the body runs through
        /// the streaming `Host`, whose position after the clean end is the
        /// trailer — verified against the bytes the decode produced. Bytes
        /// after the trailer are ignored: the one-shot reports no consumed
        /// count, so a boundary-aware caller uses the streaming reader.
        /// `error.BufferTooSmall` is reported before the overflowing write.
        pub fn decompress(source: []const u8, target: []u8) F.DecompressError!usize {
            var input: Io.Reader = .fixed(source);
            var output: Io.Writer = .fixed(target);
            var buffer: F.ReaderBuffer = undefined;
            var reader: Host = .init(&input, &buffer);
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

        /// The one-shot's view of a streaming failure: the detail recorded
        /// in `err`. Three interface entries cannot occur on this path — the
        /// one-shot's consumer never asks for contiguous bytes (no
        /// `StreamTooLong`), its input is a fixed slice (no input
        /// `ReadFailed`), and `streamRemaining` consumes the clean end
        /// itself (no `EndOfStream`) — so they are unreachable here.
        fn detail(reader: *const Host) F.DecompressError {
            const recorded = reader.err.?;
            return switch (recorded) {
                error.StreamTooLong, error.ReadFailed, error.EndOfStream => unreachable,
                else => |err| err,
            };
        }
    };
}
