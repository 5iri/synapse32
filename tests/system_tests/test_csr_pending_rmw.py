"""Hardware SEIP must not become a sticky software interrupt during CSR RMW."""
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, Timer
from cocotb_test.simulator import run


@cocotb.test()
async def hardware_pending_is_not_copied_to_software(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst.value = 1
    dut.csr_addr.value = 0
    dut.instr_id.value = 0x27
    dut.rs1_value.value = 0
    dut.rs1_addr.value = 1
    dut.read_enable.value = 1
    dut.execute.value = 0
    dut.external_interrupt.value = 0
    await ClockCycles(dut.clk, 3)
    await FallingEdge(dut.clk)
    dut.rst.value = 0

    async def operation(address, instruction, operand, register=1):
        await FallingEdge(dut.clk)
        dut.csr_addr.value = address
        dut.instr_id.value = instruction
        dut.rs1_value.value = operand
        dut.rs1_addr.value = register
        dut.execute.value = 1
        await Timer(1, units="ns")
        previous = int(dut.rd_value.value)
        await ClockCycles(dut.clk, 1)
        await FallingEdge(dut.clk)
        dut.execute.value = 0
        await ClockCycles(dut.clk, 3)
        return previous

    # Route the PLIC source to supervisor mode, as OpenSBI does.
    await operation(0x303, 0x27, 1 << 9)

    # Clearing STIP is the OpenSBI timer-update sequence that exposed this.
    # Also cover setting unrelated bits, immediate RMW, and full CSR writes.
    for instruction, operand, register in (
        (0x29, 1 << 5, 1),  # CSRRC mip, STIP
        (0x28, 1 << 5, 1),  # CSRRS mip, STIP
        (0x2B, 0, 2),       # CSRRSI mip, SSIP
        (0x2C, 0, 2),       # CSRRCI mip, SSIP
        (0x27, 0, 1),       # CSRRW mip, zero
        (0x2A, 0, 0),       # CSRRWI mip, zero
    ):
        await operation(0x344, 0x27, 0)
        dut.external_interrupt.value = 1
        await ClockCycles(dut.clk, 3)
        previous = await operation(0x344, instruction, operand, register)
        assert previous & (1 << 9), "rd must see the live hardware interrupt"
        dut.external_interrupt.value = 0
        await ClockCycles(dut.clk, 3)
        await Timer(1, units="ns")
        assert not (int(dut.read_data.value) & (1 << 9)), (
            f"CSR operation {instruction:#x} latched hardware SEIP permanently"
        )

    # Software can still inject SEIP, preserve it across unrelated RMW,
    # and clear it while the hardware source remains asserted.
    await operation(0x344, 0x28, 1 << 9)
    await operation(0x344, 0x29, 1 << 5)
    assert int(dut.read_data.value) & (1 << 9)
    dut.external_interrupt.value = 1
    await ClockCycles(dut.clk, 3)
    await operation(0x344, 0x29, 1 << 9)
    assert int(dut.read_data.value) & (1 << 9)
    dut.external_interrupt.value = 0
    await ClockCycles(dut.clk, 3)
    await Timer(1, units="ns")
    assert not (int(dut.read_data.value) & (1 << 9))


def runCocotbTests():
    root = Path(__file__).resolve().parents[2]
    run(
        verilog_sources=[
            str(root / "tests/testbenches/csr_pending_rmw_tb.sv"),
            str(root / "rtl/core_modules/csr_file.v"),
            str(root / "rtl/core_modules/csr_exec.v"),
        ],
        includes=[str(root / "rtl/include")],
        toplevel="csr_pending_rmw_tb",
        module="test_csr_pending_rmw",
        simulator="verilator",
        sim_build=str(root / "sim_build_csr_pending_rmw"),
        compile_args=["-Wno-fatal"],
    )


if __name__ == "__main__":
    runCocotbTests()
