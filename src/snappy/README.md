# snappy

Snappy compression for Zig, available as `zcompress.snappy`: a block encoder
with a hash-table match finder, a block decoder with a SIMD fast path for
overlapping copies (aarch64; x86_64 with SSSE3; portable code elsewhere), and a
streaming `Reader`/`Writer` over `std.Io`. It depends on `std`,
[fastmem](https://github.com/mattrobenolt/fastmem-zig), and `src/internal/`,
and never allocates.

The block functions implement the [Snappy block format][format] and add no
framing. The streaming layer's framing is its own, not Google's `sNaPpY`
format (see "Streaming").

## Usage

One block, at most 64 KiB:

```zig
const snappy = @import("zcompress").snappy;

// `gpa` is a std.mem.Allocator; `source` is a []const u8.
const block = try gpa.alloc(u8, snappy.encode.maxCompressedLength(source.len));
defer gpa.free(block);
const n = try snappy.encode.compressBlock(source, block);
const out = try gpa.alloc(u8, try snappy.decode.decompressedBlockLength(block[0..n]));
defer gpa.free(out);
_ = try snappy.decode.decompressBlock(block[0..n], out);
```

A stream of any length (`Writer.streamAll` and `Reader.streamAll` do each half
in one call):

```zig
// Compress `bytes` into `sink`, an *Io.Writer.
var wbuf: snappy.Writer.Buffer = undefined;
var w: snappy.Writer = .init(sink, &wbuf);
try w.writer.writeAll(bytes);
try w.finish(); // writes the last block and flushes `sink`

// Decompress `compressed`, an *Io.Reader, into `out`, an *Io.Writer.
var rbuf: snappy.Reader.Buffer = undefined;
var r: snappy.Reader = .init(compressed, &rbuf);
_ = try r.reader.streamRemaining(out);
```

## API

```zig
// snappy.encode
pub fn compressBlock(source: []const u8, target: []u8) error{BufferTooSmall}!usize
pub fn maxCompressedLength(input_len: usize) usize
pub const max_block_size: usize = 65536;

// snappy.decode
pub fn decompressBlock(source: []const u8, target: []u8) DecompressError!usize
pub fn decompressedBlockLength(source: []const u8) DecompressError!usize
pub const DecompressError = error{ BufferTooSmall, DecompressionFailed };

// snappy.Writer: a compressing Io.Writer, written through `&w.writer`
pub const Buffer = [max_block_size]u8; // 64 KiB
pub const scratch_len: usize; // 66,632: the largest compressed block
pub fn init(output: *Io.Writer, buffer: *Buffer) Writer
pub fn finish(w: *Writer) Io.Writer.Error!void // error{WriteFailed}

// snappy.Reader: a decompressing Io.Reader, read through `&r.reader`
pub const Buffer = [3 * max_block_size + Writer.scratch_len]u8; // 257 KiB
pub fn init(input: *Io.Reader, buffer: *Buffer) Reader
pub const Error = error{ Truncated, InvalidStream, StreamTooLong, BufferTooSmall,
    DecompressionFailed, ReadFailed, EndOfStream };
err: ?Error, // why the interface returned error.ReadFailed

// Writer.streamAll and Reader.streamAll: return the uncompressed bytes moved
pub fn streamAll(in: *Io.Reader, out: *Io.Writer) error{ ReadFailed, WriteFailed }!usize
```

## Behavior

- **Buffers and sizing.** The caller owns every buffer. Nothing is allocated,
  retained, or freed, and no function takes an allocator. A `target` of
  `maxCompressedLength(source.len)` bytes makes `compressBlock` infallible:
  incompressible input is stored as one literal, so output never exceeds that
  bound. `compressBlock` requires `source.len <= max_block_size` (asserted, not
  returned). `decompressBlock` needs `target.len` of at least the declared
  length that `decompressedBlockLength` reads from the header, else it returns
  `error.BufferTooSmall` before writing anything. The declared length can be up
  to 2^32 - 1 (spec §1): limit it before allocating for untrusted input.
- **Corrupt input.** `decompressBlock` returns `error.DecompressionFailed` for a
  bad length header, a literal or copy that runs past `source`, a copy offset
  of zero or before the start of the output (spec §2.2), output that does not
  add up to the declared length, or trailing bytes after the block. It never
  writes past the declared length; `target` is unspecified after an error.
- **Encoder output.** Valid Snappy, with no promise of matching another
  encoder's bytes: the format does not fix one encoding.
- **Stack.** `compressBlock` puts a 32 KiB hash table on the stack, and a
  `Writer` block adds a `scratch_len` buffer (about 97 KiB in all). The
  `streamAll` helpers keep their `Buffer` there too.

## Streaming

`Writer` and `Reader` use this framing:

```text
stream := block*
block  := u32-le compressed_length, raw-snappy-block
```

`compressed_length` is in `[1, Writer.scratch_len]` and a block decodes to at
most 64 KiB. `Writer` cuts input into 64 KiB blocks; a `flush` ends one early.
An empty stream is zero bytes. There is no magic number, end marker, or
checksum. Google's framing (`framing_format.txt`: the `sNaPpY` identifier and
CRC-32C chunks) needs the block functions and your own framing code.

- **Writer.** `finish` ends the stream: it writes the last partial block and
  flushes `output`; without it the tail stays in the buffer. After `finish`, or
  after a failed write to `output`, later writes and `finish` return
  `error.WriteFailed`. `flush` emits a block early and keeps the writer usable.
- **Reader.** It reads `input` to its end and returns `error.EndOfStream` when
  `input` ends at a block boundary. Corrupt framing or a corrupt block returns
  `error.ReadFailed` with the reason in `r.err`: `Truncated` (the input ended
  inside a length prefix or block), `InvalidStream` (a length of 0 or over
  `scratch_len`, or a block that decodes to more than 64 KiB), or
  `DecompressionFailed`. Both outcomes are sticky, and bytes from the blocks
  before a bad one are still served.
- **Trailing bytes.** Nothing marks the end of a stream, so bytes after the
  last block are read as more blocks: garbage is an error, an appended second
  stream reads as a continuation, and a stream cut at a block boundary looks
  complete. Add a checksum if you need to detect that.
- **Contiguous reads.** `peek`, `take`, and the delimiter reads need contiguous
  bytes, and the buffer guarantees two blocks (128 KiB). A larger request can
  fail with `error.ReadFailed` and `r.err == .StreamTooLong`; other reads have
  no such limit.

## Limitations

- No S2 extensions (klauspost's Snappy superset): a copy with offset 0, which
  S2 uses to repeat the previous offset, is corrupt here.

## Testing and benchmarks

`just test` runs the unit tests, including the golang/snappy decode vectors.
`just fuzz 10M` runs the fuzz targets and `just bench` the local benchmarks.
Local numbers are not claims; measured results are in `docs/results/`.

## License

MIT, like zcompress. The encoder ports the algorithm of klauspost/compress's
`encodeBlockSnappyGo64K` and the golden test vectors come from golang/snappy,
both BSD-3-Clause; see [`THIRD_PARTY.md`](../../THIRD_PARTY.md).

[format]: ../../docs/research/specs/snappy-format-description.txt
