# ---------------------------------------------------------------------------
# File        : pktgen_dual_test.tcl
# Description : The QSFP0 to QSFP1 wire test of the two client image. Seven steps from
#               identity and bring-up through byte exactness, the rate table, the stall
#               report and one repair command, each printing one result line, and the run
#               stops at the first failure.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set base [expr {[info exists env(NIA_WINDOW)] ? $env(NIA_WINDOW) : 0xA4000000}]
set PG0  [expr {[info exists env(NIA_PG0)] ? $env(NIA_PG0) : $base + 0x0000}]
set CMD  [expr {[info exists env(NIA_CMD)] ? $env(NIA_CMD) : $base + 0x1000}]
set PG1  [expr {[info exists env(NIA_PG1)] ? $env(NIA_PG1) : $base + 0x2000}]

set steps        [expr {[info exists env(NIA_STEPS)]      ? $env(NIA_STEPS)      : "1 2 3 4 5 6"}]
set bringup_tmo  [expr {[info exists env(NIA_BRINGUP_MS)] ? $env(NIA_BRINGUP_MS) : 10000}]
set burst_cap    [expr {[info exists env(NIA_BURST_BYTES)]? $env(NIA_BURST_BYTES): 3000000000}]
set burst_sizes  [expr {[info exists env(NIA_BURST_SIZES)]? $env(NIA_BURST_SIZES): "64 1518"}]
set rate_sizes   [expr {[info exists env(NIA_RATE_SIZES)] ? $env(NIA_RATE_SIZES) : "64 65 128 256 512 1024 1518"}]
set rate_s       [expr {[info exists env(NIA_RATE_S)]     ? $env(NIA_RATE_S)     : 3.0}]
set burst_tmo    [expr {[info exists env(NIA_BURST_MS)]   ? $env(NIA_BURST_MS)   : 20000}]
set reset_grp    [expr {[info exists env(NIA_RESET_GROUP)]? $env(NIA_RESET_GROUP): 0}]
set repair       [expr {[info exists env(NIA_REPAIR)]     ? $env(NIA_REPAIR)     : "rxdp"}]
set obs_ms       [expr {[info exists env(NIA_OBSERVE_MS)] ? $env(NIA_OBSERVE_MS) : 3000}]
set post_bursts  [expr {[info exists env(NIA_POST_BURSTS)] ? $env(NIA_POST_BURSTS) : 3}]

set MODULE_TYPE_EXPECT   0x4E535047
set MAP_VERSION_EXPECT   0x00030001

set SEG_W_EXPECT         128
set NIA_SEG_EXPECT       [expr {[info exists env(NIA_SEG)] ? $env(NIA_SEG) : 0}]

set R_MODULE_TYPE         0x00
set R_MAP_VERSION         0x04
set R_BUS_CHECK           0x08
set R_SEG_GEOMETRY        0x0C
set R_FEATURES            0x10
set R_CTL                 0x14
set R_STATUS              0x18
set R_LEN_MIN             0x1C
set R_LEN_MAX             0x20
set R_LEN_MODE            0x24
set R_LEN_EFFECTIVE       0x28
set R_LEN_CLAMP_STICKY    0x2C
set R_TX_FRAME_LIMIT      0x30
set R_SNAPSHOT_ROUNDS     0x34
set R_TX_FRAMES           0x40
set R_TX_BYTES            0x44
set R_RX_FRAMES           0x48
set R_RX_BYTES            0x4C
set R_RX_ERR_FRAMES       0x50
set R_RX_MISMATCH_BEATS   0x54
set R_STALL_CYCLE         0x58
set R_LATCHED_TX_FRAMES   0x60
set R_LATCHED_TX_BYTES    0x64
set R_LATCHED_RX_FRAMES   0x68
set R_LATCHED_RX_BYTES    0x6C
set R_LATCHED_RX_MISMATCH 0x70

set CTL_ENABLE 0x1
set CTL_CLEAR  0x2

set ST_BUSY     0x01
set ST_DONE     0x02
set ST_STALLED  0x04
set ST_UNDERRUN 0x08
set ST_OVERRUN  0x10
set ST_RXLOCKED 0x20
set ST_LINKUP   0x40

set C_CTL       0x00
set C_STAT_IDX  0x04
set C_STATUS    0x08
set C_SEQ       0x0C
set C_RXPHY     0x10
set C_RETRY     0x14
set C_STAT_DATA 0x18
set C_FSM       0x1C

set CC_RESTART   0x01
set CC_STATS     0x02
set CC_RESYNC_0  0x04
set CC_RXDPRST_0 0x08
set CC_TXDPRST_0 0x10
set CC_RESYNC_1  0x20
set CC_RXDPRST_1 0x40
set CC_TXDPRST_1 0x80

proc now_us {} {
  if {[catch {set t [clock microseconds]}]} { set t [expr {[clock milliseconds] * 1000}] }
  return $t
}

