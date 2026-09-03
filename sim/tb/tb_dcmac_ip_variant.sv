// ---------------------------------------------------------------------------
// File        : tb_dcmac_ip_variant.sv
// Description : The test bench that elaborates a generated IP variant, so a configuration
//               is checked to build before an image depends on it.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ps/1ps

module tb_dcmac_ip_variant;

  localparam int N_SEG      = 2;
  localparam int SEG_W      = 128;
  localparam int DATA_W     = 512;
  localparam int NET_KEEP   = DATA_W/8;
  localparam int SEG_BITS   = N_SEG*SEG_W;
  localparam int SEG_KEEP   = SEG_BITS/8;
  localparam int SEG_B      = SEG_W/8;

  localparam int SEG_HALF   = 1279;
  localparam int TX_HALF    = 2000;
  localparam int RX_HALF_OK = 2000;
  localparam int RX_HALF_SLOW = 20000;

  localparam int MAXB = 9018;
  localparam int MAXF = 32;

  logic seg_clk = 0, tx_clk_i = 0, rx_clk_i = 0;
  int   rx_half = RX_HALF_OK;

  always #(SEG_HALF)  seg_clk  = ~seg_clk;
  always #(TX_HALF)   tx_clk_i = ~tx_clk_i;
  always #(rx_half)   rx_clk_i = ~rx_clk_i;

  logic seg_rstn = 0, tx_rstn = 0, rx_rstn = 0;

  logic                 tx_rst, rx_rst;
  logic [DATA_W-1:0]    s_axis_tx_tdata;
  logic [NET_KEEP-1:0]  s_axis_tx_tkeep;
  logic                 s_axis_tx_tvalid, s_axis_tx_tready, s_axis_tx_tlast;
  logic [0:0]           s_axis_tx_tuser;

  logic                 m_axis_tx_cpl_valid;
  logic [79:0]          m_axis_tx_cpl_ts;
  logic [0:0]           m_axis_tx_cpl_tag;

  logic [DATA_W-1:0]    m_axis_rx_tdata;
  logic [NET_KEEP-1:0]  m_axis_rx_tkeep;
  logic                 m_axis_rx_tvalid, m_axis_rx_tlast;
  logic [0:0]           m_axis_rx_tuser;

  logic                 rx_seg_valid;
  logic [SEG_BITS-1:0]  rx_seg_dat;
  logic [N_SEG-1:0]     rx_seg_ena, rx_seg_sop, rx_seg_eop, rx_seg_err;
  logic [N_SEG*4-1:0]   rx_seg_mty;

  logic                 tx_seg_ready;
  logic                 tx_seg_valid;
  logic [SEG_BITS-1:0]  tx_seg_dat;
  logic [N_SEG-1:0]     tx_seg_ena, tx_seg_sop, tx_seg_eop, tx_seg_err;
  logic [N_SEG*4-1:0]   tx_seg_mty;

  logic                 stat_rx_aligned;
  logic                 link_up, rx_status, tx_status, rx_overflow, rx_trunc, tx_cpl_overflow;
  logic [31:0]          rx_err_frames, rx_drop_frames;
  logic [2:0]           fsm_state;

  tb_dcmac_adapter_link #(
    .N_SEG(N_SEG), .SEG_W(SEG_W), .DATA_W(DATA_W),
    .PTP_TS_EN(0), .PTP_TS_W(80), .TX_TAG_W(0),
    .RX_FIFO_AW(9), .RX_CDC_AW(9), .TX_FIFO_AW(8), .TX_CDC_AW(9), .TX_CPL_AW(4),
    .RX_RESET_CYCLES(16), .PORT_MAX(6), .NPORTS(1), .ANCHOR(0)
  ) dut (
    .seg_clk(seg_clk), .seg_rstn(seg_rstn),
    .tx_clk(tx_clk_i), .tx_rstn(tx_rstn), .rx_clk(rx_clk_i), .rx_rstn(rx_rstn),
    .tx_rst(tx_rst), .rx_rst(rx_rst),
    .s_axis_tx_tdata(s_axis_tx_tdata), .s_axis_tx_tkeep(s_axis_tx_tkeep),
    .s_axis_tx_tvalid(s_axis_tx_tvalid), .s_axis_tx_tready(s_axis_tx_tready),
    .s_axis_tx_tlast(s_axis_tx_tlast), .s_axis_tx_tuser(s_axis_tx_tuser),
    .m_axis_tx_cpl_valid(m_axis_tx_cpl_valid), .m_axis_tx_cpl_ready(1'b1),
    .m_axis_tx_cpl_ts(m_axis_tx_cpl_ts), .m_axis_tx_cpl_tag(m_axis_tx_cpl_tag),
    .m_axis_rx_tdata(m_axis_rx_tdata), .m_axis_rx_tkeep(m_axis_rx_tkeep),
    .m_axis_rx_tvalid(m_axis_rx_tvalid), .m_axis_rx_tlast(m_axis_rx_tlast),
    .m_axis_rx_tuser(m_axis_rx_tuser),
    .seg_ptp_time(80'd0),
    .rx_seg_valid(rx_seg_valid), .rx_seg_dat(rx_seg_dat), .rx_seg_ena(rx_seg_ena),
    .rx_seg_sop(rx_seg_sop), .rx_seg_eop(rx_seg_eop), .rx_seg_err(rx_seg_err),
    .rx_seg_mty(rx_seg_mty),
    .tx_seg_ready(tx_seg_ready), .tx_seg_valid(tx_seg_valid), .tx_seg_dat(tx_seg_dat),
    .tx_seg_ena(tx_seg_ena), .tx_seg_sop(tx_seg_sop), .tx_seg_eop(tx_seg_eop),
    .tx_seg_err(tx_seg_err), .tx_seg_mty(tx_seg_mty),
    .stat_rx_aligned(stat_rx_aligned),
    .rx_datapath_reset_req(1'b0), .tx_datapath_reset_req(1'b0), .rx_force_resync_req(1'b0),
    .ctl_rx_enable(), .ctl_rx_force_resync(), .ctl_tx_enable(), .ctl_tx_send_idle(),
    .ctl_tx_send_lfi(), .ctl_tx_send_rfi(),
    .rx_datapath_reset(), .tx_datapath_reset(), .rx_datapath_reset_ports(),
    .fsm_state(fsm_state),
    .link_up(link_up), .rx_status(rx_status), .tx_status(tx_status),
    .rx_overflow(rx_overflow), .rx_trunc(rx_trunc),
    .rx_err_frames(rx_err_frames), .rx_drop_frames(rx_drop_frames),
    .tx_cpl_overflow(tx_cpl_overflow)
  );

  int failures = 0;
  int tests    = 0;

  task automatic chk(input bit cond, input string what);
    if (!cond) begin
      failures++;
      $display("    CHECK FAIL @%0t : %s", $time, what);
    end
  endtask

  task automatic bringup();
    begin
      seg_rstn = 0; tx_rstn = 0; rx_rstn = 0; stat_rx_aligned = 0;
      s_axis_tx_tvalid = 0; s_axis_tx_tlast = 0; s_axis_tx_tuser = 0;
      s_axis_tx_tdata = '0; s_axis_tx_tkeep = '0;
      rx_seg_valid = 0; rx_seg_ena = '0; rx_seg_sop = '0; rx_seg_eop = '0;
      rx_seg_err = '0; rx_seg_mty = '0; rx_seg_dat = '0;
      repeat (20) @(posedge seg_clk);
      seg_rstn = 1; tx_rstn = 1; rx_rstn = 1;
      repeat (10) @(posedge seg_clk);
      stat_rx_aligned = 1;
      begin
        int guard = 0;
        while (!link_up && guard < 1000) begin @(posedge seg_clk); guard++; end
        chk(link_up === 1'b1, "bring-up: link_up never asserted");
      end
      repeat (20) @(posedge tx_clk_i);
    end
  endtask

  byte unsigned tx_exp_d [0:MAXF-1][0:MAXB-1];
  int           tx_exp_len [0:MAXF-1];
  bit           tx_exp_err [0:MAXF-1];
  int           tx_sent = 0;

  task automatic tx_send(input int len, input int abort_beat, input int gap);
    int nbeats, b, i, idx;
    logic [DATA_W-1:0]   d;
    logic [NET_KEEP-1:0] k;
    begin
      nbeats = (len + NET_KEEP - 1) / NET_KEEP;
      tx_exp_len[tx_sent] = len;
      tx_exp_err[tx_sent] = (abort_beat >= 0);
      for (i = 0; i < len; i++)
        tx_exp_d[tx_sent][i] = byte'((tx_sent * 7 + i * 3 + 1) & 8'hFF);

      for (b = 0; b < nbeats; b++) begin
        d = '0; k = '0;
        for (i = 0; i < NET_KEEP; i++) begin
          idx = b * NET_KEEP + i;
          if (idx < len) begin
            d[i*8 +: 8] = tx_exp_d[tx_sent][idx];
            k[i]        = 1'b1;
          end
        end
        @(posedge tx_clk_i);
        s_axis_tx_tdata  <= d;
        s_axis_tx_tkeep  <= k;
        s_axis_tx_tlast  <= (b == nbeats-1);
        s_axis_tx_tuser  <= (b == abort_beat);
        s_axis_tx_tvalid <= 1'b1;
        @(posedge tx_clk_i);
        while (!s_axis_tx_tready) @(posedge tx_clk_i);
        s_axis_tx_tvalid <= 1'b0;
        s_axis_tx_tlast  <= 1'b0;
        s_axis_tx_tuser  <= 1'b0;
        if (gap > 0) repeat (gap) @(posedge tx_clk_i);
      end
      tx_sent++;
    end
  endtask

  byte unsigned mon_d [0:MAXF-1][0:MAXB-1];
  int           mon_len [0:MAXF-1];
  bit           mon_err [0:MAXF-1];
  int           mon_frames = 0;
  bit           mon_enable = 0;
  int           w7_violations = 0;
  int           err_misplaced = 0;
  int           capture_overflow = 0;

  bit  in_frame = 0;
  int  cur_len  = 0;
  bit  cur_err  = 0;

  always_ff @(posedge seg_clk) begin
    int s, i, nbytes;
    logic [3:0] mty_s;
    if (!seg_rstn) begin
      in_frame = 0; cur_len = 0; cur_err = 0;
    end else if (mon_enable) begin
      if (in_frame && !tx_seg_valid) begin
        w7_violations = w7_violations + 1;
        $display("     VIOLATION @%0t: tx_seg_valid dropped mid-frame", $time);
      end
      if (tx_seg_valid && tx_seg_ready) begin
        if (|tx_seg_sop) begin cur_len = 0; cur_err = 0; end
        for (s = 0; s < N_SEG; s++) begin
          if (tx_seg_ena[s]) begin
            mty_s  = tx_seg_mty[s*4 +: 4];
            nbytes = tx_seg_eop[s] ? (SEG_B - int'(mty_s)) : SEG_B;
            for (i = 0; i < nbytes; i++) begin
              if (mon_frames < MAXF && (cur_len + i) < MAXB)
                mon_d[mon_frames][cur_len + i] = tx_seg_dat[(s*SEG_B + i)*8 +: 8];
              else if (mon_frames < MAXF)
                capture_overflow = capture_overflow + 1;
            end
            cur_len = cur_len + nbytes;
            if (tx_seg_err[s] && !tx_seg_eop[s]) begin
              err_misplaced = err_misplaced + 1;
  $display("  VIOLATION @%0t: err on a NON-EOP segment %0d", $time, s);
            end
            if (tx_seg_err[s] && tx_seg_eop[s]) cur_err = 1'b1;
          end
        end
        if (|(tx_seg_eop & tx_seg_ena)) begin
          if (mon_frames < MAXF) begin
            mon_len[mon_frames] = cur_len;
            mon_err[mon_frames] = cur_err;
          end
          mon_frames = mon_frames + 1;
          in_frame   = 0;
        end else begin
          in_frame = 1;
        end
      end
    end
  end

  int  bp_mode = 0;
  logic [8:0] bp_lfsr = 9'h1FF;

  always_ff @(posedge seg_clk) begin
    if (!seg_rstn) begin
      tx_seg_ready <= 1'b1;
      bp_lfsr      <= 9'h1FF;
    end else begin
      bp_lfsr <= {bp_lfsr[7:0], bp_lfsr[8] ^ bp_lfsr[4]};
      case (bp_mode)
        0: tx_seg_ready <= 1'b1;
        1: tx_seg_ready <= ~tx_seg_ready;
        default: tx_seg_ready <= (bp_lfsr[2:0] != 3'b000);
      endcase
    end
  end

  task automatic tx_check(input string tag);
    int f, i;
    begin
      chk(w7_violations == 0, {tag, ":  - tx_seg_valid dropped mid-frame"});
  chk(err_misplaced == 0, {tag, ":  - err on a non-EOP segment"});
      chk(mon_frames == tx_sent, {tag, ": frame count mismatch at the MAC client"});
      for (f = 0; f < tx_sent && f < mon_frames; f++) begin
        if (mon_len[f] != tx_exp_len[f]) begin
          failures++;
          $display("    LEN FAIL frame %0d: got %0d expected %0d", f, mon_len[f], tx_exp_len[f]);
        end else begin
          for (i = 0; i < tx_exp_len[f]; i++)
            if (mon_d[f][i] !== tx_exp_d[f][i]) begin
              failures++;
              $display("    DATA FAIL frame %0d byte %0d: got %02x expected %02x",
                       f, i, mon_d[f][i], tx_exp_d[f][i]);
              i = tx_exp_len[f];
            end
        end
        if (mon_err[f] !== tx_exp_err[f]) begin
          failures++;
  $display("  FAIL frame %0d: err at EOP = %0b, expected %0b",
                   f, mon_err[f], tx_exp_err[f]);
        end
      end
    end
  endtask

  task automatic tx_reset_counters();
    begin
      tx_sent = 0; mon_frames = 0; w7_violations = 0; err_misplaced = 0;
    end
  endtask

  byte unsigned rx_exp_d [0:MAXF-1][0:MAXB-1];
  int           rx_exp_len [0:MAXF-1];
  bit           rx_exp_err [0:MAXF-1];
  int           rx_sent = 0;

  task automatic rx_push(input int len, input int err_beat, input int err_seg);
    int nbeats, b, s, i, idx, rem, nb;
    begin
      nbeats = (len + SEG_KEEP - 1) / SEG_KEEP;
      rx_exp_len[rx_sent] = len;
      rx_exp_err[rx_sent] = (err_beat >= 0);
      for (i = 0; i < len; i++)
        rx_exp_d[rx_sent][i] = byte'((rx_sent * 11 + i * 5 + 3) & 8'hFF);

      for (b = 0; b < nbeats; b++) begin
        @(posedge seg_clk);
        rx_seg_dat <= '0; rx_seg_ena <= '0; rx_seg_sop <= '0; rx_seg_eop <= '0;
        rx_seg_err <= '0; rx_seg_mty <= '0;
        for (s = 0; s < N_SEG; s++) begin
          rem = len - (b*SEG_KEEP + s*SEG_B);
          if (rem > 0) begin
            nb = (rem > SEG_B) ? SEG_B : rem;
            rx_seg_ena[s] <= 1'b1;
            for (i = 0; i < nb; i++) begin
              idx = b*SEG_KEEP + s*SEG_B + i;
              rx_seg_dat[(s*SEG_B + i)*8 +: 8] <= rx_exp_d[rx_sent][idx];
            end
            if (b == 0 && s == 0) rx_seg_sop[s] <= 1'b1;
            if (rem <= SEG_B) begin
              rx_seg_eop[s] <= 1'b1;
              rx_seg_mty[s*4 +: 4] <= 4'(SEG_B - nb);
            end
            if (b == err_beat && s == err_seg) rx_seg_err[s] <= 1'b1;
          end
        end
        rx_seg_valid <= 1'b1;
      end
      @(posedge seg_clk);
      rx_seg_valid <= 1'b0;
      rx_seg_ena   <= '0;
      rx_seg_sop   <= '0;
      rx_seg_eop   <= '0;
      rx_seg_err   <= '0;
      rx_sent++;
    end
  endtask

  byte unsigned rxm_d [0:MAXF-1][0:MAXB-1];
  int           rxm_len [0:MAXF-1];
  bit           rxm_err [0:MAXF-1];
  int           rxm_frames = 0;
  int           rx_user_early = 0;
  int           rxs_len = 0;
  bit           rx_sink_en = 0;

  always_ff @(posedge rx_clk_i) begin
    int i, nb;
    if (!rx_rstn) begin
      rxs_len = 0;
    end else if (rx_sink_en && m_axis_rx_tvalid) begin
      nb = 0;
      for (i = 0; i < NET_KEEP; i++) if (m_axis_rx_tkeep[i]) nb = i + 1;
      for (i = 0; i < nb; i++)
        if (rxm_frames < MAXF && (rxs_len + i) < MAXB)
          rxm_d[rxm_frames][rxs_len + i] = m_axis_rx_tdata[i*8 +: 8];
        else if (rxm_frames < MAXF)
          capture_overflow = capture_overflow + 1;
      if (!m_axis_rx_tlast && m_axis_rx_tuser[0]) begin
        rx_user_early = rx_user_early + 1;
  $display("  VIOLATION @%0t: rx tuser[0] set on a non-last beat", $time);
      end
      if (m_axis_rx_tlast) begin
        if (rxm_frames < MAXF) begin
          rxm_len[rxm_frames] = rxs_len + nb;
          rxm_err[rxm_frames] = m_axis_rx_tuser[0];
        end
        rxm_frames = rxm_frames + 1;
        rxs_len    = 0;
      end else begin
        rxs_len = rxs_len + nb;
      end
    end
  end

  initial begin
    int f, i, delivered;

  $display("=== tb_dcmac_ip_variant: re-earning  and  against the axis_data_fifo IP variant");

    tests++;
    bringup();
    tx_reset_counters();
    mon_enable = 1; bp_mode = 1;
    tx_send(64,   -1, 0);
    tx_send(128,  -1, 3);
    tx_send(1514, -1, 5);
    tx_send(65,   -1, 1);
    repeat (4000) @(posedge seg_clk);
    tx_check("TEST1/");
    $display("TEST 1 w7_gapless_with_bubbles %s (w7_violations=%0d frames=%0d)",
             (failures == 0) ? "PASS" : "FAIL", w7_violations, mon_frames);

    tests++;
    begin
      int f0 = failures;
      bringup();
      tx_reset_counters();
      mon_enable = 1; bp_mode = 0;
      tx_send(64,  0, 0);
      tx_send(256, 3, 0);
      tx_send(128, -1, 0);
      repeat (3000) @(posedge seg_clk);
  tx_check("TEST2/-last");
      $display("TEST 2 ns8a_abort_last_beat %s", (failures == f0) ? "PASS" : "FAIL");
    end

    tests++;
    begin
      int f0 = failures;
      bringup();
      tx_reset_counters();
      mon_enable = 1; bp_mode = 2;
      tx_send(512, 0, 0);
      tx_send(512, 4, 2);
      tx_send(320, 1, 0);
      tx_send(128, -1, 0);
      repeat (4000) @(posedge seg_clk);
  tx_check("TEST3/-mid");
      $display("TEST 3 ns8a_abort_mid_frame %s", (failures == f0) ? "PASS" : "FAIL");
    end

    tests++;
    begin
      int f0 = failures;
      rx_half = RX_HALF_OK;
      bringup();
      rxm_frames = 0; rx_sent = 0; rx_user_early = 0; rx_sink_en = 1;
      rx_push(128, -1, -1);
      rx_push(256,  1,  0);
      rx_push(256,  2,  1);
      rx_push(64,   0,  0);
      repeat (2000) @(posedge seg_clk);
      repeat (200) @(posedge rx_clk_i);
  chk(rx_user_early == 0, "TEST4/: tuser[0] set before tlast");
  chk(rxm_frames == rx_sent, "TEST4/: an errored frame was DROPPED, not delivered");
  chk(rx_drop_frames == 32'd0, "TEST4/: rx_drop_frames moved - errors must not drop");
      for (f = 0; f < rx_sent && f < rxm_frames; f++) begin
        if (rxm_len[f] != rx_exp_len[f]) begin
          failures++;
          $display("    RX LEN FAIL frame %0d: got %0d expected %0d",
                   f, rxm_len[f], rx_exp_len[f]);
        end else begin
          for (i = 0; i < rx_exp_len[f]; i++)
            if (rxm_d[f][i] !== rx_exp_d[f][i]) begin
              failures++;
              $display("    RX DATA FAIL frame %0d byte %0d", f, i);
              i = rx_exp_len[f];
            end
        end
        if (rxm_err[f] !== rx_exp_err[f]) begin
          failures++;
  $display("  FAIL frame %0d: tuser[0] at tlast = %0b, expected %0b",
                   f, rxm_err[f], rx_exp_err[f]);
        end
      end
      $display("TEST 4 ns4_rx_err_flagged_and_forwarded %s (frames=%0d err_frames=%0d)",
               (failures == f0) ? "PASS" : "FAIL", rxm_frames, rx_err_frames);
    end

    tests++;
    begin
      int f0 = failures;
      rx_half = RX_HALF_SLOW;
      bringup();
      rxm_frames = 0; rx_sent = 0; rx_user_early = 0; rx_sink_en = 1;
      for (i = 0; i < 24; i++) rx_push(1024, -1, -1);
      repeat (4000) @(posedge seg_clk);
      repeat (2000) @(posedge rx_clk_i);
  chk(rx_drop_frames > 32'd0, "TEST5/: nothing was dropped - the test is VACUOUS");
  chk(rx_overflow === 1'b1, "TEST5/: rx_overflow did not go sticky (11.1.7)");
      delivered = rxm_frames;
  chk(delivered > 0, "TEST5/: no frame survived at all");
      for (f = 0; f < delivered && f < MAXF; f++)
        if (rxm_len[f] != 1024) begin
          failures++;
  $display("  FAIL frame %0d TRUNCATED: len=%0d expected 1024", f, rxm_len[f]);
          f = delivered;
        end
      $display("TEST 5 ns7_whole_frame_drop_slow_rxclk %s (delivered=%0d dropped=%0d ovf=%0b)",
               (failures == f0) ? "PASS" : "FAIL", delivered, rx_drop_frames, rx_overflow);
      rx_half = RX_HALF_OK;
    end

    chk(capture_overflow == 0,
        "a captured frame exceeded MAXB, so the comparison would have run against truncated data");

    $display("TB_RESULT %s tests=%0d failures=%0d capture_overflow=%0d",
             (failures == 0) ? "PASS" : "FAIL", tests, failures, capture_overflow);
    if (failures != 0) $fatal(1, "tb_dcmac_ip_variant: %0d check(s) failed", failures);
    $finish;
  end

  initial begin
    #500_000_000;
    $display("TB_RESULT FAIL tests=%0d failures=%0d (WATCHDOG: the run hung)",
             tests, failures + 1);
    $fatal(1, "tb_dcmac_ip_variant: watchdog expired");
  end
endmodule
