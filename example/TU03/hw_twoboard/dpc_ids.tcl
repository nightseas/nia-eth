# ---------------------------------------------------------------------------
# File        : dpc_ids.tcl
# Description : Prints one DPC line per board as "DPCID <cable serial> <target id>".
#               The register scripts address a board by DPC target id, and an id is
#               an enumeration order that moves, so the serial is what names a board
#               and this is where the two are tied together.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set url [expr {[info exists ::env(NIA_HW_URL)] ? $::env(NIA_HW_URL) : "TCP:localhost:3121"}]

if {[catch {connect -url $url} msg]} {
    puts "DPCID_ERROR connect $msg"
    exit 2
}
after 2000

if {[catch {set properties [targets -target-properties -filter {name =~ "DPC"}]} msg]} {
    puts "DPCID_ERROR targets $msg"
    disconnect
    exit 2
}

set found 0
foreach entry $properties {
    if {[catch {set id [dict get $entry target_id]}]} { continue }
    if {[catch {set ctx [dict get $entry target_ctx]}]} { set ctx "" }
    set serial "unknown"
    if {[regexp {JTAG-[A-Za-z0-9]+-([0-9A-Za-z]+)-} $ctx -> matched]} { set serial $matched }
    puts "DPCID $serial $id"
    incr found
}
puts "DPCID_COUNT $found"
disconnect
