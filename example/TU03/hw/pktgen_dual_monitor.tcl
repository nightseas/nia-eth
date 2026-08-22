# ---------------------------------------------------------------------------
# File        : pktgen_dual_monitor.tcl
# Description : The cable event monitor. A loop of clean bursts with the link status read
#               between them, issuing no command of its own unless asked, so what it
#               records when the cable is pulled and put back is what the design does with
#               no host.
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

set len        [expr {[info exists env(NIA_LEN)]           ? $env(NIA_LEN)           : 512}]
set burst_cap  [expr {[info exists env(NIA_BURST_BYTES)]   ? $env(NIA_BURST_BYTES)   : 3000000000}]
set burst_tmo  [expr {[info exists env(NIA_BURST_MS)]      ? $env(NIA_BURST_MS)      : 3000}]
set duration_s [expr {[info exists env(NIA_DURATION_S)]    ? $env(NIA_DURATION_S)    : 600}]
set wait_ms    [expr {[info exists env(NIA_WAIT_MS)]       ? $env(NIA_WAIT_MS)       : 500}]
set auto_rst   [expr {[info exists env(NIA_AUTO_RESTART)]  ? $env(NIA_AUTO_RESTART)  : 0}]
set rst_after  [expr {[info exists env(NIA_RESTART_AFTER_MS)] ? $env(NIA_RESTART_AFTER_MS) : 10000}]

set R_CTL               0x14
set R_STATUS            0x18
set R_LEN_MIN           0x1C
set R_LEN_MAX           0x20
set R_LEN_MODE          0x24
set R_TX_FRAME_LIMIT    0x30
set R_TX_FRAMES         0x40
set R_TX_BYTES          0x44
set R_RX_FRAMES         0x48
set R_RX_BYTES          0x4C
set R_RX_ERR_FRAMES     0x50
set R_RX_MISMATCH_BEATS 0x54
set R_STALL_CYCLE       0x58

set CTL_ENABLE 0x1
set CTL_CLEAR  0x2
set ST_DONE    0x02

set C_CTL     0x00
set C_STATUS  0x08
set C_SEQ     0x0C
set C_RXPHY   0x10
set C_RETRY   0x14
set C_FSM     0x1C
set CC_RESTART 0x01

fconfigure stdout -buffering line

proc now_us {} {
  if {[catch {set t [clock microseconds]}]} { set t [expr {[clock milliseconds] * 1000}] }
  return $t
}
proc rd {addr} {
  set v [lindex [mrd -force -value $addr 1] 0]
  if {[regexp {^[0-9]+$} $v]} { return [expr {$v + 0}] }
  return [expr {"0x$v" + 0}]
}
proc wr {addr value} { mwr -force $addr $value }

proc el_ms {} { global t_zero ; return [expr {([now_us] - $t_zero) / 1000}] }

proc link_word {} {
  global CMD C_STATUS
  set st [rd [expr {$CMD + $C_STATUS}]]
  return [list [expr {$st & 0x3}] [expr {($st >> 5) & 0x3}] [expr {($st >> 4) & 0x1}] \
               [expr {($st >> 2) & 0x1}] [expr {($st >> 3) & 0x1}]]
}

proc link_detail {} {
  global CMD C_SEQ C_RXPHY C_RETRY C_FSM
  set q [rd [expr {$CMD + $C_SEQ}]]
  return "seq_state [expr {$q & 0x1F}] seq_pc [expr {($q >> 5) & 0xFFFF}] retry [rd [expr {$CMD + $C_RETRY}]] rxphy [format 0x%08X [rd [expr {$CMD + $C_RXPHY}]]] fsm [format 0x%02X [rd [expr {$CMD + $C_FSM}]]]"
}

proc pg_setup {pg len limit} {
  global R_CTL R_LEN_MIN R_LEN_MAX R_LEN_MODE R_TX_FRAME_LIMIT CTL_CLEAR
  wr [expr {$pg + $R_CTL}] $CTL_CLEAR
  wr [expr {$pg + $R_LEN_MIN}] $len
  wr [expr {$pg + $R_LEN_MAX}] $len
  wr [expr {$pg + $R_LEN_MODE}] 0
  wr [expr {$pg + $R_TX_FRAME_LIMIT}] $limit
  wr [expr {$pg + $R_CTL}] 0x0
}

proc counters {pg} {
  global R_TX_FRAMES R_TX_BYTES R_RX_FRAMES R_RX_BYTES R_RX_ERR_FRAMES R_RX_MISMATCH_BEATS R_STALL_CYCLE
  return [list [rd [expr {$pg + $R_TX_FRAMES}]] [rd [expr {$pg + $R_TX_BYTES}]] \
               [rd [expr {$pg + $R_RX_FRAMES}]] [rd [expr {$pg + $R_RX_BYTES}]] \
               [rd [expr {$pg + $R_RX_ERR_FRAMES}]] [rd [expr {$pg + $R_RX_MISMATCH_BEATS}]] \
               [rd [expr {$pg + $R_STALL_CYCLE}]]]
}

connect
set dpc [targets -filter {name =~ "DPC"}]
if {[llength $dpc] == 0} {
  puts "MONITOR FAIL: no DPC target"
  exit 2
}
targets -set -filter {name =~ "DPC"}

