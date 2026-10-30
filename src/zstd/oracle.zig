//! Command-line harness behind `just zstd-oracle`, which cross-checks this
//! codec's encoder against the reference zstd CLI (v1.5.7) and
//! klauspost/compress; `scripts/zstd_oracle.py` drives it. It is a test
//! tool, not part of the codec: it reads whole files into an arena
//! allocator, which the codec itself never does.
//!
//! Usage:
//!   zstd-oracle encode-oneshot <input-file> [level] > frame
//!   zstd-oracle encode-stream <input-file> [level] > frame
//!   zstd-oracle encode-dict <input-file> <dict-file> [level] > frame
//!   zstd-oracle encode-raw-dict <input-file> <content-file> > frame
//!   zstd-oracle encode-stream-dict <input-file> <dict-file> > frame
//!   zstd-oracle decode <frame-file> <cap-bytes> > out
//!   zstd-oracle decode-dict <frame-file> <cap-bytes> <dict-file> > out
//!   zstd-oracle decode-raw <frame-file> <cap-bytes> <content-file> > out
//!
//! `encode-oneshot` writes `zstd.encode.compress`'s frame (the exact
//! Frame_Content_Size header); `encode-stream` writes
//! `zstd.Writer.streamAll`'s frame (the FCS-unknown header the CLI writes
//! over a pipe). The optional `level` is the CLI's scale (1 by default); a
//! level-3 `encode-stream` takes the class's window (21). `decode` writes the
//! decoded bytes of one frame, capped at `cap-bytes`; `decode-dict` is the
//! same with a formatted dictionary (`§5`) parsed from the third file,
//! `decode-raw` with format-free content handed to `Dictionary.initRaw`.
//! Exit 1 on a codec error, with the error name on stderr.

const std = @import("std");
const Io = std.Io;
const print = std.debug.print;

