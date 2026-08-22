// ---------------------------------------------------------------------------
// File        : fpga_pktgen_top.sv
// Description : The board independent body of the single cage segmented image: the
//               aperture decode, the generator, the control plane and the PHY, with no
//               device pin.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module fpga_pktgen_top #(

  parameter integer N_SEG        = 2,
  parameter integer SEG_W        = 128,
  parameter integer PORT_MAX     = 6,
  parameter integer NPORTS       = 1,
  parameter integer ANCHOR       = 0,
  parameter integer LOOPBACK_MODE = 0,
  parameter integer HOST_ADDR_W  = 16,
  parameter integer PKTGEN_BASE  = 16'h0000,
  parameter integer COMMAND_BASE = 16'h1000
)(

  input  wire                    sys_reset,

  input  wire                    gt_ref_clk_p,
  input  wire                    gt_ref_clk_n,
  input  wire [3:0]              gt_rxp_in,
  input  wire [3:0]              gt_rxn_in,
  output wire [3:0]              gt_txn_out,
  output wire [3:0]              gt_txp_out,

  output wire                    usr_clk,

  output wire                    link_up,
  output wire [2:0]              mac_fsm_state,

  input  wire [HOST_ADDR_W-1:0]  s_axil_awaddr,
  input  wire                    s_axil_awvalid,
  output wire                    s_axil_awready,
  input  wire [31:0]             s_axil_wdata,
  input  wire [3:0]              s_axil_wstrb,
  input  wire                    s_axil_wvalid,
  output wire                    s_axil_wready,
  output wire [1:0]              s_axil_bresp,
  output wire                    s_axil_bvalid,
  input  wire                    s_axil_bready,
  input  wire [HOST_ADDR_W-1:0]  s_axil_araddr,
  input  wire                    s_axil_arvalid,
  output wire                    s_axil_arready,
  output wire [31:0]             s_axil_rdata,
  output wire [1:0]              s_axil_rresp,
  output wire                    s_axil_rvalid,
  input  wire                    s_axil_rready
);

  localparam int PG_AW = 12;

  wire usr_rstn, seg_clk;

  wire        pg_sel_aw = (s_axil_awaddr[HOST_ADDR_W-1:PG_AW] == PKTGEN_BASE[HOST_ADDR_W-1:PG_AW]);
  wire        pg_sel_ar = (s_axil_araddr[HOST_ADDR_W-1:PG_AW] == PKTGEN_BASE[HOST_ADDR_W-1:PG_AW]);
  wire        cmd_sel_aw = (s_axil_awaddr[HOST_ADDR_W-1:PG_AW] == COMMAND_BASE[HOST_ADDR_W-1:PG_AW]);
  wire        cmd_sel_ar = (s_axil_araddr[HOST_ADDR_W-1:PG_AW] == COMMAND_BASE[HOST_ADDR_W-1:PG_AW]);

  wire        pg_awready, pg_wready, pg_bvalid, pg_arready, pg_rvalid;
  wire [1:0]  pg_bresp, pg_rresp;
  wire [31:0] pg_rdata;

  logic       cmd_bvalid_r, cmd_rvalid_r;
  logic [31:0] cmd_rdata_r;

  logic       cmd_bringup_restart_r;
  logic       cmd_stats_r;
  logic       cmd_rx_resync_r;
  logic       cmd_rx_dp_reset_r;
  logic       cmd_tx_dp_reset_r;
  logic [7:0] cmd_stat_idx_r;

  wire [31:0] ctl_rx_phy_status;
  wire [31:0] ctl_stat_rd_data;
  wire [7:0]  ctl_retry_cnt;
  wire [4:0]  ctl_seq_state;
  wire [15:0] ctl_seq_pc;
  wire        ctl_link_fault, ctl_access_fault, ctl_seq_busy;
  wire        ctl_rx_pcs_aligned;

  assign s_axil_awready = pg_sel_aw ? pg_awready : (cmd_sel_aw && !cmd_bvalid_r);
  assign s_axil_wready  = pg_sel_aw ? pg_wready  : (cmd_sel_aw && !cmd_bvalid_r);
  assign s_axil_bvalid  = pg_sel_aw ? pg_bvalid  : cmd_bvalid_r;
  assign s_axil_bresp   = pg_sel_aw ? pg_bresp   : 2'b00;
  assign s_axil_arready = pg_sel_ar ? pg_arready : !cmd_rvalid_r;
  assign s_axil_rvalid  = pg_sel_ar ? pg_rvalid  : cmd_rvalid_r;
  assign s_axil_rresp   = pg_sel_ar ? pg_rresp   : 2'b00;
  assign s_axil_rdata   = pg_sel_ar ? pg_rdata   : cmd_rdata_r;

  wire cmd_write = cmd_sel_aw && s_axil_awvalid && s_axil_wvalid && !cmd_bvalid_r;
  wire cmd_read  = cmd_sel_ar && s_axil_arvalid && !cmd_rvalid_r;

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
        case (s_axil_awaddr[7:2])
          6'h00: begin
            cmd_bringup_restart_r <= s_axil_wdata[0];
            cmd_stats_r           <= s_axil_wdata[1];
            cmd_rx_resync_r       <= s_axil_wdata[2];
            cmd_rx_dp_reset_r     <= s_axil_wdata[3];
            cmd_tx_dp_reset_r     <= s_axil_wdata[4];
          end
          6'h01: cmd_stat_idx_r <= s_axil_wdata[7:0];
          default: ;
        endcase
      end else if (cmd_bvalid_r && s_axil_bready) begin
        cmd_bvalid_r <= 1'b0;
      end

      if (cmd_read) begin
        cmd_rvalid_r <= 1'b1;
        case (s_axil_araddr[7:2])
          6'h00: cmd_rdata_r <= {27'd0, cmd_tx_dp_reset_r, cmd_rx_dp_reset_r,
                                 cmd_rx_resync_r, cmd_stats_r, cmd_bringup_restart_r};
          6'h01: cmd_rdata_r <= {24'd0, cmd_stat_idx_r};
          6'h02: cmd_rdata_r <= {27'd0, ctl_rx_pcs_aligned, ctl_seq_busy, ctl_access_fault,
                                 ctl_link_fault, link_up};
          6'h03: cmd_rdata_r <= {8'd0, ctl_seq_pc, 3'd0, ctl_seq_state};
          6'h04: cmd_rdata_r <= ctl_rx_phy_status;
          6'h05: cmd_rdata_r <= {24'd0, ctl_retry_cnt};
          6'h06: cmd_rdata_r <= ctl_stat_rd_data;
          6'h07: cmd_rdata_r <= {29'd0, mac_fsm_state};
          default: cmd_rdata_r <= 32'd0;
        endcase
      end else if (cmd_rvalid_r && s_axil_rready) begin
        cmd_rvalid_r <= 1'b0;
      end
    end
  end

  dcmac_pktgen_top #(
    .N_SEG(N_SEG), .SEG_W(SEG_W), .PORT_MAX(PORT_MAX),
    .NPORTS(NPORTS), .ANCHOR(ANCHOR), .PKTGEN_AXIL_AW(PG_AW),
    .LOOPBACK_MODE(3'(LOOPBACK_MODE))
  ) u_seam (
    .sys_reset               (sys_reset),

    .gt_ref_clk_p            (gt_ref_clk_p),
    .gt_ref_clk_n            (gt_ref_clk_n),
    .gt_ref_clk1_p           (1'b0),
    .gt_ref_clk1_n           (1'b0),
    .gt_rxp_in               (gt_rxp_in),
    .gt_rxn_in               (gt_rxn_in),
    .gt_txn_out              (gt_txn_out),
    .gt_txp_out              (gt_txp_out),

    .seg_clk                 (seg_clk),
    .usr_clk                 (usr_clk),
    .usr_rstn                (usr_rstn),

    .link_up                 (link_up),
    .rx_pcs_aligned          (ctl_rx_pcs_aligned),
    .mac_fsm_state           (mac_fsm_state),

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

    .pg_awaddr               (s_axil_awaddr[PG_AW-1:0]),
    .pg_awvalid              (s_axil_awvalid & pg_sel_aw),
    .pg_awready              (pg_awready),
    .pg_wdata                (s_axil_wdata),
    .pg_wstrb                (s_axil_wstrb),
    .pg_wvalid               (s_axil_wvalid & pg_sel_aw),
    .pg_wready               (pg_wready),
    .pg_bresp                (pg_bresp),
    .pg_bvalid               (pg_bvalid),
    .pg_bready               (s_axil_bready & pg_sel_aw),
    .pg_araddr               (s_axil_araddr[PG_AW-1:0]),
    .pg_arvalid              (s_axil_arvalid & pg_sel_ar),
    .pg_arready              (pg_arready),
    .pg_rdata                (pg_rdata),
    .pg_rresp                (pg_rresp),
    .pg_rvalid               (pg_rvalid),
    .pg_rready               (s_axil_rready & pg_sel_ar)
  );

  wire _unused_top = (|seg_clk);

endmodule
