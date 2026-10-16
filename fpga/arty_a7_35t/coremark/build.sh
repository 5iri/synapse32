#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
board="$(dirname "$here")"
source_dir="${COREMARK_DIR:-$board/build/coremark-source}"
output="${COREMARK_OUT:-$board/build/coremark}"
# The next upstream merge only fixes a comment typo in coremark.h without
# updating coremark.md5. Pin its parent so the entire published checksum passes.
revision=b56889a7bd9d5624fbeff2a73ba69878e6a9c146
compiler="${COREMARK_CC:-$board/build/llvm-toolchain/riscv32-linux-gnu-gcc}"
optimization="${COREMARK_OPT:--O3}"
case "$optimization" in -O2|-O3|-Os) ;; *) echo 'COREMARK_OPT must be -O2, -O3 or -Os' >&2; exit 1;; esac
if [ ! -d "$source_dir/.git" ]; then
    git clone https://github.com/eembc/coremark.git "$source_dir"
    git -C "$source_dir" checkout --detach "$revision"
fi
test "$(git -C "$source_dir" rev-parse HEAD)" = "$revision" || {
    echo "CoreMark source must be at $revision; choose COREMARK_DIR with a clean checkout." >&2; exit 1;
}
git -C "$source_dir" diff --exit-code HEAD -- . >/dev/null || {
    echo 'CoreMark source has local changes; refusing to benchmark modified algorithms.' >&2; exit 1;
}
(cd "$source_dir" && md5sum -c coremark.md5)
mkdir -p "$output/port"
cp "$source_dir/posix/core_portme.h" "$source_dir/posix/core_portme_posix_overrides.h" "$output/port/"
# Only the permitted platform timer is changed; benchmark algorithms stay intact.
sed 's/clock_gettime(CLOCK_REALTIME, _t)/clock_gettime(CLOCK_MONOTONIC, _t)/' \
    "$source_dir/posix/core_portme.c" > "$output/port/core_portme.c"
flags="$optimization -std=gnu11 -march=rv32ima_zicsr_zifencei -mabi=ilp32 -msmall-data-limit=0 -static -fno-pie -fno-pic -ffunction-sections -fdata-sections -DMEM_METHOD=MEM_STATIC -DITERATIONS=0 -DPERFORMANCE_RUN=1 -Wl,--gc-sections -Wl,--build-id=none -s"
"$compiler" "$optimization" -std=gnu11 -march=rv32ima_zicsr_zifencei -mabi=ilp32 \
    -msmall-data-limit=0 -static -fno-pie -fno-pic -ffunction-sections -fdata-sections \
    -DMEM_METHOD=MEM_STATIC -DITERATIONS=0 -DPERFORMANCE_RUN=1 \
    "-DFLAGS_STR=\"$flags\"" '-DMEM_LOCATION="DDR3, static data, Linux userspace"' \
    -I"$output/port" -I"$source_dir" \
    "$source_dir/core_list_join.c" "$source_dir/core_main.c" \
    "$source_dir/core_matrix.c" "$source_dir/core_state.c" \
    "$source_dir/core_util.c" "$output/port/core_portme.c" \
    -Wl,--gc-sections -Wl,--build-id=none -s -o "$output/coremark"
printf '%s\n' "$revision" > "$output/source-revision.txt"
printf '%s\n' "$flags" > "$output/compiler-flags.txt"
"$compiler" --version > "$output/compiler-version.txt"
sha256sum "$output/coremark"
echo "Built $output/coremark (command-line seeds and iteration count supported)"
