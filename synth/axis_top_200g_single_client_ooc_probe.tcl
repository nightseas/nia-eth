# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views

set part      [expr {[info exists env(NIA_PART)] ? $env(NIA_PART) : "xcvp1552-vsva2785-2MHP-i-S"}]
set data_w    [expr {[info exists env(NIA_OOC_DATA_W)] ? $env(NIA_OOC_DATA_W) : 1024}]
set seg_per   [expr {[info exists env(NIA_OOC_SEG_PER)] ? $env(NIA_OOC_SEG_PER) : 2.560}]
set usr_per   [expr {[info exists env(NIA_OOC_USR_PER)] ? $env(NIA_OOC_USR_PER) : 4.000}]
set run_synth [expr {[info exists env(NIA_OOC_SYNTH)] ? $env(NIA_OOC_SYNTH) : 1}]
set jobs      [expr {[info exists env(NIA_JOBS)] ? $env(NIA_JOBS) : 16}]

set here    [file normalize [file dirname [info script]]]
set root    [file normalize [file join $here ..]]
set rtl     [file join $root rtl]
set ip_src  [file join $root ip]
set rate_src [file join $ip_src rate200]
set out_dir [expr {[info exists env(NIA_OUT)] ? $env(NIA_OUT) :
                   [file join $root build axis_top_200g_single_client_ooc]}]
set ip_dir  [expr {[info exists env(NIA_IP_DIR)] ? $env(NIA_IP_DIR) : [file join $out_dir ip]}]

set config_key 200single
set n_seg      4
set nports     2
set anchor     0
set rate_code  1
set rate_field 8
set done_mask      15
set polarity_tx_q0 12
set polarity_rx_q0 0

file mkdir $out_dir $ip_dir

