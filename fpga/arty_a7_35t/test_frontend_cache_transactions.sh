#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
verilator --binary --timing -Wno-fatal -j "${JOBS:-4}" --top-module tb_frontend_cache_transactions \
    -I../../rtl/include --Mdir build/obj_frontend_cache_transactions \
    tests/tb_frontend_cache_transactions.sv sv32_bus_port.sv physical_l1_cache.sv ../../rtl/mmu/sv32_tlb.v \
    > build/frontend-cache-transactions-compile.log 2>&1
build/obj_frontend_cache_transactions/Vtb_frontend_cache_transactions
