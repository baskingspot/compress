// Analysis root for `zig build check-lib`.
//
// Each export calls the codec's public one-shot and Io entry points. Export
// status forces code generation, unlike a reference in a test block. No build
// step runs these wrappers.

const std = @import("std");
const Io = std.Io;

const compress = @import("compress");
const brotli = compress.brotli;
const flate = compress.flate;
const gzip = compress.gzip;
const lz4 = compress.lz4;
const snappy = compress.snappy;
const zlib = compress.zlib;
const zstd = compress.zstd;

var source: [1]u8 = .{0};
var target: [1]u8 = .{0};

export fn checkSnappy() void {
    var input: Io.Reader = .fixed(&source);
    var output: Io.Writer = .fixed(&target);

    _ = snappy.encode.maxCompressedLength(source.len);
    _ = snappy.encode.compressBlock(&source, &target) catch 0;
    _ = snappy.decode.decompressedBlockLength(&source) catch 0;
    _ = snappy.decode.decompressBlock(&source, &target) catch 0;
    _ = snappy.Writer.streamAll(&input, &output) catch 0;
    _ = snappy.Reader.streamAll(&input, &output) catch 0;
}

export fn checkLz4() void {
    _ = lz4.encode.maxCompressedLength(source.len);
    _ = lz4.encode.compressBlock(&source, &target) catch 0;
    _ = lz4.decode.decompressBlock(&source, &target) catch 0;
}

export fn checkFlate() void {
    var input: Io.Reader = .fixed(&source);
    var output: Io.Writer = .fixed(&target);

    _ = flate.encode.maxCompressedLength(source.len);
    _ = flate.encode.compress(&source, &target, .{}) catch 0;
    _ = flate.decode.decompress(&source, &target, null) catch 0;
    _ = flate.Writer.streamAll(&input, &output, .{}) catch 0;
    _ = flate.Reader.streamAll(&input, &output, null) catch 0;
}

export fn checkGzip() void {
    var input: Io.Reader = .fixed(&source);
    var output: Io.Writer = .fixed(&target);

    _ = gzip.encode.maxCompressedLength(source.len);
    _ = gzip.encode.compress(&source, &target, .{}) catch 0;
    _ = gzip.decode.decompress(&source, &target) catch 0;
    _ = gzip.Writer.streamAll(&input, &output, .{}) catch 0;
    _ = gzip.Reader.streamMember(&input, &output) catch 0;
    _ = gzip.Reader.streamAll(&input, &output) catch 0;
}

export fn checkZlib() void {
    var input: Io.Reader = .fixed(&source);
    var output: Io.Writer = .fixed(&target);

    _ = zlib.encode.maxCompressedLength(source.len);
    _ = zlib.encode.compress(&source, &target, .{}) catch 0;
    _ = zlib.decode.decompress(&source, &target, null) catch 0;
    _ = zlib.Writer.streamAll(&input, &output, .{}) catch 0;
    _ = zlib.Reader.streamAll(&input, &output, null) catch 0;
}

export fn checkZstd() void {
    var input: Io.Reader = .fixed(&source);
    var output: Io.Writer = .fixed(&target);
    var writer_buffer: zstd.Writer.DefaultBuffer = undefined;
    var reader_buffer: zstd.Reader.DefaultBuffer = undefined;

    const dictionary = zstd.Dictionary.initRaw(&source);
    _ = zstd.Dictionary.parse(&source) catch dictionary;
    _ = zstd.encode.maxCompressedLength(source.len);
    _ = zstd.encode.compress(&source, &target, .{ .dict = &dictionary }) catch 0;
    _ = zstd.decode.decompress(&source, &target, &dictionary) catch 0;
    _ = zstd.Writer.streamAll(
        zstd.Writer.default_window_log,
        &input,
        &output,
        &writer_buffer,
        .{ .dict = &dictionary },
    ) catch 0;
    _ = zstd.Writer.streamAllAlloc(std.heap.page_allocator, &input, &output, .{}) catch 0;
    _ = zstd.Reader.streamFrame(
        zstd.Reader.default_window_len,
        &input,
        &output,
        &reader_buffer,
        &dictionary,
    ) catch 0;
    _ = zstd.Reader.streamAll(
        zstd.Reader.default_window_len,
        &input,
        &output,
        &reader_buffer,
        &dictionary,
    ) catch 0;
    _ = zstd.Reader.streamFrameAlloc(std.heap.page_allocator, &input, &output, null) catch 0;
    _ = zstd.Reader.streamAllAlloc(std.heap.page_allocator, &input, &output, null) catch 0;
}

export fn checkBrotli() void {
    var input: Io.Reader = .fixed(&source);
    var output: Io.Writer = .fixed(&target);
    var writer_buffer: brotli.Writer.DefaultBuffer = undefined;
    var reader_buffer: brotli.Reader.DefaultBuffer = undefined;

    _ = brotli.encode.maxCompressedLength(source.len);
    _ = brotli.encode.compress(&source, &target) catch 0;
    _ = brotli.decode.decompress(&source, &target) catch 0;
    _ = brotli.Writer.streamAll(
        brotli.Writer.default_window_wbits,
        &input,
        &output,
        &writer_buffer,
    ) catch 0;
    _ = brotli.Reader.streamAll(
        brotli.Reader.default_window_wbits,
        &input,
        &output,
        &reader_buffer,
    ) catch 0;
}
