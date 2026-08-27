// ---------------------------------------------------------------------------
// File        : dcmac_pktgen_top.sv
// Description : The single client segmented instrument subsystem: one MAC client, the
//               generator on its client interface, the control plane and the PHY.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module dcmac_pktgen_top #(

  parameter integer N_SEG      = 2,
  parameter integer SEG_W      = 128,
  parameter integer PORT_MAX   = 6,
  parameter integer NPORTS     = 1,
  parameter integer ANCHOR     = 0,
  parameter [2:0]   LOOPBACK_MODE = 3'b000,
  parameter integer N_LANE     = 4,

  parameter logic [7:0] DONE_MASK      = dcmac_ctl_pkg::DONEMASK_100G,
  parameter int         RATE_CODE      = dcmac_ctl_pkg::RATE_CODE_100G,
  parameter int         RATE_FIELD     = dcmac_ctl_pkg::RATE_FIELD_100G,
  parameter logic [7:0] POLARITY_TX_Q0 = dcmac_ctl_pkg::QSFP0_TXPOLARITY,
  parameter logic [7:0] POLARITY_RX_Q0 = dcmac_ctl_pkg::QSFP0_RXPOLARITY,
  parameter logic [7:0] POLARITY_TX_Q1 = dcmac_ctl_pkg::QSFP1_TXPOLARITY,
  parameter logic [7:0] POLARITY_RX_Q1 = dcmac_ctl_pkg::QSFP1_RXPOLARITY,

  parameter integer SEG_CYC_PER_MS = 390930,
  parameter integer CTL_CYC_PER_MS = 250000,
  parameter integer T_RXDP_MS      = 100,
  parameter integer T_SERDES_MS    = 100,
  parameter integer LINK_WDT_MS    = 750,
  parameter integer T_SAMPLE_MS    = 50,
  parameter integer PKTGEN_AXIL_AW = 12
)(

  input  wire                    sys_reset,

  input  wire                    gt_ref_clk_p,
  input  wire                    gt_ref_clk_n,

  input  wire                    gt_ref_clk1_p,
  input  wire                    gt_ref_clk1_n,

  input  wire [N_LANE-1:0]       gt_rxp_in,
  input  wire [N_LANE-1:0]       gt_rxn_in,
  output wire [N_LANE-1:0]       gt_txn_out,
  output wire [N_LANE-1:0]       gt_txp_out,

  output wire                    seg_clk,
  output wire                    usr_clk,
  output wire                    usr_rstn,

  output wire                    link_up,
  output wire                    rx_pcs_aligned,
  output wire [2:0]              mac_fsm_state,

  input  wire                    ctl_bringup_restart_req,
  input  wire                    ctl_stats_req,
  input  wire                    ctl_rx_force_resync_req,
  input  wire                    ctl_rx_datapath_reset_req,
  input  wire                    ctl_tx_datapath_reset_req,
  output wire                    ctl_link_fault,
  output wire                    ctl_access_fault,
  output wire                    ctl_seq_busy,
  output wire [31:0]             ctl_rx_phy_status,
  output wire [7:0]              ctl_retry_cnt,
  output wire [4:0]              ctl_seq_state,
  output wire [15:0]             ctl_seq_pc,
  input  wire [7:0]              ctl_stat_rd_idx,
  output wire [31:0]             ctl_stat_rd_data,
  output wire [31:0]             ctl_align_word,
  output wire [31:0]             ctl_align_sticky,
  output wire [3:0]              ctl_fault_nibble,
  output wire                    ctl_bus_stuck,
  output wire                    ctl_link_valid,
  output wire                    ctl_ever_aligned,
  output wire                    ctl_window_running,
  output wire                    ctl_last_was_fault,
  output wire [15:0]             ctl_sample_count,
  output wire [15:0]             ctl_esc_count,
  output wire [15:0]             ctl_bus_err_count,
  output wire [15:0]             ctl_exec_tmo_count,
  output wire [7:0]              ctl_repair_dp_count,
  output wire [7:0]              ctl_repair_pll_count,

  input  wire [PKTGEN_AXIL_AW-1:0] pg_awaddr,
  input  wire                    pg_awvalid,
  output wire                    pg_awready,
  input  wire [31:0]             pg_wdata,
  input  wire [3:0]              pg_wstrb,
  input  wire                    pg_wvalid,
  output wire                    pg_wready,
  output wire [1:0]              pg_bresp,
  output wire                    pg_bvalid,
  input  wire                    pg_bready,
  input  wire [PKTGEN_AXIL_AW-1:0] pg_araddr,
  input  wire                    pg_arvalid,
  output wire                    pg_arready,
  output wire [31:0]             pg_rdata,
  output wire [1:0]              pg_rresp,
  output wire                    pg_rvalid,
  input  wire                    pg_rready
);

  wire                     seg_clk_i, usr_clk_i;
  wire [0:0]               seg_rstn_i;

  wire                     rx_seg_valid, tx_seg_ready, tx_seg_valid;
  wire [N_SEG*SEG_W-1:0]   rx_seg_dat, tx_seg_dat;
  wire [N_SEG-1:0]         rx_seg_ena, rx_seg_sop, rx_seg_eop, rx_seg_err;
  wire [N_SEG*4-1:0]       rx_seg_mty, tx_seg_mty;
  wire [N_SEG-1:0]         tx_seg_ena, tx_seg_sop, tx_seg_eop, tx_seg_err;

  wire                     ctl_rx_enable, ctl_rx_force_resync_core, ctl_tx_enable;
  wire                     ctl_tx_send_idle, ctl_tx_send_lfi, ctl_tx_send_rfi;

  wire                     fsm_link_up, fsm_tx_rst_seg, rx_pcs_aligned_grp;
  wire                     port_rx_dp_reset, port_core_serdes_reset;
  wire                     port_rx_pll_dp_reset;
  wire                     port_gt_all_reset;
  wire                     port_rx_serdes_reset;
  wire                     port_rx_flush;
  wire                     gt_rx_done_seg;
  wire [7:0]               port_repair_count;
  wire [7:0]               port_repair_tmo_count;
  wire                     seg_rstn_ctl_i;
  wire [PORT_MAX-1:0]      port_rx_dp_reset_ports;

  wire                     seq_rx_dp_reset;
  wire [PORT_MAX-1:0]      seq_rx_dp_ports;

  wire [7:0]               gt_tx_reset_done_raw, gt_rx_reset_done_raw;
  wire [7:0]               gt_tx_reset_done, gt_rx_reset_done;

  wire [19:0]              seq_awaddr, seq_araddr;
  wire [31:0]              seq_wdata, seq_rdata;
  wire [3:0]               seq_wstrb;
  wire [1:0]               seq_bresp, seq_rresp;
  wire                     seq_awvalid, seq_awready, seq_wvalid, seq_wready;
  wire                     seq_bvalid, seq_bready, seq_arvalid, seq_arready;
  wire                     seq_rvalid, seq_rready;

  assign seg_clk = seg_clk_i;
  assign usr_clk = usr_clk_i;

  (* ASYNC_REG = "TRUE" *) reg [2:0] usr_rstn_sr = 3'b000;
  always_ff @(posedge usr_clk_i) usr_rstn_sr <= {usr_rstn_sr[1:0], ~sys_reset};
  wire usr_rstn_i = usr_rstn_sr[2];
  assign usr_rstn = usr_rstn_i;
  assign ctl_repair_dp_count  = port_repair_count;
  assign ctl_repair_pll_count = port_repair_tmo_count;

  dcmac_sync2 #(.WIDTH(1), .STAGES(2), .INIT('0)) u_sync_gt_rx_done_seg (
    .clk  (seg_clk_i),
    .din  (|gt_rx_reset_done_raw),
    .dout (gt_rx_done_seg));

  wire host_rx_req_gated;

  dcmac_sync2 #(.WIDTH(8), .STAGES(2), .INIT(8'h00)) u_sync_gt_tx_done (
    .clk  (usr_clk_i),
    .din  (gt_tx_reset_done_raw),
    .dout (gt_tx_reset_done));

  dcmac_sync2 #(.WIDTH(8), .STAGES(2), .INIT(8'h00)) u_sync_gt_rx_done (
    .clk  (usr_clk_i),
    .din  (gt_rx_reset_done_raw),
    .dout (gt_rx_reset_done));

  gt_rst_req_gate #(
    .EN_GATE   (1),
    .SYNC_DONE (1)
  ) u_gate_rx (
    .clk           (usr_clk_i),
    .rstn          (usr_rstn_i),
    .req_level     (ctl_rx_datapath_reset_req),
    .gt_reset_done ((|gt_tx_reset_done) && (|gt_rx_reset_done)),
    .seq_busy      (ctl_seq_busy),
    .req_pulse     (host_rx_req_gated),
    .sts_state      (),
    .sts_stuck      (),
    .sts_refused    (),
    .sts_refuse_cnt (),
    .clr_status     (1'b0)
  );

  dcmac_link_ctl #(
    .PORT_MAX   (PORT_MAX),
    .NPORTS     (NPORTS),
    .ANCHOR     (ANCHOR),
    .N_GROUP    (1),
    .ANCHOR_1   (ANCHOR),
    .CYC_PER_MS (CTL_CYC_PER_MS),

    .LINK_WDT_MS     (LINK_WDT_MS),
    .T_SAMPLE_MS     (T_SAMPLE_MS),
    .SEG_CYC_PER_MS  (SEG_CYC_PER_MS),
    .T_RXDP_MS       (T_RXDP_MS),
    .T_SERDES_MS     (T_SERDES_MS),
    .ALIGN_EXPORT_MODE (1),
    .RATE_CODE       (RATE_CODE),
    .RATE_FIELD      (RATE_FIELD),
    .DONE_MASK       (DONE_MASK)
  ) u_ctl (
    .aclk                    (usr_clk_i),
    .aresetn                 (usr_rstn_i),

    .seg_clk                 (seg_clk_i),
    .seg_rstn                (seg_rstn_ctl_i),

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
    .fsm_rx_pll_datapath_reset   (port_rx_pll_dp_reset),
    .fsm_gt_all_reset            (port_gt_all_reset),
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

    .gt_tx_reset_done        (gt_tx_reset_done),
    .gt_rx_reset_done        (gt_rx_reset_done),
    .rx_datapath_reset       (seq_rx_dp_reset),
    .rx_datapath_reset_ports (seq_rx_dp_ports),
    .core_serdes_reset       (port_core_serdes_reset),
    .tx_datapath_reset       (),

    .bringup_restart_req     (ctl_bringup_restart_req),
    .stats_req               (ctl_stats_req),
    .rx_force_resync_req     (1'b0),
    .rx_datapath_reset_req   (1'b0),
    .tx_datapath_reset_req   (ctl_tx_datapath_reset_req),
    .rx_force_resync         (),

    .link_wdt_ms             (16'(LINK_WDT_MS)),

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

  dcmac_seg_pktgen #(
    .N_SEG(N_SEG), .SEG_W(SEG_W), .AXIL_ADDR_W(PKTGEN_AXIL_AW)
  ) u_pktgen (
    .seg_clk       (seg_clk_i),
    .seg_rstn      (seg_rstn_i[0]),

    .link_up       (fsm_link_up),
    .tx_rst_seg    (fsm_tx_rst_seg),
    .ctl_tx_enable (ctl_tx_enable),

    .tx_seg_ready  (tx_seg_ready),
    .tx_seg_valid  (tx_seg_valid),
    .tx_seg_dat    (tx_seg_dat),
    .tx_seg_ena    (tx_seg_ena),
    .tx_seg_sop    (tx_seg_sop),
    .tx_seg_eop    (tx_seg_eop),
    .tx_seg_err    (tx_seg_err),
    .tx_seg_mty    (tx_seg_mty),

    .rx_seg_valid  (rx_seg_valid),
    .rx_seg_dat    (rx_seg_dat),
    .rx_seg_ena    (rx_seg_ena),
    .rx_seg_sop    (rx_seg_sop),
    .rx_seg_eop    (rx_seg_eop),
    .rx_seg_err    (rx_seg_err),
    .rx_seg_mty    (rx_seg_mty),

    .axil_aclk     (usr_clk_i),
    .axil_aresetn  (usr_rstn_i),
    .s_axil_awaddr (pg_awaddr),
    .s_axil_awvalid(pg_awvalid),
    .s_axil_awready(pg_awready),
    .s_axil_wdata  (pg_wdata),
    .s_axil_wstrb  (pg_wstrb),
    .s_axil_wvalid (pg_wvalid),
    .s_axil_wready (pg_wready),
    .s_axil_bresp  (pg_bresp),
    .s_axil_bvalid (pg_bvalid),
    .s_axil_bready (pg_bready),
    .s_axil_araddr (pg_araddr),
    .s_axil_arvalid(pg_arvalid),
    .s_axil_arready(pg_arready),
    .s_axil_rdata  (pg_rdata),
    .s_axil_rresp  (pg_rresp),
    .s_axil_rvalid (pg_rvalid),
    .s_axil_rready (pg_rready)
  );

  localparam logic [PORT_MAX-1:0] GROUP_MASK = ((PORT_MAX)'((1 << NPORTS) - 1)) << ANCHOR;
  wire [PORT_MAX-1:0] seq_rx_hit      = seq_rx_dp_ports & GROUP_MASK;
  wire                phy_rx_dp_reset = port_rx_dp_reset | (seq_rx_dp_reset & (|seq_rx_hit));
  wire [PORT_MAX-1:0] phy_rx_dp_ports = port_rx_dp_reset_ports | seq_rx_hit;

  dcmac_phy #(
    .N_CLIENT(1),
    .N_SEG(N_SEG), .SEG_W(SEG_W), .PORT_MAX(PORT_MAX),
    .LOOPBACK_MODE(LOOPBACK_MODE),
    .ANCHOR_0(ANCHOR), .ANCHOR_1(ANCHOR + NPORTS),
    .POLARITY_TX_Q0(POLARITY_TX_Q0), .POLARITY_RX_Q0(POLARITY_RX_Q0),
    .POLARITY_TX_Q1(POLARITY_TX_Q1), .POLARITY_RX_Q1(POLARITY_RX_Q1)
  ) u_phy (
    .sys_reset               (sys_reset),
    .gt_ref_clk0_p           (gt_ref_clk_p),
    .gt_ref_clk0_n           (gt_ref_clk_n),
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
    .rx_pll_datapath_reset   (port_rx_pll_dp_reset),
    .gt_all_reset            (port_gt_all_reset),
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
    .gt_rx_reset_done        (gt_rx_reset_done_raw),
    .core_serdes_reset       (port_core_serdes_reset)
  );

  assign rx_pcs_aligned = rx_pcs_aligned_grp;

endmodule
