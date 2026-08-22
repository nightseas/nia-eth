# ---------------------------------------------------------------------------
# File        : pktgen_twoboard_stub.tcl
# Description : An offline rehearsal of the two board tests: two simulated boards, a clock
#               that advances on every register access, and a burst model that delivers
#               frames to the far board, so the link and wire scripts run with no
#               hardware.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set stub_instrument   [expr {[info exists ::env(NIA_STUB_INSTRUMENT)] ? $::env(NIA_STUB_INSTRUMENT) : "seg"}]
set stub_segments     [expr {[info exists ::env(NIA_STUB_SEGMENTS)]   ? $::env(NIA_STUB_SEGMENTS)   : 2}]
set stub_clients      [expr {[info exists ::env(NIA_CLIENTS)]         ? $::env(NIA_CLIENTS)         : 2}]
set stub_script       [expr {[info exists ::env(NIA_STUB_SCRIPT)]     ? $::env(NIA_STUB_SCRIPT)     : "pktgen_twoboard_link.tcl"}]
set stub_bringup_ms   [expr {[info exists ::env(NIA_STUB_BRINGUP_MS)] ? $::env(NIA_STUB_BRINGUP_MS) : 300}]
set stub_dirty_first  [expr {[info exists ::env(NIA_STUB_DIRTY)]      ? $::env(NIA_STUB_DIRTY)      : 1}]
set stub_radix        [expr {[info exists ::env(NIA_STUB_RADIX)]      ? $::env(NIA_STUB_RADIX)      : "hex"}]

set stub_read_latency_us 837
set stub_now_us 0
set stub_current_board A
set stub_line_bytes_per_s [expr {$stub_segments * 50 * 1.0e9 / 8.0}]
array set stub_memory {}
array set stub_link_up_at_us {A 0 B 0}
array set stub_done_at_us {}
array set stub_burst_length {}
array set stub_burst_limit {}
array set stub_burst_index {}

proc stub_format {value} {
  if {$::stub_radix eq "dec"} { return [format %d $value] }
  return [format %08X $value]
}

proc stub_key {board address} { return "$board,[format 0x%08X $address]" }

proc stub_poke {board address value} {
  set ::stub_memory([stub_key $board $address]) $value
}

proc stub_peek {board address} {
  set key [stub_key $board $address]
  if {[info exists ::stub_memory($key)]} { return $::stub_memory($key) }
  return 0
}

proc stub_advance_us {microseconds} { set ::stub_now_us [expr {$::stub_now_us + $microseconds}] }

proc stub_client_windows {} {
  set windows {}
  for {set client 0} {$client < $::stub_clients} {incr client} {
    lappend windows [list $client [expr {$client == 0 ? 0xA4000000 : 0xA4002000}]]
  }
  return $windows
}

proc stub_window_of {client} { return [expr {$client == 0 ? 0xA4000000 : 0xA4002000}] }

proc stub_initialise {} {
  set module_type [expr {$::stub_instrument eq "axis" ? 0x4E415047 : 0x4E535047}]
  set data_width [expr {2 * $::stub_segments * 128}]
  set geometry [expr {$::stub_instrument eq "axis"
                      ? (($data_width / 8) << 16) | $data_width
                      : ($::stub_segments << 16) | 128}]
  foreach board {A B} {
    foreach entry [stub_client_windows] {
      lassign $entry client window
      stub_poke $board [expr {$window + 0x00}] $module_type
      stub_poke $board [expr {$window + 0x04}] 0x00030001
      stub_poke $board [expr {$window + 0x0C}] $geometry
      stub_poke $board [expr {$window + 0x10}] 0x00000001
      stub_poke $board [expr {$window + 0x34}] 7
    }
    stub_poke $board 0xA400100C 0x00008B0C
    stub_poke $board 0xA4001010 0x00000000
    stub_poke $board 0xA400101C 0x0000001B
  }
}

proc stub_link_bits {board} {
  set mask [expr {(1 << $::stub_clients) - 1}]
  if {$::stub_now_us >= $::stub_link_up_at_us($board)} { return $mask }
  return 0
}

proc stub_command_status {board} {
  set up [stub_link_bits $board]
  set busy [expr {$::stub_now_us < $::stub_link_up_at_us($board) ? 1 : 0}]
  return [expr {$up | ($busy << 4) | ($up << 5)}]
}

proc stub_complete_burst {board client} {
  set key "$board,$client"
  if {![info exists ::stub_done_at_us($key)]} { return 0 }
  if {$::stub_now_us < $::stub_done_at_us($key)} { return 0 }
  set length $::stub_burst_length($key)
  set limit  $::stub_burst_limit($key)
  set peer [expr {$board eq "A" ? "B" : "A"}]
  set window [stub_window_of $client]
  set delivered $limit
  set mismatch 0
  if {$::stub_dirty_first && $::stub_burst_index($key) == 0} {
    set delivered [expr {$limit + 977}]
    set mismatch 12
  }
  stub_poke $board [expr {$window + 0x40}] $limit
  stub_poke $board [expr {$window + 0x44}] [expr {$limit * $length}]
  stub_poke $peer [expr {$window + 0x48}] $delivered
  stub_poke $peer [expr {$window + 0x4C}] [expr {$delivered * $length}]
  stub_poke $peer [expr {$window + 0x54}] $mismatch
  return 1
}

