# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views

set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir pktgen_twoboard_lib.tcl]

set cycle_index   [expr {[info exists ::env(NIA_CYCLE)]      ? $::env(NIA_CYCLE)      : 0}]
set csv_path      [expr {[info exists ::env(NIA_CSV)]        ? $::env(NIA_CSV)        : ""}]
set first_wait_ms [expr {[info exists ::env(NIA_FIRSTCHK_MS)] ? $::env(NIA_FIRSTCHK_MS) : 12000}]
set equality_lengths [expr {[info exists ::env(NIA_EQ_SIZES)] ? $::env(NIA_EQ_SIZES) : "64 1518"}]
set equality_bytes   [expr {[info exists ::env(NIA_EQ_BYTES)] ? $::env(NIA_EQ_BYTES) : 1500000000}]
set warmup_bytes     [expr {[info exists ::env(NIA_WARMUP_BYTES)] ? $::env(NIA_WARMUP_BYTES) : 100000000}]
set burst_tmo_ms     [expr {[info exists ::env(NIA_BURST_MS)] ? $::env(NIA_BURST_MS) : 30000}]

set ::CMD_DIAG_FIRST 0x20
set ::CMD_DIAG_LAST  0x44
set ::CMD_ALIGN0     0x20
set ::ALIGN_LIVE_MASK 0x5

set FRAME_LENGTH_FIXED 0

proc diag_words {board} {
  set words {}
  for {set offset $::CMD_DIAG_FIRST} {$offset <= $::CMD_DIAG_LAST} {incr offset 4} {
    lappend words [board_read $board [expr {$::WINDOW_COMMAND + $offset}]]
  }
  return $words
}

proc align_word {board cage} {
  return [board_read $board [expr {$::WINDOW_COMMAND + $::CMD_ALIGN0 + 4*$cage}]]
}

proc align_word_ok {board} {
  set seen 0
  foreach cage [cage_list] {
    set word [align_word $board $cage]
    if {$word == 0} { continue }
    incr seen
    if {($word & $::ALIGN_LIVE_MASK) != $::ALIGN_LIVE_MASK} { return 0 }
  }
  if {$seen == 0} { return -1 }
  return 1
}

proc aligned_mask_effective {board} {
  array set state [link_state $board]
  if {$state(aligned) >= 0} { return $state(aligned) }
  set mask 0
  set seen 0
  foreach cage [cage_list] {
    set word [align_word $board $cage]
    if {$word == 0} { continue }
    incr seen
    if {($word & $::ALIGN_LIVE_MASK) == $::ALIGN_LIVE_MASK} { set mask [expr {$mask | (1 << $cage)}] }
  }
  if {$seen == 0} { return -1 }
  return $mask
}

proc board_ready {board expected_mask} {
  array set state [link_state $board]
  if {($state(up) & $expected_mask) != $expected_mask} { return 0 }
  set word_ok [align_word_ok $board]
  if {$word_ok == 0} { return 0 }
  if {$word_ok == 1} { return 1 }
  return [link_aligned_matches $board $expected_mask]
}

proc state_line {tag board} {
  array set state [link_state $board]
  set aligned_text [expr {$state(aligned) < 0 ? "not-published" : [format 0x%X $state(aligned)]}]
  set diag ""
  set offset $::CMD_DIAG_FIRST
  foreach word [diag_words $board] {
    append diag [format " d%02X 0x%08X" $offset $word]
    incr offset 4
  }
  puts [format "%s board %s status 0x%08X up 0x%X aligned %s link_fault %d access_fault %d seq_busy %d seq_state %d seq_pc %d retry %d rx_phy 0x%08X mac_fsm 0x%02X%s" \
        $tag $board $state(status) $state(up) $aligned_text $state(link_fault) \
        $state(access_fault) $state(seq_busy) $state(seq_state) $state(seq_pc) $state(retry) \
        $state(rx_phy) $state(mac_fsm) $diag]
  return [array get state]
}

proc signature {board} {
  array set state [link_state $board]
  return [format "%X/%X" $state(up) $state(aligned)]
}

proc all_generators {} {
  set generators {}
  foreach board [board_list] {
    foreach cage [cage_list] { lappend generators [list $board $cage] }
  }
  return $generators
}

