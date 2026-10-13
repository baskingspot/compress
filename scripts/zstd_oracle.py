"""Check zstd against the reference CLI and klauspost/compress.

The encoder's class is the CLI v1.5.7's level 1, so every input is encoded
through both public forms — the one-shot (`encode.compress`) and the
streaming Writer — and every frame is checked all the way around: it must
decode through the CLI, through klauspost/compress, and through our own
decoder, and it must be byte-identical to the CLI's own frame for the same
input (the one-shot against `zstd -1` on a file, whose header declares the
exact Frame_Content_Size; the Writer against `zstd -1` on a pipe, whose
header declares the window instead). The CLI's frames decode through our
decoder too.

The two forms are two different classes and must not be compared across:
a pipe's length is unknown when the header goes out, so the CLI's pipe frame
carries the FCS-unknown header and its streaming parameters (windowLog 19,
hashLog 14, 7-byte hashing), while its file frame is single-segment with the
exact Frame_Content_Size under the window cap and the source-size parameter
class. On a 3.4-KiB file the CLI's own two forms differ by 102 bytes
(`README.md`: 1767 against 1869); our one-shot is the file form byte for byte
and our Writer the pipe form.

The input set covers the two blind spots the encoder's own tests cannot see:
bytes of 0x81 and above (a literals tree that lists more than 128 weights
must still take the FSE weight form, not fall back to Raw) and inputs over
512 KiB (every match offset must stay strictly below the declared
Window_Size, RFC 8878 §3.1.1.4 — the C decoder and ours accept offsets past
it when the block's own output makes the bytes addressable, klauspost does
not, so its decoder is the strict check). Run it with `just zstd-oracle`;
zstd and go come from the flake. The harness is built from
src/zstd/oracle.zig, the klauspost decoder from scripts/zstd_klauspost. The
shared plumbing is in scripts/oracle_common.py.
"""

import random
import subprocess
import tempfile
from pathlib import Path

import oracle_common as common

root = common.ROOT
harness = root / "zig-out/bin/zstd-oracle"
klauspost = root / "zig-out/bin/zstd-klauspost"

# The UTF-8 phrase behind the non-ASCII rows: a BOM, a two-byte sequence
# (é, ï), and a three-byte one (—), so the literals carry bytes on both sides
# of 0x81.
non_ascii_phrase = "café naïve — the quick brown fox jumps. ".encode()


