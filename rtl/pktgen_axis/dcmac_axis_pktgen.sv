// ---------------------------------------------------------------------------
// File        : dcmac_axis_pktgen.sv
// Description : The AXI-Stream traffic instrument and its register block, which sits on
//               the stream side of the adapter so the traffic it generates passes through
//               the adapter rather than around it.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module dcmac_axis_pktgen #(

  parameter integer DATA_W      = 512,
  parameter integer TX_USER_W   = 1,
  parameter integer RX_USER_W   = 1,
  parameter integer AXIL_ADDR_W = 12,
  parameter bit     SAME_CLOCK  = 1'b1,
  parameter integer LEN_MIN_HW  = 64,
  parameter integer LEN_MAX_HW  = 1518,
  parameter [31:0]  MODULE_TYPE = 32'h4E415047,
  parameter [31:0]  MAP_VERSION = 32'h0003_0001
)(
  input  wire                      net_clk,
  input  wire                      net_rstn,

  output wire [DATA_W-1:0]         m_axis_tx_tdata,
  output wire [DATA_W/8-1:0]       m_axis_tx_tkeep,
  output wire                      m_axis_tx_tvalid,
  input  wire                      m_axis_tx_tready,
  output wire                      m_axis_tx_tlast,
  output wire [TX_USER_W-1:0]      m_axis_tx_tuser,

  input  wire [DATA_W-1:0]         s_axis_rx_tdata,
  input  wire [DATA_W/8-1:0]       s_axis_rx_tkeep,
  input  wire                      s_axis_rx_tvalid,
  input  wire                      s_axis_rx_tlast,
  input  wire [RX_USER_W-1:0]      s_axis_rx_tuser,

  input  wire                      link_up,

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
  localparam int KEEP_W = DATA_W/8;
  localparam int HDR_B  = 42;

  localparam int WORD_W = 6;
  localparam logic [WORD_W-1:0] WORD_MODULE_TYPE         = 6'h00;
  localparam logic [WORD_W-1:0] WORD_MAP_VERSION         = 6'h01;
  localparam logic [WORD_W-1:0] WORD_BUS_CHECK           = 6'h02;
  localparam logic [WORD_W-1:0] WORD_AXIS_GEOMETRY       = 6'h03;
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

  localparam int CTL_ENABLE_BIT = 0;
  localparam int CTL_CLEAR_BIT  = 1;

  localparam int ST_BUSY_BIT     = 0;
  localparam int ST_DONE_BIT     = 1;
  localparam int ST_RXLOCKED_BIT = 5;
  localparam int ST_LINKUP_BIT   = 6;

  localparam int CTL_HDR_ENABLE_BIT = 0;

  logic        cfg_enable_r;
  logic        cfg_clear_r;
  logic [15:0] cfg_len_min_r;
  logic [15:0] cfg_len_max_r;
  logic [1:0]  cfg_len_mode_r;
  logic [31:0] cfg_frame_limit_r;
  logic [31:0] cfg_bus_check_r;
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

  wire [1:0] ctl_sync;
  dcmac_sync2 #(.WIDTH(2)) u_ctl_sync (
    .clk  (net_clk),
    .din  ({cfg_clear_r, cfg_enable_r}),
    .dout (ctl_sync)
  );
  wire net_enable = ctl_sync[0];
  wire net_clear  = ctl_sync[1];

  logic [15:0] net_len_min_r, net_len_max_r;
  logic [1:0]  net_len_mode_r;
  logic [31:0] net_frame_limit_r;
  always_ff @(posedge net_clk) begin
    if (!net_rstn) begin
      net_len_min_r     <= 16'(LEN_MIN_HW);
      net_len_max_r     <= 16'(LEN_MAX_HW);
      net_len_mode_r    <= '0;
      net_frame_limit_r <= '0;
    end else begin
      net_len_min_r     <= cfg_len_min_r;
      net_len_max_r     <= cfg_len_max_r;
      net_len_mode_r    <= cfg_len_mode_r;
      net_frame_limit_r <= cfg_frame_limit_r;
    end
  end

  wire link_up_net;
  dcmac_sync2 #(.WIDTH(1)) u_link_sync (
    .clk  (net_clk),
    .din  (link_up),
    .dout (link_up_net)
  );

  wire [15:0] len_next;

  wire [15:0] hdr_ip_length  = len_next - 16'd14;
  wire [15:0] hdr_udp_length = len_next - 16'd34;

  logic [7:0] hdr_byte_cfg [HDR_B];
  always_comb begin
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
    hdr_byte_cfg[16] = hdr_ip_length[15:8];
    hdr_byte_cfg[17] = hdr_ip_length[7:0];
    hdr_byte_cfg[18] = cfg_hdr_ip_id_flags_r[7:0];
    hdr_byte_cfg[19] = cfg_hdr_ip_id_flags_r[15:8];
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

  logic [HDR_B*8-1:0] hdr_flat;
  always_comb for (int i = 0; i < HDR_B; i++) hdr_flat[i*8 +: 8] = hdr_byte_cfg[i];

  wire [15:0] src_len_eff;
  wire        src_clamp;
  wire [31:0] src_tx_frames;
  wire [31:0] src_tx_bytes;
  wire        src_busy;
  wire        src_done;

  dcmac_axis_frame_src #(
    .DATA_W(DATA_W), .USER_W(TX_USER_W),
    .LEN_MIN_HW(LEN_MIN_HW), .LEN_MAX_HW(LEN_MAX_HW), .HDR_B(HDR_B)
  ) u_src (
    .clk              (net_clk),
    .rstn             (net_rstn),
    .ctl_enable       (net_enable),
    .ctl_clear        (net_clear),
    .cfg_len_min      (net_len_min_r),
    .cfg_len_max      (net_len_max_r),
    .cfg_len_mode     (net_len_mode_r),
    .cfg_frame_limit  (net_frame_limit_r),
    .cfg_hdr_enable   (cfg_hdr_enable_r),
    .cfg_hdr_bytes    (hdr_flat),
    .m_axis_tdata     (m_axis_tx_tdata),
    .m_axis_tkeep     (m_axis_tx_tkeep),
    .m_axis_tvalid    (m_axis_tx_tvalid),
    .m_axis_tready    (m_axis_tx_tready),
    .m_axis_tlast     (m_axis_tx_tlast),
    .m_axis_tuser     (m_axis_tx_tuser),
    .len_next         (len_next),
    .len_effective    (src_len_eff),
    .len_clamp_sticky (src_clamp),
    .tx_frames        (src_tx_frames),
    .tx_bytes         (src_tx_bytes),
    .busy             (src_busy),
    .done             (src_done)
  );

  wire [31:0] chk_rx_frames;
  wire [31:0] chk_rx_bytes;
  wire [31:0] chk_rx_err;
  wire [31:0] chk_rx_mis;
  wire        chk_locked;

  dcmac_axis_frame_chk #(
    .DATA_W(DATA_W), .USER_W(RX_USER_W), .HDR_B(HDR_B)
  ) u_chk (
    .clk               (net_clk),
    .rstn              (net_rstn),
    .ctl_clear         (net_clear),
    .cfg_hdr_enable    (cfg_hdr_enable_r),
    .s_axis_tdata      (s_axis_rx_tdata),
    .s_axis_tkeep      (s_axis_rx_tkeep),
    .s_axis_tvalid     (s_axis_rx_tvalid),
    .s_axis_tlast      (s_axis_rx_tlast),
    .s_axis_tuser      (s_axis_rx_tuser),
    .rx_frames         (chk_rx_frames),
    .rx_bytes          (chk_rx_bytes),
    .rx_err_frames     (chk_rx_err),
    .rx_mismatch_beats (chk_rx_mis),
    .rx_locked         (chk_locked)
  );

  localparam int SNAP_W = 32*6 + 16 + 6;
  wire [SNAP_W-1:0] snap_net = {
    {3'b000, chk_locked, src_done, src_busy},
    src_len_eff,
    chk_rx_mis, chk_rx_err, chk_rx_bytes, chk_rx_frames, src_tx_bytes, src_tx_frames
  };

  wire [SNAP_W-1:0] snap;
  wire [7:0]        snap_rounds;

  dcmac_csr_snap #(.WIDTH(SNAP_W), .SAME_CLOCK(SAME_CLOCK)) u_snap (
    .s_clk  (net_clk),
    .s_rstn (net_rstn),
    .din    (snap_net),
    .m_clk  (axil_aclk),
    .m_rstn (axil_aresetn),
    .dout   (snap),
    .rounds (snap_rounds)
  );

  wire [31:0] snap_tx_frames = snap[31:0];
  wire [31:0] snap_tx_bytes  = snap[63:32];
  wire [31:0] snap_rx_frames = snap[95:64];
  wire [31:0] snap_rx_bytes  = snap[127:96];
  wire [31:0] snap_rx_err    = snap[159:128];
  wire [31:0] snap_rx_mis    = snap[191:160];
  wire [15:0] snap_len_eff   = snap[207:192];
  wire        snap_busy      = snap[208];
  wire        snap_done      = snap[209];
  wire        snap_locked    = snap[210];

  wire        clamp_axil;
  if (SAME_CLOCK) begin : g_clamp_same_clock
    assign clamp_axil = src_clamp;
  end else begin : g_clamp_sync
    dcmac_sync2 #(.WIDTH(1)) u_clamp_sync (
      .clk  (axil_aclk),
      .din  (src_clamp),
      .dout (clamp_axil)
    );
  end
  wire        linkup_axil = link_up;

  logic [31:0] status_word;
  always_comb begin
    status_word = 32'd0;
    status_word[ST_BUSY_BIT]     = snap_busy;
    status_word[ST_DONE_BIT]     = snap_done;
    status_word[ST_RXLOCKED_BIT] = snap_locked;
    status_word[ST_LINKUP_BIT]   = linkup_axil;
  end

  logic        awready_r, wready_r, bvalid_r, arready_r, rvalid_r;
  logic        wr_ack_r, rd_ack_r;
  logic [31:0] rdata_r;
  logic [1:0]  rresp_r;
  logic [1:0]  bresp_r;

  wire [WORD_W-1:0] aw_word = s_axil_awaddr[WORD_W+1:2];
  wire [WORD_W-1:0] ar_word = s_axil_araddr[WORD_W+1:2];

  function automatic logic word_mapped(input logic [WORD_W-1:0] w);
    case (w)
      WORD_MODULE_TYPE, WORD_MAP_VERSION, WORD_BUS_CHECK, WORD_AXIS_GEOMETRY, WORD_FEATURES,
      WORD_CTL, WORD_STATUS, WORD_LEN_MIN, WORD_LEN_MAX, WORD_LEN_MODE, WORD_LEN_EFFECTIVE,
      WORD_LEN_CLAMP_STICKY, WORD_TX_FRAME_LIMIT, WORD_SNAPSHOT_ROUNDS,
      WORD_TX_FRAMES, WORD_TX_BYTES, WORD_RX_FRAMES, WORD_RX_BYTES, WORD_RX_ERR_FRAMES,
      WORD_RX_MISMATCH_BEATS,
      WORD_HDR_CTL, WORD_HDR_DST_MAC_LOW, WORD_HDR_DST_MAC_HIGH, WORD_HDR_SRC_MAC_LOW,
      WORD_HDR_SRC_MAC_HIGH, WORD_HDR_ETHERTYPE, WORD_HDR_IP_VERSION_TOS, WORD_HDR_IP_ID_FLAGS,
      WORD_HDR_IP_TTL_PROTOCOL, WORD_HDR_IP_SRC_ADDR, WORD_HDR_IP_DST_ADDR,
      WORD_HDR_UDP_PORTS: return 1'b1;
      default:            return 1'b0;
    endcase
  endfunction

  function automatic logic [31:0] register_read(input logic [WORD_W-1:0] w);
    case (w)
      WORD_MODULE_TYPE:       return MODULE_TYPE;
      WORD_MAP_VERSION:       return MAP_VERSION;
      WORD_BUS_CHECK:         return cfg_bus_check_r;
      WORD_AXIS_GEOMETRY:     return {16'(KEEP_W), 16'(DATA_W)};
      WORD_FEATURES:          return 32'h0000_0001;
      WORD_CTL:               return {30'd0, cfg_clear_r, cfg_enable_r};
      WORD_STATUS:            return status_word;
      WORD_LEN_MIN:           return {16'd0, cfg_len_min_r};
      WORD_LEN_MAX:           return {16'd0, cfg_len_max_r};
      WORD_LEN_MODE:          return {30'd0, cfg_len_mode_r};
      WORD_LEN_EFFECTIVE:     return {16'd0, snap_len_eff};
      WORD_LEN_CLAMP_STICKY:  return {31'd0, clamp_axil};
      WORD_TX_FRAME_LIMIT:    return cfg_frame_limit_r;
      WORD_SNAPSHOT_ROUNDS:   return {24'd0, snap_rounds};
      WORD_TX_FRAMES:         return snap_tx_frames;
      WORD_TX_BYTES:          return snap_tx_bytes;
      WORD_RX_FRAMES:         return snap_rx_frames;
      WORD_RX_BYTES:          return snap_rx_bytes;
      WORD_RX_ERR_FRAMES:     return snap_rx_err;
      WORD_RX_MISMATCH_BEATS: return snap_rx_mis;
      WORD_HDR_CTL:           return {31'd0, cfg_hdr_enable_r};
      WORD_HDR_DST_MAC_LOW:   return cfg_hdr_dst_mac_low_r;
      WORD_HDR_DST_MAC_HIGH:  return cfg_hdr_dst_mac_high_r;
      WORD_HDR_SRC_MAC_LOW:   return cfg_hdr_src_mac_low_r;
      WORD_HDR_SRC_MAC_HIGH:  return cfg_hdr_src_mac_high_r;
      WORD_HDR_ETHERTYPE:     return cfg_hdr_ethertype_r;
      WORD_HDR_IP_VERSION_TOS:return cfg_hdr_ip_version_tos_r;
      WORD_HDR_IP_ID_FLAGS:   return cfg_hdr_ip_id_flags_r;
      WORD_HDR_IP_TTL_PROTOCOL:return cfg_hdr_ip_ttl_protocol_r;
      WORD_HDR_IP_SRC_ADDR:   return cfg_hdr_ip_src_addr_r;
      WORD_HDR_IP_DST_ADDR:   return cfg_hdr_ip_dst_addr_r;
      WORD_HDR_UDP_PORTS:     return cfg_hdr_udp_ports_r;
      default:                return 32'd0;
    endcase
  endfunction

  wire wr_fire = s_axil_awvalid & s_axil_wvalid & ~bvalid_r & ~wr_ack_r;
  wire rd_fire = s_axil_arvalid & ~rvalid_r & ~rd_ack_r;

  always_ff @(posedge axil_aclk) begin
    if (!axil_aresetn) begin
      awready_r <= 1'b0; wready_r <= 1'b0; bvalid_r <= 1'b0; bresp_r <= 2'b00;
      arready_r <= 1'b0; rvalid_r <= 1'b0; rdata_r <= 32'd0; rresp_r <= 2'b00;
      wr_ack_r  <= 1'b0; rd_ack_r <= 1'b0;
      cfg_enable_r <= 1'b0;
      cfg_clear_r  <= 1'b0;
      cfg_len_min_r <= 16'(LEN_MIN_HW);
      cfg_len_max_r <= 16'(LEN_MIN_HW);
      cfg_len_mode_r <= 2'd0;
      cfg_frame_limit_r <= 32'd0;
      cfg_bus_check_r <= 32'd0;
      cfg_hdr_enable_r <= 1'b0;
      cfg_hdr_dst_mac_low_r <= 32'd0;
      cfg_hdr_dst_mac_high_r <= 32'd0;
      cfg_hdr_src_mac_low_r <= 32'd0;
      cfg_hdr_src_mac_high_r <= 32'd0;
      cfg_hdr_ethertype_r <= 32'h0000_0800;
      cfg_hdr_ip_version_tos_r <= 32'h0000_0045;
      cfg_hdr_ip_id_flags_r <= 32'd0;
      cfg_hdr_ip_ttl_protocol_r <= 32'h0000_1140;
      cfg_hdr_ip_src_addr_r <= 32'd0;
      cfg_hdr_ip_dst_addr_r <= 32'd0;
      cfg_hdr_udp_ports_r <= 32'd0;
    end else begin
      awready_r <= 1'b0;
      wready_r  <= 1'b0;
      arready_r <= 1'b0;
      wr_ack_r  <= 1'b0;
      rd_ack_r  <= 1'b0;

      if (bvalid_r && s_axil_bready) bvalid_r <= 1'b0;
      if (rvalid_r && s_axil_rready) rvalid_r <= 1'b0;

      if (wr_ack_r) bvalid_r <= 1'b1;
      if (rd_ack_r) rvalid_r <= 1'b1;

      if (wr_fire) begin
        awready_r <= 1'b1;
        wready_r  <= 1'b1;
        wr_ack_r  <= 1'b1;
        bresp_r   <= word_mapped(aw_word) ? 2'b00 : 2'b10;
        case (aw_word)
          WORD_BUS_CHECK:          cfg_bus_check_r <= s_axil_wdata;
          WORD_CTL:                begin
                                     cfg_enable_r <= s_axil_wdata[CTL_ENABLE_BIT];
                                     cfg_clear_r  <= s_axil_wdata[CTL_CLEAR_BIT];
                                   end
          WORD_LEN_MIN:            cfg_len_min_r <= s_axil_wdata[15:0];
          WORD_LEN_MAX:            cfg_len_max_r <= s_axil_wdata[15:0];
          WORD_LEN_MODE:           cfg_len_mode_r <= s_axil_wdata[1:0];
          WORD_TX_FRAME_LIMIT:     cfg_frame_limit_r <= s_axil_wdata;
          WORD_HDR_CTL:            cfg_hdr_enable_r <= s_axil_wdata[CTL_HDR_ENABLE_BIT];
          WORD_HDR_DST_MAC_LOW:    cfg_hdr_dst_mac_low_r <= s_axil_wdata;
          WORD_HDR_DST_MAC_HIGH:   cfg_hdr_dst_mac_high_r <= s_axil_wdata;
          WORD_HDR_SRC_MAC_LOW:    cfg_hdr_src_mac_low_r <= s_axil_wdata;
          WORD_HDR_SRC_MAC_HIGH:   cfg_hdr_src_mac_high_r <= s_axil_wdata;
          WORD_HDR_ETHERTYPE:      cfg_hdr_ethertype_r <= s_axil_wdata;
          WORD_HDR_IP_VERSION_TOS: cfg_hdr_ip_version_tos_r <= s_axil_wdata;
          WORD_HDR_IP_ID_FLAGS:    cfg_hdr_ip_id_flags_r <= s_axil_wdata;
          WORD_HDR_IP_TTL_PROTOCOL:cfg_hdr_ip_ttl_protocol_r <= s_axil_wdata;
          WORD_HDR_IP_SRC_ADDR:    cfg_hdr_ip_src_addr_r <= s_axil_wdata;
          WORD_HDR_IP_DST_ADDR:    cfg_hdr_ip_dst_addr_r <= s_axil_wdata;
          WORD_HDR_UDP_PORTS:      cfg_hdr_udp_ports_r <= s_axil_wdata;
          default: ;
        endcase
      end

      if (rd_fire) begin
        arready_r <= 1'b1;
        rd_ack_r  <= 1'b1;
        rdata_r   <= register_read(ar_word);
        rresp_r   <= word_mapped(ar_word) ? 2'b00 : 2'b10;
      end
    end
  end

  assign s_axil_awready = awready_r;
  assign s_axil_wready  = wready_r;
  assign s_axil_bvalid  = bvalid_r;
  assign s_axil_bresp   = bresp_r;
  assign s_axil_arready = arready_r;
  assign s_axil_rvalid  = rvalid_r;
  assign s_axil_rdata   = rdata_r;
  assign s_axil_rresp   = rresp_r;

  wire _unused = &{1'b0, s_axil_wstrb, link_up_net, 1'b0};
endmodule
