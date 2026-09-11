# ---------------------------------------------------------------------------
# File        : pktgen_twoboard_lib.tcl
# Description : The shared layer of the two board tests. Connects once, resolves the two
#               debug port targets, calibrates the radix the tool returns, identifies the
#               instrument from its module type, and presents a read and a write that name
#               their board. A client the image does not carry is refused rather than
#               read.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set ::twoboard_client_count [expr {[info exists ::env(NIA_CLIENTS)] ? $::env(NIA_CLIENTS) : 2}]
set ::twoboard_swap_boards  [expr {[info exists ::env(NIA_SWAP)]    ? $::env(NIA_SWAP)    : 0}]

set ::twoboard_mixed 0
set ::WINDOW_CLIENT0 0xA4000000
set ::WINDOW_COMMAND 0xA4001000
set ::WINDOW_CLIENT1 0xA4002000

# fpga_axispg_dual_top.sv sets N_CLIENT = (RATE == 400) ? 1 : 2 and N_STREAM = (RATE == 400) ? 2 : 1,
# so N_PG = N_CLIENT * N_STREAM is 2 at every rate and the AXI-Stream top always decodes two
# generator windows: pg_sel_ar is {block_ar == BLOCK_PKTGEN_1, block_ar == BLOCK_PKTGEN_0}. What
# changes with the rate is which cage each window feeds. At 100G and 200G window 0 feeds cage 0 and
# window 1 feeds cage 1. At 400G both windows feed the single cage, because PG_CLIENT = q / N_STREAM
# is 0 for both. NIA_CLIENTS counts carriers, which is what the link up mask and the alignment field
# are built from, and it is not the generator window count. One port and one link are checked at
# 400G; only the generator and checker count is two.
#
# The receive side of a 400G cage presents frames to its two checkers in arrival order and carries no
# stream identity, so a frame sent by window 0 of one board can be counted by either window of the
# other. Byte exactness at 400G is therefore the sum over the windows of a cage, and comparing per
# window reads exactly half of what was sent.
#
# CAUTION: the segmented one cage top, tu03_pktgen_400g_top.sv, declares BLOCK_PKTGEN_0 and
# BLOCK_COMMAND only, and its host_arready is pg_sel_ar ? pg_arready : (cmd_sel_ar && ...), so an
# access to block 2 asserts arready never and wedges the debug port until the board is reprogrammed.
# The second window is therefore enabled for the AXI-Stream instrument alone, in identify_instrument
# once the module type has been read, and these defaults keep one window a cage until then.
set ::twoboard_stream_count 1
set ::twoboard_pg_count     $::twoboard_client_count

set ::MODULE_TYPE_SEG  0x4E535047
set ::MODULE_TYPE_AXIS 0x4E415047

set ::REG_MODULE_TYPE       0x00
set ::REG_MAP_VERSION       0x04
set ::REG_BUS_CHECK         0x08
set ::REG_GEOMETRY          0x0C
set ::REG_FEATURES          0x10
set ::REG_CTL               0x14
set ::REG_STATUS            0x18
set ::REG_LEN_MIN           0x1C
set ::REG_LEN_MAX           0x20
set ::REG_LEN_MODE          0x24
set ::REG_LEN_EFFECTIVE     0x28
set ::REG_LEN_CLAMP_STICKY  0x2C
set ::REG_TX_FRAME_LIMIT    0x30
set ::REG_SNAPSHOT_ROUNDS   0x34
set ::REG_TX_FRAMES         0x40
set ::REG_TX_BYTES          0x44
set ::REG_RX_FRAMES         0x48
set ::REG_RX_BYTES          0x4C
set ::REG_RX_ERR_FRAMES     0x50
set ::REG_RX_MISMATCH_BEATS 0x54
set ::REG_STALL_CYCLE       0x58

set ::CTL_ENABLE 0x1
set ::CTL_CLEAR  0x2

set ::STATUS_BUSY      0x01
set ::STATUS_DONE      0x02
set ::STATUS_STALLED   0x04
set ::STATUS_RX_LOCKED 0x20
set ::STATUS_LINK_UP   0x40

