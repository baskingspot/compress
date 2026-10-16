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

The dictionary rows (RFC 8878 §5) train a dictionary with the CLI itself
(`zstd --train -r <dir>` over the corpus shapes), compress every shape with
`-D`, and require every frame to decode through our one-shot (the
`decode-dict` harness mode) and klauspost's `WithDecoderDicts`; the
mismatch rows pin the error names (no dictionary, a second trained
dictionary), and the hand-built §5 boundary pair records the pinned CLI's
verdict against ours (it decodes the late reach, we refuse it — DT1).
"""

import base64
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
        (
            "long text (2 MiB)",
            b"the quick brown fox jumps over the lazy dog. " * 44_000,
            True,
        ),
        (
            "RFC 8878 text",
            (root / "docs/research/specs/rfc8878-zstd.txt").read_bytes(),
            True,
        ),
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
        (
            "repo prose (src/zstd/AGENTS.md)",
            (root / "src/zstd/AGENTS.md").read_bytes(),
            True,
        ),
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


def our_dict_frame(data: bytes, dict: bytes, pipe: bool = False) -> bytes:
    """Our with-dictionary frame: the one-shot (the file class) or the Writer
    (the pipe class the CLI writes for `zstd -D dict -1 -c`)."""
    with tempfile.TemporaryDirectory() as tmp:
        dict_path = Path(tmp) / "dict.bin"
        dict_path.write_bytes(dict)
        mode = "encode-stream-dict" if pipe else "encode-dict"
        return common.harness_output(harness, mode, data, str(dict_path))


def our_raw_dict_frame(data: bytes, content: bytes) -> bytes:
    """Our one-shot frame with a raw (format-free) dictionary."""
    with tempfile.TemporaryDirectory() as tmp:
        dict_path = Path(tmp) / "dict.bin"
        dict_path.write_bytes(content)
        return common.harness_output(harness, "encode-raw-dict", data, str(dict_path))


def cli_test_dict(frame: bytes, dict: bytes) -> None:
    """The CLI's `zstd -t -D dict` on one frame."""
    with tempfile.TemporaryDirectory() as tmp:
        frame_path = Path(tmp) / "frame.zst"
        dict_path = Path(tmp) / "dict.bin"
        frame_path.write_bytes(frame)
        dict_path.write_bytes(dict)
        result = run(["zstd", "-t", "-q", "-D", str(dict_path), str(frame_path)])
        if result.returncode != 0:
            raise AssertionError(f"zstd -t -D failed: {result.stderr.decode().strip()}")


def our_decode_dict(frame: bytes, cap: int, dict: bytes) -> subprocess.CompletedProcess:
    """Our one-shot decode of `frame` with `dict` (the harness's `decode-dict`)."""
    with tempfile.TemporaryDirectory() as tmp:
        frame_path = Path(tmp) / "frame.zst"
        dict_path = Path(tmp) / "dict.bin"
        frame_path.write_bytes(frame)
        dict_path.write_bytes(dict)
        return run([str(harness), "decode-dict", str(frame_path), str(cap), str(dict_path)])


def our_decode_raw_dict(frame: bytes, cap: int, content: bytes) -> subprocess.CompletedProcess:
    """Our one-shot decode of `frame` with `content` as a raw dictionary."""
    with tempfile.TemporaryDirectory() as tmp:
        frame_path = Path(tmp) / "frame.zst"
        dict_path = Path(tmp) / "dict.bin"
        frame_path.write_bytes(frame)
        dict_path.write_bytes(content)
        return run([str(harness), "decode-raw", str(frame_path), str(cap), str(dict_path)])


def our_decode_nodict(frame: bytes, cap: int) -> subprocess.CompletedProcess:
    """Our one-shot decode of `frame` with no dictionary."""
    with tempfile.TemporaryDirectory() as tmp:
        frame_path = Path(tmp) / "frame.zst"
        frame_path.write_bytes(frame)
        return run([str(harness), "decode", str(frame_path), str(cap)])


