# ---------------------------------------------------------------------------
# File        : probe_registers.tcl
# Description : One read only pass over one generator window and the command block: the
#               identity, the bus check, the counters, the round counter and the link
#               state.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set base [expr {[info exists env(NIA_WINDOW)] ? $env(NIA_WINDOW) : 0xA4000000}]

set PG  [expr {[info exists env(NIA_PG)] ? $env(NIA_PG) : $base + 0x0000}]
set CMD [expr {[info exists env(NIA_CMD)] ? $env(NIA_CMD) : $base + 0x1000}]

set R_MODULE_TYPE       0x00
set R_MAP_VERSION       0x04
set R_BUS_CHECK         0x08
set R_SEG_GEOMETRY      0x0C
set R_FEATURES          0x10
set R_STATUS            0x18
set R_TX_FRAMES         0x40
set R_TX_BYTES          0x44
set R_RX_FRAMES         0x48
set R_RX_BYTES          0x4C
set R_RX_ERR_FRAMES     0x50
set R_RX_MISMATCH_BEATS 0x54
set R_STALL_CYCLE       0x58
set R_SNAPSHOT_ROUNDS   0x34

set C_STATUS 0x08
set C_SEQ    0x0C
set C_RXPHY  0x10
set C_RETRY  0x14
set C_FSM    0x1C

proc rd {addr} { return [lindex [mrd -force -value $addr 1] 0] }
proc wr {addr value} { mwr -force $addr $value }

connect
set dpc [targets -filter {name =~ "DPC"}]
puts "HW DPC [llength $dpc]"
if {[llength $dpc] == 0} {
  puts "HW REGISTERS DONE"
  exit 0
}
targets -set -filter {name =~ "DPC"}

puts "HW REG MODULE_TYPE [rd [expr {$PG + $R_MODULE_TYPE}]]"
puts "HW REG MAP_VERSION [rd [expr {$PG + $R_MAP_VERSION}]]"
puts "HW REG SEG_GEOMETRY [rd [expr {$PG + $R_SEG_GEOMETRY}]]"
puts "HW REG FEATURES [rd [expr {$PG + $R_FEATURES}]]"
puts "HW REG STATUS [rd [expr {$PG + $R_STATUS}]]"

set pattern 0xA5A51234
wr [expr {$PG + $R_BUS_CHECK}] $pattern
set back_one [rd [expr {$PG + $R_BUS_CHECK}]]
wr [expr {$PG + $R_BUS_CHECK}] 0x5A5AEDCB
set back_two [rd [expr {$PG + $R_BUS_CHECK}]]
puts "HW REG BUS_CHECK first $back_one second $back_two"

puts "HW CMD STATUS [rd [expr {$CMD + $C_STATUS}]] SEQ [rd [expr {$CMD + $C_SEQ}]] RXPHY [rd [expr {$CMD + $C_RXPHY}]] RETRY [rd [expr {$CMD + $C_RETRY}]] FSM [rd [expr {$CMD + $C_FSM}]]"

puts "HW COUNTERS TX [rd [expr {$PG + $R_TX_FRAMES}]] [rd [expr {$PG + $R_TX_BYTES}]] RX [rd [expr {$PG + $R_RX_FRAMES}]] [rd [expr {$PG + $R_RX_BYTES}]] ERR [rd [expr {$PG + $R_RX_ERR_FRAMES}]] MISMATCH [rd [expr {$PG + $R_RX_MISMATCH_BEATS}]] STALL [rd [expr {$PG + $R_STALL_CYCLE}]]"

set rounds_first [rd [expr {$PG + $R_SNAPSHOT_ROUNDS}]]
after 200
set rounds_second [rd [expr {$PG + $R_SNAPSHOT_ROUNDS}]]
puts "HW SNAPSHOT ROUNDS first $rounds_first second $rounds_second"

puts "HW REGISTERS DONE"
