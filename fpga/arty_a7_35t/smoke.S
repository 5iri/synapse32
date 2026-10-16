.section .text
.globl _start
_start:
    // OpenSBI clears MSIP during its single-hart warm initialization.
    li t0, 0x02000000
    li t1, 1
    sw t1, 0(t0)
    lw t2, 0(t0)
    bne t1, t2, fail
    sw zero, 0(t0)
    lw t2, 0(t0)
    bnez t2, fail
    lui t0, 0x10000
    li t1, 0x12345678
    sw t1, 0(t0)
    nop
    nop
    nop
    lw t2, 0(t0)
    bne t1, t2, fail
    li t1, -128
    sb t1, 5(t0)
    sb t1, 15(t0)
    li t1, 0x8765
    sh t1, 10(t0)
    nop
    nop
    nop
    lb t2, 5(t0)
    li t3, -128
    bne t2, t3, fail
    lbu t2, 15(t0)
    li t3, 128
    bne t2, t3, fail
    lh t2, 10(t0)
    li t3, -30875
    bne t2, t3, fail
    lhu t2, 10(t0)
    li t3, 0x8765
    bne t2, t3, fail
    li t1, 17
    sw t1, 32(t0)
    nop
    nop
    nop
    addi t4, t0, 32
    lr.w t2, (t4)
    li t1, 23
    sc.w t3, t1, (t4)
    bnez t3, fail
    li t1, 5
    amoadd.w t2, t1, (t4)
    li t3, 23
    bne t2, t3, fail
    lw t2, 32(t0)
    li t3, 28
    bne t2, t3, fail
    // Branch and dependent load-use forwarding through memory waits.
    addi t2, t2, 1
    li t3, 29
    bne t2, t3, fail
    // Exercise the upper ends of both mapped regions and the last AXI lane.
    lui t4, 0x10100
    addi t4, t4, -4
    li t1, 0x55aa33cc
    sw t1, 0(t4)
    nop
    nop
    nop
    lw t2, 0(t4)
    bne t1, t2, fail
    lui t4, 0x80080
    addi t4, t4, -4
    sw t1, 0(t4)
    nop
    nop
    nop
    lw t2, 0(t4)
    bne t1, t2, fail
    // Change an instruction in DDR3, then execute it after fence.i.
    la t4, patched_instruction
    // Execute once to warm the instruction cache with the old code too.
    jalr ra, t4, 0
    // Warm the D-cache with the old code before patching the same line.
    lw t2, 0(t4)
    li t1, 0x04d00393  // addi t2, zero, 77
    sw t1, 0(t4)
    fence rw, rw
    lw t2, 0(t4)
    bne t1, t2, fail
    fence.i
    jalr ra, t4, 0
    li t3, 77
    bne t2, t3, fail
    // FPGA iterative RV32M and forwarding into following instructions.
    li t1, -37
    li t2, 5
    mul t3, t1, t2
    li t4, -185
    bne t3, t4, fail
    div t3, t1, t2
    li t4, -7
    bne t3, t4, fail
    rem t3, t1, t2
    li t4, -2
    bne t3, t4, fail
    mulhsu t3, t1, t2
    li t4, -1
    bne t3, t4, fail
    divu t3, t2, zero
    bne t3, t4, fail
    // Two Sv32 superpage entries: identity text and a virtual alias.
    li t0, 0x10001000
    li t1, 0x200000cf
    li t2, 2048
    add t2, t0, t2
    sw t1, 0(t2)
    sw t1, 1024(t0)
    la t1, machine_resume
    csrw mtvec, t1
    la t1, supervisor
    csrw mepc, t1
    li t1, 0x80010001
    csrw satp, t1
    li t1, 0x1800
    csrc mstatus, t1
    li t1, 0x800
    csrs mstatus, t1
    mret
supervisor:
    li t0, 0x40001000
    li t1, 0x55aa7733
    sw t1, 0(t0)
    lw t2, 0(t0)
    bne t1, t2, supervisor_fail
    // The virtual alias and identity mapping share one physical D-cache line.
    li t3, 0x80001000
    lw t2, 0(t3)
    bne t1, t2, supervisor_fail
    // Return to M via an ECALL; exercise delegation-clear exception entry.
    la t1, machine_resume
    csrw stvec, t1
    ecall
supervisor_fail:
    li t6, 0xdead
    j supervisor_fail
machine_resume:
    li t0, 0x10000000
    li t1, 0x600d
    sw t1, 64(t0)
    li t6, 0x600d
done:
    j done
fail:
    li t1, 0xdead
    sw t1, 64(t0)
    li t6, 0xdead
    j fail

.balign 16
patched_instruction:
    addi t2, zero, 0
    ret
