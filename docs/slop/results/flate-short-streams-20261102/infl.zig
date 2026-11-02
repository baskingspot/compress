const std = @import("std");
const zlib = @import("compress").zlib;
const linux = std.os.linux;

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

var window: zlib.Reader.Buffer = undefined;

fn readFile(path: [*:0]const u8, buf: []u8) usize {
    const fd: i32 = @intCast(linux.open(path, .{}, 0));
    var n: usize = 0;
    while (true) {
        const r = linux.read(fd, buf[n..].ptr, buf.len - n);
        if (r == 0 or @as(isize, @bitCast(r)) < 0) break;
        n += r;
    }
    _ = linux.close(fd);
    return n;
}

/// A `.zs` file: records of a u32 little-endian length and a zlib stream,
/// a TIFF's strips; anything else is one stream.
var multi = false;

fn decodeAll(data: []const u8) usize {
    if (!multi) return decodeOnce(data);
    var total: usize = 0;
    var at: usize = 0;
    while (at < data.len) {
        const n = std.mem.readInt(u32, data[at..][0..4], .little);
        total += decodeOnce(data[at + 4 ..][0..n]);
        at += 4 + n;
    }
    return total;
}

fn decodeOnce(data: []const u8) usize {
    var in: std.Io.Reader = .fixed(data);
    var zr: zlib.Reader = .init(&in, &window, null);
    var total: usize = 0;
    while (true) {
        const got = zr.reader.peekGreedy(1) catch |e| switch (e) {
            error.EndOfStream => break,
            else => @panic("decode failed"),
        };
        total += got.len;
        zr.reader.toss(got.len);
    }
    return total;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var it = init.args.iterate();
    _ = it.next();
    const buf = try std.heap.page_allocator.alloc(u8, 64 << 20);
    while (it.next()) |path| {
        const n = readFile(path.ptr, buf);
        const data = buf[0..n];
        multi = std.mem.endsWith(u8, path, ".zs");
        const out = decodeAll(data);
        const iters: usize = @max(1, 30_000_000 / out);
        var best: u64 = std.math.maxInt(u64);
        for (0..9) |_| {
            const t0 = now();
            for (0..iters) |_| std.mem.doNotOptimizeAway(decodeAll(data));
            best = @min(best, (now() - t0) / iters);
        }
        const name = std.fs.path.basename(path);
        std.debug.print("{s}\t{d:.1}\tMB/s\t{d}\tns\n", .{ name, @as(f64, @floatFromInt(out)) * 1000.0 / @as(f64, @floatFromInt(best)), best });
    }
}
