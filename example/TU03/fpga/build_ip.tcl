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
set rate_src [file join $ip_src rate$rate]
if {$rate != 100} {
  set clients [expr {$rate == 400 ? 1 : 2}]
}
puts "IP RATE $rate"

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
  source [file join $nia_root ip dcmac_ip_rate.tcl]
  foreach x [nia_rate_ip_files $rate] {
    if {![file exists [file join $rate_src $x]]} {
      puts "IP FAIL: $x is absent from $rate_src. It is a generated product of the DCMAC example design at NIA_RATE=$rate and this script does not invent it."
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

set pktgen [expr {[info exists env(NIA_PKTGEN)] ? $env(NIA_PKTGEN) : "seg"}]

proc nia_ip_request {} {
  set out [list]
  foreach var {NIA_RATE NIA_CLIENTS NIA_PKTGEN NIA_PART} {
    lappend out "$var=[expr {[info exists ::env($var)] ? $::env($var) : {}}]"
  }
  return [join $out " "]
}
if {[lsearch -exact {seg axis} $pktgen] < 0} {
  puts "IP FAIL: NIA_PKTGEN=$pktgen is not one of seg, axis"
  exit 2
}
if {$pktgen eq "axis" && $rate != 100} {
  puts "IP FAIL: NIA_PKTGEN=axis is built at NIA_RATE=100 only, and was asked for at rate $rate"
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
  dcmac_create_ips_rate $rate $ip_src $rate_src
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
  puts "IP POLARITY done by the rate $rate recipe"
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
