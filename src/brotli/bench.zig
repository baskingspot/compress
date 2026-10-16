//! brotli codec benchmarks. Run with `zig build bench -Doptimize=ReleaseFast`.
//!
//! The rows decode the reference streams the brotli CLI 1.2.0 writes over the
//! shared corpus shapes at quality 11 (`just corpus` generates them into
//! `bench/corpus-gen/`); the harness in `bench/` runs the same files, so a
//! local row and a harness row measure the same input. Two rows per case:
//! the one-shot (`decode.decompress`, which decodes in place into the target)
//! and the streaming `Reader` (which decodes into its ring and copies out to
//! the writer, the structure the C reference decoder has). Throughput is MB/s
//! over the *decompressed* size. Local numbers are not claims.
//!
//! Output is benchstat-friendly:
//! `zig build bench -Doptimize=ReleaseFast -- --count=10 > bench.txt`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const bench = @import("benchmark");
const brotli = @import("compress").brotli;

/// The corpus shapes: the same set as the corpus generator
/// (`bench/zig/corpus.zig`) and the other codecs' benches.
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

/// The corpus base name of a case: `text-32768`.
fn baseName(comptime size: Size, comptime shape: Shape) []const u8 {
    return @tagName(shape) ++ switch (size) {
        .half => "-32768",
        .full => "-65536",
    };
}

/// Read one corpus file. Setup-only, never in the timed loop.
fn readCorpus(allocator: Allocator, io: Io, name: []const u8) ![]u8 {
    var dir = try Io.Dir.cwd().openDir(io, corpus_dir, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, name, allocator, .unlimited);
}

/// One-shot decode benchmarks: one sub-benchmark per corpus case. The stream
/// is loaded and checked once (the decode must reproduce the raw shape
/// exactly, as in the `bench/` harness), then decoded repeatedly.
pub fn benchmarkBrotliDecompress(b: *bench.B) !void {
    inline for (.{ Size.half, Size.full }) |size| {
        inline for (std.enums.values(Shape)) |shape| {
            _ = try b.run(caseName(size, shape), struct {
                fn run(bb: *bench.B) !void {
                    var threaded: Io.Threaded = .init_single_threaded;
                    const io = threaded.io();
                    const base = comptime baseName(size, shape);
                    const raw = try readCorpus(bb.allocator, io, base);
                    defer bb.allocator.free(raw);
                    const blob = try readCorpus(bb.allocator, io, base ++ ".br");
                    defer bb.allocator.free(blob);
                    const back = try bb.allocator.alloc(u8, raw.len);
                    defer bb.allocator.free(back);
                    // The reference stream must decode to the raw shape.
                    const verified = try brotli.decode.decompress(blob, back);
                    if (verified != raw.len or !std.mem.eql(u8, back, raw))
                        return error.CorpusMismatch;

                    while (try bb.loop()) {
                        const n = try brotli.decode.decompress(blob, back);
                        bb.keepAlive(n);
                    }
                    bb.setBytes(@intCast(raw.len));
                }
            }.run);
        }
    }
}

/// Streaming decode benchmarks: the same cases through `Reader` over a fixed
/// input and into a fixed writer. The buffer is the documented default
/// (`DefaultBuffer`, about 16.7 MiB), heap-allocated once; a fresh reader per
/// iteration, as one stream is one reader.
pub fn benchmarkBrotliReader(b: *bench.B) !void {
    inline for (.{ Size.half, Size.full }) |size| {
        inline for (std.enums.values(Shape)) |shape| {
            _ = try b.run(caseName(size, shape), struct {
                fn run(bb: *bench.B) !void {
                    var threaded: Io.Threaded = .init_single_threaded;
                    const io = threaded.io();
                    const base = comptime baseName(size, shape);
                    const raw = try readCorpus(bb.allocator, io, base);
                    defer bb.allocator.free(raw);
                    const blob = try readCorpus(bb.allocator, io, base ++ ".br");
                    defer bb.allocator.free(blob);
                    const back = try bb.allocator.alloc(u8, raw.len);
                    defer bb.allocator.free(back);
                    const buffer = try bb.allocator.create(brotli.Reader.DefaultBuffer);
                    defer bb.allocator.destroy(buffer);
                    // The reference stream must decode to the raw shape.
                    const verified = try decodeStream(blob, back, buffer);
                    if (verified != raw.len or !std.mem.eql(u8, back, raw))
                        return error.CorpusMismatch;

                    while (try bb.loop()) {
                        const n = try decodeStream(blob, back, buffer);
                        bb.keepAlive(n);
                    }
                    bb.setBytes(@intCast(raw.len));
                }
            }.run);
        }
    }
}

/// Decode one stream through a fresh `Reader` into `target`; the length.
fn decodeStream(
    source: []const u8,
    target: []u8,
    buffer: *brotli.Reader.DefaultBuffer,
) !usize {
    var in: Io.Reader = .fixed(source);
    var reader: brotli.Reader = .init(brotli.Reader.default_window_wbits, &in, buffer);
    var out: Io.Writer = .fixed(target);
    return reader.reader.streamRemaining(&out);
}
