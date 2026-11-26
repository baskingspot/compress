"""Check raw LZ4 blocks against github.com/pierrec/lz4/v4.

Both directions run over empty and tiny inputs, compressible and random data,
and the 13-byte, 16-KiB, and 64-KiB boundaries. Foreign Go blocks decode through
this package, and this package's blocks decode through Go. Hand-composed rows
pin the valid tails that break encoder-side restrictions and the corrupt-input
refusals.

Run with `just lz4-oracle`. The harnesses are `zig-out/bin/lz4-oracle` and
`zig-out/bin/lz4-go`; shared plumbing is in `scripts/oracle_common.py`.
"""

from __future__ import annotations

import random
import subprocess
import tempfile
from pathlib import Path

import oracle_common as common

ROOT = common.ROOT
HARNESS = ROOT / "zig-out/bin/lz4-oracle"
GO = ROOT / "zig-out/bin/lz4-go"

rows = 0


def our_encode(data: bytes) -> bytes:
    return common.harness_output(HARNESS, "encode", data)


def our_decode(block: bytes, decoded_len: int) -> bytes | None:
    result = common.run_harness(HARNESS, "decode", block, str(decoded_len))
    return result.stdout if result.returncode == 0 else None


def go_encode(data: bytes) -> bytes:
    _fd_in, in_path = tempfile.mkstemp()
    _fd_out, out_path = tempfile.mkstemp()
    try:
        Path(in_path).write_bytes(data)
        result = subprocess.run(
            [str(GO), "encode", in_path, out_path], capture_output=True, check=False
        )
        if result.returncode != 0:
            raise SystemExit(f"go encode failed on {len(data)} bytes: {result.stderr!r}")
        return Path(out_path).read_bytes()
    finally:
        Path(in_path).unlink()
        Path(out_path).unlink()


def go_decode(block: bytes, expected: bytes) -> bool:
    _fd_in, in_path = tempfile.mkstemp()
    _fd_ex, expected_path = tempfile.mkstemp()
    try:
        Path(in_path).write_bytes(block)
        Path(expected_path).write_bytes(expected)
        result = subprocess.run(
            [str(GO), "decode", in_path, expected_path], capture_output=True, check=False
        )
        return result.returncode == 0
    finally:
        Path(in_path).unlink()
        Path(expected_path).unlink()


def check_round_trip(label: str, data: bytes) -> None:
    global rows
    ours = our_encode(data)
    if len(ours) > len(data) + len(data) // 255 + 16:
        raise SystemExit(f"{label}: our block exceeds CompressBlockBound")
    if not go_decode(ours, data):
        raise SystemExit(f"{label}: Go could not decode our block")
    if our_decode(ours, len(data)) != data:
        raise SystemExit(f"{label}: our decoder disagrees with our encoder")

    theirs = go_encode(data)
    if not theirs and not data:
        # Go's zero return is its no-block convention. The block format's
        # canonical empty block is the single zero token, checked below.
        rows += 2
        return
    if our_decode(theirs, len(data)) != data:
        raise SystemExit(f"{label}: our decoder could not decode Go's block")
    rows += 3


def expect_valid(label: str, block: bytes, expected: bytes) -> None:
    global rows
    if our_decode(block, len(expected)) != expected:
        raise SystemExit(f"{label}: valid block was rejected or decoded incorrectly")
    rows += 1


def expect_invalid(label: str, block: bytes, decoded_len: int) -> None:
    global rows
    if our_decode(block, decoded_len) is not None:
        raise SystemExit(f"{label}: corrupt block was accepted")
    rows += 1


def main() -> int:
    for label, data in common.SHAPES.items():
        check_round_trip(label, data)

    sizes = (
        1,
        2,
        4,
        5,
        12,
        13,
        14,
        15,
        16,
        17,
        18,
        19,
        20,
        254,
        255,
        256,
        270,
        4096,
        16 * 1024 - 1,
        16 * 1024,
        16 * 1024 + 1,
        64 * 1024 - 1,
        64 * 1024,
        64 * 1024 + 1,
        128 * 1024,
    )
    phrase = b"the quick brown fox jumps over the lazy dog. "
    for size in sizes:
        check_round_trip(f"text {size}", (phrase * (size // len(phrase) + 1))[:size])
        random_data = random.Random(0xC0FFEE ^ size).randbytes(size)
        check_round_trip(f"random {size}", random_data)

    # Structurally valid blocks whose tails break the encoder-side 5-byte and
    # 12-byte restrictions. The final token's low nibble is unused.
    expect_valid("empty", b"\x00", b"")
    expect_valid("final token low bits", b"\x0f", b"")
    expect_valid("late match", b"\x40abcd\x04\x00\x00", b"abcdabcd")
    expect_valid("one trailing literal", b"\x40abcd\x04\x00\x10z", b"abcdabcdz")
    expect_valid("zero-literal match", b"\x40abcd\x04\x00\x00\x04\x00\x00", b"abcd" * 3)
    expect_valid("literal 15", b"\xf0\x00123456789abcdef", b"123456789abcdef")
    expect_valid("match 19", b"\x1fA\x01\x00\x00\x00", b"A" * 20)
    expect_valid("match extension", b"\x1fA\x01\x00\xff\x00\x00", b"A" * 275)

    invalid = (
        ("empty source", b"", 0),
        ("missing literal extension", b"\xf0", 0),
        ("truncated literal extension", b"\xf0\xff", 0),
        ("truncated literals", b"\x30ab", 3),
        ("literal overflow", b"\x30abc", 2),
        ("missing offset", b"\x10A", 5),
        ("truncated offset", b"\x10A\x01", 5),
        ("zero offset", b"\x10A\x00\x00\x00", 5),
        ("offset before output", b"\x10A\x02\x00\x00", 5),
        ("missing match extension", b"\x1fA\x01\x00", 20),
        ("truncated match extension", b"\x1fA\x01\x00\xff", 275),
        ("missing final literals", b"\x10A\x01\x00", 5),
        ("match overflow", b"\x11A\x01\x00\x00", 5),
        ("output underflow", b"\x10A\x01\x00\x00", 6),
        ("trailing token", b"\x30abc\x00", 3),
    )
    for label, block, decoded_len in invalid:
        expect_invalid(label, block, decoded_len)

    # Every strict prefix of a foreign block is truncated against the known
    # decoded length. This catches a decoder that accepts a complete-looking
    # final literal sequence before the real block's end.
    data = b"abc123" * 100
    foreign = go_encode(data)
    for cut in range(len(foreign)):
        expect_invalid(f"foreign prefix {cut}", foreign[:cut], len(data))

    print(
        f"lz4-oracle: {rows} rows against pierrec/lz4 v4.1.34, both directions, "
        f"{len(sizes)} sizes in compressible and random forms, valid foreign tails, "
        "corruption, and every strict prefix of a foreign block: OK"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
