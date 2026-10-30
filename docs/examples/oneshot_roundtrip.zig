const std = @import("std");
const compress = @import("compress");
const flate = compress.flate;
const gzip = compress.gzip;

// The one-shot shape is the same across codecs: encode returns the
// compressed length, decode returns the decoded length, and both take
// caller-owned buffers.
test "a one-shot round trip in both codecs" {
    const data = "the same buffer shape in every codec";

    var member: [64]u8 = undefined;
    const member_len = try gzip.encode.compress(data, &member, .init);

    var plain: [64]u8 = undefined;
    const plain_len = try gzip.decode.decompress(member[0..member_len], &plain);
    try std.testing.expectEqualSlices(u8, data, plain[0..plain_len]);

    var raw: [64]u8 = undefined;
    const raw_len = try flate.encode.compress(data, &raw, .init);

    var back: [64]u8 = undefined;
    const back_len = try flate.decode.decompress(raw[0..raw_len], &back, null);
    try std.testing.expectEqualSlices(u8, data, back[0..back_len]);
}

// Decode never writes past the returned length, so a bigger buffer
// keeps its tail untouched.
test "decode leaves the bytes past the decoded length alone" {
    const data = "sentinel rule";
    var member: [64]u8 = undefined;
    const member_len = try gzip.encode.compress(data, &member, .init);

    var plain: [64]u8 = undefined;
    @memset(&plain, 0xAA);
    const plain_len = try gzip.decode.decompress(member[0..member_len], &plain);
    try std.testing.expectEqualSlices(u8, data, plain[0..plain_len]);
    for (plain[plain_len..]) |b| try std.testing.expectEqual(@as(u8, 0xAA), b);
}