proc rd {addr} {
  set v [lindex [mrd -force -value $addr 1] 0]
  if {[string match -nocase "0x*" $v]} { return [expr {$v + 0}] }
  if {[regexp {^[0-9]+$} $v]}          { return [expr {$v + 0}] }
  return [expr {"0x$v" + 0}]
}
proc rdh {addr} { return [format 0x%08X [rd $addr]] }
proc wr  {addr value} { mwr -force $addr $value }

set ::fail_count 0

proc step_result {n ok reason} {
  if {$ok} {
    puts "STEP $n RESULT PASS $reason"
  } else {
    puts "STEP $n RESULT FAIL $reason"
    incr ::fail_count
  }
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
  set c(txf)      [rd [expr {$pg + $R_TX_FRAMES}]]
  set c(txb)      [rd [expr {$pg + $R_TX_BYTES}]]
  set c(rxf)      [rd [expr {$pg + $R_RX_FRAMES}]]
  set c(rxb)      [rd [expr {$pg + $R_RX_BYTES}]]
  set c(err)      [rd [expr {$pg + $R_RX_ERR_FRAMES}]]
  set c(mis)      [rd [expr {$pg + $R_RX_MISMATCH_BEATS}]]
  set c(stall)    [rd [expr {$pg + $R_STALL_CYCLE}]]
  set c(status)   [rd [expr {$pg + $R_STATUS}]]
  set c(rounds)   [rd [expr {$pg + $R_SNAPSHOT_ROUNDS}]]
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
  set s(pc)      [expr {($seq >> 5) & 0xFFFF}]
  set s(rxphy)   [rd [expr {$CMD + $C_RXPHY}]]
  set s(retry)   [rd [expr {$CMD + $C_RETRY}]]
  set s(fsm)     [rd [expr {$CMD + $C_FSM}]]
  return [array get s]
}

proc cmd_pulse {mask} {
  global CMD C_CTL
  wr [expr {$CMD + $C_CTL}] 0x0
  wr [expr {$CMD + $C_CTL}] $mask
  wr [expr {$CMD + $C_CTL}] 0x0
}

proc cmd_assert_then_clear {mask hold_ms} {
  global CMD C_CTL
  wr [expr {$CMD + $C_CTL}] 0x0
  wr [expr {$CMD + $C_CTL}] $mask
  if {$hold_ms > 0} { after $hold_ms }
  wr [expr {$CMD + $C_CTL}] 0x0
}

connect
set dpc [targets -filter {name =~ "DPC"}]
if {[llength $dpc] == 0} {
  puts "TEST FAIL: no DPC target; the window is reached through the processing system's debug port"
  exit 2
}
targets -set -filter {name =~ "DPC"}
puts "TEST WINDOW pg0 [format 0x%08X $PG0] cmd [format 0x%08X $CMD] pg1 [format 0x%08X $PG1]"

set ::nia_n_seg [expr {(([rd [expr {$PG0 + $R_SEG_GEOMETRY}]]) >> 16) & 0xFFFF}]
if {!($::nia_n_seg == 2 || $::nia_n_seg == 4 || $::nia_n_seg == 8)} {
  puts "TEST FAIL: SEG_GEOMETRY reports N_SEG $::nia_n_seg, which is not a rate this instrument builds"
  exit 2
}
set ::nia_line_gbps       [expr {$::nia_n_seg * 50}]
set ::nia_line_bytes_per_s [expr {$::nia_line_gbps * 1.0e9 / 8.0}]
puts "TEST RATE N_SEG $::nia_n_seg, ${::nia_line_gbps}GAUI-[expr {$::nia_n_seg / 2}], line rate $::nia_line_gbps Gb/s"
puts "TEST STEPS $steps"

set t0 [now_us]
for {set i 0} {$i < 20} {incr i} { rd [expr {$PG0 + $R_MODULE_TYPE}] }
set t1 [now_us]
set read_us [expr {($t1 - $t0) / 20.0}]
puts [format "TEST JTAG read latency %.0f us per 32-bit read" $read_us]

