# ---------------------------------------------------------------------------
# File        : pktgen_loop_test.tcl
# Description : The near-end loopback test of a single client image, which is the only
#               test that may be pointed at a one client top. Five steps: identity, bring-
#               up, the client's own transmit against its own receive, the rate table and
#               the stall report.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set ::nia_is_axis 0
set base [expr {[info exists env(NIA_WINDOW)] ? $env(NIA_WINDOW) : 0xA4000000}]
set PG0  [expr {[info exists env(NIA_PG0)] ? $env(NIA_PG0) : $base + 0x0000}]
set CMD  [expr {[info exists env(NIA_CMD)] ? $env(NIA_CMD) : $base + 0x1000}]

set steps        [expr {[info exists env(NIA_STEPS)]      ? $env(NIA_STEPS)      : "1 2 3 4 5"}]
set bringup_tmo  [expr {[info exists env(NIA_BRINGUP_MS)] ? $env(NIA_BRINGUP_MS) : 10000}]
set burst_cap    [expr {[info exists env(NIA_BURST_BYTES)]? $env(NIA_BURST_BYTES): 3000000000}]
set burst_sizes  [expr {[info exists env(NIA_BURST_SIZES)]? $env(NIA_BURST_SIZES): "64 1518"}]
set rate_sizes   [expr {[info exists env(NIA_RATE_SIZES)] ? $env(NIA_RATE_SIZES) : "64 65 128 256 512 1024 1518"}]
set rate_s       [expr {[info exists env(NIA_RATE_S)]     ? $env(NIA_RATE_S)     : 3.0}]
set burst_tmo    [expr {[info exists env(NIA_BURST_MS)]   ? $env(NIA_BURST_MS)   : 20000}]

set up_mask      [expr {[info exists env(NIA_UP_MASK)]    ? $env(NIA_UP_MASK)    : 1}]

set MODULE_TYPE_SEG      0x4E535047
set MODULE_TYPE_AXIS     0x4E415047
set MAP_VERSION_EXPECT   0x00030001
set SEG_W_EXPECT         128
set NIA_SEG_EXPECT       [expr {[info exists env(NIA_SEG)] ? $env(NIA_SEG) : 0}]

set R_MODULE_TYPE         0x00
set R_MAP_VERSION         0x04
set R_BUS_CHECK           0x08
set R_GEOMETRY            0x0C
set R_FEATURES            0x10
set R_CTL                 0x14
set R_STATUS              0x18
set R_LEN_MIN             0x1C
set R_LEN_MAX             0x20
set R_LEN_MODE            0x24
set R_LEN_EFFECTIVE       0x28
set R_TX_FRAME_LIMIT      0x30
set R_SNAPSHOT_ROUNDS     0x34
set R_TX_FRAMES           0x40
set R_TX_BYTES            0x44
set R_RX_FRAMES           0x48
set R_RX_BYTES            0x4C
set R_RX_ERR_FRAMES       0x50
set R_RX_MISMATCH_BEATS   0x54
set R_STALL_CYCLE         0x58

set CTL_ENABLE 0x1
set CTL_CLEAR  0x2

set ST_DONE     0x02
set ST_RXLOCKED 0x20
set ST_LINKUP   0x40

set C_CTL       0x00
set C_STATUS    0x08
set C_SEQ       0x0C
set C_RXPHY     0x10
set C_RETRY     0x14
set C_FSM       0x1C

set CC_RESTART   0x01
set CC_STATS     0x02

proc now_us {} {
  if {[catch {set t [clock microseconds]}]} { set t [expr {[clock milliseconds] * 1000}] }
  return $t
}

proc rd {addr} {
  set v [lindex [mrd -force -value $addr 1] 0]
  if {[string match -nocase "0x*" $v]} { set v [string range $v 2 end] }
  set out 0
  if {[scan $v %x out] != 1} {
    error "rd: [format 0x%08X $addr] returned '$v', which is not a hexadecimal word"
  }
  return $out
}
proc wr {addr value} { mwr -force $addr $value }

