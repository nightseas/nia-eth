# ---------------------------------------------------------------------------
# File        : tu03_pktgen_400g_post_synth.tcl
# Description : Post synthesis placement for the 400GAUI-4 image. The two interconnected
#               transceiver quads must occupy consecutive column sites on one cage, so
#               this file names them and their reference clock buffers and then hands the
#               rate independent constraints to tu03_pktgen_post_synth.tcl.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set nia_quad_map [list \
  {*i_gtwiz0/*gt_quad_base_0_inst/inst/quad_inst} GTM_QUAD_X0Y0 \
  {*i_gtwiz0/*gt_quad_base_1_inst/inst/quad_inst} GTM_QUAD_X0Y1]

set nia_refclk_map [list \
  {*dcmac_IBUFDS_GTE5_REFCLK0_gt0} GTM_REFCLK_X0Y0 \
  {*dcmac_IBUFDS_GTE5_REFCLK1_gt1} GTM_REFCLK_X0Y2]

puts "NIA_XDC PLACEMENT single 400G, QSFP0 banks 202+203 on consecutive column sites (DRC MGTIO-16)"

source [file join [file dirname [info script]] tu03_pktgen_post_synth.tcl]
