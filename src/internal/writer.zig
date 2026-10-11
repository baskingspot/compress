//! The shared writer machinery: the generated `Io.Writer` vtable entries and
//! the poisoned `finish` every compressing codec writer runs (README.md,
//! "The Io codec pattern book").
//!
//! The generator builds `drain`/`flush`/`rebase` and `finish` from a codec
//! writer `Host`, an `emitBlock` hook, and an optional stream-ending hook:
//! the `errdefer` poison, the parent-pointer cast, the drain top-up, the
//! rebase slide, the postconditions, and the terminal finish are structural,
//! not per-codec.
//!
//! `Host` carries two fields: `writer: Io.Writer` (the embedded interface,
//! whose `buffer` is the codec's block region) and `output: *Io.Writer` (the
//! compressed-stream sink). `emitBlock(host, len)` emits the first `len`
//! bytes of the buffered block through the codec's encoder and leaves the
//! unemitted tail at the front of the block region (`writer.end -= len`) —
//! the contract `drain`, `flush`, and `rebase` all rely on. `ending(host)`
//! writes the codec's stream ending after the final block (flate's `03 00`
//! fixed block); a codec whose stream has no ending of its own passes null.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const fastmem = @import("fastmem");

/// The generated `Io.Writer` vtable entries and `finish` for a codec writer
/// `Host`:
///
///     const Hooks = internal.writer.VTable(Writer, emitBlock, ending);
///     // init:        .vtable = &Hooks.vtable  (the generated const, never a copy)
///     // public API:  pub fn finish(w: *Writer) !void { return Hooks.finish(w); }
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

        /// The buffer is full: top it up from the front of `data` (the last
        /// slice repeats `splat` times), then emit the full block. `drain`
        /// only runs when `data` does not fit, so the top-up fills the
        /// region: every emitted block but the last is full. A degenerate
        /// call that accepted nothing still makes progress by emitting what
        /// is buffered.
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

        /// Emit the buffered block and flush `output`, keeping the writer
        /// usable: the codec's own ending is `finish`'s, never a flush's.
        fn flush(w: *Io.Writer) Io.Writer.Error!void {
            errdefer w.* = .failing;
            const host: *Host = @alignCast(@fieldParentPtr("writer", w));
            try emitBlock(host, w.end);
            try host.output.flush();
        }

        /// Everything buffered except the last `preserve` bytes is written
        /// data: emit it as a block, then leave the preserved tail as the
        /// buffered block. (A consumer can ask for a direct writable slice
        /// into the region via `writableSliceGreedy`; when the region is
        /// full, that call lands here — discarding instead of emitting would
        /// silently drop input.) `emitBlock` owns the slide: it leaves the
        /// tail at the front of the block region, with `end == keep`.
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

        /// Complete the stream: emit the buffered block, write the codec's
        /// ending, then flush `output`. Terminal — the writer is poisoned
        /// afterwards, and a failed or finished writer reports
        /// `error.WriteFailed` instead of a false success.
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
