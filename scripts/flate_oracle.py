"""Check flate against python3's zlib and klauspost/compress.

Python's zlib is an independent raw-deflate implementation, and it verifies
ours in both directions (our encode -> its decode, its encode -> our decode)
over the Go fixture pairs, generated shapes, and streaming rows through the
example CLI. Level 6 additionally has a byte-parity lane: klauspost/compress's
flate at level 6 (the pinned module version, scripts/klauspost_flate) is the
byte target, and each side's stream must decode through the other.

Level 1 is a class pin, not a byte pin (no reference emits our fixed-Huffman
class): its rows are the fixture pairs, the python3 zlib judges, and a frozen
hash per shape — the level-6 work must not perturb a single byte of it.

Run it with `just flate-oracle`; python3 and Go come from the flake. The
harness is built from src/flate/oracle.zig, the parity tool from
scripts/klauspost_flate. The shared plumbing is in scripts/oracle_common.py.
"""

import base64
import hashlib
import os
import subprocess
import tempfile
import zlib

import oracle_common as common

root = common.ROOT
harness = root / "zig-out/bin/flate-oracle"
klauspost = root / "zig-out/bin/flate-klauspost"
testdata = root / "src/flate/testdata"
corpus_dir = root / "bench/corpus-gen"

# Every testdata input fixture, one entry per pair: the text `.in` files read
# as committed; the binary ones commit `.in.base64` (no binary files in git,
# the `check_binary_files` gate) and decode here.
inputs = []
for inp in sorted(testdata.glob("*.in")):
    inputs.append((inp.name, inp.read_bytes()))
for inp in sorted(testdata.glob("*.in.base64")):
    inputs.append((inp.stem, base64.b64decode(inp.read_text())))
input_by_name = dict(inputs)
assert len(inputs) == 9, f"expected 9 input fixtures, found {len(inputs)}"


# Raw-deflate shapes the oracle can emit. zlib has no level -2 (that is
# Go's `flate.HuffmanOnly`); the huffman-only stream is the Z_HUFFMAN_ONLY
# strategy here, which is the shape that exercises dynamic blocks.
def make_raw(level, strategy=zlib.Z_DEFAULT_STRATEGY):
    def compress(data):
        co = zlib.compressobj(level, zlib.DEFLATED, -15, zlib.DEF_MEM_LEVEL, strategy)
        return co.compress(data) + co.flush()

    return compress


raw_shapes = (
    ("stored (level 0)", make_raw(0)),
    ("huffman-only", make_raw(6, zlib.Z_HUFFMAN_ONLY)),
    ("level 1", make_raw(1)),
    ("level 6", make_raw(6)),
    ("level 9", make_raw(9)),
)


def our_decompress(raw: bytes, cap: int) -> bytes:
    """Our decoder, through the oracle harness: raw deflate, target cap."""
    return common.harness_output(harness, "decode", raw, str(cap))


def our_decompress_dict(raw: bytes, cap: int, zdict: bytes) -> bytes:
    """Our decoder with a preset dictionary (`§3.2.3`)."""
    return common.harness_output_dict(harness, "decode", raw, zdict, str(cap))


def our_decompress_fails(raw: bytes, cap: int) -> bool:
    return common.run_harness(harness, "decode", raw, str(cap)).returncode != 0


def our_compress(data: bytes, level: int = 1) -> bytes:
    """Our encoder, through the oracle harness: the raw deflate stream for
    `data` at `level` (1 by default, 6 for the dynamic-Huffman class)."""
    return common.harness_output(harness, "encode", data, str(level))


def our_compress_dict(data: bytes, zdict: bytes, level: int = 1) -> bytes:
    """Our encoder against a preset dictionary."""
    return common.harness_output_dict(harness, "encode", data, zdict, str(level))


def klauspost_encode(data: bytes, level: int, zdict: bytes | None = None) -> bytes:
    """klauspost/compress's flate at `level`: one raw deflate stream."""
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "in")
        out = os.path.join(tmp, "out")
        with open(src, "wb") as f:
            f.write(data)
        argv = [str(klauspost), "encode", str(level), src, out]
        if zdict is not None:
            dict_path = os.path.join(tmp, "dict")
            with open(dict_path, "wb") as f:
                f.write(zdict)
            argv.append(dict_path)
        result = subprocess.run(argv, capture_output=True, check=False)
        if result.returncode != 0:
            raise AssertionError(f"klauspost encode failed: {result.stderr.decode().strip()}")
        with open(out, "rb") as f:
            return f.read()


