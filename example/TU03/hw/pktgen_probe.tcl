# ---------------------------------------------------------------------------
# File        : pktgen_probe.tcl
# Description : Runs the traffic source on one cage. Checks the identity and the map
#               revision, configures the length and the frame limit from the environment,
#               enables the generator and polls the counters.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set base    [expr {[info exists env(NIA_WINDOW)] ? $env(NIA_WINDOW) : 0xA4000000}]
set frames  [expr {[info exists env(NIA_FRAMES)] ? $env(NIA_FRAMES) : 1000}]
set len_min [expr {[info exists env(NIA_LEN_MIN)] ? $env(NIA_LEN_MIN) : 60}]
set len_max [expr {[info exists env(NIA_LEN_MAX)] ? $env(NIA_LEN_MAX) : 60}]
set mode    [expr {[info exists env(NIA_LEN_MODE)] ? $env(NIA_LEN_MODE) : 0}]
set polls   [expr {[info exists env(NIA_POLLS)] ? $env(NIA_POLLS) : 20}]

set PG  [expr {[info exists env(NIA_PG)] ? $env(NIA_PG) : $base + 0x0000}]
set CMD [expr {[info exists env(NIA_CMD)] ? $env(NIA_CMD) : $base + 0x1000}]

set MODULE_TYPE_EXPECT 4e535047
set MAP_VERSION_MAJOR  3

set R_MODULE_TYPE         0x00
set R_MAP_VERSION         0x04
set R_BUS_CHECK           0x08
set R_SEG_GEOMETRY        0x0C
set R_FEATURES            0x10
set R_CTL                 0x14
set R_STATUS              0x18
set R_LEN_MIN             0x1C
set R_LEN_MAX             0x20
set R_LEN_MODE            0x24
set R_LEN_EFFECTIVE       0x28
set R_LEN_CLAMP_STICKY    0x2C
set R_TX_FRAME_LIMIT      0x30
set R_SNAPSHOT_ROUNDS     0x34
set R_TX_FRAMES           0x40
set R_TX_BYTES            0x44
set R_RX_FRAMES           0x48
set R_RX_BYTES            0x4C
set R_RX_ERR_FRAMES       0x50
set R_RX_MISMATCH_BEATS   0x54
set R_STALL_CYCLE         0x58
set R_LATCHED_TX_FRAMES   0x60
set R_LATCHED_TX_BYTES    0x64
set R_LATCHED_RX_FRAMES   0x68
set R_LATCHED_RX_BYTES    0x6C
set R_LATCHED_RX_MISMATCH 0x70

set CTL_ENABLE 0x1
set CTL_CLEAR  0x2

set C_STATUS    0x08
set C_SEQ       0x0C
set C_RXPHY     0x10
set C_FSM       0x1C

proc rd {addr} { return [lindex [mrd -force -value $addr 1] 0] }
proc wr {addr value} { mwr -force $addr $value }

connect
set dpc [targets -filter {name =~ "DPC"}]
if {[llength $dpc] == 0} {
  puts "PROBE FAIL: no DPC target. The register window is reached through the processing system's debug port, so the image must carry the host bridge and the board must be programmed."
  exit 2
}
targets -set -filter {name =~ "DPC"}

set module_type [rd [expr {$PG + $R_MODULE_TYPE}]]
puts "PKTGEN MODULE_TYPE $module_type"
if {$module_type ne $MODULE_TYPE_EXPECT} {
  puts "PROBE FAIL: the generator window does not answer with $MODULE_TYPE_EXPECT at [format 0x%08x $PG]"
  exit 2
}

set map_version [rd [expr {$PG + $R_MAP_VERSION}]]
set major [expr {("0x$map_version" >> 16) & 0xFFFF}]
puts "PKTGEN MAP_VERSION $map_version major $major"
if {$major != $MAP_VERSION_MAJOR} {
  puts "PROBE FAIL: the register map major revision is $major and this script reads $MAP_VERSION_MAJOR"
  exit 2
}

puts "PKTGEN SEG_GEOMETRY [rd [expr {$PG + $R_SEG_GEOMETRY}]]  FEATURES [rd [expr {$PG + $R_FEATURES}]]"

wr [expr {$PG + $R_BUS_CHECK}] 0xA5A51234
set back [rd [expr {$PG + $R_BUS_CHECK}]]
puts "PKTGEN BUS_CHECK $back"
if {$back ne "a5a51234"} {
  puts "PROBE FAIL: BUS_CHECK does not return a written value"
  exit 2
}

puts "LINK STATUS [rd [expr {$CMD + $C_STATUS}]]  SEQ [rd [expr {$CMD + $C_SEQ}]]  RXPHY [rd [expr {$CMD + $C_RXPHY}]]  FSM [rd [expr {$CMD + $C_FSM}]]"

wr [expr {$PG + $R_CTL}] $CTL_CLEAR
wr [expr {$PG + $R_CTL}] 0x0
wr [expr {$PG + $R_LEN_MIN}] $len_min
wr [expr {$PG + $R_LEN_MAX}] $len_max
wr [expr {$PG + $R_LEN_MODE}] $mode
wr [expr {$PG + $R_TX_FRAME_LIMIT}] $frames
puts "PKTGEN LEN_EFFECTIVE [rd [expr {$PG + $R_LEN_EFFECTIVE}]]  CLAMPED [rd [expr {$PG + $R_LEN_CLAMP_STICKY}]]"
wr [expr {$PG + $R_CTL}] $CTL_ENABLE

for {set i 0} {$i < $polls} {incr i} {
  after 200
  puts [format "poll %2d  status %s  tx %s/%s  rx %s/%s  err %s  mismatch %s  stall %s  rounds %s" \
    $i [rd [expr {$PG + $R_STATUS}]] \
    [rd [expr {$PG + $R_TX_FRAMES}]] [rd [expr {$PG + $R_TX_BYTES}]] \
    [rd [expr {$PG + $R_RX_FRAMES}]] [rd [expr {$PG + $R_RX_BYTES}]] \
    [rd [expr {$PG + $R_RX_ERR_FRAMES}]] [rd [expr {$PG + $R_RX_MISMATCH_BEATS}]] \
    [rd [expr {$PG + $R_STALL_CYCLE}]] [rd [expr {$PG + $R_SNAPSHOT_ROUNDS}]]]
}

wr [expr {$PG + $R_CTL}] 0x0
wr [expr {$PG + $R_CTL}] $CTL_CLEAR
after 50
puts "PKTGEN LATCHED tx [rd [expr {$PG + $R_LATCHED_TX_FRAMES}]]/[rd [expr {$PG + $R_LATCHED_TX_BYTES}]] rx [rd [expr {$PG + $R_LATCHED_RX_FRAMES}]]/[rd [expr {$PG + $R_LATCHED_RX_BYTES}]] mismatch [rd [expr {$PG + $R_LATCHED_RX_MISMATCH}]]"
puts "PROBE DONE tx [rd [expr {$PG + $R_TX_FRAMES}]] rx [rd [expr {$PG + $R_RX_FRAMES}]] mismatch [rd [expr {$PG + $R_RX_MISMATCH_BEATS}]] err [rd [expr {$PG + $R_RX_ERR_FRAMES}]]"
