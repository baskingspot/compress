//! The command-line harness behind `just flate-oracle`, which checks this codec
//! against python3's `zlib` (raw deflate) in both directions
//! (docs/research/flate-notes.md §4.3; the driver is scripts/flate_oracle.py).
//! A test tool, not part of the codec: it allocates freely, from an arena.
//!
//! Usage:
//!   flate-oracle decode <stream-file> <cap-bytes> [dict-file] > out
//!   flate-oracle encode <input-file> [LEVEL] [dict-file] > stream
//!
//! `decode` writes the decoded bytes of one raw deflate stream to stdout, with
//! the output capped at `cap-bytes`; `dict-file` is the stream's preset
//! dictionary (`§3.2.3`), read whole. `encode` writes our raw deflate stream
//! for the input file at `LEVEL` (1 by default, 6 for the dynamic-Huffman
//! class), against `dict-file` as the preset dictionary when one is given.
//! Exits 1 on a usage or codec error and prints the error name to stderr.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const flate = @import("compress").flate;

/// Cap on the compressed stream the harness will read into memory.
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
        print("usage: flate-oracle decode <stream-file> <cap-bytes> [dict-file] > out\n", .{});
        print("       flate-oracle encode <input-file> [dict-file] > stream\n", .{});
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
            print("flate-oracle: decode needs <stream-file> <cap-bytes> [dict-file]\n", .{});
            return 1;
        }
        const cap = std.fmt.parseInt(usize, args[3], 10) catch {
            print("flate-oracle: cap must be a byte count, got '{s}'\n", .{args[3]});
            return 1;
        };
        const dict: ?[]const u8 = if (args.len == 5) try readFile(arena, io, args[4]) else null;
        const source = try file_reader.interface.allocRemaining(arena, .limited(max_stream_len));
        const target = try arena.alloc(u8, cap);

        const decoded_len = flate.decode.decompress(source, target, dict) catch |err| {
            print("flate-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        try stdout_writer.interface.writeAll(target[0..decoded_len]);
        return 0;
    }

    if (std.mem.eql(u8, args[1], "encode")) {
        if (args.len < 3 or args.len > 5) {
            print("flate-oracle: encode needs <input-file> [LEVEL] [dict-file]\n", .{});
            return 1;
        }
        const level: u8 = if (args.len >= 4)
            std.fmt.parseInt(u8, args[3], 10) catch {
                print("flate-oracle: level must be a number, got '{s}'\n", .{args[3]});
                return 1;
            }
        else
            1;
        const dict: ?[]const u8 = if (args.len == 5) try readFile(arena, io, args[4]) else null;
        const source = try file_reader.interface.allocRemaining(arena, .limited(max_input_len));
        const target = try arena.alloc(u8, flate.encode.maxCompressedLength(source.len));

        const encoded_len = flate.encode.compress(source, target, .{
            .level = level,
            .dict = dict,
        }) catch |err| {
            print("flate-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        try stdout_writer.interface.writeAll(target[0..encoded_len]);
        return 0;
    }

    print("flate-oracle: unknown mode '{s}'\n", .{args[1]});
    return 1;
}
