# The entropy wave: the Intel checksum chain and the brotli literal outline

Working-tree wave, not a fleet run: every number below is a same-box A/B
(interleaved medians, the pinned corpus, one isolated core) between the
harness-built HEAD binaries and working-tree builds, plus two micro grids.
The verification fleet run supersedes this file's rows when it lands. The
A/B harness is the untracked `bench/ab*.py` (ec2bench Box API, no quoting
hazards); the micros are /tmp scratch, their shapes and numbers reproduced
below.

Two changes kept, both in the tree:

1. `src/zstd/xxh64.zig` — the checksum's accumulator shape is per-model on
   x86_64: scalar with per-lane SLP barriers everywhere except znver4, which
   keeps the `vpmullq` vector form.
2. `src/brotli/command.zig` — the single-tree literal run's per-segment loop
   is outlined (reader carried by value) on x86_64 only.

## Finding 0 (methodology, needs the parent): the m7-fair checksum flag is a no-op on the zstd-c arm

The m7-fair grid's premise — "the zc frame form is now paid by every zstd
arm" — does not hold on the encode rows. `bench/drivers/c/bench_zstd.c` sets
`ZSTD_c_checksumFlag` on the CCtx, but the drive goes through
`ZSTD_compressCCtx`, and the vendored zstd.h (bench/zig-out/bench-src/zstd,
§"API design", line 326) says the sticky parameters "__do not apply to
one-shot variants such as ZSTD_compressCCtx()__". Evidence on c8i,
text/32768 compress: zc out_len 68, zstd-c out_len 64 — the C frame is
missing exactly the 4-byte trailer. A 4 s perf record of the C arm on
text/65536 (~1.18M iterations, 14.37G cycles) shows ~0% in XXH64; a 64 KiB
hash per iteration cannot fit that budget at any measured XXH64 speed. The
driver fix is `ZSTD_compress2` (the sticky-parameter one-shot). Sizing: the
C's own memory-churned scalar XXH64 measures 5.4 GB/s on graniterapids (the
micro's variant C), which would add ~12 µs to its 3.4 µs text-64K row — the
literal-heavy "gap" inverts when the grid is actually fair. Whether to pay
that price is the methodologist's call, not this lane's.

## zstd encode/decode: the XXH64 accumulator shape (KEPT)

**Hypothesis.** The literal-heavy Intel gap (3.3-3.9x) is dominated by the
frame checksum: on graniterapids, perf puts ~76% of the text-64K encode row
in the XXH64 stripe loop, and the loop's serial chain is one `vpmullq`
(~15-cycle latency on Intel P-cores) per 32-byte stripe. Four independent
scalar `imul` chains (3-cycle latency, port-1 bound at 8 multiplies per
stripe) should measure ~2x.

**Why the scalar form wasn't already in effect.** `use_vector_lanes` was
chosen from a sapphirerapids *disassembly* (4 vector instructions vs 8
scalar multiplies) — instruction count, not latency. And two attempts to
keep LLVM's SLP from packing the scalar form failed before the working one:
a barrier on the pre-multiply value still packed (SLP pays the extract
cost), and the batched-load barrier plus per-lane barriers packed *and* ran
6.2 GB/s. The kept shape interleaves load and round per lane with a barrier
on each *finished* lane, one stripe per iteration on x86_64 (unrolled, the
16 isomorphic chains give SLP enough to pay the extracts).

**Micro grid** (XXH64 over a 64 KiB buffer, GB/s, noinline variants):

