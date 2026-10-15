"""Check zlib against python3's zlib.

Python's zlib (the C reference, via `wbits` 15) is an independent zlib
implementation. It verifies ours in both directions (our encode -> its decode,
its encode -> our decode) over generated shapes and the example CLI, plus the
FDICT refusal, the FLEVEL/FCHECK header bytes, and the exact stream boundary.
Run it with `just zlib-oracle`; python3 comes from the flake. The harness is
built from src/zlib/oracle.zig. The reference incantations are in
docs/research/containers-notes.md §5.5, and the shared plumbing is in
scripts/oracle_common.py.
"""

import subprocess
import zlib

import oracle_common as common

root = common.ROOT
harness = root / "zig-out/bin/zlib-oracle"

# Our emitted header: CMF 0x78 (CM=8, CINFO=7); FLG carries only the level's
# FLEVEL band and the minimal FCHECK, FDICT clear. The bands follow the C
# reference (containers-notes.md §5.5: {0,1}->0, {2-5}->1, {6,-1}->2, {7-9}->3).
FLEVEL_BY_LEVEL = {"fast": 2, "0": 0, "1": 0, "2": 1, "5": 1, "6": 2, "9": 3}


def our_compress(data: bytes, level: str = "fast") -> bytes:
    """Our encoder, through the oracle harness: one zlib stream."""
    return common.harness_output(harness, "encode", data, level)


def our_compress_dict(data: bytes, zdict: bytes, level: str = "fast") -> bytes:
    """Our encoder with a preset dictionary (`§2.2` FDICT + DICTID)."""
    return common.harness_output_dict(harness, "encode", data, zdict, level)


def our_decompress(stream: bytes, cap: int) -> bytes:
    """Our one-shot decoder, through the oracle harness."""
    return common.harness_output(harness, "decode", stream, str(cap))


def our_decompress_dict(stream: bytes, cap: int, zdict: bytes) -> bytes:
    """Our one-shot decoder with a preset dictionary."""
    return common.harness_output_dict(harness, "decode", stream, zdict, str(cap))


def our_decompress_error(stream: bytes, cap: int) -> str:
    """Our one-shot decoder's error name, through the oracle harness."""
    result = common.run_harness(harness, "decode", stream, str(cap))
    assert result.returncode != 0, "expected a decoder failure"
    return result.stderr.decode().strip().removeprefix("zlib-oracle: ")


def our_decompress_dict_error(stream: bytes, cap: int, zdict: bytes) -> str:
    """Our one-shot decoder's error name with a dictionary supplied."""
    result = common.run_harness_dict(harness, "decode", stream, zdict, str(cap))
    assert result.returncode != 0, "expected a decoder failure"
    return result.stderr.decode().strip().removeprefix("zlib-oracle: ")


def example(args, data: bytes) -> subprocess.CompletedProcess:
    return common.run_example("zlib", args, data)


def check_header(stream: bytes, level: str) -> None:
    assert stream[0] == 0x78, f"CMF {stream[0]:#x}: CM=8, CINFO=7"
    assert (stream[0] << 8 | stream[1]) % 31 == 0, "FCHECK: CMF*256 + FLG must be 0 mod 31"
    assert stream[1] >> 6 == FLEVEL_BY_LEVEL[level], f"FLEVEL for level {level}"
    assert stream[1] & 0x20 == 0, "FDICT must be clear (ZE2)"


def check_trailer(stream: bytes, data: bytes) -> None:
    assert int.from_bytes(stream[-4:], "big") == zlib.adler32(data), "big-endian ADLER32"


# The generated conformance shapes (oracle_common.SHAPES): the same bytes in
# every script.
shapes = common.SHAPES
text = shapes["text"]
long_text = shapes["long text (multi-block)"]

# 1. Our encode -> the C reference's decode, every level, over the shapes.
levels = ("fast", "0", "1", "6", "9")
rows = 0
for desc, data in shapes.items():
    for level in levels:
        stream = our_compress(data, level)
        check_header(stream, level)
        check_trailer(stream, data)
        assert zlib.decompress(stream) == data, f"our encode -> zlib decode ({desc}, {level})"
        rows += 1