def klauspost_decode(stream: bytes, expected: bytes) -> None:
    """klauspost/compress's inflate of `stream`, required to equal `expected`."""
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "stream")
        want = os.path.join(tmp, "expected")
        with open(src, "wb") as f:
            f.write(stream)
        with open(want, "wb") as f:
            f.write(expected)
        result = subprocess.run(
            [str(klauspost), "decode", src, want], capture_output=True, check=False
        )
        if result.returncode != 0:
            raise AssertionError(f"klauspost decode failed: {result.stderr.decode().strip()}")


def python_decompress(raw: bytes) -> bytes:
    do = zlib.decompressobj(-15)
    return do.decompress(raw) + do.flush()


def python_decompress_dict(raw: bytes, zdict: bytes) -> bytes:
    do = zlib.decompressobj(-15, zdict)
    return do.decompress(raw) + do.flush()


def python_compress_dict(data: bytes, zdict: bytes, level: int = 6) -> bytes:
    co = zlib.compressobj(
        level, zlib.DEFLATED, -15, zlib.DEF_MEM_LEVEL, zlib.Z_DEFAULT_STRATEGY, zdict
    )
    return co.compress(data) + co.flush()


def check(desc: str, data: bytes, cap: int) -> None:
    """Both directions: an oracle-compressed stream decodes to `data` in our
    decoder, our encoder's stream decodes to `data` in the oracle, and the
    oracle itself round-trips the same bytes."""
    for shape, compress in raw_shapes:
        raw = compress(data)
        assert python_decompress(raw) == data, f"oracle round trip ({desc}, {shape})"
        got = our_decompress(raw, cap)
        assert got == data, f"our decode ({desc}, {shape}): {len(got)} bytes, want {len(data)}"

    # Our encode -> the oracle's decode. This is the main check of the
    # bit-packing rules (`§3.1.1`): a `writeBits`/`writeCode` mix-up
    # round-trips against our own decoder and fails here.
    ours = our_compress(data)
    got = python_decompress(ours)
    assert got == data, f"our encode ({desc}): oracle decoded {len(got)} bytes, want {len(data)}"
    # The stream ends with the empty fixed block `03 00` (byte-aligned) or
    # that pattern shifted into the last three bytes; either way the final
    # byte is zero and the bit before it is the ending's BTYPE bit.
    assert ours[-1] == 0x00, f"our encode ({desc}): final byte {ours[-1]:#x}"


# The generated conformance shapes (oracle_common.SHAPES): the same bytes in
# every script.
shapes = common.SHAPES

# 1. The committed golang/go pairs: `.golden` is a single non-final block,
#    so verbatim it must be rejected, and with BFINAL set on that block it
#    must decode to `.in` (both verified against the oracle).
pairs = 0
for golden in sorted(testdata.glob("*.golden.base64")):
    name = golden.name[: -len(".golden.base64")] + ".in"
    data = input_by_name[name]
    raw = base64.b64decode(golden.read_text())
    assert python_decompress(raw) == data, f"oracle decode ({golden.name})"
    assert our_decompress_fails(raw, len(data)), f"{golden.name}: non-final block accepted"
    completed = bytearray(raw)
    completed[0] |= 1  # BFINAL on the fixture's single block header
    assert python_decompress(bytes(completed)) == data, f"oracle decode ({golden.name}, final)"
    got = our_decompress(bytes(completed), len(data))
    assert got == data, f"our decode ({golden.name}): {len(got)} bytes, want {len(data)}"
    pairs += 1
assert pairs == 9, f"expected 9 testdata pairs, found {pairs}"

# 2. The oracle's own streams over the same inputs, every level, and our
#    encoder's streams for the same bytes (both directions).
for name, data in inputs:
    check(name, data, len(data) + 1)

