// Command lz4-go is the raw-block interop oracle behind `just lz4-oracle`.
// It uses github.com/pierrec/lz4/v4 CompressBlock and UncompressBlock.
//
// Usage:
//
//	lz4-go encode <input-file> <output-file>
//	lz4-go decode <block-file> <expected-file>
//
// Exit 0 on success, 1 on a mismatch or codec error, 2 on a usage error.
package main

import (
	"bytes"
	"fmt"
	"os"

	"github.com/pierrec/lz4/v4"
)

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "lz4-go: "+format+"\n", args...)
	os.Exit(1)
}

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: lz4-go encode <input-file> <output-file>")
		fmt.Fprintln(os.Stderr, "       lz4-go decode <block-file> <expected-file>")
		os.Exit(2)
	}
	source, err := os.ReadFile(os.Args[2])
	if err != nil {
		fail("read input: %v", err)
	}

	switch os.Args[1] {
	case "encode":
		target := make([]byte, lz4.CompressBlockBound(len(source)))
		n, err := lz4.CompressBlock(source, target, nil)
		if err != nil {
			fail("encode: %v", err)
		}
		if n == 0 && len(source) != 0 {
			fail("encode: no block with a CompressBlockBound destination")
		}
		if err := os.WriteFile(os.Args[3], target[:n], 0o644); err != nil {
			fail("write output: %v", err)
		}
	case "decode":
		expected, err := os.ReadFile(os.Args[3])
		if err != nil {
			fail("read expected: %v", err)
		}
		target := make([]byte, len(expected))
		n, err := lz4.UncompressBlock(source, target)
		if err != nil {
			fail("decode: %v", err)
		}
		if n != len(expected) || !bytes.Equal(target[:n], expected) {
			fail("decoded bytes differ (%d vs %d)", n, len(expected))
		}
	default:
		fmt.Fprintf(os.Stderr, "lz4-go: unknown command %q\n", os.Args[1])
		os.Exit(2)
	}
}