proc run_burst {length frame_limit timeout_ms} {
  set generators [all_generators]
  foreach generator $generators {
    lassign $generator board cage
    generator_configure $board $cage $length $::FRAME_LENGTH_FIXED $frame_limit
  }
  foreach generator $generators {
    lassign $generator board cage
    generator_clear_counters $board $cage
  }
  foreach generator $generators {
    lassign $generator board cage
    generator_enable $board $cage
  }
  set outstanding [llength $generators]
  array set done {}
  set poll_start_us [microseconds_now]
  while {$outstanding > 0} {
    foreach generator $generators {
      lassign $generator board cage
      if {[info exists done($board,$cage)]} { continue }
      if {[generator_is_done $board $cage]} {
        set done($board,$cage) 1
        incr outstanding -1
      }
    }
    if {([microseconds_now] - $poll_start_us) / 1000 > $timeout_ms} { break }
    after 20
  }
  array set result {}
  set result(timed_out) [expr {$outstanding > 0}]
  foreach generator $generators {
    lassign $generator board cage
    array set counters [generator_counters $board $cage]
    foreach field {tx_frames tx_bytes rx_frames rx_bytes rx_err_frames mismatch status} {
      set result($board,$cage,$field) $counters($field)
    }
  }
  return [array get result]
}

proc emit_row {fields} {
  if {$::csv_path eq ""} { return }
  set handle [open $::csv_path a]
  puts $handle [join $fields ","]
  close $handle
}

