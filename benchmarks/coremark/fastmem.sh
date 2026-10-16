#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/../.." && pwd)"
rtl_root="$repo/rtl"
latency=0
iterations=50
max_cycles=1000000000
binary="$here/build/sim-1mhz/coremark.bin"
output=""
build_only=0
usage() {
    cat <<'EOF'
Usage: fastmem.sh [--binary PATH] [--rtl-root PATH] [--latency 0|1]
                  [--iterations N] [--max-cycles N] [--output PATH] [--build-only]

Runs the existing bare-metal CoreMark program on riscv_cpu in Verilator with
64 MiB fast host RAM (code, data, BSS and stack), no caches and no translation.
Build the binary with CPU_CLOCK_HZ=1000000 so 1 simulated cycle is 1 us; this
speeds the firmware timer selftest while preserving cycle-based comparisons.
The simulated timebase advances once per CPU cycle, without wall-clock pacing.
Both instruction and data interfaces use rtl/mem_adapter.v with latency 0 or 1.
UART MMIO is immediate (no serial wire or baud-rate delay), outside timed work.
After each READY banner, injects 'p N' then 'v N'; requires both runs to succeed.

--rtl-root defaults to this repository's rtl directory. If riscv_cpu declares
ITERATIVE_MULDIV, it is enabled to match the FPGA; otherwise upstream's normal
combinational arithmetic is used. The selected model is printed before running.
EOF
}
while (($#)); do
    case "$1" in
        --binary) binary="$2"; shift 2;;
        --rtl-root) rtl_root="$2"; shift 2;;
        --latency) latency="$2"; shift 2;;
        --iterations) iterations="$2"; shift 2;;
        --max-cycles) max_cycles="$2"; shift 2;;
        --output) output="$2"; shift 2;;
        --build-only) build_only=1; shift;;
        -h|--help) usage; exit 0;;
        *) usage >&2; exit 1;;
    esac
done
case "$latency" in 0|1) ;; *) echo 'latency must be 0 or 1' >&2; exit 1;; esac
case "$iterations" in ''|*[!0-9]*) echo 'iterations must be positive' >&2; exit 1;; esac
test "$iterations" -gt 0
rtl_root="$(cd -- "$rtl_root" && pwd)"
variant=upstream-combinational
defines=()
if rg -q 'parameter[[:space:]]+ITERATIVE_MULDIV' "$rtl_root/riscv_cpu.v"; then
    variant=fpga-iterative
    defines+=(-DFASTMEM_ITERATIVE_CORE)
fi
output="${output:-$here/build/fastmem-$variant-$latency}"
mkdir -p "$output"
output="$(cd -- "$output" && pwd)"
sources=("$rtl_root"/*.v "$rtl_root"/core_modules/*.v "$rtl_root"/pipeline_stages/*.v)
printf 'FASTMEM_CONFIG rtl=%s arithmetic=%s latency=%s iterations=%s timebase=1cycle/tick\n' \
    "$rtl_root" "$variant" "$latency" "$iterations"
verilator --cc --exe --build -j "${JOBS:-4}" -Wno-fatal --top-module fastmem \
    --Mdir "$output" -I"$rtl_root/include" "${defines[@]}" \
    -GRESPONSE_LATENCY="$latency" -CFLAGS '-O3 -std=c++17' \
    "$here/fastmem.sv" "${sources[@]}" "$here/fastmem.cpp" \
    >"$output/build.log" 2>&1 || { tail -n 70 "$output/build.log" >&2; exit 1; }
if ((build_only)); then
    printf 'Built %s/Vfastmem\n' "$output"
else
    "$output/Vfastmem" --binary "$binary" --iterations "$iterations" --max-cycles "$max_cycles"
fi
