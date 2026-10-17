// Command flate-klauspost is the level-6 parity oracle behind
// `just flate-oracle`: klauspost/compress's own flate, the pinned module
// version, in both directions.
//
// `encode` writes one raw deflate stream at the requested level;
// `decode` inflates one and requires the bytes to equal an expected
// plaintext. The level-6 encode rows compare byte-for-byte with ours, and
// each side's output must decode through the other.
//
// Usage:
//
//	flate-klauspost encode <level> <input-file> <output-file> [dict-file]
//	flate-klauspost decode <input-file> <expected-file>
//
// With a dictionary file the encoder is `flate.NewWriterDict`: the level-6
// dictionary rows compare our `fillWindow` priming with theirs.
//
// Exit 0 on success, 1 on a mismatch or codec error, 2 on a usage error.
package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"strconv"

	"github.com/klauspost/compress/flate"
)

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "flate-klauspost: "+format+"\n", args...)
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: flate-klauspost encode <level> <input-file> <output-file>")
		fmt.Fprintln(os.Stderr, "       flate-klauspost decode <input-file> <expected-file>")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "encode":
		if len(os.Args) != 5 && len(os.Args) != 6 {
			fmt.Fprintln(os.Stderr, "usage: flate-klauspost encode <level> <input-file> <output-file> [dict-file]")
			os.Exit(2)
		}
		level, err := strconv.Atoi(os.Args[2])
		if err != nil {
			fail("level must be a number, got %q", os.Args[2])
		}
		source, err := os.ReadFile(os.Args[3])
		if err != nil {
			fail("read input: %v", err)
		}
		var out bytes.Buffer
		var w *flate.Writer
		if len(os.Args) == 6 {
			dict, err := os.ReadFile(os.Args[5])
			if err != nil {
				fail("read dictionary: %v", err)
			}
			w, err = flate.NewWriterDict(&out, level, dict)
		} else {
			w, err = flate.NewWriter(&out, level)
		}
		if err != nil {
			fail("new writer: %v", err)
		}
		if _, err := w.Write(source); err != nil {
			fail("write: %v", err)
		}
		if err := w.Close(); err != nil {
			fail("close: %v", err)
		}
		if err := os.WriteFile(os.Args[4], out.Bytes(), 0o644); err != nil {
			fail("write output: %v", err)
		}
	case "decode":
		if len(os.Args) != 4 {
			fmt.Fprintln(os.Stderr, "usage: flate-klauspost decode <input-file> <expected-file>")
			os.Exit(2)
		}
		stream, err := os.ReadFile(os.Args[2])
		if err != nil {
			fail("read stream: %v", err)
		}
		want, err := os.ReadFile(os.Args[3])
		if err != nil {
			fail("read expected: %v", err)
		}
		r := flate.NewReader(bytes.NewReader(stream))
		got, err := io.ReadAll(r)
		if err != nil {
			fail("inflate: %v", err)
		}
		if err := r.Close(); err != nil {
			fail("close: %v", err)
		}
		if !bytes.Equal(got, want) {
			fail("decoded %d bytes, want %d", len(got), len(want))
		}
	default:
		fmt.Fprintf(os.Stderr, "flate-klauspost: unknown mode %q\n", os.Args[1])
		os.Exit(2)
	}
}
