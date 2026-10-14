#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
board="$(dirname "$here")"
compiler="${TRIANGULATOR_CC:-${KERNEL_CROSS_COMPILE:-$board/build/llvm-toolchain/riscv32-linux-gnu-}gcc}"
output="${TRIANGULATOR_OUT:-$board/build/triangulator}"
mkdir -p "$output"
runtime="$("$compiler" -march=rv32ima_zicsr_zifencei -mabi=ilp32 -print-libgcc-file-name)"
test -f "$runtime" || { echo "Compiler runtime missing: $runtime" >&2; exit 1; }
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -ffreestanding -fno-builtin \
    -fno-stack-protector -fno-pie -fno-pic -msmall-data-limit=0 -nostdlib -static \
    -march=rv32ima_zicsr_zifencei -mabi=ilp32 -ffunction-sections -fdata-sections \
    -Wl,--gc-sections -Wl,--build-id=none -Wl,-e,_start -s \
    "$here/triangulator.c" "$runtime" -o "$output/triangulator"
printf 'file /bin/triangulator %s/triangulator 0755 0 0\n' "$output" > "$output/initramfs.list"
echo "Built $output/triangulator"
