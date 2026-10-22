#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
verilator --binary --timing -Wno-fatal -j 4 --top-module tb_fast_l1 \
    -I../../rtl/include --Mdir build/obj_fast_l1 \
    tests/tb_fast_l1.sv sv32_bus_port.sv physical_l1_cache.sv ../../rtl/mmu/sv32_tlb.v \
    > build/fast-l1-compile.log 2>&1
build/obj_fast_l1/Vtb_fast_l1
for registered in 0 1; do
for lines in 0 1 4 256; do
    verilator --binary --timing -Wno-fatal -j 4 --top-module tb_l1_bank \
        -GLINES="$lines" -GREGISTER_WRITES="$registered" --Mdir "build/obj_l1_bank_${lines}_rw${registered}" \
        tests/tb_l1_bank.sv physical_l1_cache.sv > "build/l1-bank-${lines}-rw${registered}-compile.log" 2>&1
    "build/obj_l1_bank_${lines}_rw${registered}/Vtb_l1_bank"
done
done
