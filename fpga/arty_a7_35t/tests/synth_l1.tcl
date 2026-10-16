# Structural regression: a 4 KiB L1 bank must use physical block RAM.
set here [file dirname [file dirname [file normalize [info script]]]]
set source "$here/physical_l1_cache.sv"
if {[info exists ::env(L1_SOURCE)]} {set source [file normalize $::env(L1_SOURCE)]}
set build "$here/build/l1-synthesis-check"
if {[info exists ::env(L1_SYNTH_BUILD)]} {set build [file normalize $::env(L1_SYNTH_BUILD)]}
file mkdir $build
set_param general.maxThreads 2
read_verilog -sv $source
synth_design -top physical_l1_cache -part xc7a35ticsg324-1L -generic LINES=256
report_utilization -file "$build/utilization.rpt"
set blocks [get_cells -hier -filter {REF_NAME =~ RAMB*}]
if {[llength $blocks]<1} {error "4 KiB L1 bank failed to infer block RAM"}
puts "PASS: L1 bank inferred [llength $blocks] block RAM primitives"
