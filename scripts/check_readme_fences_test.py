"""Tests for the README fence checker, which `just lint` runs before it.

The checker fails closed: every case here is a fence it must refuse to pass
silently, plus the fence spellings it must read.
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

    def test_a_declaration_off_column_zero_fails(self) -> None:
        fence = "fn a() void {}\n    const b = 1;"
        with self.assertRaises(SystemExit) as raised:
            declarations(Path("README.md"), 7, fence)
        self.assertIn("cannot tell", str(raised.exception))

    def test_a_container_fails(self) -> None:
        fence = "const S = struct {\n    fn m() void {}\n};"
        with self.assertRaises(SystemExit) as raised:
            declarations(Path("README.md"), 7, fence)
        self.assertIn("container", str(raised.exception))

    def test_a_fence_that_declares_nothing_fails(self) -> None:
        with self.assertRaises(SystemExit) as raised:
            declarations(Path("README.md"), 7, "try writer.writeAll(bytes);")
        self.assertIn("declares nothing", str(raised.exception))

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
        decls = declarations(Path("README.md"), 7, fence)
        self.assertEqual([("fn", "sample")], decls)

    def test_the_module_probes_each_declaration(self) -> None:
        fence = "const answer = 42;\nfn sample() void {}"
        decls = declarations(Path("README.md"), 7, fence)
        text = module(Path("README.md"), 7, fence, decls)
        self.assertIn("probe_mod.touch(answer);", text)
        self.assertIn("probe_mod.probe(sample);", text)
        self.assertIn('test "README.md:7"', text)


if __name__ == "__main__":
    unittest.main()