| variant | c7i | c8i | c7a | c8a | c7g | c8g | c9g |
|---|---|---|---|---|---|---|---|
| vector `vpmullq` (HEAD x86) | 7.09 | 7.27 | 18.57 | 20.09 | 6.92 | 7.39 | 9.40 |
| scalar, plain (SLP packs on x86) | 7.09 | 7.26 | 18.58 | 19.96 | 16.52 | 17.35 | 13.91 |
| scalar, per-lane barrier | **15.07** | **15.47** | 14.58 | **24.66** | 16.54 | 16.46 | 16.87 |
| scalar, memory-resident (the C's shape) | 5.23 | 5.42 | 6.53 | 8.35 | 3.77 | 4.12 | 4.92 |
| vector, `vpmuludq`-emulated multiply | 5.59 | 5.73 | 10.21 | 8.28 | 2.85 | 3.26 | 4.12 |
| hybrid: vector lane×P2 + scalar acc chain | 6.31 (c8i) — reverted | | | | | | |

znver4 keeps the vector form (its `vpmullq` is 3-cycle: 18.6-19.1 vs 14.6
scalar); znver5 flips to scalar (two `imul` ports: 24.7 vs 20.1); aarch64 is
untouched (its load-batch barrier form already holds SLP off and measured
best or tied there).

**Disassembly evidence.** Before (graniterapids): the stripe loop is
`vpmullq (load); vpaddq; vprolq 31; vpmullq` chained on one ymm accumulator,
4 stripes unrolled but serial through the accumulator — 15.8 cycles/stripe
measured. After: four independent `mov (load); imul; add; rorx; imul` chains
per stripe, the barriers compile to nothing, 7.4 cycles/stripe measured
(port-1's 8-`imul` bound, minus the extract-free barrier shape). znver4's
build still emits the vector round (24 `vpmullq` in the encode path);
sapphirerapids/graniterapids/znver5 build to the scalar loop.

**Row A/Bs (base = HEAD harness build; ratios are base÷wave, >1 = wave
faster; 5-10 rounds, medians).**

c8i (graniterapids), zstd compress: text-32K 6522→4177 ns (1.56), text-64K
11775→7009 (1.68), html 1.56/1.68, rle 1.57/1.68, mixed 1.14/1.38, random
1.15/1.37, skewlit 1.07/1.07, words-64K 1.00. c8i zstd decompress: text
1.94-2.00, mixed 1.93-1.95, random 1.88-1.90, skewlit 1.06-1.07, words
~1.00. c7i (sapphirerapids): text/rle compress 1.50-1.59, html 1.56/1.72,
mixed 1.16/1.41, random 1.16/1.38, skewlit 1.08/1.06, words 1.02;
decompress: text 1.95-2.01, mixed 1.99/2.05, random 1.94-1.96. c8a (znver5):
text compress 1.12-1.15. c7a (znver4, vector kept): 1.000 (a 0.962 reading
on mixed-32K decode re-measured 1.000 at 10 rounds — noise). c7g/c8g/c9g:
1.000 on text compress and mixed decompress (the aarch64 code path is
comptime-unchanged).

Net on the m7-fair rows this wave targeted: text/html/rle encode on Intel
moves from 3.3-3.9x-behind to ~2.0-2.3x-behind *against a C arm that is not
paying its checksum* (Finding 0); the Intel decode deficit on mixed/random
(1.82-2.07) should close to ~parity (1.88-1.95x faster on our side).

## brotli decode: the single-tree literal outline (KEPT)

**Hypothesis.** The entropy rows' Intel-worst signature is register
starvation: the literal run is inlined into the ~21 KB `decodeMetaBlock`,
and x86_64's 16 GPRs cannot hold the reader's seven words plus the loop
state, so every symbol pays a store-load round trip through the caller's
frame. aarch64's 31 GPRs hold it. Evidence, skewlit-64K on c8i: the hottest
block is `mov -0x110(%rbp),%rcx` (table pointer reload), `mov
(%rcx,%rax,4),%r15d` (root entry), `mov %rsi,-0x90(%rbp)` / `mov
%r10,-0x88(%rbp)` (accumulator and count stored per symbol) — 10.5/9.5/9.6/9.1%
of samples on spill instructions.

**Change.** On x86_64 with the slice reader, each block-type segment of the
single-tree literal run calls an outlined `literalSegmentSingle` that takes
the reader *by value*; the subtable fallback decodes through a second local
so the hot local's address never escapes into a call. After (graniterapids
disassembly): the whole per-symbol loop is register-resident (`rdx`=bits,
`rdi`=count, `rcx`=bit_pos, `r8`=next_byte), zero rbp-traffic; the spill
block exists only on the cold subtable path.

**Row A/Bs.** c8i: skewlit-32K/64K 1.124/1.129 (207.2→183.6 µs); words and
prose neutral (1.003-1.020). c7i: skewlit 1.108/1.126, prose-32K 1.063.
c8g (aarch64, gate is comptime-false): 0.994-1.003 — neutral.

**Reverted beside it.** Outlining the *context-modeled* segment loop the
same way measured 0.91-0.95 on words/prose (the segment-boundary carry copy
costs more than the spills it removes; that path's per-literal work is the
context lookups, not reader pressure) — kept inline, comment in the diff.
Deriving `bit_pos` instead of storing it (one add fewer per consume)
measured a reproducible −2.2% on words/prose-32K (two builds of identical
source bracket it as layout-sensitive, but the direction repeated at 10
rounds) — reverted; `bits.zig` is back at HEAD.

**Calibration note.** Two builds of *identical* source differ 2-6% on the
32 KiB brotli/words rows on c8i (layout noise); every kept delta above is
1.5-100x outside that band, and the 32K sub-1.0 readings were re-run at 10
rounds.

## Next bottlenecks (ranked, with evidence)

1. **zstd skewlit/words encode, Intel (~1.07-1.28 residual).** writeStream
   is 48.6% of the skewlit-64K row and runs ~1.4 cycles/symbol — the
   add/shift/or serial chain is the algorithm's floor and the x86_64 and
   aarch64 listings are near-isomorphic (8-9 instructions/symbol both). The
   residual gap is more likely literal *count* (the finder's match choices
   vs the C's) than per-symbol cost. Evidence: the c8i perf record of the
   skewlit row (writeStream 48.6%, writeCompressible-inline 36.2%, xxh64 now
   6.5%).
2. **brotli words/prose, Intel (1.34-1.66).** Not spills anymore: post-
   outline profiles are flat, and per 64 KiB decode zc executes 1.66M
   instructions at IPC 2.02 vs the C's 1.21M at IPC 2.30, with 1.84x the
   branch misses. L1d misses are *lower* than the C's (1882 vs 2852 per
   iteration) — the 64 KiB literal-root-region hypothesis was tested and
   killed. The levers are the bit-reader's consume model (our shift-down +
   count + bit_pos per symbol vs the C's position-advance) and per-command
   overhead — a reader rewrite, not a patch.
3. **countTwo unroll (zstd encode, Intel).** Micro on a 64 KiB long match:
   the 32B×2 unroll is +3% (c8i) / +19% (c7i) over the single-stripe vector
   loop; 64B stripes are −35% on Intel but +34% on znver5. Untried on the
   rows because the mid-length-match shapes (the won words/skewlit encode
   rows) risk the wider entry gate; needs a careful row A/B.
4. **zstd one-shot table zeroing.** ~3% of the text rows is the per-call
   `fastmem.set` of the hash table; the C never zeroes (validity by window
   floor). Removing it changes the one-shot's scratch contract — an API
   decision, not a perf patch.

## Gates

`just test`, `just lint`, `just fmt`, `just check-baseline`, `just
check-32`, `just zstd-oracle`, `just brotli-oracle`: all pass on the working
tree. Scoped fuzz: `just fuzz 1M` under timeout (see the wave's handoff for
the final status). Emission is unchanged: the zstd encode oracle pins the
byte-parity rows, brotli decode is golden-pinned; both oracles pass.
