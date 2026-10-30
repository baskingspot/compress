const std = @import("std");
const compress = @import("compress");
const flate = compress.flate;
const gzip = compress.gzip;
const zstd = compress.zstd;

// Every failure has a name. The error sets are closed per codec, so a
// switch can be exhaustive, and the names say what was wrong with the
// bytes rather than which layer noticed.
test "corrupt input fails with a named error" {
    // A gzip header with the wrong magic: ID1, ID2, or CM wrong (§2.3.1).
    const not_gzip = "not a gzip member at all, just text";
    var plain: [64]u8 = undefined;
    try std.testing.expectError(error.BadHeader, gzip.decode.decompress(not_gzip, &plain));

    // A raw-deflate stream cut before its final block: the input ended
    // early, and the error says so.
    const data = "a stream that will be cut short";
    var raw: [64]u8 = undefined;
    const raw_len = try flate.encode.compress(data, &raw, .init);
    try std.testing.expectError(
        error.Truncated,
        flate.decode.decompress(raw[0 .. raw_len - 2], &plain, null),
    );

    // A zstd frame without zstd's magic: the first four bytes are the
    // frame's whole identity (§3.1.1.1).
    try std.testing.expectError(error.BadMagic, zstd.decode.decompress("no magic here", &plain, null));
}

// Decode treats the target as a cap, not a promise: a result that does
// not fit returns error.BufferTooSmall. The decode may fill the cap on
// its way to the refusal — the guarantee is that nothing past the cap
// is ever written.
test "a target too small fails before writing past it" {
    const data = "a decoded stream that will not fit";
    var member: [64]u8 = undefined;
    const member_len = try gzip.encode.compress(data, &member, .init);

    var tiny: [4]u8 = @splat(0xAA);
    try std.testing.expectError(
        error.BufferTooSmall,
        gzip.decode.decompress(member[0..member_len], &tiny),
    );
}

// The returned length is the other half of the rule: decode never writes
// past the length it returns, so a larger target keeps its tail untouched.
// Every codec's test suite pins this with sentinels.
