# ---------------------------------------------------------------------------
# File        : tu03_pktgen_200g4_post_synth.tcl
# Description : Post synthesis placement for the dual 200GAUI-4 image. Each cage carries four
#               lanes of 53.125 Gb/s, and this board routes CH0 and CH2 of each quad to its
#               cage, so a cage takes two quads and the image takes four: QSFP0 on GTM_QUAD
#               X0Y0 and X0Y1, banks 202 and 203, and QSFP1 on X0Y2 and X0Y3, banks 204 and
#               205. The two quads of a cage are consecutive column sites, which is what
#               DRC MGTIO-16 requires of interconnected quads.
#
#               One reference clock buffer a cage feeds both quads of that cage, so two sites
#               are named. IMPORTANT: PG369 page 201 states that each quad uses its own
#               gt_ref_clk in AMD's configurations. If the placer or a DRC refuses the shared
#               route, the fix is a reference clock input a quad, which adds two ports to the
#               device top and two sites here.
#
#               The rate independent constraints are handed to tu03_pktgen_post_synth.tcl.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Tcl
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

set nia_quad_map [list \
  {*i_gtwiz0/*gt_quad_base_0_inst/inst/quad_inst} GTM_QUAD_X0Y0 \
  {*i_gtwiz0/*gt_quad_base_1_inst/inst/quad_inst} GTM_QUAD_X0Y1 \
  {*i_gtwiz1/*gt_quad_base_0_inst/inst/quad_inst} GTM_QUAD_X0Y2 \
  {*i_gtwiz1/*gt_quad_base_1_inst/inst/quad_inst} GTM_QUAD_X0Y3]

set nia_refclk_map [list \
  {*dcmac_IBUFDS_GTE5_REFCLK0_gt0} GTM_REFCLK_X0Y0 \
  {*dcmac_IBUFDS_GTE5_REFCLK1_gt1} GTM_REFCLK_X0Y4]

# One buffer serves the two quads of a cage, so the ratio is half a buffer a quad. The rate
# independent file checks the ratio the caller states, which is how a missing clock is still
# caught: four quads and two buffers is what this configuration expects, and three would fail.
set nia_refclk_per_quad 0.5

puts "NIA_XDC PLACEMENT dual 200GAUI-4, QSFP0 banks 202+203 and QSFP1 banks 204+205, four quads"

source [file join [file dirname [info script]] tu03_pktgen_post_synth.tcl]
