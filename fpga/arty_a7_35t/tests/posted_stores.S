.section .text
.globl _start
_start:
    csrw mie, zero
    csrw mstatus, zero
    csrw satp, zero
    la t0, trap
    csrw mtvec, t0
    li s0, 0x10000000
    li s1, 0x10000040
    li s3, 0x10000200
    lw zero, 0(s0)
    lw zero, 0(s1)
    li t6, 1
    li t1, 0xa5
    li t2, 0xbeef
    li t3, 0xdeadc0de
    jal ra, subwords
    li t4, 0xbeef00a5
    bne a0, t4, fail
    bne a1, t3, fail
    li t6, 2
    li t1, 0x12345678
    jal ra, load_miss
    li t4, 0xcafed00d
    bne a0, t4, fail
    li t6, 3
    li t1, 0x76543210
    jal ra, fence_block
    lw t4, 0(s0)
    bne t4, t1, fail
    li t6, 4
    la s2, patched_instruction
    jalr ra, s2, 0
    li t4, 1
    bne a0, t4, fail
    lw zero, 0(s2)
    li t1, 0x04d00513
    jal ra, fence_i_block
    jalr ra, s2, 0
    li t4, 77
    bne a0, t4, fail
    li t6, 5
    li t1, 17
    li t2, 23
    jal ra, lr_sc_block
    bne a0, t1, fail
    bnez a1, fail
    lw t4, 0(s1)
    bne t4, t2, fail
    lr.w a0, (s1)
    li t1, 123
    li t2, 29
    jal ra, successful_sc_block
    bnez a1, fail
    lw t4, 0(s1)
    bne t4, t2, fail
    li t6, 6
    li t1, 31
    li t2, 5
    jal ra, amo_block
    bne a0, t1, fail
    lw t4, 0(s1)
    li t5, 36
    bne t4, t5, fail
    li t6, 7
    li t1, 41
    li t2, 99
    jal ra, failed_sc_block
    li t4, 1
    bne a1, t4, fail
    lw t4, 0(s1)
    bne t4, t1, fail
    li t6, 8
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
    li t6, 9
    li t0, 0x10000ff0
    li t1, 0x600d
    sw t1, 0(t0)
    fence rw, rw
done:
    j done
fail:
    li t0, 0x10000ff0
    li t1, 0xdead
    sw t1, 0(t0)
    fence rw, rw
1:  j 1b
trap:
    csrr t6, mcause
    ori t6, t6, 0x100
    j fail

// Critical store/barrier pairs share a line: an I miss must not drain the
// queue before the test reaches its fence, atomic instruction or load.
.balign 16
subwords:
    sb t1, 0(s0)
    sh t2, 2(s0)
    sw t3, 4(s0)
    lw a0, 0(s0)
    lw a1, 4(s0)
    ret
.balign 16
load_miss:
    sw t1, 0(s0)
    lw a0, 0(s3)
    ret
.balign 16
fence_block:
    sw t1, 0(s0)
    fence rw, rw
    ret
.balign 16
fence_i_block:
    sw t1, 0(s2)
    fence.i
    ret
.balign 16
lr_sc_block:
    sw t1, 0(s1)
    lr.w a0, (s1)
    sc.w a1, t2, (s1)
    ret
.balign 16
successful_sc_block:
    sw t1, 0(s0)        // Different address: the LR reservation must survive.
    sc.w a1, t2, (s1)
    ret
.balign 16
amo_block:
    sw t1, 0(s1)
    amoadd.w a0, t2, (s1)
    ret
.balign 16
failed_sc_block:
    sw t1, 0(s1)
    sc.w a1, t2, (s1)
    ret
.balign 16
patched_instruction:
    addi a0, zero, 1
    ret