if {[lsearch $steps 1] >= 0} {
  set ok 1
  set why "both windows answer"
  foreach {name pg} [list client0 $PG0 client1 $PG1] {
    set mt [rd [expr {$pg + $R_MODULE_TYPE}]]
    set mv [rd [expr {$pg + $R_MAP_VERSION}]]
    set sg [rd [expr {$pg + $R_SEG_GEOMETRY}]]
    set ft [rd [expr {$pg + $R_FEATURES}]]
    puts "STEP 1 $name MODULE_TYPE [format 0x%08X $mt] MAP_VERSION [format 0x%08X $mv] SEG_GEOMETRY [format 0x%08X $sg] FEATURES [format 0x%08X $ft]"
    if {$mt != $MODULE_TYPE_EXPECT} { set ok 0 ; set why "$name MODULE_TYPE [format 0x%08X $mt] not [format 0x%08X $MODULE_TYPE_EXPECT]" }
    if {$mv != $MAP_VERSION_EXPECT} { set ok 0 ; set why "$name MAP_VERSION [format 0x%08X $mv] not [format 0x%08X $MAP_VERSION_EXPECT]" }
    set n_seg [expr {($sg >> 16) & 0xFFFF}]
    set seg_w [expr {$sg & 0xFFFF}]
    if {$seg_w != $SEG_W_EXPECT} { set ok 0 ; set why "$name SEG_W $seg_w not $SEG_W_EXPECT" }
    if {!($n_seg == 2 || $n_seg == 4 || $n_seg == 8)} {
      set ok 0 ; set why "$name N_SEG $n_seg is not 2, 4 or 8, so it is not a rate this instrument builds"
    }
    if {$NIA_SEG_EXPECT != 0 && $n_seg != $NIA_SEG_EXPECT} {
      set ok 0 ; set why "$name N_SEG $n_seg but NIA_SEG asked for $NIA_SEG_EXPECT"
    }
    if {$name eq "client0"} { set ::nia_n_seg $n_seg } elseif {$n_seg != $::nia_n_seg} {
      set ok 0 ; set why "the two clients report different geometries, $::nia_n_seg and $n_seg"
    }
    puts "STEP 1 $name N_SEG $n_seg SEG_W $seg_w, which is [expr {$n_seg * 50}]GAUI-[expr {$n_seg / 2}]"

    wr [expr {$pg + $R_BUS_CHECK}] 0xA5A51234
    set b1 [rd [expr {$pg + $R_BUS_CHECK}]]
    wr [expr {$pg + $R_BUS_CHECK}] 0x5A5AEDCB
    set b2 [rd [expr {$pg + $R_BUS_CHECK}]]
    puts "STEP 1 $name BUS_CHECK [format 0x%08X $b1] [format 0x%08X $b2]"
    if {$b1 != 0xA5A51234 || $b2 != 0x5A5AEDCB} { set ok 0 ; set why "$name BUS_CHECK [format 0x%08X $b1] [format 0x%08X $b2]" }

    set rounds {}
    for {set i 0} {$i < 3} {incr i} {
      lappend rounds [rd [expr {$pg + $R_SNAPSHOT_ROUNDS}]]
      after 100
    }
    puts "STEP 1 $name SNAPSHOT_ROUNDS $rounds at 100 ms apart, 8 bits wide so it wraps"
    if {[lindex $rounds 0] == [lindex $rounds 1] && [lindex $rounds 1] == [lindex $rounds 2]} {
      set ok 0 ; set why "$name snapshot round count did not advance, the segment clock or its crossing is dark"
    }
  }

  wr [expr {$PG0 + $R_BUS_CHECK}] 0x11112222
  wr [expr {$PG1 + $R_BUS_CHECK}] 0x33334444
  set a0 [rd [expr {$PG0 + $R_BUS_CHECK}]]
  set a1 [rd [expr {$PG1 + $R_BUS_CHECK}]]
  puts "STEP 1 alias check client0 [format 0x%08X $a0] client1 [format 0x%08X $a1]"
  if {$a0 != 0x11112222 || $a1 != 0x33334444} { set ok 0 ; set why "the two windows alias: [format 0x%08X $a0] [format 0x%08X $a1]" }
  want 1 $ok $why
  step_result 1 1 $why
}

if {[lsearch $steps 2] >= 0} {
  array set s0 [link_status]
  puts "STEP 2 before restart link_up $s0(up) aligned $s0(aligned) seq_state $s0(state) seq_pc $s0(pc) retry $s0(retry) rxphy [format 0x%08X $s0(rxphy)] fsm [format 0x%02X $s0(fsm)] fault $s0(fault) access_fault $s0(afault) busy $s0(busy)"

  set t_start [now_us]
  cmd_pulse $CC_RESTART
  set down_ms -1
  set up_ms   -1
  while {1} {
    set st [rd [expr {$CMD + $C_STATUS}]]
    set up [expr {$st & 0x3}]
    set el_ms [expr {([now_us] - $t_start) / 1000}]
    if {$up != 3 && $down_ms < 0} { set down_ms $el_ms }
    if {$up == 3 && $down_ms >= 0} { set up_ms $el_ms ; break }
    if {$el_ms > $bringup_tmo} { break }
  }
  set both [expr {($up_ms >= 0) ? 1 : 0}]
  array set s [link_status]
  puts "STEP 2 after restart link_up $s(up) aligned $s(aligned) seq_state $s(state) seq_pc $s(pc) retry $s(retry) rxphy [format 0x%08X $s(rxphy)] fsm [format 0x%02X $s(fsm)] fault $s(fault) access_fault $s(afault) busy $s(busy)"
  puts "STEP 2 the restart dropped the carrier at $down_ms ms and both carriers were up again at $up_ms ms, timeout $bringup_tmo ms"
  set st0 [rd [expr {$PG0 + $R_STATUS}]]
  set st1 [rd [expr {$PG1 + $R_STATUS}]]
  puts "STEP 2 generator STATUS client0 [format 0x%02X $st0] client1 [format 0x%02X $st1] (bit6 link_up, bit5 rx_locked)"
  want 2 [expr {$s(up) == 3}] "link_up is $s(up), not both groups; aligned $s(aligned) rxphy [format 0x%08X $s(rxphy)] retry $s(retry) seq_state $s(state) seq_pc $s(pc)"
  want 2 $both "the restart was issued but the carrier never fell and rose inside $bringup_tmo ms, so no bring-up was timed"
  step_result 2 1 "both groups up $up_ms ms after the restart, aligned $s(aligned), retry $s(retry)"
}

