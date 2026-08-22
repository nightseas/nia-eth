// ---------------------------------------------------------------------------
// File        : tb_dcmac_drp_bridge.sv
// Description : The test bench of the transceiver reconfiguration bridge, with a model of
//               the port behind it.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module tb_dcmac_drp_bridge #(
  parameter int DRP_ADDR_W   = 24,
  parameter int DRP_DATA_W   = 16,
  parameter int N_WORD       = 16,
  parameter int TIMEOUT_CYC  = 64
)(
  input  wire                    clk,
  input  wire                    rstn,

  input  wire [DRP_ADDR_W-1:0]   drp_addr,
  input  wire [DRP_DATA_W-1:0]   drp_di,
  input  wire                    drp_en,
  input  wire                    drp_we,
  output wire [DRP_DATA_W-1:0]   drp_do,
  output wire                    drp_rdy,
  output wire                    busy,

  input  wire                    axi_stall,

  input  wire                    axi_stall_data,

  input  wire                    link_up,
  input  wire [2:0]              mac_fsm_state,
  input  wire                    rx_status,
  input  wire                    tx_status,
  input  wire                    ctl_link_fault,
  input  wire                    ctl_access_fault,
  input  wire                    ctl_seq_busy,
  input  wire [31:0]             ctl_rx_phy_status,
  input  wire [7:0]              ctl_retry_cnt,
  input  wire [4:0]              ctl_seq_state,
  input  wire [15:0]             ctl_seq_pc,
  input  wire [31:0]             ctl_stat_rd_data,

  output wire [15:0]             dbg_axi_rd_count,
  output wire                    dbg_ctl_req_seen,
  output wire                    ctl_bringup_restart_req
);

  wire [11:0] b_awaddr;  wire b_awvalid;  wire b_awready;
  wire [31:0] b_wdata;   wire [3:0] b_wstrb; wire b_wvalid; wire b_wready;
  wire [1:0]  b_bresp;   wire b_bvalid;   wire b_bready;
  wire [11:0] b_araddr;  wire b_arvalid;  wire b_arready;
  wire [31:0] b_rdata;   wire [1:0] b_rresp; wire b_rvalid; wire b_rready;

  wire c_awvalid = b_awvalid & ~axi_stall;
  wire c_wvalid  = b_wvalid  & ~axi_stall;
  wire c_arvalid = b_arvalid & ~axi_stall;
  wire c_awready, c_wready, c_arready;
  assign b_awready = c_awready & ~axi_stall;
  assign b_wready  = c_wready  & ~axi_stall;
  assign b_arready = c_arready & ~axi_stall;

  wire c_rvalid, c_bvalid;
  assign b_rvalid  = c_rvalid & ~axi_stall_data;
  assign b_bvalid  = c_bvalid & ~axi_stall_data;
  wire   c_rready  = b_rready & ~axi_stall_data;
  wire   c_bready  = b_bready & ~axi_stall_data;

  dcmac_drp_bridge #(
    .DRP_ADDR_W  (DRP_ADDR_W),
    .DRP_DATA_W  (DRP_DATA_W),
    .AXIL_ADDR_W (12),
    .N_WORD      (N_WORD),
    .TIMEOUT_CYC (TIMEOUT_CYC)
  ) u_brg (
    .clk(clk), .rstn(rstn),
    .drp_addr(drp_addr), .drp_di(drp_di), .drp_en(drp_en), .drp_we(drp_we),
    .drp_do(drp_do), .drp_rdy(drp_rdy), .busy(busy),
    .m_axil_awaddr(b_awaddr), .m_axil_awvalid(b_awvalid), .m_axil_awready(b_awready),
    .m_axil_wdata(b_wdata), .m_axil_wstrb(b_wstrb), .m_axil_wvalid(b_wvalid),
    .m_axil_wready(b_wready),
    .m_axil_bresp(b_bresp), .m_axil_bvalid(b_bvalid), .m_axil_bready(b_bready),
    .m_axil_araddr(b_araddr), .m_axil_arvalid(b_arvalid), .m_axil_arready(b_arready),
    .m_axil_rdata(b_rdata), .m_axil_rresp(b_rresp), .m_axil_rvalid(b_rvalid),
    .m_axil_rready(b_rready)
  );

  wire [15:0] csr_link_wdt_ms;

  dcmac_link_csr #(
    .AXIL_ADDR_W(12),
    .AXIL_DATA_W(32)
  ) u_csr (

    .link_wdt_ms(csr_link_wdt_ms),
    .axil_aclk(clk), .axil_aresetn(rstn),
    .s_axil_awaddr(b_awaddr), .s_axil_awvalid(c_awvalid), .s_axil_awready(c_awready),
    .s_axil_wdata(b_wdata), .s_axil_wstrb(b_wstrb), .s_axil_wvalid(c_wvalid),
    .s_axil_wready(c_wready),
    .s_axil_bresp(b_bresp), .s_axil_bvalid(c_bvalid), .s_axil_bready(c_bready),
    .s_axil_araddr(b_araddr), .s_axil_arvalid(c_arvalid), .s_axil_arready(c_arready),
    .s_axil_rdata(b_rdata), .s_axil_rresp(b_rresp), .s_axil_rvalid(c_rvalid),
    .s_axil_rready(c_rready),

    .seg_clk(clk), .seg_rstn(rstn),
    .link_up(link_up), .mac_fsm_state(mac_fsm_state),

    .rx_clk(clk), .rx_rstn(rstn), .rx_status(rx_status),

    .tx_clk(clk), .tx_rstn(rstn), .tx_status(tx_status),
    .ctl_link_fault(ctl_link_fault), .ctl_access_fault(ctl_access_fault),
    .ctl_seq_busy(ctl_seq_busy), .ctl_rx_phy_status(ctl_rx_phy_status),
    .ctl_retry_cnt(ctl_retry_cnt), .ctl_seq_state(ctl_seq_state), .ctl_seq_pc(ctl_seq_pc),
    .ctl_stat_rd_data(ctl_stat_rd_data), .ctl_stat_rd_idx(),

    .ctl_bringup_restart_req(ctl_bringup_restart_req),
    .ctl_stats_req(csr_stats_req),
    .ctl_rx_force_resync_req(csr_resync_req),
    .ctl_rx_datapath_reset_req(csr_rxdp_req),
    .ctl_tx_datapath_reset_req(csr_txdp_req)
  );

  wire csr_stats_req, csr_resync_req, csr_rxdp_req, csr_txdp_req;

  reg [15:0] ar_cnt = 16'h0;
  always_ff @(posedge clk) begin
    if (!rstn) ar_cnt <= 16'h0;
    else if (c_arvalid && c_arready) ar_cnt <= ar_cnt + 16'd1;
  end
  assign dbg_axi_rd_count = ar_cnt;

  reg req_seen = 1'b0;
  always_ff @(posedge clk) begin
    if (!rstn) req_seen <= 1'b0;
    else if (ctl_bringup_restart_req | csr_stats_req | csr_resync_req |
             csr_rxdp_req | csr_txdp_req) req_seen <= 1'b1;
  end
  assign dbg_ctl_req_seen = req_seen;

endmodule

`default_nettype wire
