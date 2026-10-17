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
Multiply/divide wait includes an M instruction held behind older memory before
the arithmetic unit starts; it is not just the unit's execution time.
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

### Data-path latency

The experimental data-path configuration enables ordinary-load MEM-to-EX forwarding,
acknowledges successful data-port stores on their completion cycle, and expands
the ordered store queue from four to eight entries. Atomics retain their load
interlock; fences still drain queued writes. An older MEM fault also suppresses
younger EX effects, including MRET, SRET and WFI.

The same fixed 1 MHz profiling binary, compiler, 50 iterations and 20-cycle AXI
response model give the following separate experiments. Each performance and
validation seed set passes CRC and minimum-duration checks.

| Change from queued-fetch baseline | Performance CoreMark/MHz | CPI |
| --- | ---: | ---: |
| Baseline, four-entry queue | 1.561573 | 2.511313 |
| Load forwarding only | 1.631428 | 2.403781 |
| Store completion acknowledgement only | 1.568775 | 2.499777 |
| Eight-entry queue only | 1.627975 | 2.408859 |
| All three changes | **1.712329** | **2.290192** |
| Double I-cache capacity only | 1.579729 | 2.482443 |
| Double D-cache capacity only | 1.583431 | 2.476686 |

The combined gain is **9.65%** in this synthetic memory model, with unchanged
12,749,965 timed instructions. This does not establish the FPGA clock or physical
throughput. A faster one-cycle AXI-response experiment on the baseline reaches
1.946737/MHz; it retains the real bridge handshakes and is not an ideal-memory
pipeline measurement.

A separate simulated warm straight-line trace verifies dependent-load request, response
and EX-completion spacing of exactly three clocks becoming two. The memory
microbenchmark includes loop overhead: its steady-state AXI20 dependent-load
cost falls from 3.252838 to 2.315323 cycles/load, while independent chains remain
about 2.3156. Sparse stores save one clock; saturated stores remain limited by
the external write path. Every sample, including initial instruction-cache
warmup outliers, is retained in
[data-path-performance.json](results/data-path-performance.json). See the
[microbenchmark commands and scope](../memory_bench/README.md).

Directed load, store-response, fault-priority, fence and atomic tests pass.
The variable-latency core suite passes with load forwarding, including 1,128
interrupt positions. The combined eight-entry system boots the complete Linux
simulation to its shell.

#### Accepted store-path FPGA profile

The tested **58.823529 MHz** profile enables `FAST_STORE_ACK=1` and an eight-entry
store queue, while keeping `LOAD_FORWARDING=0`. It retains 4 KiB I/D caches,
queued fetch and fast multiplication. Three performance runs and one validation
run pass in each environment, all at least ten seconds long.

| Environment | CoreMark | CoreMark/MHz | CPI |
| --- | ---: | ---: | ---: |
| Bare metal | **106.809701** | **1.815765** | **2.159803** |
| Linux, aligned buffer, 25 Hz tick | **101.332523** | **1.722653** | Whole-CPU counters in evidence |

These improve the preceding clock-matched physical results by **3.90%** and
**3.77%**, respectively. Linux reaches **94.87%** of bare-metal throughput;
the platform ports differ, so this is not a pure OS-overhead measurement.
The same bare-metal and Linux payload binaries are reused. The two-second
timer test and CPU-cycle comparison pass.

All 40 physical microbenchmark records validate. Sparse-store cost falls from
37.270050 to 36.270065 cycles/store; steady-state saturated-store and load costs
remain unchanged. This profile does not enable the experimental load bypass.
The 16/32/64-point Linux mesh medians are **4.8355/27.2505/200.239 ms**; all
60 frames pass geometry checks and exactly match the preceding sequence.

The normal route missed setup by 0.524 ns and produced no bitstream. One
postroute refinement passes setup **+0.016 ns**, hold **+0.012 ns**, pulse width
**+0.206 ns**, clock methodology, critical CDC and bus skew. Timing margin is
narrow. Tested source is `f0d2f83`; the bitstream is
`build/performance/store-path-div17/postopt/synapse32_store-path-div17.bit`,
SHA256 `3b072166a94ad5c519c83416912b479a0d83fe01af1d3d87567f04c00dfd1fc2`.
It was copied to `siriboi:~/synapse32-store-path-div17.bit`, with the remote
checksum verified. Firmware is the same
`build/linux-image-25hz-cpu59-aligned-profile/fw_payload.bin` used for the
preceding 58.82 MHz comparison. Full configuration and frozen UART evidence
are in [data-path-performance.json](results/data-path-performance.json).

Build flags for that profile (run from the repository root, using the tested
source revision above for an exact reproduction):

```sh
PERF_TAG=store-path-div17 CPU_DIVIDE=17 BOOT_BAUD=2000000 \
  FAST_L1=1 ICACHE_LINES=256 DCACHE_LINES=256 STORE_BUFFER_DEPTH=8 \
  FAST_MULTIPLY=1 FETCH_QUEUE=1 LOAD_FORWARDING=0 FAST_STORE_ACK=1 \
  vivado -mode batch -nojournal -source fpga/arty_a7_35t/build_performance.tcl

# The accepted run needed one refinement after normal routing failed setup.
PERF_TAG=store-path-div17 vivado -mode batch -nojournal \
  -source fpga/arty_a7_35t/refine_performance.tcl
```