# 3. The generated shapes: empty, text, random, single-byte runs, and a long
#    text that spans several 64-KiB blocks (the encoder's cross-block
#    matches).
for desc, data in shapes.items():
    check(desc, data, len(data) + 1)


# 4. The streaming row: the example CLI pumps through flate.Reader and
#    flate.Writer, so this drives the streaming layer end to end through
#    the file CLI: its own encode -> decode round trip, and the oracle's
#    decode of the streaming encoder's stream, the same both-directions
#    rule as the one-shot checks above.
def example(args, data):
    result = common.run_example("flate", args, data)
    if result.returncode != 0:
        raise AssertionError(f"example-flate {args} failed: {result.stderr.decode().strip()}")
    return result.stdout


streaming = (
    ("streaming multi-block text", shapes["long text (multi-block)"]),
    ("streaming stored blocks", shapes["random"]),
)
for desc, data in streaming:
    raw = example(["encode", "-"], data)
    assert python_decompress(raw) == data, f"example encode -> oracle decode ({desc})"
    back = example(["decode", "-"], raw)
    assert back == data, f"example round trip ({desc}): {len(back)} bytes, want {len(data)}"

fixture_inputs = len(inputs) + len(shapes)

# 5. The preset dictionary (`§3.2.3`): raw deflate names no dictionary, so the
#    caller vouches for the bytes on both sides — this lane is round-trip
#    conformance, not byte parity. Our streams against a dictionary decode in
#    the oracle with the same zdict; the oracle's dictionary-compressed
#    streams decode here. A stream whose match reaches into the dictionary is
#    `InvalidMatch` without it.
#
#    The large dictionary pins the 32-KiB window rule: only its tail is
#    matchable, and a source that repeats that tail is one long match.
dict_shapes = {
    "text dictionary": (b"the quick brown fox jumps over the lazy dog. " * 8)[:300],
    "large dictionary (40 KiB)": bytes(range(256)) * 160,
}
dict_rows = 0
for ddesc, zdict in dict_shapes.items():
    sources = dict(shapes)
    sources["dictionary tail"] = zdict[-64:]
    for desc, data in sources.items():
        ours = our_compress_dict(data, zdict)
        assert python_decompress_dict(ours, zdict) == data, (
            f"our encode -> zdict decode ({desc}, {ddesc})"
        )
        ref = python_compress_dict(data, zdict)
        assert python_decompress_dict(ref, zdict) == data, (
            f"oracle zdict round trip ({desc}, {ddesc})"
        )
        got = our_decompress_dict(ref, len(data) + 1, zdict)
        assert got == data, f"oracle zdict encode -> our decode ({desc}, {ddesc})"
        if desc == "dictionary tail":
            # The match reaches into the dictionary: without it the distance
            # is past the history.
            assert our_decompress_fails(ref, len(data) + 1), (
                f"{ddesc}: decode without the dictionary"
            )
            assert our_decompress_fails(ours, len(data) + 1), (
                f"{ddesc}: our stream without the dictionary"
            )
        dict_rows += 1

