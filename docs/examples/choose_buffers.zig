const std = @import("std");
const compress = @import("compress");
const zstd = compress.zstd;
const zlib = compress.zlib;
const gzip = compress.gzip;
const snappy = compress.snappy;
const lz4 = compress.lz4;

// Sizing the target is the encoder's job. Each codec exports its own exact
// worst case, so no sizing is a guess.
test "the encoders size their own targets" {
    const data = "a target sized by the encoder, not by a guess";

    var member: [gzip.encode.maxCompressedLength(data.len)]u8 = undefined;
    const member_len = try gzip.encode.compress(data, &member, .{});
    try std.testing.expect(member_len <= member.len);

    var stream: [zlib.encode.maxCompressedLength(data.len)]u8 = undefined;
    const stream_len = try zlib.encode.compress(data, &stream, .{});
    try std.testing.expect(stream_len <= stream.len);

    var frame: [zstd.encode.maxCompressedLength(data.len)]u8 = undefined;
    const frame_len = try zstd.encode.compress(data, &frame, .{});
    try std.testing.expect(frame_len <= frame.len);

    // snappy's raw-block form: with the exact size, `compressBlock` cannot
    // fail, and its error set drops to `error{}` at the call site.
    var block: [snappy.encode.maxCompressedLength(data.len)]u8 = undefined;
    const block_len = try snappy.encode.compressBlock(data, &block);
    try std.testing.expect(block_len <= block.len);

    var lz4_block: [lz4.encode.maxCompressedLength(data.len)]u8 = undefined;
    const lz4_block_len = try lz4.encode.compressBlock(data, &lz4_block);
    try std.testing.expect(lz4_block_len <= lz4_block.len);
}

// Sizing the decode target differs by format. Snappy tells the caller the
// decoded length up front: the block header is a varint. An LZ4 caller supplies
// the exact length as the target's length. The other codecs take a target cap.
test "block decoded lengths come from the header or the caller" {
    const data = "how big is the result?";
    var block: [snappy.encode.maxCompressedLength(data.len)]u8 = undefined;
    const block_len = try snappy.encode.compressBlock(data, &block);

    try std.testing.expectEqual(
        data.len,
        try snappy.decode.decompressedBlockLength(block[0..block_len]),
    );

    var lz4_block: [lz4.encode.maxCompressedLength(data.len)]u8 = undefined;
    const lz4_block_len = try lz4.encode.compressBlock(data, &lz4_block);
    var lz4_plain: [data.len]u8 = undefined;
    const lz4_plain_len = try lz4.decode.decompressBlock(
        lz4_block[0..lz4_block_len],
        &lz4_plain,
    );
    try std.testing.expectEqualSlices(u8, data, lz4_plain[0..lz4_plain_len]);

    // The other formats keep no header field the decoder trusts for this:
    // gzip and zlib carry the decoded size only in their trailers, and a
    // zstd frame the caller produced may name it in the header, but the
    // decode still takes a target cap and returns the decoded length.
    var frame: [zstd.encode.maxCompressedLength(data.len)]u8 = undefined;
    const frame_len = try zstd.encode.compress(data, &frame, .{});
    var plain: [64]u8 = undefined;
    const plain_len = try zstd.decode.decompress(frame[0..frame_len], &plain, null);
    try std.testing.expectEqualSlices(u8, data, plain[0..plain_len]);
}
