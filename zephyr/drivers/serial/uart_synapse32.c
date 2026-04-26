#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/init.h>
#include <zephyr/sys/sys_io.h>
#include <zephyr/arch/cpu.h>

#define DT_DRV_COMPAT synapse32_uart

#define REG_DATA    0x00
#define REG_STATUS  0x04
#define REG_CONTROL 0x08
#define REG_BAUD    0x0C

#define STATUS_FULL  BIT(0)
#define STATUS_EMPTY BIT(1)
#define STATUS_BUSY  BIT(2)

#define CONTROL_TX_ENABLE BIT(0)

struct uart_synapse32_config {
	mm_reg_t base;
	uint32_t clock_frequency;
	uint32_t current_speed;
};

static void uart_synapse32_poll_out(const struct device *dev, unsigned char c)
{
	const struct uart_synapse32_config *cfg = dev->config;

	while (sys_read32(cfg->base + REG_STATUS) & STATUS_BUSY) {
	}
	sys_write32(c, cfg->base + REG_DATA);
}

static int uart_synapse32_poll_in(const struct device *dev, unsigned char *c)
{
	ARG_UNUSED(dev);
	ARG_UNUSED(c);
	return -1;
}

static int uart_synapse32_err_check(const struct device *dev)
{
	ARG_UNUSED(dev);
	return 0;
}

static int uart_synapse32_init(const struct device *dev)
{
	const struct uart_synapse32_config *cfg = dev->config;
	uint32_t divisor;

	if (cfg->current_speed == 0 || cfg->clock_frequency == 0) {
		return -EINVAL;
	}

	divisor = cfg->clock_frequency / cfg->current_speed;
	if (divisor == 0 || divisor > 0xFFFF) {
		return -EINVAL;
	}

	sys_write32(divisor, cfg->base + REG_BAUD);
	sys_write32(CONTROL_TX_ENABLE, cfg->base + REG_CONTROL);
	return 0;
}

static DEVICE_API(uart, uart_synapse32_driver_api) = {
	.poll_in = uart_synapse32_poll_in,
	.poll_out = uart_synapse32_poll_out,
	.err_check = uart_synapse32_err_check,
};

#define UART_SYNAPSE32_INIT(n)                                                       \
	static const struct uart_synapse32_config uart_synapse32_cfg_##n = {         \
		.base = DT_INST_REG_ADDR(n),                                         \
		.clock_frequency = DT_INST_PROP_OR(n, clock_frequency,               \
			DT_PROP(DT_PATH(cpus, cpu_0), clock_frequency)),             \
		.current_speed = DT_INST_PROP(n, current_speed),                     \
	};                                                                           \
	DEVICE_DT_INST_DEFINE(n, uart_synapse32_init, NULL, NULL,                    \
			      &uart_synapse32_cfg_##n, PRE_KERNEL_1,                 \
			      CONFIG_SERIAL_INIT_PRIORITY,                           \
			      &uart_synapse32_driver_api);

DT_INST_FOREACH_STATUS_OKAY(UART_SYNAPSE32_INIT)
