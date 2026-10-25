"""Check the snappy framed stream against klauspost/compress's s2.

The oracle is s2 in snappy-compatible mode (`WriterSnappyCompat`), a second
implementation of the framing format. It checks both directions: our streams
decode through s2 and s2's decode through ours, across the empty input, the
chunk boundaries, compressible and incompressible data, concatenated streams,
skippable and padding chunks, and the framing's refusals (bad identifier,
reserved chunk, bad CRC, truncation).

Run it with `just snappy-oracle`. The harnesses are `zig-out/bin/snappy-oracle`
and `zig-out/bin/snappy-klauspost`; the shared plumbing is in
`scripts/oracle_common.py`.
"""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

import oracle_common as common

ROOT = common.ROOT
HARNESS = ROOT / "zig-out/bin/snappy-oracle"
GO = ROOT / "zig-out/bin/snappy-klauspost"

IDENTIFIER = b"\xff\x06\x00\x00sNaPpY"
CHUNK_HEADER = 4
CHUNK_CRC = 4
MAX_CHUNK = 64 * 1024

rows = 0


def _harness(command: str, data: bytes) -> subprocess.CompletedProcess[bytes]:
    _fd, path = tempfile.mkstemp()
    try:
        with Path(path).open("wb") as handle:
            handle.write(data)
        return subprocess.run([str(HARNESS), command, path], capture_output=True, check=False)
    finally:
        Path(path).unlink()


def our_encode(data: bytes) -> bytes:
    result = _harness("encode", data)
    if result.returncode != 0:
        raise SystemExit(f"our encode failed on {len(data)} bytes: {result.stderr!r}")
    return result.stdout


def our_decode(stream: bytes) -> bytes | None:
    result = _harness("decode", stream)
    return result.stdout if result.returncode == 0 else None


def go_run(command: str, stream: bytes, expected: bytes) -> bool:
    _fd_in, in_path = tempfile.mkstemp()
    _fd_ex, ex_path = tempfile.mkstemp()
    try:
        with Path(in_path).open("wb") as handle:
            handle.write(stream)
        with Path(ex_path).open("wb") as handle:
            handle.write(expected)
        result = subprocess.run(
            [str(GO), command, in_path, ex_path], capture_output=True, check=False
        )
        return result.returncode == 0
    finally:
        Path(in_path).unlink()
        Path(ex_path).unlink()


def go_encode(data: bytes) -> bytes:
    _fd_in, in_path = tempfile.mkstemp()
    _fd_out, out_path = tempfile.mkstemp()
    try:
        with Path(in_path).open("wb") as handle:
            handle.write(data)
        result = subprocess.run(
            [str(GO), "encode", in_path, out_path], capture_output=True, check=False
        )
        if result.returncode != 0:
            raise SystemExit(f"go encode failed on {len(data)} bytes: {result.stderr!r}")
        return Path(out_path).read_bytes()
    finally:
        Path(in_path).unlink()
        Path(out_path).unlink()


def chunk(kind: int, payload: bytes) -> bytes:
    assert len(payload) < 1 << 24
    return bytes([kind]) + len(payload).to_bytes(3, "little") + payload


def chunks(stream: bytes) -> list[tuple[int, bytes, int, int]]:
    """Parse a framed stream into (kind, payload, start, end) entries."""
    if not stream.startswith(IDENTIFIER):
        raise SystemExit("stream does not start with the sNaPpY identifier")
    out = []
    pos = len(IDENTIFIER)
    while pos < len(stream):
        if len(stream) - pos < CHUNK_HEADER:
            raise SystemExit("truncated chunk header")
        kind = stream[pos]
        length = int.from_bytes(stream[pos + 1 : pos + 4], "little")
        end = pos + CHUNK_HEADER + length
        if end > len(stream):
            raise SystemExit("truncated chunk payload")
        out.append((kind, stream[pos + CHUNK_HEADER : end], pos, end))
        pos = end
    return out


def check_round_trip(label: str, data: bytes) -> None:
    """Both directions and our self-round-trip for one input."""
    global rows
    ours = our_encode(data)
    if not ours.startswith(IDENTIFIER):
        raise SystemExit(f"{label}: our stream lacks the identifier")
    if not go_run("decode", ours, data):
        raise SystemExit(f"{label}: s2 could not decode our stream")
    if our_decode(ours) != data:
        raise SystemExit(f"{label}: our decoder disagrees with our encoder")

    theirs = go_encode(data)
    decoded = our_decode(theirs)
    if decoded != data:
        raise SystemExit(f"{label}: our decoder could not decode s2's stream")
    rows += 3


