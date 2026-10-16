"""Fail if any git-tracked file is binary.

Test data and reference bytes commit text — base64 for binary payloads,
per `src/gzip/testdata/issue6550.gz.base64` — never binary blobs. This is
the gate for that rule: `just lint` runs it, CI runs `just lint`, and the
only exception is the brand marks: a raster image under `docs/static/` is
allowed only as a render, with its SVG source committed beside it (the
`docs/static/LICENSE` marks are the one thing the repo stores in raster
form).

Everything else: encode the file as base64 (gain the `.base64` suffix) and
add it to the `fixtures` manifest in `build.zig`, which decodes the
committed text into the anonymous `fixtures` module.

A file is binary if its first 8 KiB contains a NUL byte — the same
heuristic git uses to refuse diffs on binary content.
"""

import subprocess
import sys
from pathlib import Path

SNIFF_LEN = 8192


def is_binary(path: Path) -> bool:
    with path.open("rb") as source:
        return b"\x00" in source.read(SNIFF_LEN)


def is_brand_render(path: Path) -> bool:
    parent = path.parent
    return (
        parent == Path("docs/static")
        and path.suffix == ".png"
        and (parent / (path.stem + ".svg")).exists()
    )


def main() -> int:
    tracked = subprocess.run(
        ["git", "ls-files", "-z"], capture_output=True, check=True
    ).stdout.split(b"\x00")
    binary = []
    renders = 0
    for name in tracked:
        if not name:
            continue
        path = Path(name.decode())
        if not is_binary(path):
            continue
        if is_brand_render(path):
            renders += 1
            continue
        binary.append(str(path))
    if binary:
        for name in binary:
            print(f"binary file is tracked: {name}", file=sys.stderr)
        print(
            "commit text instead: base64 with the .base64 suffix, "
            "decoded in build.zig's fixtures manifest",
            file=sys.stderr,
        )
        return 1
    print(
        f"binary check: {len(tracked) - 1} tracked files, all text"
        f" ({renders} brand render{'s' if renders != 1 else ''})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
