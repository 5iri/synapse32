// GPIO self-test for Synapse-32
// Result data is written immediately after the GPIO registers, starting at
// 0x2000100C (i.e. after GPIO_IN at 0x20001008).

#include <stdint.h>

#define GPIO_BASE          0x20001000u
#define GPIO_DATA          (GPIO_BASE + 0x00u)
#define GPIO_DIR           (GPIO_BASE + 0x04u)
#define GPIO_IN            (GPIO_BASE + 0x08u)

#define GPIO_LOG_BASE      (GPIO_BASE + 0x0Cu)
#define GPIO_LOG_ADDR(idx) (GPIO_LOG_BASE + ((idx) << 2))
#define CPU_DONE_ADDR      (GPIO_BASE + 0x40u)

#define OUTPUT_MASK        0x00000007u

static const uint32_t output_patterns[] = {
    0x00000000u,
    0x00000001u,
    0x00000003u,
    0x00000007u,
};

enum {
    PATTERN_COUNT        = sizeof(output_patterns) / sizeof(output_patterns[0]),
    LOG_RESET_DATA_IDX   = 0,
    LOG_RESET_DIR_IDX    = 1,
    LOG_PATTERN_BASE_IDX = 2,
    LOG_FINAL_DIR_IDX    = LOG_PATTERN_BASE_IDX + PATTERN_COUNT,
    LOG_FINAL_DATA_IDX   = LOG_FINAL_DIR_IDX + 1
};

static inline void write_reg32(uint32_t addr, uint32_t value) {
    *((volatile uint32_t*)addr) = value;
}

static inline void write_reg8(uint32_t addr, uint8_t value) {
    *((volatile uint8_t*)addr) = value;
}

static inline uint32_t read_reg32(uint32_t addr) {
    return *((volatile uint32_t*)addr);
}

static inline void log_word(uint32_t idx, uint32_t value) {
    *((volatile uint32_t*)GPIO_LOG_ADDR(idx)) = value;
}

int main(void) {
    // Ensure the GPIO block starts from a known state.
    write_reg32(GPIO_DATA, 0x00000000u);
    write_reg32(GPIO_DIR,  0x00000000u);

    log_word(LOG_RESET_DATA_IDX, read_reg32(GPIO_DATA));
    log_word(LOG_RESET_DIR_IDX,  read_reg32(GPIO_DIR));

    // Drive GPIO[2:0] as outputs and sweep a few patterns across them.
    write_reg32(GPIO_DIR, OUTPUT_MASK);

    for (uint32_t i = 0; i < PATTERN_COUNT; ++i) {
        uint32_t pattern = output_patterns[i] & OUTPUT_MASK;
        write_reg32(GPIO_DATA, pattern);
        uint32_t observed = read_reg32(GPIO_IN);
        log_word(LOG_PATTERN_BASE_IDX + i, observed);
    }

    // Final snapshots of the GPIO state.
    log_word(LOG_FINAL_DIR_IDX,  read_reg32(GPIO_DIR));
    log_word(LOG_FINAL_DATA_IDX, read_reg32(GPIO_DATA));

    // Notify the testbench that the program has finished.
    write_reg8(CPU_DONE_ADDR, 1u);

    // Idle forever.
    while (1) {
        __asm__ volatile("wfi");
    }

    return 0;
}
