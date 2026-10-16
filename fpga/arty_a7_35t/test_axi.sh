#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
python3 make_boot.py
mkdir -p build
for lines in 0 256; do
for kind in 0 1 2; do
verilator --binary -GERROR_KIND="$kind" -GDCACHE_LINES="$lines" --timing -Wno-fatal -j 2 -I../../rtl/include \
    --top-module tb_axi --Mdir "build/obj_axi_${lines}_$kind" \
    tb_axi.sv synapse_ddr3_system.sv axi_word_bridge.sv sv32_bus_port.sv \
    ../../rtl/riscv_cpu.v ../../rtl/execution_unit.v ../../rtl/memory_unit.v \
    ../../rtl/writeback.v ../../rtl/core_modules/*.v ../../rtl/pipeline_stages/*.v ../../rtl/mmu/sv32_tlb.v \
    > "build/compile_axi_${lines}_$kind.log" 2>&1
"build/obj_axi_${lines}_$kind/Vtb_axi"
done
done