def cli_dict_frame(data: bytes, dict: bytes, pipe: bool = False) -> bytes:
    """The CLI's `-D dict -1` frame: the file form (exact FCS) or the pipe
    form (the FCS-unknown header)."""
    if pipe:
        with tempfile.TemporaryDirectory() as tmp:
            dict_path = Path(tmp) / "dict.bin"
            dict_path.write_bytes(dict)
            result = run(["zstd", "-D", str(dict_path), "-1", "-q", "-c"], data)
            if result.returncode != 0:
                raise AssertionError(f"zstd -D -1 -c failed: {result.stderr.decode().strip()}")
            return result.stdout
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "in"
        target = Path(tmp) / "out.zst"
        dict_path = Path(tmp) / "dict.bin"
        source.write_bytes(data)
        dict_path.write_bytes(dict)
        result = run(
            [
                "zstd",
                "-D",
                str(dict_path),
                "-1",
                "-q",
                "-f",
                str(source),
                "-o",
                str(target),
            ]
        )
        if result.returncode != 0:
            raise AssertionError(f"zstd -D -1 failed: {result.stderr.decode().strip()}")
        return target.read_bytes()


def cli_dict_decode(frame: bytes, dict: bytes) -> subprocess.CompletedProcess:
    """The CLI's own `zstd -D dict -d` of one frame."""
    with tempfile.TemporaryDirectory() as tmp:
        frame_path = Path(tmp) / "frame.zst"
        dict_path = Path(tmp) / "dict.bin"
        frame_path.write_bytes(frame)
        dict_path.write_bytes(dict)
        return run(["zstd", "-D", str(dict_path), "-d", "-q", "-c", str(frame_path)])


def klauspost_decode_dict(
    frame: bytes, expected: bytes, dict: bytes
) -> subprocess.CompletedProcess:
    """klauspost's `WithDecoderDicts` decode of one frame."""
    with tempfile.TemporaryDirectory() as tmp:
        frame_path = Path(tmp) / "frame.zst"
        plain_path = Path(tmp) / "plain"
        dict_path = Path(tmp) / "dict.bin"
        frame_path.write_bytes(frame)
        plain_path.write_bytes(expected)
        dict_path.write_bytes(dict)
        return run([str(klauspost), str(frame_path), str(plain_path), str(dict_path)])


def train_dictionary(samples: list[bytes], maxdict: int) -> bytes:
    """The pinned CLI trains a dictionary over `samples` (`zstd --train -r`)."""
    with tempfile.TemporaryDirectory() as tmp:
        sample_dir = Path(tmp) / "train"
        sample_dir.mkdir()
        for index, sample in enumerate(samples):
            (sample_dir / f"s{index:02d}.txt").write_bytes(sample)
        out = Path(tmp) / "dict.bin"
        result = run(
            [
                "zstd",
                "--train",
                "-q",
                "-r",
                str(sample_dir),
                "-o",
                str(out),
                f"--maxdict={maxdict}",
            ]
        )
        if result.returncode != 0:
            raise AssertionError(f"zstd --train failed: {result.stderr.decode().strip()}")
        return out.read_bytes()


