"""Check brotli against the pinned reference CLI (brotli 1.2.0).

The codec is decoder-only, so this lane has one direction: every stream the
CLI produced must decode through our one-shot (`brotli.decode.decompress`) to
the bytes the CLI decodes it to, and to the bytes the CLI compressed. The rows
cover the CLI's whole quality range (0..11, the dictionary-bearing q4-and-up
class included), the window flag's range, the metadata lane (`-C`), the
trailing-bytes and concatenation rules (T4 of src/brotli/AGENTS.md), the empty
family, the truncation battery, and the corruption battery under the
no-checksum rule (T6). The streaming half of the lane (`stream <file> <wbits>`)
pumps the same streams through `brotli.Reader.streamAll`, so the ring, the
window cap, and the input seams are checked against the same references.

Run it with `just brotli-oracle`; brotli comes from the flake (the pinned
1.2.0) and the Go reference from scripts/brotli_go. The harness is built from
src/brotli/oracle.zig. The shared plumbing is in scripts/oracle_common.py.
"""

import base64
import subprocess
import tempfile
from pathlib import Path

import oracle_common as common

root = common.ROOT
harness = root / "zig-out/bin/brotli-oracle"
go_oracle = root / "zig-out/bin/brotli-go"


def cli(args: list[str], data: bytes) -> subprocess.CompletedProcess[bytes]:
    """One reference-CLI row: `brotli <args>` with `data` on stdin."""
    return subprocess.run(["brotli", *args], input=data, capture_output=True, check=False)


def cli_encode(data: bytes, *flags: str) -> bytes:
    """The CLI's stream for `data` under `flags` (always `-c`, stdout)."""
    result = cli([*flags, "-c"], data)
    if result.returncode != 0:
        raise AssertionError(f"brotli encode failed ({' '.join(flags)}): {result.stderr.decode()}")
    return result.stdout


def cli_encode_file(data: bytes, quality: str) -> bytes:
    """`brotli -q <quality> -c FILE`: the file form, where the CLI's automatic
    window follows the file's size instead of the stdin default (see the file
    lane below)."""
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "in"
        source.write_bytes(data)
        result = subprocess.run(
            ["brotli", "-q", quality, "-c", str(source)], capture_output=True, check=False
        )
        if result.returncode != 0:
            raise AssertionError(f"brotli encode failed: {result.stderr.decode()}")
        return result.stdout


