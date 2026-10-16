#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
verilator --binary --timing -Wno-fatal -j 4 --top-module tb_perf_counters \
    --Mdir build/obj_perf_counters fpga_perf_counters.sv tests/tb_perf_counters.sv \
    > build/perf-counters-compile.log 2>&1
build/obj_perf_counters/Vtb_perf_counters
