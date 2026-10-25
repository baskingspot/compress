// Command snappy-klauspost is the framed-stream interop oracle behind
// `just snappy-oracle`: klauspost/compress's s2 in snappy-compatible mode,
// both directions.
//
// Usage:
//
//	snappy-klauspost encode <input-file> <output-file>
//	snappy-klauspost decode <stream-file> <expected-file>
//
// `encode` writes a snappy-framed stream (s2.WriterSnappyCompat); `decode`
// reads one and requires the bytes to equal the expected plaintext. Exit 0 on
// success, 1 on a mismatch or codec error, 2 on a usage error.
package main

import (
	"bytes"
	"fmt"
	"io"
	"os"

	"github.com/klauspost/compress/s2"
)

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "snappy-klauspost: "+format+"\n", args...)
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: snappy-klauspost encode <input-file> <output-file>")
		fmt.Fprintln(os.Stderr, "       snappy-klauspost decode <stream-file> <expected-file>")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "encode":
		if len(os.Args) != 4 {
			fmt.Fprintln(os.Stderr, "usage: snappy-klauspost encode <input-file> <output-file>")
			os.Exit(2)
		}
		source, err := os.ReadFile(os.Args[2])
		if err != nil {
			fail("read input: %v", err)
		}
		var out bytes.Buffer
		w := s2.NewWriter(&out, s2.WriterSnappyCompat())
		if _, err := w.Write(source); err != nil {
			fail("write: %v", err)
		}
		if err := w.Close(); err != nil {
			fail("close: %v", err)
		}
		if err := os.WriteFile(os.Args[3], out.Bytes(), 0o644); err != nil {
			fail("write output: %v", err)
		}
	case "decode":
		if len(os.Args) != 4 {
			fmt.Fprintln(os.Stderr, "usage: snappy-klauspost decode <stream-file> <expected-file>")
			os.Exit(2)
		}
		stream, err := os.ReadFile(os.Args[2])
		if err != nil {
			fail("read stream: %v", err)
		}
		expected, err := os.ReadFile(os.Args[3])
		if err != nil {
			fail("read expected: %v", err)
		}
		got, err := io.ReadAll(s2.NewReader(bytes.NewReader(stream)))
		if err != nil {
			fail("decode: %v", err)
		}
		if !bytes.Equal(got, expected) {
			fail("decoded bytes differ (%d vs %d)", len(got), len(expected))
		}
	default:
		fmt.Fprintf(os.Stderr, "snappy-klauspost: unknown command %q\n", os.Args[1])
		os.Exit(2)
	}
}