set ::fail_count 0

proc step_result {n ok reason} {
  if {$ok} { puts "STEP $n RESULT PASS $reason" } else {
    puts "STEP $n RESULT FAIL $reason" ; incr ::fail_count }
  return $ok
}
proc want {n ok reason} {
  if {!$ok} { step_result $n 0 $reason ; puts "TEST STOPPED at step $n" ; exit 3 }
}

proc pg_setup {pg len mode limit} {
  global R_CTL R_LEN_MIN R_LEN_MAX R_LEN_MODE R_TX_FRAME_LIMIT CTL_CLEAR
  wr [expr {$pg + $R_CTL}] $CTL_CLEAR
  wr [expr {$pg + $R_LEN_MIN}] $len
  wr [expr {$pg + $R_LEN_MAX}] $len
  wr [expr {$pg + $R_LEN_MODE}] $mode
  wr [expr {$pg + $R_TX_FRAME_LIMIT}] $limit
  wr [expr {$pg + $R_CTL}] 0x0
}
proc pg_enable  {pg} { global R_CTL CTL_ENABLE ; wr [expr {$pg + $R_CTL}] $CTL_ENABLE }
proc pg_disable {pg} { global R_CTL ; wr [expr {$pg + $R_CTL}] 0x0 }

proc pg_counters {pg} {
  global R_TX_FRAMES R_TX_BYTES R_RX_FRAMES R_RX_BYTES R_RX_ERR_FRAMES R_RX_MISMATCH_BEATS
  global R_STALL_CYCLE R_STATUS R_SNAPSHOT_ROUNDS
  set c(txf)    [rd [expr {$pg + $R_TX_FRAMES}]]
  set c(txb)    [rd [expr {$pg + $R_TX_BYTES}]]
  set c(rxf)    [rd [expr {$pg + $R_RX_FRAMES}]]
  set c(rxb)    [rd [expr {$pg + $R_RX_BYTES}]]
  set c(err)    [rd [expr {$pg + $R_RX_ERR_FRAMES}]]
  set c(mis)    [rd [expr {$pg + $R_RX_MISMATCH_BEATS}]]
  set c(stall)  [expr {$::nia_is_axis ? 0 : [rd [expr {$pg + $R_STALL_CYCLE}]]}]
  set c(status) [rd [expr {$pg + $R_STATUS}]]
  set c(rounds) [rd [expr {$pg + $R_SNAPSHOT_ROUNDS}]]
  return [array get c]
}

proc link_status {} {
  global CMD C_STATUS C_SEQ C_RXPHY C_RETRY C_FSM
  set s(status)  [rd [expr {$CMD + $C_STATUS}]]
  set s(up)      [expr {$s(status) & 0x3}]
  set s(fault)   [expr {($s(status) >> 2) & 0x1}]
  set s(afault)  [expr {($s(status) >> 3) & 0x1}]
  set s(busy)    [expr {($s(status) >> 4) & 0x1}]
  set s(aligned) [expr {($s(status) >> 5) & 0x3}]
  set seq        [rd [expr {$CMD + $C_SEQ}]]
  set s(state)   [expr {$seq & 0x1F}]
  set s(pc)      [expr {($seq >> 5) & 0x7FF}]
  set s(rxphy)   [rd [expr {$CMD + $C_RXPHY}]]
  set s(retry)   [rd [expr {$CMD + $C_RETRY}]]
  set s(fsm)     [rd [expr {$CMD + $C_FSM}]]
  return [array get s]
}

proc cmd_pulse {bit} {
  global CMD C_CTL
  wr [expr {$CMD + $C_CTL}] $bit
  after 50
  wr [expr {$CMD + $C_CTL}] 0x0
}

