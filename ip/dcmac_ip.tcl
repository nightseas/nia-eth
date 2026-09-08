# ---------------------------------------------------------------------------
# File        : dcmac_ip.tcl
# Description : Creates and configures the DCMAC IP for a single 100GAUI-1 client.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

proc dcmac_create_ips {ip_src_dir {ip_dir ""}} {
    set dir_args [expr {$ip_dir eq "" ? [list] : [list -dir $ip_dir]}]
    create_ip -name dcmac -vendor xilinx.com -library ip -version 3.1 -module_name dcmac_0 {*}$dir_args
    set_property -dict [list \
        CONFIG.MAC_PORT0_CONFIG_C0 {100GAUI-1} \
        CONFIG.MAC_PORT0_ENABLE_AN_LT_C0 {0} \
        CONFIG.MAC_PORT1_ENABLE_C0 {0} \
        CONFIG.MAC_PORT2_ENABLE_C0 {0} \
        CONFIG.MAC_PORT3_ENABLE_C0 {0} \
        CONFIG.MAC_PORT4_ENABLE_C0 {0} \
        CONFIG.MAC_PORT5_ENABLE_C0 {0} \
        CONFIG.TIMESTAMP_CLK_PERIOD_NS {2.4} \
    ] [get_ips dcmac_0]

    import_ip -quiet "$ip_src_dir/dcmac_0_gtwiz_versal_0.xci"
    import_ip -quiet "$ip_src_dir/dcmac_0_clk_wiz_0.xci"

    # The register plane is 250 MHz whatever the rate, because the DCMAC APB3_CLK requires
    # 3.333 ns. clk_out3 is the datapath and NIA_USR_MHZ moves only that one. Every rate
    # generates three outputs, because the PHY wrappers connect clk_out3 at every rate and a
    # two output wizard is the synthesis error 'named port connection clk_out3 does not exist'.
    set nia_usr_mhz [expr {[info exists ::env(NIA_USR_MHZ)] ? $::env(NIA_USR_MHZ) : 250}]
    switch -- $nia_usr_mhz {
        250     { set nia_usr_freq 250.000 }
        391     { set nia_usr_freq 390.625 }
        default {
            puts "NIA_IP FAIL: NIA_USR_MHZ=$nia_usr_mhz is not one of 250, 391"
            exit 2
        }
    }
    puts "NIA_IP NET_CLK_MHZ $nia_usr_mhz requested $nia_usr_freq, register plane 250.000"

    create_ip -name clk_wizard -vendor xilinx.com -library ip -version 1.0 \
              -module_name dcmac_usr_clk_wiz {*}$dir_args
    set_property -dict [list \
        CONFIG.CLKOUT_DRIVES {BUFG,BUFG,BUFG} \
        CONFIG.CLKOUT_PORT {clk_out1,clk_out2,clk_out3} \
        CONFIG.CLKOUT_REQUESTED_OUT_FREQUENCY "250.000,100.000,${nia_usr_freq}" \
        CONFIG.CLKOUT_USED {true,true,true} \
        CONFIG.PRIM_IN_FREQ {156.250} \
        CONFIG.PRIM_SOURCE {Global_buffer} \
        CONFIG.USE_RESET {true} \
        CONFIG.RESET_TYPE {ACTIVE_HIGH} \
        CONFIG.RESET_PORT {reset} \
        CONFIG.USE_LOCKED {true} \
    ] [get_ips dcmac_usr_clk_wiz]

    foreach k {CLKOUT_USED CLKOUT_PORT CLKOUT_REQUESTED_OUT_FREQUENCY CLKOUT_DRIVES} {
        puts "NIA_IPCHK dcmac_usr_clk_wiz CONFIG.$k = \
              [get_property CONFIG.$k [get_ips dcmac_usr_clk_wiz]]"
    }
    puts "NIA_IPCHK dcmac_0 CONFIG.MAC_PORT0_CONFIG_C0 = \
          [get_property CONFIG.MAC_PORT0_CONFIG_C0 [get_ips dcmac_0]]"
    puts "NIA_IPLIST = [get_ips]"
}
