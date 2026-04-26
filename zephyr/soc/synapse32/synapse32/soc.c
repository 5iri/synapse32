#include <zephyr/irq.h>
#include <soc.h>

#ifdef CONFIG_RISCV_SOC_INTERRUPT_INIT
void soc_interrupt_init(void)
{
	(void)arch_irq_lock();
	csr_write(mie, 0);
}
#endif
