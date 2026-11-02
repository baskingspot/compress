#!/bin/bash
# interleaved A/B: base, new, wuffs per round; benchstat format
out=/tmp/inflab2
: > $out/base.txt; : > $out/new.txt; : > $out/wuffs.txt
for r in $(seq 1 10); do
  for arm in base new wuffs; do
    case $arm in base) b=/tmp/infl/R1.bin;; new) b=/tmp/infl/R2.bin;; wuffs) b=/tmp/infl/wuffs.bin;; esac
    taskset -c 1 $b /tmp/infl/data/*.z 2>&1 | awk -v a=$arm '{printf "BenchmarkInflate/%s 1 %s ns/op %s MB/s\n", gensub(/\.z$/,"","g",$1), $4, $2}' >> $out/$arm.txt
  done
  echo round $r done $(date +%T)
done
