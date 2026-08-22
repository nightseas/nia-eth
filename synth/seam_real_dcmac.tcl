# ---------------------------------------------------------------------------
# File        : seam_real_dcmac.tcl
# Description : Elaborates the adapter against the generated DCMAC rather than the
#               simulation model, to check the boundary the model stands in for.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set part    xcvp1552-vsva2785-2mhp-i-s
set outdir  [lindex $argv 0]
set jobs    [lindex $argv 1]
if {$outdir eq ""} { set outdir "./seam_proj" }
if {$jobs   eq ""} { set jobs 8 }

set here [file normalize [file dirname [info script]]]
set rtl   [file normalize [file join $here .. rtl]]
set model [file normalize [file join $here .. sim model]]
set ipsrc [file normalize [file join $here .. ip]]

file mkdir $outdir
create_project -force n2_seam $outdir -part $part
set_property target_language Verilog [current_project]

source [file join $here dcmac_ip.tcl]
dcmac_create_ips $ipsrc

puts "NIA_STAGE=ip_created err=[get_msg_config -severity {ERROR} -count] crit=[get_msg_config -severity {CRITICAL WARNING} -count]"

generate_target {instantiation_template synthesis} [get_ips]
puts "NIA_STAGE=ip_generated err=[get_msg_config -severity {ERROR} -count] crit=[get_msg_config -severity {CRITICAL WARNING} -count]"

synth_ip [get_ips]
puts "NIA_STAGE=ip_synthed err=[get_msg_config -severity {ERROR} -count] crit=[get_msg_config -severity {CRITICAL WARNING} -count]"

add_files -norecurse [list \
  $rtl/ctl/dcmac_ctl_pkg.sv \
  $rtl/ctl/dcmac_ctl_seq.sv \
  $rtl/dcmac_seg_axis_adapter.sv \
  $rtl/eth_axis_dwidth.sv \
  $model/eth_axis_async_fifo.sv \
  $rtl/dcmac_axis_frame_fifo.sv \
  $rtl/ctl/dcmac_mac_ctl_fsm.sv \
  $rtl/rst_sync.sv \
  $rtl/dcmac_axis_adapter.sv \
  $rtl/dcmac_sync2.sv \
  $rtl/dcmac_port.sv \
  $rtl/dcmac_phy_wrapper.sv \
  $rtl/dcmac_axis_top.sv ]
set_property file_type SystemVerilog [get_files *.sv]

add_files -fileset constrs_1 -norecurse [list $here/seam_ooc.xdc]
set_property used_in_synthesis true  [get_files seam_ooc.xdc]
set_property used_in_implementation true [get_files seam_ooc.xdc]

set_property top dcmac_axis_top [current_fileset]
set_property verilog_define {DCMAC_FRAME_FIFO_BRAM} [current_fileset]

set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
             -value {-mode out_of_context} -objects [get_runs synth_1]

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
set st [get_property STATUS [get_runs synth_1]]
set pr [get_property PROGRESS [get_runs synth_1]]
puts "NIA_SYNTH_STATUS=$st  PROGRESS=$pr"
if {$pr ne "100%"} {
  puts "NIA_RESULT=SYNTH_FAILED"
  puts "NIA_DONE"
  exit 1
}

open_run synth_1 -name synth_1
puts "NIA_STAGE=opened err=[get_msg_config -severity {ERROR} -count] crit=[get_msg_config -severity {CRITICAL WARNING} -count]"

set dcmac_cells [get_cells -quiet -hier -filter {REF_NAME =~ DCMAC*}]
set gtm_cells   [get_cells -quiet -hier -filter {REF_NAME =~ GTM*}]
puts "NIA_HARDMACRO_DCMAC=[llength $dcmac_cells]"
puts "NIA_HARDMACRO_GTM=[llength $gtm_cells]"
foreach c [lrange $dcmac_cells 0 3] { puts "NIA_DCMAC_CELL $c REF=[get_property REF_NAME $c]" }
foreach c [lrange $gtm_cells 0 3]   { puts "NIA_GTM_CELL   $c REF=[get_property REF_NAME $c]" }

puts "NIA_NS9_INITCLK_PORTS=[llength [get_ports -quiet *init_clk*]]"
set fr [get_nets -quiet -hier *freerun_clk_i*]
puts "NIA_NS9_FREERUN_NETS=[llength $fr]"
if {[llength $fr]} {
  set drv [get_pins -quiet -of_objects [lindex $fr 0] -filter {DIRECTION==OUT}]
  puts "NIA_NS9_FREERUN_DRIVER=$drv"
}

report_clocks -file $outdir/report_clocks.txt
puts "NIA_NCLOCKS=[llength [get_clocks -quiet]]"
puts "NIA_CLOCKS_BEGIN"
foreach clk [get_clocks -quiet] {
  set p [get_timing_paths -quiet -setup -max_paths 1 -to [get_clocks $clk]]
  set per [get_property PERIOD [get_clocks $clk]]
  if {[llength $p]} {
    puts "NIA_CLK $clk period=$per slack=[get_property SLACK $p] levels=[get_property LOGIC_LEVELS $p] endpoint=[get_property ENDPOINT_PIN $p]"
  } else {
    puts "NIA_CLK $clk period=$per slack=NA_no_internal_path"
  }
}
puts "NIA_CLOCKS_END"

puts "NIA_CHECK_TIMING_BEGIN"
check_timing -override_defaults no_clock -verbose
puts "NIA_CHECK_TIMING_END"

report_timing_summary -delay_type max -max_paths 10 -file $outdir/timing_summary_synth.txt
set wns [get_property SLACK [get_timing_paths -quiet -setup -max_paths 1]]
if {$wns eq ""} {
  puts "NIA_SYNTH_WNS=INADMISSIBLE_no_constrained_path"
} else {
  puts "NIA_SYNTH_WNS=$wns"
}
puts "NIA_TOP10_BEGIN"
foreach p [get_timing_paths -quiet -setup -max_paths 10] {
  puts "NIA_PATH slack=[get_property SLACK $p] levels=[get_property LOGIC_LEVELS $p] endclk=[get_property ENDPOINT_CLOCK $p] endpoint=[get_property ENDPOINT_PIN $p]"
}
puts "NIA_TOP10_END"

set all_bram [get_cells -quiet -hier -filter {REF_NAME =~ RAMB*}]
puts "NIA_BRAM_TOTAL=[llength $all_bram]"
foreach {tag inst} {RX u_rx_frame_fifo TX u_tx_frame_fifo} {
  set n 0
  foreach c $all_bram { if {[string match "*${inst}*" $c]} { incr n } }
  puts "NIA_BRAM_${tag}=$n"
}

report_utilization -file $outdir/utilization_synth.txt
puts "NIA_UTIL_BEGIN"
report_utilization
puts "NIA_UTIL_END"

puts "NIA_ERRORS=[get_msg_config -severity {ERROR} -count]"
puts "NIA_CRITICAL_WARNINGS=[get_msg_config -severity {CRITICAL WARNING} -count]"
puts "NIA_PDI_WRITTEN=no  (Design_Linking blocks write_device_image; we never call it)"
puts "NIA_RESULT=OK"
puts "NIA_DONE"
