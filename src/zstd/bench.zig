//! zstd decoder benchmarks. Run with `zig build bench -Doptimize=ReleaseFast`.
//!
//! Decode-only until M5 (there is no zcompress zstd encoder): the rows decode
//! the fleet corpus's reference frames — the pinned zstd CLI v1.5.7 at level 1
//! over the shared shapes, generated into `bench/corpus-gen/` by `just corpus`
//! — so the local rows are the fleet's `zstd/decompress` cells, byte for byte.
//! Throughput is MB/s over the *decompressed* size, the fleet's metric.
//!
//! Output is benchstat-friendly:
//! `zig build bench -Doptimize=ReleaseFast -- --count=10 > bench.txt`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const bench = @import("benchmark");
const zstd = @import("zcompress").zstd;

/// The corpus shapes, mirroring the fleet corpus generator
/// (bench/zig/corpus.zig) and the sibling codec benches.
const Shape = enum {
    text,
    random,
    html,
    rle,
    mixed,
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

/// Decompress benchmarks: one sub-benchmark per corpus case. The frame is
/// loaded and verified once (the decode must reproduce the raw shape exactly,
/// the fleet driver's own gate), then decoded repeatedly.
pub fn benchmarkZstdDecompress(b: *bench.B) !void {
    inline for (.{ Size.half, Size.full }) |size| {
        inline for (.{ Shape.text, Shape.random, Shape.html, Shape.rle, Shape.mixed }) |shape| {
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
                    // The fleet gate: the reference blob decodes to the raw shape.
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
