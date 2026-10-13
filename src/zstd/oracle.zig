//! Command-line harness behind `just zstd-oracle`, which cross-checks this
//! codec's encoder against the reference zstd CLI (v1.5.7) and
//! klauspost/compress; `scripts/zstd_oracle.py` drives it. It is a test
//! tool, not part of the codec: it reads whole files into an arena
//! allocator, which the codec itself never does.
//!
//! Usage:
//!   zstd-oracle encode-oneshot <input-file> > frame
//!   zstd-oracle encode-stream <input-file> > frame
//!   zstd-oracle decode <frame-file> <cap-bytes> > out
//!
//! `encode-oneshot` writes `zstd.encode.compress`'s frame (the exact
//! Frame_Content_Size header); `encode-stream` writes
//! `zstd.Writer.streamAll`'s frame (the FCS-unknown header the CLI writes
//! over a pipe). `decode` writes the decoded bytes of one frame, capped at
//! `cap-bytes`. Exit 1 on a codec error, with the error name on stderr.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const zstd = @import("zcompress").zstd;

/// Cap on the frame the harness will read into memory.
const max_frame_len = 1 << 30;
/// Cap on the uncompressed input the encoders will read.
const max_input_len = 1 << 30;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        print("usage: zstd-oracle encode-oneshot <input-file> > frame\n", .{});
        print("       zstd-oracle encode-stream <input-file> > frame\n", .{});
        print("       zstd-oracle decode <frame-file> <cap-bytes> > out\n", .{});
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

    if (std.mem.eql(u8, args[1], "encode-oneshot")) {
        if (args.len != 3) {
            print("zstd-oracle: encode-oneshot needs <input-file>\n", .{});
            return 1;
        }
        const source = try file_reader.interface.allocRemaining(arena, .limited(max_input_len));
        const target = try arena.alloc(u8, zstd.encode.maxCompressedLength(source.len));
        const frame_len = zstd.encode.compress(source, target, .{}) catch |err| {
            print("zstd-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        try stdout_writer.interface.writeAll(target[0..frame_len]);
        return 0;
    }

    if (std.mem.eql(u8, args[1], "encode-stream")) {
        if (args.len != 3) {
            print("zstd-oracle: encode-stream needs <input-file>\n", .{});
            return 1;
        }
        const source = try file_reader.interface.allocRemaining(arena, .limited(max_input_len));
        const buffer = try arena.create(zstd.Writer.DefaultBuffer);
        var in: Io.Reader = .fixed(source);
        _ = zstd.Writer.streamAll(
            zstd.Writer.default_window_log,
            &in,
            &stdout_writer.interface,
            buffer,
            .{},
        ) catch |err| {
            print("zstd-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        return 0;
    }

    if (std.mem.eql(u8, args[1], "decode")) {
        if (args.len != 4) {
            print("zstd-oracle: decode needs <frame-file> <cap-bytes>\n", .{});
            return 1;
        }
        const cap = std.fmt.parseInt(usize, args[3], 10) catch {
            print("zstd-oracle: cap must be a byte count, got '{s}'\n", .{args[3]});
            return 1;
        };
        const source = try file_reader.interface.allocRemaining(arena, .limited(max_frame_len));
        const target = try arena.alloc(u8, cap);
        const decoded_len = zstd.decode.decompress(source, target) catch |err| {
            print("zstd-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        try stdout_writer.interface.writeAll(target[0..decoded_len]);
        return 0;
    }

    print("zstd-oracle: unknown mode '{s}'\n", .{args[1]});
    return 1;
}
