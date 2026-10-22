#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
for formatted in 0 1; do
for variable in 0 1; do
    output="build/obj_early_control_cpu_f${formatted}_v${variable}"
    verilator --binary --timing --assert -Wno-fatal -Wno-PINMISSING -j "${JOBS:-2}" -I../../rtl/include \
        --top-module tb_early_control_cpu -GLOAD_RESPONSE_FORMATTED="$formatted" -GVARIABLE_LATENCY="$variable" \
        --Mdir "$output" tests/tb_early_control_cpu.sv ../../rtl/riscv_cpu.v ../../rtl/execution_unit.v \
        ../../rtl/memory_unit.v ../../rtl/writeback.v ../../rtl/core_modules/*.v \
        ../../rtl/pipeline_stages/*.v ../../rtl/mmu/sv32_tlb.v \
        > "build/early-control-cpu-f${formatted}-v${variable}-compile.log" 2>&1
    "$output/Vtb_early_control_cpu"
done
done
