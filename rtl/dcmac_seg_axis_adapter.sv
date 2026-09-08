// ---------------------------------------------------------------------------
// File        : dcmac_seg_axis_adapter.sv
// Description : The segment to stream mapping in both directions. The receive side stores
//               segments in a lane banked ring and reads one stream beat per cycle from
//               it, so the segment count sets the addressing and never the logic depth.
//               The transmit side cuts a beat into segments and packs them, so a frame
//               occupies ceil(length/SEG_B) segments rather than whole segmented cycles
//               and a start of packet reaches any segment.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

// The transmit segment packer. The mechanism is AMD's axis_unseg_to_seg_converter, specified
// item by item in nia-dev/doc/study/AMD_TX_MECHANISM_SPEC.md. Four stages:
//
//   S1  cut one DATA_W beat into SLOTS segment records, one per SEG_W of the beat, and mark
//       valid, start of packet, end of packet, error and empty count. The reference does
//       this at its lines 3475, 3489, 3507 and 3460.
//   S2  give each valid slot a destination in the segment ring at a write pointer retained
//       across cycles, so the short tail of a frame leaves no hole, and capture the
//       destination as a registered select. The reference does this at its lines 4020 to
//       4027 and 4037.
//   S3  write the ring through a multiplex whose select is the register S2 produced, so no
//       prefix sum stands in series with a SEG_W wide multiplex. The reference does this at
//       its line 4145.
//   S4  read N_SEG consecutive ring entries at a read pointer and present them as one
//       segmented cycle.
//
// The DCMAC forbids a segment valid that goes low between a start and an end of packet
// (reference lines 72 to 74). The property that holds it here is the run end pointer. The
// run end is set to one past an end of packet each time an end of packet lands in the ring,
// and release is permitted only below the run end. Three consequences follow. Every entry
// released is valid, because writes are contiguous and the run end never exceeds the landed
// write position. A release that carries fewer than N_SEG segments ends exactly at the run
// end, so its last enabled segment carries an end of packet and the valid deassertion
// coincides with it. A release that carries N_SEG segments and does not reach the run end is
// followed by another release on the next cycle, so a frame open at a beat boundary is
// continued with no gap. Where the read pointer reaches the run end the last segment
// released was an end of packet, so an idle segmented cycle there is aligned with an end of
// packet.
//
// A start of packet is set on slot 0 of the first beat of a frame only, and reaches a
// segment other than segment 0 through the write pointer alone, as the reference does at its
// lines 3460 and 3464. Because the ring is written contiguously, a start of packet on
// segment k for k above 0 is immediately preceded on segment k-1 by the end of packet of the
// previous frame, which is the placement PG369 permits.
//
// The input stream shall present the beats of one frame on consecutive cycles once its first
// beat has been accepted. dcmac_axis_frame_fifo provides that: it commits on tlast and
// offers from the committed pointer. This is checklist item 4 of the specification.

