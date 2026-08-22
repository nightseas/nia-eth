# ---------------------------------------------------------------------------
# File        : axispg_dual_ooc_probe.tcl
# Description : Out of context synthesis of the two client AXI-Stream instrument with its
#               adapters, at a chosen stream width.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set part xcvp1552-vsva2785-2mhp-i-s
set data_w   [expr {[info exists env(NIA_OOC_DATA_W)] ? $env(NIA_OOC_DATA_W) : 512}]
set clk_per  [expr {[info exists env(NIA_OOC_CLK_PER)] ? $env(NIA_OOC_CLK_PER) : 2.558}]

set here [file normalize [file dirname [info script]]]
set root [file normalize [file join $here ..]]
set rtl  [file join $root rtl]

set sections {COMMON PKTGEN_AXIS TOP_SEAM_DUAL PHY_STUB FIFO_MODEL OPTIONAL}
set files {}
set current ""
set fh [open [file join $rtl dcmac_seam_files.f] r]
foreach line [split [read $fh] "\n"] {
  set line [string trim $line]
  if {$line eq "" || [string index $line 0] eq "#"} { continue }
  if {[regexp {^\[(\w+)\]$} $line -> name]} { set current $name; continue }
  if {[lsearch -exact $sections $current] >= 0} {
    lappend files [file normalize [file join $rtl $line]]
  }
}
close $fh
lappend files [file join $root example TU03 fpga rtl fpga_axispg_dual_top.sv]

create_project -in_memory -part $part
read_verilog -sv $files
synth_design -top fpga_axispg_dual_top -part $part -mode out_of_context \
             -generic DATA_W=$data_w

puts "PROBE_DATA_W=$data_w clk_per=$clk_per"
puts "PROBE_ERRORS=[get_msg_config -severity {ERROR} -count]"
puts "PROBE_CRITICAL_WARNINGS=[get_msg_config -severity {CRITICAL WARNING} -count]"

create_clock -name ref_clk -period $clk_per [get_ports gt_ref_clk0_p]

puts "PROBE_SEQ_CELLS=[llength [get_cells -quiet -hier -filter {IS_SEQUENTIAL}]]"
puts "PROBE_LUTS=[llength [get_cells -quiet -hier -filter {REF_NAME =~ LUT*}]]"
puts "PROBE_BRAM=[llength [get_cells -quiet -hier -filter {REF_NAME =~ RAMB*}]]"
puts "PROBE_URAM=[llength [get_cells -quiet -hier -filter {REF_NAME =~ URAM*}]]"
check_timing -override_defaults no_clock -verbose

set worst [get_timing_paths -quiet -setup -max_paths 1]
if {[llength $worst]} {
  puts "PROBE_WORST slack=[get_property SLACK $worst] levels=[get_property LOGIC_LEVELS $worst] endpoint=[get_property ENDPOINT_PIN $worst]"
} else {
  puts "PROBE_WORST none"
}

puts "PROBE_TOP20_BEGIN"
foreach p [get_timing_paths -quiet -setup -max_paths 20] {
  puts "PROBE_PATH slack=[get_property SLACK $p] levels=[get_property LOGIC_LEVELS $p] startpoint=[get_property STARTPOINT_PIN $p] endpoint=[get_property ENDPOINT_PIN $p]"
}
puts "PROBE_TOP20_END"

report_utilization
puts "PROBE_DONE data_w=$data_w"
