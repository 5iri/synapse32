#!/usr/bin/env python3
"""
Generate comprehensive RISC-V formal verification test configurations
for all RV32I instructions and system-level checks.
"""

import os
import sys
from pathlib import Path

# RV32I Base Instruction Set
RV32I_INSTRUCTIONS = {
    # Arithmetic Instructions
    "add": "R-type arithmetic",
    "sub": "R-type arithmetic",
    "addi": "I-type arithmetic",
    "lui": "U-type load upper immediate",
    "auipc": "U-type add upper immediate to PC",

    # Logical Instructions
    "and": "R-type logical",
    "or": "R-type logical",
    "xor": "R-type logical",
    "andi": "I-type logical",
    "ori": "I-type logical",
    "xori": "I-type logical",

    # Shift Instructions
    "sll": "R-type shift left logical",
    "srl": "R-type shift right logical",
    "sra": "R-type shift right arithmetic",
    "slli": "I-type shift left logical immediate",
    "srli": "I-type shift right logical immediate",
    "srai": "I-type shift right arithmetic immediate",

    # Compare Instructions
    "slt": "R-type set less than",
    "sltu": "R-type set less than unsigned",
    "slti": "I-type set less than immediate",
    "sltiu": "I-type set less than immediate unsigned",

    # Memory Instructions
    "lb": "I-type load byte",
    "lh": "I-type load halfword",
    "lw": "I-type load word",
    "lbu": "I-type load byte unsigned",
    "lhu": "I-type load halfword unsigned",
    "sb": "S-type store byte",
    "sh": "S-type store halfword",
    "sw": "S-type store word",

    # Branch Instructions
    "beq": "B-type branch equal",
    "bne": "B-type branch not equal",
    "blt": "B-type branch less than",
    "bge": "B-type branch greater equal",
    "bltu": "B-type branch less than unsigned",
    "bgeu": "B-type branch greater equal unsigned",

    # Jump Instructions
    "jal": "J-type jump and link",
    "jalr": "I-type jump and link register"
}

# System-level verification checks
SYSTEM_CHECKS = {
    "reg": "Register file verification",
    "pc_fwd": "PC forward progression verification",
    "pc_bwd": "PC backward verification",
    "dmem": "Data memory consistency",
    "imem": "Instruction memory consistency",
    "insn": "General instruction verification",
    "ill": "Illegal instruction handling",
    "hang": "Hang detection",
    "causal": "Causality verification",
    "unique": "Unique instruction verification",
    "liveness": "Liveness verification"
}

# Coverage and integration tests
INTEGRATION_CHECKS = {
    "rv32i": "Complete RV32I ISA verification",
    "cover": "Coverage analysis",
    "fault": "Fault injection testing"
}

