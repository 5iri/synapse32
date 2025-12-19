import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
import subprocess
import os
import logging
from pathlib import Path
from collections import defaultdict

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

GPIO_BASE = 0x20001000
GPIO_DATA_ADDR = GPIO_BASE + 0x00  # 0x20001000
GPIO_DIR_ADDR  = GPIO_BASE + 0x04  # 0x20001004
GPIO_IN_ADDR   = GPIO_BASE + 0x08  # 0x20001008

GPIO_LOG_BASE = GPIO_BASE + 0x0C   # First word after GPIO_IN
CPU_DONE_ADDR = GPIO_BASE + 0x40   # Completion flag location

OUTPUT_MASK = 0x00000007
OUTPUT_PATTERNS = [0x0, 0x1, 0x3, 0x7]
LOG_ENTRY_COUNT = 2 + len(OUTPUT_PATTERNS) + 2  # reset data/dir + samples + final dir/data


def gpio_log_addr(index: int) -> int:
    """Compute the log word address inside the GPIO window."""
    return GPIO_LOG_BASE + 4 * index


def compile_gpio_c():
    """Compile sim/gpio_test.c into an instruction-memory hex file."""
    log.info("Compiling gpio_test.c to RISC-V binary...")

    # Locate repo root (where rtl/ lives)
    root_dir = os.getcwd()
    while not os.path.exists(os.path.join(root_dir, "rtl")):
        parent = os.path.dirname(root_dir)
        if parent == root_dir:
            raise FileNotFoundError("rtl directory not found in current or parent directories.")
        root_dir = parent
    log.info(f"Using repository root: {root_dir}")

    rtl_dir = os.path.join(root_dir, "rtl")
    sim_dir = os.path.join(root_dir, "sim")

    curr_dir = Path.cwd()
    build_dir = curr_dir / "build"
    build_dir.mkdir(exist_ok=True)

    sim_dir = Path(sim_dir).resolve()
    gpio_c = sim_dir / "gpio_test.c"
    start_s = sim_dir / "start.S"
    link_ld = sim_dir / "link.ld"

    if not gpio_c.exists():
        raise FileNotFoundError(f"{gpio_c} not found")
    if not start_s.exists():
        raise FileNotFoundError(f"{start_s} not found")
    if not link_ld.exists():
        raise FileNotFoundError(f"{link_ld} not found")

    elf_file = build_dir / "gpio_test.elf"
    bin_file = build_dir / "gpio_test.bin"
    hex_file = build_dir / "gpio_instr_mem.hex"

    # Compile C source
    subprocess.run(
        [
            "riscv64-unknown-elf-gcc",
            "-march=rv32i",
            "-mabi=ilp32",
            "-nostdlib",
            "-ffreestanding",
            "-O1",
            "-g3",
            "-Wall",
            "-c",
            str(gpio_c),
            "-o",
            str(build_dir / "gpio_test.o"),
        ],
        check=True,
    )
    log.info("Compiled gpio_test.c to object file.")

    # Compile start.S
    subprocess.run(
        [
            "riscv64-unknown-elf-gcc",
            "-march=rv32i",
            "-mabi=ilp32",
            "-nostdlib",
            "-ffreestanding",
            "-O3",
            "-g3",
            "-Wall",
            "-c",
            str(start_s),
            "-o",
            str(build_dir / "start.o"),
        ],
        check=True,
    )
    log.info("Compiled start.S to object file.")

    # Link into ELF
    subprocess.run(
        [
            "riscv64-unknown-elf-gcc",
            "-march=rv32i",
            "-mabi=ilp32",
            "-nostdlib",
            "-Wl,--no-relax",
            "-Wl,-m,elf32lriscv",
            "-T",
            str(link_ld),
            str(build_dir / "gpio_test.o"),
            str(build_dir / "start.o"),
            "-o",
            str(elf_file),
        ],
        check=True,
    )
    log.info("Linked GPIO test ELF: %s", elf_file)

    # Convert ELF to binary
    subprocess.run(
        [
            "riscv64-unknown-elf-objcopy",
            "-O",
            "binary",
            str(elf_file),
            str(bin_file),
        ],
        check=True,
    )
    log.info("Converted ELF to binary: %s", bin_file)

    # Truncate binary to 2048 bytes
    subprocess.run(
        [
            "truncate",
            "-s",
            "2048",
            str(bin_file),
        ],
        check=True,
    )

    # Convert binary to Verilog hex
    subprocess.run(
        [
            "riscv64-unknown-elf-objcopy",
            "-I",
            "binary",
            "-O",
            "verilog",
            "--verilog-data-width=4",
            "--reverse-bytes=4",
            str(bin_file),
            str(hex_file),
        ],
        check=True,
    )
    log.info("Generated instruction memory hex: %s", hex_file)

    # Disassemble the ELF to show instructions
    log.info("\n" + "="*70)
    log.info("DISASSEMBLED INSTRUCTIONS FROM gpio_test.c:")
    log.info("="*70)
    result = subprocess.run(
        [
            "riscv64-unknown-elf-objdump",
            "-d",
            "-M",
            "numeric,no-aliases",
            str(elf_file),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    log.info(result.stdout)
    log.info("="*70 + "\n")

    return hex_file


@cocotb.test()
async def test_gpio_c_program(dut):
    """Run the C GPIO test and verify GPIO behavior."""

    # Clock and reset
    clk = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clk.start())

    dut.rst.value = 1
    if hasattr(dut, "software_interrupt"):
        dut.software_interrupt.value = 0
    if hasattr(dut, "external_interrupt"):
        dut.external_interrupt.value = 0

    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0

    log_entries = defaultdict(list)
    gpio_dir_writes = []
    gpio_data_writes = []
    cpu_done = False
    max_cycles = 20000

    for cycle in range(max_cycles):
        await RisingEdge(dut.clk)

        if dut.cpu_mem_write_en.value:
            addr = int(dut.cpu_mem_write_addr.value)
            data_val = dut.cpu_mem_write_data.value
            if data_val.is_resolvable:
                data = int(data_val) & 0xFFFFFFFF
            else:
                sanitized = data_val.binstr.replace("x", "0").replace("z", "0").replace("?", "0")
                data = int(sanitized, 2) & 0xFFFFFFFF
                dut._log.debug(
                    "Resolved write data with X/Z bits at cycle %d (addr=0x%08x, raw=%s -> 0x%08x)",
                    cycle,
                    addr,
                    data_val.binstr,
                    data,
                )

            if GPIO_LOG_BASE <= addr < CPU_DONE_ADDR:
                log_entries[addr].append(data)

            if addr == GPIO_DIR_ADDR:
                gpio_dir_writes.append(data)
            elif addr == GPIO_DATA_ADDR:
                gpio_data_writes.append(data)

            if addr == CPU_DONE_ADDR and (data & 0xFF) == 1:
                cpu_done = True
                dut._log.info("CPU_DONE flag set at cycle %d", cycle)
                break

    assert cpu_done, "Firmware never signalled completion (CPU_DONE not observed)"

    valid_log_addr_set = {gpio_log_addr(i) for i in range(LOG_ENTRY_COUNT)}
    unexpected = sorted(addr for addr in log_entries if addr not in valid_log_addr_set)
    assert not unexpected, f"Unexpected firmware logs at addresses: {unexpected}"
    dut._log.debug(
        "Captured log entries: %s",
        {
            f"0x{addr:08x}": [f"0x{val:08x}" for val in values]
            for addr, values in sorted(log_entries.items())
        },
    )

    expected_log_values = (
        [0, 0]
        + [pattern & OUTPUT_MASK for pattern in OUTPUT_PATTERNS]
        + [OUTPUT_MASK, OUTPUT_PATTERNS[-1] & OUTPUT_MASK]
    )

    for idx, expected_value in enumerate(expected_log_values):
        addr = gpio_log_addr(idx)
        writes = log_entries.get(addr)
        assert writes, f"No firmware write captured for log slot {idx} (0x{addr:08x})"
        observed = writes[-1] & 0xFFFFFFFF
        assert observed == expected_value, (
            f"Log slot {idx} at 0x{addr:08x}: expected 0x{expected_value:08x}, "
            f"got 0x{observed:08x}"
        )

    assert gpio_dir_writes, "GPIO_DIR never written by firmware"
    assert gpio_dir_writes[-1] == OUTPUT_MASK, (
        f"GPIO_DIR expected 0x{OUTPUT_MASK:08x}, saw 0x{gpio_dir_writes[-1]:08x}"
    )

    assert len(gpio_data_writes) >= len(OUTPUT_PATTERNS), (
        f"Expected at least {len(OUTPUT_PATTERNS)} GPIO_DATA writes, "
        f"saw {len(gpio_data_writes)}"
    )
    observed_patterns = [val & OUTPUT_MASK for val in gpio_data_writes[-len(OUTPUT_PATTERNS):]]
    expected_patterns = [val & OUTPUT_MASK for val in OUTPUT_PATTERNS]
    assert observed_patterns == expected_patterns, (
        f"GPIO_DATA write sequence mismatch: expected {expected_patterns}, "
        f"got {observed_patterns}"
    )

    dut._log.info("GPIO firmware test completed successfully.")

def runCocotbTests():
    """Run the GPIO C test via cocotb-test."""
    from cocotb_test.simulator import run

    hex_file = compile_gpio_c()

    # Locate repo root again
    root_dir = os.getcwd()
    while not os.path.exists(os.path.join(root_dir, "rtl")):
        parent = os.path.dirname(root_dir)
        if parent == root_dir:
            raise FileNotFoundError("rtl directory not found in current or parent directories.")
        root_dir = parent
    rtl_dir = os.path.join(root_dir, "rtl")
    incl_dir = os.path.join(rtl_dir, "include")

    # Collect all Verilog sources
    sources = []
    rtl_path = Path(rtl_dir)
    for vf in rtl_path.glob("**/*.v"):
        sources.append(str(vf))

    # Waveform output
    curr_dir = Path.cwd()
    waveform_dir = curr_dir / "waveforms"
    waveform_dir.mkdir(exist_ok=True)
    waveform_path = waveform_dir / "gpio_c_test.vcd"

    run(
        verilog_sources=sources,
        toplevel="top",
        module="test_gpio",
        testcase="test_gpio_c_program",
        includes=[str(incl_dir)],
        simulator="icarus",
        timescale="1ns/1ps",
        plus_args=[f"+dumpfile={waveform_path}"],
        defines=[f"INSTR_HEX_FILE=\"{hex_file}\""],
    )


if __name__ == "__main__":
    runCocotbTests()
