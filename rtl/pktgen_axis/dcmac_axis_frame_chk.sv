// ---------------------------------------------------------------------------
// File        : dcmac_axis_frame_chk.sv
// Description : The receive checker of the AXI-Stream instrument: predicts the payload of
//               every frame it accepts and counts the frames, the bytes, the error frames
//               and the beats that did not match.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module dcmac_axis_frame_chk #(

  parameter integer DATA_W = 512,
  parameter integer USER_W = 1,
  parameter integer HDR_B  = 42
)(
  input  wire                    clk,
  input  wire                    rstn,

  input  wire                    ctl_clear,
  input  wire                    cfg_hdr_enable,

  input  wire [DATA_W-1:0]       s_axis_tdata,
  input  wire [DATA_W/8-1:0]     s_axis_tkeep,
  input  wire                    s_axis_tvalid,
  input  wire                    s_axis_tlast,
  input  wire [USER_W-1:0]       s_axis_tuser,

  output wire [31:0]             rx_frames,
  output wire [31:0]             rx_bytes,
  output wire [31:0]             rx_err_frames,
  output wire [31:0]             rx_mismatch_beats,
  output wire                    rx_locked
);
  localparam int KEEP_W = DATA_W/8;
  localparam int LANE_W = $clog2(KEEP_W);
  localparam int BEAT_W = 16 - LANE_W;

  logic [BEAT_W-1:0] beat_r;
  logic [31:0]       frames_r;
  logic [31:0]       bytes_r;
  logic [31:0]       err_r;
  logic [31:0]       mis_r;
  logic              in_frame_r;
  logic              err_seen_r;
  logic              locked_r;

  logic [7:0]        cnt_r;
  logic              cnt_v_r;

  wire beat = s_axis_tvalid;

  logic mismatch;
  always_comb begin
    mismatch = 1'b0;
    for (int i = 0; i < KEEP_W; i++) begin
      logic [15:0] idx;
      logic [7:0]  pay;
      logic        skip;
      idx = {beat_r, i[LANE_W-1:0]};
      pay = idx[7:0];
      skip = (i < HDR_B) && cfg_hdr_enable && ~in_frame_r;
      if (s_axis_tkeep[i] && !skip && (s_axis_tdata[i*8 +: 8] != pay)) mismatch = 1'b1;
    end
  end

  logic [7:0] keep_cnt;
  always_comb begin
    keep_cnt = 8'd0;
    for (int i = 0; i < KEEP_W; i++) if (s_axis_tkeep[i]) keep_cnt = keep_cnt + 8'd1;
  end

  always_ff @(posedge clk) begin
    if (!rstn) begin
      beat_r     <= '0;
      frames_r   <= '0;
      bytes_r    <= '0;
      err_r      <= '0;
      mis_r      <= '0;
      in_frame_r <= 1'b0;
      err_seen_r <= 1'b0;
      locked_r   <= 1'b0;
      cnt_r      <= 8'd0;
      cnt_v_r    <= 1'b0;
    end else begin
      if (ctl_clear) begin
        frames_r   <= '0;
        bytes_r    <= '0;
        err_r      <= '0;
        mis_r      <= '0;
        locked_r   <= 1'b0;
        cnt_v_r    <= 1'b0;
      end

      cnt_v_r <= 1'b0;

      if (beat) begin
        if (mismatch && (mis_r != 32'hFFFF_FFFF)) mis_r <= mis_r + 32'd1;

        cnt_r   <= s_axis_tlast ? keep_cnt : 8'(KEEP_W);
        cnt_v_r <= 1'b1;

        if (s_axis_tlast) begin
          beat_r     <= '0;
          in_frame_r <= 1'b0;
          err_seen_r <= 1'b0;
          locked_r   <= 1'b1;
          if (frames_r != 32'hFFFF_FFFF) frames_r <= frames_r + 32'd1;
          if ((s_axis_tuser[0] | err_seen_r) && (err_r != 32'hFFFF_FFFF)) err_r <= err_r + 32'd1;
        end else begin
          beat_r     <= beat_r + 1'b1;
          in_frame_r <= 1'b1;
          err_seen_r <= err_seen_r | s_axis_tuser[0];
        end
      end

      if (cnt_v_r && !ctl_clear) bytes_r <= bytes_r + {24'd0, cnt_r};
    end
  end

  assign rx_frames         = frames_r;
  assign rx_bytes          = bytes_r;
  assign rx_err_frames     = err_r;
  assign rx_mismatch_beats = mis_r;
  assign rx_locked         = locked_r;
endmodule
