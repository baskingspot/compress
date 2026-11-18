"""Type-check the Zig samples in every README.

A sample that no longer compiles is a lie the reader finds out the hard
way. This extracts every ```zig fence from the tracked READMEs, writes each
one into a generated module with a fixed import preamble and a probe that
makes the compiler analyze every declaration the fence makes, and builds the
lot through `zig build check-readme-fences`. `just lint` runs this, so a
sample cannot rot unnoticed.

A fence that cannot compile as a compilation unit is a listing, not a
sample: mark it ```text and it stops being extracted. There is no skip list
here; a fence that fails is either fixed or demoted by hand.

The generated module is written to README_FENCES_DIR, which `build.zig`
compiles. A failing fence is reported by its README path and line.
"""

import re
import shutil
import subprocess
import sys
from pathlib import Path

# Where the generated module lives. build.zig's `check-readme-fences` step
# reads it from here, both being ignored by git and by `just clean`.
README_FENCES_DIR = Path("zig-out/readme-fences")

FENCE = "```zig"
CLOSE = "```"

# The names a fence may use without importing them: `compress` is the module
# under test, and the codec aliases match the barrel's namespaces.
PREAMBLE = ("std", "compress", "snappy", "flate", "gzip", "zlib", "zstd", "brotli")

# A top-level declaration: column 0, so a nested one is not counted.
DECL = re.compile(r"^(?:pub )?(const|var|fn) (\w+)", re.MULTILINE)

PROBE = """\
const std = @import("std");

/// Calls `f` with undefined arguments, which makes the compiler analyze its
/// body and its callees. The generated tests guard the call: it never runs.
pub fn probe(comptime f: anytype) void {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    // A generic fn needs comptime arguments this cannot supply.
    if (info.is_generic) return;
    const args: std.meta.ArgsTuple(@TypeOf(f)) = undefined;
    switch (@typeInfo(info.return_type.?)) {
        .error_union => if (@call(.auto, f, args)) |_| {} else |_| {},
        .void => @call(.auto, f, args),
        else => _ = @call(.auto, f, args),
    }
}
"""


def readmes() -> list[Path]:
    """Every README git tracks; the fetched packages are not ours to check."""
    tracked = subprocess.run(
        ["git", "ls-files", "-z"], capture_output=True, check=True, text=True
    ).stdout.split("\0")
    return [Path(name) for name in tracked if name and name.endswith("README.md")]


def fences(path: Path) -> list[tuple[int, str]]:
    """Every ```zig fence in `path`, as (first line number, text)."""
    lines = path.read_text(encoding="utf-8").splitlines()
    found = []
    i = 0
    while i < len(lines):
        if lines[i].strip() != FENCE:
            i += 1
            continue
        first = i + 1
        i = first
        while i < len(lines) and lines[i].strip() != CLOSE:
            i += 1
        if i == len(lines):
            raise SystemExit(f"{path}:{first}: a ```zig fence never closes")
        found.append((first + 1, "\n".join(lines[first:i])))
        i += 1
    return found


def preamble_line(name: str) -> str:
    """How the generated module binds one of the PREAMBLE names."""
    if name == "std":
        return 'const std = @import("std");'
    if name == "compress":
        return 'const compress = @import("compress");'
    return f"const {name} = compress.{name};"


def module(path: Path, line: int, fence: str) -> str:
    """The fence as a compilation unit that the compiler analyzes in full."""
    decls = DECL.findall(fence)
    declared = {name for _, name in decls}

    # A name the fence imports itself is left alone: the preamble only fills
    # the gaps, so a fence that declares `std` does not collide with it.
    preamble = [preamble_line(name) for name in PREAMBLE if name not in declared]
    preamble.append('const probe_mod = @import("probe.zig");')

    # A const's reference resolves its initializer; a fn's probe analyzes its
    # body. Every top-level declaration of the fence is covered.
    probes = [f"_ = {name};" for kind, name in decls if kind in ("const", "var")]
    probes += [f"probe_mod.probe({name});" for kind, name in decls if kind == "fn"]
    body = "\n".join(f"        {probe}" for probe in probes)

    return (
        f"//! Generated from {path}:{line} by scripts/check_readme_fences.py.\n\n"
        + "\n".join(preamble)
        + "\n\n"
        + fence
        + f"""

// The probes type-check the fence above; they never run.
var probe_skip = false;

test "{path}:{line}" {{
    if (probe_skip) {{
{body}
    }}
}}
"""
    )


def main() -> int:
    extracted = [(path, line, text) for path in readmes() for line, text in fences(path)]
    if not extracted:
        print("readme fences: no ```zig fences found", file=sys.stderr)
        return 1

    shutil.rmtree(README_FENCES_DIR, ignore_errors=True)
    README_FENCES_DIR.mkdir(parents=True)
    (README_FENCES_DIR / "probe.zig").write_text(PROBE, encoding="utf-8")

    generated = []
    for index, (path, line, fence) in enumerate(extracted):
        stem = re.sub(r"[^0-9A-Za-z]+", "_", f"{path}_{line}")
        name = f"fence_{index:02}_{stem}.zig"
        (README_FENCES_DIR / name).write_text(module(path, line, fence), encoding="utf-8")
        generated.append((name, path, line))

    root = [
        "//! Generated by scripts/check_readme_fences.py: one import per README fence.",
        "test {",
    ]
    root += [f'    _ = @import("{name}");' for name, _, _ in generated]
    root += ["}", ""]
    (README_FENCES_DIR / "root.zig").write_text("\n".join(root), encoding="utf-8")

    build = subprocess.run(
        ["zig", "build", "check-readme-fences"], capture_output=True, check=False, text=True
    )
    if build.returncode != 0:
        output = build.stderr + build.stdout
        sys.stderr.write(output)
        for name, path, line in generated:
            if name in output:
                print(f"readme fence does not compile: {path}:{line}", file=sys.stderr)
        return 1

    readme_count = len({path for path, _, _ in extracted})
    print(f"readme fences: {len(extracted)} fences from {readme_count} READMEs, all compile")
    return 0


if __name__ == "__main__":
    sys.exit(main())
