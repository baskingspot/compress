<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="compress" height="48">
  </picture>
</h1>

Compression codecs in pure Zig: Snappy, DEFLATE, gzip, zlib, and Zstandard, plus a Brotli decoder.

`compress` is one Zig module with a namespace per codec. The caller owns
every buffer, and the default APIs do not allocate: zstd's streaming
`*Alloc` variants are the opt-in that takes an allocator, for buffers too
large for a stack. Streaming goes through `std.Io`. The module imports only
`std` and [fastmem](https://github.com/mattrobenolt/fastmem-zig).

## What is in it

| Namespace                        | Format                       | Support                                      |
| -------------------------------- | ---------------------------- | -------------------------------------------- |
| [`snappy`](src/snappy/README.md) | Snappy blocks                | encode, decode, streaming                    |
| [`flate`](src/flate/README.md)   | raw DEFLATE, RFC 1951        | encode, decode, streaming, preset dictionary |
| [`gzip`](src/gzip/README.md)     | gzip, RFC 1952, over `flate` | encode, decode, streaming                    |
| [`zlib`](src/zlib/README.md)     | zlib, RFC 1950, over `flate` | encode, decode, streaming, preset dictionary |
| [`zstd`](src/zstd/README.md)     | Zstandard, RFC 8878          | encode, decode, streaming, dictionaries      |
| [`brotli`](src/brotli/README.md) | Brotli, RFC 7932             | encode (quality 3), decode, streaming        |

Each codec README documents its API, error sets, and buffer sizes. The specs are vendored in [`docs/research/specs/`](docs/research/specs/README.md).

Not implemented:

- Brotli custom dictionaries: a custom or shared dictionary is outside RFC 7932, so there is no API for one.
- The zstd CLI trains dictionaries; this package consumes them.

The snappy `Reader` and `Writer` use a length-prefixed framing of this package's own, not Google's framing format. It has no end marker or checksum, so a stream cut at a block boundary reads as complete.

## Install

```sh
zig fetch --save git+https://github.com/baskingspot/compress
```

Add the module to your build:

```zig
const compress = b.dependency("compress", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("compress", compress.module("compress"));
```

Then import a codec:

```zig
const gzip = @import("compress").gzip;
```

`std` has a `std.compress` of its own. In a file that uses both, bind this module as `compressx`.

`compress` builds with Zig 0.16 only. [`examples/`](examples/README.md) has a command-line tool for each codec.

## Design

- The caller owns every buffer. One-shot functions take `source` and `target` slices, and the streaming types take a caller-provided buffer. zstd's default buffers are too large for a stack, at 8 MiB for the `Reader` window and 2.2 MiB for the `Writer`, so its `*Alloc` pumps take an allocator.
- Streaming is `std.Io`. A `Writer` compresses into an `Io.Writer`, and a `Reader` decompresses from an `Io.Reader`.
- Decoders return an error on corrupt input, and on truncated input where the format allows it.
- Vector code uses `@Vector` and `std.simd`, sized at compile time for the build target. The one inline-assembly kernel is the snappy decoder's byte shuffle, `tbl` on aarch64 and `pshufb` on x86, with a portable fallback.
- A codec can be copied out on its own: its directory and `src/internal/`, plus `src/flate/` for gzip and zlib, under one module root. They need only `std` and fastmem.

## Work on it

```sh
nix develop   # Zig 0.16, zls, ziglint, zigdoc, and the rest
just ci       # unit tests, lint, and the cross-target compile gate
just fuzz     # fuzz every codec's targets, 10M iterations each by default
just bench    # local benchmarks
```

`just` lists every recipe. Numbers from `just bench` are local and are not claims. Comparisons with other libraries are measured on EC2 by the harness in [`bench/`](bench/README.md) and written up under `docs/results/`.

## License

MIT. See `LICENSE`. Ports and vendored artifacts are listed in [`THIRD_PARTY.md`](THIRD_PARTY.md). The logo files in `docs/static/` are baskingspot marks and are not covered by it. See `docs/static/LICENSE`.

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).

<a href="https://github.com/baskingspot"><img src="https://raw.githubusercontent.com/baskingspot/.github/main/brand/assets/badge.svg" alt="baskingspot" height="24"></a>
