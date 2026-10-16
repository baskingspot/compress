//! A 32-bit check for `zstd.Reader`. It decodes two frames whose output is
//! more than 2^32 bytes on a target where `usize` is 32 bits, the only place
//! the counters that must not wrap can be seen wrapping: `frame.State.decoded_len`
//! and the XXH64 byte count.
//!
//! Run it with `just check-32`. The file is built as `zig-out/bin/zstd-probe32.wasm`
//! (wasm32-wasi, ReleaseSafe, so a wrap panics) and run under wasmtime. A 64-bit
//! host cannot show either wrap, and `just check-baseline` only compiles for the
//! other targets. The frames and the drain loop mirror the `Reader.zig` tests "the
//! frame total runs past 2^32 without wrapping" and "the checksum fold runs past
//! 2^32 without wrapping". The probe checks its own results and exits nonzero on
//! failure.

const std = @import("std");
const Io = std.Io;

const fastmem = @import("fastmem");

const zstd = @import("compress").zstd;
const Reader = zstd.Reader;

const print = std.debug.print;

/// 32,770 RLE blocks of 128 KiB: a 131 KB input decoding to
/// 4,295,229,440 bytes — 262,144 past 2^32.
const block_count = 32_770;
const block_size = 128 * 1024;

var frame_buf: [6 + 4 * block_count + 4]u8 = undefined;
var window: Reader.Buffer(128 * 1024) = undefined;

fn buildFrame(checksum: bool) []const u8 {
    fastmem.copy(u8, frame_buf[0..4], &[_]u8{ 0x28, 0xB5, 0x2F, 0xFD });
    frame_buf[4] = if (checksum) 0x04 else 0x00;
    frame_buf[5] = 0x38; // Window_Descriptor: exponent 7, mantissa 0.
    var at: usize = 6;
    var block_index: usize = 0;
    while (block_index < block_count) : (block_index += 1) {
        const last: u24 = if (block_index + 1 == block_count) 1 else 0;
        const header: u24 = last | (1 << 1) | (@as(u24, block_size) << 3);
        frame_buf[at] = @truncate(header);
        frame_buf[at + 1] = @truncate(header >> 8);
        frame_buf[at + 2] = @truncate(header >> 16);
        frame_buf[at + 3] = 0x5A;
        at += 4;
    }
    if (checksum) {
        // The low 32 bits of XXH64 over the decoded 0x5A bytes,
        // little-endian (the value the pinned CLI's checksum produces).
        fastmem.copy(u8, frame_buf[at..][0..4], &[_]u8{ 0x5E, 0x4A, 0x49, 0xB7 });
        at += 4;
    }
    return frame_buf[0..at];
}

/// Reads `r` to its end and adds up the bytes served. Each call's count fits a
/// `usize`; only the total needs 64 bits.
fn drain(r: *Reader, served: *u64) !void {
    var sink: Io.Writer.Discarding = .init(&.{});
    while (true) {
        const n = r.reader.stream(&sink.writer, .unlimited) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        served.* += n;
    }
}

fn check(comptime what: []const u8, checksum: bool) !void {
    const bytes = buildFrame(checksum);
    var fixed_in: Io.Reader = .fixed(bytes);
    var r: Reader = .init(128 * 1024, &fixed_in, &window, null);
    var served: u64 = 0;
    try drain(&r, &served);
    const expected: u64 = @as(u64, block_count) * block_size;
    if (served != expected) {
        print("{s}: served {d}, expected {d}\n", .{ what, served, expected });
        return error.ProbeFailed;
    }
    if (fixed_in.seek != bytes.len) {
        print("{s}: input seek {d}, expected {d}\n", .{ what, fixed_in.seek, bytes.len });
        return error.ProbeFailed;
    }
    if (r.err != null) {
        print("{s}: reader detail {s}\n", .{ what, @errorName(r.err.?) });
        return error.ProbeFailed;
    }
    print("{s}: OK ({d} bytes, usize is {d} bits)\n", .{ what, served, @bitSizeOf(usize) });
}

pub fn main() !u8 {
    try check("frame total past 2^32", false);
    try check("checksum fold past 2^32", true);
    print("probe32: both large-total frames verified on this target\n", .{});
    return 0;
}
