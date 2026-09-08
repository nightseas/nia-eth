# ---------------------------------------------------------------------------
# File        : build_ip.tcl
# Description : Generates the IP an image needs: the host bridge block design that carries
#               the register aperture, the DCMAC and the transceiver wizards of the
#               selected rate, and the adapter FIFOs. The request is recorded beside the
#               artefact so a later build can tell what the files were generated for.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set nia_root     [file normalize [file join [file dirname [info script]] .. .. ..]]
set part         [expr {[info exists env(NIA_PART)]   ? $env(NIA_PART)   : "xcvp1552-vsva2785-2MHP-i-S"}]
set ip_dir       [expr {[info exists env(NIA_IP_DIR)] ? $env(NIA_IP_DIR) : [file join $nia_root build ip]}]
set ip_src       [expr {[info exists env(NIA_IP_SRC)] ? $env(NIA_IP_SRC) : [file join $nia_root ip]}]
set jobs         [expr {[info exists env(NIA_JOBS)]   ? $env(NIA_JOBS)   : 16}]
set window_base  [expr {[info exists env(NIA_WINDOW)] ? $env(NIA_WINDOW) : 0xA4000000}]
set window_bytes 0x10000
set axil_clk_hz  250000000
set clients      [expr {[info exists env(NIA_CLIENTS)] ? $env(NIA_CLIENTS) : 2}]

set rate         [expr {[info exists env(NIA_RATE)] ? $env(NIA_RATE) : 100}]
if {[lsearch -exact {100 200 400} $rate] < 0} {
  puts "IP FAIL: NIA_RATE=$rate is not one of 100, 200, 400"
  exit 2
}
set gaui_default [expr {$rate == 100 ? 1 : ($rate == 400 ? 4 : 2)}]
set gaui         [expr {[info exists env(NIA_GAUI)] ? $env(NIA_GAUI) : $gaui_default}]
if {$gaui != $gaui_default && !($rate == 200 && $gaui == 4)} {
  puts "IP FAIL: NIA_RATE=$rate with NIA_GAUI=$gaui is not a configuration this repository carries.\
The electrical lane count is fixed by the port pattern and the cage wiring: 100 takes 1, 400 takes 4,\
and 200 takes 2 or 4."
  exit 2
}
# CAUTION: 200GAUI-4 is out of scope for this release, which covers 112G PAM4 a lane only:
# 100GAUI-1, 200GAUI-2 and 400GAUI-4 all run 106.25 Gb/s a lane. A 200GAUI-4 cage needs four
# lanes at 53.125 and its wizards here are preset at 106.25, so the pair it generates is
# misconfigured. The source is kept for later work and this refusal keeps it out of every build.
if {$rate == 200 && $gaui == 4} {
  puts "IP FAIL: NIA_RATE=200 with NIA_GAUI=4 selects 200GAUI-4, which is out of scope for this\
release. This release covers 112G PAM4 a lane only. Leave NIA_GAUI unset to generate 200GAUI-2."
  exit 2
}
set rate_key [expr {($rate == 200 && $gaui == 4) ? "200g4" : $rate}]
if {$rate != 100} {
  source [file join $nia_root ip dcmac_ip_rate.tcl]
  set rate_src [file join $ip_src [nia_rate_ip_subdir $rate_key]]
  set clients [expr {$rate == 400 ? 1 : 2}]
} else {
  set rate_src [file join $ip_src rate$rate]
}
puts "IP RATE $rate"
puts "IP GAUI $gaui"
puts "IP CONFIG $rate_key"

