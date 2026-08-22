// ---------------------------------------------------------------------------
// File        : tb_dcmac_axis_pktgen_adapter.sv
// Description : The test bench of the AXI-Stream instrument through the adapter, so the
//               traffic crosses the segment to stream mapping in both directions.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_dcmac_axis_pktgen_adapter #(
  parameter integer DATA_W      = 512,
  parameter integer AXIL_ADDR_W = 12,
  parameter integer LEN_MIN_HW  = 64,
  parameter integer LEN_MAX_HW  = 1518,
  parameter integer N_SEG       = 2,
  parameter integer SEG_W       = 128,
  parameter integer PACK_LOOP   = 0
)(
  input  wire        net_clk,
  input  wire        net_rstn,
  input  wire        tready_force,
  input  wire        link_up,
  output wire        tx_tvalid,
  output wire        tx_tready,
  output wire        tx_tlast,
  output wire        rx_overflow,
  output wire        rx_trunc,
  output wire        tx_cpl_overflow,
  input  wire        axil_aclk,
  input  wire        axil_aresetn,
  input  wire [AXIL_ADDR_W-1:0] s_axil_awaddr,
  input  wire        s_axil_awvalid,
  output wire        s_axil_awready,
  input  wire [31:0] s_axil_wdata,
  input  wire [3:0]  s_axil_wstrb,
  input  wire        s_axil_wvalid,
  output wire        s_axil_wready,
  output wire [1:0]  s_axil_bresp,
  output wire        s_axil_bvalid,
  input  wire        s_axil_bready,
  input  wire [AXIL_ADDR_W-1:0] s_axil_araddr,
  input  wire        s_axil_arvalid,
  output wire        s_axil_arready,
  output wire [31:0] s_axil_rdata,
  output wire [1:0]  s_axil_rresp,
  output wire        s_axil_rvalid,
  input  wire        s_axil_rready
);
  localparam int SEG_BITS = N_SEG * SEG_W;

  wire [DATA_W-1:0]   tx_tdata;
  wire [DATA_W/8-1:0] tx_tkeep;
  wire                tx_tvalid_i, tx_tready_i, tx_tlast_i, tx_tuser;

  wire [DATA_W-1:0]   rx_tdata;
  wire [DATA_W/8-1:0] rx_tkeep;
  wire                rx_tvalid, rx_tlast, rx_tuser;

  wire                seg_valid;
  wire [SEG_BITS-1:0] seg_dat;
  wire [N_SEG-1:0]    seg_ena, seg_sop, seg_eop, seg_err;
  wire [N_SEG*4-1:0]  seg_mty;
  wire                pack_ready;
  wire                seg_ready = tready_force & pack_ready;

  wire                rxl_valid;
  wire [SEG_BITS-1:0] rxl_dat;
  wire [N_SEG-1:0]    rxl_ena, rxl_sop, rxl_eop, rxl_err;
  wire [N_SEG*4-1:0]  rxl_mty;

  generate
  if (PACK_LOOP != 0) begin : g_pack_loop
    seg_pack_loop #(.N_SEG(N_SEG), .SEG_W(SEG_W)) u_pack_loop (
      .clk         (net_clk),
      .rstn        (net_rstn),
      .s_seg_valid (seg_valid & seg_ready),
      .s_seg_ready (pack_ready),
      .s_seg_dat   (seg_dat),
      .s_seg_ena   (seg_ena),
      .s_seg_sop   (seg_sop),
      .s_seg_eop   (seg_eop),
      .s_seg_err   (seg_err),
      .s_seg_mty   (seg_mty),
      .m_seg_valid (rxl_valid),
      .m_seg_dat   (rxl_dat),
      .m_seg_ena   (rxl_ena),
      .m_seg_sop   (rxl_sop),
      .m_seg_eop   (rxl_eop),
      .m_seg_err   (rxl_err),
      .m_seg_mty   (rxl_mty)
    );
  end else begin : g_direct_loop
    assign pack_ready = 1'b1;
    assign rxl_valid  = seg_valid & seg_ready;
    assign rxl_dat    = seg_dat;
    assign rxl_ena    = seg_ena;
    assign rxl_sop    = seg_sop;
    assign rxl_eop    = seg_eop;
    assign rxl_err    = seg_err;
    assign rxl_mty    = seg_mty;
  end
  endgenerate

  assign tx_tvalid = tx_tvalid_i;
  assign tx_tready = tx_tready_i;
  assign tx_tlast  = tx_tlast_i;

  dcmac_axis_pktgen #(
    .DATA_W      (DATA_W),
    .TX_USER_W   (1),
    .RX_USER_W   (1),
    .AXIL_ADDR_W (AXIL_ADDR_W),
    .SAME_CLOCK  (1'b1),
    .LEN_MIN_HW  (LEN_MIN_HW),
    .LEN_MAX_HW  (LEN_MAX_HW)
  ) u_pktgen (
    .net_clk          (net_clk),
    .net_rstn         (net_rstn),
    .m_axis_tx_tdata  (tx_tdata),
    .m_axis_tx_tkeep  (tx_tkeep),
    .m_axis_tx_tvalid (tx_tvalid_i),
    .m_axis_tx_tready (tx_tready_i),
    .m_axis_tx_tlast  (tx_tlast_i),
    .m_axis_tx_tuser  (tx_tuser),
    .s_axis_rx_tdata  (rx_tdata),
    .s_axis_rx_tkeep  (rx_tkeep),
    .s_axis_rx_tvalid (rx_tvalid),
    .s_axis_rx_tlast  (rx_tlast),
    .s_axis_rx_tuser  (rx_tuser),
    .link_up          (link_up),
    .axil_aclk        (axil_aclk),
    .axil_aresetn     (axil_aresetn),
    .s_axil_awaddr    (s_axil_awaddr),
    .s_axil_awvalid   (s_axil_awvalid),
    .s_axil_awready   (s_axil_awready),
    .s_axil_wdata     (s_axil_wdata),
    .s_axil_wstrb     (s_axil_wstrb),
    .s_axil_wvalid    (s_axil_wvalid),
    .s_axil_wready    (s_axil_wready),
    .s_axil_bresp     (s_axil_bresp),
    .s_axil_bvalid    (s_axil_bvalid),
    .s_axil_bready    (s_axil_bready),
    .s_axil_araddr    (s_axil_araddr),
    .s_axil_arvalid   (s_axil_arvalid),
    .s_axil_arready   (s_axil_arready),
    .s_axil_rdata     (s_axil_rdata),
    .s_axil_rresp     (s_axil_rresp),
    .s_axil_rvalid    (s_axil_rvalid),
    .s_axil_rready    (s_axil_rready)
  );

  dcmac_axis_adapter #(
    .N_SEG     (N_SEG),
    .SEG_W     (SEG_W),
    .DATA_W    (DATA_W),
    .PTP_TS_EN (0),
    .TX_TAG_W  (0)
  ) u_adapter (
    .seg_clk  (net_clk),
    .seg_rstn (net_rstn),
    .tx_clk   (net_clk),
    .tx_rstn  (net_rstn),
    .rx_clk   (net_clk),
    .rx_rstn  (net_rstn),
    .tx_rst   (),
    .rx_rst   (),

    .s_axis_tx_tdata  (tx_tdata),
    .s_axis_tx_tkeep  (tx_tkeep),
    .s_axis_tx_tvalid (tx_tvalid_i),
    .s_axis_tx_tready (tx_tready_i),
    .s_axis_tx_tlast  (tx_tlast_i),
    .s_axis_tx_tuser  (tx_tuser),

    .m_axis_tx_cpl_valid (),
    .m_axis_tx_cpl_ready (1'b1),
    .m_axis_tx_cpl_ts    (),
    .m_axis_tx_cpl_tag   (),

    .m_axis_rx_tdata  (rx_tdata),
    .m_axis_rx_tkeep  (rx_tkeep),
    .m_axis_rx_tvalid (rx_tvalid),
    .m_axis_rx_tlast  (rx_tlast),
    .m_axis_rx_tuser  (rx_tuser),

    .seg_ptp_time (80'd0),

    .rx_seg_valid (rxl_valid),
    .rx_seg_dat   (rxl_dat),
    .rx_seg_ena   (rxl_ena),
    .rx_seg_sop   (rxl_sop),
    .rx_seg_eop   (rxl_eop),
    .rx_seg_err   (rxl_err),
    .rx_seg_mty   (rxl_mty),

    .tx_seg_ready (seg_ready),
    .tx_seg_valid (seg_valid),
    .tx_seg_dat   (seg_dat),
    .tx_seg_ena   (seg_ena),
    .tx_seg_sop   (seg_sop),
    .tx_seg_eop   (seg_eop),
    .tx_seg_err   (seg_err),
    .tx_seg_mty   (seg_mty),

    .stat_rx_aligned (1'b1),
    .link_up         (link_up),
    .tx_rst_seg      (1'b0),
    .ctl_tx_enable   (1'b1),

    .rx_status       (),
    .tx_status       (),
    .rx_overflow     (rx_overflow),
    .rx_trunc        (rx_trunc),
    .rx_err_frames   (),
    .rx_drop_frames  (),
    .rx_align_stat           (),
    .tx_cpl_overflow (tx_cpl_overflow)
  );
endmodule
