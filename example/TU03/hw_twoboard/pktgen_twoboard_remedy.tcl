# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views

set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir pktgen_twoboard_lib.tcl]

set cycle_index   [expr {[info exists ::env(NIA_CYCLE)]       ? $::env(NIA_CYCLE)       : 0}]
set csv_path      [expr {[info exists ::env(NIA_CSV)]         ? $::env(NIA_CSV)         : ""}]
set first_wait_ms [expr {[info exists ::env(NIA_FIRSTCHK_MS)] ? $::env(NIA_FIRSTCHK_MS) : 12000}]
set step_wait_ms  [expr {[info exists ::env(NIA_STEP_MS)]     ? $::env(NIA_STEP_MS)     : 6000}]

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

proc down_boards {expected_mask} {
  set list {}
  foreach board [board_list] {
    array set state [link_state $board]
    if {($state(up) & $expected_mask) != $expected_mask
     || ![link_aligned_matches $board $expected_mask]} { lappend list $board }
  }
  return $list
}

proc down_cages {board expected_mask} {
  array set state [link_state $board]
  set list {}
  foreach cage [cage_list] {
    if {(($state(up) >> $cage) & 1) == 0} { lappend list $cage }
  }
  return $list
}

proc try_remedy {name mask_bits expected_mask wait_ms} {
  foreach board [down_boards $expected_mask] {
    set word 0
    foreach cage [down_cages $board $expected_mask] {
      set word [expr {$word | [lindex $mask_bits $cage]}]
    }
    puts [format "REMEDY %s board %s writes CMD_CTL 0x%02X" $name $board $word]
    board_write $board [expr {$::WINDOW_COMMAND + $::CMD_CTL}] $word
    after 200
    board_write $board [expr {$::WINDOW_COMMAND + $::CMD_CTL}] 0
  }
  set ms [wait_ready $expected_mask $wait_ms]
  puts "REMEDY $name RESULT [expr {$ms >= 0 ? "UP" : "DOWN"}] $ms ms"
  return $ms
}

connect_both_boards
calibrate_register_radix
identify_instrument

set expected_mask [link_up_mask]
set first_ms [wait_ready $expected_mask $first_wait_ms]
array set state_a [link_state A]
array set state_b [link_state B]

set row [list $cycle_index [clock format [clock seconds] -format %Y-%m-%dT%H:%M:%S] \
              [expr {$first_ms >= 0 ? "UP" : "DOWN"}] \
              [format "0x%X/0x%X" $state_a(up) $state_a(aligned)] \
              [format "0x%X/0x%X" $state_b(up) $state_b(aligned)] $first_ms]

if {$first_ms < 0} {
  set resync_ms [try_remedy resync \
                 [list $::CMD_BIT_RESYNC_GROUP0 $::CMD_BIT_RESYNC_GROUP1] \
                 $expected_mask $step_wait_ms]
  lappend row [expr {$resync_ms >= 0 ? "UP" : "DOWN"}] $resync_ms
  if {$resync_ms < 0} {
    set rxdp_ms [try_remedy rxdp \
                 [list $::CMD_BIT_RXDPRST_GROUP0 $::CMD_BIT_RXDPRST_GROUP1] \
                 $expected_mask $step_wait_ms]
    lappend row [expr {$rxdp_ms >= 0 ? "UP" : "DOWN"}] $rxdp_ms
    if {$rxdp_ms < 0} {
      set txdp_ms [try_remedy txdp \
                   [list $::CMD_BIT_TXDPRST_GROUP0 $::CMD_BIT_TXDPRST_GROUP1] \
                   $expected_mask $step_wait_ms]
      lappend row [expr {$txdp_ms >= 0 ? "UP" : "DOWN"}] $txdp_ms
      if {$txdp_ms < 0} {
        foreach board [down_boards $expected_mask] { link_restart $board }
        set restart_ms [wait_ready $expected_mask 12000]
        puts "REMEDY restart RESULT [expr {$restart_ms >= 0 ? "UP" : "DOWN"}] $restart_ms ms"
        lappend row [expr {$restart_ms >= 0 ? "UP" : "DOWN"}] $restart_ms
      }
    }
  }
}

if {$csv_path ne ""} {
  set handle [open $csv_path a]
  puts $handle [join $row ","]
  close $handle
}
puts "DIAG2 $cycle_index DONE"
exit 0
