# Memory-path benchmark

This bare-metal workload measures the CPU and memory fabric separately from Linux.
It uses the existing CoreMark startup, linker layout, UART and coherent RV32
counter readers. Code, data and stack live in DDR; the measured hot buffers fit
the 4 KiB D-cache. No CoreMark algorithm is executed by this program.

Permanent measurements are in
[`data-path-performance.json`](../coremark/results/data-path-performance.json).
That file preserves every sample and profiling delta, plus the hashes and paths
of ignored raw logs. Accepted store-path hardware validates the microbenchmarks,
bare-metal/Linux CoreMark and mesh. The clock-constraint audit preserved all
physical clock periods. Experimental load forwarding is recorded separately.

## Workload and measurement

Each case performs 65,536 operations. Preparation, checksum verification and UART
printing happen outside the CSR timing window. Store cases include a final
`fence rw,rw` so queued writes have completed before timing ends.

| Case | Operation and working set |
| --- | --- |
| `register_baseline` | 16 unrolled dependent ADDIs; loop/call overhead included. |
| `dependent_loads` | 16 unrolled pointer loads through one 512-byte ring. |
| `independent_loads` | Four interleaved chains through the same 512-byte ring. |
| `stores_same_word` | 16 stores to one hot word. |
| `stores_adjacent_words` | Repeated stores to four adjacent hot words. |
| `stores_streaming_hot` | Stores through a 512-byte hot buffer. |
| `stores_sparse` | One store followed by 32 ADDIs, repeated four times per loop. |
| `loads_streaming_cold` | One word per 16-byte line through 64 KiB, repeatedly. |

The sparse case reports stores as its operation count, while including its helper
instructions in cycles and instructions. It exposes acknowledgement overhead
without keeping the write queue full; its cycles/store are the whole loop cost.
The cold case's working set exceeds the cache and deliberately measures misses.
All stores and load endpoints/checksums are verified with real memory accesses.

`cycles` and `instructions` enclose the function call, loop and final fence. The
instruction CSR counts EX completions in this CPU, rather than WB retirement.
The 16 `profiling` counters surround that window and additionally include some
snapshot/counter overhead. Their events overlap and cannot be added into a CPI
breakdown. `muldiv_wait` can include a younger M instruction held behind an older
memory access before arithmetic starts; a larger count does not imply more
arithmetic work. UART activity is outside the timed window.

The first dependent/independent sample has 4,104/4,109 I-cache misses in both the
physical baseline and AXI simulation; later samples have three. All first samples
are retained. Medians describe the repeated steady-state path. A likely cause is
a canceled speculative fetch past the taken loop branch: stale fills are drained
without caching, until final fall-through installs that line. This remains a
hypothesis pending a direct request/cancel trace; it is not a DDR instability
finding. The benchmark does not explicitly warm its instruction paths.

## Build and simulate

Run commands from the repository root. The pinned source/toolchain cache must
already exist from the board's CoreMark build. Build the simulation payload with
an explicit nominal timer frequency and the board's UART divisor scale:

```sh
CPU_CLOCK_HZ=1000000 UART_DIVISOR_SCALE=16 \
  bash fpga/arty_a7_35t/memory_bench/build.sh

AXI_RESPONSE_CYCLES=20 STORE_BUFFER_DEPTH=4 MEMORY_BENCH_REPEATS=3 \
  LOAD_FORWARDING=0 FAST_STORE_ACK=0 \
  bash fpga/arty_a7_35t/test_memory_bench.sh \
  build/memory-bench-1000000/memory-bench.bin
```

The test script changes directory to `fpga/arty_a7_35t`; its binary argument is
relative to that directory. Repeat with `LOAD_FORWARDING=1`, `FAST_STORE_ACK=1`,
or both. The default build directories encode both switches. Override
`MEMORY_BENCH_SIM_BUILD`, `MEMORY_BENCH_SIM_LOG` and `MEMORY_BENCH_SIM_REPORT` to
retain separately named experiments. `JOBS` controls Verilator build parallelism.

The model uses the actual CPU, caches, queue, UART wires and AXI bridge. Reads and
writes complete after the configured synthetic delay, with independently varied
AXI ready signals. The 1 MHz constant converts timer ticks and sets the UART;
simulation does not establish FPGA maximum frequency or real DDR latency.

