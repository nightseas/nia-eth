// ---------------------------------------------------------------------------
// File        : dcmac_axis_rx_stream.sv
// Description : One receive stream of a MAC client: the segment to stream mapping, the
//               width converter, the frame FIFO, the clock crossing, and the loss and
//               error accounting they share. A client carries one of these at 100G and
//               200G and two at 400G, where frames alternate between the two stream ports.
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

module dcmac_axis_rx_stream #(

  parameter integer N_SEG         = 2,
  parameter integer SEG_W         = 128,
  parameter integer DATA_W        = 512,

  parameter integer PTP_TS_W      = 80,
  parameter integer RX_USER_W     = 1,

  parameter integer RX_RING_DEPTH = 4,
  parameter integer RX_FIFO_AW    = 9,
  parameter integer RX_CDC_AW     = 9
)(

  input  wire                         seg_clk,
  input  wire                         seg_rstn,

  input  wire                         rx_clk,
  input  wire                         rx_rstn,

  input  wire                         link_up,

  input  wire                         rx_seg_valid,
  input  wire [N_SEG*SEG_W-1:0]       rx_seg_dat,
  input  wire [N_SEG-1:0]             rx_seg_ena,
  input  wire [N_SEG-1:0]             rx_seg_sop,
  input  wire [N_SEG-1:0]             rx_seg_eop,
  input  wire [N_SEG-1:0]             rx_seg_err,
  input  wire [N_SEG*4-1:0]           rx_seg_mty,

  input  wire [PTP_TS_W-1:0]          seg_ptp_time,

  output wire [DATA_W-1:0]            m_axis_rx_tdata,
  output wire [DATA_W/8-1:0]          m_axis_rx_tkeep,
  output wire                         m_axis_rx_tvalid,
  output wire                         m_axis_rx_tlast,
  output wire [RX_USER_W-1:0]         m_axis_rx_tuser,

  output wire                         rx_overflow,
  output wire                         rx_trunc,
  output wire [31:0]                  rx_err_frames,
  output wire [31:0]                  rx_drop_frames,
  output wire [31:0]                  rx_align_stat
);
  localparam int NET_KEEP = DATA_W/8;

  logic [DATA_W-1:0]   rxa_tdata;
  logic [NET_KEEP-1:0] rxa_tkeep;
  logic                rxa_tvalid, rxa_tready, rxa_tlast, rxa_tuser;
  logic                rx_align_drop;

  dcmac_seg_axis_rx #(
    .N_SEG  (N_SEG),
    .SEG_W  (SEG_W),
    .DATA_W (DATA_W)
  ) u_seg_rx (
    .clk           (seg_clk),
    .rstn          (seg_rstn),
    .rx_seg_valid  (rx_seg_valid),
    .rx_seg_dat    (rx_seg_dat),
    .rx_seg_ena    (rx_seg_ena),
    .rx_seg_sop    (rx_seg_sop),
    .rx_seg_eop    (rx_seg_eop),
    .rx_seg_err    (rx_seg_err),
    .rx_seg_mty    (rx_seg_mty),
    .m_axis_tdata  (rxa_tdata),
    .m_axis_tkeep  (rxa_tkeep),
    .m_axis_tvalid (rxa_tvalid),
    .m_axis_tready (rxa_tready),
    .m_axis_tlast  (rxa_tlast),
    .m_axis_tuser  (rxa_tuser),
    .rx_align_drop (rx_align_drop),
    .rx_align_stat (rx_align_stat)
  );

  logic rx_in_frame;
  always_ff @(posedge seg_clk) begin
    if (!seg_rstn)         rx_in_frame <= 1'b0;
    else if (rxa_tvalid)   rx_in_frame <= ~rxa_tlast;
  end

  logic        rxa_err_seen;
  always_ff @(posedge seg_clk) begin
    if (!seg_rstn)                    rxa_err_seen <= 1'b0;
    else if (rxa_tvalid && rxa_tlast) rxa_err_seen <= 1'b0;
    else if (rxa_tvalid)              rxa_err_seen <= rxa_err_seen | rxa_tuser;
  end

  logic [31:0] rx_err_cnt;
  always_ff @(posedge seg_clk) begin
    if (!seg_rstn)                                  rx_err_cnt <= '0;
    else if (rxa_tvalid && rxa_tlast && (rxa_tuser | rxa_err_seen) &&
             rx_err_cnt != 32'hFFFF_FFFF)           rx_err_cnt <= rx_err_cnt + 1'b1;
  end
  assign rx_err_frames = rx_err_cnt;

  wire rx_sop = rxa_tvalid & ~rx_in_frame;
  logic [PTP_TS_W-1:0] rx_ts_hold;
  always_ff @(posedge seg_clk) begin
    if (!seg_rstn)   rx_ts_hold <= '0;
    else if (rx_sop) rx_ts_hold <= seg_ptp_time;
  end
  wire [PTP_TS_W-1:0] rx_ts_cur = rx_sop ? seg_ptp_time : rx_ts_hold;

  logic        link_up_1d;
  logic        rx_abort;
  logic [2:0]  rx_flush_cnt;
  logic        rx_trunc_r;
  always_ff @(posedge seg_clk) begin
    if (!seg_rstn) begin
      link_up_1d   <= 1'b0;
      rx_flush_cnt <= '0;
      rx_trunc_r   <= 1'b0;
    end else begin
      link_up_1d <= link_up;
      if (rx_abort) begin
        rx_flush_cnt <= 3'd4;
        rx_trunc_r   <= 1'b1;
      end else if (rx_flush_cnt != '0) begin
        rx_flush_cnt <= rx_flush_cnt - 1'b1;
      end
    end
  end
  assign rx_abort = link_up_1d & ~link_up & rx_in_frame;
  assign rx_trunc = rx_trunc_r;

  wire rx_flush = rx_abort | (rx_flush_cnt != 3'd0);

  wire [DATA_W-1:0]    rxu_tdata  = rxa_tdata;
  wire [NET_KEEP-1:0]  rxu_tkeep  = rxa_tkeep;
  wire                 rxu_tvalid = rxa_tvalid & ~rx_flush;
  wire                 rxu_tlast  = rxa_tlast;
  wire                 rxu_tready;
  assign rxa_tready = rxu_tready | rx_flush;

  wire [RX_USER_W-1:0] rxa_user_vec;
  generate
  if (RX_USER_W > 1) begin : g_rx_user_wide
    assign rxa_user_vec = {rx_ts_cur, rxa_tuser};
  end else begin : g_rx_user_narrow
    assign rxa_user_vec = rxa_tuser;
  end
  endgenerate

  wire [RX_USER_W-1:0] rxu_tuser = rxa_user_vec;

  logic rx_fifo_overflow;
  logic rx_cdc_overflow;

  logic [DATA_W-1:0]    rxq_tdata;
  logic [NET_KEEP-1:0]  rxq_tkeep;
  logic                 rxq_tvalid, rxq_tready, rxq_tlast;
  logic [RX_USER_W-1:0] rxq_tuser;
  logic [31:0]          rx_drop_cnt;

  dcmac_axis_frame_fifo #(
    .DATA_W(DATA_W), .KEEP_W(NET_KEEP), .USER_W(RX_USER_W), .ADDR_W(RX_FIFO_AW),
    .DROP_BAD_FRAME(1'b0), .FLAG_BAD_FRAME(1'b1), .DROP_WHEN_FULL(1'b1),
    .MEM_STYLE(`NIA_RX_FF_MEM_STYLE)
  ) u_rx_frame_fifo (
    .clk           (seg_clk),
    .rstn          (seg_rstn),
    .abort         (rx_abort),
    .s_axis_tdata  (rxu_tdata),
    .s_axis_tkeep  (rxu_tkeep),
    .s_axis_tvalid (rxu_tvalid),
    .s_axis_tready (rxu_tready),
    .s_axis_tlast  (rxu_tlast),
    .s_axis_tuser  (rxu_tuser),
    .m_axis_tdata  (rxq_tdata),
    .m_axis_tkeep  (rxq_tkeep),
    .m_axis_tvalid (rxq_tvalid),
    .m_axis_tready (rxq_tready),
    .m_axis_tlast  (rxq_tlast),
    .m_axis_tuser  (rxq_tuser),
    .drop_frames   (rx_drop_cnt),
    .overflow      (rx_fifo_overflow)
  );
  assign rx_drop_frames = rx_drop_cnt;

  eth_axis_async_fifo #(
    .DATA_W(DATA_W), .KEEP_W(NET_KEEP), .USER_W(RX_USER_W), .ADDR_W(RX_CDC_AW),
    .DROP_ON_FULL(1'b0)
  ) u_rx_cdc (
    .s_clk         (seg_clk),
    .s_rstn        (seg_rstn),
    .s_axis_tdata  (rxq_tdata),
    .s_axis_tkeep  (rxq_tkeep),
    .s_axis_tvalid (rxq_tvalid),
    .s_axis_tready (rxq_tready),
    .s_axis_tlast  (rxq_tlast),
    .s_axis_tuser  (rxq_tuser),
    .m_clk         (rx_clk),
    .m_rstn        (rx_rstn),
    .m_axis_tdata  (m_axis_rx_tdata),
    .m_axis_tkeep  (m_axis_rx_tkeep),
    .m_axis_tvalid (m_axis_rx_tvalid),
    .m_axis_tready (1'b1),
    .m_axis_tlast  (m_axis_rx_tlast),
    .m_axis_tuser  (m_axis_rx_tuser),
    .overflow      (rx_cdc_overflow)
  );

  assign rx_overflow = rx_fifo_overflow | rx_cdc_overflow | rx_align_drop;
endmodule