def corrupt(stream: bytes, at: int, mask: int = 0x01) -> bytes:
    out = bytearray(stream)
    out[at] ^= mask
    return bytes(out)


def main() -> int:
    global rows
    shapes = common.SHAPES
    for label, data in shapes.items():
        check_round_trip(label, data)

    # The chunk boundaries: one short, exact, one over, and two chunks.
    for size in (MAX_CHUNK - 8, MAX_CHUNK - 1, MAX_CHUNK, MAX_CHUNK + 1, 2 * MAX_CHUNK):
        check_round_trip(f"boundary {size}", (b"the quick brown fox " * (size // 20 + 1))[:size])

    # Concatenation: identifiers may repeat between chunks.
    first, second = b"first stream. " * 500, b"second stream. " * 500
    joined = our_encode(first) + our_encode(second)
    if our_decode(joined) != first + second:
        raise SystemExit("concatenated streams did not decode as one")
    if not go_run("decode", joined, first + second):
        raise SystemExit("s2 did not accept concatenated streams")
    rows += 2

    # Skippable and padding chunks are accepted by both.
    data = b"skippable test. " * 300
    base = our_encode(data)
    for kind in (0x80, 0xFE):
        with_meta = base[: len(IDENTIFIER)] + chunk(kind, b"metadata") + base[len(IDENTIFIER) :]
        if our_decode(with_meta) != data:
            raise SystemExit(f"our decoder did not skip chunk {kind:#x}")
        if not go_run("decode", with_meta, data):
            raise SystemExit(f"s2 did not skip chunk {kind:#x}")
        rows += 2

    # The refusals: a bad identifier, a reserved chunk, a bad CRC, corruption,
    # and truncation inside a chunk.
    data = b"the quick brown fox jumps over the lazy dog. " * 100
    stream = our_encode(data)
    entries = chunks(stream)
    data_chunk = next((e for e in entries if e[0] in (0x00, 0x01)), None)
    if data_chunk is None:
        raise SystemExit("no data chunk in a non-empty stream")
    _, _payload, start, end = data_chunk

    bad_identifier = bytearray(stream)
    bad_identifier[len(IDENTIFIER) - 1] ^= 0x01
    if our_decode(bytes(bad_identifier)) is not None:
        raise SystemExit("a corrupted identifier was accepted")
    if go_run("decode", bytes(bad_identifier), data):
        raise SystemExit("s2 accepted a corrupted identifier")
    rows += 2

    reserved = stream[: len(IDENTIFIER)] + chunk(0x02, b"") + stream[len(IDENTIFIER) :]
    if our_decode(reserved) is not None:
        raise SystemExit("a reserved unskippable chunk was accepted")
    if go_run("decode", reserved, data):
        raise SystemExit("s2 accepted a reserved unskippable chunk")
    rows += 2

    crc_at = start + CHUNK_HEADER
    bad_crc = corrupt(stream, crc_at)
    if our_decode(bad_crc) is not None:
        raise SystemExit("a corrupted checksum was accepted")
    if go_run("decode", bad_crc, data):
        raise SystemExit("s2 accepted a corrupted checksum")
    rows += 2

    payload_at = start + CHUNK_HEADER + CHUNK_CRC
    bad_payload = corrupt(stream, payload_at, 0x80)
    if our_decode(bad_payload) is not None:
        raise SystemExit("a corrupted payload was accepted")
    rows += 1

    truncated = stream[: end - 1]
    if our_decode(truncated) is not None:
        raise SystemExit("a stream cut inside a chunk was accepted")
    rows += 1

    # An identifier-only stream is a valid empty stream, and a cut exactly at
    # a chunk boundary decodes the chunks before it.
    empty = our_encode(b"")
    if empty != IDENTIFIER:
        raise SystemExit(f"the empty input is not the identifier alone: {empty!r}")
    if our_decode(empty) != b"":
        raise SystemExit("the identifier-only stream did not decode to nothing")
    if not go_run("decode", empty, b""):
        raise SystemExit("s2 rejected the identifier-only stream")
    if our_decode(stream[:end]) != data:
        raise SystemExit("a stream cut at a chunk boundary lost its first chunk")
    rows += 3

    print(
        f"snappy-oracle: {rows} rows: our encode -> s2 decode, s2 encode -> our decode, "
        f"{len(shapes)} shapes, chunk boundaries {MAX_CHUNK - 8}..{2 * MAX_CHUNK}, "
        "concatenation, skippable and padding chunks, the refusals: OK"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
