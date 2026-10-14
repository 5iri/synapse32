# Synapse32 on Arty A7-35T

This target adds DDR3, an uncached sequential Sv32 walker, a 50 MHz CPU clock,
an AXI clock converter, iterative RV32M, and a UART loader to upstream Synapse32.
The board is the **Digilent Arty A7-35T, xc7a35ticsg324-1L**, with its 256 MiB DDR3.
Other boards require a new MIG configuration, clocking and pin constraints.

The CPU sees 64 MiB of unified main RAM. A separate 1 MiB scratch region occupies
the next MiB of physical DDR. UART, CLINT and PLIC accesses complete in the CPU
clock domain. The DDR controller uses a 325 MHz memory clock / 81.25 MHz UI clock;
its AXI interface crosses to the CPU through Vivado's asynchronous converter.

## Build and program

Vivado 2024.2 was used. Add `vivado` to PATH or set `VIVADO` in Make.
From the repository root:

```sh
make -C fpga/arty_a7_35t bitstream
make -C fpga/arty_a7_35t program
```

The first command generates MIG and AXI converter IP, synthesizes, places and
routes, checks setup/hold timing, critical CDC and bus skew, then writes
`fpga/arty_a7_35t/build/board/synapse32_linux.bit`. Reports and the Vivado project
are in `build/board/`. The second programs a connected A7-35T through JTAG;
configuration is volatile and must be repeated after power cycling.

Pins follow [Digilent's Arty-A7-35 master constraints](https://github.com/Digilent/digilent-xdc/blob/master/Arty-A7-35-Master.xdc).
DDR pins and timing come from the checked-in MIG `mig.prj` and its generated XDC.

## Build Linux

The payload combines OpenSBI 1.4, Linux 6.6.32, the device tree, and an initramfs
with BusyBox 1.36.1. It uses RV32IMA, Zicsr and Zifencei, with `ilp32` and no
compressed or hardware floating-point instructions. Linux begins at 0x80400000,
aligned to 4 MiB as required for RV32. OpenSBI begins at 0x80000000. The device
tree describes the 50 MHz timebase and 16550 input clock.

With an RV32 Linux GCC toolchain (including a soft-float userspace libc), an
OpenSBI cross compiler, `dtc`, `bc`, `bison`, `flex`, `cpio` and normal build tools:

```sh
make -C fpga/arty_a7_35t linux
```

The default compiler prefixes come from `sim/build_linux.sh`; override
`KERNEL_CROSS_COMPILE` and `OPENSBI_CROSS_COMPILE` as needed. An ELF-only RISC-V
compiler without a Linux libc cannot build BusyBox.

Alternatively, use LLVM/Clang, LLD, LLVM utilities, CMake and GNU RISC-V objcopy:

```sh
make -C fpga/arty_a7_35t llvm-toolchain
LLVM=1 make -C fpga/arty_a7_35t linux
```

`prepare_llvm.sh` builds compiler-rt and static RV32 musl 1.2.5 under `build/`;
it needs no root installation. Set `GNU_OBJCOPY` if your GNU RISC-V objcopy is
not on PATH. Source downloads require internet access. `SKIP_SOURCE_FETCH=1`
reuses already pinned Linux/OpenSBI/BusyBox checkouts. Both routes produce
`build/linux-image/fw_payload.bin` plus ELF, kernel Image, DTB and Verilog hex.

## Load and use

Connect the board's USB JTAG/UART port. Install Python's `pyserial` package, select
the Arty UART device (often `/dev/ttyUSB1`), then:

```sh
# Press/release the active-low RESET button before a new upload.
make -C fpga/arty_a7_35t upload PORT=/dev/ttyUSB1
```

The loader uses **1,000,000 baud**; after its acknowledgement, the uploader switches
to the **115200 baud** Linux console. For bitstreams built before this change,
pass `--baud 115200` to `upload.py`.

The loader writes the raw binary into DDR starting at 0x80000000, verifies CRC32,
replies `K`, and releases the CPU. The uploader then opens a 115200 8N1 console;
Ctrl+] exits. A rejected transfer replies `E` and requires a reset before retrying.
There is no boot ROM size limit on the kernel: the entire payload is streamed to
DDR while the CPU remains in reset. A transfer must finish within 64 MiB.

For an automated UART capture and shell check, reset the board and run:

```sh
make -C fpga/arty_a7_35t test-board PORT=/dev/ttyUSB1
```

This saves `build/hardware-uart.log`, waits up to ten minutes after uploading,
and requires a Linux shell to execute `echo FPGA_BOOT_OK; uname -a`. Only one
program can read the UART port at a time.

Arty jumper JP2 connects DTR to the processor RESET input. Opening or closing
the UART can reset the loaded image on this board. To retain the same
connection after a successful test:

```sh
python3 fpga/arty_a7_35t/test_board.py /dev/ttyUSB1 --keep-open
```