proc burst {len} {
  global PG0 PG1 R_STATUS R_TX_FRAME_LIMIT burst_cap burst_tmo ST_DONE
  set limit [expr {int($burst_cap / $len)}]
  if {$limit > 4000000000} { set limit 4000000000 }
  pg_setup $PG0 $len 0 $limit
  pg_setup $PG1 $len 0 $limit
  set t0 [now_us]
  pg_enable $PG0
  pg_enable $PG1
  set done 0
  while {1} {
    set s0 [rd [expr {$PG0 + $R_STATUS}]]
    set s1 [rd [expr {$PG1 + $R_STATUS}]]
    set el_ms [expr {([now_us] - $t0) / 1000}]
    if {($s0 & $ST_DONE) && ($s1 & $ST_DONE)} { set done 1 ; break }
    if {$el_ms > $burst_tmo} { break }
    after 10
  }
  set t1 [now_us]
  after 50
  pg_disable $PG0
  pg_disable $PG1
  set r(limit) $limit
  set r(done)  $done
  set r(us)    [expr {$t1 - $t0}]
  return [array get r]
}

if {[lsearch $steps 3] >= 0} {
  set ok 1
  set why "matched counts in both directions"
  foreach len $burst_sizes {
    array set b [burst $len]
    array set c0 [pg_counters $PG0]
    array set c1 [pg_counters $PG1]
    puts "STEP 3 len $len limit $b(limit) done $b(done) elapsed [expr {$b(us)/1000}] ms"
    puts "STEP 3 len $len client0 tx $c0(txf) frames $c0(txb) bytes  rx $c0(rxf) frames $c0(rxb) bytes  err $c0(err) mismatch $c0(mis) stall $c0(stall) status [format 0x%02X $c0(status)]"
    puts "STEP 3 len $len client1 tx $c1(txf) frames $c1(txb) bytes  rx $c1(rxf) frames $c1(rxb) bytes  err $c1(err) mismatch $c1(mis) stall $c1(stall) status [format 0x%02X $c1(status)]"
    puts "STEP 3 len $len cross 0to1 tx $c0(txf) rx $c1(rxf) delta [expr {$c0(txf) - $c1(rxf)}] bytes delta [expr {$c0(txb) - $c1(rxb)}]"
    puts "STEP 3 len $len cross 1to0 tx $c1(txf) rx $c0(rxf) delta [expr {$c1(txf) - $c0(rxf)}] bytes delta [expr {$c1(txb) - $c0(rxb)}]"
    if {!$b(done)} { set ok 0 ; set why "len $len: the burst did not report done inside $burst_tmo ms" }
    if {$c0(txf) == 0 || $c1(txf) == 0} { set ok 0 ; set why "len $len: a generator sent nothing" }
    if {$c0(txf) != $c1(rxf)} { set ok 0 ; set why "len $len: client0 tx $c0(txf) != client1 rx $c1(rxf)" }
    if {$c1(txf) != $c0(rxf)} { set ok 0 ; set why "len $len: client1 tx $c1(txf) != client0 rx $c0(rxf)" }
    if {$c0(txb) != $c1(rxb)} { set ok 0 ; set why "len $len: client0 tx bytes $c0(txb) != client1 rx bytes $c1(rxb)" }
    if {$c1(txb) != $c0(rxb)} { set ok 0 ; set why "len $len: client1 tx bytes $c1(txb) != client0 rx bytes $c0(rxb)" }
    if {$c0(mis) != 0 || $c1(mis) != 0} { set ok 0 ; set why "len $len: RX_MISMATCH_BEATS $c0(mis) $c1(mis)" }
    if {$c0(err) != 0 || $c1(err) != 0} { set ok 0 ; set why "len $len: RX_ERR_FRAMES $c0(err) $c1(err)" }

    puts "STEP 3 len $len latched while stopped client0 [rd [expr {$PG0 + $R_LATCHED_TX_FRAMES}]] [rd [expr {$PG0 + $R_LATCHED_TX_BYTES}]] [rd [expr {$PG0 + $R_LATCHED_RX_FRAMES}]] [rd [expr {$PG0 + $R_LATCHED_RX_BYTES}]] [rd [expr {$PG0 + $R_LATCHED_RX_MISMATCH}]]"
    wr [expr {$PG0 + $R_CTL}] $CTL_CLEAR
    after 20
    puts "STEP 3 len $len latched while clear held client0 [rd [expr {$PG0 + $R_LATCHED_TX_FRAMES}]] [rd [expr {$PG0 + $R_LATCHED_TX_BYTES}]] [rd [expr {$PG0 + $R_LATCHED_RX_FRAMES}]] [rd [expr {$PG0 + $R_LATCHED_RX_BYTES}]] [rd [expr {$PG0 + $R_LATCHED_RX_MISMATCH}]]"
    wr [expr {$PG0 + $R_CTL}] 0x0
  }
  want 3 $ok $why
  step_result 3 1 $why
}

