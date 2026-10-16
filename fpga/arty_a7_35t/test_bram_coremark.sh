#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/../.." && pwd)"
build="$here/build/bram-coremark"
mode="${1:-test}"
mkdir -p "$build"
case "$mode" in
    test) hz=1000000;out="$build/sim-firmware";;
    --build-bitstream|--firmware-only) hz=50000000;out="$build/firmware50";;
    *) echo 'Usage: test_bram_coremark.sh [test|--firmware-only|--build-bitstream]' >&2;exit 1;;
esac
mkdir -p "$out"
CPU_CLOCK_HZ="$hz" UART_DIVISOR_SCALE=16 COREMARK_BAREMETAL_OUT="$out" \
    COREMARK_DIR="$here/build/coremark-source" \
    COREMARK_CC="${COREMARK_CC:-$here/build/llvm-toolchain/riscv32-linux-gnu-gcc}" \
    COREMARK_OBJCOPY="$here/build/llvm-toolchain/riscv32-linux-gnu-objcopy" \
    COREMARK_OBJDUMP=llvm-objdump \
    COREMARK_RUNTIME_ARCHIVE="$here/build/runtime/lib/linux/libclang_rt.builtins-riscv32.a" \
    bash "$repo/benchmarks/coremark/build_baremetal.sh" >"$out/build.log" 2>&1
python3 - "$repo/benchmarks/coremark/baremetal/link.ld" "$out/bram.ld" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text().replace('LENGTH = 64M','LENGTH = 128K').replace('__bss_end + 0x10000','__bss_end + 0x4000')
assert 'LENGTH = 128K' in s
Path(sys.argv[2]).write_text(s)
PY
compiler="${COREMARK_CC:-$here/build/llvm-toolchain/riscv32-linux-gnu-gcc}"
objects=()
for name in start core_list_join core_main core_matrix core_state core_util port ee_printf cvt;do objects+=("$out/$name.o");done
"$compiler" -O3 -march=rv32ima_zicsr_zifencei -mabi=ilp32 -static -fno-pie -fno-pic \
    -nostdlib -Wl,-T,"$out/bram.ld" -Wl,--no-relax -Wl,--gc-sections -Wl,--build-id=none \
    "${objects[@]}" -Wl,--start-group -lc "$here/build/runtime/lib/linux/libclang_rt.builtins-riscv32.a" \
    -Wl,--end-group -o "$out/coremark-bram.elf"
"$here/build/llvm-toolchain/riscv32-linux-gnu-objcopy" -O binary "$out/coremark-bram.elf" "$out/coremark-bram.bin"
llvm-objdump -d "$out/coremark-bram.elf" >"$out/coremark-bram.dis"
python3 - "$out/coremark-bram.bin" "$out/coremark_bram.mem" <<'PY'
from pathlib import Path
import sys
b=Path(sys.argv[1]).read_bytes()
assert len(b)<128*1024
b+=bytes(128*1024-len(b))
Path(sys.argv[2]).write_text(''.join(f'{int.from_bytes(b[i:i+4],"little"):08x}\n' for i in range(0,len(b),4)))
PY
sha256sum "$out/coremark-bram.elf" "$out/coremark-bram.bin" "$out/coremark_bram.mem"
if [[ "$mode" == --firmware-only ]];then exit 0;fi
if [[ "$mode" == --build-bitstream ]];then
    BRAM_MEM_FILE="$out/coremark_bram.mem" vivado -mode batch -nojournal -source "$here/build_bram_coremark.tcl" >"$build/vivado.log" 2>&1
    exit 0
fi
rtl=("$repo"/rtl/*.v "$repo"/rtl/core_modules/*.v "$repo"/rtl/pipeline_stages/*.v)
verilator --binary --timing --assert -j "${JOBS:-4}" -Wno-fatal --top-module tb_bram_coremark \
    --Mdir "$build/obj_sim" -I"$repo/rtl/include" \
    "-DBRAM_BOOT_FILE=\"$out/coremark_bram.mem\"" \
    "$here/tests/tb_bram_coremark.sv" "$here/bram_coremark_system.sv" "${rtl[@]}" \
    >"$build/verilator-build.log" 2>&1 || { tail -n 70 "$build/verilator-build.log" >&2;exit 1; }
"$build/obj_sim/Vtb_bram_coremark" | tee "$build/sim.log"
