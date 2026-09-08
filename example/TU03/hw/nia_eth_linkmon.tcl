# -----------------------------------------------------------------------------
# File        : nia_eth_linkmon.tcl
# Description : Link monitor for the nia-eth one board and two cage images. It
#               samples the command window, the per port PHY status behind the
#               statistics snapshot and the two generator windows, reports every
#               link and alignment transition as it happens, and prints a summary
#               when it stops.
#
#               The statistics snapshot of this design is checked rather than
#               trusted. A counter that traffic must move is read alongside the
#               forward error correction counters, so a zero codeword count is
#               reported as an unlatched snapshot when the traffic counter is also
#               zero, and as a clean link when it is not. Without that check a
#               stale snapshot and a perfect link are the same reading.
#
# Environment : NIA_WINDOW     host base address, default 0xA4000000
#               NIA_MON_S      seconds between samples, default 2
#               NIA_MON_DUR_S  seconds to run, 0 runs until interrupted, default 60
#               NIA_MON_LEN    frame length for the load generator, default 1518
#               NIA_MON_LOAD   1 enables the generators, 0 observes only, default 1
#               NIA_MON_CSV    optional path for one comma separated row a sample
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# -----------------------------------------------------------------------------

set base     [expr {[info exists env(NIA_WINDOW)]    ? $env(NIA_WINDOW)    : 0xA4000000}]
set period_s [expr {[info exists env(NIA_MON_S)]     ? $env(NIA_MON_S)     : 2}]
set dur_s    [expr {[info exists env(NIA_MON_DUR_S)] ? $env(NIA_MON_DUR_S) : 60}]
set mon_len  [expr {[info exists env(NIA_MON_LEN)]   ? $env(NIA_MON_LEN)   : 1518}]
set load_en  [expr {[info exists env(NIA_MON_LOAD)]  ? $env(NIA_MON_LOAD)  : 1}]
set csv_path [expr {[info exists env(NIA_MON_CSV)]   ? $env(NIA_MON_CSV)   : ""}]

set PG0 [expr {$base + 0x0000}]
set CMD [expr {$base + 0x1000}]
set PG1 [expr {$base + 0x2000}]

set MODULE_TYPE_SEG  0x4E535047
set MODULE_TYPE_AXIS 0x4E415047

set R_MODULE_TYPE       0x00
set R_MAP_VERSION       0x04
set R_GEOMETRY          0x0C
set R_FEATURES          0x10
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

set C_CTL       0x00
set C_STAT_IDX  0x04
set C_STATUS    0x08
set C_SEQ       0x0C
set C_RXPHY     0x10
set C_RETRY     0x14
set C_STAT_DATA 0x18
set C_FSM       0x1C

set CC_STATS 0x02

set STATS_PER 22
set K_PHY_RT     0
set K_FEC_CW     11
set K_FEC_CORR   12
set K_FEC_UNCORR 13
set K_SRX_PKTS   16

proc rd {addr} {
  set v 0
  if {[catch {set v [lindex [mrd -force $addr] 1]}]} { return 0 }
  if {![string is integer -strict $v]} {
    if {[catch {set v [expr {"0x$v"}]}]} { return 0 }
  }
  return $v
}

proc wr {addr value} { catch { mwr -force $addr $value } }

proc now_ms {} {
  if {[catch {set t [clock milliseconds]}]} { set t [expr {[clock seconds] * 1000}] }
  return $t
}

proc stat_at {index} {
  global CMD C_STAT_IDX C_STAT_DATA
  wr [expr {$CMD + $C_STAT_IDX}] $index
  after 2
  return [rd [expr {$CMD + $C_STAT_DATA}]]
}

proc stat_refresh {} {
  global CMD C_CTL CC_STATS
  wr [expr {$CMD + $C_CTL}] 0x0
  wr [expr {$CMD + $C_CTL}] $CC_STATS
  after 40
  wr [expr {$CMD + $C_CTL}] 0x0
  after 300
}

proc gen_counters {pg} {
  global R_TX_FRAMES R_TX_BYTES R_RX_FRAMES R_RX_BYTES R_RX_ERR_FRAMES R_RX_MISMATCH_BEATS R_STATUS
  set c(txf) [rd [expr {$pg + $R_TX_FRAMES}]]
  set c(txb) [rd [expr {$pg + $R_TX_BYTES}]]
  set c(rxf) [rd [expr {$pg + $R_RX_FRAMES}]]
  set c(rxb) [rd [expr {$pg + $R_RX_BYTES}]]
  set c(err) [rd [expr {$pg + $R_RX_ERR_FRAMES}]]
  set c(mis) [rd [expr {$pg + $R_RX_MISMATCH_BEATS}]]
  set c(st)  [rd [expr {$pg + $R_STATUS}]]
  return [array get c]
}

