#!/usr/bin/env bash
# Build an isolated tick/clock experiment from an existing configured Linux build.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
board="$(dirname "$here")"
hz="${KERNEL_HZ:-25}"
cpu_clock="${CPU_CLOCK_HZ:-50000000}"
case "$hz" in 12|25|50|100) ;; *) echo 'KERNEL_HZ must be 12, 25, 50 or 100' >&2; exit 1;; esac
case "$cpu_clock" in ''|*[!0-9]*) echo 'CPU_CLOCK_HZ must be a positive integer' >&2; exit 1;; esac
test "$cpu_clock" -gt 0
source_kernel="${LINUX_SOURCE_BUILD:-$board/build/linux}"
kernel="${TICK_KERNEL_DIR:-$board/build/linux-${hz}hz}"
image_dir="${TICK_IMAGE_DIR:-$board/build/linux-image-${hz}hz}"
base_image="${BASE_LINUX_IMAGE:-$board/build/linux-image}"
compiler_prefix="$board/build/llvm-toolchain/riscv32-linux-gnu-"
test -f "$source_kernel/.config" || { echo 'Build the baseline Linux image first.' >&2; exit 1; }
test "$(realpath -m "$kernel")" != "$(realpath "$source_kernel")" || { echo 'Experiment must use a separate kernel directory.' >&2; exit 1; }
test -f "$board/build/coremark/coremark" && test -f "$board/build/coremark-o2/coremark" || {
    echo 'Build both CoreMark optimization variants first.' >&2; exit 1;
}
export LLVM=1
export PATH="$board/build/tools/usr/bin:$PATH"
mkdir -p "$image_dir"
if [ ! -d "$kernel" ]; then cp -a --reflink=auto "$source_kernel" "$kernel"; fi
if { [ "$hz" = 25 ] || [ "$hz" = 50 ]; } && ! grep -q 'config HZ_25$' "$kernel/kernel/Kconfig.hz"; then
    patch -d "$kernel" -p1 < "$board/../../sim/linux-fpga-ticks.patch"
fi
if [ "$hz" = 12 ] && ! rg -q 'config HZ_12' "$kernel/kernel/Kconfig.hz"; then
    patch -d "$kernel" -p1 < "$board/../../sim/linux-low-tick.patch"
fi
sed "s/<50000000>/<${cpu_clock}>/g" "$board/../../sim/synapse32.dts" > "$image_dir/synapse32.dts"
dtc -O dtb -o "$image_dir/synapse32.dtb" "$image_dir/synapse32.dts"
cp "$base_image/initramfs.list" "$image_dir/initramfs.list"
printf 'file /tmp/coremark-o3 %s/build/coremark/coremark 0755 0 0\nfile /tmp/coremark-o2 %s/build/coremark-o2/coremark 0755 0 0\n' "$board" "$board" >> "$image_dir/initramfs.list"
"$base_image/gen_init_cpio" "$image_dir/initramfs.list" > "$image_dir/initramfs.cpio"
for tick in 12 25 50 100 250 300 1000; do
    "$kernel/scripts/config" --file "$kernel/.config" --disable "HZ_$tick"
done
"$kernel/scripts/config" --file "$kernel/.config" --enable "HZ_$hz" --set-str INITRAMFS_SOURCE "$image_dir/initramfs.cpio"
export SOURCE_DATE_EPOCH=1716646976 KBUILD_BUILD_TIMESTAMP='Sat May 25 14:22:56 UTC 2024'
export KBUILD_BUILD_USER=synapse32 KBUILD_BUILD_HOST=synapse32 KBUILD_BUILD_VERSION="$hz"
make -C "$kernel" ARCH=riscv CROSS_COMPILE="$compiler_prefix" olddefconfig
test "$(sed -n 's/^CONFIG_HZ=//p' "$kernel/.config")" = "$hz"
cp "$kernel/.config" "$image_dir/kernel.config"
make -C "$kernel" -j"${BUILD_JOBS:-4}" ARCH=riscv CROSS_COMPILE="$compiler_prefix" KCFLAGS='-march=rv32ima_zicsr_zifencei -mabi=ilp32' KAFLAGS='-march=rv32ima_zicsr_zifencei -mabi=ilp32' Image
cp "$kernel/arch/riscv/boot/Image" "$image_dir/Image"
cp "$kernel/vmlinux" "$image_dir/vmlinux"
cp "$kernel/System.map" "$image_dir/System.map"
make -C "$board/build/opensbi" -j"${BUILD_JOBS:-4}" O="$image_dir/opensbi-build" PLATFORM=generic FW_PAYLOAD=y FW_PAYLOAD_PATH="$image_dir/Image" FW_FDT_PATH="$image_dir/synapse32.dtb" FW_TEXT_START=0x80000000 FW_PAYLOAD_ALIGN=0x400000 PLATFORM_RISCV_XLEN=32 PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei PLATFORM_RISCV_ABI=ilp32 CROSS_COMPILE="$compiler_prefix" 'platform-cflags-y=-Wno-error=unused-but-set-global -Wno-unknown-warning-option'
cp "$image_dir/opensbi-build/platform/generic/firmware/fw_payload.elf" "$image_dir/fw_payload.elf"
"${compiler_prefix}objcopy" --change-addresses -0x80000000 -O binary "$image_dir/fw_payload.elf" "$image_dir/fw_payload.bin"
sha256sum "$image_dir/fw_payload.bin"