# 2. The C reference's encode -> our decode: `zlib.compress` and the
#    `compressobj` form, levels {-1, 0, 1, 6, 9} (-1 is the reference's
#    default-compression level, FLEVEL 2).
for desc, data in shapes.items():
    for level in (-1, 0, 1, 6, 9):
        stream = zlib.compress(data, level)
        got = our_decompress(stream, len(data) + 1)
        assert got == data, f"zlib.compress -> our decode ({desc}, {level}): {len(got)} bytes"
        co = zlib.compressobj(level, zlib.DEFLATED, 15)
        stream = co.compress(data) + co.flush()
        got = our_decompress(stream, len(data) + 1)
        assert got == data, f"compressobj -> our decode ({desc}, {level}): {len(got)} bytes"
        rows += 2

# 3. The stream boundary: the second stream lands in the reference's
#    `unused_data`, and our one-shot ignores everything after ADLER32
#    (RFC 1950 §2.2: bytes after the trailer are not part of the stream).
#    The CLI rows below exercise the streaming reader's boundary.
two = zlib.compress(text, 6) * 2
do = zlib.decompressobj(15)
assert do.decompress(two) + do.flush() == text
assert do.unused_data == zlib.compress(text, 6), "the reference leaves the second stream"
assert our_decompress(two, len(text) + 1) == text, "our one-shot decodes the first stream"
rows += 1

# 4. FDICT: the C reference emits a dictionary stream with header 78 bb plus
#    the dictionary's big-endian Adler-32, and our decode refuses it before
#    any body byte when no dictionary is supplied. The dictionary +
#    FLEVEL-0 case emits 78 3f (FCHECK = 31), a conformant header that must
#    not be rejected as bad.
dictionary = b"she sells seashells by the seashore\n"
dict_stream = None
for level, expected_flg in ((6, 0xBB), (0, 0x3F)):
    co = zlib.compressobj(level, zlib.DEFLATED, 15, 9, zlib.Z_DEFAULT_STRATEGY, dictionary)
    stream = co.compress(text) + co.flush()
    assert stream[0] == 0x78 and stream[1] == expected_flg, f"dict header {stream[:2].hex()}"
    assert int.from_bytes(stream[2:6], "big") == zlib.adler32(dictionary), "DICTID"
    assert (stream[0] << 8 | stream[1]) % 31 == 0, "FCHECK=31 is 0 mod 31"
    assert zlib.decompressobj(15, dictionary).decompress(stream) == text, "the reference decodes"
    assert our_decompress_error(stream, len(text) + 1) == "DictionaryRequired", (
        f"our FDICT refusal (level {level}, FCHECK corner)"
    )
    if level == 6:
        dict_stream = stream
    rows += 1
assert dict_stream is not None
rows += 1  # the dict_stream reuse below

# 4b. The dictionary supplied, both directions (`§2.2`): our encode against a
#     dictionary is FDICT + the whole dictionary's Adler-32 as DICTID, and the
#     reference decodes it with the same zdict (and needs it: without one its
#     inflate reports "need dictionary"). The reference's zdict streams decode
#     here, and the four mismatch cases are the error-name pins.
#
#     The large dictionary pins the tail rule: only its last 32 KiB is the
#     window while DICTID names the whole, so the tail alone is a mismatch.
dict_rows = 0
large_dictionary = bytes(range(256)) * 160  # 40 KiB
dict_sources = {
    "dictionary text": b"she sells seashells she sells seashells by the seashore\n",
    "large-dictionary tail": large_dictionary[-64:],
}
for ddesc, zdict in (("text dictionary", dictionary), ("large dictionary", large_dictionary)):
    for desc, data in dict_sources.items():
        ours = our_compress_dict(data, zdict)
        # FDICT is set, DICTID is the whole dictionary's Adler-32, and the
        # trailer still covers the payload only.
        assert ours[0] == 0x78 and ours[1] & 0x20, f"FDICT ({desc}, {ddesc})"
        assert (ours[0] << 8 | ours[1]) % 31 == 0, "FCHECK holds with FDICT"
        assert int.from_bytes(ours[2:6], "big") == zlib.adler32(zdict), f"DICTID ({desc}, {ddesc})"
        check_trailer(ours, data)
        assert zlib.decompressobj(15, zdict).decompress(ours) == data, (
            f"our zdict encode -> zlib decode ({desc}, {ddesc})"
        )
        assert our_decompress_dict(ours, len(data) + 1, zdict) == data, (
            f"our zdict round trip ({desc}, {ddesc})"
        )
        # The reference needs the dictionary: its inflate says "need
        # dictionary" (error 2) without one.
        try:
            zlib.decompress(ours)
            raise AssertionError(f"the reference decoded without a zdict ({desc}, {ddesc})")
        except zlib.error as err:
            # The reference's message is "Error 2 while decompressing data"
            # (Z_NEED_DICT); the code is the contract, not the text.
            assert "Error 2" in str(err), str(err)

        # The reference's zdict encode -> our decode, and the mismatch matrix.
        co = zlib.compressobj(6, zlib.DEFLATED, 15, 9, zlib.Z_DEFAULT_STRATEGY, zdict)
        ref = co.compress(data) + co.flush()
        assert our_decompress_dict(ref, len(data) + 1, zdict) == data, (
            f"zlib zdict encode -> our decode ({desc}, {ddesc})"
        )
        assert our_decompress_error(ref, len(data) + 1) == "DictionaryRequired", (
            f"FDICT without a dictionary ({desc}, {ddesc})"
        )
        assert our_decompress_dict_error(ref, len(data) + 1, b"wrong dictionary") == (
            "DictionaryMismatch"
        ), f"FDICT with a wrong dictionary ({desc}, {ddesc})"
        if ddesc == "large dictionary":
            # The DICTID names the whole 40 KiB: only the tail is matchable,
            # but the identifier check still needs every byte.
            assert our_decompress_dict_error(ref, len(data) + 1, zdict[-32768:]) == (
                "DictionaryMismatch"
            ), "the tail alone must fail the DICTID compare"
        dict_rows += 1

