# ---------------------------------------------------------------------------
# File        : pktgen_loop_test_stub.tcl
# Description : A stand-in for the debug port that answers the loopback test's register
#               reads and writes from a memory model, so the test can be exercised with no
#               board.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set nia_stub_instrument [expr {[info exists env(NIA_STUB_INSTRUMENT)] ? $env(NIA_STUB_INSTRUMENT) : "axis"}]
set nia_stub_base 0xA4000000
array set nia_stub_mem {}

proc nia_stub_set {addr value} {
  global nia_stub_mem
  set nia_stub_mem([format 0x%08X $addr]) $value
}

proc nia_stub_get {addr} {
  global nia_stub_mem
  set key [format 0x%08X $addr]
  if {[info exists nia_stub_mem($key)]} { return $nia_stub_mem($key) }
  return 0
}

proc nia_stub_init {} {
  global nia_stub_base nia_stub_instrument
  set pg  $nia_stub_base
  set cmd [expr {$nia_stub_base + 0x1000}]
  if {$nia_stub_instrument eq "axis"} {
    nia_stub_set [expr {$pg + 0x00}] 0x4E415047
    nia_stub_set [expr {$pg + 0x0C}] [expr {(64 << 16) | 512}]
  } else {
    nia_stub_set [expr {$pg + 0x00}] 0x4E535047
    nia_stub_set [expr {$pg + 0x0C}] [expr {(2 << 16) | 128}]
  }
  nia_stub_set [expr {$pg + 0x04}] 0x00030001
  nia_stub_set [expr {$pg + 0x10}] 0x00000001
  nia_stub_set [expr {$pg + 0x18}] 0x62
  nia_stub_set [expr {$pg + 0x34}] 7
  nia_stub_set [expr {$pg + 0x40}] 1000
  nia_stub_set [expr {$pg + 0x44}] 64000
  nia_stub_set [expr {$pg + 0x48}] 1000
  nia_stub_set [expr {$pg + 0x4C}] 64000
  nia_stub_set [expr {$cmd + 0x08}] 0x00000001
  nia_stub_set [expr {$cmd + 0x0C}] 0x0000000C
  nia_stub_set [expr {$cmd + 0x1C}] 0x00000013
}

proc mrd {args} {
  set positional {}
  foreach a $args {
    if {[string match "-*" $a]} { continue }
    lappend positional $a
  }
  set addr [lindex $positional 0]
  return [list [format %08X [nia_stub_get $addr]]]
}

proc mwr {args} {
  set positional {}
  foreach a $args {
    if {[string match "-*" $a]} { continue }
    lappend positional $a
  }
  nia_stub_set [lindex $positional 0] [lindex $positional 1]
}

proc connect {args} {}
proc targets {args} { return 1 }
proc after {ms args} { if {[llength $args]} { uplevel 1 $args } }

nia_stub_init
set env(NIA_STEPS) [expr {[info exists env(NIA_STEPS)] ? $env(NIA_STEPS) : "1 5"}]
set here [file dirname [file normalize [info script]]]
source [file join $here pktgen_loop_test.tcl]
