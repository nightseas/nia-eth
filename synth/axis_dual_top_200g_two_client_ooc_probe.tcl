# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views

set part   [expr {[info exists env(NIA_PART)] ? $env(NIA_PART) : "xcvp1552-vsva2785-2MHP-i-S"}]
set data_w [expr {[info exists env(NIA_OOC_DATA_W)] ? $env(NIA_OOC_DATA_W) : 1024}]

set here     [file normalize [file dirname [info script]]]
set root     [file normalize [file join $here ..]]
set rtl      [file join $root rtl]
set ip_src   [file join $root ip]
set rate_src [file join $ip_src rate200]
set out_dir  [expr {[info exists env(NIA_OUT)] ? $env(NIA_OUT) :
                    [file join $root build axis_dual_top_200g_two_client_ooc]}]
set ip_dir   [expr {[info exists env(NIA_IP_DIR)] ? $env(NIA_IP_DIR) : [file join $out_dir ip]}]

set config_key 200
set n_client   2
set n_seg      4
set nports     2
set anchor_0   0
set anchor_1   2
set gt_lanes   8
set rate_code  1
set rate_field 8
set done_mask      15
set polarity_tx_q0 12
set polarity_rx_q0 0
set polarity_tx_q1 3
set polarity_rx_q1 3

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
               [list COMMON FIFO_IP PHY_RATE200 OPTIONAL TOP_SEAM_DUAL]] {
  set abs [file normalize [file join $rtl $rel]]
  if {![file exists $abs]} {
    puts "PROBE FAIL: $rel named by the source list is absent"
    exit 2
  }
  lappend sources $abs
}

puts "PROBE PART $part"
puts "PROBE CONFIG $config_key N_CLIENT=$n_client N_SEG=$n_seg NPORTS=$nports\
      ANCHOR_0=$anchor_0 ANCHOR_1=$anchor_1 GT_LANES=$gt_lanes DATA_W=$data_w"
puts "PROBE RATE RATE_CODE=$rate_code RATE_FIELD=$rate_field DONE_MASK=$done_mask\
      ([format %08b $done_mask])"
puts "PROBE POLARITY TX_Q0=[format %08b $polarity_tx_q0] RX_Q0=[format %08b $polarity_rx_q0]\
      TX_Q1=[format %08b $polarity_tx_q1] RX_Q1=[format %08b $polarity_rx_q1]"

create_project -in_memory -part $part
set_property target_language Verilog [current_project]
set_property ip_output_repo $ip_dir [current_project]

puts "PROBE STAGE ip_create"
source [file join $ip_src dcmac_ip_rate.tcl]
dcmac_create_ips_rate $config_key $ip_src $rate_src

set NIA_FIFO_IP_DIR $ip_dir
source [file join $ip_src dcmac_fifo_ip.tcl]

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
  -generic N_CLIENT=$n_client \
  -generic N_SEG=$n_seg \
  -generic SEG_W=128 \
  -generic DATA_W=$data_w \
  -generic NPORTS=$nports \
  -generic ANCHOR_0=$anchor_0 \
  -generic ANCHOR_1=$anchor_1 \
  -generic GT_LANES=$gt_lanes \
  -generic RATE_CODE=$rate_code \
  -generic RATE_FIELD=$rate_field \
  -generic DONE_MASK=$done_mask \
  -generic POLARITY_TX_Q0=$polarity_tx_q0 \
  -generic POLARITY_RX_Q0=$polarity_rx_q0 \
  -generic POLARITY_TX_Q1=$polarity_tx_q1 \
  -generic POLARITY_RX_Q1=$polarity_rx_q1]

puts "PROBE STAGE elaborate"
if {[catch {eval synth_design -rtl -name rtl_two_client_200g -top dcmac_axis_dual_top \
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
puts "PROBE ELAB_GT_REFCLK_PINS\
      [llength [get_ports -quiet {gt_ref_clk0_p gt_ref_clk1_p}]]"
puts "PROBE ELAB_DCMAC_INSTANCES\
      [llength [get_cells -quiet -hier -filter {REF_NAME =~ dcmac_0}]]"
puts "PROBE ELAB_REFCLK_BUFFERS\
      [llength [get_cells -quiet -hier -filter {NAME =~ *dcmac_IBUFDS_GTE5_REFCLK*}]]"
puts "PROBE ELAB_TRANSCEIVER_QUAD_CELLS\
      [llength [get_cells -quiet -hier -filter {NAME =~ *gt_quad_base_*_inst/inst/quad_inst}]]"
foreach c [get_cells -quiet -hier -filter {NAME =~ *dcmac_IBUFDS_GTE5_REFCLK*}] {
  puts "PROBE ELAB_REFCLK_BUFFER_CELL $c"
}
puts "PROBE RESULT ELABORATE_OK"
puts "PROBE DONE"
