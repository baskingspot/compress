//! The command-line harness behind `just brotli-oracle`, which checks this
//! codec against the pinned reference CLI (brotli 1.2.0): the decode
//! direction (the driver is scripts/brotli_oracle.py) and, since the encoder
//! landed, the encode direction — the one-shot against the CLI's file form,
//! byte for byte. A test tool, not part of the codec: it allocates freely,
//! from an arena.
//!
//! Usage:
//!   brotli-oracle decode <stream-file> <cap-bytes> > out
//!   brotli-oracle stream <stream-file> <window-wbits> > out
//!   brotli-oracle encode <input-file> [quality] > stream
//!   brotli-oracle encode-stream <input-file> <window-wbits> > stream
//!
//! `decode` writes the decoded bytes of one brotli stream to stdout, with the
//! output capped at `cap-bytes` (the one-shot). `stream` pumps the same file
//! through `brotli.Reader.streamAll` with a `Buffer(window-wbits)`: every
//! concatenated stream is decoded, and the reader's ring, window cap, and
//! input seams are the ones under test. `encode` writes the one-shot
//! encoder's stream for the input file (quality 3 unless given). Exits 1 on a
//! usage or codec error and prints the error name to stderr.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const brotli = @import("compress").brotli;

/// Cap on the compressed stream the harness will read into memory.
const max_stream_len = 1 << 30;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3 and args.len != 4) {
        print("usage: brotli-oracle decode|stream <file> <cap-or-wbits> > out\n" ++
            "       brotli-oracle encode <input-file> > stream\n" ++
            "       brotli-oracle encode-stream <input-file> <window-wbits> > stream\n", .{});
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
        const source = try file_reader.interface.allocRemaining(arena, .limited(max_stream_len));
        const cap = brotli.encode.maxCompressedLength(source.len);
        const target = try arena.alloc(u8, cap);
        const written = brotli.encode.compress(source, target) catch |err| {
            print("brotli-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        try stdout_writer.interface.writeAll(target[0..written]);
        return 0;
    }

    if (std.mem.eql(u8, args[1], "encode-stream")) {
        const wbits = std.fmt.parseInt(usize, args[3], 10) catch 0;
        switch (wbits) {
            inline 10...24 => |w| {
                const buffer = try arena.create(brotli.Writer.Buffer(w));
                _ = brotli.Writer.streamAll(
                    w,
                    &file_reader.interface,
                    &stdout_writer.interface,
                    buffer,
                ) catch |err| {
                    print("brotli-oracle: {s}\n", .{@errorName(err)});
                    return 1;
                };
                return 0;
            },
            else => {
                print("brotli-oracle: window_wbits must be 10..24, got {d}\n", .{wbits});
                return 1;
            },
        }
    }

    if (std.mem.eql(u8, args[1], "decode")) {
        const cap = std.fmt.parseInt(usize, args[3], 10) catch {
            print("brotli-oracle: cap must be a byte count, got '{s}'\n", .{args[3]});
            return 1;
        };
        const source = try file_reader.interface.allocRemaining(arena, .limited(max_stream_len));
        const target = try arena.alloc(u8, cap);
        const decoded_len = brotli.decode.decompress(source, target) catch |err| {
            print("brotli-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        try stdout_writer.interface.writeAll(target[0..decoded_len]);
        return 0;
    }

    if (std.mem.eql(u8, args[1], "stream")) {
        const wbits = std.fmt.parseInt(usize, args[3], 10) catch {
            print("brotli-oracle: window_wbits must be 10..24, got '{s}'\n", .{args[3]});
            return 1;
        };
        switch (wbits) {
            inline 10...24 => |w| {
                const buffer = try arena.create(brotli.Reader.Buffer(w));
                _ = brotli.Reader.streamAll(
                    w,
                    &file_reader.interface,
                    &stdout_writer.interface,
                    buffer,
                ) catch |err| {
                    print("brotli-oracle: {s}\n", .{@errorName(err)});
                    return 1;
                };
                return 0;
            },
            else => {
                print("brotli-oracle: window_wbits must be 10..24, got {d}\n", .{wbits});
                return 1;
            },
        }
    }

    print("usage: brotli-oracle decode|stream <file> <cap-or-wbits> > out\n" ++
        "       brotli-oracle encode <input-file> > stream\n" ++
        "       brotli-oracle encode-stream <input-file> <window-wbits> > stream\n", .{});
    return 1;
}