if {[lsearch $steps 4] >= 0} {
  set ok 1
  set why "the rate table is filled at every size"
  puts "STEP 4 method: two clean bursts per size, both ended by TX_FRAME_LIMIT on a frame boundary and never by clearing CTL_ENABLE, because a mid-frame stop truncates a frame on the wire and unlocks the far end checker. Burst A carries the rate and is timed whole, per client: its frame count is exactly TX_FRAME_LIMIT, so no counter is read for it and no window inside the burst exists for the burst to end inside. It is sized from the line rate SEG_GEOMETRY reports and from the len + 24 wire slot, so it lasts NIA_RATE_S seconds at every size and at every rate, and the only error left is the host bracket on one long interval. Burst B is sized under 4 GB and carries the byte exact equality."
  puts "STEP 4 TABLE len dir frames_per_s payload_Gbps wire_Gbps line_fps window_ms slot_Gbps pct_of_line"
  foreach len $rate_sizes {
    set fps_line   [expr {$::nia_line_bytes_per_s / ($len + 24.0)}]
    set rate_limit [expr {int($rate_s * $fps_line)}]
    pg_setup $PG0 $len 0 $rate_limit
    pg_setup $PG1 $len 0 $rate_limit
    set d0 0 ; set d1 0 ; set tb0 0 ; set tb1 0
    pg_enable $PG0 ; set ta0 [now_us]
    pg_enable $PG1 ; set ta1 [now_us]
    set t_wait [now_us]
    set tmo_ms [expr {int($rate_s * 1000) + $burst_tmo}]
    while {1} {
      if {!$d0 && ([rd [expr {$PG0 + $R_STATUS}]] & $ST_DONE)} { set d0 1 ; set tb0 [now_us] }
      if {!$d1 && ([rd [expr {$PG1 + $R_STATUS}]] & $ST_DONE)} { set d1 1 ; set tb1 [now_us] }
      if {$d0 && $d1} { break }
      if {([now_us] - $t_wait) / 1000 > $tmo_ms} { break }
    }
    after 50
    pg_disable $PG0
    pg_disable $PG1
    foreach {dir t_a t_b done} [list 0to1 $ta0 $tb0 $d0 1to0 $ta1 $tb1 $d1] {
      if {!$done} {
        puts "STEP 4 len $len $dir the rate burst did not report done inside [expr {$tmo_ms}] ms"
        set ok 0 ; set why "len $len $dir: the rate burst did not report done"
        continue
      }
      set win_s [expr {($t_b - $t_a) / 1000000.0}]
      set fps [expr {$rate_limit / $win_s}]
      set gbps_payload [expr {$fps * $len * 8 / 1e9}]
      set gbps_wire    [expr {$fps * ($len + 20) * 8 / 1e9}]
      set util_pct     [expr {$fps * ($len + 24) * 8 / 1e9}]
      set util_frac    [expr {100.0 * $util_pct / $::nia_line_gbps}]
      puts [format "STEP 4 TABLE %5d %s %12.0f %8.3f %8.3f %12.0f %6.1f %8.2f %7.2f" \
        $len $dir $fps $gbps_payload $gbps_wire $fps_line [expr {$win_s * 1000}] $util_pct $util_frac]
      if {$win_s < 0.5 * $rate_s} {
        set ok 0
        set why "len $len $dir: the rate burst lasted ${win_s}s against a target of ${rate_s}s, so it was mis-sized"
      }
    }

    array set b [burst $len]
    array set e0 [pg_counters $PG0]
    array set e1 [pg_counters $PG1]
    puts "STEP 4 len $len equality burst limit $b(limit) done $b(done) elapsed [expr {$b(us)/1000}] ms client0 tx $e0(txf)/$e0(txb) rx $e0(rxf)/$e0(rxb) client1 tx $e1(txf)/$e1(txb) rx $e1(rxf)/$e1(rxb) mismatch $e0(mis) $e1(mis) err $e0(err) $e1(err) stall $e0(stall) $e1(stall)"
    if {!$b(done)} { set ok 0 ; set why "len $len: the equality burst did not report done" }
    if {$e0(txf) != $e1(rxf) || $e1(txf) != $e0(rxf)} { set ok 0 ; set why "len $len: frame counts not matched across the wire" }
    if {$e0(txb) != $e1(rxb) || $e1(txb) != $e0(rxb)} { set ok 0 ; set why "len $len: byte counts not matched across the wire" }
    if {$e0(mis) != 0 || $e1(mis) != 0 || $e0(err) != 0 || $e1(err) != 0} {
      set ok 0 ; set why "len $len: mismatch $e0(mis) $e1(mis) err $e0(err) $e1(err)"
    }
  }
  want 4 $ok $why
  step_result 4 1 $why
}

