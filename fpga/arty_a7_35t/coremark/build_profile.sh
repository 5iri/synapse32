#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/../../.." && pwd)"
out="${COREMARK_BAREMETAL_OUT:-$here/../build/coremark-profile}"
mkdir -p "$out/platform"
out="$(cd -- "$out" && pwd)"
for file in core_portme.h start.S link.ld; do
    cp "$repo/benchmarks/coremark/baremetal/$file" "$out/platform/$file"
done
cp "$repo/benchmarks/coremark/baremetal/port.c" "$out/platform/base_port.c"
cp "$here/profile_port.c" "$out/platform/port.c"
export COREMARK_PLATFORM_DIR="$out/platform" COREMARK_BAREMETAL_OUT="$out"
export UART_DIVISOR_SCALE="${UART_DIVISOR_SCALE:-16}"
exec bash "$repo/benchmarks/coremark/build_baremetal.sh"
