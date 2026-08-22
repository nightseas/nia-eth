// ---------------------------------------------------------------------------
// File        : dcmac_link_csr.sv
// Description : The register block of the control plane: its identity, the link status
//               and its latched form, the sequencer state, the statistics window and the
//               runtime watchdog period.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps



module dcmac_link_csr #(
  parameter int AXIL_ADDR_W = 12,
  parameter int AXIL_DATA_W = 32,

  parameter int PTP_TS_EN   = 0,
  parameter int TX_TAG_W    = 0,
  parameter int N_SEG       = 2,
  parameter int NPORTS      = 1,

  parameter logic [7:0] STAT_IDX_MAX = 8'd255,

  parameter int N_GROUP         = 1,

  parameter int LINK_WDT_MS     = 750,
  parameter int LINK_WDT_MS_MIN = 10,
  parameter int LINK_WDT_MS_MAX = 60000
)(

  input  wire                    axil_aclk,
  input  wire                    axil_aresetn,
  input  wire [AXIL_ADDR_W-1:0]  s_axil_awaddr,
  input  wire                    s_axil_awvalid,
  output wire                    s_axil_awready,
  input  wire [AXIL_DATA_W-1:0]  s_axil_wdata,
  input  wire [AXIL_DATA_W/8-1:0] s_axil_wstrb,
  input  wire                    s_axil_wvalid,
  output wire                    s_axil_wready,
  output wire [1:0]              s_axil_bresp,
  output wire                    s_axil_bvalid,
  input  wire                    s_axil_bready,
  input  wire [AXIL_ADDR_W-1:0]  s_axil_araddr,
  input  wire                    s_axil_arvalid,
  output wire                    s_axil_arready,
  output wire [AXIL_DATA_W-1:0]  s_axil_rdata,
  output wire [1:0]              s_axil_rresp,
  output wire                    s_axil_rvalid,
  input  wire                    s_axil_rready,

  input  wire                    seg_clk,
  input  wire                    seg_rstn,
  input  wire                    link_up,
  input  wire [2:0]              mac_fsm_state,

  input  wire                    rx_clk,
  input  wire                    rx_rstn,
  input  wire                    rx_status,

  input  wire                    tx_clk,
  input  wire                    tx_rstn,
  input  wire                    tx_status,
  input  wire                    ctl_link_fault,
  input  wire                    ctl_access_fault,
  input  wire                    ctl_seq_busy,
  input  wire [31:0]             ctl_rx_phy_status,
  input  wire [7:0]              ctl_retry_cnt,
  input  wire [4:0]              ctl_seq_state,
  input  wire [15:0]             ctl_seq_pc,
  input  wire [31:0]             ctl_stat_rd_data,
  output wire [7:0]              ctl_stat_rd_idx,

  output wire                    ctl_bringup_restart_req,
  output wire                    ctl_stats_req,
  output wire                    ctl_rx_force_resync_req,
  output wire                    ctl_rx_datapath_reset_req,
  output wire                    ctl_tx_datapath_reset_req,

  output wire [16*N_GROUP-1:0]   link_wdt_ms
);

  localparam logic [5:0] A_ID       = 6'h00 >> 2, A_VERSION  = 6'h04 >> 2;
  localparam logic [5:0] A_SCRATCH  = 6'h08 >> 2, A_CAPS     = 6'h0C >> 2;
  localparam logic [5:0] A_STATUS   = 6'h10 >> 2, A_STICKY   = 6'h1C >> 2;
  localparam logic [5:0] A_STSEEN   = 6'h20 >> 2, A_LINKEV   = 6'h24 >> 2;
  localparam logic [5:0] A_CTL      = 6'h28 >> 2, A_SEQ      = 6'h2C >> 2;
  localparam logic [5:0] A_RXPHY    = 6'h30 >> 2, A_STATIDX  = 6'h34 >> 2;
  localparam logic [5:0] A_STATDATA = 6'h38 >> 2, A_ROUNDS   = 6'h3C >> 2;

  localparam logic [5:0] A_WDT0     = 6'((12'h040) >> 2);

  initial begin
    if (N_GROUP < 1 || N_GROUP > 6)
      $fatal(1, "dcmac_link_csr: N_GROUP must be 1..6 (got %0d)", N_GROUP);
    if (LINK_WDT_MS_MIN < 1 || LINK_WDT_MS_MAX > 65535 || LINK_WDT_MS_MIN > LINK_WDT_MS_MAX)
      $fatal(1, "dcmac_link_csr: LINK_WDT_MS_MIN/MAX = %0d/%0d is not a legal range",
             LINK_WDT_MS_MIN, LINK_WDT_MS_MAX);

    if (LINK_WDT_MS < LINK_WDT_MS_MIN || LINK_WDT_MS > LINK_WDT_MS_MAX)
      $fatal(1, "dcmac_link_csr: LINK_WDT_MS=%0d outside [%0d,%0d]",
             LINK_WDT_MS, LINK_WDT_MS_MIN, LINK_WDT_MS_MAX);
  end

  logic        seg_link_1d      = 1'b0;
  logic        st_link_down     = 1'b0;
  logic [4:0]  st_state_seen    = 5'b0;
  logic [15:0] cnt_link_up      = 16'd0;
  logic [15:0] cnt_link_down    = 16'd0;

  wire        clr_sticky_tgl_seg;
  wire        clr_stseen_tgl_seg;
  logic       clr_sticky_1d = 1'b0;
  logic       clr_stseen_1d = 1'b0;

  always_ff @(posedge seg_clk) begin
    if (!seg_rstn) begin
      seg_link_1d   <= 1'b0; st_link_down <= 1'b0;
      st_state_seen <= 5'b0;
      cnt_link_up   <= 16'd0; cnt_link_down <= 16'd0;
      clr_sticky_1d <= 1'b0; clr_stseen_1d <= 1'b0;
    end else begin
      seg_link_1d <= link_up;
      if (link_up && !seg_link_1d && cnt_link_up   != 16'hFFFF) cnt_link_up   <= cnt_link_up + 1'b1;
      if (!link_up && seg_link_1d && cnt_link_down != 16'hFFFF) cnt_link_down <= cnt_link_down + 1'b1;

      if (mac_fsm_state <= 3'd4) st_state_seen[mac_fsm_state] <= 1'b1;

      if (!link_up && seg_link_1d) st_link_down  <= 1'b1;

      clr_sticky_1d <= clr_sticky_tgl_seg;
      clr_stseen_1d <= clr_stseen_tgl_seg;
      if (clr_sticky_tgl_seg != clr_sticky_1d) begin
        st_link_down <= 1'b0;
      end
      if (clr_stseen_tgl_seg != clr_stseen_1d) st_state_seen <= 5'b0;
    end
  end

  localparam int SEG_W_BITS = 16 + 16 + 5 + 1 + 3 + 1;
  wire [SEG_W_BITS-1:0] seg_vec = {
    cnt_link_down,
    cnt_link_up,
    st_state_seen,
    st_link_down,
    mac_fsm_state,
    link_up
  };
  wire [SEG_W_BITS-1:0] seg_snap;
  wire [7:0]            seg_rounds;

  dcmac_csr_snap #(.WIDTH(SEG_W_BITS)) u_snap_seg (
    .s_clk(seg_clk), .s_rstn(seg_rstn), .din(seg_vec),
    .m_clk(axil_aclk), .m_rstn(axil_aresetn), .dout(seg_snap), .rounds(seg_rounds)
  );

  wire        q_link_up        = seg_snap[0];
  wire [2:0]  q_fsm_state      = seg_snap[3:1];
  wire        q_st_link_down   = seg_snap[4];
  wire [4:0]  q_state_seen     = seg_snap[9:5];
  wire [15:0] q_cnt_link_up    = seg_snap[25:10];
  wire [15:0] q_cnt_link_down  = seg_snap[41:26];

  wire       q_rx_status;
  wire [7:0] rx_rounds;
  dcmac_csr_snap #(.WIDTH(1)) u_snap_rx (
    .s_clk(rx_clk), .s_rstn(rx_rstn), .din(rx_status),
    .m_clk(axil_aclk), .m_rstn(axil_aresetn), .dout(q_rx_status), .rounds(rx_rounds)
  );

  localparam int TX_W_BITS = 1 + 1 + 1 + 1 + 32 + 8 + 5 + 16 + 32;
  wire [TX_W_BITS-1:0] tx_vec = {
    ctl_stat_rd_data,
    ctl_seq_pc,
    ctl_retry_cnt,
    ctl_rx_phy_status,
    ctl_seq_state,
    ctl_access_fault, ctl_link_fault, ctl_seq_busy, tx_status
  };
  wire [TX_W_BITS-1:0] tx_snap;
  wire [7:0]           tx_rounds;
  dcmac_csr_snap #(.WIDTH(TX_W_BITS)) u_snap_tx (
    .s_clk(tx_clk), .s_rstn(tx_rstn), .din(tx_vec),
    .m_clk(axil_aclk), .m_rstn(axil_aresetn), .dout(tx_snap), .rounds(tx_rounds)
  );

  wire        q_tx_status   = tx_snap[0];
  wire        q_seq_busy    = tx_snap[1];
  wire        q_link_fault  = tx_snap[2];
  wire        q_acc_fault   = tx_snap[3];
  wire [4:0]  q_seq_state   = tx_snap[8:4];
  wire [31:0] q_rx_phy      = tx_snap[40:9];
  wire [7:0]  q_retry       = tx_snap[48:41];
  wire [15:0] q_seq_pc      = tx_snap[64:49];
  wire [31:0] q_stat_data   = tx_snap[96:65];

  logic [31:0] scratch_r    = 32'h0;
  logic [4:0]  ctl_r        = 5'h0;
  logic [7:0]  stat_idx_r   = 8'h0;
  logic        clr_sticky_r = 1'b0;
  logic        clr_stseen_r = 1'b0;

  localparam logic [7:0] STATS_PER = 8'd22;

  wire       idx_oor_now      = (stat_idx_r > STAT_IDX_MAX);
  logic      idx_oor_sticky_r = 1'b0;

  logic [15:0] wdt_req_r    [0:5];
  logic        wdt_clamp_st [0:5];

  function automatic [15:0] wdt_clamp(input logic [15:0] req);
    if (req == 16'd0)                     wdt_clamp = 16'(LINK_WDT_MS);
    else if (req < 16'(LINK_WDT_MS_MIN))  wdt_clamp = 16'(LINK_WDT_MS_MIN);
    else if (req > 16'(LINK_WDT_MS_MAX))  wdt_clamp = 16'(LINK_WDT_MS_MAX);
    else                                  wdt_clamp = req;
  endfunction

  function automatic wdt_oor(input logic [15:0] req);
    wdt_oor = (req != 16'd0) &&
              ((req < 16'(LINK_WDT_MS_MIN)) || (req > 16'(LINK_WDT_MS_MAX)));
  endfunction

  wire [16*N_GROUP-1:0] wdt_eff_flat;
  generate
    for (genvar gi = 0; gi < N_GROUP; gi++) begin : g_wdt_eff
      assign wdt_eff_flat[gi*16 +: 16] = wdt_clamp(wdt_req_r[gi]);
    end
  endgenerate

  localparam int CTL_PUSH_W = 13 + 16*N_GROUP;
  wire [CTL_PUSH_W-1:0] ctl_push_vec = {wdt_eff_flat, stat_idx_r, ctl_r};
  wire [CTL_PUSH_W-1:0] ctl_in_tx;
  wire [7:0]  ctl_push_rounds;
  dcmac_csr_snap #(.WIDTH(CTL_PUSH_W)) u_push_ctl (
    .s_clk(axil_aclk), .s_rstn(axil_aresetn), .din(ctl_push_vec),
    .m_clk(tx_clk), .m_rstn(tx_rstn), .dout(ctl_in_tx), .rounds(ctl_push_rounds)
  );
  assign ctl_bringup_restart_req   = ctl_in_tx[0];
  assign ctl_stats_req             = ctl_in_tx[1];
  assign ctl_rx_force_resync_req   = ctl_in_tx[2];
  assign ctl_rx_datapath_reset_req = ctl_in_tx[3];
  assign ctl_tx_datapath_reset_req = ctl_in_tx[4];
  assign ctl_stat_rd_idx           = ctl_in_tx[12:5];
  assign link_wdt_ms               = ctl_in_tx[CTL_PUSH_W-1:13];

  wire [1:0] clr_in_seg;
  wire [7:0] clr_push_rounds;
  dcmac_csr_snap #(.WIDTH(2)) u_push_clr (
    .s_clk(axil_aclk), .s_rstn(axil_aresetn), .din({clr_stseen_r, clr_sticky_r}),
    .m_clk(seg_clk), .m_rstn(seg_rstn), .dout(clr_in_seg), .rounds(clr_push_rounds)
  );
  assign clr_sticky_tgl_seg = clr_in_seg[0];
  assign clr_stseen_tgl_seg = clr_in_seg[1];

  wire [5:0] rd_word = s_axil_araddr[7:2];
  wire       rd_in_range = (s_axil_araddr[AXIL_ADDR_W-1:8] == '0);

  logic [31:0] rdata_c;
  always_comb begin
    rdata_c = 32'h0;
    if (rd_in_range) begin
      case (rd_word)
        A_ID:       rdata_c = 32'h4E49_4143;
        A_VERSION:  rdata_c = {16'h0003, 16'h0000};
        A_SCRATCH:  rdata_c = scratch_r;
        A_CAPS:     rdata_c = {8'(NPORTS), 8'(N_SEG), 8'(TX_TAG_W),
                               7'b0, (PTP_TS_EN != 0)};
        A_STATUS:   rdata_c = {26'b0, q_fsm_state,
                               q_tx_status, q_rx_status, q_link_up};
        A_STICKY:   rdata_c = {31'b0, q_st_link_down};
        A_STSEEN:   rdata_c = {27'b0, q_state_seen};
        A_LINKEV:   rdata_c = {q_cnt_link_down, q_cnt_link_up};
        A_CTL:      rdata_c = {27'b0, ctl_r};
        A_SEQ:      rdata_c = {q_seq_pc, q_retry, q_acc_fault, q_link_fault,
                               q_seq_busy, q_seq_state};
        A_RXPHY:    rdata_c = q_rx_phy;
        A_STATIDX:  rdata_c = {idx_oor_now, idx_oor_sticky_r, 6'b0,
                               STAT_IDX_MAX, STATS_PER, stat_idx_r};
        A_STATDATA: rdata_c = idx_oor_now ? 32'h0 : q_stat_data;
        A_ROUNDS:   rdata_c = {8'b0, rx_rounds, tx_rounds, seg_rounds};
        default:    rdata_c = 32'h0;
      endcase

      for (int g = 0; g < N_GROUP; g++) begin
        if (rd_word == (A_WDT0 + 6'(g)))
          rdata_c = {wdt_oor(wdt_req_r[g]), wdt_clamp_st[g], 10'b0,
                     4'(N_GROUP), wdt_clamp(wdt_req_r[g])};

      end
    end
  end

  logic        awr_done = 1'b0;
  logic        w_done   = 1'b0;
  logic [5:0]  aw_word  = 6'b0;
  logic        aw_range = 1'b0;
  logic [31:0] w_data   = 32'b0;
  logic [3:0]  w_strb   = 4'b0;
  logic        bvalid_r = 1'b0;
  logic        rvalid_r = 1'b0;
  logic [31:0] rdata_r  = 32'b0;

  wire aw_fire = s_axil_awvalid & s_axil_awready;
  wire w_fire  = s_axil_wvalid  & s_axil_wready;
  wire wr_fire = (aw_fire | awr_done) & (w_fire | w_done);

  wire [5:0]  cm_word  = aw_fire ? s_axil_awaddr[7:2] : aw_word;
  wire        cm_range = aw_fire ? (s_axil_awaddr[AXIL_ADDR_W-1:8] == '0) : aw_range;
  wire [31:0] cm_data  = w_fire  ? s_axil_wdata       : w_data;
  wire [3:0]  cm_strb  = w_fire  ? s_axil_wstrb[3:0]  : w_strb;

  assign s_axil_awready = ~awr_done & ~bvalid_r;
  assign s_axil_wready  = ~w_done   & ~bvalid_r;
  assign s_axil_bresp   = 2'b00;
  assign s_axil_bvalid  = bvalid_r;
  assign s_axil_arready = ~rvalid_r;
  assign s_axil_rresp   = 2'b00;
  assign s_axil_rvalid  = rvalid_r;
  assign s_axil_rdata   = rdata_r;

  always_ff @(posedge axil_aclk) begin
    if (!axil_aresetn) begin
      awr_done <= 1'b0; w_done <= 1'b0; bvalid_r <= 1'b0; rvalid_r <= 1'b0;
      scratch_r <= 32'h0; ctl_r <= 5'h0; stat_idx_r <= 8'h0;
      clr_sticky_r <= 1'b0; clr_stseen_r <= 1'b0;
      idx_oor_sticky_r <= 1'b0;

      for (int g = 0; g < 6; g++) begin
        wdt_req_r[g]    <= 16'd0;
        wdt_clamp_st[g] <= 1'b0;
      end
      aw_word <= 6'b0; aw_range <= 1'b0; w_data <= 32'b0; w_strb <= 4'b0;
      rdata_r <= 32'b0;
    end else begin

      if (aw_fire) begin
        aw_word  <= s_axil_awaddr[7:2];
        aw_range <= (s_axil_awaddr[AXIL_ADDR_W-1:8] == '0);
        awr_done <= 1'b1;
      end
      if (w_fire) begin
        w_data <= s_axil_wdata;
        w_strb <= s_axil_wstrb[3:0];
        w_done <= 1'b1;
      end

      if (wr_fire) begin
        if (cm_range) begin
          case (cm_word)
            A_SCRATCH: begin
              if (cm_strb[0]) scratch_r[7:0]   <= cm_data[7:0];
              if (cm_strb[1]) scratch_r[15:8]  <= cm_data[15:8];
              if (cm_strb[2]) scratch_r[23:16] <= cm_data[23:16];
              if (cm_strb[3]) scratch_r[31:24] <= cm_data[31:24];
            end
            A_CTL:      if (cm_strb[0]) ctl_r      <= cm_data[4:0];

            A_STATIDX:  begin
                          if (cm_strb[0] && !(cm_strb[3] && cm_data[30]))
                            stat_idx_r <= cm_data[7:0];
                          if (cm_strb[3] && cm_data[30]) idx_oor_sticky_r <= 1'b0;
                        end

            A_STICKY:   if (cm_strb[0] && (cm_data[3:0] != 4'b0)) clr_sticky_r <= ~clr_sticky_r;
            A_STSEEN:   if (cm_strb[0] && (cm_data[4:0] != 5'b0)) clr_stseen_r <= ~clr_stseen_r;
            default: ;
          endcase
        end

        if (cm_range && (cm_word == A_STATIDX) && cm_strb[0]
            && !(cm_strb[3] && cm_data[30]) && (cm_data[7:0] > STAT_IDX_MAX))
          idx_oor_sticky_r <= 1'b1;

        for (int g = 0; g < N_GROUP; g++) begin
          if (cm_range && (cm_word == (A_WDT0 + 6'(g)))) begin
            if (!(cm_strb[3] && cm_data[30])) begin
              if (cm_strb[0]) wdt_req_r[g][7:0]  <= cm_data[7:0];
              if (cm_strb[1]) wdt_req_r[g][15:8] <= cm_data[15:8];

              if ((cm_strb[1:0] == 2'b11) && wdt_oor(cm_data[15:0]))
                wdt_clamp_st[g] <= 1'b1;
            end
            if (cm_strb[3] && cm_data[30]) wdt_clamp_st[g] <= 1'b0;
          end
        end
        awr_done <= 1'b0;
        w_done   <= 1'b0;
        bvalid_r <= 1'b1;
      end
      if (bvalid_r && s_axil_bready) bvalid_r <= 1'b0;

      if (s_axil_arvalid && s_axil_arready) begin
        rdata_r  <= rdata_c;
        rvalid_r <= 1'b1;
      end else if (rvalid_r && s_axil_rready) begin
        rvalid_r <= 1'b0;
      end
    end
  end
endmodule
