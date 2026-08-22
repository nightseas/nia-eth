# ---------------------------------------------------------------------------
# File        : tu03_pktgen_400g_timing.xdc
# Description : Timing constraints for the 400GAUI-4 image, where the one client spans two
#               GTM banks of the same cage. Both reference clock ports are declared, at
#               the same 6.400 ns, because each quad needs its own input buffer.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Xilinx design constraints
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

create_clock -name gt_ref_clk0 -period 6.400 [get_ports gt_ref_clk0_p]
create_clock -name gt_ref_clk1 -period 6.400 [get_ports gt_ref_clk1_p]
