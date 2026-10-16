#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
image="${1:-build/linux-image/fw_payload.bin}"
sim_build="${LINUX_SIM_BUILD:-build/obj_linux}"
cpu_divide="${CPU_DIVIDE:-20}"
case "$cpu_divide" in ''|*[!0-9]*) echo 'CPU_DIVIDE must be an integer in 1..128' >&2; exit 1;; esac
test "$cpu_divide" -ge 1 && test "$cpu_divide" -le 128
cpu_clock=$(((1000000000+cpu_divide/2)/cpu_divide))
uart_divisor=$(((cpu_clock+115200*8)/(115200*16)))
uart_bit_cycles=$((uart_divisor*16))
test -f "$image" || { echo 'Build the Linux payload first.' >&2; exit 1; }
mkdir -p build
verilator --cc --exe --build -O3 -Wno-fatal -j 4 -I../../rtl/include \
    --top-module synapse_ddr3_system --Mdir "$sim_build" \
    -GSERIAL_BOOT=1 -GITERATIVE_MULDIV=1 -GUART_DIVISOR_SCALE=16 -GUART_DEFAULT_DIVISOR="$uart_divisor" \
    -GDCACHE_LINES="${DCACHE_LINES:-256}" -GICACHE_LINES="${ICACHE_LINES:-256}" -GFAST_L1="${FAST_L1:-0}" \
    -GSTORE_BUFFER_DEPTH="${STORE_BUFFER_DEPTH:-0}" -GFAST_MULTIPLY="${FAST_MULTIPLY:-0}" \
    -CFLAGS "-O3 -DUART_BIT_CYCLES=$uart_bit_cycles" tests/linux_axi.cpp synapse_ddr3_system.sv axi_word_bridge.sv physical_l1_cache.sv ordered_write_buffer.sv fpga_perf_counters.sv sv32_bus_port.sv \
    ../../rtl/riscv_cpu.v ../../rtl/execution_unit.v ../../rtl/memory_unit.v \
    ../../rtl/writeback.v ../../rtl/core_modules/*.v ../../rtl/pipeline_stages/*.v ../../rtl/mmu/sv32_tlb.v \
    > build/linux-sim-compile.log 2>&1
exec "$sim_build/Vsynapse_ddr3_system" "$image" "${LINUX_TEST_CYCLES:-2000000000}"
