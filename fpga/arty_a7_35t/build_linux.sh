#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export LINUX_OUT_DIR="${LINUX_OUT_DIR:-$here/build/linux-image}"
export LINUX_DIR="${LINUX_DIR:-$here/build/linux}"
export OPENSBI_DIR="${OPENSBI_DIR:-$here/build/opensbi}"
export BUSYBOX_DIR="${BUSYBOX_DIR:-$here/build/busybox}"
export PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei
export KERNEL_MARCH=rv32ima_zicsr_zifencei
# RV32 Linux requires a 4 MiB aligned kernel entry (Documentation/riscv/boot.rst).
export FW_PAYLOAD_ALIGN=0x400000
if [ "${LLVM:-}" = 1 ]; then
    export KERNEL_CROSS_COMPILE="$here/build/llvm-toolchain/riscv32-linux-gnu-"
    export OPENSBI_CROSS_COMPILE="$KERNEL_CROSS_COMPILE"
    test -x "${KERNEL_CROSS_COMPILE}gcc" || { echo 'Run prepare_llvm.sh first.' >&2; exit 1; }
fi
exec bash "$here/../../sim/build_linux.sh"
