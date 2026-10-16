#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/../.." && pwd)"
out="$here/build/obj_instr_access_fault"
mkdir -p "$out"
verilator --binary --timing --assert -j "${JOBS:-4}" -Wno-fatal \
    --top-module tb_instr_access_fault --Mdir "$out" -I"$repo/rtl/include" \
    "$here/tests/tb_instr_access_fault.sv" "$repo"/rtl/*.v \
    "$repo"/rtl/core_modules/*.v "$repo"/rtl/pipeline_stages/*.v \
    >"$out/build.log" 2>&1 || { tail -n 60 "$out/build.log" >&2;exit 1; }
"$out/Vtb_instr_access_fault" | tee "$out/run.log"
