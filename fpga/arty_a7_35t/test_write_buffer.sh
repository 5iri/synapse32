#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
for depth in 0 1 3 4; do
    verilator --binary --timing -Wno-fatal -j 4 --top-module tb_ordered_write_buffer \
        -GDEPTH="$depth" --Mdir "build/obj_write_buffer_$depth" \
        tests/tb_ordered_write_buffer.sv ordered_write_buffer.sv \
        > "build/write-buffer-compile-$depth.log" 2>&1
    "build/obj_write_buffer_$depth/Vtb_ordered_write_buffer"
done
