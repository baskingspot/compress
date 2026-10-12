//! The `Io.Writer` vtable entries and `finish` shared by block-based
//! compressing writers (snappy and flate).
//!
//! `VTable` generates `drain`, `flush`, `rebase`, and `finish` from the
//! codec's `emitBlock` hook and an optional stream-ending hook. The codec
//! supplies only block encoding. After a failed call, and after `finish`, the
//! writer is replaced by `Io.Writer.failing`, so every later call returns
//! `error.WriteFailed`.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const fastmem = @import("fastmem");

/// Generates the `Io.Writer` vtable entries and `finish` for a codec writer
/// `Host`:
///
///     const Hooks = internal.writer.VTable(Writer, emitBlock, ending);
///     // init:        .vtable = &Hooks.vtable  (the generated const, never a copy)
///     // public API:  pub fn finish(w: *Writer) !void { return Hooks.finish(w); }
///
/// `finish` recognizes a live writer by the address of `Hooks.vtable`, so
/// `init` must store `&Hooks.vtable`, not a copy of its value.
///
/// `Host` needs two fields: `writer: Io.Writer`, the embedded interface whose
/// `buffer` is the codec's block region, and `output: *Io.Writer`, the sink for
/// the compressed bytes.
///
/// - `emitBlock(host, len)` encodes the first `len` buffered bytes to `output`
///   and leaves the rest at the front of the block region
///   (`writer.end -= len`). `drain`, `flush`, and `rebase` all rely on that.
/// - `ending(host)` writes the stream ending after the final block (flate's
///   `03 00`, an empty final fixed block). A codec whose stream has no ending
///   of its own passes null.
pub fn VTable(
    comptime Host: type,
    comptime emitBlock: fn (*Host, usize) Io.Writer.Error!void,
    comptime ending: ?fn (*Host) Io.Writer.Error!void,
) type {
    return struct {
        pub const vtable: Io.Writer.VTable = .{
            .drain = drain,
            .flush = flush,
            .rebase = rebase,
        };

        /// Called when `data` does not fit in the buffer. Tops the buffer up
        /// from the front of `data` (the last slice repeats `splat` times),
        /// then emits the full block, so every emitted block but the last is
        /// full whatever the caller's write sizes were. A call that accepts
        /// nothing still makes progress by emitting what is buffered.
        fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
            errdefer w.* = .failing;
            const host: *Host = @alignCast(@fieldParentPtr("writer", w));
            var consumed: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| {
                consumed += accept(w, bytes);
                if (w.end == w.buffer.len) break;
            }
            const pattern = data[data.len - 1];
            if (pattern.len != 0) {
                for (0..splat) |_| {
                    if (w.end == w.buffer.len) break;
                    consumed += accept(w, pattern);
                }
            }
            if (w.end == w.buffer.len or consumed == 0) try emitBlock(host, w.end);
            return consumed;
        }

        /// Emits the buffered block and flushes `output`. The writer stays
        /// usable: the stream ending is written only by `finish`.
        fn flush(w: *Io.Writer) Io.Writer.Error!void {
            errdefer w.* = .failing;
            const host: *Host = @alignCast(@fieldParentPtr("writer", w));
            try emitBlock(host, w.end);
            try host.output.flush();
        }

        /// Makes room for `capacity` more bytes. Everything buffered except
        /// the last `preserve` bytes is written data: emit it as a block, then
        /// leave the preserved tail as the buffered block. A consumer that asks
        /// for a direct writable slice (`writableSliceGreedy`) on a full
        /// buffer lands here; discarding instead of emitting would silently
        /// drop input. `emitBlock` does the slide: it leaves the tail at the
        /// front of the block region, with `end == keep`.
        fn rebase(w: *Io.Writer, preserve: usize, capacity: usize) Io.Writer.Error!void {
            errdefer w.* = .failing;
            assert(preserve + capacity <= w.buffer.len);
            const host: *Host = @alignCast(@fieldParentPtr("writer", w));
            const keep = @min(preserve, w.end);
            try emitBlock(host, w.end - keep);
            // Postcondition: the preserved tail is buffered and the freed
            // room is at least the requested capacity.
            assert(w.end == keep);
            assert(w.buffer.len - w.end >= capacity);
        }

        /// Completes the stream: emits the buffered block, writes the codec's
        /// ending, and flushes `output`. Terminal: the writer is poisoned
        /// afterwards, so later writes and `finish` calls return
        /// `error.WriteFailed`. A writer that already failed or finished
        /// returns `error.WriteFailed` here too, never a false success.
        pub fn finish(host: *Host) Io.Writer.Error!void {
            if (host.writer.vtable != &vtable) return error.WriteFailed;
            defer host.writer = .failing;
            try emitBlock(host, host.writer.end);
            if (ending) |writeEnding| try writeEnding(host);
            try host.output.flush();
        }

        /// Copy at most the block region's remaining space from the front of
        /// `bytes` to `buffer[end..]`, returning the bytes taken.
        fn accept(w: *Io.Writer, bytes: []const u8) usize {
            const n = @min(bytes.len, w.buffer.len - w.end);
            fastmem.copy(u8, w.buffer[w.end..][0..n], bytes[0..n]);
            w.end += n;
            return n;
        }
    };
}
