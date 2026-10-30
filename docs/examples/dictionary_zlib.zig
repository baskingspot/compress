const std = @import("std");
const compress = @import("compress");
const zlib = compress.zlib;

// The zlib preset dictionary is raw bytes (RFC 1950 §2.2 FDICT): the last
// 32 KiB are the decoder's history, and both directions must supply the
// same bytes. A dictionary longer than 32 KiB contributes only its tail.
test "a preset dictionary round-trips both directions" {
    const dict = "the same bytes to both sides of the stream";
    const data = "the same bytes appear in the data, and the matches reach back into the dictionary";

    var stream: [128]u8 = undefined;
    const stream_len = try zlib.encode.compress(data, &stream, .{ .level = .@"1", .dict = dict });

    var plain: [128]u8 = undefined;
    const plain_len = try zlib.decode.decompress(stream[0..stream_len], &plain, dict);
    try std.testing.expectEqualSlices(u8, data, plain[0..plain_len]);
}

// FDICT is part of the stream, so the decoder refuses to guess: a stream
// that says a dictionary is present fails DictionaryRequired when none is
// supplied, and the wrong dictionary fails DictionaryMismatch.
test "the wrong dictionary fails by name" {
    const dict = "the dictionary the stream was made with";
    const data = "some data that matches the dictionary";

    var stream: [128]u8 = undefined;
    const stream_len = try zlib.encode.compress(data, &stream, .{ .level = .@"1", .dict = dict });

    var plain: [128]u8 = undefined;
    try std.testing.expectError(
        error.DictionaryRequired,
        zlib.decode.decompress(stream[0..stream_len], &plain, null),
    );
    try std.testing.expectError(
        error.DictionaryMismatch,
        zlib.decode.decompress(stream[0..stream_len], &plain, "not the dictionary"),
    );
}
