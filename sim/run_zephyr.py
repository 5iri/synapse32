"""Run a prebuilt Zephyr image on the synapse32 cocotb testbench.

Usage:
    python3 sim/run_zephyr.py [path/to/zephyr.bin]

Defaults to /tmp/zephyr_synapse32_build/zephyr/zephyr.bin.
The bin is converted to a Verilog hex file and loaded via $readmemh
in unified_mem.v.
"""
import logging
import os
import subprocess
import sys
from decimal import Decimal
from pathlib import Path

import cocotb
from cocotb_test.simulator import run
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ClockCycles

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

DEFAULT_BIN = Path("/tmp/zephyr_synapse32_build/zephyr/zephyr.bin")
SIM_DIR = Path(__file__).resolve().parent
REPO_ROOT = SIM_DIR.parent
RTL_DIR = REPO_ROOT / "rtl"

CPU_CLOCK_HZ = 100_000_000
ZEPHYR_BAUD = 115200
SUCCESS_NEEDLE = b"Hello World"


class UartMonitor:
    def __init__(self, uart_tx, clk, cpu_clock_freq, baud_divisor):
        self.tx = uart_tx
        self.clk = clk
        self.baud_period_cycles = baud_divisor
        self.received = bytearray()
        self.monitoring = True
        log.info(
            "UART monitor: clk=%dHz, divisor=%d → ~%d baud",
            cpu_clock_freq, baud_divisor, cpu_clock_freq // baud_divisor,
        )

    async def run(self):
        while self.monitoring:
            while self.tx.value != 0:
                await RisingEdge(self.clk)
                if not self.monitoring:
                    return
            # 1.5 bit periods to centre of bit 0
            await Timer(Decimal(self.baud_period_cycles * 1.5 * 10), units="ns")
            byte = 0
            for bit in range(8):
                byte |= (int(self.tx.value) << bit)
                if bit < 7:
                    await Timer(Decimal(self.baud_period_cycles * 10), units="ns")
            # stop bit
            await Timer(Decimal(self.baud_period_cycles * 10), units="ns")
            self.received.append(byte & 0xFF)

    def text(self):
        return self.received.decode("ascii", errors="replace")

    def stop(self):
        self.monitoring = False


def bin_to_hex(bin_path: Path, hex_path: Path):
    """Convert a flat binary into the Verilog readmemh format unified_mem expects."""
    subprocess.run([
        "riscv64-unknown-elf-objcopy",
        "-I", "binary",
        "-O", "verilog",
        "--verilog-data-width=4",
        "--reverse-bytes=4",
        str(bin_path),
        str(hex_path),
    ], check=True)


@cocotb.test
async def run_zephyr(dut):
    log.info("Starting Zephyr cocotb run")

    clk = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clk.start())

    dut.rst.value = 1
    dut.software_interrupt.value = 0
    dut.external_interrupt.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0

    baud_div = CPU_CLOCK_HZ // ZEPHYR_BAUD
    monitor = UartMonitor(dut.uart_tx, dut.clk, CPU_CLOCK_HZ, baud_div)
    monitor_task = cocotb.start_soon(monitor.run())

    max_cycles = 20_000_000
    found = False
    last_log_cycle = 0
    for cycle in range(max_cycles):
        await RisingEdge(dut.clk)
        if SUCCESS_NEEDLE in monitor.received and not found:
            log.info("Detected '%s' at cycle %d, draining trailing output", SUCCESS_NEEDLE.decode(), cycle)
            found = True
            # 1 byte = 10 baud bits = baud_div*10 cycles. Drain ~80 bytes worth.
            await ClockCycles(dut.clk, baud_div * 10 * 80)
            break
        if cycle - last_log_cycle >= 200_000:
            last_log_cycle = cycle
            pc = int(dut.pc_debug.value) if hasattr(dut, "pc_debug") else 0
            log.info("cycle=%d pc=0x%08x rx_len=%d", cycle, pc, len(monitor.received))

    monitor.stop()
    await monitor_task

    text = monitor.text()
    print(f"\n{'=' * 60}\nUART OUTPUT ({len(monitor.received)} bytes):\n{text}\n{'=' * 60}\n", flush=True)
    dut._log.info("UART output (%d bytes):\n%s", len(monitor.received), text)

    assert found, f"timed out after {max_cycles} cycles without seeing '{SUCCESS_NEEDLE.decode()}'"


def rtl_sources():
    """Return RTL sources in a stable order for cocotb_test."""
    sources = sorted(str(path) for path in RTL_DIR.rglob("*") if path.suffix in {".v", ".sv"})
    if not sources:
        raise FileNotFoundError(f"No Verilog sources found under {RTL_DIR}")
    return sources


def run_cocotb(hex_path: Path):
    """Run the Zephyr cocotb test without depending on a makefile cwd."""
    if not RTL_DIR.exists():
        raise FileNotFoundError(f"RTL directory not found: {RTL_DIR}")

    run(
        verilog_sources=rtl_sources(),
        toplevel="top",
        module="run_zephyr",
        testcase="run_zephyr",
        includes=[str(RTL_DIR / "include"), str(RTL_DIR)],
        simulator="verilator",
        timescale="1ns/1ps",
        defines=[f'INSTR_HEX_FILE="{hex_path}"'],
        python_search=[str(SIM_DIR)],
        sim_build=str(SIM_DIR / "sim_build_zephyr"),
        force_compile=True,
        waves=os.getenv("WAVES", "0") == "1",
    )


if __name__ == "__main__":
    bin_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_BIN
    if not bin_path.exists():
        log.error("Zephyr bin not found: %s — did you run `west build`?", bin_path)
        sys.exit(1)

    build_dir = SIM_DIR / "build"
    build_dir.mkdir(exist_ok=True)
    hex_path = build_dir / "zephyr.hex"
    bin_to_hex(bin_path, hex_path)
    log.info("Wrote %s (%d bytes from %s)", hex_path, hex_path.stat().st_size, bin_path)

    run_cocotb(hex_path)
