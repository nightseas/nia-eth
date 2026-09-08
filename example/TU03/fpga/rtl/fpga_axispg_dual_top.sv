// ---------------------------------------------------------------------------
// File        : fpga_axispg_dual_top.sv
// Description : The board independent body of the two cage AXI-Stream image: the aperture
//               decode, the two generators behind their adapters, the control plane, and
//               the command block that publishes the adapter status.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module fpga_axispg_dual_top #(

  parameter integer RATE          = 100,
  // The electrical lane count of one client. It is fixed by the rate everywhere except at
  // 200G, where a port is either 200GAUI-2, two lanes of 106.25 Gb/s on one quad a cage, or
  // 200GAUI-4, four lanes of 53.125 Gb/s on the two quads of a cage.
  parameter integer GAUI          = 2,
  parameter integer DATA_W        = 512,
  parameter integer LOOPBACK_MODE = 0,
  parameter integer HOST_ADDR_W   = 16,
  parameter integer PG_AW         = 12,
  parameter integer LEN_MIN_HW    = 64,
  parameter integer LEN_MAX_HW    = 9018,
  // The host stream clock in MHz. The link control counts milliseconds in this clock, so the
  // two shall move together. 250 is what every rate has shipped with, 391 is the segment
  // clock's own frequency and is what AMD's converter runs its stream side at.
  parameter integer USR_MHZ       = 250,

  parameter integer GT_LANES      = 8
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

  output wire                    usr_clk,
  output wire                    usr_rstn,

  output wire [1:0]              link_up,
  output wire [5:0]              mac_fsm_state,

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

  localparam int N_CLIENT   = (RATE == 400) ? 1 : 2;
  // Stream ports per client. Two at 400G, where successive frames alternate between them,
  // because one 1024 bit port carries 400.4 Gb/s of beats against a frame rate that needs
  // 653.6 M beats/s at 129 bytes. N_PG is therefore 2 at every rate and the register
  // aperture is the same at every rate.
  localparam int N_STREAM   = (RATE == 400) ? 2 : 1;
  localparam int N_PG       = N_CLIENT * N_STREAM;
  localparam int N_SEG      = (RATE == 400) ? 8 : ((RATE == 200) ? 4 : 2);
  localparam int NPORTS     = (RATE == 400) ? 4 : ((RATE == 200) ? 2 : 1);
  localparam int ANCHOR_1   = (RATE == 200) ? 2 : 1;
  // The mask names the pattern a PHY wrapper drives, which is one bit per data lane of a client
  // replicated over the eight bit quad field, and dcmac_ctl_seq compares it for equality. A
  // 200GAUI-4 client carries four lanes and its wrapper drives 8'h0F, the same as 200GAUI-2, so
  // both take DONEMASK_200G. A 400GAUI-4 client drives 8'h03 and takes DONEMASK_100G.
  localparam logic [7:0] DONE_MASK  = (RATE == 200) ? dcmac_ctl_pkg::DONEMASK_200G
                                                    : dcmac_ctl_pkg::DONEMASK_100G;
  localparam int RATE_CODE  = (RATE == 400) ? dcmac_ctl_pkg::RATE_CODE_400G
                            : ((RATE == 200) ? dcmac_ctl_pkg::RATE_CODE_200G
                                             : dcmac_ctl_pkg::RATE_CODE_100G);
  localparam int RATE_FIELD = (RATE == 400) ? dcmac_ctl_pkg::RATE_FIELD_400G
                            : ((RATE == 200) ? dcmac_ctl_pkg::RATE_FIELD_200G
                                             : dcmac_ctl_pkg::RATE_FIELD_100G);
  localparam logic [7:0] POLARITY_TX_Q0 = (RATE == 100) ? dcmac_ctl_pkg::QSFP0_TXPOLARITY : 8'b0000_1100;
  localparam logic [7:0] POLARITY_RX_Q0 = (RATE == 100) ? dcmac_ctl_pkg::QSFP0_RXPOLARITY : 8'b0000_0000;
  localparam logic [7:0] POLARITY_TX_Q1 = (RATE == 100) ? dcmac_ctl_pkg::QSFP1_TXPOLARITY : 8'b0000_0011;
  localparam logic [7:0] POLARITY_RX_Q1 = (RATE == 400) ? 8'b0000_1111
                            : ((RATE == 200) ? 8'b0000_0011 : dcmac_ctl_pkg::QSFP1_RXPOLARITY);
  localparam logic [7:0] POLARITY_TX_Q2 = 8'b0000_0000;
  localparam logic [7:0] POLARITY_RX_Q2 = 8'b0000_0000;
  localparam logic [7:0] POLARITY_TX_Q3 = 8'b0000_0000;
  localparam logic [7:0] POLARITY_RX_Q3 = 8'b0000_0000;
  localparam int BLOCK    = HOST_ADDR_W - PG_AW;
  localparam logic [BLOCK-1:0] BLOCK_PKTGEN_0 = 'h0;
  localparam logic [BLOCK-1:0] BLOCK_COMMAND  = 'h1;
  localparam logic [BLOCK-1:0] BLOCK_PKTGEN_1 = 'h2;

  // usr_clk is the register plane at 250 MHz: the host bridge, the AXI-Lite fabric, the
  // control plane and the DCMAC's own s_axi, whose APB3_CLK requires 3.333 ns. net_clk is the
  // datapath at USR_MHZ, 250 or 391, and it is the only clock the rate changes.
  wire usr_clk_i, usr_rstn_i;
  wire net_clk_i;
  logic [2:0] net_rstn_sr = 3'b000;
  always_ff @(posedge net_clk_i) net_rstn_sr <= {net_rstn_sr[1:0], usr_rstn_i};
  wire net_rstn_i = net_rstn_sr[2];
  localparam bit PG_SAME_CLOCK = (USR_MHZ == 250);
  assign usr_clk  = usr_clk_i;
  assign usr_rstn = usr_rstn_i;

  wire [BLOCK-1:0] block_aw = s_axil_awaddr[HOST_ADDR_W-1:PG_AW];
  wire [BLOCK-1:0] block_ar = s_axil_araddr[HOST_ADDR_W-1:PG_AW];

  wire [N_PG-1:0] pg_sel_aw = {block_aw == BLOCK_PKTGEN_1, block_aw == BLOCK_PKTGEN_0};
  wire [N_PG-1:0] pg_sel_ar = {block_ar == BLOCK_PKTGEN_1, block_ar == BLOCK_PKTGEN_0};
  wire       cmd_sel_aw = (block_aw == BLOCK_COMMAND);
  wire       cmd_sel_ar = (block_ar == BLOCK_COMMAND);

  wire       pg_hit_aw = |pg_sel_aw;
  wire       pg_hit_ar = |pg_sel_ar;
  wire       none_aw   = ~(pg_hit_aw | cmd_sel_aw);
  wire       none_ar   = ~(pg_hit_ar | cmd_sel_ar);

  wire [N_PG-1:0]    pg_awready, pg_wready, pg_bvalid, pg_arready, pg_rvalid;
  wire [2*N_PG-1:0]  pg_bresp, pg_rresp;
  wire [32*N_PG-1:0] pg_rdata;

  logic        cmd_bvalid_r, cmd_rvalid_r;
  logic [31:0] cmd_rdata_r;
  logic        dec_bvalid_r, dec_rvalid_r;

  logic        cmd_bringup_restart_r;
  logic        cmd_stats_r;
  logic [1:0]  cmd_rx_resync_r;
  logic [1:0]  cmd_rx_dp_reset_r;
  logic [1:0]  cmd_tx_dp_reset_r;
  logic [7:0]  cmd_stat_idx_r;

  wire [1:0]  ctl_rx_pcs_aligned;
  wire [31:0] ctl_rx_phy_status;
  wire [31:0] ctl_stat_rd_data;
  wire [7:0]  ctl_retry_cnt;
  wire [4:0]  ctl_seq_state;
  wire [15:0] ctl_seq_pc;
  wire        ctl_link_fault, ctl_access_fault, ctl_seq_busy;
  wire [1:0]  ctl_rx_status, ctl_tx_status;
  wire [1:0]  ad_rx_overflow, ad_rx_trunc, ad_tx_cpl_overflow;
  wire [63:0] ad_rx_err_frames, ad_rx_drop_frames, ad_rx_align_stat;

  // report_cdc gives CDC-15, clock enable controlled CDC structure detected, 37 times, for
  // this status: the adapter counts on the segment clock and the command block reads the
  // counters on the register plane with nothing but a read enable between them, so a read
  // that lands while a counter is carrying returns a mixture of two values. The whole set
  // crosses through one dcmac_csr_snap, whose handshake holds the vector still for the
  // crossing, which is the arrangement dcmac_axis_csr already uses for seg_vec.
  // The seam exports the segment clock and no reset for it, so the reset of the register
  // plane is synchronised into that domain for the source side of the snap below. Two flops
  // are what dcmac_sync2 provides and what the source side needs to leave its handshake idle.
  wire seg_clk_i;
  wire seg_rstn_i;
  dcmac_sync2 #(.WIDTH(1), .STAGES(2), .INIT(1'b0)) u_seg_rstn_sync (
    .clk  (seg_clk_i),
    .din  (usr_rstn_i),
    .dout (seg_rstn_i)
  );

  localparam int AD_STS_W = 2 + 2 + 2 + 64 + 64 + 64;
  wire [AD_STS_W-1:0] ad_sts_seg = { ad_rx_align_stat, ad_rx_drop_frames, ad_rx_err_frames,
                                     ad_tx_cpl_overflow, ad_rx_trunc, ad_rx_overflow };
  wire [AD_STS_W-1:0] ad_sts_usr;
  dcmac_csr_snap #(.WIDTH(AD_STS_W), .SAME_CLOCK(1'b0)) u_ad_sts_snap (
    .s_clk  (seg_clk_i),
    .s_rstn (seg_rstn_i),
    .m_clk  (usr_clk_i),
    .m_rstn (usr_rstn_i),
    .din    (ad_sts_seg),
    .dout   (ad_sts_usr),
    .rounds ()
  );
  wire [1:0]  sad_rx_overflow     = ad_sts_usr[1:0];
  wire [1:0]  sad_rx_trunc        = ad_sts_usr[3:2];
  wire [1:0]  sad_tx_cpl_overflow = ad_sts_usr[5:4];
  wire [63:0] sad_rx_err_frames   = ad_sts_usr[69:6];
  wire [63:0] sad_rx_drop_frames  = ad_sts_usr[133:70];
  wire [63:0] sad_rx_align_stat   = ad_sts_usr[197:134];

  assign s_axil_awready = pg_hit_aw  ? |(pg_awready & pg_sel_aw)
                        : cmd_sel_aw ? ~cmd_bvalid_r
                        :              ~dec_bvalid_r;
  assign s_axil_wready  = pg_hit_aw  ? |(pg_wready  & pg_sel_aw)
                        : cmd_sel_aw ? ~cmd_bvalid_r
                        :              ~dec_bvalid_r;
  assign s_axil_bvalid  = pg_hit_aw  ? |(pg_bvalid  & pg_sel_aw)
                        : cmd_sel_aw ? cmd_bvalid_r
                        :              dec_bvalid_r;
  assign s_axil_bresp   = none_aw ? 2'b11 : 2'b00;

  assign s_axil_arready = pg_hit_ar  ? |(pg_arready & pg_sel_ar)
                        : cmd_sel_ar ? ~cmd_rvalid_r
                        :              ~dec_rvalid_r;
  assign s_axil_rvalid  = pg_hit_ar  ? |(pg_rvalid  & pg_sel_ar)
                        : cmd_sel_ar ? cmd_rvalid_r
                        :              dec_rvalid_r;
  assign s_axil_rresp   = none_ar ? 2'b11 : 2'b00;
  assign s_axil_rdata   = pg_sel_ar[0] ? pg_rdata[31:0]
                        : pg_sel_ar[1] ? pg_rdata[63:32]
                        :                cmd_rdata_r;

  wire cmd_write = cmd_sel_aw && s_axil_awvalid && s_axil_wvalid && !cmd_bvalid_r;
  wire cmd_read  = cmd_sel_ar && s_axil_arvalid && !cmd_rvalid_r;
  wire dec_write = none_aw    && s_axil_awvalid && s_axil_wvalid && !dec_bvalid_r;
  wire dec_read  = none_ar    && s_axil_arvalid && !dec_rvalid_r;

  always_ff @(posedge usr_clk_i) begin
    if (!usr_rstn_i) begin
      cmd_bvalid_r          <= 1'b0;
      cmd_rvalid_r          <= 1'b0;
      cmd_rdata_r           <= '0;
      dec_bvalid_r          <= 1'b0;
      dec_rvalid_r          <= 1'b0;
      cmd_bringup_restart_r <= 1'b0;
      cmd_stats_r           <= 1'b0;
      cmd_rx_resync_r       <= '0;
      cmd_rx_dp_reset_r     <= '0;
      cmd_tx_dp_reset_r     <= '0;
      cmd_stat_idx_r        <= '0;
    end else begin
      if (cmd_write) begin
        cmd_bvalid_r <= 1'b1;
        case (s_axil_awaddr[7:2])
          6'h00: begin
            cmd_bringup_restart_r <= s_axil_wdata[0];
            cmd_stats_r           <= s_axil_wdata[1];
            cmd_rx_resync_r[0]    <= s_axil_wdata[2];
            cmd_rx_dp_reset_r[0]  <= s_axil_wdata[3];
            cmd_tx_dp_reset_r[0]  <= s_axil_wdata[4];
            cmd_rx_resync_r[1]    <= s_axil_wdata[5];
            cmd_rx_dp_reset_r[1]  <= s_axil_wdata[6];
            cmd_tx_dp_reset_r[1]  <= s_axil_wdata[7];
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
          6'h00: cmd_rdata_r <= {24'd0, cmd_tx_dp_reset_r[1], cmd_rx_dp_reset_r[1],
                                 cmd_rx_resync_r[1], cmd_tx_dp_reset_r[0], cmd_rx_dp_reset_r[0],
                                 cmd_rx_resync_r[0], cmd_stats_r, cmd_bringup_restart_r};
          6'h01: cmd_rdata_r <= {24'd0, cmd_stat_idx_r};
          6'h02: cmd_rdata_r <= {23'd0, ctl_rx_pcs_aligned, ctl_seq_busy, ctl_access_fault,
                                 ctl_link_fault, link_up};
          6'h03: cmd_rdata_r <= {8'd0, ctl_seq_pc, 3'd0, ctl_seq_state};
          6'h04: cmd_rdata_r <= ctl_rx_phy_status;
          6'h05: cmd_rdata_r <= {24'd0, ctl_retry_cnt};
          6'h06: cmd_rdata_r <= ctl_stat_rd_data;
          6'h07: cmd_rdata_r <= {26'd0, mac_fsm_state};
          6'h08: cmd_rdata_r <= {26'd0, sad_tx_cpl_overflow, sad_rx_trunc, sad_rx_overflow};
          6'h09: cmd_rdata_r <= sad_rx_err_frames[31:0];
          6'h0A: cmd_rdata_r <= sad_rx_drop_frames[31:0];
          6'h0B: cmd_rdata_r <= sad_rx_err_frames[63:32];
          6'h0C: cmd_rdata_r <= sad_rx_drop_frames[63:32];
          6'h0D: cmd_rdata_r <= {28'd0, ctl_rx_status, ctl_tx_status};
          6'h0E: cmd_rdata_r <= sad_rx_align_stat[31:0];
          6'h0F: cmd_rdata_r <= sad_rx_align_stat[63:32];
          default: cmd_rdata_r <= 32'd0;
        endcase
      end else if (cmd_rvalid_r && s_axil_rready) begin
        cmd_rvalid_r <= 1'b0;
      end

      if (dec_write)                          dec_bvalid_r <= 1'b1;
      else if (dec_bvalid_r && s_axil_bready) dec_bvalid_r <= 1'b0;
      if (dec_read)                           dec_rvalid_r <= 1'b1;
      else if (dec_rvalid_r && s_axil_rready) dec_rvalid_r <= 1'b0;
    end
  end

  wire [N_CLIENT*DATA_W-1:0]   tx_tdata;
  wire [N_CLIENT*DATA_W/8-1:0] tx_tkeep;
  wire [N_CLIENT-1:0]          tx_tvalid, tx_tready, tx_tlast, tx_tuser;

  wire [N_PG*DATA_W-1:0]       pg_tx_tdata;
  wire [N_PG*DATA_W/8-1:0]     pg_tx_tkeep;
  wire [N_PG-1:0]              pg_tx_tvalid, pg_tx_tready, pg_tx_tlast, pg_tx_tuser;

  wire [N_PG*DATA_W-1:0]       rx_tdata;
  wire [N_PG*DATA_W/8-1:0]     rx_tkeep;
  wire [N_PG-1:0]              rx_tvalid, rx_tlast, rx_tuser;

  // Generator g serves client g / N_STREAM on stream g % N_STREAM. Only the first stream of
  // a client carries transmit: one frame per segmented cycle is 390.930 M frames/s, which
  // is the whole line rate at and above 104 bytes, so a second transmit stream buys
  // nothing. The other generator's source is left unenabled and its checker is the one
  // that reads the second receive port.
  genvar q;
  generate
  for (q = 0; q < N_PG; q++) begin : g_pktgen
    localparam int PG_CLIENT = q / N_STREAM;
    dcmac_axis_pktgen #(
      .DATA_W(DATA_W), .AXIL_ADDR_W(PG_AW), .SAME_CLOCK(PG_SAME_CLOCK),
      .LEN_MIN_HW(LEN_MIN_HW), .LEN_MAX_HW(LEN_MAX_HW)
    ) u_pktgen (
      .net_clk          (net_clk_i),
      .net_rstn         (net_rstn_i),

      .m_axis_tx_tdata  (pg_tx_tdata[q*DATA_W +: DATA_W]),
      .m_axis_tx_tkeep  (pg_tx_tkeep[q*(DATA_W/8) +: DATA_W/8]),
      .m_axis_tx_tvalid (pg_tx_tvalid[q]),
      .m_axis_tx_tready (pg_tx_tready[q]),
      .m_axis_tx_tlast  (pg_tx_tlast[q]),
      .m_axis_tx_tuser  (pg_tx_tuser[q]),

      .s_axis_rx_tdata  (rx_tdata[q*DATA_W +: DATA_W]),
      .s_axis_rx_tkeep  (rx_tkeep[q*(DATA_W/8) +: DATA_W/8]),
      .s_axis_rx_tvalid (rx_tvalid[q]),
      .s_axis_rx_tlast  (rx_tlast[q]),
      .s_axis_rx_tuser  (rx_tuser[q]),

      .link_up          (link_up[PG_CLIENT]),

      .axil_aclk        (usr_clk_i),
      .axil_aresetn     (usr_rstn_i),
      .s_axil_awaddr    (s_axil_awaddr[PG_AW-1:0]),
      .s_axil_awvalid   (pg_sel_aw[q] & s_axil_awvalid),
      .s_axil_awready   (pg_awready[q]),
      .s_axil_wdata     (s_axil_wdata),
      .s_axil_wstrb     (s_axil_wstrb),
      .s_axil_wvalid    (pg_sel_aw[q] & s_axil_wvalid),
      .s_axil_wready    (pg_wready[q]),
      .s_axil_bresp     (pg_bresp[q*2 +: 2]),
      .s_axil_bvalid    (pg_bvalid[q]),
      .s_axil_bready    (pg_sel_aw[q] & s_axil_bready),
      .s_axil_araddr    (s_axil_araddr[PG_AW-1:0]),
      .s_axil_arvalid   (pg_sel_ar[q] & s_axil_arvalid),
      .s_axil_arready   (pg_arready[q]),
      .s_axil_rdata     (pg_rdata[q*32 +: 32]),
      .s_axil_rresp     (pg_rresp[q*2 +: 2]),
      .s_axil_rvalid    (pg_rvalid[q]),
      .s_axil_rready    (pg_sel_ar[q] & s_axil_rready)
    );
  end
  endgenerate

  generate
  for (q = 0; q < N_CLIENT; q++) begin : g_tx_bind
    assign tx_tdata [q*DATA_W       +: DATA_W]   = pg_tx_tdata [q*N_STREAM*DATA_W       +: DATA_W];
    assign tx_tkeep [q*(DATA_W/8)   +: DATA_W/8] = pg_tx_tkeep [q*N_STREAM*(DATA_W/8)   +: DATA_W/8];
    assign tx_tvalid[q]                          = pg_tx_tvalid[q*N_STREAM];
    assign tx_tlast [q]                          = pg_tx_tlast [q*N_STREAM];
    assign tx_tuser [q]                          = pg_tx_tuser [q*N_STREAM];
  end
  for (q = 0; q < N_PG; q++) begin : g_tx_ready
    // A generator that owns no transmit stream is held ready so its source never stalls a
    // register access; it is left unenabled and contributes no traffic.
    assign pg_tx_tready[q] = ((q % N_STREAM) == 0) ? tx_tready[q / N_STREAM] : 1'b1;
  end
  endgenerate

  dcmac_axis_dual_top #(
    .CTL_CYC_PER_MS (250000),
    .N_CLIENT      (N_CLIENT),
    .N_STREAM      (N_STREAM),
    .N_SEG         (N_SEG),
    .NPORTS        (NPORTS),
    .ANCHOR_1      (ANCHOR_1),
    .DONE_MASK     (DONE_MASK),
    .RATE_CODE     (RATE_CODE),
    .RATE_FIELD    (RATE_FIELD),
    .POLARITY_TX_Q0(POLARITY_TX_Q0),
    .POLARITY_RX_Q0(POLARITY_RX_Q0),
    .POLARITY_TX_Q1(POLARITY_TX_Q1),
    .POLARITY_RX_Q1(POLARITY_RX_Q1),
    .POLARITY_TX_Q2(POLARITY_TX_Q2),
    .POLARITY_RX_Q2(POLARITY_RX_Q2),
    .POLARITY_TX_Q3(POLARITY_TX_Q3),
    .POLARITY_RX_Q3(POLARITY_RX_Q3),
    .GT_LANES      (GT_LANES),
    .DATA_W        (DATA_W),
    .LOOPBACK_MODE (3'(LOOPBACK_MODE))
  ) u_seam (
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
    .usr_clk                 (usr_clk_i),
    .net_clk                 (net_clk_i),
    .usr_rstn                (usr_rstn_i),

    .s_axis_tx_tdata         (tx_tdata),
    .s_axis_tx_tkeep         (tx_tkeep),
    .s_axis_tx_tvalid        (tx_tvalid),
    .s_axis_tx_tready        (tx_tready),
    .s_axis_tx_tlast         (tx_tlast),
    .s_axis_tx_tuser         (tx_tuser),

    .m_axis_tx_cpl_valid     (),
    .m_axis_tx_cpl_ready     ({N_CLIENT{1'b1}}),
    .m_axis_tx_cpl_ts        (),
    .m_axis_tx_cpl_tag       (),

    .m_axis_rx_tdata         (rx_tdata),
    .m_axis_rx_tkeep         (rx_tkeep),
    .m_axis_rx_tvalid        (rx_tvalid),
    .m_axis_rx_tlast         (rx_tlast),
    .m_axis_rx_tuser         (rx_tuser),

    .seg_ptp_time            ('0),

    .tx_status               (ctl_tx_status),
    .rx_status               (ctl_rx_status),
    .link_up                 (link_up),
    .mac_fsm_state           (mac_fsm_state),
    .rx_overflow             (ad_rx_overflow),
    .rx_trunc                (ad_rx_trunc),
    .rx_err_frames           (ad_rx_err_frames),
    .rx_align_stat           (ad_rx_align_stat),
    .rx_drop_frames          (ad_rx_drop_frames),
    .tx_cpl_overflow         (ad_tx_cpl_overflow),

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
    .ctl_rx_pcs_aligned        (ctl_rx_pcs_aligned)
  );

endmodule
