//! The command-line harness behind `just brotli-oracle`, which checks this
//! codec against the pinned reference CLI (brotli 1.2.0) in the only
//! direction the codec has: decode (the driver is scripts/brotli_oracle.py).
//! A test tool, not part of the codec: it allocates freely, from an arena.
//!
//! Usage:
//!   brotli-oracle decode <stream-file> <cap-bytes> > out
//!
//! `decode` writes the decoded bytes of one brotli stream to stdout, with the
//! output capped at `cap-bytes`. Exits 1 on a usage or codec error and prints
//! the error name to stderr.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const brotli = @import("zcompress").brotli;

/// Cap on the compressed stream the harness will read into memory.
const max_stream_len = 1 << 30;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4 or !std.mem.eql(u8, args[1], "decode")) {
        print("usage: brotli-oracle decode <stream-file> <cap-bytes> > out\n", .{});
        return 1;
    }

    const cap = std.fmt.parseInt(usize, args[3], 10) catch {
        print("brotli-oracle: cap must be a byte count, got '{s}'\n", .{args[3]});
        return 1;
    };
    const file = try Io.Dir.cwd().openFile(io, args[2], .{
        .allow_directory = false,
        .follow_symlinks = true,
    });
    var read_buffer: [64 * 1024]u8 = undefined;
    var file_reader: Io.File.Reader = .init(file, io, &read_buffer);

    var write_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &write_buffer);
    defer stdout_writer.interface.flush() catch {};

    const source = try file_reader.interface.allocRemaining(arena, .limited(max_stream_len));
    const target = try arena.alloc(u8, cap);

    const decoded_len = brotli.decode.decompress(source, target) catch |err| {
        print("brotli-oracle: {s}\n", .{@errorName(err)});
        return 1;
    };
    try stdout_writer.interface.writeAll(target[0..decoded_len]);
    return 0;
}
