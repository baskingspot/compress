//! The `Io.Reader` lifecycle shared by codec readers, and the generated
//! vtable entries built on it.
//!
//! A reader is `streaming` until its input ends cleanly at a stream boundary
//! (`done`) or a failure occurs (`failed`). A failure is sticky: the detail is
//! recorded in the codec's `err` field and every later call reports it. Each
//! codec reader keeps its own `state` and `err` (the detail error set belongs
//! to the codec), consults `guard` on entry, and records failures with `fail`.
//!
//! `VTable` generates the `stream`, `discard`, `readVec`, and `rebase`
//! entries from the codec's fill and rebase functions.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

/// Where a reader is in its life. `done` (the input ended cleanly at a stream
/// boundary) and `failed` (the detail is in the codec's `err` field) are
/// terminal.
pub const State = enum { streaming, done, failed };

/// The error a reader in `state` must report, or null while `streaming`:
/// `error.ReadFailed` once `failed`, `error.EndOfStream` once `done`. Every
/// vtable entry calls it first.
pub fn guard(state: State) ?Io.Reader.Error {
    return switch (state) {
        .failed => error.ReadFailed,
        .done => error.EndOfStream,
        .streaming => null,
    };
}

/// Records a failure: sets `state` to `failed`, stores `err` in `detail`, and
/// returns `error.ReadFailed`, the interface's coarse error. Call it once,
/// from the entry that found the failure; `state` must still be `streaming`.
/// What happens to bytes already buffered is the codec's policy, applied by its
/// own wrapper around this function (flate drops them, so no partial output
/// follows an error; snappy keeps them).
pub fn fail(comptime Detail: type, state: *State, detail: *?Detail, err: Detail) Io.Reader.Error {
    // `failed` is terminal: a failure is recorded once, by the entry that
    // discovered it.
    assert(state.* == .streaming);
    state.* = .failed;
    detail.* = err;
    return error.ReadFailed;
}

/// Generates the `Io.Reader` vtable entries for a codec reader `Host`. Take
/// the table from the returned namespace:
/// `const vtable = internal.reader.VTable(Reader, pump, rebase).vtable;`
///
/// `Host` needs two fields: `reader: Io.Reader`, the embedded interface, and
/// `state: State`.
///
/// - `pump(host)` decodes more bytes into `host.reader.buffer`, adjusting
///   `seek` and `end`, and maps every failure to an `Io.Reader.Error` (see
///   `fail`). Its returned count is ignored: `stream` and `readVec` return 0,
///   because the data went into the buffer, not to a writer
///   (`std/Io/Reader.zig:42-44`).
/// - `rebase(host, capacity)` slides the unconsumed bytes to the front of the
///   buffer so that `capacity` contiguous bytes fit. A request the buffer
///   cannot hold must return an error (`error.ReadFailed` with
///   `StreamTooLong` recorded in `err`), never assert: the consumer made the
///   request, not a bug in the codec.
///
/// Every entry first applies `guard`. `stream` answers a zero-length poll with
/// 0 without calling `pump`, and `discard` pumps once, then consumes up to
/// `limit` of the buffered bytes.
pub fn VTable(
    comptime Host: type,
    comptime pump: fn (*Host) Io.Reader.Error!usize,
    comptime rebase: fn (*Host, usize) Io.Reader.RebaseError!void,
) type {
    return struct {
        fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
            _ = w;
            const host: *Host = @alignCast(@fieldParentPtr("reader", r));
            if (guard(host.state)) |err| return err;
            // A zero limit is a poll. `std.Io.Reader.stream` slices the
            // buffered bytes by the limit, so a zero limit leaves an empty
            // slice and reaches the vtable even when bytes are buffered
            // (`std/Io/Reader.zig:168-177`). Answer 0 without filling: a fill
            // can fail with `StreamTooLong` on a valid stream whose serving
            // region cannot hold a fresh block beside the unconsumed bytes.
            if (limit == .nothing) return 0;
            _ = try pump(host);
            return 0;
        }

        fn discard(r: *Io.Reader, limit: Io.Limit) Io.Reader.Error!usize {
            const host: *Host = @alignCast(@fieldParentPtr("reader", r));
            if (guard(host.state)) |err| return err;
            _ = try pump(host);
            const n = limit.minInt(r.end - r.seek);
            r.seek += n;
            return n;
        }

        fn readVec(r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
            _ = data;
            const host: *Host = @alignCast(@fieldParentPtr("reader", r));
            if (guard(host.state)) |err| return err;
            _ = try pump(host);
            return 0;
        }

        fn rebaseEntry(r: *Io.Reader, capacity: usize) Io.Reader.RebaseError!void {
            const host: *Host = @alignCast(@fieldParentPtr("reader", r));
            if (guard(host.state)) |err| return err;
            return rebase(host, capacity);
        }

        pub const vtable: Io.Reader.VTable = .{
            .stream = stream,
            .discard = discard,
            .readVec = readVec,
            .rebase = rebaseEntry,
        };
    };
}
