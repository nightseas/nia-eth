// ---------------------------------------------------------------------------
// File        : dcmac_drp_bridge.sv
// Description : The bridge from the register aperture to the transceiver dynamic
//               reconfiguration port, which presents a 32 bit register view of a 16 bit
//               port as a coherent halfword pair.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module dcmac_drp_bridge #(
  parameter int DRP_ADDR_W  = 24,
  parameter int DRP_DATA_W  = 16,
  parameter int AXIL_ADDR_W = 12,

  parameter int N_WORD      = 16,

  parameter int TIMEOUT_CYC = 64
)(
  input  wire                    clk,
  input  wire                    rstn,

  input  wire [DRP_ADDR_W-1:0]   drp_addr,
  input  wire [DRP_DATA_W-1:0]   drp_di,
  input  wire                    drp_en,
  input  wire                    drp_we,
  output wire [DRP_DATA_W-1:0]   drp_do,
  output wire                    drp_rdy,
  output wire                    busy,

  output wire [AXIL_ADDR_W-1:0]  m_axil_awaddr,
  output wire                    m_axil_awvalid,
  input  wire                    m_axil_awready,
  output wire [31:0]             m_axil_wdata,
  output wire [3:0]              m_axil_wstrb,
  output wire                    m_axil_wvalid,
  input  wire                    m_axil_wready,
  input  wire [1:0]              m_axil_bresp,
  input  wire                    m_axil_bvalid,
  output wire                    m_axil_bready,
  output wire [AXIL_ADDR_W-1:0]  m_axil_araddr,
  output wire                    m_axil_arvalid,
  input  wire                    m_axil_arready,
  input  wire [31:0]             m_axil_rdata,
  input  wire [1:0]              m_axil_rresp,
  input  wire                    m_axil_rvalid,
  output wire                    m_axil_rready
);

  localparam logic [15:0] SENT_OOR     = 16'hBAD0;
  localparam logic [15:0] SENT_TIMEOUT = 16'hBAD1;
  localparam logic [5:0]  STS_WORD     = 6'h3F;

  localparam logic [2:0] S_IDLE = 3'd0,
                         S_RD   = 3'd1,
                         S_RDW  = 3'd2,
                         S_WR   = 3'd3,
                         S_WRB  = 3'd4,
                         S_ANS  = 3'd5;

  logic [2:0]  state;
  logic [15:0] ans;
  logic [31:0] shadow;
  logic [5:0]  word_q;
  logic        half_q;
  logic [15:0] di_q;
  logic [$clog2(TIMEOUT_CYC+1)-1:0] to_cnt;

  logic        awv, wv, arv, bready_r, rready_r;
  logic [31:0] wdata_r;
  logic [3:0]  wstrb_r;

  logic        sts_to, sts_oor;
  logic [6:0]  cnt_to, cnt_oor;

  wire [5:0]  d_word = drp_addr[6:1];
  wire        d_half = drp_addr[0];
  wire        d_hi_z = (DRP_ADDR_W > 7) ? (drp_addr[DRP_ADDR_W-1:7] == '0) : 1'b1;
  wire        d_sts  = d_hi_z && (d_word == STS_WORD);

  wire        d_ok   = d_hi_z && (d_word < 6'(N_WORD));

  wire [15:0] sts_word = {cnt_to[6:0], 1'b0, 6'b0, sts_oor, sts_to};

  assign drp_do        = ans;
  assign drp_rdy       = (state == S_ANS);
  assign busy          = (state != S_IDLE);
  assign m_axil_awaddr = {{(AXIL_ADDR_W-8){1'b0}}, word_q, 2'b00};
  assign m_axil_araddr = {{(AXIL_ADDR_W-8){1'b0}}, word_q, 2'b00};
  assign m_axil_awvalid = awv;
  assign m_axil_wvalid  = wv;
  assign m_axil_arvalid = arv;
  assign m_axil_wdata   = wdata_r;
  assign m_axil_wstrb   = wstrb_r;
  assign m_axil_bready  = bready_r;
  assign m_axil_rready  = rready_r;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      state <= S_IDLE; ans <= 16'h0; shadow <= 32'h0;
      word_q <= 6'h0; half_q <= 1'b0; di_q <= 16'h0; to_cnt <= '0;
      awv <= 1'b0; wv <= 1'b0; arv <= 1'b0; bready_r <= 1'b0; rready_r <= 1'b0;
      wdata_r <= 32'h0; wstrb_r <= 4'h0;
      sts_to <= 1'b0; sts_oor <= 1'b0; cnt_to <= 7'h0; cnt_oor <= 7'h0;
    end else begin
      case (state)
        S_IDLE: begin
          if (drp_en) begin
            word_q <= d_word;
            half_q <= d_half;
            di_q   <= drp_di;
            to_cnt <= '0;
            if (d_sts) begin

              ans <= sts_word;
              if (drp_we) begin
                if (drp_di[0]) sts_to  <= 1'b0;
                if (drp_di[1]) sts_oor <= 1'b0;
              end
              state <= S_ANS;
            end else if (!d_ok) begin

              ans     <= SENT_OOR;
              sts_oor <= 1'b1;
              if (cnt_oor != 7'h7F) cnt_oor <= cnt_oor + 7'd1;
              state   <= S_ANS;
            end else if (drp_we) begin
              wdata_r <= d_half ? {drp_di, 16'h0} : {16'h0, drp_di};
              wstrb_r <= d_half ? 4'b1100 : 4'b0011;
              awv     <= 1'b1;
              wv      <= 1'b1;
              state   <= S_WR;
            end else if (d_half) begin

              ans   <= shadow[31:16];
              state <= S_ANS;
            end else begin
              arv   <= 1'b1;
              state <= S_RD;
            end
          end
        end

        S_RD: begin
          to_cnt <= to_cnt + 1'b1;
          if (m_axil_arready) begin
            arv      <= 1'b0;
            rready_r <= 1'b1;
            to_cnt   <= '0;
            state    <= S_RDW;
          end else if (to_cnt >= TIMEOUT_CYC[$bits(to_cnt)-1:0]) begin
            arv    <= 1'b0;
            ans    <= SENT_TIMEOUT;
            sts_to <= 1'b1;
            if (cnt_to != 7'h7F) cnt_to <= cnt_to + 7'd1;
            state  <= S_ANS;
          end
        end
        S_RDW: begin
          to_cnt <= to_cnt + 1'b1;
          if (m_axil_rvalid) begin
            rready_r <= 1'b0;
            shadow   <= m_axil_rdata;
            ans      <= m_axil_rdata[15:0];
            state    <= S_ANS;
          end else if (to_cnt >= TIMEOUT_CYC[$bits(to_cnt)-1:0]) begin
            rready_r <= 1'b0;
            ans      <= SENT_TIMEOUT;
            sts_to   <= 1'b1;
            if (cnt_to != 7'h7F) cnt_to <= cnt_to + 7'd1;
            state    <= S_ANS;
          end
        end

        S_WR: begin
          to_cnt <= to_cnt + 1'b1;
          if (m_axil_awready) awv <= 1'b0;
          if (m_axil_wready)  wv  <= 1'b0;
          if ((!awv || m_axil_awready) && (!wv || m_axil_wready)) begin
            bready_r <= 1'b1;
            to_cnt   <= '0;
            state    <= S_WRB;
          end else if (to_cnt >= TIMEOUT_CYC[$bits(to_cnt)-1:0]) begin
            awv    <= 1'b0;
            wv     <= 1'b0;
            ans    <= SENT_TIMEOUT;
            sts_to <= 1'b1;
            if (cnt_to != 7'h7F) cnt_to <= cnt_to + 7'd1;
            state  <= S_ANS;
          end
        end
        S_WRB: begin
          to_cnt <= to_cnt + 1'b1;
          if (m_axil_bvalid) begin
            bready_r <= 1'b0;

            ans      <= 16'h0;
            state    <= S_ANS;
          end else if (to_cnt >= TIMEOUT_CYC[$bits(to_cnt)-1:0]) begin
            bready_r <= 1'b0;
            ans      <= SENT_TIMEOUT;
            sts_to   <= 1'b1;
            if (cnt_to != 7'h7F) cnt_to <= cnt_to + 7'd1;
            state    <= S_ANS;
          end
        end

        S_ANS: begin
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  // synthesis translate_off
  initial begin
    if (DRP_DATA_W != 16)
      $fatal(1, "dcmac_drp_bridge: violated - DRP_DATA_W=%0d; the reference's rb_drp instantiation is 16 and changing it moves fpga_core.v", DRP_DATA_W);
    if (AXIL_ADDR_W < 8)
      $fatal(1, "dcmac_drp_bridge: AXIL_ADDR_W=%0d cannot reach the window", AXIL_ADDR_W);
    if (N_WORD < 16)
      $fatal(1, "dcmac_drp_bridge: N_WORD=%0d is below the 16 words dcmac_link_csr has always had (0x00..0x3C)", N_WORD);
    if (N_WORD >= STS_WORD)
      $fatal(1, "dcmac_drp_bridge: N_WORD=%0d reaches word 0x3F, which is THIS module's own status word and is never forwarded", N_WORD);
    if (TIMEOUT_CYC < 8)
      $fatal(1, "dcmac_drp_bridge: violated - TIMEOUT_CYC=%0d is shorter than the CSR's own registered read latency, so a HEALTHY access would report a timeout", TIMEOUT_CYC);
  end
  // synthesis translate_on

endmodule

`default_nettype wire
