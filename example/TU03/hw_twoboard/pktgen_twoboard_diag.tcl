# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views

set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir pktgen_twoboard_lib.tcl]

set cycle_index   [expr {[info exists ::env(NIA_CYCLE)]       ? $::env(NIA_CYCLE)       : 0}]
set csv_path      [expr {[info exists ::env(NIA_CSV)]         ? $::env(NIA_CSV)         : ""}]
set first_wait_ms [expr {[info exists ::env(NIA_FIRSTCHK_MS)] ? $::env(NIA_FIRSTCHK_MS) : 12000}]
set restart_wait_ms [expr {[info exists ::env(NIA_RESTART_MS)] ? $::env(NIA_RESTART_MS) : 10000}]
set restart_tries [expr {[info exists ::env(NIA_RESTART_N)]   ? $::env(NIA_RESTART_N)   : 3}]

proc wait_ready {expected_mask limit_ms} {
  set start_us [microseconds_now]
  while {1} {
    set elapsed_ms [expr {([microseconds_now] - $start_us) / 1000}]
    array set state_a [link_state A]
    array set state_b [link_state B]
    set ready [expr {($state_a(up) & $expected_mask) == $expected_mask
                  && ($state_b(up) & $expected_mask) == $expected_mask
                  && [link_aligned_matches A $expected_mask]
                  && [link_aligned_matches B $expected_mask]}]
    if {$ready} { return $elapsed_ms }
    if {$elapsed_ms > $limit_ms} { return -1 }
    after 100
  }
}

proc report_state {tag board} {
  array set state [link_state $board]
  puts [format "%s board %s status 0x%08X up 0x%X aligned 0x%X seq_state %d seq_pc %d retry %d mac_fsm 0x%02X rx_phy 0x%08X" \
        $tag $board $state(status) $state(up) $state(aligned) $state(seq_state) $state(seq_pc) \
        $state(retry) $state(mac_fsm) $state(rx_phy)]
  return [array get state]
}

connect_both_boards
calibrate_register_radix
identify_instrument

set expected_mask [link_up_mask]
set first_ms [wait_ready $expected_mask $first_wait_ms]

array set state_a [report_state "DIAG $cycle_index FIRST" A]
array set state_b [report_state "DIAG $cycle_index FIRST" B]

set row [list $cycle_index [clock format [clock seconds] -format %Y-%m-%dT%H:%M:%S] \
              [expr {$first_ms >= 0 ? "UP" : "DOWN"}] \
              [format "0x%X/0x%X" $state_a(up) $state_a(aligned)] \
              [format "0x%X/0x%X" $state_b(up) $state_b(aligned)] $first_ms]

if {$first_ms < 0} {
  for {set attempt 1} {$attempt <= $restart_tries} {incr attempt} {
    foreach board [board_list] {
      array set state [link_state $board]
      if {($state(up) & $expected_mask) != $expected_mask
       || ![link_aligned_matches $board $expected_mask]} {
        puts "DIAG $cycle_index RESTART $attempt issued to board $board"
        link_restart $board
      }
    }
    set again_ms [wait_ready $expected_mask $restart_wait_ms]
    array set state_a [report_state "DIAG $cycle_index AFTER$attempt" A]
    array set state_b [report_state "DIAG $cycle_index AFTER$attempt" B]
    lappend row [expr {$again_ms >= 0 ? "UP" : "DOWN"}] $again_ms
    puts "DIAG $cycle_index RESTART $attempt RESULT [expr {$again_ms >= 0 ? "UP" : "DOWN"}] $again_ms ms"
    if {$again_ms >= 0} { break }
  }
}

if {$csv_path ne ""} {
  set handle [open $csv_path a]
  puts $handle [join $row ","]
  close $handle
}
puts "DIAG $cycle_index DONE"
exit 0
