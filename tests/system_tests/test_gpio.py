import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
import subprocess
import os
import logging
from pathlib import Path

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

DATA_MEM_BASE = 0x10000000
CPU_DONE_ADDR = DATA_MEM_BASE + 0xFF
GPIO_RESULT_ADDR = DATA_MEM_BASE + 0x00

GPIO_BASE = 0x20001000
GPIO_DATA_ADDR = GPIO_BASE + 0x00
GPIO_DIR_ADDR  = GPIO_BASE + 0x04
GPIO_IN_ADDR = GPIO_BASE + 0x08


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

    # Ensure GPIO[1] starts low from the testbench side
    try:
        dut.gpio[1].value = 0
    except Exception:
        # If gpio is not present (unexpected), fail early
        assert False, "DUT has no 'gpio' port, cannot run GPIO C test"

    max_cycles = 20000
    cpu_done = False
    seen_result = False
    result_value = 0

    # Trace GPIO-related bus activity
    dir_writes = []
    data_writes = []
    gpio_in_reads = []
    gpio_in_read_count = 0
    all_writes = []

    for cycle in range(max_cycles):
        await RisingEdge(dut.clk)

        # Drive GPIO[1] from the testbench to simulate an external signal.
        # Keep it low for some initial cycles so the firmware's polling loop
        # sees at least a few zero reads, then raise it and keep it high.
        if cycle < 10:
            dut.gpio[1].value = 0
        else:
            dut.gpio[1].value = 1

        # Track reads from GPIO_IN on the bus for coverage / introspection.
        if hasattr(dut, "cpu_mem_read_en") and int(dut.cpu_mem_read_en.value):
            addr = int(dut.cpu_mem_read_addr.value)
            if addr == GPIO_IN_ADDR:
                # Sample the pad value. Some bits may be high‑Z; map X/Z to 0
                # so that we can still get an integer snapshot for debug.
                try:
                    raw = dut.gpio.value
                    val_str = raw.binstr.replace("z", "0").replace("x", "0")
                    gpio_in_reads.append(int(val_str, 2))
                except Exception:
                    gpio_in_reads.append(0)
                gpio_in_read_count += 1

        # Track memory writes
        if hasattr(dut, "cpu_mem_write_en") and int(dut.cpu_mem_write_en.value):
            waddr = int(dut.cpu_mem_write_addr.value)
            # cpu_mem_write_data may have X/Z bits early in reset; map them to 0
            # so we can still log and match on the low byte.
            try:
                raw_w = dut.cpu_mem_write_data.value
                w_str = raw_w.binstr.replace("z", "0").replace("x", "0")
                wdata = int(w_str, 2)
            except Exception:
                wdata = 0

            if len(all_writes) < 64:
                all_writes.append((waddr, wdata))

            if waddr == GPIO_DIR_ADDR:
                dir_writes.append(wdata)
            if waddr == GPIO_DATA_ADDR:
                data_writes.append(wdata)

            if waddr == GPIO_RESULT_ADDR:
                seen_result = True
                result_value = wdata

            if waddr == CPU_DONE_ADDR and (wdata & 0xFF) == 1:
                cpu_done = True
                break

    if not cpu_done:
        # Diagnostic dump to help understand why the loop didn't observe CPU_DONE.
        print("\n[GPIO DEBUG] CPU_DONE was not observed on the bus")
        print(f"[GPIO DEBUG] Total dir_writes: {len(dir_writes)}")
        print(f"[GPIO DEBUG] Total data_writes: {len(data_writes)}")
        print(f"[GPIO DEBUG] gpio_in_read_count: {gpio_in_read_count}")
        print(f"[GPIO DEBUG] First few GPIO_IN reads (pad value): {gpio_in_reads[:8]}")
        print("[GPIO DEBUG] First few bus writes (addr, data):")
        for (a, d) in all_writes[:16]:
            print(f"    addr=0x{a:08x}, data=0x{d:08x}")

    assert cpu_done, "CPU_DONE flag was not set by the GPIO C test"
    assert seen_result, "GPIO_RESULT_ADDR was never written"

    # We expect at least one write to GPIO_DIR/Data from the C program.
    assert dir_writes, "No writes to GPIO_DIR were observed"
    assert data_writes, "No writes to GPIO_DATA were observed"

    # Last DIR should configure bit 0 as output.
    assert (dir_writes[-1] & 0x1) == 0x1, f"Expected GPIO_DIR bit 0 set, got 0x{dir_writes[-1]:08x}"
    # Last DATA should drive bit 0 high.
    assert (data_writes[-1] & 0x1) == 0x1, f"Expected GPIO_DATA bit 0 set, got 0x{data_writes[-1]:08x}"

    # We should have seen at least one read from GPIO_IN.
    assert gpio_in_reads, "No reads from GPIO_IN were observed"
    assert gpio_in_read_count >= 1, "Expected at least one read from GPIO_IN"

    # Bit 0 should have been driven high by the C code (output)
    assert (result_value & 0x1) == 0x1, f"Expected GPIO bit 0 high in result, got 0x{result_value:08x}"

    # Also, check the actual pad state for bit 0. Some bits on the bus may be
    # high‑Z; treat X/Z as 0 for this debug check.
    raw_gpio = dut.gpio.value
    gpio_str = raw_gpio.binstr.replace("z", "0").replace("x", "0")
    gpio_val = int(gpio_str, 2)
    assert (gpio_val & 0x1) == 0x1, f"Top-level gpio[0] is not high: gpio=0x{gpio_val:08x}"


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