set ::CMD_CTL       0x00
set ::CMD_STAT_IDX  0x04
set ::CMD_STATUS    0x08
set ::CMD_SEQ       0x0C
set ::CMD_RXPHY     0x10
set ::CMD_RETRY     0x14
set ::CMD_STAT_DATA 0x18
set ::CMD_MAC_FSM   0x1C

# The adapter status set is read through the indexed window of the command block: write the
# index, then read the data word.
proc command_stat_read {board index} {
  board_write $board [expr {$::WINDOW_COMMAND + $::CMD_STAT_IDX}] $index
  return [board_read $board [expr {$::WINDOW_COMMAND + $::CMD_STAT_DATA}]]
}

set ::CMD_BIT_RESTART        0x01
set ::CMD_BIT_STATS          0x02
set ::CMD_BIT_RESYNC_GROUP0  0x04
set ::CMD_BIT_RXDPRST_GROUP0 0x08
set ::CMD_BIT_TXDPRST_GROUP0 0x10
set ::CMD_BIT_RESYNC_GROUP1  0x20
set ::CMD_BIT_RXDPRST_GROUP1 0x40
set ::CMD_BIT_TXDPRST_GROUP1 0x80

set ::twoboard_is_axis        0
set ::twoboard_segments       0
set ::twoboard_line_gbps      0
set ::twoboard_line_bytes_per_s 0
set ::twoboard_read_latency_us 0
set ::twoboard_fail_count     0
set ::twoboard_current_board  ""
set ::twoboard_radix          hex
set ::twoboard_aligned_published [expr {$::twoboard_client_count > 1}]

proc microseconds_now {} {
  if {[catch {set t [clock microseconds]}]} { set t [expr {[clock milliseconds] * 1000}] }
  return $t
}

proc parse_register_value {text} {
  if {[string match -nocase "0x*" $text]} {
    set body [string range $text 2 end]
    set value 0
    if {[scan $body %x value] != 1} {
      error "parse_register_value: '$text' is not a hexadecimal word"
    }
    return $value
  }
  set value 0
  if {$::twoboard_radix eq "hex"} {
    if {[scan $text %x value] != 1} {
      error "parse_register_value: '$text' is not a hexadecimal word"
    }
    return $value
  }
  if {[scan $text %d value] != 1} {
    error "parse_register_value: '$text' is not a decimal word"
  }
  return $value
}

proc raw_register_text {board address} {
  select_board $board
  return [lindex [mrd -force -value $address 1] 0]
}

proc calibrate_register_radix {} {
  set text [raw_register_text A [expr {$::WINDOW_CLIENT0 + $::REG_MODULE_TYPE}]]
  set as_hex 0
  set as_dec 0
  set hex_ok [expr {[scan $text %x as_hex] == 1}]
  set dec_ok [expr {[scan $text %d as_dec] == 1}]
  set hex_match [expr {$hex_ok && ($as_hex == $::MODULE_TYPE_SEG || $as_hex == $::MODULE_TYPE_AXIS)}]
  set dec_match [expr {$dec_ok && ($as_dec == $::MODULE_TYPE_SEG || $as_dec == $::MODULE_TYPE_AXIS)}]
  if {$hex_match && !$dec_match} {
    set ::twoboard_radix hex
  } elseif {$dec_match && !$hex_match} {
    set ::twoboard_radix dec
  } elseif {$hex_match && $dec_match} {
    set ::twoboard_radix hex
  } else {
    puts "TWOBOARD FAIL: MODULE_TYPE returned '$text', which is neither the segmented identity\
 [format 0x%08X $::MODULE_TYPE_SEG] nor the AXI-Stream one [format 0x%08X $::MODULE_TYPE_AXIS] read as\
 hexadecimal or as decimal. All ones means the board is not programmed or the aperture is not assigned."
    exit 2
  }
  puts "TWOBOARD RADIX mrd -value returns $::twoboard_radix, calibrated from MODULE_TYPE '$text'"
}

proc debug_port_target_ids {} {
  set ids {}
  if {![catch {set properties [targets -target-properties -filter {name =~ "DPC"}]}]} {
    foreach entry $properties {
      if {[catch {set id [dict get $entry target_id]}]} { continue }
      lappend ids $id
    }
  }
  if {[llength $ids] == 0} {
    if {[catch {set listing [targets]}]} { set listing "" }
    foreach line [split $listing "\n"] {
      if {[regexp {^\s*(\d+)\s+.*DPC} $line -> id]} { lappend ids $id }
    }
  }
  return $ids
}

