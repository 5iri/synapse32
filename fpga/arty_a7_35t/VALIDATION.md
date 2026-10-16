# Validation — 2026-10-11

Base: SRA-VJTI/Synapse32 main `835b5fad1dcfa175273faad0757f9c52a27ca7ba`.
Target: Arty A7-35T, CPU 50 MHz, DDR3 325 MHz / AXI UI 81.25 MHz.

| Check | Result |
| --- | --- |
| FPGA SoC Verilator lint, iterative M / real UART divisor | Pass, no warnings |
| Stalled AXI RAM CPU smoke, including MSIP, atomics, byte lanes, self-modifying code and Sv32 | Pass |
| AXI read/write response error injections | Both halt the CPU as expected |
| Iterative RV32M | 1,633 edge/random cases, held results and cancellation pass |
| Sv32 data/execute permissions, A/D faults, SUM/MXR, superpage alignment, redirects, out-of-range root PPN | Pass |
| UART loader, real serial waveforms | Valid CRC accepted; invalid length/CRC, DDR overrun and DDR error rejected |
| Upstream memory-wait, UART FIFO and PLIC re-arm regressions | 3 tests pass; UART tests also pass after final width cleanup |
| Vivado MIG DDR3 component model with asynchronous AXI converter | Pass, 28,775 UI cycles |
| Linux 6.6.32 + OpenSBI 1.4 + static RV32 BusyBox 1.36.1 build | Pass |
| Linux boot through FPGA CPU/AXI/Sv32/peripherals, decoded 16550 TX | BusyBox shell reached |
| UART command through Linux/PLIC | `echo FPGA_BOOT_OK` returns `FPGA_BOOT_OK`; pass at 1,141,575,782 model cycles |
| Physical board | Pass 2026-10-14 with 12 Hz kernel: BusyBox shell executes UART commands (details below) |

The Linux test preloads RAM and uses a functional AXI RAM model. The UART loader
and MIG/PHY/clock converter are tested separately. The component-model run
preceded the final MSIP/loader error-path additions; those changes are covered by
the AXI/Linux and loader tests and final synthesis, and do not alter DDR PHY logic.

The final bitstream build checks setup and hold timing, critical CDC violations,
and the AXI converter's bus skew constraints before writing the bitstream.
Setup WNS is +0.743 ns; hold WHS is +0.053 ns, with zero failing endpoints.
Utilization is 12,512 / 20,800 LUTs (60.15%), 9,270 registers, no BRAM and no DSPs.
Vivado's WebTalk settings warnings come from the restricted home directory;
bitstream generation succeeds. Other remaining CDC warnings are within vendor
IP. Reports are under `build/board/`.

The source build uses Clang/LLD 23.1.1, compiler-rt sources 19.1.7 and musl 1.2.5.
Sources are pinned to Linux v6.6.32, OpenSBI v1.4 and BusyBox 1_36_1. Linux has the
existing build script's VDSO pause-encoding patch and reports `6.6.32-dirty`.

Console excerpt from `build/linux-uart-simulation.log`:

```text
Synapse32 Linux userspace is up.
uname: Linux synapse32
Launching /sbin/init...
~ # echo FPGA_BOOT_OK
FPGA_BOOT_OK

PASS: Linux BusyBox shell executed a UART command through FPGA AXI/Sv32/PLIC fabric in 1141575782 cycles
```

The images and detailed logs are generated locally under ignored `build/`;
rebuild them using the commands in [README.md](README.md).

SHA-256 for the locally generated artifacts:

```text
51b96fccbf60a44c8c6ca4f24eefcef25610656a82f49e87213543103b59ff27  build/board/synapse32_linux.bit
f7cc18095a312c0ae511a3b012c44e98429b3c054717989b02d5080212b7c474  build/linux-image/fw_payload.bin
```

## Physical board — 2026-10-14

Connected Arty A7-35T, Digilent serial `210319A43D3E`, UART `/dev/ttyUSB1`.
JTAG programming succeeded. LED0 and LED1 were lit, confirming clock lock and
DDR calibration. A temporary ILA capture also confirmed reset deassertion,
calibration synchronized into the loader, and correct decoding of UART bytes
at 1 Mbaud (50 CPU cycles per bit).

