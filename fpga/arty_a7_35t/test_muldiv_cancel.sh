#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
for fast in 0 1; do
    verilator --binary --timing --top-module tb_muldiv_cancel -j "${JOBS:-2}" \
        -Wno-fatal -I../../rtl/include -GFAST_MULTIPLY="$fast" --Mdir "build/obj_muldiv_cancel_fast$fast" \
        tests/tb_muldiv_cancel.sv ../../rtl/core_modules/iterative_muldiv.v \
        > "build/muldiv-cancel-fast$fast-compile.log" 2>&1
    "build/obj_muldiv_cancel_fast$fast/Vtb_muldiv_cancel"
done
