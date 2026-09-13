// ---------------------------------------------------------------------------
// File        : dcmac_axis_dual_top.sv
// Description : The two client AXI-Stream subsystem: two MAC clients each behind their
//               own adapter, one control plane across both, and the adapter status they
//               publish.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module dcmac_axis_dual_top #(

  parameter integer N_CLIENT   = 2,
  parameter integer N_STREAM   = 1,
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

  parameter integer PORT_MAX   = 6,
  parameter integer NPORTS     = 1,
  parameter integer ANCHOR_0   = 0,
  parameter integer ANCHOR_1   = 1,
  parameter [2:0]   LOOPBACK_MODE = 3'b000,

  parameter logic [7:0] DONE_MASK      = dcmac_ctl_pkg::DONEMASK_100G,
  parameter int         RATE_CODE      = dcmac_ctl_pkg::RATE_CODE_100G,
  parameter int         RATE_FIELD     = dcmac_ctl_pkg::RATE_FIELD_100G,
  parameter bit         LANE_RATE_HI   = 1'b1,
  parameter logic [7:0] POLARITY_TX_Q0 = dcmac_ctl_pkg::QSFP0_TXPOLARITY,
  parameter logic [7:0] POLARITY_RX_Q0 = dcmac_ctl_pkg::QSFP0_RXPOLARITY,
  parameter logic [7:0] POLARITY_TX_Q1 = dcmac_ctl_pkg::QSFP1_TXPOLARITY,
  parameter logic [7:0] POLARITY_RX_Q1 = dcmac_ctl_pkg::QSFP1_RXPOLARITY,
  parameter logic [7:0] POLARITY_TX_Q2 = 8'b0000_0000,
  parameter logic [7:0] POLARITY_RX_Q2 = 8'b0000_0000,
  parameter logic [7:0] POLARITY_TX_Q3 = 8'b0000_0000,
  parameter logic [7:0] POLARITY_RX_Q3 = 8'b0000_0000,

  // The transceiver serial pin count of the whole image. A cage occupies the serial pins of
  // every quad that serves it, four a quad, and every configuration is one quad a cage.
  parameter integer GT_LANES  = 8,

  parameter integer SEG_CYC_PER_MS = 390930,
  parameter integer CTL_CYC_PER_MS = 250000,
  parameter integer T_RXDP_MS      = 100,
  parameter integer T_SERDES_MS    = 100,
  parameter integer LINK_WDT_MS    = 750,
  parameter integer T_SAMPLE_MS    = 50,

  parameter integer RX_USER_W = (PTP_TS_EN != 0) ? (PTP_TS_W + 1) : 1,
  parameter integer TX_USER_W = TX_TAG_W + 1,
  parameter integer TX_TAG_WP = (TX_TAG_W > 0) ? TX_TAG_W : 1
)(

  input  wire                    sys_reset,

  input  wire                    gt_ref_clk0_p,
  input  wire                    gt_ref_clk0_n,
  input  wire                    gt_ref_clk1_p,
  input  wire                    gt_ref_clk1_n,
  input  wire [GT_LANES-1:0]     gt_rxp_in,
  input  wire [GT_LANES-1:0]     gt_rxn_in,
  output wire [GT_LANES-1:0]     gt_txn_out,
  output wire [GT_LANES-1:0]     gt_txp_out,

  output wire                    seg_clk,
  output wire                    usr_clk,
  output wire                    net_clk,
  output wire                    usr_rstn,

  input  wire [2*DATA_W-1:0]     s_axis_tx_tdata,
  input  wire [2*DATA_W/8-1:0]   s_axis_tx_tkeep,
  input  wire [1:0]              s_axis_tx_tvalid,
  output wire [1:0]              s_axis_tx_tready,
  input  wire [1:0]              s_axis_tx_tlast,
  input  wire [2*TX_USER_W-1:0]  s_axis_tx_tuser,

  output wire [1:0]              m_axis_tx_cpl_valid,
  input  wire [1:0]              m_axis_tx_cpl_ready,
  output wire [2*PTP_TS_W-1:0]   m_axis_tx_cpl_ts,
  output wire [2*TX_TAG_WP-1:0]  m_axis_tx_cpl_tag,

  output wire [N_CLIENT*N_STREAM*DATA_W-1:0]    m_axis_rx_tdata,
  output wire [N_CLIENT*N_STREAM*DATA_W/8-1:0]  m_axis_rx_tkeep,
  output wire [N_CLIENT*N_STREAM-1:0]           m_axis_rx_tvalid,
  output wire [N_CLIENT*N_STREAM-1:0]           m_axis_rx_tlast,
  output wire [N_CLIENT*N_STREAM*RX_USER_W-1:0] m_axis_rx_tuser,

  input  wire [PTP_TS_W-1:0]     seg_ptp_time,

  output wire [1:0]              tx_status,
  output wire [1:0]              rx_status,
  output wire [1:0]              link_up,
  output wire [5:0]              mac_fsm_state,
  output wire [1:0]              rx_overflow,
  output wire [1:0]              rx_trunc,
  output wire [63:0]             rx_err_frames,
  output wire [63:0]             rx_align_stat,
  output wire [63:0]             rx_drop_frames,
  output wire [1:0]              tx_cpl_overflow,

  input  wire                    ctl_bringup_restart_req,
  input  wire                    ctl_stats_req,
  input  wire [1:0]              ctl_rx_force_resync_req,
  input  wire [1:0]              ctl_rx_datapath_reset_req,
  input  wire [1:0]              ctl_tx_datapath_reset_req,
  output wire                    ctl_link_fault,
  output wire                    ctl_access_fault,
  output wire                    ctl_seq_busy,
  output wire [31:0]             ctl_rx_phy_status,
  output wire [16*N_CLIENT-1:0]  ctl_gt_ch_reset_done,
  output wire [7:0]              ctl_retry_cnt,
  output wire [4:0]              ctl_seq_state,
  output wire [15:0]             ctl_seq_pc,
  input  wire [7:0]              ctl_stat_rd_idx,
  output wire [31:0]             ctl_stat_rd_data,
  output wire [1:0]              ctl_rx_pcs_aligned,
  output wire [63:0]             ctl_align_word,
  output wire [63:0]             ctl_align_sticky,
  output wire [7:0]              ctl_fault_nibble,
  output wire [1:0]              ctl_bus_stuck,
  output wire [1:0]              ctl_link_valid,
  output wire [1:0]              ctl_ever_aligned,
  output wire [1:0]              ctl_window_running,
  output wire [1:0]              ctl_last_was_fault,
  output wire [31:0]             ctl_sample_count,
  output wire [31:0]             ctl_esc_count,
  output wire [31:0]             ctl_bus_err_count,
  output wire [15:0]             ctl_exec_tmo_count,
  output wire [15:0]             ctl_repair_dp_count,
  output wire [15:0]             ctl_repair_pll_count
);


  wire                            seg_clk_i, usr_clk_i;
  wire                            net_clk_i;
  wire [N_CLIENT-1:0]             seg_rstn_i;

  wire [N_CLIENT-1:0]             rx_seg_valid, tx_seg_ready, tx_seg_valid;
  wire [N_CLIENT*N_SEG*SEG_W-1:0] rx_seg_dat, tx_seg_dat;
  wire [N_CLIENT*N_SEG-1:0]       rx_seg_ena, rx_seg_sop, rx_seg_eop, rx_seg_err;
  wire [N_CLIENT*N_SEG*4-1:0]     rx_seg_mty, tx_seg_mty;
  wire [N_CLIENT*N_SEG-1:0]       tx_seg_ena, tx_seg_sop, tx_seg_eop, tx_seg_err;

  wire [N_CLIENT-1:0]             ctl_rx_enable, ctl_rx_force_resync_core, ctl_tx_enable;
  wire [N_CLIENT-1:0]             ctl_tx_send_idle, ctl_tx_send_lfi, ctl_tx_send_rfi;

  wire [N_CLIENT-1:0]             fsm_link_up, fsm_tx_rst_seg, rx_pcs_aligned_grp;
  wire [N_CLIENT-1:0]             port_rx_dp_reset;
  wire [N_CLIENT-1:0]             port_rx_serdes_reset;
  wire [N_CLIENT-1:0]             port_rx_flush;
  wire [N_CLIENT-1:0]             gt_rx_done_seg;
  wire [N_CLIENT-1:0]             gt_rx_done_raw_client;
  wire [8*N_CLIENT-1:0]           port_repair_count;
  wire [8*N_CLIENT-1:0]           port_repair_tmo_count;
  wire                            seg_rstn_ctl_i;
  wire [N_CLIENT*PORT_MAX-1:0]    port_rx_dp_reset_ports;

  wire                            seq_rx_dp_reset;
  wire [PORT_MAX-1:0]             seq_rx_dp_ports;
  wire                            seq_core_serdes_reset;
  wire [N_CLIENT-1:0]             seq_rx_dp_for_client;
  wire [N_CLIENT*PORT_MAX-1:0]    seq_rx_ports_for_client;

  wire [8*N_CLIENT-1:0]           gt_tx_reset_done_raw, gt_rx_reset_done_raw;
  wire [8*N_CLIENT-1:0]           gt_tx_done_sync, gt_rx_done_sync;

  wire [19:0] seq_awaddr, seq_araddr;
  wire [31:0] seq_wdata, seq_rdata;
  wire [3:0]  seq_wstrb;
  wire [1:0]  seq_bresp, seq_rresp;
  wire        seq_awvalid, seq_awready, seq_wvalid, seq_wready;
  wire        seq_bvalid, seq_bready, seq_arvalid, seq_arready;
  wire        seq_rvalid, seq_rready;

  assign seg_clk = seg_clk_i;
  assign usr_clk = usr_clk_i;
  assign net_clk = net_clk_i;
  assign ctl_rx_pcs_aligned = rx_pcs_aligned_grp;
  assign ctl_repair_dp_count  = port_repair_count;
  assign ctl_repair_pll_count = port_repair_tmo_count;

  genvar qd;
  generate
  for (qd = 0; qd < N_CLIENT; qd++) begin : g_done_client
    // report_cdc gives CDC-11, fan-out from launch flop to destination clock, because
    // gt_rx_reset_done_raw fed both u_sync_rx_done and this reduction, so one source flop
    // reached the destination domain by two routes that can disagree. The reduction takes the
    // synchronised copy, which is the same information one crossing later.
    assign gt_rx_done_raw_client[qd] = |gt_rx_done_sync[8*qd +: 8];
  end
  endgenerate

  dcmac_sync2 #(.WIDTH(N_CLIENT), .STAGES(2), .INIT('0)) u_sync_gt_rx_done_seg (
    .clk  (seg_clk_i),
    .din  (gt_rx_done_raw_client),
    .dout (gt_rx_done_seg));

  (* ASYNC_REG = "TRUE" *) reg [2:0] usr_rstn_sr = 3'b000;
  always_ff @(posedge usr_clk_i) usr_rstn_sr <= {usr_rstn_sr[1:0], ~sys_reset};
  wire usr_rstn_i = usr_rstn_sr[2];
  assign usr_rstn = usr_rstn_i;

  genvar q;
  generate
  for (q = 0; q < N_CLIENT; q++) begin : g_done_sync
    dcmac_sync2 #(.WIDTH(8), .STAGES(2), .INIT(8'h00)) u_sync_tx_done (
      .clk  (usr_clk_i),
      .din  (gt_tx_reset_done_raw[8*q +: 8]),
      .dout (gt_tx_done_sync[8*q +: 8]));
    dcmac_sync2 #(.WIDTH(8), .STAGES(2), .INIT(8'h00)) u_sync_rx_done (
      .clk  (usr_clk_i),
      .din  (gt_rx_reset_done_raw[8*q +: 8]),
      .dout (gt_rx_done_sync[8*q +: 8]));
  end
  endgenerate

  logic [7:0] gt_tx_done_all, gt_rx_done_all;
  always_comb begin
    gt_tx_done_all = 8'hFF;
    gt_rx_done_all = 8'hFF;
    for (int k = 0; k < N_CLIENT; k++) begin
      gt_tx_done_all &= gt_tx_done_sync[8*k +: 8];
      gt_rx_done_all &= gt_rx_done_sync[8*k +: 8];
    end
  end

  wire [N_CLIENT-1:0] host_rx_req_gated;

  generate
  for (q = 0; q < N_CLIENT; q++) begin : g_rx_req_gate
    gt_rst_req_gate #(
      .EN_GATE   (1),
      .SYNC_DONE (1)
    ) u_gate_rx (
      .clk           (usr_clk_i),
      .rstn          (usr_rstn_i),
      .req_level     (ctl_rx_datapath_reset_req[q]),
      .gt_reset_done ((|gt_tx_done_all) && (|gt_rx_done_all)),
      .seq_busy      (ctl_seq_busy),
      .req_pulse     (host_rx_req_gated[q]),
      .sts_state      (),
      .sts_stuck      (),
      .sts_refused    (),
      .sts_refuse_cnt (),
      .clr_status     (1'b0)
    );
  end
  endgenerate

  dcmac_link_ctl #(
    .PORT_MAX   (PORT_MAX),
    .NPORTS     (NPORTS),
    .ANCHOR     (ANCHOR_0),
    .N_GROUP    (N_CLIENT),
    .ANCHOR_1   (ANCHOR_1),
    .CYC_PER_MS (CTL_CYC_PER_MS),
    .DONE_MASK  (DONE_MASK),
    .RATE_CODE  (RATE_CODE),
    .RATE_FIELD (RATE_FIELD),
    .LANE_RATE_HI (LANE_RATE_HI),

    .LINK_WDT_MS     (LINK_WDT_MS),
    .T_SAMPLE_MS     (T_SAMPLE_MS),
    .SEG_CYC_PER_MS  (SEG_CYC_PER_MS),
    .T_RXDP_MS       (T_RXDP_MS),
    .T_SERDES_MS     (T_SERDES_MS),
    .ALIGN_EXPORT_MODE (1)
  ) u_ctl (
    .aclk                    (usr_clk_i),
    .aresetn                 (usr_rstn_i),

    .seg_clk                 (seg_clk_i),
    .seg_rstn                ({N_CLIENT{seg_rstn_ctl_i}}),

    .link_up                     (fsm_link_up),
    .tx_rst_seg                  (fsm_tx_rst_seg),
    .carrier                     (link_up),
    .mac_fsm_state               (mac_fsm_state),
    .ctl_rx_enable               (ctl_rx_enable),
    .ctl_rx_force_resync         (ctl_rx_force_resync_core),
    .ctl_tx_enable               (ctl_tx_enable),
    .ctl_tx_send_idle            (ctl_tx_send_idle),
    .ctl_tx_send_lfi             (ctl_tx_send_lfi),
    .ctl_tx_send_rfi             (ctl_tx_send_rfi),
    .fsm_rx_datapath_reset       (port_rx_dp_reset),
    .fsm_rx_serdes_reset         (port_rx_serdes_reset),
    .fsm_rx_flush                (port_rx_flush),
    .fsm_gt_rx_done              (gt_rx_done_seg),
    .fsm_repair_count            (port_repair_count),
    .fsm_repair_tmo_count        (port_repair_tmo_count),
    .fsm_rx_datapath_reset_ports (port_rx_dp_reset_ports),
    .host_link_reset_req         (host_rx_req_gated),
    .host_rx_force_resync_req    (ctl_rx_force_resync_req),

    .m_axil_awaddr           (seq_awaddr),
    .m_axil_awvalid          (seq_awvalid),
    .m_axil_awready          (seq_awready),
    .m_axil_wdata            (seq_wdata),
    .m_axil_wstrb            (seq_wstrb),
    .m_axil_wvalid           (seq_wvalid),
    .m_axil_wready           (seq_wready),
    .m_axil_bresp            (seq_bresp),
    .m_axil_bvalid           (seq_bvalid),
    .m_axil_bready           (seq_bready),
    .m_axil_araddr           (seq_araddr),
    .m_axil_arvalid          (seq_arvalid),
    .m_axil_arready          (seq_arready),
    .m_axil_rdata            (seq_rdata),
    .m_axil_rresp            (seq_rresp),
    .m_axil_rvalid           (seq_rvalid),
    .m_axil_rready           (seq_rready),

    .gt_tx_reset_done        (gt_tx_done_all),
    .gt_rx_reset_done        (gt_rx_done_all),
    .rx_datapath_reset       (seq_rx_dp_reset),
    .rx_datapath_reset_ports (seq_rx_dp_ports),
    .core_serdes_reset       (seq_core_serdes_reset),
    .tx_datapath_reset       (),

    .bringup_restart_req     (ctl_bringup_restart_req),
    .stats_req               (ctl_stats_req),
    .rx_force_resync_req     ({N_CLIENT{1'b0}}),
    .rx_datapath_reset_req   ({N_CLIENT{1'b0}}),
    .tx_datapath_reset_req   (|ctl_tx_datapath_reset_req),
    .rx_force_resync         (),

    .link_wdt_ms             ({N_CLIENT{16'(LINK_WDT_MS)}}),

    .rx_pcs_aligned          (rx_pcs_aligned_grp),
    .link_fault              (ctl_link_fault),
    .access_fault            (ctl_access_fault),
    .seq_busy                (ctl_seq_busy),
    .bringup_done            (),
    .rx_phy_status           (ctl_rx_phy_status),
    .retry_cnt               (ctl_retry_cnt),
    .seq_state               (ctl_seq_state),
    .seq_pc                  (ctl_seq_pc),
    .stat_rd_idx             (ctl_stat_rd_idx),
    .stat_rd_data            (ctl_stat_rd_data),

    .link_reset_req          (),
    .link_remote_fault       (),
    .link_bus_stuck          (ctl_bus_stuck),
    .link_ever_aligned       (ctl_ever_aligned),
    .link_fault_nibble       (ctl_fault_nibble),
    .link_align_word         (ctl_align_word),
    .link_align_sticky       (ctl_align_sticky),
    .sup_esc_count           (ctl_esc_count),
    .link_sample_count       (ctl_sample_count),
    .link_valid              (ctl_link_valid),
    .link_window_running     (ctl_window_running),
    .link_last_was_fault     (ctl_last_was_fault),
    .link_bus_err_count      (ctl_bus_err_count),
    .link_window_remaining   (),
    .exec_tmo_count          (ctl_exec_tmo_count)
  );

  generate
  for (q = 0; q < N_CLIENT; q++) begin : g_port
    dcmac_port #(
      .N_SEG(N_SEG), .SEG_W(SEG_W), .DATA_W(DATA_W), .N_STREAM(N_STREAM),
      .PTP_TS_EN(PTP_TS_EN), .PTP_TS_W(PTP_TS_W), .TX_TAG_W(TX_TAG_W),
      .RX_FIFO_AW(RX_FIFO_AW), .RX_CDC_AW(RX_CDC_AW),
      .TX_FIFO_AW(TX_FIFO_AW), .TX_CDC_AW(TX_CDC_AW), .TX_CPL_AW(TX_CPL_AW)
    ) u_port (
      .sys_reset               (sys_reset),
      .seg_clk                 (seg_clk_i),
      .seg_rstn                (seg_rstn_i[q]),
      .usr_clk                 (usr_clk_i),
      .net_clk                 (net_clk_i),

      .tx_clk                  (),
      .tx_rst                  (),
      .rx_clk                  (),
      .rx_rst                  (),
      .usr_rstn                (),

      .s_axis_tx_tdata         (s_axis_tx_tdata[q*DATA_W +: DATA_W]),
      .s_axis_tx_tkeep         (s_axis_tx_tkeep[q*(DATA_W/8) +: DATA_W/8]),
      .s_axis_tx_tvalid        (s_axis_tx_tvalid[q]),
      .s_axis_tx_tready        (s_axis_tx_tready[q]),
      .s_axis_tx_tlast         (s_axis_tx_tlast[q]),
      .s_axis_tx_tuser         (s_axis_tx_tuser[q*TX_USER_W +: TX_USER_W]),

      .m_axis_tx_cpl_valid     (m_axis_tx_cpl_valid[q]),
      .m_axis_tx_cpl_ready     (m_axis_tx_cpl_ready[q]),
      .m_axis_tx_cpl_ts        (m_axis_tx_cpl_ts[q*PTP_TS_W +: PTP_TS_W]),
      .m_axis_tx_cpl_tag       (m_axis_tx_cpl_tag[q*TX_TAG_WP +: TX_TAG_WP]),

      .m_axis_rx_tdata         (m_axis_rx_tdata[q*N_STREAM*DATA_W +: N_STREAM*DATA_W]),
      .m_axis_rx_tkeep         (m_axis_rx_tkeep[q*N_STREAM*(DATA_W/8) +: N_STREAM*(DATA_W/8)]),
      .m_axis_rx_tvalid        (m_axis_rx_tvalid[q*N_STREAM +: N_STREAM]),
      .m_axis_rx_tlast         (m_axis_rx_tlast[q*N_STREAM +: N_STREAM]),
      .m_axis_rx_tuser         (m_axis_rx_tuser[q*N_STREAM*RX_USER_W +: N_STREAM*RX_USER_W]),

      .seg_ptp_time            (seg_ptp_time),

      .tx_status               (tx_status[q]),
      .rx_status               (rx_status[q]),
      .rx_overflow             (rx_overflow[q]),
      .rx_trunc                (rx_trunc[q]),
      .rx_err_frames           (rx_err_frames[q*32 +: 32]),
      .rx_align_stat           (rx_align_stat[q*32 +: 32]),
      .rx_drop_frames          (rx_drop_frames[q*32 +: 32]),
      .tx_cpl_overflow         (tx_cpl_overflow[q]),

      .rx_seg_valid            (rx_seg_valid[q]),
      .rx_seg_dat              (rx_seg_dat[q*N_SEG*SEG_W +: N_SEG*SEG_W]),
      .rx_seg_ena              (rx_seg_ena[q*N_SEG +: N_SEG]),
      .rx_seg_sop              (rx_seg_sop[q*N_SEG +: N_SEG]),
      .rx_seg_eop              (rx_seg_eop[q*N_SEG +: N_SEG]),
      .rx_seg_err              (rx_seg_err[q*N_SEG +: N_SEG]),
      .rx_seg_mty              (rx_seg_mty[q*N_SEG*4 +: N_SEG*4]),

      .tx_seg_ready            (tx_seg_ready[q]),
      .tx_seg_valid            (tx_seg_valid[q]),
      .tx_seg_dat              (tx_seg_dat[q*N_SEG*SEG_W +: N_SEG*SEG_W]),
      .tx_seg_ena              (tx_seg_ena[q*N_SEG +: N_SEG]),
      .tx_seg_sop              (tx_seg_sop[q*N_SEG +: N_SEG]),
      .tx_seg_eop              (tx_seg_eop[q*N_SEG +: N_SEG]),
      .tx_seg_err              (tx_seg_err[q*N_SEG +: N_SEG]),
      .tx_seg_mty              (tx_seg_mty[q*N_SEG*4 +: N_SEG*4]),

      .stat_rx_aligned         (rx_pcs_aligned_grp[q]),
      .link_up                 (fsm_link_up[q]),
      .tx_rst_seg              (fsm_tx_rst_seg[q]),
      .ctl_tx_enable           (ctl_tx_enable[q])
    );
  end
  endgenerate

  generate
  for (q = 0; q < N_CLIENT; q++) begin : g_seq_rx_dp
    localparam integer AK = (q == 0) ? ANCHOR_0 : ANCHOR_1;
    localparam logic [PORT_MAX-1:0] MASK_K = ((PORT_MAX)'((1 << NPORTS) - 1)) << AK;
    wire [PORT_MAX-1:0] hit = seq_rx_dp_ports & MASK_K;
    assign seq_rx_dp_for_client[q] = seq_rx_dp_reset & (|hit);
    assign seq_rx_ports_for_client[q*PORT_MAX +: PORT_MAX] = hit;
  end
  endgenerate

  wire [N_CLIENT-1:0]          phy_rx_dp_reset = port_rx_dp_reset | seq_rx_dp_for_client;
  wire [N_CLIENT*PORT_MAX-1:0] phy_rx_dp_ports = port_rx_dp_reset_ports | seq_rx_ports_for_client;

  dcmac_phy #(
    .N_CLIENT(N_CLIENT),
    .N_SEG(N_SEG), .SEG_W(SEG_W), .PORT_MAX(PORT_MAX),
    .LOOPBACK_MODE(LOOPBACK_MODE),
    .ANCHOR_0(ANCHOR_0), .ANCHOR_1(ANCHOR_1),
    .POLARITY_TX_Q0(POLARITY_TX_Q0), .POLARITY_RX_Q0(POLARITY_RX_Q0),
    .POLARITY_TX_Q1(POLARITY_TX_Q1), .POLARITY_RX_Q1(POLARITY_RX_Q1),
    .POLARITY_TX_Q2(POLARITY_TX_Q2), .POLARITY_RX_Q2(POLARITY_RX_Q2),
    .POLARITY_TX_Q3(POLARITY_TX_Q3), .POLARITY_RX_Q3(POLARITY_RX_Q3),
    .GT_LANES(GT_LANES)
  ) u_phy (
    .sys_reset               (sys_reset),
    .gt_ref_clk0_p           (gt_ref_clk0_p),
    .gt_ref_clk0_n           (gt_ref_clk0_n),
    .gt_ref_clk1_p           (gt_ref_clk1_p),
    .gt_ref_clk1_n           (gt_ref_clk1_n),
    .gt_rxp_in               (gt_rxp_in),
    .gt_rxn_in               (gt_rxn_in),
    .gt_txn_out              (gt_txn_out),
    .gt_txp_out              (gt_txp_out),

    .seg_clk                 (seg_clk_i),
    .seg_rstn                (seg_rstn_i),
    .seg_rstn_ctl            (seg_rstn_ctl_i),
    .usr_clk                 (usr_clk_i),
    .net_clk                 (net_clk_i),

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

    .ctl_rx_enable           (ctl_rx_enable),
    .ctl_rx_force_resync     (ctl_rx_force_resync_core),
    .ctl_tx_enable           (ctl_tx_enable),
    .ctl_tx_send_idle        (ctl_tx_send_idle),
    .ctl_tx_send_lfi         (ctl_tx_send_lfi),
    .ctl_tx_send_rfi         (ctl_tx_send_rfi),

    .rx_datapath_reset       (phy_rx_dp_reset),
    .rx_serdes_reset_req     (port_rx_serdes_reset),
    .rx_flush_req            (port_rx_flush),
    .rx_datapath_reset_ports (phy_rx_dp_ports),
    .tx_datapath_reset       (ctl_tx_datapath_reset_req),

    .axil_aclk               (usr_clk_i),
    .axil_aresetn            (usr_rstn_i),

    .s_axil_awaddr           (seq_awaddr),
    .s_axil_awvalid          (seq_awvalid),
    .s_axil_awready          (seq_awready),
    .s_axil_wdata            (seq_wdata),
    .s_axil_wstrb            (seq_wstrb),
    .s_axil_wvalid           (seq_wvalid),
    .s_axil_wready           (seq_wready),
    .s_axil_bresp            (seq_bresp),
    .s_axil_bvalid           (seq_bvalid),
    .s_axil_bready           (seq_bready),
    .s_axil_araddr           (seq_araddr),
    .s_axil_arvalid          (seq_arvalid),
    .s_axil_arready          (seq_arready),
    .s_axil_rdata            (seq_rdata),
    .s_axil_rresp            (seq_rresp),
    .s_axil_rvalid           (seq_rvalid),
    .s_axil_rready           (seq_rready),

    .gt_tx_reset_done        (gt_tx_reset_done_raw),
    .gt_ch_reset_done        (ctl_gt_ch_reset_done),
    .gt_rx_reset_done        (gt_rx_reset_done_raw),

    .core_serdes_reset       (seq_core_serdes_reset)
  );

endmodule