proc burst {len} {
  global PG0 R_STATUS burst_cap burst_tmo ST_DONE
  set limit [expr {int($burst_cap / $len)}]
  if {$limit > 4000000000} { set limit 4000000000 }
  pg_setup $PG0 $len 0 $limit
  set t0 [now_us]
  pg_enable $PG0
  set done 0
  while {1} {
    if {[rd [expr {$PG0 + $R_STATUS}]] & $ST_DONE} { set done 1 ; break }
    if {([now_us] - $t0) / 1000 > $burst_tmo} { break }
    after 10
  }
  set t1 [now_us]
  after 50
  pg_disable $PG0
  set r(limit) $limit
  set r(done)  $done
  set r(us)    [expr {$t1 - $t0}]
  return [array get r]
}

connect
targets -set -filter {name =~ "DPC"}

set t0 [now_us]
for {set i 0} {$i < 20} {incr i} { rd [expr {$PG0 + $R_MODULE_TYPE}] }
set t1 [now_us]
puts [format "TEST JTAG read latency %.0f us per 32-bit read" [expr {($t1 - $t0) / 20.0}]]
puts "TEST WINDOWS client $PG0 command $CMD, and nothing else is read"

if {[lsearch $steps 1] >= 0} {
  set ok 1
  set why "the one window answers"
  set mt [rd [expr {$PG0 + $R_MODULE_TYPE}]]
  set mv [rd [expr {$PG0 + $R_MAP_VERSION}]]
  set sg [rd [expr {$PG0 + $R_GEOMETRY}]]
  set ft [rd [expr {$PG0 + $R_FEATURES}]]
  if {$mt == $MODULE_TYPE_AXIS} { set ::nia_is_axis 1 } else { set ::nia_is_axis 0 }
  set geom_name [expr {$::nia_is_axis ? "AXIS_GEOMETRY" : "SEG_GEOMETRY"}]
  puts "STEP 1 client MODULE_TYPE [format 0x%08X $mt] MAP_VERSION [format 0x%08X $mv] $geom_name [format 0x%08X $sg] FEATURES [format 0x%08X $ft]"
  if {$mt != $MODULE_TYPE_SEG && $mt != $MODULE_TYPE_AXIS} {
    set ok 0 ; set why "MODULE_TYPE [format 0x%08X $mt] is neither the segmented instrument [format 0x%08X $MODULE_TYPE_SEG] nor the AXI-Stream one [format 0x%08X $MODULE_TYPE_AXIS]"
  }
  if {$mv != $MAP_VERSION_EXPECT} { set ok 0 ; set why "MAP_VERSION [format 0x%08X $mv] not [format 0x%08X $MAP_VERSION_EXPECT]" }
  if {$::nia_is_axis} {
    set data_w [expr {$sg & 0xFFFF}]
    set keep_w [expr {($sg >> 16) & 0xFFFF}]
    if {$keep_w != $data_w / 8} { set ok 0 ; set why "AXIS_GEOMETRY KEEP_W $keep_w is not DATA_W $data_w over 8" }
    set n_seg [expr {$data_w / 256}]
    set seg_w $SEG_W_EXPECT
    puts "STEP 1 client DATA_W $data_w KEEP_W $keep_w, and study Section 15.11 fixes DATA_W = 2 x N_SEG x 128, so N_SEG $n_seg"
  } else {
    set n_seg [expr {($sg >> 16) & 0xFFFF}]
    set seg_w [expr {$sg & 0xFFFF}]
    if {$seg_w != $SEG_W_EXPECT} { set ok 0 ; set why "SEG_W $seg_w not $SEG_W_EXPECT" }
  }
  if {!($n_seg == 2 || $n_seg == 4 || $n_seg == 8)} {
    set ok 0 ; set why "N_SEG $n_seg is not 2, 4 or 8, so it is not a rate this instrument builds"
  }
  if {$NIA_SEG_EXPECT != 0 && $n_seg != $NIA_SEG_EXPECT} {
    set ok 0 ; set why "N_SEG $n_seg but NIA_SEG asked for $NIA_SEG_EXPECT"
  }
  set ::nia_n_seg $n_seg
  puts "STEP 1 client N_SEG $n_seg SEG_W $seg_w, which is [expr {$n_seg * 50}]GAUI-[expr {$n_seg / 2}]"

  wr [expr {$PG0 + $R_BUS_CHECK}] 0xA5A51234
  set bc [rd [expr {$PG0 + $R_BUS_CHECK}]]
  puts "STEP 1 BUS_CHECK wrote 0xA5A51234 read [format 0x%08X $bc]"
  if {$bc != 0xA5A51234} { set ok 0 ; set why "BUS_CHECK read [format 0x%08X $bc], so the register path is not proven" }

  want 1 $ok $why
  step_result 1 1 $why
}

