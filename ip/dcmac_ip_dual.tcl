# ---------------------------------------------------------------------------
# File        : dcmac_ip_dual.tcl
# Description : Creates and configures the DCMAC IP and both transceiver wizards for two
#               100GAUI-1 clients, and refuses a configuration the two cages cannot carry.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set ::nia_dp_synth_dir [file dirname [file normalize [info script]]]

proc dcmac_create_ips_dual {ip_src_dir} {

    source $::nia_dp_synth_dir/dcmac_polarity.tcl

    puts "NIA_DP_IP BEGIN dcmac_create_ips_dual ip_src_dir=$ip_src_dir"

    foreach f [list dcmac_0_gtwiz_versal_0.xci dcmac_0_gtwiz_versal_1.xci dcmac_0_clk_wiz_0.xci] {
        if {![file exists $ip_src_dir/$f]} {
            error "dcmac_create_ips_dual: missing $ip_src_dir/$f. The dual image needs TWO\
                   gtwiz XCIs, one per client and one quad each: one quad cannot reach two\
                   QSFP cages."
        }
    }

    create_ip -name dcmac -vendor xilinx.com -library ip -version 3.1 -module_name dcmac_0
    set_property -dict [list \
        CONFIG.MAC_PORT0_CONFIG_C0 {100GAUI-1} \
        CONFIG.MAC_PORT0_ENABLE_AN_LT_C0 {0} \
        CONFIG.MAC_PORT1_CONFIG_C0 {100GAUI-1} \
        CONFIG.MAC_PORT1_ENABLE_C0 {1} \
        CONFIG.MAC_PORT1_ENABLE_AN_LT_C0 {0} \
        CONFIG.MAC_PORT2_ENABLE_C0 {0} \
        CONFIG.MAC_PORT3_ENABLE_C0 {0} \
        CONFIG.MAC_PORT4_ENABLE_C0 {0} \
        CONFIG.MAC_PORT5_ENABLE_C0 {0} \
        CONFIG.TIMESTAMP_CLK_PERIOD_NS {2.4} \
    ] [get_ips dcmac_0]

    import_ip -quiet "$ip_src_dir/dcmac_0_gtwiz_versal_0.xci"
    import_ip -quiet "$ip_src_dir/dcmac_0_gtwiz_versal_1.xci"
    import_ip -quiet "$ip_src_dir/dcmac_0_clk_wiz_0.xci"

    create_ip -name clk_wizard -vendor xilinx.com -library ip -version 1.0 \
              -module_name dcmac_usr_clk_wiz
    set_property -dict [list \
        CONFIG.CLKOUT_DRIVES {BUFG,BUFG} \
        CONFIG.CLKOUT_PORT {clk_out1,clk_out2} \
        CONFIG.CLKOUT_REQUESTED_OUT_FREQUENCY {250.000,100.000} \
        CONFIG.CLKOUT_USED {true,true} \
        CONFIG.PRIM_IN_FREQ {156.250} \
        CONFIG.PRIM_SOURCE {Global_buffer} \
        CONFIG.USE_RESET {true} \
        CONFIG.RESET_TYPE {ACTIVE_HIGH} \
        CONFIG.RESET_PORT {reset} \
        CONFIG.USE_LOCKED {true} \
    ] [get_ips dcmac_usr_clk_wiz]

    nia_dp_pol_enable_ports

    foreach k {MAC_PORT0_CONFIG_C0 MAC_PORT0_ENABLE_AN_LT_C0 \
               MAC_PORT1_CONFIG_C0 MAC_PORT1_ENABLE_C0 MAC_PORT1_ENABLE_AN_LT_C0 \
               MAC_PORT2_ENABLE_C0 MAC_PORT3_ENABLE_C0 \
               MAC_PORT4_ENABLE_C0 MAC_PORT5_ENABLE_C0 \
               TIMESTAMP_CLK_PERIOD_NS} {
        puts "NIA_IPCHK dcmac_0 CONFIG.$k = [get_property CONFIG.$k [get_ips dcmac_0]]"
    }

    foreach k {FEC_SLICE0_CFG_C0 FEC_SLICE1_CFG_C0 GT_TYPE_C0 GT_REF_CLK_FREQ_C0 \
               GT_GROUP_SELECT_C0} {
        set v "<unreadable>"
        catch { set v [get_property CONFIG.$k [get_ips dcmac_0]] }
        puts "NIA_IPCHK dcmac_0 CONFIG.$k = $v   (DERIVED / default - not set by this recipe)"
    }
    foreach k {CLKOUT_USED CLKOUT_PORT CLKOUT_REQUESTED_OUT_FREQUENCY CLKOUT_DRIVES} {
        puts "NIA_IPCHK dcmac_usr_clk_wiz CONFIG.$k = \
              [get_property CONFIG.$k [get_ips dcmac_usr_clk_wiz]]"
    }

    set gtwiz [nia_dp_gtwiz_ips]
    puts "NIA_DP_GTWIZ ip_count=[llength $gtwiz] (want 2, one per client)"
    puts "NIA_DP_GTWIZ ips=$gtwiz"
    if {[llength $gtwiz] != 2} {
        error "expected TWO gtwiz IPs in the project, one per client, found [llength $gtwiz]:\
               '$gtwiz'. There is a named fallback if the IP genuinely packs two 1-lane clients into ONE\
               gtwiz: move the clients to MAC slots **0 and 2** - the golden dual exdes' own slot\
               pattern - via CONFIG.MAC_PORT2_CONFIG_C0 here and `ANCHOR_1 = 2` /\
               MAC_ANCHOR_LIST of each variant. Do NOT proceed with one gtwiz and two cages: a single\
               quad cannot reach two QSFP cages."
    }
    foreach ip $gtwiz {
        set l "<unreadable>"
        catch { set l [get_property CONFIG.INTF0_NO_OF_LANES [get_ips $ip]] }
        puts "NIA_DP_GTWIZ $ip INTF0_NO_OF_LANES = $l   (want 2: 100GAUI-1 = 1 wire lane = 1 Dual)"
        if {$l ne "2"} {
            error "$ip has INTF0_NO_OF_LANES = $l, but a 100GAUI-1 client is 2 GT channels\
                   (CH0 + its Dual partner CH1). A 4-lane gtwiz here means a 200G client crept in,\
                   and the PHY's INTF0_TX0/TX1 + RX0/RX1 map - including its polarity connections -\
                   would cover half the lanes."
        }
    }

    nia_dp_preflight_polarity_or_die

    puts "NIA_IPLIST = [get_ips]"
    puts "NIA_DP_IP END dcmac_create_ips_dual"
}

proc dcmac_ip_dual_preflight {ip_src_dir} {
    puts "NIA_DP_PREFLIGHT BEGIN ip_src_dir=$ip_src_dir"
    nia_dp_preflight_polarity_or_die
    puts "NIA_DP_PREFLIGHT END rc=0"
}
