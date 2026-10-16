#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
verilator --binary --timing -Wno-fatal -j 4 -I../../rtl/include \
    --top-module tb_instruction_fetch_queue --Mdir build/obj_instruction_fetch_queue \
    tests/tb_instruction_fetch_queue.sv instruction_fetch_queue.sv \
    > build/instruction-fetch-queue-compile.log 2>&1
build/obj_instruction_fetch_queue/Vtb_instruction_fetch_queue | tee build/instruction-fetch-queue-test.log
