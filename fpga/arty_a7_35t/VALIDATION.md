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
| Physical board | Unverified: no Arty USB UART/JTAG device available |

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
