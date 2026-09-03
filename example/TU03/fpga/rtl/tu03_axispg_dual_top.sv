// ---------------------------------------------------------------------------
// File        : tu03_axispg_dual_top.sv
// Description : The device top of the two cage 100GAUI-1 AXI-Stream image. It wires the
//               board pins and the host bridge around fpga_axispg_dual_top.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module tu03_axispg_dual_top #(

  parameter integer HOST_ADDR_W   = 16,
  parameter integer DATA_W        = 512,
  parameter integer LOOPBACK_MODE = 0,
  parameter integer LEN_MIN_HW    = 64,
  parameter integer LEN_MAX_HW    = 9018
)(

  input  wire        gt_ref_clk0_p,
  input  wire        gt_ref_clk0_n,
  input  wire        gt_ref_clk1_p,
  input  wire        gt_ref_clk1_n,
  input  wire [7:0]  gt_rxp_in,
  input  wire [7:0]  gt_rxn_in,
  output wire [7:0]  gt_txn_out,
  output wire [7:0]  gt_txp_out
);

  wire        usr_clk, usr_rstn, pl_resetn;
  wire        sys_reset = ~pl_resetn;

  wire [31:0] host_awaddr, host_araddr, host_wdata, host_rdata;
  wire [3:0]  host_wstrb;
  wire [1:0]  host_bresp, host_rresp;
  wire        host_awvalid, host_awready, host_wvalid, host_wready;
  wire        host_bvalid, host_bready, host_arvalid, host_arready;
  wire        host_rvalid, host_rready;

  dcmac_host_bridge_wrapper u_host_bridge (
    .axil_aclk      (usr_clk),
    .pl_resetn      (pl_resetn),

    .m_axil_awaddr  (host_awaddr),
    .m_axil_awprot  (),
    .m_axil_awvalid (host_awvalid),
    .m_axil_awready (host_awready),
    .m_axil_wdata   (host_wdata),
    .m_axil_wstrb   (host_wstrb),
    .m_axil_wvalid  (host_wvalid),
    .m_axil_wready  (host_wready),
    .m_axil_bresp   (host_bresp),
    .m_axil_bvalid  (host_bvalid),
    .m_axil_bready  (host_bready),
    .m_axil_araddr  (host_araddr),
    .m_axil_arprot  (),
    .m_axil_arvalid (host_arvalid),
    .m_axil_arready (host_arready),
    .m_axil_rdata   (host_rdata),
    .m_axil_rresp   (host_rresp),
    .m_axil_rvalid  (host_rvalid),
    .m_axil_rready  (host_rready)
  );

  fpga_axispg_dual_top #(
    .DATA_W        (DATA_W),
    .LOOPBACK_MODE (LOOPBACK_MODE),
    .HOST_ADDR_W   (HOST_ADDR_W),
    .LEN_MIN_HW    (LEN_MIN_HW),
    .LEN_MAX_HW    (LEN_MAX_HW)
  ) u_instrument (
    .sys_reset       (sys_reset),

    .gt_ref_clk0_p   (gt_ref_clk0_p),
    .gt_ref_clk0_n   (gt_ref_clk0_n),
    .gt_ref_clk1_p   (gt_ref_clk1_p),
    .gt_ref_clk1_n   (gt_ref_clk1_n),
    .gt_rxp_in       (gt_rxp_in),
    .gt_rxn_in       (gt_rxn_in),
    .gt_txn_out      (gt_txn_out),
    .gt_txp_out      (gt_txp_out),

    .usr_clk         (usr_clk),
    .usr_rstn        (usr_rstn),

    .link_up         (),
    .mac_fsm_state   (),

    .s_axil_awaddr   (host_awaddr[HOST_ADDR_W-1:0]),
    .s_axil_awvalid  (host_awvalid),
    .s_axil_awready  (host_awready),
    .s_axil_wdata    (host_wdata),
    .s_axil_wstrb    (host_wstrb),
    .s_axil_wvalid   (host_wvalid),
    .s_axil_wready   (host_wready),
    .s_axil_bresp    (host_bresp),
    .s_axil_bvalid   (host_bvalid),
    .s_axil_bready   (host_bready),
    .s_axil_araddr   (host_araddr[HOST_ADDR_W-1:0]),
    .s_axil_arvalid  (host_arvalid),
    .s_axil_arready  (host_arready),
    .s_axil_rdata    (host_rdata),
    .s_axil_rresp    (host_rresp),
    .s_axil_rvalid   (host_rvalid),
    .s_axil_rready   (host_rready)
  );

  wire _unused = &{1'b0, usr_rstn, 1'b0};
endmodule