const zstd = @import("compress").zstd;

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

    if (std.mem.eql(u8, args[1], "encode-dict") or
        std.mem.eql(u8, args[1], "encode-raw-dict") or
        std.mem.eql(u8, args[1], "encode-stream-dict"))
    {
        if (args.len != 4 and args.len != 5) {
            print("zstd-oracle: {s} needs <input-file> <dict-file> [level]\n", .{args[1]});
            return 1;
        }
        const level: zstd.encode.Level = if (args.len == 5) try parseLevel(args[4]) else .@"1";
        const dict_file = try Io.Dir.cwd().openFile(io, args[3], .{
            .allow_directory = false,
            .follow_symlinks = true,
        });
        var dict_buffer: [64 * 1024]u8 = undefined;
        var dict_reader: Io.File.Reader = .init(dict_file, io, &dict_buffer);
        const dict_source = try dict_reader.interface.allocRemaining(
            arena,
            .limited(max_input_len),
        );
        const dict = if (std.mem.eql(u8, args[1], "encode-raw-dict"))
            zstd.Dictionary.initRaw(dict_source)
        else
            zstd.Dictionary.parse(dict_source) catch |err| {
                print("zstd-oracle: dictionary parse: {s}\n", .{@errorName(err)});
                return 1;
            };
        const source = try file_reader.interface.allocRemaining(arena, .limited(max_input_len));
        if (!std.mem.eql(u8, args[1], "encode-stream-dict")) {
            const target = try arena.alloc(u8, zstd.encode.maxCompressedLength(source.len));
            const frame_len = zstd.encode.compress(source, target, .{
                .level = level,
                .dict = &dict,
            }) catch |err| {
                print("zstd-oracle: {s}\n", .{@errorName(err)});
                return 1;
            };
            try stdout_writer.interface.writeAll(target[0..frame_len]);
            return 0;
        }
        const buffer = try arena.create(zstd.Writer.DefaultBuffer);
        var in: Io.Reader = .fixed(source);
        _ = zstd.Writer.streamAll(
            zstd.Writer.default_window_log,
            &in,
            &stdout_writer.interface,
            buffer,
            .{ .dict = &dict },
        ) catch |err| {
            print("zstd-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        return 0;
    }

    if (std.mem.eql(u8, args[1], "encode-oneshot")) {
        if (args.len != 3 and args.len != 4) {
            print("zstd-oracle: encode-oneshot needs <input-file> [level]\n", .{});
            return 1;
        }
        const level = if (args.len == 4) try parseLevel(args[3]) else .@"1";
        const source = try file_reader.interface.allocRemaining(arena, .limited(max_input_len));
        const target = try arena.alloc(u8, zstd.encode.maxCompressedLength(source.len));
        const frame_len = zstd.encode.compress(source, target, .{
            .level = level,
            .dict = null,
        }) catch |err| {
            print("zstd-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        try stdout_writer.interface.writeAll(target[0..frame_len]);
        return 0;
    }

    if (std.mem.eql(u8, args[1], "encode-stream")) {
        if (args.len != 3 and args.len != 4) {
            print("zstd-oracle: encode-stream needs <input-file> [level]\n", .{});
            return 1;
        }
        const level = if (args.len == 4) try parseLevel(args[3]) else .@"1";
        const source = try file_reader.interface.allocRemaining(arena, .limited(max_input_len));
        const options: zstd.encode.Options = .{ .level = level, .dict = null };
        var in: Io.Reader = .fixed(source);
        if (level == .@"3") {
            const buffer = try arena.create(
                zstd.Writer.Buffer(zstd.Writer.level3_default_window_log),
            );
            _ = zstd.Writer.streamAll(
                zstd.Writer.level3_default_window_log,
                &in,
                &stdout_writer.interface,
                buffer,
                options,
            ) catch |err| {
                print("zstd-oracle: {s}\n", .{@errorName(err)});
                return 1;
            };
        } else {
            const buffer = try arena.create(zstd.Writer.DefaultBuffer);
            _ = zstd.Writer.streamAll(
                zstd.Writer.default_window_log,
                &in,
                &stdout_writer.interface,
                buffer,
                options,
            ) catch |err| {
                print("zstd-oracle: {s}\n", .{@errorName(err)});
                return 1;
            };
        }
        return 0;
    }

    if (std.mem.eql(u8, args[1], "decode") or
        std.mem.eql(u8, args[1], "decode-dict") or
        std.mem.eql(u8, args[1], "decode-raw"))
    {
        const with_dict = !std.mem.eql(u8, args[1], "decode");
        const wanted: usize = if (with_dict) 5 else 4;
        if (args.len != wanted) {
            const suffix: []const u8 = if (with_dict) " <dict-file>" else "";
            print("zstd-oracle: {s} needs <frame-file> <cap-bytes>{s}\n", .{
                args[1],
                suffix,
            });
            return 1;
        }
        const cap = std.fmt.parseInt(usize, args[3], 10) catch {
            print("zstd-oracle: cap must be a byte count, got '{s}'\n", .{args[3]});
            return 1;
        };
        // The dictionary's bytes are read whole into the arena and parsed
        // once; the parse error vocabulary is the codec's own. `decode-raw`
        // takes format-free content instead (`initRaw`), which never fails.
        var dict: ?zstd.Dictionary = null;
        if (with_dict) {
            const dict_file = try Io.Dir.cwd().openFile(io, args[4], .{
                .allow_directory = false,
                .follow_symlinks = true,
            });
            var dict_buffer: [64 * 1024]u8 = undefined;
            var dict_reader: Io.File.Reader = .init(dict_file, io, &dict_buffer);
            const dict_source = try dict_reader.interface.allocRemaining(
                arena,
                .limited(max_input_len),
            );
            dict = if (std.mem.eql(u8, args[1], "decode-raw"))
                zstd.Dictionary.initRaw(dict_source)
            else
                zstd.Dictionary.parse(dict_source) catch |err| {
                    print("zstd-oracle: dictionary parse: {s}\n", .{@errorName(err)});
                    return 1;
                };
        }
        const source = try file_reader.interface.allocRemaining(arena, .limited(max_frame_len));
        const target = try arena.alloc(u8, cap);
        const decoded_len = zstd.decode.decompress(
            source,
            target,
            if (dict) |*d| d else null,
        ) catch |err| {
            print("zstd-oracle: {s}\n", .{@errorName(err)});
            return 1;
        };
        try stdout_writer.interface.writeAll(target[0..decoded_len]);
        return 0;
    }

    print("zstd-oracle: unknown mode '{s}'\n", .{args[1]});
    return 1;
}

/// Parse a CLI-scale level argument (1-19; `encode` gates the unimplemented ones).
fn parseLevel(text: []const u8) !zstd.encode.Level {
    const number = std.fmt.parseInt(u8, text, 10) catch {
        print("zstd-oracle: level must be 1 or 3, got '{s}'\n", .{text});
        return error.BadLevel;
    };
    return zstd.encode.Level.fromInt(number) orelse {
        print("zstd-oracle: level must be 1 or 3, got {d}\n", .{number});
        return error.BadLevel;
    };
}
