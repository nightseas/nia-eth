# ---------------------------------------------------------------------------
# File        : seam_ooc.xdc
# Description : The out of context constraints of the adapter boundary: the reset input is
#               not a timed path.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Xilinx design constraints
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

create_clock -name gt_refclk -period 6.400 [get_ports gt_ref_clk_p]

set_false_path -from [get_ports sys_reset]
