#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
results="$root/bench/results"
mkdir -p "$results"

run () {
    local out="$1"
    shift
    echo "==> $out" >&2
    "$root/bench/run.sh" "$@" > "$out"
}

# Full C quality matrix at 1 MiB.
run "$results/quality-1m.out" \
    --sizes 1M \
    --levels 0,1,2,3,4,5,6,7,8,9,10,11 \
    --windows 22 --modes 0 \
    --samples 3 --target 0.15 \
    --csv "$results/quality-1m.csv"

# C window sweep on representative data.
run "$results/windows-1m.out" \
    --sizes 1M --datasets text,html,source,binary \
    --levels 5,11 --windows 10,12,14,16,18,20,22,24 --modes 0 \
    --samples 2 --target 0.1 \
    --csv "$results/windows-1m.csv"

# Edge sizes for every data class.
run "$results/sizes-small.out" \
    --sizes 0,1,2,10,100,1K,10K,100K,1M \
    --levels 5,11 --windows 22 --modes 0 \
    --samples 1 --target 0.05 \
    --csv "$results/sizes-small.csv"

# Large sizes on representative data (including the 16 MiB boundary).
run "$results/sizes-large.out" \
    --sizes 4M,16M,17M \
    --datasets text,source,random,periodic,pattern \
    --levels 5,11 --windows 22 --modes 0 \
    --samples 1 --target 0.05 \
    --csv "$results/sizes-large.csv"

# C mode sweep (generic / text / font).
run "$results/modes-1m.out" \
    --sizes 1M --datasets text,html,json \
    --levels 11 --windows 22 --modes 0,1,2 \
    --samples 2 --target 0.1 \
    --csv "$results/modes-1m.csv"

# Optional allocation diagnostics.
run "$results/consing-quick.out" \
    --quick --samples 1 --target 0.05 --consing \
    --csv "$results/consing-quick.csv"

echo "results written under $results" >&2
