# Third-party notices

compress is MIT (`LICENSE`). This file lists every port, vendored artifact,
and dependency with a license that is not ours.

## Ports

- `src/snappy/encode.zig`: a port of the algorithm in klauspost/compress
  (BSD-3-Clause) `encodeBlockSnappyGo64K`, itself descended from the
  Snappy-Go reference encoder. The algorithm is ported, not the code.
  Attribution: Copyright klauspost/compress contributors,
  https://github.com/klauspost/compress (s2/encode_all.go).
- `src/flate/encode.zig`: a port of the algorithm in klauspost/compress
  (BSD-3-Clause) `flate/level1.go` (`fastEncL1`) and `flate/fast_encoder.go` —
  the single-slot `[1 << 15]` table, the 5-byte hash and its `prime5bytes`,
  the accelerating skip, the 4-byte confirm, the backward extension, and the
  258/255 match split. The algorithm is ported, not the code. Attribution:
  Copyright klauspost/compress contributors,
  https://github.com/klauspost/compress.
- `src/flate/encode.zig` (level 6) and `src/flate/dynamic.zig`: ports of the
  algorithms in klauspost/compress (BSD-3-Clause) `flate/level6.go`
  (`fastEncL6`: the two hash tables, the accelerating skip, the candidate
  arbitration, the end-of-match check), `flate/huffman_code.go` (the
  length-limited tree construction), and `flate/huffman_bit_writer.go` (the
  codegen, the dynamic header, the cost model, the stored/fixed/dynamic
  dispatch). The algorithm is ported, not the code; the oracle's level-6 lane
  checks the bytes against the pinned module (`scripts/klauspost_flate`).
  Attribution: Copyright klauspost/compress contributors,
  https://github.com/klauspost/compress.
- `src/snappy/golden.zig` golden fixtures: ported from golang/snappy
  (BSD-3-Clause) `TestDecode`, `TestDecodeCopy4`, and `TestDecodeLengthOffset`
  tables. Attribution: Copyright the Go Authors,
  https://github.com/golang/snappy (decode_test.go).
- `src/flate/golden.zig` golden fixtures: ported from golang/go
  (BSD-3-Clause) `src/compress/flate/flate_test.go` (`TestStreams`,
  `TestTruncatedStreams`), `inflate_test.go` (`TestReaderTruncated`), and
  `deflate_test.go` (`deflateTests`, as decode goldens), plus two
  preset-dictionary streams generated with python3's `zlib` (the C
  reference, `compressobj(..., zdict=...)`) and the dictionaries they were
  built against. Attribution: Copyright the Go Authors,
  https://github.com/golang/go; Jean-loup Gailly and Mark Adler (zlib).
- `src/flate/testdata/huffman-*`: the nine `.in`/`.golden` pairs vendored
  verbatim from golang/go (BSD-3-Clause)
  `src/compress/flate/testdata/`. Attribution: Copyright the Go Authors,
  https://github.com/golang/go.
- `src/gzip/golden.zig` golden fixtures: ported from golang/go
  (BSD-3-Clause) `src/compress/gzip/gunzip_test.go` (`gunzipTests`,
  `TestTruncatedStreams`, `TestIssue6550`, `TestMultistreamFalse`,
  `TestNilStream`, `TestCVE202230631`) and `gzip_test.go` (`TestEmpty`,
  `TestWriterFlush`, as policy fixtures), plus Zig 0.16 std's in-tree gzip
  container tests (`std/compress/flate/Decompress.zig`, MIT) as decoder
  goldens and divergence pins. Attribution: Copyright the Go Authors,
  https://github.com/golang/go; Zig std contributors.
- `src/gzip/testdata/issue6550.gz.base64`: vendored verbatim from golang/go
  (BSD-3-Clause) `src/compress/gzip/testdata/issue6550.gz.base64` — the
  decompression-hang regression's input. Attribution: Copyright the Go
  Authors, https://github.com/golang/go.
