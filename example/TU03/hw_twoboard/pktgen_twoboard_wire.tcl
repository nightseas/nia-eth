# ---------------------------------------------------------------------------
# File        : pktgen_twoboard_wire.tcl
# Description : The two board wire test. Requires the links to be up, discards one warm-up
#               burst, asserts each cage's transmit counts against the same cage on the
#               far board, and times one burst per size for the rate table.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir pktgen_twoboard_lib.tcl]

set steps            [expr {[info exists ::env(NIA_STEPS)]    ? $::env(NIA_STEPS)    : "1 2 3 4"}]
set rate_lengths     [expr {[info exists ::env(NIA_SIZES)]    ? $::env(NIA_SIZES)    : "64 65 128 256 512 1024 1518"}]
set equality_lengths [expr {[info exists ::env(NIA_EQ_SIZES)] ? $::env(NIA_EQ_SIZES) : "64 1518"}]
set equality_bytes   [expr {[info exists ::env(NIA_EQ_BYTES)] ? $::env(NIA_EQ_BYTES) : 3000000000}]
set rate_seconds     [expr {[info exists ::env(NIA_RATE_S)]   ? $::env(NIA_RATE_S)   : 3.0}]
set burst_tmo_ms     [expr {[info exists ::env(NIA_BURST_MS)] ? $::env(NIA_BURST_MS) : 30000}]
set warmup_bytes     [expr {[info exists ::env(NIA_WARMUP_BYTES)] ? $::env(NIA_WARMUP_BYTES) : 100000000}]

set FRAME_LENGTH_FIXED 0

connect_both_boards
calibrate_register_radix
identify_instrument
calibrate_read_latency
puts "TWOBOARD STEPS $steps"

proc all_generators {} {
  set generators {}
  foreach board [board_list] {
    foreach cage [cage_list] { lappend generators [list $board $cage] }
  }
  return $generators
}

proc run_burst {length mode frame_limit poll_without_sleep timeout_ms} {
  set generators [all_generators]

  foreach generator $generators {
    lassign $generator board cage
    generator_configure $board $cage $length $mode $frame_limit
  }
  foreach generator $generators {
    lassign $generator board cage
    generator_clear_counters $board $cage
  }

  array set enable_us {}
  foreach generator $generators {
    lassign $generator board cage
    generator_enable $board $cage
    set enable_us($board,$cage) [microseconds_now]
  }
  set first_enable_us [microseconds_now]

  array set done_us {}
  set outstanding [llength $generators]
  set poll_start_us [microseconds_now]
  while {$outstanding > 0} {
    foreach generator $generators {
      lassign $generator board cage
      if {[info exists done_us($board,$cage)]} { continue }
      if {[generator_is_done $board $cage]} {
        set done_us($board,$cage) [microseconds_now]
        incr outstanding -1
      }
    }
    if {([microseconds_now] - $poll_start_us) / 1000 > $timeout_ms} { break }
    if {!$poll_without_sleep} { after 20 }
  }

  array set result {}
  set result(timed_out) [expr {$outstanding > 0}]
  set result(enable_skew_us) [expr {[microseconds_now] - $first_enable_us}]
  foreach generator $generators {
    lassign $generator board cage
    array set counters [generator_counters $board $cage]
    foreach field {tx_frames tx_bytes rx_frames rx_bytes rx_err_frames mismatch status rounds
                   stall_cycle} {
      set result($board,$cage,$field) $counters($field)
    }
    if {[info exists done_us($board,$cage)]} {
      set result($board,$cage,elapsed_us) [expr {$done_us($board,$cage) - $enable_us($board,$cage)}]
    } else {
      set result($board,$cage,elapsed_us) 0
    }
  }
  return [array get result]
}

if {[lsearch $steps 1] >= 0} {
  set expected_mask [link_up_mask]
  set passed 1
  set reason "every carrier up and aligned on both boards"
  foreach board [board_list] {
    array set state [link_state $board]
    set aligned_text [expr {$state(aligned) < 0 \
                            ? "aligned not-published" \
                            : [format "aligned 0x%X" $state(aligned)]}]
    puts [format "STEP 1 board %s up 0x%X %s link_fault %d seq_state %d seq_pc %d retry %d" \
          $board $state(up) $aligned_text $state(link_fault) $state(seq_state) $state(seq_pc) \
          $state(retry)]
    if {($state(up) & $expected_mask) != $expected_mask
     || ![link_aligned_matches $board $expected_mask]} {
      set passed 0
      set reason "board $board is not fully up: up 0x[format %X $state(up)] $aligned_text\
 against 0x[format %X $expected_mask]. Run\
 pktgen_twoboard_link.tcl, which brings the link up and names the polarity suspects. This script does\
 not bring a link up, because the first burst after a bring-up is dirty and a test that hides that in\
 its own preamble cannot report it."
    }
  }
  require_step 1 $passed $reason
  report_step 1 $passed $reason
}

