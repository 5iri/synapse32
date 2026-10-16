# vivado -mode batch -source build_bitstream.tcl
set here [file dirname [file normalize [info script]]]
set repo [file normalize "$here/../.."]
set build "$here/build/board"
file mkdir $build
set_param general.maxThreads 4
create_project -force synapse32_linux "$build/project" -part xc7a35ticsg324-1L
set_property target_language Verilog [current_project]
create_ip -name mig_7series -vendor xilinx.com -library ip -version 4.2 -module_name mig_arty
set_property CONFIG.XML_INPUT_FILE "$here/mig.prj" [get_ips mig_arty]
generate_target all [get_ips mig_arty]
create_ip -name axi_clock_converter -vendor xilinx.com -library ip -version 2.1 -module_name axi_cpu_cdc
set_property -dict [list CONFIG.ADDR_WIDTH {28} CONFIG.DATA_WIDTH {128} CONFIG.ID_WIDTH {4} CONFIG.ACLK_ASYNC {1}] [get_ips axi_cpu_cdc]
generate_target all [get_ips axi_cpu_cdc]
set rtl [glob "$repo/rtl/*.v" "$repo/rtl/core_modules/*.v" "$repo/rtl/pipeline_stages/*.v" "$repo/rtl/mmu/*.v"]
set fabric [list "$here/axi_word_bridge.sv" "$here/sv32_bus_port.sv" "$here/uart_boot_loader.sv" "$here/synapse_ddr3_system.sv" "$here/arty_ddr3_top.sv" "$here/arty_linux_top.sv"]
add_files -norecurse [concat $rtl $fabric]
set_property file_type SystemVerilog [get_files [concat $rtl $fabric]]
set_property include_dirs [list "$repo/rtl/include"] [get_filesets sources_1]
set_property top arty_linux_top [get_filesets sources_1]
set generics {}
foreach name {CPU_DIVIDE BOOT_BAUD} {
    if {[info exists ::env($name)]} {
        if {![string is integer -strict $::env($name)] || $::env($name) <= 0} {error "$name must be a positive integer"}
        if {$name eq "CPU_DIVIDE" && $::env($name) > 128} {error "CPU_DIVIDE must be in 1..128"}
        lappend generics "$name=$::env($name)"
    }
}
if {[info exists ::env(DCACHE_LINES)]} {
    set lines $::env(DCACHE_LINES)
    if {![string is integer -strict $lines] || $lines < 0 || $lines > 65536 || ($lines > 0 && ($lines & ($lines-1)) != 0)} {
        error "DCACHE_LINES must be zero or a power of two up to 65536"
    }
    lappend generics "DCACHE_LINES=$lines"
}
if {[llength $generics]} {set_property generic $generics [get_filesets sources_1]}
add_files -fileset constrs_1 -norecurse "$here/arty.xdc"
update_compile_order -fileset sources_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Synthesis failed"}
launch_runs impl_1 -to_step route_design -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Implementation failed"}
open_run impl_1
report_utilization -file "$build/utilization.rpt"
report_timing_summary -report_unconstrained -file "$build/timing.rpt"
report_drc -file "$build/drc.rpt"
report_cdc -details -file "$build/cdc.rpt"
report_bus_skew -file "$build/bus-skew.rpt"
foreach {report pattern message} [list "$build/cdc.rpt" {CDC-[0-9]+\s+Critical} "Critical CDC violation" "$build/bus-skew.rpt" {VIOLATED} "AXI CDC bus skew violation"] {
    set stream [open $report r]
    set contents [read $stream]
    close $stream
    if {[regexp $pattern $contents]} {error "$message: inspect $report"}
}
if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]] < 0} {error "Setup timing failed: inspect timing.rpt"}
if {[get_property SLACK [get_timing_paths -delay_type min -max_paths 1]] < 0} {error "Hold timing failed: inspect timing.rpt"}
write_bitstream -force "$build/synapse32_linux.bit"
close_project
