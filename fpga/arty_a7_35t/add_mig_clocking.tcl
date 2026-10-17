# Register the integration constraint without modifying generated MIG/IP files.
# This also handles performance projects cloned from older board projects.
proc add_mig_clocking_constraints {directory} {
    foreach name {mig_clocking.xdc mig_tempmon.xdc} {
        set path [file normalize "$directory/$name"]
        if {![llength [get_files -quiet $path]]} {
            add_files -fileset constrs_1 -norecurse $path
        }
        set_property PROCESSING_ORDER LATE [get_files $path]
        # MIG is an OOC black box during top-level RTL synthesis. Its internal
        # clock pins/registers exist only once the IP checkpoint is linked.
        set_property USED_IN_SYNTHESIS false [get_files $path]
        set_property USED_IN_IMPLEMENTATION true [get_files $path]
    }
}

proc check_mig_tempmon_structure {} {
    set sources [get_cells -hier -regexp {.*temp_mon_enabled\.u_tempmon/xadc_supplied_temperature\.temperature_reg\[[0-9]+\]}]
    set first [get_cells -hier -regexp {.*temp_mon_enabled\.u_tempmon/device_temp_sync_r1_reg\[[0-9]+\]}]
    set second [get_cells -hier -regexp {.*temp_mon_enabled\.u_tempmon/device_temp_sync_r2_reg\[[0-9]+\]}]
    if {[llength $sources]!=12 || [llength $first]!=12 || [llength $second]!=12} {
        error "Unexpected MIG temperature CDC structure: expected 12 source, first-stage and second-stage registers"
    }
    foreach cell [concat $first $second] {
        if {![get_property ASYNC_REG $cell]} {error "MIG temperature synchronizer lacks ASYNC_REG: $cell"}
    }
    if {[llength [get_pins -of_objects $first -filter {REF_PIN_NAME == D}]]!=12} {error "Expected exactly 12 temperature first-stage data pins"}
}

# Run this before the timing summary: checkpoint-restored summaries can carry
# stale methodology results even after clock constraints have been corrected.
proc check_mig_clocking {report} {
    check_mig_tempmon_structure
    report_methodology -file $report
    set f [open $report r];set text [read $f];close $f
    if {[regexp {TIMING-(4|6|27)([ #|]|$)} $text]} {
        error "Board/MIG clock-root constraints failed: inspect $report"
    }
    set mig_clock [get_clocks -quiet {system/mig/sys_clk_i}]
    if {[llength $mig_clock]!=1 || ![get_property IS_GENERATED $mig_clock] ||
        [get_property MASTER_CLOCK $mig_clock] ne "board_clk"} {
        error "MIG sys_clk_i must be a generated clock derived from board_clk"
    }
}
