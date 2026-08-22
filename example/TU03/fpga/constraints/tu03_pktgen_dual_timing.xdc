# ---------------------------------------------------------------------------
# File        : tu03_pktgen_dual_timing.xdc
# Description : Timing constraints for the two cage image: both QSFP transceiver reference
#               clocks at 6.400 ns, one per cage. Both must be declared or the second is
#               unconstrained and check_timing stops the build.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Xilinx design constraints
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

create_clock -name gt_ref_clk0 -period 6.400 [get_ports gt_ref_clk0_p]
create_clock -name gt_ref_clk1 -period 6.400 [get_ports gt_ref_clk1_p]
