# Agent notes: gzip

gzip members (RFC 1952) over flate. `README.md` is the user-facing contract and
`docs/research/specs/rfc1952-gzip.txt` is the format. The research is
`docs/research/containers-notes.md` (`containers-notes.md` below); its row ids
(T1-T7, OQ1-OQ7) are used as they appear there. `THIRD_PARTY.md` has the
attribution for ported fixtures and studied references.

## Design decisions

### The wrapping design

The container design, stated once for gzip, zlib, and zstd: zlib follows the
same shape (one stream per reader, an exact boundary, checksums that ride the
codec), and zstd's frame walk mirrors the member walk below.
`src/zlib/AGENTS.md` cites "The wrapping design", "Trailer location and the
one-shot decoder", and "Streaming" by name, and `src/zstd/AGENTS.md` leans on
the member decisions: keep the headings.

- **One member per stream (OQ3, T2).** `Reader` consumes `input` through the
  member's last trailer byte and stops. Bytes after it are not consumed,
  interpreted, or skipped, so the input position at a clean end is the next
  member's first byte. Multi-member composes inside the package:
  `Reader.streamAll` walks one member per iteration at that boundary. End of
  input there is the file's clean end; any other byte starts a header parse, so
  garbage is `BadHeader`. That is libdeflate's boundary plus a caller loop that
  rejects garbage; the references split four ways (`containers-notes.md §2.5`).
- **A zero-byte input is `Truncated`** for `Reader` and `decompress` (no member
  began; `streamMember` reports the coarse `ReadFailed`), while `streamAll`
  serves zero members. Go and CPython accept an empty file as zero members; the
  gzip CLI errors.
- **The container owns no buffers (OQ6).** The memory is flate's `Writer.Buffer`
  and `Reader.Buffer`, handed to the inner flate layer and re-exported. The
  container's own scratch is a few comptime-sized stack bytes.
- **Hashing rides the codec boundary (OQ1).** The CRC-32 is folded through
  flate's optional checksum hook (`src/flate/Checksum.zig`, and "Checksum hook"
  in `src/flate/AGENTS.md`) where bytes cross the codec boundary: as a block is
  emitted on encode, as bytes enter the window on decode. Every byte is hashed
  once, with no container buffer, copy, or second pass; the one-shot encode
  hashes `source` directly. Rejected: a container-side `Io.Writer` front or a
  decode staging loop, each an extra copy of every byte (OQ1 in
  `containers-notes.md §4`).
- **Deterministic headers (OQ7).** FLG=0, MTIME=0, OS=255, XFL by level band:
  the encoder reads no clock, locale, or environment. "Format notes and errata"
  has the OS and XFL choices.
- **Specific errors, composed (OQ5).** Every malformed header, body, or trailer
  is a specific error, and no output is trusted past it. `Reader.Error` is
  flate's reader errors plus gzip's own entries, not a wrapper around them.
- **Framing helpers stay public behind the four barrels** (the flate precedent:
  `BitWriter`, `copyMatch`). The streaming layers are composed from
  `encode.writeHeader`/`writeTrailer` and `decode.HeaderParser`/`checkTrailer`
  through `framing.zig`; the README lists them.

### Trailer location and the one-shot decoder

OQ2. `flate.decode.decompress` returns a decoded length but not the input it
consumed, so a one-shot container decode cannot find its trailer from that call.
`decompress` therefore runs the whole member through `Reader` over
`Io.Reader.fixed(source)`: flate's reader consumes the input exactly through the
body's last byte, so the fixed reader's position afterwards is the trailer. That
exact-consumption contract is the one the container design rests on
(`src/flate/AGENTS.md`, "Contracts the containers rely on"). The one-shot
reports no consumed count, so bytes after the trailer are ignored; a
boundary-aware caller uses `Reader`.

### Streaming

`Reader` and `Writer` are thin: `internal.container.ReaderHooks` and
`WriterHooks` over `framing.zig` (gzip's half of the driver contract: header
parse, trailer check, CRC-32 state, error sets, flate's streaming types; not
public). `encode.compress` is `EncodeHooks(Framing).compress` and
`decode.decompress` is `DecodeHooks(Framing, Reader)`. The sticky lifecycle, the
count contracts, the zero-length poll, the poison check on `finish`, the
contiguity failure, and the trailer-at-the-clean-end rule are the driver's (its
doc comments; `src/internal/AGENTS.md`, "Io contracts"). gzip supplies the
header parse, the trailer check, the CRC-32, and the member boundary.

- One region, one position: the container has no serving region of its own.
  Decoded bytes are served out of flate's window (the caller's `Reader.Buffer`)
  and written bytes land in flate's block buffer (the caller's `Writer.Buffer`).
