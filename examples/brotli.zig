//! brotli example CLI: `brotli decode [FILE|-] > out`. Shared scaffolding in
//! `examples/cli.zig`; the codec is decoder-only, so the CLI reports `encode`
//! as usage.
//!
//! `decode` runs the input through `brotli.Reader.streamAll`, which decodes
//! every stream in the input and writes the concatenation. Each stream is
//! consumed exactly through its last byte, so the walk starts the next one at
//! the right position; a tail that cannot begin a stream is an error. The
//! default buffer is about 16.7 MiB, so it comes from the arena rather than
//! the stack; nothing else is allocated.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const cli = @import("cli");
const brotli = @import("zcompress").brotli;

/// The codec's CLI surface: `main` runs it, the tests drive the same pump.
const codec: cli.Codec = .{
    .name = "brotli",
    .decode = decode,
};

pub fn main(init: std.process.Init) !u8 {
    return cli.run(codec, init);
}

fn decode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    // The default buffer is 16.7 MiB: never a stack local.
    const buffer = try arena.create(brotli.Reader.DefaultBuffer);
    _ = try brotli.Reader.streamAll(
        brotli.Reader.default_window_wbits,
        in,
        out,
        buffer,
    );
}

test "example: the empty stream decodes to nothing" {
    // RFC 7932 §7.2 — the empty *stream* is the single byte `06`.
    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var in: Io.Reader = .fixed(&[_]u8{0x06});
    try decode(arena.allocator(), &in, &plain.writer);
    try testing.expectEqual(@as(usize, 0), plain.written().len);
}

test "example: the walk decodes concatenated streams" {
    // Two empty streams: the walk reads the second where the first ended.
    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var in: Io.Reader = .fixed(&[_]u8{ 0x06, 0x06 });
    try decode(arena.allocator(), &in, &plain.writer);
    try testing.expectEqual(@as(usize, 0), plain.written().len);
    try testing.expectEqual(@as(usize, 2), in.seek);
}

test "example: a tail that cannot begin a stream fails" {
    // RFC 7932 §9.1 — 0010001 "is invalid and must not be used": at a
    // start position those bytes cannot begin a stream.
    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var in: Io.Reader = .fixed(&[_]u8{ 0x06, 0x11 });
    try testing.expectError(error.ReadFailed, decode(arena.allocator(), &in, &plain.writer));
}

test "example: the CLI's own stream decodes" {
    // The pinned CLI's `brotli -q 9 -w 10 -c` over
    // 'the quick brown fox jumps over the lazy dog\n' ** 100: 4,400 bytes in
    // 49, one copy at distance 45 (verified with brotli 1.2.0).
    const stream = [_]u8{
        0xA1, 0x78, 0x89, 0x00, 0x20, 0x9A, 0x27, 0xED, 0x96, 0xA9, 0xF3, 0x4A,
        0x1C, 0x22, 0x4F, 0xE5, 0xF8, 0x73, 0x14, 0x89, 0x7E, 0x2B, 0x2B, 0x33,
        0x93, 0xE0, 0x8C, 0x70, 0xCA, 0xD3, 0x10, 0x78, 0x91, 0x57, 0xED, 0x03,
        0xDC, 0xA2, 0x20, 0xF7, 0x45, 0x00, 0x28, 0xF6, 0x3F, 0x78, 0x46, 0xE3,
        0x01,
    };
    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var in: Io.Reader = .fixed(&stream);
    try decode(arena.allocator(), &in, &plain.writer);
    try testing.expectEqualStrings(
        "the quick brown fox jumps over the lazy dog\n" ** 100,
        plain.written(),
    );
}
