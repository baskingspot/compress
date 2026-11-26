//! The command-line harness behind `just lz4-oracle`, which checks raw blocks
//! against github.com/pierrec/lz4/v4 in both directions. The Python driver is
//! `scripts/lz4_oracle.py`. A test tool, not part of the codec: it allocates
//! from the process arena.
//!
//! Usage:
//!   lz4-oracle encode <input-file> > block
//!   lz4-oracle decode <block-file> <decoded-length> > out
//!
//! Exits 1 on a usage or codec error and prints the error name to stderr.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;
const mem = std.mem;
const parseInt = std.fmt.parseInt;

const lz4 = @import("compress").lz4;

const max_input_len = 1 << 30;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        print("usage: lz4-oracle encode <input-file> > block\n", .{});
        print("       lz4-oracle decode <block-file> <decoded-length> > out\n", .{});
        return 1;
    }

    const file = try Io.Dir.cwd().openFile(io, args[2], .{
        .allow_directory = false,
        .follow_symlinks = true,
    });
    var read_buffer: [64 * 1024]u8 = undefined;
    var file_reader: Io.File.Reader = .init(file, io, &read_buffer);
    const source = try file_reader.interface.allocRemaining(arena, .limited(max_input_len));

    var write_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &write_buffer);
    defer stdout_writer.interface.flush() catch {};

    if (mem.eql(u8, args[1], "encode")) {
        if (args.len != 3) return 1;
        const target = try arena.alloc(u8, lz4.encode.maxCompressedLength(source.len));
        const written = lz4.encode.compressBlock(source, target) catch |err| {
            print("lz4-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        try stdout_writer.interface.writeAll(target[0..written]);
        return 0;
    }

    if (mem.eql(u8, args[1], "decode")) {
        if (args.len != 4) return 1;
        const decoded_len = parseInt(usize, args[3], 10) catch {
            print("lz4-oracle: decoded length must be a byte count\n", .{});
            return 1;
        };
        const target = try arena.alloc(u8, decoded_len);
        const written = lz4.decode.decompressBlock(source, target) catch |err| {
            print("lz4-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        try stdout_writer.interface.writeAll(target[0..written]);
        return 0;
    }

    print("lz4-oracle: unknown command '{s}'\n", .{args[1]});
    return 1;
}
