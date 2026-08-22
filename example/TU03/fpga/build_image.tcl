# ---------------------------------------------------------------------------
# File        : build_image.tcl
# Description : Builds a device image. Selects the client rate, the client count and the
#               traffic instrument, generates or reuses the IP, runs synthesis and
#               implementation, and reports the stage it reached.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set nia_root    [file normalize [file join [file dirname [info script]] .. .. ..]]
set part        [expr {[info exists env(NIA_PART)] ? $env(NIA_PART) : "xcvp1552-vsva2785-2MHP-i-S"}]
set out_dir     [expr {[info exists env(NIA_OUT)] ? $env(NIA_OUT) : [file join $nia_root build image]}]
set clients     [expr {[info exists env(NIA_CLIENTS)] ? $env(NIA_CLIENTS) : 2}]

set rate        [expr {[info exists env(NIA_RATE)] ? $env(NIA_RATE) : 100}]
if {[lsearch -exact {100 200 400} $rate] < 0} {
  puts "IMAGE FAIL: NIA_RATE=$rate is not one of 100, 200, 400"
  exit 2
}
if {$rate != 100} {
  set clients [expr {$rate == 400 ? 1 : 2}]
}

set pktgen [expr {[info exists env(NIA_PKTGEN)] ? $env(NIA_PKTGEN) : "seg"}]
if {[lsearch -exact {seg axis} $pktgen] < 0} {
  puts "IMAGE FAIL: NIA_PKTGEN=$pktgen is not one of seg, axis"
  exit 2
}
if {$pktgen eq "axis" && $rate != 100} {
  puts "IMAGE FAIL: NIA_PKTGEN=axis is built at NIA_RATE=100 only. It was asked for at rate $rate,\
and the AXI-Stream host width has to follow the client geometry, DATA_W = 2 x N_SEG x 128, which no\
wider seam provides yet."
  exit 2
}
puts "IMAGE PKTGEN $pktgen"

switch -- $rate {
  100 {
    set rate_phy_section PHY_REAL
    set rate_top      [expr {$clients > 1 ? "tu03_pktgen_dual_top" : "tu03_pktgen_board_top"}]
    set rate_top_file [expr {$clients > 1 ? "tu03_pktgen_dual_top.sv" : "tu03_pktgen_board_top.sv"}]
    if {$pktgen eq "axis"} {
      set rate_top      [expr {$clients > 1 ? "tu03_axispg_dual_top" : "tu03_axispg_top"}]
      set rate_top_file [expr {$clients > 1 ? "tu03_axispg_dual_top.sv" : "tu03_axispg_top.sv"}]
    }
    set xdc_name      [expr {$clients > 1 ? "tu03_pktgen_dual_timing.xdc" : "tu03_pktgen_timing.xdc"}]
    set phys_name     tu03_pktgen_post_synth.tcl
  }
  200 {
    set rate_phy_section PHY_RATE200
    set rate_top      tu03_pktgen_dual200_top
    set rate_top_file tu03_pktgen_dual200_top.sv
    set xdc_name      tu03_pktgen_dual_timing.xdc
    set phys_name     tu03_pktgen_post_synth.tcl
  }
  400 {
    set rate_phy_section PHY_RATE400
    set rate_top      tu03_pktgen_400g_top
    set rate_top_file tu03_pktgen_400g_top.sv
    set xdc_name      tu03_pktgen_400g_timing.xdc
    set phys_name     tu03_pktgen_400g_post_synth.tcl
  }
}

set xdc_default [file join $nia_root example TU03 fpga constraints $xdc_name]
set xdc_file    [expr {[info exists env(NIA_XDC)] ? $env(NIA_XDC) : $xdc_default}]
set phys_default [file join $nia_root example TU03 fpga constraints $phys_name]
set xdc_phys    [expr {[info exists env(NIA_XDC_PHYS)] ? $env(NIA_XDC_PHYS) : $phys_default}]
if {$xdc_phys eq "none"} { set xdc_phys "" }
set jobs        [expr {[info exists env(NIA_JOBS)] ? $env(NIA_JOBS) : 16}]
set ip_dir      [expr {[info exists env(NIA_IP_DIR)] ? $env(NIA_IP_DIR) : [file join $nia_root build ip]}]

