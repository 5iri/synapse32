# CoreMark memory-path measurements

These measurements separate external-memory costs from CPU execution with fast
memory. All accepted scores use the pinned EEMBC source, Clang 23.1.1, `-O3`,
RV32IMA, static allocation, one context, valid CRCs, and runs lasting at least
10 seconds. Scores are medians of three performance runs; a validation-seed run
also passes. `FAST_MULTIPLY=0` means iterative multiplication and division.

## Accepted physical results

| CPU MHz | Environment and memory path | CoreMark | CoreMark/MHz | CPI |
| ---: | --- | ---: | ---: | ---: |
| 62.5 | Bare metal, DDR3, no caches | 3.695765 | 0.059132 | 66.320722 |
| 62.5 | Bare metal, DDR3, 4 KiB I + 4 KiB D caches in serialized bridge | 24.710270 | 0.395364 | 9.919053 |
| 62.5 | Linux, DDR3, no caches, unaligned buffer, 25 Hz tick | 0.058275 | 0.000932 | — |
| 62.5 | Linux, DDR3, bridge I/D caches, unaligned buffer, 25 Hz tick | 0.365751 | 0.005852 | — |
| 50 | Bare metal, 128 KiB synchronous BRAM, no caches | 52.172175 | 1.0434435 | 3.758463 |
| 50 | Profiled bare metal, DDR3, local I/D L1, no store queue, iterative M | 40.117286 | 0.802346 | 4.887824 |
| 50 | Bare metal, BRAM L1, four-entry store queue, iterative M | 48.408576 | 0.968172 | 4.050582 |
| 50 | Linux, BRAM L1, store queue, iterative M, unaligned buffer | 0.655841 | 0.013117 | — |
| 50 | Bare metal, BRAM L1, store queue, fast multiplication | 66.768841 | 1.335377 | 2.936864 |
| 62.5 | Bare metal, BRAM L1, store queue, fast multiplication | 82.000000 | 1.312000 | 2.989189 |
| 62.5 | Linux, same hardware, original unaligned buffer | 0.768580 | 0.012297 | — |
| 62.5 | Linux, same hardware, aligned buffer | **80.847279** | **1.293556** | — |

The first local-L1 measurement used **LUTRAM**, with zero inferred cache BRAMs.
It is a valid physical score for that implementation, not a measurement of the
subsequent BRAM-inference fix. Current source uses canonical registered RAM reads
and a separate fill/snoop write port; standalone synthesis infers two RAMB36s per
4 KiB bank. The subsequent buffered physical builds use four RAMB36 blocks total.

The BRAM baseline holds **all code, constants, data, BSS and stack** in
`0x80000000–0x8001ffff`. Its CPU uses iterative M, no I-cache or D-cache, and
one-cycle memory responses. The 50-iteration pilot gives exactly the simulated
latency-1 result: 47,920,134 cycles / 12,749,961 counted instructions. Accepted
long runs use 783 iterations. Physical implementation uses 32 RAMB36s and meets
50 MHz timing: setup +0.994 ns, hold +0.034 ns.

Compare clock-matched rows or CoreMark/MHz; 50 MHz and 62.5 MHz totals are not
direct speedups. At 62.5 MHz, bridge caches improve bare-metal throughput 6.69×
and the original Linux port's throughput 6.28×. Those Linux results include
misaligned-access emulation and must not be treated as a pure OS-overhead cost.

The original Linux `static_memblk` was at **0x26cd5**, an odd address. The list
initializer uses it directly as pointers and halfwords. One diagnostic process
produced **24,015 misaligned-load and 7,004 misaligned-store traps**; the last
faults were user instructions accessing odd address `0x26cdd`. These counts
include setup/reporting and are diagnostic, not a valid one-iteration score.
See [trap evidence](results/misalignment-trap-diagnostic.json).

The platform linker script places the buffer at 16-aligned **0x26cb0** without
changing EEMBC source. Ten linked timed functions remain byte-identical. Both
binaries were tested in the same normal-firmware Linux image on the same
62.5 MHz bitstream: alignment alone improves throughput **105.19×**. Aligned
Linux achieves **98.59%** of bare-metal throughput. Platform code and linker
relaxation still differ, so the remaining 1.41% is not a pure OS-cost measurement.

Permanent evidence, including outputs, hashes and configuration, is in
[memory-performance.json](results/memory-performance.json), with the earlier
Linux baseline in [cpu62-coremark.json](results/cpu62-coremark.json). The first
local-L1 run originates in `build/performance-fast-l1-50.json`; accepted new
stages are consolidated into the permanent results. Generated bitstreams,
Verilator outputs, raw UART logs and Vivado reports under `build/` are ignored.

## Build and run

Run from the repository root with the existing Vivado, cross-toolchain and
Python serial environment installed. Keep one process owning the UART.

```bash
board=fpga/arty_a7_35t
bash "$board/test_bram_coremark.sh"                    # full serial simulation
bash "$board/test_bram_coremark.sh" --build-bitstream  # embedded 50 MHz firmware
```

