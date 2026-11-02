# flate Writer: block scratch in the caller's buffer, 2026-11-02

baskingspot/image's PNG encoder states its work memory up front and the
caller provides it, but each block that `flate.Writer` emitted also took
about 320 KiB of stack: the token list (`dynamic.TokenList`, 262,788 bytes)
for level 6 and the lazy levels, and the compressed-block scratch
(`maxCompressedLength(65535)` bytes) for every level. The image owner chose
to move both into the writer's memory (image's plan, decision 16).

They are now fields of `Writer.Buffer`, beside the window, and
`compressBlockStream6` and `compressBlockStreamLazy` take the token list as
a pointer. `Buffer` was `[98303]u8`; it is a struct of `window` (that
array), `tokens`, and `scratch`, 426,636 bytes. `Writer` stays 401,696
bytes. Peak memory for a stream is the same, now all in memory the caller
places, and an emission no longer has a 320 KiB stack frame.

## Why the buffer and not the writer

The first version put the two fields in `Writer` itself (730,024 bytes).
Its tests passed on x86_64, aarch64, and x86, but `zig build check
-Dtarget=arm-linux` ran out of memory: the compiler passed 6.2 GB and was
killed, where main peaks at 1.94 GB (419 s). An unused 262,788-byte array
added to `Writer` (with the token list back on the stack) did the same,
and the same array added to `Buffer` instead did not, so it is the size of
`Writer`, which `init` returns by value and tests hold by value, not the
token list's type. With the scratch in `Buffer`, which is only ever used
through a pointer, the arm-linux check peaks at about 2 GB like main, and
`init` copies no more than before.

## Speed

`/tmp/scratch/wab` (not committed): one `zlib.Writer` in static memory,
restarted with `initInPlace` per stream, the whole input written and
finished; best of 5 batches of about 30 ms each, 4 interleaved runs per
build, ReleaseFast for the host CPU, `taskset -c 2`. Inputs: the filtered
IDAT payloads (filter bytes plus filtered rows) of a 16×16 and a 64×64
icon and kodim01 (768×512), from image's PNG encoder. Base: compress main
fef7f95. CPU: Intel Xeon Processor @ 2.60GHz (4 vCPUs, a cloud VM).

```
row                                       base ns     new ns new/base
icon_16-ac L1 944 B                          7848       7951    1.013
icon_16-ac L6 713 B                         32506      32632    1.004
icon_16-ac L7 701 B                         31692      31144    0.983
icon_16-ac L9 702 B                         33587      33128    0.986
icon_64-ac L1 6957 B                        37294      37548    1.007
icon_64-ac L6 5071 B                       144842     148632    1.026
icon_64-ac L7 5026 B                       242986     240601    0.990
icon_64-ac L9 4870 B                      1592408    1574097    0.989
photo_koda L1 1069353 B                  10965097   10856779    0.990
photo_koda L6 771673 B                   26408290   26515795    1.004
photo_koda L7 780936 B                   42856712   43785711    1.022
photo_koda L9 779549 B                   55882044   56354704    1.008
```

The output is the same bytes, and speed is unchanged within the runs'
spread: from 1.7% faster to 2.6% slower by row, with no level
consistently on one side.
