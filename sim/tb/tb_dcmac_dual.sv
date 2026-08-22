// ---------------------------------------------------------------------------
// File        : tb_dcmac_dual.sv
// Description : The test bench of the two client subsystem, which is what shows a client
//               is independent of its sibling.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

`ifndef NIA_DUAL_CLIENT_MODULE

  `define NIA_DUAL_CLIENT_MODULE tb_dcmac_adapter_link
`endif

module tb_dcmac_dual #(
  parameter integer N_SEG      = 2,
  parameter integer SEG_W      = 128,
  parameter integer DATA_W     = 512,
  parameter integer PTP_TS_EN  = 0,
  parameter integer PTP_TS_W   = 80,
  parameter integer TX_TAG_W   = 0,

  parameter integer SEG_CYC_PER_MS = 20,
  parameter integer T_RXDP_MS      = 3,
  parameter integer T_SERDES_MS    = 2,
  parameter integer PORT_MAX   = 6,

  parameter integer NPORTS_C0  = 1,
  parameter integer ANCHOR_C0  = 0,
  parameter integer NPORTS_C1  = 1,
  parameter integer ANCHOR_C1  = 1,

  parameter integer RX_USER_W = (PTP_TS_EN != 0) ? (PTP_TS_W + 1) : 1,
  parameter integer TX_USER_W = TX_TAG_W + 1,
  parameter integer TX_TAG_WP = (TX_TAG_W > 0) ? TX_TAG_W : 1
)(

  input  wire                         seg_clk,
  input  wire                         seg_rstn,
  input  wire                         tx_clk,
  input  wire                         tx_rstn,
  input  wire                         rx_clk,
  input  wire                         rx_rstn,
  input  wire [PTP_TS_W-1:0]          seg_ptp_time,

  output wire                         tx_rst_c0,
  output wire                         rx_rst_c0,
  input  wire [DATA_W-1:0]            s_axis_tx_c0_tdata,
  input  wire [DATA_W/8-1:0]          s_axis_tx_c0_tkeep,
  input  wire                         s_axis_tx_c0_tvalid,
  output wire                         s_axis_tx_c0_tready,
  input  wire                         s_axis_tx_c0_tlast,
  input  wire [TX_USER_W-1:0]         s_axis_tx_c0_tuser,
  output wire                         m_axis_tx_cpl_c0_valid,
  input  wire                         m_axis_tx_cpl_c0_ready,
  output wire [PTP_TS_W-1:0]          m_axis_tx_cpl_c0_ts,
  output wire [TX_TAG_WP-1:0]         m_axis_tx_cpl_c0_tag,
  output wire [DATA_W-1:0]            m_axis_rx_c0_tdata,
  output wire [DATA_W/8-1:0]          m_axis_rx_c0_tkeep,
  output wire                         m_axis_rx_c0_tvalid,
  output wire                         m_axis_rx_c0_tlast,
  output wire [RX_USER_W-1:0]         m_axis_rx_c0_tuser,
  input  wire                         rx_seg_valid_c0,
  input  wire [N_SEG*SEG_W-1:0]       rx_seg_dat_c0,
  input  wire [N_SEG-1:0]             rx_seg_ena_c0,
  input  wire [N_SEG-1:0]             rx_seg_sop_c0,
  input  wire [N_SEG-1:0]             rx_seg_eop_c0,
  input  wire [N_SEG-1:0]             rx_seg_err_c0,
  input  wire [N_SEG*4-1:0]           rx_seg_mty_c0,
  input  wire                         tx_seg_ready_c0,
  output wire                         tx_seg_valid_c0,
  output wire [N_SEG*SEG_W-1:0]       tx_seg_dat_c0,
  output wire [N_SEG-1:0]             tx_seg_ena_c0,
  output wire [N_SEG-1:0]             tx_seg_sop_c0,
  output wire [N_SEG-1:0]             tx_seg_eop_c0,
  output wire [N_SEG-1:0]             tx_seg_err_c0,
  output wire [N_SEG*4-1:0]           tx_seg_mty_c0,
  input  wire                         stat_rx_aligned_c0,

  input  wire                         link_reset_req_c0,
  output wire                         link_reset_ack_c0,
  input  wire                         stat_remote_fault_c0,
  input  wire                         configured_c0,

  input  wire                         host_tx_dp_req_c0,
  input  wire                         rx_force_resync_req_c0,

  input  wire                         gt_down_c0,
  output wire                         ctl_rx_enable_c0,
  output wire                         ctl_rx_force_resync_c0,
  output wire                         ctl_tx_enable_c0,
  output wire                         ctl_tx_send_idle_c0,
  output wire                         ctl_tx_send_lfi_c0,
  output wire                         ctl_tx_send_rfi_c0,
  output wire                         rx_datapath_reset_c0,
  output wire [PORT_MAX-1:0]          rx_datapath_reset_ports_c0,
  output wire [2:0]                   fsm_state_c0,
  output wire                         link_up_c0,
  output wire                         carrier_c0,
  output wire                         rx_status_c0,
  output wire                         tx_status_c0,
  output wire                         rx_overflow_c0,
  output wire                         rx_trunc_c0,
  output wire [31:0]                  rx_err_frames_c0,
  output wire [31:0]                  rx_drop_frames_c0,
  output wire                         tx_cpl_overflow_c0,

  output wire                         tx_rst_c1,
  output wire                         rx_rst_c1,
  input  wire [DATA_W-1:0]            s_axis_tx_c1_tdata,
  input  wire [DATA_W/8-1:0]          s_axis_tx_c1_tkeep,
  input  wire                         s_axis_tx_c1_tvalid,
  output wire                         s_axis_tx_c1_tready,
  input  wire                         s_axis_tx_c1_tlast,
  input  wire [TX_USER_W-1:0]         s_axis_tx_c1_tuser,
  output wire                         m_axis_tx_cpl_c1_valid,
  input  wire                         m_axis_tx_cpl_c1_ready,
  output wire [PTP_TS_W-1:0]          m_axis_tx_cpl_c1_ts,
  output wire [TX_TAG_WP-1:0]         m_axis_tx_cpl_c1_tag,
  output wire [DATA_W-1:0]            m_axis_rx_c1_tdata,
  output wire [DATA_W/8-1:0]          m_axis_rx_c1_tkeep,
  output wire                         m_axis_rx_c1_tvalid,
  output wire                         m_axis_rx_c1_tlast,
  output wire [RX_USER_W-1:0]         m_axis_rx_c1_tuser,
  input  wire                         rx_seg_valid_c1,
  input  wire [N_SEG*SEG_W-1:0]       rx_seg_dat_c1,
  input  wire [N_SEG-1:0]             rx_seg_ena_c1,
  input  wire [N_SEG-1:0]             rx_seg_sop_c1,
  input  wire [N_SEG-1:0]             rx_seg_eop_c1,
  input  wire [N_SEG-1:0]             rx_seg_err_c1,
  input  wire [N_SEG*4-1:0]           rx_seg_mty_c1,
  input  wire                         tx_seg_ready_c1,
  output wire                         tx_seg_valid_c1,
  output wire [N_SEG*SEG_W-1:0]       tx_seg_dat_c1,
  output wire [N_SEG-1:0]             tx_seg_ena_c1,
  output wire [N_SEG-1:0]             tx_seg_sop_c1,
  output wire [N_SEG-1:0]             tx_seg_eop_c1,
  output wire [N_SEG-1:0]             tx_seg_err_c1,
  output wire [N_SEG*4-1:0]           tx_seg_mty_c1,
  input  wire                         stat_rx_aligned_c1,
  input  wire                         link_reset_req_c1,
  output wire                         link_reset_ack_c1,
  input  wire                         stat_remote_fault_c1,
  input  wire                         configured_c1,
  input  wire                         host_tx_dp_req_c1,
  input  wire                         rx_force_resync_req_c1,
  input  wire                         gt_down_c1,
  output wire                         ctl_rx_enable_c1,
  output wire                         ctl_rx_force_resync_c1,
  output wire                         ctl_tx_enable_c1,
  output wire                         ctl_tx_send_idle_c1,
  output wire                         ctl_tx_send_lfi_c1,
  output wire                         ctl_tx_send_rfi_c1,
  output wire                         rx_datapath_reset_c1,
  output wire [PORT_MAX-1:0]          rx_datapath_reset_ports_c1,
  output wire [2:0]                   fsm_state_c1,
  output wire                         link_up_c1,
  output wire                         carrier_c1,
  output wire                         rx_status_c1,
  output wire                         tx_status_c1,
  output wire                         rx_overflow_c1,
  output wire                         rx_trunc_c1,
  output wire [31:0]                  rx_err_frames_c1,
  output wire [31:0]                  rx_drop_frames_c1,
  output wire                         tx_cpl_overflow_c1,

  output wire [PORT_MAX-1:0]          mac_port_reset,

  output wire [1:0]                   quad_rx_dp_reset,
  output wire [1:0]                   quad_tx_dp_reset,

  output wire [31:0]                  quad0_rx_reset_events,
  output wire [31:0]                  quad1_rx_reset_events,
  output wire [31:0]                  quad0_tx_reset_events,
  output wire [31:0]                  quad1_tx_reset_events,

  output wire                         xclient_mask_leak
);

  function automatic [PORT_MAX-1:0] group_mask(input integer anchor, input integer nports);
    group_mask = '0;
    for (int p = 0; p < PORT_MAX; p++)
      if (p >= anchor && p < (anchor + nports)) group_mask[p] = 1'b1;
  endfunction

  localparam logic [PORT_MAX-1:0] MASK_C0 = group_mask(ANCHOR_C0, NPORTS_C0);
  localparam logic [PORT_MAX-1:0] MASK_C1 = group_mask(ANCHOR_C1, NPORTS_C1);

  wire aligned_gated_c0 = stat_rx_aligned_c0 & ~gt_down_c0;
  wire aligned_gated_c1 = stat_rx_aligned_c1 & ~gt_down_c1;
  wire rx_seg_valid_g_c0 = rx_seg_valid_c0 & ~gt_down_c0;
  wire rx_seg_valid_g_c1 = rx_seg_valid_c1 & ~gt_down_c1;

  `NIA_DUAL_CLIENT_MODULE #(
    .N_SEG(N_SEG), .SEG_W(SEG_W), .DATA_W(DATA_W),
    .PTP_TS_EN(PTP_TS_EN), .PTP_TS_W(PTP_TS_W), .TX_TAG_W(TX_TAG_W),
    .SEG_CYC_PER_MS(SEG_CYC_PER_MS), .T_RXDP_MS(T_RXDP_MS), .T_SERDES_MS(T_SERDES_MS),
    .PORT_MAX(PORT_MAX),
    .NPORTS(NPORTS_C0), .ANCHOR(ANCHOR_C0)
  ) u_client0 (
    .seg_clk(seg_clk), .seg_rstn(seg_rstn),
    .tx_clk(tx_clk), .tx_rstn(tx_rstn), .rx_clk(rx_clk), .rx_rstn(rx_rstn),
    .tx_rst(tx_rst_c0), .rx_rst(rx_rst_c0),
    .s_axis_tx_tdata(s_axis_tx_c0_tdata), .s_axis_tx_tkeep(s_axis_tx_c0_tkeep),
    .s_axis_tx_tvalid(s_axis_tx_c0_tvalid), .s_axis_tx_tready(s_axis_tx_c0_tready),
    .s_axis_tx_tlast(s_axis_tx_c0_tlast), .s_axis_tx_tuser(s_axis_tx_c0_tuser),
    .m_axis_tx_cpl_valid(m_axis_tx_cpl_c0_valid), .m_axis_tx_cpl_ready(m_axis_tx_cpl_c0_ready),
    .m_axis_tx_cpl_ts(m_axis_tx_cpl_c0_ts), .m_axis_tx_cpl_tag(m_axis_tx_cpl_c0_tag),
    .m_axis_rx_tdata(m_axis_rx_c0_tdata), .m_axis_rx_tkeep(m_axis_rx_c0_tkeep),
    .m_axis_rx_tvalid(m_axis_rx_c0_tvalid), .m_axis_rx_tlast(m_axis_rx_c0_tlast),
    .m_axis_rx_tuser(m_axis_rx_c0_tuser),
    .seg_ptp_time(seg_ptp_time),
    .rx_seg_valid(rx_seg_valid_g_c0), .rx_seg_dat(rx_seg_dat_c0),
    .rx_seg_ena(rx_seg_ena_c0), .rx_seg_sop(rx_seg_sop_c0), .rx_seg_eop(rx_seg_eop_c0),
    .rx_seg_err(rx_seg_err_c0), .rx_seg_mty(rx_seg_mty_c0),
    .tx_seg_ready(tx_seg_ready_c0), .tx_seg_valid(tx_seg_valid_c0),
    .tx_seg_dat(tx_seg_dat_c0), .tx_seg_ena(tx_seg_ena_c0), .tx_seg_sop(tx_seg_sop_c0),
    .tx_seg_eop(tx_seg_eop_c0), .tx_seg_err(tx_seg_err_c0), .tx_seg_mty(tx_seg_mty_c0),
    .stat_rx_aligned(aligned_gated_c0),
    .link_reset_req(link_reset_req_c0),
    .link_reset_ack(link_reset_ack_c0),
    .stat_remote_fault(stat_remote_fault_c0),
    .configured(configured_c0),
    .rx_force_resync_req(rx_force_resync_req_c0),
    .ctl_rx_enable(ctl_rx_enable_c0), .ctl_rx_force_resync(ctl_rx_force_resync_c0),
    .ctl_tx_enable(ctl_tx_enable_c0), .ctl_tx_send_idle(ctl_tx_send_idle_c0),
    .ctl_tx_send_lfi(ctl_tx_send_lfi_c0), .ctl_tx_send_rfi(ctl_tx_send_rfi_c0),
    .rx_datapath_reset(rx_datapath_reset_c0),
    .rx_datapath_reset_ports(rx_datapath_reset_ports_c0), .fsm_state(fsm_state_c0),
    .link_up(link_up_c0), .carrier(carrier_c0),
    .rx_status(rx_status_c0), .tx_status(tx_status_c0),
    .rx_overflow(rx_overflow_c0), .rx_trunc(rx_trunc_c0),
    .rx_err_frames(rx_err_frames_c0), .rx_drop_frames(rx_drop_frames_c0),
    .tx_cpl_overflow(tx_cpl_overflow_c0)
  );

  `NIA_DUAL_CLIENT_MODULE #(
    .N_SEG(N_SEG), .SEG_W(SEG_W), .DATA_W(DATA_W),
    .PTP_TS_EN(PTP_TS_EN), .PTP_TS_W(PTP_TS_W), .TX_TAG_W(TX_TAG_W),
    .SEG_CYC_PER_MS(SEG_CYC_PER_MS), .T_RXDP_MS(T_RXDP_MS), .T_SERDES_MS(T_SERDES_MS),
    .PORT_MAX(PORT_MAX),
    .NPORTS(NPORTS_C1), .ANCHOR(ANCHOR_C1)
  ) u_client1 (
    .seg_clk(seg_clk), .seg_rstn(seg_rstn),
    .tx_clk(tx_clk), .tx_rstn(tx_rstn), .rx_clk(rx_clk), .rx_rstn(rx_rstn),
    .tx_rst(tx_rst_c1), .rx_rst(rx_rst_c1),
    .s_axis_tx_tdata(s_axis_tx_c1_tdata), .s_axis_tx_tkeep(s_axis_tx_c1_tkeep),
    .s_axis_tx_tvalid(s_axis_tx_c1_tvalid), .s_axis_tx_tready(s_axis_tx_c1_tready),
    .s_axis_tx_tlast(s_axis_tx_c1_tlast), .s_axis_tx_tuser(s_axis_tx_c1_tuser),
    .m_axis_tx_cpl_valid(m_axis_tx_cpl_c1_valid), .m_axis_tx_cpl_ready(m_axis_tx_cpl_c1_ready),
    .m_axis_tx_cpl_ts(m_axis_tx_cpl_c1_ts), .m_axis_tx_cpl_tag(m_axis_tx_cpl_c1_tag),
    .m_axis_rx_tdata(m_axis_rx_c1_tdata), .m_axis_rx_tkeep(m_axis_rx_c1_tkeep),
    .m_axis_rx_tvalid(m_axis_rx_c1_tvalid), .m_axis_rx_tlast(m_axis_rx_c1_tlast),
    .m_axis_rx_tuser(m_axis_rx_c1_tuser),
    .seg_ptp_time(seg_ptp_time),
    .rx_seg_valid(rx_seg_valid_g_c1), .rx_seg_dat(rx_seg_dat_c1),
    .rx_seg_ena(rx_seg_ena_c1), .rx_seg_sop(rx_seg_sop_c1), .rx_seg_eop(rx_seg_eop_c1),
    .rx_seg_err(rx_seg_err_c1), .rx_seg_mty(rx_seg_mty_c1),
    .tx_seg_ready(tx_seg_ready_c1), .tx_seg_valid(tx_seg_valid_c1),
    .tx_seg_dat(tx_seg_dat_c1), .tx_seg_ena(tx_seg_ena_c1), .tx_seg_sop(tx_seg_sop_c1),
    .tx_seg_eop(tx_seg_eop_c1), .tx_seg_err(tx_seg_err_c1), .tx_seg_mty(tx_seg_mty_c1),
    .stat_rx_aligned(aligned_gated_c1),
    .link_reset_req(link_reset_req_c1),
    .link_reset_ack(link_reset_ack_c1),
    .stat_remote_fault(stat_remote_fault_c1),
    .configured(configured_c1),
    .rx_force_resync_req(rx_force_resync_req_c1),
    .ctl_rx_enable(ctl_rx_enable_c1), .ctl_rx_force_resync(ctl_rx_force_resync_c1),
    .ctl_tx_enable(ctl_tx_enable_c1), .ctl_tx_send_idle(ctl_tx_send_idle_c1),
    .ctl_tx_send_lfi(ctl_tx_send_lfi_c1), .ctl_tx_send_rfi(ctl_tx_send_rfi_c1),
    .rx_datapath_reset(rx_datapath_reset_c1),
    .rx_datapath_reset_ports(rx_datapath_reset_ports_c1), .fsm_state(fsm_state_c1),
    .link_up(link_up_c1), .carrier(carrier_c1),
    .rx_status(rx_status_c1), .tx_status(tx_status_c1),
    .rx_overflow(rx_overflow_c1), .rx_trunc(rx_trunc_c1),
    .rx_err_frames(rx_err_frames_c1), .rx_drop_frames(rx_drop_frames_c1),
    .tx_cpl_overflow(tx_cpl_overflow_c1)
  );

  assign mac_port_reset = rx_datapath_reset_ports_c0 | rx_datapath_reset_ports_c1;

  wire [1:0] quad_rx_owned = { |(mac_port_reset & MASK_C1), |(mac_port_reset & MASK_C0) };
  wire [1:0] quad_tx_owned = { host_tx_dp_req_c1,           host_tx_dp_req_c0           };

`ifdef NIA_DUAL_SHARED_QUAD_RESET

  assign quad_rx_dp_reset = {2{|quad_rx_owned}};
  assign quad_tx_dp_reset = {2{|quad_tx_owned}};