The BRAM bitstream is `build/bram-coremark/board/synapse32_bram_coremark.bit`.
Use `run_baremetal.py --no-upload` with the matching
`build/bram-coremark/firmware50/coremark-bram.bin`; start capture before programming.
LED0 means clock locked, LED1 reset released, LED2 CPU UART access, LED3 fault.

Build a current 50 MHz local-L1 stage, varying one parameter at a time:

```bash
PERF_TAG=local-l1-bram-50 CPU_DIVIDE=20 BOOT_BAUD=1000000 \
  FAST_L1=1 ICACHE_LINES=256 DCACHE_LINES=256 \
  STORE_BUFFER_DEPTH=0 FAST_MULTIPLY=0 \
  vivado -mode batch -nojournal -source "$board/build_performance.tcl"
```

This reuses previously generated MIG/CDC IP and snapshots RTL, configuration and
source hashes into `build/performance/$PERF_TAG/`. Timing, critical CDC, bus-skew
and cache-BRAM inference checks gate acceptance. A four-entry store-queue stage
uses `STORE_BUFFER_DEPTH=4`; accelerated multiplication uses `FAST_MULTIPLY=1`.

Build the profiling payload with the board's existing toolchain, then program
the matching bitstream and run the UART benchmark:

```bash
export COREMARK_CC="$PWD/$board/build/llvm-toolchain/riscv32-linux-gnu-gcc"
export COREMARK_OBJCOPY="$PWD/$board/build/llvm-toolchain/riscv32-linux-gnu-objcopy"
export COREMARK_OBJDUMP=llvm-objdump
export COREMARK_RUNTIME_ARCHIVE="$PWD/$board/build/runtime/lib/linux/libclang_rt.builtins-riscv32.a"
export COREMARK_DIR="$PWD/$board/build/coremark-source"
CPU_CLOCK_HZ=50000000 COREMARK_BAREMETAL_OUT="$PWD/$board/build/coremark-profile50" \
  bash "$board/coremark/build_profile.sh"
.venv/bin/python "$board/coremark/run_baremetal.py" "$port" --cpu-mhz 50 \
  --baud 1000000 --image "$board/build/coremark-profile50/coremark.bin" \
  --iterations 50 --repeats 3 --output "$board/build/profile-run.json" \
  --log "$board/build/profile-run.uart.log"
```

Set `port` to the board UART path. CPU clock, payload timer frequency and loader
baud must match the bitstream. The runner checks the two-second timer against
host elapsed time and CPU cycles, and expands short pilots into valid long runs.

## Profiling registers and scope

[`fpga_perf_counters.sv`](../fpga_perf_counters.sv) maps a page at `0x20001000`.
Offset `+0` reads magic `0x53333250` and any write clears counters; `+4` reads
version 1. Counter `n` has low/high words at `+0x10+8*n` / `+0x14+8*n`.
Read high/low/high and retry on rollover.

| n | Event | n | Event |
| ---: | --- | ---: | --- |
| 0 | clock cycles | 8 | D-cache hits |
| 1 | counted instructions | 9 | D-cache misses |
| 2 | fetch wait | 10 | ITLB misses |
| 3 | data wait | 11 | DTLB misses |
| 4 | multiply/divide wait | 12 | AXI read wait |
| 5 | fence wait | 13 | AXI write wait |
| 6 | I-cache hits | 14 | store-queue backpressure |
| 7 | I-cache misses | 15 | stores enqueued |

Events overlap; adding wait counts does not produce an additive CPI breakdown.
Instruction counts use the core's EX-completion event, also used by `instret`,
not a separate writeback retirement trace. Cache-hit events can include repeated
fetches while execution is held. The profiled port's MMIO snapshots bracket the
normal timed interval and add small read overhead, so their clock/retired deltas
need not equal the normal timed CSR deltas exactly.

The plain and profiled bare-metal ports leave EEMBC algorithm objects unchanged.
Linux uses a different platform timer and enables linker relaxation; identical
pre-link algorithm objects do not imply identical final instruction counts.

For Linux, build `coremark/build_linux_profiler.sh`, copy its `profile` executable
to the board, and run as root with a bitstream exposing the profiling page:

```bash
# On FPGA Linux; requires /dev/mem access as root:
/tmp/profile /tmp/coremark-o3 0 0 0x66 10 7 1
```

This wrapper measures the **whole CPU during the command**, including kernel,
background tasks, process startup and reporting. Its counters are not restricted
to CoreMark's internally timed loop. Do not label them userspace-only CPI.

## Current verified profile

Board defaults are BRAM L1, a four-entry store queue and fast multiplication at
50 MHz. The optional 62.5 MHz profile passed all CRC/duration checks and timing
(setup +0.023 ns, hold +0.051 ns); its setup margin is narrow. Tested artifacts:
`build/performance/fastmul-bram-l1-62/synapse32_fastmul-bram-l1-62.bit` and
`build/linux-image-25hz-cpu62-aligned-profile/fw_payload.bin` (2 Mbaud loader,
115200 console, 25 Hz kernel). The image retains the original comparison binary;
run `/tmp/coremark-aligned-o3 0 0 0x66 1000 7 1` for the corrected benchmark.
`build_trap_profile.sh` produces separate diagnostic firmware; do not use its
instrumented timing as an accepted score. Hashes and full reports are preserved
in the permanent result JSON files.
