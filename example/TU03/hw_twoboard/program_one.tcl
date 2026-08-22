# ---------------------------------------------------------------------------
# File        : program_one.tcl
# Description : Writes one image to one board, selecting the board by JTAG cable
#               serial. The single board programmer of the image tree opens the
#               first target it finds, which is an arbitrary choice as soon as
#               more than one board is attached, so this selects explicitly.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
# Version     : 0.1
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set serial [lindex $argv 0]
set pdi    [lindex $argv 1]
set hw_url [expr {[llength $argv] > 2 ? [lindex $argv 2] : "localhost:3121"}]
set device [expr {[llength $argv] > 3 ? [lindex $argv 3] : "xcvp1552"}]

if {$serial eq "" || $pdi eq ""} {
    puts "PROGRAM_ONE FAIL: usage program_one.tcl <cable serial> <image.pdi> \[hw_url\] \[part\]"
    exit 2
}
if {![file exists $pdi]} {
    puts "PROGRAM_ONE FAIL: $pdi does not exist"
    exit 2
}

open_hw_manager
connect_hw_server -url $hw_url

set chosen ""
foreach target [get_hw_targets] {
    if {[string first $serial $target] >= 0} { set chosen $target }
}
if {$chosen eq ""} {
    puts "PROGRAM_ONE FAIL: no target matches serial $serial. Present: [get_hw_targets]"
    disconnect_hw_server
    exit 2
}
puts "PROGRAM_ONE TARGET $chosen"

open_hw_target $chosen
set match [lindex [get_hw_devices] 0]
foreach candidate [get_hw_devices] {
    if {[string first $device $candidate] >= 0} { set match $candidate }
}
current_hw_device $match
puts "PROGRAM_ONE DEVICE $match"

set_property PROGRAM.FILE $pdi $match
program_hw_devices $match
catch {refresh_hw_device -update_hw_probes false $match}
puts "PROGRAM_ONE WRITTEN $pdi to $serial"

close_hw_target
disconnect_hw_server
