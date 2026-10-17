# Refine an existing routed performance checkpoint with the board/MIG clock root
# correction applied even when the checkpoint predates mig_clocking.xdc.
# PERF_TAG=fetch-queue-div17 vivado -mode batch -source refine_performance.tcl
set here [file dirname [file normalize [info script]]]
if {![info exists ::env(PERF_TAG)] || $::env(PERF_TAG) eq ""} {error "PERF_TAG is required"}
set tag $::env(PERF_TAG)
if {![regexp {^[A-Za-z0-9_-]+$} $tag]} {error "Invalid PERF_TAG"}
set build "$here/build/performance/$tag"
set output "$build/postopt"
file mkdir $output
set_param general.maxThreads 4
open_checkpoint "$build/project/synapse32_performance.runs/impl_1/arty_linux_top_routed.dcp"
foreach name {mig_clocking.xdc mig_tempmon.xdc} {
    set constraint "$build/source/constraints/$name"
    if {![file exists $constraint]} {set constraint "$here/$name"}
    read_xdc $constraint
}
source "$here/add_mig_clocking.tcl"
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
check_mig_clocking "$output/methodology.rpt"
report_timing_summary -report_unconstrained -file "$output/timing.rpt"
report_utilization -file "$output/utilization.rpt"
report_drc -file "$output/drc.rpt"
report_cdc -details -file "$output/cdc.rpt"
report_bus_skew -file "$output/bus-skew.rpt"
write_checkpoint -force "$output/routed.dcp"
foreach {report pattern message} [list "$output/cdc.rpt" {CDC-[0-9]+\s+Critical} "Critical CDC violation" "$output/bus-skew.rpt" {VIOLATED} "AXI CDC bus skew violation"] {
    set stream [open $report r];set contents [read $stream];close $stream
    if {[regexp $pattern $contents]} {error "$message: inspect $report"}
}
if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]<0} {error "Setup timing failed"}
if {[get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]<0} {error "Hold timing failed"}
write_bitstream -force "$output/synapse32_$tag.bit"
close_design
