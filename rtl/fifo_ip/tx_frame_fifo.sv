// ---------------------------------------------------------------------------
// File        : tx_frame_fifo.sv
// Description : The wrapper that binds the generated packet mode FIFO IP, which a device
//               image takes in place of the behavioural model of the same module name.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module tx_frame_fifo #(
  parameter int DATA_W = 512,
  parameter int KEEP_W = DATA_W/8,
  parameter int USER_W = 1,
  parameter int ADDR_W = 8,
  parameter int MAX_FRAME_B = 9018
)(
  input  logic               clk,
  input  logic               rstn,

  input  logic [DATA_W-1:0]  s_axis_tdata,
  input  logic [KEEP_W-1:0]  s_axis_tkeep,
  input  logic               s_axis_tvalid,
  output logic               s_axis_tready,
  input  logic               s_axis_tlast,
  input  logic [USER_W-1:0]  s_axis_tuser,

  output logic [DATA_W-1:0]  m_axis_tdata,
  output logic [KEEP_W-1:0]  m_axis_tkeep,
  output logic               m_axis_tvalid,
  input  logic               m_axis_tready,
  output logic               m_axis_tlast,
  output logic [USER_W-1:0]  m_axis_tuser
);

  localparam bit IP_MATCH = (DATA_W == 512) && (KEEP_W == 64) &&
                            (USER_W == 1)   && (ADDR_W == 8);

  localparam int IP_DEPTH        = 256;
  localparam int MAX_FRAME_BEATS = (MAX_FRAME_B + DATA_W/8 - 1) / (DATA_W/8);

  generate
  if (MAX_FRAME_BEATS > IP_DEPTH) begin : g_frame_too_big
    initial begin
      $error("Error: nia_fifo_pkt_512x1 is a packet mode FIFO, so it commits on tlast and back pressures when full: a frame that alone fills its depth stalls the writer permanently and only a reset clears it.");
      $display("  MAX_FRAME_B=%0d needs %0d beats, the IP holds %0d.",
               MAX_FRAME_B, MAX_FRAME_BEATS, IP_DEPTH);
      $finish;
    end
  end
  endgenerate

  generate
  if (!IP_MATCH) begin : g_no_ip
    initial begin
      $error("tx_frame_fifo (IP variant): no generated axis_data_fifo matches this configuration.");
      $display("  DATA_W=%0d KEEP_W=%0d USER_W=%0d ADDR_W=%0d", DATA_W, KEEP_W, USER_W, ADDR_W);
      $display("  the only IP that exists is nia_fifo_pkt_512x1 (512/64/1/8, FIFO_MODE=2).");
      $display("  Widen ip/dcmac_fifo_ip.tcl AND add a branch here. Do NOT relax this");
      $display("  guard, and do NOT run the PTP/tag variant on the IP variant.");
      $finish;
    end
  end
  endgenerate

  wire [USER_W-1:0] ip_tuser;

  nia_fifo_pkt_512x1 u_pkt (
    .s_axis_aresetn (rstn),
    .s_axis_aclk    (clk),
    .s_axis_tvalid  (s_axis_tvalid),
    .s_axis_tready  (s_axis_tready),
    .s_axis_tdata   (s_axis_tdata),
    .s_axis_tkeep   (s_axis_tkeep),
    .s_axis_tlast   (s_axis_tlast),
    .s_axis_tuser   (s_axis_tuser),
    .m_axis_tvalid  (m_axis_tvalid),
    .m_axis_tready  (m_axis_tready),
    .m_axis_tdata   (m_axis_tdata),
    .m_axis_tkeep   (m_axis_tkeep),
    .m_axis_tlast   (m_axis_tlast),
    .m_axis_tuser   (ip_tuser)
  );

  logic abort_acc;
  wire  xfer = m_axis_tvalid & m_axis_tready;

  always_ff @(posedge clk) begin
    if (!rstn)                      abort_acc <= 1'b0;
    else if (xfer && m_axis_tlast)  abort_acc <= 1'b0;
    else if (xfer)                  abort_acc <= abort_acc | ip_tuser[0];
  end

  generate
  if (USER_W > 1) begin : g_user_wide
    assign m_axis_tuser = {ip_tuser[USER_W-1:1],
                           m_axis_tlast ? (abort_acc | ip_tuser[0]) : 1'b0};
  end else begin : g_user_narrow
    assign m_axis_tuser = m_axis_tlast ? (abort_acc | ip_tuser[0]) : 1'b0;
  end
  endgenerate
endmodule
