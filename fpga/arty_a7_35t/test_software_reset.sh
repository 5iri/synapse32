#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
cat > build/software-reset-program.S <<'ASM'
.section .text
.global _start
_start:
 li s0,0x10000000
 li s1,0x20002000
 li t0,0x53333252
 li t1,0x53333253
 sw t1,0(s1)
 sb t0,0(s1)
 sh t0,0(s1)
 sw t0,4(s1)
 lw t2,0(s1)
 bnez t2,failed
 li t3,0x5eed
 sw t3,0(s0)
 li s2,0x20000000
 li t2,7
 sw t2,8(s2)
# Queue a real final console marker before the pending RAM stores. Drain only
# the first two bytes; the remaining16 fill the FIFO without overflowing it.
 li t2,82
 sw t2,0(s2)
90: lw t5,20(s2)
 andi t5,t5,64
 beqz t5,90b
 li t2,101
 sw t2,0(s2)
90: lw t5,20(s2)
 andi t5,t5,64
 beqz t5,90b
 li t2,115
 sw t2,0(s2)
 li t2,116
 sw t2,0(s2)
 li t2,97
 sw t2,0(s2)
 li t2,114
 sw t2,0(s2)
 li t2,116
 sw t2,0(s2)
 li t2,105
 sw t2,0(s2)
 li t2,110
 sw t2,0(s2)
 li t2,103
 sw t2,0(s2)
 li t2,32
 sw t2,0(s2)
 li t2,115
 sw t2,0(s2)
 li t2,121
 sw t2,0(s2)
 li t2,115
 sw t2,0(s2)
 li t2,116
 sw t2,0(s2)
 li t2,101
 sw t2,0(s2)
 li t2,109
 sw t2,0(s2)
 li t2,10
 sw t2,0(s2)
 li t4,1
 .set off,8
 .rept 29
 sw t4,off(s0)
 addi t4,t4,1
 .set off,off+4
 .endr
 li t4,30
 li t5,31
 li t6,32
 .balign 16
 sw t4,124(s0)
 sw t5,128(s0)
 sw t6,132(s0)
 sw t0,0(s1)
failed:
 li t2,0xbad
 sw t2,4(s0)
1:j 1b
ASM
cat > build/software-reset-final.S <<'ASM'
.section .text
.global _start
_start:
 li s0,0x10000000
 li t0,0x600d
 sw t0,4(s0)
 fence rw,rw
1:j 1b
ASM
for program in program final; do
 riscv64-unknown-elf-gcc -march=rv32ima_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles \
  -Wl,-Ttext=0x80000000 -Wl,--no-relax -Wl,--build-id=none -o "build/software-reset-$program.elf" "build/software-reset-$program.S"
 riscv64-unknown-elf-objcopy -O binary "build/software-reset-$program.elf" "build/software-reset-$program.bin"
done
python3 - <<'PY'
from pathlib import Path
for name in ['program','final']:
 raw=Path(f'build/software-reset-{name}.bin').read_bytes();assert len(raw)%4==0 and len(raw)<1020
 words=[int.from_bytes(raw[n:n+4],'little')for n in range(0,len(raw),4)];count=len(words);words+=[0x13]*(255-count);words+=[count]
 Path(f'build/software-reset-{name}.hex').write_text(''.join(f'{v:08x}\n'for v in words))
PY
for latency in ${RESET_TEST_LATENCIES:-2 20}; do
 verilator --binary --timing -Wno-fatal -j "${JOBS:-2}" -I../../rtl/include --top-module tb_software_reset \
  -DRESET_AXI_CYCLES="$latency" --Mdir "build/obj_software_reset_$latency" \
  tests/tb_software_reset.sv arty_ddr3_top.sv uart_boot_loader.sv synapse_ddr3_system.sv axi_word_bridge.sv \
  physical_l1_cache.sv ordered_write_buffer.sv fpga_perf_counters.sv sv32_bus_port.sv instruction_fetch_queue.sv \
  ../../rtl/riscv_cpu.v ../../rtl/execution_unit.v ../../rtl/memory_unit.v ../../rtl/writeback.v \
  ../../rtl/core_modules/*.v ../../rtl/pipeline_stages/*.v ../../rtl/mmu/sv32_tlb.v \
  > "build/software-reset-$latency-compile.log" 2>&1
 "build/obj_software_reset_$latency/Vtb_software_reset" | tee "build/software-reset-$latency.log"
done
