// ---------------------------------------------------------------------------
// File        : tb_dcmac_adapter_link.sv
// Description : The test bench of one adapter against the control plane, so a reset or a
//               link event arrives while the stream is running.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_dcmac_adapter_link #(

  parameter integer N_SEG      = 2,
  parameter integer SEG_W      = 128,
  parameter integer DATA_W     = 512,

  parameter integer PTP_TS_EN  = 0,
  parameter integer PTP_TS_W   = 80,
  parameter integer TX_TAG_W   = 0,

  parameter integer RX_FIFO_AW = 9,
  parameter integer RX_CDC_AW  = 9,
  parameter integer TX_FIFO_AW = 8,
  parameter integer TX_CDC_AW  = 9,
  parameter integer TX_CPL_AW  = 4,

  parameter integer SEG_CYC_PER_MS  = 390930,
  parameter integer T_RXDP_MS       = 100,
  parameter integer T_SERDES_MS     = 100,
  parameter integer PORT_MAX  = 6,
  parameter integer NPORTS    = 1,
  parameter integer ANCHOR    = 0,

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

  output wire                         tx_rst,
  output wire                         rx_rst,

  input  wire [DATA_W-1:0]            s_axis_tx_tdata,
  input  wire [DATA_W/8-1:0]          s_axis_tx_tkeep,
  input  wire                         s_axis_tx_tvalid,
  output wire                         s_axis_tx_tready,
  input  wire                         s_axis_tx_tlast,
  input  wire [TX_USER_W-1:0]         s_axis_tx_tuser,

  output wire                         m_axis_tx_cpl_valid,
  input  wire                         m_axis_tx_cpl_ready,
  output wire [PTP_TS_W-1:0]          m_axis_tx_cpl_ts,
  output wire [TX_TAG_WP-1:0]         m_axis_tx_cpl_tag,

  output wire [DATA_W-1:0]            m_axis_rx_tdata,
  output wire [DATA_W/8-1:0]          m_axis_rx_tkeep,
  output wire                         m_axis_rx_tvalid,
  output wire                         m_axis_rx_tlast,
  output wire [RX_USER_W-1:0]         m_axis_rx_tuser,

  input  wire [PTP_TS_W-1:0]          seg_ptp_time,

  input  wire                         rx_seg_valid,
  input  wire [N_SEG*SEG_W-1:0]       rx_seg_dat,
  input  wire [N_SEG-1:0]             rx_seg_ena,
  input  wire [N_SEG-1:0]             rx_seg_sop,
  input  wire [N_SEG-1:0]             rx_seg_eop,
  input  wire [N_SEG-1:0]             rx_seg_err,
  input  wire [N_SEG*4-1:0]           rx_seg_mty,

  input  wire                         tx_seg_ready,
  output wire                         tx_seg_valid,
  output wire [N_SEG*SEG_W-1:0]       tx_seg_dat,
  output wire [N_SEG-1:0]             tx_seg_ena,
  output wire [N_SEG-1:0]             tx_seg_sop,
  output wire [N_SEG-1:0]             tx_seg_eop,
  output wire [N_SEG-1:0]             tx_seg_err,
  output wire [N_SEG*4-1:0]           tx_seg_mty,

  input  wire                         stat_rx_aligned,

  input  wire                         link_reset_req,
  output wire                         link_reset_ack,
  input  wire                         stat_remote_fault,
  input  wire                         configured,

  input  wire                         rx_force_resync_req,
  output wire                         ctl_rx_enable,
  output wire                         ctl_rx_force_resync,
  output wire                         ctl_tx_enable,
  output wire                         ctl_tx_send_idle,
  output wire                         ctl_tx_send_lfi,
  output wire                         ctl_tx_send_rfi,
  output wire                         rx_datapath_reset,

  output wire [PORT_MAX-1:0]          rx_datapath_reset_ports,
  output wire [2:0]                   fsm_state,

  output wire                         link_up,
  output wire                         carrier,
  output wire                         rx_status,
  output wire                         tx_status,
  output wire                         rx_overflow,
  output wire                         rx_trunc,
  output wire [31:0]                  rx_err_frames,
  output wire [31:0]                  rx_drop_frames,
  output wire                         tx_cpl_overflow
);

  (* ASYNC_REG = "TRUE" *) logic algn_s0 = 1'b0, algn_s1 = 1'b0;
  (* ASYNC_REG = "TRUE" *) logic rmt_s0  = 1'b0, rmt_s1  = 1'b0;
  (* ASYNC_REG = "TRUE" *) logic rrq_s0  = 1'b0, rrq_s1  = 1'b0;
  (* ASYNC_REG = "TRUE" *) logic cfg_s0  = 1'b0, cfg_s1  = 1'b0;
  always_ff @(posedge seg_clk) begin
    algn_s0 <= stat_rx_aligned;  algn_s1 <= algn_s0;
    rmt_s0  <= stat_remote_fault; rmt_s1 <= rmt_s0;
    rrq_s0  <= link_reset_req;    rrq_s1 <= rrq_s0;
    cfg_s0  <= configured;        cfg_s1 <= cfg_s0;
  end

  wire link_up_i, tx_rst_seg_i, ctl_tx_enable_i;

  dcmac_mac_ctl_fsm #(
    .CYC_PER_MS(SEG_CYC_PER_MS), .T_RXDP_MS(T_RXDP_MS), .T_SERDES_MS(T_SERDES_MS),
    .PORT_MAX(PORT_MAX), .NPORTS(NPORTS), .ANCHOR(ANCHOR)
  ) u_fsm (
    .seg_clk                 (seg_clk),
    .seg_rstn                (seg_rstn),
    .stat_rx_aligned         (algn_s1),
    .stat_remote_fault       (rmt_s1),
    .reset_req               (rrq_s1),
    .reset_ack               (link_reset_ack),
    .configured              (cfg_s1),
    .rx_force_resync_req     (rx_force_resync_req),
    .ctl_rx_enable           (ctl_rx_enable),
    .ctl_rx_force_resync     (ctl_rx_force_resync),
    .ctl_tx_enable           (ctl_tx_enable_i),
    .ctl_tx_send_idle        (ctl_tx_send_idle),
    .ctl_tx_send_lfi         (ctl_tx_send_lfi),
    .ctl_tx_send_rfi         (ctl_tx_send_rfi),
    .rx_datapath_reset       (rx_datapath_reset),
    .rx_datapath_reset_ports (rx_datapath_reset_ports),
    .tx_rst_seg              (tx_rst_seg_i),
    .link_up                 (link_up_i),
    .carrier                 (carrier),
    .fsm_state               (fsm_state)
  );

  assign link_up       = link_up_i;
  assign ctl_tx_enable = ctl_tx_enable_i;

  dcmac_axis_adapter #(
    .N_SEG(N_SEG), .SEG_W(SEG_W), .DATA_W(DATA_W),
    .PTP_TS_EN(PTP_TS_EN), .PTP_TS_W(PTP_TS_W), .TX_TAG_W(TX_TAG_W),
    .RX_FIFO_AW(RX_FIFO_AW), .RX_CDC_AW(RX_CDC_AW),
    .TX_FIFO_AW(TX_FIFO_AW), .TX_CDC_AW(TX_CDC_AW), .TX_CPL_AW(TX_CPL_AW)
  ) u_adapter (
    .seg_clk                 (seg_clk),
    .seg_rstn                (seg_rstn),
    .tx_clk                  (tx_clk),
    .tx_rstn                 (tx_rstn),
    .rx_clk                  (rx_clk),
    .rx_rstn                 (rx_rstn),
    .tx_rst                  (tx_rst),
    .rx_rst                  (rx_rst),

    .s_axis_tx_tdata         (s_axis_tx_tdata),
    .s_axis_tx_tkeep         (s_axis_tx_tkeep),
    .s_axis_tx_tvalid        (s_axis_tx_tvalid),
    .s_axis_tx_tready        (s_axis_tx_tready),
    .s_axis_tx_tlast         (s_axis_tx_tlast),
    .s_axis_tx_tuser         (s_axis_tx_tuser),
    .m_axis_tx_cpl_valid     (m_axis_tx_cpl_valid),
    .m_axis_tx_cpl_ready     (m_axis_tx_cpl_ready),
    .m_axis_tx_cpl_ts        (m_axis_tx_cpl_ts),
    .m_axis_tx_cpl_tag       (m_axis_tx_cpl_tag),

    .m_axis_rx_tdata         (m_axis_rx_tdata),
    .m_axis_rx_tkeep         (m_axis_rx_tkeep),
    .m_axis_rx_tvalid        (m_axis_rx_tvalid),
    .m_axis_rx_tlast         (m_axis_rx_tlast),
    .m_axis_rx_tuser         (m_axis_rx_tuser),
    .seg_ptp_time            (seg_ptp_time),

    .rx_seg_valid            (rx_seg_valid),
    .rx_seg_dat              (rx_seg_dat),
    .rx_seg_ena              (rx_seg_ena),
    .rx_seg_sop              (rx_seg_sop),
    .rx_seg_eop              (rx_seg_eop),
    .rx_seg_err              (rx_seg_err),
    .rx_seg_mty              (rx_seg_mty),

    .tx_seg_ready            (tx_seg_ready),
    .tx_seg_valid            (tx_seg_valid),
    .tx_seg_dat              (tx_seg_dat),
    .tx_seg_ena              (tx_seg_ena),
    .tx_seg_sop              (tx_seg_sop),
    .tx_seg_eop              (tx_seg_eop),
    .tx_seg_err              (tx_seg_err),
    .tx_seg_mty              (tx_seg_mty),

    .stat_rx_aligned         (stat_rx_aligned),
    .link_up                 (link_up_i),
    .tx_rst_seg              (tx_rst_seg_i),
    .ctl_tx_enable           (ctl_tx_enable_i),

    .rx_status               (rx_status),
    .tx_status               (tx_status),
    .rx_overflow             (rx_overflow),
    .rx_trunc                (rx_trunc),
    .rx_err_frames           (rx_err_frames),
    .rx_drop_frames          (rx_drop_frames),
    .rx_align_stat           (),
    .tx_cpl_overflow         (tx_cpl_overflow)
  );

endmodule
