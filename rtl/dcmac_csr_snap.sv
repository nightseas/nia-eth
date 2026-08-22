// ---------------------------------------------------------------------------
// File        : dcmac_csr_snap.sv
// Description : The snapshot crossing every register block reads through: a wide counter
//               set is captured in the data path clock and published to the register
//               clock with a round counter, so a reader can tell a coherent set from a
//               torn one.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module dcmac_csr_snap #(
  parameter int WIDTH      = 32,
  parameter bit SAME_CLOCK = 1'b0
)(
  input  wire              s_clk,
  input  wire              s_rstn,
  input  wire [WIDTH-1:0]  din,
  input  wire              m_clk,
  input  wire              m_rstn,
  output wire [WIDTH-1:0]  dout,
  output wire [7:0]        rounds
);

  logic [WIDTH-1:0] dout_r = '0;
  logic [7:0]       rounds_r = '0;

  if (SAME_CLOCK) begin : g_capture_same_clock

    always_ff @(posedge m_clk) begin
      if (!m_rstn) begin
        dout_r   <= '0;
        rounds_r <= '0;
      end else begin
        dout_r   <= din;
        rounds_r <= rounds_r + 8'd1;
      end
    end

    wire _unused_source_clock = &{1'b0, s_clk, s_rstn, 1'b0};

  end else begin : g_capture_handshake

    logic             req_m = 1'b0;
    (* ASYNC_REG = "TRUE" *) logic ack_s0 = 1'b0, ack_s1 = 1'b0;

    (* ASYNC_REG = "TRUE" *) logic req_s0 = 1'b0, req_s1 = 1'b0;
    logic             ack_r = 1'b0;
    logic [WIDTH-1:0] hold  = '0;

    always_ff @(posedge s_clk) begin
      if (!s_rstn) begin
        req_s0 <= 1'b0; req_s1 <= 1'b0; ack_r <= 1'b0; hold <= '0;
      end else begin
        req_s0 <= req_m;
        req_s1 <= req_s0;
        if (req_s1 != ack_r) begin
          hold  <= din;
          ack_r <= req_s1;
        end
      end
    end

    always_ff @(posedge m_clk) begin
      if (!m_rstn) begin
        ack_s0 <= 1'b0; ack_s1 <= 1'b0; req_m <= 1'b0; dout_r <= '0; rounds_r <= '0;
      end else begin
        ack_s0 <= ack_r;
        ack_s1 <= ack_s0;
        if (ack_s1 == req_m) begin
          dout_r   <= hold;
          rounds_r <= rounds_r + 8'd1;
          req_m    <= ~req_m;
        end
      end
    end

  end

  assign dout   = dout_r;
  assign rounds = rounds_r;
endmodule