- `src/zlib/golden.zig` golden fixtures: ported from golang/go
  (BSD-3-Clause) `src/compress/zlib/reader_test.go` (`zlibTests`, whose own
  comment records that the golden bytes came from the C reference's
  `zpipe.c`), plus Zig 0.16 std's in-tree zlib container tests
  (`std/compress/flate/Decompress.zig`, MIT) as decoder goldens and
  divergence pins (the fixed and dynamic members are std's gzip bodies with
  zlib's framing), and the C-reference emissions verified through python3's
  `zlib` in `docs/research/containers-notes.md §5.5`. Attribution: Copyright
  the Go Authors, https://github.com/golang/go; Zig std contributors; Jean-loup
  Gailly and Mark Adler (zlib, the `78 3f` corner emission and the dictionary
  vector's DICTID check).
- `src/brotli/huffman.zig`: the two-level decode table's proven size ceiling
  (`max_table_size_by_block`) and the code-length prefix tables
  (`cl_prefix_length`/`cl_prefix_value`) are transcribed from google/brotli
  v1.2.0 (MIT) `c/dec/huffman.c` (`kMaxHuffmanTableSize`,
  `kCodeLengthPrefixLength`/`Value`). The tables themselves are built by this
  package's own two-pass construction, verified against that ceiling.
  Attribution: Copyright the Brotli Authors,
  https://github.com/google/brotli.
- `src/brotli/dictionary.bin`, `src/brotli/dictionary_data.zig`,
  `src/brotli/dictionary.zig`: the static dictionary (122,784 bytes) and the
  121 word transforms, generated from RFC 7932's Appendix A hex and Appendix B
  table by `scripts/brotli_dictionary_gen.py` — the vendored RFC text is the
  only data source. The transforms' deduplicated representation (the
  length-prefixed prefix/suffix pool, the pool-offset map, the
  `[prefix id, elementary transform, suffix id]` triplets, and the
  `cutOffTransforms` table) and the transform arithmetic (Ferment's case-flip
  semantics, `BrotliTransformDictionaryWord`) follow google/brotli v1.2.0
  (MIT) `c/common/transform.c`/`transform.h`. The generator and the port were
  written from the RFC; the reference is the differential oracle. Attribution:
  Copyright the Brotli Authors, https://github.com/google/brotli; the RFC's
  authors for the data.
- `src/flate/decode.zig` lineage: the two-level Huffman decode table (a
  9-bit primary table plus a chained chase for longer codes) follows the
  algorithm in zlib's `doc/algorithm.txt` (zlib license, studied), as used by
  Zig std's `std.compress.flate.Decompress.zig` (MIT, in-tree, studied).
  Reimplemented in this package's shape — wire-bit orientation, table
  packing, chain layout, and the completeness rules are ours; no code copied.
- `src/zstd/` encoder (`match_compress.zig`, `block_compress.zig`,
  `literals_compress.zig`, `sequences_compress.zig`, `fse_compress.zig`,
  `huff0_compress.zig`, and the writer inverses in `bits.zig`): a port of the
  algorithms in facebook/zstd v1.5.7 (BSD-3-Clause or GPLv2) — the level-1
  fast match finder (`zstd_fast.c`), the block emission ladder
  (`zstd_compress.c`), the literals and sequences sections
  (`zstd_compress_literals.c`, `zstd_compress_sequences.c`), the FSE
  normalize/table builder and description writer (`fse_compress.c`), and the
  Huffman tree builder, tree-description writer, and streams
  (`huf_compress.c`), including the hash primes and the FSE rounding table
  (`rtbTable`). The algorithm is ported, not the code; `encode.zig` and
  `Writer.zig` follow the same reference's frame-header and block-chain
  emission (`ZSTD_writeFrameHeader`, `ZSTD_compressContinue_internal`).
  Attribution: Copyright (c) Meta Platforms, Inc. and affiliates,
  https://github.com/facebook/zstd.
- `src/zstd/xxh64.zig`: a port of the XXH64 algorithm following Zig std's
  `std/hash/xxhash.zig` (MIT; itself the xxHash reference, public domain at
  github.com/Cyan4973/xxHash) with one deliberate change: the running byte
  count is `u64`, where std's is a `usize` that wraps past 2^32 on 32-bit
  targets. The algorithm is ported with the change; the attribution covers
  the reference. std's `XxHash64` stays in the tests as the differential
  oracle.
- `src/flate/encode.zig` persistent `FinderTable`: the `Lookup`/persistent-chain
  design in Zig std's `std.compress.flate` (MIT) is studied, not copied
  (absolute wrapping positions; `docs/research/flate-notes.md` §8).

## Vendored specs (`docs/research/specs/`)

Verbatim spec text, fetched once with provenance recorded in the directory
`README.md`. IETF RFCs are freely distributed. The Snappy format description
comes from google/snappy (BSD-3-Clause).

## Studied, not copied

Reference implementations read or run to settle behavior. No code is copied from
them; the rows are here so the debt is visible.

- `src/gzip/`, `src/zlib/`: klauspost/compress (BSD-3-Clause) `gzip/` and `zlib/`,
  the Go stdlib containers over the klauspost flate engine, for the header and
  trailer emission policy and where the checksum is computed.
- `src/gzip/crc32.zig`, `src/zlib/adler32.zig`: ebiggers/libdeflate (MIT)
  `lib/crc32.c`, `lib/adler32.c`, `lib/gzip_compress.c`, `lib/gzip_decompress.c`,
  for the checksum function shape and the single-member boundary reported to the
  caller. zlib-ng (zlib license) `crc32.c`, `adler32.c`, `arch/**`, `zutil.h` for
  the kernel dispatch landscape and the gzip OS byte survey.
- `src/gzip/`, `src/zlib/`: Zig std's container handling in
  `std.compress.flate` (MIT), studied for its decoder laxness (no trailer or
  FCHECK verification, no reserved-bit check), which the tests pin as
  divergences.
- `src/zstd/`: the reference zstd C library and CLI v1.5.7 (BSD-3-Clause or
  GPLv2) as the encoder port's source (the port row above) and as the
  behavior oracle for both directions; klauspost/compress (BSD-3-Clause)
  `zstd/` for its error vocabulary, the level-1 encoder decisions it makes
  differently (`TE1`-`TE5` in `src/zstd/AGENTS.md`), and the strict-window
  decoder behind `just zstd-oracle`; Zig std's zstd decoder (MIT) for its
  `ReverseBitReader`, and for the unverified checksum and rejected dictionary
  frames that the tests pin as divergences.
- madler/zlib's emission rules were verified through python3's `zlib` and `gzip`
  modules (PSF) used as a CLI oracle. Nothing is vendored.

## Dependencies

- fastmem (`https://github.com/mattrobenolt/fastmem-zig`, MIT): the blessed
  memory-copy primitive for codec hot paths. Pinned in `build.zig.zon`.
- testingx (`https://github.com/baskingspot/testingx`, MIT): the plain-text
  test runner, the local benchmark harness behind `zig build bench`, and the
  comptime fixtures. Pinned in `build.zig.zon`, lazy. The fuzz path
  (`-Dfuzz`) uses the default runner. Used by the test and bench steps only,
  never by codecs.
