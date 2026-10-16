#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
for instruction in 0 1; do
for lines in 0 1 64 256; do
    verilator --binary --timing -Wno-fatal -j 4 --top-module tb_dcache \
        -GCACHE_LINES="$lines" -GINSTRUCTION="$instruction" --Mdir "build/obj_cache_${instruction}_$lines" \
        tests/tb_dcache.sv axi_word_bridge.sv > "build/cache-compile-${instruction}-$lines.log" 2>&1
    "build/obj_cache_${instruction}_$lines/Vtb_dcache"
done
done
