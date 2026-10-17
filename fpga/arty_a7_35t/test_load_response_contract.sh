#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
# This builds the shared program from source and checks the formatted SoC path.
LOAD_FORWARDING_INTERFACE=1 LOAD_FORWARDING=1 EXPECT_INTERVAL=2 \
    bash test_load_forwarding.sh > build/load-response-contract-soc.log 2>&1 || {
        tail -n 60 build/load-response-contract-soc.log >&2;exit 1;
    }
tail -n 2 build/load-response-contract-soc.log
for formatted in 0 1; do
    out="build/obj_load_response_contract_$formatted"
    verilator --binary --timing --assert -Wno-fatal -j "${JOBS:-2}" -I../../rtl/include \
        --top-module tb_load_response_contract -GLOAD_RESPONSE_FORMATTED="$formatted" --Mdir "$out" \
        tests/tb_load_response_contract.sv ../../rtl/riscv_cpu.v ../../rtl/execution_unit.v \
        ../../rtl/memory_unit.v ../../rtl/writeback.v ../../rtl/core_modules/*.v \
        ../../rtl/pipeline_stages/*.v ../../rtl/mmu/sv32_tlb.v \
        > "build/load-response-contract-$formatted-compile.log" 2>&1 || {
            tail -n 60 "build/load-response-contract-$formatted-compile.log" >&2;exit 1;
        }
    "$out/Vtb_load_response_contract"
done
