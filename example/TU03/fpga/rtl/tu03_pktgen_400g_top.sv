// ---------------------------------------------------------------------------
// File        : tu03_pktgen_400g_top.sv
// Description : The device top of the single client 400GAUI-4 image. One client occupies
//               QSFP0 across two transceiver quads, so the aperture decodes one generator
//               block and the command block and nothing at the second client offset.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module tu03_pktgen_400g_top #(

  parameter integer HOST_ADDR_W   = 16,
  parameter integer LOOPBACK_MODE = 0,
  parameter integer LEN_MIN_HW    = 60,
  parameter integer LEN_MAX_HW    = 9018
)(

  input  wire        gt_ref_clk0_p,
  input  wire        gt_ref_clk0_n,
  input  wire        gt_ref_clk1_p,
  input  wire        gt_ref_clk1_n,
  input  wire [7:0]  gt_rxp_in,
  input  wire [7:0]  gt_rxn_in,
  output wire [7:0]  gt_txn_out,
  output wire [7:0]  gt_txp_out
);

  localparam int PG_AW    = 12;
  localparam int BLOCK    = HOST_ADDR_W - PG_AW;
  localparam logic [BLOCK-1:0] BLOCK_PKTGEN_0 = 'h0;
  localparam logic [BLOCK-1:0] BLOCK_COMMAND  = 'h1;

  wire        usr_clk, usr_rstn, pl_resetn;
  wire        sys_reset = ~pl_resetn;

  wire [31:0] host_awaddr, host_araddr, host_wdata, host_rdata;
  wire [3:0]  host_wstrb;
  wire [1:0]  host_bresp, host_rresp;
  wire        host_awvalid, host_awready, host_wvalid, host_wready;
  wire        host_bvalid, host_bready, host_arvalid, host_arready;
  wire        host_rvalid, host_rready;

  wire [BLOCK-1:0] block_aw = host_awaddr[HOST_ADDR_W-1:PG_AW];
  wire [BLOCK-1:0] block_ar = host_araddr[HOST_ADDR_W-1:PG_AW];

  wire       pg_sel_aw  = (block_aw == BLOCK_PKTGEN_0);
  wire       pg_sel_ar  = (block_ar == BLOCK_PKTGEN_0);
  wire       cmd_sel_aw = (block_aw == BLOCK_COMMAND);
  wire       cmd_sel_ar = (block_ar == BLOCK_COMMAND);

  wire        pg_awready, pg_wready, pg_bvalid, pg_arready, pg_rvalid;
  wire [1:0]  pg_bresp, pg_rresp;
  wire [31:0] pg_rdata;

  logic        cmd_bvalid_r, cmd_rvalid_r;
  logic [31:0] cmd_rdata_r;

  logic        cmd_bringup_restart_r;
  logic        cmd_stats_r;
  logic        cmd_rx_resync_r;
  logic        cmd_rx_dp_reset_r;
  logic        cmd_tx_dp_reset_r;
  logic [7:0]  cmd_stat_idx_r;

  wire        ctl_link_up;
  wire        ctl_rx_pcs_aligned;
  wire [2:0]  ctl_mac_fsm_state;
  wire [31:0] ctl_rx_phy_status;
  wire [31:0] ctl_stat_rd_data;
  wire [31:0] ctl_align_word;
  wire [31:0] ctl_align_sticky;
  wire [3:0]  ctl_fault_nibble;
  wire        ctl_bus_stuck;
  wire        ctl_link_valid;
  wire        ctl_ever_aligned;
  wire        ctl_window_running;
  wire        ctl_last_was_fault;
  wire [15:0] ctl_sample_count;
  wire [15:0] ctl_esc_count;
  wire [15:0] ctl_bus_err_count;
  wire [15:0] ctl_exec_tmo_count;
  wire [7:0]  ctl_repair_dp_count;
  wire [7:0]  ctl_repair_pll_count;
  wire [7:0]  ctl_retry_cnt;
  wire [4:0]  ctl_seq_state;
  wire [15:0] ctl_seq_pc;
  wire        ctl_link_fault, ctl_access_fault, ctl_seq_busy;

  assign host_awready = pg_sel_aw ? pg_awready : (cmd_sel_aw && !cmd_bvalid_r);
  assign host_wready  = pg_sel_aw ? pg_wready  : (cmd_sel_aw && !cmd_bvalid_r);
  assign host_bvalid  = pg_sel_aw ? pg_bvalid  : cmd_bvalid_r;
  assign host_bresp   = 2'b00;
  assign host_arready = pg_sel_ar ? pg_arready : (cmd_sel_ar && !cmd_rvalid_r);
  assign host_rvalid  = pg_sel_ar ? pg_rvalid  : cmd_rvalid_r;
  assign host_rresp   = 2'b00;
  assign host_rdata   = pg_sel_ar ? pg_rdata : cmd_rdata_r;

  wire cmd_write = cmd_sel_aw && host_awvalid && host_wvalid && !cmd_bvalid_r;
  wire cmd_read  = cmd_sel_ar && host_arvalid && !cmd_rvalid_r;

  always_ff @(posedge usr_clk) begin
    if (!usr_rstn) begin
      cmd_bvalid_r          <= 1'b0;
      cmd_rvalid_r          <= 1'b0;
      cmd_rdata_r           <= '0;
      cmd_bringup_restart_r <= 1'b0;
      cmd_stats_r           <= 1'b0;
      cmd_rx_resync_r       <= 1'b0;
      cmd_rx_dp_reset_r     <= 1'b0;
      cmd_tx_dp_reset_r     <= 1'b0;
      cmd_stat_idx_r        <= '0;
    end else begin
      if (cmd_write) begin
        cmd_bvalid_r <= 1'b1;
        case (host_awaddr[7:2])
          6'h00: begin
            cmd_bringup_restart_r <= host_wdata[0];
            cmd_stats_r           <= host_wdata[1];
            cmd_rx_resync_r       <= host_wdata[2];
            cmd_rx_dp_reset_r     <= host_wdata[3];
            cmd_tx_dp_reset_r     <= host_wdata[4];
          end
          6'h01: cmd_stat_idx_r <= host_wdata[7:0];
          default: ;
        endcase
      end else if (cmd_bvalid_r && host_bready) begin
        cmd_bvalid_r <= 1'b0;
      end

      if (cmd_read) begin
        cmd_rvalid_r <= 1'b1;
        case (host_araddr[7:2])
          6'h00: cmd_rdata_r <= {27'd0, cmd_tx_dp_reset_r, cmd_rx_dp_reset_r,
                                 cmd_rx_resync_r, cmd_stats_r, cmd_bringup_restart_r};
          6'h01: cmd_rdata_r <= {24'd0, cmd_stat_idx_r};
          6'h02: cmd_rdata_r <= {27'd0, ctl_rx_pcs_aligned, ctl_seq_busy, ctl_access_fault,
                                 ctl_link_fault, ctl_link_up};
          6'h03: cmd_rdata_r <= {8'd0, ctl_seq_pc, 3'd0, ctl_seq_state};
          6'h04: cmd_rdata_r <= ctl_rx_phy_status;
          6'h05: cmd_rdata_r <= {24'd0, ctl_retry_cnt};
          6'h06: cmd_rdata_r <= ctl_stat_rd_data;
          6'h07: cmd_rdata_r <= {29'd0, ctl_mac_fsm_state};
          6'h08: cmd_rdata_r <= ctl_align_word;
          6'h09: cmd_rdata_r <= 32'd0;
          6'h0A: cmd_rdata_r <= ctl_align_sticky;
          6'h0B: cmd_rdata_r <= 32'd0;
          6'h0C: cmd_rdata_r <= {23'd0, ctl_last_was_fault, ctl_window_running,
                                 ctl_ever_aligned, ctl_link_valid, ctl_bus_stuck,
                                 ctl_fault_nibble};
          6'h0D: cmd_rdata_r <= {16'd0, ctl_sample_count};
          6'h0E: cmd_rdata_r <= {16'd0, ctl_esc_count};
          6'h0F: cmd_rdata_r <= {16'd0, ctl_bus_err_count};
          6'h10: cmd_rdata_r <= {16'd0, ctl_exec_tmo_count};
          6'h11: cmd_rdata_r <= {16'd0, ctl_repair_pll_count, ctl_repair_dp_count};
          default: cmd_rdata_r <= 32'd0;
        endcase
      end else if (cmd_rvalid_r && host_rready) begin
        cmd_rvalid_r <= 1'b0;
      end
    end
  end

  dcmac_host_bridge_wrapper u_host_bridge (
    .axil_aclk      (usr_clk),
    .pl_resetn      (pl_resetn),

    .m_axil_awaddr  (host_awaddr),
    .m_axil_awprot  (),
    .m_axil_awvalid (host_awvalid),
    .m_axil_awready (host_awready),
    .m_axil_wdata   (host_wdata),
    .m_axil_wstrb   (host_wstrb),
    .m_axil_wvalid  (host_wvalid),
    .m_axil_wready  (host_wready),
    .m_axil_bresp   (host_bresp),
    .m_axil_bvalid  (host_bvalid),
    .m_axil_bready  (host_bready),
    .m_axil_araddr  (host_araddr),
    .m_axil_arprot  (),
    .m_axil_arvalid (host_arvalid),
    .m_axil_arready (host_arready),
    .m_axil_rdata   (host_rdata),
    .m_axil_rresp   (host_rresp),
    .m_axil_rvalid  (host_rvalid),
    .m_axil_rready  (host_rready)
  );

  dcmac_pktgen_top #(
    .PKTGEN_AXIL_AW (PG_AW),
    .LOOPBACK_MODE  (3'(LOOPBACK_MODE)),
    .LEN_MIN_HW     (LEN_MIN_HW),
    .LEN_MAX_HW     (LEN_MAX_HW),
    .N_SEG          (8),
    .N_LANE         (8),
    .NPORTS         (4),
    .ANCHOR         (0),
    .DONE_MASK      (dcmac_ctl_pkg::DONEMASK_100G),
    .RATE_CODE      (dcmac_ctl_pkg::RATE_CODE_400G),
    .RATE_FIELD     (dcmac_ctl_pkg::RATE_FIELD_400G),
    .POLARITY_TX_Q0 (8'b0000_1100),
    .POLARITY_RX_Q0 (8'b0000_0000),
    .POLARITY_TX_Q1 (8'b0000_0011),
    .POLARITY_RX_Q1 (8'b0000_1111)
  ) u_seam (
    .sys_reset               (sys_reset),

    .gt_ref_clk_p            (gt_ref_clk0_p),
    .gt_ref_clk_n            (gt_ref_clk0_n),
    .gt_ref_clk1_p           (gt_ref_clk1_p),
    .gt_ref_clk1_n           (gt_ref_clk1_n),
    .gt_rxp_in               (gt_rxp_in),
    .gt_rxn_in               (gt_rxn_in),
    .gt_txn_out              (gt_txn_out),
    .gt_txp_out              (gt_txp_out),

    .seg_clk                 (),
    .usr_clk                 (usr_clk),
    .usr_rstn                (usr_rstn),

    .link_up                 (ctl_link_up),
    .rx_pcs_aligned          (ctl_rx_pcs_aligned),
    .mac_fsm_state           (ctl_mac_fsm_state),

    .ctl_bringup_restart_req   (cmd_bringup_restart_r),
    .ctl_stats_req             (cmd_stats_r),
    .ctl_rx_force_resync_req   (cmd_rx_resync_r),
    .ctl_rx_datapath_reset_req (cmd_rx_dp_reset_r),
    .ctl_tx_datapath_reset_req (cmd_tx_dp_reset_r),
    .ctl_link_fault            (ctl_link_fault),
    .ctl_access_fault          (ctl_access_fault),
    .ctl_seq_busy              (ctl_seq_busy),
    .ctl_rx_phy_status         (ctl_rx_phy_status),
    .ctl_retry_cnt             (ctl_retry_cnt),
    .ctl_seq_state             (ctl_seq_state),
    .ctl_seq_pc                (ctl_seq_pc),
    .ctl_stat_rd_idx           (cmd_stat_idx_r),
    .ctl_stat_rd_data          (ctl_stat_rd_data),
    .ctl_align_word            (ctl_align_word),
    .ctl_align_sticky          (ctl_align_sticky),
    .ctl_fault_nibble          (ctl_fault_nibble),
    .ctl_bus_stuck             (ctl_bus_stuck),
    .ctl_link_valid            (ctl_link_valid),
    .ctl_ever_aligned          (ctl_ever_aligned),
    .ctl_window_running        (ctl_window_running),
    .ctl_last_was_fault        (ctl_last_was_fault),
    .ctl_sample_count          (ctl_sample_count),
    .ctl_esc_count             (ctl_esc_count),
    .ctl_bus_err_count         (ctl_bus_err_count),
    .ctl_exec_tmo_count        (ctl_exec_tmo_count),
    .ctl_repair_dp_count       (ctl_repair_dp_count),
    .ctl_repair_pll_count      (ctl_repair_pll_count),

    .pg_awaddr               (host_awaddr[PG_AW-1:0]),
    .pg_awvalid              (pg_sel_aw & host_awvalid),
    .pg_awready              (pg_awready),
    .pg_wdata                (host_wdata),
    .pg_wstrb                (host_wstrb),
    .pg_wvalid               (pg_sel_aw & host_wvalid),
    .pg_wready               (pg_wready),
    .pg_bresp                (pg_bresp),
    .pg_bvalid               (pg_bvalid),
    .pg_bready               (pg_sel_aw & host_bready),
    .pg_araddr               (host_araddr[PG_AW-1:0]),
    .pg_arvalid              (pg_sel_ar & host_arvalid),
    .pg_arready              (pg_arready),
    .pg_rdata                (pg_rdata),
    .pg_rresp                (pg_rresp),
    .pg_rvalid               (pg_rvalid),
    .pg_rready               (pg_sel_ar & host_rready)
  );

endmodule
