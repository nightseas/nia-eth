# ---------------------------------------------------------------------------
# File        : seg_pktgen_ooc.xdc
# Description : Out of context constraints for the segmented instrument: the segment clock
#               at 2.558 ns, the register clock at 4.000 ns, the asynchronous group
#               between them, and the false paths into the synchroniser and snapshot entry
#               registers.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Xilinx design constraints
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

create_clock -name seg_clk -period 2.558 [get_ports seg_clk]
create_clock -name axil_aclk -period 4.000 [get_ports axil_aclk]

set_clock_groups -asynchronous -name seg_to_axil \
  -group [get_clocks seg_clk] -group [get_clocks axil_aclk]

set_false_path -to [get_pins -quiet -hier -filter {NAME =~ *ack_s0_reg/D}]
set_false_path -to [get_pins -quiet -hier -filter {NAME =~ *req_s0_reg/D}]
set_false_path -to [get_pins -quiet -hier -filter {NAME =~ *sr_reg[0][*]/D}]