The physical top now selects a 1,000,000 baud loader; the CPU console remains at
115200. Loader waveform tests pass at both the original 115200 setting and the
board's 50 MHz / 1 Mbaud setting, including CRC, invalid-length, DDR overrun and
DDR response-error cases. A 64-byte physical transfer returned `K`.

An initial full transfer received no valid acknowledgement. After a controlled
reset and a one-second USB UART settling interval, the 21,550,312-byte Linux
image transferred in 216.5 seconds and returned `K`. The exact cause of the
initial failed transfer is not established. The uploader now waits one second
after opening the port and switches to 115200 after the loader acknowledgement.

The initial 100 Hz output includes OpenSBI v1.4 and Linux 6.6.32 startup, DDR-backed memory
initialization, PLIC setup, devtmpfs initialization, and clocksource selection.
Linux then reports repeated soft/workqueue lockups without reaching userspace.
One `hrtimer` interrupt took 42,444,580 ns, exceeding the configured
100 Hz tick interval (10 ms). Early lockups interrupt `finish_task_switch` just
after re-enabling supervisor interrupts. Timer overhead on the uncached DDR
CPU is a working hypothesis, not a confirmed root cause.

Local UART evidence: `build/hardware-uart.log` and `build/hardware-test.log`.
Temporary debug captures: `build/board/loader-idle.csv`, `loader-rx.csv`, and
`loader-after.csv`. The normal bitstream was restored after debug capture.

The faster-loader build passes setup/hold timing, critical CDC and bus-skew
checks: WNS +1.233 ns, WHS +0.054 ns, zero failing endpoints. Current bitstream:

```text
0fb0c8b33d7100c7ba72dc996b36a356d458f5c9f1bec36774b2255a63d4a3ef  build/board/synapse32_linux.bit
```

The subsequent 12 Hz kernel uses the same 50 MHz hardware timebase. Its first
upload stopped at 77% with a serial write I/O error. After reconnection, full
transfers returned `K` in approximately 215.5 seconds. Linux reached userspace
and a BusyBox prompt at approximately 131 seconds after CPU release, then
executed the following command over the physical UART:

```text
Synapse32 Linux userspace is up.
uname: Linux synapse32
Launching /sbin/init...
~ # echo FPGA_BOOT_OK; uname -a
FPGA_BOOT_OK
Linux (none) 6.6.32-dirty #2 Sat May 25 14:22:56 UTC 2024 riscv32 GNU/Linux
~ #
```

The original test harness incorrectly expected a `synapse32` hostname in
BusyBox's uname output and reported a timeout despite this successful command.
The corrected harness accepts the actual RV32 uname line. Slow console input
(100 ms between bytes) was verified. Arty JP2 can connect DTR to RESET, and
reopening a port was observed to return
the board to its loader. `--keep-open` retains the UART handle after success.

One boot-time soft-lockup warning remains in the BLAKE2s self-test; it completes
and Linux proceeds to userspace. This is functional boot acceptance, not a
performance or sustained-load validation. The board build now defaults to
12 Hz; the shared simulator build remains at 100 Hz. Reproduce the board build
with `LLVM=1 make -C fpga/arty_a7_35t linux`, then program and run `test-board`.
The 100 Hz failure logs remain under `build/baseline-100hz/`; successful UART
evidence is in `build/hardware-12hz-repeat-uart.log` and the live capture files.

The initial repeat run returned `K` in 215.5 seconds, reached userspace at
131.2 seconds and printed `PASS: physical FPGA reached Linux shell and executed
UART command`. Archived logs: `build/hardware-live-test.log` and
`build/hardware-live-uart.log`. The later console regression and current
physical-board results follow.

### Interactive-console interrupt regression

Later interactive input exposed a repeatable console stall. A temporary ILA
build captured the CPU and interrupt state while the UART reader stayed open.
The stalled snapshot in `build/board/runtime-12.csv` shows:

- `scause = 0x80000009` (supervisor external interrupt), `mip = 0x220`.
- UART IRQ, PLIC IRQ, PLIC pending and gateway busy are all zero.
- Fabric fault is zero; the CPU continues executing interrupt-handler code.
- CLINT `mtime` and the CSR cycle counter agree exactly.

