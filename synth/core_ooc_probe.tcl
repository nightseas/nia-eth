# ---------------------------------------------------------------------------
# File        : core_ooc_probe.tcl
# Description : Out of context synthesis of one boundary of this subsystem, at a chosen
#               variant and geometry, reporting the slack, the cell it binds on and the
#               resource count. It is the pattern every timing measurement in this
#               repository follows.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set part xcvp1552-vsva2785-2mhp-i-s
set variant  [lindex $argv 0]
if {$variant eq ""} { set variant A }
switch -- $variant {
  A { set seg_per 2.558 ; set tx_per 3.104 ; set rx_per 3.104 ; set nm "tx=rx=322.265625MHz" }
  X { set seg_per 2.558 ; set tx_per 3.104 ; set rx_per 4.000 ; set nm "tx=322.265625 rx=250MHz" }
  U250 { set seg_per 2.558 ; set tx_per 4.000 ; set rx_per 4.000 ; set nm "host stream 250MHz both directions" }
  U391 { set seg_per 2.558 ; set tx_per 2.558 ; set rx_per 2.558 ; set nm "host stream 390.625MHz both directions" }
  default { puts "PROBE_ERROR unknown variant $variant" ; exit 1 }
}

set n_seg  [expr {[info exists env(NIA_OOC_N_SEG)]  ? $env(NIA_OOC_N_SEG)  : 2}]
set data_w [expr {[info exists env(NIA_OOC_DATA_W)] ? $env(NIA_OOC_DATA_W) : 512}]
if {$data_w < $n_seg * 128} {
  puts "PROBE_ERROR DATA_W=$data_w is narrower than N_SEG=$n_seg segments of 128 bits"
  exit 1
}

set here  [file normalize [file dirname [info script]]]
set rtl   [file normalize [file join $here .. rtl]]
set model [file normalize [file join $here .. sim model]]
create_project -in_memory -part $part

read_verilog -sv [list \
  $rtl/dcmac_seg_axis_adapter.sv \
  $rtl/eth_axis_dwidth.sv \
  $model/eth_axis_async_fifo.sv \
  $rtl/dcmac_axis_frame_fifo.sv \
  $model/tx_frame_fifo.sv \
  $rtl/ctl/dcmac_mac_ctl_fsm.sv \
  $rtl/dcmac_axis_rx_stream.sv \
  $rtl/dcmac_axis_adapter.sv ]

# The image builds PTP_TS_EN 0 and TX_TAG_W 0, so the transmit completion crossing does not
# exist there. Leaving them on in the probe measures a model FIFO the image never
# instantiates, which is how the probe came to bind on g_tx_cpl.u_tx_cpl_cdc.
set ptp [expr {[info exists env(NIA_OOC_PTP)] ? $env(NIA_OOC_PTP) : 1}]
set tag [expr {$ptp != 0 ? 16 : 0}]
puts "PROBE_CPL ptp=$ptp tx_tag=$tag"
synth_design -top dcmac_axis_adapter -part $part -mode out_of_context \
             -generic PTP_TS_EN=$ptp -generic PTP_TS_W=80 -generic TX_TAG_W=$tag \
             -generic N_SEG=$n_seg -generic DATA_W=$data_w \
             -verilog_define DCMAC_FRAME_FIFO_BRAM

puts "PROBE_VARIANT=$variant  seg=$seg_per tx=$tx_per rx=$rx_per ($nm)"
puts "PROBE_GEOMETRY N_SEG=$n_seg DATA_W=$data_w client_beat_bytes=[expr {$n_seg * 16}]"
puts "PROBE_ERRORS=[get_msg_config -severity {ERROR} -count]"
puts "PROBE_CRITICAL_WARNINGS=[get_msg_config -severity {CRITICAL WARNING} -count]"

create_clock -name seg_clk -period $seg_per [get_ports seg_clk]
create_clock -name tx_clk  -period $tx_per  [get_ports tx_clk]
create_clock -name rx_clk  -period $rx_per  [get_ports rx_clk]
set_clock_groups -asynchronous -group [get_clocks seg_clk] \
                               -group [get_clocks tx_clk] -group [get_clocks rx_clk]

