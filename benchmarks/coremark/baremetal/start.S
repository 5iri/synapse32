.section .text.start,"ax",@progbits
.globl _start
_start:
    csrw mie, zero
    csrw mstatus, zero
    csrw satp, zero
    csrw mcountinhibit, zero
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la sp, __stack_top
    la t0, trap
    csrw mtvec, t0
    la t0, __bss_start
    la t1, __bss_end
1:  bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b
2:  call board_main
3:  wfi
    j 3b
trap:
    csrr a0, mcause
    csrr a1, mepc
    csrr a2, mtval
    tail board_trap
