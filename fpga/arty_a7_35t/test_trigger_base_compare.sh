#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
verilator --binary --timing --top-module tb_trigger_base_compare -j 2 \
  -Wno-fatal -Wno-PINMISSING -I../../rtl/include \
  --Mdir build/obj_trigger_base_compare tests/tb_trigger_base_compare.sv \
  ../../rtl/execution_unit.v ../../rtl/core_modules/alu.v ../../rtl/core_modules/csr_exec.v \
  > build/trigger-base-compile.log 2>&1
build/obj_trigger_base_compare/Vtb_trigger_base_compare