proc print_target_listing {} {
  if {[catch {set listing [targets]}]} { return }
  foreach line [split $listing "\n"] {
    if {[regexp {DPC|Versal} $line]} { puts "TWOBOARD TARGET $line" }
  }
}

proc connect_both_boards {} {
  connect
  print_target_listing
  set ids [debug_port_target_ids]
  if {[info exists ::env(NIA_DPC_A)] && [info exists ::env(NIA_DPC_B)]} {
    set want_a $::env(NIA_DPC_A)
    set want_b $::env(NIA_DPC_B)
    foreach want [list $want_a $want_b] {
      if {[lsearch -exact $ids $want] < 0} {
        puts "TWOBOARD FAIL: NIA_DPC_A/NIA_DPC_B name target $want and the DPC targets present are\
 $ids. Name two of the targets listed above."
        exit 2
      }
    }
    if {$want_a eq $want_b} {
      puts "TWOBOARD FAIL: NIA_DPC_A and NIA_DPC_B both name target $want_a."
      exit 2
    }
    set ids [list $want_a $want_b]
    puts "TWOBOARD SELECTION by NIA_DPC_A/NIA_DPC_B, not by enumeration order"
  } else {
    if {[llength $ids] < 2} {
      puts "TWOBOARD FAIL: [llength $ids] DPC target(s) found and this bench needs two. Check that both\
 boards are powered, that both FT232H cables enumerate, and that hw_server sees both."
      exit 2
    }
    if {[llength $ids] > 2} {
      puts "TWOBOARD FAIL: [llength $ids] DPC targets found. Naming board A and board B is by JTAG\
 enumeration order, so more than two boards makes it a guess. Disconnect the extra boards, or name the\
 two this bench uses with NIA_DPC_A and NIA_DPC_B."
      exit 2
    }
  }
  if {$::twoboard_swap_boards} { set ids [list [lindex $ids 1] [lindex $ids 0]] }
  set ::twoboard_target(A) [lindex $ids 0]
  set ::twoboard_target(B) [lindex $ids 1]
  set ::twoboard_current_board ""
  set swapped [expr {$::twoboard_swap_boards ? " swapped by NIA_SWAP=1" : ""}]
  puts "TWOBOARD BOARD A target $::twoboard_target(A) BOARD B target $::twoboard_target(B)$swapped"
}

proc select_board {board} {
  if {$::twoboard_current_board eq $board} { return }
  targets $::twoboard_target($board)
  set ::twoboard_current_board $board
}

proc board_read {board address} {
  select_board $board
  return [parse_register_value [lindex [mrd -force -value $address 1] 0]]
}

proc board_read_hex {board address} { return [format 0x%08X [board_read $board $address]] }

proc board_write {board address value} {
  select_board $board
  mwr -force $address $value
}

proc client_window {client} {
  if {$client != 0 && $client >= $::twoboard_pg_count} {
    error "client_window: generator window $client requested on an image with\
 $::twoboard_pg_count window(s), NIA_CLIENTS=$::twoboard_client_count and\
 $::twoboard_stream_count stream(s) a cage. A one client top decodes register blocks 0 and 1 only,\
 and a read of block 2 asserts no arready: it stalls at the address phase and wedges the debug port\
 until the board is reprogrammed. Refused."
  }
  return [expr {$client == 0 ? $::WINDOW_CLIENT0 : $::WINDOW_CLIENT1}]
}

proc board_list {} { return [list A B] }

proc far_board {board} { return [expr {$board eq "A" ? "B" : "A"}] }

proc cage_list {} {
  set cages {}
  for {set client 0} {$client < $::twoboard_client_count} {incr client} { lappend cages $client }
  return $cages
}

# The generator windows, which is what a burst drives and what a counter read addresses.
proc pg_list {} {
  set pgs {}
  for {set pg 0} {$pg < $::twoboard_pg_count} {incr pg} { lappend pgs $pg }
  return $pgs
}

# The cage a generator window feeds.
proc pg_cage {pg} {
  return [expr {$::twoboard_stream_count > 1 ? 0 : $pg}]
}

