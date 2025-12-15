// GPIO and data memory test for Synapse-32

#define GPIO_BASE       0x20001000
#define GPIO_DATA       (GPIO_BASE + 0x00)
#define GPIO_DIR        (GPIO_BASE + 0x04)
#define GPIO_IN         (GPIO_BASE + 0x08)

#define DATA_MEM_BASE    0x10000000
#define GPIO_RESULT_ADDR (DATA_MEM_BASE + 0x00)
#define CPU_DONE_ADDR    (DATA_MEM_BASE + 0xFF)

static inline void write_reg32(unsigned int addr, unsigned int value) {
    *((volatile unsigned int*)addr) = value;
}

static inline void write_reg8(unsigned int addr, unsigned char value) {
    *((volatile unsigned char*)addr) = value;
}

int main(void) {
    // 1) Configure GPIO[0] as output and drive it high.
    write_reg32(GPIO_DIR, 0x00000001);   // bit 0 -> output, others input
    write_reg32(GPIO_DATA, 0x00000001);  // drive bit 0 high

    // 2) For this reduced debug case, don't poll GPIO_IN.
    //    Just record the current GPIO_IN value once and then set CPU_DONE.
    unsigned int val = *((volatile unsigned int*)GPIO_IN);
    write_reg32(GPIO_RESULT_ADDR, val);

    // Use an 8-bit store for CPU_DONE to match other tests and avoid alignment issues.
    write_reg8(CPU_DONE_ADDR, 1);

    // Idle forever.
    while (1) {
        __asm__ volatile("nop");
    }

    return 0;
}
