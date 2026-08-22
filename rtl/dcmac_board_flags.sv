// ---------------------------------------------------------------------------
// File        : dcmac_board_flags.sv
// Description : The board facts a build must not invent, held as parameters so one top
//               serves every board that differs only in them.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module dcmac_board_flags #(

  parameter int SEG_HALF_CYC  = 195_465_000,

  parameter int PCIE_HALF_CYC = 125_000_000,

  parameter int SYNC_N        = 2
)(

  input  wire        flag_clk,

  input  wire        pcie_user_clk,
  input  wire        pcie_user_lnk_up,

  input  wire        seg_clk,
  input  wire        dcmac_link_up,
  input  wire        rx_overflow,

  input  wire        ctl_seq_busy,
  input  wire        ctl_access_fault,

  output wire [3:0]  bmc_gpio,
  output wire [1:0]  led
);

  logic st_rx_overflow = 1'b0;

  always_ff @(posedge seg_clk) begin
    if (rx_overflow) st_rx_overflow <= 1'b1;
  end

  localparam int SEG_CNT_W = $clog2(SEG_HALF_CYC + 1);

  logic [SEG_CNT_W-1:0] seg_div = '0;
  logic                 seg_hb  = 1'b0;

  always_ff @(posedge seg_clk) begin
    if (seg_div >= SEG_CNT_W'(SEG_HALF_CYC - 1)) begin
      seg_div <= '0;
      seg_hb  <= ~seg_hb;
    end else begin
      seg_div <= seg_div + 1'b1;
    end
  end

  localparam int PCIE_CNT_W = $clog2(PCIE_HALF_CYC + 1);

  logic [PCIE_CNT_W-1:0] pcie_div = '0;
  logic                  pcie_hb  = 1'b0;

  always_ff @(posedge pcie_user_clk) begin
    if (pcie_div >= PCIE_CNT_W'(PCIE_HALF_CYC - 1)) begin
      pcie_div <= '0;
      pcie_hb  <= ~pcie_hb;
    end else begin
      pcie_div <= pcie_div + 1'b1;
    end
  end

  assign led[1] = seg_hb;
  assign led[0] = pcie_hb;

  wire [2:0] lvl_async = {st_rx_overflow, dcmac_link_up, pcie_user_lnk_up};
  wire [2:0] lvl_sync;

  (* ASYNC_REG = "TRUE" *) reg [2:0] nia_flag_sync [SYNC_N-1:0];

  integer k;
  always_ff @(posedge flag_clk) begin
    nia_flag_sync[0] <= lvl_async;
    for (k = 1; k < SYNC_N; k = k + 1) begin
      nia_flag_sync[k] <= nia_flag_sync[k-1];
    end
  end

  assign lvl_sync = nia_flag_sync[SYNC_N-1];

  logic [3:0] gpio_r = 4'b0;

  always_ff @(posedge flag_clk) begin
    gpio_r[0] <= lvl_sync[0];
    gpio_r[1] <= lvl_sync[1];
    gpio_r[2] <= !ctl_seq_busy && !ctl_access_fault;
    gpio_r[3] <= lvl_sync[2];
  end

  assign bmc_gpio = gpio_r;

endmodule