def wbits(stream: bytes) -> int:
    """RFC 7932 §9.1's WBITS, read from the stream's first bits (the
    patterns are parsed from right to left; 0010001 is the invalid one)."""
    position = 0

    def take(count: int) -> int:
        nonlocal position
        value = 0
        for i in range(count):
            value |= ((stream[position // 8] >> (position % 8)) & 1) << i
            position += 1
        return value

    if take(1) == 0:
        return 16
    short = take(3)
    if short != 0:
        return 17 + short
    long = take(3)
    if long == 1:
        return -1
    if long != 0:
        return 8 + long
    return 17


def cli_decode(stream: bytes) -> bytes | None:
    """The CLI's decode of `stream`, or None where the CLI refuses it."""
    result = cli(["-d", "-c"], stream)
    return result.stdout if result.returncode == 0 else None


def our_decode(stream: bytes, cap: int) -> bytes:
    """Our one-shot, through the oracle harness, at a `cap`-byte target."""
    return common.harness_output(harness, "decode", stream, str(cap))


def our_stream(stream: bytes, wbits: int) -> bytes:
    """Our streaming reader, through the oracle harness, at `wbits`."""
    return common.harness_output(harness, "stream", stream, str(wbits))


def our_stream_result(stream: bytes, wbits: int) -> bytes | None:
    """The streaming reader's decode, or None where it refuses."""
    result = common.run_harness(harness, "stream", stream, str(wbits))
    return result.stdout if result.returncode == 0 else None


def our_decode_result(stream: bytes, cap: int) -> bytes | None:
    """Our one-shot's decode, or None where it refuses."""
    result = common.run_harness(harness, "decode", stream, str(cap))
    return result.stdout if result.returncode == 0 else None


def our_decode_fails(stream: bytes, cap: int) -> bool:
    return common.run_harness(harness, "decode", stream, str(cap)).returncode != 0


def go_decode_result(stream: bytes) -> bytes | None:
    """andybalholm/brotli's decode of `stream`, or None where it refuses
    (a corrupt stream, or bytes after the stream's last byte)."""
    with tempfile.TemporaryDirectory() as tmp:
        stream_path = Path(tmp) / "stream.br"
        stream_path.write_bytes(stream)
        result = subprocess.run(
            [str(go_oracle), "decode", str(stream_path)], capture_output=True, check=False
        )
        return result.stdout if result.returncode == 0 else None


def go_decode(stream: bytes, expected: bytes) -> None:
    """The Go reference's decode of `stream`, which must reproduce
    `expected`."""
    got = go_decode_result(stream)
    assert got == expected, f"the Go reference decoded {got if got is None else len(got)} bytes"


def go_encode(data: bytes, quality: str) -> bytes:
    """The Go encoder's stream for `data` at `quality`."""
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "in"
        source.write_bytes(data)
        result = subprocess.run(
            [str(go_oracle), "encode", str(source), quality], capture_output=True, check=False
        )
        if result.returncode != 0:
            raise AssertionError(f"the Go encoder failed: {result.stderr.decode()}")
        return result.stdout


# The sweep's inputs: the shared conformance shapes plus the repository's own
# text. The RFC is the largest text at hand, and the note files are what the
# reference encoder's dictionary search bites on at q4 and up (F6).
def inputs() -> list[tuple[str, bytes]]:
    return [
        ("empty", common.SHAPES["empty"]),
        ("text", common.SHAPES["text"]),
        ("random", common.SHAPES["random"]),
        ("rle", common.SHAPES["rle"]),
        ("long text (multi-block)", common.SHAPES["long text (multi-block)"]),
        ("RFC 7932 text", (root / "docs/research/specs/rfc7932-brotli.txt").read_bytes()),
        ("brotli notes", (root / "docs/research/brotli-notes.md").read_bytes()),
        ("brotli AGENTS.md", (root / "src/brotli/AGENTS.md").read_bytes()),
    ]


def sweep(rows: list[tuple[str, bytes]], *flags: str) -> int:
    """One differential row per input: the CLI's stream decodes through our
    one-shot, at the exact cap, to the input bytes, and both references' own
    decodes of the same stream agree. Returns the row count."""
    count = 0
    for desc, data in rows:
        stream = cli_encode(data, *flags)
        label = f"{desc}, {' '.join(flags)}"
        assert cli_decode(stream) == data, f"oracle round trip ({label})"
        go_decode(stream, data)
        got = our_decode(stream, len(data))
        assert got == data, f"our decode ({label}): {len(got)} bytes, want {len(data)}"
        count += 1
    return count


def stream_sweep(rows: list[tuple[str, bytes]], *flags: str, wbits: int = 24) -> int:
    """The same rows through the streaming reader: the walk decodes the CLI's
    stream to the input bytes, and it consumes exactly through the stream's
    last byte. Returns the row count."""
    count = 0
    for desc, data in rows:
        stream = cli_encode(data, *flags)
        label = f"stream {desc}, {' '.join(flags)} at {wbits}"
        got = our_stream(stream, wbits)
        assert got == data, f"our streaming decode ({label}): {len(got)} bytes, want {len(data)}"
        # A second stream after the first is the walk's next iteration, so the
        # doubled stream decodes twice.
        doubled = our_stream(stream + stream, wbits)
        assert doubled == data + data, f"our streaming walk ({label})"
        count += 1
    return count


# 1. The differential sweep: every input at every quality 0..11. Quality 4 and
#    up is where the encoder starts emitting dictionary references on text
#    (F6), so this is the dictionary port's live conformance lane.
version = cli(["--version"], b"")
assert b"brotli 1.2.0" in version.stdout + version.stderr, f"unexpected CLI: {version.stdout!r}"

qualities = [str(q) for q in range(12)]
sweep_inputs = inputs()
swept = sum(sweep(sweep_inputs, "-q", q) for q in qualities)

# 1b. The streaming reader over the same sweep: the CLI's pipe family is
#     WBITS 24 (F9), so the default buffer decodes every row, and the walk
#     decodes a doubled stream twice.
streamed = sum(stream_sweep(sweep_inputs, "-q", q) for q in qualities)

# 1c. The ring: -w 10..24 on the text shape through a Buffer of the same size,
#     so the reader's ring wraps under real copies, plus the cap: a pipe
#     stream (WBITS 24) refused by a Buffer(22).
ring_rows = 0
for w in range(10, 25):
    ring_rows += stream_sweep([("text", common.SHAPES["text"])], "-q", "11", "-w", str(w), wbits=w)
pipe_stream = cli_encode(common.SHAPES["text"], "-q", "11")
assert our_stream_result(pipe_stream, 22) is None, "Buffer(22) must refuse a WBITS-24 pipe stream"
assert our_stream(pipe_stream, 24) == common.SHAPES["text"], "Buffer(24) must decode it"

# 2. The window lane: -w 10..24 on the text shape (the header's WBITS is the
#    stream's own, and the one-shot has no cap, so every value must decode),
#    and the four values the research's lane used on the other shapes.
window_rows = 0
for w in range(10, 25):
    window_rows += sweep([("text", common.SHAPES["text"])], "-q", "11", "-w", str(w))
for w in ("10", "16", "22", "24"):
    window_rows += sweep(
        [row for row in sweep_inputs if row[0] in ("empty", "rle")], "-q", "11", "-w", w
    )

# 3. The metadata lane: the CLI's -C comment is a metadata meta-block, which
#    skips without touching the output, the window, or the context (RFC 7932
#    §2). The CLI verifies the comment when asked to; ours ignores it.
text = common.SHAPES["text"]
comment = base64.b64encode(b"brotli-oracle")
metadata_rows = 0
stream = cli_encode(text, "-q", "11", "-C", comment.decode())
assert cli(["-d", "-c", "-C", comment.decode()], stream).stdout == text
go_decode(stream, text)
assert our_decode(stream, len(text)) == text
wrong = base64.b64encode(b"not-the-comment").decode()
assert cli(["-d", "-c", "-C", wrong], stream).returncode != 0
metadata_rows += 1

# 4. The trailing rule (T4): the CLI fails closed on bytes after the stream;
#    our one-shot ignores them and returns the stream's own bytes.
#    Concatenation is the same rule seen twice: one call, one stream, and the
#    CLI needs -K to walk the second.
boundary_rows = 0
for desc, data in (("text", text), ("rle", common.SHAPES["rle"])):
    stream = cli_encode(data, "-q", "9")
    assert our_decode(stream + b"garbage", len(data)) == data, f"trailing bytes ({desc})"
    assert cli_decode(stream + b"garbage") is None, f"CLI accepted trailing bytes ({desc})"
    assert go_decode_result(stream + b"garbage") is None, f"Go accepted trailing bytes ({desc})"
    assert our_decode(stream + stream, len(data)) == data, f"concatenation ({desc})"
    assert cli_decode(stream + stream) is None, f"CLI accepted concatenation ({desc})"
    assert go_decode_result(stream + stream) is None, f"Go accepted concatenation ({desc})"
    assert cli(["-d", "-K", "-c"], stream + stream).stdout == data + data, f"-K ({desc})"
    boundary_rows += 1

# 5. The empty lane: zero bytes is no stream at all (ours Truncated, the CLI
#    "corrupt input"), and the empty family — RFC 7932 §9.2's last-empty
#    forms, T5's metadata terminators included — decodes to zero bytes through
#    both.
assert our_decode_fails(b"", 0)
assert cli_decode(b"") is None
empty_family = (
    b"\x06",
    b"\x81\x01",
    b"\xa1\x01",
    b"\xb1\x01",
    b"\xc1\x01",
    b"\xd1\x01",
    b"\xe1\x01",
    b"\xf1\x01",
    b"\x33",
    b"\x35",
    b"\x37",
    b"\x39",
    b"\x3b",
    b"\x3d",
    b"\x3f",
    b"\x1a",
    b"\x81\x16\x00\x58",
)
for stream in empty_family:
    assert cli_decode(stream) == b"", f"oracle decode ({stream.hex()})"
    assert go_decode_result(stream) == b"", f"Go decode ({stream.hex()})"
    assert our_decode(stream, 0) == b"", f"our decode ({stream.hex()})"


def prefix_sample(stream: bytes, limit: int = 256) -> list[int]:
    """The prefix lengths to try: every one for a short stream, an even sample
    (plus the last byte) for a long one, so the lane stays a few seconds."""
    if len(stream) <= limit:
        return list(range(len(stream)))
    stride = len(stream) // limit + 1
    return [*range(0, len(stream) - 1, stride), len(stream) - 1]


# 6. The truncation battery (RFC 7932 §10): every strict prefix of a valid
#    stream is refused by both decoders, never accepted as a shorter stream.
truncations = 0
for desc, data in sweep_inputs:
    stream = cli_encode(data, "-q", "9")
    for n in prefix_sample(stream):
        assert our_decode_fails(stream[:n], len(data)), f"our decode took a prefix ({desc}, {n})"
        assert cli_decode(stream[:n]) is None, f"the CLI took a prefix ({desc}, {n})"
        assert go_decode_result(stream[:n]) is None, f"Go took a prefix ({desc}, {n})"
        truncations += 1

# 7. The corruption battery (T6): the format has no checksum, so a flipped
#    bit either fails or decodes to different bytes. Where the CLI refuses,
#    ours must refuse too; where the CLI decodes, ours must decode the same
#    bytes — a byte-exact decoder has no third answer. The cap is generous so
#    that a flip which inflates a length still compares content.
corrupt_cap = 8 * 1024 * 1024
corruptions = 0
for desc, data in (("text", text), ("rle", common.SHAPES["rle"])):
    stream = cli_encode(data, "-q", "9")
    for i in range(len(stream)):
        for bit in (0, 7):
            corrupt = bytearray(stream)
            corrupt[i] ^= 1 << bit
            label = f"{desc}, byte {i} bit {bit}"
            ours = our_decode_result(bytes(corrupt), corrupt_cap)
            for reference, plain in (
                ("the CLI", cli_decode(bytes(corrupt))),
                ("Go", go_decode_result(bytes(corrupt))),
            ):
                if plain is None:
                    assert ours is None, f"our decode took a stream {reference} refuses ({label})"
                elif ours is None:
                    # Our cap refused a stream whose output the reference
                    # decoded past it: acceptable only when that output is
                    # longer than the cap.
                    assert len(plain) > corrupt_cap, f"our decode failed early ({label})"
                else:
                    assert ours == plain, f"our decode differs from {reference} ({label})"
            corruptions += 1

# 8. The Go encoder's streams: andybalholm/brotli's encoder is a second
#    reference encoder with its own block layout, so its streams are a fresh
#    family for our decoder. Every one decodes through ours to the input, and
#    through the CLI's decoder too.
go_streams = 0
for desc, data in sweep_inputs:
    for quality in ("0", "1", "5", "9", "11"):
        stream = go_encode(data, quality)
        label = f"{desc}, Go q{quality}"
        assert our_decode(stream, len(data)) == data, f"our decode ({label})"
        assert cli_decode(stream) == data, f"the CLI's decode ({label})"
        go_streams += 1

# 9. The file lane: the CLI takes its window from a file's size when it can
#    stat one (10 for a tiny file, 14..19 up the size ladder), where every
#    stdin stream above is WBITS 24 — the pipe form cannot be stat'd, so the
#    CLI uses the maximum window. Both classes are whole streams for our
#    decoder, and the sniffer pins the class each row is in.
file_ladder = (
    ("empty file", b""),
    ("1-byte file", b"A"),
    ("12-byte file", b"hello world\n"),
    ("8 KiB text file", text),
    ("133 KiB rle file", common.SHAPES["rle"]),
    ("390 KiB RFC file", (root / "docs/research/specs/rfc7932-brotli.txt").read_bytes()),
)
file_rows = 0
file_windows: set[int] = set()
for desc, data in file_ladder:
    for quality in ("0", "5", "11"):
        stream = cli_encode_file(data, quality)
        label = f"{desc}, q{quality}"
        window = wbits(stream)
        assert 10 <= window <= 24, f"the sniffer lost the header ({label})"
        assert our_decode(stream, len(data)) == data, f"our decode ({label})"
        go_decode(stream, data)
        file_windows.add(window)
        file_rows += 1
# F1 of src/brotli/AGENTS.md, pinned: a tiny file gets the smallest window,
# and the pipe form gets the largest.
assert wbits(cli_encode_file(b"A", "11")) == 10, "a 1-byte file is WBITS 10 (F1)"
stdin_windows = {wbits(cli_encode(text, "-q", quality)) for quality in ("0", "5", "11")}
assert stdin_windows == {24}, f"stdin streams are not WBITS 24: {stdin_windows}"

print(
    "brotli-oracle: "
    f"{swept} CLI streams over {len(sweep_inputs)} inputs x {len(qualities)} qualities, "
    f"+ {streamed} of them through the streaming reader (doubled, too), "
    f"+ {ring_rows} ring rows (Buffer(10..24)), "
    f"+ {window_rows} window rows, + {metadata_rows} metadata row, "
    f"+ {boundary_rows} boundary rows, + {len(empty_family)} empty-family streams, "
    f"+ {truncations} truncations, + {corruptions} corruptions, "
    f"+ {go_streams} Go-encoder streams, + {file_rows} file rows "
    f"(WBITS {min(file_windows)}..{max(file_windows)} against the pipe form's 24): OK"
)
