// GPIO and data memory test for Synapse-32

#define GPIO_BASE       0x20001000
#define GPIO_DATA       (GPIO_BASE + 0x00)
#define GPIO_DIR        (GPIO_BASE + 0x04)
#define GPIO_IN         (GPIO_BASE + 0x08)

#define DATA_MEM_BASE        0x10000000
#define GPIO_RESULT_ADDR     (DATA_MEM_BASE + 0x00)
#define GPIO_OUT_TEST_BASE   (DATA_MEM_BASE + 0x10)
#define CPU_DONE_ADDR        (DATA_MEM_BASE + 0xFF)

static inline void write_reg32(unsigned int addr, unsigned int value) {
    *((volatile unsigned int*)addr) = value;
}

static inline void write_reg8(unsigned int addr, unsigned char value) {
    *((volatile unsigned char*)addr) = value;
}

int main(void) {
    // ---------------------------------------------------------------------
    // 1) Basic sanity: GPIO[0] as output driven high, snapshot GPIO_IN.
    // ---------------------------------------------------------------------
    write_reg32(GPIO_DIR, 0x00000001);   // bit 0 -> output, others input
    write_reg32(GPIO_DATA, 0x00000001);  // drive bit 0 high

    unsigned int basic_val = *((volatile unsigned int*)GPIO_IN);
    write_reg32(GPIO_RESULT_ADDR, basic_val);

    // ---------------------------------------------------------------------
    // 2) Output pattern test on low 2 bits (GPIO[1:0]).
    //    We drive patterns and record what the CPU sees via GPIO_IN.
    // ---------------------------------------------------------------------
    static const unsigned out_patterns[] = {
        0x00000000u,
        0x00000001u,
        0x00000002u,
        0x00000003u,
    };
    const unsigned num_patterns = sizeof(out_patterns) / sizeof(out_patterns[0]);

    // Configure GPIO[1:0] as outputs (low 2 bits)
    write_reg32(GPIO_DIR, 0x00000003u);

    for (unsigned i = 0; i < num_patterns; ++i) {
        write_reg32(GPIO_DATA, out_patterns[i]);

        // Small delay to allow outputs to settle before sampling.
        for (volatile int d = 0; d < 16; ++d) {
            __asm__ volatile("nop");
        }

        unsigned int v = *((volatile unsigned int*)GPIO_IN);
        write_reg32(GPIO_OUT_TEST_BASE + i * 4u, v);
    }

    // ---------------------------------------------------------------------
    // 3) Signal completion.
    // ---------------------------------------------------------------------
    write_reg8(CPU_DONE_ADDR, 1);

    // Idle forever.
    while (1) {
        __asm__ volatile("nop");
    }

    return 0;
}