`else
  assign quad_rx_dp_reset = quad_rx_owned;
  assign quad_tx_dp_reset = quad_tx_owned;
`endif
  logic [1:0]  qrx_d, qtx_d;
  logic [31:0] q0rx, q1rx, q0tx, q1tx;
  logic        leak_r;

  wire mask_leak_now =
        |(rx_datapath_reset_ports_c0 & ~MASK_C0) |
        |(rx_datapath_reset_ports_c1 & ~MASK_C1) |
        |(MASK_C0 & MASK_C1);

  always_ff @(posedge seg_clk) begin
    if (!seg_rstn) begin
      qrx_d <= '0; qtx_d <= '0;
      q0rx <= '0; q1rx <= '0; q0tx <= '0; q1tx <= '0;
      leak_r <= 1'b0;
    end else begin
      if (quad_rx_dp_reset[0] & ~qrx_d[0] & (q0rx != 32'hFFFF_FFFF)) q0rx <= q0rx + 1;
      if (quad_rx_dp_reset[1] & ~qrx_d[1] & (q1rx != 32'hFFFF_FFFF)) q1rx <= q1rx + 1;
      if (quad_tx_dp_reset[0] & ~qtx_d[0] & (q0tx != 32'hFFFF_FFFF)) q0tx <= q0tx + 1;
      if (quad_tx_dp_reset[1] & ~qtx_d[1] & (q1tx != 32'hFFFF_FFFF)) q1tx <= q1tx + 1;
      qrx_d  <= quad_rx_dp_reset;
      qtx_d  <= quad_tx_dp_reset;
      leak_r <= leak_r | mask_leak_now;
    end
  end

  assign quad0_rx_reset_events = q0rx;
  assign quad1_rx_reset_events = q1rx;
  assign quad0_tx_reset_events = q0tx;
  assign quad1_tx_reset_events = q1tx;
  assign xclient_mask_leak     = leak_r;

endmodule
`default_nettype wire
