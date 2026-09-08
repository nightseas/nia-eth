# ---------------------------------------------------------------------------
# File        : tu03_pktgen_post_synth.tcl
# Description : Post synthesis placement and the rate independent constraints of the
#               segmented images: the transceiver quad and reference clock buffer sites,
#               the asynchronous clock groups, the reset synchroniser false paths, and the
#               snapshot crossing waiver. A placement that is not the one this file states
#               is refused.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set nia_rate [expr {[info exists env(NIA_RATE)] ? $env(NIA_RATE) : 100}]
puts "NIA_XDC RATE $nia_rate"

if {![info exists nia_quad_map] && ![info exists nia_refclk_map]} {
  if {[lsearch -exact {100 200} $nia_rate] < 0} {
    error "NIA_XDC FAIL: NIA_RATE=$nia_rate does not share the dual 100G/200G transceiver placement,\
           and this file names no site for it. A single 400GAUI-4 client needs two quads in\
           CONSECUTIVE column sites on ONE cage - GTM_QUAD_X0Y0 and GTM_QUAD_X0Y1, or DRC MGTIO-16\
           unroutes the design - so it is placed by constraints/tu03_pktgen_400g_post_synth.tcl.\
           Leaving the placement to the tool is not an option: it is a board fact."
  }
  set nia_quad_map [list \
    {*i_gtwiz0/*gt_quad_base_0_inst/inst/quad_inst} GTM_QUAD_X0Y0 \
    {*i_gtwiz1/*gt_quad_base_0_inst/inst/quad_inst} GTM_QUAD_X0Y2]

  set nia_refclk_map [list \
    {*dcmac_IBUFDS_GTE5_REFCLK0_gt0} GTM_REFCLK_X0Y0 \
    {*dcmac_IBUFDS_GTE5_REFCLK1_gt1} GTM_REFCLK_X0Y4]
  puts "NIA_XDC PLACEMENT dual 100G/200G (identical per specification Section 4)"
} else {
  if {![info exists nia_quad_map] || ![info exists nia_refclk_map]} {
    error "NIA_XDC FAIL: a caller set one of nia_quad_map / nia_refclk_map and not the other, so\
           either the quads or their reference clocks would fall back to a map that does not match\
           them. Set both or neither."
  }
  puts "NIA_XDC PLACEMENT supplied by the caller: [llength [dict keys $nia_quad_map]] quad site(s)"
}

proc nia_place_by_name {map kind} {
  set placed 0
  foreach {pattern site} $map {
    set cells [get_cells -quiet -hier -filter "NAME =~ $pattern"]
    if {[llength $cells] == 0} { continue }
    if {[llength $cells] != 1} {
      error "NIA_XDC FAIL: $kind pattern $pattern matched [llength $cells] cells, so the site would be ambiguous"
    }
    set_property LOC $site [get_cells $cells]
    puts "NIA_XDC $kind [get_property NAME [get_cells $cells]] $site"
    incr placed
  }
  return $placed
}

set nia_quads_placed [nia_place_by_name $nia_quad_map quad]
if {$nia_quads_placed == 0} {
  error "NIA_XDC FAIL: no transceiver quad matched a cage, placement would be left to the tool"
}
set nia_refclks_placed [nia_place_by_name $nia_refclk_map refclk]
# One buffer a quad is the usual arrangement. A caller whose quads share a buffer within a cage
# states the ratio it expects, so a missing buffer is still caught.
if {![info exists nia_refclk_per_quad]} { set nia_refclk_per_quad 1 }
set nia_refclks_want [expr {int($nia_quads_placed * $nia_refclk_per_quad)}]
if {$nia_refclks_placed != $nia_refclks_want} {
  error "NIA_XDC FAIL: $nia_quads_placed quad(s) placed and $nia_refclks_placed reference clock\
         buffer(s), where $nia_refclks_want are expected at $nia_refclk_per_quad buffer(s) a quad, so\
         one cage has no clock"
}
puts "NIA_XDC cages $nia_quads_placed quad(s) and $nia_refclks_placed reference clock buffer(s)"

set nia_clock_trees [list]

foreach nia_clkgen [lsort [get_cells -quiet -hier \
  -filter {REF_NAME =~ MMCME5* || ORIG_REF_NAME =~ MMCME5*}]] {
  set nia_clkgen_clocks [get_clocks -quiet -of_objects \
    [get_pins -quiet -of_objects [get_cells $nia_clkgen] -filter {REF_PIN_NAME =~ CLKOUT*}]]
  if {[llength $nia_clkgen_clocks] > 0} {
    # The outputs of one clock generator are normally related and are grouped together. The
    # user clock wizard is the exception: since the DCMAC APB3_CLK requires 3.333 ns, its
    # clk_out1 carries the register plane at 250 MHz while clk_out3 carries the datapath at
    # 250 or 390.625, and the two are crossed only through dcmac_sync2 and the dcmac_csr_snap
    # handshake. Grouping them together times those crossings against the tighter period,
    # which is how a 199 bit handshake bus came to fail by -1.914 ns in m400u391. Each output
    # of this generator is therefore its own group.
    if {[string match "*usr_clk_wiz*" $nia_clkgen]} {
      foreach nia_one $nia_clkgen_clocks {
        lappend nia_clock_trees [list $nia_one]
        puts "NIA_XDC clock tree $nia_clkgen output [get_property NAME $nia_one] is its own\
 group, because the register plane and the datapath are asynchronous by design"
      }
    } else {
      lappend nia_clock_trees $nia_clkgen_clocks
      puts "NIA_XDC clock tree $nia_clkgen : $nia_clkgen_clocks"
    }
  }
}

set nia_ps [get_cells -quiet -hier -filter {REF_NAME == PS9 || ORIG_REF_NAME == PS9}]
if {[llength $nia_ps] > 0} {
  set nia_ps_clocks [get_clocks -quiet -of_objects \
    [get_pins -quiet -of_objects $nia_ps -filter {DIRECTION == OUT}]]
  if {[llength $nia_ps_clocks] == 0} {
    error "NIA_XDC FAIL: the processing system is in the design and drives no clock, so the host bridge clock group would name nothing"
  }
  lappend nia_clock_trees $nia_ps_clocks
  puts "NIA_XDC processing system clocks $nia_ps_clocks"
}

if {[llength $nia_clock_trees] > 1} {
  set nia_group_args [list]
  foreach nia_tree $nia_clock_trees { lappend nia_group_args -group $nia_tree }
  set_clock_groups -asynchronous -name nia_unrelated_clock_trees {*}$nia_group_args
  puts "NIA_XDC asynchronous clock trees [llength $nia_clock_trees]"
}

set nia_rst_syncs [get_cells -quiet -hier -filter {ORIG_REF_NAME == rst_sync || REF_NAME == rst_sync}]
set nia_rst_async_pins [list]
foreach nia_rst_sync $nia_rst_syncs {
  foreach nia_pin [get_pins -quiet -of_objects \
    [get_cells -quiet -hier -filter "PARENT == $nia_rst_sync"] \
    -filter {REF_PIN_NAME == CLR || REF_PIN_NAME == PRE}] {
    lappend nia_rst_async_pins $nia_pin
  }
}
if {[llength $nia_rst_async_pins] == 0} {
  set nia_rst_async_pins [get_pins -quiet -hier -filter {NAME =~ *release_chain_r_reg*/CLR}]
  foreach nia_pin [get_pins -quiet -hier -filter {NAME =~ *release_chain_r_reg*/PRE}] {
    lappend nia_rst_async_pins $nia_pin
  }
}
if {[llength $nia_rst_async_pins] == 0} {
  error "NIA_XDC FAIL: no reset synchroniser asynchronous pin matched"
}
set_false_path -to $nia_rst_async_pins
puts "NIA_XDC rst_sync instances [llength $nia_rst_syncs] asynchronous pins [llength $nia_rst_async_pins]"

