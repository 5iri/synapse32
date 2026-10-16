#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
source_root="${FETCH_SOURCE_ROOT:-$(realpath ../..)}"
if [ -n "${FETCH_BASELINE_COMMIT:-}" ]; then
    source_root="$PWD/build/fetch-baseline-source"
    python3 - "$source_root" "$FETCH_BASELINE_COMMIT" <<'PY'
from pathlib import Path
import hashlib,json,subprocess,sys
out=Path(sys.argv[1]);git=['git','-C',str(Path('../..').resolve())]
revision=subprocess.check_output(git+['rev-parse',sys.argv[2]],text=True).strip()
paths=subprocess.check_output(git+['ls-tree','-r',revision,'--name-only'],text=True).splitlines()
board=['synapse_ddr3_system.sv','axi_word_bridge.sv','physical_l1_cache.sv',
       'ordered_write_buffer.sv','fpga_perf_counters.sv','sv32_bus_port.sv','instruction_fetch_queue.sv']
selected=[p for p in paths if (p.startswith('rtl/') and p.endswith(('.v','.vh'))) or
          p in ['fpga/arty_a7_35t/'+name for name in board]]
hashes={}
for path in selected:
    raw=subprocess.check_output(git+['show',f'{revision}:{path}'])
    target=out/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(raw)
    hashes[path]=hashlib.sha256(raw).hexdigest()
(out/'source-manifest.json').write_text(json.dumps({'commit':revision,'sha256':hashes},indent=2)+'\n')
print('Immutable baseline source:',revision)
PY
fi
cat > build/fetch-throughput.S <<'ASM'
.section .text
.globl _start
_start:
    li t6, 0
    li t0, 5
    li a0, 0
    j loop
.balign 256
loop:
.rept 64
    addi a0, a0, 1
.endr
    addi t6, t6, 1
    addi t0, t0, -1
    bnez t0, loop
    li s0, 0x10000000
    sw a0, 0(s0)
    li t1, 0x600d
    sw t1, 4(s0)
    fence rw, rw
1:  j 1b
ASM
riscv64-unknown-elf-gcc -march=rv32ima_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles \
    -Wl,-Ttext=0x80000000 -Wl,--no-relax -Wl,--build-id=none -o build/fetch-throughput.elf build/fetch-throughput.S
riscv64-unknown-elf-objcopy -O binary build/fetch-throughput.elf build/fetch-throughput.bin
python3 - <<'PY'
from pathlib import Path
raw=Path('build/fetch-throughput.bin').read_bytes();assert len(raw)<=1024 and len(raw)%4==0
words=[int.from_bytes(raw[i:i+4],'little') for i in range(0,len(raw),4)]
words += [0x00000013]*(256-len(words))
Path('build/fetch-throughput.hex').write_text(''.join(f'{word:08x}\n' for word in words))
PY
queue="${FETCH_QUEUE:-0}"
tag="${FETCH_TEST_TAG:-q$queue}"
src_board="$source_root/fpga/arty_a7_35t"
defines=()
extra=()
if rg -q 'FETCH_QUEUE[[:space:]]*=' "$src_board/synapse_ddr3_system.sv"; then
    defines+=(-DFETCH_QUEUE_INTERFACE)
elif [ "$queue" != 0 ]; then
    echo 'FETCH_QUEUE=1 requires a source tree exposing the feature parameter.' >&2; exit 1
fi
if [ -f "$src_board/instruction_fetch_queue.sv" ]; then extra+=("$src_board/instruction_fetch_queue.sv"); fi
verilator --binary --timing -Wno-fatal -j 4 -I"$source_root/rtl/include" \
    --top-module tb_fetch_throughput -GFETCH_QUEUE="$queue" -GEXPECT_INTERVAL="${EXPECT_INTERVAL:-0}" \
    "${defines[@]}" --Mdir "build/obj_fetch_throughput_$tag" \
    tests/tb_fetch_throughput.sv "$src_board/synapse_ddr3_system.sv" "$src_board/axi_word_bridge.sv" \
    "$src_board/physical_l1_cache.sv" "$src_board/ordered_write_buffer.sv" "$src_board/fpga_perf_counters.sv" \
    "$src_board/sv32_bus_port.sv" "${extra[@]}" \
    "$source_root/rtl/riscv_cpu.v" "$source_root/rtl/execution_unit.v" "$source_root/rtl/memory_unit.v" \
    "$source_root/rtl/writeback.v" "$source_root"/rtl/core_modules/*.v \
    "$source_root"/rtl/pipeline_stages/*.v "$source_root/rtl/mmu/sv32_tlb.v" \
    > "build/fetch-throughput-$tag-compile.log" 2>&1
"build/obj_fetch_throughput_$tag/Vtb_fetch_throughput" | tee "build/fetch-throughput-$tag.log"
python3 - "$source_root" "$tag" <<'PY'
from pathlib import Path
import hashlib,json,sys
root=Path(sys.argv[1]);tag=sys.argv[2]
lines=Path(f'build/fetch-throughput-{tag}.log').read_text().splitlines()
report=json.loads(next(line.split(' ',1)[1] for line in lines if line.startswith('S32_FETCH_THROUGHPUT ')))
names=['rtl/riscv_cpu.v','fpga/arty_a7_35t/synapse_ddr3_system.sv',
       'fpga/arty_a7_35t/sv32_bus_port.sv','fpga/arty_a7_35t/physical_l1_cache.sv',
       'fpga/arty_a7_35t/instruction_fetch_queue.sv']
report['source_sha256']={name:hashlib.sha256((root/name).read_bytes()).hexdigest()
                         for name in names if (root/name).exists()}
Path(f'build/fetch-throughput-{tag}.json').write_text(json.dumps(report,indent=2)+'\n')
PY
