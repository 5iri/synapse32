#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
build_dir="${SPECULATIVE_FETCH_BUILD_DIR:-build/obj_speculative_fetch_fill}"
port_source="${SPECULATIVE_FETCH_PORT_SOURCE:-sv32_bus_port.sv}"
mkdir -p "$build_dir"
verilator --binary --timing --assert -Wno-fatal -j "${JOBS:-2}" -I../../rtl/include \
    --top-module tb_speculative_fetch_fill --Mdir "$build_dir" \
    tests/tb_speculative_fetch_fill.sv "$port_source" physical_l1_cache.sv \
    ../../rtl/mmu/sv32_tlb.v > "$build_dir/compile.log" 2>&1
"$build_dir/Vtb_speculative_fetch_fill"
