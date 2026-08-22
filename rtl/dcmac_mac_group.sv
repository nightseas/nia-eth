// ---------------------------------------------------------------------------
// File        : dcmac_mac_group.sv
// Description : The MAC group: the hard block instance, its per client ports, the
//               statistics interface and the per group reset requests the control plane
//               drives.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

`default_nettype none

module dcmac_mac_group #(

  parameter integer N_CLIENT   = 2,
  parameter integer ANCHOR_0   = 0,
  parameter integer ANCHOR_1   = 1,

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

  parameter integer SEG_CYC_PER_MS = 390930,
  parameter integer T_RXDP_MS      = 100,
  parameter integer T_SERDES_MS    = 100,
  parameter int     T_SAMPLE_MS    = 50,
  parameter int     N_BUS_ERR      = 16,
  parameter integer PORT_MAX   = 6,
  parameter integer NPORTS     = 1,
  parameter [2:0]   LOOPBACK_MODE = 3'b000,
  parameter integer CTL_CYC_PER_MS = 250000,
  parameter integer EN_DPRST_SYNC = 1,

  parameter integer EN_CTLREQ_SYNC = 0,

  parameter bit     EN_RR_POLL      = 1'b1,

  parameter integer LINK_WDT_MS     = 750,
  parameter integer LINK_WDT_MS_MIN = 10,
  parameter integer LINK_WDT_MS_MAX = 60000,

  parameter integer ESC_MAX_STAGE   = 3,

  parameter integer LINK_CONFIRM_N   = 2,

  parameter bit     EN_STATS         = 1'b1,

  parameter integer ALIGN_EXPORT_MODE = 1,

  parameter logic [7:0] STAT_IDX_MAX = 8'(22 * NPORTS * N_CLIENT - 1),

  parameter integer EN_DPRST_GATE      = 1,
  parameter integer DPRST_PULSE_CYC    = 64,
  parameter integer DPRST_SETTLE_CYC   = 250000,
  parameter integer DPRST_DONE_TMO_CYC = 50000000,

  parameter integer RX_USER_W = (PTP_TS_EN != 0) ? (PTP_TS_W + 1) : 1,
  parameter integer TX_USER_W = TX_TAG_W + 1,
  parameter integer TX_TAG_WP = (TX_TAG_W > 0) ? TX_TAG_W : 1
)(

  input  wire                            sys_reset,
  input  wire                            gt_ref_clk0_p,
  input  wire                            gt_ref_clk0_n,
  input  wire                            gt_ref_clk1_p,
  input  wire                            gt_ref_clk1_n,
  input  wire [4*N_CLIENT-1:0]           gt_rxp_in,
  input  wire [4*N_CLIENT-1:0]           gt_rxn_in,
  output wire [4*N_CLIENT-1:0]           gt_txp_out,
  output wire [4*N_CLIENT-1:0]           gt_txn_out,

  output wire [N_CLIENT-1:0]             tx_clk,
  output wire [N_CLIENT-1:0]             tx_rst,
  output wire [N_CLIENT-1:0]             rx_clk,
  output wire [N_CLIENT-1:0]             rx_rst,

  input  wire [N_CLIENT*DATA_W-1:0]      s_axis_tx_tdata,
  input  wire [N_CLIENT*DATA_W/8-1:0]    s_axis_tx_tkeep,
  input  wire [N_CLIENT-1:0]             s_axis_tx_tvalid,
  output wire [N_CLIENT-1:0]             s_axis_tx_tready,
  input  wire [N_CLIENT-1:0]             s_axis_tx_tlast,
  input  wire [N_CLIENT*TX_USER_W-1:0]   s_axis_tx_tuser,

  output wire [N_CLIENT-1:0]             m_axis_tx_cpl_valid,
  input  wire [N_CLIENT-1:0]             m_axis_tx_cpl_ready,
  output wire [N_CLIENT*PTP_TS_W-1:0]    m_axis_tx_cpl_ts,
  output wire [N_CLIENT*TX_TAG_WP-1:0]   m_axis_tx_cpl_tag,

  output wire [N_CLIENT*DATA_W-1:0]      m_axis_rx_tdata,
  output wire [N_CLIENT*DATA_W/8-1:0]    m_axis_rx_tkeep,
  output wire [N_CLIENT-1:0]             m_axis_rx_tvalid,
  output wire [N_CLIENT-1:0]             m_axis_rx_tlast,
  output wire [N_CLIENT*RX_USER_W-1:0]   m_axis_rx_tuser,

  input  wire [N_CLIENT*PTP_TS_W-1:0]    seg_ptp_time,
  output wire                            seg_clk,

  output wire [N_CLIENT-1:0]             tx_status,
  output wire [N_CLIENT-1:0]             rx_status,
  output wire [N_CLIENT-1:0]             link_up,
  output wire [N_CLIENT-1:0]             rx_overflow,
  output wire [N_CLIENT-1:0]             rx_trunc,
  output wire [N_CLIENT*32-1:0]          rx_err_frames,
  output wire [N_CLIENT*32-1:0]          rx_drop_frames,
  output wire [N_CLIENT-1:0]             tx_cpl_overflow,
  output wire [N_CLIENT*3-1:0]           mac_fsm_state,

  input  wire [N_CLIENT-1:0]             ctl_rx_force_resync_req,
  input  wire [N_CLIENT-1:0]             ctl_rx_datapath_reset_req,
  input  wire [N_CLIENT-1:0]             ctl_tx_datapath_reset_req,

  input  wire [16*N_CLIENT-1:0]          ctl_link_wdt_ms,
  input  wire                            ctl_bringup_restart_req,
  input  wire                            ctl_stats_req,
  output wire                            ctl_link_fault,
  output wire                            ctl_access_fault,
  output wire                            ctl_seq_busy,
  output wire [31:0]                     ctl_rx_phy_status,
  output wire [7:0]                      ctl_retry_cnt,
  output wire [4:0]                      ctl_seq_state,
  output wire [15:0]                     ctl_seq_pc,
  input  wire [7:0]                      ctl_stat_rd_idx,
  output wire [31:0]                     ctl_stat_rd_data
);

  // synthesis translate_off
  initial begin
    if (N_CLIENT < 1 || N_CLIENT > 2)
      $fatal(1, "dcmac_mac_group: N_CLIENT=%0d - the PHY maps dcmac_0 for 1 or 2 clients only", N_CLIENT);

    if (N_CLIENT > 1 && !((ANCHOR_1 >= ANCHOR_0 + NPORTS) || (ANCHOR_0 >= ANCHOR_1 + NPORTS)))
      $fatal(1, "dcmac_mac_group: violated - client groups overlap (ANCHOR_0=%0d ANCHOR_1=%0d NPORTS=%0d)",
             ANCHOR_0, ANCHOR_1, NPORTS);
  end
  // synthesis translate_on

  function automatic integer anchor_of(input integer k);
    return (k == 0) ? ANCHOR_0 : ANCHOR_1;
  endfunction

  wire seg_clk_i, usr_clk_i;
  wire [N_CLIENT-1:0] seg_rstn_i;
  assign seg_clk = seg_clk_i;

  wire [N_CLIENT-1:0]             rx_seg_valid;
  wire [N_CLIENT*N_SEG*SEG_W-1:0] rx_seg_dat;
  wire [N_CLIENT*N_SEG-1:0]       rx_seg_ena, rx_seg_sop, rx_seg_eop, rx_seg_err;
  wire [N_CLIENT*N_SEG*4-1:0]     rx_seg_mty;

  wire [N_CLIENT-1:0]             tx_seg_ready, tx_seg_valid;
  wire [N_CLIENT*N_SEG*SEG_W-1:0] tx_seg_dat;
  wire [N_CLIENT*N_SEG-1:0]       tx_seg_ena, tx_seg_sop, tx_seg_eop, tx_seg_err;
  wire [N_CLIENT*N_SEG*4-1:0]     tx_seg_mty;

  wire [N_CLIENT-1:0] p_ctl_rx_enable, p_ctl_rx_force_resync, p_ctl_tx_enable;
  wire [N_CLIENT-1:0] p_ctl_tx_send_idle, p_ctl_tx_send_lfi, p_ctl_tx_send_rfi;

  wire [N_CLIENT-1:0]            p_rx_dp_reset, p_tx_dp_reset, p_core_serdes_reset;
  wire [N_CLIENT*PORT_MAX-1:0]   p_rx_dp_ports;

  wire [8*N_CLIENT-1:0] gt_tx_reset_done_raw, gt_rx_reset_done_raw;

  wire [8*N_CLIENT-1:0] gt_tx_done_sync, gt_rx_done_sync;

  genvar q;
  generate
  for (q = 0; q < N_CLIENT; q++) begin : g_qsync
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
    for (int qq = 0; qq < N_CLIENT; qq++) begin
      gt_tx_done_all &= gt_tx_done_sync[8*qq +: 8];
      gt_rx_done_all &= gt_rx_done_sync[8*qq +: 8];
    end
  end

  (* ASYNC_REG = "TRUE" *) reg [2:0] seq_rstn_sr = 3'b000;
  always_ff @(posedge usr_clk_i) seq_rstn_sr <= {seq_rstn_sr[1:0], ~sys_reset};
  wire seq_rstn = seq_rstn_sr[2];

  wire [19:0] seq_awaddr, seq_araddr;
  wire [31:0] seq_wdata, seq_rdata;
  wire [3:0]  seq_wstrb;
  wire [1:0]  seq_bresp, seq_rresp;
  wire        seq_awvalid, seq_awready, seq_wvalid, seq_wready;
  wire        seq_bvalid, seq_bready, seq_arvalid, seq_arready;
  wire        seq_rvalid, seq_rready;

  wire                    seq_rx_dp_reset, seq_tx_dp_reset_unused, seq_core_serdes_reset;
  wire                    seq_rx_force_resync;
  wire [PORT_MAX-1:0]     seq_rx_dp_ports;

  wire [N_CLIENT-1:0]     rx_pcs_aligned_grp;
  wire                    ctl_bringup_done;

  wire [N_CLIENT-1:0]           link_reset_req;
  wire [N_CLIENT-1:0]           fsm_link_up;
  wire [N_CLIENT-1:0]           fsm_tx_rst_seg;
  wire [N_CLIENT-1:0]           link_remote_fault;
  wire [N_CLIENT-1:0]           link_bus_stuck;
  wire [N_CLIENT-1:0]           link_ever_aligned;
  wire [4*N_CLIENT-1:0]         link_fault_nibble;
  wire [16*N_CLIENT-1:0]        link_sample_count;
  wire [N_CLIENT-1:0]           p_carrier;
  wire [N_CLIENT-1:0]           link_valid;
  wire [N_CLIENT-1:0]           link_window_running;
  wire [N_CLIENT-1:0]           link_last_was_fault;
  wire [16*N_CLIENT-1:0]        link_bus_err_count;
  wire [40*N_CLIENT-1:0]        link_window_remaining;

  wire [16*N_CLIENT-1:0]        sup_esc_count;
  wire [15:0]                   exec_tmo_count;

  dcmac_link_ctl #(
    .PORT_MAX   (PORT_MAX),
    .NPORTS     (NPORTS),
    .ANCHOR     (ANCHOR_0),
    .N_GROUP    (N_CLIENT),
    .ANCHOR_1   (ANCHOR_1),
    .CYC_PER_MS (CTL_CYC_PER_MS),
    .EN_STATS   (EN_STATS),
    .EN_RR_POLL (EN_RR_POLL),

    .LINK_CONFIRM_N_BRINGUP (LINK_CONFIRM_N),

    .LINK_WDT_MS     (LINK_WDT_MS),
    .LINK_WDT_MS_MIN (LINK_WDT_MS_MIN),
    .LINK_WDT_MS_MAX (LINK_WDT_MS_MAX),
    .LINK_CONFIRM_N  (LINK_CONFIRM_N),

    .T_SAMPLE_MS     (T_SAMPLE_MS),
    .N_BUS_ERR       (N_BUS_ERR),

    .SEG_CYC_PER_MS  (SEG_CYC_PER_MS),
    .T_RXDP_MS       (T_RXDP_MS),
    .T_SERDES_MS     (T_SERDES_MS),
    .ALIGN_EXPORT_MODE (1)
  ) u_ctl (
    .aclk                    (usr_clk_i),
    .aresetn                 (seq_rstn),

    .seg_clk                 (seg_clk_i),
    .seg_rstn                (seg_rstn_i),

    .link_up                     (fsm_link_up),
    .tx_rst_seg                  (fsm_tx_rst_seg),
    .carrier                     (p_carrier),
    .mac_fsm_state               (mac_fsm_state),
    .ctl_rx_enable               (p_ctl_rx_enable),
    .ctl_rx_force_resync         (p_ctl_rx_force_resync),
    .ctl_tx_enable               (p_ctl_tx_enable),
    .ctl_tx_send_idle            (p_ctl_tx_send_idle),
    .ctl_tx_send_lfi             (p_ctl_tx_send_lfi),
    .ctl_tx_send_rfi             (p_ctl_tx_send_rfi),
    .fsm_rx_datapath_reset       (p_rx_dp_reset),
    .fsm_rx_datapath_reset_ports (p_rx_dp_ports),
    .host_link_reset_req         (host_rx_dp_req_gated),
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
    .tx_datapath_reset       (seq_tx_dp_reset_unused),
    .bringup_restart_req     (ctl_bringup_restart_req),
    .stats_req               (ctl_stats_req),

    .rx_force_resync_req     (1'b0),
    .rx_datapath_reset_req   (1'b0),
    .tx_datapath_reset_req   (1'b0),
    .rx_force_resync         (seq_rx_force_resync),

    .link_wdt_ms             (ctl_link_wdt_ms),

    .rx_pcs_aligned          (rx_pcs_aligned_grp),
    .link_fault              (ctl_link_fault),
    .access_fault            (ctl_access_fault),
    .seq_busy                (ctl_seq_busy),
    .bringup_done            (ctl_bringup_done),
    .rx_phy_status           (ctl_rx_phy_status),
    .retry_cnt               (ctl_retry_cnt),
    .seq_state               (ctl_seq_state),
    .seq_pc                  (ctl_seq_pc),
    .stat_rd_idx             (ctl_stat_rd_idx),
    .stat_rd_data            (ctl_stat_rd_data),

    .link_reset_req          (link_reset_req),
    .link_remote_fault       (link_remote_fault),
    .link_bus_stuck          (link_bus_stuck),
    .link_ever_aligned       (link_ever_aligned),
    .link_fault_nibble       (link_fault_nibble),
    .sup_esc_count           (sup_esc_count),
    .link_sample_count       (link_sample_count),

    .link_valid              (link_valid),
    .link_window_running     (link_window_running),
    .link_last_was_fault     (link_last_was_fault),
    .link_bus_err_count      (link_bus_err_count),
    .link_window_remaining   (link_window_remaining),
    .exec_tmo_count          (exec_tmo_count)
  );

  wire _unused_seq_tx = seq_tx_dp_reset_unused | seq_rx_force_resync;

  wire [N_CLIENT-1:0]          seq_rx_dp_for_client;
  wire [N_CLIENT*PORT_MAX-1:0] seq_rx_ports_for_client;

  generate
  for (q = 0; q < N_CLIENT; q++) begin : g_grpdec
    localparam integer AK = (q == 0) ? ANCHOR_0 : ANCHOR_1;

    localparam logic [PORT_MAX-1:0] MASK_K = ((PORT_MAX)'((1 << NPORTS) - 1)) << AK;

    wire [PORT_MAX-1:0] hit = seq_rx_dp_ports & MASK_K;
    assign seq_rx_dp_for_client[q]                    = seq_rx_dp_reset & (|hit);
    assign seq_rx_ports_for_client[q*PORT_MAX +: PORT_MAX] = hit;
  end
  endgenerate

  wire [N_CLIENT-1:0] host_rx_dp_req_gated, host_tx_dp_req_gated;
  wire [N_CLIENT-1:0] dprst_rx_stuck, dprst_tx_stuck;
  wire [N_CLIENT-1:0] dprst_rx_refused, dprst_tx_refused;
  wire [2*N_CLIENT-1:0] dprst_rx_state, dprst_tx_state;
  wire [4*N_CLIENT-1:0] dprst_rx_cnt, dprst_tx_cnt;

  localparam logic [7:0] DPRST_DONE_MASK = 8'h03;
  wire gt_dprst_done = ((gt_tx_done_all & DPRST_DONE_MASK) == DPRST_DONE_MASK)
                    && ((gt_rx_done_all & DPRST_DONE_MASK) == DPRST_DONE_MASK);

  generate
  for (q = 0; q < N_CLIENT; q++) begin : g_dprst_gate
    gt_rst_req_gate #(
      .PULSE_CYC    (DPRST_PULSE_CYC),
      .SETTLE_CYC   (DPRST_SETTLE_CYC),
      .DONE_TMO_CYC (DPRST_DONE_TMO_CYC),
      .EN_GATE      (EN_DPRST_GATE),
      .SYNC_DONE    (0)
    ) u_gate_rx (
      .clk            (usr_clk_i),
      .rstn           (seq_rstn),
      .req_level      (ctl_rx_datapath_reset_req[q]),
      .gt_reset_done  (gt_dprst_done),
      .seq_busy       (ctl_seq_busy),
      .req_pulse      (host_rx_dp_req_gated[q]),
      .sts_state      (dprst_rx_state[2*q +: 2]),
      .sts_stuck      (dprst_rx_stuck[q]),
      .sts_refused    (dprst_rx_refused[q]),
      .sts_refuse_cnt (dprst_rx_cnt[4*q +: 4]),
      .clr_status     (1'b0)
    );

    gt_rst_req_gate #(
      .PULSE_CYC    (DPRST_PULSE_CYC),
      .SETTLE_CYC   (DPRST_SETTLE_CYC),
      .DONE_TMO_CYC (DPRST_DONE_TMO_CYC),
      .EN_GATE      (EN_DPRST_GATE),
      .SYNC_DONE    (0)
    ) u_gate_tx (
      .clk            (usr_clk_i),
      .rstn           (seq_rstn),
      .req_level      (ctl_tx_datapath_reset_req[q]),
      .gt_reset_done  (gt_dprst_done),
      .seq_busy       (ctl_seq_busy),
      .req_pulse      (host_tx_dp_req_gated[q]),
      .sts_state      (dprst_tx_state[2*q +: 2]),
      .sts_stuck      (dprst_tx_stuck[q]),
      .sts_refused    (dprst_tx_refused[q]),
      .sts_refuse_cnt (dprst_tx_cnt[4*q +: 4]),
      .clr_status     (1'b0)
    );
  end
  endgenerate

  wire _unused_dprst = (|dprst_rx_state) | (|dprst_tx_state) | (|dprst_rx_stuck)
                     | (|dprst_tx_stuck) | (|dprst_rx_refused) | (|dprst_tx_refused)
                     | (|dprst_rx_cnt)   | (|dprst_tx_cnt);

  wire _unused_sup = (|sup_esc_count) | (|link_sample_count) | (|exec_tmo_count)
                   | (|link_bus_stuck) | (|link_ever_aligned) | (|link_fault_nibble)
                   | (|link_valid) | (|link_window_running) | (|link_last_was_fault)
                   | (|link_bus_err_count) | (|link_window_remaining)
                   | ctl_bringup_done;

  wire [N_CLIENT-1:0] seq_align_sel = rx_pcs_aligned_grp;

  genvar c;
  generate
  for (c = 0; c < N_CLIENT; c++) begin : g_port
    localparam integer AK = (c == 0) ? ANCHOR_0 : ANCHOR_1;

    dcmac_port #(
      .N_SEG(N_SEG), .SEG_W(SEG_W), .DATA_W(DATA_W),
      .PTP_TS_EN(PTP_TS_EN), .PTP_TS_W(PTP_TS_W), .TX_TAG_W(TX_TAG_W),
      .RX_FIFO_AW(RX_FIFO_AW), .RX_CDC_AW(RX_CDC_AW),
      .TX_FIFO_AW(TX_FIFO_AW), .TX_CDC_AW(TX_CDC_AW), .TX_CPL_AW(TX_CPL_AW)
    ) u_port (
      .sys_reset               (sys_reset),
      .seg_clk                 (seg_clk_i),
      .seg_rstn                (seg_rstn_i[c]),
      .usr_clk                 (usr_clk_i),

      .tx_clk                  (tx_clk[c]),
      .tx_rst                  (tx_rst[c]),
      .rx_clk                  (rx_clk[c]),
      .rx_rst                  (rx_rst[c]),

      .usr_rstn                (),

      .s_axis_tx_tdata         (s_axis_tx_tdata [c*DATA_W    +: DATA_W]),
      .s_axis_tx_tkeep         (s_axis_tx_tkeep [c*DATA_W/8  +: DATA_W/8]),
      .s_axis_tx_tvalid        (s_axis_tx_tvalid[c]),
      .s_axis_tx_tready        (s_axis_tx_tready[c]),
      .s_axis_tx_tlast         (s_axis_tx_tlast [c]),
      .s_axis_tx_tuser         (s_axis_tx_tuser [c*TX_USER_W +: TX_USER_W]),

      .m_axis_tx_cpl_valid     (m_axis_tx_cpl_valid[c]),
      .m_axis_tx_cpl_ready     (m_axis_tx_cpl_ready[c]),
      .m_axis_tx_cpl_ts        (m_axis_tx_cpl_ts [c*PTP_TS_W  +: PTP_TS_W]),
      .m_axis_tx_cpl_tag       (m_axis_tx_cpl_tag[c*TX_TAG_WP +: TX_TAG_WP]),

      .m_axis_rx_tdata         (m_axis_rx_tdata [c*DATA_W    +: DATA_W]),
      .m_axis_rx_tkeep         (m_axis_rx_tkeep [c*DATA_W/8  +: DATA_W/8]),
      .m_axis_rx_tvalid        (m_axis_rx_tvalid[c]),
      .m_axis_rx_tlast         (m_axis_rx_tlast [c]),
      .m_axis_rx_tuser         (m_axis_rx_tuser [c*RX_USER_W +: RX_USER_W]),
      .seg_ptp_time            (seg_ptp_time    [c*PTP_TS_W  +: PTP_TS_W]),

      .tx_status               (tx_status[c]),
      .rx_status               (rx_status[c]),

      .rx_overflow             (rx_overflow[c]),
      .rx_trunc                (rx_trunc[c]),
      .rx_err_frames           (rx_err_frames [c*32 +: 32]),
      .rx_drop_frames          (rx_drop_frames[c*32 +: 32]),
      .tx_cpl_overflow         (tx_cpl_overflow[c]),

      .rx_seg_valid            (rx_seg_valid[c]),
      .rx_seg_dat              (rx_seg_dat[c*N_SEG*SEG_W +: N_SEG*SEG_W]),
      .rx_seg_ena              (rx_seg_ena[c*N_SEG +: N_SEG]),
      .rx_seg_sop              (rx_seg_sop[c*N_SEG +: N_SEG]),
      .rx_seg_eop              (rx_seg_eop[c*N_SEG +: N_SEG]),
      .rx_seg_err              (rx_seg_err[c*N_SEG +: N_SEG]),
      .rx_seg_mty              (rx_seg_mty[c*N_SEG*4 +: N_SEG*4]),

      .tx_seg_ready            (tx_seg_ready[c]),
      .tx_seg_valid            (tx_seg_valid[c]),
      .tx_seg_dat              (tx_seg_dat[c*N_SEG*SEG_W +: N_SEG*SEG_W]),
      .tx_seg_ena              (tx_seg_ena[c*N_SEG +: N_SEG]),
      .tx_seg_sop              (tx_seg_sop[c*N_SEG +: N_SEG]),
      .tx_seg_eop              (tx_seg_eop[c*N_SEG +: N_SEG]),
      .tx_seg_err              (tx_seg_err[c*N_SEG +: N_SEG]),
      .tx_seg_mty              (tx_seg_mty[c*N_SEG*4 +: N_SEG*4]),

      .stat_rx_aligned         (seq_align_sel[c]),
      .link_up                 (fsm_link_up[c]),
      .tx_rst_seg              (fsm_tx_rst_seg[c]),
      .ctl_tx_enable           (p_ctl_tx_enable[c])
    );
  end
  endgenerate

  assign p_tx_dp_reset       = host_tx_dp_req_gated;
  assign p_core_serdes_reset = {N_CLIENT{seq_core_serdes_reset}};

  assign link_up = p_carrier;

  wire [N_CLIENT-1:0]          phy_rx_dp_reset =
      p_rx_dp_reset | seq_rx_dp_for_client;
  wire [N_CLIENT*PORT_MAX-1:0] phy_rx_dp_ports =
      p_rx_dp_ports | seq_rx_ports_for_client;

  wire [N_CLIENT-1:0]          phy_tx_dp_reset = p_tx_dp_reset;

  dcmac_phy #(
    .N_CLIENT(N_CLIENT), .N_SEG(N_SEG), .SEG_W(SEG_W), .PORT_MAX(PORT_MAX),
    .LOOPBACK_MODE(LOOPBACK_MODE),
    .ANCHOR_0(ANCHOR_0), .ANCHOR_1(ANCHOR_1),
    .EN_DPRST_SYNC(EN_DPRST_SYNC)
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
    .usr_clk                 (usr_clk_i),

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

    .ctl_rx_enable           (p_ctl_rx_enable),
    .ctl_rx_force_resync     (p_ctl_rx_force_resync),
    .ctl_tx_enable           (p_ctl_tx_enable),
    .ctl_tx_send_idle        (p_ctl_tx_send_idle),
    .ctl_tx_send_lfi         (p_ctl_tx_send_lfi),
    .ctl_tx_send_rfi         (p_ctl_tx_send_rfi),

    .rx_datapath_reset       (phy_rx_dp_reset),
    .rx_datapath_reset_ports (phy_rx_dp_ports),
    .tx_datapath_reset       (phy_tx_dp_reset),

    .axil_aclk               (usr_clk_i),
    .axil_aresetn            (seq_rstn),
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
    .gt_rx_reset_done        (gt_rx_reset_done_raw),
    .core_serdes_reset       (seq_core_serdes_reset | (|p_core_serdes_reset))
  );

endmodule

`default_nettype wire
