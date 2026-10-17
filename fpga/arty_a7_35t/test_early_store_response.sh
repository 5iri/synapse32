#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
for early in 0 1; do
    verilator --binary --timing -Wno-fatal -j "${JOBS:-4}" --top-module tb_early_store_response \
        -GEARLY="$early" -I../../rtl/include --Mdir "build/obj_early_store_response_$early" \
        tests/tb_early_store_response.sv sv32_bus_port.sv physical_l1_cache.sv ../../rtl/mmu/sv32_tlb.v \
        > "build/early-store-response-$early-compile.log" 2>&1
    "build/obj_early_store_response_$early/Vtb_early_store_response"
done
