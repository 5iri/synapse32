#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
verilator --binary --timing -Wno-fatal -j 4 -I../../rtl/include --top-module tb_fetch_port_restart \
    --Mdir build/obj_fetch_port_restart tests/tb_fetch_port_restart.sv \
    sv32_bus_port.sv physical_l1_cache.sv ../../rtl/mmu/sv32_tlb.v \
    > build/fetch-port-restart-compile.log 2>&1
build/obj_fetch_port_restart/Vtb_fetch_port_restart | tee build/fetch-port-restart.log
