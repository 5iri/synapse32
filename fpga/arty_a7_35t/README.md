# Synapse32 on Arty A7-35T

This target adds DDR3, a sequential Sv32 walker with upstream TLBs, a 50 MHz CPU clock,
an AXI clock converter, iterative RV32M, and a UART loader to upstream Synapse32.
The board is the **Digilent Arty A7-35T, xc7a35ticsg324-1L**, with its 256 MiB DDR3.
Other boards require a new MIG configuration, clocking and pin constraints.

The [triangulation visualizer](triangulator/README.md) runs a moving 2D mesh
workload under FPGA Linux and displays its results and timing in a laptop
browser. The Linux image includes `/bin/triangulator`; an uploader can also
install the small executable into a Linux session already running.
The [Linux workload suite](workloads/README.md) adds checked zlib compression,
decompression and SQLite operations, with pinned sources and repeatable reports.
Build its static executable with `make workloads`; set `BUILD_WORKLOADS=1` when
building Linux to include `/bin/workloads` in the initramfs.
The [CoreMark workflow](coremark/README.md) builds the official integer
benchmark for FPGA Linux; [physical performance results](coremark/RESULTS.md)
record validated scores and the TLB comparison.

The optional [native C development image](nativecc/README.md) adds GCC and
binutils that run inside FPGA Linux. Linux 7.3.0 and on-board C compilation,
linking, integer arithmetic and software floating-point tests have passed.

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

For Clang builds, the builder sets BusyBox's documented `-DBB_GLOBAL_CONST=`
workaround. Without it, BusyBox 1.36.1 can load its old globals pointer during
`vi` initialization and crash at address `0x24`. The fix covers all applets
using that pointer. GCC builds retain their existing configuration. The
[regression evidence](workloads/results/busybox-vi.json) includes the original
failure, corrected QEMU runs, and editing on the physical FPGA. To test a
rebuilt static BusyBox without a board:

```sh
python3 fpga/arty_a7_35t/tests/test_busybox_vi.py \
  --qemu /path/to/qemu-riscv32 \
  --busybox fpga/arty_a7_35t/build/linux-image/busybox-build/busybox
```

The test uses a PTY and checks startup, saved file bytes, reopening, changes,
undo, and exit status.

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

While that reader is running, type into Linux from a second **Linux host** terminal:

```sh
python3 fpga/arty_a7_35t/console.py /dev/ttyUSB1 --log fpga/arty_a7_35t/build/hardware-uart.log
```

Use the same `--log` path as the reader. This client tails its output and sends
keystrokes without reconfiguring the UART. Enter requests a prompt; Ctrl+C
interrupts a Linux command, and Ctrl+] detaches the client while leaving the
reader and loaded image running. Start with `uname -a`, `ls`, or `free`.
Add `--from-start` to show the saved boot output before following the live
terminal. When deliberately rebooting with the same log path, start the new
`test_board.py` reader with `--append-log` so an attached console continues to
see output without reopening its log.

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

## Reboot from Linux

Software reboot requires a reset-capable bitstream and its matching device
tree. The keyed reset register at `0x20002000` waits for older DDR stores and
the final UART output to drain, then resets the CPU, caches, peripherals and
UART loader. DDR calibration and clocking remain active. OpenSBI exposes this
through the standard SBI reset extension using a `syscon-reboot` binding.

Reset returns to the UART loader. The loaded kernel cannot simply be entered
again: Linux has reused initialization memory, and the design has no persistent
boot storage. To reload Linux automatically from the connected host, run:

```sh
python3 fpga/arty_a7_35t/test_board.py /dev/ttyUSB2 /path/to/matching/fw_payload.bin \
  --program-bitstream /path/to/reset-capable.bit \
  --baud 2000000 --input-delay 0.002 --timeout 1800 \
  --auto-reboot --append-log --log fpga/arty_a7_35t/build/reboot-linux.uart.log
```

This programs the bitstream once, uploads Linux, and retains the same UART
connection while watching for a verified kernel reboot request. A later
`reboot` inside Linux switches the reader back to loader speed and uploads the
same saved payload again, without a JTAG or DTR reset. The image bytes are frozen
when the reader starts, so a concurrent host rebuild cannot change that session's
kernel or clock configuration. Use the interactive console with this log path.
The updated console pauses keyboard transmission while the image is loading.

