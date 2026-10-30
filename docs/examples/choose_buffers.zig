const std = @import("std");
const compress = @import("compress");
const zstd = compress.zstd;
const zlib = compress.zlib;
const gzip = compress.gzip;
const snappy = compress.snappy;

// Sizing the target is the encoder's job. Each codec exports its own exact
// worst case, so no sizing is a guess.
test "the encoders size their own targets" {
    const data = "a target sized by the encoder, not by a guess";

    var member: [gzip.encode.maxCompressedLength(data.len)]u8 = undefined;
    const member_len = try gzip.encode.compress(data, &member, .init);
    try std.testing.expect(member_len <= member.len);

    var stream: [zlib.encode.maxCompressedLength(data.len)]u8 = undefined;
    const stream_len = try zlib.encode.compress(data, &stream, .init);
    try std.testing.expect(stream_len <= stream.len);

    var frame: [zstd.encode.maxCompressedLength(data.len)]u8 = undefined;
    const frame_len = try zstd.encode.compress(data, &frame, .init);
    try std.testing.expect(frame_len <= frame.len);

    // snappy's raw-block form: with the exact size, `compressBlock` cannot
    // fail, and its error set drops to `error{}` at the call site.
    var block: [snappy.encode.maxCompressedLength(data.len)]u8 = undefined;
    const block_len = try snappy.encode.compressBlock(data, &block);
    try std.testing.expect(block_len <= block.len);
}

// Sizing the decode target differs by format. Only snappy tells the caller
// the decoded length up front: the block header is a varint. For the other
// codecs the caller knows the size or bounds it.
test "snappy reads the decoded length from the block header" {
    const data = "how big is the result?";
    var block: [snappy.encode.maxCompressedLength(data.len)]u8 = undefined;
    const block_len = try snappy.encode.compressBlock(data, &block);

    try std.testing.expectEqual(
        data.len,
        try snappy.decode.decompressedBlockLength(block[0..block_len]),
    );

    // The other formats keep no header field the decoder trusts for this:
    // gzip and zlib carry the decoded size only in their trailers, and a
    // zstd frame the caller produced may name it in the header, but the
    // decode still takes a target cap and returns the decoded length.
    var frame: [zstd.encode.maxCompressedLength(data.len)]u8 = undefined;
    const frame_len = try zstd.encode.compress(data, &frame, .init);
    var plain: [64]u8 = undefined;
    const plain_len = try zstd.decode.decompress(frame[0..frame_len], &plain, null);
    try std.testing.expectEqualSlices(u8, data, plain[0..plain_len]);
}
