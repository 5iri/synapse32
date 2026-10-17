# MIG 7-series v4.2 temperature sampling is an intentional sampled-bus CDC:
# tempmon.v126-169 marks r1..r5 ASYNC_REG and accepts an output only after
# 16 stable destination cycles; v302-310 updates the XADC source every 10us.
# Its generated mig_arty.xdc370-371 contains a commented datapath-only 20ns
# bound, followed by a plain 20ns max delay. Restore datapath-only semantics
# ONLY from XADC temperature storage to the first synchronization stage.
# Retain the vendor's 20ns data bound and normal r1->r2 setup/hold checks.
# AMD UG835 explains this CDC use and its deliberately excluded first-stage
# hold check: https://docs.amd.com/r/2021.2-English/ug835-vivado-tcl-commands/set_max_delay
# Read LATE for implementation only. The build Tcl gate checks the exact
# 12-source/12-first-stage/12-second-stage structure and ASYNC_REG properties;
# Tcl control-flow assertions are not supported inside Vivado XDC files.
set mig_temperature_sources [get_cells -hier -regexp {.*temp_mon_enabled\.u_tempmon/xadc_supplied_temperature\.temperature_reg\[[0-9]+\]}]
set mig_temperature_first [get_cells -hier -regexp {.*temp_mon_enabled\.u_tempmon/device_temp_sync_r1_reg\[[0-9]+\]}]
set mig_temperature_destinations [get_pins -of_objects $mig_temperature_first -filter {REF_PIN_NAME == D}]
set_max_delay -datapath_only -from $mig_temperature_sources -to $mig_temperature_destinations 20.000
