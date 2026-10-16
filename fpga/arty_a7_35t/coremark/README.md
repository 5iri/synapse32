# CoreMark under FPGA Linux

This builds an RV32IMA static Linux executable on the host, then runs it on
Synapse32 under Linux. It does not install a native compiler on the FPGA.
The baseline CPU runs at 50 MHz, with separate eight-entry upstream TLBs and no
instruction/data caches. The board Linux build defaults to 25 Hz after the
physical tick sweep. A 62.5 MHz / 25 Hz runtime profile is also tested; see
[results](RESULTS.md) for measured comparisons and matching image hashes.

The build pins official EEMBC CoreMark commit
`b56889a7bd9d5624fbeff2a73ba69878e6a9c146` and checks all six files against
the supplied `coremark.md5`. The next upstream merge changes only a comment
in `coremark.h` without updating its checksum. None of the benchmark algorithms
are modified. Only the platform timer changes from `CLOCK_REALTIME` to
`CLOCK_MONOTONIC`. The standard workload uses 2,000 bytes, static data, all
three algorithms and one execution context. Software floating point is used
for timing/reporting; this CPU has no FPU.

## Build and transfer

After preparing the LLVM/musl toolchain, from the repository root:

```sh
make -C fpga/arty_a7_35t coremark
COREMARK_OPT=-O2 COREMARK_OUT="$PWD/fpga/arty_a7_35t/build/coremark-o2" \
  bash fpga/arty_a7_35t/coremark/build.sh
```

`COREMARK_CC`, `COREMARK_DIR` and `COREMARK_OUT` select a compiler, source
checkout and output directory. `COREMARK_OPT` accepts `-O2`, `-O3` (default)
or `-Os`. Compiler version, full relevant flags and source revision are saved
beside the executable. No LTO or profile-guided optimization is used.

Keep the existing `test_board.py --keep-open` reader running. Use its actual
UART port and log path, closing other typing/viewer clients first. For example:

```sh
.venv/bin/python fpga/arty_a7_35t/triangulator/deploy.py /dev/ttyUSB2 \
  --log fpga/arty_a7_35t/build/tlb-hardware-uart.log \
  --binary fpga/arty_a7_35t/build/coremark/coremark \
  --destination /tmp/coremark-o3 --byte-delay 0.001
.venv/bin/python fpga/arty_a7_35t/triangulator/deploy.py /dev/ttyUSB2 \
  --log fpga/arty_a7_35t/build/tlb-hardware-uart.log \
  --binary fpga/arty_a7_35t/build/coremark-o2/coremark \
  --destination /tmp/coremark-o2 --byte-delay 0.001
```

The uploader acknowledges each chunk and checks SHA256 on the FPGA. It suppresses
informational console printk messages during transfer and restores the prior
console log level afterward. Normal and here-document shell prompts are
removed from parsed responses; raw UART logs are retained unchanged. The
1 ms byte delay is used on the TLB build; slower hardware can use the default.
Both executables live in RAM and disappear on reboot.

## Run and interpret

From the FPGA's Linux console, the standard performance and validation runs are:

```sh
/tmp/coremark-o3 0 0 0x66 1 7 1
/tmp/coremark-o3 0x3415 0x3415 0x66 1 7 1
```

The fourth argument is the iteration count. One iteration exceeds ten seconds
on this configuration; increase it if a faster machine finishes too quickly.
Zero enables upstream calibration, which starts at ten iterations and can
take several minutes on this CPU. The host runner performs three performance runs per compiler setting and one
validation-seed run per setting, requiring successful CRC validation, the
standard seed checksum, exit status zero, and at least ten timed seconds:

```sh
.venv/bin/python fpga/arty_a7_35t/coremark/run.py /dev/ttyUSB2 \
  --log fpga/arty_a7_35t/build/tlb-hardware-uart.log \
  --output fpga/arty_a7_35t/build/coremark-results.json
```

Pass `--cpu-mhz 62.5` on the faster profile so normalization uses the actual
clock. `--optimizations o3` selects just that variant, `--repeats` changes the
number of performance samples, and `--iterations 10` runs a longer check.

CoreMark is timed iterations per second; CoreMark/MHz divides that score by
the actual CPU frequency in MHz (50 by default).
Timing includes Linux interrupt and scheduling overhead. UART transfer, runtime
calibration and report printing are outside the timed benchmark. These are
local measurements, not an EEMBC-certified or submitted score. A short run or
CRC failure is not a valid score. The results establish performance at the
tested clock, not the maximum stable FPGA clock or a thermal limit.

The companion `run_mesh.py` measures fixed 16-, 32- and 64-point sequences and
saves the original mesh records for matching against previous bitstreams.
Its received FPS also includes serialization/UART costs. The reader's polling
interval limits arrival-time precision, so use the computation times for
the primary hardware comparison.

## Isolated kernel tick experiments

`build_tick_image.sh` reuses an existing configured Linux build in a separate
directory, retaining the baseline image and including both CoreMark binaries
in `/tmp`. After building the baseline Linux image and executables:

```sh
KERNEL_HZ=25 bash fpga/arty_a7_35t/coremark/build_tick_image.sh
KERNEL_HZ=50 bash fpga/arty_a7_35t/coremark/build_tick_image.sh
```

`CPU_CLOCK_HZ` sets the actual hardware timebase and UART clock for an
experiment; `TICK_IMAGE_DIR`, `TICK_KERNEL_DIR` and `LINUX_SOURCE_BUILD` select
absolute output/cache paths. A fast profile must use `CPU_CLOCK_HZ=62500000`
and its matching 62.5 MHz bitstream. Changing these values does not change
the FPGA clock by itself. The normal board Linux builder instead derives
the clock from `CPU_DIVIDE`, as described in the parent README.

Upstream run rules: https://github.com/eembc/coremark#run-rules
