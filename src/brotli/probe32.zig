//! A 32-bit check for `brotli.Reader`. It decodes one stream whose
//! *compressed* input runs past 2^32 bytes on a target where `usize` is 32
//! bits — the only place the bit reader's u64 stream position can be seen
//! narrowed to a `usize` and wrapping.
//!
//! Run it with `just check-32`. The file is built as
//! `zig-out/bin/brotli-probe32.wasm` (wasm32-wasi, ReleaseSafe, so a wrap
//! panics) and run under wasmtime. A 64-bit host cannot show the wrap, and
//! `just check-baseline` only compiles for the other targets. The stream is
//! 257 metadata meta-blocks of 16 MiB each — skipped, never output — then
//! ISLAST + ISLASTEMPTY: 4,311,745,541 input bytes generated on the fly by a
//! custom `Io.Reader`, decoding to zero bytes with the input consumed exactly
//! through the last byte. The probe checks its own results and exits nonzero
//! on failure.

const std = @import("std");
const Io = std.Io;

const fastmem = @import("fastmem");

const brotli = @import("zcompress").brotli;

const print = std.debug.print;

/// `§9.2` — one metadata meta-block's payload: skipped, never output, never
/// window, never literal context.
const payload_len: u64 = 1 << 24;

/// The payload meta-blocks; the last meta-block is the empty terminator.
const block_count: u64 = 257;

/// One metadata meta-block's header: ISLAST, MNIBBLES = 3 (the metadata
/// form), the reserved bit, MSKIPBYTES = 3, and MSKIPLEN - 1 in three bytes.
const header_len: u64 = 4;

/// One payload meta-block: its header and its payload.
const block_len: u64 = header_len + payload_len;

/// The whole stream: the payload blocks, then `§9.3`'s ISLAST +
/// ISLASTEMPTY byte. 4,311,745,541 bytes, 262,146 past 2^32.
const stream_len: u64 = block_count * block_len + 1;

/// A metadata meta-block's header bytes: `0xEC` for the first block — its
/// low bit is the stream header's WBITS 16 bit (`§9.1`), so the first header
/// shares a byte with it — and `0xF6` for the rest. The three bytes between
/// are MSKIPLEN - 1 = 2^24 - 1, and the header's trailing fill bits are
/// zero.
const first_header = [header_len]u8{ 0xEC, 0xFF, 0xFF, 0x7F };
const rest_header = [header_len]u8{ 0xF6, 0xFF, 0xFF, 0x3F };

/// The stream's bytes, generated on the fly: the caller never holds more
/// than one input buffer's worth.
const Generator = struct {
    /// The stream byte the next fill starts at, counted in u64: this is the
    /// position the reader's `toss` arithmetic must keep exact past 2^32.
    pos: u64 = 0,
    reader: Io.Reader,

    const vtable: Io.Reader.VTable = .{ .stream = stream };

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *Generator = @alignCast(@fieldParentPtr("reader", r));
        if (self.pos == stream_len) return error.EndOfStream;
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n: usize = @intCast(@min(@as(u64, dest.len), stream_len - self.pos));
        var at: usize = 0;
        while (at < n) {
            const pos = self.pos + at;
            if (pos + 1 == stream_len) {
                dest[at] = 0x03; // ISLAST + ISLASTEMPTY (`§9.2`, `§9.3`).
                at += 1;
                continue;
            }
            const off = if (pos < block_len) pos else (pos - block_len) % block_len;
            if (off < header_len) {
                dest[at] = if (pos < block_len)
                    first_header[@intCast(off)]
                else
                    rest_header[@intCast(off)];
                at += 1;
                continue;
            }
            // A payload run never crosses the next header: the run stops at
            // the block boundary, and the next pass writes the header.
            const run: usize = @intCast(@min(block_len - off, n - at));
            fastmem.set(u8, dest[at..][0..run], 0);
            at += run;
        }
        w.advance(n);
        self.pos += n;
        return n;
    }
};

/// Consecutive zero-serve calls tolerated before the probe calls it a stall:
/// the generated `stream` entry answers 0 while it fills the ring, so one
/// zero is normal and a run of them is a reader that neither serves nor
/// fails.
const stall_limit: usize = 4;

/// The generator's input buffer and the reader's `Buffer(16)` (a 64 KiB ring
/// plus the 707,204-byte meta-block arena). Both are static: they are far
/// past a stack local's size.
var in_buf: [1 << 16]u8 = undefined;
var buffer: brotli.Reader.Buffer(16) = undefined;

pub fn main() !u8 {
    print("usize is {d} bits; the stream is {d} bytes (2^32 = {d})\n", .{
        @bitSizeOf(usize),
        stream_len,
        @as(u64, 1) << 32,
    });

    var generator: Generator = .{
        .reader = .{ .buffer = &in_buf, .seek = 0, .end = 0, .vtable = &Generator.vtable },
    };
    // `§9.1` — the stream's WBITS is 16, the smallest ring this can decode
    // in.
    var r: brotli.Reader = .init(16, &generator.reader, &buffer);
    var sink: Io.Writer.Discarding = .init(&.{});
    var served: u64 = 0;
    var stalls: usize = 0;
    while (true) {
        const n = r.reader.stream(&sink.writer, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                print("failed: {s} detail {s}\n", .{
                    @errorName(err),
                    if (r.err) |detail| @errorName(detail) else "none",
                });
                return error.ProbeFailed;
            },
        };
        served += n;
        stalls = if (n == 0) stalls + 1 else 0;
        if (stalls > stall_limit) {
            print("stalled after {d} input bytes\n", .{generator.pos});
            return error.ProbeFailed;
        }
    }

    if (r.err != null) {
        print("reader detail: {s}\n", .{@errorName(r.err.?)});
        return error.ProbeFailed;
    }
    if (served != 0) {
        print("served {d} bytes; the metadata stream decodes to none\n", .{served});
        return error.ProbeFailed;
    }
    if (generator.pos != stream_len) {
        print("input consumed {d} bytes, expected {d}\n", .{ generator.pos, stream_len });
        return error.ProbeFailed;
    }
    print("brotli-probe32: {d} input bytes consumed, 0 served, no wrap\n", .{generator.pos});
    return 0;
}
