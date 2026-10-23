# Compile C inside FPGA Linux

This optional toolchain runs on Synapse32 and produces RV32IMA/ILP32 Linux
programs. It adds GCC, the assembler and linker, musl headers, and static C
libraries. C++ tools and development libraries are omitted to save RAM.

The current bitstream exposes 64 MiB of DDR. The root filesystem and compiler
files share that RAM with Linux and the compiler's working memory. Start with
small C programs; the build and board tests record the measured memory budget.

[Board results](results.json) verify Linux **7.3.0**, GCC **12.4.0**, separate
translation units, 64-bit division and software floating-point/libm operations.
The hello-world compilation took **17.27 seconds** at 62.5 MHz. Linux reported
12,012 KiB available before the compiler tests and 11,808 KiB afterward.

The running session was recovered by resizing the RAM filesystem, disabling
fragmentation watermark boosting, setting a 1 MiB free-memory reserve, and
deleting the packed compiler archive. The revised startup wrapper includes
these steps, but its complete automatic boot has **not yet been tested**.

Once installed, use the FPGA console:

```sh
vi /tmp/hello.c
gcc -O2 /tmp/hello.c -o /tmp/hello
/tmp/hello
```

[examples/hello.c](examples/hello.c) is a minimal starting program. The toolchain
uses static linking, so the executable carries its C runtime and needs no
separate dynamic loader.

The toolchain is optional; the default boot and performance images keep their
existing contents. Files created in the current RAM filesystem are lost when
the FPGA is reset or powered off.

Build the toolchain on the host with:

```sh
make -C fpga/arty_a7_35t nativecc
```

This builds a private musl cross bootstrap, then native GCC 12.4.0 and binutils
2.44. It requires a host C/C++ compiler, GNU make/binutils, Python 3, git,
bison, flex, m4, patch, tar, gzip, xz, and curl. Set `QEMU_RISCV32` to an
installed RV32 user emulator if the existing board test copy is unavailable.
`BUILD_JOBS` defaults to four. `NATIVECC_OUT` selects a separate build directory;
use a fresh directory when changing the toolchain configuration.

To build the development payload, first generate a normal board Linux image
with the fixed BusyBox and a clock matching the programmed bitstream, then
select that image and its configured kernel as inputs. For the 62.5 MHz board:

```sh
LLVM=1 CPU_DIVIDE=16 BUILD_WORKLOADS=1 make -C fpga/arty_a7_35t linux
NATIVECC_BASE_IMAGE="$PWD/fpga/arty_a7_35t/build/linux-image" \
NATIVECC_BASE_CONFIG="$PWD/fpga/arty_a7_35t/build/linux/.config" \
  make -C fpga/arty_a7_35t linux-dev
```

The image builder pins the Linux 7.3 release archive by SHA256, retains RV32IMA
and the 25 Hz tick, and selects size optimization. It puts a separately packed
compiler archive in the initramfs. After Linux frees initialization memory,
`/init` raises the tmpfs capacity and extracts the compiler. Both XZ archives
use CRC32 and a 64 KiB dictionary. Output is
`build/linux-image-7.3-cpu62/fw_payload.bin`; the current prepared image is
recorded separately from the tested running session in the results file.

Sources and the bootstrap checkout are pinned in [sources.json](sources.json).
Downloads use bounded resumable ranges and are checked against SHA256 pins.
The generated `build/native-toolchain/initramfs.list` includes the compiler
under `/opt/nativecc` and the `gcc`, `cc`, `as`, and `ld` commands under `/bin`.
The bundle contains its license files and build inputs. Adding the fragment to
a kernel image also requires checking its **peak boot memory**, since the
embedded archive and unpacked files coexist until Linux frees init memory.

Test the native executables on the host:

```sh
python3 fpga/arty_a7_35t/tests/test_native_toolchain.py \
  --qemu /path/to/qemu-riscv32 \
  --prefix fpga/arty_a7_35t/build/native-toolchain/bundle/opt/nativecc
```

This exercises the native compiler, assembler and linker with unsupported
compressed and floating-point instructions disabled in QEMU. It checks C
headers, separate translation units, 64-bit arithmetic, software floating
point, and libm. Board memory use requires separate measurement.

To send a small source file to an already running board while its UART reader
remains open:

```sh
python3 fpga/arty_a7_35t/nativecc/deploy.py /dev/ttyUSB1 \
  --log fpga/arty_a7_35t/build/hardware-uart.log \
  --binary hello.c --destination /tmp/hello.c
```

Use the reader's actual log path and pause other console writers during the
transfer. The uploader uses BusyBox `rx`, CRC16 XMODEM-1K, and a final exact-size
SHA256 check. It retains the UART reader and restores the terminal settings.
