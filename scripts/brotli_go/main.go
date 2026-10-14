// Command brotli-go is the Go reference codec behind `just brotli-oracle`:
// it decodes one brotli stream with andybalholm/brotli and requires the bytes
// to equal an expected plaintext, and it encodes an input at a quality so our
// decoder meets a second encoder's streams.
//
// andybalholm/brotli is a direct port of the C reference (the same error
// names, the byte-identical dictionary), and its reader is single-stream: it
// fails "excessive input" where bytes follow the stream (T4 of
// src/brotli/AGENTS.md).
//
// Usage:
//
//	brotli-go decode <stream-file>          # the decoded bytes on stdout
//	brotli-go encode <input-file> <quality> # the stream on stdout
//
// Exit 0 on success, 1 on a codec error, 2 on a usage error.
package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"strconv"

	"github.com/andybalholm/brotli"
)

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "brotli-go: "+format+"\n", args...)
	os.Exit(1)
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: brotli-go decode <stream-file>")
	fmt.Fprintln(os.Stderr, "       brotli-go encode <input-file> <quality>")
	os.Exit(2)
}

func main() {
	if len(os.Args) < 3 {
		usage()
	}
	switch os.Args[1] {
	case "decode":
		if len(os.Args) != 3 {
			usage()
		}
		decode(os.Args[2])
	case "encode":
		if len(os.Args) != 4 {
			usage()
		}
		encode(os.Args[2], os.Args[3])
	default:
		usage()
	}
}

// decode writes the reader's bytes for one stream to stdout; a refusal (a
// corrupt stream, or bytes after the stream's last byte) exits 1 with the
// reader's own error.
func decode(streamPath string) {
	stream, err := os.ReadFile(streamPath)
	if err != nil {
		fail("read stream: %v", err)
	}
	got, err := io.ReadAll(brotli.NewReader(bytes.NewReader(stream)))
	if err != nil {
		fail("decode: %v", err)
	}
	if _, err := os.Stdout.Write(got); err != nil {
		fail("write stdout: %v", err)
	}
}

// encode writes the Go encoder's stream for one input at a quality (0..11,
// the CLI's range) to stdout.
func encode(inputPath, qualityArg string) {
	data, err := os.ReadFile(inputPath)
	if err != nil {
		fail("read input: %v", err)
	}
	quality, err := strconv.Atoi(qualityArg)
	if err != nil {
		fail("quality %q: %v", qualityArg, err)
	}
	var out bytes.Buffer
	w := brotli.NewWriterLevel(&out, quality)
	if _, err := w.Write(data); err != nil {
		fail("encode: %v", err)
	}
	if err := w.Close(); err != nil {
		fail("encode close: %v", err)
	}
	if _, err := os.Stdout.Write(out.Bytes()); err != nil {
		fail("write stdout: %v", err)
	}
}
