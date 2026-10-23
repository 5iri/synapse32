#!/usr/bin/env bash
# Build the Linux 7.3 image with deferred native compiler installation.
# Inputs: a generated board baseline image/config and the nativecc bundle.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
board="$(dirname "$here")"
repo="$(dirname "$(dirname "$board")")"
version=7.3
kernel="${LINUX_DIR:-$board/build/linux-$version}"
image="${NATIVECC_IMAGE_OUT:-$board/build/linux-image-$version-cpu62}"
base="${NATIVECC_BASE_IMAGE:-$board/build/linux-image-workloads-25hz-cpu62-vi}"
base_config="${NATIVECC_BASE_CONFIG:-$board/build/linux-workloads-25hz-cpu62-vi/.config}"
bundle="${NATIVECC_BUNDLE:-${NATIVECC_OUT:-$board/build/native-toolchain}/bundle}"
opensbi="${OPENSBI_DIR:-$board/build/opensbi}"
compiler="${KERNEL_CROSS_COMPILE:-$board/build/llvm-toolchain/riscv32-linux-gnu-}"
jobs="${BUILD_JOBS:-6}"
case "$jobs" in ''|*[!0-9]*) echo 'BUILD_JOBS must be an integer in 1..16' >&2; exit 1;; esac
[[ "$jobs" -ge 1 && "$jobs" -le 16 ]]
for tool in python3 make cc tar xz patch curl clang ld.lld llvm-ar llvm-nm llvm-objcopy; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
for path in "$base/initramfs.list" "$base/synapse32.dtb" "$base/synapse32.dts" "$bundle/opt/nativecc/bin/gcc" "$opensbi/Makefile"; do
    [[ -f "$path" ]] || { echo "Missing input: $path" >&2; exit 1; }
done
for tool in "${compiler}gcc" "${compiler}objcopy"; do
    command -v "$tool" >/dev/null || { echo "Missing cross tool: $tool" >&2; exit 1; }
done
mkdir -p "$image" "$(dirname "$kernel")"
image="$(cd "$image" && pwd)"
if [[ ! -f "$kernel/Makefile" ]]; then
    archive="$(dirname "$kernel")/linux-$version.tar.xz"
    if [[ ! -f "$archive" ]]; then
        curl --fail --location --retry 3 --connect-timeout 20 \
            -o "$archive.part" "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$version.tar.xz"
        mv "$archive.part" "$archive"
    fi
    python3 - "$archive" <<'PY'
from pathlib import Path
import hashlib,sys
h=hashlib.sha256()
with Path(sys.argv[1]).open('rb') as f:
    for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
assert h.hexdigest()=='87363c24f10e06321eb362765521094e94471f6bff8bce2d6b3e40f39f004953','Linux source SHA256 differs from its pin'
PY
    tar -xf "$archive" -C "$(dirname "$kernel")"
    if [[ "$(basename "$kernel")" != "linux-$version" ]]; then
        mv "$(dirname "$kernel")/linux-$version" "$kernel"
    fi
fi
kernel="$(cd "$kernel" && pwd)"
python3 - "$kernel/Makefile" <<'PYCHECK'
from pathlib import Path
import re,sys
text=Path(sys.argv[1]).read_text()
for key,value in [('VERSION','7'),('PATCHLEVEL','3'),('SUBLEVEL','0')]:
    found=re.search(r'^'+key+r'\s*=\s*(\S+)',text,re.M)
    if not found or found.group(1)!=value:
        raise SystemExit('Cached LINUX_DIR must contain Linux7.3.0; choose a separate directory')
PYCHECK
if ! grep -q '^config HZ_25$' "$kernel/kernel/Kconfig.hz"; then
    patch -d "$kernel" -p1 < "$repo/sim/linux-fpga-ticks.patch"
fi
if [[ ! -f "$kernel/.config" ]]; then
    [[ -f "$base_config" ]] || { echo "Missing baseline kernel config: $base_config" >&2; exit 1; }
    cp "$base_config" "$kernel/.config"
fi
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1792365298}"
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-Sun Oct 18 23:14:58 UTC 2026}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-synapse32}" KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-synapse32}"
export KBUILD_BUILD_VERSION="${KBUILD_BUILD_VERSION:-1}" LLVM=1
export PATH="$board/build/tools/usr/bin:$PATH"
# Compress the compiler separately. It is expanded by /init only after Linux
# has freed its embedded archive and init memory; direct cpio entries exceed RAM.
tar --sort=name --format=ustar --owner=0 --group=0 --numeric-owner --mtime="@$SOURCE_DATE_EPOCH" \
    -C "$bundle" -cf - opt | xz --threads=1 --check=crc32 --lzma2=dict=64KiB > "$image/nativecc.tar.xz"
python3 - "$base/initramfs.list" "$here/init" "$image" <<'PY'
from pathlib import Path
import shlex,shutil,sys
base,wrapper,out=Path(sys.argv[1]),Path(sys.argv[2]),Path(sys.argv[3]);lines=[];original=None
for line in base.read_text().splitlines():
    if not line.strip() or line.lstrip().startswith('#'):
        lines.append(line);continue
    w=shlex.split(line)
    if w and w[0]=='file' and w[1]=='/init':original=Path(w[2]);continue
    if w and (w[1].startswith('/opt/nativecc')or w[1]in ['/bin/gcc','/bin/cc','/bin/as','/bin/ld']):continue
    lines.append(line)
