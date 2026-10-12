//! zstd example CLI: `zstd decode [FILE|-] > out`. Shared scaffolding in
//! `examples/cli.zig`.
//!
//! There is no zstd encoder, so the CLI leaves `encode` null and reports that
//! direction as usage. `decode` runs the input through
//! `zstd.Reader.streamAllAlloc`, which decodes every frame in turn (RFC 8878
//! §3.1: the decompressed output is the concatenation of the frames).
//! Skippable frames are consumed and ignored (§3.1.2), and empty input is a
//! clean end. Bytes where a frame should start must be a valid frame magic,
//! or the decode fails (`BadMagic` in the reader, surfaced by the pump as
//! `error.ReadFailed`).
//!
//! The default window buffer is 8 MiB + 256 KiB: the 8 MiB window that
//! §3.1.1.1.2 recommends decoders support, plus block room. That is too large
//! for a stack local under the usual 8 MiB stack limit, so `streamAllAlloc`
//! allocates it from the run's arena for the call. The other examples buffer
//! on the stack. The codec itself does not allocate; the allocator is this
//! example's.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const cli = @import("cli");
const zstd = @import("zcompress").zstd;

pub fn main(init: std.process.Init) !u8 {
    // No `encode`: there is no zstd encoder, so `cli.run` reports that
    // direction as usage.
    return cli.run(.{ .name = "zstd", .decode = decode }, init);
}

fn decode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    // `streamAllAlloc` takes the default window (8 MiB + 256 KiB) from the
    // arena for the call, then decodes every frame (RFC 8878 §3.1).
    _ = try zstd.Reader.streamAllAlloc(arena, in, out);
}

test "example: the decode pump walks a multi-frame file" {
    // RFC 8878 §3.1 — frames concatenate: the CLI decodes every frame, and
    // trailing bytes that do not start a frame are an error.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var frames: Io.Writer.Allocating = .init(testing.allocator);
    defer frames.deinit();
    try frames.writer.writeAll(&frame_raw);
    try frames.writer.writeAll(&frame_raw);

    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    var z: Io.Reader = .fixed(frames.written());
    try decode(arena, &z, &plain.writer);
    try testing.expectEqualStrings("zstd rawzstd raw", plain.written());

    // Trailing garbage: the next frame's magic check fails.
    try frames.writer.writeByte(0x00);
    var bad: Io.Writer.Allocating = .init(testing.allocator);
    defer bad.deinit();
    var bad_in: Io.Reader = .fixed(frames.written());
    try testing.expectError(error.ReadFailed, decode(arena, &bad_in, &bad.writer));
}

test "example: the pump stops at the frame's end" {
    // A frame's end is exact: decoding one frame consumes through its last
    // byte, the checksum's when the frame has one (RFC 8878 §3.1.1), and
    // leaves the marker bytes behind it unread, where the next frame would
    // start.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var framed: Io.Writer.Allocating = .init(testing.allocator);
    defer framed.deinit();
    try framed.writer.writeAll(&frame_raw);
    try framed.writer.writeByte(0xaa);
    try framed.writer.writeByte(0xaa);

    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    var z: Io.Reader = .fixed(framed.written());
    const buffer = try arena.create(zstd.Reader.DefaultBuffer);
    try testing.expectEqual(
        @as(usize, 8),
        try zstd.Reader.streamFrame(zstd.Reader.default_window_len, &z, &plain.writer, buffer),
    );
    try testing.expectEqualStrings("zstd raw", plain.written());
    try testing.expectEqual(frame_raw.len, z.seek);
}

/// `golden.frame_raw`'s bytes: the Zstandard magic (`§3.1.1`), a 512-KiB
/// window descriptor (`§3.1.1.1.2`), and one Raw block of 8 bytes —
/// "zstd raw" (`§3.1.1.2.2`).
const frame_raw = [_]u8{
    0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x48, 0x41, 0x00, 0x00,
    0x7a, 0x73, 0x74, 0x64, 0x20, 0x72, 0x61, 0x77,
};
