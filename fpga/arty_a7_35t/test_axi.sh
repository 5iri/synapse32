#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
python3 make_boot.py
mkdir -p build
for config in ${AXI_TEST_CONFIGS:-none data instruction both}; do
case "$config" in
    none) lines=0; instr_lines=0;;
    data) lines=256; instr_lines=0;;
    instruction) lines=0; instr_lines=256;;
    both) lines=256; instr_lines=256;;
esac
for kind in ${AXI_ERROR_KINDS:-0 1 2}; do
sim_build="build/obj_axi_${config}_${kind}_l1${FAST_L1:-0}_sb${STORE_BUFFER_DEPTH:-0}_mul${FAST_MULTIPLY:-0}"
verilator --binary -GERROR_KIND="$kind" -GDCACHE_LINES="$lines" -GICACHE_LINES="$instr_lines" \
    -GFAST_L1="${FAST_L1:-0}" -GSTORE_BUFFER_DEPTH="${STORE_BUFFER_DEPTH:-0}" -GFAST_MULTIPLY="${FAST_MULTIPLY:-0}" --timing -Wno-fatal -j 2 -I../../rtl/include \
    --top-module tb_axi --Mdir "$sim_build" \
    tb_axi.sv synapse_ddr3_system.sv axi_word_bridge.sv physical_l1_cache.sv ordered_write_buffer.sv fpga_perf_counters.sv sv32_bus_port.sv \
    ../../rtl/riscv_cpu.v ../../rtl/execution_unit.v ../../rtl/memory_unit.v \
    ../../rtl/writeback.v ../../rtl/core_modules/*.v ../../rtl/pipeline_stages/*.v ../../rtl/mmu/sv32_tlb.v \
    > "build/compile_axi_${config}_$kind.log" 2>&1
"$sim_build/Vtb_axi"
done
done
