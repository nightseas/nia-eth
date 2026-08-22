# ---------------------------------------------------------------------------
# File        : nia_rate_discover.tcl
# Description : Reads the generated DCMAC to discover the port and sub port layout of the
#               configured rate rather than assuming it.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set rate   [lindex $argv 0]
set outdir [lindex $argv 1]
set part   xcvp1552-vsva2785-2mhp-i-s

file mkdir $outdir
file mkdir $outdir/gtwiz

proc say {msg} {
  global outdir
  puts "RATE_DISCOVER $msg"
  set fh [open $outdir/summary.txt a]
  puts $fh $msg
  close $fh
}

say "BEGIN rate=$rate part=$part [clock format [clock seconds]]"

create_project rate_$rate $outdir/prj -part $part -force
create_ip -name dcmac -vendor xilinx.com -library ip -version 3.1 -module_name dcmac_0

switch -- $rate {
  dual100 {
    set cfg [list \
      CONFIG.MAC_PORT0_CONFIG_C0 {100GAUI-1} \
      CONFIG.MAC_PORT0_ENABLE_AN_LT_C0 {0} \
      CONFIG.MAC_PORT1_CONFIG_C0 {100GAUI-1} \
      CONFIG.MAC_PORT1_ENABLE_C0 {1} \
      CONFIG.MAC_PORT1_ENABLE_AN_LT_C0 {0} \
      CONFIG.MAC_PORT2_ENABLE_C0 {0} \
      CONFIG.MAC_PORT3_ENABLE_C0 {0} \
      CONFIG.MAC_PORT4_ENABLE_C0 {0} \
      CONFIG.MAC_PORT5_ENABLE_C0 {0} \
      CONFIG.TIMESTAMP_CLK_PERIOD_NS {2.4}]
  }
  dual200 {
    set cfg [list \
      CONFIG.MAC_PORT0_CONFIG_C0 {200GAUI-2} \
      CONFIG.MAC_PORT0_ENABLE_AN_LT_C0 {0} \
      CONFIG.MAC_PORT1_ENABLE_C0 {1} \
      CONFIG.MAC_PORT1_ENABLE_AN_LT_C0 {0} \
      CONFIG.MAC_PORT2_CONFIG_C0 {200GAUI-2} \
      CONFIG.MAC_PORT2_ENABLE_C0 {1} \
      CONFIG.MAC_PORT2_ENABLE_AN_LT_C0 {0} \
      CONFIG.MAC_PORT3_ENABLE_C0 {1} \
      CONFIG.MAC_PORT3_ENABLE_AN_LT_C0 {0} \
      CONFIG.MAC_PORT4_ENABLE_C0 {0} \
      CONFIG.MAC_PORT5_ENABLE_C0 {0} \
      CONFIG.TIMESTAMP_CLK_PERIOD_NS {2.4}]
  }
  single400 {
    set cfg [list \
      CONFIG.MAC_PORT0_CONFIG_C0 {400GAUI-4} \
      CONFIG.MAC_PORT0_ENABLE_AN_LT_C0 {0} \
      CONFIG.MAC_PORT1_ENABLE_C0 {1} \
      CONFIG.MAC_PORT1_ENABLE_AN_LT_C0 {0} \
      CONFIG.MAC_PORT2_ENABLE_C0 {1} \
      CONFIG.MAC_PORT2_ENABLE_AN_LT_C0 {0} \
      CONFIG.MAC_PORT3_ENABLE_C0 {1} \
      CONFIG.MAC_PORT3_ENABLE_AN_LT_C0 {0} \
      CONFIG.MAC_PORT4_ENABLE_C0 {0} \
      CONFIG.MAC_PORT5_ENABLE_C0 {0} \
      CONFIG.TIMESTAMP_CLK_PERIOD_NS {2.4}]
  }
  default { say "FAIL unknown rate $rate" ; exit 2 }
}

if {[catch {set_property -dict $cfg [get_ips dcmac_0]} err]} {
  say "FAIL set_property: $err"
  exit 2
}
foreach {k v} $cfg {
  set kk [string range $k 7 end]
  say "IPCFG $kk = [get_property CONFIG.$kk [get_ips dcmac_0]]"
}

generate_target {instantiation_template} [get_ips dcmac_0]

set veo ""
foreach cand [glob -nocomplain $outdir/prj/*.gen/sources_1/ip/dcmac_0/dcmac_0.veo \
                              $outdir/prj/*.srcs/sources_1/ip/dcmac_0/dcmac_0.veo] {
  set veo $cand
}
if {$veo eq ""} {
  set found [glob -nocomplain -directory $outdir/prj -types f -join * * * * * dcmac_0.veo]
  if {[llength $found]} { set veo [lindex $found 0] }
}
say "VEO $veo"

set ports {}
if {$veo ne "" && [file exists $veo]} {
  set fh [open $veo r]
  set txt [read $fh]
  close $fh
  foreach line [split $txt \n] {
    if {[regexp {\.((?:tx|rx)_axis_[a-z0-9_]+)} $line -> p]} { lappend ports $p }
  }
}
set ports [lsort -unique $ports]
set fh [open $outdir/ports.txt w]
foreach p $ports { puts $fh $p }
close $fh
say "CLIENT PORTS [llength $ports] written to ports.txt"
foreach pat {tx_axis_tdata rx_axis_tdata tx_axis_tvalid rx_axis_tvalid tx_axis_tready tx_axis_taf} {
  set hit {}
  foreach p $ports { if {[string match "$pat*" $p]} { lappend hit $p } }
  say "CLIENT $pat -> [join $hit { }]"
}

if {[catch {open_example_project -force -dir $outdir/ex [get_ips dcmac_0]} err]} {
  say "EXDES FAIL open_example_project: $err"
  say "END with ports but no gtwiz"
  exit 3
}
say "EXDES opened"

set n 0
foreach x [glob -nocomplain -directory $outdir/ex -join * * * * * * *gtwiz*.xci] {
  file copy -force $x $outdir/gtwiz/[file tail $x]
  incr n
  say "GTWIZ copied [file tail $x] from $x"
}
if {$n == 0} {
  foreach x [glob -nocomplain -directory $outdir/ex -join * * * * * * * *gtwiz*.xci] {
    file copy -force $x $outdir/gtwiz/[file tail $x]
    incr n
    say "GTWIZ copied [file tail $x] from $x"
  }
}
say "GTWIZ count $n"

set fh [open $outdir/knobs.tcl w]
puts $fh "# read back from the example design of rate $rate on [clock format [clock seconds]]"
foreach ip [get_ips -quiet *gtwiz*] {
  puts $fh "# ip $ip"
  say "GTWIZ IP $ip"
  foreach k {INTF0_NO_OF_LANES NO_OF_QUADS QUAD0_PROT0_LANES INTF0_PRESET GT_TYPE \
             INTF0_GT_SETTINGS NO_OF_INTERFACE REG_CONF_INTF ENABLE_REG_INTERFACE} {
    set v "<unset>"
    catch { set v [get_property CONFIG.$k [get_ips $ip]] }
    puts $fh "set knob($ip,$k) {$v}"
    say "GTWIZ $ip CONFIG.$k = $v"
  }
}
close $fh

say "END ok [clock format [clock seconds]]"
exit 0