To enable reloads for Linux that is already running, use `--console-only
--auto-reboot` with the matching payload, omitting `--program-bitstream`.
Keep the host reader running for this workflow. Standalone Linux reboot needs a
separate reliable image source such as persistent storage or a protected RAM
copy. Files created in the RAM filesystem are lost on reset.

Older bitstreams have no software reset register: Linux prints “Restarting
system” and stops. Adding the reset device-tree node alone does not fix those
bitstreams; the hardware and image must be updated together.

The [software-reset validation record](results/software-reset.json) identifies
the matched bitstream and payload and records simulation, firmware, host and
physical timing checks. Its hardware-test status is separate from timing
acceptance; check that status before treating a build as board-validated.

## Kernel timer tick

The board build defaults to **25 Hz**, selected after testing 12, 25, 50 and
100 Hz on the TLB-equipped physical board. At 50 MHz, 25 Hz retains about 93%
of the 12 Hz CoreMark throughput while reducing the tick interval from about
83 ms to 40 ms. All four settings booted and passed CoreMark CRC validation;
100 Hz roughly halved throughput. The earlier uncached build needed 12 Hz
to avoid timer starvation. Build the current default with:

```sh
LLVM=1 make -C fpga/arty_a7_35t linux
```

The build applies `sim/linux-fpga-ticks.patch` for 25/50 Hz or
`sim/linux-low-tick.patch` for 12 Hz, and verifies the resulting configuration.
The shared simulator build retains its 100 Hz default. `KERNEL_HZ=12`, `50`
or `100` selects another board rate. The physical 50 MHz TLB build reaches
`/init` at about 79 seconds with 12 Hz and 148 seconds with 100 Hz. See the
[performance results](coremark/RESULTS.md) for the controlled workload tests.
The UART test retains a conservative 100 ms input spacing by default;
`--input-delay` can select a faster tested input rate.

### CPU clock profiles

The default CPU divider is 20: a 1 GHz MMCM VCO produces 50 MHz. Divider 17
produces about 58.82 MHz, 18 produces 55.56 MHz, and 16 produces 62.5 MHz.
The DDR memory and reference clocks stay unchanged. Clock limits depend on the
RTL configuration. The current tested profile uses divider 16,
with load forwarding enabled; the earlier store-path profile uses divider 17.
The builder checks setup/hold, clock methodology, DRC, critical CDC and AXI bus
skew. Physical benchmark acceptance is recorded separately from timing closure.

Use the same divider for hardware and Linux so UART and the CLINT timebase
match. Build the tested hardware configuration explicitly:

```sh
PERF_TAG=fetch-refill-div16 CPU_DIVIDE=16 BOOT_BAUD=2000000 \
  FAST_L1=1 ICACHE_LINES=256 DCACHE_LINES=256 STORE_BUFFER_DEPTH=8 \
  FAST_MULTIPLY=1 FETCH_QUEUE=1 LOAD_FORWARDING=1 FAST_STORE_ACK=1 \
  vivado -mode batch -nojournal -source fpga/arty_a7_35t/build_performance.tcl
```

The tested route uses the refinement below. Its initial route misses setup by
0.339 ns; refinement reuses the frozen checkpoint and constraints and passes
setup at +0.305 ns, hold at +0.017 ns, and pulse width at +0.206 ns.
Run it after the routed checkpoint exists, then build matching Linux and select
the refined bitstream:

```sh
PERF_TAG=fetch-refill-div16 vivado -mode batch -nojournal \
  -source fpga/arty_a7_35t/refine_performance.tcl
CPU_DIVIDE=16 KERNEL_HZ=25 LLVM=1 BUILD_WORKLOADS=1 make -C fpga/arty_a7_35t linux
vivado -mode batch -nojournal -source fpga/arty_a7_35t/program.tcl \
  -tclargs fpga/arty_a7_35t/build/performance/fetch-refill-div16/postopt/synapse32_fetch-refill-div16.bit
BOOT_BAUD=2000000 make -C fpga/arty_a7_35t test-board PORT=/dev/ttyUSB1
```

`BOOT_BAUD` controls only the payload loader; Linux still uses 115200 baud.
The Linux builder generates a matching device tree automatically unless
`DEVICE_TREE` is explicitly supplied. The full SoC simulator also uses
`CPU_DIVIDE` to select its UART framing. Clear these environment overrides
before building the conservative 50 MHz / 1 Mbaud profile.

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
| 0x20001000–0x20001fff | FPGA performance counters |

