# ---------------------------------------------------------------------------
# File        : pktgen_twoboard_rxdiag.tcl
# Description : Reads the AXI-Stream adapter's receive counters on both boards, at rest
#               and after a burst per configured size, so a loss inside the adapter is
#               separated from a loss on the wire.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir pktgen_twoboard_lib.tcl]

set diag_lengths [expr {[info exists ::env(NIA_DIAG_SIZES)] ? $::env(NIA_DIAG_SIZES) : "65 129"}]
set diag_bytes   [expr {[info exists ::env(NIA_DIAG_BYTES)] ? $::env(NIA_DIAG_BYTES) : 200000000}]
set burst_tmo_ms [expr {[info exists ::env(NIA_BURST_MS)]   ? $::env(NIA_BURST_MS)   : 30000}]

set ::CMD_AD_STICKY 0x20
set ::CMD_AD_ERR    0x24
set ::CMD_AD_DROP   0x28
set ::CMD_AD_ALIGN0 0x38
set ::CMD_AD_ALIGN1 0x3C

connect_both_boards
calibrate_register_radix
identify_instrument
calibrate_read_latency

proc adapter_status {board} {
  set sticky [board_read $board [expr {$::WINDOW_COMMAND + $::CMD_AD_STICKY}]]
  set err    [board_read $board [expr {$::WINDOW_COMMAND + $::CMD_AD_ERR}]]
  set drop   [board_read $board [expr {$::WINDOW_COMMAND + $::CMD_AD_DROP}]]
  set s(rx_overflow)     [expr {$sticky & 0x3}]
  set s(rx_trunc)        [expr {($sticky >> 2) & 0x3}]
  set s(tx_cpl_overflow) [expr {($sticky >> 4) & 0x3}]
  set s(word)            $sticky
  set s(rx_err_frames)   $err
  set s(rx_drop_frames)  $drop
  foreach {client offset} [list 0 $::CMD_AD_ALIGN0 1 $::CMD_AD_ALIGN1] {
    set word [board_read $board [expr {$::WINDOW_COMMAND + $offset}]]
    set s(align_word$client)  $word
    set s(align_drop$client)  [expr {$word & 0xFFFF}]
    set s(align_abort$client) [expr {($word >> 16) & 0xFFFF}]
  }
  return [array get s]
}

foreach board [board_list] {
  array set before [adapter_status $board]
  puts [format "RXDIAG board %s at rest sticky 0x%08X rx_overflow 0x%X rx_trunc 0x%X rx_err_frames %d rx_drop_frames %d align_drop %d %d align_abort %d %d" \
        $board $before(word) $before(rx_overflow) $before(rx_trunc) \
        $before(rx_err_frames) $before(rx_drop_frames) \
        $before(align_drop0) $before(align_drop1) $before(align_abort0) $before(align_abort1)]
}

foreach length $diag_lengths {
  set frame_limit [expr {int($diag_bytes / $length)}]
  foreach board [board_list] {
    foreach cage [cage_list] {
      generator_configure $board $cage $length 0 $frame_limit
      generator_clear_counters $board $cage
    }
  }
  foreach board [board_list] {
    foreach cage [cage_list] { generator_enable $board $cage }
  }
  set t0 [microseconds_now]
  while {1} {
    set done 1
    foreach board [board_list] {
      foreach cage [cage_list] {
        if {![generator_is_done $board $cage]} { set done 0 }
      }
    }
    if {$done} break
    if {[expr {([microseconds_now] - $t0) / 1000}] > $burst_tmo_ms} {
      puts "RXDIAG len $length TIMEOUT"
      break
    }
  }
  foreach board [board_list] {
    array set st [adapter_status $board]
    puts [format "RXDIAG len %4d board %s sticky 0x%08X rx_overflow 0x%X rx_trunc 0x%X rx_err_frames %d rx_drop_frames %d align_drop %d %d align_abort %d %d" \
          $length $board $st(word) $st(rx_overflow) $st(rx_trunc) \
          $st(rx_err_frames) $st(rx_drop_frames) \
          $st(align_drop0) $st(align_drop1) $st(align_abort0) $st(align_abort1)]
    foreach cage [cage_list] {
      array set c [generator_counters $board $cage]
      puts [format "RXDIAG len %4d board %s cage %d tx %d frames rx %d frames err_frames %d mismatch_beats %d" \
            $length $board $cage $c(tx_frames) $c(rx_frames) $c(rx_err_frames) $c(mismatch)]
    }
  }
}

puts "RXDIAG DONE"
