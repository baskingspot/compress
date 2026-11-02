#!/bin/bash
# ab2.sh OUT ROUNDS GLOB: interleaved base/new/libdeflate/wuffs, core 3, benchstat format
out=$1; rounds=$2; shift 2
mkdir -p $out; for a in base new libdeflate wuffs; do : > $out/$a.txt; done
for r in $(seq 1 $rounds); do
  for arm in base new libdeflate wuffs; do
    case $arm in base) b=${BASE:-/tmp/infl/A.bin};; new) b=${NEW:-/tmp/infl/E.bin};; libdeflate) b=/tmp/infl/libdeflate.bin;; wuffs) b=/tmp/infl/wuffs.bin;; esac
    taskset -c ${CORE:-3} $b "$@" 2>&1 | awk '{n=$1; sub(/\.zs?$/,"",n); printf "BenchmarkInflate/%s 1 %s ns/op %s MB/s\n", n, $4, $2}' >> $out/$arm.txt
  done
done