def check_dictionary_rows() -> int:
    """The `-D` rows: the CLI trains, we decode. Returns the row count."""
    # The training set: the corpus shapes, sliced so the trainer sees several
    # samples (the CLI wants the source at least 10x the dictionary).
    rows = [
        ("text", common.SHAPES["text"], True),
        ("random", common.SHAPES["random"], True),
        ("rle", common.SHAPES["rle"], True),
        ("long text (multi-block)", common.SHAPES["long text (multi-block)"], True),
    ]
    samples = []
    for _, data, _ in rows:
        samples.extend(data[at : at + 2048] for at in range(0, min(len(data), 16 * 1024), 2048))
    dictionary = train_dictionary(samples, 4096)
    # A second dictionary: the mismatch seat.
    other = train_dictionary(samples[1:], 4096)
    assert dictionary != other, "two trainings produced the same bytes"

    checked = 0
    for desc, data, _ in rows:
        if not data:
            continue
        for pipe in (False, True):
            frame = cli_dict_frame(data, dictionary, pipe=pipe)
            # The CLI's own decode is the reference.
            cli = cli_dict_decode(frame, dictionary)
            if cli.returncode != 0:
                raise AssertionError(f"zstd -D -d failed ({desc}): {cli.stderr.decode().strip()}")
            assert cli.stdout == data, (
                f"CLI -D decode ({desc}): {len(cli.stdout)} bytes, want {len(data)}"
            )
            # Ours, with the dictionary.
            ours = our_decode_dict(frame, len(data), dictionary)
            if ours.returncode != 0:
                raise AssertionError(
                    f"our -D decode failed ({desc}): {ours.stderr.decode().strip()}"
                )
            assert ours.stdout == data, f"our -D decode ({desc}): {len(ours.stdout)} bytes"
            # klauspost's WithDecoderDicts.
            kp = klauspost_decode_dict(frame, data, dictionary)
            if kp.returncode != 0:
                raise AssertionError(
                    f"klauspost -D decode failed ({desc}): {kp.stderr.decode().strip()}"
                )
            checked += 1

        # The mismatch matrix: a frame that names the dictionary's ID must
        # fail `DictionaryRequired` without one and `DictionaryMismatch` with
        # another (the CLI fails both with "Dictionary mismatch").
        frame = cli_dict_frame(data, dictionary)
        bare = our_decode_nodict(frame, len(data))
        if bare.returncode == 0:
            raise AssertionError(f"no-dictionary decode succeeded ({desc})")
        assert b"DictionaryRequired" in bare.stderr, bare.stderr
        wrong = our_decode_dict(frame, len(data), other)
        if wrong.returncode == 0:
            raise AssertionError(f"wrong-dictionary decode succeeded ({desc})")
        assert b"DictionaryMismatch" in wrong.stderr, wrong.stderr
        # A raw dictionary names no ID, so it is a mismatch too (the CLI's
        # "Dictionary mismatch" for the same shape).
        raw = our_decode_raw_dict(frame, len(data), data[:4096])
        assert raw.returncode != 0 and b"DictionaryMismatch" in raw.stderr, raw.stderr
        checked += 3

    # The encode rows: the parity target is `zstd -D dict -1`, form-matched —
    # the one-shot against the CLI's file form (the exact
    # Frame_Content_Size), the Writer against its pipe form (`-c`, the
    # FCS-unknown header). The CLI's own frame is the reference, byte for
    # byte; `zstd -t -D` and our own decoder verify every frame. The 8-KiB
    # boundary is the C's attach/copy switch, so the rows bracket it.
    for desc, data, _ in rows:
        if not data:
            continue
        for pipe in (False, True):
            frame = cli_dict_frame(data, dictionary, pipe=pipe)
            ours = our_dict_frame(data, dictionary, pipe=pipe)
            assert ours == frame, (
                f"with-dictionary parity ({desc}, pipe={pipe}): "
                f"{len(ours)} bytes against the CLI's {len(frame)}"
            )
            cli_test_dict(frame, dictionary)
            decoded = our_decode_dict(frame, len(data), dictionary)
            if decoded.returncode != 0 or decoded.stdout != data:
                raise AssertionError(
                    f"our decode of the parity frame ({desc}, pipe={pipe}): "
                    f"{decoded.stderr.decode().strip()}"
                )
            checked += 1

    # A raw dictionary (`§5`'s format-free form): the CLI takes any file with
    # `-D`, and the frame names no ID. The parity target is the same switch.
    raw_content = common.SHAPES["text"][:4096]
    raw_data = common.SHAPES["long text (multi-block)"]
    raw_frame = cli_dict_frame(raw_data, raw_content)
    raw_ours = our_raw_dict_frame(raw_data, raw_content)
    assert raw_ours == raw_frame, "raw-dictionary parity"
    cli_test_dict(raw_frame, raw_content)
    decoded = our_decode_raw_dict(raw_frame, len(raw_data), raw_content)
    if decoded.returncode != 0 or decoded.stdout != raw_data:
        raise AssertionError(f"our raw-dictionary decode: {decoded.stderr.decode().strip()}")
    checked += 1

    # The C's incomplete-statistics fixture (`zero-weight-dict`, committed
    # in src/zstd/testdata as base64 text): the CLI compresses with it and we
    # decode the frame — and our encoder re-emits the CLI's own frame byte
    # for byte, the promotion rules degrading exactly as the C's do (its
    # literals tree has zero weights, so nothing is reused blindly).
    zero_weight = base64.b64decode(
        (root / "src/zstd/testdata/dict-zero-weight.bin.base64").read_text()
    )
    data = common.SHAPES["text"]
    frame = cli_dict_frame(data, zero_weight)
    ours = our_decode_dict(frame, len(data), zero_weight)
    if ours.returncode != 0:
        raise AssertionError(f"zero-weight decode failed: {ours.stderr.decode().strip()}")
    assert ours.stdout == data, "zero-weight decode bytes"
    encoded = our_dict_frame(data, zero_weight)
    assert encoded == frame, "zero-weight encode parity"
    checked += 2

    # The §5 boundary pair (the hand-built fixtures in golden.zig, same
    # bytes): the pinned CLI decodes both — the second reads the dictionary
    # across the boundary — and ours decodes the first and refuses the
    # second with `OffsetTooFar` (the fail-closed DT1 decision).
    boundary = bytes.fromhex(
        "37a430ec2a00000084432010731000e0a0a1d2d1b6d9480d"
        "141f012010b4d0bf00141f012010b4d0bf0001000000020000000300000058595a"
    )
    boundary_short = bytes.fromhex(
        "37a430ec2a00000084432010731000e0a0a1d2d1b6d9480d"
        "141f012010b4d0bf00141f012010b4d0bf000100000002000000020000005859"
    )
    frame_ok = bytes.fromhex("28b52ffd01002a022000413d000000010006001908")
    frame_over = bytes.fromhex("28b52ffd01002a022000410a0000413d000000010006001908")
    frame_straddle = bytes.fromhex("28b52ffd01002a022000413d000000010004001908")
    expected_ok = b"A" * 1024 + b"XYZ"
    expected_straddle = b"A" * 1024 + b"ZAA"
    for name, frame in (
        ("at the boundary", frame_ok),
        ("past the boundary", frame_over),
    ):
        cli = cli_dict_decode(frame, boundary)
        if cli.returncode != 0:
            raise AssertionError(f"the CLI refused the {name} frame: {cli.stderr.decode().strip()}")
        if name == "at the boundary":
            assert cli.stdout == expected_ok, "the CLI's boundary decode bytes"
            ours = our_decode_dict(frame, len(expected_ok), boundary)
            if ours.returncode != 0:
                raise AssertionError(f"our boundary decode failed: {ours.stderr.decode().strip()}")
            assert ours.stdout == expected_ok, "our boundary decode bytes"
        else:
            # The CLI's leniency recorded: it decodes the late reach (reading
            # the dictionary's tail and the output's first byte).
            assert cli.stdout == b"A" * 1025 + b"YZA", "the CLI's late-reach bytes"
            ours = our_decode_dict(frame, 2048, boundary)
            if ours.returncode == 0:
                raise AssertionError("our decode accepted the late reach")
            assert b"OffsetTooFar" in ours.stderr, ours.stderr
            # The short-content dictionary is a reach past the content: the
            # CLI reads a byte in front of it, we refuse.
            short_cli = cli_dict_decode(frame_ok, boundary_short)
            assert short_cli.returncode == 0, "the CLI refused the short-content frame"
            short = our_decode_dict(frame_ok, 2048, boundary_short)
            if short.returncode == 0:
                raise AssertionError("our decode accepted the short-content reach")
            assert b"OffsetTooFar" in short.stderr, short.stderr
        checked += 1
    # The straddling match: one dictionary byte and the output's own first
    # two. The CLI and ours agree on it.
    cli = cli_dict_decode(frame_straddle, boundary)
    if cli.returncode != 0 or cli.stdout != expected_straddle:
        raise AssertionError(f"the CLI's straddle decode: {cli.stderr.decode().strip()}")
    ours = our_decode_dict(frame_straddle, len(expected_straddle), boundary)
    if ours.returncode != 0 or ours.stdout != expected_straddle:
        raise AssertionError(f"our straddle decode: {ours.stderr.decode().strip()}")
    checked += 1
    return checked


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
dict_rows = check_dictionary_rows()

print(
    f"zstd-oracle: {len(rows)} inputs x 2 encoder forms -> zstd -t, zstd -d, "
    "klauspost DecodeAll + stream, our decode; byte parity with zstd -1 on "
    f"both header forms for {parity_rows} of them; {dict_rows} dictionary "
    "rows (CLI-trained, the mismatch matrix, and the §5 boundary): OK"
)
