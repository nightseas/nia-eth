# ---------------------------------------------------------------------------
# File        : rank_image.tcl
# Description : Reads a routed checkpoint and reports what owns the timing failure and the
#               area: the failing setup endpoints grouped by structure, the worst paths
#               with the route fraction of each, the hierarchical LUT and register count,
#               and the highest fanout nets of the failing clock. It takes a checkpoint
#               path so it serves any build.
#
#               It also classifies every failing endpoint by its clock and by the plane it
#               belongs to. The register plane is the host bridge, the AXI-Lite fabric, the
#               control plane and the DCMAC register bus, which the clock split moves to
#               250 MHz. The datapath plane is the adapter, the generators and the checkers,
#               which stay at the datapath clock. The split repairs a failing endpoint only
#               if it is in the register plane, so the RANK_PLANE and RANK_SPLIT lines say
#               whether the split alone can close a build without rebuilding it.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set dcp [lindex $argv 0]
if {$dcp eq "" || ![file exists $dcp]} { puts "RANK_ERROR checkpoint '$dcp' is absent" ; exit 1 }
open_checkpoint $dcp
puts "RANK_DCP $dcp"

# The clock the split moves. Every endpoint captured by it is repaired by the split.
set reg_clk [expr {[info exists ::env(NIA_RANK_REG_CLK)] ? $::env(NIA_RANK_REG_CLK)
                   : "clkout1_primitive_1"}]
puts "RANK_REG_CLK $reg_clk"
puts "RANK_CLOCKS_IN_DESIGN_BEGIN"
foreach c [get_clocks -quiet *] {
  puts [format "RANK_CLOCK_DEF %-24s period=%s" [get_property NAME $c] \
    [get_property PERIOD $c]]
}
puts "RANK_CLOCKS_IN_DESIGN_END"

set failing [get_timing_paths -setup -max_paths 20000 -nworst 1 -slack_lesser_than 0]
puts "RANK_FAILING [llength $failing]"

array set bym {}
array set worst {}
array set byd {}
array set byc {}
array set cworst {}
array set byp {}
array set pworst {}
array set planecells {}
foreach p $failing {
  set ep [get_property ENDPOINT_PIN $p]
  set sp [get_property STARTPOINT_PIN $p]
  set sl [get_property SLACK $p]
  set cells [get_cells -quiet -of_objects [get_pins -quiet $ep]]
  set cell ""
  if {[llength $cells]} { set cell [get_property NAME [lindex $cells 0]] }
  set key "other"
  foreach pat {u_seg_rx u_seg_tx u_rx_frame_fifo u_tx_frame_fifo u_rx_cdc u_tx_cdc u_rx_up u_tx_dn
               u_tx_cpl_cdc u_ctl u_pktgen u_src u_chk u_adapter} {
    if {[string match "*/$pat/*" $cell] || [string match "*/$pat" $cell]} { set key $pat ; break }
  }
  if {![info exists bym($key)]} { set bym($key) 0 ; set worst($key) 99 }
  incr bym($key)
  if {$sl < $worst($key)} { set worst($key) $sl }

  # the endpoint pin kind separates a data path failure from a control path failure
  set kind [lindex [split $ep /] end]
  if {![info exists byd($kind)]} { set byd($kind) 0 }
  incr byd($kind)

  # The clock of the endpoint, which is what the split moves. A timing path carries its own
  # endpoint clock, and asking the pin for its clock returns nothing, which is why an earlier
  # form of this reported 'none' for every endpoint of a400rx.
  set eclk [get_property -quiet ENDPOINT_CLOCK $p]
  if {$eclk eq ""} { set eclk "none" }
  set sclk [get_property -quiet STARTPOINT_CLOCK $p]
  if {$sclk eq ""} { set sclk "none" }
  set ckey "$sclk -> $eclk"
  if {![info exists byc($ckey)]} { set byc($ckey) 0 ; set cworst($ckey) 99 }
  incr byc($ckey)
  if {$sl < $cworst($ckey)} { set cworst($ckey) $sl }

  # The plane. The split moves one clock and leaves the others, so the plane of a failing
  # endpoint is decided by the clock that captures it and not by the cell it sits in: a
  # register in the generator is repaired if the AXI-Lite clock captures it and is not if the
  # datapath clock does. NIA_RANK_REG_CLK names the clock the split moves, and it defaults to
  # the usr_clk plane of the pre split images, clkout1_primitive_1.
  set plane "datapath"
  if {[string match "*$reg_clk*" $eclk]} { set plane "register" }
  if {$eclk eq "none"} { set plane "unclocked" }
  if {![info exists byp($plane)]} { set byp($plane) 0 ; set pworst($plane) 99 }
  incr byp($plane)
  if {$sl < $pworst($plane)} { set pworst($plane) $sl }
  lappend planecells($plane) [list $cell $sl]
}
set pairs {}
foreach k [array names bym] { lappend pairs [list $k $bym($k) $worst($k)] }
foreach e [lsort -integer -decreasing -index 1 $pairs] {
  puts [format "RANK_GROUP %-18s endpoints=%6d worst=%7.3f" [lindex $e 0] [lindex $e 1] [lindex $e 2]]
}
set pairs {}
foreach k [array names byd] { lappend pairs [list $k $byd($k)] }
foreach e [lsort -integer -decreasing -index 1 $pairs] {
  puts [format "RANK_PINKIND %-8s endpoints=%6d" [lindex $e 0] [lindex $e 1]]
}

