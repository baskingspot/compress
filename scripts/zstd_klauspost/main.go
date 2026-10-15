// Command zstd-klauspost is the strict-window decoder behind
// `just zstd-oracle`. It decodes one Zstandard frame with
// klauspost/compress and requires the bytes to equal an expected plaintext.
//
// klauspost bounds its retained history by the frame's declared Window_Size,
// so an offset above Window_Size fails here ("match offset ... bigger than
// current history") — the check RFC 8878 §3.1.1.4 states. The reference C
// decoder and ours accept such offsets when the block's own output makes the
// bytes addressable, which is why this lane exists.
//
// Usage: zstd-klauspost <frame-file> <expected-file> [dict-file]
//
// With a dictionary file the decoders are built with
// `WithDecoderDicts` (klauspost's formatted-dictionary seat): the frame's
// Dictionary_ID must match the dictionary's, and the dictionary's tables and
// content seed the decode — the lane's `-D` rows.
//
// Exit 0 when both of klauspost's decoders (the one-shot DecodeAll and the
// streaming Reader) reproduce the expected bytes, 1 otherwise.
package main

import (
	"bytes"
	"fmt"
	"io"
	"os"

	"github.com/klauspost/compress/zstd"
)

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "zstd-klauspost: "+format+"\n", args...)
	os.Exit(1)
}

func main() {
	if len(os.Args) != 3 && len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: zstd-klauspost <frame-file> <expected-file> [dict-file]")
		os.Exit(2)
	}
	frame, err := os.ReadFile(os.Args[1])
	if err != nil {
		fail("read frame: %v", err)
	}
	want, err := os.ReadFile(os.Args[2])
	if err != nil {
		fail("read expected: %v", err)
	}

	// The decoder options: the RFC's recommended window bound (8 MiB; every
	// frame this lane feeds it declares at most a 512 KiB window, and the
	// bound is what makes the history strict), and the dictionary when the
	// lane supplies one.
	opts := []zstd.DOption{zstd.WithDecoderMaxWindow(1 << 23)}
	if len(os.Args) == 4 {
		dict, err := os.ReadFile(os.Args[3])
		if err != nil {
			fail("read dictionary: %v", err)
		}
		opts = append(opts, zstd.WithDecoderDicts(dict))
	}

	dec, err := zstd.NewReader(nil, opts...)
	if err != nil {
		fail("new reader: %v", err)
	}
	defer dec.Close()
	got, err := dec.DecodeAll(frame, nil)
	if err != nil {
		fail("DecodeAll: %v", err)
	}
	if !bytes.Equal(got, want) {
		fail("DecodeAll: %d bytes, want %d", len(got), len(want))
	}

	// The streaming decoder is klauspost's second code path; it keeps its
	// own history and rejects a bad frame too.
	sdec, err := zstd.NewReader(bytes.NewReader(frame), opts...)
	if err != nil {
		fail("new stream reader: %v", err)
	}
	defer sdec.Close()
	var buf bytes.Buffer
	if _, err := io.Copy(&buf, sdec); err != nil {
		fail("stream decode: %v", err)
	}
	if !bytes.Equal(buf.Bytes(), want) {
		fail("stream decode: %d bytes, want %d", buf.Len(), len(want))
	}
}
