# ---------------------------------------------------------------------------
# File        : tu03_pktgen_timing.xdc
# Description : Timing constraints for the single cage image: the one QSFP transceiver
#               reference clock at 6.400 ns, which is 156.25 MHz.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Xilinx design constraints
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

create_clock -name gt_ref_clk -period 6.400 [get_ports gt_ref_clk_p]