set ::nia_line_gbps        [expr {$::nia_n_seg * 50}]
set ::nia_line_bytes_per_s [expr {$::nia_line_gbps * 1.0e9 / 8.0}]
puts "TEST RATE N_SEG $::nia_n_seg, line rate $::nia_line_gbps Gb/s, up_mask $up_mask"

if {[lsearch $steps 2] >= 0} {
  array set s0 [link_status]
  puts "STEP 2 before restart link_up $s0(up) aligned $s0(aligned) seq_state $s0(state) seq_pc $s0(pc) retry $s0(retry) rxphy [format 0x%08X $s0(rxphy)] fsm [format 0x%02X $s0(fsm)] fault $s0(fault) access_fault $s0(afault) busy $s0(busy)"

  set t_start [now_us]
  cmd_pulse $CC_RESTART
  set down_ms -1
  set up_ms   -1
  while {1} {
    set st [rd [expr {$CMD + $C_STATUS}]]
    set up [expr {$st & $up_mask}]
    set el_ms [expr {([now_us] - $t_start) / 1000}]
    if {$up != $up_mask && $down_ms < 0} { set down_ms $el_ms }
    if {$up == $up_mask && $down_ms >= 0} { set up_ms $el_ms ; break }
    if {$el_ms > $bringup_tmo} { break }
  }
  array set s [link_status]
  puts "STEP 2 after restart link_up $s(up) aligned $s(aligned) seq_state $s(state) seq_pc $s(pc) retry $s(retry) rxphy [format 0x%08X $s(rxphy)] fsm [format 0x%02X $s(fsm)] fault $s(fault) access_fault $s(afault) busy $s(busy)"
  puts "STEP 2 the restart dropped the carrier at $down_ms ms and it was up again at $up_ms ms, timeout $bringup_tmo ms"
  set st0 [rd [expr {$PG0 + $R_STATUS}]]
  puts "STEP 2 generator STATUS [format 0x%02X $st0] (bit6 link_up, bit5 rx_locked)"
  want 2 [expr {($s(up) & $up_mask) == $up_mask}] "link_up is $s(up) against mask $up_mask; aligned $s(aligned) rxphy [format 0x%08X $s(rxphy)] retry $s(retry) seq_state $s(state) seq_pc $s(pc)"
  if {$up_ms < 0} {
    set when "without a timed restart, the carrier never fell inside $bringup_tmo ms"
  } else {
    set when "$up_ms ms after the restart"
  }
  step_result 2 1 "the client is up $when, aligned $s(aligned), retry $s(retry)"
}

if {[lsearch $steps 3] >= 0} {
  set ok 1
  set why "transmit equals receive on the one client at every size"
  puts "STEP 3 method: near-end PCS loopback, so the equality is this client's own TX_FRAMES against its own RX_FRAMES and TX_BYTES against RX_BYTES. Each burst is ended by TX_FRAME_LIMIT and sized under 4 GB, because every counter in the map is 32 bits and TX_BYTES wraps at 4.295 GB, which is 86 ms at 400 Gb/s."
  foreach len $burst_sizes {
    array set b [burst $len]
    array set c [pg_counters $PG0]
    puts "STEP 3 len $len limit $b(limit) done $b(done) elapsed [expr {$b(us)/1000}] ms tx $c(txf)/$c(txb) rx $c(rxf)/$c(rxb) mismatch $c(mis) err $c(err) stall $c(stall) rounds $c(rounds)"
    if {!$b(done)}                { set ok 0 ; set why "len $len: the burst did not report done inside $burst_tmo ms" }
    if {$c(txf) != $c(rxf)}       { set ok 0 ; set why "len $len: TX_FRAMES $c(txf) against RX_FRAMES $c(rxf)" }
    if {$c(txb) != $c(rxb)}       { set ok 0 ; set why "len $len: TX_BYTES $c(txb) against RX_BYTES $c(rxb)" }
    if {$c(mis) != 0}             { set ok 0 ; set why "len $len: RX_MISMATCH_BEATS $c(mis)" }
    if {$c(err) != 0}             { set ok 0 ; set why "len $len: RX_ERR_FRAMES $c(err)" }
  }
  want 3 $ok $why
  step_result 3 1 $why
}

