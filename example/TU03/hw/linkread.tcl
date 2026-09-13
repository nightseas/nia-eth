#!/usr/bin/env xsdb
# ---------------------------------------------------------------------------
# File        : linkread.tcl
# Description : Read only reading of the link state of both cages and of the per channel
#               transceiver reset done words. It writes no register, issues no restart and
#               programs nothing, so the state of a failed bring-up is preserved for probing.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set base [expr {[info exists env(NIA_WINDOW)] ? $env(NIA_WINDOW) : 0xA4000000}]
set CMD  [expr {[info exists env(NIA_CMD)] ? $env(NIA_CMD) : $base + 0x1000}]

set C_STATUS  0x08
set C_SEQ     0x0C
set C_RXPHY   0x10
set C_RETRY   0x14
set C_FSM     0x1C
set C_CHDONE0 0x40
set C_CHDONE1 0x44

set samples [expr {[info exists env(NIA_SAMPLES)] ? $env(NIA_SAMPLES) : 1}]
set gap_ms  [expr {[info exists env(NIA_SAMPLE_MS)] ? $env(NIA_SAMPLE_MS) : 200}]

connect
targets -set -filter {name =~ "DPC"}

proc rd {addr} {
    set v [lindex [mrd -force -value $addr 1] 0]
    return [expr {$v & 0xFFFFFFFF}]
}

for {set i 0} {$i < $samples} {incr i} {
    set st  [rd [expr {$CMD + $C_STATUS}]]
    set seq [rd [expr {$CMD + $C_SEQ}]]
    set up      [expr {$st & 0x3}]
    set aligned [expr {($st >> 5) & 0x3}]
    set fault   [expr {($st >> 2) & 0x1}]
    set afault  [expr {($st >> 3) & 0x1}]
    set busy    [expr {($st >> 4) & 0x1}]
    set rxphy [rd [expr {$CMD + $C_RXPHY}]]
    set retry [rd [expr {$CMD + $C_RETRY}]]
    set fsm   [rd [expr {$CMD + $C_FSM}]]
    set chd0  [rd [expr {$CMD + $C_CHDONE0}]]
    set chd1  [rd [expr {$CMD + $C_CHDONE1}]]
    puts "LINKREAD sample $i link_up $up aligned $aligned fault $fault access_fault $afault busy $busy seq_state [expr {$seq & 0x1F}] seq_pc [expr {($seq >> 5) & 0xFFFF}] retry $retry rxphy [format 0x%08X $rxphy] fsm [format 0x%02X $fsm] chdone0 [format 0x%04X $chd0] chdone1 [format 0x%04X $chd1]"
    foreach {cage word} [list 0 $chd0 1 $chd1] {
        set cage_up [expr {($up >> $cage) & 0x1}]
        set tx [expr {$word & 0xFF}]
        set rx [expr {($word >> 8) & 0xFF}]
        set state [expr {$cage_up ? "up" : "DOWN"}]
        puts "LINKREAD   cage $cage $state tx_done [format 0x%02X $tx] rx_done [format 0x%02X $rx] quad[expr {2 * $cage}]_rx [format 0x%X [expr {$rx & 0xF}]] quad[expr {2 * $cage + 1}]_rx [format 0x%X [expr {($rx >> 4) & 0xF}]]"
    }
    if {$up != 3} {
        set failed {}
        for {set c 0} {$c < 2} {incr c} {
            if {!(($up >> $c) & 0x1)} { lappend failed $c }
        }
        puts "LINKREAD FAILED_CAGE $failed"
    } else {
        puts "LINKREAD FAILED_CAGE none"
    }
    if {$i + 1 < $samples} { after $gap_ms }
}