if {[lsearch $steps 5] >= 0} {
  set stall0 [rd [expr {$PG0 + $R_STALL_CYCLE}]]
  set stall1 [rd [expr {$PG1 + $R_STALL_CYCLE}]]
  set sta0 [rd [expr {$PG0 + $R_STATUS}]]
  set sta1 [rd [expr {$PG1 + $R_STATUS}]]
  puts "STEP 5 STALL_CYCLE client0 $stall0 client1 $stall1"
  puts "STEP 5 STATUS client0 [format 0x%02X $sta0] client1 [format 0x%02X $sta1] stall_latched [expr {($sta0 & 0x4) ? 1 : 0}] [expr {($sta1 & 0x4) ? 1 : 0}] underflow [expr {($sta0 & 0x8) ? 1 : 0}] [expr {($sta1 & 0x8) ? 1 : 0}] overflow [expr {($sta0 & 0x10) ? 1 : 0}] [expr {($sta1 & 0x10) ? 1 : 0}]"
  puts "STEP 5 note: the stall latch needs 1024 consecutive back pressured segment clock cycles, rtl/dcmac_seg_pktgen.sv STALL_CYC, so zero means no stall of that length and not the absence of every stalled cycle"
  step_result 5 1 "STALL_CYCLE $stall0 $stall1"
}

