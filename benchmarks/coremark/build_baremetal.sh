#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
platform_dir="${COREMARK_PLATFORM_DIR:-$here/baremetal}"
source_dir="${COREMARK_DIR:-$here/build/source}"
output="${COREMARK_BAREMETAL_OUT:-$here/build/baremetal}"
compiler="${COREMARK_CC:-riscv32-unknown-elf-gcc}"
cpu_clock="${CPU_CLOCK_HZ:-50000000}"
case "$cpu_clock" in ''|*[!0-9]*) echo 'CPU_CLOCK_HZ must be an integer' >&2; exit 1;; esac
test "$cpu_clock" -ge 1000 && test "$((cpu_clock%1000))" -eq 0
mkdir -p "$output/port" "$output/linux-reference/port"
revision=b56889a7bd9d5624fbeff2a73ba69878e6a9c146
if [ ! -d "$source_dir/.git" ]; then
    git clone https://github.com/eembc/coremark.git "$source_dir"
    git -C "$source_dir" checkout --detach "$revision"
fi
test "$(git -C "$source_dir" rev-parse HEAD)" = "$revision"
git -C "$source_dir" diff --exit-code HEAD -- . >/dev/null
(cd "$source_dir" && md5sum -c coremark.md5)
cp "$source_dir/posix/core_portme.h" "$source_dir/posix/core_portme_posix_overrides.h" "$output/linux-reference/port/"
uart_scale="${UART_DIVISOR_SCALE:-1}"
case "$uart_scale" in 1|16) ;; *) echo 'UART_DIVISOR_SCALE must be 1 or 16' >&2; exit 1;; esac
objcopy="${COREMARK_OBJCOPY:-riscv32-unknown-elf-objcopy}"
objdump="${COREMARK_OBJDUMP:-riscv32-unknown-elf-objdump}"
runtime="${COREMARK_RUNTIME_ARCHIVE:--lgcc}"
cp "$platform_dir/core_portme.h" "$output/port/"
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
for file in "$platform_dir/port.c" "$output/port/ee_printf.c" "$source_dir/barebones/cvt.c"; do
    name="$(basename "$file" .c)"
    "$compiler" "${flags[@]}" -fno-builtin "-DCPU_CLOCK_HZ=$cpu_clock" "-DUART_DIVISOR_SCALE=$uart_scale" "-DFLAGS_STR=\"$flags_str\"" \
        -I"$output/port" -I"$source_dir" -c "$file" -o "$output/$name.o"
    objects+=("$output/$name.o")
done
"$compiler" "${flags[@]}" -c "$platform_dir/start.S" -o "$output/start.o"
"$compiler" "${flags[@]}" -nostdlib -Wl,-T,"${COREMARK_LINKER_SCRIPT:-$platform_dir/link.ld}" -Wl,--no-relax \
    -Wl,--gc-sections -Wl,--build-id=none "$output/start.o" "${objects[@]}" \
    -Wl,--start-group -lm -lc "$runtime" -Wl,--end-group \
    -o "$output/coremark.elf"
"$objcopy" -O binary "$output/coremark.elf" "$output/coremark.bin"
"$objdump" -d "$output/coremark.elf" > "$output/coremark.dis"
python3 - "$output/coremark.dis" <<'PY'
from pathlib import Path
import re, sys
if re.search(r'\becall\b',Path(sys.argv[1]).read_text()):
    raise SystemExit('Unexpected OS syscall in bare-metal executable')
PY
printf '%s\n' "$flags_str" > "$output/compiler-flags.txt"
printf '%s\n' "$cpu_clock" > "$output/cpu-clock-hz.txt"
printf '%s\n' "$revision" > "$output/source-revision.txt"
"$compiler" --version > "$output/compiler-version.txt"
# Check that platform-header differences did not change the timed algorithms.
for name in core_list_join core_matrix core_state core_main; do
    "$compiler" "${flags[@]}" '-Dmain=coremark_main' "-DFLAGS_STR=\"$flags_str\"" \
        -I"$output/linux-reference/port" -I"$source_dir" -c "$source_dir/$name.c" -o "$output/$name-linux.o"
done
python3 - "$output" "$objdump" "$objcopy" <<'PY'
from pathlib import Path
import subprocess, sys
out=Path(sys.argv[1])
checks=[]
for name in ['core_list_join', 'core_matrix', 'core_state']:
    dis=[]
    for suffix in ['-linux.o', '.o']:
        dis.append('\n'.join(subprocess.check_output([sys.argv[2],'-d',str(out/(name+suffix))],text=True).splitlines()[3:]))
    assert dis[0]==dis[1], name+' timed algorithm differs'
    checks.append(name+': identical object instructions')
for suffix in ['-linux', '']:
    subprocess.run([sys.argv[3],'--dump-section',f'.text.iterate={out}/iterate{suffix}.text',str(out/f'core_main{suffix}.o')],check=True)
assert (out/'iterate-linux.text').read_bytes()==(out/'iterate.text').read_bytes(), 'iterate differs'
checks.append('iterate: identical object instruction bytes before link relocation')
(out/'object-code-check.txt').write_text('\n'.join(checks)+'\n')
print('\n'.join(checks))
PY
sha256sum "$output/coremark.elf" "$output/coremark.bin"
python3 - "$output/coremark.bin" "$output/coremark.hex" <<'PY'
from pathlib import Path
import sys
raw=Path(sys.argv[1]).read_bytes()
raw+=bytes(-len(raw)%4)
Path(sys.argv[2]).write_text(''.join(f'{int.from_bytes(raw[i:i+4], "little"):08x}\n' for i in range(0,len(raw),4)))
PY
