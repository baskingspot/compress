//! The command-line harness behind `just snappy-oracle`, which checks the
//! framed stream against klauspost/compress's snappy-compatible s2 writer and
//! reader (the driver is scripts/snappy_oracle.py). A test tool, not part of
//! the codec: it allocates freely, from an arena.
//!
//! Usage:
//!   snappy-oracle encode <input-file> > stream
//!   snappy-oracle decode <stream-file> > out
//!
//! `encode` writes our framed stream for the input file; `decode` decodes one
//! framed stream to stdout. Exits 1 on a usage or codec error and prints the
//! error name to stderr.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const snappy = @import("compress").snappy;

/// Cap on the stream or input the harness will read into memory.
const max_len = 1 << 30;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        print(
            "usage: snappy-oracle encode <input-file> > stream\n" ++
                "       snappy-oracle decode <stream-file> > out\n",
            .{},
        );
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

    if (std.mem.eql(u8, args[1], "encode")) {
        _ = snappy.Writer.streamAll(&file_reader.interface, &stdout_writer.interface) catch |err| {
            print("snappy-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        return 0;
    }
    if (std.mem.eql(u8, args[1], "decode")) {
        _ = snappy.Reader.streamAll(&file_reader.interface, &stdout_writer.interface) catch |err| {
            print("snappy-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        return 0;
    }
    print("snappy-oracle: unknown command '{s}'\n", .{args[1]});
    return 1;
}
