# ---------------------------------------------------------------------------
# File        : program.tcl
# Description : The hardware manager side of program.sh: selects the board by JTAG
#               cable serial, selects the device and programs the image. A serial is
#               required whenever more than one board is attached, because the first
#               target is otherwise an arbitrary choice.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set mode   [lindex $argv 0]
set hw_url [lindex $argv 1]
set device [lindex $argv 2]
set pdi    [lindex $argv 3]
set serial [expr {[llength $argv] > 4 ? [lindex $argv 4] : ""}]

open_hw_manager
connect_hw_server -url $hw_url
set targets [get_hw_targets]
if {[llength $targets] == 0} {
  puts "PROGRAM FAIL: no hardware target at $hw_url"
  exit 2
}
puts "PROGRAM TARGETS $targets"

if {$serial eq ""} {
  if {[llength $targets] > 1} {
    puts "PROGRAM FAIL: [llength $targets] targets are attached and no serial was given, so the board\
 would be an arbitrary choice. Set NIA_TARGET to a substring of the JTAG cable serial of the board to\
 write. The targets above carry the serials."
    disconnect_hw_server
    exit 2
  }
  set chosen [lindex $targets 0]
} else {
  set chosen ""
  foreach target $targets {
    if {[string first $serial $target] >= 0} { set chosen $target }
  }
  if {$chosen eq ""} {
    puts "PROGRAM FAIL: no target matches serial $serial. Attached: $targets"
    disconnect_hw_server
    exit 2
  }
}
puts "PROGRAM SELECTED $chosen"
open_hw_target $chosen

set devices [get_hw_devices]
puts "PROGRAM DEVICES $devices"
set match [get_hw_devices $device]
if {[llength $match] == 0} {
  puts "PROGRAM FAIL: device $device is not on this target"
  close_hw_target
  exit 2
}
current_hw_device $match

if {$mode eq "check"} {
  refresh_hw_device -update_hw_probes false $match
  puts "PROGRAM PART [get_property PART $match]"
  close_hw_target
  exit 0
}

set_property PROGRAM.FILE $pdi $match
program_hw_devices $match
catch {refresh_hw_device -update_hw_probes false $match}
puts "PROGRAM WRITTEN $pdi to $chosen"
close_hw_target
