//! Flate example CLI: `flate encode [FILE|-] > out`,
//! `flate decode [FILE|-] > out`. Shared scaffolding in `examples/cli.zig`.
//!
//! `encode` runs the input through `flate.Writer.streamAll`, and `decode`
//! runs it through `flate.Reader.streamAll`. Raw deflate needs no framing of
//! its own: the final block (BFINAL) ends the stream (RFC 1951 §3.2.3), so
//! the tool's output is the deflate stream itself. Both directions use stack
//! buffers and allocate nothing.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const cli = @import("cli");
const flate = @import("compress").flate;

/// The codec's CLI surface: `main` runs it, the test drives the same pumps.
const codec: cli.Codec = .{
    .name = "flate",
    .encode = encode,
    .decode = decode,
};

pub fn main(init: std.process.Init) !u8 {
    return cli.run(codec, init);
}

fn encode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    _ = arena;
    _ = try flate.Writer.streamAll(in, out, .init);
}

fn decode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    _ = arena;
    _ = try flate.Reader.streamAll(in, out, null);
}

test "example: streaming round-trip" {
    try cli.expectRoundTrip(codec, "hello hello hello, streaming flate round-trip");
}
