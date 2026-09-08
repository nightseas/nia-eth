# ---------------------------------------------------------------------------
# File        : nia_s2u_ooc_probe.tcl
# Description : Out of context synthesis of rtl/nia_seg_to_unseg.sv on this part at the
#               segment clock.
#               so the two are read side by side. The reference measured on this part at
#               2.558 ns is the acceptance condition for the reimplementation:
#
#                 rate  reference receive slack   reference sequential cells
#                 200G  +0.428                    40855 for the whole file
#                 400G  -0.090                    67915 for the whole file
#
#               NIA_SYSTEM_DEV_PLAN.md Section 11.27 holds those measurements and the
#               conditions they were taken under. A reimplementation that does not reach
#               the reference figure at the same clock does not go into an image, because
#               the ring it replaces already fails that clock by -0.790 before routing.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set part xcvp1552-vsva2785-2mhp-i-s

# The rate names the geometry, exactly as the reference define does, so one variable sets
# both probes and the comparison is of one thing.
set rate [expr {[info exists ::env(NIA_S2U_RATE)] ? $::env(NIA_S2U_RATE) : 200}]
set per  [expr {[info exists ::env(NIA_OOC_NET_PER)] ? $::env(NIA_OOC_NET_PER) : 2.558}]

switch -- $rate {
  100 { set n_seg 2 ; set data_w 256  ; set n_port 1 }
  200 { set n_seg 4 ; set data_w 1024 ; set n_port 1 }
  400 { set n_seg 8 ; set data_w 1024 ; set n_port 2 }
  default {
    puts "S2U_PROBE_ERROR NIA_S2U_RATE=$rate is not one of 100, 200, 400"
    exit 1
  }
}
# The group count follows the module default and is overridable, because it trades slots
# against the slack the pointer has to fill a group.
set n_group [expr {[info exists ::env(NIA_S2U_GROUP)] ? $::env(NIA_S2U_GROUP) :
                   ($n_seg >= ($data_w / 128) ? 2 : 4)}]

set here [file normalize [file dirname [info script]]]
set src  [file normalize [file join $here .. rtl nia_seg_to_unseg.sv]]
if {![file exists $src]} { puts "S2U_PROBE_ERROR $src is absent" ; exit 1 }

create_project -in_memory -part $part
read_verilog -sv $src

puts "S2U_PROBE_REQUEST rate=$rate n_seg=$n_seg seg_w=128 data_w=$data_w n_port=$n_port\
 n_group=$n_group period=$per src=$src"

synth_design -top nia_seg_to_unseg -part $part -mode out_of_context \
             -generic N_SEG=$n_seg -generic SEG_W=128 -generic DATA_W=$data_w \
             -generic N_PORT=$n_port -generic N_GROUP=$n_group

puts "S2U_PROBE_ERRORS=[get_msg_config -severity {ERROR} -count]"
puts "S2U_PROBE_CRITICAL_WARNINGS=[get_msg_config -severity {CRITICAL WARNING} -count]"

# One clock. The reference runs its whole converter on the segment clock at 200G and 400G,
# and this module does the same, so a crossing is the caller's to add.
create_clock -name seg_clk -period $per [get_ports clk]
puts "S2U_PROBE_CLOCK seg_clk period=$per"

set seqs [get_cells -quiet -hier -filter {IS_SEQUENTIAL}]
puts "S2U_PROBE_SEQ_CELLS=[llength $seqs]"
set bram [get_cells -quiet -hier -filter {REF_NAME =~ RAMB*}]
set uram [get_cells -quiet -hier -filter {REF_NAME =~ URAM*}]
puts "S2U_PROBE_BRAM=[llength $bram] S2U_PROBE_URAM=[llength $uram]"

check_timing -override_defaults no_clock -verbose

set p [get_timing_paths -quiet -setup -max_paths 1]
if {[llength $p]} {
  puts "S2U_PROBE_WORST slack=[get_property SLACK $p]\
 levels=[get_property LOGIC_LEVELS $p]\
 logic=[get_property DATAPATH_LOGIC_DELAY $p]\
 route=[get_property DATAPATH_NET_DELAY $p]\
 from=[get_property STARTPOINT_PIN $p] to=[get_property ENDPOINT_PIN $p]"
} else {
  puts "S2U_PROBE_WORST none"
}

# The endpoint kind separates a data path failure from a control path failure, and the
# structure it belongs to says whether the mechanism or its surroundings is short.
puts "S2U_PROBE_TOP25_BEGIN"
foreach q [get_timing_paths -quiet -setup -max_paths 25 -nworst 25] {
  set ep [get_property ENDPOINT_PIN $q]
  puts "S2U_PROBE_PATH slack=[get_property SLACK $q]\
 levels=[get_property LOGIC_LEVELS $q] pin=[lindex [split $ep /] end]\
 from=[get_property STARTPOINT_PIN $q] to=$ep"
}
puts "S2U_PROBE_TOP25_END"

# The acceptance condition, stated in the log so the caller does not have to remember it.
set ref [expr {$rate == 400 ? -0.090 : ($rate == 200 ? 0.428 : 0.442)}]
if {[llength $p]} {
  set got [get_property SLACK $p]
  set gap [expr {$got - $ref}]
  if {$gap >= 0} {
    puts [format "S2U_PROBE_VERSUS_REFERENCE slack %.3f against reference %.3f at rate %s,\
 ahead by %.3f" $got $ref $rate $gap]
  } else {
    puts [format "S2U_PROBE_VERSUS_REFERENCE slack %.3f against reference %.3f at rate %s,\
 short by %.3f" $got $ref $rate [expr {-$gap}]]
  }
}

report_utilization
puts "S2U_PROBE_DONE rate=$rate"