set nia_sync2_cells [get_cells -quiet -hier \
  -filter {ORIG_REF_NAME == dcmac_sync2 || REF_NAME == dcmac_sync2}]
if {[llength $nia_sync2_cells] == 0} {
  error "NIA_XDC FAIL: no dcmac_sync2 instance matched, so every crossing into a synchroniser would be timed against the clock relationship the synchroniser exists to break"
}
set nia_sync2_flops [list]
foreach nia_sync2 $nia_sync2_cells {
  foreach nia_cell [get_cells -quiet -hier -filter "PARENT == $nia_sync2"] {
    lappend nia_sync2_flops $nia_cell
  }
}
set nia_sync2_entry [dict create]
foreach nia_pin [get_pins -quiet -of_objects $nia_sync2_flops -filter {REF_PIN_NAME == D}] {
  if {![regexp {sr_reg\[0\]} [get_property NAME $nia_pin]]} { continue }
  set nia_dst_clk [get_clocks -quiet -of_objects \
    [get_pins -quiet -of_objects [get_cells -quiet -of_objects $nia_pin] \
       -filter {REF_PIN_NAME == C}]]
  if {[llength $nia_dst_clk] != 1} { continue }
  dict lappend nia_sync2_entry [get_property NAME [lindex $nia_dst_clk 0]] $nia_pin
}
if {[dict size $nia_sync2_entry] == 0} {
  error "NIA_XDC FAIL: no dcmac_sync2 first stage input matched, so the crossing bound would name nothing"
}
# The dcmac_csr_snap handshake carries a wide vector across the same boundary: hold is
# clocked by s_clk and dout_r by m_clk, and the two phase handshake holds the data stable for
# the whole crossing, so the path is asynchronous by construction and is bounded rather than
# timed. Without this the bus is timed as a synchronous path and fails by most of a cycle.
set nia_snap_cells [get_cells -quiet -hier \
  -filter {ORIG_REF_NAME == dcmac_csr_snap || REF_NAME == dcmac_csr_snap}]