# The generator windows that feed one cage. One window a cage at 100G and 200G, both at 400G.
proc cage_pgs {cage} {
  set pgs {}
  foreach pg [pg_list] { if {[pg_cage $pg] == $cage} { lappend pgs $pg } }
  return $pgs
}

proc cage_label {cage} { return [expr {$cage == 0 ? "QSFP0" : "QSFP1"}] }

# The window of a cage that transmits. At 400G window 0 transmits and window 1 is receive only, so a
# summed transmit count would double count frames that never reached the wire.
proc pg_is_tx {pg} { return [expr {($pg % $::twoboard_stream_count) == 0}] }

proc cage_tx_pg {cage} {
  foreach pg [cage_pgs $cage] { if {[pg_is_tx $pg]} { return $pg } }
  return [lindex [cage_pgs $cage] 0]
}

# The receive side splits frames across the checkers of a cage in arrival order and carries no stream
# identity, so the sum over its windows is what may be compared against the transmit count.
proc cage_sum {result_name board cage field} {
  upvar 1 $result_name values
  set total 0
  foreach pg [cage_pgs $cage] { set total [expr {$total + $values($board,$pg,$field)}] }
  return $total
}

proc identify_instrument {} {
  set module_type [board_read A [expr {$::WINDOW_CLIENT0 + $::REG_MODULE_TYPE}]]
  set map_version [board_read A [expr {$::WINDOW_CLIENT0 + $::REG_MAP_VERSION}]]
  set geometry    [board_read A [expr {$::WINDOW_CLIENT0 + $::REG_GEOMETRY}]]

  if {$module_type == $::MODULE_TYPE_AXIS} {
    set ::twoboard_is_axis 1
  } elseif {$module_type == $::MODULE_TYPE_SEG} {
    set ::twoboard_is_axis 0
  } else {
    puts "TWOBOARD FAIL: board A MODULE_TYPE [format 0x%08X $module_type] is neither the segmented\
 instrument [format 0x%08X $::MODULE_TYPE_SEG] nor the AXI-Stream one\
 [format 0x%08X $::MODULE_TYPE_AXIS]. A read of 0xFFFFFFFF means the board is not programmed or the\
 register aperture is not assigned."
    exit 2
  }

  if {$::twoboard_is_axis} {
    set keep_width [expr {($geometry >> 16) & 0xFFFF}]
    set data_width [expr {$geometry & 0xFFFF}]
    if {$keep_width != $data_width / 8} {
      puts "TWOBOARD FAIL: AXIS_GEOMETRY KEEP_W $keep_width is not DATA_W $data_width over 8"
      exit 2
    }
    set ::twoboard_segments [expr {$data_width / 256}]
    set geometry_detail "AXIS_GEOMETRY DATA_W $data_width KEEP_W $keep_width"
    set ::twoboard_rate_from_env 0
    if {[info exists ::env(NIA_LINE_GBPS)]} {
      set ::twoboard_segments [expr {$::env(NIA_LINE_GBPS) / 50}]
      set ::twoboard_rate_from_env 1
    } elseif {$data_width >= 1024} {
      puts "TWOBOARD FAIL: AXIS_GEOMETRY reports DATA_W $data_width, and the AXI-Stream instrument\
 publishes the stream width rather than the line rate. A 200G client and a 400G client both present\
 1024 bits, four segments of 128 against eight of 128, so the rate cannot be derived here. Set\
 NIA_LINE_GBPS to the rate of the image under test; NIA_RATE in its image_props.txt carries it."
      exit 2
    }
  } else {
    set ::twoboard_segments [expr {($geometry >> 16) & 0xFFFF}]
    set geometry_detail "SEG_GEOMETRY N_SEG $::twoboard_segments SEG_W [expr {$geometry & 0xFFFF}]"
  }

  if {!($::twoboard_segments == 2 || $::twoboard_segments == 4 || $::twoboard_segments == 8)} {
    puts "TWOBOARD FAIL: the geometry gives N_SEG $::twoboard_segments, which is not 2, 4 or 8 and so\
 is not a rate this instrument builds"
    exit 2
  }

  set ::twoboard_line_gbps         [expr {$::twoboard_segments * 50}]
  set ::twoboard_slots_per_cage    [expr {$::twoboard_line_gbps / 100}]
  set ::twoboard_line_bytes_per_s  [expr {$::twoboard_line_gbps * 1.0e9 / 8.0}]
  set instrument_name [expr {$::twoboard_is_axis ? "AXI-Stream" : "segmented"}]

  puts "TWOBOARD INSTRUMENT $instrument_name MODULE_TYPE [format 0x%08X $module_type]\
 MAP_VERSION [format 0x%08X $map_version] $geometry_detail"
  set rate_source [expr {[info exists ::twoboard_rate_from_env] && $::twoboard_rate_from_env \
                         ? "NIA_LINE_GBPS" : "the geometry register"}]
  puts "TWOBOARD RATE line rate $::twoboard_line_gbps Gb/s from $rate_source, segments\
 $::twoboard_segments, clients $::twoboard_client_count, cages [cage_list]. The electrical lane count\
 is not in the register map, so the GAUI variant is not named here."

  if {$::twoboard_is_axis && $::twoboard_client_count == 1} {
    set ::twoboard_stream_count 2
    set ::twoboard_pg_count     2
    puts "TWOBOARD STREAMS the AXI-Stream one cage top sets N_STREAM 2, so it decodes two generator\
 windows on the single cage: [pg_list] on cage [pg_cage 0]. One port and one link are checked, and\
 byte exactness is the sum over both windows."
  } else {
    puts "TWOBOARD STREAMS one generator window a cage, windows [pg_list] on cages [cage_list]."
  }

  set far_module_type [board_read B [expr {$::WINDOW_CLIENT0 + $::REG_MODULE_TYPE}]]
  set far_geometry    [board_read B [expr {$::WINDOW_CLIENT0 + $::REG_GEOMETRY}]]
  if {$far_module_type != $module_type || $far_geometry != $geometry} {
    if {[info exists ::env(NIA_ALLOW_MIXED)] && $::env(NIA_ALLOW_MIXED) != 0} {
      set far_name [expr {$far_module_type == $::MODULE_TYPE_AXIS ? "AXI-Stream" : \
                          ($far_module_type == $::MODULE_TYPE_SEG ? "segmented" : "unknown")}]
      puts "TWOBOARD MIXED board A carries the $instrument_name instrument and board B the $far_name\
 one, geometry [format 0x%08X $geometry] against [format 0x%08X $far_geometry]. A to B then measures\
 board B's receive path against board A's transmit path, and B to A the reverse."
      set ::twoboard_mixed 1
      return
    }
    puts "TWOBOARD FAIL: the two boards carry different builds. Board A reads MODULE_TYPE\
 [format 0x%08X $module_type] geometry [format 0x%08X $geometry], board B reads\
 [format 0x%08X $far_module_type] [format 0x%08X $far_geometry]. Both boards must carry the same rate\
 variant or the lane counts do not agree. NIA_ALLOW_MIXED=1 measures one instrument against the other\
 on purpose."
    exit 2
  }
}