# 4c. FDICT clear with a dictionary supplied: the stream names none, so the
#     parameter is unused and the stream decodes (one reader can walk mixed
#     streams).
plain_stream = our_compress(text)
assert our_decompress_dict(plain_stream, len(text) + 1, dictionary) == text
rows += 1

# The FDICT refusal through the streaming CLI: the input is a real dictionary
# stream, and the decode fails instead of misreading the DICTID as deflate
# data, which is what std's zlib reader does.
p = example(["decode", "-"], dict_stream)
assert p.returncode != 0, "the CLI fails closed on an FDICT stream"

# 5. The C reference's FLEVEL/FCHECK header bytes: 78 9c at level 6, 78 01 at
#    levels 0/1, 78 da at level 9.
assert zlib.compress(text, 6)[:2] == b"\x78\x9c", "78 9c at level 6"
assert zlib.compress(text, 0)[:2] == b"\x78\x01", "78 01 at level 0"
assert zlib.compress(text, 1)[:2] == b"\x78\x01", "78 01 at level 1"
assert zlib.compress(text, 9)[:2] == b"\x78\xda", "78 da at level 9"
rows += 1

# 6. Trailing bytes, the spec's own boundary (§2.2: "Any data which may
#    appear after ADLER32 are not part of the zlib stream"): the one-shot and
#    the thin CLI pump both decode the stream and stop; nothing is
#    interpreted past ADLER32.
stream = our_compress(text)
assert our_decompress(stream + b"garbage!!!", len(text) + 1) == text
p = example(["decode", "-"], stream + b"garbage!!!")
assert p.returncode == 0, f"the CLI stops at the stream end: {p.stderr.decode().strip()}"
assert p.stdout == text
rows += 1

# 7. The streaming rows through the example CLI (zlib.Writer/zlib.Reader
#    underneath): its own round trip, the C reference's decode of its stream,
#    and the reference's stream through the CLI.
for desc, data in (("streaming text", text), ("streaming multi-block", long_text)):
    p = example(["encode", "-"], data)
    assert p.returncode == 0, f"example encode ({desc}): {p.stderr.decode().strip()}"
    stream = p.stdout
    check_header(stream, "fast")
    check_trailer(stream, data)
    assert zlib.decompress(stream) == data, f"example encode -> zlib decode ({desc})"
    p = example(["decode", "-"], stream)
    assert p.returncode == 0, f"example decode ({desc}): {p.stderr.decode().strip()}"
    assert p.stdout == data, f"example round trip ({desc})"
    reference = zlib.compress(data, 6)
    p = example(["decode", "-"], reference)
    assert p.returncode == 0, f"zlib stream -> example decode ({desc})"
    assert p.stdout == data, f"zlib encode -> example decode ({desc})"
    rows += 3

print(
    "zlib-oracle: "
    f"{rows} container rows (our encode -> zlib decode, zlib/compressobj -> our decode), "
    "both directions, + the FDICT refusal + the FCHECK=31 corner + the FLEVEL/FCHECK emissions + the boundary "
    f"pins + {dict_rows} dictionary rows x 2 dictionaries (our zdict encode -> zlib zdict decode, zlib zdict "
    "encode -> our zdict decode, the four mismatch cases) + 6 streaming rows through the CLI: OK"
)
