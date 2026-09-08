// ---------------------------------------------------------------------------
// File        : tb_dcmac_seg_pack.sv
// Description : A bench for the transmit segment packer. The stream side is fed through the
//               store and forward frame FIFO the design places in front of the packer, so
//               the bench presents the packer the same input contract the design does. The
//               segmented side is observed by the cocotb set, which rebuilds every frame
//               from the segments and checks the placement rules.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_dcmac_seg_pack #(
  parameter int N_SEG   = 4,
  parameter int SEG_W   = 128,
  parameter int DATA_W  = 1024,
  parameter int MAX_LEN = 9018,
  parameter int FIFO_AW = 10
)();
  localparam int SEG_B  = SEG_W/8;
  localparam int KEEP_W = DATA_W/8;
  localparam int MAX_FRAME_BEATS = (MAX_LEN + KEEP_W - 1) / KEEP_W;

  logic clk  = 1'b0;
  logic rstn = 1'b0;

  logic [DATA_W-1:0] s_axis_tdata  = '0;
  logic [KEEP_W-1:0] s_axis_tkeep  = '0;
  logic              s_axis_tvalid = 1'b0;
  logic              s_axis_tready;
  logic              s_axis_tlast  = 1'b0;
  logic              s_axis_tuser  = 1'b0;

  logic [DATA_W-1:0] f_axis_tdata;
  logic [KEEP_W-1:0] f_axis_tkeep;
  logic              f_axis_tvalid;
  logic              f_axis_tready;
  logic              f_axis_tlast;
  logic              f_axis_tuser;

  logic                   tx_seg_ready = 1'b1;
  logic                   tx_seg_valid;
  logic [N_SEG*SEG_W-1:0] tx_seg_dat;
  logic [N_SEG-1:0]       tx_seg_ena;
  logic [N_SEG-1:0]       tx_seg_sop;
  logic [N_SEG-1:0]       tx_seg_eop;
  logic [N_SEG-1:0]       tx_seg_err;
  logic [N_SEG*4-1:0]     tx_seg_mty;

  dcmac_axis_frame_fifo #(
    .DATA_W(DATA_W), .KEEP_W(KEEP_W), .USER_W(1), .ADDR_W(FIFO_AW),
    .DROP_BAD_FRAME(1'b0), .FLAG_BAD_FRAME(1'b0), .DROP_WHEN_FULL(1'b0),
    .MAX_FRAME_BEATS(MAX_FRAME_BEATS), .MEM_STYLE("distributed")
  ) u_frame_fifo (
    .clk(clk), .rstn(rstn), .abort(1'b0),
    .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
    .s_axis_tlast(s_axis_tlast), .s_axis_tuser(s_axis_tuser),
    .m_axis_tdata(f_axis_tdata), .m_axis_tkeep(f_axis_tkeep),
    .m_axis_tvalid(f_axis_tvalid), .m_axis_tready(f_axis_tready),
    .m_axis_tlast(f_axis_tlast), .m_axis_tuser(f_axis_tuser),
    .drop_frames(), .overflow()
  );

  dcmac_seg_axis_tx #(.N_SEG(N_SEG), .SEG_W(SEG_W), .DATA_W(DATA_W)) dut (
    .clk(clk), .rstn(rstn),
    .s_axis_tdata(f_axis_tdata), .s_axis_tkeep(f_axis_tkeep),
    .s_axis_tvalid(f_axis_tvalid), .s_axis_tready(f_axis_tready),
    .s_axis_tlast(f_axis_tlast), .s_axis_tuser(f_axis_tuser),
    .tx_seg_ready(tx_seg_ready), .tx_seg_valid(tx_seg_valid),
    .tx_seg_dat(tx_seg_dat), .tx_seg_ena(tx_seg_ena), .tx_seg_sop(tx_seg_sop),
    .tx_seg_eop(tx_seg_eop), .tx_seg_err(tx_seg_err), .tx_seg_mty(tx_seg_mty)
  );

  initial begin
    if ($test$plusargs("dump")) begin
      $dumpfile("tb_dcmac_seg_pack.vcd");
      $dumpvars(0, tb_dcmac_seg_pack);
    end
  end
endmodule
