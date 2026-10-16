#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
image="${1:-build/linux-image/fw_payload.bin}"
sim_build="${LINUX_SIM_BUILD:-build/obj_linux}"
test -f "$image" || { echo 'Build the Linux payload first.' >&2; exit 1; }
mkdir -p build
verilator --cc --exe --build -O3 -Wno-fatal -j 4 -I../../rtl/include \
    --top-module synapse_ddr3_system --Mdir "$sim_build" \
    -GSERIAL_BOOT=1 -GITERATIVE_MULDIV=1 -GUART_DIVISOR_SCALE=16 -GUART_DEFAULT_DIVISOR=27 \
    -CFLAGS '-O3' tests/linux_axi.cpp synapse_ddr3_system.sv axi_word_bridge.sv sv32_bus_port.sv \
    ../../rtl/riscv_cpu.v ../../rtl/execution_unit.v ../../rtl/memory_unit.v \
    ../../rtl/writeback.v ../../rtl/core_modules/*.v ../../rtl/pipeline_stages/*.v ../../rtl/mmu/sv32_tlb.v \
    > build/linux-sim-compile.log 2>&1
exec "$sim_build/Vsynapse_ddr3_system" "$image" "${LINUX_TEST_CYCLES:-2000000000}"
