#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
verilator --binary --timing -Wno-fatal -j "${JOBS:-4}" --top-module tb_pipelined_fetch_port \
    -I../../rtl/include --Mdir build/obj_pipelined_fetch_port \
    tests/tb_pipelined_fetch_port.sv sv32_bus_port.sv physical_l1_cache.sv ../../rtl/mmu/sv32_tlb.v \
    > build/pipelined-fetch-port-compile.log 2>&1
build/obj_pipelined_fetch_port/Vtb_pipelined_fetch_port
