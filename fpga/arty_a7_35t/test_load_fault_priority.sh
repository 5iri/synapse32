#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/../.." && pwd)"
for forwarding in 0 1; do
out="$here/build/obj_load_fault_priority_$forwarding"
mkdir -p "$out"
verilator --binary --timing --assert -j "${JOBS:-4}" -Wno-fatal \
    --top-module tb_load_fault_priority -GLOAD_FORWARDING="$forwarding" --Mdir "$out" -I"$repo/rtl/include" \
    "$here/tests/tb_load_fault_priority.sv" "$repo"/rtl/*.v \
    "$repo"/rtl/core_modules/*.v "$repo"/rtl/pipeline_stages/*.v \
    >"$out/build.log" 2>&1 || { tail -n 60 "$out/build.log" >&2;exit 1; }
"$out/Vtb_load_fault_priority" | tee "$out/run.log"
done
