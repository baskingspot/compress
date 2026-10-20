const std = @import("std");
const compress = @import("compress");
const zstd = compress.zstd;

// A dictionary is caller bytes. `Dictionary.parse` takes the formatted form
// that `zstd --train` writes; `initRaw` takes any bytes at all, used as
// history with no entropy tables. The value borrows the bytes: keep them
// alive as long as the dictionary is.
test "a raw dictionary round-trips both directions" {
    const dict_file = "a small dictionary of bytes the input will resemble";
    const data = "the input resembles the dictionary of bytes";

    const dict: zstd.Dictionary = .initRaw(dict_file);

    var frame: [zstd.encode.maxCompressedLength(data.len)]u8 = undefined;
    const frame_len = try zstd.encode.compress(data, &frame, .{ .dict = &dict });

    var plain: [64]u8 = undefined;
    const plain_len = try zstd.decode.decompress(frame[0..frame_len], &plain, &dict);
    try std.testing.expectEqualSlices(u8, data, plain[0..plain_len]);
}

// A raw dictionary carries no ID: `initRaw` content has no magic, so the
// frame the encoder writes cannot name it. A decode without the
// dictionary proceeds until a match reaches back into history that is not
// there, and fails OffsetTooFar — the honest refusal for the raw form.
// A formatted dictionary (the `zstd --train` output `parse` reads) carries
// a DICTID: its frames fail DictionaryRequired with none supplied and
// DictionaryMismatch for the wrong one.
test "a raw dictionary frame is honest about what it needs" {
    const right: zstd.Dictionary = .initRaw("the dictionary the frame was made with");
    const data = "the dictionary the frame was made with, and the data";

    var frame: [zstd.encode.maxCompressedLength(data.len)]u8 = undefined;
    const frame_len = try zstd.encode.compress(data, &frame, .{ .dict = &right });

    var plain: [128]u8 = undefined;
    try std.testing.expectError(
        error.OffsetTooFar,
        zstd.decode.decompress(frame[0..frame_len], &plain, null),
    );
}