`--console-only` skips uploading and tests an already running Linux console.
If reopening the port resets your board, remove the processor-reset jumper JP2
or keep the existing connection open. See [Digilent's reference manual](https://media.digikey.com/pdf/Data%20Sheets/Digilent%20PDFs/Arty_A7_RM_Web.pdf).

The protocol is `S32!`, little-endian 32-bit padded payload length, payload, and
little-endian IEEE/zlib CRC32 over the padded payload. Length must be a multiple
of four. DDR writes must complete before the next UART byte; the loader rejects
an overrun. At 1 Mbaud the transfer rate is about 98 KiB/s; a 21 MiB payload
takes roughly 3.6 minutes. Keep the board powered throughout the transfer.

LED0 means clocks locked, LED1 DDR calibrated, LED2 image accepted / CPU running,
and LED3 a loader or fabric fault. On success, expect OpenSBI, Linux messages,
`Synapse32 Linux userspace is up.`, and a BusyBox `~ #` prompt.

## Kernel timer tick

The physical 100 Hz kernel starts but reports repeated soft lockups before
userspace. The board build defaults to **12 Hz**, which reached a BusyBox shell
and executed UART commands on hardware, while retaining the correct 50 MHz
hardware timebase. Build it with:

```sh
LLVM=1 make -C fpga/arty_a7_35t linux
```

The build applies `sim/linux-low-tick.patch` to the pinned Linux source and
verifies the resulting configuration. The shared simulator build retains its
100 Hz default; `KERNEL_HZ=100` overrides the board default for comparisons.
The uncached core is slow: Linux reaches the prompt about 131 seconds after
image acceptance. The boot-time BLAKE2s self-test can emit a soft-lockup warning,
but startup completes. The UART test spaces input bytes by 100 ms to avoid
overrunning this CPU; adjust `--input-delay` when investigating throughput.

Use `make ... program` before retrying a failed upload. A fresh machine needs
Vivado, the toolchain and build dependencies described above; generated
bitstreams, Linux images and full UART logs live in ignored `build/` directories.

## Memory and interrupts

| CPU physical address | Function |
| --- | --- |
| 0x80000000–0x83ffffff | Main RAM, DDR offset 0–64 MiB |
| 0x10000000–0x100fffff | Scratch RAM, DDR offset 64–65 MiB |
| 0x02000000 | Hart 0 MSIP (read/write bit 0, machine software interrupt) |
| 0x02004000 / 0x02004004 | mtimecmp low/high |
| 0x0200bff8 / 0x0200bffc | mtime low/high, increments at 50 MHz |
| 0x0c000000–0x0c3fffff | PLIC, UART source 1, M/S contexts |
| 0x20000000–0x20000fff | 16550 UART, register shift 2, 32-bit MMIO |

Sv32 walks fetch PTEs through the same DDR arbiter as normal memory accesses.
Both 4 KiB pages and 4 MiB superpages are supported, with U/S, SUM/MXR and
read/write/execute checks. Clear A/D bits cause page faults (Svade behavior).
There is no TLB or cache; SFENCE.VMA has no cached translations to invalidate,
and FENCE.I observes stores in the shared RAM. Redirected fetches cannot return
an old PC/context as a current instruction. Addresses above 4 GiB are rejected.
Unexpected physical addresses or failed AXI responses latch a fabric fault and
hold the CPU in reset.

## Verification

```sh
make -C fpga/arty_a7_35t test PYTHON=../../.venv/bin/python
make -C fpga/arty_a7_35t test-core PYTHON=../../.venv/bin/python
make -C fpga/arty_a7_35t test-phy
make -C fpga/arty_a7_35t test-linux
```

Install `tests/requirements.txt` in the chosen Python environment. Verilator
tests exercise stalled AXI channels, response errors, byte lanes, loads/stores,
LR/SC and AMOs, instruction modification, iterative multiply/divide, Sv32 data
and execute permissions, redirects, and serial framing/CRC. The PHY test uses
MIG's DDR3 component model and the asynchronous 50/81.25 MHz AXI converter.
It can take several minutes and emits extensive vendor diagnostics.

The Linux test preloads the binary into a byte-accurate AXI RAM model and decodes
the actual 16550 TX waveform. It uses the FPGA CPU, peripherals and sequential
Sv32 ports. This test does not model the DDR PHY or host image upload; those are
verified separately. It waits for a root shell, sends `echo FPGA_BOOT_OK` over
the RX waveform, and requires the command's output. See [validation results](VALIDATION.md).
The physical-board test on 2026-10-14 confirmed DDR calibration, a CRC-accepted
1 Mbaud image upload, OpenSBI, Linux startup and a BusyBox shell executing
`echo FPGA_BOOT_OK; uname -a` over UART with the 12 Hz kernel. See
[validation results](VALIDATION.md) for the captured evidence.

The CPU and walker intentionally issue one outstanding access at a time. This
keeps the A7-35T implementation small but makes Linux substantially slower than
a cached core. This target has no persistent storage or network peripheral;
the root filesystem is the embedded initramfs.