def create_instruction_config(instruction, description, output_dir):
    """Create SBY configuration for individual instruction verification."""

    config_content = f"""[options]
mode prove
expect pass
depth 20
wait on

[engines]
smtbmc boolector

[script]
# --- Design files with instruction-specific defines ---
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/top.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/riscv_cpu.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/data_mem.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/execution_unit.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/instr_mem.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/memory_unit.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/seven_seg.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/writeback.v

# Core modules
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/alu.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/csr_exec.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/csr_file.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/decoder.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/interrupt_controller.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/pc.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/registerfile.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/timer.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/uart.v

# Pipeline stages
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/EX_MEM.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/forwarding_unit.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/ID_EX.v
read_verilog -DFORMAL -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/IF_ID.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/load_use_detector.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/MEM_WB.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/store_load_detector.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/store_load_forward.v

# Include files
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/include/instr_defines.vh
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/include/memory_map.vh

# riscv-formal checks for {instruction.upper()} instruction
read_verilog -sv -formal -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/riscv-formal/checks/rvfi_macros.vh
read_verilog -sv -formal -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/riscv-formal/insns/insn_{instruction}.v
read_verilog -sv -formal -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_INSN_MODEL=rvfi_insn_{instruction} -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/riscv-formal/checks/rvfi_insn_check.sv

# Synthesis passes
hierarchy -top top
proc
opt
memory -nomap
flatten
setundef -undriven -anyseq
check
stat

[files]
/Users/lazybanana/github/synapse32/rtl/top.v
/Users/lazybanana/github/synapse32/rtl/riscv_cpu.v
/Users/lazybanana/github/synapse32/rtl/data_mem.v
/Users/lazybanana/github/synapse32/rtl/execution_unit.v
/Users/lazybanana/github/synapse32/rtl/instr_mem.v
/Users/lazybanana/github/synapse32/rtl/memory_unit.v
/Users/lazybanana/github/synapse32/rtl/seven_seg.v
/Users/lazybanana/github/synapse32/rtl/writeback.v
/Users/lazybanana/github/synapse32/rtl/core_modules/alu.v
/Users/lazybanana/github/synapse32/rtl/core_modules/csr_exec.v
/Users/lazybanana/github/synapse32/rtl/core_modules/csr_file.v
/Users/lazybanana/github/synapse32/rtl/core_modules/decoder.v
/Users/lazybanana/github/synapse32/rtl/core_modules/interrupt_controller.v
/Users/lazybanana/github/synapse32/rtl/core_modules/pc.v
/Users/lazybanana/github/synapse32/rtl/core_modules/registerfile.v
/Users/lazybanana/github/synapse32/rtl/core_modules/timer.v
/Users/lazybanana/github/synapse32/rtl/core_modules/uart.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/EX_MEM.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/forwarding_unit.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/ID_EX.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/IF_ID.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/load_use_detector.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/MEM_WB.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/store_load_detector.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/store_load_forward.v
/Users/lazybanana/github/synapse32/rtl/include/instr_defines.vh
/Users/lazybanana/github/synapse32/rtl/include/memory_map.vh
/Users/lazybanana/github/synapse32/riscv-formal/checks/rvfi_macros.vh
/Users/lazybanana/github/synapse32/riscv-formal/insns/insn_{instruction}.v
/Users/lazybanana/github/synapse32/riscv-formal/checks/rvfi_insn_check.sv
"""

    # Write the configuration file
    config_file = output_dir / f"verify_{instruction}.sby"
    with open(config_file, 'w') as f:
        f.write(config_content)

    return config_file

