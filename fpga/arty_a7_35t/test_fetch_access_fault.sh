#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
cat > build/fetch-fault.S <<'ASM'
.section .text
.globl _start
_start:
    la t0, trap
    csrw mtvec, t0
    li t3, 17
    li t4, 5
#if CASE == 0
    la t0, fault_target
    jr t0
#elif CASE == 1
    j branch_block
#else
    li t0, 0x10000080
    lw a0, 0(t0)
    j fail
#endif
.org 0x80
trap:
    csrr a0, mcause
    csrr a1, mepc
    csrr a2, mtval
#if CASE == 0
    li t1, 1
    bne a0, t1, fail
    la t1, fault_target
    bne a1, t1, fail
    bne a2, t1, fail
    j report
#else
    j fail
#endif
.org 0x130
branch_block:
    nop
    div t2, t3, t4
    nop
    j branch_target
wrong_path:
    ebreak
.org 0x200
branch_target:
    mv a0, t2
    li a1, 0
    li a2, 0
report:
    li t0, 0x10000000
    sw a0, 0(t0)
    sw a1, 4(t0)
    sw a2, 8(t0)
    li t1, 0x600d
    sw t1, 12(t0)
    fence rw, rw
1:  j 1b
fail:
    li t0, 0x10000000
    sw a0, 0(t0)
    sw a1, 4(t0)
    sw a2, 8(t0)
    li t1, 0xdead
    sw t1, 12(t0)
2:  j 2b
.org 0x400
fault_target:
    nop
    j fail
ASM
for kind in ${FETCH_FAULT_CASES:-0 1 2}; do
    riscv64-unknown-elf-gcc -DCASE="$kind" -march=rv32ima_zicsr_zifencei -mabi=ilp32 \
        -nostdlib -nostartfiles -Wl,-Ttext=0x80000000 -Wl,--no-relax -Wl,--build-id=none \
        -o "build/fetch-fault-$kind.elf" build/fetch-fault.S
    riscv64-unknown-elf-objcopy -O binary "build/fetch-fault-$kind.elf" "build/fetch-fault-$kind.bin"
    python3 - "$kind" <<'PY'
from pathlib import Path
import sys
kind=sys.argv[1];raw=Path(f'build/fetch-fault-{kind}.bin').read_bytes()
assert len(raw)<=2048 and len(raw)%4==0
words=[int.from_bytes(raw[i:i+4],'little') for i in range(0,len(raw),4)]
words += [0x00000013]*(512-len(words))
Path(f'build/fetch-fault-{kind}.hex').write_text(''.join(f'{word:08x}\n' for word in words))
PY
    output="build/obj_fetch_fault_$kind"
    verilator --binary --timing -Wno-fatal -j 4 -I../../rtl/include --top-module tb_fetch_access_fault \
        -GERROR_CASE="$kind" --Mdir "$output" tests/tb_fetch_access_fault.sv \
        synapse_ddr3_system.sv instruction_fetch_queue.sv axi_word_bridge.sv physical_l1_cache.sv \
        ordered_write_buffer.sv fpga_perf_counters.sv sv32_bus_port.sv \
        ../../rtl/riscv_cpu.v ../../rtl/execution_unit.v ../../rtl/memory_unit.v ../../rtl/writeback.v \
        ../../rtl/core_modules/*.v ../../rtl/pipeline_stages/*.v ../../rtl/mmu/sv32_tlb.v \
        > "build/fetch-fault-$kind-compile.log" 2>&1
    "$output/Vtb_fetch_access_fault" | tee "build/fetch-fault-$kind.log"
done
