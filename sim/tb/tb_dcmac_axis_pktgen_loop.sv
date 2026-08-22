// ---------------------------------------------------------------------------
// File        : tb_dcmac_axis_pktgen_loop.sv
// Description : The test bench of the AXI-Stream instrument in loopback, with no adapter
//               in the path.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_dcmac_axis_pktgen_loop #(

  parameter integer DATA_W      = 512,
  parameter integer AXIL_ADDR_W = 12,
  parameter integer LEN_MIN_HW  = 64,
  parameter integer LEN_MAX_HW  = 1518
)(
  input  wire                   net_clk,
  input  wire                   net_rstn,

  input  wire                   tready_force,
  input  wire                   link_up,

  output wire                   tx_tvalid,
  output wire                   tx_tready,
  output wire                   tx_tlast,

  input  wire                   axil_aclk,
  input  wire                   axil_aresetn,
  input  wire [AXIL_ADDR_W-1:0] s_axil_awaddr,
  input  wire                   s_axil_awvalid,
  output wire                   s_axil_awready,
  input  wire [31:0]            s_axil_wdata,
  input  wire [3:0]             s_axil_wstrb,
  input  wire                   s_axil_wvalid,
  output wire                   s_axil_wready,
  output wire [1:0]             s_axil_bresp,
  output wire                   s_axil_bvalid,
  input  wire                   s_axil_bready,
  input  wire [AXIL_ADDR_W-1:0] s_axil_araddr,
  input  wire                   s_axil_arvalid,
  output wire                   s_axil_arready,
  output wire [31:0]            s_axil_rdata,
  output wire [1:0]             s_axil_rresp,
  output wire                   s_axil_rvalid,
  input  wire                   s_axil_rready
);
  wire [DATA_W-1:0]   tdata;
  wire [DATA_W/8-1:0] tkeep;
  wire                tvalid, tready, tlast;
  wire                tuser;

  assign tready    = tready_force;
  assign tx_tvalid = tvalid;
  assign tx_tready = tready;
  assign tx_tlast  = tlast;

  dcmac_axis_pktgen #(
    .DATA_W(DATA_W), .AXIL_ADDR_W(AXIL_ADDR_W),
    .LEN_MIN_HW(LEN_MIN_HW), .LEN_MAX_HW(LEN_MAX_HW)
  ) u_pktgen (
    .net_clk          (net_clk),
    .net_rstn         (net_rstn),

    .m_axis_tx_tdata  (tdata),
    .m_axis_tx_tkeep  (tkeep),
    .m_axis_tx_tvalid (tvalid),
    .m_axis_tx_tready (tready),
    .m_axis_tx_tlast  (tlast),
    .m_axis_tx_tuser  (tuser),

    .s_axis_rx_tdata  (tdata),
    .s_axis_rx_tkeep  (tkeep),
    .s_axis_rx_tvalid (tvalid & tready),
    .s_axis_rx_tlast  (tlast),
    .s_axis_rx_tuser  (1'b0),

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

  wire _unused = &{1'b0, tuser, 1'b0};
endmodule