if {[lsearch $steps 6] >= 0} {
  set ok 1
  set why "the other group kept counting across the repair"
  if {$reset_grp == 0} {
    set victim $PG0 ; set other $PG1 ; set vname client0 ; set oname client1
    array set mask_of [list rxdp $CC_RXDPRST_0 resync $CC_RESYNC_0 txdp $CC_TXDPRST_0]
  } else {
    set victim $PG1 ; set other $PG0 ; set vname client1 ; set oname client0
    array set mask_of [list rxdp $CC_RXDPRST_1 resync $CC_RESYNC_1 txdp $CC_TXDPRST_1]
  }
  if {![info exists mask_of($repair)]} {
    puts "STEP 6 RESULT FAIL NIA_REPAIR=$repair is not one of rxdp resync txdp"
    exit 3
  }
  set mask $mask_of($repair)
  puts "STEP 6 repair $repair to group $reset_grp only, command bit mask [format 0x%02X $mask]"

  pg_setup $victim 512 0 0
  pg_setup $other  512 0 0
  pg_enable $victim
  pg_enable $other
  after 200

  array set o_before [pg_counters $other]
  array set v_before [pg_counters $victim]
  array set l_before [link_status]
  puts "STEP 6 before $oname rx $o_before(rxf) frames $o_before(rxb) bytes mismatch $o_before(mis) err $o_before(err)"
  puts "STEP 6 before $vname rx $v_before(rxf) frames $v_before(rxb) bytes"
  puts "STEP 6 before link_up $l_before(up) aligned $l_before(aligned)"

  set t_rst [now_us]
  cmd_assert_then_clear $mask 5
  set down 0
  set rec_ms -1
  set mono 1
  set zeroed_ms -1
  set wraps 0
  set prev_rxf $o_before(rxf)
  set prev_rxb $o_before(rxb)
  set moved 0

  while {1} {
    set st  [rd [expr {$CMD + $C_STATUS}]]
    set up  [expr {$st & 0x3}]
    set rxf [rd [expr {$other + $R_RX_FRAMES}]]
    set rxb [rd [expr {$other + $R_RX_BYTES}]]
    set el_ms [expr {([now_us] - $t_rst) / 1000}]
    if {$rxf < $prev_rxf} {
      set mono 0
      if {$zeroed_ms < 0} { set zeroed_ms $el_ms }
      puts "STEP 6 $oname frame count went backwards at $el_ms ms: rx $prev_rxf -> $rxf frames, $prev_rxb -> $rxb bytes, which is a reset of the other group's data path"
    } elseif {$rxb < $prev_rxb} {
      incr wraps
    }
    if {$rxf > $prev_rxf} { set moved 1 }
    set prev_rxf $rxf
    set prev_rxb $rxb
    if {$up != 3} { set down 1 }
    if {$down && $up == 3} { set rec_ms $el_ms ; break }
    if {$el_ms > $bringup_tmo} { break }
    if {!$down && $el_ms > $obs_ms} { break }
  }
  array set l_after [link_status]
  array set o_after [pg_counters $other]
  array set v_after [pg_counters $victim]
  puts "STEP 6 link dropped during the repair: $down, carrier back at $rec_ms ms, the other group's frame count first went backwards at $zeroed_ms ms, its byte counter wrapped $wraps times, link_up now $l_after(up) aligned $l_after(aligned) retry $l_after(retry)"
  puts "STEP 6 after $oname rx $o_after(rxf) frames $o_after(rxb) bytes mismatch $o_after(mis) err $o_after(err) monotone $mono advanced $moved"
  puts "STEP 6 after $vname rx $v_after(rxf) frames $v_after(rxb) bytes mismatch $v_after(mis) err $v_after(err)"

  set v6a [expr {$mono ? 1 : 0}]
  set v6b [expr {($o_after(mis) == $o_before(mis) && $o_after(err) == $o_before(err)) ? 1 : 0}]
  set v6c [expr {($l_after(up) == 3) ? 1 : 0}]
  puts "STEP 6 VERDICT 6a other group monotone across the repair: [expr {$v6a ? {PASS} : {FAIL}}]"
  puts "STEP 6 VERDICT 6b other group counted no error across the repair: [expr {$v6b ? {PASS} : {FAIL}}] mismatch $o_before(mis) to $o_after(mis), err $o_before(err) to $o_after(err)"
  puts "STEP 6 VERDICT 6c the reset group's carrier is up again inside $bringup_tmo ms: [expr {$v6c ? {PASS} : {FAIL}}] at $rec_ms ms"
  if {!$v6a} { set ok 0 ; set why "$oname counters were not monotone across the repair" }
  if {!$v6b} { set ok 0 ; set why "$oname counted an error across the repair: mismatch $o_before(mis) to $o_after(mis), err $o_before(err) to $o_after(err)" }
  if {!$v6c} { set ok 0 ; set why "link_up is $l_after(up) after the repair" }

  pg_disable $victim
  pg_disable $other
  after 300

  set clean_a -1
  set clean_seq {}
  for {set k 1} {$k <= $post_bursts} {incr k} {
    array set ba [burst 512]
    array set a0 [pg_counters $PG0]
    array set a1 [pg_counters $PG1]
    set ck [expr {($a0(txf) == $a1(rxf) && $a1(txf) == $a0(rxf) && $a0(txb) == $a1(rxb) &&
                   $a1(txb) == $a0(rxb) && $a0(mis) == 0 && $a1(mis) == 0 &&
                   $a0(err) == 0 && $a1(err) == 0) ? 1 : 0}]
    if {$k == 1} { set clean_a $ck }
    lappend clean_seq [expr {$ck ? {EXACT} : {DIRTY}}]
    puts "STEP 6 burst $k after the repair, no restart: done $ba(done) client0 tx $a0(txf)/$a0(txb) rx $a0(rxf)/$a0(rxb) client1 tx $a1(txf)/$a1(txb) rx $a1(rxf)/$a1(rxb) mismatch $a0(mis) $a1(mis) err $a0(err) $a1(err) byte_exact $ck"
  }
  puts "STEP 6 bursts after the repair with no restart: $clean_seq"

  set t_r [now_us]
  cmd_pulse $CC_RESTART
  set back -1
  while {1} {
    set st [rd [expr {$CMD + $C_STATUS}]]
    set el_ms [expr {([now_us] - $t_r) / 1000}]
    if {($st & 0x3) == 3} { set back $el_ms ; break }
    if {$el_ms > $bringup_tmo} { break }
  }
  puts "STEP 6 bring-up restart: both carriers up at $back ms"
  after 200
  array set b [burst 512]
  array set c0 [pg_counters $PG0]
  array set c1 [pg_counters $PG1]
  puts "STEP 6 burst after the restart: done $b(done) client0 tx $c0(txf)/$c0(txb) rx $c0(rxf)/$c0(rxb) client1 tx $c1(txf)/$c1(txb) rx $c1(rxf)/$c1(rxb) mismatch $c0(mis) $c1(mis) err $c0(err) $c1(err)"
  set clean_b [expr {($c0(txf) == $c1(rxf) && $c1(txf) == $c0(rxf) && $c0(txb) == $c1(rxb) &&
                      $c1(txb) == $c0(rxb) && $c0(mis) == 0 && $c1(mis) == 0 &&
                      $c0(err) == 0 && $c1(err) == 0) ? 1 : 0}]
  puts "STEP 6 VERDICT 6d the first burst after the repair is byte exact: [expr {$clean_a ? {PASS} : {FAIL}}]"
  set later_clean [expr {[lsearch [lrange $clean_seq 1 end] DIRTY] < 0}]
  puts "STEP 6 VERDICT 6f every later burst after the repair is byte exact with no restart: [expr {$later_clean ? {PASS} : {FAIL}}], the sequence was $clean_seq"
  puts "STEP 6 VERDICT 6e a burst after one bring-up restart is byte exact: [expr {$clean_b ? {PASS} : {FAIL}}]"
  if {!$clean_a} { set ok 0 ; set why "a burst straight after the repair was not byte exact, and one after a bring-up restart was [expr {$clean_b ? {clean} : {not clean either}}]" }
  if {!$clean_b} { set ok 0 ; set why "a burst after a bring-up restart was not byte exact" }
  want 6 $ok $why
  step_result 6 1 "$why, carrier back at $rec_ms ms"
}