proc link_sample {} {
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

proc phy_rt_str {values} {
  set out {}
  foreach v $values { lappend out [format 0x%02X $v] }
  return [join $out ,]
}

proc ratio_str {num den} {
  if {$den <= 0} { return "n/a" }
  if {$num <= 0} { return "0" }
  return [format "%.2e" [expr {double($num) / $den}]]
}

connect -url TCP:localhost:3121
targets -set -filter {name =~ "DPC"}

set mt [rd [expr {$PG0 + $R_MODULE_TYPE}]]
if {$mt == $MODULE_TYPE_SEG} {
  set kind segmented
} elseif {$mt == $MODULE_TYPE_AXIS} {
  set kind AXI-Stream
} else {
  puts "LINKMON FAIL MODULE_TYPE [format 0x%08X $mt] is neither the segmented nor the AXI-Stream instrument"
  exit 2
}

set geom [rd [expr {$PG0 + $R_GEOMETRY}]]
set gh [expr {($geom >> 16) & 0xFFFF}]
set gl [expr {$geom & 0xFFFF}]
if {$kind eq "segmented"} {
  set geom_str "N_SEG $gh SEG_W $gl"
  set n_blk 2
} else {
  set geom_str "DATA_W $gl KEEP_W $gh"
  set n_blk 2
}
puts "LINKMON instrument $kind, MAP_VERSION [format 0x%08X [rd [expr {$PG0 + $R_MAP_VERSION}]]], $geom_str"
puts "LINKMON window [format 0x%08X $base], sample every ${period_s}s, duration ${dur_s}s, load $load_en at $mon_len bytes"

if {$load_en} {
  foreach pg [list $PG0 $PG1] {
    wr [expr {$pg + $R_CTL}] 0x2
    wr [expr {$pg + $R_LEN_MIN}] $mon_len
    wr [expr {$pg + $R_LEN_MAX}] $mon_len
    wr [expr {$pg + $R_LEN_MODE}] 0
    wr [expr {$pg + $R_TX_FRAME_LIMIT}] 0
    wr [expr {$pg + $R_CTL}] 0x0
  }
  foreach pg [list $PG0 $PG1] { wr [expr {$pg + $R_CTL}] 0x1 }
  after 500
}

set fh ""
if {$csv_path ne ""} {
  set fh [open $csv_path w]
  puts $fh "elapsed_s,up,aligned,fault,access_fault,retry,seq_state,rxphy,phy_rt_g0p0,phy_rt_g1p0,fec_cw_delta,fec_corr_delta,cer,pg0_rxf,pg0_mis,pg1_rxf,pg1_mis"
  flush $fh
}

set t0 [now_ms]
set samples 0
set up_samples 0
set transitions 0
set align_changes 0
set prev_up -1
set prev_align -1
set worst_cer 0.0
set fec_seen 0
set snapshot_live 0
set snapshot_dead 0
set max_mis 0
set max_err 0
array set prev_fec {}

while {1} {
  set el_ms [expr {[now_ms] - $t0}]
  if {$dur_s > 0 && $el_ms > $dur_s * 1000} { break }

  array set s [link_sample]
  stat_refresh

  set phy_rt {}
  set fec_cw 0
  set fec_co 0
  set fec_un 0
  set srx 0
  for {set b 0} {$b < $n_blk} {incr b} {
    set off [expr {$b * $STATS_PER * 2}]
    lappend phy_rt [stat_at [expr {$off + $K_PHY_RT}]]
    incr fec_cw [stat_at [expr {$off + $K_FEC_CW}]]
    incr fec_co [stat_at [expr {$off + $K_FEC_CORR}]]
    incr fec_un [stat_at [expr {$off + $K_FEC_UNCORR}]]
    incr srx    [stat_at [expr {$off + $K_SRX_PKTS}]]
  }

  array set c0 [gen_counters $PG0]
  array set c1 [gen_counters $PG1]

  set d_cw 0
  set d_co 0
  if {[info exists prev_fec(cw)]} {
    set d_cw [expr {$fec_cw - $prev_fec(cw)}]
    set d_co [expr {$fec_co - $prev_fec(co)}]
    if {$d_cw < 0} { set d_cw 0 }
    if {$d_co < 0} { set d_co 0 }
  }
  set prev_fec(cw) $fec_cw
  set prev_fec(co) $fec_co

  set cer [ratio_str $d_co $d_cw]
  if {$d_cw > 0} {
    set fec_seen 1
    set r [expr {double($d_co) / $d_cw}]
    if {$r > $worst_cer} { set worst_cer $r }
  }

  set traffic_moved [expr {($c0(rxf) > 0 || $c1(rxf) > 0) ? 1 : 0}]
  if {$fec_cw == 0 && $srx == 0 && $traffic_moved} {
    incr snapshot_dead
  } elseif {$fec_cw > 0 || $srx > 0} {
    incr snapshot_live
  }

  incr samples
  if {$s(up) == 0x3} { incr up_samples }
  if {$prev_up >= 0 && $s(up) != $prev_up} {
    incr transitions
    puts [format "LINKMON %7.1fs EVENT link_up %d -> %d, aligned %d, retry %d, fault %d" \
          [expr {$el_ms / 1000.0}] $prev_up $s(up) $s(aligned) $s(retry) $s(fault)]
  }
  if {$prev_align >= 0 && $s(aligned) != $prev_align} {
    incr align_changes
    puts [format "LINKMON %7.1fs EVENT aligned %d -> %d while link_up %d" \
          [expr {$el_ms / 1000.0}] $prev_align $s(aligned) $s(up)]
  }
  set prev_up $s(up)
  set prev_align $s(aligned)

  if {$c0(mis) > $max_mis} { set max_mis $c0(mis) }
  if {$c1(mis) > $max_mis} { set max_mis $c1(mis) }
  if {$c0(err) > $max_err} { set max_err $c0(err) }
  if {$c1(err) > $max_err} { set max_err $c1(err) }

  puts [format "LINKMON %7.1fs up %d aligned %d fault %d afault %d retry %-3d seq %2d rxphy 0x%08X phy_rt %s  cw+%-10d corr+%-6d CER %-9s  pg0 rx %d mis %d  pg1 rx %d mis %d" \
        [expr {$el_ms / 1000.0}] $s(up) $s(aligned) $s(fault) $s(afault) $s(retry) $s(state) \
        $s(rxphy) [phy_rt_str $phy_rt] \
        $d_cw $d_co $cer $c0(rxf) $c0(mis) $c1(rxf) $c1(mis)]

  if {$fh ne ""} {
    puts $fh [format "%.1f,%d,%d,%d,%d,%d,%d,0x%08X,0x%02X,0x%02X,%d,%d,%s,%d,%d,%d,%d" \
              [expr {$el_ms / 1000.0}] $s(up) $s(aligned) $s(fault) $s(afault) $s(retry) $s(state) \
              $s(rxphy) [lindex $phy_rt 0] [lindex $phy_rt 1] $d_cw $d_co $cer \
              $c0(rxf) $c0(mis) $c1(rxf) $c1(mis)]
    flush $fh
  }

  after [expr {int($period_s * 1000)}]
}

if {$load_en} { foreach pg [list $PG0 $PG1] { wr [expr {$pg + $R_CTL}] 0x0 } }
if {$fh ne ""} { close $fh }

set dur [expr {([now_ms] - $t0) / 1000.0}]
puts ""
puts "LINKMON SUMMARY"
puts [format "  duration            %.1fs over %d sample(s)" $dur $samples]
puts [format "  both groups up      %d of %d sample(s)" $up_samples $samples]
puts [format "  link_up transitions %d" $transitions]
puts [format "  aligned changes     %d" $align_changes]
puts [format "  worst mismatch      %d beat(s), worst rx error %d frame(s)" $max_mis $max_err]
if {$fec_seen} {
  puts [format "  worst pre-FEC CER   %.2e over one sample interval" $worst_cer]
} elseif {$snapshot_dead > 0} {
  puts "  pre-FEC CER         NOT MEASURED. The codeword counters and the received packet"
  puts "                      counter of the statistics snapshot both read zero while the"
  puts "                      generator counters advanced, so the snapshot is not being"
  puts "                      latched and the zero is an artefact and not a clean link."
  puts "                      dcmac_ctl_seq reserves the pmtick block at P_B17 and drives no"
  puts "                      branch over it, so no tick is written before the counter reads."
} else {
  puts "  pre-FEC CER         no codewords counted and no traffic seen, so nothing to report"
}
puts [format "  statistics snapshot live in %d sample(s), stale in %d" $snapshot_live $snapshot_dead]
if {$transitions > 0 || $align_changes > 0} {
  puts "  RESULT UNSTABLE the link changed state during the observation"
} elseif {$up_samples == $samples && $samples > 0} {
  puts "  RESULT STABLE both groups stayed up for every sample"
} else {
  puts "  RESULT DOWN the link was not up for every sample and did not transition"
}
disconnect
exit 0