proc nia_probe_sections {path sections} {
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

set file_list [file join $rtl dcmac_seam_files.f]
if {![file exists $file_list]} {
  puts "PROBE FAIL: source list $file_list is absent"
  exit 2
}
set sources [list]
foreach rel [nia_probe_sections $file_list \
               [list COMMON FIFO_IP PHY_RATE200 OPTIONAL TOP_SEAM]] {
  set abs [file normalize [file join $rtl $rel]]
  if {![file exists $abs]} {
    puts "PROBE FAIL: $rel named by the source list is absent"
    exit 2
  }
  lappend sources $abs
}
set phy_defs [list]
foreach s $sources {
  set fh [open $s r]
  set txt [read $fh]
  close $fh
  if {[regexp -line {^[ \t]*module[ \t]+dcmac_phy[ \t]*(#|\()} $txt]} { lappend phy_defs $s }
}
puts "PROBE PHY [llength $phy_defs] [join $phy_defs { }]"
if {[llength $phy_defs] != 1} {
  puts "PROBE FAIL: [llength $phy_defs] file(s) define module dcmac_phy, and exactly one may"
  exit 2
}

puts "PROBE PART $part"
puts "PROBE CONFIG $config_key N_SEG=$n_seg NPORTS=$nports ANCHOR=$anchor DATA_W=$data_w"
puts "PROBE RATE RATE_CODE=$rate_code RATE_FIELD=$rate_field DONE_MASK=$done_mask\
      ([format %08b $done_mask])"
puts "PROBE POLARITY TX_Q0=$polarity_tx_q0 ([format %08b $polarity_tx_q0])\
      RX_Q0=$polarity_rx_q0 ([format %08b $polarity_rx_q0])"

create_project -in_memory -part $part
set_property target_language Verilog [current_project]
set_property ip_output_repo $ip_dir [current_project]

puts "PROBE STAGE ip_create"
source [file join $ip_src dcmac_ip_rate.tcl]
dcmac_create_ips_rate $config_key $ip_src $rate_src

set NIA_FIFO_IP_DIR $ip_dir
source [file join $ip_src dcmac_fifo_ip.tcl]

foreach ip [get_ips] { puts "PROBE IP $ip [get_property IP_DIR [get_ips $ip]]" }

puts "PROBE STAGE ip_generate"
generate_target {instantiation_template synthesis} [get_ips]

puts "PROBE STAGE ip_synth"
foreach ip [get_ips] {
  if {[catch {synth_ip [get_ips $ip]} err]} {
    puts "PROBE FAIL: synth_ip $ip: $err"
    exit 2
  }
  puts "PROBE IP SYNTH OK $ip"
}

foreach src $sources { read_verilog -sv $src }

set generics [list \
  -generic N_SEG=$n_seg \
  -generic SEG_W=128 \
  -generic DATA_W=$data_w \
  -generic NPORTS=$nports \
  -generic ANCHOR=$anchor \
  -generic RATE_CODE=$rate_code \
  -generic RATE_FIELD=$rate_field \
  -generic DONE_MASK=$done_mask \
  -generic POLARITY_TX_Q0=$polarity_tx_q0 \
  -generic POLARITY_RX_Q0=$polarity_rx_q0]

puts "PROBE STAGE elaborate"
if {[catch {eval synth_design -rtl -name rtl_single_client_200g -top dcmac_axis_top \
              -part $part -mode out_of_context \
              -verilog_define DCMAC_FRAME_FIFO_BRAM $generics} err]} {
  puts "PROBE ELABORATE FAIL: $err"
  puts "PROBE ERRORS [get_msg_config -severity {ERROR} -count]"
  puts "PROBE RESULT ELABORATE_FAILED"
  puts "PROBE DONE"
  exit 1
}
puts "PROBE ELABORATE OK"
puts "PROBE ELAB_ERRORS [get_msg_config -severity {ERROR} -count]"
puts "PROBE ELAB_CRITICAL_WARNINGS [get_msg_config -severity {CRITICAL WARNING} -count]"
puts "PROBE ELAB_GT_SERIAL_PINS [llength [get_ports -quiet {gt_rxp_in[*]}]]"
puts "PROBE ELAB_GT_REFCLK_PINS [llength [get_ports -quiet gt_ref_clk_p]]"
puts "PROBE ELAB_DCMAC_INSTANCES\
      [llength [get_cells -quiet -hier -filter {REF_NAME =~ dcmac_0}]]"
puts "PROBE ELAB_TRANSCEIVER_QUAD_CELLS\
      [llength [get_cells -quiet -hier -filter {NAME =~ *gt_quad_base_*_inst/inst/quad_inst}]]"
puts "PROBE ELAB_REFCLK_BUFFERS\
      [llength [get_cells -quiet -hier -filter {NAME =~ *dcmac_IBUFDS_GTE5_REFCLK*}]]"
close_design

if {$run_synth == 0} {
  puts "PROBE SYNTH SKIPPED NIA_OOC_SYNTH=0"
  puts "PROBE RESULT ELABORATE_OK"
  puts "PROBE DONE"
  exit 0
}

read_xdc [file join $here axis_top_200g_single_client_ooc.xdc]

puts "PROBE STAGE synth"
if {[catch {eval synth_design -top dcmac_axis_top -part $part -mode out_of_context \
              -verilog_define DCMAC_FRAME_FIFO_BRAM $generics} err]} {
  puts "PROBE SYNTH FAIL: $err"
  puts "PROBE ERRORS [get_msg_config -severity {ERROR} -count]"
  puts "PROBE RESULT SYNTH_FAILED"
  puts "PROBE DONE"
  exit 1
}
write_checkpoint -force [file join $out_dir post_synth.dcp]
puts "PROBE SYNTH OK"
puts "PROBE ERRORS [get_msg_config -severity {ERROR} -count]"
puts "PROBE CRITICAL_WARNINGS [get_msg_config -severity {CRITICAL WARNING} -count]"

set dcmac_cells [get_cells -quiet -hier -filter {REF_NAME =~ DCMAC*}]
set gtm_cells   [get_cells -quiet -hier -filter {REF_NAME =~ GTM*}]
set quad_cells  [get_cells -quiet -hier -filter {NAME =~ *gt_quad_base_*_inst/inst/quad_inst}]
puts "PROBE HARDMACRO_DCMAC [llength $dcmac_cells]"
puts "PROBE HARDMACRO_GTM [llength $gtm_cells]"
puts "PROBE TRANSCEIVER_QUAD_CELLS [llength $quad_cells]"
foreach c $quad_cells { puts "PROBE TRANSCEIVER_QUAD_CELL $c" }

set mac_core_clocks   [list]
set mac_stream_clocks [list]
foreach clk [get_clocks -quiet] {
  set source_pins ""
  catch { set source_pins [get_property SOURCE_PINS $clk] }
  if {[string match *i_dcmac_clk_wiz* $source_pins]} { lappend mac_core_clocks   $clk }
  if {[string match *i_usr_clk_wiz*   $source_pins]} { lappend mac_stream_clocks $clk }
}
puts "PROBE MAC_CORE_CLOCKS $mac_core_clocks"
puts "PROBE MAC_STREAM_CLOCKS $mac_stream_clocks"
if {[llength $mac_core_clocks] > 0 && [llength $mac_stream_clocks] > 0} {
  set_clock_groups -asynchronous -name nia_eth_mac_core_to_mac_stream \
    -group $mac_core_clocks -group $mac_stream_clocks
  puts "PROBE CLOCK_GROUP nia_eth_mac_core_to_mac_stream applied"
} else {
  puts "PROBE CLOCK_GROUP nia_eth_mac_core_to_mac_stream not applied: a clock tree resolved empty"
}

report_clocks -file [file join $out_dir report_clocks.rpt]
puts "PROBE NCLOCKS [llength [get_clocks -quiet]]"
foreach clk [get_clocks -quiet] {
  set p [get_timing_paths -quiet -setup -max_paths 1 -to [get_clocks $clk]]
  set per [get_property PERIOD [get_clocks $clk]]
  if {[llength $p]} {
    puts "PROBE CLK $clk period=$per slack=[get_property SLACK $p]\
          levels=[get_property LOGIC_LEVELS $p] endpoint=[get_property ENDPOINT_PIN $p]"
  } else {
    puts "PROBE CLK $clk period=$per slack=no_internal_path"
  }
}

check_timing -override_defaults no_clock -verbose
report_timing_summary -delay_type max -max_paths 10 \
                      -file [file join $out_dir timing_summary_synth.rpt]
set wns [get_property SLACK [get_timing_paths -quiet -setup -max_paths 1]]
if {$wns eq ""} {
  puts "PROBE SYNTH_WNS no_constrained_path"
} else {
  puts "PROBE SYNTH_WNS $wns"
}
puts "PROBE FAILING_SETUP_ENDPOINTS\
      [llength [get_timing_paths -quiet -setup -max_paths 10000 -slack_lesser_than 0]]"
report_utilization -file [file join $out_dir utilization_synth.rpt]
puts "PROBE SEQ_CELLS [llength [get_cells -quiet -hier -filter {IS_SEQUENTIAL}]]"
puts "PROBE LUTS [llength [get_cells -quiet -hier -filter {REF_NAME =~ LUT*}]]"
puts "PROBE BRAM [llength [get_cells -quiet -hier -filter {REF_NAME =~ RAMB*}]]"
puts "PROBE SEG_PERIOD $seg_per USR_PERIOD $usr_per"
puts "PROBE RESULT SYNTH_OK"
puts "PROBE DONE"
