# CoreMark on Synapse32

Build the official EEMBC CoreMark workload for Linux or run it directly in
machine mode without OpenSBI or an OS. This directory contains benchmark
software only; it does not change the CPU, memory system, caches or board logic.

Both builds pin EEMBC revision `b56889a7bd9d5624fbeff2a73ba69878e6a9c146`,
check the six published `coremark.md5` checksums and reject modified algorithm
sources. The next EEMBC merge changes a comment without updating its checksum;
the pinned parent passes the full supplied manifest. Algorithms remain
unmodified: 2,000 bytes, static allocation, one context, all three algorithms,
RV32IMA/Zicsr/Zifencei, ILP32, no compressed instructions or hardware floating
point. Soft floating point is used for reporting outside the timed workload.

## Build

Requirements: Bash, Git, Python 3, GNU coreutils, and a RISC-V cross compiler
with RV32IMA ILP32 headers/libraries. Linux needs static libc support. Bare
metal needs a C library/math implementation and compiler runtime built for
this ISA/ABI. A suitable Clang/sysroot wrapper can be supplied as `COREMARK_CC`.
The scripts save compiler version, flags and source revision beside each image.
They do not install a compiler or download one.

```sh
make -C benchmarks/coremark linux
make -C benchmarks/coremark baremetal
```

Linux defaults to `riscv32-unknown-linux-gnu-gcc`, bare metal to
`riscv32-unknown-elf-gcc`. Set `COREMARK_CC` to another compatible compiler;
`COREMARK_DIR` selects a clean checkout of the pinned EEMBC sources. The output
defaults to `build/linux` or `build/baremetal` inside this directory and can
be overridden with `COREMARK_OUT` or `COREMARK_BAREMETAL_OUT` respectively.
Linux accepts `COREMARK_OPT=-O2`, `-O3` (default), or `-Os`; bare metal uses
`-O3` to match the default Linux comparison. Neither uses LTO or PGO.

Bare-metal overrides:

```sh
CPU_CLOCK_HZ=50000000 UART_DIVISOR_SCALE=1 \
  COREMARK_OBJCOPY=riscv32-unknown-elf-objcopy \
  COREMARK_OBJDUMP=riscv32-unknown-elf-objdump \
  bash benchmarks/coremark/build_baremetal.sh
```

`CPU_CLOCK_HZ` must match the actual CPU/timer clock (default 50 MHz);
changing it does not change hardware frequency. `UART_DIVISOR_SCALE=1` matches
upstream `top.v`; use 16 only for a UART integration that multiplies the divisor
by 16. `COREMARK_RUNTIME_ARCHIVE` selects a compiler-builtins archive for Clang
instead of the default `-lgcc`. GNU and LLVM objcopy/objdump are supported.

The bare-metal build produces `coremark.elf`, a raw `coremark.bin` linked at
`0x80000000`, and a little-endian, 32-bit-word `coremark.hex` for `$readmemh`.
It checks that the image contains no `ecall` instructions. It also compares
the list/matrix/state object instructions and the `iterate` function bytes
against compilation with EEMBC's Linux platform header; link addresses can
still differ. The check is saved in `object-code-check.txt`.

## Run

On target Linux, copy the static executable to RAM and capture console output:

```sh
sh run_linux.sh /tmp/coremark 1 > coremark-linux.log
```

This runs three performance repeats and one validation-seed run. The final
argument is iterations per run: increase it until every timed run exceeds
ten seconds. Zero enables EEMBC's calibration, which starts at ten iterations
and can take minutes on a slow target. Linux uses `CLOCK_MONOTONIC`.

For bare metal, load the ELF with a debugger or the raw image with the existing
target loader and start at `_start`. The startup initializes SP/GP and BSS,
disables translation and interrupts, and installs a diagnostic trap handler.
Code, static data and the stack reside in the existing 64 MiB RAM region;
the stack starts at `0x84000000` and grows downward. No Linux ABI/syscalls are
used. UART is polled at `0x20000000`, with the existing register spacing of four
bytes and 115200 baud; CLINT `mtime` is read at `0x0200bff8`.

The target first checks its timer for two seconds against the cycle counter
and emits `S32_BAREMETAL_READY`. Send these lines through its console:

```text
p 0
p 0
p 0
v 0
```

`p` selects standard performance seeds; `v` selects validation seeds. The number
is iterations (zero selects EEMBC calibration). Each response includes the
standard CoreMark report, timed CPU cycles, retired instructions and
`S32_BAREMETAL_DONE:0`. The program then waits for another command. A trap
prints cause/PC/value and stops. The timer and UART assume the clocks and
register map above; no cache configuration or maintenance is performed.

On the host, validate either console capture and export JSON:

```sh
python3 benchmarks/coremark/report.py coremark-linux.log --cpu-mhz 50 --output results.json
make -C benchmarks/coremark test
```

Reports must have correct 2K seeds and algorithm CRCs, a successful validation
message, at least ten timed seconds, and a score consistent with iterations
and elapsed time. Short pilot runs are rejected unless explicitly excluded
with `--skip-short-runs`; excluded pilots never become results. The parser
also accepts the optional bare-metal cycle/instruction counters and reports CPI.
These are local benchmark measurements, not EEMBC-certified/submitted scores.

Compare Linux and bare metal with the same CPU clock, memory integration,
cache configuration, compiler and workload. The difference includes address
translation, traps/interrupts, scheduling and link/data layout effects; it
does not isolate scheduler overhead. Simulation RAM and external DDR can
have very different latency. [Measured cacheless comparison](RESULTS.md).

Upstream benchmark and run rules: <https://github.com/eembc/coremark>.
