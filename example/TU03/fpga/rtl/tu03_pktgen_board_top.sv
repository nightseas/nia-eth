// ---------------------------------------------------------------------------
// File        : tu03_pktgen_board_top.sv
// Description : The device top of the single cage segmented image. It wires the board
//               pins and the host bridge around fpga_pktgen_top.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module tu03_pktgen_board_top #(

  parameter integer HOST_ADDR_W   = 16,
  parameter integer LOOPBACK_MODE = 0
)(

  input  wire        gt_ref_clk_p,
  input  wire        gt_ref_clk_n,
  input  wire [3:0]  gt_rxp_in,
  input  wire [3:0]  gt_rxn_in,
  output wire [3:0]  gt_txn_out,
  output wire [3:0]  gt_txp_out
);

  wire        usr_clk;
  wire        pl_resetn;

  wire [31:0] host_awaddr;
  wire        host_awvalid, host_awready;
  wire [31:0] host_wdata;
  wire [3:0]  host_wstrb;
  wire        host_wvalid, host_wready;
  wire [1:0]  host_bresp;
  wire        host_bvalid, host_bready;
  wire [31:0] host_araddr;
  wire        host_arvalid, host_arready;
  wire [31:0] host_rdata;
  wire [1:0]  host_rresp;
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

  fpga_pktgen_top #(
    .HOST_ADDR_W   (HOST_ADDR_W),
    .LOOPBACK_MODE (LOOPBACK_MODE)
  ) u_pktgen (
    .sys_reset      (~pl_resetn),

    .gt_ref_clk_p   (gt_ref_clk_p),
    .gt_ref_clk_n   (gt_ref_clk_n),
    .gt_rxp_in      (gt_rxp_in),
    .gt_rxn_in      (gt_rxn_in),
    .gt_txn_out     (gt_txn_out),
    .gt_txp_out     (gt_txp_out),

    .usr_clk        (usr_clk),

    .link_up        (),
    .mac_fsm_state  (),

    .s_axil_awaddr  (host_awaddr[HOST_ADDR_W-1:0]),
    .s_axil_awvalid (host_awvalid),
    .s_axil_awready (host_awready),
    .s_axil_wdata   (host_wdata),
    .s_axil_wstrb   (host_wstrb),
    .s_axil_wvalid  (host_wvalid),
    .s_axil_wready  (host_wready),
    .s_axil_bresp   (host_bresp),
    .s_axil_bvalid  (host_bvalid),
    .s_axil_bready  (host_bready),
    .s_axil_araddr  (host_araddr[HOST_ADDR_W-1:0]),
    .s_axil_arvalid (host_arvalid),
    .s_axil_arready (host_arready),
    .s_axil_rdata   (host_rdata),
    .s_axil_rresp   (host_rresp),
    .s_axil_rvalid  (host_rvalid),
    .s_axil_rready  (host_rready)
  );

endmodule