if {[lsearch $steps 2] >= 0} {
  set length 64
  set frame_limit [expr {int($warmup_bytes / $length)}]
  array set result [run_burst $length $FRAME_LENGTH_FIXED $frame_limit 0 $burst_tmo_ms]
  set dirty 0
  foreach board [board_list] {
    foreach cage [cage_list] {
      set peer [far_board $board]
      set sent     $result($board,$cage,tx_frames)
      set received $result($peer,$cage,rx_frames)
      set mismatch $result($peer,$cage,mismatch)
      puts "STEP 2 warm-up cage $cage ([cage_label $cage]) $board to $peer sent $sent received\
 $received mismatch_beats $mismatch"
      if {$received != $sent || $mismatch != 0} { set dirty 1 }
    }
  }
  if {$dirty} {
    puts "STEP 2 the warm-up burst is DIRTY, which is the documented behaviour of the first burst after\
 a link event. It is discarded and is not counted as a failure."
  } else {
    puts "STEP 2 the warm-up burst is already byte exact, which is worth recording: on the one board\
 bench the first burst after a link event was dirty in three of five cable events."
  }
  report_step 2 1 "one burst discarded, dirty=$dirty"
}

if {[lsearch $steps 3] >= 0} {
  set passed 1
  set reason "every cage byte exact in both directions"
  foreach length $equality_lengths {
    set frame_limit [expr {int($equality_bytes / $length)}]
    array set result [run_burst $length $FRAME_LENGTH_FIXED $frame_limit 0 $burst_tmo_ms]
    if {$result(timed_out)} {
      set passed 0
      set reason "a burst at $length B did not finish inside $burst_tmo_ms ms"
      puts "STEP 3 len $length TIMEOUT"
      continue
    }
    foreach board [board_list] {
      foreach cage [cage_list] {
        set peer [far_board $board]
        set tx_frames  $result($board,$cage,tx_frames)
        set tx_bytes   $result($board,$cage,tx_bytes)
        set rx_frames  $result($peer,$cage,rx_frames)
        set rx_bytes   $result($peer,$cage,rx_bytes)
        set err_frames $result($peer,$cage,rx_err_frames)
        set mismatch   $result($peer,$cage,mismatch)
        set exact [expr {$tx_frames == $rx_frames && $tx_bytes == $rx_bytes
                      && $err_frames == 0 && $mismatch == 0}]
        set verdict [expr {$exact ? "EXACT" : "MISMATCH"}]
        puts [format "STEP 3 len %4d cage %d (%s) %s to %s tx %d frames %d bytes rx %d frames %d bytes err_frames %d mismatch_beats %d %s" \
              $length $cage [cage_label $cage] $board $peer $tx_frames $tx_bytes $rx_frames $rx_bytes \
              $err_frames $mismatch $verdict]
        if {!$exact} {
          set passed 0
          set reason "cage $cage $board to $peer at $length B sent $tx_frames frames and $tx_bytes\
 bytes against $rx_frames and $rx_bytes received, err_frames $err_frames, mismatch_beats $mismatch"
        }
      }
    }
  }
  report_step 3 $passed $reason
}

if {[lsearch $steps 4] >= 0} {
  set passed 1
  set reason "the rate table filled at every size"
  puts "TWOBOARD RATE TABLE length cage direction frames_per_s wire_Gbps line_frames_per_s\
 percent_of_line window_ms"
  foreach length $rate_lengths {
    set line_fps [line_rate_frames_per_s $length]
    set frame_limit [expr {int($line_fps * $rate_seconds)}]
    if {$frame_limit > 3500000000} { set frame_limit 3500000000 }
    if {$frame_limit < 1000}       { set frame_limit 1000 }
    array set result [run_burst $length $FRAME_LENGTH_FIXED $frame_limit 1 $burst_tmo_ms]
    if {$result(timed_out)} {
      set passed 0
      set reason "the rate burst at $length B did not finish inside $burst_tmo_ms ms"
      puts "STEP 4 len $length TIMEOUT"
      continue
    }
    foreach board [board_list] {
      foreach cage [cage_list] {
        set peer [far_board $board]
        set tx_frames  $result($board,$cage,tx_frames)
        set elapsed_us $result($board,$cage,elapsed_us)
        if {$elapsed_us <= 0} {
          set passed 0
          set reason "no timed interval was recorded for board $board client $cage at $length B"
          continue
        }
        set frames_per_s [expr {$tx_frames * 1.0e6 / $elapsed_us}]
        set wire_gbps [expr {$frames_per_s * [wire_slot_bytes $length] * 8.0 / 1.0e9}]
        set percent_of_line [expr {100.0 * $frames_per_s / $line_fps}]
        puts [format "STEP 4 TABLE %4d %d %s->%s %.0f %.2f %.0f %.2f %.1f" \
              $length $cage $board $peer $frames_per_s $wire_gbps $line_fps $percent_of_line \
              [expr {$elapsed_us / 1000.0}]]
        if {$result($peer,$cage,mismatch) != 0 || $result($peer,$cage,rx_err_frames) != 0} {
          puts "STEP 4 NOTE len $length cage $cage $board to $peer carried errors, mismatch_beats\
 $result($peer,$cage,mismatch) err_frames $result($peer,$cage,rx_err_frames), so the row above is not\
 a clean rate"
        }
      }
    }
    puts [format "STEP 4 len %4d enable skew across %d generators %.1f ms" \
          $length [expr {2 * $::twoboard_client_count}] \
          [expr {$result(enable_skew_us) / 1000.0}]]
  }
  report_step 4 $passed $reason
}

report_summary "TWOBOARD WIRE"
