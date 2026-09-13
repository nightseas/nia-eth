# ---------------------------------------------------------------------------
# File        : dcmac_ip_rate.tcl
# Description : Creates the DCMAC and the transceiver wizards for the 200GAUI-2, 200GAUI-4
#               and 400GAUI-4 configurations, from the port pattern each one needs.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set ::nia_rate_ip_dir [file dirname [file normalize [info script]]]

proc nia_rate_ip_files {key} {
    switch -- $key {
        200     { return [list dcmac_0_gtwiz_versal_0.xci dcmac_0_gtwiz_versal_1.xci] }
        200g4   { return [list dcmac_0_gtwiz_versal_0.xci dcmac_0_gtwiz_versal_1.xci] }
        400     { return [list dcmac_0_gtwiz_versal_0.xci] }
        default { error "nia_rate_ip_files: '$key' is not 200, 200g4 or 400" }
    }
}

proc nia_rate_ip_subdir {key} {
    switch -- $key {
        200     { return rate200 }
        200g4   { return rate200g4 }
        400     { return rate400 }
        default { error "nia_rate_ip_subdir: '$key' is not 200, 200g4 or 400" }
    }
}

proc nia_rate_dcmac_cfg {key} {
    if {$key eq "200g4"} {
        return [list \
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
    }
    set rate $key
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
    error "nia_rate_dcmac_cfg: '$key' is not 200, 200g4 or 400"
}

proc dcmac_create_ips_rate {key ip_src_dir rate_dir} {

    source $::nia_rate_ip_dir/dcmac_polarity.tcl

    set rate $key

    puts "NIA_RATE_IP BEGIN config=$key ip_src_dir=$ip_src_dir rate_dir=$rate_dir"

    foreach f [nia_rate_ip_files $key] {
        if {![file exists [file join $rate_dir $f]]} {
            error "dcmac_create_ips_rate: missing [file join $rate_dir $f]. The wizard XCIs of a\
                   configuration are generated products and this script does not invent them: a\
                   200GAUI-2 client is a 4-lane one-quad wizard at 106.25 Gb/s a lane, a 200GAUI-4\
                   client is the same 4-lane one-quad wizard at 53.125 Gb/s a lane, and a 400GAUI-4\
                   client is one 8-lane two-quad wizard at 106.25 Gb/s a lane. The 200GAUI-4 wizards\
                   differ from the 200GAUI-2 ones in INTF0_PRESET alone."
        }
    }
    if {![file exists [file join $ip_src_dir dcmac_0_clk_wiz_0.xci]]} {
        error "dcmac_create_ips_rate: missing [file join $ip_src_dir dcmac_0_clk_wiz_0.xci]. It is\
               rate independent - identical by md5 in the 100, 200 and 400 example designs - so\
               every rate reads the one in ip/."
    }

    create_ip -name dcmac -vendor xilinx.com -library ip -version 3.1 -module_name dcmac_0
    set_property -dict [nia_rate_dcmac_cfg $key] [get_ips dcmac_0]

    foreach f [nia_rate_ip_files $key] {
        import_ip -quiet [file join $rate_dir $f]
        puts "NIA_RATE_IP IMPORT [file join $rate_dir $f]"
    }
    import_ip -quiet [file join $ip_src_dir dcmac_0_clk_wiz_0.xci]
    puts "NIA_RATE_IP IMPORT [file join $ip_src_dir dcmac_0_clk_wiz_0.xci] (rate independent)"

    # The host stream clock. 250 is what every rate has shipped with; 391 is what AMD's
    # converter runs the stream side at in its 200G and 400G configurations, and it is the
    # only frequency at which a 1024 bit stream carries the 200G frame rate. The reference
    # clock is 156.25 MHz, so 390.625 is the achievable neighbour of 391.
    set nia_usr_mhz [expr {[info exists ::env(NIA_USR_MHZ)] ? $::env(NIA_USR_MHZ) : 250}]
    switch -- $nia_usr_mhz {
        250     { set nia_usr_freq 250.000 }
        391     { set nia_usr_freq 390.625 }
        default {
            puts "NIA_RATE_IP FAIL: NIA_USR_MHZ=$nia_usr_mhz is not one of 250, 391"
            exit 2
        }
    }
    puts "NIA_RATE_IP NET_CLK_MHZ $nia_usr_mhz requested $nia_usr_freq, register plane 250.000"
    create_ip -name clk_wizard -vendor xilinx.com -library ip -version 1.0 \
              -module_name dcmac_usr_clk_wiz
    # clk_out1 is the register plane: the host bridge, the AXI-Lite fabric, the control plane
    # and the DCMAC's own s_axi. It stays at 250 MHz because the DCMAC hard block's APB3_CLK
    # requires 3.333 ns, measured as a pulse width and minimum period violation of -0.773 ns
    # when it was driven at 390.625 MHz. clk_out3 is the datapath, and it is the one the rate
    # selects. clk_out2 is the transceiver free running clock.
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

    nia_dp_pol_enable_ports

    foreach {k v} [nia_rate_dcmac_cfg $key] {
        set cfg_name [string range $k 7 end]
        puts "NIA_IPCHK dcmac_0 CONFIG.$cfg_name = [get_property CONFIG.$cfg_name [get_ips dcmac_0]]\
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

    set want_wiz  $::nia_dp_pol_rate_wiz($key)
    set want_lane $::nia_dp_pol_rate_lane($key)
    set want_quad [nia_dp_pol_banks_per_wiz $key]
    set want_preset [expr {$key eq "200g4" ? "GTM-PAM4_Ethernet_53G" : "GTM-PAM4_Ethernet_106G"}]
    set gtwiz [nia_dp_gtwiz_ips]
    puts "NIA_RATE_GTWIZ ip_count=[llength $gtwiz] (want $want_wiz at config $key)"
    puts "NIA_RATE_GTWIZ ips=$gtwiz"
    if {[llength $gtwiz] != $want_wiz} {
        error "expected $want_wiz gtwiz IP(s) at config $key, found [llength $gtwiz]: '$gtwiz'. At\
               200GAUI-2 and at 200GAUI-4 there is one per cage, because one wizard cannot reach two\
               QSFP cages; at 400GAUI-4 there is exactly one, covering the two quads of QSFP0."
    }
    foreach ip $gtwiz {
        set l "<unreadable>"
        set q "<unreadable>"
        set r "<unreadable>"
        catch { set l [get_property CONFIG.INTF0_NO_OF_LANES [get_ips $ip]] }
        catch { set q [get_property CONFIG.NO_OF_QUADS [get_ips $ip]] }
        catch { set r [get_property CONFIG.INTF0_PRESET [get_ips $ip]] }
        puts "NIA_RATE_GTWIZ $ip INTF0_NO_OF_LANES = $l NO_OF_QUADS = $q INTF0_PRESET = $r  (want\
              $want_lane lanes, $want_quad quad(s), $want_preset)"
        if {$l ne "$want_lane"} {
            error "$ip has INTF0_NO_OF_LANES = $l, but config $key needs $want_lane: a 200GAUI-2\
                   and a 200GAUI-4 client are each 4 GT channels on one quad, and a 400GAUI-4 client\
                   is 8 across two quads. The PHY of this configuration connects\
                   INTF0_TX0..TX[expr {$want_lane - 1}] and their polarity, so a mismatch here is\
                   either a dangling connection or lanes left at polarity 0."
        }
        if {$q ne "$want_quad"} {
            error "$ip has NO_OF_QUADS = $q, but config $key needs $want_quad. A cage is served by\
                   one quad at 100GAUI-1, 200GAUI-2 and 200GAUI-4, and by two at 400GAUI-4, and the\
                   PHY drives a QUAD0 group for each quad it expects. PG369 page 201 states that a\
                   3x200GE 200GAUI-4 configuration requires three GTM quads."
        }
        if {$r ne "$want_preset"} {
            error "$ip has INTF0_PRESET = $r, but config $key needs $want_preset. The lane rate is\
                   106.25 Gb/s where a 200G port has two lanes and a 400G port has four, and\
                   53.125 Gb/s where a 200G port has four. A wizard built for the wrong lane rate\
                   divides the reference clock differently and never reaches CDR lock."
        }
        # The preset is a label. The rate the quad is built from is INTF0_LR0_SETTINGS, and a
        # wizard whose label was changed without the settings being re-derived carries the old
        # rate under the new name: that is what ip/rate200g4 held before 2026-09-11, 106.25 Gb/s
        # with a 53G label, and it is why this reads the settings and not only the label.
        set want_rate [expr {$key eq "200g4" ? "53.125" : "106.25"}]
        set lr "<unreadable>"
        catch { set lr [get_property CONFIG.INTF0_LR0_SETTINGS [get_ips $ip]] }
        foreach field {TX_LINE_RATE RX_LINE_RATE} {
            if {![regexp "(^|\\s)$field\\s+(\\S+)" $lr -> _ got]} {
                error "$ip carries no $field in INTF0_LR0_SETTINGS, so its lane rate cannot be\
                       verified. The settings read: [string range $lr 0 200]"
            }
            if {$got ne $want_rate} {
                error "$ip has $field = $got in INTF0_LR0_SETTINGS where config $key needs\
                       $want_rate, whatever INTF0_PRESET says. Regenerate the wizard for this\
                       configuration rather than renaming its preset."
            }
            puts "NIA_RATE_GTWIZ $ip $field = $got  (want $want_rate)"
        }
        # The reference clock this board carries is 156.25 MHz on REFCLK0 of banks 202, 203, 204
        # and 205, from CLK_BUF1, and the DCMAC IP reads GT_REF_CLK_FREQ_C0 156.25 with it. A
        # wizard configured for another frequency divides the clock it is given for a rate it is
        # not given: AMD's GTM-PAM4_Ethernet_53G preset carries 161.1328125 MHz, and a wizard left
        # at that value ran the lanes at 51.5152 Gb/s and the port at 193.94 Gb/s, which is
        # 156.25 / 161.1328125 of the asked rate. Both ends of a loopback share the error, so the
        # defect passes a byte exactness test and shows only in the rate table and in an unreliable
        # bring-up. Plan Section 11.37.25.
        foreach field {TX_REFCLK_FREQUENCY RX_REFCLK_FREQUENCY} {
            if {![regexp "(^|\\s)$field\\s+(\\S+)" $lr -> _ got]} {
                error "$ip carries no $field in INTF0_LR0_SETTINGS, so the reference clock it was\
                       built for cannot be verified. The settings read: [string range $lr 0 200]"
            }
            if {$got ne "156.25"} {
                error "$ip has $field = $got in INTF0_LR0_SETTINGS where this board carries 156.25\
                       MHz. Regenerate the wizard with the board reference clock: the LCPLL is\
                       programmed from this number, so a wizard built for 161.1328125 MHz runs\
                       every lane at 156.25/161.1328125 of the rate asked for."
            }
            puts "NIA_RATE_GTWIZ $ip $field = $got  (want 156.25)"
        }
    }

    nia_dp_preflight_polarity_or_die $key

    puts "NIA_IPLIST = [get_ips]"
    puts "NIA_RATE_IP END config=$key"
}
