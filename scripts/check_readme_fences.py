"""Type-check the Zig samples in every README.

A sample that no longer compiles is a lie the reader finds out the hard
way. This extracts every Zig fence from the tracked READMEs, writes each
one into a generated module with a fixed import preamble and a probe that
makes the compiler analyze every declaration the fence makes, and builds the
lot through `zig build check-readme-fences`. `just lint` runs this, so a
sample cannot rot unnoticed.

The checker fails closed: a fence it cannot fully analyze is a lint failure
that names the README and line, never a pass. A fence that cannot be a
compilation unit is a listing, and a listing is tagged `text`; there is no
skip list here.

The generated module is written to README_FENCES_DIR, which `build.zig`
compiles.
"""

import re
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

# Where the generated module lives. build.zig's `check-readme-fences` step
# reads it from here, both being ignored by git and by `just clean`.
README_FENCES_DIR = Path("zig-out/readme-fences")

# A markdown fence opener: three or more backticks or tildes, indented or
# not, with an info string. Any fence style counts, because a tester will
# reach for `~~~` and a four-backtick fence next.
OPENER = re.compile(r"^[ \t]*(?P<fence>`{3,}|~{3,})(?P<info>.*)$")

# The names a fence may use without importing them: `compress` is the module
# under test, and the codec aliases match the barrel's namespaces.
PREAMBLE = ("std", "compress", "snappy", "flate", "gzip", "zlib", "zstd", "brotli")

# A top-level declaration: a column-0 line, so a nested one is not counted.
DECL = re.compile(r"^(?:pub )?(const|var|fn) (\w+)")

# A declaration the compiler would take at file scope but this cannot probe:
# one indented off column 0, and a container, whose private members Zig does
# not list for `@typeInfo` (only `pub` ones).
INDENTED_DECL = re.compile(r"^[ \t]+(?:pub )?(?:const|var|fn) \w+")
CONTAINER = re.compile(r"^\s*(?:pub )?const \w+ = (?:struct|union|enum|opaque)\b")

PROBE = """\
const std = @import("std");

/// References a declaration so the compiler resolves its initializer.
pub fn touch(value: anytype) void {
    _ = value;
}

/// Calls `f` with undefined arguments, so the compiler analyzes its body and
/// its callees. The generated tests guard the call: it never runs.
pub fn probe(comptime f: anytype) void {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    if (info.is_generic) {
        @compileError("a README fence declares a generic function, which cannot be" ++
            " type-checked; make the sample concrete");
    }
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


def is_zig(info: str) -> bool:
    """Whether an info string names Zig, in any case."""
    words = info.split()
    return bool(words) and words[0].lower().startswith("zig")


def strip_code(line: str) -> str:
    """`line` with the contents of its strings, chars, and comment blanked.

    The columns survive, so a pattern still matches where it did, and a brace
    inside a string can no longer move the depth. A Zig multiline string line
    (`\\\\`) is all content.
    """
    if line.lstrip().startswith("\\\\"):
        return " " * len(line)
    out = list(line)
    quote = None
    i = 0
    while i < len(line):
        char = line[i]
        if quote:
            out[i] = " "
            if char == "\\" and i + 1 < len(line):
                out[i + 1] = " "
                i += 2
                continue
            if char == quote:
                quote = None
        elif char in "\"'":
            quote = char
            out[i] = " "
        elif line.startswith("//", i):
            out[i:] = " " * (len(line) - i)
            break
        i += 1
    return "".join(out)


def fences(path: Path) -> list[tuple[int, str]]:
    """Every Zig fence in `path`, as (first line number, dedented text).

    A non-Zig fence is consumed too, so its body is never read as markup.
    """
    lines = path.read_text(encoding="utf-8").splitlines()
    found = []
    i = 0
    while i < len(lines):
        opener = OPENER.match(lines[i])
        if opener is None:
            i += 1
            continue
        fence, info = opener["fence"], opener["info"].strip()
        if fence[0] == "`" and "`" in info:
            i += 1  # a code span, not a fence
            continue
        closer = re.compile(rf"^[ \t]*{re.escape(fence[0])}{{{len(fence)},}}[ \t]*$")
        first = i + 1
        i = first
        while i < len(lines) and closer.match(lines[i]) is None:
            i += 1
        if i == len(lines):
            raise SystemExit(f"{path}:{first}: an unclosed {fence} fence")
        if is_zig(info):
            found.append((first + 1, textwrap.dedent("\n".join(lines[first:i])).strip("\n")))
        i += 1
    return found


def declarations(path: Path, line: int, fence: str) -> list[tuple[str, str]]:
    """The fence's top-level (kind, name) declarations, or a lint failure."""
    lines = [strip_code(text) for text in fence.splitlines()]
    unparsed = []
    depth = 0
    for index, text in enumerate(lines):
        if depth == 0 and INDENTED_DECL.match(text):
            unparsed.append(index)
        depth += sum(1 for char in text if char == "{") - sum(1 for char in text if char == "}")
    if depth != 0:
        raise SystemExit(f"{path}:{line}: the fence's braces do not balance")

    for text in lines:
        if CONTAINER.match(text):
            raise SystemExit(
                f"{path}:{line}: the fence declares a container, and Zig lists only its"
                " `pub` declarations to `@typeInfo`, so a private member would go unchecked."
                " Declare the members at the fence's top level, or tag the fence `text`"
            )
    if unparsed:
        found = fence.splitlines()[unparsed[0]]
        raise SystemExit(
            f"{path}:{line}: cannot tell whether this is a top-level declaration: {found!r}."
            " Declarations at file scope start in column 0"
        )

    decls = []
    for text in lines:
        match = DECL.match(text)
        if match:
            decls.append((match[1], match[2]))
    if not decls:
        raise SystemExit(
            f"{path}:{line}: the fence declares nothing this can type-check."
            " A sample declares a function or a constant; a listing is tagged `text`"
        )
    return decls


def preamble_line(name: str) -> str:
    """How the generated module binds one of the PREAMBLE names."""
    if name == "std":
        return 'const std = @import("std");'
    if name == "compress":
        return 'const compress = @import("compress");'
    return f"const {name} = compress.{name};"


def module(path: Path, line: int, fence: str, decls: list[tuple[str, str]]) -> str:
    """The fence as a compilation unit that the compiler analyzes in full."""
    declared = {name for _, name in decls}

    # A name the fence imports itself is left alone: the preamble only fills
    # the gaps, so a fence that declares `std` does not collide with it.
    preamble = [preamble_line(name) for name in PREAMBLE if name not in declared]
    preamble.append('const probe_mod = @import("probe.zig");')

    # A const's reference resolves its initializer; a fn's probe analyzes its
    # body. Every top-level declaration of the fence is covered.
    probes = [
        f"_ = {name};" if kind == "var" else f"probe_mod.touch({name});"
        for kind, name in decls
        if kind in ("const", "var")
    ]
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
        print("readme fences: no Zig fences found", file=sys.stderr)
        return 1

    shutil.rmtree(README_FENCES_DIR, ignore_errors=True)
    README_FENCES_DIR.mkdir(parents=True)
    (README_FENCES_DIR / "probe.zig").write_text(PROBE, encoding="utf-8")

    generated = []
    for index, (path, line, fence) in enumerate(extracted):
        decls = declarations(path, line, fence)
        stem = re.sub(r"[^0-9A-Za-z]+", "_", f"{path}_{line}")
        name = f"fence_{index:02}_{stem}.zig"
        (README_FENCES_DIR / name).write_text(module(path, line, fence, decls), encoding="utf-8")
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
