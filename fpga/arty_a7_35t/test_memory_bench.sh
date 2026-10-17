#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
binary="${1:?usage: test_memory_bench.sh memory-bench.bin}"
delay="${AXI_RESPONSE_CYCLES:-20}"
depth="${STORE_BUFFER_DEPTH:-4}"
repeats="${MEMORY_BENCH_REPEATS:-3}"
load_forwarding="${LOAD_FORWARDING:-0}"
fast_store_ack="${FAST_STORE_ACK:-0}"
for value in "$delay" "$depth" "$repeats" "$load_forwarding" "$fast_store_ack"; do
    case "$value" in ''|*[!0-9]*) echo 'Parameters must be unsigned integers' >&2; exit 1;; esac
done
test "$delay" -gt 0 && test "$repeats" -gt 0 && test -f "$binary"
sim_build="${MEMORY_BENCH_SIM_BUILD:-build/obj_memory_bench_sb${depth}_lf${load_forwarding}_sa${fast_store_ack}}"
mkdir -p "$sim_build"
sim_build="$(cd "$sim_build" && pwd)"
log="${MEMORY_BENCH_SIM_LOG:-$sim_build/run-delay${delay}.log}"
report="${MEMORY_BENCH_SIM_REPORT:-$sim_build/report-delay${delay}.json}"
verilator --cc --exe --build -O3 -Wno-fatal -j "${JOBS:-4}" -I../../rtl/include \
    --top-module synapse_ddr3_system --Mdir "$sim_build" \
    -GSERIAL_BOOT=1 -GITERATIVE_MULDIV=1 -GUART_DIVISOR_SCALE=16 -GUART_DEFAULT_DIVISOR=1 \
    -GDCACHE_LINES=256 -GICACHE_LINES=256 -GFAST_L1=1 \
    -GSTORE_BUFFER_DEPTH="$depth" -GFAST_MULTIPLY=1 -GFETCH_QUEUE=1 \
    -GLOAD_FORWARDING="$load_forwarding" \
    -GFAST_STORE_ACK="$fast_store_ack" \
    -CFLAGS '-O3 -std=c++17 -DUART_BIT_CYCLES=16' \
    tests/memory_bench_axi.cpp synapse_ddr3_system.sv axi_word_bridge.sv physical_l1_cache.sv \
    ordered_write_buffer.sv fpga_perf_counters.sv sv32_bus_port.sv instruction_fetch_queue.sv \
    ../../rtl/riscv_cpu.v ../../rtl/execution_unit.v ../../rtl/memory_unit.v \
    ../../rtl/writeback.v ../../rtl/core_modules/*.v ../../rtl/pipeline_stages/*.v ../../rtl/mmu/sv32_tlb.v \
    > "$sim_build/build.log" 2>&1 || { tail -n 70 "$sim_build/build.log" >&2; exit 1; }
"$sim_build/Vsynapse_ddr3_system" "$binary" "${MEMORY_BENCH_TEST_CYCLES:-200000000}" "$repeats" "$delay" | tee "$log"
python3 memory_bench/memory_report.py "$log" --repeats "$repeats" --output "$report"
