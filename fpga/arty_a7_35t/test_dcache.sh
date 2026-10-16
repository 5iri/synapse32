#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
for lines in 0 1 64 256; do
    verilator --binary --timing -Wno-fatal -j 4 --top-module tb_dcache \
        -GCACHE_LINES="$lines" --Mdir "build/obj_dcache_$lines" \
        tests/tb_dcache.sv axi_word_bridge.sv > "build/dcache-compile-$lines.log" 2>&1
    "build/obj_dcache_$lines/Vtb_dcache"
done