Sv32 walks fetch PTEs through the same DDR arbiter as normal memory accesses.
Both 4 KiB pages and 4 MiB superpages are supported, with U/S, SUM/MXR and
read/write/execute checks. Clear A/D bits cause page faults (Svade behavior).
Instruction and data ports each reuse the unmodified upstream eight-entry
`sv32_tlb` module. Hits skip the DDR page-table walk and recheck privilege,
SUM/MXR and A/D permissions. SFENCE.VMA and writes to satp flush both TLBs;
any satp change, including an ASID-only change, also invalidates them. A flush
during a walk prevents a stale refill, and pre-fence instruction responses are
discarded even when the PC is unchanged. The FPGA path now has separate 4 KiB
instruction and data caches. FENCE.I observes stores in the
shared RAM. Redirected fetches cannot return
an old PC/context as a current instruction. Addresses above 4 GiB are rejected.
Unexpected data/loader physical addresses or failed AXI responses latch a
fabric fault and hold the CPU in reset. With queued fetch enabled, instruction
access errors instead reach the CPU as precise instruction access faults.

### Instruction and data caches

The board defaults to `FAST_L1=1 STORE_BUFFER_DEPTH=8 FAST_MULTIPLY=1 FETCH_QUEUE=1`
and `LOAD_FORWARDING=0 FAST_STORE_ACK=1` at 50 MHz.
`FAST_L1=1` moves the physically tagged I/D caches onto independent synchronous
ports ahead of the shared bus arbiter. A hit returns in one cycle, including
while the other port waits for DDR. Each 4 KiB bank uses two RAMB36 blocks.
Translation and permission checks still precede access to cached data.

