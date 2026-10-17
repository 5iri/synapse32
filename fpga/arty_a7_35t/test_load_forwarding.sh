#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
cat > build/load-forwarding.S <<'ASM'
.option norelax
.section .text
.global _start
_start:
    li s0, 0x10000000
    addi t0, s0, 16
    sw t0, 0(s0)
    addi t0, s0, 32
    sw t0, 16(s0)
    sw s0, 32(s0)
    fence rw,rw
    li t6, 0
    li s1, 3
again:
    call dependent_block
    addi t6, t6, 1
    bne t6, s1, again
    call verify_forwarding
    li t0, 0x10000300
    sw s0, 0(t0)
    li t1, 0x600d
    sw t1, 4(t0)
    fence rw,rw
stop: j stop
.org 0x100
dependent_block:
.rept 64
    lw s0, 0(s0)
.endr
    ret
verify_forwarding:
    li a0, 0x10000400
    li a1, 0x10000420
    li t0, 0x8001ff80
    sw t0, 0(a0)
    li t0, 0x1234
    sw t0, 4(a0)
    la t0, loaded_jump_target
    sw t0, 8(a0)
    li t0, 0x55
    sw t0, 12(a0)
    fence rw,rw
    lb t0, 0(a0)
    addi t1, t0, 1
    sw t1, 0(a1)
    lbu t0, 0(a0)
    addi t1, t0, 1
    sw t1, 4(a1)
    lh t0, 2(a0)
    addi t1, t0, 1
    sw t1, 8(a1)
    lhu t0, 2(a0)
    addi t1, t0, 1
    sw t1, 12(a1)
    lw t0, 0(a0)
    sw t0, 16(a1)
    li t0, 0xdead
    lw t0, 4(a0)
    addi t1, t0, 3
    sw t1, 20(a1)
    li t2, 0x1234
    lw t0, 4(a0)
    beq t0, t2, loaded_branch_target
forwarding_failed: j forwarding_failed
loaded_branch_target:
    lw t0, 8(a0)
    jalr t6, 0(t0)
    j forwarding_failed
loaded_jump_target:
    lw t0, 12(a0)
    csrw mscratch, t0
    csrr t1, mscratch
    sw t1, 24(a1)
    lw t0, 4(a0)
    mul t1, t0, t0
    sw t1, 28(a1)
    ret
ASM
# Keep a fixed 256-word loader image, just like the fetch-cadence regression.
riscv64-unknown-elf-gcc -march=rv32ima_zicsr_zifencei -mabi=ilp32 \
    -nostdlib -nostartfiles -Wl,-Ttext=0x80000000 -Wl,--no-relax -Wl,--build-id=none \
    build/load-forwarding.S -o build/load-forwarding.elf
riscv64-unknown-elf-objcopy -O binary build/load-forwarding.elf build/load-forwarding.bin
python3 - <<'PY'
from pathlib import Path
b=Path('build/load-forwarding.bin').read_bytes()
assert len(b)<=1024
b=b.ljust(1024,b'\0')
Path('build/load-forwarding.hex').write_text('\n'.join(f'{int.from_bytes(b[i:i+4],"little"):08x}' for i in range(0,1024,4))+'\n')
PY
mode="${LOAD_FORWARDING:-0}"
interval="${EXPECT_INTERVAL:-3}"
extra=()
if [ "${LOAD_FORWARDING_INTERFACE:-0}" = 1 ]; then extra=(-DLOAD_FORWARDING_INTERFACE); fi
verilator --binary --timing -Wno-fatal -j "${JOBS:-2}" -I../../rtl/include \
    --top-module tb_load_forwarding --Mdir "build/obj_load_forwarding${mode}" \
    "${extra[@]}" -GLOAD_FORWARDING="$mode" -GEXPECT_INTERVAL="$interval" \
    tests/tb_load_forwarding.sv synapse_ddr3_system.sv axi_word_bridge.sv physical_l1_cache.sv \
    ordered_write_buffer.sv fpga_perf_counters.sv sv32_bus_port.sv instruction_fetch_queue.sv \
    ../../rtl/riscv_cpu.v ../../rtl/execution_unit.v ../../rtl/memory_unit.v ../../rtl/writeback.v \
    ../../rtl/core_modules/*.v ../../rtl/pipeline_stages/*.v ../../rtl/mmu/sv32_tlb.v \
    > "build/load-forwarding${mode}-compile.log" 2>&1 || { tail -n 60 "build/load-forwarding${mode}-compile.log" >&2; exit 1; }
"build/obj_load_forwarding${mode}/Vtb_load_forwarding"