proc nia_synth_dir_arg {} {
  set v [expr {[info exists ::env(NIA_SYNTH_DIRECTIVE)] ? $::env(NIA_SYNTH_DIRECTIVE) : ""}]
  if {$v eq ""} { return "" }
  return "-directive $v"
}
set ooc         [expr {[info exists env(NIA_OOC)] ? $env(NIA_OOC) : 0}]
set loopback    [expr {[info exists env(NIA_LOOPBACK)] ? $env(NIA_LOOPBACK) : 0}]
if {$ooc && $rate != 100} {
  puts "IMAGE FAIL: NIA_OOC=1 with NIA_RATE=$rate. The out of context top is fpga_pktgen_top, which\
is the one-quad 100GAUI-1 instrument: it would bind a 2-segment 4-lane seam to the PHY of a wider\
rate. Build the wide rates pin complete, with their own tops."
  exit 2
}
set ooc_top     [expr {$pktgen eq "axis" ? "fpga_axispg_dual_top" : "fpga_pktgen_top"}]
set top_default [expr {$ooc ? $ooc_top : $rate_top}]
set top         [expr {[info exists env(NIA_TOP)] ? $env(NIA_TOP) : $top_default}]
set write_pdi   [expr {[info exists env(NIA_IMAGE_WRITE)] ? $env(NIA_IMAGE_WRITE) : ($ooc ? 0 : 1)}]

file mkdir $out_dir

proc nia_sections {path sections} {
  set out [list]
  set current ""
  set fh [open $path r]
  foreach line [split [read $fh] "\n"] {
    set line [string trim $line]
    if {$line eq "" || [string index $line 0] eq "#"} { continue }
    if {[string index $line 0] eq "\["} {
      set current [string trim $line "\[\]"]
      continue
    }
    if {[lsearch -exact $sections $current] >= 0} { lappend out $line }
  }
  close $fh
  return $out
}

set file_list [file join $nia_root rtl dcmac_seam_files.f]
if {![file exists $file_list]} {
  puts "IMAGE FAIL: source list $file_list is absent"
  exit 2
}

if {$pktgen eq "axis"} {
  set sections [list COMMON FIFO_IP PKTGEN_AXIS $rate_phy_section OPTIONAL]
  lappend sections [expr {$clients > 1 ? "TOP_SEAM_DUAL" : "TOP_SEAM"}]
} else {
  set sections [list COMMON PKTGEN TOP_PKTGEN $rate_phy_section OPTIONAL]
  if {$clients > 1} { lappend sections TOP_PKTGEN_DUAL }
}
set sources [list]
foreach rel [nia_sections $file_list $sections] {
  set abs [file normalize [file join $nia_root rtl $rel]]
  if {![file exists $abs]} {
    puts "IMAGE FAIL: $rel named by the source list is absent"
    exit 2
  }
  lappend sources $abs
}

foreach src $sources {
  if {[string match "*/sim/model/*" $src]} {
    puts "IMAGE FAIL: $src is a simulation model and this is a device image. The FIFO arms share\
 module names, so FIFO_IP and FIFO_MODEL are alternatives and never an addition."
    exit 2
  }
}
if {$rate == 100} {
  if {$pktgen eq "axis"} {
    lappend sources [file normalize [file join $nia_root example TU03 fpga rtl fpga_axispg_dual_top.sv]]
  } else {
    lappend sources [file normalize [file join $nia_root example TU03 fpga rtl fpga_pktgen_top.sv]]
  }
}
if {!$ooc} {
  lappend sources [file normalize [file join $nia_root example TU03 fpga rtl $rate_top_file]]
}

