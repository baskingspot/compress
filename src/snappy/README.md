# snappy

Snappy compression for Zig, available as `compress.snappy`: a block encoder
with a hash-table match finder, a block decoder with a SIMD fast path for
overlapping copies (aarch64; x86_64 with SSSE3; portable code elsewhere), and a
streaming `Reader`/`Writer` over `std.Io`. It depends on `std`,
[fastmem](https://github.com/baskingspot/fastmem), and `src/internal/`,
and never allocates.

The block functions implement the [Snappy block format][format] and add no
framing. The streaming layer implements Google's [framed format][framing]:
the `sNaPpY` identifier, compressed and raw data chunks with a masked CRC-32C
each, and skippable chunks.

## Usage

One block, at most 64 KiB:

```zig
const snappy = @import("compress").snappy;

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
pub const Error = error{ Truncated, InvalidStream, BadStreamIdentifier,
    BadChunkType, BadChecksum, StreamTooLong, BufferTooSmall,
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

`Writer` and `Reader` use Google's [framing][framing]:

```text
stream     := identifier chunk*
identifier := 0xff, u24-le 6, "sNaPpY"
chunk      := type, u24-le length, data
  0x00 compressed   u32-le masked CRC-32C (uncompressed), snappy block
  0x01 uncompressed u32-le masked CRC-32C, raw bytes
  0xfe padding, 0x80-0xfd skippable: skipped
  0x02-0x7f reserved unskippable: error
```

A data chunk decodes to at most 64 KiB. `Writer` cuts input into 64 KiB
chunks; a `flush` ends one early. A chunk is compressed only when the block is
smaller than the raw bytes. An empty stream is the identifier alone (10
bytes). The identifier may repeat between chunks (for concatenation); the
Reader checks and ignores it.

- **Writer.** `finish` ends the stream: it writes the identifier if nothing
  has been written, the final partial chunk, and flushes `output`; without it
  the tail stays in the buffer. After `finish`, or after a failed write to
  `output`, later writes and `finish` return `error.WriteFailed`. `flush`
  emits a chunk early and keeps the writer usable.
- **Reader.** It reads `input` to its end and returns `error.EndOfStream` when
  `input` ends at a chunk boundary. Corrupt framing or a corrupt block returns
  `error.ReadFailed` with the reason in `r.err`: `Truncated` (the input ended
  inside the identifier, a chunk header, or a chunk), `BadStreamIdentifier`,
  `BadChunkType` (a reserved unskippable type), `BadChecksum`, `InvalidStream`
  (a data chunk shorter than its checksum, a payload past the staging region,
  or a block that decodes past 64 KiB), `StreamTooLong`, or
  `DecompressionFailed`. Both outcomes are sticky, and bytes from the chunks
  before a bad one are still served.
- **Trailing bytes.** The input's end is the stream's end; there is no end
  marker. A cut inside a chunk is `Truncated`, but a cut exactly at a chunk
  boundary is a complete stream (the CRC checks each chunk, not the stream's
  length). A second stream's identifier is accepted and ignored, so
  concatenated streams decode as one.
- **Contiguous reads.** `peek`, `take`, and the delimiter reads need contiguous
  bytes, and the buffer guarantees two blocks (128 KiB). A larger request can
  fail with `error.ReadFailed` and `r.err == .StreamTooLong`; other reads have
  no such limit.

## Limitations

- No S2 extensions (klauspost's Snappy superset): a copy with offset 0, which
  S2 uses to repeat the previous offset, is corrupt here.

## Testing and benchmarks

`just test` runs the unit tests, including the golang/snappy decode vectors.
`just snappy-oracle` cross-checks framed streams against klauspost/compress's
snappy-compatible s2 in both directions. `just fuzz 10M` runs the fuzz targets
and `just bench` the local benchmarks. Local numbers are not claims; a claim
names the run that produced it.

## License

MIT, like compress. The encoder ports the algorithm of klauspost/compress's
`encodeBlockSnappyGo64K` and the golden test vectors come from golang/snappy,
both BSD-3-Clause; see [`THIRD_PARTY.md`](../../THIRD_PARTY.md).

[format]: ../../docs/specs/snappy-format-description.txt
[framing]: ../../docs/specs/snappy-framing.txt
