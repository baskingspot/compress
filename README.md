# compress

Fast, self-contained compression codecs in pure Zig. Performance in the class
of [klauspost/compress](https://github.com/klauspost/compress), usability in
the class of `std.compress`.

compress is one Zig module with a namespace per codec. It imports only `std`
and [fastmem](https://github.com/mattrobenolt/fastmem-zig), and needs Zig 0.16.

## Codecs

| Namespace                        | Format                       | Support                   |
| -------------------------------- | ---------------------------- | ------------------------- |
| [`snappy`](src/snappy/README.md) | Snappy blocks                | encode, decode, streaming |
| [`flate`](src/flate/README.md)   | raw DEFLATE, RFC 1951        | encode, decode, streaming |
| [`gzip`](src/gzip/README.md)     | gzip, RFC 1952, over `flate` | encode, decode, streaming |
| [`zlib`](src/zlib/README.md)     | zlib, RFC 1950, over `flate` | encode, decode, streaming |
| [`zstd`](src/zstd/README.md)     | Zstandard, RFC 8878          | encode, decode, streaming |

Each codec README documents its API, error sets, and buffer sizes. The specs
are vendored in [`docs/research/specs/`](docs/research/specs/README.md). The
snappy `Reader` and `Writer` use a length-prefixed framing of this package's
own, not Google's framing format. It has no end marker or checksum, so a stream
cut at a block boundary reads as complete.

Not implemented: brotli, and zstd's `.ratio` level. The flate encoder writes
fixed-Huffman and stored blocks only, and gzip and zlib inherit that;
`Level.ratio`, the dynamic-Huffman mode, returns `error.Unimplemented`.
Dictionaries are unsupported: a zlib or zstd stream that needs one is rejected
with `DictionaryRequired`.

## Use

```sh
zig fetch --save git+https://github.com/baskingspot/compress
```

```zig
// build.zig
const compress = b.dependency("compress", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("compress", compress.module("compress"));

// your code
const gzip = @import("compress").gzip;
```

[`examples/`](examples/README.md) has a command-line tool for each codec.

## Design

- The caller owns every buffer. One-shot functions take `source` and `target`
  slices, and the streaming types take a caller-provided buffer. The codecs do
  not allocate. zstd's default buffers are too large for a stack — an 8 MiB
  window for `Reader`, 1.4 MiB for `Writer` — so the `*Alloc` pumps take an
  allocator for them.
- Streaming is `std.Io`: a `Writer` compresses into an `Io.Writer`, and a
  `Reader` decompresses from an `Io.Reader`.
- Decoders return an error on corrupt input and, where the format allows it, on
  truncated input.
- Vector code uses `@Vector` and `std.simd`, sized at compile time for the
  build target. The one inline-assembly kernel is the snappy decoder's byte
  shuffle (aarch64 `tbl`, x86 `pshufb`), with a portable fallback.
- A codec can be copied out on its own: its directory and `src/internal/`, plus
  `src/flate/` for gzip and zlib, under one module root. They need only `std`
  and fastmem.

## Testing and benchmarks

```sh
nix develop   # Zig 0.16.0, zls, ziglint, zigdoc
just test     # unit tests for every codec
just fuzz     # fuzz every codec's targets (10M iterations each by default)
just lint     # ziglint, zig fmt --check, ruff and ty on scripts/
just bench    # local benchmarks
```

Numbers from `just bench` are local and are not claims. Comparisons with other
libraries are measured on EC2 by the harness in [`bench/`](bench/README.md) and
written up under `docs/results/`.

## License

MIT. Ports and vendored artifacts are attributed in
[`THIRD_PARTY.md`](THIRD_PARTY.md).
