# vivado -mode batch -source program.tcl [-tclargs /path/to/image.bit]
set here [file dirname [file normalize [info script]]]
set bit "$here/build/board/synapse32_linux.bit"
if {$argc > 0} {set bit [file normalize [lindex $argv 0]]}
if {![file exists $bit]} {error "Bitstream missing: run build_bitstream.tcl first"}
open_hw_manager
connect_hw_server
open_hw_target
set devices [get_hw_devices -filter {PART =~ xc7a35t*}]
if {[llength $devices] != 1} {error "Expected one Arty A7-35T, found [llength $devices]"}
set device [lindex $devices 0]
current_hw_device $device
refresh_hw_device $device
set_property PROGRAM.FILE $bit $device
program_hw_devices $device
close_hw_manager