proc calibrate_read_latency {} {
  set start [microseconds_now]
  for {set i 0} {$i < 20} {incr i} { board_read A [expr {$::WINDOW_CLIENT0 + $::REG_MODULE_TYPE}] }
  set ::twoboard_read_latency_us [expr {([microseconds_now] - $start) / 20.0}]
  puts [format "TWOBOARD JTAG read latency %.0f us per 32-bit register read" \
        $::twoboard_read_latency_us]
}

proc generator_configure {board client length mode frame_limit} {
  set window [client_window $client]
  board_write $board [expr {$window + $::REG_CTL}] $::CTL_CLEAR
  board_write $board [expr {$window + $::REG_LEN_MIN}] $length
  board_write $board [expr {$window + $::REG_LEN_MAX}] $length
  board_write $board [expr {$window + $::REG_LEN_MODE}] $mode
  board_write $board [expr {$window + $::REG_TX_FRAME_LIMIT}] $frame_limit
  board_write $board [expr {$window + $::REG_CTL}] 0x0
}

proc generator_clear_counters {board client} {
  set window [client_window $client]
  board_write $board [expr {$window + $::REG_CTL}] $::CTL_CLEAR
  board_write $board [expr {$window + $::REG_CTL}] 0x0
}

proc generator_enable {board client} {
  board_write $board [expr {[client_window $client] + $::REG_CTL}] $::CTL_ENABLE
}