assert original and original.is_file(),'Baseline init binary is missing'
shutil.copyfile(original,out/'synapse-init');shutil.copyfile(wrapper,out/'init-nativecc.sh')
lines += [f'file /init {out}/init-nativecc.sh 0755 0 0',f'file /sbin/synapse-init {out}/synapse-init 0755 0 0',f'file /nativecc.tar.xz {out}/nativecc.tar.xz 0644 0 0']
lines += [f'slink /bin/{n} ../opt/nativecc/bin/{n} 0777 0 0'for n in ['gcc','cc','as','ld']]
(out/'initramfs.list').write_text('\n'.join(lines)+'\n')
PY
cc -O2 -o "$image/gen_init_cpio" "$kernel/usr/gen_init_cpio.c"
"$image/gen_init_cpio" "$image/initramfs.list" > "$image/initramfs.cpio"
xz --threads=1 --check=crc32 --lzma2=dict=64KiB -k -f "$image/initramfs.cpio"
cp "$base/synapse32.dtb" "$image/synapse32.dtb"
cp "$base/synapse32.dts" "$image/synapse32.dts"
"$kernel/scripts/config" --file "$kernel/.config" --set-str INITRAMFS_SOURCE "$image/initramfs.cpio.xz" \
    --enable BLK_DEV_INITRD --enable INITRAMFS_COMPRESSION_XZ --disable INITRAMFS_COMPRESSION_GZIP \
    --enable DECOMPRESS_XZ --enable CC_OPTIMIZE_FOR_SIZE --disable CC_OPTIMIZE_FOR_PERFORMANCE \
    --disable LOCALVERSION_AUTO --enable 32BIT --enable MMU --enable HZ_25
for symbol in 64BIT SMP FPU RISCV_ISA_C RISCV_ISA_F RISCV_ISA_D RISCV_ISA_V HZ_12 HZ_50 HZ_100 HZ_250 HZ_300 HZ_1000 \
    DEBUG_ATOMIC_SLEEP DEBUG_BUGVERBOSE DEBUG_MEMORY_INIT DEBUG_MUTEXES DEBUG_PAGEALLOC DEBUG_RT_MUTEXES \
    DEBUG_RWSEMS DEBUG_SG DEBUG_SPINLOCK DEBUG_VM DEBUG_VM_IRQSOFF DEBUG_VM_PGFLAGS LOCKUP_DETECTOR \
    RCU_EQS_DEBUG SCHED_STACK_END_CHECK SLUB_DEBUG SOFTLOCKUP_DETECTOR STACKDEPOT; do
    "$kernel/scripts/config" --file "$kernel/.config" --disable "$symbol"
done
make -C "$kernel" ARCH=riscv CROSS_COMPILE="$compiler" olddefconfig
python3 - "$kernel/.config" <<'PYCHECK'
from pathlib import Path
import sys
lines=set(Path(sys.argv[1]).read_text().splitlines())
for expected in ['CONFIG_32BIT=y','CONFIG_MMU=y','CONFIG_HZ=25','CONFIG_HZ_25=y',
                 'CONFIG_CC_OPTIMIZE_FOR_SIZE=y','CONFIG_INITRAMFS_COMPRESSION_XZ=y']:
    if expected not in lines:raise SystemExit('Kernel configuration gate failed: '+expected)
for symbol in ['64BIT','SMP','FPU','RISCV_ISA_C','RISCV_ISA_V']:
    if 'CONFIG_'+symbol+'=y' in lines:raise SystemExit('Unsupported kernel configuration: '+symbol)
PYCHECK
make -C "$kernel" -j"$jobs" ARCH=riscv CROSS_COMPILE="$compiler" \
    KCFLAGS='-march=rv32ima_zicsr_zifencei -mabi=ilp32' KAFLAGS='-march=rv32ima_zicsr_zifencei -mabi=ilp32' Image
cp "$kernel/arch/riscv/boot/Image" "$image/Image"
cp "$kernel/vmlinux" "$image/vmlinux"
cp "$kernel/System.map" "$image/System.map"
cp "$kernel/.config" "$image/kernel.config"
make -C "$opensbi" -j"$jobs" O="$image/opensbi-build" PLATFORM=generic FW_PAYLOAD=y \
    FW_PAYLOAD_PATH="$image/Image" FW_FDT_PATH="$image/synapse32.dtb" FW_TEXT_START=0x80000000 \
    FW_PAYLOAD_ALIGN=0x400000 PLATFORM_RISCV_XLEN=32 PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei \
    PLATFORM_RISCV_ABI=ilp32 CROSS_COMPILE="$compiler" \
    'platform-cflags-y=-Wno-error=unused-but-set-global -Wno-unknown-warning-option'
cp "$image/opensbi-build/platform/generic/firmware/fw_payload.elf" "$image/fw_payload.elf"
"${compiler}objcopy" --change-addresses -0x80000000 -O binary "$image/fw_payload.elf" "$image/fw_payload.bin"
python3 - "$image/fw_payload.bin" <<'PY'
from pathlib import Path
import hashlib,sys
p=Path(sys.argv[1]);print(hashlib.sha256(p.read_bytes()).hexdigest(),p)
PY
