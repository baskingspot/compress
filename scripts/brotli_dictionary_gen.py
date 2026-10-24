"""Generate the brotli static dictionary data (RFC 7932 §8, Appendices A and B).

Run once, commit the artifacts:

    uv run scripts/brotli_dictionary_gen.py

It reads the vendored RFC text (`docs/specs/rfc7932-brotli.txt`) and
writes two files under `src/brotli/`:

- `dictionary.bin.base64` — Appendix A's DICT as single-line base64, 122,784
  bytes (binary files are never committed; `build.zig`'s fixture generation
  decodes it into the `fixtures` module);
- `dictionary_data.zig` — Appendix A's NDBITS array and Appendix B's 121
  transforms, deduplicated into the C reference's prefix/suffix-pool shape
  (google/brotli v1.2.0 `c/common/transform.c`): a length-prefixed string
  pool, a pool-offset map, and 121 `[prefix id, elementary transform, suffix
  id]` triplets.

The pool's order is first use in Appendix B — the reference's own pool order
is hand-chosen, and only the transform semantics are pinned: the tests pin
them by rebuilding Appendix B's flat 648-byte sequence from the generated
tables and checking its CRC-32. Nothing here is fetched, and every check
value the RFC prints is asserted before anything is written.
"""

import base64
import re
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RFC = ROOT / "docs/specs/rfc7932-brotli.txt"
DICT_PATH = ROOT / "src/brotli/dictionary.bin.base64"
DATA_PATH = ROOT / "src/brotli/dictionary_data.zig"

DICT_CRC = 0x5136CB04
FLAT_CRC = 0x3D965F81

# RFC 7932 §8, Appendix B — the elementary transform names to the RFC's own
# numbering (Appendix B's flat sequence) and to the C reference's
# (`BrotliWordTransformType`, `c/common/transform.h`), which is the numbering
# the generated table uses.
RFC_TYPE = {
    "Identity": 0,
    "FermentFirst": 1,
    "FermentAll": 2,
    **{f"OmitFirst{k}": 2 + k for k in range(1, 10)},
    **{f"OmitLast{k}": 11 + k for k in range(1, 10)},
}
C_TYPE = {
    "Identity": 0,
    **{f"OmitLast{k}": k for k in range(1, 10)},
    "FermentFirst": 10,
    "FermentAll": 11,
    **{f"OmitFirst{k}": 11 + k for k in range(1, 10)},
}

# google/brotli v1.2.0 `c/common/transform.c` — the ids of the
# `["", OmitLast_k, ""]` transforms, k = 0..9. The decoder uses [0], the
# identity fast path; the table is generated (not copied) and asserted here.
CUT_OFF = [0, 12, 27, 23, 42, 63, 56, 48, 59, 64]

ROW = re.compile(
    r'^\s*(\d+)\s+("(?:\\.|[^"\\])*")\s+'
    r"(Identity|FermentFirst|FermentAll|OmitFirst[1-9]|OmitLast[1-9])\s+"
    r'("(?:\\.|[^"\\])*")\s*$'
)

ESCAPES = {
    "n": b"\n",
    "t": b"\t",
    "r": b"\r",
    "0": b"\0",
    "\\": b"\\",
    '"': b'"',
    "'": b"'",
}


def c_string(text: str) -> bytes:
    """Decode one C string literal (quotes included), RFC 7932 Appendix B."""
    out = bytearray()
    i = 1
    while i < len(text) - 1:
        if text[i] != "\\":
            out += text[i].encode("latin-1")
            i += 1
            continue
        i += 1
        escape = text[i]
        if escape == "x":
            out.append(int(text[i + 1 : i + 3], 16))
            i += 3
        elif escape in "01234567":
            end = i
            while end < len(text) and end < i + 3 and text[end] in "01234567":
                end += 1
            out.append(int(text[i:end], 8))
            i = end
        else:
            out += ESCAPES[escape]
            i += 1
    return bytes(out)


