// ---------------------------------------------------------------------------
// File        : dcmac_seg_pktgen.sv
// Description : The segmented traffic instrument: the generator, the receive checker and
//               the register block, on the client interface and ahead of any stream
//               boundary.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module dcmac_seg_pktgen #(
  parameter integer N_SEG       = 2,
  parameter integer SEG_W       = 128,
  parameter integer AXIL_ADDR_W = 12,
  parameter integer LEN_MIN_HW  = 60,
  parameter integer LEN_MAX_HW  = 9018,
  parameter integer STALL_CYC   = 1024,
  parameter [31:0]  MODULE_TYPE = 32'h4E535047,
  parameter [31:0]  MAP_VERSION = 32'h0003_0001
)(
  input  wire                      seg_clk,
  input  wire                      seg_rstn,

  input  wire                      link_up,
  input  wire                      tx_rst_seg,
  input  wire                      ctl_tx_enable,

  input  wire                      tx_seg_ready,
  output wire                      tx_seg_valid,
  output wire [N_SEG*SEG_W-1:0]    tx_seg_dat,
  output wire [N_SEG-1:0]          tx_seg_ena,
  output wire [N_SEG-1:0]          tx_seg_sop,
  output wire [N_SEG-1:0]          tx_seg_eop,
  output wire [N_SEG-1:0]          tx_seg_err,
  output wire [N_SEG*4-1:0]        tx_seg_mty,

  input  wire                      rx_seg_valid,
  input  wire [N_SEG*SEG_W-1:0]    rx_seg_dat,
  input  wire [N_SEG-1:0]          rx_seg_ena,
  input  wire [N_SEG-1:0]          rx_seg_sop,
  input  wire [N_SEG-1:0]          rx_seg_eop,
  input  wire [N_SEG-1:0]          rx_seg_err,
  input  wire [N_SEG*4-1:0]        rx_seg_mty,

  input  wire                      axil_aclk,
  input  wire                      axil_aresetn,
  input  wire [AXIL_ADDR_W-1:0]    s_axil_awaddr,
  input  wire                      s_axil_awvalid,
  output wire                      s_axil_awready,
  input  wire [31:0]               s_axil_wdata,
  input  wire [3:0]                s_axil_wstrb,
  input  wire                      s_axil_wvalid,
  output wire                      s_axil_wready,
  output wire [1:0]                s_axil_bresp,
  output wire                      s_axil_bvalid,
  input  wire                      s_axil_bready,
  input  wire [AXIL_ADDR_W-1:0]    s_axil_araddr,
  input  wire                      s_axil_arvalid,
  output wire                      s_axil_arready,
  output wire [31:0]               s_axil_rdata,
  output wire [1:0]                s_axil_rresp,
  output wire                      s_axil_rvalid,
  input  wire                      s_axil_rready
);

  localparam int WORD_W = 6;

  localparam logic [WORD_W-1:0] WORD_MODULE_TYPE         = 6'h00;
  localparam logic [WORD_W-1:0] WORD_MAP_VERSION         = 6'h01;
  localparam logic [WORD_W-1:0] WORD_BUS_CHECK           = 6'h02;
  localparam logic [WORD_W-1:0] WORD_SEG_GEOMETRY        = 6'h03;
  localparam logic [WORD_W-1:0] WORD_FEATURES            = 6'h04;
  localparam logic [WORD_W-1:0] WORD_CTL                 = 6'h05;
  localparam logic [WORD_W-1:0] WORD_STATUS              = 6'h06;
  localparam logic [WORD_W-1:0] WORD_LEN_MIN             = 6'h07;
  localparam logic [WORD_W-1:0] WORD_LEN_MAX             = 6'h08;
  localparam logic [WORD_W-1:0] WORD_LEN_MODE            = 6'h09;
  localparam logic [WORD_W-1:0] WORD_LEN_EFFECTIVE       = 6'h0A;
  localparam logic [WORD_W-1:0] WORD_LEN_CLAMP_STICKY    = 6'h0B;
  localparam logic [WORD_W-1:0] WORD_TX_FRAME_LIMIT      = 6'h0C;
  localparam logic [WORD_W-1:0] WORD_SNAPSHOT_ROUNDS     = 6'h0D;
  localparam logic [WORD_W-1:0] WORD_TX_FRAMES           = 6'h10;
  localparam logic [WORD_W-1:0] WORD_TX_BYTES            = 6'h11;
  localparam logic [WORD_W-1:0] WORD_RX_FRAMES           = 6'h12;
  localparam logic [WORD_W-1:0] WORD_RX_BYTES            = 6'h13;
  localparam logic [WORD_W-1:0] WORD_RX_ERR_FRAMES       = 6'h14;
  localparam logic [WORD_W-1:0] WORD_RX_MISMATCH_BEATS   = 6'h15;
  localparam logic [WORD_W-1:0] WORD_STALL_CYCLE         = 6'h16;
  localparam logic [WORD_W-1:0] WORD_LATCHED_TX_FRAMES   = 6'h18;
  localparam logic [WORD_W-1:0] WORD_LATCHED_TX_BYTES    = 6'h19;
  localparam logic [WORD_W-1:0] WORD_LATCHED_RX_FRAMES   = 6'h1A;
  localparam logic [WORD_W-1:0] WORD_LATCHED_RX_BYTES    = 6'h1B;
  localparam logic [WORD_W-1:0] WORD_LATCHED_RX_MISMATCH = 6'h1C;
  localparam logic [WORD_W-1:0] WORD_HDR_CTL             = 6'h20;
  localparam logic [WORD_W-1:0] WORD_HDR_DST_MAC_LOW     = 6'h21;
  localparam logic [WORD_W-1:0] WORD_HDR_DST_MAC_HIGH    = 6'h22;
  localparam logic [WORD_W-1:0] WORD_HDR_SRC_MAC_LOW     = 6'h23;
  localparam logic [WORD_W-1:0] WORD_HDR_SRC_MAC_HIGH    = 6'h24;
  localparam logic [WORD_W-1:0] WORD_HDR_ETHERTYPE       = 6'h25;
  localparam logic [WORD_W-1:0] WORD_HDR_IP_VERSION_TOS  = 6'h26;
  localparam logic [WORD_W-1:0] WORD_HDR_IP_ID_FLAGS     = 6'h27;
  localparam logic [WORD_W-1:0] WORD_HDR_IP_TTL_PROTOCOL = 6'h28;
  localparam logic [WORD_W-1:0] WORD_HDR_IP_SRC_ADDR     = 6'h29;
  localparam logic [WORD_W-1:0] WORD_HDR_IP_DST_ADDR     = 6'h2A;
  localparam logic [WORD_W-1:0] WORD_HDR_UDP_PORTS       = 6'h2B;

  localparam logic [31:0] FEATURE_SET = 32'h0000_0001;

  localparam int HDR_B = 42;

  localparam int CTL_HDR_ENABLE_BIT = 0;

  localparam logic [1:0] LEN_MODE_FIXED  = 2'd0;
  localparam logic [1:0] LEN_MODE_RANDOM = 2'd1;

  localparam int CTL_ENABLE_BIT = 0;
  localparam int CTL_CLEAR_BIT  = 1;

  logic        cfg_enable_r;
  logic        cfg_clear_r;
  logic [1:0]  cfg_len_mode_r;
  logic [31:0] cfg_bus_check_r;
  logic [31:0] cfg_tx_frame_limit_r;
  logic [15:0] cfg_len_min_r;
  logic [15:0] cfg_len_max_r;
  logic        cfg_len_clamped_r;
  logic        cfg_hdr_enable_r;
  logic [31:0] cfg_hdr_dst_mac_low_r;
  logic [31:0] cfg_hdr_dst_mac_high_r;
  logic [31:0] cfg_hdr_src_mac_low_r;
  logic [31:0] cfg_hdr_src_mac_high_r;
  logic [31:0] cfg_hdr_ethertype_r;
  logic [31:0] cfg_hdr_ip_version_tos_r;
  logic [31:0] cfg_hdr_ip_id_flags_r;
  logic [31:0] cfg_hdr_ip_ttl_protocol_r;
  logic [31:0] cfg_hdr_ip_src_addr_r;
  logic [31:0] cfg_hdr_ip_dst_addr_r;
  logic [31:0] cfg_hdr_udp_ports_r;

  localparam int HDR_IP_OVERHEAD  = 14;
  localparam int HDR_UDP_OVERHEAD = 34;

  wire [15:0] hdr_ip_total_length = len_min_effective - 16'(HDR_IP_OVERHEAD);
  wire [15:0] hdr_udp_length      = len_min_effective - 16'(HDR_UDP_OVERHEAD);

  logic [HDR_B-1:0][7:0] hdr_byte_cfg;

  always_comb begin
    hdr_byte_cfg = '0;

    hdr_byte_cfg[0]  = cfg_hdr_dst_mac_low_r[7:0];
    hdr_byte_cfg[1]  = cfg_hdr_dst_mac_low_r[15:8];
    hdr_byte_cfg[2]  = cfg_hdr_dst_mac_low_r[23:16];
    hdr_byte_cfg[3]  = cfg_hdr_dst_mac_low_r[31:24];
    hdr_byte_cfg[4]  = cfg_hdr_dst_mac_high_r[7:0];
    hdr_byte_cfg[5]  = cfg_hdr_dst_mac_high_r[15:8];

    hdr_byte_cfg[6]  = cfg_hdr_src_mac_low_r[7:0];
    hdr_byte_cfg[7]  = cfg_hdr_src_mac_low_r[15:8];
    hdr_byte_cfg[8]  = cfg_hdr_src_mac_low_r[23:16];
    hdr_byte_cfg[9]  = cfg_hdr_src_mac_low_r[31:24];
    hdr_byte_cfg[10] = cfg_hdr_src_mac_high_r[7:0];
    hdr_byte_cfg[11] = cfg_hdr_src_mac_high_r[15:8];

    hdr_byte_cfg[12] = cfg_hdr_ethertype_r[15:8];
    hdr_byte_cfg[13] = cfg_hdr_ethertype_r[7:0];

    hdr_byte_cfg[14] = cfg_hdr_ip_version_tos_r[7:0];
    hdr_byte_cfg[15] = cfg_hdr_ip_version_tos_r[15:8];
    hdr_byte_cfg[16] = hdr_ip_total_length[15:8];
    hdr_byte_cfg[17] = hdr_ip_total_length[7:0];
    hdr_byte_cfg[18] = cfg_hdr_ip_id_flags_r[15:8];
    hdr_byte_cfg[19] = cfg_hdr_ip_id_flags_r[7:0];
    hdr_byte_cfg[20] = cfg_hdr_ip_id_flags_r[31:24];
    hdr_byte_cfg[21] = cfg_hdr_ip_id_flags_r[23:16];
    hdr_byte_cfg[22] = cfg_hdr_ip_ttl_protocol_r[7:0];
    hdr_byte_cfg[23] = cfg_hdr_ip_ttl_protocol_r[15:8];
    hdr_byte_cfg[24] = 8'h00;
    hdr_byte_cfg[25] = 8'h00;
    hdr_byte_cfg[26] = cfg_hdr_ip_src_addr_r[31:24];
    hdr_byte_cfg[27] = cfg_hdr_ip_src_addr_r[23:16];
    hdr_byte_cfg[28] = cfg_hdr_ip_src_addr_r[15:8];
    hdr_byte_cfg[29] = cfg_hdr_ip_src_addr_r[7:0];
    hdr_byte_cfg[30] = cfg_hdr_ip_dst_addr_r[31:24];
    hdr_byte_cfg[31] = cfg_hdr_ip_dst_addr_r[23:16];
    hdr_byte_cfg[32] = cfg_hdr_ip_dst_addr_r[15:8];
    hdr_byte_cfg[33] = cfg_hdr_ip_dst_addr_r[7:0];

    hdr_byte_cfg[34] = cfg_hdr_udp_ports_r[15:8];
    hdr_byte_cfg[35] = cfg_hdr_udp_ports_r[7:0];
    hdr_byte_cfg[36] = cfg_hdr_udp_ports_r[31:24];
    hdr_byte_cfg[37] = cfg_hdr_udp_ports_r[23:16];
    hdr_byte_cfg[38] = hdr_udp_length[15:8];
    hdr_byte_cfg[39] = hdr_udp_length[7:0];
    hdr_byte_cfg[40] = 8'h00;
    hdr_byte_cfg[41] = 8'h00;
  end

  wire [HDR_B*8-1:0] hdr_bytes_cfg = hdr_byte_cfg;

  wire [15:0] len_min_effective = (cfg_len_min_r < 16'(LEN_MIN_HW)) ? 16'(LEN_MIN_HW) :
                                  (cfg_len_min_r > 16'(LEN_MAX_HW)) ? 16'(LEN_MAX_HW) :
                                                                      cfg_len_min_r;

  wire [15:0] len_max_clamped   = (cfg_len_max_r > 16'(LEN_MAX_HW)) ? 16'(LEN_MAX_HW) :
                                  (cfg_len_max_r < 16'(LEN_MIN_HW)) ? 16'(LEN_MIN_HW) :
                                                                      cfg_len_max_r;

  wire [15:0] len_max_effective = (len_max_clamped < len_min_effective) ? len_min_effective :
                                                                         len_max_clamped;

  wire [31:0] tx_frames;
  wire [31:0] tx_bytes;
  wire [31:0] tx_stall_cycle;
  wire [31:0] latched_tx_frames;
  wire [31:0] latched_tx_bytes;
  wire        tx_busy;
  wire        tx_done;
  wire        tx_stalled;
  wire        tx_underflow;
  wire        tx_overflow;

  wire [31:0] rx_frames;
  wire [31:0] rx_bytes;
  wire [31:0] rx_err_frames;
  wire [31:0] rx_mismatch_beats;
  wire [31:0] latched_rx_frames;
  wire [31:0] latched_rx_bytes;
  wire [31:0] latched_rx_mismatch;
  wire        rx_locked;

  wire enable_seg;
  wire clear_seg;
  wire len_random_seg;
  wire hdr_enable_seg;

  dcmac_sync2 #(.WIDTH(4), .STAGES(2), .INIT(4'b0000)) u_sync_ctl (
    .clk  (seg_clk),
    .din  ({cfg_hdr_enable_r, cfg_len_mode_r == LEN_MODE_RANDOM, cfg_clear_r, cfg_enable_r}),
    .dout ({hdr_enable_seg, len_random_seg, clear_seg, enable_seg})
  );

  logic [15:0]       len_min_seg_r;
  logic [15:0]       len_max_seg_r;
  logic [31:0]       tx_frame_limit_seg_r;
  (* max_fanout = 32 *)
  logic [HDR_B*8-1:0] hdr_bytes_seg_r;

  always_ff @(posedge seg_clk) begin
    if (!enable_seg) begin
      len_min_seg_r        <= len_min_effective;
      len_max_seg_r        <= len_random_seg ? len_max_effective : len_min_effective;
      tx_frame_limit_seg_r <= cfg_tx_frame_limit_r;
      hdr_bytes_seg_r      <= hdr_bytes_cfg;
    end
  end

  wire tx_permitted = link_up & ctl_tx_enable & ~tx_rst_seg;

  dcmac_seg_pktgen_tx #(
    .N_SEG      (N_SEG),
    .SEG_W      (SEG_W),
    .LEN_MIN_HW (LEN_MIN_HW),
    .LEN_MAX_HW (LEN_MAX_HW),
    .STALL_CYC  (STALL_CYC)
  ) u_tx (
    .seg_clk        (seg_clk),
    .seg_rstn       (seg_rstn),
    .enable         (enable_seg),
    .clear          (clear_seg),
    .tx_ok          (tx_permitted),
    .len_min        (len_min_seg_r),
    .len_max        (len_max_seg_r),
    .limit          (tx_frame_limit_seg_r),
    .hdr_enable     (hdr_enable_seg),
    .hdr_bytes      (hdr_bytes_seg_r),

    .tx_seg_ready   (tx_seg_ready),
    .tx_seg_valid   (tx_seg_valid),
    .tx_seg_dat     (tx_seg_dat),
    .tx_seg_ena     (tx_seg_ena),
    .tx_seg_sop     (tx_seg_sop),
    .tx_seg_eop     (tx_seg_eop),
    .tx_seg_err     (tx_seg_err),
    .tx_seg_mty     (tx_seg_mty),

    .frames         (tx_frames),
    .bytes          (tx_bytes),
    .latched_frames (latched_tx_frames),
    .latched_bytes  (latched_tx_bytes),
    .busy           (tx_busy),
    .done           (tx_done),
    .stalled        (tx_stalled),
    .stall_cycle    (tx_stall_cycle),
    .underflow      (tx_underflow),
    .overflow       (tx_overflow)
  );

  dcmac_seg_pktmon #(
    .N_SEG (N_SEG),
    .SEG_W (SEG_W)
  ) u_rx (
    .seg_clk           (seg_clk),
    .seg_rstn          (seg_rstn),
    .clear             (clear_seg),

    .rx_seg_valid      (rx_seg_valid),
    .rx_seg_dat        (rx_seg_dat),
    .rx_seg_ena        (rx_seg_ena),
    .rx_seg_sop        (rx_seg_sop),
    .rx_seg_eop        (rx_seg_eop),
    .rx_seg_err        (rx_seg_err),
    .rx_seg_mty        (rx_seg_mty),

    .frames            (rx_frames),
    .bytes             (rx_bytes),
    .latched_frames    (latched_rx_frames),
    .latched_bytes     (latched_rx_bytes),
    .err_frames        (rx_err_frames),
    .mismatch_beats    (rx_mismatch_beats),
    .latched_mismatch  (latched_rx_mismatch),
    .locked            (rx_locked)
  );

  localparam int SNAPSHOT_W = 12*32 + 8;

  wire [7:0] status_seg = {
    1'b0,
    link_up,
    rx_locked,
    tx_overflow,
    tx_underflow,
    tx_stalled,
    tx_done,
    tx_busy
  };

  wire [SNAPSHOT_W-1:0] snapshot_seg = {
    status_seg,
    latched_rx_mismatch,
    latched_rx_bytes,
    latched_rx_frames,
    latched_tx_bytes,
    latched_tx_frames,
    tx_stall_cycle,
    rx_mismatch_beats,
    rx_err_frames,
    rx_bytes,
    rx_frames,
    tx_bytes,
    tx_frames
  };

  wire [SNAPSHOT_W-1:0] snapshot;
  wire [7:0]            snapshot_rounds;

  dcmac_csr_snap #(.WIDTH(SNAPSHOT_W)) u_snap (
    .s_clk  (seg_clk),
    .s_rstn (seg_rstn),
    .din    (snapshot_seg),
    .m_clk  (axil_aclk),
    .m_rstn (axil_aresetn),
    .dout   (snapshot),
    .rounds (snapshot_rounds)
  );

  wire [31:0] snap_tx_frames           = snapshot[31:0];
  wire [31:0] snap_tx_bytes            = snapshot[63:32];
  wire [31:0] snap_rx_frames           = snapshot[95:64];
  wire [31:0] snap_rx_bytes            = snapshot[127:96];
  wire [31:0] snap_rx_err_frames       = snapshot[159:128];
  wire [31:0] snap_rx_mismatch_beats   = snapshot[191:160];
  wire [31:0] snap_stall_cycle         = snapshot[223:192];
  wire [31:0] snap_latched_tx_frames   = snapshot[255:224];
  wire [31:0] snap_latched_tx_bytes    = snapshot[287:256];
  wire [31:0] snap_latched_rx_frames   = snapshot[319:288];
  wire [31:0] snap_latched_rx_bytes    = snapshot[351:320];
  wire [31:0] snap_latched_rx_mismatch = snapshot[383:352];
  wire [31:0] snap_status              = {24'd0, snapshot[391:384]};

  localparam int REG_ADDR_W = 8;

  logic                  aw_hold_r;
  logic                  w_hold_r;
  logic                  b_pending_r;
  logic                  r_pending_r;
  logic [WORD_W-1:0]     aw_word_r;
  logic [31:0]           wdata_r;
  logic [31:0]           rdata_r;

  wire [WORD_W-1:0] aw_word_in = s_axil_awaddr[REG_ADDR_W-1:2];
  wire [WORD_W-1:0] ar_word_in = s_axil_araddr[REG_ADDR_W-1:2];

  assign s_axil_awready = !aw_hold_r && !b_pending_r;
  assign s_axil_wready  = !w_hold_r  && !b_pending_r;
  assign s_axil_bvalid  = b_pending_r;
  assign s_axil_bresp   = 2'b00;
  assign s_axil_arready = !r_pending_r;
  assign s_axil_rvalid  = r_pending_r;
  assign s_axil_rresp   = 2'b00;
  assign s_axil_rdata   = rdata_r;

  function automatic [31:0] register_read(input logic [WORD_W-1:0] word);
    case (word)
      WORD_MODULE_TYPE:         register_read = MODULE_TYPE;
      WORD_MAP_VERSION:         register_read = MAP_VERSION;
      WORD_BUS_CHECK:           register_read = cfg_bus_check_r;
      WORD_SEG_GEOMETRY:        register_read = {16'(N_SEG), 16'(SEG_W)};
      WORD_FEATURES:            register_read = FEATURE_SET;
      WORD_CTL:                 register_read = {30'd0, cfg_clear_r, cfg_enable_r};
      WORD_STATUS:              register_read = snap_status;
      WORD_LEN_MIN:             register_read = {16'd0, cfg_len_min_r};
      WORD_LEN_MAX:             register_read = {16'd0, cfg_len_max_r};
      WORD_LEN_MODE:            register_read = {30'd0, cfg_len_mode_r};
      WORD_LEN_EFFECTIVE:       register_read = {len_max_effective, len_min_effective};
      WORD_LEN_CLAMP_STICKY:    register_read = {31'd0, cfg_len_clamped_r};
      WORD_TX_FRAME_LIMIT:      register_read = cfg_tx_frame_limit_r;
      WORD_SNAPSHOT_ROUNDS:     register_read = {24'd0, snapshot_rounds};
      WORD_TX_FRAMES:           register_read = snap_tx_frames;
      WORD_TX_BYTES:            register_read = snap_tx_bytes;
      WORD_RX_FRAMES:           register_read = snap_rx_frames;
      WORD_RX_BYTES:            register_read = snap_rx_bytes;
      WORD_RX_ERR_FRAMES:       register_read = snap_rx_err_frames;
      WORD_RX_MISMATCH_BEATS:   register_read = snap_rx_mismatch_beats;
      WORD_STALL_CYCLE:         register_read = snap_stall_cycle;
      WORD_HDR_CTL:             register_read = {31'd0, cfg_hdr_enable_r};
      WORD_HDR_DST_MAC_LOW:     register_read = cfg_hdr_dst_mac_low_r;
      WORD_HDR_DST_MAC_HIGH:    register_read = cfg_hdr_dst_mac_high_r;
      WORD_HDR_SRC_MAC_LOW:     register_read = cfg_hdr_src_mac_low_r;
      WORD_HDR_SRC_MAC_HIGH:    register_read = cfg_hdr_src_mac_high_r;
      WORD_HDR_ETHERTYPE:       register_read = cfg_hdr_ethertype_r;
      WORD_HDR_IP_VERSION_TOS:  register_read = cfg_hdr_ip_version_tos_r;
      WORD_HDR_IP_ID_FLAGS:     register_read = cfg_hdr_ip_id_flags_r;
      WORD_HDR_IP_TTL_PROTOCOL: register_read = cfg_hdr_ip_ttl_protocol_r;
      WORD_HDR_IP_SRC_ADDR:     register_read = cfg_hdr_ip_src_addr_r;
      WORD_HDR_IP_DST_ADDR:     register_read = cfg_hdr_ip_dst_addr_r;
      WORD_HDR_UDP_PORTS:       register_read = cfg_hdr_udp_ports_r;
      WORD_LATCHED_TX_FRAMES:   register_read = snap_latched_tx_frames;
      WORD_LATCHED_TX_BYTES:    register_read = snap_latched_tx_bytes;
      WORD_LATCHED_RX_FRAMES:   register_read = snap_latched_rx_frames;
      WORD_LATCHED_RX_BYTES:    register_read = snap_latched_rx_bytes;
      WORD_LATCHED_RX_MISMATCH: register_read = snap_latched_rx_mismatch;
      default:                  register_read = 32'd0;
    endcase
  endfunction

  function automatic logic length_needs_clamp(input logic [15:0] value, input logic [15:0] partner,
                                              input logic value_is_min);
    length_needs_clamp = (value < 16'(LEN_MIN_HW)) || (value > 16'(LEN_MAX_HW)) ||
                         (value_is_min ? (partner < value) : (value < partner));
  endfunction

  always_ff @(posedge axil_aclk) begin
    if (!axil_aresetn) begin
      aw_hold_r            <= 1'b0;
      w_hold_r             <= 1'b0;
      b_pending_r          <= 1'b0;
      r_pending_r          <= 1'b0;
      aw_word_r            <= '0;
      wdata_r              <= '0;
      rdata_r              <= '0;
      cfg_enable_r         <= 1'b0;
      cfg_clear_r          <= 1'b0;
      cfg_len_mode_r       <= LEN_MODE_FIXED;
      cfg_bus_check_r      <= '0;
      cfg_tx_frame_limit_r <= '0;
      cfg_len_min_r        <= 16'(LEN_MIN_HW);
      cfg_len_max_r        <= 16'(LEN_MAX_HW);
      cfg_len_clamped_r    <= 1'b0;
      cfg_hdr_enable_r          <= 1'b0;
      cfg_hdr_dst_mac_low_r     <= '0;
      cfg_hdr_dst_mac_high_r    <= '0;
      cfg_hdr_src_mac_low_r     <= '0;
      cfg_hdr_src_mac_high_r    <= '0;
      cfg_hdr_ethertype_r       <= 32'h0000_0800;
      cfg_hdr_ip_version_tos_r  <= 32'h0000_0045;
      cfg_hdr_ip_id_flags_r     <= 32'h0000_0000;
      cfg_hdr_ip_ttl_protocol_r <= 32'h0000_1140;
      cfg_hdr_ip_src_addr_r     <= '0;
      cfg_hdr_ip_dst_addr_r     <= '0;
      cfg_hdr_udp_ports_r       <= '0;
    end else begin
      if (s_axil_awvalid && s_axil_awready) begin
        aw_word_r <= aw_word_in;
        aw_hold_r <= 1'b1;
      end
      if (s_axil_wvalid && s_axil_wready) begin
        wdata_r  <= s_axil_wdata;
        w_hold_r <= 1'b1;
      end

      if (aw_hold_r && w_hold_r && !b_pending_r) begin
        aw_hold_r   <= 1'b0;
        w_hold_r    <= 1'b0;
        b_pending_r <= 1'b1;
        case (aw_word_r)
          WORD_BUS_CHECK: cfg_bus_check_r <= wdata_r;
          WORD_CTL: begin
            cfg_enable_r <= wdata_r[CTL_ENABLE_BIT];
            cfg_clear_r  <= wdata_r[CTL_CLEAR_BIT];
          end
          WORD_LEN_MIN: begin
            cfg_len_min_r <= wdata_r[15:0];
            if (length_needs_clamp(wdata_r[15:0], cfg_len_max_r, 1'b1)) cfg_len_clamped_r <= 1'b1;
          end
          WORD_LEN_MAX: begin
            cfg_len_max_r <= wdata_r[15:0];
            if (length_needs_clamp(wdata_r[15:0], cfg_len_min_r, 1'b0)) cfg_len_clamped_r <= 1'b1;
          end
          WORD_LEN_MODE:         cfg_len_mode_r       <= wdata_r[1:0];
          WORD_TX_FRAME_LIMIT:   cfg_tx_frame_limit_r <= wdata_r;
          WORD_LEN_CLAMP_STICKY: if (wdata_r[0]) cfg_len_clamped_r <= 1'b0;
          WORD_HDR_CTL:             cfg_hdr_enable_r          <= wdata_r[CTL_HDR_ENABLE_BIT];
          WORD_HDR_DST_MAC_LOW:     cfg_hdr_dst_mac_low_r     <= wdata_r;
          WORD_HDR_DST_MAC_HIGH:    cfg_hdr_dst_mac_high_r    <= wdata_r;
          WORD_HDR_SRC_MAC_LOW:     cfg_hdr_src_mac_low_r     <= wdata_r;
          WORD_HDR_SRC_MAC_HIGH:    cfg_hdr_src_mac_high_r    <= wdata_r;
          WORD_HDR_ETHERTYPE:       cfg_hdr_ethertype_r       <= wdata_r;
          WORD_HDR_IP_VERSION_TOS:  cfg_hdr_ip_version_tos_r  <= wdata_r;
          WORD_HDR_IP_ID_FLAGS:     cfg_hdr_ip_id_flags_r     <= wdata_r;
          WORD_HDR_IP_TTL_PROTOCOL: cfg_hdr_ip_ttl_protocol_r <= wdata_r;
          WORD_HDR_IP_SRC_ADDR:     cfg_hdr_ip_src_addr_r     <= wdata_r;
          WORD_HDR_IP_DST_ADDR:     cfg_hdr_ip_dst_addr_r     <= wdata_r;
          WORD_HDR_UDP_PORTS:       cfg_hdr_udp_ports_r       <= wdata_r;
          default: ;
        endcase
      end else if (b_pending_r && s_axil_bready) begin
        b_pending_r <= 1'b0;
      end

      if (s_axil_arvalid && s_axil_arready) begin
        rdata_r     <= register_read(ar_word_in);
        r_pending_r <= 1'b1;
      end else if (r_pending_r && s_axil_rready) begin
        r_pending_r <= 1'b0;
      end
    end
  end

  wire unused_register_bits = (|s_axil_wstrb)
                            | (|s_axil_awaddr[AXIL_ADDR_W-1:REG_ADDR_W])
                            | (|s_axil_araddr[AXIL_ADDR_W-1:REG_ADDR_W])
                            ;

endmodule

module dcmac_seg_pktgen_tx #(
  parameter int N_SEG        = 2,
  parameter int SEG_W        = 128,
  parameter int LEN_MIN_HW   = 60,
  parameter int LEN_MAX_HW   = 9018,
  parameter int STALL_CYC    = 1024,
  parameter int NUM_ID       = 6,
  parameter int IDLE_DONE    = 16,
  parameter int HDR_B        = 42
)(
  input  wire                      seg_clk,
  input  wire                      seg_rstn,

  input  wire                      enable,
  input  wire                      clear,
  input  wire                      tx_ok,

  input  wire [15:0]               len_min,
  input  wire [15:0]               len_max,
  input  wire [31:0]               limit,

  input  wire                      hdr_enable,
  input  wire [HDR_B*8-1:0]        hdr_bytes,

  input  wire                      tx_seg_ready,
  output wire                      tx_seg_valid,
  output wire [N_SEG*SEG_W-1:0]    tx_seg_dat,
  output wire [N_SEG-1:0]          tx_seg_ena,
  output wire [N_SEG-1:0]          tx_seg_sop,
  output wire [N_SEG-1:0]          tx_seg_eop,
  output wire [N_SEG-1:0]          tx_seg_err,
  output wire [N_SEG*4-1:0]        tx_seg_mty,

  output wire [31:0]               frames,
  output wire [31:0]               bytes,
  output wire [31:0]               latched_frames,
  output wire [31:0]               latched_bytes,
  output wire                      busy,
  output wire                      done,
  output wire                      stalled,
  output wire [31:0]               stall_cycle,
  output wire                      underflow,
  output wire                      overflow
);

  localparam int ID_W    = (NUM_ID == 1) ? 1 : $clog2(NUM_ID);
  localparam int PKT_W   = ID_W + 12 + 12 + 12 + 12 + 12*4 + 12*128;
  localparam int SLICE_W = 2 + 2 + 2 + 2 + 2*4 + 2*128;

  localparam int PKT_DAT_LSB = 0;
  localparam int PKT_MTY_LSB = PKT_DAT_LSB + 12*128;
  localparam int PKT_ERR_LSB = PKT_MTY_LSB + 12*4;
  localparam int PKT_EOP_LSB = PKT_ERR_LSB + 12;
  localparam int PKT_SOP_LSB = PKT_EOP_LSB + 12;
  localparam int PKT_ENA_LSB = PKT_SOP_LSB + 12;

  localparam int SLICE_DAT_LSB = 0;
  localparam int SLICE_MTY_LSB = SLICE_DAT_LSB + 2*128;
  localparam int SLICE_ERR_LSB = SLICE_MTY_LSB + 2*4;
  localparam int SLICE_EOP_LSB = SLICE_ERR_LSB + 2;
  localparam int SLICE_SOP_LSB = SLICE_EOP_LSB + 2;
  localparam int SLICE_ENA_LSB = SLICE_SOP_LSB + 2;

  initial begin
    if (!(N_SEG == 2 || N_SEG == 4 || N_SEG == 8) || SEG_W != 128)
      $fatal(1, "dcmac_seg_pktgen_tx: the client bus is 2, 4 or 8 segments of 128 bits, which is 100GAUI-1, 200GAUI-2 and 400GAUI-4 of PG369 p113. N_SEG=%0d SEG_W=%0d", N_SEG, SEG_W);
  end

  wire rst = ~seg_rstn;

  logic [15:0] len_min_q;
  logic [15:0] len_max_q;

  always_comb begin
    len_min_q = (len_min < 16'(LEN_MIN_HW)) ? 16'(LEN_MIN_HW) : len_min;
    len_max_q = (len_max > 16'(LEN_MAX_HW)) ? 16'(LEN_MAX_HW) :
                (len_max < len_min_q)       ? len_min_q       : len_max;
  end

  logic [15:0] len_min_r;
  logic [15:0] len_max_r;
  logic [31:0] limit_r;

  wire [NUM_ID-1:0][63:0] pkt_cnt;
  wire [NUM_ID-1:0][63:0] byte_cnt;

  logic [31:0] issued_r;
  logic limit_hit_r;
  logic run_r;

  always_ff @(posedge seg_clk) begin
    if (rst) begin
      len_min_r   <= 16'(LEN_MIN_HW);
      len_max_r   <= 16'(LEN_MIN_HW);
      limit_r     <= '0;
      limit_hit_r <= 1'b0;
      run_r       <= 1'b0;
    end else begin
      if (!run_r) begin
        len_min_r <= len_min_q;
        len_max_r <= len_max_q;
        limit_r   <= limit;
      end

      limit_hit_r <= (limit_r != 32'd0) && (issued_r >= limit_r);
      run_r       <= enable & tx_ok & ~limit_hit_r;
    end
  end

  wire [NUM_ID:0]     pkt_ena = {1'b0, {(NUM_ID-1){1'b0}}, run_r};
  wire [NUM_ID-1:0]   clear_counters = {{(NUM_ID-1){1'b0}}, clear};
  wire [NUM_ID-1:0]   gearbox_af;
  wire [NUM_ID-1:0]   gearbox_underflow;
  wire [NUM_ID-1:0]   gearbox_overflow;
  wire [PKT_W-1:0]    gen_pkt;
  wire [6*SLICE_W-1:0] gearbox_slice;
  wire [5:0]          gearbox_vld;
  wire                skip_response;

  localparam int CAL_N = 6;
  localparam logic [ID_W-1:0] ID_IDLE = {ID_W{1'b1}};

  localparam logic [CAL_N-1:0] CAL_OWNED = (N_SEG == 8) ? 6'b011011
                                         : (N_SEG == 4) ? 6'b001001
                                         :                6'b000001;

  localparam logic [1:0] RATE_WORD = (N_SEG == 8) ? 2'b10 : (N_SEG == 4) ? 2'b01 : 2'b00;
  localparam int NSLICE_TX = N_SEG / 2;

  logic [2:0]       cal_cnt;
  logic [ID_W-1:0] req_id_r;

  always_ff @(posedge seg_clk) begin
    if (rst) begin
      cal_cnt  <= '0;
      req_id_r <= ID_IDLE;
    end else begin
      cal_cnt  <= (cal_cnt == 3'(CAL_N-1)) ? '0 : cal_cnt + 3'd1;
      req_id_r <= CAL_OWNED[cal_cnt] ? {ID_W{1'b0}} : ID_IDLE;
    end
  end

  dcmac_seg_pktgen_core #(
    .NUM_ID (NUM_ID)
  ) u_gen (
    .clk              (seg_clk),
    .rst              (rst),
    .i_pkt_ena        (pkt_ena),
    .i_min_len        (len_min_r),
    .i_max_len        (len_max_r),
    .i_clear_counters (clear_counters),
    .i_req_id         (req_id_r),
    .i_req_id_vld     (1'b1),
    .i_skip_id        ({ID_W{1'b0}}),
    .i_skip           (1'b0),
    .i_af             (gearbox_af),
    .o_skip_response  (skip_response),
    .o_pkt            (gen_pkt),
    .o_pkt_vld        (),
    .o_byte_cnt       (byte_cnt),
    .o_pkt_cnt        (pkt_cnt)
  );

  wire gearbox_rst = rst | ~enable | ~tx_ok;

  dcmac_seg_pktgen_gearbox #(
    .REGISTER_INPUT (1)
  ) u_gearbox (
    .clk             (seg_clk),
    .rst             ({6{gearbox_rst}}),
    .i_data_rate     ({10'b0, RATE_WORD}),
    .i_pkt_ena       ({6{run_r}}),
    .i_skip_response (skip_response),
    .i_pkt           (gen_pkt),
    .i_tready        ({5'b0, tx_seg_ready}),
    .i_hdr_ena       (hdr_enable),
    .i_hdr_bytes     (hdr_bytes),
    .o_af            (gearbox_af),
    .o_vld           (gearbox_vld),
    .o_preamble      (),
    .o_slice         (gearbox_slice),
    .o_underflow     (gearbox_underflow),
    .o_overflow      (gearbox_overflow)
  );

  wire [N_SEG*SEG_W-1:0] tx_dat_w;
  wire [N_SEG*4-1:0]     tx_mty_w;
  wire [N_SEG-1:0]       tx_err_w, tx_eop_w, tx_sop_w, tx_ena_w;

  genvar gs;
  generate
  for (gs = 0; gs < NSLICE_TX; gs++) begin : g_txslice
    wire [SLICE_W-1:0] sl = gearbox_slice[gs*SLICE_W +: SLICE_W];
    assign tx_dat_w[gs*2*128 +: 2*128] = sl[SLICE_DAT_LSB +: 2*128];
    assign tx_mty_w[gs*2*4   +: 2*4]   = sl[SLICE_MTY_LSB +: 2*4];
    assign tx_err_w[gs*2     +: 2]     = sl[SLICE_ERR_LSB +: 2];
    assign tx_eop_w[gs*2     +: 2]     = sl[SLICE_EOP_LSB +: 2];
    assign tx_sop_w[gs*2     +: 2]     = sl[SLICE_SOP_LSB +: 2];
    assign tx_ena_w[gs*2     +: 2]     = sl[SLICE_ENA_LSB +: 2];
  end
  endgenerate

  assign tx_seg_valid = gearbox_vld[0];
  assign tx_seg_dat   = tx_dat_w;
  assign tx_seg_mty   = tx_mty_w;
  assign tx_seg_err   = tx_err_w;
  assign tx_seg_eop   = tx_eop_w;
  assign tx_seg_sop   = tx_sop_w;
  assign tx_seg_ena   = tx_ena_w;

  logic [31:0] cycle_r;
  logic [31:0] stall_cnt_r;
  logic        stalled_r;
  logic [31:0] stall_cycle_r;
  logic [7:0]  idle_cnt_r;
  logic        done_r;
  logic [31:0] frames_r;
  logic [31:0] bytes_r;
  logic [3:0]  issued_inc_r;
  logic [3:0]  taken_inc_r;
  logic [11:0] bytes_inc_r;

  wire [11:0] gen_ena = gen_pkt[PKT_ENA_LSB +: 12];
  wire [11:0] gen_eop = gen_pkt[PKT_EOP_LSB +: 12];

  wire [3:0] gen_eop_n = 4'($countones(gen_eop & gen_ena));

  wire beat_taken = tx_seg_valid & tx_seg_ready;

  wire [N_SEG-1:0] taken_ena = tx_seg_ena;
  wire [N_SEG-1:0] taken_eop = tx_seg_eop & tx_seg_ena;

  logic [11:0] beat_bytes_c;
  always_comb begin
    beat_bytes_c = 12'd0;
    for (int b = 0; b < N_SEG; b++) begin
      if (taken_ena[b]) beat_bytes_c += 12'd16;
      if (taken_eop[b]) beat_bytes_c -= 12'(tx_seg_mty[b*4 +: 4]);
    end
  end
  wire [11:0] beat_bytes = beat_bytes_c;

  always_ff @(posedge seg_clk) begin
    if (rst) begin
      cycle_r       <= '0;
      stall_cnt_r   <= '0;
      stalled_r     <= 1'b0;
      stall_cycle_r <= '0;
      idle_cnt_r    <= '0;
      done_r        <= 1'b0;
      issued_r      <= '0;
      frames_r      <= '0;
      bytes_r       <= '0;
      issued_inc_r  <= '0;
      taken_inc_r   <= '0;
      bytes_inc_r   <= '0;
    end else begin
      cycle_r <= cycle_r + 32'd1;
      issued_inc_r <= gen_eop_n;
      taken_inc_r  <= beat_taken ? 4'($countones(taken_eop)) : 4'd0;
      bytes_inc_r  <= beat_taken ? beat_bytes : 12'd0;

      if (!run_r && !enable) begin
        issued_r     <= '0;
        issued_inc_r <= '0;
      end else if (|issued_inc_r) issued_r <= issued_r + 32'(issued_inc_r);

      if (clear) begin
        stalled_r     <= 1'b0;
        stall_cycle_r <= '0;
        stall_cnt_r   <= '0;
        frames_r      <= '0;
        bytes_r       <= '0;
        taken_inc_r   <= '0;
        bytes_inc_r   <= '0;
      end else begin
        frames_r <= frames_r + 32'(taken_inc_r);
        bytes_r  <= bytes_r + 32'(bytes_inc_r);
      end

      if (tx_seg_valid && !tx_seg_ready) begin
        if (stall_cnt_r < 32'(STALL_CYC)) begin
          stall_cnt_r <= stall_cnt_r + 32'd1;
        end else if (!stalled_r) begin
          stalled_r     <= 1'b1;
          stall_cycle_r <= cycle_r;
        end
      end else begin
        stall_cnt_r <= '0;
      end

      if (tx_seg_valid) idle_cnt_r <= '0;
      else if (idle_cnt_r < 8'(IDLE_DONE)) idle_cnt_r <= idle_cnt_r + 8'd1;

      done_r <= limit_hit_r & (idle_cnt_r >= 8'(IDLE_DONE));

      if (!enable) done_r <= 1'b0;
    end
  end

  logic busy_r;

  always_ff @(posedge seg_clk) begin
    if (rst) busy_r <= 1'b0;
    else     busy_r <= run_r | tx_seg_valid;
  end

  assign frames         = frames_r;
  assign bytes          = bytes_r;
  assign latched_frames = pkt_cnt[0][31:0];
  assign latched_bytes  = byte_cnt[0][31:0];
  assign busy           = busy_r;
  assign done           = done_r;
  assign stalled        = stalled_r;
  assign stall_cycle    = stall_cycle_r;
  assign underflow      = gearbox_underflow[0];
  assign overflow       = gearbox_overflow[0];

endmodule

module dcmac_seg_pktmon #(
  parameter int N_SEG        = 2,
  parameter int SEG_W        = 128,
  parameter int NUM_ID       = 6
)(
  input  wire                      seg_clk,
  input  wire                      seg_rstn,
  input  wire                      clear,

  input  wire                      rx_seg_valid,
  input  wire [N_SEG*SEG_W-1:0]    rx_seg_dat,
  input  wire [N_SEG-1:0]          rx_seg_ena,
  input  wire [N_SEG-1:0]          rx_seg_sop,
  input  wire [N_SEG-1:0]          rx_seg_eop,
  input  wire [N_SEG-1:0]          rx_seg_err,
  input  wire [N_SEG*4-1:0]        rx_seg_mty,

  output wire [31:0]               frames,
  output wire [31:0]               bytes,
  output wire [31:0]               latched_frames,
  output wire [31:0]               latched_bytes,
  output wire [31:0]               err_frames,
  output wire [31:0]               mismatch_beats,
  output wire [31:0]               latched_mismatch,
  output wire                      locked
);

  localparam int SLICE_W = 2 + 2 + 2 + 2 + 2*4 + 2*128;

  initial begin
    if (!(N_SEG == 2 || N_SEG == 4 || N_SEG == 8) || SEG_W != 128)
      $fatal(1, "dcmac_seg_pktmon: the client bus is 2, 4 or 8 segments of 128 bits, which is 100GAUI-1, 200GAUI-2 and 400GAUI-4 of PG369 p113. N_SEG=%0d SEG_W=%0d", N_SEG, SEG_W);
  end

  wire rst = ~seg_rstn;

  localparam int NSLICE_RX = N_SEG / 2;
  localparam logic [1:0] RATE_WORD_RX = (N_SEG == 8) ? 2'b10 : (N_SEG == 4) ? 2'b01 : 2'b00;

  wire [6*SLICE_W-1:0] rx_slice;
  genvar gr;
  generate
  for (gr = 0; gr < NSLICE_RX; gr++) begin : g_rxslice
    assign rx_slice[gr*SLICE_W +: SLICE_W] = {rx_seg_ena[gr*2 +: 2], rx_seg_sop[gr*2 +: 2],
                                              rx_seg_eop[gr*2 +: 2], rx_seg_err[gr*2 +: 2],
                                              rx_seg_mty[gr*2*4 +: 2*4],
                                              rx_seg_dat[gr*2*128 +: 2*128]};
  end
  for (gr = NSLICE_RX; gr < 6; gr++) begin : g_rxslice_tied
    assign rx_slice[gr*SLICE_W +: SLICE_W] = '0;
  end
  endgenerate
  wire [5:0]           rx_valid = {5'b0, rx_seg_valid};

  wire [NUM_ID-1:0] clear_counters = {{(NUM_ID-1){1'b0}}, clear};

  localparam int PKT_W = ((NUM_ID == 1) ? 1 : $clog2(NUM_ID)) + 12 + 12 + 12 + 12 + 12*4 + 12*128;

  wire [PKT_W-1:0] mon_pkt;
  logic [PKT_W-1:0] mon_pkt_r;

  always_ff @(posedge seg_clk) mon_pkt_r <= mon_pkt;

  dcmac_seg_pktmon_gearbox u_gearbox (
    .clk                (seg_clk),
    .rst                ({6{rst}}),
    .i_clear_counters   (clear_counters),
    .i_data_rate        ({10'b0, RATE_WORD_RX}),
    .i_valid            (rx_valid),
    .i_preamble         ('0),
    .i_slice            (rx_slice),
    .o_preamble_err_cnt (),
    .o_pkt              (mon_pkt)
  );

  wire [NUM_ID-1:0][63:0] pkt_cnt;
  wire [NUM_ID-1:0][63:0] byte_cnt;
  wire [NUM_ID-1:0][31:0] err_cnt;
  wire [NUM_ID-1:0]       locked_id;
  wire                    err_beat;

  dcmac_seg_pktmon_core #(
    .NUM_ID (NUM_ID)
  ) u_mon (
    .clk              (seg_clk),
    .rst              (rst),
    .port_rst         ({6{rst}}),
    .i_pkt            (mon_pkt_r),
    .i_clear_counters (clear_counters),
    .o_pkt_cnt        (pkt_cnt),
    .o_byte_cnt       (byte_cnt),
    .o_locked         (locked_id),
    .o_err_cnt        (err_cnt),
    .o_err_beat       (err_beat)
  );

  logic [31:0] err_frames_r;
  logic [31:0] frames_r;
  logic [31:0] bytes_r;
  logic [31:0] mismatch_beats_r;
  logic [3:0]  rx_frames_inc_r;
  logic [11:0] rx_bytes_inc_r;

  wire [N_SEG-1:0] rx_eop_q = rx_seg_eop & rx_seg_ena;

  logic [11:0] rx_beat_bytes_c;
  always_comb begin
    rx_beat_bytes_c = 12'd0;
    for (int b = 0; b < N_SEG; b++) begin
      if (rx_seg_ena[b]) rx_beat_bytes_c += 12'd16;
      if (rx_eop_q[b])   rx_beat_bytes_c -= 12'(rx_seg_mty[b*4 +: 4]);
    end
  end
  wire [11:0] rx_beat_bytes = rx_beat_bytes_c;

  wire beat_err = rx_seg_valid & |(rx_seg_err & rx_seg_ena);

  always_ff @(posedge seg_clk) begin
    if (rst || clear) begin
      err_frames_r     <= '0;
      frames_r         <= '0;
      bytes_r          <= '0;
      mismatch_beats_r <= '0;
      rx_frames_inc_r  <= '0;
      rx_bytes_inc_r   <= '0;
    end else begin
      if (err_beat) mismatch_beats_r <= mismatch_beats_r + 32'd1;
      if (beat_err) err_frames_r <= err_frames_r + 32'd1;

      rx_frames_inc_r <= (rx_seg_valid && |rx_seg_ena) ? 4'($countones(rx_eop_q)) : 4'd0;
      rx_bytes_inc_r  <= (rx_seg_valid && |rx_seg_ena) ? rx_beat_bytes : 12'd0;
      frames_r <= frames_r + 32'(rx_frames_inc_r);
      bytes_r  <= bytes_r + 32'(rx_bytes_inc_r);
    end
  end


  assign frames           = frames_r;
  assign bytes            = bytes_r;
  assign latched_frames   = pkt_cnt[0][31:0];
  assign latched_bytes    = byte_cnt[0][31:0];
  assign err_frames       = err_frames_r;
  assign mismatch_beats   = mismatch_beats_r;
  assign latched_mismatch = err_cnt[0];
  assign locked           = locked_id[0];

endmodule
