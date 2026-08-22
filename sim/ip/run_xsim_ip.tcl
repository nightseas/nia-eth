# ---------------------------------------------------------------------------
# File        : run_xsim_ip.tcl
# Description : Elaborates a generated IP variant under xsim, which is the simulator that
#               can read the vendor output.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

if {$argc >= 1} { set work [lindex $argv 0] } else { set work "./xsim_work" }
if {$argc >= 2} { set part [lindex $argv 1] } else { set part "xcvp1552-vsva2785-2MHP-i-S" }

set here   [file normalize [file dirname [info script]]]
set rtl    [file normalize $here/..]

file mkdir $work

create_project -force nia_ip_sim $work -part $part
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set NIA_FIFO_IP_DIR $work/ip_fifo
source $rtl/synth/dcmac_fifo_ip.tcl

add_files -fileset sources_1 [list \
  $rtl/dcmac_seg_axis_adapter.sv \
  $rtl/eth_axis_dwidth.sv \
  $rtl/dcmac_axis_frame_fifo.sv \
  $rtl/fifo_ip/eth_axis_async_fifo.sv \
  $rtl/fifo_ip/tx_frame_fifo.sv \
  $rtl/ctl/dcmac_mac_ctl_fsm.sv \
  $rtl/dcmac_axis_adapter.sv \
]
set_property file_type {SystemVerilog} [get_files -of_objects [get_filesets sources_1] *.sv]

set_property verilog_define {DCMAC_FRAME_FIFO_BRAM} [get_filesets sources_1]

add_files -fileset sim_1 [list $here/tb_dcmac_ip_variant.sv]
set_property file_type {SystemVerilog} [get_files -of_objects [get_filesets sim_1] *.sv]
set_property top tb_dcmac_ip_variant [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property verilog_define {DCMAC_FRAME_FIFO_BRAM} [get_filesets sim_1]

set_property -name {xsim.simulate.runtime} -value {-all} -objects [get_filesets sim_1]
set_property -name {xsim.elaborate.debug_level} -value {typical} -objects [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "NIA_XSIM_TOP [get_property top [get_filesets sim_1]]"
puts "NIA_XSIM_SOURCES [llength [get_files -of_objects [get_filesets sources_1]]]"

foreach f [get_files -of_objects [get_filesets sources_1]] {
    if {[string match *fifo* $f]} { puts "NIA_XSIM_FIFO_FILE $f" }
}

launch_simulation -mode behavioral
puts "NIA_XSIM_DONE"
