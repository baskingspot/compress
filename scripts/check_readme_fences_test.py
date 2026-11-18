"""Tests for the README fence checker, which `just lint` runs before it.

The checker fails closed: every case here is a fence it must refuse to pass
silently, a statement spelling it must not skip, or a fence shape it must
read.
"""

import tempfile
import unittest
from pathlib import Path

from check_readme_fences import declarations, fences, module


def parse(readme: str) -> list[tuple[int, str]]:
    """The fences of a README written to a scratch file."""
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "README.md"
        path.write_text(readme, encoding="utf-8")
        return fences(path)


def names(fence: str) -> list[tuple[str, str]]:
    return declarations(Path("README.md"), 1, fence)


class FencesTest(unittest.TestCase):
    def test_every_zig_fence_spelling_counts(self) -> None:
        readme = """\
```zig
const a = 1;
```

```Zig
const b = 2;
```

``` zig
const c = 3;
```

```zig title="x.zig"
const d = 4;
```

~~~zig
const e = 5;
~~~

````zig
const f = 6;
````

```sh
echo skipped
```

```text
const g = 7;
```
"""
        found = parse(readme)
        self.assertEqual(6, len(found))
        self.assertEqual(
            ["const a", "const b", "const c", "const d", "const e", "const f"],
            [text.split(" = ")[0] for _, text in found],
        )

    def test_a_fence_inside_a_blockquote_is_read(self) -> None:
        readme = """\
> A sample:
>
> ```zig
> fn sample() void {}
> ```
"""
        found = parse(readme)
        self.assertEqual(1, len(found))
        line, text = found[0]
        self.assertEqual(4, line)
        self.assertEqual("fn sample() void {}", text)
        self.assertEqual([("fn", "sample")], declarations(Path("README.md"), line, text))

    def test_a_fence_inside_a_list_item_is_dedented(self) -> None:
        readme = """\
- Usage:

    ```zig
    fn sample() void {
        const nested: u8 = 1;
        _ = nested;
    }
    ```
"""
        found = parse(readme)
        self.assertEqual(1, len(found))
        line, text = found[0]
        self.assertEqual(4, line)
        self.assertEqual(
            ["sample"], [name for _, name in declarations(Path("README.md"), line, text)]
        )

    def test_every_declaration_spelling_is_probed(self) -> None:
        fence = """\
inline fn one() void {}
pub inline fn two() void {}
noinline fn three() void {}
threadlocal var four: u8 = 1;
pub const five = 5;
"""
        self.assertEqual(
            [("fn", "one"), ("fn", "two"), ("fn", "three"), ("var", "four"), ("const", "five")],
            names(fence),
        )

    def test_a_multi_line_declaration_is_one_statement(self) -> None:
        fence = """\
fn sample(out: *Writer, in: *Reader,
    buffer: *Buffer) !void {
    _ = out;
    _ = in;
    _ = buffer;
}
"""
        self.assertEqual([("fn", "sample")], names(fence))

    def test_a_statement_it_cannot_name_fails(self) -> None:
        for fence in ("try writer.writeAll(bytes);", "usingnamespace foo;", "x y z;"):
            with self.assertRaises(SystemExit) as raised:
                names(fence)
            self.assertIn("cannot type-check", str(raised.exception))

    def test_test_and_comptime_statements_are_allowed(self) -> None:
        fence = """\
test "a sample" {
    _ = 1;
}
comptime {
    _ = 2;
}
"""
        self.assertEqual([], names(fence))

    def test_a_container_fails(self) -> None:
        for fence in (
            "const S = struct {\n    fn m() void {}\n};",
            "const S = packed struct {\n    fn m() void {}\n};",
            "const S = extern struct {\n    fn m() void {}\n};",
            "const S = blk: {\n    break :blk struct {\n        fn m() void {}\n    };\n};",
            "const S = union {\n    fn m() void {}\n};",
            "const S = enum {\n    a,\n    fn m() void {}\n};",
            "const S = opaque {\n    fn m() void {}\n};",
        ):
            with self.assertRaises(SystemExit) as raised:
                names(fence)
            self.assertIn("container", str(raised.exception))

    def test_a_container_of_fields_is_allowed(self) -> None:
        fence = """\
fn sample() void {
    const S = struct { a: u8, b: *const fn () void };
    _ = S;
}
const Options = struct { level: u8 = 1 };
"""
        self.assertEqual([("fn", "sample"), ("const", "Options")], names(fence))

    def test_a_container_with_a_member_inside_a_function_body_fails(self) -> None:
        fence = """\
fn sample() void {
    const S = struct {
        fn m() void {}
    };
    _ = S;
}
"""
        with self.assertRaises(SystemExit) as raised:
            names(fence)
        self.assertIn("container with a member", str(raised.exception))

    def test_an_extern_prototype_ends_at_its_semicolon(self) -> None:
        fence = """\
pub extern fn proto(x: u32) u32;
fn sample() void {}
"""
        self.assertEqual([("fn_proto", "proto"), ("fn", "sample")], names(fence))

    def test_a_fence_with_no_statements_fails(self) -> None:
        with self.assertRaises(SystemExit) as raised:
            names("")
        self.assertIn("no statements", str(raised.exception))

    def test_an_unclosed_fence_fails(self) -> None:
        with self.assertRaises(SystemExit) as raised:
            parse("```zig\nconst a = 1;\n")
        self.assertIn("unclosed", str(raised.exception))

    def test_a_string_or_comment_brace_does_not_move_the_depth(self) -> None:
        fence = """\
fn sample(out: *std.Io.Writer) void {
    out.writeAll("{ not a block") catch {};
    // a closing brace in a comment: }
    const inner = '}';
    _ = inner;
}"""
        self.assertEqual([("fn", "sample")], names(fence))

    def test_the_module_probes_each_declaration(self) -> None:
        fence = "const answer = 42;\npub extern fn proto(x: u32) u32;\nfn sample() void {}"
        decls = declarations(Path("README.md"), 7, fence)
        text = module(Path("README.md"), 7, fence, decls)
        self.assertIn("probe_mod.touch(answer);", text)
        self.assertIn("probe_mod.touch(proto);", text)
        self.assertIn("probe_mod.probe(sample);", text)
        self.assertIn('test "README.md:7"', text)


if __name__ == "__main__":
    unittest.main()
