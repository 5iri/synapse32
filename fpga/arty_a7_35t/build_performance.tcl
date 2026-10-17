# Reuse generated MIG/CDC IP while keeping each performance run isolated.
# PERF_TAG=fast-l1-50 FAST_L1=1 CPU_DIVIDE=20 vivado -mode batch -source build_performance.tcl
set here [file dirname [file normalize [info script]]]
set repo [file normalize "$here/../.."]
set tag fast-l1-50
if {[info exists ::env(PERF_TAG)]} {set tag $::env(PERF_TAG)}
if {![regexp {^[A-Za-z0-9_-]+$} $tag]} {error "Invalid PERF_TAG"}
set build "$here/build/performance/$tag"
file mkdir $build
set original "$here/build/board/project/synapse32_linux.xpr"
if {![file exists $original]} {error "Run build_bitstream.tcl once to generate MIG/CDC IP"}
set defaults {CPU_DIVIDE 20 BOOT_BAUD 1000000 DCACHE_LINES 256 ICACHE_LINES 256 FAST_L1 1 STORE_BUFFER_DEPTH 0 FAST_MULTIPLY 0 FETCH_QUEUE 0 LOAD_FORWARDING 0 FAST_STORE_ACK 0}
set generics {}
foreach {name value} $defaults {
    if {[info exists ::env($name)]} {set value $::env($name)}
    if {![string is integer -strict $value]} {error "$name must be an integer"}
    if {$name eq "CPU_DIVIDE" && ($value<1 || $value>128)} {error "CPU_DIVIDE must be 1..128"}
    if {$name eq "BOOT_BAUD" && $value<1} {error "BOOT_BAUD must be positive"}
    if {$name in {FAST_L1 FAST_MULTIPLY FETCH_QUEUE LOAD_FORWARDING FAST_STORE_ACK} && $value ni {0 1}} {error "$name must be 0 or 1"}
    if {$name eq "STORE_BUFFER_DEPTH" && ($value<0 || $value>8)} {error "STORE_BUFFER_DEPTH must be 0..8"}
    if {$name in {DCACHE_LINES ICACHE_LINES} && ($value<0 || $value>65536 || ($value>0 && ($value&($value-1))!=0))} {
        error "$name must be zero or a power of two up to 65536"
    }
    lappend generics "$name=$value"
    dict set configuration $name $value
}
# Sources are snapshotted before synthesis; later edits cannot change this run.
file delete -force "$build/source"
file mkdir "$build/source/fabric"
file mkdir "$build/source/constraints"
foreach name {arty.xdc mig_clocking.xdc mig_tempmon.xdc} {file copy -force "$here/$name" "$build/source/constraints/$name"}
file copy -force "$repo/rtl" "$build/source/rtl"
set fabric_names {axi_word_bridge.sv physical_l1_cache.sv ordered_write_buffer.sv fpga_perf_counters.sv sv32_bus_port.sv instruction_fetch_queue.sv uart_boot_loader.sv synapse_ddr3_system.sv arty_ddr3_top.sv arty_linux_top.sv}
foreach name $fabric_names {file copy -force "$here/$name" "$build/source/fabric/$name"}
set rtl [glob "$build/source/rtl/*.v" "$build/source/rtl/core_modules/*.v" "$build/source/rtl/pipeline_stages/*.v" "$build/source/rtl/mmu/*.v"]
set fabric [glob "$build/source/fabric/*.sv"]
set manifest [open "$build/source-manifest.txt" w]
puts $manifest "generics: $generics"
set source_head unavailable
if {[info exists ::env(SOURCE_HEAD)]} {set source_head $::env(SOURCE_HEAD)}
if {$source_head eq "unavailable" && ![catch {exec git -C $repo rev-parse HEAD} revision]} {set source_head $revision}
puts $manifest "source HEAD: $source_head"
puts $manifest [exec sha256sum {*}$rtl {*}$fabric {*}[glob "$build/source/rtl/include/*.vh"]]
puts $manifest [exec sha256sum {*}[glob "$build/source/constraints/*.xdc"]]
close $manifest
set_param general.maxThreads 4
open_project $original
save_project_as -include_local_ip_cache -force synapse32_performance "$build/project"
source "$here/add_mig_clocking.tcl"
# Use this run's frozen board constraints, including when cloning an old project.
foreach constraint [get_files -of_objects [get_filesets constrs_1]] {
    if {[file tail $constraint] in {arty.xdc mig_clocking.xdc mig_tempmon.xdc}} {remove_files $constraint}
}
add_files -fileset constrs_1 -norecurse "$build/source/constraints/arty.xdc"
add_mig_clocking_constraints "$build/source/constraints"
set old_sources {}
foreach source [get_files -of_objects [get_filesets sources_1]] {
    set path [file normalize $source]
    if {[string match "$repo/rtl/*" $path] || [file dirname $path] eq $here} {lappend old_sources $source}
}
if {[llength $old_sources]} {remove_files $old_sources}
add_files -norecurse [concat $rtl $fabric]
set_property file_type SystemVerilog [get_files [concat $rtl $fabric]]
set_property include_dirs [list "$build/source/rtl/include"] [get_filesets sources_1]
set_property top arty_linux_top [get_filesets sources_1]
set_property generic $generics [get_filesets sources_1]
update_compile_order -fileset sources_1
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Synthesis failed"}
open_run synth_1
report_utilization -file "$build/synthesis-utilization.rpt"
if {[dict get $configuration FAST_L1] &&
    ([dict get $configuration DCACHE_LINES]>=64 || [dict get $configuration ICACHE_LINES]>=64)} {
    set cache_blocks [get_cells -hier -filter {REF_NAME =~ RAMB* && NAME =~ *l1*}]
    if {[llength $cache_blocks]==0} {error "L1 data arrays failed to infer block RAM"}
}
close_design
launch_runs impl_1 -to_step route_design -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Implementation failed"}
open_run impl_1
report_utilization -file "$build/utilization.rpt"
check_mig_clocking "$build/methodology.rpt"
report_timing_summary -report_unconstrained -file "$build/timing.rpt"
report_drc -file "$build/drc.rpt"
report_cdc -details -file "$build/cdc.rpt"
report_bus_skew -file "$build/bus-skew.rpt"
foreach {report pattern message} [list "$build/cdc.rpt" {CDC-[0-9]+\s+Critical} "Critical CDC violation" "$build/bus-skew.rpt" {VIOLATED} "AXI CDC bus skew violation"] {
    set stream [open $report r];set contents [read $stream];close $stream
    if {[regexp $pattern $contents]} {error "$message: inspect $report"}
}
if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]<0} {error "Setup timing failed"}
if {[get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]<0} {error "Hold timing failed"}
write_bitstream -force "$build/synapse32_$tag.bit"
close_project
