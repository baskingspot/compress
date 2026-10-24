# flate

Raw DEFLATE ([RFC 1951](https://www.rfc-editor.org/rfc/rfc1951.txt)) in pure Zig: an encoder,
a decoder, and `std.Io` streaming adapters. It is the `compress.flate` namespace, imports
only `std` and [fastmem](https://github.com/baskingspot/fastmem), and never allocates.
The spec is vendored at `docs/specs/rfc1951-deflate.txt`.

The decoder handles stored, fixed-Huffman, and dynamic-Huffman blocks. The
encoder has two levels. Level 1 is a greedy match finder in the style of
klauspost/compress level 1 that emits fixed-Huffman blocks, storing any block
that would not shrink. Level 6 is klauspost/compress's level-6 class: their
wider two-table greedy finder, dynamic-Huffman blocks, and the per-block
stored/fixed/dynamic dispatch, byte-identical to their flate at level 6 (the
pinned module version). "Raw" means no container: the gzip (RFC 1952) and zlib
(RFC 1950) packages wrap this one.

## Usage

One call each way, over buffers you own:

```zig
const std = @import("std");
const flate = @import("compress").flate;

fn roundTrip(gpa: std.mem.Allocator, input: []const u8) !void {
    const compressed = try gpa.alloc(u8, flate.encode.maxCompressedLength(input.len));
    defer gpa.free(compressed);
    const n = try flate.encode.compress(input, compressed, .{});

    const decoded = try gpa.alloc(u8, input.len); // the stream records no size: a cap
    defer gpa.free(decoded);
    _ = try flate.decode.decompress(compressed[0..n], decoded, null);
}
```

Streaming, from any `std.Io.Reader` to any `std.Io.Writer`:

```zig
fn compressStream(in: *std.Io.Reader, out: *std.Io.Writer) !void {
    var buffer: flate.Writer.Buffer = undefined;
    var w: flate.Writer = .init(out, &buffer, .{});
    _ = try in.streamRemaining(&w.writer);
    try w.finish(); // writes the final block; the stream is incomplete without it
}
```

Decoding mirrors it: `flate.Reader.init(in, &buffer, null)`, then read through
`&r.reader`. `Writer.streamAll` and `Reader.streamAll` pump a whole stream in
one call; a preset dictionary is the trailing `dict` parameter on the decode
entry points and `options.dict` on the encode ones.

## API

```zig
encode.compress(source: []const u8, target: []u8, options: Options)
    error{ BufferTooSmall, Unimplemented }!usize
encode.maxCompressedLength(input_len: usize) usize  // input_len + 5 * ceil(input_len / 65535) + 2
encode.Options = struct { level: u8 = 1, dict: ?[]const u8 = null }
    // level: 1-9, the zlib scale (1 is the default):
    //   1: fixed-Huffman blocks over the level-1 finder, or a stored block
    //      when that is smaller.
    //   6: the class above — klauspost/compress's wider greedy finder,
    //      dynamic-Huffman blocks (§3.2.7 length-limited trees), and the
    //      per-block stored/fixed/dynamic dispatch. Byte-identical to
    //      klauspost/compress's flate at level 6 (the pinned module version).
    // Levels 2-5 and 7-9 are not implemented and return error.Unimplemented,
    // never a silent alias, and so is any level outside 1-9. Callers of the
    // old `.fast` name change to level 1 — the same class under its number, a
    // source-breaking rename.
    // dict: preset history in front of the stream (§3.2.3). The caller vouches
    // for the bytes on both sides; zlib's FDICT/DICTID is the checked form.
encode.max_block_size = 65535, encode.history_len = 32768  // block size; match reach

decode.decompress(source: []const u8, target: []u8, dict: ?[]const u8) DecompressError!usize
decode.DecompressError = error{
    BufferTooSmall,            // `target` cannot hold the output
    Truncated,                 // the input ended before the final block
    InvalidBlockType, WrongStoredBlockNlen, // reserved block type 3 (§3.2.3); NLEN != ~LEN (§3.2.4)
    InvalidDynamicBlockHeader, // a bad header, HLIT > 286, HDIST > 30, or an empty precode
    OversubscribedHuffmanTree, IncompleteHuffmanTree, MissingEndOfBlockCode, // bad code lengths
    InvalidCode,               // a code that decodes to no legal symbol
    InvalidMatch,              // a distance before the start of the history: the
                               // dictionary's first byte, then the output's (§3.2.3)
}

Writer.Buffer = [98303]u8  // max_block_size + history_len
Writer.init(output: *Io.Writer, buffer: *Buffer, options: encode.Options) Writer
Writer.writer: Io.Writer   // write through &w.writer
Writer.finish(w: *Writer) Io.Writer.Error!void
Writer.streamAll(in: *Io.Reader, out: *Io.Writer, options: encode.Options)
    error{ ReadFailed, WriteFailed }!usize

Reader.Buffer = [65536]u8  // 2 * history_len
Reader.init(input: *Io.Reader, buffer: *Buffer, dict: ?[]const u8) Reader
Reader.reader: Io.Reader   // read through &r.reader
Reader.err: ?Error         // why error.ReadFailed happened: DecompressError without
                           // BufferTooSmall, plus StreamTooLong, ReadFailed, EndOfStream
Reader.streamAll(in: *Io.Reader, out: *Io.Writer, dict: ?[]const u8)
    error{ ReadFailed, WriteFailed }!usize
```

`Writer` and `Reader` also have an optional `checksum` hook for containers (`Checksum.zig`):
set `.checksum = .{ .context = &state, .update_fn = update }` before the first write or
read, and `update_fn` sees every payload byte once, in stream order. Other `pub`
declarations in `encode` and `decode` are shared internals.

## Behavior

- **Buffers.** You own every buffer. Nothing is allocated, freed, or retained.
- **Sizing.** `compress` writes at most `maxCompressedLength(source.len)` bytes: a block
  adds at most 5 header bytes to its input, and every stream ends with a 2-byte empty
  block. A raw deflate stream records no decoded length, so `target` is a cap for
  `decompress`, which returns `error.BufferTooSmall` before the write that would
  overflow it.
- **Preset dictionaries.** `dict` is history in front of the stream (§3.2.3):
  a distance may reach into it, and it slides out of the 32 KiB window as the
  output passes it. A dictionary longer than 32 KiB contributes only its last
  32 KiB. On decode the caller vouches for the bytes — raw flate carries no
  identifier — and on encode the dictionary is the window's oldest bytes. The
  zlib container is the form that names one: its FDICT flag and DICTID check
  the bytes before the body (RFC 1950 §2.2).
- **Corrupt input.** Decoding stops at the first invalid element with the matching
  `DecompressError`. Nothing is written past `target`, but after an error it may hold
  a partial prefix of the output. `Reader` returns `error.ReadFailed` with the detail
  in `r.err`, then stays failed and serves nothing more, buffered bytes included. An
  empty input is `error.Truncated`.
- **End of stream.** A stream ends at the first block with BFINAL set (§3.2.3).
  `decompress` ignores bytes after it and does not say where it ended. `Reader`
  stops after the stream's last byte, partial final byte included, and leaves the
  rest of `input` unconsumed, so you can keep parsing after it. Once the final
  block's output is consumed it returns `error.EndOfStream`.
- **Output.** Deterministic, but not canonical: other encoders emit other valid streams.
- **Stack.** `compress` keeps a 128 KiB match-finder table on the stack at
  level 1; at level 6 it keeps 384 KiB of finder tables, a 257 KiB token list,
  and the tree scratch, about 650 KiB in all. A `Writer` is about 392 KiB (it
  reserves the level-6 tables at every level), `Writer.Buffer` adds 96 KiB,
  and a level-6 block emission uses about 320 KiB more, so `Writer.streamAll`
  peaks near 810 KiB. A `Reader` is about 4 KiB plus its 64 KiB buffer;
  `decompress` needs a few KiB. On a small stack, heap-allocate the structs and
  buffers.

## Streaming

- `Writer.finish` emits the buffered data, then the final empty block, then flushes
  `output`. It ends the writer: later writes and `finish` calls return
  `error.WriteFailed`. `Writer.flush` ends the current block and flushes `output`,
  and the writer stays usable. It is not a zlib-style sync flush: the block's last
  few bits (fewer than 8) stay in the writer until the next block or `finish`, so
  a peer cannot decode everything written before the flush.
- `Reader` serves decoded bytes from a 64 KiB window, keeping 32 KiB as match history, so a
  contiguous request (`peek`, `take`) of up to 32 KiB is served while that much output remains.
  A larger one succeeds only if the window can hold it at the consumer's position; otherwise it
  returns `error.ReadFailed` with `r.err == error.StreamTooLong`.
- The input's own buffer must hold at least 3 bytes, unless the stream ends sooner:
  the decoder looks ahead a stored block's LEN and NLEN (§3.2.4), or one Huffman
  code, plus the partial byte already consumed.

## Limitations

- Level 1 emits fixed-Huffman blocks only: codes spend 8 or 9 bits per literal,
  so its output is larger than level 6's. Levels 2-5 and 7-9 are not
  implemented: `compress` returns `error.Unimplemented` for them and for any
  level outside 1-9, a `Writer` made with one fails every write and `finish`,
  and `Writer.streamAll` returns `error.ReadFailed` before reading.
- A preset dictionary on raw flate is unverified: no container carries an
  identifier, so the caller vouches for the bytes on both sides. The zlib
  container's FDICT/DICTID is the checked form.

## Testing and benchmarks

`just test` runs the unit tests: vectors ported from Go's `compress/flate` suite, RFC 1951's
worked examples, round trips, and overrun checks on every decode. `just flate-oracle`
cross-checks both directions against python3's `zlib`, pins level 1's bytes, and checks
level 6 against klauspost/compress's flate at level 6 byte for byte. `just fuzz` runs the
fuzz targets, and `just bench` runs the local benchmarks. Local numbers are not
performance claims; a claim names the run that produced it.

## License

MIT. The level-1 match finder follows klauspost/compress's level-1 encoder, the level-6
finder and block emitter follow their level-6 class, and the test vectors come from
golang/go's `compress/flate` (all BSD-3-Clause); see
[`THIRD_PARTY.md`](../../THIRD_PARTY.md).