proc stub_status_word {board client} {
  set window [stub_window_of $client]
  set status [expr {[stub_link_bits $board] ? 0x40 : 0x00}]
  if {[stub_complete_burst $board $client]} { set status [expr {$status | 0x02 | 0x20}] }
  return $status
}

proc stub_client_of_address {address} {
  foreach entry [stub_client_windows] {
    lassign $entry client window
    if {$address >= $window && $address < $window + 0x1000} { return [list $client $window] }
  }
  return {}
}

proc mrd {args} {
  set positional {}
  foreach argument $args {
    if {[string match "-*" $argument]} { continue }
    lappend positional $argument
  }
  set address [expr {[lindex $positional 0]}]
  stub_advance_us $::stub_read_latency_us
  set board $::stub_current_board
  if {$address >= 0xA4001000 && $address < 0xA4002000} {
    if {$address == 0xA4001008} { return [list [stub_format [stub_command_status $board]]] }
    return [list [stub_format [stub_peek $board $address]]]
  }
  set located [stub_client_of_address $address]
  if {[llength $located] == 2} {
    lassign $located client window
    if {$address == $window + 0x18} { return [list [stub_format [stub_status_word $board $client]]] }
    stub_complete_burst $board $client
  }
  return [list [stub_format [stub_peek $board $address]]]
}

proc mwr {args} {
  set positional {}
  foreach argument $args {
    if {[string match "-*" $argument]} { continue }
    lappend positional $argument
  }
  set address [expr {[lindex $positional 0]}]
  set value   [expr {[lindex $positional 1]}]
  stub_advance_us $::stub_read_latency_us
  set board $::stub_current_board

  if {$address == 0xA4001000} {
    if {$value & 0x01} {
      set ::stub_link_up_at_us($board) [expr {$::stub_now_us + $::stub_bringup_ms * 1000}]
      foreach index_key [array names ::stub_burst_index] {
        unset ::stub_burst_index($index_key)
      }
    }
    return
  }

  set located [stub_client_of_address $address]
  if {[llength $located] == 2} {
    lassign $located client window
    set key "$board,$client"
    if {$address == $window + 0x14} {
      if {$value & 0x02} {
        foreach offset {0x40 0x44 0x48 0x4C 0x50 0x54 0x58} {
          stub_poke $board [expr {$window + $offset}] 0
        }
        catch {unset ::stub_done_at_us($key)}
      }
      if {$value & 0x01} {
        set length [stub_peek $board [expr {$window + 0x1C}]]
        set limit  [stub_peek $board [expr {$window + 0x30}]]
        if {$length <= 0} { set length 64 }
        if {$limit  <= 0} { set limit 1 }
        set ::stub_burst_length($key) $length
        set ::stub_burst_limit($key) $limit
        if {![info exists ::stub_burst_index($key)]} {
          set ::stub_burst_index($key) 0
        } else {
          incr ::stub_burst_index($key)
        }
        set duration_us [expr {$limit * ($length + 24) * 1.0e6 / $::stub_line_bytes_per_s}]
        set ::stub_done_at_us($key) [expr {$::stub_now_us + $duration_us}]
      }
      return
    }
  }
  stub_poke $board $address $value
}

proc connect {args} { return "" }

proc targets {args} {
  if {[llength $args] == 1 && [string is integer -strict [lindex $args 0]]} {
    set ::stub_current_board [expr {[lindex $args 0] == 1 ? "A" : "B"}]
    return ""
  }
  if {[lsearch -exact $args "-target-properties"] >= 0} {
    return [list [dict create target_id 1 name DPC] [dict create target_id 2 name DPC]]
  }
  return "  1  DPC (board A)\n  2  DPC (board B)"
}

proc after {milliseconds args} {
  stub_advance_us [expr {$milliseconds * 1000}]
  if {[llength $args]} { uplevel 1 $args }
}

proc stub_install_clock {} {
  proc microseconds_now {} { return [expr {int($::stub_now_us)}] }
}

rename source stub_real_source
proc source {path args} {
  set result [uplevel #0 [list stub_real_source $path]]
  if {[string match *pktgen_twoboard_lib.tcl $path]} { stub_install_clock }
  return $result
}

stub_initialise
set stub_dir [file dirname [file normalize [info script]]]
puts "STUB instrument $stub_instrument segments $stub_segments clients $stub_clients radix $stub_radix script $stub_script"
stub_real_source [file join $stub_dir $stub_script]
