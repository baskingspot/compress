//! zlib benchmarks. Run with `zig build bench -Doptimize=ReleaseFast` (or
//! `just bench`).
//!
//! Rows cover one-shot compress, decompress, and ratio over the same shapes
//! as flate's bench, plus paired raw-flate rows over the same corpus and
//! level. The flate core dominates a zlib number; the difference between a
//! zlib row and its paired flate row is what the container adds: the 2-byte
//! header, the 4-byte trailer, and the Adler-32 pass. Throughput is MB/s over
//! the uncompressed size, so compress and decompress rows are comparable.
//!
//! The zlib rows carry a `Zlib` prefix (`BenchmarkZlibCompress/...`) because
//! each bench root builds its own binary, and an unprefixed
//! `BenchmarkCompress/32K/text` would collide with flate's own rows in a
//! combined report. Compare zlib rows only with the paired flate rows in this
//! same binary, never with flate's own bench binary: across binaries,
//! `flate.encode.compress` code generation changes with unrelated binary
//! composition (LLVM's inlining of the bit-writer state; the random shape
//! swings about 2x). Numbers from these rows are local measurements, not
//! performance claims.
//!
//! Output is benchstat-friendly:
//! `zig build bench -Doptimize=ReleaseFast -- --count=10 > bench.txt`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const DefaultPrng = std.Random.DefaultPrng;

const fastmem = @import("fastmem");

const bench = @import("benchmark");
const flate = @import("compress").flate;
const zlib = @import("compress").zlib;

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
            const phrase = "<div class=\"row\"><span>hello</span><span>zlib</span></div>";
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

/// The zlib one-shot encoder. Reports MB/s over the uncompressed input.
pub fn benchmarkZlibCompress(b: *bench.B) !void {
    inline for (.{ Size.half, Size.block }) |size| {
        inline for (.{ Shape.text, Shape.random, Shape.html, Shape.rle, Shape.mixed }) |shape| {
            _ = try b.run(caseName(size, shape), struct {
                fn run(bb: *bench.B) !void {
                    const input = try makeShape(bb.allocator, shape, size.len());
                    defer bb.allocator.free(input);
                    const bound = zlib.encode.maxCompressedLength(input.len);
                    const comp = try bb.allocator.alloc(u8, bound);
                    defer bb.allocator.free(comp);

                    while (try bb.loop()) {
                        const n = try zlib.encode.compress(input, comp, .{});
                        bb.keepAlive(n);
                    }
                    bb.setBytes(@intCast(input.len));
                }
            }.run);
        }
    }
}

/// The zlib one-shot decoder. The stream is prepared once (outside the timed
/// loop), then decompressed repeatedly. Reports MB/s over the decompressed
/// size.
pub fn benchmarkZlibDecompress(b: *bench.B) !void {
    inline for (.{ Size.half, Size.block }) |size| {
        inline for (.{ Shape.text, Shape.random, Shape.html, Shape.rle, Shape.mixed }) |shape| {
            _ = try b.run(caseName(size, shape), struct {
                fn run(bb: *bench.B) !void {
                    const input = try makeShape(bb.allocator, shape, size.len());
                    defer bb.allocator.free(input);
                    const bound = zlib.encode.maxCompressedLength(input.len);
                    const comp = try bb.allocator.alloc(u8, bound);
                    defer bb.allocator.free(comp);
                    const clen = try zlib.encode.compress(input, comp, .{});

                    const back = try bb.allocator.alloc(u8, input.len);
                    defer bb.allocator.free(back);

                    while (try bb.loop()) {
                        const n = try zlib.decode.decompress(comp[0..clen], back, null);
                        bb.keepAlive(n);
                    }
                    bb.setBytes(@intCast(input.len));
                }
            }.run);
        }
    }
}

/// Compression ratio (stream / uncompressed) per size and shape, reported as
/// a custom metric. Not a timed loop — it runs once.
pub fn benchmarkZlibRatio(b: *bench.B) !void {
    inline for (.{ Size.half, Size.block }) |size| {
        inline for (.{ Shape.text, Shape.random, Shape.html, Shape.rle, Shape.mixed }) |shape| {
            _ = try b.run(caseName(size, shape), struct {
                fn run(bb: *bench.B) !void {
                    const input = try makeShape(bb.allocator, shape, size.len());
                    defer bb.allocator.free(input);
                    const bound = zlib.encode.maxCompressedLength(input.len);
                    const comp = try bb.allocator.alloc(u8, bound);
                    defer bb.allocator.free(comp);
                    const clen = try zlib.encode.compress(input, comp, .{});
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
/// against `BenchmarkZlibCompress` is the container's framing and checksum.
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
/// against `BenchmarkZlibDecompress` is the trailer verification (the Adler-32
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
