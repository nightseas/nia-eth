// ---------------------------------------------------------------------------
// File        : tu03_axispg_top.sv
// Description : The device top of the single cage AXI-Stream image. The aperture decodes
//               one generator block and one command block, and the command block also
//               publishes the adapter's receive counters.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module tu03_axispg_top #(

  parameter integer HOST_ADDR_W   = 16,
  parameter integer DATA_W        = 512,
  parameter integer LOOPBACK_MODE = 0,
  parameter integer LEN_MIN_HW    = 64,
  parameter integer LEN_MAX_HW    = 9018
)(

  input  wire        gt_ref_clk_p,
  input  wire        gt_ref_clk_n,
  input  wire [3:0]  gt_rxp_in,
  input  wire [3:0]  gt_rxn_in,
  output wire [3:0]  gt_txn_out,
  output wire [3:0]  gt_txp_out
);

  localparam int PG_AW = 12;
  localparam int BLOCK = HOST_ADDR_W - PG_AW;
  localparam logic [BLOCK-1:0] BLOCK_PKTGEN  = 'h0;
  localparam logic [BLOCK-1:0] BLOCK_COMMAND = 'h1;


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

  wire pg_sel_aw  = (block_aw == BLOCK_PKTGEN);
  wire pg_sel_ar  = (block_ar == BLOCK_PKTGEN);
  wire cmd_sel_aw = (block_aw == BLOCK_COMMAND);
  wire cmd_sel_ar = (block_ar == BLOCK_COMMAND);
  wire none_aw = ~(pg_sel_aw | cmd_sel_aw);
  wire none_ar = ~(pg_sel_ar | cmd_sel_ar);

  wire        pg_awready, pg_wready, pg_bvalid, pg_arready, pg_rvalid;
  wire [1:0]  pg_bresp, pg_rresp;
  wire [31:0] pg_rdata;

  logic        cmd_bvalid_r, cmd_rvalid_r;
  logic [31:0] cmd_rdata_r;
  logic        dec_bvalid_r, dec_rvalid_r;

  logic        cmd_bringup_restart_r;
  logic        cmd_stats_r;
  logic        cmd_rx_resync_r;
  logic        cmd_rx_dp_reset_r;
  logic        cmd_tx_dp_reset_r;
  logic [7:0]  cmd_stat_idx_r;

  wire        ctl_link_up;
  wire [2:0]  ctl_mac_fsm_state;
  wire [31:0] ctl_rx_phy_status;
  wire [31:0] ctl_stat_rd_data;
  wire [7:0]  ctl_retry_cnt;
  wire [4:0]  ctl_seq_state;
  wire [15:0] ctl_seq_pc;
  wire        ctl_link_fault, ctl_access_fault, ctl_seq_busy;
  wire        ctl_rx_status, ctl_tx_status;
  wire        ad_rx_overflow, ad_rx_trunc, ad_tx_cpl_overflow;
  wire [31:0] ad_rx_err_frames, ad_rx_drop_frames;

  assign host_awready = pg_sel_aw  ? pg_awready
                      : cmd_sel_aw ? ~cmd_bvalid_r
                      :              ~dec_bvalid_r;
  assign host_wready  = pg_sel_aw  ? pg_wready
                      : cmd_sel_aw ? ~cmd_bvalid_r
                      :              ~dec_bvalid_r;
  assign host_bvalid  = pg_sel_aw  ? pg_bvalid
                      : cmd_sel_aw ? cmd_bvalid_r
                      :              dec_bvalid_r;
  assign host_bresp   = pg_sel_aw  ? pg_bresp
                      : cmd_sel_aw ? 2'b00
                      :              2'b11;

  assign host_arready = pg_sel_ar  ? pg_arready
                      : cmd_sel_ar ? ~cmd_rvalid_r
                      :              ~dec_rvalid_r;
  assign host_rvalid  = pg_sel_ar  ? pg_rvalid
                      : cmd_sel_ar ? cmd_rvalid_r
                      :              dec_rvalid_r;
  assign host_rresp   = pg_sel_ar  ? pg_rresp
                      : cmd_sel_ar ? 2'b00
                      :              2'b11;
  assign host_rdata   = pg_sel_ar  ? pg_rdata
                      :              cmd_rdata_r;

  wire cmd_write = cmd_sel_aw && host_awvalid && host_wvalid && !cmd_bvalid_r;
  wire cmd_read  = cmd_sel_ar && host_arvalid && !cmd_rvalid_r;
  wire dec_write = none_aw     && host_awvalid && host_wvalid && !dec_bvalid_r;
  wire dec_read  = none_ar     && host_arvalid && !dec_rvalid_r;

  always_ff @(posedge usr_clk) begin
    if (!usr_rstn) begin
      cmd_bvalid_r          <= 1'b0;
      cmd_rvalid_r          <= 1'b0;
      cmd_rdata_r           <= '0;
      dec_bvalid_r          <= 1'b0;
      dec_rvalid_r          <= 1'b0;
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
          6'h00: cmd_rdata_r <= {27'd0, cmd_tx_dp_reset_r, cmd_rx_dp_reset_r, cmd_rx_resync_r,
                                 cmd_stats_r, cmd_bringup_restart_r};
          6'h01: cmd_rdata_r <= {24'd0, cmd_stat_idx_r};
          6'h02: cmd_rdata_r <= {24'd0, ctl_rx_status, ctl_tx_status, ctl_seq_busy,
                                 ctl_access_fault, ctl_link_fault, 2'd0, ctl_link_up};
          6'h03: cmd_rdata_r <= {8'd0, ctl_seq_pc, 3'd0, ctl_seq_state};
          6'h04: cmd_rdata_r <= ctl_rx_phy_status;
          6'h05: cmd_rdata_r <= {24'd0, ctl_retry_cnt};
          6'h06: cmd_rdata_r <= ctl_stat_rd_data;
          6'h07: cmd_rdata_r <= {29'd0, ctl_mac_fsm_state};
          6'h08: cmd_rdata_r <= {29'd0, ad_tx_cpl_overflow, ad_rx_trunc, ad_rx_overflow};
          6'h09: cmd_rdata_r <= ad_rx_err_frames;
          6'h0A: cmd_rdata_r <= ad_rx_drop_frames;
          default: cmd_rdata_r <= 32'd0;
        endcase
      end else if (cmd_rvalid_r && host_rready) begin
        cmd_rvalid_r <= 1'b0;
      end

      if (dec_write)                              dec_bvalid_r <= 1'b1;
      else if (dec_bvalid_r && host_bready)       dec_bvalid_r <= 1'b0;
      if (dec_read)                               dec_rvalid_r <= 1'b1;
      else if (dec_rvalid_r && host_rready)       dec_rvalid_r <= 1'b0;
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

  wire [DATA_W-1:0]   tx_tdata;
  wire [DATA_W/8-1:0] tx_tkeep;
  wire                tx_tvalid, tx_tready, tx_tlast, tx_tuser;

  wire [DATA_W-1:0]   rx_tdata;
  wire [DATA_W/8-1:0] rx_tkeep;
  wire                rx_tvalid, rx_tlast, rx_tuser;

  dcmac_axis_pktgen #(
    .DATA_W(DATA_W), .AXIL_ADDR_W(PG_AW),
    .LEN_MIN_HW(LEN_MIN_HW), .LEN_MAX_HW(LEN_MAX_HW)
  ) u_pktgen (
    .net_clk          (usr_clk),
    .net_rstn         (usr_rstn),

    .m_axis_tx_tdata  (tx_tdata),
    .m_axis_tx_tkeep  (tx_tkeep),
    .m_axis_tx_tvalid (tx_tvalid),
    .m_axis_tx_tready (tx_tready),
    .m_axis_tx_tlast  (tx_tlast),
    .m_axis_tx_tuser  (tx_tuser),

    .s_axis_rx_tdata  (rx_tdata),
    .s_axis_rx_tkeep  (rx_tkeep),
    .s_axis_rx_tvalid (rx_tvalid),
    .s_axis_rx_tlast  (rx_tlast),
    .s_axis_rx_tuser  (rx_tuser),

    .link_up          (ctl_link_up),

    .axil_aclk        (usr_clk),
    .axil_aresetn     (usr_rstn),
    .s_axil_awaddr    (host_awaddr[PG_AW-1:0]),
    .s_axil_awvalid   (pg_sel_aw & host_awvalid),
    .s_axil_awready   (pg_awready),
    .s_axil_wdata     (host_wdata),
    .s_axil_wstrb     (host_wstrb),
    .s_axil_wvalid    (pg_sel_aw & host_wvalid),
    .s_axil_wready    (pg_wready),
    .s_axil_bresp     (pg_bresp),
    .s_axil_bvalid    (pg_bvalid),
    .s_axil_bready    (pg_sel_aw & host_bready),
    .s_axil_araddr    (host_araddr[PG_AW-1:0]),
    .s_axil_arvalid   (pg_sel_ar & host_arvalid),
    .s_axil_arready   (pg_arready),
    .s_axil_rdata     (pg_rdata),
    .s_axil_rresp     (pg_rresp),
    .s_axil_rvalid    (pg_rvalid),
    .s_axil_rready    (pg_sel_ar & host_rready)
  );

  dcmac_axis_top #(
    .DATA_W        (DATA_W),
    .LOOPBACK_MODE (3'(LOOPBACK_MODE))
  ) u_seam (
    .sys_reset               (sys_reset),
    .gt_ref_clk_p            (gt_ref_clk_p),
    .gt_ref_clk_n            (gt_ref_clk_n),
    .gt_rxp_in               (gt_rxp_in),
    .gt_rxn_in               (gt_rxn_in),
    .gt_txp_out              (gt_txp_out),
    .gt_txn_out              (gt_txn_out),

    .tx_clk                  (),
    .tx_rst                  (),
    .rx_clk                  (),
    .rx_rst                  (),

    .s_axis_tx_tdata         (tx_tdata),
    .s_axis_tx_tkeep         (tx_tkeep),
    .s_axis_tx_tvalid        (tx_tvalid),
    .s_axis_tx_tready        (tx_tready),
    .s_axis_tx_tlast         (tx_tlast),
    .s_axis_tx_tuser         (tx_tuser),

    .m_axis_tx_cpl_valid     (),
    .m_axis_tx_cpl_ready     (1'b1),
    .m_axis_tx_cpl_ts        (),
    .m_axis_tx_cpl_tag       (),

    .m_axis_rx_tdata         (rx_tdata),
    .m_axis_rx_tkeep         (rx_tkeep),
    .m_axis_rx_tvalid        (rx_tvalid),
    .m_axis_rx_tlast         (rx_tlast),
    .m_axis_rx_tuser         (rx_tuser),

    .seg_ptp_time            ('0),
    .seg_clk                 (),

    .tx_status               (ctl_tx_status),
    .rx_status               (ctl_rx_status),
    .link_up                 (ctl_link_up),
    .rx_overflow             (ad_rx_overflow),
    .rx_trunc                (ad_rx_trunc),
    .rx_err_frames           (ad_rx_err_frames),
    .rx_drop_frames          (ad_rx_drop_frames),
    .tx_cpl_overflow         (ad_tx_cpl_overflow),
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

    .s_axil_awaddr           (20'd0),
    .s_axil_awvalid          (1'b0),
    .s_axil_awready          (),
    .s_axil_wdata            (32'd0),
    .s_axil_wstrb            (4'd0),
    .s_axil_wvalid           (1'b0),
    .s_axil_wready           (),
    .s_axil_bresp            (),
    .s_axil_bvalid           (),
    .s_axil_bready           (1'b0),
    .s_axil_araddr           (20'd0),
    .s_axil_arvalid          (1'b0),
    .s_axil_arready          (),
    .s_axil_rdata            (),
    .s_axil_rresp            (),
    .s_axil_rvalid           (),
    .s_axil_rready           (1'b0)
  );

  wire _unused = &{1'b0, usr_rstn, 1'b0};
endmodule