def section(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    return text[begin : text.index(end, begin)]


def parse_dict(text: str) -> bytes:
    """Appendix A's DICT hex, 64 hex digits to the line."""
    body = section(text, "Appendix A.  Static Dictionary Data", "The number of words")
    data = bytearray()
    for line in body.splitlines():
        line = line.strip()
        if line and re.fullmatch(r"[0-9a-f]+", line):
            data += bytes.fromhex(line)
    assert len(data) == 122784, len(data)
    assert zlib.crc32(data) == DICT_CRC, hex(zlib.crc32(data))
    return bytes(data)


def parse_ndbits(text: str) -> list[int]:
    """Appendix A's NDBITS array, "the number of words for each length"."""
    body = section(text, "NDBITS :=", "Appendix B.  List of Word Transformations")
    values = [int(value) for value in re.findall(r"\d+", body)]
    assert len(values) == 25, values
    return values


def parse_transforms(text: str) -> list[tuple[bytes, str, bytes]]:
    """Appendix B's 121 rows: (prefix, elementary name, suffix), id order."""
    body = section(
        text,
        "Appendix B.  List of Word Transformations",
        "Appendix C.  Computing CRC-32 Check Values",
    )
    rows: list[tuple[int, bytes, str, bytes]] = []
    for line in body.splitlines():
        match = ROW.match(line)
        if match:
            rows.append(
                (
                    int(match.group(1)),
                    c_string(match.group(2)),
                    match.group(3),
                    c_string(match.group(4)),
                )
            )
    assert [row[0] for row in rows] == list(range(121)), [row[0] for row in rows]
    return [(prefix, name, suffix) for _, prefix, name, suffix in rows]


def flat(transforms: list[tuple[bytes, str, bytes]]) -> bytes:
    """Appendix B's flat sequence: prefix, NUL, transform id, suffix, NUL."""
    out = bytearray()
    for prefix, name, suffix in transforms:
        out += prefix + b"\0" + bytes([RFC_TYPE[name]]) + suffix + b"\0"
    return bytes(out)


def dedup(transforms: list[tuple[bytes, str, bytes]]):
    """The C reference's shape: a pool of strings, a map, and triplets."""
    pool: dict[bytes, int] = {}
    entries: list[bytes] = []
    for prefix, _, suffix in transforms:
        for string in (prefix, suffix):
            if string not in pool:
                pool[string] = len(entries)
                entries.append(string)
    offsets = bytearray()
    for string in entries:
        assert len(string) < 256
        offsets += bytes([len(string)]) + string
    pool_map = []
    offset = 0
    for string in entries:
        pool_map.append(offset)
        offset += 1 + len(string)
    triplets = [(pool[prefix], C_TYPE[name], pool[suffix]) for prefix, name, suffix in transforms]
    assert len(entries) == 50, len(entries)
    assert len(offsets) == 217, len(offsets)
    return bytes(offsets), pool_map, triplets


def zig_bytes(data: bytes) -> str:
    """One Zig string literal for `data`, escape-safe."""
    out = ['"']
    for byte in data:
        if byte == 0x22:
            out.append('\\"')
        elif byte == 0x5C:
            out.append("\\\\")
        elif 0x20 <= byte < 0x7F:
            out.append(chr(byte))
        else:
            out.append(f"\\x{byte:02x}")
    out.append('"')
    return "".join(out)


def display(data: bytes) -> str:
    """A readable C-style display of one pool string for the emitted comment."""
    out = []
    for byte in data:
        if byte == 0x22:
            out.append('\\"')
        elif byte == 0x5C:
            out.append("\\\\")
        elif 0x20 <= byte < 0x7F:
            out.append(chr(byte))
        else:
            out.append(f"\\x{byte:02x}")
    return '"' + "".join(out) + '"'


def emit_data(ndbits: list[int], pool: bytes, pool_map: list[int], triplets, rows, cut_off) -> str:
    lines = [
        "//! Generated by `scripts/brotli_dictionary_gen.py` from the vendored RFC",
        "//! 7932 text (`docs/specs/rfc7932-brotli.txt`): Appendix A's",
        "//! DICT hex and its NDBITS array, and Appendix B's 121 transforms,",
        "//! deduplicated into the C reference's prefix/suffix-pool shape",
        "//! (`c/common/transform.c`). Do not edit by hand: re-run the generator and",
        "//! commit its output. The dictionary bytes are `dictionary.bin` beside",
        "//! this file; the tests pin both by the RFC's own CRC-32 check values.",
        "",
        "/// RFC 7932 §8, Appendix A — NDBITS[0..24]: the index bit-depth of each",
        "/// word length; NWORDS[length] = 1 << NDBITS[length] for length >= 4.",
        "pub const ndbits = [25]u5{",
        "    " + ", ".join(str(v) for v in ndbits) + ",",
        "};",
        "",
        "/// RFC 7932 §8, Appendix B — the prefix/suffix pool: one length byte then",
        "/// that many bytes per entry, in order of first use in Appendix B (ids in",
        "/// `prefix_suffix_map` order). The final entry is the empty string.",
        "pub const prefix_suffix =",
    ]
    offset = 0
    for index, entry in enumerate(_entries(pool)):
        suffix = " ++" if index + 1 < 50 else ";"
        text = display(pool[offset + 1 : offset + 1 + entry])
        lines.append(
            f"    {zig_bytes(pool[offset : offset + 1 + entry])}{suffix} // {index}: {text}"
        )
        offset += 1 + entry
    lines += [
        "",
        "/// The pool offset of each of the 50 strings, by id.",
        "pub const prefix_suffix_map = [50]u16{",
    ]
    # zig fmt lays a multi-line array out as a table: pad each column to the
    # widest value in that column, or the file fails `zig fmt --check`.
    map_rows = [pool_map[start : start + 10] for start in range(0, 50, 10)]
    widths = [max(len(str(row[col])) for row in map_rows) for col in range(10)]
    for row in map_rows:
        cells = [f"{value}," for value in row[:-1]]
        cells = [cell + " " * (widths[col] - len(cell) + 2) for col, cell in enumerate(cells)] + [
            f"{row[-1]},"
        ]
        lines.append("    " + "".join(cells))
    lines += [
        "};",
        "",
        "/// The 121 transforms as [prefix id, elementary transform, suffix id]",
        "/// triplets, in Appendix B's id order; the elementary numbering is the C",
        "/// reference's (`c/common/transform.h`).",
        "pub const transforms = [121][3]u8{",
    ]
    for index, (prefix_id, kind, suffix_id) in enumerate(triplets):
        prefix, name, suffix = rows[index]
        lines.append(
            f"    .{{ {prefix_id}, {kind}, {suffix_id} }},"
            f" // {index}: {display(prefix)} {name} {display(suffix)}"
        )
    lines += [
        "};",
        "",
        "/// The C reference's `cutOffTransforms`: the transform ids of",
        '/// `["", OmitLast_k, ""]`, k = 0..9 (`c/common/transform.c`). The',
        "/// decoder uses [0], the identity fast path.",
        "pub const cut_off_transforms = [10]u8{ " + ", ".join(str(v) for v in cut_off) + " };",
        "",
    ]
    return "\n".join(lines)


def _entries(pool: bytes) -> list[int]:
    """The length prefix of each pool entry, in order."""
    lengths = []
    offset = 0
    while offset < len(pool):
        length = pool[offset]
        lengths.append(length)
        offset += 1 + length
    assert offset == len(pool)
    return lengths


def main() -> None:
    text = RFC.read_text()
    dictionary = parse_dict(text)
    ndbits = parse_ndbits(text)
    transforms = parse_transforms(text)

    # Appendix A's recursion: DICTSIZE = DOFFSET[24] + 24 * NWORDS[24] must be
    # exactly the DICT length, and Appendix B's flat sequence must check out.
    offset = 0
    for length in range(24):
        offset += length * (0 if length < 4 else 1 << ndbits[length])
    assert offset + 24 * (1 << ndbits[24]) == len(dictionary), offset
    flat_sequence = flat(transforms)
    assert len(flat_sequence) == 648, len(flat_sequence)
    assert zlib.crc32(flat_sequence) == FLAT_CRC, hex(zlib.crc32(flat_sequence))

    # The RFC's own bound: the largest prefix + suffix is 13 (transform 73).
    affix = max(len(prefix) + len(suffix) for prefix, _, suffix in transforms)
    assert affix == 13, affix

    # The cut-off table is generated from the parsed table, never copied.
    cut_off = [
        next(
            index
            for index, (prefix, name, suffix) in enumerate(transforms)
            if not prefix and not suffix and name == f"OmitLast{k}"
        )
        for k in range(1, 10)
    ]
    cut_off = [0] + cut_off
    assert cut_off == CUT_OFF, cut_off

    pool, pool_map, triplets = dedup(transforms)
    DICT_PATH.write_text(base64.b64encode(dictionary).decode() + "\n")
    DATA_PATH.write_text(emit_data(ndbits, pool, pool_map, triplets, transforms, cut_off))
    print(f"{DICT_PATH}: {len(dictionary)} bytes as base64, CRC-32 {DICT_CRC:#010x}")
    print(f"{DATA_PATH}: {len(pool)} pool bytes, {len(triplets)} transforms")


if __name__ == "__main__":
    main()
