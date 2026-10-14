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

The corrected final run returned `K` in 215.5 seconds, reached userspace at
131.2 seconds and printed `PASS: physical FPGA reached Linux shell and executed
UART command`. Its `--keep-open` UART reader remains connected so the board
retains the loaded image. Logs: `build/hardware-live-test.log` and
`build/hardware-live-uart.log`.

### Subsequent interactive acceptance

Typing a later command on the normal bitstream echoed its first character and
then halted with LED3 lit, indicating a latched fabric fault. A temporary ILA
build captures CPU PC, instruction/data bus and virtual addresses, translation
context, and fatal-error signals. It was armed for twelve minutes and did not
reproduce the fault: both a command after five seconds of idle and a command
typed through `console.py` returned `TERMINAL_OK`.

The current debug run's UART reader remains open at
`build/fault-reproduction-uart.log`. The Linux-host console client was verified
against it in a real terminal and detached without closing the reader. The
original fault is not yet explained; these results establish basic boot and
interactive use, not sustained runtime reliability. Debug artifacts are local
under `build/board/fault-debug.*` and `cpu-fault-capture.log`.

```text
1ba296a2ad4f893b03c21aada5bdbb00f6226e369e04d1b48046419ecfc9c584  12 Hz fw_payload.bin
```