proc generator_disable {board client} {
  board_write $board [expr {[client_window $client] + $::REG_CTL}] 0x0
}

proc generator_is_done {board client} {
  set status [board_read $board [expr {[client_window $client] + $::REG_STATUS}]]
  return [expr {($status & $::STATUS_DONE) != 0}]
}

proc generator_counters {board client} {
  set window [client_window $client]
  select_board $board
  set counters(tx_frames)     [board_read $board [expr {$window + $::REG_TX_FRAMES}]]
  set counters(tx_bytes)      [board_read $board [expr {$window + $::REG_TX_BYTES}]]
  set counters(rx_frames)     [board_read $board [expr {$window + $::REG_RX_FRAMES}]]
  set counters(rx_bytes)      [board_read $board [expr {$window + $::REG_RX_BYTES}]]
  set counters(rx_err_frames) [board_read $board [expr {$window + $::REG_RX_ERR_FRAMES}]]
  set counters(mismatch)      [board_read $board [expr {$window + $::REG_RX_MISMATCH_BEATS}]]
  set counters(status)        [board_read $board [expr {$window + $::REG_STATUS}]]
  set counters(align_stat)    [command_stat_read $board [expr {0x0E + $client}]]
  set counters(rounds)        [board_read $board [expr {$window + $::REG_SNAPSHOT_ROUNDS}]]
  set counters(stall_cycle)   [expr {$::twoboard_is_axis \
                                     ? 0 \
                                     : [board_read $board [expr {$window + $::REG_STALL_CYCLE}]]}]
  return [array get counters]
}

proc link_state {board} {
  set status [board_read $board [expr {$::WINDOW_COMMAND + $::CMD_STATUS}]]
  set state(status) $status
  set groups $::twoboard_client_count
  set state(up) [expr {$status & ((1 << $groups) - 1)}]
  set state(link_fault)   [expr {($status >> $groups) & 0x1}]
  set state(access_fault) [expr {($status >> ($groups + 1)) & 0x1}]
  set state(seq_busy)     [expr {($status >> ($groups + 2)) & 0x1}]
  if {$::twoboard_aligned_published} {
    set state(aligned) [expr {($status >> ($groups + 3)) & ((1 << $groups) - 1)}]
  } else {
    set state(aligned) -1
  }
  set sequencer [board_read $board [expr {$::WINDOW_COMMAND + $::CMD_SEQ}]]
  set state(seq_state) [expr {$sequencer & 0x1F}]
  set state(seq_pc)    [expr {($sequencer >> 5) & 0xFFFF}]
  set state(retry)     [board_read $board [expr {$::WINDOW_COMMAND + $::CMD_RETRY}]]
  set state(rx_phy)    [board_read $board [expr {$::WINDOW_COMMAND + $::CMD_RXPHY}]]
  set state(mac_fsm)   [board_read $board [expr {$::WINDOW_COMMAND + $::CMD_MAC_FSM}]]
  return [array get state]
}

proc link_aligned_matches {board expected_mask} {
  array set state [link_state $board]
  if {$state(aligned) < 0} { return 1 }
  return [expr {($state(aligned) & $expected_mask) == $expected_mask}]
}

proc link_up_mask {} { return [expr {(1 << $::twoboard_client_count) - 1}] }

proc link_restart {board} {
  board_write $board [expr {$::WINDOW_COMMAND + $::CMD_CTL}] $::CMD_BIT_RESTART
}

proc report_step {number passed reason} {
  if {$passed} {
    puts "STEP $number RESULT PASS $reason"
  } else {
    puts "STEP $number RESULT FAIL $reason"
    incr ::twoboard_fail_count
  }
  return $passed
}

proc require_step {number passed reason} {
  if {!$passed} {
    report_step $number 0 $reason
    puts "TEST STOPPED at step $number"
    exit 3
  }
}

proc report_summary {name} {
  if {$::twoboard_fail_count == 0} {
    puts "$name RESULT PASS"
    exit 0
  }
  puts "$name RESULT FAIL $::twoboard_fail_count step(s)"
  exit 1
}

proc wire_slot_bytes {frame_length} { return [expr {$frame_length + 24}] }

proc line_rate_frames_per_s {frame_length} {
  return [expr {$::twoboard_line_bytes_per_s / [wire_slot_bytes $frame_length]}]
}
