# Changelog

All notable changes to compress are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
