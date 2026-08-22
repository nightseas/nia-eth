// ---------------------------------------------------------------------------
// File        : tb_dcmac_link_csr.sv
// Description : The test bench of the control plane register block, driven over
//               AXI4-Lite.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_dcmac_link_csr;

  localparam int AW = 12;

  logic axil_clk = 0, seg_clk = 0, rx_clk = 0, tx_clk = 0;
  always #2.000ns axil_clk = ~axil_clk;
  always #1.279ns seg_clk  = ~seg_clk;
  always #2.000ns rx_clk   = ~rx_clk;
  always #2.500ns tx_clk   = ~tx_clk;

  logic axil_rstn = 0, seg_rstn = 0, rx_rstn = 0, tx_rstn = 0;

  logic [AW-1:0] awaddr, araddr;
  logic          awvalid, wvalid, bready, arvalid, rready;
  logic [31:0]   wdata, rdata;
  logic [3:0]    wstrb;
  logic          awready, wready, bvalid, arready, rvalid;
  logic [1:0]    bresp, rresp;

  logic        link_up = 0, rx_overflow = 0, rx_trunc = 0, tx_cpl_overflow = 0;
  logic [31:0] rx_err_frames = 0, rx_drop_frames = 0;
  logic [2:0]  mac_fsm_state = 0;
  logic        rx_status = 0, tx_status = 0;
  logic        ctl_link_fault = 0, ctl_access_fault = 0, ctl_seq_busy = 0;
  logic [31:0] ctl_rx_phy_status = 0;
  logic [7:0]  ctl_retry_cnt = 0;
  logic [4:0]  ctl_seq_state = 0;
  logic [15:0] ctl_seq_pc = 0;
  logic [31:0] ctl_stat_rd_data = 0;

  wire [7:0]   ctl_stat_rd_idx;
  wire         ctl_bringup_restart_req, ctl_stats_req, ctl_rx_force_resync_req;
  wire         ctl_rx_datapath_reset_req, ctl_tx_datapath_reset_req;

  dcmac_link_csr #(
    .AXIL_ADDR_W(AW), .AXIL_DATA_W(32),
    .PTP_TS_EN(0), .TX_TAG_W(0), .N_SEG(2), .NPORTS(1)
  ) dut (
    .axil_aclk(axil_clk), .axil_aresetn(axil_rstn),
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
    .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
    .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
    .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
    .seg_clk(seg_clk), .seg_rstn(seg_rstn),
    .link_up(link_up), .rx_overflow(rx_overflow), .rx_trunc(rx_trunc),
    .tx_cpl_overflow(tx_cpl_overflow),
    .rx_err_frames(rx_err_frames), .rx_drop_frames(rx_drop_frames),
    .mac_fsm_state(mac_fsm_state),
    .rx_clk(rx_clk), .rx_rstn(rx_rstn), .rx_status(rx_status),
    .tx_clk(tx_clk), .tx_rstn(tx_rstn), .tx_status(tx_status),
    .ctl_link_fault(ctl_link_fault), .ctl_access_fault(ctl_access_fault),
    .ctl_seq_busy(ctl_seq_busy), .ctl_rx_phy_status(ctl_rx_phy_status),
    .ctl_retry_cnt(ctl_retry_cnt), .ctl_seq_state(ctl_seq_state), .ctl_seq_pc(ctl_seq_pc),
    .ctl_stat_rd_data(ctl_stat_rd_data), .ctl_stat_rd_idx(ctl_stat_rd_idx),
    .ctl_bringup_restart_req(ctl_bringup_restart_req), .ctl_stats_req(ctl_stats_req),
    .ctl_rx_force_resync_req(ctl_rx_force_resync_req),
    .ctl_rx_datapath_reset_req(ctl_rx_datapath_reset_req),
    .ctl_tx_datapath_reset_req(ctl_tx_datapath_reset_req)
  );

  localparam [AW-1:0] O_ID = 12'h000, O_VER = 12'h004, O_SCR = 12'h008, O_CAPS = 12'h00C;
  localparam [AW-1:0] O_STS = 12'h010, O_ERR = 12'h014, O_DROP = 12'h018, O_STICKY = 12'h01C;
  localparam [AW-1:0] O_SEEN = 12'h020, O_LINKEV = 12'h024, O_CTL = 12'h028, O_SEQ = 12'h02C;
  localparam [AW-1:0] O_PHY = 12'h030, O_IDX = 12'h034, O_DATA = 12'h038, O_RND = 12'h03C;
  localparam [AW-1:0] O_OOR = 12'h800;

  int failures = 0, tests = 0;

  task automatic chk(input bit c, input string what);
    if (!c) begin failures++; $display("    CHECK FAIL @%0t : %s", $time, what); end
  endtask

  task automatic chk32(input logic [31:0] got, exp, input string what);
    if (got !== exp) begin
      failures++;
      $display("    CHECK FAIL @%0t : %s (got %08x expected %08x)", $time, what, got, exp);
    end
  endtask

  task automatic axil_write(input [AW-1:0] a, input [31:0] d, input [3:0] strb = 4'hF);
    int guard;
    bit aw_ok, w_ok;
    begin
      @(negedge axil_clk);
      awaddr = a; awvalid = 1'b1; wdata = d; wstrb = strb; wvalid = 1'b1; bready = 1'b1;
      aw_ok = 1'b0; w_ok = 1'b0;
      guard = 0;
      do begin
        @(posedge axil_clk);
        if (awvalid && awready) aw_ok = 1'b1;
        if (wvalid  && wready ) w_ok  = 1'b1;
        @(negedge axil_clk);
        if (aw_ok) awvalid = 1'b0;
        if (w_ok ) wvalid  = 1'b0;
        guard++;
      end while (!(aw_ok && w_ok) && guard < 100);
      chk(guard < 100, $sformatf("axil_write @%03x: AW/W were never accepted", a));
      guard = 0;
      while (!bvalid && guard < 100) begin @(posedge axil_clk); guard++; end
      chk(guard < 100, $sformatf("axil_write @%03x never returned BVALID", a));
      chk(bresp === 2'b00, "axil_write: BRESP not OKAY");
      @(negedge axil_clk);
      bready = 1'b0;
    end
  endtask

  task automatic axil_read(input [AW-1:0] a, output [31:0] d);
    int guard;
    begin
      @(negedge axil_clk);
      araddr = a; arvalid = 1'b1; rready = 1'b1;
      guard = 0;
      do begin
        @(posedge axil_clk);
        guard++;
      end while (!(arvalid && arready) && guard < 100);
      chk(guard < 100, $sformatf("axil_read @%03x: AR was never accepted", a));
      @(negedge axil_clk);
      arvalid = 1'b0;
      guard = 0;
      while (!rvalid && guard < 100) begin @(posedge axil_clk); guard++; end
      chk(guard < 100, $sformatf("axil_read @%03x never returned RVALID", a));
      chk(rresp === 2'b00, "axil_read: RRESP not OKAY");
      d = rdata;
      @(negedge axil_clk);
      rready = 1'b0;
    end
  endtask

  task automatic settle();
    repeat (60) @(posedge axil_clk);
  endtask

  initial begin
    logic [31:0] v, v2;
    int r_seg0, r_tx0, r_rx0;
    int f0;

    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    awaddr = 0; araddr = 0; wdata = 0; wstrb = 4'hF;

    repeat (10) @(posedge axil_clk);
    axil_rstn = 1; seg_rstn = 1; rx_rstn = 1; tx_rstn = 1;
    settle();

    chk(awready === 1'b1 && wready === 1'b1,
        "PRECHECK: AWREADY/WREADY are not high after reset - the slave is absent or held reset");
    chk(arready === 1'b1,
        "PRECHECK: ARREADY is not high after reset - the slave is absent or held in reset");

    tests++;
    begin
      f0 = failures;
      axil_read(O_ID, v);   chk32(v, 32'h4E49_4143, "ID is not \"NIAC\"");
      axil_read(O_VER, v);  chk32(v, 32'h0001_0000, "VERSION");
      $display("TEST 1 id_version %s", (failures == f0) ? "PASS" : "FAIL");
    end

    tests++;
    begin
      f0 = failures;
      axil_write(O_SCR, 32'hDEAD_BEEF);
      axil_read (O_SCR, v);  chk32(v, 32'hDEAD_BEEF, "SCRATCH full-word readback");
      axil_write(O_SCR, 32'h0000_0055, 4'b0001);
      axil_read (O_SCR, v);  chk32(v, 32'hDEAD_BE55, "SCRATCH byte-strobe write");
      $display("TEST 2 scratch_readback %s", (failures == f0) ? "PASS" : "FAIL");
    end

    tests++;
    begin
      f0 = failures;
      axil_read(O_CAPS, v);
      chk32(v, 32'h0102_0000, "CAPS encoding");
      $display("TEST 3 caps %s", (failures == f0) ? "PASS" : "FAIL");
    end

    tests++;
    begin
      f0 = failures;
      axil_read(O_STS, v);
      chk32(v, 32'h0, "STATUS should be all-zero before any stimulus");
      link_up = 1; rx_status = 1; tx_status = 1; mac_fsm_state = 3'd3;
      settle();
      axil_read(O_STS, v);
      chk(v[0] === 1'b1, "STATUS.link_up (seg domain)");
      chk(v[1] === 1'b1, "STATUS.rx_status (rx domain)");
      chk(v[2] === 1'b1, "STATUS.tx_status (tx domain)");
      chk(v[10:8] === 3'd3, "STATUS.mac_fsm_state");
      rx_overflow = 1; rx_trunc = 1; tx_cpl_overflow = 1;
      settle();
      axil_read(O_STS, v);
      chk(v[3] === 1'b1 && v[4] === 1'b1 && v[5] === 1'b1,
          "STATUS overflow/trunc/cpl_overflow");
      $display("TEST 4 status_bits_three_domains %s", (failures == f0) ? "PASS" : "FAIL");
    end

    tests++;
    begin
      f0 = failures;
      rx_err_frames  = 32'h0000_1234;
      rx_drop_frames = 32'h0000_5678;
      settle();
      axil_read(O_ERR,  v);  chk32(v, 32'h0000_1234, "RX_ERR_FRAMES");
      axil_read(O_DROP, v);  chk32(v, 32'h0000_5678, "RX_DROP_FRAMES");
      link_up = 0; settle(); link_up = 1; settle();
      link_up = 0; settle(); link_up = 1; settle();
      axil_read(O_LINKEV, v);
      chk(v[15:0]  === 16'd3, "LINK_EVENTS up count (1 initial + 2 flaps)");
      chk(v[31:16] === 16'd2, "LINK_EVENTS down count");
      rx_err_frames  = 32'hAAAA_0001;
      rx_drop_frames = 32'h5555_0002;
      settle();
      axil_read(O_ERR,  v);
      axil_read(O_DROP, v2);
      chk32(v,  32'hAAAA_0001, "coherent snapshot: RX_ERR_FRAMES");
      chk32(v2, 32'h5555_0002, "coherent snapshot: RX_DROP_FRAMES");
      $display("TEST 5 counters_and_coherence %s", (failures == f0) ? "PASS" : "FAIL");
    end

    tests++;
    begin
      f0 = failures;
      axil_read(O_STICKY, v);
      chk(v[0] === 1'b1, "STICKY.link_down_seen should be latched by the flaps in test 5");
      chk(v[1] === 1'b1, "STICKY.rx_overflow_seen");
      chk(v[2] === 1'b1, "STICKY.rx_trunc_seen");
      chk(v[3] === 1'b1, "STICKY.tx_cpl_overflow_seen");
      rx_overflow = 0; rx_trunc = 0; tx_cpl_overflow = 0;
      settle();
      axil_write(O_STICKY, 32'h0000_000F);
      settle();
      axil_read(O_STICKY, v);
      chk32(v, 32'h0, "STICKY did not clear on W1C");
      rx_overflow = 1;
      settle();
      axil_read(O_STICKY, v);
      chk(v[1] === 1'b1, "STICKY.rx_overflow_seen did not re-latch after a clear");
      rx_overflow = 0;
      settle();
      $display("TEST 6 sticky_latch_and_w1c %s", (failures == f0) ? "PASS" : "FAIL");
    end

    tests++;
    begin
      f0 = failures;
      axil_write(O_SEEN, 32'h0000_001F);
      settle();
      axil_read(O_SEEN, v);
      chk(v[3] === 1'b1, "STATE_SEEN: the current state (3) must re-latch immediately");
      mac_fsm_state = 3'd0; repeat (3) @(posedge seg_clk);
      mac_fsm_state = 3'd1; repeat (3) @(posedge seg_clk);
      mac_fsm_state = 3'd2; repeat (3) @(posedge seg_clk);
      mac_fsm_state = 3'd4; repeat (3) @(posedge seg_clk);
      mac_fsm_state = 3'd3;
      settle();
      axil_read(O_SEEN, v);
      chk32(v, 32'h0000_001F, "STATE_SEEN must show all five states after a fast walk");
      axil_write(O_SEEN, 32'h0000_001F);
      settle();
      axil_read(O_SEEN, v);
      chk32(v, 32'h0000_0008, "after a clear only the CURRENT state (3) should be set");
      $display("TEST 7 state_seen_latch_and_w1c %s", (failures == f0) ? "PASS" : "FAIL");
    end

    tests++;
    begin
      f0 = failures;
      axil_write(O_CTL, 32'h0000_0000);
      settle();
      chk(ctl_rx_datapath_reset_req === 1'b0 && ctl_tx_datapath_reset_req === 1'b0,
          "CTL: both datapath resets should be 0 at rest");
      axil_write(O_CTL, 32'h0000_0008);
      settle();
      chk(ctl_rx_datapath_reset_req === 1'b1, "CTL[3] did not reach ctl_rx_datapath_reset_req");
      chk(ctl_tx_datapath_reset_req === 1'b0,
          "  VIOLATION: a TX datapath reset appeared from an RX-only request");
      axil_write(O_CTL, 32'h0000_0010);
      settle();
      chk(ctl_tx_datapath_reset_req === 1'b1, "CTL[4] did not reach ctl_tx_datapath_reset_req");
      chk(ctl_rx_datapath_reset_req === 1'b0,
          "  VIOLATION: an RX datapath reset appeared from a TX-only request");
      axil_write(O_CTL, 32'h0000_0007);
      settle();
      chk(ctl_bringup_restart_req === 1'b1 && ctl_stats_req === 1'b1 &&
          ctl_rx_force_resync_req === 1'b1, "CTL[2:0] did not reach their outputs");
      axil_read(O_CTL, v);
      chk32(v, 32'h0000_0007, "CTL readback");
      axil_write(O_CTL, 32'h0);
      settle();
      $display("TEST 8 ctl_to_tx_domain_and_w17 %s", (failures == f0) ? "PASS" : "FAIL");
    end

    tests++;
    begin
      f0 = failures;
      ctl_stat_rd_data = 32'hC0DE_0001;
      axil_write(O_IDX, 32'h0000_0021);
      settle();
      chk(ctl_stat_rd_idx === 8'h21, "STAT_IDX did not reach ctl_stat_rd_idx in tx_clk");
      axil_read(O_IDX, v);   chk32(v, 32'h0000_0021, "STAT_IDX readback");
      axil_read(O_DATA, v);  chk32(v, 32'hC0DE_0001, "STAT_DATA");
      ctl_stat_rd_data = 32'hC0DE_0002;
      settle();
      axil_read(O_DATA, v);  chk32(v, 32'hC0DE_0002, "STAT_DATA after a change");
      $display("TEST 9 stat_idx_data_roundtrip %s", (failures == f0) ? "PASS" : "FAIL");
    end

    tests++;
    begin
      f0 = failures;
      axil_read(O_RND, v);
      r_seg0 = v[7:0]; r_tx0 = v[15:8]; r_rx0 = v[23:16];
      settle(); settle();
      axil_read(O_RND, v2);
      chk(v2[7:0]   !== r_seg0[7:0], "SNAP_ROUNDS seg group is not advancing");
      chk(v2[15:8]  !== r_tx0[7:0],  "SNAP_ROUNDS tx group is not advancing");
      chk(v2[23:16] !== r_rx0[7:0],  "SNAP_ROUNDS rx group is not advancing");
      chk(v2[31:24] === 8'h00,       "SNAP_ROUNDS [31:24] is reserved and must read 0");
      ctl_seq_state = 5'd9; ctl_seq_busy = 1; ctl_link_fault = 1; ctl_access_fault = 0;
      ctl_retry_cnt = 8'd7; ctl_seq_pc = 16'h0123; ctl_rx_phy_status = 32'h0000_0001;
      settle();
      axil_read(O_SEQ, v);
      chk32(v, {16'h0123, 8'd7, 1'b0, 1'b1, 1'b1, 5'd9}, "SEQ packing");
      axil_read(O_PHY, v);
      chk32(v, 32'h0000_0001, "RX_PHY_STATUS");
      $display("TEST 10 snap_rounds_liveness_and_seq %s", (failures == f0) ? "PASS" : "FAIL");
    end

    tests++;
    begin
      f0 = failures;
      axil_read(O_OOR, v);
      chk32(v, 32'h0, "an out-of-range read must return 0");
      axil_write(O_OOR, 32'hFFFF_FFFF);
      axil_read(O_SCR, v);
      chk32(v, 32'hDEAD_BE55, "an out-of-range write corrupted SCRATCH");
      $display("TEST 11 out_of_range %s", (failures == f0) ? "PASS" : "FAIL");
    end

    $display("TB_RESULT %s tests=%0d failures=%0d",
             (failures == 0) ? "PASS" : "FAIL", tests, failures);
    if (failures != 0) $fatal(1, "tb_dcmac_link_csr: %0d check(s) failed", failures);
    $finish;
  end

  initial begin
    #2000000ns;
    $display("TB_RESULT FAIL tests=%0d failures=%0d (WATCHDOG: the run hung)",
             tests, failures + 1);
    $fatal(1, "tb_dcmac_link_csr: watchdog expired");
  end
endmodule
