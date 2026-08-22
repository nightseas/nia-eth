// ---------------------------------------------------------------------------
// File        : seg_pack_loop.sv
// Description : A segmented loopback that packs what it receives back onto the transmit
//               side, so a client interface can be exercised with no MAC behind it.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module seg_pack_loop #(
  parameter int N_SEG     = 2,
  parameter int SEG_W     = 128,
  parameter int DEPTH     = 64,
  parameter int IPG_BYTES = 24
)(
  input  logic                       clk,
  input  logic                       rstn,

  input  logic                       s_seg_valid,
  output logic                       s_seg_ready,
  input  logic [N_SEG*SEG_W-1:0]     s_seg_dat,
  input  logic [N_SEG-1:0]           s_seg_ena,
  input  logic [N_SEG-1:0]           s_seg_sop,
  input  logic [N_SEG-1:0]           s_seg_eop,
  input  logic [N_SEG-1:0]           s_seg_err,
  input  logic [N_SEG*4-1:0]         s_seg_mty,

  output logic                       m_seg_valid,
  output logic [N_SEG*SEG_W-1:0]     m_seg_dat,
  output logic [N_SEG-1:0]           m_seg_ena,
  output logic [N_SEG-1:0]           m_seg_sop,
  output logic [N_SEG-1:0]           m_seg_eop,
  output logic [N_SEG-1:0]           m_seg_err,
  output logic [N_SEG*4-1:0]         m_seg_mty
);
  localparam int PW     = $clog2(DEPTH);
  localparam int CNT_W  = $clog2(DEPTH+1);
  localparam int BEAT_B = N_SEG*SEG_W/8;

  logic [SEG_W-1:0] f_dat [DEPTH];
  logic [3:0]       f_mty [DEPTH];
  logic             f_sop [DEPTH];
  logic             f_eop [DEPTH];
  logic             f_err [DEPTH];

  logic [PW-1:0]    wr, rd;
  logic [CNT_W-1:0] cnt;
  logic [15:0]      debt;

  logic [CNT_W-1:0] take;
  logic [CNT_W-1:0] pushed;

  always_comb begin
    pushed = '0;
    if (s_seg_valid && s_seg_ready)
      for (int s = 0; s < N_SEG; s++)
        if (s_seg_ena[s]) pushed = pushed + 1'b1;
  end

  wire pay_gap = (debt >= 16'(BEAT_B));

  always_comb begin
    take = '0;
    if (!pay_gap) begin
      if (int'(cnt) >= N_SEG)
        take = CNT_W'(N_SEG);
      else if (cnt != '0 && f_eop[PW'(rd + PW'(cnt) - PW'(1))])
        take = cnt;
    end
  end

  assign s_seg_ready = (int'(cnt) <= (DEPTH - 2*N_SEG));

  always_ff @(posedge clk) begin
    if (!rstn) begin
      wr          <= '0;
      rd          <= '0;
      cnt         <= '0;
      debt        <= '0;
      m_seg_valid <= 1'b0;
      m_seg_dat   <= '0;
      m_seg_ena   <= '0;
      m_seg_sop   <= '0;
      m_seg_eop   <= '0;
      m_seg_err   <= '0;
      m_seg_mty   <= '0;
    end else begin
      if (s_seg_valid && s_seg_ready) begin
        int n;
        n = 0;
        for (int s = 0; s < N_SEG; s++) begin
          if (s_seg_ena[s]) begin
            f_dat[PW'(wr + PW'(n))] <= s_seg_dat[s*SEG_W +: SEG_W];
            f_sop[PW'(wr + PW'(n))] <= s_seg_sop[s];
            f_eop[PW'(wr + PW'(n))] <= s_seg_eop[s];
            f_err[PW'(wr + PW'(n))] <= s_seg_err[s];
            f_mty[PW'(wr + PW'(n))] <= s_seg_mty[s*4 +: 4];
            n = n + 1;
          end
        end
        wr <= PW'(wr + PW'(n));
      end

      m_seg_valid <= (take != '0);
      m_seg_dat   <= '0;
      m_seg_ena   <= '0;
      m_seg_sop   <= '0;
      m_seg_eop   <= '0;
      m_seg_err   <= '0;
      m_seg_mty   <= '0;
      for (int k = 0; k < N_SEG; k++) begin
        if (k < int'(take)) begin
          m_seg_dat[k*SEG_W +: SEG_W] <= f_dat[PW'(rd + PW'(k))];
          m_seg_ena[k]                <= 1'b1;
          m_seg_sop[k]                <= f_sop[PW'(rd + PW'(k))];
          m_seg_eop[k]                <= f_eop[PW'(rd + PW'(k))];
          m_seg_err[k]                <= f_err[PW'(rd + PW'(k))];
          m_seg_mty[k*4 +: 4]         <= f_mty[PW'(rd + PW'(k))];
        end
      end

      rd  <= PW'(rd + PW'(take));
      cnt <= cnt + pushed - take;

      if (pay_gap) begin
        debt <= debt - 16'(BEAT_B);
      end else if (take != '0) begin
        for (int k = 0; k < N_SEG; k++)
          if (k < int'(take) && f_eop[PW'(rd + PW'(k))]) debt <= debt + 16'(IPG_BYTES);
      end
    end
  end
endmodule
