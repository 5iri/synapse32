#!/usr/bin/env bash
set -euo pipefail
board="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
sbi="${OPENSBI_DIR:-$board/build/opensbi}"
output="${RESET_SBI_TEST_OUT:-$board/build/reset-firmware-test}"
compiler="${RESET_SBI_TEST_CC:-$board/build/native-toolchain/cross/bin/riscv32-linux-musl-gcc}"
qemu="${QEMU_RISCV32:-$board/build/qemu-profile/usr/bin/qemu-riscv32-static}"
dtc="${DTC:-$board/build/linux-7.3/scripts/dtc/dtc}"
mkdir -p "$output"
"$dtc" -I dts -O dtb -o "$output/reset.dtb" "$board/../../sim/synapse32.dts"
# Removing the two nodes creates a fail-before/no-device reference DTB.
python3 - "$board/../../sim/synapse32.dts" "$output/no-reset.dts" <<'PY'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text()
for pattern in [r'\n\treset_control: reset-controller@20002000 \{.*?\n\t\};',
                r'\n\treboot \{.*?\n\t\};']:
    text, count = re.subn(pattern, '', text, flags=re.S)
    assert count == 1
Path(sys.argv[2]).write_text(text)
PY
"$dtc" -I dts -O dtb -o "$output/no-reset.dtb" "$output/no-reset.dts"
"$compiler" -O2 -ffreestanding -fno-builtin -ffunction-sections -fdata-sections \
    -static -Wl,--gc-sections -DCONFIG_FDT_RESET=1 -DCONFIG_FDT_REGMAP=1 \
    -I"$sbi/include" -I"$sbi/lib/utils/libfdt" -I"$sbi" \
    "$board/tests/test_sbi_reset_binding.c" \
    "$sbi/lib/sbi/sbi_string.c" "$sbi/lib/sbi/sbi_ecall_srst.c" \
    "$sbi/lib/utils/fdt/fdt_helper.c" "$sbi/lib/utils/reset/fdt_reset.c" \
    "$sbi/lib/utils/reset/fdt_reset_syscon.c" \
    "$sbi/lib/utils/regmap/regmap.c" "$sbi/lib/utils/regmap/fdt_regmap.c" \
    "$sbi/lib/utils/regmap/fdt_regmap_syscon.c" \
    "$sbi/lib/utils/libfdt/fdt.c" "$sbi/lib/utils/libfdt/fdt_ro.c" \
    "$sbi/lib/utils/libfdt/fdt_addresses.c" "$sbi/lib/utils/libfdt/fdt_check.c" \
    -o "$output/test_sbi_reset_binding" > "$output/compile.log" 2>&1
"$qemu" -cpu rv32,c=false,f=false,d=false,zfa=false "$output/test_sbi_reset_binding" "$output/no-reset.dtb" 0
"$qemu" -cpu rv32,c=false,f=false,d=false,zfa=false "$output/test_sbi_reset_binding" "$output/reset.dtb" 1
