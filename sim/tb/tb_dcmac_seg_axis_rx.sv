// ---------------------------------------------------------------------------
// File        : tb_dcmac_seg_axis_rx.sv
// Description : A self checking bench for the receive segment ring. It drives frames as
//               the DCMAC client does, packed back to back so a frame may start at any
//               lane, and it rebuilds every frame from the stream beats and compares.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_dcmac_seg_axis_rx #(
  parameter int N_SEG       = 2,
  parameter int SEG_W       = 128,
  parameter int N_FRAMES    = 64,
  parameter int MAX_LEN     = 1518,
  parameter int READY_GAPS  = 0,
  parameter int SEG_GAPS    = 1,
  parameter int EXPECT_LOSS = 0
)();
  localparam int SEG_B  = SEG_W/8;
  localparam int BEAT_B = N_SEG*SEG_B;

  logic clk = 1'b0;
  logic rstn = 1'b0;

  always #1.28 clk = ~clk;

  logic                     rx_seg_valid;
  logic [N_SEG*SEG_W-1:0]   rx_seg_dat;
  logic [N_SEG-1:0]         rx_seg_ena;
  logic [N_SEG-1:0]         rx_seg_sop;
  logic [N_SEG-1:0]         rx_seg_eop;
  logic [N_SEG-1:0]         rx_seg_err;
  logic [N_SEG*4-1:0]       rx_seg_mty;

  logic [N_SEG*SEG_W-1:0]   m_axis_tdata;
  logic [N_SEG*SEG_B-1:0]   m_axis_tkeep;
  logic                     m_axis_tvalid;
  logic                     m_axis_tready;
  logic                     m_axis_tlast;
  logic                     m_axis_tuser;
  logic                     rx_align_drop;
  logic [31:0]              rx_align_stat;

  dcmac_seg_axis_rx #(
    .N_SEG(N_SEG), .SEG_W(SEG_W), .DATA_W(N_SEG*SEG_W)
  ) dut (
    .clk(clk), .rstn(rstn),
    .rx_seg_valid(rx_seg_valid), .rx_seg_dat(rx_seg_dat), .rx_seg_ena(rx_seg_ena),
    .rx_seg_sop(rx_seg_sop), .rx_seg_eop(rx_seg_eop), .rx_seg_err(rx_seg_err),
    .rx_seg_mty(rx_seg_mty),
    .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
    .m_axis_tlast(m_axis_tlast), .m_axis_tuser(m_axis_tuser),
    .rx_align_drop(rx_align_drop), .rx_align_stat(rx_align_stat)
  );

  int unsigned frame_len [N_FRAMES];
  int unsigned seed = 32'h1234_5678;

  function automatic int unsigned next_rand();
    seed = seed * 32'd1103515245 + 32'd12345;
    return seed >> 16;
  endfunction

  function automatic logic [7:0] frame_byte(input int unsigned f, input int unsigned i);
    return 8'((f * 7) + i * 3 + (i >> 4));
  endfunction

  int unsigned drv_frame;
  int unsigned drv_byte;
  int unsigned drv_done;

  task automatic clear_seg_bus();
    rx_seg_valid = 1'b0;
    rx_seg_dat   = '0;
    rx_seg_ena   = '0;
    rx_seg_sop   = '0;
    rx_seg_eop   = '0;
    rx_seg_err   = '0;
    rx_seg_mty   = '0;
  endtask

  task automatic drive_one_cycle();
    logic [N_SEG*SEG_W-1:0] dat;
    logic [N_SEG-1:0]       ena, sop, eop;
    logic [N_SEG*4-1:0]     mty;
    int unsigned            take;
    int unsigned            rem;

    dat = '0; ena = '0; sop = '0; eop = '0; mty = '0;

    for (int s = 0; s < N_SEG; s++) begin
      if (drv_frame < N_FRAMES) begin
        ena[s] = 1'b1;
        if (drv_byte == 0) sop[s] = 1'b1;
        rem  = frame_len[drv_frame] - drv_byte;
        take = (rem > SEG_B) ? SEG_B : rem;
        for (int b = 0; b < SEG_B; b++)
          if (b < int'(take))
            dat[s*SEG_W + b*8 +: 8] = frame_byte(drv_frame, drv_byte + b);
        if (take == rem) begin
          eop[s]          = 1'b1;
          mty[s*4 +: 4]   = 4'(SEG_B - take);
          drv_frame       = drv_frame + 1;
          drv_byte        = 0;
        end else begin
          drv_byte = drv_byte + take;
        end
      end
    end

    rx_seg_valid = (ena != '0);
    rx_seg_dat   = dat;
    rx_seg_ena   = ena;
    rx_seg_sop   = sop;
    rx_seg_eop   = eop;
    rx_seg_err   = '0;
    rx_seg_mty   = mty;
    @(negedge clk);
    clear_seg_bus();
    if (SEG_GAPS != 0 && (next_rand() % 8) == 0) @(negedge clk);
  endtask

  int unsigned chk_frame;
  int unsigned chk_byte;
  int unsigned errors;
  int unsigned beats_seen;

  task automatic check_beat();
    logic [7:0] got;
    logic [7:0] want;
    int unsigned kept;
    int unsigned stop;

    kept = 0;
    stop = 0;
    for (int i = 0; i < N_SEG*SEG_B; i++) begin
      if (m_axis_tkeep[i]) begin
        kept = kept + 1;
        if (EXPECT_LOSS == 0 && stop == 0) begin
          got  = m_axis_tdata[i*8 +: 8];
          want = frame_byte(chk_frame, chk_byte);
          if (chk_frame >= N_FRAMES) begin
            errors = errors + 1;
            stop   = 1;
            $display("FAIL extra frame beyond %0d", N_FRAMES);
          end else if (chk_byte >= frame_len[chk_frame]) begin
            errors = errors + 1;
            stop   = 1;
            $display("FAIL frame %0d longer than %0d bytes", chk_frame, frame_len[chk_frame]);
          end else if (got !== want) begin
            errors = errors + 1;
            stop   = 1;
            $display("FAIL frame %0d byte %0d got %02x want %02x", chk_frame, chk_byte, got, want);
          end else begin
            chk_byte = chk_byte + 1;
          end
        end
      end
    end
    if (kept == 0) begin
      errors = errors + 1;
      $display("FAIL a beat was offered with no kept byte");
    end
    if (stop == 0) begin
      beats_seen = beats_seen + 1;
      if (m_axis_tlast) begin
        if (EXPECT_LOSS == 0 && chk_byte != frame_len[chk_frame]) begin
          errors = errors + 1;
          $display("FAIL frame %0d length %0d expected %0d", chk_frame, chk_byte,
                   frame_len[chk_frame]);
        end
        chk_frame = chk_frame + 1;
        chk_byte  = 0;
      end else if (kept != N_SEG*SEG_B) begin
        errors = errors + 1;
        $display("FAIL frame %0d non final beat carries %0d of %0d bytes", chk_frame, kept,
                 N_SEG*SEG_B);
      end
    end
  endtask

  initial begin
    clear_seg_bus();
    m_axis_tready = 1'b0;
    drv_frame = 0; drv_byte = 0; drv_done = 0;
    chk_frame = 0; chk_byte = 0; errors = 0; beats_seen = 0;

    for (int f = 0; f < N_FRAMES; f++) begin
      int unsigned l;
      l = 64 + (next_rand() % (MAX_LEN - 63));
      if ((f % 7) == 0) l = 64;
      if ((f % 11) == 0) l = 65;
      if ((f % 13) == 0) l = BEAT_B;
      if ((f % 17) == 0) l = BEAT_B + 1;
      frame_len[f] = l;
    end

    repeat (8) @(negedge clk);
    rstn = 1'b1;
    m_axis_tready = 1'b1;
    repeat (4) @(negedge clk);

    fork
      begin
        while (drv_frame < N_FRAMES) drive_one_cycle();
        drv_done = 1;
      end
      begin
        forever begin
          @(negedge clk);
          if (READY_GAPS != 0) m_axis_tready = ((next_rand() % 4) != 0);
        end
      end
    join_none

    while (chk_frame < N_FRAMES && errors <= 8 && $time < 4000000) begin
      @(negedge clk);
      if (m_axis_tvalid && m_axis_tready) check_beat();
    end

    if (EXPECT_LOSS == 0 && rx_align_drop !== 1'b0) begin
      errors = errors + 1;
      $display("FAIL rx_align_drop asserted with a ring that was never overrun, stat %08x",
               rx_align_stat);
    end

    if (EXPECT_LOSS != 0 && rx_align_drop !== 1'b1) begin
      errors = errors + 1;
      $display("FAIL a starved reader lost frames without rx_align_drop, stat %08x",
               rx_align_stat);
    end

    if (EXPECT_LOSS == 0 && chk_frame != N_FRAMES) begin
      errors = errors + 1;
      $display("FAIL delivered %0d of %0d frames", chk_frame, N_FRAMES);
    end

    if (errors == 0)
      $display("PASS N_SEG=%0d frames=%0d beats=%0d", N_SEG, chk_frame, beats_seen);
    else
      $display("FAILED N_SEG=%0d errors=%0d frames=%0d", N_SEG, errors, chk_frame);
    $finish;
  end
endmodule
