//! zlib example CLI: `zlib encode [FILE|-] > out`,
//! `zlib decode [FILE|-] > out`. Shared scaffolding in `examples/cli.zig`.
//!
//! `encode` runs the input through `zlib.Writer.streamAll`, which writes one
//! stream. `decode` runs it through `zlib.Reader.streamAll`, which decodes one
//! stream and stops after its Adler-32 trailer. Whatever follows is left
//! unread: RFC 1950 §2.2 says "Any data which may appear after ADLER32 are
//! not part of the zlib stream". A caller that wants concatenated streams can
//! repeat the call, since the reader consumes exactly through the trailer.
//! Both directions use stack buffers and allocate nothing.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const cli = @import("cli");
const zlib = @import("zcompress").zlib;

/// The codec's CLI surface: `main` runs it, the tests drive the same pumps.
const codec: cli.Codec = .{
    .name = "zlib",
    .encode = encode,
    .decode = decode,
};

pub fn main(init: std.process.Init) !u8 {
    return cli.run(codec, init);
}

fn encode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    _ = arena;
    _ = try zlib.Writer.streamAll(in, out, .{});
}

fn decode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    _ = arena;
    _ = try zlib.Reader.streamAll(in, out);
}

test "example: streaming round-trip" {
    try cli.expectRoundTrip(codec, "hello hello hello, streaming zlib round-trip");
}

test "example: decode stops at the stream's end" {
    // RFC 1950 §2.2 — "Any data which may appear after ADLER32 are not part
    // of the zlib stream": the pump decodes the stream and leaves whatever
    // follows unconsumed.
    var compressed: Io.Writer.Allocating = .init(testing.allocator);
    defer compressed.deinit();
    var in: Io.Reader = .fixed("hello, zlib");
    try encode(testing.allocator, &in, &compressed.writer);

    // The stream, then marker bytes where a next stream would start.
    var framed: Io.Writer.Allocating = .init(testing.allocator);
    defer framed.deinit();
    try framed.writer.writeAll(compressed.written());
    try framed.writer.splatBytesAll(&[_]u8{0xaa}, 8);

    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    var z: Io.Reader = .fixed(framed.written());
    try decode(testing.allocator, &z, &plain.writer);
    try testing.expectEqualStrings("hello, zlib", plain.written());
    try testing.expectEqual(compressed.written().len, z.seek);
}
