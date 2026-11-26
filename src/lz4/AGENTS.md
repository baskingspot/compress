# Agent notes: lz4

`README.md` is the user-facing contract; this file holds the reasons behind it.

## Design decisions

- Raw blocks only. There is no decoded-length prefix, so `decompressBlock`
  takes the exact expected length as `target.len`. `DecompressionFailed`
  covers a target-size mismatch; the format cannot distinguish it from corrupt
  bytes, so there is no `BufferTooSmall` decode result.
- The final sequence must end in literals, but its low token bits are ignored.
  The last-five-literals and last-match-12-bytes-from-the-end rules are encoder
  restrictions. The decoder deliberately accepts blocks without those margins.
- `max_block_size` is the reference implementation's `0x7E00_0000`. It keeps
  `maxCompressedLength` within a 32-bit `usize`.
- The encoder follows pierrec/lz4 v4.1.34's fast finder: a 65,536-entry `u16`
  table, an 8-KiB occupancy bitmap, three candidates per 64-bit load, and an
  adaptive skip. Only the bitmap is cleared. Position reconstruction selects
  the current or previous 64-KiB segment and rejects offsets of 65,536 or more.
- The scan reserves its second and third candidate positions inside the
  specification's 12-byte match-start margin. Match extension leaves five last
  literals. Inputs below 14 bytes are literals. Byte parity is not a goal.
- `golden.expectEncoderBlock` walks every unit-test and fuzz round trip. It
  checks the last match's start and the final literal count independently of
  the decoders. `abababbababba` pins the former `s+2` overrun.
- Match extension advances both cursors on an eight-byte mismatch before the
  byte-wise tail. The 25-byte regression in `encode.zig` pins that pairing.
- Decode copies share `internal.match.copyMatch` with Snappy. Exact-sized
  targets cannot use wild stores; the shared kernel's small-offset source is
  padded before its SIMD shuffle.

## Testing and oracles

- `golden.zig` covers the specification's 15, 48, and 280 literal examples,
  match extensions, zero-literal sequences, offset 65,535, late matches, short
  final literals, and the corrupt-input matrix. Every case has a sentinel
  region after the exact target.
- `just lz4-oracle` runs both directions against pierrec/lz4 v4.1.34 and
  liblz4 through Python `lz4` 4.4.5. The C seat uses exact-capacity decode for
  our output and emits default, fast, and high-compression blocks for ours.
  Two-symbol inputs cover the late-match class. The Go destination is always
  `CompressBlockBound`, so random inputs produce a literal-only block instead
  of Go's no-block zero return. Go's empty-input zero return is not a block;
  the canonical zero-token empty block is tested directly.
  klauspost/compress's LZ4 encoder is in `internal/lz4ref`; its
  public `s2.LZ4Converter` consumes LZ4 and emits S2, so it is not an oracle
  seat here.
- The fuzz targets cap arbitrary decode input at 8 KiB and decoded output at
  128 KiB. Structured round trips cross the 64-KiB position-segment boundary.
- `examples/lz4.zig` has an example-local 64-KiB record framing: two `u32-le`
  lengths, decoded then compressed. It is not an LZ4 frame and does not belong
  in the library.

## Performance notes

- The local bench uses 64-KiB inputs, the journal-record size in the issue.
  Local numbers are not claims. A public comparison needs the EC2 harness and
  a results file under `docs/slop/results/`.
- The occupancy bitmap avoids a 128-KiB table clear per call. On the other
  side of that trade, the table is larger than the reference C's small-block
  table. Measure before changing either size.