- The header is written lazily (Go's shape) because `init` cannot fail. The
  trailer is written by `finish` only.
- A reserved level poisons the writer at `init`, and `Writer.streamAll`
  rejects it upfront: the same reserved-seat behavior as flate's.
- A clean `EndOfStream` always means the trailer was verified, on the fill path
  and on the rebase path. The rebase path is the easy one to miss: an
  over-the-end `peek` reaches flate's sticky end through `rebase`, before any
  trailer read. The test "Reader: an over-the-end request still checks the
  trailer" pins it (bug history in `src/internal/AGENTS.md`).
- A `Reader` or `Writer` must not move after first use. The checksum hook that
  flate calls holds the address of the container's `checksum` field, set at the
  first entry (`init` cannot take its own address). A moved `Reader` keeps
  folding into the old copy and fails with `WrongChecksum`; a moved `Writer`
  writes a trailer that does not match its data.

## Format notes and errata

`containers-notes.md §1.1` recaps the member format; the spec is vendored. What
is not obvious from either:

- **Emitted header (OQ7, T1).** OS=255, the §2.3.1.2 default and what Go,
  libdeflate, and CPython write, not the 3 of the gzip CLI, C zlib, and std
  (zlib-ng writes 19 on Apple, outside the §2.3.1 table). A decoder must accept
  any OS byte, and a check of OS against the table would reject real files. XFL
  follows C zlib's and Go's bands (`xflFor`; `containers-notes.md §5.5`).
- **FHCRC is the low 16 bits of a CRC-32, not a CRC-16** (§2.3.1), over every
  header byte before it, the extra field and the NUL terminators included. The
  decoder verifies it (`WrongHeaderChecksum`, T3). The RFC requires only that it
  be skippable; Go verifies, and CPython, libdeflate, and std skip it.
- **Header caps (T7, OQ6).** FNAME and FCOMMENT are NUL-scanned with a 512-byte
  cap (`HeaderTooLong`), Go's house rule; the RFC bounds nothing. The extra
  field is skipped and hashed as it streams from the input, never staged, so a
  65,535-byte XLEN cannot amplify memory (zstd's skippable-frame skip follows
  the same rule).
- **The trailer is verified on purpose (T4).** RFC 1952 makes the check
  optional (§2.3.1.2) while RFC 1950 makes zlib's ADLER32 check a MUST. Every
  reference gzip reader verifies anyway except std, whose `Decompress` reads the
  footer and never compares it. `WrongChecksum` and `WrongSize` stay separate;
  Go reports both as `ErrChecksum`.
- **std's CRC-32 names** (`containers-notes.md §3.1`, checked by running).
  `std.hash.crc.Crc32` is the gzip CRC-32 (`Crc32("123456789")` is 0xCBF43926)
  and the test reference for `crc32.zig`. `Crc32Iscsi` is CRC-32C, the wrong
  CRC, next to the right one. `Crc32WithPoly` and `Crc32SmallWithPoly` are
  dangling declarations in the 0.16.0 tree (the `impl` names they reference do
  not exist): do not reach for them.

## Testing and golden vectors

The conformance bar is the reference suites, ported as fixtures in `golden.zig`
and shared by every layer's tests. `containers-notes.md §5` is the inventory.
Go's `TestRoundTrip` and `TestLatin1RoundTrip` are not ported: no header
metadata is written or surfaced, and the FNAME/FCOMMENT byte rules ride the
all-fields and truncated-name vectors. The hostile-header pins in `fuzz.zig` are
a plain unit test, so `just test` gates them; the fuzz targets need `just fuzz`.

## Oracles

`just gzip-oracle` builds the harness (`oracle.zig`) and runs
`scripts/gzip_oracle.py` (incantations: `containers-notes.md §5.5`). It covers:

- Our encode at levels 1 and 6 into python3's `zlib` (wbits 31), the
  CPython `gzip` module, and `gunzip -c`, and their encoders (C zlib's
  `compressobj(level, DEFLATED, 31)`, `gzip.compress`, `gzip -c`) into our
  decode. Header and trailer checks run on every member we emit.
- The single-member boundary: `decompressobj(31)` leaves the second member in
  `unused_data`, and our one-shot ignores everything after the first trailer.
- FHCRC: a hand-built member with a right CRC16 decodes, a corrupted one is
  rejected.
- Trailing garbage: the one-shot ignores it, and the example CLI's `decode`
  (`Reader.streamAll`) rejects it.
- Streaming rows through the example CLI (`examples/gzip.zig`): its own round
  trip, C zlib's decode of its stream, and a multi-member walk.

## Performance notes

- The CRC-32 kernel is slice-by-16 (`crc32.zig`) behind libdeflate's shape,
  `crc32(crc, bytes)` with the conditioning inside (`containers-notes.md §3.3`),
  so a faster kernel swaps in without touching the container. Hardware CRC or
  PCLMULQDQ folding is the plan's deferred decision; the gzip decode gap it
  targets is in `docs/results/m3-fleet-20261010.md`. The kernel stays here,
  not in `src/internal/`, because CRC-32 has one user: snappy's framing carries
  no checksum and zstd uses XXH64.
- `bench.zig`'s header says why a gzip row compares only with its paired
  raw-flate row from the same binary. Performance claims come from the fleet
  harness and name a run directory and a results file in `docs/results/`; local
  numbers are never quoted.