module dcmac_seg_axis_tx #(
  parameter int N_SEG  = 2,
  parameter int SEG_W  = 128,
  parameter int DATA_W = N_SEG*SEG_W
)(
  input  logic                       clk,
  input  logic                       rstn,

  input  logic [DATA_W-1:0]          s_axis_tdata,
  input  logic [DATA_W/8-1:0]        s_axis_tkeep,
  input  logic                       s_axis_tvalid,
  output logic                       s_axis_tready,
  input  logic                       s_axis_tlast,
  input  logic                       s_axis_tuser,

  input  logic                       tx_seg_ready,
  output logic                       tx_seg_valid,
  output logic [N_SEG*SEG_W-1:0]     tx_seg_dat,
  output logic [N_SEG-1:0]           tx_seg_ena,
  output logic [N_SEG-1:0]           tx_seg_sop,
  output logic [N_SEG-1:0]           tx_seg_eop,
  output logic [N_SEG-1:0]           tx_seg_err,
  output logic [N_SEG*4-1:0]         tx_seg_mty
);
  localparam int SEG_B     = SEG_W/8;
  localparam int MTY_W     = 4;
  localparam int SLOTS     = DATA_W/SEG_W;
  localparam int RING_MIN  = (2*SLOTS + 2*N_SEG > 4*N_SEG) ? 2*SLOTS + 2*N_SEG : 4*N_SEG;
  localparam int RING      = 1 << $clog2(RING_MIN);
  localparam int ADDR_W    = $clog2(RING);
  localparam int PTR_W     = ADDR_W + 2;
  localparam int SLOT_IX_W = (SLOTS > 1) ? $clog2(SLOTS) : 1;
  localparam int CNT_W     = $clog2(N_SEG+1);

  initial begin
    if (DATA_W % SEG_W != 0)
      $fatal(1, "dcmac_seg_axis_tx: DATA_W %0d is not a multiple of SEG_W %0d", DATA_W, SEG_W);
    if (SLOTS < N_SEG)
      $fatal(1, "dcmac_seg_axis_tx: one beat carries %0d slots against %0d segments per segmented cycle, so the packer cannot feed the segmented interface", SLOTS, N_SEG);
    if (RING < SLOTS + 2*N_SEG)
      $fatal(1, "dcmac_seg_axis_tx: ring of %0d entries cannot hold one beat of %0d slots and two released groups of %0d", RING, SLOTS, N_SEG);
    if (SEG_B > (1 << MTY_W))
      $fatal(1, "dcmac_seg_axis_tx: SEG_B %0d does not fit the %0d bit empty count", SEG_B, MTY_W);
  end

  logic [PTR_W-1:0] write_ptr, read_ptr, landed_ptr;
  logic             landed_tail_eop;
  logic             accept;
  logic             input_first_beat;
  logic             stage2_take;
  logic             ring_room;
  logic [PTR_W-1:0] ring_occupancy;

  logic [SEG_W-1:0] slot_data_c [SLOTS];
  logic [MTY_W-1:0] slot_mty_c  [SLOTS];
  logic [SLOTS-1:0] slot_val_c, slot_sop_c, slot_eop_c, slot_err_c;

  always_comb begin
    slot_val_c = '0;
    slot_eop_c = '0;
    slot_sop_c = '0;
    slot_err_c = '0;
    for (int j = 0; j < SLOTS; j++) begin
      logic [SEG_B-1:0] keep_slot;
      logic             val_here, val_next;
      keep_slot      = s_axis_tkeep[j*SEG_B +: SEG_B];
      val_here       = |keep_slot;
      val_next       = (j == SLOTS-1) ? 1'b0 : |s_axis_tkeep[(j+1)*SEG_B +: SEG_B];
      slot_val_c[j]  = val_here;
      slot_eop_c[j]  = val_here & ~val_next & s_axis_tlast;
      slot_sop_c[j]  = val_here & input_first_beat & (j == 0);
      slot_err_c[j]  = slot_eop_c[j] & s_axis_tuser;
      slot_data_c[j] = s_axis_tdata[j*SEG_W +: SEG_W];
      slot_mty_c[j]  = MTY_W'(SEG_B) - MTY_W'($countones(keep_slot));
    end
  end

  logic             s1_valid;
  logic [SEG_W-1:0] s1_data [SLOTS];
  logic [MTY_W-1:0] s1_mty  [SLOTS];
  logic [SLOTS-1:0] s1_val, s1_sop, s1_eop, s1_err;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      s1_valid         <= 1'b0;
      s1_val           <= '0;
      s1_sop           <= '0;
      s1_eop           <= '0;
      s1_err           <= '0;
      input_first_beat <= 1'b1;
    end else begin
      if (accept) begin
        s1_valid <= 1'b1;
        s1_val   <= slot_val_c;
        s1_sop   <= slot_sop_c;
        s1_eop   <= slot_eop_c;
        s1_err   <= slot_err_c;
      end else if (stage2_take) begin
        s1_valid <= 1'b0;
        s1_val   <= '0;
        s1_sop   <= '0;
        s1_eop   <= '0;
        s1_err   <= '0;
      end
      if (accept) input_first_beat <= s_axis_tlast;
    end
  end

  always_ff @(posedge clk) begin
    if (accept) begin
      for (int j = 0; j < SLOTS; j++) begin
        s1_data[j] <= slot_data_c[j];
        s1_mty[j]  <= slot_mty_c[j];
      end
    end
  end

  logic [PTR_W-1:0] slot_dest_c [SLOTS];
  logic [PTR_W-1:0] write_ptr_next_c;
  logic             beat_ends_frame_c;

  always_comb begin
    logic [PTR_W-1:0] running;
    running           = write_ptr;
    beat_ends_frame_c = 1'b0;
    for (int j = 0; j < SLOTS; j++) begin
      slot_dest_c[j] = running;
      if (s1_val[j]) begin
        running = running + PTR_W'(1);
        if (s1_eop[j]) beat_ends_frame_c = 1'b1;
      end
    end
    write_ptr_next_c = running;
  end

  logic [RING-1:0]      s2_write_en_c;
  logic [SLOT_IX_W-1:0] s2_write_sel_c [RING];

  always_comb begin
    s2_write_en_c = '0;
    for (int d = 0; d < RING; d++) s2_write_sel_c[d] = '0;
    for (int j = 0; j < SLOTS; j++) begin
      if (s1_val[j]) begin
        s2_write_en_c [slot_dest_c[j][ADDR_W-1:0]] = 1'b1;
        s2_write_sel_c[slot_dest_c[j][ADDR_W-1:0]] = SLOT_IX_W'(j);
      end
    end
  end

  logic [RING-1:0]      s2_write_en;
  logic [SLOT_IX_W-1:0] s2_write_sel [RING];
  logic [SEG_W-1:0]     s2_data [SLOTS];
  logic [MTY_W-1:0]     s2_mty  [SLOTS];
  logic [SLOTS-1:0]     s2_sop, s2_eop, s2_err;
  logic                 s2_tail_eop;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      write_ptr   <= '0;
      s2_write_en <= '0;
      s2_tail_eop <= 1'b0;
    end else if (stage2_take) begin
      write_ptr   <= write_ptr_next_c;
      s2_write_en <= s2_write_en_c;
      s2_tail_eop <= beat_ends_frame_c;
    end else begin
      s2_write_en <= '0;
    end
  end

  always_ff @(posedge clk) begin
    if (stage2_take) begin
      for (int d = 0; d < RING; d++) s2_write_sel[d] <= s2_write_sel_c[d];
      for (int j = 0; j < SLOTS; j++) begin
        s2_data[j] <= s1_data[j];
        s2_mty[j]  <= s1_mty[j];
      end
      s2_sop <= s1_sop;
      s2_eop <= s1_eop;
      s2_err <= s1_err;
    end
  end

  logic [SEG_W-1:0] ring_data [RING];
  logic [MTY_W-1:0] ring_mty  [RING];
  logic [RING-1:0]  ring_sop, ring_eop, ring_err;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      ring_sop        <= '0;
      ring_eop        <= '0;
      ring_err        <= '0;
      landed_ptr      <= '0;
      landed_tail_eop <= 1'b1;
    end else begin
      for (int d = 0; d < RING; d++) begin
        if (s2_write_en[d]) begin
          ring_sop[d] <= s2_sop[s2_write_sel[d]];
          ring_eop[d] <= s2_eop[s2_write_sel[d]];
          ring_err[d] <= s2_err[s2_write_sel[d]];
        end
      end
      landed_ptr <= write_ptr;
      if (|s2_write_en) landed_tail_eop <= s2_tail_eop;
    end
  end

  always_ff @(posedge clk) begin
    for (int d = 0; d < RING; d++) begin
      if (s2_write_en[d]) begin
        ring_data[d] <= s2_data[s2_write_sel[d]];
        ring_mty[d]  <= s2_mty[s2_write_sel[d]];
      end
    end
  end

  logic [PTR_W-1:0] landed_lead;
  logic [CNT_W-1:0] release_count;
  logic             release_now;

  assign landed_lead   = landed_ptr - read_ptr;
  assign release_count = (landed_lead >= PTR_W'(N_SEG)) ? CNT_W'(N_SEG) : CNT_W'(landed_lead);
  assign release_now   = (landed_lead >= PTR_W'(N_SEG))
                       | ((landed_lead != '0) & landed_tail_eop);

  logic                   out_valid;
  logic [N_SEG*SEG_W-1:0] out_data;
  logic [N_SEG-1:0]       out_ena, out_sop, out_eop, out_err;
  logic [N_SEG*MTY_W-1:0] out_mty;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      out_valid <= 1'b0;
      out_ena   <= '0;
      out_sop   <= '0;
      out_eop   <= '0;
      out_err   <= '0;
      out_mty   <= '0;
      read_ptr  <= '0;
    end else if (tx_seg_ready) begin
      out_valid <= release_now;
      out_ena   <= '0;
      out_sop   <= '0;
      out_eop   <= '0;
      out_err   <= '0;
      if (release_now) begin
        for (int k = 0; k < N_SEG; k++) begin
          logic [PTR_W-1:0]  entry_ptr;
          logic [ADDR_W-1:0] entry;
          entry_ptr = read_ptr + PTR_W'(k);
          entry     = entry_ptr[ADDR_W-1:0];
          if (k < int'(release_count)) begin
            out_data[k*SEG_W +: SEG_W] <= ring_data[entry];
            out_mty [k*MTY_W +: MTY_W] <= ring_mty [entry];
            out_ena[k]                 <= 1'b1;
            out_sop[k]                 <= ring_sop[entry];
            out_eop[k]                 <= ring_eop[entry];
            out_err[k]                 <= ring_err[entry];
          end
        end
        read_ptr <= read_ptr + PTR_W'(release_count);
      end
    end
  end

  assign ring_occupancy = write_ptr - read_ptr;
  assign ring_room      = (ring_occupancy + PTR_W'(SLOTS)) <= PTR_W'(RING);
  assign stage2_take    = s1_valid & ring_room;
  assign s_axis_tready  = ~s1_valid | stage2_take;
  assign accept         = s_axis_tvalid & s_axis_tready;

  assign tx_seg_valid = out_valid;
  assign tx_seg_dat   = out_data;
  assign tx_seg_ena   = out_ena;
  assign tx_seg_sop   = out_sop;
  assign tx_seg_eop   = out_eop;
  assign tx_seg_err   = out_err;
  assign tx_seg_mty   = out_mty;
endmodule

module dcmac_seg_axis_adapter #(
  parameter int N_SEG  = 2,
  parameter int SEG_W  = 128,
  parameter int DATA_W = N_SEG*SEG_W
)(
  input  logic                       clk,
  input  logic                       rstn,

  input  logic                       rx_seg_valid,
  input  logic [N_SEG*SEG_W-1:0]     rx_seg_dat,
  input  logic [N_SEG-1:0]           rx_seg_ena,
  input  logic [N_SEG-1:0]           rx_seg_sop,
  input  logic [N_SEG-1:0]           rx_seg_eop,
  input  logic [N_SEG-1:0]           rx_seg_err,
  input  logic [N_SEG*4-1:0]         rx_seg_mty,
  output logic [N_SEG*SEG_W-1:0]     m_axis_tdata,
  output logic [N_SEG*SEG_W/8-1:0]   m_axis_tkeep,
  output logic                       m_axis_tvalid,
  input  logic                       m_axis_tready,
  output logic                       m_axis_tlast,
  output logic                       m_axis_tuser,
  output logic                       rx_align_drop,
  output logic [31:0]                rx_align_stat,

  input  logic [DATA_W-1:0]          s_axis_tdata,
  input  logic [DATA_W/8-1:0]        s_axis_tkeep,
  input  logic                       s_axis_tvalid,
  output logic                       s_axis_tready,
  input  logic                       s_axis_tlast,
  input  logic                       s_axis_tuser,
  input  logic                       tx_seg_ready,
  output logic                       tx_seg_valid,
  output logic [N_SEG*SEG_W-1:0]     tx_seg_dat,
  output logic [N_SEG-1:0]           tx_seg_ena,
  output logic [N_SEG-1:0]           tx_seg_sop,
  output logic [N_SEG-1:0]           tx_seg_eop,
  output logic [N_SEG-1:0]           tx_seg_err,
  output logic [N_SEG*4-1:0]         tx_seg_mty
);
  dcmac_seg_axis_rx #(.N_SEG(N_SEG), .SEG_W(SEG_W), .DATA_W(N_SEG*SEG_W)) u_rx (
    .clk, .rstn,
    .rx_seg_valid, .rx_seg_dat, .rx_seg_ena, .rx_seg_sop, .rx_seg_eop, .rx_seg_err, .rx_seg_mty,
    .m_axis_tdata, .m_axis_tkeep, .m_axis_tvalid, .m_axis_tready, .m_axis_tlast, .m_axis_tuser,
    .rx_align_drop, .rx_align_stat
  );

  dcmac_seg_axis_tx #(.N_SEG(N_SEG), .SEG_W(SEG_W), .DATA_W(DATA_W)) u_tx (
    .clk, .rstn,
    .s_axis_tdata, .s_axis_tkeep, .s_axis_tvalid, .s_axis_tready, .s_axis_tlast, .s_axis_tuser,
    .tx_seg_ready, .tx_seg_valid, .tx_seg_dat, .tx_seg_ena, .tx_seg_sop, .tx_seg_eop, .tx_seg_err, .tx_seg_mty
  );
endmodule
