//! Command-line harness behind `just zlib-oracle`, which cross-checks this
//! module against python3's `zlib` (the C reference) in both directions;
//! `scripts/zlib_oracle.py` drives it. It is a test tool, not part of the
//! codec: it reads whole files into an arena allocator, which the codec
//! itself never does.
//!
//! Usage:
//!   zlib-oracle decode <stream-file> <cap-bytes> [dict-file] > out
//!   zlib-oracle encode <input-file> [LEVEL] [dict-file] > stream
//!
//! `decode` writes the decoded bytes of one zlib stream to stdout; `dict-file`
//! is the stream's preset dictionary (§2.2), read whole. `encode` writes our
//! zlib stream for the input file at `LEVEL` (`fast` by default; `0`-`9` and
//! `ratio` name the flate levels), against `dict-file` as the preset dictionary
//! when one is given. Exit 1 on a codec error, with the error name on stderr.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const zlib = @import("compress").zlib;

/// Cap on the stream the harness will read into memory.
const max_stream_len = 1 << 30;
/// Cap on the uncompressed input `encode` will read.
const max_input_len = 1 << 30;

/// Read a whole file into the arena, for the optional dictionary argument.
fn readFile(arena: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{
        .allow_directory = false,
        .follow_symlinks = true,
    });
    var read_buffer: [64 * 1024]u8 = undefined;
    var file_reader: Io.File.Reader = .init(file, io, &read_buffer);
    return file_reader.interface.allocRemaining(arena, .limited(max_input_len));
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        print("usage: zlib-oracle decode <stream-file> <cap-bytes> [dict-file] > out\n", .{});
        print("       zlib-oracle encode <input-file> [LEVEL] [dict-file] > stream\n", .{});
        return 1;
    }

    const file = try Io.Dir.cwd().openFile(io, args[2], .{
        .allow_directory = false,
        .follow_symlinks = true,
    });
    var read_buffer: [64 * 1024]u8 = undefined;
    var file_reader: Io.File.Reader = .init(file, io, &read_buffer);

    var write_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &write_buffer);
    defer stdout_writer.interface.flush() catch {};

    if (std.mem.eql(u8, args[1], "decode")) {
        if (args.len != 4 and args.len != 5) {
            print("zlib-oracle: decode needs <stream-file> <cap-bytes> [dict-file]\n", .{});
            return 1;
        }
        const cap = std.fmt.parseInt(usize, args[3], 10) catch {
            print("zlib-oracle: cap must be a byte count, got '{s}'\n", .{args[3]});
            return 1;
        };
        const dict: ?[]const u8 = if (args.len == 5) try readFile(arena, io, args[4]) else null;
        const source = try file_reader.interface.allocRemaining(arena, .limited(max_stream_len));
        const target = try arena.alloc(u8, cap);

        const decoded_len = zlib.decode.decompress(source, target, dict) catch |err| {
            print("zlib-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        try stdout_writer.interface.writeAll(target[0..decoded_len]);
        return 0;
    }

    if (std.mem.eql(u8, args[1], "encode")) {
        if (args.len != 3 and args.len != 4 and args.len != 5) {
            print("zlib-oracle: encode needs <input-file> [LEVEL] [dict-file]\n", .{});
            return 1;
        }
        const level: zlib.encode.Level = if (args.len >= 4)
            std.meta.stringToEnum(zlib.encode.Level, args[3]) orelse {
                print("zlib-oracle: unknown level '{s}'\n", .{args[3]});
                return 1;
            }
        else
            .fast;
        const dict: ?[]const u8 = if (args.len == 5) try readFile(arena, io, args[4]) else null;
        const source = try file_reader.interface.allocRemaining(arena, .limited(max_input_len));
        const target = try arena.alloc(u8, zlib.encode.maxCompressedLength(source.len));

        const encoded_len = zlib.encode.compress(source, target, .{
            .level = level,
            .dict = dict,
        }) catch |err| {
            print("zlib-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        try stdout_writer.interface.writeAll(target[0..encoded_len]);
        return 0;
    }

    print("zlib-oracle: unknown mode '{s}'\n", .{args[1]});
    return 1;
}
