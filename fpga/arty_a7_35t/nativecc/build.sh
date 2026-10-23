#!/usr/bin/env bash
# Build a native C compiler using an isolated RV32 musl C/C++ cross bootstrap.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
board="$(dirname "$here")"
toolroot="${NATIVECC_OUT:-$board/build/native-toolchain}"
jobs="${BUILD_JOBS:-4}"
case "$jobs" in ''|*[!0-9]*) echo 'BUILD_JOBS must be a positive integer' >&2; exit 1;; esac
test "$jobs" -ge 1 && test "$jobs" -le 16
for tool in git python3 make gcc g++ bison flex m4 patch tar gzip xz curl; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
mkdir -p "$toolroot"
toolroot="$(cd "$toolroot" && pwd)"
qemu="${QEMU_RISCV32:-$board/build/qemu-profile/usr/bin/qemu-riscv32-static}"
test -x "$qemu" || qemu="$(command -v qemu-riscv32 || true)"
test -n "$qemu" && test -x "$qemu" || { echo 'Set QEMU_RISCV32 to a qemu-riscv32 executable.' >&2; exit 1; }
mcm="$toolroot/musl-cross-make"
pin=5e8042e63de29f8473fc3b0b831a587ba284e1a8
if [ ! -d "$mcm/.git" ]; then
    git clone https://github.com/richfelker/musl-cross-make.git "$mcm"
    git -C "$mcm" checkout --detach "$pin"
fi
test "$(git -C "$mcm" rev-parse HEAD)" = "$pin" || {
    echo "musl-cross-make must be at $pin; choose a separate NATIVECC_OUT." >&2; exit 1;
}
git -C "$mcm" diff HEAD --quiet
python3 "$here/fetch_sources.py" "$mcm/sources"
cat > "$mcm/config.mak" <<EOF
TARGET = riscv32-linux-musl
GCC_VER = 12.4.0
BINUTILS_VER = 2.44
MUSL_VER = 1.2.5
GMP_VER = 6.3.0
MPFR_VER = 4.2.2
MPC_VER = 1.3.1
LINUX_VER =
OUTPUT = $toolroot/cross
COMMON_CONFIG += --disable-nls CFLAGS="-O2 -g0" CXXFLAGS="-O2 -g0 -std=gnu++11" LDFLAGS="-Wl,-s"
GCC_CONFIG_FOR_TARGET += --with-arch=rv32ima_zicsr_zifencei --with-abi=ilp32
GCC_CONFIG += --enable-languages=c,c++ --disable-lto --disable-plugin --disable-analyzer --disable-libquadmath --disable-libgomp --disable-libitm --disable-libatomic --disable-libsanitizer --disable-libssp --disable-libvtv --disable-decimal-float --disable-fixed-point
BINUTILS_CONFIG += --disable-gprofng --disable-gold --disable-plugins --without-debuginfod
EOF
make -C "$mcm" -j"$jobs" CXXFLAGS='-O2 -g0 -std=gnu++11' CXXFLAGS_FOR_BUILD='-O2 -g0 -std=gnu++11'
make -C "$mcm" -j"$jobs" CXXFLAGS='-O2 -g0 -std=gnu++11' CXXFLAGS_FOR_BUILD='-O2 -g0 -std=gnu++11' install

target=riscv32-linux-musl
cross="$toolroot/cross"
stage="$toolroot/native-stage"
export PATH="$cross/bin:$PATH"
export CC="$cross/bin/$target-gcc" CXX="$cross/bin/$target-g++"
export AR="$cross/bin/$target-ar" RANLIB="$cross/bin/$target-ranlib"
export CC_FOR_BUILD=gcc CXX_FOR_BUILD=g++
export CFLAGS='-Os -g0 -std=gnu11' CXXFLAGS='-Os -g0 -std=gnu++11' LDFLAGS='-static -s'
mkdir -p "$toolroot/obj-native-binutils" "$toolroot/obj-native-gcc" "$stage"
cd "$toolroot/obj-native-binutils"
if [ ! -f Makefile ]; then
    "$mcm/binutils-2.44/configure" --build="$(gcc -dumpmachine)" --host="$target" --target="$target" \
        --prefix=/opt/nativecc --with-sysroot=/opt/nativecc --disable-nls --disable-werror \
        --disable-gprofng --disable-gold --disable-plugins --without-debuginfod --disable-shared --enable-static
fi
# Libtool's -static permits a dynamic libc; -all-static produces static tools.
make -j"$jobs" MAKEINFO=true LDFLAGS='-all-static -s' all-binutils all-gas all-ld
make -j"$jobs" MAKEINFO=true DESTDIR="$stage" install-binutils install-gas install-ld
cd "$toolroot/obj-native-gcc"
if [ ! -f Makefile ]; then
    "$mcm/build/local/$target/src_gcc/configure" --build="$(gcc -dumpmachine)" --host="$target" --target="$target" \
        --prefix=/opt/nativecc --with-sysroot=/opt/nativecc --with-build-sysroot="$cross/$target" \
        --with-native-system-header-dir=/include --with-build-time-tools="$cross/$target/bin" \
        --with-arch=rv32ima_zicsr_zifencei --with-abi=ilp32 --with-specs='%{!shared:%{!r:-static}}' \
        --enable-languages=c --disable-bootstrap --disable-multilib --disable-nls --disable-lto \
        --disable-plugin --disable-analyzer --disable-checking --disable-libcc1 --disable-libstdcxx \
        --disable-libstdcxx-pch --disable-shared --disable-libquadmath --disable-libgomp --disable-libitm \
        --disable-libatomic --disable-libsanitizer --disable-libssp --disable-libvtv \
        --disable-decimal-float --disable-fixed-point --without-isl --disable-werror
fi
make -j"$jobs" MAKEINFO=true all-gcc
make -j"$jobs" MAKEINFO=true DESTDIR="$stage" install-gcc
prefix="$stage/opt/nativecc"
mkdir -p "$prefix/include" "$prefix/lib/gcc/$target/12.4.0"
tar -C "$cross/$target/include" --exclude=./c++ -cf - . | tar -C "$prefix/include" -xf -
for library in libc libm libpthread libcrypt libdl libresolv librt libutil libxnet; do
    cp -a "$cross/$target/lib/$library.a" "$prefix/lib/"
done
cp -a "$cross/$target/lib/"crt*.o "$prefix/lib/"
cp -a "$cross/lib/gcc/$target/12.4.0/"libgcc*.a "$cross/lib/gcc/$target/12.4.0/"crt*.o "$prefix/lib/gcc/$target/12.4.0/"
"$cross/bin/$target-strip" "$prefix/bin/gcc" "$prefix/libexec/gcc/$target/12.4.0/cc1" "$prefix/libexec/gcc/$target/12.4.0/collect2"
python3 "$here/package.py" --build-dir "$toolroot" --qemu "$qemu"
