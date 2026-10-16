//! Snappy example CLI: `snappy encode [FILE|-] > out`,
//! `snappy decode [FILE|-] > out`. Shared scaffolding in `examples/cli.zig`.
//!
//! `encode` runs the input through `snappy.Writer.streamAll`, and `decode`
//! runs it through `snappy.Reader.streamAll`. The stream format (each raw
//! block behind a little-endian `u32` compressed length, blocks split at
//! `snappy.encode.max_block_size`) belongs to the snappy package, not to this
//! file. Both directions use stack buffers and allocate nothing.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const cli = @import("cli");
const snappy = @import("compress").snappy;

/// The codec's CLI surface: `main` runs it, the test drives the same pumps.
const codec: cli.Codec = .{
    .name = "snappy",
    .encode = encode,
    .decode = decode,
};

pub fn main(init: std.process.Init) !u8 {
    return cli.run(codec, init);
}

fn encode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    _ = arena;
    _ = try snappy.Writer.streamAll(in, out);
}

fn decode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    _ = arena;
    _ = try snappy.Reader.streamAll(in, out);
}

test "example: streaming round-trip" {
    try cli.expectRoundTrip(codec, "hello hello hello, streaming snappy round-trip");
}
