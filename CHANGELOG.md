# Changelog

All notable changes to compress are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.3.0] - 2026-11-10

### Added

- `brotli.decode.decompressBuffered` and `brotli.decode.Buffer`: the
  one-shot decode with its state (about 2.6 MiB, the meta-block tree region)
  in memory the caller places instead of on the stack.
- `brotli.decode.decompressCounted(source, target, buffer)`: the buffered
  one-shot decode, also returning the stream's length in `source`, so a
  caller can find or refuse trailing bytes.
- `flate.encode.Level` gains `@"7"` and `@"9"`: hash chains with lazy match
  evaluation, smaller output than level 6 at lower speed, through `flate`,
  `zlib`, and `gzip`, one-shot and `Writer`.
- `flate.encode.Options.strategy`, and the same field on `zlib.encode.Options`
  and `gzip.encode.Options`: `.filtered` tunes levels 7 and 9 for predictor
  residuals such as PNG's filtered rows.
- `flate.Writer.initInPlace`, `zlib.Writer.initInPlace`, and
  `gzip.Writer.initInPlace` start a stream in existing memory without the copy
  that assigning a new writer makes.

### Changed

- The package builds and tests on Zig 0.17.0 as well as 0.16.0.
  `minimum_zig_version` stays `"0.16.0"`, so a consumer on either version
  resolves the same tree: the version-dependent builtins and type info go
  through a private shim module, and the public API is the same on both.
- aarch64-macos is now in the support tier with x86_64-linux and
  aarch64-linux: a failure on any of the three fails CI. Every other target
  remains best effort.
- `brotli` decodes meta-blocks with up to 256 trees in each category, the
  format's ceiling, where it refused more than 64 with `TooManyTrees`;
  brotli 1.2.0 writes up to 256 literal trees at q4 to q9 on inputs of a
  megabyte. The tree region grows to match: `brotli.Reader.DefaultBuffer`
  is about 18.6 MiB (was 16.7), and `brotli.decode.decompress` keeps about
  2.6 MiB on the stack (was 691 KiB); `decompressBuffered` keeps it off the
  stack. `TooManyTrees` is gone from `DecompressError` and
  `Reader.Error`.
- `flate.Writer.Buffer`, and so `zlib.Writer.Buffer` and
  `gzip.Writer.Buffer`, is a struct holding the window (`window`, the
  former 98,303-byte array) and a block emission's token list and
  compressed-output scratch, 426,636 bytes in all: emitting a block no
  longer takes about 320 KiB of stack, and the writer itself is unchanged.
  Code that indexed the buffer indexes `buffer.window`.
- Short streams compress 2 to 4 times faster: a writer no longer zeroes its
  match-finder tables when it is created, and level 6 no longer clears its
  256-KiB token array for every block.
- `flate.Reader`, and so `zlib.Reader`, `gzip.Reader`, and the zlib and gzip
  one-shot decoders, inflate Huffman blocks 2 to 2.6 times faster: symbols
  decode from a 64-bit bit buffer over the input's buffered bytes, and the
  literal/length table's primary lookup is 10 bits.
- `flate.Reader` inflates a further 1.25 to 1.6 times faster on PNG image
  data, small icon streams included: table entries carry each symbol's
  length or distance base and bit counts, the literal/length table is 11
  bits and builds without a full fill, and up to four literals decode per
  refill.
- `flate.Reader` inflates 4 to 13% faster again on PNG image data: the fast
  loop's bit count and match reach check are cheaper.
- `flate.Reader` and `zlib.Reader` inflate short streams such as TIFF's
  8-KiB Deflate strips 1.05 to 1.39 times faster, and PNG image data 2 to
  33% faster: a block's Huffman tables build without counting and sorting
  symbol by symbol, its header decodes from a bit buffer, and Adler-32 folds
  without multiplies.
- Deflate encodes short streams faster, through `flate`, `zlib`, and `gzip`,
  one-shot and `Writer`: up to 1.28 times at level 1 and 1.08 at levels 6
  and 7 on 8 KiB TIFF strips, from clearing a stream's emitter and each
  Huffman tree's scratch without compiler_rt's byte-wise `memset`.
- `flate.Reader` inflates 2 to 6% faster on photographs' TIFF strips and PNG
  image data, and up to 17% on images with long runs: the fast loop reads its
  input through a cursor.

### Fixed

- Zig packages retain `LICENSE` and `THIRD_PARTY.md` after extraction.
- `zstd.encode` and `zstd.Writer` on big-endian targets took a match's
  length from the wrong end of a vector compare, so frames could decode to
  the wrong bytes (`WrongChecksum`) or differ from the reference encoder's;
  they now write the same frames as on little-endian targets.

## [0.2.0] - 2026-10-31

### Changed

- `flate.encode.Options`, `gzip.encode.Options`, `zlib.encode.Options`, and
  `zstd.encode.Options` require every field: replace `.{}` with `.init` (level
  1, no dictionary) and name every field in a partial literal. Public structs
  that carried field defaults now name a constructor too
  (`brotli.distance.Ring.init`, `brotli.command.State.init`,
  `flate.dynamic.TokenList.empty`, `flate.dynamic.HuffmanEncoder.empty`,
  `gzip.crc32.Checksum.init`, `zlib.adler32.Checksum.init`,
  `zstd.block_compress.State.init`, `zstd.frame.HeaderParser.init`,
  `zstd.xxh64.State.init`, and their peers): construct through those instead
  of a bare `.{}`.

## [0.1.0] - 2026-10-25

### Added

- `compress`: one Zig module with a namespace per codec. The default APIs take
  caller-owned buffers and allocate nothing, and streaming goes through
  `std.Io`.
- `snappy`: block encode and decode, plus a streaming `Writer` and `Reader`
  over Google's framed format: the `sNaPpY` identifier, per-chunk masked
  CRC-32C, and skippable chunks.
- `flate` (RFC 1951): raw DEFLATE both directions, levels 1 and 6, named by
  the zlib scale in a `Level` enum.
- `gzip` (RFC 1952) and `zlib` (RFC 1950): both directions over `flate`, with
  the container checksum verified on decode and a preset dictionary option.
- `zstd` (RFC 8878): decode with the frame checksum and content size verified,
  levels 1 and 3 byte-identical to the reference CLI in a `Level` enum,
  dictionaries through `zstd.Dictionary.parse` and `zstd.Dictionary.initRaw`,
  and streaming.
- `brotli` (RFC 7932): the complete decoder, including the static dictionary,
  and an encoder at quality 3, both one-shot and streaming.
- `examples/`: one command-line tool per codec, compiled and exercised by
  `just test`.
