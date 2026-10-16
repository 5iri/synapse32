# Physical performance, 2026-10-16

Arty A7-35T, 50 MHz RV32IMA CPU, 64 MiB exposed DDR3, separate eight-entry
upstream TLBs, no instruction/data caches, Linux 6.6.32 with a 12 Hz timer.
The tested bitstream is `synapse32_linux_tlb.bit`, SHA256
`18d6f26367de347e0c90dfafd9af64fdf0b6679eb83f999505dd9c16910d81f9`.

## Triangulation

The identical `/bin/triangulator` executable was used before and after adding
the TLB. Comparison matches the point count, frame index and every point's
coordinates. Multiple old captures of an identical frame are reduced to their
median before comparing the matched frames. Times include Linux interrupts
and clock-read overhead, and exclude JSON formatting and UART output.

| Points | Matched frames | Before, median ms | With TLB, median ms | Speedup | Current received FPS |
| --- | --- | --- | --- | --- | --- |
| 16 | 30 | 225.45 | 91.05 | 2.48× | 5.44 |
| 32 | 14 | 1145.74 | 452.59 | 2.53× | 1.47 |
| 64 | 10 | 8203.43 | 3334.53 | 2.46× | 0.27 |

The current run contains 30, 20 and 10 frames at 16, 32 and 64 points respectively.
Only 14 old 32-point frames match, so that row compares those 14 frames; all
20 current 32-point frames have a median of 464.24 ms. The 16-point sequence
runs at 5.44 received FPS; the arrival timestamps include UART and host polling.
All 60 new frames pass independent exact-predicate geometry checks.

The board accepted the same 21.5 MB Linux payload in about 215.5 seconds.
The kernel reached `/init` at 78.58 seconds, compared with roughly 131 seconds
in the preceding uncached boot acceptance. Kernel timestamps and boot endpoints
make this a rough boot comparison; the matched mesh timings above are the
controlled workload comparison.

## CoreMark

All eight runs below execute the official workload under physical FPGA Linux:
three performance runs per optimization and one validation-seed run per
optimization. Every run reports correct operation and matching CRCs. Each uses
one iteration, which exceeds the ten-second minimum on this CPU. Upstream's
automatic calibration starts at ten iterations; the initial attempt therefore
exceeded a five-minute host timeout and was interrupted without being scored.

| Optimization | Performance scores, iterations/sec | Median CoreMark | CoreMark/MHz | Validation run |
| --- | --- | --- | --- | --- |
| -O3 | 0.056651, 0.056728, 0.056654 | 0.056654 | 0.00113308 | CRCs pass, 17.883 s |
| -O2 | 0.056699, 0.056664, 0.056593 | 0.056664 | 0.00113328 | CRCs pass, 17.881 s |

The measured difference between `-O2` and `-O3` is smaller than the variation
between repeats. These flags do not provide a meaningful speedup here.
The score describes this Linux/DDR/TLB system at 50 MHz; it is not a bare-metal
score or the maximum performance of the ISA.

Compiler: Clang 23.1.1, RV32IMA/ILP32, static musl, no FPU or compressed
instructions, no LTO. Full flags, CRCs and all reports are retained in
[12hz-coremark.json](results/12hz-coremark.json). The source revision and
checks are described in [README.md](README.md).

| Executable | SHA256 |
| --- | --- |
| O3 | `06605377a08cade9cfc809610e4733bdb981fc4a4f43805e5a4f102f5f0729d8` |
| O2 | `cf042323deb3fa6dbe3c58bea5697b5c25cb8496d3cae774916204bad29d7a8c` |


## Evidence

Full local evidence is retained in ignored build files:
`build/tlb-hardware-test.log`, `build/tlb-hardware-uart.log`,
`build/tlb-mesh-benchmark.json`, `build/tlb-mesh-comparison.json`,
`build/physical-benchmark.log`, and `build/tlb-coremark-benchmark.json`.
The UART reader remains open throughout the experiments.

## Timer and CPU-clock sweep

Each profile boots on the same physical Arty board. Tick comparisons at 50 MHz
use the same bitstream and identical CoreMark executables. Each score below is
the median of three performance-seed runs; all performance and validation-seed
runs passed CRC checks and the minimum ten-second duration. The 25/50 Hz and
62.5 MHz profiles use `-O3`; 12/100 Hz also include `-O2` cross-checks above.

| Kernel tick | CPU clock | CoreMark (-O3 median) | 16-point median ms | Received FPS |
| --- | --- | --- | --- | --- |
| 12 Hz | 50 MHz | 0.056654 | 91.05 | 5.44 |
| 25 Hz | 50 MHz | 0.052436 | 94.79 | 5.14 |
| 50 Hz | 50 MHz | 0.044088 | 117.94 | 4.54 |
| 100 Hz | 50 MHz | 0.027397 | 183.56 | 3.19 |
| 25 Hz | 62.5 MHz | 0.058275 | 81.62 | 5.93 |

25 Hz is the selected compromise: at 50 MHz it retains about 92.6% of 12 Hz
CoreMark throughput, with a 40 ms tick interval instead of about 83 ms. 50 Hz
retains about 77.8%, and 100 Hz about 48.4%. Tick frequency does not change
the hardware timebase or the CPU clock.

