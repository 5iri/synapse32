#include <zephyr/toolchain.h>

GTEXT(__soc_handle_irq)

/*
 * SoC-specific per-IRQ handling. Synapse32 has only the standard RISC-V
 * machine timer and ECALL exception sources — neither needs SoC-level
 * acknowledgement, so this is a no-op.
 */
SECTION_FUNC(exception.other, __soc_handle_irq)
	ret
