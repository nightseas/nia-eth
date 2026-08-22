# ---------------------------------------------------------------------------
# File        : program_twoboard.tcl
# Description : The hardware manager side of program_twoboard.sh: opens one target by
#               cable serial, selects the device and programs the image.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set mode      [lindex $argv 0]
set hw_url    [lindex $argv 1]
set device    [lindex $argv 2]
set serial    [lindex $argv 3]
set pdi       [lindex $argv 4]

open_hw_manager
connect_hw_server -url $hw_url
set all_targets [get_hw_targets]
if {[llength $all_targets] == 0} {
  puts "PROGRAM FAIL: no hardware target at $hw_url"
  exit 2
}
foreach target $all_targets { puts "PROGRAM TARGET $target" }

if {$mode eq "list"} {
  puts "PROGRAM TARGET COUNT [llength $all_targets]"
  exit 0
}

if {$serial eq ""} {
  puts "PROGRAM FAIL: a cable serial is required. With two boards on one host the target order is not\
 a board identity, so an index selects an unknown board. Run the list mode and pass a serial."
  exit 2
}

set matched {}
foreach target $all_targets {
  if {[string match "*$serial*" $target]} { lappend matched $target }
}
if {[llength $matched] != 1} {
  puts "PROGRAM FAIL: cable serial '$serial' matched [llength $matched] of [llength $all_targets]\
 targets. It must match exactly one."
  exit 2
}
set target [lindex $matched 0]
puts "PROGRAM SELECTED $target"
open_hw_target $target

set devices [get_hw_devices]
puts "PROGRAM DEVICES $devices"
set matched_device {}
foreach candidate $devices {
  if {[get_property PART $candidate] eq $device} { lappend matched_device $candidate }
}
if {[llength $matched_device] != 1} {
  puts "PROGRAM FAIL: part $device matched [llength $matched_device] of [llength $devices] devices on\
 target $target. The enumerated device name is not stable across sessions, so the part is what selects,\
 and it must select exactly one."
  close_hw_target
  exit 2
}
set matched_device [lindex $matched_device 0]
puts "PROGRAM DEVICE $matched_device part $device"
current_hw_device $matched_device

if {$mode eq "check"} {
  refresh_hw_device -update_hw_probes false $matched_device
  puts "PROGRAM PART [get_property PART $matched_device]"
  puts "PROGRAM SERIAL $serial CHECK OK"
  close_hw_target
  exit 0
}

set_property PROGRAM.FILE $pdi $matched_device
program_hw_devices $matched_device
refresh_hw_device -update_hw_probes false $matched_device
puts "PROGRAM PART [get_property PART $matched_device]"
puts "PROGRAM SERIAL $serial WRITTEN $pdi"
close_hw_target
