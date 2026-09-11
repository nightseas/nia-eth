# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views

set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir pktgen_twoboard_lib.tcl]

set stats_per [expr {[info exists ::env(NIA_STATS_PER)] ? $::env(NIA_STATS_PER) : 22}]
set settle_ms [expr {[info exists ::env(NIA_STATS_MS)]  ? $::env(NIA_STATS_MS)  : 500}]

set names [list \
  RX_PHY_RT_STATUS RX_PHY_STATUS RX_MAC_RT_STATUS RX_MODE TX_MODE \
  PCTL_RX PCTL_TX CHCTL_RX CHCTL_TX GLOBAL_MODE CONFIG_REV \
  FEC_CW FEC_CORR FEC_UNCORR TICK_RX TICK_TX \
  SRX_PKTS SRX_GPKTS STX_PKTS STX_GPKTS SRX_BYTES STX_BYTES]

connect_both_boards
calibrate_register_radix
identify_instrument

foreach board [board_list] {
  board_write $board [expr {$::WINDOW_COMMAND + $::CMD_CTL}] $::CMD_BIT_STATS
}
after $settle_ms
foreach board [board_list] {
  board_write $board [expr {$::WINDOW_COMMAND + $::CMD_CTL}] 0
}
after $settle_ms

foreach board [board_list] {
  set carrier_mask [expr {[board_read $board [expr {$::WINDOW_COMMAND + $::CMD_STATUS}]] & 0x3}]
  foreach cage [cage_list] {
    set carrier_up [expr {($carrier_mask >> $cage) & 1}]
    puts [format "STATS board %s cage %d carrier_up %d" $board $cage $carrier_up]
    set nonzero 0
    for {set k 0} {$k < $stats_per} {incr k} {
      set index [expr {$cage * $::twoboard_slots_per_cage * $stats_per + $k}]
      board_write $board [expr {$::WINDOW_COMMAND + $::CMD_STAT_IDX}] $index
      set value [board_read $board [expr {$::WINDOW_COMMAND + $::CMD_STAT_DATA}]]
      if {$value != 0} { incr nonzero }
      puts [format "STATS board %s cage %d idx %3d %-16s 0x%08X" \
            $board $cage $index [lindex $names $k] $value]
    }
    board_write $board [expr {$::WINDOW_COMMAND + $::CMD_STAT_IDX}] \
          [expr {$cage * $::twoboard_slots_per_cage * $stats_per}]
    set first [board_read $board [expr {$::WINDOW_COMMAND + $::CMD_STAT_DATA}]]
    set aligned [expr {($first & 0x5) == 0x5}]
    set agree [expr {$aligned == $carrier_up}]
    puts [format "STATS board %s cage %d nonzero %d of %d, index0 0x%08X aligned %d carrier_up %d agree %d" \
          $board $cage $nonzero $stats_per $first $aligned $carrier_up $agree]
  }
}
puts "STATS DONE"
exit 0
