#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
out="${COREMARK_PROFILE_OUT:-$here/../build/coremark-linux-profile}"
cc="${COREMARK_CC:-riscv32-unknown-linux-gnu-gcc}"
mkdir -p "$out"
"$cc" -O2 -std=gnu11 -march=rv32ima_zicsr_zifencei -mabi=ilp32 -msmall-data-limit=0 \
    -static -fno-pie -fno-pic -Wl,--build-id=none "$here/profile_linux.c" -o "$out/profile"
sha256sum "$out/profile"
