#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
board="$(dirname "$here")"
source_dir="${COREMARK_DIR:-$board/build/coremark-source}"
output="${COREMARK_BAREMETAL_OUT:-$board/build/coremark-baremetal}"
compiler="${COREMARK_CC:-$board/build/llvm-toolchain/riscv32-linux-gnu-gcc}"
cpu_clock="${CPU_CLOCK_HZ:-62500000}"
case "$cpu_clock" in ''|*[!0-9]*) echo 'CPU_CLOCK_HZ must be an integer' >&2; exit 1;; esac
test "$cpu_clock" -ge 1000 && test "$((cpu_clock%1000))" -eq 0
mkdir -p "$output/port"
# Reuse the pinned, clean official source and checksum checks of the Linux build.
COREMARK_OUT="$output/linux-reference" COREMARK_OPT=-O3 bash "$here/build.sh" > "$output/linux-reference-build.log"
cp "$here/baremetal/core_portme.h" "$output/port/"
python3 - "$source_dir/barebones/ee_printf.c" "$output/port/ee_printf.c" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
needle='#error "You must implement the method uart_send_char to use this file!\\n";'
assert needle in s
s=s.replace(needle,'extern void board_uart_putc(char); board_uart_putc(c);')
Path(sys.argv[2]).write_text(s)
PY
flags=(-O3 -std=gnu11 -march=rv32ima_zicsr_zifencei -mabi=ilp32 -msmall-data-limit=0
    -static -fno-pie -fno-pic -ffunction-sections -fdata-sections
    -DMEM_METHOD=MEM_STATIC -DITERATIONS=0 -DPERFORMANCE_RUN=1)
flags_str="${flags[*]} -nostdlib -Wl,--gc-sections -Wl,--build-id=none"
objects=()
for name in core_list_join core_main core_matrix core_state core_util; do
    "$compiler" "${flags[@]}" '-Dmain=coremark_main' "-DFLAGS_STR=\"$flags_str\"" \
        -I"$output/port" -I"$source_dir" -c "$source_dir/$name.c" -o "$output/$name.o"
    objects+=("$output/$name.o")
done
for file in "$here/baremetal/port.c" "$output/port/ee_printf.c" "$source_dir/barebones/cvt.c"; do
    name="$(basename "$file" .c)"
    "$compiler" "${flags[@]}" -fno-builtin "-DCPU_CLOCK_HZ=$cpu_clock" "-DFLAGS_STR=\"$flags_str\"" \
        -I"$output/port" -I"$source_dir" -c "$file" -o "$output/$name.o"
    objects+=("$output/$name.o")
done
"$compiler" "${flags[@]}" -c "$here/baremetal/start.S" -o "$output/start.o"
"$compiler" "${flags[@]}" -nostdlib -Wl,-T,"$here/baremetal/link.ld" -Wl,--no-relax \
    -Wl,--gc-sections -Wl,--build-id=none "$output/start.o" "${objects[@]}" \
    -Wl,--start-group -lc "$board/build/runtime/lib/linux/libclang_rt.builtins-riscv32.a" -Wl,--end-group \
    -o "$output/coremark.elf"
"$board/build/llvm-toolchain/riscv32-linux-gnu-objcopy" -O binary "$output/coremark.elf" "$output/coremark.bin"
llvm-objdump -d "$output/coremark.elf" > "$output/coremark.dis"
if rg -q '\becall\b' "$output/coremark.dis"; then
    echo 'Unexpected OS syscall in bare-metal executable' >&2; exit 1
fi
printf '%s\n' "$flags_str" > "$output/compiler-flags.txt"
printf '%s\n' "$cpu_clock" > "$output/cpu-clock-hz.txt"
cp "$output/linux-reference/source-revision.txt" "$output/source-revision.txt"
"$compiler" --version > "$output/compiler-version.txt"
# Check that platform-header differences did not change the timed algorithms.
for name in core_list_join core_matrix core_state core_main; do
    "$compiler" "${flags[@]}" '-Dmain=coremark_main' "-DFLAGS_STR=\"$flags_str\"" \
        -I"$output/linux-reference/port" -I"$source_dir" -c "$source_dir/$name.c" -o "$output/$name-linux.o"
done
python3 - "$output" <<'PY'
from pathlib import Path
import subprocess, sys
out=Path(sys.argv[1])
checks=[]
for name in ['core_list_join', 'core_matrix', 'core_state']:
    dis=[]
    for suffix in ['-linux.o', '.o']:
        dis.append('\n'.join(subprocess.check_output(['llvm-objdump','-d',str(out/(name+suffix))],text=True).splitlines()[3:]))
    assert dis[0]==dis[1], name+' timed algorithm differs'
    checks.append(name+': identical object instructions')
for suffix in ['-linux', '']:
    subprocess.run(['llvm-objcopy','--dump-section',f'.text.iterate={out}/iterate{suffix}.text',str(out/f'core_main{suffix}.o')],check=True)
assert (out/'iterate-linux.text').read_bytes()==(out/'iterate.text').read_bytes(), 'iterate differs'
checks.append('iterate: identical object instruction bytes before link relocation')
(out/'object-code-check.txt').write_text('\n'.join(checks)+'\n')
print('\n'.join(checks))
PY
sha256sum "$output/coremark.elf" "$output/coremark.bin"
