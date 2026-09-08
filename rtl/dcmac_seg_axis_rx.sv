// ---------------------------------------------------------------------------
// File        : dcmac_seg_axis_rx.sv
// Description : Segmented to AXI-Stream receive conversion. Takes N_SEG segments of
//               SEG_W bits per cycle from the DCMAC and produces one AXI-Stream
//               master of DATA_W bits.
// Author      : Xiaohai Li <haixiaolee@gmail.com>
// Language    : SystemVerilog
//
//
// Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
// SPDX-License-Identifier: BSD-2-Clause-Views
// ---------------------------------------------------------------------------

`default_nettype none

module dcmac_seg_axis_rx #(
  parameter integer N_SEG = 4,
  parameter integer SEG_W = 128,
  parameter integer DATA_W  = 1024,
  parameter integer BEAT_GROUPS   = 4
)(
  input  wire                                    clk,
  input  wire                                    rstn,

  input  wire                                    rx_seg_valid,
  input  wire [N_SEG*SEG_W-1:0]  rx_seg_dat,
  input  wire [N_SEG-1:0]                rx_seg_ena,
  input  wire [N_SEG-1:0]                rx_seg_sop,
  input  wire [N_SEG-1:0]                rx_seg_eop,
  input  wire [N_SEG-1:0]                rx_seg_err,
  input  wire [N_SEG*4-1:0]              rx_seg_mty,

  output wire [DATA_W-1:0]                 m_axis_tdata,
  output wire [DATA_W/8-1:0]               m_axis_tkeep,
  output wire                                    m_axis_tvalid,
  input  wire                                    m_axis_tready,
  output wire                                    m_axis_tlast,
  output wire                                    m_axis_tuser,

  output wire                                    rx_align_drop,
  output wire [31:0]                             rx_align_stat
);

  localparam integer SLOTS_PER_BEAT   = DATA_W / SEG_W;
  localparam integer SLOT_COUNT       = SLOTS_PER_BEAT * BEAT_GROUPS;
  localparam integer SLOT_INDEX_W     = $clog2(SLOT_COUNT);
  localparam integer SLOT_OFFSET_W    = $clog2(SLOTS_PER_BEAT);
  localparam integer LANE_INDEX_W     = (N_SEG > 1) ? $clog2(N_SEG) : 1;
  localparam integer GROUP_INDEX_W    = (BEAT_GROUPS > 1) ? $clog2(BEAT_GROUPS) : 1;
  localparam integer MTY_W    = 4;
  localparam integer SEG_KEEP_W   = SEG_W / 8;

  initial begin
    if (DATA_W % SEG_W != 0) begin
      $fatal(1, "dcmac_seg_axis_rx: DATA_W %0d is not a multiple of SEG_W %0d",
             DATA_W, SEG_W);
    end
    if (N_SEG > SLOTS_PER_BEAT) begin
      $fatal(1, "dcmac_seg_axis_rx: N_SEG %0d exceeds the %0d slots of one beat",
             N_SEG, SLOTS_PER_BEAT);
    end
  end

  logic [SEG_W-1:0] segment_data_d1 [N_SEG];
  logic [MTY_W-1:0] segment_mty_d1  [N_SEG];
  logic [N_SEG-1:0] segment_ena_d1, segment_eop_d1, segment_err_d1, segment_sop_d1;
  logic                     segment_valid_d1;

  logic [SEG_W-1:0] segment_data_d2 [N_SEG];
  logic [MTY_W-1:0] segment_mty_d2  [N_SEG];

  always_ff @(posedge clk) begin
    if (!rstn) begin
      segment_valid_d1 <= 1'b0;
      segment_ena_d1   <= '0;
      segment_eop_d1   <= '0;
      segment_err_d1   <= '0;
      segment_sop_d1   <= '0;
    end else begin
      segment_valid_d1 <= rx_seg_valid;
      segment_ena_d1   <= rx_seg_valid ? rx_seg_ena : '0;
      segment_eop_d1   <= rx_seg_valid ? rx_seg_eop : '0;
      segment_err_d1   <= rx_seg_valid ? rx_seg_err : '0;
      segment_sop_d1   <= rx_seg_valid ? rx_seg_sop : '0;
    end
  end

  always_ff @(posedge clk) begin
    for (int lane = 0; lane < N_SEG; lane++) begin
      segment_data_d1[lane] <= rx_seg_dat[lane*SEG_W +: SEG_W];
      segment_mty_d1[lane]  <= rx_seg_mty[lane*MTY_W +: MTY_W];
      segment_data_d2[lane] <= segment_data_d1[lane];
      segment_mty_d2[lane]  <= segment_mty_d1[lane];
    end
  end

  logic [SLOT_INDEX_W-1:0]  write_slot_q;
  logic [SLOT_INDEX_W-1:0]  write_slot_next;
  logic [GROUP_INDEX_W-1:0] write_group;
  logic [GROUP_INDEX_W-1:0] write_group_next;

  logic [LANE_INDEX_W-1:0]  slot_lane_next  [SLOT_COUNT];
  logic [SLOT_COUNT-1:0]    slot_load_next;
  logic [SLOT_COUNT-1:0]    slot_eop_next;
  logic [SLOT_COUNT-1:0]    slot_err_next;
  logic [BEAT_GROUPS-1:0]   group_filled_next;

  logic [LANE_INDEX_W-1:0]  slot_lane_d1  [SLOT_COUNT];
  logic [SLOT_COUNT-1:0]    slot_load_d1, slot_eop_d1, slot_err_d1;
  logic [BEAT_GROUPS-1:0]   group_filled_d1;

  always_comb begin
    write_slot_next    = write_slot_q;
    write_group        = GROUP_INDEX_W'(write_slot_q / SLOT_INDEX_W'(SLOTS_PER_BEAT));
    write_group_next   = (write_group == GROUP_INDEX_W'(BEAT_GROUPS-1))
                       ? GROUP_INDEX_W'(0) : GROUP_INDEX_W'(write_group + GROUP_INDEX_W'(1));
    slot_load_next     = '0;
    slot_eop_next      = '0;
    slot_err_next      = '0;
    group_filled_next  = '0;
    for (int slot = 0; slot < SLOT_COUNT; slot++) begin
      slot_lane_next[slot] = slot_lane_d1[slot];
    end
    if (segment_valid_d1) begin
      for (int lane = 0; lane < N_SEG; lane++) begin
        write_group      = GROUP_INDEX_W'(write_slot_next / SLOT_INDEX_W'(SLOTS_PER_BEAT));
        write_group_next = (write_group == GROUP_INDEX_W'(BEAT_GROUPS-1))
                         ? GROUP_INDEX_W'(0) : GROUP_INDEX_W'(write_group + GROUP_INDEX_W'(1));
        if (segment_ena_d1[lane]) begin
          slot_lane_next[write_slot_next] = LANE_INDEX_W'(lane);
          slot_load_next[write_slot_next] = 1'b1;
          slot_eop_next[write_slot_next]  = segment_eop_d1[lane];
          slot_err_next[write_slot_next]  = segment_err_d1[lane];
          if (segment_eop_d1[lane]) begin
            group_filled_next[write_group] = 1'b1;
            write_slot_next = {write_group_next, {SLOT_OFFSET_W{1'b0}}};
          end else if ((write_slot_next % SLOT_INDEX_W'(SLOTS_PER_BEAT))
                       == SLOT_INDEX_W'(SLOTS_PER_BEAT-1)) begin
            group_filled_next[write_group] = 1'b1;
            write_slot_next = write_slot_next + SLOT_INDEX_W'(1);
          end else begin
            write_slot_next = write_slot_next + SLOT_INDEX_W'(1);
          end
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rstn) begin
      write_slot_q    <= '0;
      slot_load_d1    <= '0;
      slot_eop_d1     <= '0;
      slot_err_d1     <= '0;
      group_filled_d1 <= '0;
    end else begin
      write_slot_q    <= write_slot_next;
      slot_load_d1    <= slot_load_next;
      slot_eop_d1     <= slot_eop_next;
      slot_err_d1     <= slot_err_next;
      group_filled_d1 <= group_filled_next;
    end
  end

  always_ff @(posedge clk) begin
    for (int slot = 0; slot < SLOT_COUNT; slot++) begin
      slot_lane_d1[slot] <= slot_lane_next[slot];
    end
  end

  logic [SEG_W-1:0] slot_data [SLOT_COUNT];
  logic [MTY_W-1:0] slot_mty  [SLOT_COUNT];
  logic [SLOT_COUNT-1:0]    slot_occupied, slot_frame_end, slot_frame_err;

  logic [BEAT_GROUPS-1:0]   group_ready;
  logic [BEAT_GROUPS-1:0]   group_release;
  logic [GROUP_INDEX_W-1:0] read_group_q;

  for (genvar slot = 0; slot < SLOT_COUNT; slot++) begin : g_slot
    always_ff @(posedge clk) begin
      if (slot_load_d1[slot]) begin
        slot_data[slot] <= segment_data_d2[slot_lane_d1[slot]];
        slot_mty[slot]  <= segment_mty_d2[slot_lane_d1[slot]];
      end
    end
    always_ff @(posedge clk) begin
      if (!rstn) begin
        slot_occupied[slot]  <= 1'b0;
        slot_frame_end[slot] <= 1'b0;
        slot_frame_err[slot] <= 1'b0;
      end else if (slot_load_d1[slot]) begin
        slot_occupied[slot]  <= 1'b1;
        slot_frame_end[slot] <= slot_eop_d1[slot];
        slot_frame_err[slot] <= slot_err_d1[slot];
      end else if (group_release[slot / SLOTS_PER_BEAT]) begin
        slot_occupied[slot]  <= 1'b0;
        slot_frame_end[slot] <= 1'b0;
        slot_frame_err[slot] <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rstn) begin
      group_ready <= '0;
    end else begin
      for (int group = 0; group < BEAT_GROUPS; group++) begin
        if (group_filled_d1[group])      group_ready[group] <= 1'b1;
        else if (group_release[group])   group_ready[group] <= 1'b0;
      end
    end
  end

  logic                    beat_valid_q;
  logic [DATA_W-1:0] beat_data_q;
  logic [DATA_W/8-1:0] beat_keep_q;
  logic                    beat_last_q, beat_user_q;

  wire out_ready = !beat_valid_q || m_axis_tready;
  wire read_fire = group_ready[read_group_q] && out_ready;

  always_comb begin
    group_release = '0;
    if (read_fire) group_release[read_group_q] = 1'b1;
  end

  always_ff @(posedge clk) begin
    if (!rstn) begin
      read_group_q <= '0;
    end else if (read_fire) begin
      read_group_q <= (BEAT_GROUPS == 1) ? '0
                    : (read_group_q == GROUP_INDEX_W'(BEAT_GROUPS-1))
                      ? '0 : read_group_q + GROUP_INDEX_W'(1);
    end
  end

  function automatic logic frame_ended_before(input integer group, input integer offset);
    logic ended;
    ended = 1'b0;
    for (int scan = 0; scan < SLOTS_PER_BEAT; scan++) begin
      if (scan < offset && slot_occupied[group*SLOTS_PER_BEAT + scan]
                        && slot_frame_end[group*SLOTS_PER_BEAT + scan]) begin
        ended = 1'b1;
      end
    end
    return ended;
  endfunction

  function automatic logic [SEG_KEEP_W-1:0] segment_keep(
      input logic occupied, input logic [MTY_W-1:0] empty_bytes, input logic ended,
      input logic frame_end);
    logic [SEG_KEEP_W:0] mask;
    int valid_bytes;
    if (!occupied || ended) begin
      return '0;
    end
    if (!frame_end) begin
      return {SEG_KEEP_W{1'b1}};
    end
    valid_bytes = SEG_KEEP_W - int'(empty_bytes);
    mask = ({{SEG_KEEP_W{1'b0}}, 1'b1} << valid_bytes) - (SEG_KEEP_W+1)'(1);
    return mask[SEG_KEEP_W-1:0];
  endfunction

  logic [DATA_W-1:0]   group_data [BEAT_GROUPS];
  logic [DATA_W/8-1:0] group_keep [BEAT_GROUPS];
  logic [BEAT_GROUPS-1:0]    group_last, group_err;

  for (genvar group = 0; group < BEAT_GROUPS; group++) begin : g_beat
    for (genvar offset = 0; offset < SLOTS_PER_BEAT; offset++) begin : g_lane
      assign group_data[group][offset*SEG_W +: SEG_W] =
        slot_data[group*SLOTS_PER_BEAT + offset];
      assign group_keep[group][offset*SEG_KEEP_W +: SEG_KEEP_W] =
        segment_keep(slot_occupied[group*SLOTS_PER_BEAT + offset],
                     slot_mty[group*SLOTS_PER_BEAT + offset],
                     frame_ended_before(group, offset),
                     slot_frame_end[group*SLOTS_PER_BEAT + offset]);
    end
    assign group_last[group] = |(slot_occupied[group*SLOTS_PER_BEAT +: SLOTS_PER_BEAT]
                               & slot_frame_end[group*SLOTS_PER_BEAT +: SLOTS_PER_BEAT]);
    assign group_err[group]  = |(slot_occupied[group*SLOTS_PER_BEAT +: SLOTS_PER_BEAT]
                               & slot_frame_err[group*SLOTS_PER_BEAT +: SLOTS_PER_BEAT]);
  end

  always_ff @(posedge clk) begin
    if (out_ready) begin
      beat_data_q <= group_data[read_group_q];
      beat_keep_q <= group_keep[read_group_q];
      beat_last_q <= group_last[read_group_q];
      beat_user_q <= group_err[read_group_q];
    end
  end

  always_ff @(posedge clk) begin
    if (!rstn)          beat_valid_q <= 1'b0;
    else if (out_ready) beat_valid_q <= read_fire;
  end

  logic frame_open_q, frame_open_d, sop_with_frame_open;

  always_comb begin
    logic open;
    open = frame_open_q;
    sop_with_frame_open = 1'b0;
    if (segment_valid_d1) begin
      for (int lane = 0; lane < N_SEG; lane++) begin
        if (segment_ena_d1[lane]) begin
          if (segment_sop_d1[lane] && open) sop_with_frame_open = 1'b1;
          if (segment_sop_d1[lane])         open = 1'b1;
          if (segment_eop_d1[lane])         open = 1'b0;
        end
      end
    end
    frame_open_d = open;
  end

  always_ff @(posedge clk) begin
    if (!rstn) frame_open_q <= 1'b0;
    else       frame_open_q <= frame_open_d;
  end

  logic        overflow_q;
  logic [31:0] overflow_count_q;
  wire         all_groups_ready = &group_ready;

  wire overflow_event = (all_groups_ready && !(|group_release)
                         && segment_valid_d1 && (|segment_ena_d1))
                      || sop_with_frame_open;

  always_ff @(posedge clk) begin
    if (!rstn) begin
      overflow_q       <= 1'b0;
      overflow_count_q <= '0;
    end else begin
      if (overflow_event) begin
        overflow_q <= 1'b1;
        if (overflow_count_q != 32'hFFFF_FFFF) begin
          overflow_count_q <= overflow_count_q + 32'd1;
        end
      end
    end
  end

  assign m_axis_tdata  = beat_data_q;
  assign m_axis_tkeep  = beat_keep_q;
  assign m_axis_tvalid = beat_valid_q;
  assign m_axis_tlast  = beat_last_q;
  assign m_axis_tuser  = beat_user_q;
  assign rx_align_drop = overflow_q;
  assign rx_align_stat = overflow_count_q;

endmodule

`default_nettype wire