The first full-bypass implementation missed 58.82 MHz setup by **4.427 ns** and
was rejected. The late path runs from data-cache BRAM through load forwarding,
address-trigger comparison and fetch cancellation. Subsequent source removes
duplicate load formatting only for an explicit formatted-response contract,
and uses the equivalent 32-bit trigger comparison `base == target - offset`.
All four address triggers remain supported; memory addresses and trap values
retain their original calculation. Raw/formatted load contracts and 10,804
trigger comparisons pass, and matched CoreMark cycles remain exactly unchanged.
The subsequent 55.555556 MHz `Performance_Explore` implementation also fails
setup: **−2.145 ns WNS, −4763.703 ns TNS**, with hold **+0.008 ns**.
No bitstream is accepted or programmed for that experiment. The clock and
implementation strategy differ, so its slack cannot isolate either source
change's timing effect. Load forwarding remains opt-in; physical board defaults
retain the tested store-path configuration.
The remaining worst path crosses data-cache BRAM, forwarded EX arithmetic and
redirect/control logic into instruction-cache BRAM write data. Further timing
work needs to separate those stages while preserving cancellation, cache
coherence and precise faults.

### MIG clock constraint audit

The integration now derives MIG's `system/mig/sys_clk_i` clock from `board_clk`,
matching their physical connection. All 23 clock periods, waveforms and source
pins are unchanged. This resolves TIMING-4/6/27 rather than hiding those warnings.

The corrected relationship exposes the vendor temperature sampler's intentional
CDC. A narrowly scoped 20 ns datapath-only bound applies to its 12 XADC source
registers and 12 first-stage synchronizer endpoints. The existing data bound and
all 12 first-to-second-stage hold checks remain. The old accepted routed design,
rechecked with this model, has setup +0.014 ns, hold +0.051 ns and pulse-width
+0.206 ns, with no critical CDC or bus-skew violations. This audit does not change
the old programmed bitstream. New builds snapshot these constraints and reject
the clock warnings, negative setup/hold slack, critical CDC or failed bus skew.

### Queued instruction fetch

`FETCH_QUEUE=1` gives the FPGA a separate sequential request PC, four reserved
instruction slots, and a pipelined I-cache/TLB hit path. An empty queue forwards
the returning instruction directly; backpressure retains it. The CPU's existing
PC remains the architectural instruction position. Branches, traps, FENCE.I,
SFENCE.VMA, satp writes and privilege/translation changes discard queued and
in-flight work. Already granted bus reads drain before a new request is accepted.
Speculative fetches cannot read MMIO. Instruction access faults carry their PC
to EX and use cause 1, including supervisor delegation; page faults use cause 12.

The warm 64-instruction loop improves from exactly **two clocks per instruction**
to **one clock per instruction**, including request, response and counted
instruction cadence. The final accumulator checks for dropped or repeated work.
See [fetch-throughput.json](results/fetch-throughput.json) for traces and hashes.

With the same 1 MHz profiling binary and 20-cycle AXI response model:

| Fetch path | Performance CoreMark/MHz | CPI | Timed instructions |
| --- | ---: | ---: | ---: |
| Serialized cache controller | 1.245175 | 3.149472 | 12,749,965 |
| Pipelined controller and queue | 1.561573 | 2.511313 | 12,749,965 |

Both performance and validation seeds pass, with runs over 10 simulated seconds.
The gain is **25.41%** in this model. A registered-only queue measured 1.510894;
empty-queue forwarding removes another refill cycle. The initial forwarding
candidate measured 1.562207; removing the live cancellation path from bus
arbitration gives the final 1.561573 result. A cancel-edge RAM read grant drains
silently, preserving bus ownership without a long redirect-to-device path.
Instruction access and page faults are both excluded from `instret`.
These are simulation
results; use the physical measurements below for FPGA throughput.
Full reports, counter snapshots, bitstream/source hashes and clock-matched
baselines are in [fetch-performance.json](results/fetch-performance.json).

Run `make -C fpga/arty_a7_35t test-fetch` for queue credits/backpressure,
redirect/context cancellation, pipelined cache hits and misses, precise access
faults, fences, atomics and warm-loop cadence. `test_linux.sh` defaults to this
fetch path and requires boot plus execution of a UART shell command.

```bash
FAST_MULTIPLY=1 FETCH_QUEUE=1 bash fpga/arty_a7_35t/test_coremark_axi.sh \
  build/coremark-profile-1000000/coremark.bin
PERF_TAG=fetch-queue-div17 CPU_DIVIDE=17 BOOT_BAUD=2000000 \
  FAST_L1=1 STORE_BUFFER_DEPTH=4 FAST_MULTIPLY=1 FETCH_QUEUE=1 \
  vivado -mode batch -nojournal -source fpga/arty_a7_35t/build_performance.tcl
# The normal route fails setup; this required refinement produces the tested bit:
PERF_TAG=fetch-queue-div17 \
  vivado -mode batch -nojournal -source fpga/arty_a7_35t/refine_performance.tcl
```