set nia_snap_entry [dict create]
foreach nia_snap $nia_snap_cells {
  foreach nia_pin [get_pins -quiet -of_objects \
    [get_cells -quiet -hier -filter "PARENT =~ $nia_snap*"] -filter {REF_PIN_NAME == D}] {
    set nia_nm [get_property NAME $nia_pin]
    if {![regexp {(dout_r_reg|hold_reg)} $nia_nm]} { continue }
    set nia_dc [get_clocks -quiet -of_objects \
      [get_pins -quiet -of_objects [get_cells -quiet -of_objects $nia_pin] \
         -filter {REF_PIN_NAME == C}]]
    if {[llength $nia_dc] != 1} { continue }
    dict lappend nia_snap_entry [get_property NAME [lindex $nia_dc 0]] $nia_pin
  }
}
dict for {nia_dst nia_pins} $nia_snap_entry {
  set nia_from [list]
  foreach nia_clk [get_clocks -quiet] {
    set nia_name [get_property NAME $nia_clk]
    if {$nia_name ne $nia_dst} { lappend nia_from $nia_name }
  }
  if {[llength $nia_from] == 0} { continue }
  set nia_period [get_property PERIOD [get_clocks $nia_dst]]
  set_max_delay -datapath_only $nia_period -from [get_clocks $nia_from] -to $nia_pins
  puts "NIA_XDC handshake vector entries [llength $nia_pins] into $nia_dst bounded at\
 $nia_period ns"
}

dict for {nia_dst nia_pins} $nia_sync2_entry {
  set nia_from [list]
  foreach nia_clk [get_clocks -quiet] {
    set nia_name [get_property NAME $nia_clk]
    if {$nia_name ne $nia_dst} { lappend nia_from $nia_name }
  }
  if {[llength $nia_from] == 0} {
    error "NIA_XDC FAIL: $nia_dst is the only clock in the design, so no crossing into its synchronisers can be named"
  }
  set nia_period [get_property PERIOD [get_clocks $nia_dst]]
  set_max_delay -datapath_only $nia_period -from [get_clocks $nia_from] -to $nia_pins
  puts "NIA_XDC synchroniser entries [llength $nia_pins] into $nia_dst bounded at $nia_period ns from [llength $nia_from] other clock(s)"
}

set nia_snaps [get_cells -quiet -hier -filter {ORIG_REF_NAME =~ dcmac_csr_snap* || REF_NAME =~ dcmac_csr_snap*}]
if {[llength $nia_snaps] == 0} {
  error "NIA_XDC FAIL: no dcmac_csr_snap instance matched, the crossing waiver would name nothing"
}
set nia_snap_from [list]
set nia_snap_to   [list]
set nia_snap_handshake 0
set nia_snap_same_clock 0
foreach nia_snap $nia_snaps {
  set nia_snap_hold [get_cells -quiet -hier -filter "NAME =~ $nia_snap/*hold_reg*"]
  set nia_snap_dout [get_cells -quiet -hier -filter "NAME =~ $nia_snap/*dout_r_reg*"]
  if {[llength $nia_snap_hold] == 0} {
    incr nia_snap_same_clock
    if {[llength $nia_snap_dout] == 0} {
      error "NIA_XDC FAIL: $nia_snap has neither a hold stage nor a capture stage, so it moves no vector at all"
    }
    continue
  }
  incr nia_snap_handshake
  foreach nia_pin [get_pins -quiet -of_objects $nia_snap_hold -filter {REF_PIN_NAME == C}] {
    lappend nia_snap_from $nia_pin
  }
  foreach nia_pin [get_pins -quiet -of_objects $nia_snap_dout -filter {REF_PIN_NAME == D}] {
    lappend nia_snap_to $nia_pin
  }
}
if {$nia_snap_handshake > 0 && ([llength $nia_snap_from] == 0 || [llength $nia_snap_to] == 0)} {
  error "NIA_XDC FAIL: the snapshot capture registers did not match, from [llength $nia_snap_from] to [llength $nia_snap_to]"
}
if {$nia_snap_handshake > 0} {
  create_waiver -quiet -type CDC -id {CDC-15} -user "nia" \
    -desc "dcmac_csr_snap moves the vector on a two-phase handshake: hold is written in the source domain only when the synchronised request differs from the acknowledgement, and dout is written in the destination domain only when the synchronised acknowledgement matches the request, so every bit is stable across the capture edge" \
    -from $nia_snap_from -to $nia_snap_to
}
puts "NIA_XDC snapshot instances [llength $nia_snaps] handshake $nia_snap_handshake same_clock $nia_snap_same_clock crossing waiver from [llength $nia_snap_from] to [llength $nia_snap_to]"
