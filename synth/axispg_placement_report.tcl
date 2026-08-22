# ---------------------------------------------------------------------------
# File        : axispg_placement_report.tcl
# Description : Reports where the AXI-Stream instrument's cells were placed, which clock
#               regions they span and the worst paths between them.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set dcp [lindex $argv 0]
open_checkpoint $dcp

proc nia_report_cells {label cells} {
  puts "PLACE_GROUP $label count [llength $cells]"
  foreach c $cells {
    set site [get_property -quiet LOC $c]
    set bel  [get_property -quiet BEL $c]
    set cr   [get_property -quiet CLOCK_REGION $c]
    puts "PLACE_CELL $label site=$site bel=$bel clock_region=$cr name=[get_property NAME $c]"
  }
}

nia_report_cells dcmac [get_cells -quiet -hier -filter {REF_NAME =~ DCMAC* || PRIMITIVE_TYPE =~ *DCMAC*}]
nia_report_cells gtm [get_cells -quiet -hier -filter {REF_NAME =~ GTM_QUAD*}]

foreach client {0 1} {
  set pat "*g_port\[$client\].u_port/u_adapter/u_tx_frame_fifo/*"
  set brams [get_cells -quiet -hier -filter "NAME =~ $pat && PRIMITIVE_TYPE =~ BLOCKRAM.*.*"]
  nia_report_cells tx_frame_fifo_bram_$client $brams
  set pat_rx "*g_port\[$client\].u_port/u_adapter/u_rx_frame_fifo/*"
  set brams_rx [get_cells -quiet -hier -filter "NAME =~ $pat_rx && PRIMITIVE_TYPE =~ BLOCKRAM.*.*"]
  nia_report_cells rx_frame_fifo_bram_$client $brams_rx
}

puts "PLACE_CLOCK_REGIONS"
foreach cr [lsort [get_clock_regions]] {
  puts "PLACE_CR $cr"
}

set worst [get_timing_paths -quiet -setup -max_paths 6 -slack_lesser_than 0.100]
foreach p $worst {
  puts "PLACE_PATH slack=[get_property SLACK $p] levels=[get_property LOGIC_LEVELS $p] skew=[get_property SKEW $p]"
  puts "PLACE_PATH_FROM [get_property STARTPOINT_PIN $p]"
  puts "PLACE_PATH_TO   [get_property ENDPOINT_PIN $p]"
}
puts "PLACE_DONE"

foreach s [get_sites -quiet -filter {SITE_TYPE =~ *DCMAC*}] {
  puts "PLACE_SITE dcmac $s tile=[get_tiles -quiet -of_objects $s] cr=[get_clock_regions -quiet -of_objects $s]"
}
foreach s [get_sites -quiet -filter {SITE_TYPE =~ *GTM*}] {
  puts "PLACE_SITE gtm $s cr=[get_clock_regions -quiet -of_objects $s]"
}
foreach c [get_clocks -quiet] {
  puts "PLACE_CLOCK $c period=[get_property PERIOD $c] regions=[get_clock_regions -quiet -of_objects [get_nets -quiet -of_objects $c]]"
}
puts "PLACE_DONE2"

foreach s {RAMB36_X14Y52 RAMB36_X15Y51 RAMB36_X16Y49 RAMB36_X16Y44 RAMB18_X14Y107 RAMB18_X15Y97} {
  set st [get_sites -quiet $s]
  if {[llength $st]} { puts "PLACE_BRAMCR $s cr=[get_clock_regions -quiet -of_objects $st]" }
}
foreach cr {X8Y2 X9Y2 X8Y3 X9Y3 X8Y4 X9Y4 X7Y3 X7Y2} {
  set r [get_clock_regions -quiet $cr]
  if {[llength $r]} {
    puts "PLACE_CRINV $cr ramb36=[llength [get_sites -quiet -of_objects $r -filter {SITE_TYPE =~ RAMB36*}]] slice=[llength [get_sites -quiet -of_objects $r -filter {SITE_TYPE =~ SLICE*}]]"
  }
}
puts "PLACE_DONE3"
