#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
verilator --binary --timing --assert -Wno-fatal -j "${JOBS:-2}" -I../../rtl/include \
    --top-module tb_fetch_completion --Mdir build/obj_fetch_completion \
    tests/tb_fetch_completion.sv sv32_bus_port.sv physical_l1_cache.sv \
    ../../rtl/mmu/sv32_tlb.v > build/fetch-completion-compile.log 2>&1
build/obj_fetch_completion/Vtb_fetch_completion
