// ---------------------------------------------------------------------------
// File        : tb_dcmac_pktgen_loop.sv
// Description : The test bench of the segmented instrument in loopback: the generator's
//               transmit side is fed back to its own receive checker.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_dcmac_pktgen_loop #(

  parameter integer N_SEG       = 2,
  parameter integer SEG_W       = 128,
  parameter integer AXIL_ADDR_W = 12,
  parameter integer STALL_CYC   = 16,
  parameter integer LEN_MIN_HW  = 60,
  parameter integer LEN_MAX_HW  = 9018
)(

  input  wire                      seg_clk,
  input  wire                      seg_rstn,

  input  wire                      link_up,
  input  wire                      tx_rst_seg,
  input  wire                      ctl_tx_enable,

  input  wire                      tx_seg_ready,
  output wire                      tx_seg_valid,
  output wire [N_SEG*SEG_W-1:0]    tx_seg_dat,
  output wire [N_SEG-1:0]          tx_seg_ena,
  output wire [N_SEG-1:0]          tx_seg_sop,
  output wire [N_SEG-1:0]          tx_seg_eop,
  output wire [N_SEG-1:0]          tx_seg_err,
  output wire [N_SEG*4-1:0]        tx_seg_mty,

  input  wire                      loop_enable,
  input  wire                      loop_err_inject,
  input  wire [N_SEG*SEG_W-1:0]    loop_dat_xor,

  input  wire                      axil_aclk,
  input  wire                      axil_aresetn,
  input  wire [AXIL_ADDR_W-1:0]    s_axil_awaddr,
  input  wire                      s_axil_awvalid,
  output wire                      s_axil_awready,
  input  wire [31:0]               s_axil_wdata,
  input  wire [3:0]                s_axil_wstrb,
  input  wire                      s_axil_wvalid,
  output wire                      s_axil_wready,
  output wire [1:0]                s_axil_bresp,
  output wire                      s_axil_bvalid,
  input  wire                      s_axil_bready,
  input  wire [AXIL_ADDR_W-1:0]    s_axil_araddr,
  input  wire                      s_axil_arvalid,
  output wire                      s_axil_arready,
  output wire [31:0]               s_axil_rdata,
  output wire [1:0]                s_axil_rresp,
  output wire                      s_axil_rvalid,
  input  wire                      s_axil_rready
);

  wire                   accepted = tx_seg_valid & tx_seg_ready;

  logic                  rx_valid_r;
  logic [N_SEG*SEG_W-1:0] rx_dat_r;
  logic [N_SEG-1:0]      rx_ena_r, rx_sop_r, rx_eop_r, rx_err_r;
  logic [N_SEG*4-1:0]    rx_mty_r;

  always_ff @(posedge seg_clk) begin
    if (!seg_rstn) begin
      rx_valid_r <= 1'b0;
      rx_dat_r   <= '0;
      rx_ena_r   <= '0;
      rx_sop_r   <= '0;
      rx_eop_r   <= '0;
      rx_err_r   <= '0;
      rx_mty_r   <= '0;
    end else begin
      rx_valid_r <= accepted & loop_enable;
      rx_dat_r   <= tx_seg_dat ^ loop_dat_xor;
      rx_ena_r   <= tx_seg_ena;
      rx_sop_r   <= tx_seg_sop;
      rx_eop_r   <= tx_seg_eop;
      rx_err_r   <= loop_err_inject ? tx_seg_eop : tx_seg_err;
      rx_mty_r   <= tx_seg_mty;
    end
  end

  dcmac_seg_pktgen #(
    .N_SEG(N_SEG), .SEG_W(SEG_W), .AXIL_ADDR_W(AXIL_ADDR_W), .STALL_CYC(STALL_CYC),
    .LEN_MIN_HW(LEN_MIN_HW), .LEN_MAX_HW(LEN_MAX_HW)
  ) u_pktgen (
    .seg_clk       (seg_clk),
    .seg_rstn      (seg_rstn),

    .link_up       (link_up),
    .tx_rst_seg    (tx_rst_seg),
    .ctl_tx_enable (ctl_tx_enable),

    .tx_seg_ready  (tx_seg_ready),
    .tx_seg_valid  (tx_seg_valid),
    .tx_seg_dat    (tx_seg_dat),
    .tx_seg_ena    (tx_seg_ena),
    .tx_seg_sop    (tx_seg_sop),
    .tx_seg_eop    (tx_seg_eop),
    .tx_seg_err    (tx_seg_err),
    .tx_seg_mty    (tx_seg_mty),

    .rx_seg_valid  (rx_valid_r),
    .rx_seg_dat    (rx_dat_r),
    .rx_seg_ena    (rx_ena_r),
    .rx_seg_sop    (rx_sop_r),
    .rx_seg_eop    (rx_eop_r),
    .rx_seg_err    (rx_err_r),
    .rx_seg_mty    (rx_mty_r),

    .axil_aclk     (axil_aclk),
    .axil_aresetn  (axil_aresetn),
    .s_axil_awaddr (s_axil_awaddr),
    .s_axil_awvalid(s_axil_awvalid),
    .s_axil_awready(s_axil_awready),
    .s_axil_wdata  (s_axil_wdata),
    .s_axil_wstrb  (s_axil_wstrb),
    .s_axil_wvalid (s_axil_wvalid),
    .s_axil_wready (s_axil_wready),
    .s_axil_bresp  (s_axil_bresp),
    .s_axil_bvalid (s_axil_bvalid),
    .s_axil_bready (s_axil_bready),
    .s_axil_araddr (s_axil_araddr),
    .s_axil_arvalid(s_axil_arvalid),
    .s_axil_arready(s_axil_arready),
    .s_axil_rdata  (s_axil_rdata),
    .s_axil_rresp  (s_axil_rresp),
    .s_axil_rvalid (s_axil_rvalid),
    .s_axil_rready (s_axil_rready)
  );

endmodule
