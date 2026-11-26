//! LZ4 example CLI: `lz4 encode [FILE|-] > out`,
//! `lz4 decode [FILE|-] > out`. Shared scaffolding in `examples/cli.zig`.
//!
//! Raw LZ4 blocks carry neither their compressed nor decoded length. This tool
//! uses its own sequence of independent 64 KiB records, each behind two
//! little-endian u32 lengths: decoded, then compressed. It is not the LZ4 frame
//! format. Both directions use stack buffers and allocate nothing.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const readInt = std.mem.readInt;
const writeInt = std.mem.writeInt;

const cli = @import("cli");
const lz4 = @import("compress").lz4;

const max_record_len = 64 * 1024;
const max_compressed_len = lz4.encode.maxCompressedLength(max_record_len);
const header_len = 8;

const codec: cli.Codec = .{
    .name = "lz4",
    .encode = encode,
    .decode = decode,
};

pub fn main(init: std.process.Init) !u8 {
    return cli.run(codec, init);
}

fn encode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    _ = arena;
    var source: [max_record_len]u8 = undefined;
    var target: [max_compressed_len]u8 = undefined;
    while (true) {
        const source_len = try in.readSliceShort(&source);
        if (source_len == 0) return;
        const target_len = try lz4.encode.compressBlock(source[0..source_len], &target);
        var header: [header_len]u8 = undefined;
        writeInt(u32, header[0..4], @intCast(source_len), .little);
        writeInt(u32, header[4..8], @intCast(target_len), .little);
        try out.writeAll(&header);
        try out.writeAll(target[0..target_len]);
    }
}

fn decode(arena: Allocator, in: *Io.Reader, out: *Io.Writer) !void {
    _ = arena;
    var source: [max_compressed_len]u8 = undefined;
    var target: [max_record_len]u8 = undefined;
    while (true) {
        var header: [header_len]u8 = undefined;
        const header_read = try in.readSliceShort(&header);
        if (header_read == 0) return;
        if (header_read != header.len) return error.Truncated;
        const decoded_len = readInt(u32, header[0..4], .little);
        const compressed_len = readInt(u32, header[4..8], .little);
        if (decoded_len > max_record_len) return error.InvalidStream;
        if (compressed_len == 0 or compressed_len > lz4.encode.maxCompressedLength(decoded_len)) {
            return error.InvalidStream;
        }
        try in.readSliceAll(source[0..compressed_len]);
        const written = try lz4.decode.decompressBlock(
            source[0..compressed_len],
            target[0..decoded_len],
        );
        try out.writeAll(target[0..written]);
    }
}

test "example: streaming round-trip" {
    try cli.expectRoundTrip(codec, "hello hello hello, streaming lz4 round-trip");
}

test "example: multiple records round-trip" {
    const input = try std.testing.allocator.alloc(u8, 200_000);
    defer std.testing.allocator.free(input);
    for (input, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% i / 97);
    try cli.expectRoundTrip(codec, input);
}
