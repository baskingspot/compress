//! gzip benchmarks: `zig build bench -Doptimize=ReleaseFast`, or for benchstat
//! input `... -- --count=10 > bench.txt`. Throughput is MB/s over the
//! *uncompressed* size, so compress and decompress rows compare directly.
//!
//! The rows cover the one-shot path (`BenchmarkGzipCompress`,
//! `BenchmarkGzipDecompress`, `BenchmarkGzipRatio`) over the same shapes as
//! flate's bench, plus paired raw-flate rows (`BenchmarkFlateCompress`,
//! `BenchmarkFlateDecompress`) over the same corpus and level. The difference
//! between a gzip row and its flate row is the container's cost: the 18 bytes
//! of framing and the CRC-32 pass.
//!
//! Compare a gzip row only with the flate row from this same binary. The `Gzip`
//! prefix keeps these rows from colliding with flate's own bench rows in a
//! combined report, and flate's own bench binary is not comparable: its
//! encoder's code generation changes with the rest of the binary (LLVM's
//! inlining of the bit-writer state moves the `random` shape by about 2x).

const std = @import("std");
const Allocator = std.mem.Allocator;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const bench = @import("benchmark");
const flate = @import("compress").flate;
const gzip = @import("compress").gzip;

/// Input corpus shapes, the same set the flate bench uses.
const Shape = enum {
    text, // repetitive English-ish text (highly compressible)
    random, // PRNG bytes (incompressible -> stored blocks)
    html, // tag-heavy markup (compressible, short matches)
    rle, // single-byte run (extreme RLE)
    mixed, // structured + random (realistic-ish record batch)
};

/// The two input sizes: the encoder's block size (65535, rounded to 64 KiB)
/// and half of it.
const Size = enum {
    half,
    block,

    fn len(size: Size) usize {
        return switch (size) {
            .half => 32 * 1024,
            .block => 64 * 1024,
        };
    }

    fn name(comptime size: Size) []const u8 {
        return switch (size) {
            .half => "32K",
            .block => "64K",
        };
    }
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
            for (buf) |*byte| byte.* = rng.random().int(u8);
        },
        .html => {
            const phrase = "<div class=\"row\"><span>hello</span><span>gzip</span></div>";
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
            for (buf, 0..) |*byte, i| {
                byte.* = @truncate(rng.random().int(u8) ^ @as(u8, @truncate(i)));
            }
        },
    }
    return buf;
}

fn shapeName(comptime shape: Shape) []const u8 {
    return switch (shape) {
        .text => "text",
        .random => "random",
        .html => "html",
        .rle => "rle",
        .mixed => "mixed",
    };
}

/// `64K/text`, so a benchstat run lines the sizes up per shape.
fn caseName(comptime size: Size, comptime shape: Shape) []const u8 {
    return comptime size.name() ++ "/" ++ shapeName(shape);
}

/// The gzip one-shot encoder. Reports MB/s over the uncompressed input.
/// (`Gzip` prefix: this binary's rows must not collide with flate's own
/// bench rows — see the file header.)
pub fn benchmarkGzipCompress(b: *bench.B) !void {
    inline for (.{ Size.half, Size.block }) |size| {
        inline for (.{ Shape.text, Shape.random, Shape.html, Shape.rle, Shape.mixed }) |shape| {
            _ = try b.run(caseName(size, shape), struct {
                fn run(bb: *bench.B) !void {
                    const input = try makeShape(bb.allocator, shape, size.len());
                    defer bb.allocator.free(input);
                    const bound = gzip.encode.maxCompressedLength(input.len);
                    const comp = try bb.allocator.alloc(u8, bound);
                    defer bb.allocator.free(comp);

                    while (try bb.loop()) {
                        const n = try gzip.encode.compress(input, comp, .{});
                        bb.keepAlive(n);
                    }
                    bb.setBytes(@intCast(input.len));
                }
            }.run);
        }
    }
}

