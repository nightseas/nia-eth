# ---------------------------------------------------------------------------
# File        : pktgen_axis_ooc_probe.tcl
# Description : Out of context synthesis of the AXI-Stream instrument alone, without the
#               adapter around it.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set part xcvp1552-vsva2785-2mhp-i-s
set data_w   [expr {[info exists env(NIA_OOC_DATA_W)] ? $env(NIA_OOC_DATA_W) : 512}]
set net_per  [expr {[info exists env(NIA_OOC_NET_PER)] ? $env(NIA_OOC_NET_PER) : 4.000}]
set axil_per [expr {[info exists env(NIA_OOC_AXIL_PER)] ? $env(NIA_OOC_AXIL_PER) : 4.000}]
set same_clock [expr {[info exists env(NIA_OOC_SAME_CLOCK)] ? $env(NIA_OOC_SAME_CLOCK) : 1}]
set len_min_hw [expr {[info exists env(NIA_LEN_MIN_HW)] ? $env(NIA_LEN_MIN_HW) : 64}]
set len_max_hw [expr {[info exists env(NIA_LEN_MAX_HW)] ? $env(NIA_LEN_MAX_HW) : 9018}]

set here [file normalize [file dirname [info script]]]
set rtl  [file normalize [file join $here .. rtl]]
create_project -in_memory -part $part

read_verilog -sv [list \
  $rtl/dcmac_sync2.sv \
  $rtl/dcmac_csr_snap.sv \
  $rtl/pktgen_axis/dcmac_axis_frame_src.sv \
  $rtl/pktgen_axis/dcmac_axis_frame_chk.sv \
  $rtl/pktgen_axis/dcmac_axis_pktgen.sv ]

synth_design -top dcmac_axis_pktgen -part $part -mode out_of_context \
             -generic DATA_W=$data_w -generic SAME_CLOCK=$same_clock \
             -generic LEN_MIN_HW=$len_min_hw -generic LEN_MAX_HW=$len_max_hw

puts "PROBE_DATA_W=$data_w net_per=$net_per axil_per=$axil_per"
puts "PROBE_ERRORS=[get_msg_config -severity {ERROR} -count]"
puts "PROBE_CRITICAL_WARNINGS=[get_msg_config -severity {CRITICAL WARNING} -count]"

if {$same_clock} {
  create_clock -name net_clk -period $net_per [get_ports {net_clk axil_aclk}]
  set probe_clocks {net_clk}
} else {
  create_clock -name net_clk   -period $net_per  [get_ports net_clk]
  create_clock -name axil_aclk -period $axil_per [get_ports axil_aclk]
  set_clock_groups -asynchronous -group [get_clocks net_clk] -group [get_clocks axil_aclk]
  set probe_clocks {net_clk axil_aclk}
}

puts "PROBE_SEQ_CELLS=[llength [get_cells -quiet -hier -filter {IS_SEQUENTIAL}]]"
puts "PROBE_LUTS=[llength [get_cells -quiet -hier -filter {REF_NAME =~ LUT*}]]"
check_timing -override_defaults no_clock -verbose

foreach c $probe_clocks {
  set p [get_timing_paths -quiet -setup -max_paths 1 -to [get_clocks $c]]
  if {[llength $p]} {
    puts "PROBE_${c}_WORST slack=[get_property SLACK $p] levels=[get_property LOGIC_LEVELS $p] endpoint=[get_property ENDPOINT_PIN $p]"
  } else {
    puts "PROBE_${c}_WORST none"
  }
}

puts "PROBE_NET_TOP5_BEGIN"
foreach p [get_timing_paths -quiet -setup -max_paths 5 -to [get_clocks net_clk]] {
  puts "PROBE_NET_PATH slack=[get_property SLACK $p] levels=[get_property LOGIC_LEVELS $p] endpoint=[get_property ENDPOINT_PIN $p]"
}
puts "PROBE_NET_TOP5_END"

report_utilization
puts "PROBE_DONE data_w=$data_w"
