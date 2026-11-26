//! LZ4 block codec benchmarks. Run with `zig build bench`.
//!
//! Covers compress, decompress, and compression ratio across five input shapes
//! at the 64 KiB journal-record size. Throughput is MB/s over uncompressed
//! bytes, so compress and decompress are directly comparable.
//!
//! Output is benchstat-friendly:
//! `zig build bench -- --count=10 > bench.txt`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const testingx = @import("testingx");
const lz4 = @import("compress").lz4;

pub fn benchmarkMain(b: *testingx.B) !void {
    try b.add("Compress", benchmarkCompress);
    try b.add("Decompress", benchmarkDecompress);
    try b.add("Ratio", benchmarkRatio);
}

const Shape = enum {
    text,
    random,
    html,
    rle,
    mixed,
};

fn makeShape(allocator: Allocator, shape: Shape, len: usize) ![]u8 {
    const buf = try allocator.alloc(u8, len);
    switch (shape) {
        .text => {
            const phrase = "the quick brown fox jumps over the lazy dog. ";
            var i: usize = 0;
            while (i < len) {
                const n = @min(phrase.len, len - i);
                fastmem.copy(u8, buf[i..][0..n], phrase[0..n]);
                i += n;
            }
        },
        .random => {
            var rng: DefaultPrng = .init(0xC0FFEE);
            rng.random().bytes(buf);
        },
        .html => {
            const phrase = "<div class=\"row\"><span>hello</span><span>lz4</span></div>";
            var i: usize = 0;
            while (i < len) {
                const n = @min(phrase.len, len - i);
                fastmem.copy(u8, buf[i..][0..n], phrase[0..n]);
                i += n;
            }
        },
        .rle => fastmem.set(u8, buf, 0x41),
        .mixed => {
            var rng: DefaultPrng = .init(0x5A4BEEF);
            const random = rng.random();
            var i: usize = 0;
            while (i < len) {
                const n = @min(random.intRangeAtMost(usize, 1, 128), len - i);
                if (random.boolean()) {
                    fastmem.set(u8, buf[i..][0..n], random.int(u8));
                } else {
                    random.bytes(buf[i..][0..n]);
                }
                i += n;
            }
        },
    }
    return buf;
}

fn shapeName(shape: Shape) []const u8 {
    return switch (shape) {
        .text => "text",
        .random => "random",
        .html => "html",
        .rle => "rle",
        .mixed => "mixed",
    };
}

pub fn benchmarkCompress(b: *testingx.B) !void {
    inline for (.{ Shape.text, Shape.random, Shape.html, Shape.rle, Shape.mixed }) |shape| {
        _ = try b.run(shapeName(shape), struct {
            fn run(bb: *testingx.B) !void {
                const input = try makeShape(bb.allocator, shape, 64 * 1024);
                defer bb.allocator.free(input);
                const target = try bb.allocator.alloc(
                    u8,
                    lz4.encode.maxCompressedLength(input.len),
                );
                defer bb.allocator.free(target);

                while (try bb.loop()) {
                    const n = try lz4.encode.compressBlock(input, target);
                    bb.keepAlive(n);
                }
                bb.setBytes(@intCast(input.len));
            }
        }.run);
    }
}

pub fn benchmarkDecompress(b: *testingx.B) !void {
    inline for (.{ Shape.text, Shape.random, Shape.html, Shape.rle, Shape.mixed }) |shape| {
        _ = try b.run(shapeName(shape), struct {
            fn run(bb: *testingx.B) !void {
                const input = try makeShape(bb.allocator, shape, 64 * 1024);
                defer bb.allocator.free(input);
                const target = try bb.allocator.alloc(
                    u8,
                    lz4.encode.maxCompressedLength(input.len),
                );
                defer bb.allocator.free(target);
                const compressed_len = try lz4.encode.compressBlock(input, target);
                const decoded = try bb.allocator.alloc(u8, input.len);
                defer bb.allocator.free(decoded);

                while (try bb.loop()) {
                    const n = try lz4.decode.decompressBlock(
                        target[0..compressed_len],
                        decoded,
                    );
                    bb.keepAlive(n);
                }
                bb.setBytes(@intCast(input.len));
            }
        }.run);
    }
}

pub fn benchmarkRatio(b: *testingx.B) !void {
    inline for (.{ Shape.text, Shape.random, Shape.html, Shape.rle, Shape.mixed }) |shape| {
        _ = try b.run(shapeName(shape), struct {
            fn run(bb: *testingx.B) !void {
                const input = try makeShape(bb.allocator, shape, 64 * 1024);
                defer bb.allocator.free(input);
                const target = try bb.allocator.alloc(
                    u8,
                    lz4.encode.maxCompressedLength(input.len),
                );
                defer bb.allocator.free(target);
                const compressed_len = try lz4.encode.compressBlock(input, target);
                const ratio = @as(f64, @floatFromInt(compressed_len)) /
                    @as(f64, @floatFromInt(input.len));
                while (try bb.loop()) {
                    bb.keepAlive(compressed_len);
                }
                // The harness resets per-iteration metrics in `loop`; report
                // after the final iteration so the ratio survives to the row.
                try bb.reportMetric(ratio, "ratio");
            }
        }.run);
    }
}
