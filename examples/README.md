# Examples

One command-line tool per codec: snappy, lz4, flate, gzip, zlib, zstd, and brotli.
Each encodes or decodes a file argument or stdin and writes to stdout:

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
functions, and the tests run the same functions. For snappy, flate, gzip, and
zlib, each function is one call to the codec's `Writer.streamAll` or
`Reader.streamAll`, with buffers on the stack. zstd's two directions call the
`*Alloc` pumps instead: a 512-KiB-window Writer buffer and an 8 MiB-window
Reader buffer are too large for a stack. They take them from the run's arena
(`examples/zstd.zig`), and brotli's `Writer` and `Reader.DefaultBuffer` also
come from the arena the same way (`examples/brotli.zig`).

The lz4 tool has no streaming API to call. It reads and writes independent
64 KiB blocks behind two little-endian `u32` lengths: decoded, then compressed.
That record header belongs to `examples/lz4.zig` and is not the LZ4 frame
format. Its buffers stay on the stack.

The snappy tool reads and writes Google's framed format, so its output is a
`.sz`-style stream that other snappy tools read. The other stream tools use
their codec package's format. The lz4 tool is the exception: its record header
is example-only because a raw LZ4 block has no lengths. The examples double as
short, complete uses of the codec APIs.
