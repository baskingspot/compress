"""Check flate against python3's zlib.

Python's zlib is an independent raw-deflate implementation, and it verifies
ours in both directions (our encode -> its decode, its encode -> our decode)
over the Go fixture pairs, generated shapes, and streaming rows through the
example CLI. Run it with `just flate-oracle`; python3 comes from the flake.
The harness is built from src/flate/oracle.zig. The shared plumbing is in
scripts/oracle_common.py.
"""

import zlib

import oracle_common as common

root = common.ROOT
harness = root / "zig-out/bin/flate-oracle"
testdata = root / "src/flate/testdata"


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


def our_decompress_fails(raw: bytes, cap: int) -> bool:
    return common.run_harness(harness, "decode", raw, str(cap)).returncode != 0


def our_compress(data: bytes) -> bytes:
    """Our encoder, through the oracle harness: the raw deflate stream for
    `data`."""
    return common.harness_output(harness, "encode", data)


def python_decompress(raw: bytes) -> bytes:
    do = zlib.decompressobj(-15)
    return do.decompress(raw) + do.flush()


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
for golden in sorted(testdata.glob("*.golden")):
    inp = golden.parent / (golden.name[: -len(".golden")] + ".in")
    data = inp.read_bytes()
    raw = golden.read_bytes()
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
for inp in sorted(testdata.glob("*.in")):
    check(inp.name, inp.read_bytes(), len(inp.read_bytes()) + 1)

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

fixture_inputs = len(list(testdata.glob("*.in"))) + len(shapes)
print(
    "flate-oracle: "
    f"{pairs} fixture pairs + {fixture_inputs} inputs x {len(raw_shapes)} raw-deflate shapes, "
    f"both directions, + {len(streaming)} streaming rows through the CLI: OK"
)
