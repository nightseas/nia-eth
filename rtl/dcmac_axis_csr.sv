// ---------------------------------------------------------------------------
// File        : dcmac_axis_csr.sv
// Description : The register block of the AXI-Stream adapter: its identity, its
//               capabilities, the latched loss indications and the receive counters.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module dcmac_axis_csr #(
  parameter int AXIL_ADDR_W = 12,
  parameter int AXIL_DATA_W = 32,
  parameter int N_SEG       = 2,
  parameter int SEG_W       = 128,
  parameter [31:0] ID_VALUE = 32'h4E414353,
  parameter [31:0] VERSION  = 32'h0001_0000
)(
  input  wire                     axil_aclk,
  input  wire                     axil_aresetn,
  input  wire [AXIL_ADDR_W-1:0]   s_axil_awaddr,
  input  wire                     s_axil_awvalid,
  output wire                     s_axil_awready,
  input  wire [AXIL_DATA_W-1:0]   s_axil_wdata,
  input  wire [AXIL_DATA_W/8-1:0] s_axil_wstrb,
  input  wire                     s_axil_wvalid,
  output wire                     s_axil_wready,
  output wire [1:0]               s_axil_bresp,
  output wire                     s_axil_bvalid,
  input  wire                     s_axil_bready,
  input  wire [AXIL_ADDR_W-1:0]   s_axil_araddr,
  input  wire                     s_axil_arvalid,
  output wire                     s_axil_arready,
  output wire [AXIL_DATA_W-1:0]   s_axil_rdata,
  output wire [1:0]               s_axil_rresp,
  output wire                     s_axil_rvalid,
  input  wire                     s_axil_rready,

  input  wire                     seg_clk,
  input  wire                     seg_rstn,
  input  wire                     rx_overflow,
  input  wire                     rx_trunc,
  input  wire                     tx_cpl_overflow,
  input  wire [31:0]              rx_err_frames,
  input  wire [31:0]              rx_drop_frames
);

  localparam logic [5:0] A_ID      = 6'h00 >> 2, A_VERSION = 6'h04 >> 2;
  localparam logic [5:0] A_SCRATCH = 6'h08 >> 2, A_CAPS    = 6'h0C >> 2;
  localparam logic [5:0] A_STICKY  = 6'h10 >> 2, A_RXERR   = 6'h14 >> 2;
  localparam logic [5:0] A_RXDROP  = 6'h18 >> 2, A_CTL     = 6'h1C >> 2;
  localparam logic [5:0] A_ROUNDS  = 6'h20 >> 2;

  logic st_rx_ovf   = 1'b0;
  logic st_rx_trunc = 1'b0;
  logic st_tx_cpl   = 1'b0;

  wire clr_sticky_seg;
  wire clr_count_seg;
  logic clr_sticky_1d = 1'b0;
  logic clr_count_1d  = 1'b0;

  logic [31:0] err_hold = '0;
  logic [31:0] drop_hold = '0;

  always_ff @(posedge seg_clk) begin
    if (!seg_rstn) begin
      st_rx_ovf     <= 1'b0;
      st_rx_trunc   <= 1'b0;
      st_tx_cpl     <= 1'b0;
      clr_sticky_1d <= 1'b0;
      clr_count_1d  <= 1'b0;
      err_hold      <= '0;
      drop_hold     <= '0;
    end else begin
      if (rx_overflow)     st_rx_ovf   <= 1'b1;
      if (rx_trunc)        st_rx_trunc <= 1'b1;
      if (tx_cpl_overflow) st_tx_cpl   <= 1'b1;

      clr_sticky_1d <= clr_sticky_seg;
      clr_count_1d  <= clr_count_seg;

      if (clr_sticky_seg != clr_sticky_1d) begin
        st_rx_ovf   <= 1'b0;
        st_rx_trunc <= 1'b0;
        st_tx_cpl   <= 1'b0;
      end

      if (clr_count_seg != clr_count_1d) begin
        err_hold  <= rx_err_frames;
        drop_hold <= rx_drop_frames;
      end
    end
  end

  localparam int SEG_BITS = 32 + 32 + 3;
  wire [SEG_BITS-1:0] seg_vec = {
    rx_drop_frames - drop_hold,
    rx_err_frames - err_hold,
    st_tx_cpl, st_rx_trunc, st_rx_ovf
  };
  wire [SEG_BITS-1:0] seg_snap;
  wire [7:0]          seg_rounds;

  dcmac_csr_snap #(.WIDTH(SEG_BITS)) u_snap_seg (
    .s_clk  (seg_clk),
    .s_rstn (seg_rstn),
    .din    (seg_vec),
    .m_clk  (axil_aclk),
    .m_rstn (axil_aresetn),
    .dout   (seg_snap),
    .rounds (seg_rounds)
  );

  wire        q_st_rx_ovf   = seg_snap[0];
  wire        q_st_rx_trunc = seg_snap[1];
  wire        q_st_tx_cpl   = seg_snap[2];
  wire [31:0] q_err_frames  = seg_snap[34:3];
  wire [31:0] q_drop_frames = seg_snap[66:35];

  logic [31:0] scratch_r    = '0;
  logic        clr_sticky_r = 1'b0;
  logic        clr_count_r  = 1'b0;

  (* ASYNC_REG = "TRUE" *) logic clr_sticky_s0 = 1'b0, clr_sticky_s1 = 1'b0;
  (* ASYNC_REG = "TRUE" *) logic clr_count_s0  = 1'b0, clr_count_s1  = 1'b0;

  always_ff @(posedge seg_clk) begin
    clr_sticky_s0 <= clr_sticky_r;
    clr_sticky_s1 <= clr_sticky_s0;
    clr_count_s0  <= clr_count_r;
    clr_count_s1  <= clr_count_s0;
  end

  assign clr_sticky_seg = clr_sticky_s1;
  assign clr_count_seg  = clr_count_s1;

  logic aw_hold, w_hold, b_pend, r_pend;
  logic [5:0]  aw_addr_r, ar_addr_r;
  logic [31:0] wdata_r, rdata_r;

  assign s_axil_awready = !aw_hold && !b_pend;
  assign s_axil_wready  = !w_hold  && !b_pend;
  assign s_axil_bvalid  = b_pend;
  assign s_axil_bresp   = 2'b00;
  assign s_axil_arready = !r_pend;
  assign s_axil_rvalid  = r_pend;
  assign s_axil_rresp   = 2'b00;
  assign s_axil_rdata   = rdata_r;

  function automatic [31:0] reg_read(input logic [5:0] a);
    case (a)
      A_ID:      reg_read = ID_VALUE;
      A_VERSION: reg_read = VERSION;
      A_SCRATCH: reg_read = scratch_r;
      A_CAPS:    reg_read = {16'(N_SEG), 16'(SEG_W)};
      A_STICKY:  reg_read = {29'b0, q_st_tx_cpl, q_st_rx_trunc, q_st_rx_ovf};
      A_RXERR:   reg_read = q_err_frames;
      A_RXDROP:  reg_read = q_drop_frames;
      A_CTL:     reg_read = {30'b0, clr_count_r, clr_sticky_r};
      A_ROUNDS:  reg_read = {24'b0, seg_rounds};
      default:   reg_read = 32'h0;
    endcase
  endfunction

  always_ff @(posedge axil_aclk) begin
    if (!axil_aresetn) begin
      aw_hold      <= 1'b0;
      w_hold       <= 1'b0;
      b_pend       <= 1'b0;
      r_pend       <= 1'b0;
      aw_addr_r    <= '0;
      ar_addr_r    <= '0;
      wdata_r      <= '0;
      rdata_r      <= '0;
      scratch_r    <= '0;
      clr_sticky_r <= 1'b0;
      clr_count_r  <= 1'b0;
    end else begin
      if (s_axil_awvalid && s_axil_awready) begin
        aw_addr_r <= s_axil_awaddr[7:2];
        aw_hold   <= 1'b1;
      end
      if (s_axil_wvalid && s_axil_wready) begin
        wdata_r <= s_axil_wdata;
        w_hold  <= 1'b1;
      end

      if (aw_hold && w_hold && !b_pend) begin
        aw_hold <= 1'b0;
        w_hold  <= 1'b0;
        b_pend  <= 1'b1;
        case (aw_addr_r)
          A_SCRATCH: scratch_r <= wdata_r;
          A_CTL: begin
            if (wdata_r[0]) clr_sticky_r <= ~clr_sticky_r;
            if (wdata_r[1]) clr_count_r  <= ~clr_count_r;
          end
          default: ;
        endcase
      end else if (b_pend && s_axil_bready) begin
        b_pend <= 1'b0;
      end

      if (s_axil_arvalid && s_axil_arready) begin
        ar_addr_r <= s_axil_araddr[7:2];
        rdata_r   <= reg_read(s_axil_araddr[7:2]);
        r_pend    <= 1'b1;
      end else if (r_pend && s_axil_rready) begin
        r_pend <= 1'b0;
      end
    end
  end

  wire _unused_axis_csr = (|ar_addr_r) | (|s_axil_wstrb)
                        | (|s_axil_awaddr[AXIL_ADDR_W-1:8])
                        | (|s_axil_araddr[AXIL_ADDR_W-1:8]);

endmodule