set t_zero [now_us]
set limit  [expr {int($burst_cap / $len)}]
puts "MONITOR window pg0 [format 0x%08X $PG0] cmd [format 0x%08X $CMD] pg1 [format 0x%08X $PG1]"
puts "MONITOR burst len $len bytes, TX_FRAME_LIMIT $limit frames, [expr {$limit * $len / 1000000}] MB per burst per direction, burst timeout $burst_tmo ms"
puts "MONITOR duration $duration_s s, auto restart $auto_rst[expr {$auto_rst ? " after $rst_after ms down" : {}}]"
puts "MONITOR it issues no bring-up restart unless auto restart is 1, so a cable event measures what the design does on its own"

lassign [link_word] up_prev al_prev busy_prev flt_prev afl_prev
puts "EVENT [el_ms] start carrier $up_prev aligned $al_prev busy $busy_prev link_fault $flt_prev access_fault $afl_prev [link_detail]"

set n 0
set exact 0
set dirty 0
set aborted 0
set events 0
set down_at -1
set worst_recovery -1
set best_recovery -1
set first_after_recovery 0
set recoveries 0
set healed 0

while {[el_ms] < $duration_s * 1000} {
  lassign [link_word] up al busy flt afl
  if {$up != $up_prev || $al != $al_prev || $flt != $flt_prev || $afl != $afl_prev} {
    incr events
    puts "EVENT [el_ms] carrier $up_prev to $up, aligned $al_prev to $al, link_fault $flt, access_fault $afl, [link_detail]"
    if {$up != 3 && $up_prev == 3} { set down_at [el_ms] }
    if {$up == 3 && $up_prev != 3} {
      set rec [expr {($down_at >= 0) ? [el_ms] - $down_at : -1}]
      incr recoveries
      set first_after_recovery 1
      if {$rec >= 0} {
        if {$worst_recovery < 0 || $rec > $worst_recovery} { set worst_recovery $rec }
        if {$best_recovery  < 0 || $rec < $best_recovery}  { set best_recovery  $rec }
        puts "EVENT [el_ms] carrier returned with no host command, [expr {$rec}] ms after it fell"
      }
    }
    set up_prev $up ; set al_prev $al ; set flt_prev $flt ; set afl_prev $afl
  }

  if {$up != 3} {
    puts "WAIT  [el_ms] carrier $up aligned $al [link_detail]"
    if {$auto_rst && $down_at >= 0 && [el_ms] - $down_at > $rst_after} {
      puts "EVENT [el_ms] auto restart issued after [expr {[el_ms] - $down_at}] ms with the carrier down"
      wr [expr {$CMD + $C_CTL}] 0x0
      wr [expr {$CMD + $C_CTL}] $CC_RESTART
      wr [expr {$CMD + $C_CTL}] 0x0
      set down_at [el_ms]
    }
    after $wait_ms
    continue
  }

  incr n
  pg_setup $PG0 $len $limit
  pg_setup $PG1 $len $limit
  set t_b [now_us]
  wr [expr {$PG0 + $R_CTL}] $CTL_ENABLE
  wr [expr {$PG1 + $R_CTL}] $CTL_ENABLE
  set done 0
  while {1} {
    set s0 [rd [expr {$PG0 + $R_STATUS}]]
    set s1 [rd [expr {$PG1 + $R_STATUS}]]
    if {($s0 & $ST_DONE) && ($s1 & $ST_DONE)} { set done 1 ; break }
    if {([now_us] - $t_b) / 1000 > $burst_tmo} { break }
  }
  set dur_ms [expr {([now_us] - $t_b) / 1000}]
  after 30
  wr [expr {$PG0 + $R_CTL}] 0x0
  wr [expr {$PG1 + $R_CTL}] 0x0
  lassign [counters $PG0] tf0 tb0 rf0 rb0 er0 mi0 sc0
  lassign [counters $PG1] tf1 tb1 rf1 rb1 er1 mi1 sc1
  set match [expr {($tf0 == $rf1 && $tf1 == $rf0 && $tb0 == $rb1 && $tb1 == $rb0 &&
                    $mi0 == 0 && $mi1 == 0 && $er0 == 0 && $er1 == 0) ? 1 : 0}]
  if {!$done} {
    set verdict ABORTED ; incr aborted
  } elseif {$match} {
    set verdict EXACT ; incr exact
  } else {
    set verdict DIRTY ; incr dirty
  }
  set tag ""
  if {$first_after_recovery} {
    set tag " first_burst_after_recovery"
    set first_after_recovery 0
    if {$verdict eq "EXACT"} { incr healed }
  }
  puts "BURST $n [el_ms] $verdict done $done in $dur_ms ms 0to1 tx $tf0/$tb0 rx $rf1/$rb1 1to0 tx $tf1/$tb1 rx $rf0/$rb0 mismatch $mi0 $mi1 err $er0 $er1 stall $sc0 $sc1 carrier $up aligned $al$tag"
}

puts "SUMMARY bursts $n exact $exact dirty $dirty aborted $aborted"
puts "SUMMARY link status changes $events, carrier recoveries with no host command $recoveries, of which the first burst afterwards was byte exact $healed"
puts "SUMMARY recovery time best $best_recovery ms worst $worst_recovery ms, bounded below by the poll period of this script"
puts "MONITOR DONE"

exit 0
