# MIG's generated XDC declares sys_clk_i as an independent primary clock for
# standalone use. In arty_linux_top it is the same physical input as clk100,
# which arty.xdc already constrains as board_clk. Preserve MIG's clock name for
# its generated clocks, but inherit the real root and insertion delay. No clock
# period or exception is changed. Read LATE, after MIG's scoped constraints.
create_generated_clock -name {system/mig/sys_clk_i} -source [get_ports clk100] -divide_by 1 [get_pins {system/mig/sys_clk_i}]