The selected runtime profile is 62.5 MHz / 25 Hz. Relative to 50 MHz / 25 Hz,
CoreMark rises about 11.1%; relative to 50 MHz / 12 Hz it rises about 2.9%.
The smaller gain than the 25% clock increase is consistent with memory and
clock-crossing costs; these tests do not measure a precise stall breakdown.
DDR remains at 325 MHz with an 81.25 MHz UI clock. Both Linux's device tree
and the UART/loader use the actual 62.5 MHz CPU/timebase frequency. OpenSBI
reports `aclint-mtimer @ 62500000Hz`; UART base baud is 3,906,250. Linux reaches
`/init` at 74.67 seconds in this profile. The 2 Mbaud upload takes 107.8 seconds,
versus 215.5 seconds at 1 Mbaud.

## Clock implementation and paired images

| CPU clock | MMCM divider | Setup slack | Hold slack | Runtime acceptance |
| --- | --- | --- | --- | --- |
| 50 MHz | 20 | +0.688 ns | +0.051 ns | Tick sweep and benchmarks |
| 55.56 MHz | 18 | +0.256 ns | +0.050 ns | Timing closure only |
| 62.5 MHz | 16 | +0.010 ns | +0.054 ns | Boot, mesh and CoreMark pass |

Both faster builds pass setup/hold, DRC, critical CDC and AXI bus-skew checks.
The 62.5 MHz margin is narrow; its tested workload acceptance does not establish
an absolute frequency ceiling or indefinite stability under every condition.
A longer check also passes: 10 performance iterations in 171.609 s
(0.058272 CoreMark), followed by 10 validation iterations
in 174.186 s. Both pass CRC validation. Full output is in
[cpu62-long-coremark.json](results/cpu62-long-coremark.json). The clock-aware
full SoC simulation boots Linux and executes its UART command in 761,494,750
simulated CPU cycles; physical runtime acceptance above is separate from simulation.

The default source profile remains 50 MHz and a 1 Mbaud loader; the board Linux
build now defaults to 25 Hz. The fast profile is explicitly selected with
`CPU_DIVIDE=16 BOOT_BAUD=2000000`, and requires its matching Linux image:

* Bitstream: `build/board/synapse32_linux_cpu62.bit`, SHA256
  `3c3ca4550289f1bf4c675013a5938f226c5db1e7e843fce9294c29ca82266024`.
* Linux: `build/linux-image-25hz-cpu62/fw_payload.bin`, SHA256
  `f1568fca0526fde02f7e1fde51a5387ee2d3912de5196ca68e9a74fd138ab093`.
* Known fallback bitstream: `build/board/synapse32_linux_tlb.bit` (50 MHz / 1 Mbaud).

Compact mesh records, full CoreMark output and the profile summary are in
[results](results/). The original logs are `build/{25hz,50hz,100hz,cpu62}-hardware-uart.log`;
62.5 MHz implementation reports are `build/board/cpu62-*.rpt`.

## Data cache at 62.5 MHz

Adding the 4 KiB, 16-byte-line, physical write-through D-cache improves
CoreMark by **13.2%**, from **0.058275 to 0.065954** (0.001055 CoreMark/MHz).
The board, 62.5 MHz CPU clock, 25 Hz tick, Linux payload and exact `-O3`
CoreMark executable are unchanged. Instruction fetches remain uncached.

The cached median uses three two-iteration performance runs, plus a separate
two-iteration validation-seed run. Every run exceeds ten seconds and validates
its CRCs. The earlier baseline uses three one-iteration runs and has a
ten-iteration cross-check recorded above.

| Workload | Without D-cache | With 4 KiB D-cache | Speedup |
| --- | --- | --- | --- |
| CoreMark, iterations/s | 0.058275 | 0.065954 | 1.132× |
| 16-point mesh, median ms | 81.619 | 71.7585 | 1.137× |
| 32-point mesh, median ms | 419.4525 | 386.079 | 1.086× |
| 64-point mesh, median ms | 2945.3675 | 2708.744 | 1.087× |

All 60 cached mesh frames pass independent exact geometry checks and match
the earlier frame IDs, point coordinates and triangle indices. Received FPS
is 6.38, 1.76 and 0.327 for 16/32/64 points. The Linux `/init` timestamp moves
from 74.67 to 67.85 seconds; this is a single boot comparison. These results
show a modest data-cache benefit and do not establish a memory-stall or
instruction-fetch cycle breakdown.

The physical bitstream is `build/board/synapse32_linux_dcache_cpu62.bit`,
SHA256 `b5f0ae2f22835f296b8ddcffca4cdfa2b4659e235513cd9abb8f6578936753d3`,
from source commit `d299677`. Full-board setup/hold slack is +0.138/+0.051 ns;
DRC, critical CDC and bus-skew checks pass. The unchanged payload SHA256 is
`f1568fca0526fde02f7e1fde51a5387ee2d3912de5196ca68e9a74fd138ab093`.

Raw evidence: [CoreMark](results/dcache-coremark.json),
[meshes](results/dcache-mesh.json),
[paired images and comparison](results/dcache-profile.json).
