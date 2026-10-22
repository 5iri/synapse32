# Linux application workloads

This suite measures real zlib and SQLite code on Synapse32 Linux using small,
fixed datasets. It complements CoreMark and the existing
[triangulator](../triangulator/README.md); it does not produce a CoreMark score.
Every sample validates its output. No FPGA performance result is implied by
building or testing the executable on a host.

Run the following commands from the repository root.

## Build and include in Linux

The existing RV32 Linux compiler wrapper and static C library must be prepared
first (`make -C fpga/arty_a7_35t llvm-toolchain`). Then:

```sh
python3 fpga/arty_a7_35t/workloads/build.py
```

The build downloads the versions in [sources.json](sources.json), verifies their
archive hashes on every invocation, extracts a fresh copy, and compiles a static
RV32IMA/ILP32 executable. Sources and binaries remain in the ignored board
`build/` directory. `--cc`, `--cache` and `--output` select explicit alternatives;
`WORKLOAD_CC` also selects the cross compiler.

Outputs in `fpga/arty_a7_35t/build/workloads/`:

- `workloads`: the static Linux executable (approximately 1.3 MB with the local
  LLVM/musl toolchain; check `manifest.json` for the exact size).
- `manifest.json`: source URLs and hashes, compiler version, all compiler/linker
  settings, harness hash, build identity, and executable SHA256.
- `initramfs.list`: the executable at `/bin/workloads`, manifest at
  `/etc/workloads.json`, and both upstream license notices.

Use initramfs inclusion for this binary. The board Linux wrapper accepts
`BUILD_WORKLOADS=1`; it combines the workload fragment with the triangulator and
any caller-supplied `INITRAMFS_EXTRA_LIST`. For example, to build a 25 Hz Linux
image matching a CPU divider of 17:

```sh
BUILD_WORKLOADS=1 LLVM=1 CPU_DIVIDE=17 KERNEL_HZ=25 \
  bash fpga/arty_a7_35t/build_linux.sh
```

The DTB clock and actual programmed bitstream must match. The suite does not
change CPU clock or kernel tick rate. To use the existing isolated
`coremark/build_tick_image.sh` workflow instead, include the generated workload
fragment in its `INITRAMFS_EXTRA_LIST`; combine additional fragments in one file
first. Do not include duplicate paths already present in the base initramfs.

The optional uploader reuses the triangulator's retained-UART writer without
opening a new serial reader or changing DTR:

```sh
python3 fpga/arty_a7_35t/workloads/deploy.py "$PORT" --log "$UART_LOG"
```

This installs `/tmp/workloads` and verifies its SHA256. Its conservative default
5 ms delay per transmitted byte makes a full 1.3 MB upload take **several hours**
after base64 expansion and acknowledgements. Prefer rebuilding the initramfs.
Faster delays require separate UART reliability testing.

## Run from the FPGA shell

After booting the resulting Linux image:

```sh
/bin/workloads 3
```

The optional number is the iteration count, 1–100 (default 3). A successful
invocation emits one `S32_WORKLOAD_CONFIG` JSON record, four `S32_WORKLOAD` JSON
records, and `S32_WORKLOAD_DONE 0`, then exits zero. Failures print
`S32_WORKLOAD_ERROR` and exit nonzero. This shell path needs no host Python.

For repeated runs from a host, keep the existing `test_board.py --keep-open`
reader running and pass its port and growing log to:

```sh
python3 fpga/arty_a7_35t/workloads/run.py "$PORT" \
  --log "$UART_LOG" \
  --output fpga/arty_a7_35t/build/workloads-linux-results.json \
  --cpu-mhz 58.823529 --kernel-hz 25 --repeats 3 --iterations 3
```

Use `--binary /tmp/workloads` after a serial deployment. The runner checks the
board executable's SHA256 against the build manifest before running it. It
requires the full ordered protocol, successful shell exit, matching build and
library versions, and independently calculated dataset checksums. An incomplete
run leaves `completed: false`, with completed samples retained for diagnosis.

The output records every raw sample, elapsed time, kernel and machine strings,
library source identity, manifest, host-supplied CPU/tick configuration and median
throughput. CPU MHz and kernel HZ are supplied by the caller, not detected by the
suite. Keep the same bitstream, DTB, executable, iterations and background load
for comparisons. Every process starts afresh; samples are retained in order and
no warm-up sample is silently discarded.

## Measured FPGA baseline

The accepted store-path bitstream runs this suite on the **Arty A7-35T at
58.823529 MHz**, with Linux **6.6.32-dirty / HZ=25**, 4 KiB instruction and data
caches, fetch queue and fast multiply enabled, an eight-entry store buffer and
fast store acknowledgement. Load forwarding is disabled. Three complete runs
at three iterations each passed all output checks:

| Case | Median elapsed time per run | Median throughput |
|---|---:|---:|
| zlib compression | 1.566227 s | 125,530 input bytes/s |
| zlib decompression | 2.138755 s | 1,470,822 input bytes/s |
| SQLite insert | 2.821231 s | 1,088.886 rows/s |
| SQLite query mix | 4.495183 s | 86.760 SQL statements/s |

These are measurements of the defined workloads and timing boundaries below.
SQLite uses memory for its database, journal and temporary storage, so these
numbers do not measure disk performance or durable writes. The query mix
combines statements with different costs; its statements/s figure applies to
that exact mix. The complete build manifest, every raw sample/output, and
bitstream/Linux payload/frozen UART capture hashes are preserved in
[results/store-path-baseline.json](results/store-path-baseline.json). This is
the previous accepted hardware baseline; it makes no performance claim about
the new RTL until that configuration passes timing and is measured on the board.

A transcript captured manually can also be validated:

```sh
python3 fpga/arty_a7_35t/workloads/report.py captured-workloads.log \
  --manifest fpga/arty_a7_35t/build/workloads/manifest.json \
  --output fpga/arty_a7_35t/build/manual-workloads-results.json
```

## Measured operations and limits

| Case | Timed operation | Output validation |
|---|---|---|
| `zlib_compress` | `compress2`, level 6, on a deterministic 65,536-byte synthetic sensor log; repeated `iterations` times | Decompress and compare every byte after each timed call; fixed FNV1a input checksum and 9,629-byte stream length checked by host |
| `zlib_decompress` | `uncompress` on the same stream, `16 × iterations` times | Compare every restored byte after each timed call; fixed checksum checked by host |
| `sqlite_insert` | One transaction inserting 1,024 deterministic integer rows through a prepared statement; repeated `iterations` times | Row count and sum queried after each timed transaction; sum 509,976 checked by host |
| `sqlite_queries` | Per iteration: 128 primary-key lookups, one grouped aggregate/sort, and one self-join aggregate | Every result checked during the timed loop; aggregate checksum 321,362,488 per iteration checked by host |

All durations use Linux `CLOCK_MONOTONIC` and include preemption while the timed
operation runs. Clock calls add a small fixed measurement cost. Allocation and
dataset generation, SQL preparation, table deletion between insertion trials,
and final database close are excluded. Query result consumption/reset and query
validation are included; compression byte comparisons and insert validation are
excluded. The different cases therefore have different explicitly defined
timing boundaries.

The SQLite database and journal are in memory, with temporary storage in memory.
The build disables threads, extension loading and the optional memory-status
counters, uses a 256 KiB default page-cache budget, and leaves normal SQL
execution and result checking intact. Exact defines are recorded in the
manifest. This measures CPU/cache/allocator/SQL behavior and **does not measure
storage throughput, durable transactions or filesystem synchronization**.
The query throughput unit counts the fixed mix of 130 SQL statements per
iteration; its individual statements have different costs.

The compression input mixes repeated text with deterministic pseudo-random
bytes. This is a reproducible application kernel, not a representative corpus
for every compression workload. The static build uses software support for any
floating-point operations required by the C library or SQLite on RV32IMA.

## Correctness checks on a host

```sh
python3 fpga/arty_a7_35t/workloads/build.py --native
WORKLOAD_TEST_BINARY=fpga/arty_a7_35t/build/workloads-native/workloads \
  python3 -m unittest discover -s fpga/arty_a7_35t/workloads -p 'test_*.py' -v
```

This checks the native executable at 1 and 3 iterations, argument rejection,
independent dataset oracles, damaged checksums, zero/invalid timing, wrong build
identity and incomplete/duplicated/reordered captures. Native elapsed times are
host measurements and must not be reported as FPGA results. The UART runner
rejects a native build manifest.

## Upstream sources and licenses

- [zlib 1.3.2](https://zlib.net/), pinned release archive and SHA256 in
  `sources.json`. It uses the zlib license; the complete upstream `LICENSE` is
  distributed beside the executable and in the initramfs fragment.
- [SQLite 3.54.1](https://www.sqlite.org/download.html), pinned amalgamation
  archive, SHA256 and upstream-published SHA3-256 in `sources.json`.
  [SQLite is public domain](https://www.sqlite.org/copyright.html); the opening
  copyright disclaimer in its unmodified `sqlite3.h` is copied beside the binary
  and included in the initramfs fragment.

Upstream algorithms are compiled from verified archives without source edits.
Updating either pin is an explicit benchmark configuration change: update its
hashes, review release notes, rebuild, recheck output oracles, and establish a new
baseline.