The simulation uses the fixed profiling binary, not a benchmark recompiled to
exploit the fetch change. Queue-enabled I-cache events include speculative work;
they are not instruction retirement counts or a per-retired-instruction hit rate.

### Final 58.823529 MHz FPGA measurements

| Environment | Median CoreMark | CoreMark/MHz | CPI |
| --- | ---: | ---: | ---: |
| Bare metal | 102.796272 | 1.747537 | 2.244174 |
| Linux, aligned buffer, 25 Hz tick | 97.646714 | 1.659994 | 2.376202¹ |

¹ Linux CPI covers the whole command and background kernel work. Each environment
passes three performance runs and one validation run, all longer than 14.9 seconds.
Linux reaches **94.99%** of bare-metal throughput; the ports and linker relaxation
differ, so this ratio is not a pure OS-overhead measurement. Bare metal improves
**25.36%** over the previous 82.0 at 62.5 MHz, or **33.20%** after clock normalization.
The physical comparison also changes the CPU/DDR clock ratio and bare-metal binary
layout; the matched simulation above isolates the fetch change.

The final RTL snapshot is `2f056e0`; fractional-clock firmware support is
`1339ee8`. Firmware and DTB use **58,823,529 Hz**, with a two-second timer test
measuring 1.999712 host seconds and 117,647,098 CPU cycles. All nine benchmark tests pass;
the existing 1 MHz profiling binary remains byte-identical.

| Final RTL implementation | Setup WNS | Setup TNS | Accepted |
| --- | ---: | ---: | --- |
| Normal route, 62.5 MHz | −0.687 ns | −298.590 ns | No |
| Normal route, 58.823529 MHz | −0.428 ns | −48.928 ns | No |
| Postroute refinement, 58.823529 MHz | +0.014 ns | 0 ns | Yes |

The accepted build also has hold +0.051 ns and pulse-width +0.206 ns, four RAMB36s
and four DSPs, with no critical CDC or bus-skew violations. Its setup margin is
narrow. Reports retain inherited critical clock-methodology warnings TIMING-4/27
for `system/mig/sys_clk_i` redefinition beneath `board_clk`, and TIMING-6 for
`ref200_raw`/`clk_pll_i` lacking a common primary clock. The same warnings occur in
the initial 50 MHz and previous fastmul62 reports. They were unresolved when this
bitstream was accepted; the subsequent clock audit above records the correction.

Tested bitstream:
`build/performance/fetch-queue-div17/postopt/synapse32_fetch-queue-div17.bit`
(SHA256 `8d9141c052adf2e62cd5596d2bc71f5d285ca79301a752d2d09ae1190f403001`).
Matching Linux image: `build/linux-image-25hz-cpu59-aligned-profile/fw_payload.bin`.
Full firmware/source/report hashes and frozen UART evidence are preserved in
[fetch-performance.json](results/fetch-performance.json).

The 16/32/64-point mesh medians are **5.3595/28.0055/208.8485 ms**. All 60 frames
pass geometry validation and exactly match the previous 62.5 MHz run's points and
triangles. UART transport also limits visible frame rate; the live 32-point viewer
receives about 11.3 frames/s.

### Initial 50 MHz FPGA measurements

| Environment | CoreMark | CoreMark/MHz |
| --- | ---: | ---: |
| Bare metal | 88.264661 | 1.765293 |
| Linux, aligned buffer, 25 Hz tick | 86.422954 | 1.728459 |

The bare-metal median improves **32.19%** over the previous 50 MHz result of
66.768841. Linux reaches **97.91%** of the bare-metal throughput. Three
performance runs and one validation run pass in each environment. The initial
bitstream meets setup +0.274 ns and hold +0.054 ns, using four RAMB36s/four DSPs.
It precedes the cancellation timing change and page-fault counter correction;
its exact source hashes and a reproduction patch are preserved in the result
artifact. Benchmark loops have no instruction faults.

The 16/32/64-point Linux mesh tests validate all 60 frames, including exact
geometry agreement with the previous run. Median computation is
6.3335/33.888/232.584 ms respectively at 50 MHz; UART transport also limits
visible frame rate.

### Previous FPGA profile

The previous profile used BRAM L1, a four-entry store queue and fast multiplication
at 50 MHz. Its optional 62.5 MHz profile passed all CRC/duration checks and timing
(setup +0.023 ns, hold +0.051 ns); its setup margin is narrow. Tested artifacts:
`build/performance/fastmul-bram-l1-62/synapse32_fastmul-bram-l1-62.bit` and
`build/linux-image-25hz-cpu62-aligned-profile/fw_payload.bin` (2 Mbaud loader,
115200 console, 25 Hz kernel). The image retains the original comparison binary;
run `/tmp/coremark-aligned-o3 0 0 0x66 1000 7 1` for the corrected benchmark.
`build_trap_profile.sh` produces separate diagnostic firmware; do not use its
instrumented timing as an accepted score. Hashes and full reports are preserved
in the permanent result JSON files.
