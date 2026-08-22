// ---------------------------------------------------------------------------
// File        : quad_readiness_good.sv
// Description : The fixture a structural check mutates: a transceiver quad readiness
//               wiring that is correct, so the check is shown to fail when it is broken.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

`default_nettype none

module quad_readiness_good #(
  parameter integer N_QUAD = 2
)(
  input  wire tx_clk,
  input  wire tx_rstn,
  input  wire gtpowergood_0,
  input  wire gt_tx_reset_done_0,
  input  wire gt_rx_reset_done_0,
  input  wire gtpowergood_1,
  input  wire gt_tx_reset_done_1,
  input  wire gt_rx_reset_done_1,

  output wire gt_ready
);

  (* ASYNC_REG = "TRUE" *) reg [1:0] gtpowergood_0_sync;
  (* ASYNC_REG = "TRUE" *) reg [1:0] gt_tx_reset_done_0_sync;
  (* ASYNC_REG = "TRUE" *) reg [1:0] gt_rx_reset_done_0_sync;
  (* ASYNC_REG = "TRUE" *) reg [1:0] gtpowergood_1_sync;
  (* ASYNC_REG = "TRUE" *) reg [1:0] gt_tx_reset_done_1_sync;
  (* ASYNC_REG = "TRUE" *) reg [1:0] gt_rx_reset_done_1_sync;

  always_ff @(posedge tx_clk) begin
    if (!tx_rstn) begin
      gtpowergood_0_sync      <= 2'b00;
      gt_tx_reset_done_0_sync <= 2'b00;
      gt_rx_reset_done_0_sync <= 2'b00;
      gtpowergood_1_sync      <= 2'b00;
      gt_tx_reset_done_1_sync <= 2'b00;
      gt_rx_reset_done_1_sync <= 2'b00;
    end else begin

      gtpowergood_0_sync      <= {gtpowergood_0_sync[0],      gtpowergood_0};
      gt_tx_reset_done_0_sync <= {gt_tx_reset_done_0_sync[0], gt_tx_reset_done_0};
      gt_rx_reset_done_0_sync <= {gt_rx_reset_done_0_sync[0], gt_rx_reset_done_0};
      gtpowergood_1_sync      <= {gtpowergood_1_sync[0],      gtpowergood_1};
      gt_tx_reset_done_1_sync <= {gt_tx_reset_done_1_sync[0], gt_tx_reset_done_1};
      gt_rx_reset_done_1_sync <= {gt_rx_reset_done_1_sync[0], gt_rx_reset_done_1};
    end
  end

  wire quad0_ready = gtpowergood_0_sync[1] & gt_tx_reset_done_0_sync[1]
                                          & gt_rx_reset_done_0_sync[1];
  wire quad1_ready = gtpowergood_1_sync[1] & gt_tx_reset_done_1_sync[1]
                                          & gt_rx_reset_done_1_sync[1];

  assign gt_ready = quad0_ready & quad1_ready;

endmodule
`default_nettype wire