# the clock each failing endpoint belongs to
set pairs {}
foreach k [array names byc] { lappend pairs [list $k $byc($k) $cworst($k)] }
foreach e [lsort -integer -decreasing -index 1 $pairs] {
  puts [format "RANK_CLOCK %-52s endpoints=%6d worst=%7.3f" [lindex $e 0] [lindex $e 1] [lindex $e 2]]
}

# the plane, and therefore what the clock split can and cannot repair
set pairs {}
foreach k [array names byp] { lappend pairs [list $k $byp($k) $pworst($k)] }
foreach e [lsort -integer -decreasing -index 1 $pairs] {
  puts [format "RANK_PLANE %-10s endpoints=%6d worst=%7.3f" [lindex $e 0] [lindex $e 1] [lindex $e 2]]
}
set n_reg 0 ; set n_dp 0 ; set w_dp 99
if {[info exists byp(register)]} { set n_reg $byp(register) }
if {[info exists byp(datapath)]} { set n_dp $byp(datapath) ; set w_dp $pworst(datapath) }
if {$n_dp == 0} {
  puts "RANK_SPLIT every failing endpoint is in the register plane, so the clock split alone\
 closes this build"
} else {
  puts [format "RANK_SPLIT the clock split repairs %d of %d failing endpoints and leaves %d in\
 the datapath plane at worst %.3f, so the split alone does not close this build" \
    $n_reg [expr {$n_reg+$n_dp}] $n_dp $w_dp]
}
# the datapath residue named, since it is the work the split leaves behind
if {$n_dp > 0} {
  array set dpg {}
  foreach e $planecells(datapath) {
    set c [lindex $e 0] ; set s [lindex $e 1]
    set g "other"
    foreach pat {u_seg_rx u_seg_tx u_rx_frame_fifo u_tx_frame_fifo u_rx_cdc u_tx_cdc u_rx_up
                 u_tx_dn u_pktgen u_src u_chk u_adapter} {
      if {[string match "*/$pat/*" $c] || [string match "*/$pat" $c]} { set g $pat ; break }
    }
    if {![info exists dpg($g)]} { set dpg($g) [list 0 99] }
    set cur [lindex $dpg($g) 0] ; set cw [lindex $dpg($g) 1]
    if {$s < $cw} { set cw $s }
    set dpg($g) [list [expr {$cur+1}] $cw]
  }
  set pairs {}
  foreach k [array names dpg] { lappend pairs [list $k [lindex $dpg($k) 0] [lindex $dpg($k) 1]] }
  foreach e [lsort -integer -decreasing -index 1 $pairs] {
    puts [format "RANK_RESIDUE %-18s endpoints=%6d worst=%7.3f" \
      [lindex $e 0] [lindex $e 1] [lindex $e 2]]
  }
}

puts "RANK_WORST_PATHS_BEGIN"
foreach p [get_timing_paths -setup -max_paths 25 -nworst 25 -slack_lesser_than 0] {
  set ld [get_property DATAPATH_LOGIC_DELAY $p]
  set nd [get_property DATAPATH_NET_DELAY $p]
  set t [expr {$ld+$nd}]
  puts [format "RANK_PATH slack=%7.3f levels=%2s logic=%6.3f route=%6.3f route_pct=%5.1f from=%s to=%s" \
    [get_property SLACK $p] [get_property LOGIC_LEVELS $p] $ld $nd \
    [expr {$t>0 ? 100.0*$nd/$t : 0}] [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
}
puts "RANK_WORST_PATHS_END"

puts "RANK_FANOUT_BEGIN"
set nets [list]
foreach n [get_nets -quiet -hier -filter {TYPE == SIGNAL}] {
  set f [get_property FLAT_PIN_COUNT $n]
  if {$f ne "" && $f > 400} { lappend nets [list [get_property NAME $n] $f] }
}
foreach e [lrange [lsort -integer -decreasing -index 1 $nets] 0 39] {
  puts [format "RANK_FANOUT pins=%6d net=%s" [lindex $e 1] [lindex $e 0]]
}
puts "RANK_FANOUT_END"

# IMPORTANT: report_utilization -file /dev/stdout opens the job log for writing and
# truncates it, which loses everything printed above. It goes to a file of its own and the
# caller reads that file.
set hier [file join [pwd] rank_hierarchy.rpt]
report_utilization -hierarchical -hierarchical_depth 6 -file $hier
puts "RANK_HIERARCHY $hier"
puts "RANK_DONE"
