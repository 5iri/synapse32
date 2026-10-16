set here [file dirname [file normalize [info script]]]
set repo [file normalize "$here/../.."]
set build "$here/build/bram-coremark/board"
file mkdir $build
set_param general.maxThreads 4
set mem "$here/build/bram-coremark/firmware50/coremark_bram.mem"
if {[info exists ::env(BRAM_MEM_FILE)]} {set mem [file normalize $::env(BRAM_MEM_FILE)]}
if {![file exists $mem]} {error "Build firmware first: test_bram_coremark.sh --firmware-only"}
create_project -force synapse32_bram "$build/project" -part xc7a35ticsg324-1L
set rtl [glob "$repo/rtl/*.v" "$repo/rtl/core_modules/*.v" "$repo/rtl/pipeline_stages/*.v"]
set sources [concat $rtl [list "$here/bram_coremark_system.sv" "$here/arty_bram_coremark_top.sv"]]
add_files -norecurse $sources
set_property file_type SystemVerilog [get_files $sources]
set_property include_dirs [list "$repo/rtl/include"] [get_filesets sources_1]
set_property top arty_bram_coremark_top [get_filesets sources_1]
set_property generic [list "MEM_FILE=\"$mem\""] [get_filesets sources_1]
# The ordinary Arty constraints already contain only clock/reset/UART/LED pins;
# MIG pins live in generated IP XDC and are not part of this standalone build.
# Remove only the MIG status synchronizer exception, absent from this design.
set input [open "$here/arty.xdc" r]
set xdc [read $input]
close $input
set output [open "$build/bram.xdc" w]
foreach line [split $xdc "\n"] {
    if {[string first {set status_first_stage} $line]==0 || [string first {$status_first_stage} $line]>=0 || [string first {set_false_path -from [get_ports uart_rx]} $line]==0} {continue}
    puts $output $line
}
puts $output {set reset_first [get_cells -hier -regexp {.*reset_sync_reg\[0\]}]}
puts $output {set_false_path -to [get_pins -of_objects $reset_first -filter {REF_PIN_NAME == D}]}
puts $output {set rx_first [get_cells -hier -regexp {.*rx_sync_reg\[0\]}]}
puts $output {set_false_path -from [get_ports uart_rx] -to [get_pins -of_objects $rx_first -filter {REF_PIN_NAME == D}]}
close $output
add_files -fileset constrs_1 -norecurse "$build/bram.xdc"
update_compile_order -fileset sources_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Synthesis failed"}
open_run synth_1
set blocks [get_cells -hier -filter {REF_NAME =~ RAMB*}]
if {[llength $blocks] == 0} {error "Synchronous memory did not infer physical block RAM"}
report_utilization -file "$build/synthesis-utilization.rpt"
close_design
launch_runs impl_1 -to_step route_design -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Implementation failed"}
open_run impl_1
report_utilization -file "$build/utilization.rpt"
report_timing_summary -report_unconstrained -file "$build/timing.rpt"
report_drc -file "$build/drc.rpt"
report_cdc -details -file "$build/cdc.rpt"
if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]] < 0} {error "Setup timing failed"}
if {[get_property SLACK [get_timing_paths -delay_type min -max_paths 1]] < 0} {error "Hold timing failed"}
write_bitstream -force "$build/synapse32_bram_coremark.bit"
close_project
