# Reuse a routed placement while implementing the current run's optimized netlist.
# PERF_TAG=new-run REFERENCE_CHECKPOINT=/absolute/reference/routed.dcp vivado \
#   -mode batch -source incremental_performance.tcl
set here [file dirname [file normalize [info script]]]
if {![info exists ::env(PERF_TAG)] || ![regexp {^[A-Za-z0-9_-]+$} $::env(PERF_TAG)]} {
    error "PERF_TAG is required and must contain only letters, digits, underscores or hyphens"
}
if {![info exists ::env(REFERENCE_CHECKPOINT)]} {error "REFERENCE_CHECKPOINT is required"}
set tag $::env(PERF_TAG)
set build "$here/build/performance/$tag"
set current "$build/project/synapse32_performance.runs/impl_1/arty_linux_top_opt.dcp"
set reference [file normalize $::env(REFERENCE_CHECKPOINT)]
foreach path [list $current $reference] {if {![file isfile $path]} {error "Missing checkpoint: $path"}}
set output "$build/incremental"
file mkdir $output
set manifest [open "$output/input-manifest.txt" w]
puts $manifest "Current logical design: $current"
puts $manifest "Physical reference only: $reference"
puts $manifest "Incremental directive: TimingClosure (target WNS 0)"
puts $manifest [exec sha256sum $current $reference [file normalize [info script]]]
close $manifest
set_param general.maxThreads 4
open_checkpoint $current
foreach name {mig_clocking.xdc mig_tempmon.xdc} {read_xdc "$build/source/constraints/$name"}
source "$here/add_mig_clocking.tcl"
# The reference supplies matching physical locations/routes, not its older RTL.
read_checkpoint -incremental -directive TimingClosure $reference
report_incremental_reuse -file "$output/reuse-input.rpt"
place_design
route_design
check_mig_clocking "$output/methodology.rpt"
report_timing_summary -report_unconstrained -file "$output/timing.rpt"
report_utilization -file "$output/utilization.rpt"
report_drc -file "$output/drc.rpt"
report_cdc -details -file "$output/cdc.rpt"
report_bus_skew -file "$output/bus-skew.rpt"
report_incremental_reuse -file "$output/reuse-routed.rpt"
write_checkpoint -force "$output/routed.dcp"
foreach {report pattern message} [list "$output/cdc.rpt" {CDC-[0-9]+\s+Critical} "Critical CDC violation" "$output/bus-skew.rpt" {VIOLATED} "AXI CDC bus skew violation"] {
    set stream [open $report r];set contents [read $stream];close $stream
    if {[regexp $pattern $contents]} {error "$message: inspect $report"}
}
if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]<0} {error "Setup timing failed"}
if {[get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]<0} {error "Hold timing failed"}
write_bitstream -force "$output/synapse32_$tag.bit"
close_design
