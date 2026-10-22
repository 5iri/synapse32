#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export LINUX_OUT_DIR="${LINUX_OUT_DIR:-$here/build/linux-image}"
export LINUX_DIR="${LINUX_DIR:-$here/build/linux}"
export OPENSBI_DIR="${OPENSBI_DIR:-$here/build/opensbi}"
export BUSYBOX_DIR="${BUSYBOX_DIR:-$here/build/busybox}"
export PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei
export KERNEL_MARCH=rv32ima_zicsr_zifencei
# TLB hardware tests select 25 Hz as a throughput/latency compromise.
# 12 Hz remains available for maximum throughput or uncached bring-up.
export KERNEL_HZ="${KERNEL_HZ:-25}"
# Match arty_linux_top's 1 GHz VCO/output divider, including UART and mtime.
cpu_divide="${CPU_DIVIDE:-20}"
case "$cpu_divide" in ''|*[!0-9]*) echo 'CPU_DIVIDE must be an integer in 1..128' >&2; exit 1;; esac
test "$cpu_divide" -ge 1 && test "$cpu_divide" -le 128 || { echo 'CPU_DIVIDE must be in 1..128' >&2; exit 1; }
cpu_clock=$(((1000000000+cpu_divide/2)/cpu_divide))
if [ -z "${DEVICE_TREE:-}" ]; then
    mkdir -p "$LINUX_OUT_DIR"
    export DEVICE_TREE="$LINUX_OUT_DIR/synapse32-clock.dts"
    sed "s/<50000000>/<${cpu_clock}>/g" "$here/../../sim/synapse32.dts" > "$DEVICE_TREE"
fi
# RV32 Linux requires a 4 MiB aligned kernel entry (Documentation/riscv/boot.rst).
export FW_PAYLOAD_ALIGN=0x400000
if [ "${LLVM:-}" = 1 ]; then
    export KERNEL_CROSS_COMPILE="$here/build/llvm-toolchain/riscv32-linux-gnu-"
    export OPENSBI_CROSS_COMPILE="$KERNEL_CROSS_COMPILE"
    test -x "${KERNEL_CROSS_COMPILE}gcc" || { echo 'Run prepare_llvm.sh first.' >&2; exit 1; }
fi
extra_lists=()
if [ -n "${INITRAMFS_EXTRA_LIST:-}" ]; then
    test -r "$INITRAMFS_EXTRA_LIST" && test -f "$INITRAMFS_EXTRA_LIST" || {
        echo 'INITRAMFS_EXTRA_LIST must name a readable regular file.' >&2; exit 1;
    }
    extra_lists+=("$INITRAMFS_EXTRA_LIST")
fi
if [ "${BUILD_TRIANGULATOR:-1}" = 1 ]; then
    TRIANGULATOR_CC="${KERNEL_CROSS_COMPILE:-riscv32-unknown-linux-gnu-}gcc" \
        bash "$here/triangulator/build.sh"
    extra_lists+=("$here/build/triangulator/initramfs.list")
fi
if [ "${BUILD_WORKLOADS:-0}" = 1 ]; then
    WORKLOAD_CC="${WORKLOAD_CC:-${KERNEL_CROSS_COMPILE:-riscv32-unknown-linux-gnu-}gcc}" \
        "${PYTHON:-python3}" "$here/workloads/build.py"
    extra_lists+=("$here/build/workloads/initramfs.list")
fi
if [ "${#extra_lists[@]}" -gt 0 ]; then
    mkdir -p "$LINUX_OUT_DIR"
    extra_tmp=$(mktemp "$LINUX_OUT_DIR/board-initramfs-extra.XXXXXX")
    trap 'rm -f "$extra_tmp"' EXIT
    for extra in "${extra_lists[@]}"; do
        cat "$extra" >> "$extra_tmp"
        printf '\n' >> "$extra_tmp"
    done
    export INITRAMFS_EXTRA_LIST="$LINUX_OUT_DIR/board-initramfs-extra.list"
    mv "$extra_tmp" "$INITRAMFS_EXTRA_LIST"
fi
exec bash "$here/../../sim/build_linux.sh"
