#!/bin/bash
# ab.sh OUT ROUNDS LEVEL FILE...: interleaved base/new deflate encodes, one core, benchstat format
out=$1; rounds=$2; lv=$3; shift 3
mkdir -p $out; for a in base new; do : > $out/$a.txt; done
for r in $(seq 1 $rounds); do
  for arm in base new; do
    taskset -c ${CORE:-3} /tmp/enc/$arm.bin $lv "$@" 2>&1 | awk '{n=$1; sub(/\.raw$/,"",n); printf "BenchmarkDeflate/%s 1 %s ns/op %s MB/s\n", n, $4, $2}' >> $out/$arm.txt
  done
done
