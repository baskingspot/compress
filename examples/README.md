# Examples

One CLI per codec — snappy, flate, gzip, zlib, zstd — over a file argument
or stdin, writing to stdout:

```sh
zig build example-snappy -- encode README.md > /tmp/out.snappy
zig build example-snappy -- decode /tmp/out.snappy > /tmp/out
cmp README.md /tmp/out
cat README.md | zig build example-snappy -- encode - > /tmp/out.snappy
```

Or via just: `just example snappy encode README.md > /tmp/out.snappy`.

Shared scaffolding lives in `examples/cli.zig`: argument parsing (`encode` /
`decode`, one optional path, `-` or no path for stdin), the input as an
`Io.File.Reader`, and stdout as an `Io.File.Writer`. A codec's example file
declares one `cli.Codec` — its name and its streaming pumps — and both `main`
and the round-trip test run that declaration. The pumps are stack-buffered,
allocation-free end to end; zstd's decode is the one divergence, its 8 MiB
default window comes from the run's arena (`examples/zstd.zig`).

zstd is decode-only until M5 adds the encoder: `cli.Codec.encode` is null
there, and `zstd encode` reports usage.

The framing is the codec package's, not the example's (snappy's:
`src/snappy/README.md`, "Streaming"). The examples exist to feel the codec
APIs in real usage: wrap, pump, finish.
