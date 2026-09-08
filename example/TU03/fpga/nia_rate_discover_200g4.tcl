# ---------------------------------------------------------------------------
# File        : nia_rate_discover_200g4.tcl
# Description : Reads the client and serdes port list the DCMAC generates for the dual
#               200GAUI-4 configuration, so the PHY wrapper is written against the port
#               list and not against an assumption about it.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set nia_d_part [expr {[info exists env(NIA_PART)] ? $env(NIA_PART) : "xcvp1552-vsva2785-2MHP-i-S"}]
set nia_d_out  [expr {[info exists env(NIA_DISCOVER_OUT)] ? $env(NIA_DISCOVER_OUT) : [pwd]}]

file mkdir $nia_d_out
create_project -force nia_rate_discover $nia_d_out/work -part $nia_d_part
set_property target_language Verilog [current_project]

create_ip -name dcmac -vendor xilinx.com -library ip -version 3.1 -module_name dcmac_0
set nia_d_ip [get_ips dcmac_0]

puts "DISCOVER PORT0 legal values = [list_property_value CONFIG.MAC_PORT0_CONFIG_C0 $nia_d_ip]"

set nia_d_cfg [list \
    CONFIG.MAC_PORT0_CONFIG_C0 {200GAUI-4} \
    CONFIG.MAC_PORT0_ENABLE_AN_LT_C0 {0} \
    CONFIG.MAC_PORT1_ENABLE_C0 {1} \
    CONFIG.MAC_PORT1_ENABLE_AN_LT_C0 {0} \
    CONFIG.MAC_PORT2_CONFIG_C0 {200GAUI-4} \
    CONFIG.MAC_PORT2_ENABLE_C0 {1} \
    CONFIG.MAC_PORT2_ENABLE_AN_LT_C0 {0} \
    CONFIG.MAC_PORT3_ENABLE_C0 {1} \
    CONFIG.MAC_PORT3_ENABLE_AN_LT_C0 {0} \
    CONFIG.MAC_PORT4_ENABLE_C0 {0} \
    CONFIG.MAC_PORT5_ENABLE_C0 {0} \
    CONFIG.TIMESTAMP_CLK_PERIOD_NS {2.4}]

if {[catch {set_property -dict $nia_d_cfg $nia_d_ip} nia_d_err]} {
    puts "DISCOVER FAIL config: $nia_d_err"
    exit 2
}

foreach nia_d_k {MAC_PORT0_CONFIG_C0 MAC_PORT2_CONFIG_C0 GT_TYPE_C0 GT_REF_CLK_FREQ_C0 \
                 GT_GROUP_SELECT_C0 FEC_SLICE0_CFG_C0 FEC_SLICE1_CFG_C0 NUM_OF_GT_LANES_C0 \
                 GT_LINE_RATE_C0} {
    set nia_d_v "<unreadable>"
    catch { set nia_d_v [get_property CONFIG.$nia_d_k $nia_d_ip] }
    puts "DISCOVER dcmac_0 CONFIG.$nia_d_k = $nia_d_v"
}

if {[catch {generate_target {instantiation_template synthesis} $nia_d_ip} nia_d_err]} {
    puts "DISCOVER FAIL generate: $nia_d_err"
    exit 2
}

set nia_d_dir [get_property IP_DIR $nia_d_ip]
puts "DISCOVER IP_DIR $nia_d_dir"

set nia_d_tmpl ""
foreach nia_d_pat {dcmac_0.veo dcmac_0.vho dcmac_0_stub.v dcmac_0.v} {
    foreach nia_d_f [glob -nocomplain -directory $nia_d_dir -join * $nia_d_pat] {
        if {$nia_d_tmpl eq ""} { set nia_d_tmpl $nia_d_f }
    }
    foreach nia_d_f [glob -nocomplain -directory $nia_d_dir $nia_d_pat] {
        if {$nia_d_tmpl eq ""} { set nia_d_tmpl $nia_d_f }
    }
}
puts "DISCOVER TEMPLATE $nia_d_tmpl"
if {$nia_d_tmpl ne ""} {
    set nia_d_fh [open $nia_d_tmpl r]
    set nia_d_txt [read $nia_d_fh]
    close $nia_d_fh
    foreach nia_d_re {{tx_axis_tdata\d+} {tx_axis_tvalid_\d+} {tx_axis_tready_\d+}
                      {rx_axis_tdata\d+} {rx_axis_tvalid_\d+}
                      {txdata_out_\d+} {rxdata_in_\d+}
                      {tx_serdes_clk} {rx_serdes_clk}} {
        set nia_d_hit [lsort -unique [regexp -all -inline $nia_d_re $nia_d_txt]]
        puts "DISCOVER PORTS $nia_d_re count=[llength $nia_d_hit] : $nia_d_hit"
    }
    file copy -force $nia_d_tmpl [file join $nia_d_out [file tail $nia_d_tmpl]]
}

puts "DISCOVER DONE"
