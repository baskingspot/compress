# flate.Reader: a 32-bit bit count and a hoisted reach in the fast loop, 2026-11-02

After `flate-packed-entries-20261102.md`, `fastSymbols` kept its bit count
as a `u6`, so every subtraction of a code's length went through an
`@intCast` to 6 bits and every refill's shift and `(63 - count) >> 3`
through a 6-bit value, all on the loop's critical path (bits, then
count, then the next shift). Each match's distance check also computed
`r.total_out + (end - start)`, which reads `r.total_out` through the
`Reader` pointer; the loop's byte stores into `out` may alias it, so the
compiler has to load it again for every match. This change:

- keeps `count` in a `u32`. It still never exceeds 63: a refill sets it
  to `count | 56`, and each symbol takes at most what the refill
  guaranteed, as before. Shifts take `@truncate(count)`.
- computes `reach = r.total_out -% start` once before the loop and checks
  `match_distance > reach +% end`, the same value as before (`end` is at
  least `start`, so the wrapping arithmetic gives the exact sum).

No table, buffer, or state changes size.

Tests: `zig build test` (718 tests, exit 0); `just flate-oracle`,
`just zlib-oracle`, and `just gzip-oracle` pass (exit 0).

## Method

As in `flate-packed-entries-20261102.md`: the `infl.zig` harness from that
file's directory decodes each file's IDAT data through `zlib.Reader` over
`Io.Reader.fixed` and keeps the best of 9 timings of about 30 MB of
output. Built ReleaseFast for this CPU against the packed-entries commit
(`base`) and this change (`new`); `wuffs.c` is the same loop over Wuffs
0.4's zlib decoder. `run.sh` runs base, new, and Wuffs in turn, 10 rounds,
pinned to core 1 with `taskset -c 1`; benchstat compares them.

CPU: Intel Xeon Processor @ 2.60GHz (3.3 GHz under load), 4 vCPUs,
AVX-512, a shared cloud host; Linux 6.1, Zig 0.16.0. Other work (an
oracle run in baskingspot/image) ran on other cores.

## Results

Median of 10 rounds, MB/s of decompressed output:

| file                      | before | after | speedup | Wuffs | vs Wuffs |
| ------------------------- | ------ | ----- | ------- | ----- | -------- |
| icon 16×16                | 167    | 183   | 1.10×   | 156   | 1.17     |
| icon 64×64                | 558    | 640   | 1.15×   | 561   | 1.14     |
| icon 512×512              | 1427   | 1491  | 1.04×   | 1558  | 0.96     |
| kodim01 768×512           | 256    | 278   | 1.08×   | 295   | 0.94     |
| mosaic 8192×6144          | 446    | 489   | 1.10×   | 442   | 1.11     |
| wikipedia-001 1276×850    | 309    | 336   | 1.09×   | 338   | 0.99     |
| air_pump 999×772 (RGBA)   | 1081   | 1151  | 1.07×   | 1134  | 1.02     |
| amazon.com 1313×6097      | 825    | 922   | 1.12×   | 730   | 1.26     |
| dice 800×600 (RGBA)       | 935    | 992   | 1.06×   | 1099  | 0.90     |
| plant_02 1024×1316 (RGBA) | 728    | 810   | 1.11×   | 783   | 1.03     |

benchstat: −8.34% time geomean (+9.10% throughput), every file at
p = 0.000, from −4.3% (icon 512) to −12.8% (icon 64) (`bs.txt`). Against
Wuffs the branch is now 4.7% faster geomean (Wuffs −4.50% throughput,
`bs-wuffs.txt`), from 26% faster (amazon.com) to 10% slower (dice).

## Raw output

`base.txt`, `new.txt`, and `wuffs.txt`: one line per file and round, the
best-of-9 ns per decode and MB/s. `bs.txt`: benchstat base against new.
`bs-wuffs.txt`: new against Wuffs. `run.sh`: the interleaved runner.
