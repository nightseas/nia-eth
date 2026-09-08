// ---------------------------------------------------------------------------
// File        : eth_axis_async_fifo.sv
// Description : The wrapper that binds the generated clock crossing FIFO IP, which a
//               device image takes in place of the behavioural model of the same module
//               name.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module eth_axis_async_fifo #(
  parameter int DATA_W = 256,
  parameter int KEEP_W = DATA_W/8,
  parameter int USER_W = 1,
  parameter int ADDR_W = 9,
  parameter bit DROP_ON_FULL = 1'b1
)(
  input  logic               s_clk,
  input  logic               s_rstn,
  input  logic [DATA_W-1:0]  s_axis_tdata,
  input  logic [KEEP_W-1:0]  s_axis_tkeep,
  input  logic               s_axis_tvalid,
  output logic               s_axis_tready,
  input  logic               s_axis_tlast,
  input  logic [USER_W-1:0]  s_axis_tuser,

  input  logic               m_clk,
  input  logic               m_rstn,
  output logic [DATA_W-1:0]  m_axis_tdata,
  output logic [KEEP_W-1:0]  m_axis_tkeep,
  output logic               m_axis_tvalid,
  input  logic               m_axis_tready,
  output logic               m_axis_tlast,
  output logic [USER_W-1:0]  m_axis_tuser,

  output logic               overflow
);

  localparam bit IP_512  = (DATA_W == 512)  && (KEEP_W == 64);
  localparam bit IP_1024 = (DATA_W == 1024) && (KEEP_W == 128);
  localparam bit IP_MATCH = (IP_512 || IP_1024) && (USER_W == 1) && (ADDR_W == 9);

  generate
  if (DROP_ON_FULL) begin : g_no_drop_on_full
    initial begin
      $error("eth_axis_async_fifo (IP variant): DROP_ON_FULL=1 is not implementable by axis_data_fifo.");
      $display("  There is no accept-and-drop property in axis_data_fifo v2.0. All three CDC");
      $display("  instances in dcmac_axis_adapter pass DROP_ON_FULL(1'b0); a lossy source");
      $display("  must be handled by dcmac_axis_frame_fifo's DROP_WHEN_FULL instead.");
      $finish;
    end
  end
  if (!IP_MATCH) begin : g_no_ip
    initial begin
      $error("eth_axis_async_fifo (IP variant): no generated axis_data_fifo matches this configuration.");
      $display("  DATA_W=%0d KEEP_W=%0d USER_W=%0d ADDR_W=%0d", DATA_W, KEEP_W, USER_W, ADDR_W);
      $display("  the generated IPs are nia_fifo_cdc_512x1 and nia_fifo_cdc_1024x1, both USER_W 1 ADDR_W 9.");
      $display("  Widen ip/dcmac_fifo_ip.tcl AND add a branch here. Do NOT relax this");
      $display("  guard, and do NOT run the PTP/tag variant on the IP variant.");
      $finish;
    end
  end
  endgenerate

  generate
  if (IP_1024) begin : g_cdc_1024
    nia_fifo_cdc_1024x1 u_cdc (
      .s_axis_aresetn (s_rstn),
      .s_axis_aclk    (s_clk),
      .s_axis_tvalid  (s_axis_tvalid),
      .s_axis_tready  (s_axis_tready),
      .s_axis_tdata   (s_axis_tdata),
      .s_axis_tkeep   (s_axis_tkeep),
      .s_axis_tlast   (s_axis_tlast),
      .s_axis_tuser   (s_axis_tuser),
      .m_axis_aclk    (m_clk),
      .m_axis_tvalid  (m_axis_tvalid),
      .m_axis_tready  (m_axis_tready),
      .m_axis_tdata   (m_axis_tdata),
      .m_axis_tkeep   (m_axis_tkeep),
      .m_axis_tlast   (m_axis_tlast),
      .m_axis_tuser   (m_axis_tuser)
    );
  end else begin : g_cdc_512
    nia_fifo_cdc_512x1 u_cdc (
      .s_axis_aresetn (s_rstn),
      .s_axis_aclk    (s_clk),
      .s_axis_tvalid  (s_axis_tvalid),
      .s_axis_tready  (s_axis_tready),
      .s_axis_tdata   (s_axis_tdata),
      .s_axis_tkeep   (s_axis_tkeep),
      .s_axis_tlast   (s_axis_tlast),
      .s_axis_tuser   (s_axis_tuser),
      .m_axis_aclk    (m_clk),
      .m_axis_tvalid  (m_axis_tvalid),
      .m_axis_tready  (m_axis_tready),
      .m_axis_tdata   (m_axis_tdata),
      .m_axis_tkeep   (m_axis_tkeep),
      .m_axis_tlast   (m_axis_tlast),
      .m_axis_tuser   (m_axis_tuser)
    );
  end
  endgenerate

  logic ovf_r;
  always_ff @(posedge s_clk) begin
    if (!s_rstn)                              ovf_r <= 1'b0;
    else if (s_axis_tvalid && !s_axis_tready) ovf_r <= 1'b1;
  end
  assign overflow = ovf_r;
endmodule