`FETCH_QUEUE=1` pipelines instruction-cache hits and fetches sequentially into
four reserved slots using a separate request PC. Warm straight-line code can
execute one instruction per cycle. Redirects and address-space changes cancel
younger fetches; instruction bus errors trap precisely if execution reaches
them. Speculative instruction reads never access MMIO. `FETCH_QUEUE=0` selects
the original serialized interface for comparisons. Run `make test-fetch` in
this directory for the fetch, fault and fence regressions; see the
[measured performance and reproduction commands](coremark/MEMORY_PERFORMANCE.md#queued-instruction-fetch).

With this path, `STORE_BUFFER_DEPTH=8` posts ordinary translated RAM stores
into an ordered queue. A store updates matching resident I/D lines when it
enters the queue; the queued write remains pending until its AXI response.
Misses, page walks, MMIO, fences and atomic operations wait for older stores.
A failed write latches the fabric fault and halts the CPU. There is no dirty
write-back cache state.

The pipelined instruction port registers its complete fill/snoop write stream
before committing to cache BRAM. Lookup forwarding merges the committing write
and newer incoming bytes, preserving store ordering without relying on BRAM
read-during-write behavior. Harmless reads run in available lookup slots;
architectural grants, responses and faults still honor immediate cancellation.
This separates the RAM controls from the late EX redirect without adding a
cache-hit cycle. `make test-fetch` covers canceled returns, ordered writes,
subword collisions, errors and reset in addition to the normal fetch tests.
The queue hides wrong-path instructions immediately, then sends a registered
cancellation and target to the port. A canceled local lookup can accept the
new target on that edge. Registered cancellation also withdraws an ungranted
lower request before arbitration, avoiding an unnecessary wrong-path DDR read;
an already granted lower read must first drain. A successful RAM read still
populates the physical I-cache when its instruction is canceled, so later
speculative fall-through lookups can hit without another DDR read. Canceled CPU
responses, faults and TLB fills remain suppressed. Every new fetch checks its
current translation and permissions before using those physical bytes.
Older posted stores drain before a lower read; new stores cannot enqueue
through its completion edge, and later stores snoop the pending cache fill.
An uncanceled instruction read returns on the lower completion cycle and can
grant the next lookup on that edge. A same-line successor uses fill forwarding;
an error returns one fault token and accepts no following request on that edge.
Instruction TLB flushes cross the same control boundary. This keeps late CPU
redirects out of fetch arbitration while retaining precise fault/PC tags.

`LOAD_FORWARDING=1` forwards completed ordinary load data from MEM to dependent
arithmetic, ordinary address computation and store data. EX waits for the
response. Branches, JALR and atomics retain a load-use interlock and use
registered control operands. A dependent ordinary load/store address also
interlocks while a data watchpoint is enabled; a store-data-only dependency
still uses the bypass. This keeps the completed load off the redirect and
trigger control paths. An older memory fault suppresses younger EX effects, including
privilege returns and WFI. `FAST_STORE_ACK=1` acknowledges a successful data-port
write on its completion cycle, removing the separate DONE cycle. Permission
checks, failures and queue/fence ordering retain their normal handling.
Both parameters default to zero in the reusable CPU/system and in the
performance-build script so comparisons must enable them explicitly. Run
`make test-memory-path` for the directed regressions and see the
[memory microbenchmark](memory_bench/README.md) for measurement commands.

The refined 62.5 MHz bitstream passes setup, hold, clock methodology,
DRC, critical CDC and bus-skew checks. Its bare-metal median is 114.811032
CoreMark, or 1.836977/MHz. Earlier full control-bypass attempts failed timing;
the selective interlocks above let the data bypass run at the higher clock.
See [the measured profile and complete validation evidence](coremark/results/fetch-refill-performance.json),
with historical configurations in [memory-path measurements](coremark/MEMORY_PERFORMANCE.md).

`FAST_MULTIPLY=1` uses four DSPs for two-cycle RV32 multiplication; division
remains iterative. The board build checks timing for each configuration.
The uncached BRAM baseline, matched AXI simulations, physical measurements
and profiling workflow are documented in
[memory-path measurements](coremark/MEMORY_PERFORMANCE.md).

`FAST_L1=0 STORE_BUFFER_DEPTH=0` selects the legacy serialized bridge path
described below for comparison.

`axi_word_bridge` implements a physically addressed, direct-mapped D-cache:
256 lines of 16 bytes, matching one DDR AXI beat per refill. Data-port RAM
reads (including its page-table walks) allocate D-cache lines. Actual
instruction fetches allocate a separate I-cache of the same size and line
geometry. Instruction page-table walks bypass both banks and do not allocate.
UART, timer, MSIP and PLIC accesses bypass the DDR bridge entirely.

Stores are write-through and do not allocate on a miss. Every RAM writer,
including uncached owners and the boot loader, updates matching lines in BOTH banks
after a successful AXI write response, respecting byte strobes. Completion is
reported only after that response, so there are no dirty lines or buffered
cache writes for FENCE to drain. FENCE.I still flushes the CPU's younger
instructions and discards stale fetch responses. Physical tags handle virtual aliases;
SFENCE.VMA flushes translations without needing to discard cached RAM data.
The single-hart LR/SC and AMO paths use the same serialized read/write path.
Failed refills never become valid; a failed write invalidates a matching line.
Reset clears validity without clearing the block-RAM data array. There is no
external DMA master or multi-hart cache-coherence protocol on this board.

`DCACHE_LINES` and `ICACHE_LINES` default to 256 throughout the board hierarchy. Set either to zero
for an uncached comparison, or another power of two to change capacity:

```sh
FAST_L1=0 STORE_BUFFER_DEPTH=0 FAST_MULTIPLY=0 DCACHE_LINES=0 ICACHE_LINES=0 make -C fpga/arty_a7_35t bitstream
FAST_L1=0 STORE_BUFFER_DEPTH=0 FAST_MULTIPLY=0 DCACHE_LINES=0 ICACHE_LINES=0 LINUX_SIM_BUILD=build/obj_linux_nocache bash fpga/arty_a7_35t/test_linux.sh /absolute/path/to/fw_payload.bin
bash fpga/arty_a7_35t/test_dcache.sh
```

Cache changes require rebuilding and programming the FPGA. The Linux image and
device tree do not need cache-specific changes. The initial 62.5 MHz bridge-cache
comparison improved Linux CoreMark from 0.058275 to 0.065954, with all 60 mesh
frames validated. Those early results precede the separate local L1 ports and
the benchmark-buffer alignment correction. See the
[historical comparison](coremark/RESULTS.md#data-cache-at-625-mhz) and the
[current measurements](coremark/MEMORY_PERFORMANCE.md).

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
An interactive-console stall was traced to CSR read-modify-write copying a
live UART interrupt into a sticky software-pending bit. The corrected CPU
preserves pending bits absent from the CSR operand; repeated physical-board
commands now succeed, including after a one-minute idle period. See the
validation notes for the interrupt capture and remaining runtime limitations.

The lower DDR bus accepts one outstanding transaction at a time. Local cache
hits can proceed independently, and the optional store queue overlaps CPU
execution with write responses. This target has no persistent storage or network peripheral;
the root filesystem is the embedded initramfs.