puts "PROBE_SEQ_CELLS=[llength [get_cells -quiet -hier -filter {IS_SEQUENTIAL}]]"
check_timing -override_defaults no_clock -verbose

foreach c {seg_clk tx_clk rx_clk} {
  set p [get_timing_paths -quiet -setup -max_paths 1 -to [get_clocks $c]]
  if {[llength $p]} {
    puts "PROBE_${c}_WORST slack=[get_property SLACK $p] levels=[get_property LOGIC_LEVELS $p] endpoint=[get_property ENDPOINT_PIN $p]"
  } else {
    puts "PROBE_${c}_WORST none"
  }
}

set all_bram [get_cells -quiet -hier -filter {REF_NAME =~ RAMB*}]
set all_uram [get_cells -quiet -hier -filter {REF_NAME =~ URAM*}]
puts "PROBE_BRAM_TOTAL=[llength $all_bram]  PROBE_URAM_TOTAL=[llength $all_uram]"
foreach {tag inst} {RX u_rx_frame_fifo TX u_tx_frame_fifo} {
  set n 0
  foreach c $all_bram { if {[string match "*${inst}*" $c]} { incr n } }
  puts "PROBE_BRAM_${tag}=$n"
}
foreach c $all_bram { puts "PROBE_BRAM_CELL $c REF=[get_property REF_NAME $c]" }

foreach {tag pat} {RX_wr_cur *u_rx_frame_fifo*wr_cur_reg*
                   RX_errsn  *u_rx_frame_fifo*err_seen_reg*
                   TX_wr_cur *u_tx_frame_fifo*wr_cur_reg*
                   TX_errsn  *u_tx_frame_fifo*err_seen_reg*
                   CPL       *u_tx_cpl_cdc*
                   RXTS      *rx_ts_hold_reg*} {
  set cells [get_cells -quiet -hier -filter "NAME =~ $pat"]
  if {[llength $cells]} {
    set p [get_timing_paths -quiet -setup -max_paths 1 \
            -to [get_pins -quiet -of_objects $cells -filter {REF_PIN_NAME==D}]]
    if {[llength $p]} {
      puts "PROBE_CONE_${tag} cells=[llength $cells] slack=[get_property SLACK $p] levels=[get_property LOGIC_LEVELS $p] endpoint=[get_property ENDPOINT_PIN $p]"
    } else { puts "PROBE_CONE_${tag} cells=[llength $cells] nopath" }
  } else { puts "PROBE_CONE_${tag} nocells" }
}

puts "PROBE_SEG_TOP5_BEGIN"
foreach p [get_timing_paths -quiet -setup -max_paths 5 -to [get_clocks seg_clk]] {
  puts "PROBE_SEG_PATH slack=[get_property SLACK $p] levels=[get_property LOGIC_LEVELS $p] endpoint=[get_property ENDPOINT_PIN $p]"
}
puts "PROBE_SEG_TOP5_END"
set nonmodel {}
foreach p [get_timing_paths -quiet -setup -max_paths 40 -to [get_clocks seg_clk]] {
  set ep [get_property ENDPOINT_PIN $p]
  if {![string match "*u_tx_cdc*" $ep] && ![string match "*u_rx_cdc*" $ep] \
      && ![string match "*u_tx_cpl_cdc*" $ep]} { lappend nonmodel $p }
}
if {[llength $nonmodel]} {
  set p [lindex $nonmodel 0]
  puts "PROBE_SEG_WORST_EXCL_CDCMODEL slack=[get_property SLACK $p] levels=[get_property LOGIC_LEVELS $p] endpoint=[get_property ENDPOINT_PIN $p]"
} else {
  puts "PROBE_SEG_WORST_EXCL_CDCMODEL none_in_top40"
}

report_utilization
puts "PROBE_DONE variant=$variant"
