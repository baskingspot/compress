const std = @import("std");
const compress = @import("compress");
const gzip = compress.gzip;

// A Writer compresses into an Io.Writer, and a Reader decompresses from an
// Io.Reader. `finish` is required on the encode side: it writes the trailer.
fn streamingRoundTrip(gpa: std.mem.Allocator, input: []const u8) !void {
    var member: std.Io.Writer.Allocating = .init(gpa);
    defer member.deinit();

    var wbuf: gzip.Writer.Buffer = undefined;
    var w: gzip.Writer = .init(&member.writer, &wbuf, .init);
    try w.writer.writeAll(input);
    try w.finish();

    var in: std.Io.Reader = .fixed(member.written());
    var rbuf: gzip.Reader.Buffer = undefined;
    var r: gzip.Reader = .init(&in, &rbuf);
    const plain = try r.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(plain);
    try std.testing.expectEqualSlices(u8, input, plain);
}

test "a streaming round trip through Io" {
    try streamingRoundTrip(std.testing.allocator, "streamed through the Io interfaces");
}

// The one-call forms pump a whole input through. On the Reader side the
// gzip framing is self-delimiting, so one `streamAll` walks every member
// in a multi-member stream.
test "streamAll pumps a whole stream in one call" {
    const input = "one call, both directions";

    var member: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer member.deinit();
    var in: std.Io.Reader = .fixed(input);
    _ = try gzip.Writer.streamAll(&in, &member.writer, .init);

    var back: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer back.deinit();
    var source: std.Io.Reader = .fixed(member.written());
    _ = try gzip.Reader.streamAll(&source, &back.writer);
    try std.testing.expectEqualSlices(u8, input, back.written());
}

// The buffers are named types the caller owns. gzip's are small enough for
// a stack local; zstd's are not, and its `*Alloc` variants take an
// allocator for them.
test "the caller owns the streaming buffer" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var wbuf: gzip.Writer.Buffer = undefined; // [98303]u8: a stack local is fine
    var in: std.Io.Reader = .fixed("caller-owned, stack-sized");
    var w: gzip.Writer = .init(&out.writer, &wbuf, .init);
    try w.writer.writeAll("caller-owned, stack-sized");
    try w.finish();
    _ = &in;
}
