# lz4

LZ4 block compression for Zig, available as `compress.lz4`: a block encoder
with a hash-table match finder and a block decoder with a SIMD fast path for
overlapping copies. It depends on `std`,
[fastmem](https://github.com/baskingspot/fastmem), and `src/internal/`, and
never allocates.

The block functions implement the [LZ4 block format][format]. They add no
framing, checksum, decoded-length prefix, or dictionary. The caller supplies
the decoded length through the output buffer's length.

## Usage

```zig
const std = @import("std");
const lz4 = @import("compress").lz4;

fn roundTripBlock(gpa: std.mem.Allocator, source: []const u8) !void {
    const block = try gpa.alloc(u8, lz4.encode.maxCompressedLength(source.len));
    defer gpa.free(block);
    const n = try lz4.encode.compressBlock(source, block);

    const out = try gpa.alloc(u8, source.len);
    defer gpa.free(out);
    const written = try lz4.decode.decompressBlock(block[0..n], out);
    std.debug.assert(written == source.len);
    std.debug.assert(std.mem.eql(u8, source, out));
}
```

## API

```text
// lz4.encode
pub fn compressBlock(source: []const u8, target: []u8) error{BufferTooSmall}!usize
pub fn maxCompressedLength(input_len: usize) usize
pub const max_block_size: usize = 0x7E00_0000;

// lz4.decode
pub fn decompressBlock(source: []const u8, target: []u8) DecompressError!usize
pub const DecompressError = error{DecompressionFailed};
```

## Behavior

- **Buffers and sizing.** The caller owns every buffer. Nothing is allocated,
  retained, or freed, and no function takes an allocator. A `target` of
  `maxCompressedLength(source.len)` bytes makes `compressBlock` infallible.
  `compressBlock` requires `source.len <= max_block_size` (asserted, not
  returned). `decompressBlock` requires `target.len` to equal the decoded
  length. It returns that length on success.
- **Corrupt input.** `decompressBlock` returns `error.DecompressionFailed` for
  an empty or truncated block, a length that overflows `usize`, literals or a
  match that run past either buffer, offset zero, an offset before the start of
  the output, a missing final literal sequence, or output shorter than
  `target.len`. It never writes past `target`; `target` is unspecified after an
  error.
- **Foreign blocks.** The decoder accepts every structurally valid block. It
  does not require five trailing literals or a last match at least 12 bytes
  before the end. Those are encoder-side compatibility restrictions in the
  specification, and encoders in the wild do not all follow them. The final
  token's match-length bits are ignored when the block ends after its literals.
- **Empty input.** The encoder writes one zero token. The decoder accepts that
  token with a zero-length `target`. An empty compressed slice is invalid.
- **Encoder output.** Valid LZ4, with no promise of matching another encoder's
  bytes. The encoder follows the end-of-block restrictions: inputs shorter
  than 13 bytes are literals, the last match starts at least 12 bytes before
  the end, and at least five trailing bytes are literals.
- **Stack.** `compressBlock` uses a 128 KiB position table and an 8 KiB
  occupancy bitmap. The bitmap alone is cleared for each call. Blocks larger
  than 64 KiB use the same table through the format's 65,535-byte match window.

## Limitations

No LZ4 frame format, legacy format, high-compression mode, or dictionaries.
Split input above `max_block_size` into independently decodable blocks and
carry each decoded length out of band.

## Testing and benchmarks

`just test` runs the unit tests, including hand-composed format vectors and
blocks that break the encoder-side end restrictions. `just lz4-oracle`
cross-checks blocks against `github.com/pierrec/lz4/v4` in both directions.
`just fuzz 10M` runs the fuzz targets and `just bench` the local benchmarks.
Local numbers are not claims; a claim names the run that produced it.

A 2026-11-26 local run measured 64 KiB inputs on aarch64-linux with a Neoverse
V3. These are five-round medians in GB/s over uncompressed bytes, not a
cross-library comparison:

| Shape  | Encode | Decode | Compressed/raw |
| ------ | -----: | -----: | -------------: |
| text   |   6.50 |   9.45 |       0.004761 |
| random |  11.69 |  79.80 |       1.003937 |
| html   |   7.53 |  13.35 |       0.004807 |
| rle    |   6.54 |  24.81 |       0.004074 |
| mixed  |  11.83 |  79.80 |       1.003937 |

## License

MIT, like compress. The encoder follows the match-finding algorithm in
pierrec/lz4, BSD-3-Clause; see [`THIRD_PARTY.md`](../../THIRD_PARTY.md).

[format]: ../../docs/specs/lz4-block-format.md
