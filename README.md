<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="compress" height="48">
  </picture>
</h1>

Compression codecs in pure Zig: Snappy, DEFLATE, gzip, zlib, Zstandard, and Brotli.

`compress` is one Zig module with a namespace per codec. The caller owns
every buffer, and the default APIs do not allocate: zstd's streaming
`*Alloc` variants are the opt-in that takes an allocator, for buffers too
large for a stack. Streaming goes through `std.Io`. The module imports only
`std` and [fastmem](https://github.com/baskingspot/fastmem).

## What is in it

| Namespace                        | Format                       | Support                                      |
| -------------------------------- | ---------------------------- | -------------------------------------------- |
| [`snappy`](src/snappy/README.md) | Snappy blocks                | encode, decode, streaming                    |
| [`flate`](src/flate/README.md)   | raw DEFLATE, RFC 1951        | encode, decode, streaming, preset dictionary |
| [`gzip`](src/gzip/README.md)     | gzip, RFC 1952, over `flate` | encode, decode, streaming                    |
| [`zlib`](src/zlib/README.md)     | zlib, RFC 1950, over `flate` | encode, decode, streaming, preset dictionary |
| [`zstd`](src/zstd/README.md)     | Zstandard, RFC 8878          | encode, decode, streaming, dictionaries      |
| [`brotli`](src/brotli/README.md) | Brotli, RFC 7932             | encode (quality 3), decode, streaming        |

Not implemented:

- Brotli custom dictionaries: a custom or shared dictionary is outside RFC 7932, so there is no API for one.
- A zstd dictionary trainer: the zstd CLI trains dictionaries, and this package consumes them.
- zstd levels other than 1 and 3: the rest return `error.Unimplemented`.
- Google's Snappy framing: the `Reader` and `Writer` use a length-prefixed framing of this package's own. It has no end marker or checksum, so a stream cut at a block boundary reads as complete.

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

`compress` builds with Zig 0.16 only.

## Documentation

- The [guide](https://baskingspot.dev/compress/) says which codec to use for a task, with examples that compile.
- The [API reference](https://baskingspot.dev/compress/api/) documents every symbol.
- [`examples/`](examples/README.md) has a command-line tool for each codec.
- Each codec's README documents its API, error sets, and buffer sizes. The specs are vendored in [`docs/research/specs/`](docs/research/specs/README.md).

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
