# Agent notes: internal

The codec-agnostic layer: code that more than one codec imports. `README.md` is
the human overview, and each file's `//!` header lists its entry points and what
a codec supplies. This file is the "Io codec pattern book": how a codec adopts
the shared machinery, and the `std.Io` contracts the generated code encodes.

## Design decisions

- A contract that cost a bug lives in one generated body, and the codec supplies
  only its own step, so a fix lands once. The layer exists because the same
  bugs were fixed once per codec (flate and snappy, then gzip and zlib).
- Readers: `reader.VTable(Host, pump, rebase)`. The codec supplies its fill and
  its `rebase`, and keeps `state` and `err` on the host.
- Writers: `writer.VTable(Host, emitBlock, ending)`. The codec supplies
  `emitBlock` and an optional stream ending (null when the format has none).
- Containers: `container.ReaderHooks`, `WriterHooks`, `EncodeHooks`, and
  `DecodeHooks` over the codec's `framing.zig` (header, trailer, checksum, error
  sets). The contract is the header of `container.zig`.
- Each codec's `common.zig` binds `int.little` or `int.big`. Decode tests
  pre-fill the target with `sentinel.fill` and check the tail with
  `sentinel.expect`.
- Worked examples: snappy and flate for readers and writers, gzip and zlib for
  containers.

## Io contracts

One entry per bug class: the rule, the one-line why, and where std states it.
The generated entries apply them, and a codec's own `pump`, `rebase`,
`emitBlock`, and framing code must keep them. Each is pinned by regression
tests in the codecs' `Reader.zig` and `Writer.zig`, and a new codec copies them.
"Fixed in" names the commit. std cites are line numbers in `std/Io/Reader.zig`
and `std/Io/Writer.zig` of Zig 0.16.0 (`zig env` prints `std_dir`); re-check
them on a toolchain bump.

### Fill and return 0, never the bytes-added count

`stream` and `readVec` return 0 whatever `pump` returns, because `pump` stores
bytes in `reader.buffer` (adjusting `seek` and `end`). The return value counts
bytes given to the caller's writer, and the interface advances by it, so
returning the stored count serves the same bytes twice. std: `Reader.zig:26-28`,
`:42-44`.

### The zero-length poll answers 0 without filling

`std.Io.Reader.stream` slices buffered bytes by `limit`, so a zero limit reaches
`vtable.stream` even when bytes are buffered. The generated `stream` answers 0
without calling `pump`: a fill can fail `StreamTooLong` on a valid stream whose
serving region cannot hold a fresh block beside the unconsumed bytes. Test it
with bytes buffered: peek, poll, assert `err == null`, then decode the rest.
std: `Reader.zig:168-177`. Fixed in flate (8057598) and snappy (5c5eb16).

### Sticky lifecycle: clean end, sticky failure, detail in `err`

- The interface has two coarse errors, `ReadFailed` and `EndOfStream`. std
  leaves the detail to the implementation (`Reader.zig:111-116`), so it goes in
  the codec's `err`, set once and never cleared.
- Every entry opens with `guard`: `failed` reports `ReadFailed`, `done` reports
  `EndOfStream`. `done` is set only when the input ends cleanly at a stream
  boundary. The state never returns to `streaming`.
- Buffered bytes after a failure are the codec's policy. Dropping them takes
  code in the codec's `fail` wrapper, because `std.Io.Reader.stream` serves
  buffered bytes before it consults the vtable.

### A contiguity request past capacity returns an error, never asserts

A consumer (`peek`, `take`, delimiter scans, `fillMore`) can ask for more
contiguous bytes than the buffer holds at its position, and the request reaches
`vtable.rebase` as `capacity`. The codec's `rebase` returns `error.ReadFailed`
with `err == .StreamTooLong`: the request is the consumer's, not a codec bug.
std's own `rebase` asserts here, and the codecs deliberately do not. Left as an
assert it panics in Debug and segfaulted in ReleaseFast (caeaae9), and a
hand-written `rebase` assert hid the same class (a812b4f). std:
`Reader.zig:89-92`, `:1132-1136`, `:1402-1409`.

### A wrapper's rebase routes the inner end through the same ending as fill

- An inner reader can be `done` as soon as its last block is decoded (flate sets
  it in the fill that still returns data), so a later `rebase` can return the
  inner's sticky `error.EndOfStream` before the wrapper has read its trailer.
  That end is the wrapper's own clean-end signal. Whatever `fill` runs there
  (read and check a trailer, verify a checksum, consume to the frame boundary),
  `rebase` must run too.
- Passing the end through reports a clean `EndOfStream` with the wrapper still
  `streaming` and its trailer unread, and a caller loop parses the trailer as
  the next frame. Ordinary calls reach it: a `peek` or `take` larger than the
  window's room at its position, or a record loop sized past the remaining tail.
- The ending step returns the trailer's own errors (the specific set, not
  `ReadFailed`) and never `EndOfStream`. In `fill`, `record` turns them into the
  sticky failure. `rebase` sits below `record`, so it calls `fail` directly,
  once.
- Lives in `container.ReaderHooks.rebase`, one body for gzip and zlib (it was
  fixed once per container before). zstd's `Reader` applies the rule by hand in
  `rebase` for its frame checksum. Any reader whose frame ends in a trailer it
  must verify needs it. Fixed in fca3604.
- Fuzz ops that bound every request by the bytes still to come never ask past
  the end, which hid this. Keep an `over_end_peek` op in a wrapper's
  reader-machinery fuzz target, and test a `take` plus a `peek` past the end on
  good and corrupted trailers.

### Rebase emits, never discards (writers)

`rebase` is where a full buffer's bytes go when a consumer asks for a direct
writable slice (`writableSliceGreedy`). It emits everything buffered beyond the
preserved tail, then leaves the tail as the buffered block. Discarding drops
input silently, and `writeAll`-based tests never reach this path (`File.Reader`
simple-mode streaming does). `emitBlock(host, len)` owns the slide, and the
generated `rebase` owns the keep computation, the emit length, and the
postconditions. std: `Writer.zig:82-88`, `:397-418`. Fixed in ea2a581.

### Drain tops up before emitting: maximal blocks, not caller chunking

`drain` runs only when `data` cannot fit in the buffer. It fills the remaining
space from the front of `data` (the last slice repeated `splat` times), then
emits the full block, and the caller re-slices and calls again. Emitting before
topping up splits blocks at the caller's write boundaries instead of the
codec's block size. std: `Writer.zig:21-25`, `:183-186`. Fixed in caeaae9.

### Poison checks: finish after failure never reports false success

`finish` checks that the interface still carries the codec's own vtable before
writing the stream ending, then poisons it (`Writer.failing`). A failed or
finished writer returns `error.WriteFailed`, never a false success on a
truncated stream. The check compares the address of the generated `vtable`, so
`init` must store `&Hooks.vtable`, never a copy of its value. std:
`Writer.zig:43-45`, `:124-125`, `:140-148`. Fixed in caeaae9.

## Testing

- `internal` has no test target of its own. The sentinel is test machinery, and
  the lifecycle and generated entries run under the codecs' reader, writer,
  golden, and fuzz tests.
- The lift check has no `just` recipe. When imports in this directory change,
  build a scratch project per codec by hand (the codec directory,
  `src/internal/`, and a path dependency on fastmem, under a module root above
  both) and run that codec's tests.
