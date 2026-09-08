# ---------------------------------------------------------------------------
# File        : dcmac_gtwiz_200g4.tcl
# Description : Generates the two transceiver wizard XCIs of the dual 200GAUI-4
#               configuration. Each wizard covers the two GTM quads of one QSFP112 cage,
#               eight channels, at the 53.125 Gb/s per lane a four lane 200G port runs at.
#               The wizards harvested from the other rates are 106.25 Gb/s per lane, so the
#               two quad 400GAUI-4 wizard supplies the quad and lane mapping and this
#               recipe changes the line rate preset on it.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set nia_g4_root [file normalize [file join [file dirname [info script]] ..]]
set nia_g4_part [expr {[info exists env(NIA_PART)] ? $env(NIA_PART) : "xcvp1552-vsva2785-2MHP-i-S"}]
set nia_g4_out  [expr {[info exists env(NIA_GTWIZ_OUT)] ? $env(NIA_GTWIZ_OUT) : [pwd]}]
set nia_g4_work [file join $nia_g4_out work]
set nia_g4_seed [file join $nia_g4_root ip rate400 dcmac_0_gtwiz_versal_0.xci]

set nia_g4_preset GTM-PAM4_Ethernet_53G

if {![file exists $nia_g4_seed]} {
    puts "GTWIZ200G4 FAIL the two quad seed wizard $nia_g4_seed is absent"
    exit 2
}

file mkdir $nia_g4_out $nia_g4_work

puts "GTWIZ200G4 PART $nia_g4_part"
puts "GTWIZ200G4 SEED $nia_g4_seed"
puts "GTWIZ200G4 OUT $nia_g4_out"

create_project -force nia_gtwiz_200g4 $nia_g4_work -part $nia_g4_part
set_property target_language Verilog [current_project]
set_property ip_output_repo [file join $nia_g4_work repo] [current_project]

set nia_g4_report {GT_TYPE NO_OF_QUADS INTF0_NO_OF_LANES INTF0_PRESET INTF0_GT_SETTINGS
                   INTF0_OPTIONAL_PORTS INTF0_LANE_MAP QUAD0_PROT0_LANES QUAD1_PROT0_LANES
                   QUAD0_REFCLK_STRING QUAD1_REFCLK_STRING}

foreach nia_g4_name {dcmac_0_gtwiz_versal_0 dcmac_0_gtwiz_versal_1} {
    set nia_g4_stage [file join $nia_g4_work stage_$nia_g4_name]
    file mkdir $nia_g4_stage
    set nia_g4_copy [file join $nia_g4_stage ${nia_g4_name}.xci]
    set nia_g4_fh [open $nia_g4_seed r]
    set nia_g4_txt [read $nia_g4_fh]
    close $nia_g4_fh
    set nia_g4_txt [string map [list dcmac_0_gtwiz_versal_0 $nia_g4_name] $nia_g4_txt]
    set nia_g4_fh [open $nia_g4_copy w]
    puts -nonewline $nia_g4_fh $nia_g4_txt
    close $nia_g4_fh
    import_ip -quiet -name $nia_g4_name $nia_g4_copy
    set nia_g4_ip [get_ips $nia_g4_name]
    if {[llength $nia_g4_ip] != 1} {
        puts "GTWIZ200G4 FAIL import $nia_g4_name produced [llength $nia_g4_ip] IP"
        exit 2
    }
    puts "GTWIZ200G4 $nia_g4_name preset before = [get_property CONFIG.INTF0_PRESET $nia_g4_ip]"
    if {[get_property IS_LOCKED $nia_g4_ip]} {
        puts "GTWIZ200G4 $nia_g4_name is LOCKED, upgrading before the preset change"
        upgrade_ip $nia_g4_ip
    }
    if {[catch {set_property CONFIG.INTF0_PRESET $nia_g4_preset $nia_g4_ip} nia_g4_err]} {
        puts "GTWIZ200G4 FAIL preset $nia_g4_name: $nia_g4_err"
        exit 2
    }
    # The polarity ports are deliberately left as the seed carries them, which is without
    # ch_txpolarity and ch_rxpolarity. nia_dp_pol_enable_ports adds them and regenerates the
    # output products, and the polarity preflight then reads the port names out of those
    # products. A wizard that arrives with the ports already enabled skips that regeneration
    # and the preflight finds no sources to read the names from.
    foreach nia_g4_key $nia_g4_report {
        set nia_g4_val "<unreadable>"
        catch { set nia_g4_val [get_property CONFIG.$nia_g4_key $nia_g4_ip] }
        puts "GTWIZ200G4 $nia_g4_name CONFIG.$nia_g4_key = $nia_g4_val"
    }
    reset_target -quiet all $nia_g4_ip
    if {[catch {generate_target all $nia_g4_ip} nia_g4_err]} {
        puts "GTWIZ200G4 FAIL generate $nia_g4_name: $nia_g4_err"
        exit 2
    }
    set nia_g4_xci [get_property IP_FILE $nia_g4_ip]
    file copy -force $nia_g4_xci [file join $nia_g4_out ${nia_g4_name}.xci]
    puts "GTWIZ200G4 WROTE [file join $nia_g4_out ${nia_g4_name}.xci]"
}

puts "GTWIZ200G4 DONE"