def create_system_config(check_name, description, output_dir):
    """Create SBY configuration for system-level verification checks."""

    config_content = f"""[options]
mode prove
expect pass
depth 30
wait on

[engines]
smtbmc boolector

[script]
# --- Design files for {check_name.upper()} verification ---
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/top.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/riscv_cpu.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/data_mem.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/execution_unit.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/instr_mem.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/memory_unit.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/seven_seg.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/writeback.v

# Core modules
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/alu.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/csr_exec.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/csr_file.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/decoder.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/interrupt_controller.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/pc.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/registerfile.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/timer.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/uart.v

# Pipeline stages
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/EX_MEM.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/forwarding_unit.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/ID_EX.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/IF_ID.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/load_use_detector.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/MEM_WB.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/store_load_detector.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/store_load_forward.v

# Include files
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/include/instr_defines.vh
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/include/memory_map.vh

# riscv-formal checks for {check_name.upper()} verification
read_verilog -sv -formal -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/riscv-formal/checks/rvfi_macros.vh
read_verilog -sv -formal -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/riscv-formal/checks/rvfi_{check_name}_check.sv

# Synthesis passes
hierarchy -top top
proc
opt
memory -nomap
flatten
setundef -undriven -anyseq
check
stat

[files]
/Users/lazybanana/github/synapse32/rtl/top.v
/Users/lazybanana/github/synapse32/rtl/riscv_cpu.v
/Users/lazybanana/github/synapse32/rtl/data_mem.v
/Users/lazybanana/github/synapse32/rtl/execution_unit.v
/Users/lazybanana/github/synapse32/rtl/instr_mem.v
/Users/lazybanana/github/synapse32/rtl/memory_unit.v
/Users/lazybanana/github/synapse32/rtl/seven_seg.v
/Users/lazybanana/github/synapse32/rtl/writeback.v
/Users/lazybanana/github/synapse32/rtl/core_modules/alu.v
/Users/lazybanana/github/synapse32/rtl/core_modules/csr_exec.v
/Users/lazybanana/github/synapse32/rtl/core_modules/csr_file.v
/Users/lazybanana/github/synapse32/rtl/core_modules/decoder.v
/Users/lazybanana/github/synapse32/rtl/core_modules/interrupt_controller.v
/Users/lazybanana/github/synapse32/rtl/core_modules/pc.v
/Users/lazybanana/github/synapse32/rtl/core_modules/registerfile.v
/Users/lazybanana/github/synapse32/rtl/core_modules/timer.v
/Users/lazybanana/github/synapse32/rtl/core_modules/uart.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/EX_MEM.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/forwarding_unit.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/ID_EX.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/IF_ID.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/load_use_detector.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/MEM_WB.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/store_load_detector.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/store_load_forward.v
/Users/lazybanana/github/synapse32/rtl/include/instr_defines.vh
/Users/lazybanana/github/synapse32/rtl/include/memory_map.vh
/Users/lazybanana/github/synapse32/riscv-formal/checks/rvfi_macros.vh
/Users/lazybanana/github/synapse32/riscv-formal/checks/rvfi_{check_name}_check.sv
"""

    # Write the configuration file
    config_file = output_dir / f"verify_{check_name}.sby"
    with open(config_file, 'w') as f:
        f.write(config_content)

    return config_file

def create_integration_config(check_name, description, output_dir):
    """Create SBY configuration for integration tests."""

    isa_config = f"""[options]
mode prove
expect pass
depth 50
wait on

[engines]
smtbmc boolector

[script]
# --- Complete ISA verification for {check_name.upper()} ---
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/top.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/riscv_cpu.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/data_mem.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/execution_unit.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/instr_mem.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/memory_unit.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/seven_seg.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/writeback.v

# Core modules
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/alu.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/csr_exec.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/csr_file.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/decoder.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/interrupt_controller.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/pc.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/registerfile.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/timer.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/core_modules/uart.v

# Pipeline stages
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/EX_MEM.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/forwarding_unit.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/ID_EX.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/IF_ID.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/load_use_detector.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/MEM_WB.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/store_load_detector.v
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/pipeline_stages/store_load_forward.v

# Include files
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/include/instr_defines.vh
read_verilog -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/rtl/include/memory_map.vh

# Complete ISA verification
read_verilog -sv -formal -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/riscv-formal/checks/rvfi_macros.vh
read_verilog -sv -formal -DFORMAL -DRISCV_FORMAL_NRET=1 -DRISCV_FORMAL_ILEN=32 -DRISCV_FORMAL_XLEN=32 -DRISCV_FORMAL_CHANNEL_IDX=0 /Users/lazybanana/github/synapse32/riscv-formal/insns/isa_{check_name}.v

# Synthesis passes
hierarchy -top top
proc
opt
memory -nomap
flatten
setundef -undriven -anyseq
check
stat

[files]
/Users/lazybanana/github/synapse32/rtl/top.v
/Users/lazybanana/github/synapse32/rtl/riscv_cpu.v
/Users/lazybanana/github/synapse32/rtl/data_mem.v
/Users/lazybanana/github/synapse32/rtl/execution_unit.v
/Users/lazybanana/github/synapse32/rtl/instr_mem.v
/Users/lazybanana/github/synapse32/rtl/memory_unit.v
/Users/lazybanana/github/synapse32/rtl/seven_seg.v
/Users/lazybanana/github/synapse32/rtl/writeback.v
/Users/lazybanana/github/synapse32/rtl/core_modules/alu.v
/Users/lazybanana/github/synapse32/rtl/core_modules/csr_exec.v
/Users/lazybanana/github/synapse32/rtl/core_modules/csr_file.v
/Users/lazybanana/github/synapse32/rtl/core_modules/decoder.v
/Users/lazybanana/github/synapse32/rtl/core_modules/interrupt_controller.v
/Users/lazybanana/github/synapse32/rtl/core_modules/pc.v
/Users/lazybanana/github/synapse32/rtl/core_modules/registerfile.v
/Users/lazybanana/github/synapse32/rtl/core_modules/timer.v
/Users/lazybanana/github/synapse32/rtl/core_modules/uart.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/EX_MEM.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/forwarding_unit.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/ID_EX.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/IF_ID.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/load_use_detector.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/MEM_WB.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/store_load_detector.v
/Users/lazybanana/github/synapse32/rtl/pipeline_stages/store_load_forward.v
/Users/lazybanana/github/synapse32/rtl/include/instr_defines.vh
/Users/lazybanana/github/synapse32/rtl/include/memory_map.vh
/Users/lazybanana/github/synapse32/riscv-formal/checks/rvfi_macros.vh
/Users/lazybanana/github/synapse32/riscv-formal/insns/isa_{check_name}.v
"""

    # Write the configuration file
    config_file = output_dir / f"verify_{check_name}.sby"
    with open(config_file, 'w') as f:
        f.write(isa_config)

    return config_file

