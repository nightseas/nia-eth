// ---------------------------------------------------------------------------
// File        : dcmac_axis_frame_src.sv
// Description : The frame source of the AXI-Stream instrument: one frame per configured
//               length, with the header overlay and the payload counter the checker
//               predicts.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module dcmac_axis_frame_src #(

  parameter integer DATA_W     = 512,
  parameter integer USER_W     = 1,
  parameter integer LEN_MIN_HW = 64,
  parameter integer LEN_MAX_HW = 9018,
  parameter integer HDR_B      = 42
)(
  input  wire                    clk,
  input  wire                    rstn,

  input  wire                    ctl_enable,
  input  wire                    ctl_clear,

  input  wire [15:0]             cfg_len_min,
  input  wire [15:0]             cfg_len_max,
  input  wire [1:0]              cfg_len_mode,
  input  wire [31:0]             cfg_frame_limit,

  input  wire                    cfg_hdr_enable,
  input  wire [HDR_B*8-1:0]      cfg_hdr_bytes,

  output wire [DATA_W-1:0]       m_axis_tdata,
  output wire [DATA_W/8-1:0]     m_axis_tkeep,
  output wire                    m_axis_tvalid,
  input  wire                    m_axis_tready,
  output wire                    m_axis_tlast,
  output wire [USER_W-1:0]       m_axis_tuser,

  output wire [15:0]             len_next,
  output wire [15:0]             len_effective,
  output wire                    len_clamp_sticky,
  output wire [31:0]             tx_frames,
  output wire [31:0]             tx_bytes,
  output wire                    busy,
  output wire                    done
);
  localparam int KEEP_W = DATA_W/8;
  localparam int LANE_W = $clog2(KEEP_W);
  localparam int BEAT_W = 16 - LANE_W;

  localparam logic [1:0] LEN_MODE_RANDOM = 2'd1;

  initial begin
    if (LEN_MIN_HW < 64) begin
      $error("Error: dcmac_axis_frame_src LEN_MIN_HW=%0d is below 64. PG369 p119 and p126 require the minimum frame to be four segments even when aborting, and nothing in the DCMAC pads, so a shorter frame is a protocol violation and not a runt (instance %m)", LEN_MIN_HW);
      $finish;
    end
    if (HDR_B > KEEP_W) begin
      $error("Error: dcmac_axis_frame_src needs the %0d byte header to fit inside one beat of %0d bytes, because the lane comparison against HDR_B is what resolves at elaboration (instance %m)", HDR_B, KEEP_W);
      $finish;
    end
  end

  logic [15:0]       len_r;
  logic [BEAT_W-1:0] beat_last_r;
  logic [KEEP_W-1:0] keep_last_r;
  logic              clamp_r;

  logic [BEAT_W-1:0] beat_r;
  logic [31:0]       frames_r;
  logic [31:0]       frames_left_r;
  logic              limit_en_r;
  logic [31:0]       bytes_r;
  logic              run_r;
  logic              done_r;
  logic              hdr_beat_r;
  logic [15:0]       lfsr_r;
  logic [HDR_B*8-1:0] hdr_r;

  wire xfer      = m_axis_tvalid & m_axis_tready;
  wire last_beat = (beat_r == beat_last_r);
  wire eof       = xfer & last_beat;

  function automatic [BEAT_W-1:0] beat_last_of(input [15:0] len);
    logic [15:0] len_m1;
    len_m1 = len - 16'd1;
    return len_m1[15:LANE_W];
  endfunction

  function automatic [KEEP_W-1:0] keep_last_of(input [15:0] len);
    logic [15:0]       len_m1;
    logic [LANE_W-1:0] last_lane;
    logic [KEEP_W-1:0] keep;
    len_m1    = len - 16'd1;
    last_lane = len_m1[LANE_W-1:0];
    keep      = '0;
    for (int i = 0; i < KEEP_W; i++)
      keep[i] = (i[LANE_W-1:0] <= last_lane);
    return keep;
  endfunction

  wire [15:0] lo_cfg     = (cfg_len_min < 16'(LEN_MIN_HW)) ? 16'(LEN_MIN_HW) :
                           (cfg_len_min > 16'(LEN_MAX_HW)) ? 16'(LEN_MAX_HW) : cfg_len_min;
  wire [15:0] hi_cfg     = (cfg_len_max > 16'(LEN_MAX_HW)) ? 16'(LEN_MAX_HW) : cfg_len_max;
  wire [15:0] hi_eff_cfg = (hi_cfg < lo_cfg) ? lo_cfg : hi_cfg;

  logic [15:0]       bound_lo_r, bound_hi_r;
  logic [15:0]       len_fixed_r, len_fixed_d_r;
  logic [BEAT_W-1:0] beat_last_fixed_r;
  logic [KEEP_W-1:0] keep_last_fixed_r;
  logic              clamp_fixed_r, clamp_fixed_d_r;

  logic [15:0]       len_rand_r, len_rand_d_r;
  logic [BEAT_W-1:0] beat_last_rand_r;
  logic [KEEP_W-1:0] keep_last_rand_r;
  logic              clamp_rand_r, clamp_rand_d_r;

  wire [15:0] fixed_clamped = (cfg_len_min < bound_lo_r) ? bound_lo_r
                            : (cfg_len_min > bound_hi_r) ? bound_hi_r : cfg_len_min;
  wire        fixed_clamp   = (cfg_len_min < bound_lo_r) | (cfg_len_min > bound_hi_r);
  wire [15:0] rand_clamped  = (lfsr_r < bound_lo_r) ? bound_lo_r
                            : (lfsr_r > bound_hi_r) ? bound_hi_r : lfsr_r;
  wire        rand_clamp    = (lfsr_r < bound_lo_r) | (lfsr_r > bound_hi_r);

  always_ff @(posedge clk) begin
    if (!rstn) begin
      bound_lo_r        <= 16'(LEN_MIN_HW);
      bound_hi_r        <= 16'(LEN_MAX_HW);
      len_fixed_r       <= 16'(LEN_MIN_HW);
      len_fixed_d_r     <= 16'(LEN_MIN_HW);
      beat_last_fixed_r <= beat_last_of(16'(LEN_MIN_HW));
      keep_last_fixed_r <= keep_last_of(16'(LEN_MIN_HW));
      clamp_fixed_r     <= 1'b0;
      clamp_fixed_d_r   <= 1'b0;
      len_rand_r        <= 16'(LEN_MIN_HW);
      len_rand_d_r      <= 16'(LEN_MIN_HW);
      beat_last_rand_r  <= beat_last_of(16'(LEN_MIN_HW));
      keep_last_rand_r  <= keep_last_of(16'(LEN_MIN_HW));
      clamp_rand_r      <= 1'b0;
      clamp_rand_d_r    <= 1'b0;
      limit_en_r        <= 1'b0;
      hdr_r             <= '0;
    end else begin
      bound_lo_r        <= lo_cfg;
      bound_hi_r        <= hi_eff_cfg;

      len_fixed_r       <= fixed_clamped;
      clamp_fixed_r     <= fixed_clamp;
      len_fixed_d_r     <= len_fixed_r;
      clamp_fixed_d_r   <= clamp_fixed_r;
      beat_last_fixed_r <= beat_last_of(len_fixed_r);
      keep_last_fixed_r <= keep_last_of(len_fixed_r);

      len_rand_r        <= rand_clamped;
      clamp_rand_r      <= rand_clamp;
      len_rand_d_r      <= len_rand_r;
      clamp_rand_d_r    <= clamp_rand_r;
      beat_last_rand_r  <= beat_last_of(len_rand_r);
      keep_last_rand_r  <= keep_last_of(len_rand_r);

      limit_en_r        <= (cfg_frame_limit != 32'd0);
      hdr_r             <= cfg_hdr_bytes;
    end
  end

  wire               rand_mode = (cfg_len_mode == LEN_MODE_RANDOM);

  wire [15:0]        len_nxt       = rand_mode ? len_rand_d_r      : len_fixed_d_r;
  wire [BEAT_W-1:0]  beat_last_nxt = rand_mode ? beat_last_rand_r  : beat_last_fixed_r;
  wire [KEEP_W-1:0]  keep_last_nxt = rand_mode ? keep_last_rand_r  : keep_last_fixed_r;
  wire               clamp_nx      = rand_mode ? clamp_rand_d_r    : clamp_fixed_d_r;

  wire last_frame = limit_en_r & (frames_left_r == 32'd1);
  wire load       = ctl_enable & ~done_r & (~run_r | eof) & ~(eof & last_frame);

  always_ff @(posedge clk) begin
    if (!rstn) begin
      len_r       <= 16'(LEN_MIN_HW);
      beat_last_r <= '0;
      keep_last_r <= '1;
      clamp_r     <= 1'b0;
      beat_r      <= '0;
      frames_r    <= '0;
      frames_left_r <= '0;
      bytes_r     <= '0;
      run_r       <= 1'b0;
      done_r      <= 1'b0;
      hdr_beat_r  <= 1'b1;
      lfsr_r      <= 16'hACE1;
    end else if (ctl_clear) begin
      frames_r    <= '0;
      frames_left_r <= cfg_frame_limit;
      bytes_r     <= '0;
      clamp_r     <= 1'b0;
      done_r      <= 1'b0;
      beat_r      <= '0;
      run_r       <= 1'b0;
      hdr_beat_r  <= 1'b1;
    end else begin
      if (!run_r) frames_left_r <= cfg_frame_limit;

      if (eof) begin
        frames_r <= frames_r + 32'd1;
        bytes_r  <= bytes_r + {16'd0, len_r};
        if (frames_left_r != 32'd0) frames_left_r <= frames_left_r - 32'd1;
        if (last_frame) begin
          done_r <= 1'b1;
          run_r  <= 1'b0;
        end
      end

      if (load) begin
        len_r       <= len_nxt;
        beat_last_r <= beat_last_nxt;
        keep_last_r <= keep_last_nxt;
        clamp_r     <= clamp_r | clamp_nx;
        beat_r      <= '0;
        hdr_beat_r  <= 1'b1;
        run_r       <= 1'b1;
        lfsr_r      <= {lfsr_r[14:0], lfsr_r[15] ^ lfsr_r[13] ^ lfsr_r[12] ^ lfsr_r[10]};
      end else if (xfer) begin
        hdr_beat_r <= 1'b0;
        if (!last_beat) beat_r <= beat_r + 1'b1;
      end

      if (!ctl_enable) begin
        run_r  <= 1'b0;
        beat_r <= '0;
      end
    end
  end

  logic [DATA_W-1:0] dat;
  always_comb begin
    for (int i = 0; i < KEEP_W; i++) begin
      logic [15:0] idx;
      logic [7:0]  pay;
      idx = {beat_r, i[LANE_W-1:0]};
      pay = idx[7:0];

      if (i < HDR_B) dat[i*8 +: 8] = (cfg_hdr_enable & hdr_beat_r) ? hdr_r[i*8 +: 8] : pay;
      else           dat[i*8 +: 8] = pay;
    end
  end

  assign m_axis_tdata  = dat;
  assign m_axis_tkeep  = last_beat ? keep_last_r : {KEEP_W{1'b1}};
  assign m_axis_tvalid = run_r;
  assign m_axis_tlast  = last_beat;
  assign m_axis_tuser  = '0;

  assign len_next         = len_nxt;
  assign len_effective    = len_r;
  assign len_clamp_sticky = clamp_r;
  assign tx_frames        = frames_r;
  assign tx_bytes         = bytes_r;
  assign busy             = run_r;
  assign done             = done_r;
endmodule
