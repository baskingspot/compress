# Changelog

All notable changes to compress are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- `flate`, `gzip`, and `zlib` take a `Level` enum (`@"1"` and `@"6"`), and
  `zstd` its own (`@"1"` and `@"3"`), instead of a number. A bad level is a
  compile error, and `error.Unimplemented` leaves `compress`. A numeric level
  from a config maps with `Level.fromInt` and handles the null.
- `snappy.Writer` and `snappy.Reader` use Google's framed format: the
  `sNaPpY` identifier, per-chunk masked CRC-32C, and skippable chunks. Streams
  interoperate with other framed-snappy tools; streams from the previous
  length-prefixed framing do not decode.
- `brotli.encode` and `brotli.Writer` take no options: quality 3 is the only
  encoder class, so the one-value `Options` is gone. The one-shot is
  `compress(source, target)`, the writer `init(window_wbits, output, buffer)`.

### Added

- `compress`: one Zig module with a namespace per codec. The default APIs take
  caller-owned buffers and allocate nothing, and streaming goes through
  `std.Io`.
- `snappy`: block encode and decode, plus a streaming `Writer` and `Reader`
  over a length-prefixed framing of this package's own.
- `flate` (RFC 1951): raw DEFLATE both directions, levels 1 and 6.
- `gzip` (RFC 1952) and `zlib` (RFC 1950): both directions over `flate`, with
  the container checksum verified on decode and a preset dictionary option.
- `zstd` (RFC 8878): decode with the frame checksum and content size verified,
  levels 1 and 3 byte-identical to the reference CLI, dictionaries through
  `zstd.Dictionary.parse` and `zstd.Dictionary.initRaw`, and streaming.
- `brotli` (RFC 7932): the complete decoder, including the static dictionary,
  and an encoder at quality 3, both one-shot and streaming.
- `examples/`: one command-line tool per codec, compiled and exercised by
  `just test`.
