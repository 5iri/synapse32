# Check the clock-root correction on an existing routed design; no synthesis,
# programming, bitstream output, or clock relaxation. Model only the documented
# MIG temperature first-stage CDC with its existing 20ns datapath bound.
# vivado -mode batch -source fpga/arty_a7_35t/verify_mig_clocking.tcl
# Optional CLOCK_CHECKPOINT and CLOCK_AUDIT_DIR.
set here [file dirname [file normalize [info script]]]
set checkpoint "$here/build/performance/fetch-queue-div17/postopt/routed.dcp"
set output "$here/build/clock-constraints-audit/verified"
if {[info exists ::env(CLOCK_CHECKPOINT)]} {set checkpoint $::env(CLOCK_CHECKPOINT)}
if {[info exists ::env(CLOCK_AUDIT_DIR)]} {set output $::env(CLOCK_AUDIT_DIR)}
file mkdir $output
set_param general.maxThreads 2
source "$here/add_mig_clocking.tcl"

proc clock_snapshot {} {
    set result {}
    foreach clock [lsort [get_clocks]] {
        dict set result $clock [list [get_property PERIOD $clock] [get_property WAVEFORM $clock] [get_property SOURCE_PINS $clock]]
    }
    return $result
}
proc clock_root {name} {
    while {[get_property IS_GENERATED [get_clocks $name]]} {
        set name [get_property MASTER_CLOCK [get_clocks $name]]
    }
    return $name
}
proc timing_exceptions {path} {
    set f [open $path r];set text [read $f];close $f
    set result {}
    foreach line [split $text \n] {
        if {[regexp {^set_(false_path|max_delay|min_delay|multicycle_path|bus_skew|clock_groups|clock_uncertainty|clock_latency)\s} $line]} {lappend result $line}
    }
    return $result
}
proc reports {output label {check_clock 0}} {
    report_clocks -file "$output/$label-clocks.rpt"
    # Refresh methodology before the summary, which otherwise carries cached
    # methodology results restored from the checkpoint.
    if {$check_clock} {
        check_mig_clocking "$output/$label-methodology.rpt"
    } else {
        report_methodology -file "$output/$label-methodology.rpt"
    }
    report_timing_summary -report_unconstrained -file "$output/$label-timing.rpt"
    report_cdc -details -file "$output/$label-cdc.rpt"
    report_bus_skew -file "$output/$label-bus-skew.rpt"
    write_xdc -force "$output/$label.xdc"
}

open_checkpoint $checkpoint
set before [clock_snapshot]
reports $output before
read_xdc "$here/mig_clocking.xdc"
set after [clock_snapshot]
if {$before ne $after} {error "Clock periods/waveforms/source pins changed"}
foreach name {board_clk system/mig/sys_clk_i cpu50_raw ref200_raw clk_pll_i mem_refclk} {
    if {[clock_root $name] ne "board_clk"} {error "$name does not inherit board_clk"}
}
if {![get_property IS_GENERATED [get_clocks {system/mig/sys_clk_i}]]} {error "MIG still has an independent primary clock"}
reports $output clock-root 1
set f [open "$output/temperature-properties.txt" w]
foreach cell [get_cells -hier -filter {NAME =~ *temp_mon_enabled.u_tempmon/device_temp_sync_r1_reg* || NAME =~ *temp_mon_enabled.u_tempmon/xadc_supplied_temperature/temperature_reg*}] {
    puts $f "CELL $cell"
    foreach property {ASYNC_REG DONT_TOUCH IS_LOC_FIXED IS_BEL_FIXED} {
        puts $f "$property=[get_property $property $cell]"
    }
}
close $f
if {[timing_exceptions "$output/before.xdc"] ne [timing_exceptions "$output/clock-root.xdc"]} {error "Clock-root fix changed timing exceptions"}
read_xdc "$here/mig_tempmon.xdc"
if {$before ne [clock_snapshot]} {error "Temperature CDC constraint changed clocks"}
reports $output after 1
set original_exceptions [timing_exceptions "$output/before.xdc"]
set final_exceptions [timing_exceptions "$output/after.xdc"]
set added {}
foreach exception $final_exceptions {
    if {[lsearch -exact $original_exceptions $exception]<0} {lappend added $exception}
}
if {[llength $added]!=1 || [llength $final_exceptions]!=[llength $original_exceptions]+1 ||
    ![string match {set_max_delay -datapath_only*temperature_reg*device_temp_sync_r1_reg*20.000} [lindex $added 0]]} {
    error "Expected exactly the narrow 20ns temperature first-stage datapath-only addition"
}
set first [get_cells -hier -regexp {.*temp_mon_enabled\.u_tempmon/device_temp_sync_r1_reg\[[0-9]+\]}]
set second [get_cells -hier -regexp {.*temp_mon_enabled\.u_tempmon/device_temp_sync_r2_reg\[[0-9]+\]}]
set sources [get_cells -hier -regexp {.*temp_mon_enabled\.u_tempmon/xadc_supplied_temperature\.temperature_reg\[[0-9]+\]}]
set destinations [get_pins -of_objects $first -filter {REF_PIN_NAME == D}]
set hold_paths [get_timing_paths -from $first -to $second -delay_type min -max_paths 12]
set data_paths [get_timing_paths -from $sources -to $destinations -delay_type max -max_paths 12]
if {[llength $first]!=12 || [llength $sources]!=12 || [llength $destinations]!=12 ||
    [llength $hold_paths]!=12 || [llength $data_paths]!=12} {error "Temperature 12-source/12-endpoint coverage or second-stage hold checking changed"}
report_timing -from $sources -to $destinations -delay_type max -max_paths 12 -file "$output/temperature-data-bound.rpt"
report_timing -from $first -to $second -delay_type min -max_paths 12 -file "$output/temperature-stage2-hold.rpt"
set f [open "$output/temperature-data-bound.rpt" r];set bounds [read $f];close $f
if {[regexp -all {Requirement:\s+20\.000ns\s+\(MaxDelay} $bounds]!=12} {error "Temperature data paths lost their 20ns bounds"}
set f [open "$output/after-methodology.rpt" r];set method [read $f];close $f
if {[regexp {TIMING-(4|6|27)([ #|]|$)} $method]} {error "Clock methodology warning remains"}
set f [open "$output/after-cdc.rpt" r];set cdc [read $f];close $f
if {[regexp {CDC-[0-9]+\s+Critical} $cdc]} {error "Critical CDC violation"}
set f [open "$output/after-bus-skew.rpt" r];set skew [read $f];close $f
if {[regexp {VIOLATED} $skew]} {error "Bus skew violation"}
puts "PASS: MIG shares board_clk; all [dict size $before] clocks preserved; TIMING-4/6/27 absent; only 12-source/12-endpoint first-stage CDC uses 20ns datapath-only; all 12 second-stage hold paths remain timed"
if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]<0} {error "Corrected model fails setup timing"}
if {[get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]<0} {error "Corrected model fails hold timing"}

close_design