if {[lsearch $steps 4] >= 0} {
  set ok 1
  set why "the rate table is filled at every size"
  puts "STEP 4 method: one burst per size, ended by TX_FRAME_LIMIT and timed whole. Its frame count is exactly TX_FRAME_LIMIT, so no counter is read for the rate and no window inside the burst exists for the burst to end inside. It is sized from the line rate SEG_GEOMETRY reports and the len + 24 wire slot, so it lasts NIA_RATE_S seconds at every size."
  puts "STEP 4 TABLE len frames_per_s payload_Gbps wire_Gbps line_fps window_ms slot_Gbps pct_of_line"
  foreach len $rate_sizes {
    set fps_line   [expr {$::nia_line_bytes_per_s / ($len + 24.0)}]
    set rate_limit [expr {int($rate_s * $fps_line)}]
    pg_setup $PG0 $len 0 $rate_limit
    pg_enable $PG0 ; set ta [now_us]
    set done 0 ; set tb 0
    set tmo_ms [expr {int($rate_s * 1000) + $burst_tmo}]
    while {1} {
      if {[rd [expr {$PG0 + $R_STATUS}]] & $ST_DONE} { set done 1 ; set tb [now_us] ; break }
      if {([now_us] - $ta) / 1000 > $tmo_ms} { break }
    }
    after 50
    pg_disable $PG0
    if {!$done} {
      puts "STEP 4 len $len the rate burst did not report done inside $tmo_ms ms"
      set ok 0 ; set why "len $len: the rate burst did not report done"
      continue
    }
    set win_s [expr {($tb - $ta) / 1000000.0}]
    set fps   [expr {$rate_limit / $win_s}]
    set util  [expr {$fps * ($len + 24) * 8 / 1e9}]
    puts [format "STEP 4 TABLE %5d %12.0f %8.3f %8.3f %12.0f %6.1f %8.2f %7.2f" \
      $len $fps [expr {$fps * $len * 8 / 1e9}] [expr {$fps * ($len + 20) * 8 / 1e9}] \
      $fps_line [expr {$win_s * 1000}] $util [expr {100.0 * $util / $::nia_line_gbps}]]
    if {$win_s < 0.5 * $rate_s} {
      set ok 0
      set why "len $len: the rate burst lasted ${win_s}s against a target of ${rate_s}s, so it was mis-sized"
    }
  }
  want 4 $ok $why
  step_result 4 1 $why
}

if {[lsearch $steps 5] >= 0 && $::nia_is_axis} {
  puts "STEP 5 skipped: the AXI-Stream instrument has no STALL_CYCLE register, and an unmapped offset inside a decoded block answers with DECERR rather than the value of another register"
  step_result 5 1 "no STALL_CYCLE in this instrument"
} elseif {[lsearch $steps 5] >= 0} {
  set stall [rd [expr {$PG0 + $R_STALL_CYCLE}]]
  puts "STEP 5 STALL_CYCLE $stall"
  puts "STEP 5 note: the latch needs 1024 consecutive back pressured segment clock cycles, so a zero here is weaker than it looks. At this rate the generator offers more than the client carries, so the MAC must be back pressuring in bursts shorter than the latch can see."
  step_result 5 1 "STALL_CYCLE $stall"
}

puts "TEST DONE failures $::fail_count"
if {$::fail_count > 0} { exit 3 }
exit 0
