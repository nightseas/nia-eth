# ---------------------------------------------------------------------------
# File        : dcmac_seam_files.f
# Description : The source list for the MAC subsystem, in sections. A build selects the
#               top it needs, the PHY of its rate, and either the generated FIFO IP or the
#               behavioural models, which define the same module names and are
#               alternatives.
# Author      : Xiaohai Li <haixiaolee@gmail.com>
# Language    : Source list
#
#
# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: BSD-2-Clause-Views
# ---------------------------------------------------------------------------

[COMMON]
ctl/dcmac_ctl_pkg.sv
ctl/dcmac_ctl_seq.sv
ctl/wdt.sv
ctl/dcmac_link_sample.sv
ctl/dcmac_axil_exec.sv
ctl/dcmac_axil_arb.sv
ctl/dcmac_mac_ctl_fsm.sv
ctl/dcmac_link_ctl.sv
dcmac_sync2.sv
gt_rst_req_gate.sv
dcmac_seg_axis_adapter.sv
dcmac_seg_axis_rx.sv
eth_axis_dwidth.sv
dcmac_axis_frame_fifo.sv
dcmac_axis_rx_stream.sv
dcmac_axis_adapter.sv
dcmac_port.sv

[TOP_SEAM]
dcmac_axis_top.sv

[TOP_SEAM_DUAL]
dcmac_axis_dual_top.sv

[PKTGEN_AXIS]
pktgen_axis/dcmac_axis_frame_src.sv
pktgen_axis/dcmac_axis_frame_chk.sv
pktgen_axis/dcmac_axis_pktgen.sv

[TOP_MAC]
dcmac_mac_group.sv

[PHY_REAL]
rst_sync.sv
dcmac_phy_wrapper.sv

[PHY_RATE200]
rst_sync.sv
rate/dcmac_phy_wrapper_200g.sv

[PHY_RATE400]
rst_sync.sv
rate/dcmac_phy_wrapper_400g.sv

[PHY_STUB]
dcmac_phy_model.sv

[FIFO_IP]
fifo_ip/eth_axis_async_fifo.sv
fifo_ip/tx_frame_fifo.sv

[FIFO_MODEL]
../sim/model/eth_axis_async_fifo.sv
../sim/model/tx_frame_fifo.sv

[PKTGEN]
dcmac_seg_fifo.sv
pktgen_seg/dcmac_seg_ctx.sv
pktgen_seg/dcmac_seg_pktgen_chain.sv
pktgen_seg/dcmac_seg_pktmon_chain.sv
dcmac_seg_pktgen.sv

[TOP_PKTGEN]
dcmac_pktgen_top.sv

[TOP_PKTGEN_DUAL]
dcmac_pktgen_dual_top.sv

[OPTIONAL]
dcmac_csr_snap.sv
ctl/dcmac_link_csr.sv
dcmac_axis_csr.sv
dcmac_board_flags.sv
