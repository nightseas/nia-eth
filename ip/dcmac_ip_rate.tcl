# ---------------------------------------------------------------------------
# File        : dcmac_ip_rate.tcl
# Description : Creates the DCMAC and the transceiver wizards for the 200GAUI-2 and
#               400GAUI-4 configurations, from the port pattern each rate needs.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set ::nia_rate_ip_dir [file dirname [file normalize [info script]]]

proc nia_rate_ip_files {rate} {
    switch -- $rate {
        200     { return [list dcmac_0_gtwiz_versal_0.xci dcmac_0_gtwiz_versal_1.xci] }
        400     { return [list dcmac_0_gtwiz_versal_0.xci] }
        default { error "nia_rate_ip_files: NIA_RATE=$rate is not 200 or 400" }
    }
}

proc nia_rate_dcmac_cfg {rate} {
    if {$rate == 200} {
        return [list \
            CONFIG.MAC_PORT0_CONFIG_C0 {200GAUI-2} \
            CONFIG.MAC_PORT0_ENABLE_AN_LT_C0 {0} \
            CONFIG.MAC_PORT1_ENABLE_C0 {1} \
            CONFIG.MAC_PORT1_ENABLE_AN_LT_C0 {0} \
            CONFIG.MAC_PORT2_CONFIG_C0 {200GAUI-2} \
            CONFIG.MAC_PORT2_ENABLE_C0 {1} \
            CONFIG.MAC_PORT2_ENABLE_AN_LT_C0 {0} \
            CONFIG.MAC_PORT3_ENABLE_C0 {1} \
            CONFIG.MAC_PORT3_ENABLE_AN_LT_C0 {0} \
            CONFIG.MAC_PORT4_ENABLE_C0 {0} \
            CONFIG.MAC_PORT5_ENABLE_C0 {0} \
            CONFIG.TIMESTAMP_CLK_PERIOD_NS {2.4}]
    }
    if {$rate == 400} {
        return [list \
            CONFIG.MAC_PORT0_CONFIG_C0 {400GAUI-4} \
            CONFIG.MAC_PORT0_ENABLE_AN_LT_C0 {0} \
            CONFIG.MAC_PORT1_ENABLE_C0 {1} \
            CONFIG.MAC_PORT1_ENABLE_AN_LT_C0 {0} \
            CONFIG.MAC_PORT2_ENABLE_C0 {1} \
            CONFIG.MAC_PORT2_ENABLE_AN_LT_C0 {0} \
            CONFIG.MAC_PORT3_ENABLE_C0 {1} \
            CONFIG.MAC_PORT3_ENABLE_AN_LT_C0 {0} \
            CONFIG.MAC_PORT4_ENABLE_C0 {0} \
            CONFIG.MAC_PORT5_ENABLE_C0 {0} \
            CONFIG.TIMESTAMP_CLK_PERIOD_NS {2.4}]
    }
    error "nia_rate_dcmac_cfg: NIA_RATE=$rate is not 200 or 400"
}

proc dcmac_create_ips_rate {rate ip_src_dir rate_dir} {

    source $::nia_rate_ip_dir/dcmac_polarity.tcl

    puts "NIA_RATE_IP BEGIN rate=$rate ip_src_dir=$ip_src_dir rate_dir=$rate_dir"

    foreach f [nia_rate_ip_files $rate] {
        if {![file exists [file join $rate_dir $f]]} {
            error "dcmac_create_ips_rate: missing [file join $rate_dir $f]. The wizard XCIs of a\
                   rate are generated products of the DCMAC example design OF THAT RATE and this\
                   script does not invent them: a 200GAUI-2 client is a 4-lane wizard and a\
                   400GAUI-4 client is one 8-lane two-quad wizard."
        }
    }
    if {![file exists [file join $ip_src_dir dcmac_0_clk_wiz_0.xci]]} {
        error "dcmac_create_ips_rate: missing [file join $ip_src_dir dcmac_0_clk_wiz_0.xci]. It is\
               rate independent - identical by md5 in the 100, 200 and 400 example designs - so\
               every rate reads the one in ip/."
    }

    create_ip -name dcmac -vendor xilinx.com -library ip -version 3.1 -module_name dcmac_0
    set_property -dict [nia_rate_dcmac_cfg $rate] [get_ips dcmac_0]

    foreach f [nia_rate_ip_files $rate] {
        import_ip -quiet [file join $rate_dir $f]
        puts "NIA_RATE_IP IMPORT [file join $rate_dir $f]"
    }
    import_ip -quiet [file join $ip_src_dir dcmac_0_clk_wiz_0.xci]
    puts "NIA_RATE_IP IMPORT [file join $ip_src_dir dcmac_0_clk_wiz_0.xci] (rate independent)"

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

    foreach {k v} [nia_rate_dcmac_cfg $rate] {
        set key [string range $k 7 end]
        puts "NIA_IPCHK dcmac_0 CONFIG.$key = [get_property CONFIG.$key [get_ips dcmac_0]]\
              (asked for $v)"
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

    set want_wiz  $::nia_dp_pol_rate_wiz($rate)
    set want_lane $::nia_dp_pol_rate_lane($rate)
    set gtwiz [nia_dp_gtwiz_ips]
    puts "NIA_RATE_GTWIZ ip_count=[llength $gtwiz] (want $want_wiz at rate $rate)"
    puts "NIA_RATE_GTWIZ ips=$gtwiz"
    if {[llength $gtwiz] != $want_wiz} {
        error "expected $want_wiz gtwiz IP(s) at rate $rate, found [llength $gtwiz]: '$gtwiz'. At\
               200GAUI-2 there is one per cage, because one quad cannot reach two QSFP cages; at\
               400GAUI-4 there is exactly one, covering the two quads of QSFP0."
    }
    foreach ip $gtwiz {
        set l "<unreadable>"
        set q "<unreadable>"
        catch { set l [get_property CONFIG.INTF0_NO_OF_LANES [get_ips $ip]] }
        catch { set q [get_property CONFIG.NO_OF_QUADS [get_ips $ip]] }
        puts "NIA_RATE_GTWIZ $ip INTF0_NO_OF_LANES = $l NO_OF_QUADS = $q  (want $want_lane lanes)"
        if {$l ne "$want_lane"} {
            error "$ip has INTF0_NO_OF_LANES = $l, but rate $rate needs $want_lane: a 200GAUI-2\
                   client is 4 GT channels and a 400GAUI-4 client is 8 across two quads. The PHY of\
                   this rate connects INTF0_TX0..TX[expr {$want_lane - 1}] and their polarity, so a\
                   mismatch here is either a dangling connection or lanes left at polarity 0."
        }
    }

    nia_dp_preflight_polarity_or_die $rate

    puts "NIA_IPLIST = [get_ips]"
    puts "NIA_RATE_IP END rate=$rate"
}
