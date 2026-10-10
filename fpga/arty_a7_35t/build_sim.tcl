# Run from this directory: vivado -mode batch -source build_sim.tcl
set here [file dirname [file normalize [info script]]]
set repo [file normalize "$here/../.."]
set build "$here/build/vivado"
file mkdir $build
set_param general.maxThreads 2
create_project -force synapse32_ddr3 "$build/project" -part xc7a35ticsg324-1L
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
create_ip -name mig_7series -vendor xilinx.com -library ip -version 4.2 -module_name mig_arty
set_property CONFIG.XML_INPUT_FILE "$here/mig.prj" [get_ips mig_arty]
generate_target all [get_ips mig_arty]
create_ip -name axi_clock_converter -vendor xilinx.com -library ip -version 2.1 -module_name axi_cpu_cdc
set_property -dict [list CONFIG.ADDR_WIDTH {28} CONFIG.DATA_WIDTH {128} CONFIG.ID_WIDTH {4} CONFIG.ACLK_ASYNC {1}] [get_ips axi_cpu_cdc]
generate_target all [get_ips axi_cpu_cdc]
export_ip_user_files -of_objects [get_ips mig_arty] -no_script -sync -force
set original "$build/project/synapse32_ddr3.xpr"
open_example_project -force -dir "$build/mig_example" [get_ips mig_arty]
set example_defines [get_property verilog_define [get_filesets sim_1]]
set example_includes [get_property include_dirs [get_filesets sim_1]]
close_project
open_project $original
proc find_files {dir pattern} {
    set found [glob -nocomplain -directory $dir $pattern]
    foreach path [glob -nocomplain -directory $dir *] {
        if {[file isdirectory $path]} {set found [concat $found [find_files $path $pattern]]}
    }
    return $found
}
set models [find_files "$build/mig_example" ddr3_model.v]
if {![llength $models]} {set models [find_files "$build/mig_example" ddr3_model.sv]}
if {![llength $models]} {error "MIG example did not export a DDR3 component simulation model"}
set model [lindex $models 0]
# The CPU uses default_nettype none. Restore implicit wire nets before the
# vendor's non-ANSI model ports, rather than leaking that directive into it.
set model_includes [file dirname $model]
set stream [open $model r]
set model_source [read $stream]
close $stream
set model "$build/ddr3_model.sv"
set stream [open $model w]
puts $stream "`default_nettype wire"
puts -nonewline $stream $model_source
close $stream
set wire_source [lindex [find_files "$build/mig_example" wiredly.v] 0]
set stream [open $wire_source r]
set wire_contents [read $stream]
close $stream
set wire_model "$build/wiredly.v"
set stream [open $wire_model w]
puts $stream "`default_nettype wire"
puts -nonewline $stream $wire_contents
close $stream
set rtl_files [glob "$repo/rtl/*.v" "$repo/rtl/core_modules/*.v" "$repo/rtl/pipeline_stages/*.v" "$repo/rtl/mmu/*.v"]
add_files -norecurse $rtl_files
set_property file_type SystemVerilog [get_files $rtl_files]
add_files -norecurse [list "$here/axi_word_bridge.sv" "$here/sv32_bus_port.sv" "$here/uart_boot_loader.sv" "$here/synapse_ddr3_system.sv" "$here/arty_ddr3_top.sv"]
set_property file_type Verilog [get_files "$here/arty_ddr3_top.sv"]
set_property include_dirs [list "$repo/rtl/include"] [get_filesets sources_1]
set_property top arty_ddr3_top [get_filesets sources_1]
add_files -fileset sim_1 -norecurse [list "$here/tb_ddr3.sv" $model $wire_model "$here/boot.hex"]
set_property file_type Verilog [get_files "$here/tb_ddr3.sv"]
set_property file_type {Memory Initialization Files} [get_files "$here/boot.hex"]
set_property include_dirs [concat [list "$repo/rtl/include" $model_includes] $example_includes] [get_filesets sim_1]
set_property verilog_define $example_defines [get_filesets sim_1]
set_property top tb_ddr3 [get_filesets sim_1]
set_property xsim.simulate.runtime 0ns [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
set simdir "$build/project/synapse32_ddr3.sim/sim_1/behav/xsim"
file mkdir $simdir
file copy -force "$here/boot.hex" "$simdir/boot.hex"
launch_simulation
run all
close_sim
set logfile "$simdir/simulate.log"
set stream [open $logfile r]
set result [read $stream]
close $stream
if {[string first "PASS: Synapse32 Arty A7-35T MIG DDR3 simulation" $result] < 0} {
    error "DDR3 simulation did not pass; inspect $logfile"
}
close_project
