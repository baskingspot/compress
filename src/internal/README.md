# internal

Code shared by more than one zcompress codec. It is not public API: the barrel
(`src/root.zig`) and the codec namespaces never re-export it, and there is no
build module for it. A codec reaches it by relative import:

```zig
const internal = @import("../internal/root.zig");
```

The layer imports only `std` and `fastmem` and holds no codec-specific state.
Code moves here when a second codec needs it, not before.

- `sentinel.zig`: the byte pattern decode tests pre-fill output buffers with,
  and the check that a decode did not write past its decoded length.
- `reader.zig`: the `Io.Reader` lifecycle (`State`, `guard`, `fail`) and the
  generated reader vtable entries.
- `writer.zig`: the generated `Io.Writer` entries and `finish` for
  block-based compressing writers.
- `int.zig`: little-endian and big-endian integer access, which each codec's
  `common.zig` binds to its wire byte order.
- `container.zig`: the reader, writer, and one-shot drivers that gzip and zlib
  share over flate. Each container supplies its own framing.

Each file's `//!` header lists its entry points and what a codec has to supply.

## Copying a codec out

A codec that uses this layer takes it along. Copy the codec's directory and
`src/internal/` into a project, add `fastmem` as a dependency, and make the
module root a file in a directory above both. Relative imports cannot leave the
module root's directory, so rooting the module at the codec's own `root.zig`
fails with "import of file outside module path". The repo's `src/root.zig` is
that kind of root file.

Notes on the `std.Io` contracts that the generated reader and writer code
relies on are in `AGENTS.md`.