The CPU was copying the hardware SEIP read value into its software-pending
latch when OpenSBI cleared STIP with `CSRRC mip`. The software latch then kept
external interrupts pending after the UART/PLIC source was cleared. The
[RISC-V SEIP rule](https://docs.riscv.org/reference/isa/priv/machine.html)
requires the hardware signal to be excluded from this writeback.

CSR execution now carries an operand write mask to the CSR file. Pending
software bits absent from a set/clear operand retain their software latch;
full CSR writes still replace them. The regression couples the actual CSR
execution and register-file modules, reproduces the failure before the fix,
and passes after it. It covers register/immediate set, clear and write forms,
and verifies that software SEIP injection still works. All nineteen existing
CSR regressions and the CSR trap-priority regression pass.

The corrected bitstream `build/board/synapse32_linux_irqfix.bit` passes setup
and hold timing (WNS +0.657 ns, WHS +0.050 ns), DRC, CDC and AXI bus-skew checks.
The physical board accepted the unchanged 12 Hz payload in 215.5 seconds,
executed the initial boot/uname command, and then passed twelve further
commands, including one after a sixty-second idle period. The actual
`console.py` client returned `USER_CONSOLE_OK`, interrupted `sleep 30` with
Ctrl+C, and returned `AFTER_CTRL_C`. Detaching it preserved the UART reader;
a Ghostty window titled `FPGA Linux` uses that same reader and log.

The three existing memory/UART test runners pass, and the new pending-CSR
runner passes separately under pytest. `test-core` now collects all four.
The earlier LED3 fabric fault has not been independently traced to this
interrupt bug; none occurred during this corrected-board acceptance run.
The BLAKE2s boot warning and slow uncached execution remain.

Current logs: `build/irqfix-board-test.log`, `build/irqfix-host-test.log` and
`build/irqfix-uart.log`. The retained reader uses the latter log. The standard
`build/board/synapse32_linux.bit` is now a copy of the verified corrected
bitstream; `synapse32_linux_before_irqfix.bit` preserves the previous image.

```text
827f9aa09840bb3995572c710299f6fc82f0cba500a25c0fbaa2a458d2fac7a4  synapse32_linux_irqfix.bit
```

```text
1ba296a2ad4f893b03c21aada5bdbb00f6226e369e04d1b48046419ecfc9c584  12 Hz fw_payload.bin
```

### Upstream synchronization and physical triangulator (2026-10-15)

The work branch merges upstream `45433c3`, including the sequential walker/TLB,
SFENCE fetch ordering, and deferred instruction-fault fixes. Local and origin
`main` are fast-forwarded to that upstream commit. The Arty target still uses
its separate uncached `sv32_bus_port`; the upstream TLB is not connected to the
board's DDR interface.

The rebuilt `build/board/synapse32_linux_synced.bit` passes setup/hold timing
(WNS +1.316 ns, WHS +0.050 ns), DRC, CDC and AXI bus-skew checks. The standard
`synapse32_linux.bit` is a copy of this image. The physical board accepted the
new payload, booted Linux, and ran `/bin/triangulator` from its initramfs.

```text
1baa1a5fe18ce84d147543ede224b956f345dd17e59d769af55527c5728aa1eb  synapse32_linux_synced.bit
dad84f99613944dcc7ebc05e80a33156053251a5061fdf291d619f8ef67f44a2  fw_payload.bin
1516c10212200a5eabb5775708f98dc66107c67448001121578cb3cc17b93434  triangulator (7092 bytes)
```

All six core runners pass: TLB, walker flush, SFENCE ordering, instruction-fault
deferral, store/load across page walks, and pending-CSR read-modify-write.
The seven geometry/viewer/protocol unit tests also pass. The live UART capture
contains more than 1,000 complete meshes across 16, 32 and 64 points; independent
geometry checks pass for every complete captured frame. Representative elapsed
triangulation times, excluding JSON formatting and UART transmission:

| Points | Median calculation | Observed range |
| --- | --- | --- |
| 16 | 216 ms | 128–351 ms |
| 32 | 1,146 ms | 940–1,236 ms |
| 64 | 7,091 ms | 6,228–8,434 ms |

These times include interrupts and clock-read overhead. The browser receives
about 2.7 frames/second at 16 points. Its FPS calculation now handles intervals
longer than five seconds, and its protocol parser handles kernel console
messages appended to mesh records. Neither measurement is CPU utilization.
Start/stop and point-count changes were exercised on the board, and the final
visible demo runs with 16 points.

The UART reader and viewer are detached processes so an interrupted host tool
session does not close the UART and reset the board. Current evidence:
`build/triangulator-synced-board-test.log`, `build/triangulator-synced-uart.log`,
`build/triangulator-synced-viewer.log`, `build/synced-core-regression.log` and
`build/board/synced-build.log`. The acknowledged software uploader has not been
validated on hardware; this acceptance used the executable embedded in initramfs.

The kernel remains pinned to 6.6.32 with the 12 Hz timer workaround. Cache/TLB
integration and a newer kernel require separate implementation and hardware
validation. The earlier BLAKE2s warning and unresolved historical LED3 fault
limitations above remain applicable. Compilation currently uses the laptop's
cross toolchain; a native compiler is not installed in the FPGA Linux image.

### Upstream TLB integration (2026-10-16)

The board's instruction and data ports now instantiate the unmodified upstream
`rtl/mmu/sv32_tlb.v`, eight entries per port. Permission checks still run on
every hit. The CPU's SFENCE.VMA/satp-write pulse invalidates both instances;
the adapter also detects all satp changes, including ASID-only changes.
Invalidation during a walk prevents stale refills and discards pre-fence
instruction responses even when the PC does not change. No instruction/data
cache is included in this change.

All eight TLB adapter cases pass across fetch/data configurations, checking
4 KiB and 4 MiB hits, root/ASID changes, bare-mode bypass, fault retries,
live privilege/SUM/MXR/D-bit checks, cached stores and fences during a delayed
leaf response. Bus traces require three physical reads for a cold 4 KiB access
and exactly one on a hit. The existing walker/redirect tests, three AXI smoke
and error configurations, and four core regression runners pass as well.

The next bitstream is `build/board/synapse32_linux_tlb.bit`. Vivado 2024.2
completed synthesis and routing, then passed setup/hold timing (WNS +0.688 ns,
WHS +0.051 ns), DRC, critical-CDC and AXI bus-skew checks. Utilization is
12,724 LUTs (61.17%) and 10,062 registers (24.19%). Reports are named
`build/board/tlb-*.rpt`; the full build log is `build/board/tlb-build.log`.
The existing duplicate 100 MHz input-clock definition still produces synthesis
warning Constraints 18-1056; both definitions specify the same 10 ns period,
and the final routed timing constraints pass.

```text
18d6f26367de347e0c90dfafd9af64fdf0b6679eb83f999505dd9c16910d81f9  synapse32_linux_tlb.bit
```

The default `build/board/synapse32_linux.bit` is a copy of this TLB image.
The preceding physically verified image remains `synapse32_linux_synced.bit`.

The Linux payload is unchanged from the preceding acceptance. This bitstream
has not been programmed or benchmarked on physical hardware: the board was
disconnected during this build. Test logs are `build/tlb-bus.log`,
`build/tlb-walker-regression.log`, `build/tlb-axi-regression.log` and
`build/tlb-core-regression.log`. Full SoC Linux simulation is recorded in
`build/tlb-linux-sim.log`: it booted to a BusyBox shell and executed
`echo FPGA_BOOT_OK` through the UART in 878,670,086 simulated CPU cycles.
This run models byte-accurate AXI RAM, not the DDR PHY or USB upload, and does
not establish physical-board boot time or triangulator throughput.

### Physical performance and clock/tick sweep (2026-10-16)

The TLB bitstream now passes physical boot and UART command execution. Matched
meshes compute about 2.5× faster than the prior uncached bitstream. The official
CoreMark sources pass all published checksums; each physical run passes CRC
validation and exceeds the minimum ten timed seconds. Median `-O3` scores:

| CPU clock | Linux tick | CoreMark |
| --- | --- | --- |
| 50 MHz | 12 Hz | 0.056654 |
| 50 MHz | 25 Hz | 0.052436 |
| 50 MHz | 50 Hz | 0.044088 |
| 50 MHz | 100 Hz | 0.027397 |
| 62.5 MHz | 25 Hz | 0.058275 |

Each row has three performance repeats and a validation-seed run. The 12/100 Hz
profiles also include `-O2` cross-checks, with no meaningful improvement.
All five profiles contribute 60 independently validated mesh frames each.
The board Linux build now defaults to 25 Hz; 12/50/100 Hz remain selectable.

The fast profile passes setup/hold (+0.010/+0.054 ns), DRC, critical CDC and
bus skew. It uses MMCM divider 16 while DDR/reference clocks stay unchanged.
The 2 Mbaud payload transfer takes 107.8 seconds, Linux reaches `/init` at
74.67 seconds, and OpenSBI reports 62,500,000 Hz. A device-tree probe confirms
`03 b9 ac a0` (62,500,000). Ten CoreMark performance iterations pass in 171.609
seconds, followed by ten validation iterations in 174.186 seconds. The
clock-aware full SoC simulation boots and executes its UART command in
761,494,750 simulated CPU cycles. A 55.56 MHz fallback also closes timing
(+0.256/+0.050 ns) but has not been tested physically.

The active board runs 62.5 MHz / 25 Hz. [Full results](coremark/RESULTS.md)
include image hashes, compiler settings, raw reports and all comparisons.
Local evidence: `build/cpu62-hardware-uart.log`, `build/cpu62-long-coremark.log`,
`build/cpu62-console-proof.log` and `build/cpu62-linux-sim.log`. Earlier tick
logs have `25hz`, `50hz`, `100hz` or `tlb` prefixes. The reader stays open while
host tools change; final printk settings are restored to `8 4 1 7` after upload.
Eight host geometry/viewer/protocol/UART tests pass. The narrow timing margin
is recorded without claiming an absolute frequency ceiling or unlimited
runtime stability.

## Data cache, 2026-10-16

The board DDR bridge now has a 4 KiB physical direct-mapped data cache with
16-byte lines. Only data-port reads allocate. All stores remain write-through,
wait for the AXI response and update matching cache lines by byte enable;
instruction reads remain uncached. MMIO never enters the DDR bridge. There
are no dirty lines, new cache-maintenance instructions or Linux image changes.

`make test` passes with four cache capacities (disabled, one line, 1 KiB and
4 KiB). Directed cases cover line reuse, last-byte reads, byte/halfword/sparse
stores, uncached reads and writers, tag conflicts, no-write-allocate, failed
stores/refills, missing RLAST and reset. Each capacity also runs 300 fixed-seed
random samples against an independent byte scoreboard. The CPU AXI suite
passes normal/error-response tests with the cache both disabled and enabled;
the smoke program now warms code through the data port before patching it,
executes FENCE/FENCE.I, and checks virtual aliases of one physical word.
Existing MMU/TLB, UART loader, iterative M and four core regression runners
also pass.

Vivado 2024.2 out-of-context synthesis of the bridge infers two RAMB36E1 tiles
for the cache data. This is a synthesis check, not full-board timing signoff.
The real 62.5 MHz / 25 Hz Linux image boots in the full cached SoC simulation
and executes `echo FPGA_BOOT_OK` through its UART in 750,497,246 cycles.
Evidence: `build/dcache-regressions.log`, `build/dcache-core-regressions.log`,
`build/dcache-utilization.rpt`, and `build/dcache-linux.log`.

The full-board 62.5 MHz bitstream `synapse32_linux_dcache_cpu62.bit` also
passes setup/hold (+0.138/+0.051 ns), DRC, critical CDC and bus skew. Its SHA256
is `b5f0ae2f22835f296b8ddcffca4cdfa2b4659e235513cd9abb8f6578936753d3`.
Total routed usage is 13,558 LUTs, 10,321 registers and two block-RAM tiles.
It was programmed onto the same Arty, with the unchanged 25 Hz / 62.5 MHz
Linux image (SHA256 `f1568fca0526fde02f7e1fde51a5387ee2d3912de5196ca68e9a74fd138ab093`).
The loader accepted CRC after 107.8 seconds, Linux reached `/init` at
67.849 seconds, and the physical UART shell command passed.

Three two-iteration CoreMark performance runs and one two-iteration
validation run all pass upstream CRC checks and the ten-second minimum.
Median performance is 0.065954 versus the prior uncached 0.058275, a 13.2%
gain at the same CPU clock and tick. All 60 physical mesh frames pass
independent exact geometry checks and match the previous points, frame IDs
and triangles. Their median compute times are 71.7585, 386.079 and 2708.744 ms
for 16/32/64 points respectively. See [results](coremark/RESULTS.md#data-cache-at-625-mhz)
and the tracked `coremark/results/dcache-*.json` reports. Local UART evidence
is in `build/dcache-hardware-uart.log`; timing/CDC/DRC reports have the
`build/board/dcache-cpu62-` prefix. This acceptance does not measure cache
hit rates or a detailed cycle breakdown, and instruction fetches remain uncached.
