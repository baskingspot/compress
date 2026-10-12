# Agent notes: zlib

zlib streams (RFC 1950) over flate. `README.md` is the user-facing contract and
the spec is `docs/research/specs/rfc1950-zlib.txt`. The research is
`docs/research/containers-notes.md` (cited here as `containers-notes.md`); its
OQ, ZD, and T row ids are used as they appear there. Ports, studied references,
and licenses are in `THIRD_PARTY.md`.

## Design decisions

The container design is stated once, in `src/gzip/AGENTS.md` ("The wrapping
design", "Trailer location and the one-shot decoder", "Streaming"). zlib follows
it unchanged, over the same driver (`src/internal/container.zig`) instantiated
on `framing.zig`: one stream per reader with an exact boundary, no container
buffers, the Adler-32 folded through flate's checksum hook, the trailer check on
the fill and rebase paths, the `.ratio` rejection, and the rule that a `Reader`
or `Writer` must not move after first use. What is specific to zlib:

- **No multi-stream mode** (OQ3). zlib has no concatenation convention, so
  `Reader.streamAll` decodes exactly one stream where gzip's walks members. A
  second stream means a new reader at the exact boundary.
- **A zero-byte input is `Truncated`** on every path (T2, OQ3): no stream began.
  `streamAll` reports it as the coarse `ReadFailed`. gzip's `streamAll` serves
  zero members instead.
- **FDICT is rejected, never skipped** (OQ4, ZD3/ZD4). RFC 1950 §2.3 requires an
  error when FDICT is set and the dictionary is not known, and this decoder
  knows none. C zlib emits such streams when given a dictionary
  (`containers-notes.md §5.5`). The answer is `DictionaryRequired`, raised at
  the header before any body byte, for "no dictionary" and "wrong dictionary"
  alike. It is never a silent skip of the four DICTID bytes and never std's
  misparse of them as deflate data (T6). Dictionary support waits for a
  dictionary entry point in flate (`flate-notes.md §6`, OQ6). The encoder never
  sets FDICT.
- **CMF, FLG, and ADLER32 are all checked** (ZD1). RFC 1950 §2.3 makes this a
  decoder MUST, where gzip's trailer check is optional by its RFC. std's zlib
  decoder is the lax outlier (T4, T6): it checks CM and CINFO only, has no FDICT
  handling, and never compares its footer. `golden.zig` pins the FCHECK and
  FDICT divergences by running std's decoder next to ours.

## Format notes and errata

- **Byte order is the family's trap** (`containers-notes.md §1.2`, §7 item 4).
  zlib's multi-byte numbers are most-significant byte first, the opposite of
  gzip's (`rfc1950-zlib.txt §2.1`): DICTID, ADLER32, and the CMF/FLG pair in
  the FCHECK arithmetic. The deflate LEN/NLEN underneath stay little-endian
  (`rfc1951-deflate.txt §3.2.4`).
- **FCHECK is validated as `(CMF*256 + FLG) % 31 == 0`, never by re-deriving
  it** (T5). With CMF 0x78, FDICT set, and FLEVEL 0, the naive `31 - r` (no
  outer modulo) emits FCHECK = 31, header `78 3f`. C zlib and Go's writer both
  do, and the pair is conformant (31 is 0 mod 31 and fits five bits). A decoder
  that recomputes FCHECK rejects that whole output family. The encoder uses the
  minimal `(31 - r) % 31` and never sets FDICT, so the corner only arises when
  decoding. The stream must land on `DictionaryRequired`, never `BadHeader`.
  Pinned by `golden.fcheck31_dict_stream` and the tests built on it.
- **`.fast` reads differently in the two containers.** zlib emits FLEVEL 2
  ("default algorithm") where gzip emits XFL 4 ("fastest algorithm"). Both are
  legal and informational: no decoder may require either value. The FLEVEL bands
  (C zlib's and Go's) are documented at `encode.flgFor`.

## Testing and oracle

- `golden.zig` (Go's `zlibTests` plus std's in-tree zlib tests) is shared by
  every layer's tests. `fuzz.zig` lists its fuzz targets in its header
  (`just fuzz`) and also holds the deterministic hostile-header pins, which are
  plain unit tests under `just test`.
- `just zlib-oracle` builds `oracle.zig` and runs `scripts/zlib_oracle.py`
  against python3's `zlib` (the C reference, wbits 15; the incantations are
  `containers-notes.md §5.5`). It covers our encode into its decode and its
  encode into our decode over generated shapes and levels, the FDICT refusal
  (including the `78 3f` corner), the FLEVEL/FCHECK header bytes (`78 9c` at
  level 6, `78 01`, `78 da`), the exact boundary (`decompressobj(15)` leaves the
  second stream in `unused_data`), and streaming rows through the example CLI.
- python3 is the only zlib reference: no zlib CLI is on PATH (`zlib-flate` is
  absent). The gzip/gunzip CLI rows belong to gzip.

## Performance notes

- The Adler-32 kernel (`adler32.zig`) folds RFC 1950 §8.2's 5552-byte
  deferred-modulo blocks with `@Vector` accumulators; std's scalar `Adler32` is
  the test reference. It sits behind `adler32(adler, bytes)`, libdeflate's
  signature, so a faster kernel swaps in without touching the container
  (`containers-notes.md §3.3`). It lives here, not in
  `src/internal/checksum.zig`: Adler-32 has one user, and a shared file waits
  for a second.
- `just bench` rows are local numbers, never claims. A claim names a fleet run
  directory and a results file in `docs/results/` (`m3-fleet-20261010.md` has
  the zlib rows). Read a zlib row only against its paired raw-flate row in the
  same binary (`bench.zig`'s header says why).
