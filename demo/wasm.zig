//! The browser demo's wasm module: encode and decode one buffer, one codec per
//! call. Freestanding wasm32, no allocator; input and output are fixed
//! regions of the module's memory, and the JavaScript side writes/reads them.
//!
//! Exports:
//!   inputPtr() / inputCap()    the input region
//!   outputPtr() / outputCap()  the output region
//!   encode(codec, level, len)  compress input[0..len] into output; the
//!                              compressed length, or a negative error
//!   decode(codec, len)         decompress input[0..len] into output; the
//!                              decoded length, or a negative error
//!
//! Codec ids: 0 snappy, 1 flate, 2 gzip, 3 zlib, 4 zstd, 5 brotli.
//! Negative returns: -1 unknown codec, -2 input or output too large, -3 the
//! codec refused the bytes.

const compress = @import("compress");

const max_input = 1 << 20;
const max_output = 8 << 20;

var input: [max_input]u8 = undefined;
var output: [max_output]u8 = undefined;
var zstd_buffer: compress.zstd.encode.Buffer = undefined;

export fn inputPtr() [*]u8 {
    return &input;
}

export fn inputCap() u32 {
    return max_input;
}

export fn outputPtr() [*]u8 {
    return &output;
}

export fn outputCap() u32 {
    return max_output;
}

fn levelOf(level: u32) u32 {
    return if (level == 0) 1 else level;
}

export fn encode(codec: u32, level: u32, source_len: u32) i32 {
    if (source_len > max_input) return -2;
    const source = input[0..source_len];
    const n: usize = switch (codec) {
        0 => blk: {
            if (source_len > compress.snappy.encode.max_block_size) return -2;
            break :blk compress.snappy.encode.compressBlock(source, &output) catch return -3;
        },
        1 => blk: {
            const lvl: compress.flate.encode.Level =
                if (levelOf(level) == 6) .@"6" else .@"1";
            break :blk compress.flate.encode.compress(source, &output, .{
                .level = lvl,
            }) catch return -3;
        },
        2 => blk: {
            const lvl: compress.gzip.encode.Level =
                if (levelOf(level) == 6) .@"6" else .@"1";
            break :blk compress.gzip.encode.compress(source, &output, .{
                .level = lvl,
            }) catch return -3;
        },
        3 => blk: {
            const lvl: compress.zlib.encode.Level =
                if (levelOf(level) == 6) .@"6" else .@"1";
            break :blk compress.zlib.encode.compress(source, &output, .{
                .level = lvl,
            }) catch return -3;
        },
        4 => blk: {
            const lvl: compress.zstd.encode.Level = if (levelOf(level) == 3) .@"3" else .@"1";
            break :blk compress.zstd.encode.compressBuffered(
                source,
                &output,
                &zstd_buffer,
                .{ .level = lvl },
            ) catch return -3;
        },
        5 => compress.brotli.encode.compress(source, &output) catch return -3,
        else => return -1,
    };
    return @intCast(n);
}

export fn decode(codec: u32, source_len: u32) i32 {
    if (source_len > max_input) return -2;
    const source = input[0..source_len];
    const n: usize = switch (codec) {
        0 => blk: {
            const declared = compress.snappy.decode.decompressedBlockLength(source) catch return -3;
            if (declared > max_output) return -2;
            break :blk compress.snappy.decode.decompressBlock(
                source,
                output[0..declared],
            ) catch return -3;
        },
        1 => compress.flate.decode.decompress(source, &output, null) catch return -3,
        2 => compress.gzip.decode.decompress(source, &output) catch return -3,
        3 => compress.zlib.decode.decompress(source, &output, null) catch return -3,
        4 => compress.zstd.decode.decompress(source, &output, null) catch return -3,
        5 => compress.brotli.decode.decompress(source, &output) catch return -3,
        else => return -1,
    };
    return @intCast(n);
}