def non_ascii(size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        data += non_ascii_phrase
    data = data[:size]
    data[0:3] = b"\xef\xbb\xbf"  # the BOM
    return bytes(data)


def _inputs() -> list[tuple[str, bytes, bool]]:
    """The rows: description, bytes, and whether the C's own frame is the
    byte-parity target. The mixed-binary row is not: its compressible runs
    trigger the C v1.5.7's pre-block splitter (`ZSTD_splitBlock`, which cuts
    a full block to 32/64/96 KiB), a deliberate difference this port does not
    implement (TE8 in src/zstd/AGENTS.md), so its frames differ in block
    layout while both decode identically. Its round-trip rows still run."""
    rng = random.Random(20261013)
    period = bytes(rng.randrange(256) for _ in range(520 * 1024))
    mixed = bytearray()
    while len(mixed) < 1_500_000:
        if len(mixed) % 3 == 0:
            mixed += bytes(rng.randrange(256) for _ in range(997))
        else:
            mixed += b"\x5a" * 1301
    return [
        ("empty", b"", True),
        ("text", common.SHAPES["text"], True),
        ("random", common.SHAPES["random"], True),
        ("rle", common.SHAPES["rle"], True),
        ("long text (multi-block)", common.SHAPES["long text (multi-block)"], True),
        ("non-ASCII utf-8 (4 KiB)", non_ascii(4096), True),
        ("non-ASCII utf-8 (1 MiB)", non_ascii(1024 * 1024), True),
        ("520-KiB period", period * 2 + period[:41], True),
        ("mixed binary (1.5 MiB)", bytes(mixed[:1_500_000]), False),
        ("long text (2 MiB)", b"the quick brown fox jumps over the lazy dog. " * 44_000, True),
        ("RFC 8878 text", (root / "docs/research/specs/rfc8878-zstd.txt").read_bytes(), True),
        # The brotli RFC text triggers the C v1.5.7's pre-block splitter (its
        # frames carry four split blocks, ours three whole ones — TE8 in
        # src/zstd/AGENTS.md), so only its round-trip rows run: the class is
        # a deliberate block-layout difference, and our file-form frame is 9
        # bytes smaller while the pipe-form frame is 293 bytes larger.
        (
            "RFC 7932 text (TE8)",
            (root / "docs/research/specs/rfc7932-brotli.txt").read_bytes(),
            False,
        ),
        # Two repo files whose literals list more than 128 weights: without
        # the FSE weight form either row alone fails parity (src/zstd/AGENTS.md
        # is 23616 bytes against the CLI's 18402).
        ("repo prose (src/zstd/AGENTS.md)", (root / "src/zstd/AGENTS.md").read_bytes(), True),
        ("repo prose (README.md)", (root / "README.md").read_bytes(), True),
    ]


def run(argv: list[str], data: bytes | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(argv, input=data, capture_output=True, check=False)


def our_oneshot(data: bytes) -> bytes:
    return common.harness_output(harness, "encode-oneshot", data)


def our_stream(data: bytes) -> bytes:
    return common.harness_output(harness, "encode-stream", data)


def our_decode(frame: bytes, cap: int) -> bytes:
    return common.harness_output(harness, "decode", frame, str(cap))


def cli_oneshot(data: bytes) -> bytes:
    """`zstd -1` on a file: the exact-Frame_Content_Size header form."""
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "in"
        target = Path(tmp) / "out.zst"
        source.write_bytes(data)
        result = run(["zstd", "-1", "-q", "-f", str(source), "-o", str(target)])
        if result.returncode != 0:
            raise AssertionError(f"zstd -1 failed: {result.stderr.decode().strip()}")
        return target.read_bytes()


def cli_stream(data: bytes) -> bytes:
    """`zstd -1` on a pipe: the FCS-unknown header form the Writer writes."""
    result = run(["zstd", "-1", "-q", "-c"], data)
    if result.returncode != 0:
        raise AssertionError(f"zstd -1 -c failed: {result.stderr.decode().strip()}")
    return result.stdout


def cli_decode(frame: bytes) -> bytes:
    result = run(["zstd", "-d", "-q", "-c"], frame)
    if result.returncode != 0:
        raise AssertionError(f"zstd -d failed: {result.stderr.decode().strip()}")
    return result.stdout


def cli_test(frame: bytes) -> None:
    result = run(["zstd", "-t", "-q"], frame)
    if result.returncode != 0:
        raise AssertionError(f"zstd -t failed: {result.stderr.decode().strip()}")


def klauspost_decode(frame: bytes, expected: bytes) -> None:
    """klauspost/compress's strict-window decode of one frame."""
    with tempfile.TemporaryDirectory() as tmp:
        frame_path = Path(tmp) / "frame.zst"
        plain_path = Path(tmp) / "plain"
        frame_path.write_bytes(frame)
        plain_path.write_bytes(expected)
        result = run([str(klauspost), str(frame_path), str(plain_path)])
        if result.returncode != 0:
            raise AssertionError(f"klauspost rejected the frame: {result.stderr.decode().strip()}")


def check(desc: str, data: bytes, parity: bool) -> None:
    """Every row for one input, all three decoders and the byte parity."""
    frames = {"one-shot": our_oneshot(data), "Writer": our_stream(data)}
    for form, frame in frames.items():
        cli_test(frame)
        got = cli_decode(frame)
        assert got == data, f"CLI decode ({desc}, {form}): {len(got)} bytes, want {len(data)}"
        klauspost_decode(frame, data)
        got = our_decode(frame, len(data))
        assert got == data, f"our decode ({desc}, {form}): {len(got)} bytes, want {len(data)}"

    # The class reference, both header forms. The empty stream is the one
    # recorded divergence: the CLI knows the length by the time it ends the
    # frame, so its empty pipe frame is the one-shot's single-segment form.
    cli_one = cli_oneshot(data)
    if parity:
        assert frames["one-shot"] == cli_one, f"one-shot byte parity ({desc})"
        if data:
            assert frames["Writer"] == cli_stream(data), f"Writer byte parity ({desc})"
        else:
            assert cli_stream(data) == cli_one

    # The CLI's frames, back through our decoder: the exact-FCS form through
    # the one-shot, the pipe form through the streaming Reader (the example
    # CLI is the streaming pump's public surface).
    assert our_decode(cli_one, len(data)) == data, f"our decode of the CLI's frame ({desc})"
    if data:
        result = common.run_example("zstd", ["decode", "-"], cli_stream(data))
        if result.returncode != 0:
            raise AssertionError(f"example decode ({desc}): {result.stderr.decode().strip()}")
        assert result.stdout == data, f"example decode of the CLI's pipe frame ({desc})"


if not harness.exists():
    raise SystemExit("zstd-oracle: build the harness first (just zstd-oracle)")
if not klauspost.exists():
    raise SystemExit("zstd-oracle: build the klauspost decoder first (just zstd-oracle)")

rows = _inputs()
for desc, data, parity in rows:
    check(desc, data, parity)
parity_rows = sum(1 for _, _, parity in rows if parity)

print(
    f"zstd-oracle: {len(rows)} inputs x 2 encoder forms -> zstd -t, zstd -d, "
    "klauspost DecodeAll + stream, our decode; byte parity with zstd -1 on "
    f"both header forms for {parity_rows} of them: OK"
)
