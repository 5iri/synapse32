#!/usr/bin/env bash
# Optional native LLVM + RV32 musl toolchain; no system installation or sudo.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
build="$here/build"
sysroot="$build/sysroot"
runtime="$build/runtime"
for tool in clang ld.lld llvm-ar llvm-ranlib llvm-config cmake make git; do
    command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }
done
objcopy="${GNU_OBJCOPY:-$(command -v riscv64-linux-gnu-objcopy || command -v riscv64-unknown-elf-objcopy || true)}"
test -x "$objcopy" || { echo 'Set GNU_OBJCOPY to a GNU RISC-V objcopy (Verilog image export needs it).' >&2; exit 1; }
mkdir -p "$build" "$sysroot" "$runtime" "$build/llvm-toolchain" "$build/musl-out"
if [ ! -d "$build/linux/.git" ]; then
    git clone --depth 1 --branch v6.6.32 https://github.com/gregkh/linux.git "$build/linux"
fi
if [ ! -d "$build/musl/.git" ]; then
    git clone --depth 1 --branch v1.2.5 https://github.com/ifduyue/musl.git "$build/musl"
fi
if [ ! -d "$build/llvm-project/.git" ]; then
    git clone --depth 1 --branch llvmorg-19.1.7 --filter=blob:none --sparse https://github.com/llvm/llvm-project.git "$build/llvm-project"
fi
git -C "$build/llvm-project" sparse-checkout set compiler-rt/lib/builtins compiler-rt/cmake llvm/cmake cmake
for source_ref in 'linux v6.6.32' 'musl v1.2.5' 'llvm-project llvmorg-19.1.7'; do
    read -r source ref <<< "$source_ref"
    test "$(git -C "$build/$source" rev-parse HEAD)" = "$(git -C "$build/$source" rev-parse "$ref^{commit}")" || {
        echo "Cached $source is not at $ref; choose a clean build directory." >&2; exit 1;
    }
done
make -C "$build/linux" ARCH=riscv INSTALL_HDR_PATH="$sysroot" headers_install
march='-march=rv32ima_zicsr_zifencei -mabi=ilp32'
cmake -S "$build/llvm-project/compiler-rt/lib/builtins" -B "$build/compiler-rt" \
    -DCMAKE_C_COMPILER=clang -DCMAKE_C_COMPILER_TARGET=riscv32-unknown-linux-gnu \
    -DCMAKE_C_FLAGS="$march -isystem $sysroot/include" \
    -DCMAKE_ASM_COMPILER=clang -DCMAKE_ASM_COMPILER_TARGET=riscv32-unknown-linux-gnu \
    -DCMAKE_ASM_FLAGS="--target=riscv32-unknown-linux-gnu $march" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON -DCOMPILER_RT_BAREMETAL_BUILD=ON \
    -DCMAKE_INSTALL_PREFIX="$runtime" -DLLVM_CONFIG_PATH="$(command -v llvm-config)"
cmake --build "$build/compiler-rt" -j "${JOBS:-8}"
cmake --install "$build/compiler-rt"
ln -sfn "$(clang -print-resource-dir)/include" "$runtime/include"
(
    cd "$build/musl-out"
    ../musl/configure --prefix="$sysroot" --disable-shared --target=riscv32 \
        CC="clang --target=riscv32-unknown-linux-gnu $march -fuse-ld=lld" \
        CROSS_COMPILE=llvm- LIBCC="$runtime/lib/linux/libclang_rt.builtins-riscv32.a"
    make -j "${JOBS:-8}"
    make install
)
cat > "$build/llvm-toolchain/riscv32-linux-gnu-gcc" <<EOF
#!/bin/sh
if [ "\$#" = 1 ] && [ "\$1" = -print-sysroot ]; then printf '%s\n' "$sysroot"; exit 0; fi
exec clang --target=riscv32-linux-gnu --gcc-toolchain="$sysroot" --sysroot="$sysroot" -resource-dir="$runtime" $march -fuse-ld=lld --rtlib=compiler-rt -isystem "$sysroot/include" -L"$sysroot/lib" -Qunused-arguments -Wno-ignored-optimization-argument "\$@"
EOF
for tool in ar nm ranlib strip readelf; do
    printf '#!/bin/sh\nexec llvm-%s "$@"\n' "$tool" > "$build/llvm-toolchain/riscv32-linux-gnu-$tool"
done
printf '#!/bin/sh\nexec "%s" "$@"\n' "$objcopy" > "$build/llvm-toolchain/riscv32-linux-gnu-objcopy"
chmod +x "$build/llvm-toolchain/"*
echo 'Toolchain ready. Run: LLVM=1 bash fpga/arty_a7_35t/build_linux.sh'
