// ---------------------------------------------------------------------------
// File        : dcmac_axis_adapter.sv
// Description : The AXI-Stream boundary of one MAC client. Carries the segment to stream
//               mapping in both directions, the receive frame FIFO, the clock crossings,
//               the transmit packet FIFO, and the loss reporting they share.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

`ifndef NIA_RX_FF_MEM_STYLE
  `ifdef DCMAC_FRAME_FIFO_BRAM
    `define NIA_RX_FF_MEM_STYLE "block"
  `else
    `define NIA_RX_FF_MEM_STYLE "distributed"
  `endif
`endif

module dcmac_axis_adapter #(

  parameter integer N_SEG      = 2,
  parameter integer SEG_W      = 128,
  parameter integer DATA_W     = 512,

  // The stream ports this client presents. One at 100G and 200G. Two at 400G, where
  // successive frames alternate between the ports: a single 1024 bit port would need
  // 654 MHz to carry the 400G frame rate, which is the reason AMD's converter also
  // splits at that rate, axis_seg_to_unseg_converter.v:71.
  parameter integer N_STREAM   = 1,

  parameter integer PTP_TS_EN  = 0,
  parameter integer PTP_TS_W   = 80,
  parameter integer TX_TAG_W   = 0,

  // The receive ring holds RX_RING_DEPTH rows of N_SEG segments. Four rows is the minimum
  // the read plan allows and it is what the wide geometries use: the row select is then a
  // four way multiplexer per lane rather than a sixteen way one, and the ring costs a
  // quarter of the flops.
  parameter integer RX_RING_DEPTH = 4,

  parameter integer RX_FIFO_AW = 9,
  parameter integer RX_CDC_AW  = 9,
  parameter integer TX_FIFO_AW = 8,
  parameter integer TX_CDC_AW  = 9,
  parameter integer TX_CPL_AW  = 4,

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

  output wire [N_STREAM*DATA_W-1:0]   m_axis_rx_tdata,
  output wire [N_STREAM*DATA_W/8-1:0] m_axis_rx_tkeep,
  output wire [N_STREAM-1:0]          m_axis_rx_tvalid,
  output wire [N_STREAM-1:0]          m_axis_rx_tlast,
  output wire [N_STREAM*RX_USER_W-1:0] m_axis_rx_tuser,

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

  input  wire                         link_up,
  input  wire                         tx_rst_seg,
  input  wire                         ctl_tx_enable,

  output wire                         rx_status,
  output wire                         tx_status,
  output wire                         rx_overflow,
  output wire                         rx_trunc,
  output wire [31:0]                  rx_err_frames,
  output wire [31:0]                  rx_drop_frames,
  output wire [31:0]                  rx_align_stat,
  output wire                         tx_cpl_overflow
);
  localparam int SEG_BITS  = N_SEG*SEG_W;
  localparam int SEG_KEEP  = SEG_BITS/8;
  localparam int NET_KEEP  = DATA_W/8;

  localparam int CPL_W     = PTP_TS_W + TX_TAG_WP;
  localparam bit TX_CPL_EN = (PTP_TS_EN != 0) || (TX_TAG_W > 0);

  (* ASYNC_REG = "TRUE" *) logic rx_algn_s0 = 1'b0, rx_algn_s1 = 1'b0;
  always_ff @(posedge seg_clk) begin
    rx_algn_s0 <= stat_rx_aligned;
    rx_algn_s1 <= rx_algn_s0;
  end
  wire stat_rx_aligned_seg = rx_algn_s1;

  wire link_up_i = link_up;

  logic rx_rst_seg;
  always_ff @(posedge seg_clk) begin
    rx_rst_seg <= ~seg_rstn | ~link_up_i | ~stat_rx_aligned_seg;
  end

  (* ASYNC_REG = "TRUE" *) logic tx_rst_s0 = 1'b1, tx_rst_s1 = 1'b1;
  // report_cdc gives CDC-10, combinational logic detected before a synchroniser, for both
  // status crossings below: link_up_i & ctl_tx_enable was an AND presented to the first
  // asynchronous flop, so the flop can capture the gate settling rather than a stable value.
  // The term is formed in the source domain first and the synchroniser takes a register.
  logic tx_sts_src = 1'b0;
  always_ff @(posedge seg_clk) begin
    if (!seg_rstn) tx_sts_src <= 1'b0;
    else           tx_sts_src <= link_up_i & ctl_tx_enable;
  end

  (* ASYNC_REG = "TRUE" *) logic tx_sts_s0 = 1'b0, tx_sts_s1 = 1'b0;
  always_ff @(posedge tx_clk) begin
    tx_rst_s0 <= tx_rst_seg;
    tx_rst_s1 <= tx_rst_s0;
    tx_sts_s0 <= tx_sts_src;
    tx_sts_s1 <= tx_sts_s0;
  end
  assign tx_rst    = tx_rst_s1;
  assign tx_status = tx_sts_s1;

  (* ASYNC_REG = "TRUE" *) logic rx_rst_s0 = 1'b1, rx_rst_s1 = 1'b1;
  (* ASYNC_REG = "TRUE" *) logic rx_sts_s0 = 1'b0, rx_sts_s1 = 1'b0;
  always_ff @(posedge rx_clk) begin
    rx_rst_s0 <= rx_rst_seg;
    rx_rst_s1 <= rx_rst_s0;
    rx_sts_s0 <= link_up_i;
    rx_sts_s1 <= rx_sts_s0;
  end
  assign rx_rst    = rx_rst_s1;
  assign rx_status = rx_sts_s1;

  wire rx_gated_valid = rx_seg_valid & link_up_i;

  // The frame parity steer. A frame's segments all carry the same parity, so each receive
  // stream sees whole frames and needs to know nothing about the other. The parity toggles
  // at every start of packet, so frame 0 goes to stream 0. At N_STREAM 1 the steer is a
  // constant and synthesis removes it.
  logic [N_SEG-1:0] str_par;
  logic             frame_par_q;
  logic             frame_par_d;

  always_comb begin
    logic p;
    p = frame_par_q;
    for (int s = 0; s < N_SEG; s++) begin
      if (rx_gated_valid && rx_seg_ena[s] && rx_seg_sop[s]) p = ~p;
      str_par[s] = p;
    end
    frame_par_d = p;
  end

  always_ff @(posedge seg_clk) begin
    if (!seg_rstn) frame_par_q <= 1'b1;
    else           frame_par_q <= frame_par_d;
  end

  wire [N_STREAM-1:0] str_overflow;
  wire [N_STREAM-1:0] str_trunc;
  wire [32*N_STREAM-1:0] str_err_frames;
  wire [32*N_STREAM-1:0] str_drop_frames;
  wire [32*N_STREAM-1:0] str_align_stat;

  genvar g;
  generate
  for (g = 0; g < N_STREAM; g++) begin : g_rx_stream
    wire [N_SEG-1:0] ena_g;
    if (N_STREAM > 1) begin : g_steer
      assign ena_g = rx_seg_ena & (g[0] ? str_par : ~str_par);
    end else begin : g_no_steer
      assign ena_g = rx_seg_ena;
    end

    dcmac_axis_rx_stream #(
      .N_SEG(N_SEG), .SEG_W(SEG_W), .DATA_W(DATA_W),
      .PTP_TS_W(PTP_TS_W), .RX_USER_W(RX_USER_W),
      .RX_RING_DEPTH(RX_RING_DEPTH), .RX_FIFO_AW(RX_FIFO_AW), .RX_CDC_AW(RX_CDC_AW)
    ) u_rx_stream (
      .seg_clk          (seg_clk),
      .seg_rstn         (seg_rstn),
      .rx_clk           (rx_clk),
      .rx_rstn          (rx_rstn),
      .link_up          (link_up_i),
      .rx_seg_valid     (rx_gated_valid),
      .rx_seg_dat       (rx_seg_dat),
      .rx_seg_ena       (ena_g),
      .rx_seg_sop       (rx_seg_sop),
      .rx_seg_eop       (rx_seg_eop),
      .rx_seg_err       (rx_seg_err),
      .rx_seg_mty       (rx_seg_mty),
      .seg_ptp_time     (seg_ptp_time),
      .m_axis_rx_tdata  (m_axis_rx_tdata[g*DATA_W +: DATA_W]),
      .m_axis_rx_tkeep  (m_axis_rx_tkeep[g*(DATA_W/8) +: DATA_W/8]),
      .m_axis_rx_tvalid (m_axis_rx_tvalid[g]),
      .m_axis_rx_tlast  (m_axis_rx_tlast[g]),
      .m_axis_rx_tuser  (m_axis_rx_tuser[g*RX_USER_W +: RX_USER_W]),
      .rx_overflow      (str_overflow[g]),
      .rx_trunc         (str_trunc[g]),
      .rx_err_frames    (str_err_frames[g*32 +: 32]),
      .rx_drop_frames   (str_drop_frames[g*32 +: 32]),
      .rx_align_stat    (str_align_stat[g*32 +: 32])
    );
  end
  endgenerate

  // The status a client publishes is the whole client's, so a two stream client reports the
  // sum of its streams' frame counters and the union of their loss flags. rx_align_stat
  // carries an abort count and a drop count in its two halves and each half is summed.
  assign rx_overflow = |str_overflow;
  assign rx_trunc    = |str_trunc;
  generate
  if (N_STREAM > 1) begin : g_stat_sum
    logic [31:0] err_sum, drop_sum;
    logic [15:0] abort_sum, algn_sum;
    always_comb begin
      err_sum   = '0;
      drop_sum  = '0;
      abort_sum = '0;
      algn_sum  = '0;
      for (int k = 0; k < N_STREAM; k++) begin
        err_sum   = err_sum   + str_err_frames[k*32 +: 32];
        drop_sum  = drop_sum  + str_drop_frames[k*32 +: 32];
        algn_sum  = algn_sum  + str_align_stat[k*32 +: 16];
        abort_sum = abort_sum + str_align_stat[k*32 + 16 +: 16];
      end
    end
    assign rx_err_frames  = err_sum;
    assign rx_drop_frames = drop_sum;
    assign rx_align_stat  = {abort_sum, algn_sum};
  end else begin : g_stat_one
    assign rx_err_frames  = str_err_frames[31:0];
    assign rx_drop_frames = str_drop_frames[31:0];
    assign rx_align_stat  = str_align_stat[31:0];
  end
  endgenerate

  logic [DATA_W-1:0]    txf_tdata;
  logic [NET_KEEP-1:0]  txf_tkeep;
  logic                 txf_tvalid, txf_tready, txf_tlast;
  logic [TX_USER_W-1:0] txf_tuser;

  eth_axis_async_fifo #(
    .DATA_W(DATA_W), .KEEP_W(NET_KEEP), .USER_W(TX_USER_W), .ADDR_W(TX_CDC_AW),
    .DROP_ON_FULL(1'b0)
  ) u_tx_cdc (
    .s_clk         (tx_clk),
    .s_rstn        (tx_rstn),
    .s_axis_tdata  (s_axis_tx_tdata),
    .s_axis_tkeep  (s_axis_tx_tkeep),
    .s_axis_tvalid (s_axis_tx_tvalid),
    .s_axis_tready (s_axis_tx_tready),
    .s_axis_tlast  (s_axis_tx_tlast),
    .s_axis_tuser  (s_axis_tx_tuser),
    .m_clk         (seg_clk),
    .m_rstn        (seg_rstn),
    .m_axis_tdata  (txf_tdata),
    .m_axis_tkeep  (txf_tkeep),
    .m_axis_tvalid (txf_tvalid),
    .m_axis_tready (txf_tready),
    .m_axis_tlast  (txf_tlast),
    .m_axis_tuser  (txf_tuser),
    .overflow      ()
  );

  logic [DATA_W-1:0]    txp_tdata;
  logic [NET_KEEP-1:0]  txp_tkeep;
  logic                 txp_tvalid, txp_tready, txp_tlast;
  logic [TX_USER_W-1:0] txp_tuser;

  tx_frame_fifo #(
    .DATA_W(DATA_W), .KEEP_W(NET_KEEP), .USER_W(TX_USER_W), .ADDR_W(TX_FIFO_AW)
  ) u_tx_frame_fifo (
    .clk           (seg_clk),
    .rstn          (seg_rstn),
    .s_axis_tdata  (txf_tdata),
    .s_axis_tkeep  (txf_tkeep),
    .s_axis_tvalid (txf_tvalid),
    .s_axis_tready (txf_tready),
    .s_axis_tlast  (txf_tlast),
    .s_axis_tuser  (txf_tuser),
    .m_axis_tdata  (txp_tdata),
    .m_axis_tkeep  (txp_tkeep),
    .m_axis_tvalid (txp_tvalid),
    .m_axis_tready (txp_tready),
    .m_axis_tlast  (txp_tlast),
    .m_axis_tuser  (txp_tuser)
  );

  logic                 tx_in_frame;
  logic [DATA_W-1:0]    txg_tdata;
  logic [NET_KEEP-1:0]  txg_tkeep;
  logic                 txg_tvalid, txg_tready, txg_tlast;
  logic [TX_USER_W-1:0] txg_tuser;

  always_ff @(posedge seg_clk) begin
    if (!seg_rstn)                     tx_in_frame <= 1'b0;
    else if (txg_tvalid && txg_tready) tx_in_frame <= ~txg_tlast;
  end

  wire tx_gate = ctl_tx_enable | tx_in_frame;
  assign txg_tdata  = txp_tdata;
  assign txg_tkeep  = txp_tkeep;
  assign txg_tlast  = txp_tlast;
  assign txg_tuser  = txp_tuser;
  assign txg_tvalid = txp_tvalid & tx_gate;
  assign txp_tready = txg_tready & tx_gate;

  // The packer takes the host bus width directly. Cutting the stream to N_SEG*SEG_W first
  // quantised a frame to whole segmented cycles, which with one start of packet per cycle
  // held 65 byte frames at 200G to 0.696 of line rate. The receive direction carried the
  // same fault through eth_axis_dwidth_up and it is removed there for the same reason.
  dcmac_seg_axis_tx #(.N_SEG(N_SEG), .SEG_W(SEG_W), .DATA_W(DATA_W)) u_seg_tx (
    .clk           (seg_clk),
    .rstn          (seg_rstn),
    .s_axis_tdata  (txg_tdata),
    .s_axis_tkeep  (txg_tkeep),
    .s_axis_tvalid (txg_tvalid),
    .s_axis_tready (txg_tready),
    .s_axis_tlast  (txg_tlast),
    .s_axis_tuser  (txg_tuser[0]),
    .tx_seg_ready  (tx_seg_ready),
    .tx_seg_valid  (tx_seg_valid),
    .tx_seg_dat    (tx_seg_dat),
    .tx_seg_ena    (tx_seg_ena),
    .tx_seg_sop    (tx_seg_sop),
    .tx_seg_eop    (tx_seg_eop),
    .tx_seg_err    (tx_seg_err),
    .tx_seg_mty    (tx_seg_mty)
  );

  generate
  if (TX_CPL_EN) begin : g_tx_cpl
    wire tx_eop_accepted = txg_tvalid & txg_tready & txg_tlast;

    wire [PTP_TS_W-1:0]  cpl_ts_in  = seg_ptp_time;

    wire [TX_TAG_WP-1:0] cpl_tag_in;
    if (TX_TAG_W > 0) begin : g_tag
      assign cpl_tag_in = txg_tuser[TX_TAG_W:1];
    end else begin : g_no_tag
      assign cpl_tag_in = {TX_TAG_WP{1'b0}};
    end

    wire [CPL_W-1:0] cpl_word;
    assign cpl_word = {cpl_ts_in, cpl_tag_in};

    wire [CPL_W-1:0] cpl_word_out;

    eth_axis_async_fifo #(
      .DATA_W(CPL_W), .KEEP_W(1), .USER_W(1), .ADDR_W(TX_CPL_AW), .DROP_ON_FULL(1'b0)
    ) u_tx_cpl_cdc (
      .s_clk         (seg_clk),
      .s_rstn        (seg_rstn),
      .s_axis_tdata  (cpl_word),
      .s_axis_tkeep  (1'b1),
      .s_axis_tvalid (tx_eop_accepted),
      .s_axis_tready (),
      .s_axis_tlast  (1'b1),
      .s_axis_tuser  (1'b0),
      .m_clk         (tx_clk),
      .m_rstn        (tx_rstn),
      .m_axis_tdata  (cpl_word_out),
      .m_axis_tkeep  (),
      .m_axis_tvalid (m_axis_tx_cpl_valid),
      .m_axis_tready (m_axis_tx_cpl_ready),
      .m_axis_tlast  (),
      .m_axis_tuser  (),
      .overflow      (tx_cpl_overflow)
    );

    assign m_axis_tx_cpl_tag = cpl_word_out[TX_TAG_WP-1:0];
    assign m_axis_tx_cpl_ts  = cpl_word_out[CPL_W-1:TX_TAG_WP];
  end else begin : g_no_tx_cpl
    assign m_axis_tx_cpl_valid = 1'b0;
    assign m_axis_tx_cpl_tag   = {TX_TAG_WP{1'b0}};
    assign m_axis_tx_cpl_ts    = {PTP_TS_W{1'b0}};
    assign tx_cpl_overflow     = 1'b0;
  end
  endgenerate
endmodule
