# Examples

One command-line tool per codec: snappy, flate, gzip, zlib, zstd, and brotli. Each
encodes or decodes a file argument or stdin and writes to stdout. brotli only decodes, because
the codec has no encoder:

```sh
zig build example-snappy -- encode README.md > /tmp/out.snappy
zig build example-snappy -- decode /tmp/out.snappy > /tmp/out
cmp README.md /tmp/out
cat README.md | zig build example-snappy -- encode - > /tmp/out.snappy
```

Or via just: `just example snappy encode README.md > /tmp/out.snappy`.

`examples/cli.zig` holds what the tools share: argument parsing (`encode` or
`decode`, then one optional path, where `-` or no path means stdin), the input
as an `Io.File.Reader`, and stdout as an `Io.File.Writer`. Each codec's file
gives `cli.run` a `cli.Codec`, which is the codec's name and its streaming
functions, and the tests run the same functions. Each function is one call to
the codec's `Writer.streamAll` or `Reader.streamAll`, which buffer on the
stack, so those tools allocate nothing. zstd's two directions call the
`*Alloc` pumps instead — a 512-KiB-window Writer buffer and an 8 MiB-window
Reader buffer are too large for a stack — which take them from the run's
arena (`examples/zstd.zig`).

The stream format is the codec package's, not the example's. The snappy tool,
for instance, reads and writes the package's length-prefixed framing, not
Google's framing format. The examples double as short, complete uses of the
streaming API.