The measured AXI20 baseline and load-forwarding variant use the same payload
SHA256 `24f8f3c42307071e00579c92057f5afc581413b35b279fa930659546132686d2`.
Their median dependent-load costs are 3.252838 and 2.315323 cycles/operation.
An isolated warm, straight-line load trace verifies exact grant, response and
EX-completion spacing of three clocks becoming two. Independent loads remain
about 2.3156 cycles/operation. Fast store acknowledgement saves about one clock
per sparse store; sustained AXI20 hot stores remain about 28 cycles/store.

## Physical run and report validation

Use a payload clock matching the actual programmed design. The original div17
baseline used the following firmware metadata:

```sh
CPU_CLOCK_HZ=58823529 UART_DIVISOR_SCALE=16 \
  bash fpga/arty_a7_35t/memory_bench/build.sh

.venv/bin/python fpga/arty_a7_35t/memory_bench/run.py /dev/ttyUSB2 \
  --image fpga/arty_a7_35t/build/memory-bench-58823529/memory-bench.bin \
  --cpu-hz 58823529 --baud 2000000 --repeats 5 \
  --log fpga/arty_a7_35t/build/memory-run.uart.log \
  --output fpga/arty_a7_35t/build/memory-run.json
```

Select the connected board's actual serial path. The runner uploads into the
existing loader, changes to 115,200 baud, checks the firmware clock banner, sends
`r\n` at each `S32_MEMORY_BENCH_READY`, and waits for `S32_MEMORY_BENCH_DONE:0`.
UART access must have one owner. The runner does not program a bitstream.

Each result is a `S32_MEMORY_BENCH ` JSON line. The strict parser requires all
eight cases in order, positive integer counters, `validated: true`, and exactly
the requested number of successful completed runs. Revalidate a saved capture:

```sh
python3 fpga/arty_a7_35t/memory_bench/memory_report.py \
  fpga/arty_a7_35t/build/memory-run.uart.log --repeats 5 \
  --output fpga/arty_a7_35t/build/memory-run.json
```

The five-repeat physical baseline validates all 40 records. Its median dependent
and independent costs are 3.253220 and 2.315948 cycles/load; sustained hot stores
cost about 19.194 cycles/store. These are measured cycle ratios. The audited
constraint correction preserves the actual clock period. These are not AXI20 store
costs. No sample has been removed from the permanent evidence.

The fixed CoreMark simulation payload (`c24f9070…f7fe`) separately improves from
1.561573 to 1.631428 CoreMark/MHz with load forwarding, with exactly 12,749,965
timed instructions for both 50-iteration performance runs. This is a synthetic
memory comparison. Larger cache/depth sweeps, fault-priority checks and full
memory-wait regressions are recorded in the permanent JSON.

The synthetic combination (`LOAD_FORWARDING=1`, `FAST_STORE_ACK=1`,
`STORE_BUFFER_DEPTH=8`) reaches 1.712329 performance and 1.717564 validation
iterations/second at the nominal 1 MHz timer setting, with the same fixed payload.
Its div17 implementation failed setup timing (WNS -4.427 ns), so no bitstream
was written. The fallback disables load forwarding while retaining fast store
acknowledgement and eight queue entries: its frozen-source simulation validates
both seeds at 1.638431/1.639344 iterations/second. Its normal route failed setup
(WNS -0.524 ns); bounded post-route optimization recovered setup/hold/pulse slack
of 0.016/0.012/0.206 ns and produced the accepted `store-path-div17` bitstream.
That bitstream validates all 40 microbenchmark records; sparse stores improve
from 37.270050 to 36.270065 cycles/store. Bare-metal CoreMark improves from
102.796272 to 106.809701 (+3.904%), and aligned Linux from 97.646714 to
101.332523 (+3.776%), each with three performance and one validation run.
Both run at 58.823529 MHz; Linux reaches 94.872% of bare-metal throughput.
The accepted implementation passes the clock methodology, CDC and skew gates.
The separate clock audit preserves all 23 periods, waveforms and source pins;
only the temperature synchronizer's first stage uses the narrow 20 ns bound.
The formatted-response/load-forwarding div18 candidate also failed setup
(WNS -2.145 ns); load forwarding remains experimental and disabled on the board.
