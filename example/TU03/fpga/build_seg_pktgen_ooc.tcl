# ---------------------------------------------------------------------------
# File        : build_seg_pktgen_ooc.tcl
# Description : Out of context synthesis of the segmented traffic instrument alone, at a
#               chosen segment geometry, so a timing figure is available without building
#               an image.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set nia_root   [file normalize [file join [file dirname [info script]] .. .. ..]]
set part       [expr {[info exists env(NIA_PART)] ? $env(NIA_PART) : "xcvp1552-vsva2785-2MHP-i-S"}]
set out_dir    [expr {[info exists env(NIA_OUT)] ? $env(NIA_OUT) : [file join $nia_root build seg_pktgen]}]
set n_seg      [expr {[info exists env(NIA_N_SEG)] ? $env(NIA_N_SEG) : 2}]
set seg_w      [expr {[info exists env(NIA_SEG_W)] ? $env(NIA_SEG_W) : 128}]
set len_min_hw [expr {[info exists env(NIA_LEN_MIN_HW)] ? $env(NIA_LEN_MIN_HW) : 60}]
set len_max_hw [expr {[info exists env(NIA_LEN_MAX_HW)] ? $env(NIA_LEN_MAX_HW) : 9018}]
set jobs       [expr {[info exists env(NIA_JOBS)] ? $env(NIA_JOBS) : 16}]

file mkdir $out_dir

set sources [list \
  [file join $nia_root rtl dcmac_sync2.sv] \
  [file join $nia_root rtl dcmac_csr_snap.sv] \
  [file join $nia_root rtl dcmac_seg_fifo.sv] \
  [file join $nia_root rtl pktgen_seg dcmac_seg_ctx.sv] \
  [file join $nia_root rtl pktgen_seg dcmac_seg_pktgen_chain.sv] \
  [file join $nia_root rtl pktgen_seg dcmac_seg_pktmon_chain.sv] \
  [file join $nia_root rtl dcmac_seg_pktgen.sv] \
]

foreach src $sources {
  if {![file exists $src]} {
    puts "SEGPKTGEN FAIL: $src is absent"
    exit 2
  }
}

set xdc [file join $nia_root example TU03 fpga constraints seg_pktgen_ooc.xdc]
if {![file exists $xdc]} {
  puts "SEGPKTGEN FAIL: $xdc is absent"
  exit 2
}

puts "SEGPKTGEN STAGE project N_SEG=$n_seg SEG_W=$seg_w"
create_project -in_memory -part $part
set_property target_language Verilog [current_project]
foreach src $sources { read_verilog -sv $src }
read_xdc $xdc

puts "SEGPKTGEN STAGE synth"
synth_design -top dcmac_seg_pktgen -part $part -mode out_of_context \
  -generic N_SEG=$n_seg -generic SEG_W=$seg_w \
  -generic LEN_MIN_HW=$len_min_hw -generic LEN_MAX_HW=$len_max_hw
report_utilization -file [file join $out_dir post_synth_utilization.rpt]
report_timing_summary -file [file join $out_dir post_synth_timing_summary.rpt]

puts "SEGPKTGEN STAGE impl"
opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force [file join $out_dir post_route.dcp]
report_timing_summary -file [file join $out_dir post_route_timing_summary.rpt]
report_utilization -file [file join $out_dir post_route_utilization.rpt]

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "SEGPKTGEN N_SEG $n_seg WNS $wns"
puts "SEGPKTGEN N_SEG $n_seg WHS $whs"

puts "SEGPKTGEN DONE"