set phy_defs [list]
foreach s $sources {
  set fh [open $s r]
  set txt [read $fh]
  close $fh
  if {[regexp -line {^[ \t]*module[ \t]+dcmac_phy[ \t]*(#|\()} $txt]} { lappend phy_defs $s }
}
puts "IMAGE RATE $rate"
puts "IMAGE PHY [llength $phy_defs] [join $phy_defs { }]"
if {[llength $phy_defs] != 1} {
  puts "IMAGE FAIL: [llength $phy_defs] file(s) define module dcmac_phy, and exactly one may:\
[join $phy_defs { }]. Section $rate_phy_section of [file tail $file_list] names the one this rate\
needs."
  exit 2
}

if {![file exists $xdc_file]} {
  puts "IMAGE FAIL: NIA_XDC=$xdc_file does not exist. The transceiver placement and the board clocks are board facts and this script does not invent them."
  exit 2
}
puts "IMAGE XDC $xdc_file"

set manifest [file join $ip_dir ip_manifest.txt]
set xci_list [list]
if {[file exists $manifest]} {
  set fh [open $manifest r]
  foreach line [split [read $fh] "\n"] {
    set line [string trim $line]
    if {$line ne "" && [file exists $line]} { lappend xci_list $line }
  }
  close $fh
}
if {[llength $xci_list] == 0} {
  puts "IMAGE FAIL: $manifest names no existing .xci. build_ip.tcl generates them; make image runs it when they are absent."
  exit 2
}

set bridge_files [list]
if {!$ooc} {
  source [file join $nia_root ip dcmac_host_bridge_bd.tcl]
  set bridge_files [dcmac_host_bridge_read [file join $ip_dir bd]]
  if {[llength $bridge_files] != 2} {
    puts "IMAGE FAIL: [dcmac_host_bridge_manifest [file join $ip_dir bd]] names no block design and wrapper. build_ip.tcl builds them; make image runs it when they are absent."
    exit 2
  }
}

puts "IMAGE STAGE project"
create_project -in_memory -part $part
set_property target_language Verilog [current_project]
set_property ip_output_repo $ip_dir [current_project]

foreach src $sources { read_verilog -sv $src }
foreach xci $xci_list {
  read_ip $xci
  puts "IMAGE IP $xci"
}
foreach f $bridge_files {
  if {[file extension $f] eq ".bd"} {
    read_bd $f
    puts "IMAGE BD $f"
    set bd_sources [get_files -quiet -compile_order sources -used_in synthesis \
                      -of_objects [get_files $f]]
    puts "IMAGE BD SOURCES [llength $bd_sources]"
    foreach cell {versal_cips axil_convert axil_reset} {
      set n 0
      foreach s $bd_sources { if {[string match "*_${cell}_0*" $s]} { incr n } }
      if {$n == 0} {
        puts "IMAGE FAIL: the block design contributes no synthesis source for $cell, so synthesis would not find its module. Rebuild the block design: NIA_IP_FORCE=1 make image"
        exit 2
      }
      puts "IMAGE BD SOURCE COUNT $cell $n"
    }
  } else {
    read_verilog $f
    puts "IMAGE BD WRAPPER $f"
  }
}
read_xdc $xdc_file

puts "IMAGE TOP $top"
puts "IMAGE CLIENTS $clients"
puts "IMAGE LOOPBACK $loopback"
puts "IMAGE STAGE synth"
if {$ooc} {
  synth_design -top $top -part $part -mode out_of_context \
    -generic LOOPBACK_MODE=$loopback
} else {
  set d_synth [nia_synth_dir_arg]
  set a_retime [expr {[info exists env(NIA_SYNTH_RETIMING)] && $env(NIA_SYNTH_RETIMING) != 0 ? "-retiming" : ""}]
  puts "IMAGE SYNTH EFFORT directive='$d_synth' retiming='$a_retime'"
  eval synth_design -top $top -part $part -generic LOOPBACK_MODE=$loopback $d_synth $a_retime
}
write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization -file [file join $out_dir post_synth_utilization.rpt]
report_timing_summary -file [file join $out_dir post_synth_timing_summary.rpt]
puts "IMAGE STAGE synth done"

if {$xdc_phys ne ""} {
  if {![file exists $xdc_phys]} {
    puts "IMAGE FAIL: NIA_XDC_PHYS=$xdc_phys does not exist"
    exit 2
  }
  source $xdc_phys
  puts "IMAGE PHYS $xdc_phys"
}

puts "IMAGE STAGE impl"

proc nia_dir_arg {name {fallback ""}} {
  set v [expr {[info exists ::env($name)] ? $::env($name) : $fallback}]
  if {$v eq ""} { return "" }
  return "-directive $v"
}
set axis_place_default [expr {$pktgen eq "axis" ? "ExtraTimingOpt" : ""}]
set axis_phys_default  [expr {$pktgen eq "axis" ? "AggressiveExplore" : ""}]
set axis_post_default  [expr {$pktgen eq "axis" ? 1 : 0}]
set d_opt   [nia_dir_arg NIA_OPT_DIRECTIVE]
set d_place [nia_dir_arg NIA_PLACE_DIRECTIVE $axis_place_default]
set d_phys  [nia_dir_arg NIA_PHYS_DIRECTIVE $axis_phys_default]
set d_route [nia_dir_arg NIA_ROUTE_DIRECTIVE]
set post_phys [expr {[info exists env(NIA_POST_ROUTE_PHYS)] ? $env(NIA_POST_ROUTE_PHYS) : $axis_post_default}]
puts "IMAGE IMPL DIRECTIVES opt='$d_opt' place='$d_place' phys='$d_phys' route='$d_route' post_route_phys=$post_phys"

eval opt_design $d_opt
eval place_design $d_place
eval phys_opt_design $d_phys
eval route_design $d_route

if {$post_phys != 0} {
  puts "IMAGE STAGE post_route_phys_opt"
  phys_opt_design -directive AggressiveExplore
  puts "IMAGE POST_ROUTE_PHYS done"
}

write_checkpoint -force [file join $out_dir post_route.dcp]
puts "IMAGE CHECKPOINT [file join $out_dir post_route.dcp]"
if {$ooc} {
  puts "IMAGE MODE out_of_context"
} else {
  puts "IMAGE MODE pin_complete"
}
report_timing_summary -file [file join $out_dir post_route_timing_summary.rpt]
report_utilization -file [file join $out_dir post_route_utilization.rpt]
report_drc -file [file join $out_dir post_route_drc.rpt]
report_methodology -file [file join $out_dir post_route_methodology.rpt]
report_cdc -details -file [file join $out_dir post_route_cdc.rpt]
report_clock_utilization -file [file join $out_dir post_route_clock_utilization.rpt]
report_control_sets -verbose -file [file join $out_dir post_route_control_sets.rpt]
report_bus_skew -file [file join $out_dir post_route_bus_skew.rpt]
report_clock_interaction -file [file join $out_dir post_route_clock_interaction.rpt]

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "IMAGE WNS $wns"
puts "IMAGE WHS $whs"

set nfail [llength [get_timing_paths -delay_type max -max_paths 10000 -slack_lesser_than 0]]
puts "IMAGE FAILING_PATHS $nfail"

set check_timing_rpt [file join $out_dir post_route_check_timing.rpt]
check_timing -file $check_timing_rpt
set noclk "unknown"
if {[file exists $check_timing_rpt]} {
  set fh [open $check_timing_rpt r]
  foreach line [split [read $fh] "\n"] {
    if {[regexp {checking no_clock\s*\((\d+)\)} $line -> n]} { set noclk $n }
  }
  close $fh
}
puts "IMAGE NOCLK $noclk"

if {$write_pdi} {
  if {[catch {write_device_image -force [file join $out_dir ${top}.pdi]} err]} {
    puts "IMAGE PDI REFUSED $err"
  } else {
    puts "IMAGE WRITTEN [file join $out_dir ${top}.pdi]"
  }
} elseif {$ooc} {
  puts "IMAGE PDI SKIPPED out of context: no pin assignment, so no device image"
} else {
  puts "IMAGE PDI SKIPPED NIA_IMAGE_WRITE=0"
}
puts "IMAGE DONE rc=0"
