//! zstd codec benchmarks. Run with `zig build bench -Doptimize=ReleaseFast`.
//!
//! The decode rows decode a reference frame written by the zstd CLI v1.5.7
//! over the shared corpus shapes (level 1, except the entropy shapes in
//! `Shape`); the compress rows are the mirror: the one-shot encoder (the
//! CLI's level-1 class) over the raw shapes. `just corpus` generates the
//! corpus into `bench/corpus-gen/`, and the harness in `bench/` runs the
//! same files, so a local row and a harness row measure the same input.
//! Throughput is MB/s over the *decompressed* size.
//!
//! Output is benchstat-friendly:
//! `zig build bench -Doptimize=ReleaseFast -- --count=10 > bench.txt`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const bench = @import("benchmark");
const zstd = @import("zcompress").zstd;

/// The corpus shapes: the same set as the corpus generator
/// (`bench/zig/corpus.zig`) and the other codecs' benches. The entropy pair
/// (`words`, `skewlit`) is generated at CLI level 19, so its frames carry
/// Huffman-coded literals; the other shapes are level 1.
const Shape = enum {
    text,
    random,
    html,
    rle,
    mixed,
    words,
    skewlit,
};

/// The two corpus sizes.
const Size = enum {
    half,
    full,

    fn len(comptime size: Size) usize {
        return switch (size) {
            .half => 32 * 1024,
            .full => 64 * 1024,
        };
    }
};

/// The generated corpus directory (`just corpus`; gitignored).
const corpus_dir = "bench/corpus-gen";

/// `64K/text`, so a benchstat run lines the sizes up per shape.
fn caseName(comptime size: Size, comptime shape: Shape) []const u8 {
    return switch (size) {
        .half => "32K/",
        .full => "64K/",
    } ++ @tagName(shape);
}

/// Read one corpus file. Setup-only, never in the timed loop.
fn readCorpus(allocator: Allocator, io: Io, name: []const u8) ![]u8 {
    var dir = try Io.Dir.cwd().openDir(io, corpus_dir, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, name, allocator, .unlimited);
}

/// Compress benchmarks: one sub-benchmark per corpus case. The raw shape is
/// loaded once and the one-shot output is verified once (the frame must
/// decode back to the raw shape, as in the `bench/` harness's warmup), then
/// the raw shape is compressed repeatedly. Reports MB/s over the
/// uncompressed input.
pub fn benchmarkZstdCompress(b: *bench.B) !void {
    inline for (.{ Size.half, Size.full }) |size| {
        inline for (std.enums.values(Shape)) |shape| {
            _ = try b.run(caseName(size, shape), struct {
                fn run(bb: *bench.B) !void {
                    var threaded: Io.Threaded = .init_single_threaded;
                    const io = threaded.io();
                    const base = @tagName(shape) ++ switch (size) {
                        .half => "-32768",
                        .full => "-65536",
                    };
                    const raw = try readCorpus(bb.allocator, io, base);
                    defer bb.allocator.free(raw);
                    const bound = zstd.encode.maxCompressedLength(raw.len);
                    const comp = try bb.allocator.alloc(u8, bound);
                    defer bb.allocator.free(comp);
                    const back = try bb.allocator.alloc(u8, raw.len);
                    defer bb.allocator.free(back);
                    // The one-shot's frame must round trip to the raw shape.
                    const clen = try zstd.encode.compress(raw, comp, .{});
                    const verified = try zstd.decode.decompress(comp[0..clen], back);
                    if (verified != raw.len or !std.mem.eql(u8, back, raw))
                        return error.CorpusMismatch;

                    while (try bb.loop()) {
                        const n = try zstd.encode.compress(raw, comp, .{});
                        bb.keepAlive(n);
                    }
                    bb.setBytes(@intCast(raw.len));
                }
            }.run);
        }
    }
}

/// Decompress benchmarks: one sub-benchmark per corpus case. The frame is
/// loaded and checked once (the decode must reproduce the raw shape exactly,
/// as in the `bench/` harness), then decoded repeatedly.
pub fn benchmarkZstdDecompress(b: *bench.B) !void {
    inline for (.{ Size.half, Size.full }) |size| {
        inline for (std.enums.values(Shape)) |shape| {
            _ = try b.run(caseName(size, shape), struct {
                fn run(bb: *bench.B) !void {
                    var threaded: Io.Threaded = .init_single_threaded;
                    const io = threaded.io();
                    const base = @tagName(shape) ++ switch (size) {
                        .half => "-32768",
                        .full => "-65536",
                    };
                    const raw = try readCorpus(bb.allocator, io, base);
                    defer bb.allocator.free(raw);
                    const blob = try readCorpus(bb.allocator, io, base ++ ".zst");
                    defer bb.allocator.free(blob);
                    const back = try bb.allocator.alloc(u8, raw.len);
                    defer bb.allocator.free(back);
                    // The reference blob must decode to the raw shape.
                    const verified = try zstd.decode.decompress(blob, back);
                    if (verified != raw.len or !std.mem.eql(u8, back, raw))
                        return error.CorpusMismatch;

                    while (try bb.loop()) {
                        const n = try zstd.decode.decompress(blob, back);
                        bb.keepAlive(n);
                    }
                    bb.setBytes(@intCast(raw.len));
                }
            }.run);
        }
    }
}
