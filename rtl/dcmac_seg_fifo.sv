// ---------------------------------------------------------------------------
// File        : dcmac_seg_fifo.sv
// Description : The segmented data path FIFOs: the synchronous one inside a clock domain
//               and the one that crosses to the stream side.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module dcmac_seg_fifo_sync #(
  parameter int DW                = 288,
  parameter int DEPTH             = 256,
  parameter int PROG_EMPTY_THRESH = 18,
  parameter int PROG_FULL_THRESH  = 128,
  parameter     MEM_STYLE         = "block"
)(
  input  wire          clk,
  input  wire          rst,
  input  wire          wr_en,
  input  wire [DW-1:0] din,
  input  wire          rd_en,
  output wire [DW-1:0] dout,
  output wire          data_valid,
  output wire          empty,
  output wire          full,
  output wire          prog_empty,
  output wire          prog_full,
  output wire          overflow,
  output wire          underflow
);

  localparam int PTR_W = $clog2(DEPTH);
  localparam int CNT_W = $clog2(DEPTH + 1);

  (* ram_style = MEM_STYLE *) reg [DW-1:0] mem [DEPTH-1:0];

  reg [PTR_W-1:0] wr_ptr;
  reg [PTR_W-1:0] rd_ptr;
  reg [CNT_W-1:0] cnt;
  reg             empty_r;
  reg             full_r;
  reg             prog_empty_r;
  reg             prog_full_r;
  reg             overflow_r;
  reg             underflow_r;
  reg [DW-1:0]    mem_q;
  reg [DW-1:0]    dout_r;
  reg [1:0]       vld_pipe;

  wire wr_fire = wr_en & ~full_r;
  wire rd_fire = rd_en & ~empty_r;

  always_ff @(posedge clk) begin
    if (wr_fire) mem[wr_ptr] <= din;
    mem_q <= mem[rd_ptr];
    dout_r <= mem_q;

    vld_pipe <= {vld_pipe[0], rd_fire};

    if (wr_fire) wr_ptr <= (wr_ptr == PTR_W'(DEPTH - 1)) ? '0 : wr_ptr + 1'b1;
    if (rd_fire) rd_ptr <= (rd_ptr == PTR_W'(DEPTH - 1)) ? '0 : rd_ptr + 1'b1;

    cnt <= cnt + CNT_W'(wr_fire) - CNT_W'(rd_fire);

    empty_r      <= (cnt + CNT_W'(wr_fire) - CNT_W'(rd_fire)) == '0;
    full_r       <= (cnt + CNT_W'(wr_fire) - CNT_W'(rd_fire)) == CNT_W'(DEPTH);
    prog_empty_r <= (cnt + CNT_W'(wr_fire) - CNT_W'(rd_fire)) <= CNT_W'(PROG_EMPTY_THRESH);
    prog_full_r  <= (cnt + CNT_W'(wr_fire) - CNT_W'(rd_fire)) >= CNT_W'(PROG_FULL_THRESH);

    overflow_r  <= wr_en & full_r;
    underflow_r <= rd_en & empty_r;

    if (rst) begin
      wr_ptr       <= '0;
      rd_ptr       <= '0;
      cnt          <= '0;
      empty_r      <= 1'b1;
      full_r       <= 1'b0;
      prog_empty_r <= 1'b1;
      prog_full_r  <= 1'b0;
      overflow_r   <= 1'b0;
      underflow_r  <= 1'b0;
      vld_pipe     <= '0;
    end
  end

  assign dout       = dout_r;
  assign data_valid = vld_pipe[1];
  assign empty      = empty_r;
  assign full       = full_r;
  assign prog_empty = prog_empty_r;
  assign prog_full  = prog_full_r;
  assign overflow   = overflow_r;
  assign underflow  = underflow_r;

endmodule

module dcmac_seg_fifo_axis #(
  parameter int DW                = 288,
  parameter int DEPTH             = 16,
  parameter int PROG_EMPTY_THRESH = 8,
  parameter     MEM_STYLE         = "distributed"
)(
  input  wire          clk,
  input  wire          rstn,
  input  wire [DW-1:0] s_axis_tdata,
  input  wire          s_axis_tvalid,
  output wire          s_axis_tready,
  output wire [DW-1:0] m_axis_tdata,
  output wire          m_axis_tvalid,
  input  wire          m_axis_tready,
  output wire          prog_empty
);

  localparam int PTR_W = $clog2(DEPTH);
  localparam int CNT_W = $clog2(DEPTH + 1);

  (* ram_style = MEM_STYLE *) reg [DW-1:0] mem [DEPTH-1:0];

  reg [PTR_W-1:0] wr_ptr;
  reg [PTR_W-1:0] rd_ptr;
  reg [CNT_W-1:0] cnt;

  wire wr_fire = s_axis_tvalid & s_axis_tready;
  wire rd_fire = m_axis_tvalid & m_axis_tready;

  always_ff @(posedge clk) begin
    if (wr_fire) begin
      mem[wr_ptr] <= s_axis_tdata;
      wr_ptr <= (wr_ptr == PTR_W'(DEPTH - 1)) ? '0 : wr_ptr + 1'b1;
    end
    if (rd_fire) rd_ptr <= (rd_ptr == PTR_W'(DEPTH - 1)) ? '0 : rd_ptr + 1'b1;

    cnt <= cnt + CNT_W'(wr_fire) - CNT_W'(rd_fire);

    if (!rstn) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      cnt    <= '0;
    end
  end

  assign s_axis_tready = cnt != CNT_W'(DEPTH);
  assign m_axis_tvalid = cnt != '0;
  assign m_axis_tdata  = mem[rd_ptr];
  assign prog_empty    = cnt <= CNT_W'(PROG_EMPTY_THRESH);

endmodule