/// The gzip one-shot decoder. The member is prepared once (outside the timed
/// loop), then decompressed repeatedly. Reports MB/s over the decompressed
/// size.
pub fn benchmarkGzipDecompress(b: *bench.B) !void {
    inline for (.{ Size.half, Size.block }) |size| {
        inline for (.{ Shape.text, Shape.random, Shape.html, Shape.rle, Shape.mixed }) |shape| {
            _ = try b.run(caseName(size, shape), struct {
                fn run(bb: *bench.B) !void {
                    const input = try makeShape(bb.allocator, shape, size.len());
                    defer bb.allocator.free(input);
                    const bound = gzip.encode.maxCompressedLength(input.len);
                    const comp = try bb.allocator.alloc(u8, bound);
                    defer bb.allocator.free(comp);
                    const clen = try gzip.encode.compress(input, comp, .{});

                    const back = try bb.allocator.alloc(u8, input.len);
                    defer bb.allocator.free(back);

                    while (try bb.loop()) {
                        const n = try gzip.decode.decompress(comp[0..clen], back);
                        bb.keepAlive(n);
                    }
                    bb.setBytes(@intCast(input.len));
                }
            }.run);
        }
    }
}

/// Compression ratio (member / uncompressed) per size and shape, reported as
/// a custom metric. Not a timed loop — it runs once.
pub fn benchmarkGzipRatio(b: *bench.B) !void {
    inline for (.{ Size.half, Size.block }) |size| {
        inline for (.{ Shape.text, Shape.random, Shape.html, Shape.rle, Shape.mixed }) |shape| {
            _ = try b.run(caseName(size, shape), struct {
                fn run(bb: *bench.B) !void {
                    const input = try makeShape(bb.allocator, shape, size.len());
                    defer bb.allocator.free(input);
                    const bound = gzip.encode.maxCompressedLength(input.len);
                    const comp = try bb.allocator.alloc(u8, bound);
                    defer bb.allocator.free(comp);
                    const clen = try gzip.encode.compress(input, comp, .{});
                    const ratio = @as(f64, @floatFromInt(clen)) /
                        @as(f64, @floatFromInt(input.len));
                    try bb.reportMetric(ratio, "ratio");
                    // One iteration so the harness is happy; the metric is the point.
                    while (try bb.loop()) {
                        bb.keepAlive(clen);
                    }
                }
            }.run);
        }
    }
}

/// The paired raw-flate encoder over the same corpus and level: the delta
/// against `BenchmarkGzipCompress` is the container's framing and checksum.
pub fn benchmarkFlateCompress(b: *bench.B) !void {
    inline for (.{ Size.half, Size.block }) |size| {
        inline for (.{ Shape.text, Shape.random, Shape.html, Shape.rle, Shape.mixed }) |shape| {
            _ = try b.run(caseName(size, shape), struct {
                fn run(bb: *bench.B) !void {
                    const input = try makeShape(bb.allocator, shape, size.len());
                    defer bb.allocator.free(input);
                    const bound = flate.encode.maxCompressedLength(input.len);
                    const comp = try bb.allocator.alloc(u8, bound);
                    defer bb.allocator.free(comp);

                    while (try bb.loop()) {
                        const n = try flate.encode.compress(input, comp, .{});
                        bb.keepAlive(n);
                    }
                    bb.setBytes(@intCast(input.len));
                }
            }.run);
        }
    }
}

/// The paired raw-flate decoder over the same corpus and level: the delta
/// against `BenchmarkGzipDecompress` is the trailer verification (the CRC-32
/// rides flate's window fill; there is no second pass).
pub fn benchmarkFlateDecompress(b: *bench.B) !void {
    inline for (.{ Size.half, Size.block }) |size| {
        inline for (.{ Shape.text, Shape.random, Shape.html, Shape.rle, Shape.mixed }) |shape| {
            _ = try b.run(caseName(size, shape), struct {
                fn run(bb: *bench.B) !void {
                    const input = try makeShape(bb.allocator, shape, size.len());
                    defer bb.allocator.free(input);
                    const bound = flate.encode.maxCompressedLength(input.len);
                    const comp = try bb.allocator.alloc(u8, bound);
                    defer bb.allocator.free(comp);
                    const clen = try flate.encode.compress(input, comp, .{});

                    const back = try bb.allocator.alloc(u8, input.len);
                    defer bb.allocator.free(back);

                    while (try bb.loop()) {
                        const n = try flate.decode.decompress(comp[0..clen], back, null);
                        bb.keepAlive(n);
                    }
                    bb.setBytes(@intCast(input.len));
                }
            }.run);
        }
    }
}
