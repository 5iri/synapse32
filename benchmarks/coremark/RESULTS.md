# Cacheless CoreMark comparison

Physical measurements on 2026-10-16, one hart at 50 MHz, external DDR RAM,
with **neither instruction nor data cache**. The Linux configuration has
separate eight-entry translation caches, Linux 6.6.32 and a 25 Hz tick.
Bare metal runs in M-mode with translation and interrupts disabled, without
OpenSBI or Linux. Both use Clang 23.1.1, `-O3`, RV32IMA/Zicsr/Zifencei ILP32,
2,000-byte static data and all three EEMBC algorithms. The timed algorithm
object instructions match between the two platform headers.

The external-DDR integration used for these measurements is separate work;
its board logic, bitstreams, cache implementations and Linux build are not
included here. These numbers describe that configuration, rather than the
upstream zero-wait simulation RAM. Its existing bitstream SHA256 is
`18d6f26367de347e0c90dfafd9af64fdf0b6679eb83f999505dd9c16910d81f9`.

See [raw reports and metadata](results/cacheless-50mhz.json) for the accepted
runs, short calibration pilot, timer self-test, image hashes and compiler flags.
Short pilots are excluded from scores. The Linux baseline was measured earlier
on the same board/configuration; it is not a simultaneous sample.

The observed gap combines the Linux execution environment, address translation,
interrupts and link/data layout. It does not establish a cycle breakdown or
show that the difference is inherent to Linux. No cache changes are required
or proposed by this benchmark package.

| Environment | Median CoreMark | CoreMark/MHz |
| --- | --- | --- |
| Bare metal, M-mode, interrupts off | 3.332667 | 0.066653 |
| Linux, 25 Hz | 0.052436 | 0.001049 |

Bare-metal throughput is **63.56×** the Linux baseline; Linux achieves **1.57%**
of bare-metal throughput on this configuration. Each environment has three
performance repeats and a separate validation-seed run. All accepted runs
exceed ten seconds and validate the reference CRCs. Bare metal used 50
iterations per accepted run; Linux used one iteration per run.

The packaged bare-metal binary SHA256 is
`09c650b1a4b6653d9af761b29873b6c45086ab8da06b3b2a0d18230fdb6f0aed`. Its two-second timer self-test took
1.999587 seconds on the host and counted 100000540 CPU cycles. The target also reports
cycles and retired instructions for each timed benchmark region.

## Fast-memory isolation

CoreMark's code, data, BSS and stack were moved to independent fast host-RAM
ports in Verilator 5.052. No caches or OS were added. The physical core's
iterative multiply/divide implementation is retained for the two matched
experiments. An additional upstream-core run uses its combinational arithmetic
and is listed separately. The memory change removes the external DDR path,
its shared arbitration, clock crossing and board adapters collectively.

| Configuration | Memory response | Timed CPI | CoreMark/MHz |
| --- | --- | --- | --- |
| Physical CPU, iterative M | Uncached external DDR | 58.8388 | 0.066653 |
| Same CPU, iterative M | One-cycle simulated RAM | 3.7585 | 1.043406 |
| Same CPU, iterative M | Zero-wait simulated RAM | 2.6069 | 1.504348 |
| Upstream CPU, combinational M | Zero-wait simulated RAM | 1.3816 | 2.838490 |

The matched zero-wait model improves normalized throughput by **22.6×**;
the one-cycle model improves it by **15.7×**. These interventions strongly
identify the memory integration as the main limit on the current uncached
physical result. They do not separate DDR device latency from the surrounding
protocol/adapter costs or establish a physically achievable RAM clock.

Simulations use a nominal 1 MHz CPU/timer so a duration-compliant workload
needs fewer simulated clocks. All three models run 50 performance and 50
validation iterations, exceeding ten simulated seconds per seed with correct
reference CRCs. Performance runs retire **exactly 12,749,961 instructions**
in every model and the physical reference; validation runs all retire
12,722,675. Host clock ticks and the RTL cycle counter agree exactly.
The list/matrix/state object files are byte-identical between the physical
50 MHz and simulated 1 MHz builds; `iterate` instruction bytes also match.
Timer/reporting code differs outside the timed workload.

These are deterministic single performance/validation runs per memory model.
The nominal simulation frequency and combinational arithmetic result do not
claim FPGA timing closure or Fmax. The one-cycle memory model is not a BRAM
implementation. The hardware `instret` counter records valid EX completions;
this trap-free timed workload contains no WFI/fence holds, and its instruction
count is invariant across the tested memory latencies.

[Raw simulation reports, CPU RTL revisions and metadata](results/fast-memory.json)
contain cycle counts, normalized scores and reproducibility details. The
experiment is implemented entirely in the benchmark harness, with no CPU,
cache or board RTL changes.
