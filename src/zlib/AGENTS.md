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
- **FDICT is checked, never skipped** (OQ4, ZD3/ZD4; "The preset dictionary"
  below). RFC 1950 §2.3 requires an error when FDICT is set and the dictionary
  is not known. The M3 posture collapsed "no dictionary" and "wrong
  dictionary" into `DictionaryRequired` at the header before any body byte —
  never a silent skip of the four DICTID bytes, never std's misparse of them
  as deflate data (T6). The dictionary milestone splits the two:
  `dict: ?[]const u8` on both directions, `DictionaryRequired` when FDICT is
  set and `dict` is null, `DictionaryMismatch` when `dict`'s Adler-32 is not
  the header's DICTID. The encoder sets FDICT exactly when given a dictionary.
- **CMF, FLG, and ADLER32 are all checked** (ZD1). RFC 1950 §2.3 makes this a
  decoder MUST, where gzip's trailer check is optional by its RFC. std's zlib
  decoder is the lax outlier (T4, T6): it checks CM and CINFO only, has no FDICT
  handling, and never compares its footer. `golden.zig` pins the FCHECK and
  FDICT divergences by running std's decoder next to ours.

## The preset dictionary (RFC 1950 §2.2; the M7 sketch)

The dictionary is raw caller bytes — RFC 1950 has no dictionary file format
("The dictionary is a sequence of bytes which are initially fed to the
compressor without producing any compressed output", §2.2). The research is
`dictionary-notes.md §4`; the surface follows the zstd sketch's error-name
rule (DQ4/DQ5).

- **The surface (DQ5).** `dict: ?[]const u8` on `decode.decompress` (third
  parameter), `Reader.init` (last), `Reader.streamAll`, and `encode.Options`;
  `Writer.init` and `Writer.streamAll` thread the options through unchanged.
  The migration is compile-checked: every existing callsite adds `, null`. No
  `Dictionary` type — there is nothing to parse; the check is one Adler-32
  compare at the header.
- **The wire.** Encode: FDICT (FLG bit 5) set, DICTID = the Adler-32 of the
  whole dictionary, big-endian, written before the body (`deflate()`'s
  INIT_STATE block, `deflateSetDictionary`; the C sets PRESET_DICT only when
  bytes were inserted, so an empty slice is no dictionary). The ADLER32
  trailer covers the output "excluding any dictionary data" (§2.2). Decode:
  the header check reads DICTID and compares it against `dict`'s Adler-32
  before any body byte. A dictionary longer than 32 KiB contributes only its
  last 32 KiB to the window, while DICTID names the whole
  (`deflateSetDictionary`'s tail cut, verified live): the caller supplies the
  full bytes on both sides, and a tail-only slice fails `DictionaryMismatch`.
- **The mismatch matrix.** FDICT set + `dict` null → `DictionaryRequired`
  (the M3 name, unchanged); FDICT set + a wrong or truncated `dict` →
  `DictionaryMismatch`; FDICT set + the right `dict` → decode; FDICT clear →
  the stream names no dictionary and a supplied `dict` is unused.
- **The flate seam (OQ6 retired).** The kernel gains the preset-history entry
  point: the decode's history region gains a caller-owned prefix (the
  dictionary rides in front of the output — the same two-region shape zstd's
  content uses, minus every zstd complication: no entropy tables, no
  repcodes, no ID arithmetic beyond one Adler-32 compare, no expiry rule —
  the window is fixed 32 KiB and the dictionary is its oldest bytes, so once
  the output passes 32 KiB the dictionary has slid out and the existing
  distance-bound check already refuses it). `src/flate/AGENTS.md`'s OQ6 row
  is retired by this; the parameter lands on the existing functions
  (`decode.decompress`, `Reader.init`, `Reader.streamAll`,
  `encode.Options.dict`), no new names.
- **The encoder's pre-fill is a measurement, not a conformance duty (DQ6,
  DT7).** The C inserts every dictionary position into its chains at every
  level; Go's level-1 skips the pre-hash (`fillWindow`'s `level < 2` early
  return, `deflate.go:181-185`). The flate oracle is round-trip conformance —
  `scripts/flate_oracle.py` checks both directions' decodes, never
  encoder-byte equality — so the slice measures the pre-fill densities on the
  fleet corpus and keeps the winner (the checksum-interleave precedent). A
  density changes ratio and speed, never a stream's validity.
- **Tests (the oracle rows, `dictionary-notes.md §8`).** python3 zlib's
  `zdict=` rows in `scripts/zlib_oracle.py` and `scripts/flate_oracle.py`:
  the four mismatch cases (right, none, wrong, truncated) as the error-name
  pins; the 40-KiB tail-cut round trip; the FDICT header bytes (FCHECK holds:
  `78 bb` for the Go vector); and the existing FDICT fixtures
  (`golden.dictionary_stream`, `golden.fcheck31_dict_stream`) become
  decode-with-dictionary pins.
- **Sketch calls.** (1) `dict` is ignored when FDICT is clear — the C's
  `inflateSetDictionary` is a DICT-state call that only accepts a stream that
  asked; ours ignores the parameter so one Reader can walk mixed streams.
  (2) An empty slice is no dictionary: the C's PRESET_DICT gate needs inserted
  bytes; `null` is the documented spelling. (3) The pre-fill density is DQ6's
  measurement, not this sketch's call.

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
