#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
board="$PWD"
bench="${COREMARK_BENCH_DIR:-$board/../../benchmarks/coremark}"
binary="${1:-${COREMARK_BINARY:-build/coremark-axi-1mhz/coremark.bin}}"
iterations="${COREMARK_ITERATIONS:-50}"
delay="${AXI_RESPONSE_CYCLES:-20}"
depth="${STORE_BUFFER_DEPTH:-4}"
fast_l1="${FAST_L1:-1}"
fast_multiply="${FAST_MULTIPLY:-0}"
fetch_queue="${FETCH_QUEUE:-0}"
dcache="${DCACHE_LINES:-256}"
icache="${ICACHE_LINES:-256}"
for value in "$iterations" "$delay" "$depth" "$fast_l1" "$fast_multiply" "$fetch_queue" "$dcache" "$icache"; do
    case "$value" in ''|*[!0-9]*) echo 'Simulation parameters must be unsigned integers' >&2; exit 1;; esac
done
test "$iterations" -gt 0 && test "$delay" -gt 0
if [ ! -f "$binary" ]; then
    if [ "$#" -gt 0 ] || [ -n "${COREMARK_BINARY:-}" ]; then echo "Missing firmware: $binary" >&2; exit 1; fi
    compiler="${COREMARK_CC:-riscv32-unknown-elf-gcc}"
    runtime="${COREMARK_RUNTIME_ARCHIVE:--lgcc}"
    objcopy="${COREMARK_OBJCOPY:-riscv32-unknown-elf-objcopy}"
    objdump="${COREMARK_OBJDUMP:-riscv32-unknown-elf-objdump}"
    if [ -x build/llvm-toolchain/riscv32-linux-gnu-gcc ] && [ -z "${COREMARK_CC:-}" ]; then
        compiler="$board/build/llvm-toolchain/riscv32-linux-gnu-gcc"
        runtime="$board/build/runtime/lib/linux/libclang_rt.builtins-riscv32.a"
        objcopy=llvm-objcopy; objdump=llvm-objdump
    fi
    mkdir -p "$(dirname "$binary")"
    output="$(cd "$(dirname "$binary")" && pwd)"
    CPU_CLOCK_HZ=1000000 UART_DIVISOR_SCALE=16 COREMARK_BAREMETAL_OUT="$output" \
        COREMARK_CC="$compiler" COREMARK_RUNTIME_ARCHIVE="$runtime" \
        COREMARK_OBJCOPY="$objcopy" COREMARK_OBJDUMP="$objdump" \
        COREMARK_DIR="${COREMARK_DIR:-$board/build/coremark-source}" \
        bash "$bench/build_baremetal.sh" > "$output/build.log" 2>&1 || {
            tail -n 50 "$output/build.log" >&2; exit 1;
        }
fi
sim_build="${COREMARK_SIM_BUILD:-build/obj_coremark_axi_l1${fast_l1}_sb${depth}_mul${fast_multiply}_fq${fetch_queue}_d${dcache}_i${icache}}"
mkdir -p "$sim_build"
sim_build="$(cd "$sim_build" && pwd)"
log="${COREMARK_SIM_LOG:-$sim_build/run.log}"
report="${COREMARK_SIM_REPORT:-$sim_build/report.json}"
verilator --cc --exe --build -O3 -Wno-fatal -j "${JOBS:-4}" -I../../rtl/include \
    --top-module synapse_ddr3_system --Mdir "$sim_build" \
    -GSERIAL_BOOT=1 -GITERATIVE_MULDIV=1 -GUART_DIVISOR_SCALE=16 -GUART_DEFAULT_DIVISOR=1 \
    -GDCACHE_LINES="$dcache" -GICACHE_LINES="$icache" -GFAST_L1="$fast_l1" \
    -GSTORE_BUFFER_DEPTH="$depth" -GFAST_MULTIPLY="$fast_multiply" -GFETCH_QUEUE="$fetch_queue" \
    -CFLAGS '-O3 -std=c++17 -DUART_BIT_CYCLES=16' \
    tests/coremark_axi.cpp synapse_ddr3_system.sv axi_word_bridge.sv physical_l1_cache.sv \
    ordered_write_buffer.sv fpga_perf_counters.sv sv32_bus_port.sv instruction_fetch_queue.sv \
    ../../rtl/riscv_cpu.v ../../rtl/execution_unit.v ../../rtl/memory_unit.v \
    ../../rtl/writeback.v ../../rtl/core_modules/*.v ../../rtl/pipeline_stages/*.v ../../rtl/mmu/sv32_tlb.v \
    > "$sim_build/build.log" 2>&1 || { tail -n 70 "$sim_build/build.log" >&2; exit 1; }
printf 'COREMARK_AXI_CONFIG nominal_cpu_hz=1000000 fast_l1=%s store_buffer_depth=%s fast_multiply=%s fetch_queue=%s dcache_lines=%s icache_lines=%s iterations=%s response_cycles=%s\n' \
    "$fast_l1" "$depth" "$fast_multiply" "$fetch_queue" "$dcache" "$icache" "$iterations" "$delay" | tee "$log"
"$sim_build/Vsynapse_ddr3_system" "$binary" "${COREMARK_TEST_CYCLES:-2000000000}" "$iterations" "$delay" | tee -a "$log"
python3 "$bench/report.py" "$log" --cpu-mhz 1 --output "$report"
python3 - "$report" "$iterations" <<'PY'
import json, sys
from pathlib import Path
reports=json.loads(Path(sys.argv[1]).read_text())
assert len(reports)==2 and {r['mode'] for r in reports}=={'performance','validation'}
assert all(r['iterations']==int(sys.argv[2]) and r['validated'] for r in reports)
for r in reports:
    print(f"PASS: AXI CoreMark {r['mode']} CPI={r['cpi']:.6f} CoreMark/MHz={r['coremark_per_mhz']:.6f}")
PY
