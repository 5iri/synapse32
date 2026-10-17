#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
riscv64-unknown-elf-gcc -march=rv32ima_zicsr_zifencei -mabi=ilp32 \
    -nostdlib -nostartfiles -Wl,-Ttext=0x80000000 -Wl,--no-relax -Wl,--build-id=none \
    -o build/posted_stores.elf tests/posted_stores.S
riscv64-unknown-elf-objcopy -O binary build/posted_stores.elf build/posted_stores.bin
python3 - <<'PY'
from pathlib import Path
raw=Path('build/posted_stores.bin').read_bytes()
assert len(raw)<=2048 and len(raw)%4==0, len(raw)
words=[int.from_bytes(raw[i:i+4],'little') for i in range(0,len(raw),4)]
words += [0x00000013]*(512-len(words))
Path('build/posted_stores.hex').write_text(''.join(f'{word:08x}\n' for word in words))
print(f'Posted-store program: {len(raw)} bytes')
PY
for depth in ${POSTED_TEST_DEPTHS:-1 4}; do
for fastmul in ${POSTED_TEST_FAST_MUL:-0 1}; do
    output="build/obj_posted_stores_${depth}_${fastmul}_fq${FETCH_QUEUE:-0}_lf${LOAD_FORWARDING:-0}_sa${FAST_STORE_ACK:-0}"
    verilator --binary --timing -Wno-fatal -j 4 -I../../rtl/include \
        --top-module tb_posted_stores -GDEPTH="$depth" -GFAST_MULTIPLY="$fastmul" -GFETCH_QUEUE="${FETCH_QUEUE:-0}" \
        -GLOAD_FORWARDING="${LOAD_FORWARDING:-0}" -GFAST_STORE_ACK="${FAST_STORE_ACK:-0}" --Mdir "$output" \
        tests/tb_posted_stores.sv synapse_ddr3_system.sv axi_word_bridge.sv physical_l1_cache.sv \
        ordered_write_buffer.sv fpga_perf_counters.sv sv32_bus_port.sv instruction_fetch_queue.sv \
        ../../rtl/riscv_cpu.v ../../rtl/execution_unit.v ../../rtl/memory_unit.v ../../rtl/writeback.v \
        ../../rtl/core_modules/*.v ../../rtl/pipeline_stages/*.v ../../rtl/mmu/sv32_tlb.v \
        > "build/posted-stores-${depth}-$fastmul-compile.log" 2>&1
    "$output/Vtb_posted_stores"
done
done
