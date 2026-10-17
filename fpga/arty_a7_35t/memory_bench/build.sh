#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
board="$(dirname "$here")"
repo="$(cd -- "$board/../.." && pwd)"
clock="${CPU_CLOCK_HZ:-58823529}"
scale="${UART_DIVISOR_SCALE:-16}"
case "$clock" in ''|*[!0-9]*) echo 'CPU_CLOCK_HZ must be an integer >=1000' >&2;exit 1;;esac
test "$clock" -ge 1000
case "$scale" in 1|16) ;; *) echo 'UART_DIVISOR_SCALE must be 1 or 16' >&2;exit 1;;esac
out="${MEMORY_BENCH_OUT:-$board/build/memory-bench-$clock}"
source_dir="${COREMARK_DIR:-$board/build/coremark-source}"
compiler="${COREMARK_CC:-$board/build/llvm-toolchain/riscv32-linux-gnu-gcc}"
objcopy="${COREMARK_OBJCOPY:-$board/build/llvm-toolchain/riscv32-linux-gnu-objcopy}"
objdump="${COREMARK_OBJDUMP:-llvm-objdump}"
runtime="${COREMARK_RUNTIME_ARCHIVE:-$board/build/runtime/lib/linux/libclang_rt.builtins-riscv32.a}"
test -f "$source_dir/coremark.h" || { echo 'Build CoreMark once to populate the pinned source/toolchain cache.' >&2;exit 1; }
(cd "$source_dir" && md5sum -c coremark.md5)
mkdir -p "$out"
out="$(cd -- "$out" && pwd)"
cp "$repo/benchmarks/coremark/baremetal/port.c" "$out/base_port.c"
cp "$repo/benchmarks/coremark/baremetal/core_portme.h" "$out/core_portme.h"
python3 - "$source_dir/barebones/ee_printf.c" "$out/ee_printf.c" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
needle='#error "You must implement the method uart_send_char to use this file!\\n";'
assert needle in s
Path(sys.argv[2]).write_text(s.replace(needle,'extern void board_uart_putc(char); board_uart_putc(c);'))
PY
flags=(-O3 -std=gnu11 -march=rv32ima_zicsr_zifencei -mabi=ilp32 -msmall-data-limit=0
    -static -fno-pie -fno-pic -ffunction-sections -fdata-sections -fno-builtin)
for file in "$here/benchmark.c" "$out/ee_printf.c" "$source_dir/barebones/cvt.c";do
    name="$(basename "$file" .c)"
    "$compiler" "${flags[@]}" -DCPU_CLOCK_HZ="$clock" -DUART_DIVISOR_SCALE="$scale" \
        '-DFLAGS_STR="memory latency microbenchmarks -O3 RV32IMA"' \
        -I"$out" -I"$source_dir" -c "$file" -o "$out/$name.o"
done
"$compiler" "${flags[@]}" -c "$repo/benchmarks/coremark/baremetal/start.S" -o "$out/start.o"
"$compiler" "${flags[@]}" -nostdlib -Wl,-T,"$repo/benchmarks/coremark/baremetal/link.ld" \
    -Wl,--no-relax -Wl,--gc-sections -Wl,--build-id=none \
    "$out/start.o" "$out/benchmark.o" "$out/ee_printf.o" "$out/cvt.o" \
    -Wl,--start-group -lm -lc "$runtime" -Wl,--end-group -o "$out/memory-bench.elf"
"$objcopy" -O binary "$out/memory-bench.elf" "$out/memory-bench.bin"
"$objdump" -d "$out/memory-bench.elf" >"$out/memory-bench.dis"
if rg -q '\becall\b' "$out/memory-bench.dis";then echo 'Unexpected OS syscall in benchmark' >&2;exit 1;fi
printf '%s\n' "$clock" >"$out/cpu-clock-hz.txt"
printf '%s\n' "$scale" >"$out/uart-divisor-scale.txt"
printf '%s\n' "${flags[*]} -DCPU_CLOCK_HZ=$clock -DUART_DIVISOR_SCALE=$scale" >"$out/compiler-flags.txt"
"$compiler" --version >"$out/compiler-version.txt"
sha256sum "$here/benchmark.c" "$out/base_port.c" "$repo/benchmarks/coremark/baremetal/start.S" \
    "$repo/benchmarks/coremark/baremetal/link.ld" >"$out/source-hashes.txt"
sha256sum "$out/memory-bench.elf" "$out/memory-bench.bin"
