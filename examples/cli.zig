//! Shared scaffolding for the per-codec example CLIs.
//!
//! Each codec gets a thin executable (`examples/<codec>.zig`) that names the
//! codec and provides streaming `encode`/`decode` pumps. This file owns
//! everything the codecs share: argument parsing, input (a file, or stdin
//! via `-` or no argument) as an `Io.File.Reader`, stdout, and error
//! handling. A codec with no encoder yet leaves `encode` null and the CLI
//! reports the direction as usage.
//!
//! Usage (per codec): `<codec> encode [FILE|-] > out`, `<codec> decode [FILE|-] > out`.
//! Errors propagate to an error return trace with a nonzero exit code.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;
const stringToEnum = std.meta.stringToEnum;
const mem = std.mem;
const Allocator = mem.Allocator;
const process = std.process;

/// The uniform streaming pump both directions share: the whole input in, the
/// codec's stream out (encode) or the decoded bytes out (decode).
pub const StreamFn = *const fn (arena: Allocator, in: *Io.Reader, out: *Io.Writer) anyerror!void;

pub const Codec = struct {
    name: []const u8,
    /// Encode the whole input and write the encoded stream to `out`. Null for
    /// a codec with no encoder yet (zstd until M5): the CLI reports the
    /// direction as usage, and the codec's error surface never carries it.
    encode: ?StreamFn = null,
    /// Decode a stream produced by `encode` and write the decoded bytes.
    decode: StreamFn,
};

const Mode = enum {
    encode,
    decode,
};

pub fn run(codec: Codec, init: process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return usage(codec);

    const cmd = args[1];
    const rest = args[2..];

    const mode = stringToEnum(Mode, cmd) orelse return usage(codec);

    const path: ?[]const u8 = switch (rest.len) {
        0 => null,
        1 => if (mem.eql(u8, rest[0], "-")) null else rest[0],
        else => return usage(codec),
    };

    const input: Io.File = if (path) |p| try Io.Dir.cwd().openFile(io, p, .{
        .allow_directory = false,
        .follow_symlinks = true,
    }) else .stdin();

    var read_buffer: [64 * 1024]u8 = undefined;
    var file_reader: Io.File.Reader = .init(input, io, &read_buffer);
    const reader = &file_reader.interface;

    var write_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &write_buffer);
    const writer = &stdout_writer.interface;
    // Best-effort flush on every exit path; errors are unreportable here.
    defer writer.flush() catch {};

    const op = switch (mode) {
        .encode => codec.encode orelse return usage(codec),
        .decode => codec.decode,
    };
    try op(arena, reader, writer);
    return 0;
}

/// The round trip every codec's example test drives: `text` through the
/// codec's own pumps, decoded back, bytes required. A codec without an
/// encoder (zstd) cannot call it.
pub fn expectRoundTrip(codec: Codec, text: []const u8) !void {
    const encode = codec.encode orelse return error.NoEncoder;
    const testing = std.testing;

    var compressed: Io.Writer.Allocating = .init(testing.allocator);
    defer compressed.deinit();
    var in: Io.Reader = .fixed(text);
    try encode(testing.allocator, &in, &compressed.writer);

    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    var z: Io.Reader = .fixed(compressed.written());
    try codec.decode(testing.allocator, &z, &plain.writer);

    try testing.expectEqualStrings(text, plain.written());
}

fn usage(codec: Codec) u8 {
    if (codec.encode != null) {
        print("usage: {s} encode|decode [FILE|-] > out\n", .{codec.name});
    } else {
        print("usage: {s} decode [FILE|-] > out (decode-only)\n", .{codec.name});
    }
    return 1;
}
