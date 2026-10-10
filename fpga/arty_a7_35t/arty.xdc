# Arty A7-35 Rev. D/E. Source: Digilent Arty-A7-35-Master.xdc.
# DDR pins, VREF and memory timing are constrained by MIG's generated XDC.
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports clk100]
create_clock -name board_clk -period 10.000 [get_ports clk100]
set_property -dict {PACKAGE_PIN C2 IOSTANDARD LVCMOS33} [get_ports reset_n]
set_property -dict {PACKAGE_PIN A9 IOSTANDARD LVCMOS33} [get_ports uart_rx]
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33} [get_ports uart_tx]
set_property -dict {PACKAGE_PIN H5 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN J5 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN T9 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_false_path -from [get_ports reset_n]
set_false_path -from [get_ports uart_rx] -to [get_cells -hier -filter {NAME =~ *rx_meta* || NAME =~ *uart_sync_reg*}]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
# These single-bit MIG status signals enter explicit synchronizers in cpu50.
# Constrain only the first stage; later stages retain normal setup/hold checks.
set status_first_stage [get_cells -hier -regexp {.*(cal_sync|reset_sync)_reg\[0\]}]
set_false_path -to [get_pins -of_objects $status_first_stage -filter {REF_PIN_NAME == D}]
# UART and LEDs are asynchronous external interfaces, not synchronous buses.
set_false_path -to [get_ports {uart_tx led[*]}]
