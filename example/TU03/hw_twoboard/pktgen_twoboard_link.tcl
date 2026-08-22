# ---------------------------------------------------------------------------
# File        : pktgen_twoboard_link.tcl
# Description : The first test to run on the two board bench and the one that brings the
#               link up. Three steps: every register window distinct, a bring-up restart
#               with every carrier up and held, and a quiet observation with no traffic
#               offered.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir pktgen_twoboard_lib.tcl]

set steps          [expr {[info exists ::env(NIA_STEPS)]      ? $::env(NIA_STEPS)      : "1 2 3"}]
set bringup_tmo_ms [expr {[info exists ::env(NIA_BRINGUP_MS)] ? $::env(NIA_BRINGUP_MS) : 8000}]
set settle_ms      [expr {[info exists ::env(NIA_SETTLE_MS)]  ? $::env(NIA_SETTLE_MS)  : 1500}]
set observe_ms     [expr {[info exists ::env(NIA_OBSERVE_MS)] ? $::env(NIA_OBSERVE_MS) : 5000}]

connect_both_boards
calibrate_register_radix
identify_instrument
calibrate_read_latency

set client1_note [expr {$::twoboard_client_count > 1 \
                        ? "client1 [format 0x%08X $::WINDOW_CLIENT1]" \
                        : "client1 absent, one client image"}]
puts "TWOBOARD WINDOWS client0 [format 0x%08X $::WINDOW_CLIENT0]\
 command [format 0x%08X $::WINDOW_COMMAND] $client1_note"
puts "TWOBOARD STEPS $steps"

proc print_link_state {tag board} {
  array set state [link_state $board]
  set aligned_text [expr {$state(aligned) < 0 \
                          ? "aligned not-published" \
                          : [format "aligned 0x%X" $state(aligned)]}]
  puts [format "%s board %s up 0x%X %s link_fault %d access_fault %d seq_busy %d seq_state %d seq_pc %d retry %d rx_phy 0x%08X mac_fsm 0x%02X" \
        $tag $board $state(up) $aligned_text $state(link_fault) $state(access_fault) \
        $state(seq_busy) $state(seq_state) $state(seq_pc) $state(retry) $state(rx_phy) \
        $state(mac_fsm)]
}

if {[lsearch $steps 1] >= 0} {
  set passed 1
  set reason "every instrument window answers and is a distinct instance"
  set written {}
  foreach board [board_list] {
    foreach cage [cage_list] {
      set window [client_window $cage]
      set pattern [expr {0x11110000 + ($cage << 8) + ($board eq "A" ? 1 : 2)}]
      board_write $board [expr {$window + $::REG_BUS_CHECK}] $pattern
      lappend written [list $board $cage $window $pattern]
    }
  }
  foreach entry $written {
    lassign $entry board cage window pattern
    set readback    [board_read $board [expr {$window + $::REG_BUS_CHECK}]]
    set module_type [board_read $board [expr {$window + $::REG_MODULE_TYPE}]]
    puts "STEP 1 board $board client $cage ([cage_label $cage])\
 MODULE_TYPE [format 0x%08X $module_type]\
 BUS_CHECK wrote [format 0x%08X $pattern] read [format 0x%08X $readback]"
    if {$readback != $pattern} {
      set passed 0
      set reason "board $board client $cage returned BUS_CHECK [format 0x%08X $readback] for\
 [format 0x%08X $pattern], so the windows alias or the aperture is not assigned"
    }
  }
  require_step 1 $passed $reason
  report_step 1 $passed $reason
}

if {[lsearch $steps 2] >= 0} {
  set expected_mask [link_up_mask]
  foreach board [board_list] { print_link_state "STEP 2 before" $board }

  foreach board [board_list] { link_restart $board }
  puts "STEP 2 bring-up restart issued to both boards, expecting up mask\
 0x[format %X $expected_mask] on each"

  set start_us [microseconds_now]
  set all_up_ms -1
  set held_ms -1
  set last_partial ""
  while {1} {
    set elapsed_ms [expr {([microseconds_now] - $start_us) / 1000}]
    array set state_a [link_state A]
    array set state_b [link_state B]
    set both_up [expr {($state_a(up) & $expected_mask) == $expected_mask
                    && ($state_b(up) & $expected_mask) == $expected_mask}]
    if {!$both_up} {
      set last_partial [format "A up 0x%X aligned %d, B up 0x%X aligned %d at %d ms" \
                        $state_a(up) $state_a(aligned) $state_b(up) $state_b(aligned) $elapsed_ms]
      set all_up_ms -1
    } elseif {$all_up_ms < 0} {
      set all_up_ms $elapsed_ms
      puts "STEP 2 every carrier up at $all_up_ms ms"
    } elseif {$elapsed_ms - $all_up_ms >= $settle_ms} {
      set held_ms $elapsed_ms
      break
    }
    if {$elapsed_ms > $bringup_tmo_ms} { break }
    after 100
  }

  foreach board [board_list] { print_link_state "STEP 2 after" $board }

  set passed [expr {$held_ms >= 0}]
  if {$passed} {
    set reason "both boards reached up 0x[format %X $expected_mask] at $all_up_ms ms and held it for\
 $settle_ms ms"
  } else {
    set reason "the carriers did not all come up and hold inside $bringup_tmo_ms ms. Last partial\
 state: $last_partial. On this bench the first suspect is the absolute lane polarity of the cage that\
 stayed down, bank 202 for QSFP0 and bank 204 for QSFP1, and bank 203 as well at 400GAUI-4 where no\
 100G or 200G port ever exercised it. The second suspect is a DAC in the wrong cage."
  }
  if {$passed} {
    foreach board [board_list] {
      if {![link_aligned_matches $board $expected_mask]} {
        array set state [link_state $board]
        set passed 0
        set reason "board $board reports carrier up but rx_pcs_aligned 0x[format %X $state(aligned)]\
 against the expected 0x[format %X $expected_mask], so the link state machine and the MAC disagree and\
 this is not a cable fault"
      }
    }
  }
  report_step 2 $passed $reason
}

if {[lsearch $steps 3] >= 0} {
  set expected_mask [link_up_mask]
  array set previous_signature {}
  set start_us [microseconds_now]
  set change_count 0
  set fault_samples 0
  set first_change ""
  while {([microseconds_now] - $start_us) / 1000 < $observe_ms} {
    foreach board [board_list] {
      array set state [link_state $board]
      set signature [format "up 0x%X aligned %d" $state(up) $state(aligned)]
      if {![info exists previous_signature($board)]} {
        set previous_signature($board) $signature
      }
      if {$previous_signature($board) ne $signature} {
        incr change_count
        if {$first_change eq ""} {
          set first_change "board $board went from $previous_signature($board) to $signature"
        }
        set previous_signature($board) $signature
      }
      if {$state(link_fault) || $state(access_fault)} { incr fault_samples }
    }
    after 250
  }
  set passed [expr {$change_count == 0 && $fault_samples == 0}]
  if {$passed} {
    set reason "no carrier or alignment change and no fault on either board over $observe_ms ms with\
 no traffic offered"
  } else {
    set reason "$change_count carrier or alignment change(s) and $fault_samples fault sample(s) over\
 $observe_ms ms with no traffic offered. First change: $first_change"
  }
  report_step 3 $passed $reason
}

report_summary "TWOBOARD LINK"