proc finish {result detail} {
  set stamp [clock format [clock seconds] -format %Y-%m-%dT%H:%M:%S]
  emit_row [list $::cycle_index $stamp $result $::row_first_a $::row_first_b $::row_ms_to_up \
                 $::row_fault $::row_access $::row_retry $::row_transitions $::row_mismatch \
                 $::row_err_frames \"$detail\"]
  puts "CYCLE $::cycle_index RESULT $result $detail"
  if {$result eq "PASS"} { exit 0 }
  exit 1
}

set ::row_first_a "-"
set ::row_first_b "-"
set ::row_ms_to_up -1
set ::row_fault 0
set ::row_access 0
set ::row_retry 0
set ::row_transitions 0
set ::row_mismatch 0
set ::row_err_frames 0

connect_both_boards
calibrate_register_radix
identify_instrument

set expected_mask [link_up_mask]
set start_us [microseconds_now]
set both_ready 0
while {1} {
  set elapsed_ms [expr {([microseconds_now] - $start_us) / 1000}]
  array set state_a [link_state A]
  array set state_b [link_state B]
  set ready [expr {[board_ready A $expected_mask] && [board_ready B $expected_mask]}]
  if {$ready} {
    set both_ready 1
    set ::row_ms_to_up $elapsed_ms
    break
  }
  if {$elapsed_ms > $::first_wait_ms} { break }
  after 100
}

set ::row_first_a [format "0x%X/0x%X" $state_a(up) [aligned_mask_effective A]]
set ::row_first_b [format "0x%X/0x%X" $state_b(up) [aligned_mask_effective B]]
set ::row_fault [expr {$state_a(link_fault) || $state_b(link_fault)}]
set ::row_access [expr {$state_a(access_fault) || $state_b(access_fault)}]
set ::row_retry [expr {$state_a(retry) > $state_b(retry) ? $state_a(retry) : $state_b(retry)}]

foreach board [board_list] { state_line "CYCLE $cycle_index FIRST" $board }

if {!$both_ready} {
  foreach board [board_list] {
    foreach cage [cage_list] {
      set window [client_window $cage]
      puts [format "CYCLE %d CAPTURE board %s cage %d status 0x%08X rx_frames %d rx_err %d" \
            $cycle_index $board $cage \
            [board_read $board [expr {$window + $::REG_STATUS}]] \
            [board_read $board [expr {$window + $::REG_RX_FRAMES}]] \
            [board_read $board [expr {$window + $::REG_RX_ERR_FRAMES}]]]
    }
  }
  foreach board [board_list] {
    board_write $board [expr {$::WINDOW_COMMAND + $::CMD_CTL}] $::CMD_BIT_STATS
  }
  after 300
  foreach board [board_list] {
    board_write $board [expr {$::WINDOW_COMMAND + $::CMD_CTL}] 0
  }
  for {set index 0} {$index < 22} {incr index} {
    foreach board [board_list] {
      board_write $board [expr {$::WINDOW_COMMAND + $::CMD_STAT_IDX}] $index
      puts [format "CYCLE %d STAT board %s idx %d 0x%08X" $cycle_index $board $index \
            [board_read $board [expr {$::WINDOW_COMMAND + $::CMD_STAT_DATA}]]]
    }
  }
  finish FAIL "first link check did not reach up 0x[format %X $expected_mask] aligned 0x[format %X $expected_mask] inside ${first_wait_ms} ms"
}

array set before {}
foreach board [board_list] { set before($board) [signature $board] }

set warmup_limit [expr {int($warmup_bytes / 64)}]
array set warmup [run_burst 64 $warmup_limit $burst_tmo_ms]
set warmup_dirty 0
foreach board [board_list] {
  foreach cage [cage_list] {
    set peer [far_board $board]
    if {$warmup($peer,$cage,rx_frames) != $warmup($board,$cage,tx_frames)
     || $warmup($peer,$cage,mismatch) != 0} { set warmup_dirty 1 }
  }
}
puts "CYCLE $cycle_index WARMUP dirty=$warmup_dirty"

set traffic_ok 1
set traffic_detail "byte exact both directions on every cage at $equality_lengths"
foreach length $equality_lengths {
  set frame_limit [expr {int($equality_bytes / $length)}]
  array set result [run_burst $length $frame_limit $burst_tmo_ms]
  if {$result(timed_out)} {
    set traffic_ok 0
    set traffic_detail "a burst at $length B did not finish inside $burst_tmo_ms ms"
    continue
  }
  foreach board [board_list] {
    foreach cage [cage_list] {
      set peer [far_board $board]
      set tx_frames $result($board,$cage,tx_frames)
      set tx_bytes  $result($board,$cage,tx_bytes)
      set rx_frames $result($peer,$cage,rx_frames)
      set rx_bytes  $result($peer,$cage,rx_bytes)
      set err       $result($peer,$cage,rx_err_frames)
      set mismatch  $result($peer,$cage,mismatch)
      set ::row_mismatch [expr {$::row_mismatch + $mismatch}]
      set ::row_err_frames [expr {$::row_err_frames + $err}]
      set exact [expr {$tx_frames == $rx_frames && $tx_bytes == $rx_bytes
                    && $err == 0 && $mismatch == 0}]
      puts [format "CYCLE %d TRAFFIC len %4d cage %d %s to %s tx %d %d rx %d %d err %d mismatch %d %s" \
            $cycle_index $length $cage $board $peer $tx_frames $tx_bytes $rx_frames $rx_bytes \
            $err $mismatch [expr {$exact ? "EXACT" : "MISMATCH"}]]
      if {!$exact} {
        set traffic_ok 0
        set traffic_detail "cage $cage $board to $peer at $length B tx $tx_frames/$tx_bytes rx $rx_frames/$rx_bytes err $err mismatch $mismatch"
      }
    }
  }
  foreach board [board_list] {
    set now [signature $board]
    if {$now ne $before($board)} {
      incr ::row_transitions
      puts "CYCLE $cycle_index TRANSITION board $board $before($board) to $now at $length B"
      set before($board) $now
    }
  }
}

foreach board [board_list] {
  array set state [state_line "CYCLE $cycle_index SECOND" $board]
  if {![board_ready $board $expected_mask]} {
    set traffic_ok 0
    set traffic_detail "board $board left traffic with up 0x[format %X $state(up)] aligned 0x[format %X $state(aligned)] align_word 0x[format %08X [align_word $board 0]]"
  }
  if {$state(link_fault)}   { set ::row_fault 1 }
  if {$state(access_fault)} { set ::row_access 1 }
  if {$state(retry) > $::row_retry} { set ::row_retry $state(retry) }
}

if {$::row_fault || $::row_access || $::row_retry != 0 || $::row_transitions != 0} {
  finish FAIL "link_fault $::row_fault access_fault $::row_access retry $::row_retry transitions $::row_transitions"
}
if {!$traffic_ok} { finish FAIL $traffic_detail }
finish PASS $traffic_detail