set required [list dcmac_0_gtwiz_versal_0.xci dcmac_0_clk_wiz_0.xci]
if {$clients > 1} { lappend required dcmac_0_gtwiz_versal_1.xci }
if {$rate == 100} {
  foreach x $required {
    if {![file exists [file join $ip_src $x]]} {
      puts "IP FAIL: $x is absent from NIA_IP_SRC=$ip_src. It is a generated product of the DCMAC example design and this script does not invent it."
      exit 2
    }
  }
} else {
  foreach x [nia_rate_ip_files $rate_key] {
    if {![file exists [file join $rate_src $x]]} {
      puts "IP FAIL: $x is absent from $rate_src. It is a generated product for configuration $rate_key and this script does not invent it; ip/dcmac_gtwiz_200g4.tcl produces the 200GAUI-4 pair."
      exit 2
    }
  }
  if {![file exists [file join $ip_src dcmac_0_clk_wiz_0.xci]]} {
    puts "IP FAIL: dcmac_0_clk_wiz_0.xci is absent from NIA_IP_SRC=$ip_src"
    exit 2
  }
  puts "IP RATE SRC $rate_src"
}
puts "IP SRC $ip_src"

set pktgen [expr {[info exists env(NIA_PKTGEN)] ? $env(NIA_PKTGEN) : "axis"}]

proc nia_ip_request {} {
  set out [list]
  foreach var {NIA_RATE NIA_GAUI NIA_CLIENTS NIA_PKTGEN NIA_PART} {
    lappend out "$var=[expr {[info exists ::env($var)] ? $::env($var) : {}}]"
  }
  return [join $out " "]
}
if {[lsearch -exact {seg axis} $pktgen] < 0} {
  puts "IP FAIL: NIA_PKTGEN=$pktgen is not one of seg, axis"
  exit 2
}
puts "IP PKTGEN $pktgen"

file mkdir $ip_dir

puts "IP STAGE bridge"
source [file join $nia_root ip dcmac_host_bridge_bd.tcl]
if {[catch {dcmac_host_bridge_create [file join $ip_dir bd] $part \
              $window_base $window_bytes $axil_clk_hz} err]} {
  puts "IP FAIL: the host bridge block design did not build: $err"
  exit 2
}

create_project -in_memory -part $part
set_property target_language Verilog [current_project]
set_property ip_output_repo $ip_dir [current_project]

puts "IP CLIENTS $clients"
if {$rate != 100} {
  puts "IP STAGE create"
  dcmac_create_ips_rate $rate_key $ip_src $rate_src
} elseif {$clients > 1} {
  source [file join $nia_root ip dcmac_ip_dual.tcl]
  puts "IP STAGE create"
  dcmac_create_ips_dual $ip_src
} else {
  source [file join $nia_root ip dcmac_ip.tcl]
  puts "IP STAGE create"
  dcmac_create_ips $ip_src $ip_dir
}

if {$pktgen eq "axis"} {
  puts "IP STAGE fifo"
  set NIA_FIFO_IP_DIR $ip_dir
  source [file join $nia_root ip dcmac_fifo_ip.tcl]
}

foreach ip [get_ips] {
  set d [get_property IP_DIR [get_ips $ip]]
  puts "IP PRESENT $ip $d"
}

puts "IP STAGE polarity"
if {$rate != 100} {
  puts "IP POLARITY done by the $rate_key recipe"
} elseif {$clients == 1} {
  source [file join $nia_root ip dcmac_polarity.tcl]
  nia_dp_pol_enable_ports
}

puts "IP STAGE upgrade"
set stale [get_ips -filter {UPGRADE_VERSIONS != ""}]
if {[llength $stale] > 0} { upgrade_ip $stale }

puts "IP STAGE generate"
generate_target {instantiation_template synthesis implementation} [get_ips]

puts "IP STAGE synth"
foreach ip [get_ips] {
  set dcp [file join [get_property IP_DIR [get_ips $ip]] "${ip}.dcp"]
  if {[file exists $dcp]} {
    puts "IP SYNTH SKIP $ip"
    continue
  }
  if {[catch {synth_ip [get_ips $ip]} err]} {
    puts "IP FAIL: synth_ip $ip: $err"
    exit 2
  }
  puts "IP SYNTH OK $ip"
}

set mf [open [file join $ip_dir ip_manifest.txt] w]
foreach ip [get_ips] {
  set xci [get_property IP_FILE [get_ips $ip]]
  puts $mf $xci
  puts "IP XCI $xci"
}
close $mf
set cf [open [file join $ip_dir ip_config.txt] w]
puts $cf [nia_ip_request]
close $cf
puts "IP DONE $ip_dir"
