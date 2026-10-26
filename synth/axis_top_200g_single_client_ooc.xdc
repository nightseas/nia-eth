# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views

create_clock -name gt_refclk -period 6.400 [get_ports gt_ref_clk_p];

set_false_path -from [get_ports sys_reset];

set_false_path -to [get_pins -quiet -hier -filter {NAME =~ *release_chain_r_reg*/CLR}];