def main():
    """Main function to generate all verification configurations."""

    # Set up directories
    script_dir = Path(__file__).parent
    base_dir = script_dir.parent
    instructions_dir = script_dir / "instructions"
    system_dir = script_dir / "system_checks"
    integration_dir = script_dir / "integration"

    # Create directories
    instructions_dir.mkdir(exist_ok=True)
    system_dir.mkdir(exist_ok=True)
    integration_dir.mkdir(exist_ok=True)

    print("Generating RISC-V Formal Verification Test Suite")
    print("=" * 60)

    # Generate individual instruction tests
    print(f"\nGenerating {len(RV32I_INSTRUCTIONS)} individual instruction tests...")
    instruction_configs = []
    for instruction, description in RV32I_INSTRUCTIONS.items():
        try:
            config_file = create_instruction_config(instruction, description, instructions_dir)
            instruction_configs.append(config_file)
            print(f"  [PASS] {instruction.upper():<8} - {description}")
        except Exception as e:
            print(f"  [ERROR] {instruction.upper():<8} - Error: {e}")

    # Generate system-level tests
    print(f"\nGenerating {len(SYSTEM_CHECKS)} system-level verification tests...")
    system_configs = []
    for check, description in SYSTEM_CHECKS.items():
        try:
            config_file = create_system_config(check, description, system_dir)
            system_configs.append(config_file)
            print(f"  [PASS] {check.upper():<12} - {description}")
        except Exception as e:
            print(f"  [ERROR] {check.upper():<12} - Error: {e}")

    # Generate integration tests
    print(f"\nGenerating {len(INTEGRATION_CHECKS)} integration tests...")
    integration_configs = []
    for check, description in INTEGRATION_CHECKS.items():
        try:
            config_file = create_integration_config(check, description, integration_dir)
            integration_configs.append(config_file)
            print(f"  [PASS] {check.upper():<8} - {description}")
        except Exception as e:
            print(f"  [ERROR] {check.upper():<8} - Error: {e}")

    print("\n" + "=" * 60)
    print("Generated verification suite:")
    print(f"   {len(instruction_configs)} instruction tests in {instructions_dir}")
    print(f"   {len(system_configs)} system tests in {system_dir}")
    print(f"   {len(integration_configs)} integration tests in {integration_dir}")
    print(f"   Total: {len(instruction_configs) + len(system_configs) + len(integration_configs)} test configurations")

    return True

if __name__ == "__main__":
    main()