if {[lsearch $steps 7] >= 0} {
  set ok 1
  set why "a mid-frame stop is not what dirties the data path"

  array set r0 [burst 512]
  array set p0 [pg_counters $PG0]
  array set p1 [pg_counters $PG1]
  set clean0 [expr {($p0(txf) == $p1(rxf) && $p1(txf) == $p0(rxf) && $p0(txb) == $p1(rxb) &&
                     $p1(txb) == $p0(rxb) && $p0(mis) == 0 && $p1(mis) == 0) ? 1 : 0}]
  puts "STEP 7 baseline clean burst byte exact $clean0 client0 tx $p0(txf)/$p0(txb) rx $p0(rxf)/$p0(rxb) client1 tx $p1(txf)/$p1(txb) rx $p1(rxf)/$p1(rxb) mismatch $p0(mis) $p1(mis) err $p0(err) $p1(err)"
  want 7 $clean0 "the baseline burst was not byte exact, so nothing after it can be attributed"

  puts "STEP 7 200 ms of unlimited traffic, then CTL_ENABLE cleared while a frame is in flight"
  pg_setup $PG0 512 0 0
  pg_setup $PG1 512 0 0
  pg_enable $PG0
  pg_enable $PG1
  after 200
  pg_disable $PG0
  pg_disable $PG1
  after 300
  array set q0 [pg_counters $PG0]
  array set q1 [pg_counters $PG1]
  puts "STEP 7 straight after the mid-frame stop client0 tx $q0(txf)/$q0(txb) rx $q0(rxf)/$q0(rxb) mismatch $q0(mis) err $q0(err) status [format 0x%02X $q0(status)]"
  puts "STEP 7 straight after the mid-frame stop client1 tx $q1(txf)/$q1(txb) rx $q1(rxf)/$q1(rxb) mismatch $q1(mis) err $q1(err) status [format 0x%02X $q1(status)]"
  array set l [link_status]
  puts "STEP 7 link after the mid-frame stop link_up $l(up) aligned $l(aligned) seq_state $l(state) retry $l(retry)"

  array set r1 [burst 512]
  array set u0 [pg_counters $PG0]
  array set u1 [pg_counters $PG1]
  set clean1 [expr {($u0(txf) == $u1(rxf) && $u1(txf) == $u0(rxf) && $u0(txb) == $u1(rxb) &&
                     $u1(txb) == $u0(rxb) && $u0(mis) == 0 && $u1(mis) == 0) ? 1 : 0}]
  puts "STEP 7 burst after the mid-frame stop byte exact $clean1 client0 tx $u0(txf)/$u0(txb) rx $u0(rxf)/$u0(rxb) client1 tx $u1(txf)/$u1(txb) rx $u1(rxf)/$u1(rxb) mismatch $u0(mis) $u1(mis) err $u0(err) $u1(err)"

  set t_r [now_us]
  cmd_pulse $CC_RESTART
  set back -1
  while {1} {
    set st [rd [expr {$CMD + $C_STATUS}]]
    set el_ms [expr {([now_us] - $t_r) / 1000}]
    if {($st & 0x3) == 3 && $el_ms > 50} { set back $el_ms ; break }
    if {$el_ms > $bringup_tmo} { break }
  }
  after 200
  array set r2 [burst 512]
  array set w0 [pg_counters $PG0]
  array set w1 [pg_counters $PG1]
  set clean2 [expr {($w0(txf) == $w1(rxf) && $w1(txf) == $w0(rxf) && $w0(txb) == $w1(rxb) &&
                     $w1(txb) == $w0(rxb) && $w0(mis) == 0 && $w1(mis) == 0) ? 1 : 0}]
  puts "STEP 7 burst after one bring-up restart at $back ms byte exact $clean2 client0 tx $w0(txf)/$w0(txb) rx $w0(rxf)/$w0(rxb) client1 tx $w1(txf)/$w1(txb) rx $w1(rxf)/$w1(rxb) mismatch $w0(mis) $w1(mis) err $w0(err) $w1(err)"
  puts "STEP 7 VERDICT 7a a burst after a mid-frame stop, with no repair command issued, is byte exact: [expr {$clean1 ? {PASS} : {FAIL}}]"
  puts "STEP 7 VERDICT 7b a burst after one bring-up restart is byte exact: [expr {$clean2 ? {PASS} : {FAIL}}]"
  if {!$clean1} { set ok 0 ; set why "a mid-frame stop alone dirties the data path: the next burst was not byte exact, and a bring-up restart [expr {$clean2 ? {repaired it} : {did not repair it}}]" }
  if {!$clean2} { set ok 0 ; set why "a burst after a bring-up restart was not byte exact" }
  step_result 7 $ok $why
}

puts "TEST DONE failures $::fail_count"
if {$::fail_count > 0} { exit 3 }
exit 0
