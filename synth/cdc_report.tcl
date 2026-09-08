# ---------------------------------------------------------------------------
# File        : cdc_report.tcl
# Description : Reads a checkpoint and reports every clock domain crossing that Vivado
#               classifies as unsafe, together with the safe ones for context. This is the
#               authoritative answer to the question a regular expression cannot answer:
#               which signals cross a domain without being captured in it.
#
#               The measured reason it exists: cfg_hdr_enable_r of dcmac_axis_pktgen was
#               written on axil_aclk and read by the frame checker on net_clk inside the
#               comparison of every one of KEEP_W lanes, and in m400u391 it presented as 853
#               endpoints crossing at -2.344 ns with the bit replicated nine times. Four
#               other configuration registers in the same module were correctly
#               re-registered, so the fault was invisible to review.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set dcp [lindex $argv 0]
if {$dcp eq "" || ![file exists $dcp]} { puts "CDC_ERROR checkpoint '$dcp' is absent" ; exit 1 }
open_checkpoint $dcp
puts "CDC_DCP $dcp"

set rpt [file join [pwd] cdc_full.rpt]
report_cdc -details -file $rpt
puts "CDC_REPORT $rpt"

# The severity counts and the unsafe list are read from the report, because
# get_cdc_violations is absent from Vivado 2025.2. The summary rows read
# "CDC-<n>  <severity>  <count>  <description>", and each detail row carries the
# severity, the check and the endpoints.
array set nia_count {Critical 0 Warning 0 Info 0}
set nia_unsafe [list]
set nia_src ""
set nia_dst ""
if {[file exists $rpt]} {
  set fh [open $rpt r]
  foreach line [split [read $fh] "\n"] {
    if {[regexp {^CDC-[0-9]+\s+(Critical|Warning|Info)\s+([0-9]+)\s} $line -> sev cnt]} {
      incr nia_count($sev) $cnt
      continue
    }
    if {[regexp {^Source Clock:\s*(\S+)} $line -> nia_src]}      { continue }
    if {[regexp {^Destination Clock:\s*(\S+)} $line -> nia_dst]}  { continue }
    if {[regexp {^\s*[0-9]+\s+(CDC-[0-9]+)\s+(Critical|Warning)\s+(.+)$} $line \
         -> id sev tail]} {
      lappend nia_unsafe [format "%-9s %-7s from=%s to=%s %s" \
        $sev $id $nia_src $nia_dst [string trim [string range $tail 0 56]]]
    }
  }
  close $fh
}

foreach sev {Critical Warning Info} {
  puts "CDC_COUNT $sev $nia_count($sev)"
}

# Every crossing that is not a recognised synchroniser, named with its clocks, because that
# is the list to repair.
puts "CDC_UNSAFE_BEGIN"
foreach line $nia_unsafe {
  puts "CDC_UNSAFE $line"
}
puts "CDC_UNSAFE_END"
puts "CDC_DONE"
