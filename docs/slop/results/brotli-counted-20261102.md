# brotli one-shot decode: the stream's length, 2026-11-02

baskingspot/image's JPEG XL reader takes the Brotli stream of a `jbrd`
box, which must end at the box's last byte: libjxl rejects bytes after it.
`decode.decompress` ignores trailing bytes and reports only the decoded
length, so image checked the boundary by decoding a second time without the
stream's last byte. `decode.decompressCounted` now returns both lengths,
`target_len` and `source_len`; `decompress` is that call's
`target_len`. The decode loop is unchanged: the count is the bit reader's
position, read once at the end, where the stream is always on a byte
boundary (`§9.2`, `§9.3`).

## Speed

`/tmp/brab` (not committed): `decode.decompress` into a static 8 MiB
target, timed as the best of 5 batches of about 30 ms each, 12 interleaved
runs per build, ReleaseFast for the host CPU, `taskset -c 2`, compared
with benchstat. Inputs from brotli 1.2.0: a 47-byte jbrd-sized payload at
q11, 55 KB of Markdown at q11, 256 KiB of Zig source and of an x86-64
binary at q5, 1 MiB of source at q11, and 1 MiB of the binary at q1. Base:
compress main 6319823. CPU: Intel Xeon Processor @ 2.60GHz (4 vCPUs, a
cloud VM).

```
                          │ /tmp/brab/base.txt │         /tmp/brab/new.txt          │
                          │       sec/op       │   sec/op     vs base               │
Decompress/small-q11.br            7.920µ ± 6%   7.845µ ± 2%       ~ (p=0.298 n=12)
Decompress/text64k-q11.br          270.0µ ± 3%   272.5µ ± 2%       ~ (p=0.242 n=12)
Decompress/src256k-q5.br           894.5µ ± 4%   894.8µ ± 1%       ~ (p=0.671 n=12)
Decompress/bin256k-q5.br           1.151m ± 3%   1.152m ± 3%       ~ (p=0.551 n=12)
Decompress/src1m-q11.br            3.053m ± 3%   3.054m ± 2%       ~ (p=0.590 n=12)
Decompress/bin1m-q1.br             3.798m ± 3%   3.761m ± 2%       ~ (p=0.347 n=12)
geomean                            542.6µ        541.8µ       -0.15%
```

No row changes beyond the runs' spread (every p above 0.24), and the
geometric mean moves 0.15%, within that spread. For image, a `jbrd` payload now decodes
once instead of twice.

## Aside

brotli 1.2.0 at q5 on the 1 MiB inputs writes meta-blocks with more than
64 trees in a category, which this decoder refuses as `TooManyTrees`
(its documented instantiation limit; the format allows 256). Those inputs
are left out above.
