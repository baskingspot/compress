const std = @import("std");
const zlib = @import("compress").zlib;
const linux = std.os.linux;

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

var window: zlib.Writer.Buffer = undefined;
var zw: zlib.Writer = undefined;
var outbuf: [1 << 20]u8 = undefined;

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

var level: zlib.encode.Level = .@"6";

/// Records of a u32 little-endian length and the raw bytes of a strip,
/// each encoded as its own zlib stream, as a TIFF encoder does.
fn encodeAll(data: []const u8) usize {
    var total: usize = 0;
    var at: usize = 0;
    while (at < data.len) {
        const n = std.mem.readInt(u32, data[at..][0..4], .little);
        var fixed: std.Io.Writer = .fixed(&outbuf);
        zw.initInPlace(&fixed, &window, .{ .level = level, .dict = null });
        zw.writer.writeAll(data[at + 4 ..][0..n]) catch @panic("write");
        zw.finish() catch @panic("finish");
        total += fixed.buffered().len;
        at += 4 + n;
    }
    return total;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var it = init.args.iterate();
    _ = it.next();
    const lv = it.next().?;
    level = if (std.mem.eql(u8, lv, "1")) .@"1" else if (std.mem.eql(u8, lv, "7")) .@"7" else .@"6";
    const buf = try std.heap.page_allocator.alloc(u8, 64 << 20);
    while (it.next()) |path| {
        const n = readFile(path.ptr, buf);
        const data = buf[0..n];
        var raw: usize = 0;
        var at: usize = 0;
        while (at < n) {
            const k = std.mem.readInt(u32, data[at..][0..4], .little);
            raw += k;
            at += 4 + k;
        }
        const iters: usize = @max(1, 8_000_000 / raw);
        var best: u64 = std.math.maxInt(u64);
        for (0..9) |_| {
            const t0 = now();
            for (0..iters) |_| std.mem.doNotOptimizeAway(encodeAll(data));
            best = @min(best, (now() - t0) / iters);
        }
        const name = std.fs.path.basename(path);
        std.debug.print("{s}\t{d:.1}\tMB/s\t{d}\tns\n", .{ name, @as(f64, @floatFromInt(raw)) * 1000.0 / @as(f64, @floatFromInt(best)), best });
    }
}
