+++
title = "compress"
+++

Compression codecs in pure Zig: Snappy, DEFLATE, gzip, zlib, Zstandard, and Brotli.

One module, a namespace per codec, the same buffer discipline everywhere: the caller owns every buffer, the default APIs do not allocate, and every failure has a name. Streaming goes through `std.Io`. The encoders target the speed class — the zstd encoder is byte-identical to `zstd -1` at level 1 and `zstd -3` at level 3 — and the zstd decoder verifies what the C library does not.

- [Codecs](#codecs): one namespace per format, and which of them are containers over `flate`.
- [Choose std or compress](#choose-std-or-compress): what `std.compress` has in 0.16, and what this package adds. gzip, zlib, and Snappy are missing from std entirely; zstd in std is decode-only.
- [One-shot encode and decode](#one-shot-encode-and-decode): the same shape in every codec. Encode returns the compressed length, decode returns the decoded length, and both take caller-owned buffers.
- [Size the buffers](#size-the-buffers): every encoder exports its exact worst case, and decode never writes past the length it returns.
- [Streaming](#streaming): `Writer` and `Reader` over `std.Io`, with one-call pumps.
- [Dictionaries](#dictionaries): zstd dictionaries both directions, the zlib preset, and why there is no trainer in here.
- [Choose a codec](#choose-a-codec): which format for which job, and what each one costs.
- [Errors and corrupt input](#errors-and-corrupt-input): closed error sets, named per failure, `error.BufferTooSmall` before any byte past the cap.
- [Design](#design): how the SIMD code is built, and how to copy one codec out on its own.
- [Performance](#performance): what the 7-target EC2 grid measured, and the rule that local numbers are never claims.
- [Limits](#limits): what has no API, and what returns `error.Unimplemented`.

This guide is the recipes. The [API reference](api/) has the contract for every symbol. Each codec's README documents its API, error sets, and buffer sizes in the same terms.

# Getting started

## Install

```sh
zig fetch --save git+https://github.com/baskingspot/compress
```

Add the module to your build in `build.zig`:

```zig
const compress = b.dependency("compress", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("compress", compress.module("compress"));
```

`compress` builds with Zig 0.16 only.

## Import it

Bind a codec from the module, once per file:

```zig
const compress = @import("compress");
const gzip = compress.gzip;
```

If the file uses only one codec, import it directly:

```zig
const gzip = @import("compress").gzip;
```

`std` has a `std.compress` of its own. In a file that uses both, bind this module as `compressx`:

```zig
const compressx = @import("compress");
const zstd = compressx.zstd; // this package
const std_zstd = std.compress.zstd; // std, decode only
```

## Read the examples

Every example in this guide is a complete file in `docs/examples/`. The test step compiles and runs each one, so the code in this guide builds:

```sh
just test
```

# Codecs

| Namespace                        | Format                | Support                                      |
| -------------------------------- | --------------------- | -------------------------------------------- |
| [`snappy`](api/#compress.snappy) | Snappy blocks         | encode, decode, streaming                    |
| [`flate`](api/#compress.flate)   | raw DEFLATE, RFC 1951 | encode, decode, streaming, preset dictionary |
| [`gzip`](api/#compress.gzip)     | gzip, RFC 1952        | encode, decode, streaming                    |
| [`zlib`](api/#compress.zlib)     | zlib, RFC 1950        | encode, decode, streaming, preset dictionary |
| [`zstd`](api/#compress.zstd)     | Zstandard, RFC 8878   | encode, decode, streaming, dictionaries      |
| [`brotli`](api/#compress.brotli) | Brotli, RFC 7932      | encode (quality 3), decode, streaming        |

`flate` is the kernel: `gzip` and `zlib` are containers over it, each adding its framing, its checksum, and its own error names. `snappy`, `zstd`, and `brotli` are self-contained.

# Choose std or compress

`std.compress` in Zig 0.16 ships `flate` with both directions, `zstd` with decode only, and the LZMA family. It does not ship gzip, zlib, Snappy, or Brotli at all.

| Format  | std.compress 0.16 | this package                                                  |
| ------- | ----------------- | ------------------------------------------------------------- |
| DEFLATE | both directions   | both, one-shot and streaming, preset history                  |
| gzip    | not present       | both, one-shot and streaming                                  |
| zlib    | not present       | both, one-shot and streaming, preset history                  |
| Snappy  | not present       | both, one-shot and streaming                                  |
| zstd    | decode only       | both, byte-identical to `zstd -1` and `zstd -3`, dictionaries |
| Brotli  | not present       | both, one-shot and streaming                                  |

Use std when it has the direction you need and its shape fits. Use this package when you need the missing formats, a zstd encoder, or the same buffer discipline across every codec you touch. The decode paths here also check what std's zstd decoder does not: the frame checksum, the content size, and the dictionary ID, each with a named error.

# One-shot encode and decode

The one-shot shape is identical in every codec:

```zig
{{ load_data(path="examples/oneshot_roundtrip.zig", format="plain") | trim_end }}
```

Encode takes `source` and `target` and returns the compressed length. Decode takes the compressed bytes and a `target` cap and returns the decoded length. `target` on the decode side is a cap, not a promise: the decode may fill the cap on its way to a refusal, but a result that does not fit fails `error.BufferTooSmall` and nothing past the cap is ever written. The returned length carries the other half of the rule: decode never writes past it, so a larger target keeps its tail untouched.

# Size the buffers

Never guess a size. Every encoder exports its exact worst case, and Snappy's block form tells the decoder its exact decoded length up front:

```zig
{{ load_data(path="examples/choose_buffers.zig", format="plain") | trim_end }}
```

With the exact worst case, `snappy.encode.compressBlock` cannot fail, and its error set drops to `error{}` at the call site. For the other codecs, decode sizing is the caller's: gzip and zlib carry the decoded size only in their trailers, and a decode that must know it up front needs the caller's bound. Decode never writes past the length it returns, so a larger target keeps its tail untouched — every codec's test suite pins that rule with sentinels.

# Streaming

A `Writer` compresses into an `Io.Writer`, and a `Reader` decompresses from an `Io.Reader`. `finish` is required on the encode side: it writes the trailer. One-call pumps move a whole stream:

```zig
{{ load_data(path="examples/streaming_pump.zig", format="plain") | trim_end }}
```

## Who allocates

The codec holds no allocator, and every call that allocates says so in its name. This table is the whole contract:

| Call                                                    | Allocates                                                                             |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| One-shot `encode` and `decode`                          | Nothing. The caller passes both buffers.                                              |
| `Writer.init` and `Reader.init`                         | Nothing. The caller passes the named `Buffer` type.                                   |
| `Writer.streamAllAlloc` and the `Reader` `*Alloc` pumps | One `DefaultBuffer` from the caller's allocator. It is freed before the call returns. |
| `Io.Writer.Allocating` and `allocRemaining` in examples | Caller-side scaffolding. These belong to the example, not to the codec.               |

A `Buffer` is storage that the codec writes into, not state that it owns. The type's size decides where it lives. `gzip.Writer.Buffer` is `[98303]u8`, so a stack local is fine. The zstd types are too large for that: `zstd.Reader.DefaultBuffer` is 8 MiB + 256 KiB and `zstd.Writer.DefaultBuffer` is 2.2 MiB, so keep those in static or heap storage. The `*Alloc` pumps take an allocator for exactly that buffer.

A failed allocation from a `*Alloc` pump is `error.OutOfMemory`.

The container codecs are self-delimiting at the member boundary: `gzip.Reader.streamAll` walks every member in a multi-member stream, and the exact boundary stays visible when a caller needs to stop there. Snappy's streaming framing is this package's own length-prefixed form, not Google's: it has no end marker and no checksum, so a stream cut at a block boundary reads as complete. Snappy framing is a decision to make with that in mind.

# Dictionaries

A dictionary is caller bytes, and both sides must supply the same bytes. zstd takes a parsed `Dictionary`: `parse` reads the formatted form that `zstd --train` writes, and `initRaw` takes any bytes at all, used as history with no entropy tables. The zlib preset is raw bytes in both directions, with FDICT and the DICTID check the RFC describes:

```zig
{{ load_data(path="examples/dictionary_zstd.zig", format="plain") | trim_end }}
```

```zig
{{ load_data(path="examples/dictionary_zlib.zig", format="plain") | trim_end }}
```

The value borrows the file bytes: keep them alive as long as the dictionary is. A raw dictionary carries no ID — a frame made with one decodes without it only until a match reaches back into history that is not there, and fails `error.OffsetTooFar`. A formatted dictionary carries a DICTID, and its frames refuse by name: `DictionaryRequired` when none is supplied, `DictionaryMismatch` for the wrong one. The zlib preset fails the same way. gzip has no dictionary concept (RFC 1952 defines none), and Brotli's static dictionary already ships inside the decoder — RFC 7932 defines no way to supply your own.

There is no trainer in this package, on purpose. Training is a tooling decision the `zstd` CLI already makes well; this package is the consumer side.

# Choose a codec

Pick the format for the job, not the fastest name:

| You need                        | Use    | The trade                                                    |
| ------------------------------- | ------ | ------------------------------------------------------------ |
| The smallest payloads           | zstd   | The heaviest format of the five; also the best ratio         |
| Interop with everything         | gzip   | DEFLATE's ratio and speed, universal acceptance              |
| A zlib-shaped wire format       | zlib   | gzip without the file framing, plus a preset dictionary      |
| In-memory blocks, latency-bound | snappy | No ratio to speak of; the framing here is this package's own |
| Web text, either direction      | brotli | Encoder at quality 3; the static dictionary ships inside     |

The zstd encoder is byte-identical to `zstd -1` at level 1 and `zstd -3` at level 3, which pins it to the fast class; levels 2 and 4-19 on the CLI's 1-19 scale return `error.Unimplemented`. The DEFLATE encoder's level 1 writes fixed-Huffman and stored blocks only; its level 6 writes dynamic-Huffman blocks and is byte-identical to klauspost/compress's level 6; `gzip` and `zlib` inherit both.

# Errors and corrupt input

Every failure has a name, the sets are closed per codec, and the names say what was wrong with the bytes rather than which layer noticed:

```zig
{{ load_data(path="examples/errors_named.zig", format="plain") | trim_end }}
```

Hostile input gets error returns, never assertions: the decoders treat every input as untrusted, and the fuzz suites pin the error names per mutation class. Truncated input fails by name too — `error.Truncated` for a DEFLATE stream cut before its final block, and each container adds its own names for its framing (`error.BadHeader` for gzip's magic, `error.BadMagic` for zstd's).

# Design

- Vector code uses `@Vector` and `std.simd`, sized at compile time for the build target. The one inline-assembly kernel is the snappy decoder's byte shuffle, `tbl` on aarch64 and `pshufb` on x86, with a portable fallback.
- A codec can be copied out on its own: its directory and `src/internal/`, plus `src/flate/` for gzip and zlib, under one module root. The copy needs only `std` and fastmem.

# Performance

The encoders and decoders target the fast class, and the numbers are measured, not asserted. Every comparison runs on a 7-target EC2 grid — ARM and Intel — against the C reference libraries, 5 rounds each with an A/A control, and every claim names a run and a results file in [`docs/results/`](https://github.com/baskingspot/compress/tree/main/docs/results):

- The zstd encoder is at parity to faster than facebook/zstd's C library at the level-1 class on literal-heavy input on every ARM target, with both sides paying the frame checksum. It is 4-17x faster than klauspost/compress's Go zstd on entropy-heavy input. The zstd decoder verifies the frame checksum and the content size that the C library skips.
- The Brotli encoder's one-shot beats google/brotli's C encoder on every encode row of the encoder-seats run: 1.4-2.4x on text and HTML, up to 10.7x on random and mixed input. The numbers are in [`docs/results/encoder-seats-fleet-20261017.md`](https://github.com/baskingspot/compress/blob/main/docs/results/encoder-seats-fleet-20261017.md).
- Brotli decoding is 2-3x faster than google/brotli's C decoder on copy-structure input, and the remaining gaps are entropy rows with ranked, measured causes.
- Local `just bench` numbers are never claims. The grid and the methodology are in [`bench/README.md`](https://github.com/baskingspot/compress/blob/main/bench/README.md).

No allocation on the hot paths, no `Io` value held, and the caller's buffers are the only memory the codecs touch.

# Limits

- Brotli takes no custom or shared dictionary. RFC 7932 defines no way to supply one, so there is no API.
- There is no zstd dictionary trainer. The `zstd` CLI trains, and this package consumes.
- The zstd encoder implements levels 1 and 3. Levels 2 and 4-19 on the CLI's scale return `error.Unimplemented`.
- gzip has no dictionary, because RFC 1952 defines none.
- The snappy `Reader` and `Writer` use a length-prefixed framing of this package's own, not Google's framing format. The stream has no end marker and no checksum, so a stream cut at a block boundary reads as complete.
