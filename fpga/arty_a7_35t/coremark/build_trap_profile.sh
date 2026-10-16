#!/usr/bin/env bash
# Optional OpenSBI-only diagnostic image. Existing kernels/rootfs/source stay intact.
# Reserved page: 0x803ff000. u32[0]=0x53335450, [1]=version 1,
# [2]=64 counters, [3]=single hart; [4..7]=last cause/PC/tval/mstatus;
# [8..11]=last misaligned load PC/tval and misaligned store PC/tval.
# u64 exception[n] is at page+0x40+8*n; interrupt[n] at page+0x140+8*n.
# Read low/high with BusyBox devmem ADDR 32. Causes 4/6: +0x60/+0x70.
# These instrumented images are for diagnosis, not benchmark score reporting.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
board="$(dirname "$here")"
original="$board/build/opensbi"
source="$board/build/opensbi-trap-profile"
prefix="$board/build/llvm-toolchain/riscv32-linux-gnu-"
export PATH="$board/build/tools/usr/bin:$PATH"
export LLVM=1
test -f "$original/lib/sbi/sbi_trap.c"
test "$(realpath -m "$source")" != "$(realpath "$original")"
if [ ! -d "$source" ]; then cp -a --reflink=auto "$original" "$source"; fi
python3 - "$source" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1])
header=source/'include/sbi/synapse_trap_profile.h'
header.write_text('''/* Optional single-hart M-mode trap diagnostic. Reserved by its paired DTB. */
#ifndef SYNAPSE_TRAP_PROFILE_H
#define SYNAPSE_TRAP_PROFILE_H
#include <sbi/sbi_types.h>
#define SYNAPSE_TRAP_PROFILE ((volatile u32 *)0x803ff000UL)
static inline void synapse_trap_profile_init(void)
{
    volatile u32 *p = SYNAPSE_TRAP_PROFILE;
    unsigned int i;
    for (i = 0; i < 144; ++i) p[i] = 0;
    p[1] = 1; /* layout version */
    p[2] = 64; /* 32 exceptions, then 32 interrupt counters; all u64 */
    p[3] = 1; /* single-hart diagnostic */
    p[0] = 0x53335450; /* S3TP: publish after initialization */
}
static inline void synapse_trap_profile_record(ulong cause, ulong epc,
                                              ulong tval, ulong status)
{
    volatile u32 *p = SYNAPSE_TRAP_PROFILE;
    ulong code = cause & ~(1UL << (__riscv_xlen - 1));
    unsigned int slot;
    u32 low;
    if (p[0] != 0x53335450 || code >= 32) return;
    slot = 16 + 2 * (code + ((cause >> (__riscv_xlen - 1)) ? 32 : 0));
    low = p[slot] + 1;
    p[slot] = low;
    if (!low) p[slot + 1] = p[slot + 1] + 1;
    p[4] = cause; p[5] = epc; p[6] = tval; p[7] = status;
    if (cause == 4) { p[8] = epc; p[9] = tval; }
    if (cause == 6) { p[10] = epc; p[11] = tval; }
}
#endif
''')
trap=source/'lib/sbi/sbi_trap.c'
text=trap.read_text()
if '#include <sbi/synapse_trap_profile.h>' not in text:
    text='#include <sbi/synapse_trap_profile.h>\n'+text
    needle='\tstruct sbi_trap_info trap;\n\n\tif (misa_extension(\'H\')) {'
    assert text.count(needle)==1
    text=text.replace(needle, '\tstruct sbi_trap_info trap;\n\n'
        '\tsynapse_trap_profile_record(mcause, regs->mepc, mtval, regs->mstatus);\n\n'
        '\tif (misa_extension(\'H\')) {', 1)
    trap.write_text(text)
init=source/'lib/sbi/sbi_init.c'
text=init.read_text()
if '#include <sbi/synapse_trap_profile.h>' not in text:
    text='#include <sbi/synapse_trap_profile.h>\n'+text
    needle='\tconst struct sbi_platform *plat = sbi_platform_ptr(scratch);\n\n\t/* Note: This has to be first thing in coldboot init sequence */'
    assert text.count(needle)==1
    text=text.replace(needle, '\tconst struct sbi_platform *plat = sbi_platform_ptr(scratch);\n\n'
        '\tsynapse_trap_profile_init();\n\n'
        '\t/* Note: This has to be first thing in coldboot init sequence */',1)
    init.write_text(text)
PY
for variant in 50 62; do
    if [ "$variant" = 50 ]; then
        base="$board/build/linux-image-25hz-profile"
        output="$board/build/linux-image-25hz-trap-profile"
    else
        base="$board/build/linux-image-25hz-cpu62-profile"
        output="$board/build/linux-image-25hz-cpu62-trap-profile"
    fi
    mkdir -p "$output"
    cp --reflink=auto "$base/Image" "$output/Image"
    dtc -I dtb -O dts -o "$output/synapse32.dts" "$base/synapse32.dtb"
    python3 - "$output/synapse32.dts" <<'PY'
from pathlib import Path
import sys
path=Path(sys.argv[1]); text=path.read_text()
assert 'reserved-memory {' not in text
node='''/ {
    reserved-memory {
        #address-cells = <1>;
        #size-cells = <1>;
        ranges;
        trap-profile@803ff000 {
            reg = <0x803ff000 0x1000>;
            no-map;
        };
    };
'''
assert text.count('/ {\n')==1
path.write_text(text+'\n'+node+'};\n')
PY
    dtc -I dts -O dtb -o "$output/synapse32.dtb" "$output/synapse32.dts"
    make -C "$source" -j"${BUILD_JOBS:-4}" O="$output/opensbi-build" \
        PLATFORM=generic FW_PAYLOAD=y FW_PAYLOAD_PATH="$output/Image" FW_FDT_PATH="$output/synapse32.dtb" \
        FW_TEXT_START=0x80000000 FW_PAYLOAD_ALIGN=0x400000 \
        PLATFORM_RISCV_XLEN=32 PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei PLATFORM_RISCV_ABI=ilp32 \
        CROSS_COMPILE="$prefix" \
        'platform-cflags-y=-Wno-error=unused-but-set-global -Wno-unknown-warning-option'
    cp "$output/opensbi-build/platform/generic/firmware/fw_payload.elf" "$output/fw_payload.elf"
    "${prefix}objcopy" --change-addresses -0x80000000 -O binary "$output/fw_payload.elf" "$output/fw_payload.bin"
    sha256sum "$base/Image" "$output/Image" "$output/fw_payload.bin" > "$output/build-hashes.txt"
    cat "$output/build-hashes.txt"
done