# 5b. The level-1 byte pin. Our level 1 is a class pin (no reference emits
#     the fixed-Huffman class), so nothing else freezes its bytes — but the
#     level-6 work shares its finder, its block split, and its bit writer, and
#     must not perturb a single one of them. These hashes were recorded before
#     the level-6 change; a deliberate level-1 change updates them.
level1_pins = {
    "empty": "9b4fb24edd6d1d8830e272398263cdbf026b97392cc35387b991dc0248a628f9",
    "text": "832ad7cbcee404f750dff41d1975053a83b787171dcfbd8a39cdda05f40bde19",
    "random": "443882bc818cf49236744cbc15bfe3c28d36766763e1132c793dc367eee96f6a",
    "rle": "91dc41c5cfa38e41694e60a2b08807d509d7ca971d8986a0239728f9405028fe",
    "long text (multi-block)": "77fbfe57735ecd5f26cada8a29c909f56e5ecb0e811fe3b2f1b255629bdb94e6",
    "fixture:huffman-pi.in": "7b71a31e7b4a718ee18c7b1a321da0cb9d3d870bf9dbc82a142a285b2840d3fa",
    "fixture:huffman-rand-limit.in": "324d667aa1941e0633650655656cdeebec5cbe35588a19ba5891af96376b77c4",
    "fixture:huffman-shifts.in": "5c53eaf3ea9a860ff14d04485f29784fd8b43849ab701c1c4c2f766532b08ffa",
    "fixture:huffman-text-shift.in": "554edcabd142c507265c988cb50c5a66f9a94ec71c3a31ec85facd276dd88616",
    "fixture:huffman-text.in": "15c79a75dbf2676934f38807359130482b619c24fff04443258ec03972a0d775",
    "fixture:huffman-zero.in": "3d4d2c520e4d6ffbf34610cfbcd79abe0c344c8b6f73cac92e30052b8d976092",
    "fixture:huffman-null-max.in": "11df0a25308e4b2ff4311779466fd6659528a1c0d8ba629a5293e89156971a0d",
    "fixture:huffman-rand-1k.in": "135dd156b6bc3900f30a8d910b018dccb2164203ae85a3fff06fd35b8534203f",
    "fixture:huffman-rand-max.in": "57545ce5b77e2ef05f2eaa2ea7eee8e31ff922a6df5b2bd815712bc36ec56c4a",
}
level1_rows = 0
pinned_inputs = {**{f"fixture:{name}": data for name, data in inputs}, **shapes}
for desc, data in pinned_inputs.items():
    digest = hashlib.sha256(our_compress(data)).hexdigest()
    assert digest == level1_pins[desc], (
        f"level 1 changed for {desc}: {digest} (the level-1 class is pinned; "
        "a deliberate change updates level1_pins)"
    )
    level1_rows += 1

# 6. The level-6 byte-parity lane: klauspost/compress's flate at level 6, the
#    pinned module version, is the byte target (src/flate/README.md). Our
#    stream must equal theirs byte for byte, and each side's stream must
#    decode through the other. The corpus shapes join the lane when the
#    generated corpus is present (`just corpus`); a clean tree runs the
#    oracle shapes and fixtures alone.
parity_inputs = dict(inputs)
parity_inputs.update(shapes)
if corpus_dir.is_dir():
    for path in sorted(corpus_dir.iterdir()):
        if "." in path.name or path.name == "SHA256SUMS":
            continue
        parity_inputs[f"corpus/{path.name}"] = path.read_bytes()

parity_rows = 0
for desc, data in parity_inputs.items():
    theirs = klauspost_encode(data, 6)
    ours = our_compress(data, 6)
    assert ours == theirs, (
        f"level 6 != klauspost level 6 ({desc}): ours {len(ours)} bytes, theirs {len(theirs)}"
    )
    got = our_decompress(theirs, len(data) + 1)
    assert got == data, f"klauspost level 6 -> our decode ({desc})"
    klauspost_decode(ours, data)
    parity_rows += 1

# The level-6 dictionary rows: klauspost's NewWriterDict is the byte target,
# and the stream must decode with the same dictionary.
parity_dict_rows = 0
for ddesc, zdict in dict_shapes.items():
    sources = dict(shapes)
    sources["dictionary tail"] = zdict[-64:]
    for desc, data in sources.items():
        theirs = klauspost_encode(data, 6, zdict)
        ours = our_compress_dict(data, zdict, 6)
        assert ours == theirs, (
            f"level 6 dict != klauspost ({desc}, {ddesc}): ours {len(ours)} "
            f"bytes, theirs {len(theirs)}"
        )
        got = our_decompress_dict(theirs, len(data) + 1, zdict)
        assert got == data, f"klauspost level 6 dict -> our decode ({desc}, {ddesc})"
        parity_dict_rows += 1

print(
    "flate-oracle: "
    f"{pairs} fixture pairs + {fixture_inputs} inputs x {len(raw_shapes)} raw-deflate shapes, "
    f"both directions, + {len(streaming)} streaming rows through the CLI "
    f"+ {dict_rows} dictionary rows x {len(dict_shapes)} dictionaries, both directions "
    f"+ {level1_rows} level-1 byte pins "
    f"+ {parity_rows} level-6 byte-parity rows + {parity_dict_rows} level-6 dictionary "
    "parity rows (ours == klauspost, both directions): OK"
)
