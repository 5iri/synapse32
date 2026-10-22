#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
verilator --binary --timing --top-module tb_atomic_trigger_forwarding -j "${JOBS:-2}" \
    -Wno-fatal -Wno-PINMISSING -I../../rtl/include --Mdir build/obj_atomic_trigger_forwarding \
    tests/tb_atomic_trigger_forwarding.sv ../../rtl/execution_unit.v \
    ../../rtl/core_modules/alu.v ../../rtl/core_modules/csr_exec.v \
    > build/atomic-trigger-forwarding-compile.log 2>&1
build/obj_atomic_trigger_forwarding/Vtb_atomic_trigger_forwarding
