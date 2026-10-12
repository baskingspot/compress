"""Shared plumbing for the external-oracle scripts (flate, gzip, zlib).

Each script has its own harness, its own oracle, and its own checks; nothing
here knows about a codec. This module holds what the scripts share: the
repository root, the generated conformance shapes, one harness command over a
temp-file input, and one example-CLI row. The scripts import nothing from each
other and nothing from `src/`, so python's zlib and the CPython gzip module
stay independent references.
"""

import os
import random
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _shapes() -> dict[str, bytes]:
    """The generated conformance shapes by description.

    The same bytes in every script, so the same inputs exercise every codec:
    the empty input, text, seeded random bytes, an RLE run that spans a
    64-KiB block split, and a multi-block long text.
    """
    rng = random.Random(20261009)
    return {
        "empty": b"",
        "text": (b"the quick brown fox jumps over the lazy dog. " * 200)[:8192],
        "random": bytes(rng.randrange(256) for _ in range(4096)),
        "rle": b"\x5a" * 3000 + b"\x00" * 5 + b"q" * 130000,  # spans a 64 KiB split
        "long text (multi-block)": b"the quick brown fox jumps over the lazy dog. " * 6000,
    }


SHAPES = _shapes()


def run_harness(
    harness: Path, command: str, data: bytes, *args: str
) -> subprocess.CompletedProcess:
    """One harness command over `data`.

    The harness reads its input from a file (its first argument) and writes
    the result to stdout. `command` is "encode" or "decode"; `args` are its
    trailing arguments (the decode cap, the encode level).
    """
    fd, path = tempfile.mkstemp()
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        return subprocess.run(
            [str(harness), command, path, *args], capture_output=True, check=False
        )
    finally:
        os.unlink(path)


def harness_output(harness: Path, command: str, data: bytes, *args: str) -> bytes:
    """`run_harness` for the commands that must succeed.

    A nonzero exit raises AssertionError, with the harness's own stderr (the
    codec's error name) as the detail.
    """
    result = run_harness(harness, command, data, *args)
    if result.returncode != 0:
        raise AssertionError(
            f"our {command} failed ({result.returncode}): {result.stderr.decode().strip()}"
        )
    return result.stdout


def run_example(codec: str, args: list[str], data: bytes) -> subprocess.CompletedProcess:
    """One example-CLI row: `zig build example-<codec> -- <args>`, `data` on
    stdin."""
    return subprocess.run(
        ["zig", "build", f"example-{codec}", "--", *args],
        cwd=ROOT,
        input=data,
        capture_output=True,
        check=False,
    )
