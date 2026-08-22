// ---------------------------------------------------------------------------
// File        :
// Description :
// Author      :
// Language    : SystemVerilog
//
//
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module dcmac_seg_pktmon_shift (
  clk,
  i_pkt,
  o_pkt
);

  parameter NUM_ID = 6;
  localparam ID_W = (NUM_ID == 1) ? 1 : $clog2(NUM_ID);

  typedef struct packed {
    logic [ID_W-1:0]     id;
    logic [11:0]         ena;
    logic [11:0]         sop;
    logic [11:0]         eop;
    logic [11:0]         err;
    logic [11:0][3:0]    mty;
    logic [11:0][127:0]  dat;
  } lbus_pkt_t;

  input  clk;
  input  lbus_pkt_t  i_pkt;
  output lbus_pkt_t  o_pkt;

  reg  [1:1][2:0][2:0] ena_sum_4;
  reg  [2:2][1:0][3:0] ena_sum_8;
  lbus_pkt_t [3:1] pkt_shift;

  assign o_pkt = pkt_shift[3];

  always_ff @(posedge clk) begin
    pkt_shift[1] <= i_pkt;

    ena_sum_4[1][0] <= i_pkt.ena[0] +  i_pkt.ena[1] + i_pkt.ena[2] + i_pkt.ena[3];
    ena_sum_4[1][1] <= i_pkt.ena[4] +  i_pkt.ena[5] + i_pkt.ena[6] + i_pkt.ena[7];
    ena_sum_4[1][2] <= i_pkt.ena[8] +  i_pkt.ena[9] + i_pkt.ena[10] + i_pkt.ena[11];

    if (~i_pkt.ena[0]) begin
      pkt_shift[1].ena[3:2] <= 2'd0;
      pkt_shift[1].ena[1:0] <= i_pkt.ena[3:2];
      pkt_shift[1].sop[1:0] <= i_pkt.sop[3:2];
      pkt_shift[1].eop[1:0] <= i_pkt.eop[3:2];
      pkt_shift[1].err[1:0] <= i_pkt.err[3:2];
      pkt_shift[1].mty[1:0] <= i_pkt.mty[3:2];
      pkt_shift[1].dat[1:0] <= i_pkt.dat[3:2];
    end
    else if (~i_pkt.ena[1]) begin
      pkt_shift[1].ena[3] <= 1'b0;
      pkt_shift[1].ena[2:1] <= i_pkt.ena[3:2];
      pkt_shift[1].sop[2:1] <= i_pkt.sop[3:2];
      pkt_shift[1].eop[2:1] <= i_pkt.eop[3:2];
      pkt_shift[1].err[2:1] <= i_pkt.err[3:2];
      pkt_shift[1].mty[2:1] <= i_pkt.mty[3:2];
      pkt_shift[1].dat[2:1] <= i_pkt.dat[3:2];
    end

    if (~i_pkt.ena[4]) begin
      pkt_shift[1].ena[7:6] <= 2'd0;
      pkt_shift[1].ena[5:4] <= i_pkt.ena[7:6];
      pkt_shift[1].sop[5:4] <= i_pkt.sop[7:6];
      pkt_shift[1].eop[5:4] <= i_pkt.eop[7:6];
      pkt_shift[1].err[5:4] <= i_pkt.err[7:6];
      pkt_shift[1].mty[5:4] <= i_pkt.mty[7:6];
      pkt_shift[1].dat[5:4] <= i_pkt.dat[7:6];
    end
    else if (~i_pkt.ena[5]) begin
      pkt_shift[1].ena[7] <= 1'b0;
      pkt_shift[1].ena[6:5] <= i_pkt.ena[7:6];
      pkt_shift[1].sop[6:5] <= i_pkt.sop[7:6];
      pkt_shift[1].eop[6:5] <= i_pkt.eop[7:6];
      pkt_shift[1].err[6:5] <= i_pkt.err[7:6];
      pkt_shift[1].mty[6:5] <= i_pkt.mty[7:6];
      pkt_shift[1].dat[6:5] <= i_pkt.dat[7:6];
    end

    if (~i_pkt.ena[8]) begin
      pkt_shift[1].ena[11:10] <= 2'd0;
      pkt_shift[1].ena[9:8] <= i_pkt.ena[11:10];
      pkt_shift[1].sop[9:8] <= i_pkt.sop[11:10];
      pkt_shift[1].eop[9:8] <= i_pkt.eop[11:10];
      pkt_shift[1].err[9:8] <= i_pkt.err[11:10];
      pkt_shift[1].mty[9:8] <= i_pkt.mty[11:10];
      pkt_shift[1].dat[9:8] <= i_pkt.dat[11:10];
    end
    else if (~i_pkt.ena[9]) begin
      pkt_shift[1].ena[11] <= 1'b0;
      pkt_shift[1].ena[10:9] <= i_pkt.ena[11:10];
      pkt_shift[1].sop[10:9] <= i_pkt.sop[11:10];
      pkt_shift[1].eop[10:9] <= i_pkt.eop[11:10];
      pkt_shift[1].err[10:9] <= i_pkt.err[11:10];
      pkt_shift[1].mty[10:9] <= i_pkt.mty[11:10];
      pkt_shift[1].dat[10:9] <= i_pkt.dat[11:10];
    end

    pkt_shift[2] <= pkt_shift[1];

    case(ena_sum_4[1][0])
      3'd0: begin
        pkt_shift[2].ena[7:4] <= 4'd0;
        pkt_shift[2].ena[3:0] <= pkt_shift[1].ena[7:4];
        pkt_shift[2].sop[3:0] <= pkt_shift[1].sop[7:4];
        pkt_shift[2].eop[3:0] <= pkt_shift[1].eop[7:4];
        pkt_shift[2].err[3:0] <= pkt_shift[1].err[7:4];
        pkt_shift[2].mty[3:0] <= pkt_shift[1].mty[7:4];
        pkt_shift[2].dat[3:0] <= pkt_shift[1].dat[7:4];
      end
      3'd1: begin
        pkt_shift[2].ena[7:5] <= 3'd0;
        pkt_shift[2].ena[4:1] <= pkt_shift[1].ena[7:4];
        pkt_shift[2].sop[4:1] <= pkt_shift[1].sop[7:4];
        pkt_shift[2].eop[4:1] <= pkt_shift[1].eop[7:4];
        pkt_shift[2].err[4:1] <= pkt_shift[1].err[7:4];
        pkt_shift[2].mty[4:1] <= pkt_shift[1].mty[7:4];
        pkt_shift[2].dat[4:1] <= pkt_shift[1].dat[7:4];
      end
      3'd2: begin
        pkt_shift[2].ena[7:6] <= 2'd0;
        pkt_shift[2].ena[5:2] <= pkt_shift[1].ena[7:4];
        pkt_shift[2].sop[5:2] <= pkt_shift[1].sop[7:4];
        pkt_shift[2].eop[5:2] <= pkt_shift[1].eop[7:4];
        pkt_shift[2].err[5:2] <= pkt_shift[1].err[7:4];
        pkt_shift[2].mty[5:2] <= pkt_shift[1].mty[7:4];
        pkt_shift[2].dat[5:2] <= pkt_shift[1].dat[7:4];
      end
      3'd3: begin
        pkt_shift[2].ena[7:7] <= 1'd0;
        pkt_shift[2].ena[6:3] <= pkt_shift[1].ena[7:4];
        pkt_shift[2].sop[6:3] <= pkt_shift[1].sop[7:4];
        pkt_shift[2].eop[6:3] <= pkt_shift[1].eop[7:4];
        pkt_shift[2].err[6:3] <= pkt_shift[1].err[7:4];
        pkt_shift[2].mty[6:3] <= pkt_shift[1].mty[7:4];
        pkt_shift[2].dat[6:3] <= pkt_shift[1].dat[7:4];
      end
    endcase

    ena_sum_8[2][0] <= ena_sum_4[1][0] + ena_sum_4[1][1];
    ena_sum_8[2][1] <= ena_sum_4[1][2];

    pkt_shift[3] <= pkt_shift[2];

    case(ena_sum_8[2][0])
      4'd0: begin
        pkt_shift[3].ena[11:4] <= '0;
        pkt_shift[3].ena[3:0] <= pkt_shift[2].ena[11:8];
        pkt_shift[3].sop[3:0] <= pkt_shift[2].sop[11:8];
        pkt_shift[3].eop[3:0] <= pkt_shift[2].eop[11:8];
        pkt_shift[3].err[3:0] <= pkt_shift[2].err[11:8];
        pkt_shift[3].mty[3:0] <= pkt_shift[2].mty[11:8];
        pkt_shift[3].dat[3:0] <= pkt_shift[2].dat[11:8];
      end
      4'd1: begin
        pkt_shift[3].ena[11:5] <= '0;
        pkt_shift[3].ena[4:1] <= pkt_shift[2].ena[11:8];
        pkt_shift[3].sop[4:1] <= pkt_shift[2].sop[11:8];
        pkt_shift[3].eop[4:1] <= pkt_shift[2].eop[11:8];
        pkt_shift[3].err[4:1] <= pkt_shift[2].err[11:8];
        pkt_shift[3].mty[4:1] <= pkt_shift[2].mty[11:8];
        pkt_shift[3].dat[4:1] <= pkt_shift[2].dat[11:8];
      end
      4'd2: begin
        pkt_shift[3].ena[11:6] <= '0;
        pkt_shift[3].ena[5:2] <= pkt_shift[2].ena[11:8];
        pkt_shift[3].sop[5:2] <= pkt_shift[2].sop[11:8];
        pkt_shift[3].eop[5:2] <= pkt_shift[2].eop[11:8];
        pkt_shift[3].err[5:2] <= pkt_shift[2].err[11:8];
        pkt_shift[3].mty[5:2] <= pkt_shift[2].mty[11:8];
        pkt_shift[3].dat[5:2] <= pkt_shift[2].dat[11:8];
      end
      4'd3: begin
        pkt_shift[3].ena[11:7] <= '0;
        pkt_shift[3].ena[6:3] <= pkt_shift[2].ena[11:8];
        pkt_shift[3].sop[6:3] <= pkt_shift[2].sop[11:8];
        pkt_shift[3].eop[6:3] <= pkt_shift[2].eop[11:8];
        pkt_shift[3].err[6:3] <= pkt_shift[2].err[11:8];
        pkt_shift[3].mty[6:3] <= pkt_shift[2].mty[11:8];
        pkt_shift[3].dat[6:3] <= pkt_shift[2].dat[11:8];
      end
      4'd4: begin
        pkt_shift[3].ena[11:8] <= '0;
        pkt_shift[3].ena[7:4] <= pkt_shift[2].ena[11:8];
        pkt_shift[3].sop[7:4] <= pkt_shift[2].sop[11:8];
        pkt_shift[3].eop[7:4] <= pkt_shift[2].eop[11:8];
        pkt_shift[3].err[7:4] <= pkt_shift[2].err[11:8];
        pkt_shift[3].mty[7:4] <= pkt_shift[2].mty[11:8];
        pkt_shift[3].dat[7:4] <= pkt_shift[2].dat[11:8];
      end
      4'd5: begin
        pkt_shift[3].ena[11:9] <= '0;
        pkt_shift[3].ena[8:5] <= pkt_shift[2].ena[11:8];
        pkt_shift[3].sop[8:5] <= pkt_shift[2].sop[11:8];
        pkt_shift[3].eop[8:5] <= pkt_shift[2].eop[11:8];
        pkt_shift[3].err[8:5] <= pkt_shift[2].err[11:8];
        pkt_shift[3].mty[8:5] <= pkt_shift[2].mty[11:8];
        pkt_shift[3].dat[8:5] <= pkt_shift[2].dat[11:8];
      end
      4'd6: begin
        pkt_shift[3].ena[11:10] <= '0;
        pkt_shift[3].ena[9:6] <= pkt_shift[2].ena[11:8];
        pkt_shift[3].sop[9:6] <= pkt_shift[2].sop[11:8];
        pkt_shift[3].eop[9:6] <= pkt_shift[2].eop[11:8];
        pkt_shift[3].err[9:6] <= pkt_shift[2].err[11:8];
        pkt_shift[3].mty[9:6] <= pkt_shift[2].mty[11:8];
        pkt_shift[3].dat[9:6] <= pkt_shift[2].dat[11:8];
      end
      4'd7: begin
        pkt_shift[3].ena[11:11] <= '0;
        pkt_shift[3].ena[10:7] <= pkt_shift[2].ena[11:8];
        pkt_shift[3].sop[10:7] <= pkt_shift[2].sop[11:8];
        pkt_shift[3].eop[10:7] <= pkt_shift[2].eop[11:8];
        pkt_shift[3].err[10:7] <= pkt_shift[2].err[11:8];
        pkt_shift[3].mty[10:7] <= pkt_shift[2].mty[11:8];
        pkt_shift[3].dat[10:7] <= pkt_shift[2].dat[11:8];
      end
    endcase

  end

endmodule

module dcmac_seg_pktmon_merge (
  clk,
  i_pkt,
  o_size,
  o_dat
);

  parameter NUM_ID = 6;
  localparam ID_W = (NUM_ID == 1) ? 1 : $clog2(NUM_ID);

  typedef struct packed {
    logic [ID_W-1:0]     id;
    logic [11:0]         ena;
    logic [11:0]         sop;
    logic [11:0]         eop;
    logic [11:0]         err;
    logic [11:0][3:0]    mty;
    logic [11:0][127:0]  dat;
  } lbus_pkt_t;

  input  clk;
  input  lbus_pkt_t i_pkt;
  output logic [7:0] o_size;
  output logic [11:0][15:0][7:0] o_dat;

  logic [2:0][2:0] valid_seg_sum_per_pkt_0;
  logic [1:1][2:0][2:0] valid_seg_sum_per_pkt;
  logic [2:0][3:0] sop_addr_0;
  logic [1:1][2:0][3:0] sop_addr;
  logic [2:0][3:0] pkt_mty_0;
  logic [4:1][2:0][3:0] pkt_mty;
  logic [3:0] valid_seg_sum_1;
  logic [2:2][3:0] valid_seg_sum;
  logic [5:0] mty_sum_1;
  logic [2:2][5:0] mty_sum;
  logic [5:3][7:0] size;
  logic [2:2][2:0][7:0] dat_idx;
  logic [4:3][191:0][1:0] sel;
  reg   [4:1][1536-1:0] dat_shift;
  logic [4:2][1536-1:0] dat_shift_pkt_0;
  logic [4:3][1536-1:0] dat_shift_pkt_1;
  logic [4:4][1536-1:0] dat_shift_pkt_2;
  logic [4:4][1536-1:0] dat_shift_pkt_3;
  reg   [4:4][3:0][191:0][7:0] byte_shift;
  reg   [5:5][191:0][7:0] byte_merge;

  always @* begin
    case (i_pkt.eop[3:0] & i_pkt.ena[3:0])
      4'b0001: begin pkt_mty_0[0] = i_pkt.mty[0]; sop_addr_0[0] = 0 + 1; end
      4'b0010: begin pkt_mty_0[0] = i_pkt.mty[1]; sop_addr_0[0] = 1 + 1; end
      4'b0100: begin pkt_mty_0[0] = i_pkt.mty[2]; sop_addr_0[0] = 2 + 1; end
      4'b1000: begin pkt_mty_0[0] = i_pkt.mty[3]; sop_addr_0[0] = 3 + 1; end
      default: begin pkt_mty_0[0] = '0; sop_addr_0[0] = 3 + 1; end
    endcase

    valid_seg_sum_per_pkt_0[0] = i_pkt.ena[0] + i_pkt.ena[1] + i_pkt.ena[2] + i_pkt.ena[3];

    case (i_pkt.eop[7:4] & i_pkt.ena[7:4])
      4'b0001: begin pkt_mty_0[1] = i_pkt.mty[4]; sop_addr_0[1] = 4 + 1; end
      4'b0010: begin pkt_mty_0[1] = i_pkt.mty[5]; sop_addr_0[1] = 5 + 1; end
      4'b0100: begin pkt_mty_0[1] = i_pkt.mty[6]; sop_addr_0[1] = 6 + 1; end
      4'b1000: begin pkt_mty_0[1] = i_pkt.mty[7]; sop_addr_0[1] = 7 + 1; end
      default: begin pkt_mty_0[1] = '0; sop_addr_0[1] = 7 + 1; end
    endcase

    valid_seg_sum_per_pkt_0[1] = i_pkt.ena[4] + i_pkt.ena[5] + i_pkt.ena[6] + i_pkt.ena[7];

    case (i_pkt.eop[11:8] & i_pkt.ena[11:8])
      4'b0001: begin pkt_mty_0[2] = i_pkt.mty[8]; sop_addr_0[2] = 8 + 1; end
      4'b0010: begin pkt_mty_0[2] = i_pkt.mty[9]; sop_addr_0[2] = 9 + 1; end
      4'b0100: begin pkt_mty_0[2] = i_pkt.mty[10]; sop_addr_0[2] = 10 + 1; end
      4'b1000: begin pkt_mty_0[2] = i_pkt.mty[11]; sop_addr_0[2] = 11 + 1; end
      default: begin pkt_mty_0[2] = '0; sop_addr_0[2] = 11 + 1; end
    endcase

    valid_seg_sum_per_pkt_0[2] = i_pkt.ena[8] + i_pkt.ena[9] + i_pkt.ena[10] + i_pkt.ena[11];

    valid_seg_sum_1 = '0;
    mty_sum_1 = '0;

    for (int i=0; i<3; i++) begin
      valid_seg_sum_1 += valid_seg_sum_per_pkt[1][i];
      mty_sum_1 += pkt_mty[1][i];
    end

  end

  assign dat_shift_pkt_3[4] = dat_shift[4];

  assign byte_shift[4][0] = dat_shift_pkt_0[4];
  assign byte_shift[4][1] = dat_shift_pkt_1[4];
  assign byte_shift[4][2] = dat_shift_pkt_2[4];
  assign byte_shift[4][3] = dat_shift_pkt_3[4];

  assign o_size = size[5];
  assign o_dat = byte_merge[5];

  always_ff @(posedge clk) begin
    valid_seg_sum_per_pkt[1] <= valid_seg_sum_per_pkt_0;
    pkt_mty[4:2] <= pkt_mty[3:1];
    pkt_mty[1] <= pkt_mty_0;
    valid_seg_sum[2] <= valid_seg_sum_1;
    mty_sum[2] <= mty_sum_1;
    sop_addr[1] <= sop_addr_0;

    size[3] <= {valid_seg_sum[2], 4'd0} - mty_sum[2];
    size[5:4] <= size[4:3];

    sel[4:4] <= sel[3:3];

    dat_idx[2][0] <= {sop_addr[1][0], 4'd0}
                      - pkt_mty[1][0]
                      ;
    dat_idx[2][1] <= {sop_addr[1][1], 4'd0}
                      - pkt_mty[1][0]
                      - pkt_mty[1][1]
                      ;
    dat_idx[2][2] <= {sop_addr[1][2], 4'd0}
                      - pkt_mty[1][0]
                      - pkt_mty[1][1]
                      - pkt_mty[1][2]
                      ;

    for (int i=0; i<192; i++) begin
      if (i < dat_idx[2][0]) sel[3][i] <= 0;
      else if (i < dat_idx[2][1]) sel[3][i] <= 1;
      else if (i < dat_idx[2][2]) sel[3][i] <= 2;
      else sel[3][i] <= 3;

      if (i < 48) byte_merge[5][i] <= byte_shift[4][sel[4][i][0]][i];
      else if (i < 64) byte_merge[5][i] <= (sel[4][i] == 0)? byte_shift[4][0][i] : (sel[4][i] == 1)? byte_shift[4][1][i] : byte_shift[4][2][i];
      else if (i < 96) byte_merge[5][i] <= (sel[4][i] == 1)? byte_shift[4][1][i] : byte_shift[4][2][i];
      else if (i < 128) byte_merge[5][i] <= (sel[4][i] == 1)? byte_shift[4][1][i] : (sel[4][i] == 2)? byte_shift[4][2][i] : byte_shift[4][3][i];
      else  byte_merge[5][i] <= (sel[4][i] == 2)? byte_shift[4][2][i] : byte_shift[4][3][i];

    end

    dat_shift[1] <= i_pkt.dat;
    dat_shift_pkt_0[2] <= dat_shift[1];
    dat_shift_pkt_0[4:3] <= dat_shift_pkt_0[3:2];

    dat_shift[2] <= dat_shift[1] >> {pkt_mty[1][0][3:0], 3'd0};
    dat_shift_pkt_1[3] <= dat_shift[2];
    dat_shift_pkt_1[4] <= dat_shift_pkt_1[3];

    dat_shift[3] <= dat_shift[2] >> {pkt_mty[2][1][3:0], 3'd0};
    dat_shift_pkt_2[4] <= dat_shift[3];

    dat_shift[4] <= dat_shift[3] >> {pkt_mty[3][2][3:0], 3'd0};

  end

endmodule

module dcmac_seg_pktmon_check (
  clk,
  rst,
  i_id,
  i_num_byte,
  i_dat,
  i_locked,
  o_locked,
  o_err
);

  parameter NUM_ID = 6;
  localparam ID_W = (NUM_ID == 1) ? 1 : $clog2(NUM_ID);

  input        clk;
  input        rst;
  input        [ID_W-1:0] i_id;
  input        [8-1:0] i_num_byte;
  input        [1536-1:0] i_dat;
  input        i_locked;
  output logic o_locked;
  output reg o_err;

  wire   [6:0][31:0][16-1:0] seed_group;
  reg    [1:1][6:0][16-1:0] seed_pipe;
  reg    [4:1][ID_W-1:0] id;
  reg    [2:1] shift;
  reg    [3:1][8-1:0] num_byte;
  reg    [3:1][1536-1:0] dat;
  wire   [192+2-1:0][7:0] wide_bus;
  logic  [192:0][2-1:0][7:0] seed_array;
  reg    [2:2][16-1:0] seed_select;
  wire   [2:2][16-1:0] seed_i, seed_o;
  reg    [5:1] load_new_seed, locked;
  logic  [3:3][192-1:0][7:0] pay_nxt;
  wire   [3:3][192-1:0][7:0] byte_in;
  logic  [4:4][192-1:0] byte_err;
  reg    [5:5][1:0] err_cnt_i, err_cnt_o;
  reg    [5:5] byte_err_is_0, byte_err_full;

  assign wide_bus = {i_dat, 16'd0};

  assign byte_in[3] = dat[3];

  always @* begin
    for (int i=0; i<=192; i++) begin
      for (int j=0; j<2; j++) begin
        seed_array[i][j] = wide_bus[i+j];
      end
    end
  end

  assign seed_group[0] = seed_array[31:0];
  assign seed_group[1] = seed_array[63:32];
  assign seed_group[2] = seed_array[95:64];
  assign seed_group[3] = seed_array[127:96];
  assign seed_group[4] = seed_array[159:128];
  assign seed_group[5] = seed_array[191:160];
  assign seed_group[6] = seed_array[192:192];

  assign seed_i[2] = seed_select[2];

  always_ff @(posedge clk) begin
    id <= {id, i_id};
    locked <= {locked, i_locked};
    num_byte <= {num_byte, i_num_byte};
    dat <= {dat, i_dat};

    for (int i=0; i<7; i++) begin
      seed_pipe[1][i] <= {8'd0, seed_group[i][i_num_byte[4:0]][15:8]};
    end

    seed_select[2] <= seed_pipe[1][num_byte[1][8-1:5]];

    load_new_seed[1] <= |i_num_byte;
    load_new_seed[5:2] <= load_new_seed[4:1];
    shift[1] <= i_num_byte == 1;
    shift[2] <= shift[1];

    for (int i=0; i<192; i++) begin
      byte_err[4][i] <= (i < num_byte[3])? pay_nxt[3][i] != byte_in[3][i] : 1'b0;
    end
    byte_err_is_0[5] <= byte_err[4] == '0;
    byte_err_full[5] <= byte_err[4] == '1;
  end

  dcmac_seg_ctx_mem  #(
    .DW (16),
    .INIT_VALUE (0)
  ) u_seed_ctx (
    .clk             (clk),
    .rst             (rst),
    .ts_rst          (1'b0),
    .i_rd_id         (id[1]),
    .i_ena           (load_new_seed[2]),
    .i_rd_during_wr  (),
    .i_dat           (seed_i[2]),
    .o_dat           (seed_o[2]),
    .o_init          ()
  );

  dcmac_seg_ctx_mem  #(
    .DW (2),
    .INIT_VALUE (0)
  ) u_match_ctx (
    .clk             (clk),
    .rst             (rst),
    .ts_rst          (1'b0),
    .i_rd_id         (id[4]),
    .i_ena           (load_new_seed[5]),
    .i_rd_during_wr  (),
    .i_dat           (err_cnt_i[5]),
    .o_dat           (err_cnt_o[5]),
    .o_init          ()
  );

  always @* begin
    err_cnt_i[5] = err_cnt_o[5];

    if (byte_err_is_0[5]) err_cnt_i[5] = '0;
    else if (!err_cnt_o[5][1]) err_cnt_i[5]++;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      o_locked <= 1'b0;
      o_err <= 1'b0;
    end
    else begin
      o_err <= locked[5]? !byte_err_is_0[5] : 0;

      if (load_new_seed[5]) begin
        if (byte_err_is_0[5]) o_locked <= 1'b1;
        else begin
          if (byte_err_full[5]) o_locked <= 1'b0;
          else o_locked <= ~err_cnt_o[5][1];
        end
      end
      else  o_locked <= locked[5];
    end
  end

  dcmac_seg_pktgen_payload #(
    .LOAD_SEED (1),
    .REGISTER_OUTPUT (1)
  ) u_payload_ref (
    .clk         (clk),
    .rst         (rst),
    .i_id_m1     (),
    .i_req_en    (),
    .i_req_num   (8'd192),
    .i_seed      (seed_o[2]),
    .o_dat       (pay_nxt[3])
  );

endmodule

module dcmac_seg_pktmon_gearbox (
  clk,
  rst,
  i_clear_counters,
  i_data_rate,
  i_valid,
  i_preamble,
  i_slice,
  o_preamble_err_cnt,
  o_pkt
);

  parameter R_400G = 2'b10,
            R_200G = 2'b01,
            R_100G = 2'b00;

  typedef struct packed {
    logic [2:0]               id;
    logic [11:0]              ena;
    logic [11:0]              sop;
    logic [11:0]              eop;
    logic [11:0]              err;
    logic [11:0][3:0]         mty;
    logic [11:0][127:0]       dat;
  } axis_rx_pkt_t;

  typedef struct packed {
    logic [1:0]              ena;
    logic [1:0]              sop;
    logic [1:0]              eop;
    logic [1:0]              err;
    logic [1:0][3:0]         mty;
    logic [1:0][127:0]       dat;
  } slice_t;

  input                               clk;
  input                [5:0]          rst;
  input                [5:0]          i_clear_counters;
  input                [5:0][1:0]     i_data_rate;
  input                [5:0]          i_valid;
  input                [5:0][55:0]    i_preamble;
  input  slice_t       [5:0]          i_slice;
  output reg           [5:0][31:0]    o_preamble_err_cnt;
  output axis_rx_pkt_t                o_pkt;

  reg                             p0_400, p0_200, p2_200, p4_200;
  reg             [2:0]           phase = 0;
  reg             [1:1][5:0][2:0] dmux;
  reg             [2:1][2:0]      sel;
  slice_t         [1:1][5:0]      slice_reg;
  logic           [1:1][5:0][1:0] din_ena;
  axis_rx_pkt_t   [2:2][5:0]      pkt, pkt_select;

  always_ff @(posedge clk) begin
    p0_400 <= i_data_rate[0] == R_400G;
    p0_200 <= i_data_rate[0] == R_200G;
    p2_200 <= !p0_400 & i_data_rate[2] == R_200G;
    p4_200 <= i_data_rate[4] == R_200G;

    for (int i=0; i<6; i++) begin
      pkt[2][i].id <= i[5:0];
      din_ena[1][i] <= i_slice[i].ena;

      slice_reg[1][i].ena <= i_slice[i].ena;
      slice_reg[1][i].sop <= i_slice[i].sop;
      slice_reg[1][i].eop <= i_slice[i].eop;
      slice_reg[1][i].err <= i_slice[i].err;
      slice_reg[1][i].mty <= i_slice[i].mty;
      slice_reg[1][i].dat <= i_slice[i].dat;
    end

    dmux[1] <= '0;

    if (i_data_rate[0] == R_400G) begin
      if (!i_valid[0]) din_ena[1][3:0] <= '0;
      case (phase)
        3'd0: begin sel[1] <= 3'd0; dmux[1][0] <= 1; end
        3'd1: begin sel[1] <= 3'd0; dmux[1][0] <= 2; end
        3'd2: begin                 dmux[1][0] <= 0; end
        3'd3: begin sel[1] <= 3'd0; dmux[1][0] <= 1; end
        3'd4: begin sel[1] <= 3'd0; dmux[1][0] <= 2; end
        3'd5: begin                 dmux[1][0] <= 0; end
      endcase
    end
    else if (i_data_rate[0] == R_200G) begin
      if (!i_valid[0]) din_ena[1][1:0] <= '0;
      case (phase)
        3'd0: begin dmux[1][0] <= 1;  sel[1] <= 3'd0; end
        3'd1: begin dmux[1][0] <= 0;                  end
        3'd2: begin dmux[1][0] <= 3;                  end
        3'd3: begin dmux[1][0] <= 1;  sel[1] <= 3'd0; end
        3'd4: begin dmux[1][0] <= 0;                  end
        3'd5: begin dmux[1][0] <= 3;                  end
      endcase
    end
    else begin
      if (!i_valid[0]) din_ena[1][0] <= '0;
      case (phase)
        3'd0: begin dmux[1][0] <= 7;   sel[1] <= 3'd0; end
        3'd1: begin dmux[1][0] <= 0;   end
        3'd2: begin dmux[1][0] <= 4;   end
        3'd3: begin dmux[1][0] <= 3;   end
        3'd4: begin dmux[1][0] <= 5;   end
        3'd5: begin dmux[1][0] <= 6;   end
      endcase
    end

    if (i_data_rate[0] != R_400G & i_data_rate[0] != R_200G) begin
      if (!i_valid[1]) din_ena[1][1] <= '0;
      case (phase)
        3'd0: begin dmux[1][1] <= 3;  end
        3'd1: begin dmux[1][1] <= 5;  end
        3'd2: begin dmux[1][1] <= 6;  end
        3'd3: begin dmux[1][1] <= 7;  sel[1] <= 3'd1; end
        3'd4: begin dmux[1][1] <= 0;  end
        3'd5: begin dmux[1][1] <= 4;  end
      endcase
    end

    if (i_data_rate[0] != R_400G) begin
      if (i_data_rate[2] == R_200G) begin
        if (!i_valid[2]) din_ena[1][3:2] <= '0;
        case (phase)
          3'd0: begin dmux[1][2] <= 3;  end
          3'd1: begin dmux[1][2] <= 1;  sel[1] <= 3'd2; end
          3'd2: begin dmux[1][2] <= 0;  end
          3'd3: begin dmux[1][2] <= 3;  end
          3'd4: begin dmux[1][2] <= 1;  sel[1] <= 3'd2; end
          3'd5: begin dmux[1][2] <= 0;  end
        endcase
      end
      else begin
        if (!i_valid[2]) din_ena[1][2] <= '0;
        case (phase)
          3'd0: begin dmux[1][2] <= 6; end
          3'd1: begin dmux[1][2] <= 7; sel[1] <= 3'd2; end
          3'd2: begin dmux[1][2] <= 0; end
          3'd3: begin dmux[1][2] <= 4; end
          3'd4: begin dmux[1][2] <= 3; end
          3'd5: begin dmux[1][2] <= 5; end
        endcase
      end
    end

    if (i_data_rate[0] != R_400G & i_data_rate[2] != R_200G) begin
      if (!i_valid[3]) din_ena[1][3] <= '0;
      case (phase)
        3'd0: begin dmux[1][3] <= 4;  end
        3'd1: begin dmux[1][3] <= 3;  end
        3'd2: begin dmux[1][3] <= 5;  end
        3'd3: begin dmux[1][3] <= 6;  end
        3'd4: begin dmux[1][3] <= 7;  sel[1] <= 3'd3; end
        3'd5: begin dmux[1][3] <= 0;  end
      endcase
    end

    if (i_data_rate[4] == R_200G) begin
      if (!i_valid[4]) din_ena[1][5:4] <= '0;
      case (phase)
        3'd0: begin dmux[1][4] <= 0;  end
        3'd1: begin dmux[1][4] <= 3;  end
        3'd2: begin dmux[1][4] <= 1;  sel[1] <= 3'd4; end
        3'd3: begin dmux[1][4] <= 0;  end
        3'd4: begin dmux[1][4] <= 3;  end
        3'd5: begin dmux[1][4] <= 1;  sel[1] <= 3'd4; end
      endcase
    end
    else begin
      if (!i_valid[4]) din_ena[1][4] <= '0;
      case (phase)
        3'd0: begin dmux[1][4] <= 5; end
        3'd1: begin dmux[1][4] <= 6; end
        3'd2: begin dmux[1][4] <= 7; sel[1] <= 3'd4; end
        3'd3: begin dmux[1][4] <= 0; end
        3'd4: begin dmux[1][4] <= 4; end
        3'd5: begin dmux[1][4] <= 3; end
      endcase
    end

    if (i_data_rate[4] != R_200G) begin
      if (!i_valid[5]) din_ena[1][5] <= '0;
      case (phase)
        3'd0: begin dmux[1][5] <= 0;  end
        3'd1: begin dmux[1][5] <= 4;  end
        3'd2: begin dmux[1][5] <= 3;  end
        3'd3: begin dmux[1][5] <= 5;  end
        3'd4: begin dmux[1][5] <= 6;  end
        3'd5: begin dmux[1][5] <= 7; sel[1] <= 3'd5;  end
      endcase
    end

    sel[2] <= sel[1];
    phase <= (phase == 3'd5)? 3'd0 : phase + 1'b1;
    for (int i=0; i<6; i++) pkt_select[2][i].ena <= '0;

    o_pkt.id  <= pkt_select[2][sel[2]].id;
    o_pkt.ena <= pkt_select[2][sel[2]].ena;
    o_pkt.sop <= pkt_select[2][sel[2]].sop;
    o_pkt.eop <= pkt_select[2][sel[2]].eop;
    o_pkt.err <= pkt_select[2][sel[2]].err;
    o_pkt.mty <= pkt_select[2][sel[2]].mty;
    o_pkt.dat <= pkt_select[2][sel[2]].dat;

    case (dmux[1][0])
      0: begin
        for (int i=0; i<4; i++) begin
          if (0 + i < 6) begin
            for (int j=0; j<2; j++) begin
              pkt[2][0].ena[i*2+j] <= din_ena[1][i][j];
              pkt[2][0].sop[i*2+j] <= slice_reg[1][i].sop[j];
              pkt[2][0].eop[i*2+j] <= slice_reg[1][i].eop[j];
              pkt[2][0].err[i*2+j] <= slice_reg[1][i].err[j];
              pkt[2][0].mty[i*2+j] <= slice_reg[1][i].mty[j];
              pkt[2][0].dat[i*2+j] <= slice_reg[1][i].dat[j];
            end
          end
        end
      end
      1: begin
        pkt_select[2][0] <= pkt[2][0];
        pkt[2][0].ena <= '0;
        for (int i=0; i<0+2; i++) begin
          for (int j=0; j<2; j++) begin
            pkt_select[2][0].ena[8+i*2+j] <= din_ena[1][i][j];
            pkt_select[2][0].sop[8+i*2+j] <= slice_reg[1][i].sop[j];
            pkt_select[2][0].eop[8+i*2+j] <= slice_reg[1][i].eop[j];
            pkt_select[2][0].err[8+i*2+j] <= slice_reg[1][i].err[j];
            pkt_select[2][0].mty[8+i*2+j] <= slice_reg[1][i].mty[j];
            pkt_select[2][0].dat[8+i*2+j] <= slice_reg[1][i].dat[j];
          end
        end
        for (int i=0; i<2; i++) begin
          for (int j=0; j<2; j++) begin
            pkt[2][0].ena[i*2+j] <= din_ena[1][2+i][j];
            pkt[2][0].sop[i*2+j] <= slice_reg[1][2+i].sop[j];
            pkt[2][0].eop[i*2+j] <= slice_reg[1][2+i].eop[j];
            pkt[2][0].err[i*2+j] <= slice_reg[1][2+i].err[j];
            pkt[2][0].mty[i*2+j] <= slice_reg[1][2+i].mty[j];
            pkt[2][0].dat[i*2+j] <= slice_reg[1][2+i].dat[j];
          end
        end
      end
      2: begin
        pkt_select[2][0] <= pkt[2][0];
        pkt[2][0].ena <= '0;
        for (int i=0; i<4; i++) begin
          for (int j=0; j<2; j++) begin
            pkt_select[2][0].ena[4+i*2+j] <= din_ena[1][i][j];
            pkt_select[2][0].sop[4+i*2+j] <= slice_reg[1][i].sop[j];
            pkt_select[2][0].eop[4+i*2+j] <= slice_reg[1][i].eop[j];
            pkt_select[2][0].err[4+i*2+j] <= slice_reg[1][i].err[j];
            pkt_select[2][0].mty[4+i*2+j] <= slice_reg[1][i].mty[j];
            pkt_select[2][0].dat[4+i*2+j] <= slice_reg[1][i].dat[j];
          end
        end
      end
      3: begin
        for (int i=0; i<2; i++) begin
          for (int j=0; j<2; j++) begin
            if (i < 6) begin
              pkt[2][0].ena[4+i*2+j] <= din_ena[1][i][j];
              pkt[2][0].sop[4+i*2+j] <= slice_reg[1][i].sop[j];
              pkt[2][0].eop[4+i*2+j] <= slice_reg[1][i].eop[j];
              pkt[2][0].err[4+i*2+j] <= slice_reg[1][i].err[j];
              pkt[2][0].mty[4+i*2+j] <= slice_reg[1][i].mty[j];
              pkt[2][0].dat[4+i*2+j] <= slice_reg[1][i].dat[j];
            end
          end
        end
      end
      4: begin
        for (int j=0; j<2; j++) begin
          pkt[2][0].ena[2+j] <= din_ena[1][0][j];
          pkt[2][0].sop[2+j] <= slice_reg[1][0].sop[j];
          pkt[2][0].eop[2+j] <= slice_reg[1][0].eop[j];
          pkt[2][0].err[2+j] <= slice_reg[1][0].err[j];
          pkt[2][0].mty[2+j] <= slice_reg[1][0].mty[j];
          pkt[2][0].dat[2+j] <= slice_reg[1][0].dat[j];
        end
      end
      5: begin
        for (int j=0; j<2; j++) begin
          pkt[2][0].ena[6+j] <= din_ena[1][0][j];
          pkt[2][0].sop[6+j] <= slice_reg[1][0].sop[j];
          pkt[2][0].eop[6+j] <= slice_reg[1][0].eop[j];
          pkt[2][0].err[6+j] <= slice_reg[1][0].err[j];
          pkt[2][0].mty[6+j] <= slice_reg[1][0].mty[j];
          pkt[2][0].dat[6+j] <= slice_reg[1][0].dat[j];
        end
      end
      6: begin
        for (int j=0; j<2; j++) begin
          pkt[2][0].ena[8+j] <= din_ena[1][0][j];
          pkt[2][0].sop[8+j] <= slice_reg[1][0].sop[j];
          pkt[2][0].eop[8+j] <= slice_reg[1][0].eop[j];
          pkt[2][0].err[8+j] <= slice_reg[1][0].err[j];
          pkt[2][0].mty[8+j] <= slice_reg[1][0].mty[j];
          pkt[2][0].dat[8+j] <= slice_reg[1][0].dat[j];
        end
      end
      7: begin
        pkt_select[2][0] <= pkt[2][0];
        for (int j=0; j<2; j++) begin
          pkt_select[2][0].ena[10+j] <= din_ena[1][0][j];
          pkt_select[2][0].sop[10+j] <= slice_reg[1][0].sop[j];
          pkt_select[2][0].eop[10+j] <= slice_reg[1][0].eop[j];
          pkt_select[2][0].err[10+j] <= slice_reg[1][0].err[j];
          pkt_select[2][0].mty[10+j] <= slice_reg[1][0].mty[j];
          pkt_select[2][0].dat[10+j] <= slice_reg[1][0].dat[j];
        end
      end
    endcase
    case (dmux[1][1])
      0: begin
        for (int i=0; i<4; i++) begin
          if (1 + i < 6) begin
            for (int j=0; j<2; j++) begin
              pkt[2][1].ena[i*2+j] <= din_ena[1][1+i][j];
              pkt[2][1].sop[i*2+j] <= slice_reg[1][1+i].sop[j];
              pkt[2][1].eop[i*2+j] <= slice_reg[1][1+i].eop[j];
              pkt[2][1].err[i*2+j] <= slice_reg[1][1+i].err[j];
              pkt[2][1].mty[i*2+j] <= slice_reg[1][1+i].mty[j];
              pkt[2][1].dat[i*2+j] <= slice_reg[1][1+i].dat[j];
            end
          end
        end
      end
      3: begin
        for (int i=0; i<2; i++) begin
          for (int j=0; j<2; j++) begin
            if (1+i < 6) begin
              pkt[2][1].ena[4+i*2+j] <= din_ena[1][1+i][j];
              pkt[2][1].sop[4+i*2+j] <= slice_reg[1][1+i].sop[j];
              pkt[2][1].eop[4+i*2+j] <= slice_reg[1][1+i].eop[j];
              pkt[2][1].err[4+i*2+j] <= slice_reg[1][1+i].err[j];
              pkt[2][1].mty[4+i*2+j] <= slice_reg[1][1+i].mty[j];
              pkt[2][1].dat[4+i*2+j] <= slice_reg[1][1+i].dat[j];
            end
          end
        end
      end
      4: begin
        for (int j=0; j<2; j++) begin
          pkt[2][1].ena[2+j] <= din_ena[1][1][j];
          pkt[2][1].sop[2+j] <= slice_reg[1][1].sop[j];
          pkt[2][1].eop[2+j] <= slice_reg[1][1].eop[j];
          pkt[2][1].err[2+j] <= slice_reg[1][1].err[j];
          pkt[2][1].mty[2+j] <= slice_reg[1][1].mty[j];
          pkt[2][1].dat[2+j] <= slice_reg[1][1].dat[j];
        end
      end
      5: begin
        for (int j=0; j<2; j++) begin
          pkt[2][1].ena[6+j] <= din_ena[1][1][j];
          pkt[2][1].sop[6+j] <= slice_reg[1][1].sop[j];
          pkt[2][1].eop[6+j] <= slice_reg[1][1].eop[j];
          pkt[2][1].err[6+j] <= slice_reg[1][1].err[j];
          pkt[2][1].mty[6+j] <= slice_reg[1][1].mty[j];
          pkt[2][1].dat[6+j] <= slice_reg[1][1].dat[j];
        end
      end
      6: begin
        for (int j=0; j<2; j++) begin
          pkt[2][1].ena[8+j] <= din_ena[1][1][j];
          pkt[2][1].sop[8+j] <= slice_reg[1][1].sop[j];
          pkt[2][1].eop[8+j] <= slice_reg[1][1].eop[j];
          pkt[2][1].err[8+j] <= slice_reg[1][1].err[j];
          pkt[2][1].mty[8+j] <= slice_reg[1][1].mty[j];
          pkt[2][1].dat[8+j] <= slice_reg[1][1].dat[j];
        end
      end
      7: begin
        pkt_select[2][1] <= pkt[2][1];
        for (int j=0; j<2; j++) begin
          pkt_select[2][1].ena[10+j] <= din_ena[1][1][j];
          pkt_select[2][1].sop[10+j] <= slice_reg[1][1].sop[j];
          pkt_select[2][1].eop[10+j] <= slice_reg[1][1].eop[j];
          pkt_select[2][1].err[10+j] <= slice_reg[1][1].err[j];
          pkt_select[2][1].mty[10+j] <= slice_reg[1][1].mty[j];
          pkt_select[2][1].dat[10+j] <= slice_reg[1][1].dat[j];
        end
      end
    endcase
    case (dmux[1][2])
      0: begin
        for (int i=0; i<4; i++) begin
          if (2 + i < 6) begin
            for (int j=0; j<2; j++) begin
              pkt[2][2].ena[i*2+j] <= din_ena[1][2+i][j];
              pkt[2][2].sop[i*2+j] <= slice_reg[1][2+i].sop[j];
              pkt[2][2].eop[i*2+j] <= slice_reg[1][2+i].eop[j];
              pkt[2][2].err[i*2+j] <= slice_reg[1][2+i].err[j];
              pkt[2][2].mty[i*2+j] <= slice_reg[1][2+i].mty[j];
              pkt[2][2].dat[i*2+j] <= slice_reg[1][2+i].dat[j];
            end
          end
        end
      end
      1: begin
        pkt_select[2][2] <= pkt[2][2];
        pkt[2][2].ena <= '0;
        for (int i=2; i<2+2; i++) begin
          for (int j=0; j<2; j++) begin
            pkt_select[2][2].ena[8+(i-2)*2+j] <= din_ena[1][i][j];
            pkt_select[2][2].sop[8+(i-2)*2+j] <= slice_reg[1][i].sop[j];
            pkt_select[2][2].eop[8+(i-2)*2+j] <= slice_reg[1][i].eop[j];
            pkt_select[2][2].err[8+(i-2)*2+j] <= slice_reg[1][i].err[j];
            pkt_select[2][2].mty[8+(i-2)*2+j] <= slice_reg[1][i].mty[j];
            pkt_select[2][2].dat[8+(i-2)*2+j] <= slice_reg[1][i].dat[j];
          end
        end
      end
      3: begin
        for (int i=0; i<2; i++) begin
          for (int j=0; j<2; j++) begin
            if (2+i < 6) begin
              pkt[2][2].ena[4+i*2+j] <= din_ena[1][2+i][j];
              pkt[2][2].sop[4+i*2+j] <= slice_reg[1][2+i].sop[j];
              pkt[2][2].eop[4+i*2+j] <= slice_reg[1][2+i].eop[j];
              pkt[2][2].err[4+i*2+j] <= slice_reg[1][2+i].err[j];
              pkt[2][2].mty[4+i*2+j] <= slice_reg[1][2+i].mty[j];
              pkt[2][2].dat[4+i*2+j] <= slice_reg[1][2+i].dat[j];
            end
          end
        end
      end
      4: begin
        for (int j=0; j<2; j++) begin
          pkt[2][2].ena[2+j] <= din_ena[1][2][j];
          pkt[2][2].sop[2+j] <= slice_reg[1][2].sop[j];
          pkt[2][2].eop[2+j] <= slice_reg[1][2].eop[j];
          pkt[2][2].err[2+j] <= slice_reg[1][2].err[j];
          pkt[2][2].mty[2+j] <= slice_reg[1][2].mty[j];
          pkt[2][2].dat[2+j] <= slice_reg[1][2].dat[j];
        end
      end
      5: begin
        for (int j=0; j<2; j++) begin
          pkt[2][2].ena[6+j] <= din_ena[1][2][j];
          pkt[2][2].sop[6+j] <= slice_reg[1][2].sop[j];
          pkt[2][2].eop[6+j] <= slice_reg[1][2].eop[j];
          pkt[2][2].err[6+j] <= slice_reg[1][2].err[j];
          pkt[2][2].mty[6+j] <= slice_reg[1][2].mty[j];
          pkt[2][2].dat[6+j] <= slice_reg[1][2].dat[j];
        end
      end
      6: begin
        for (int j=0; j<2; j++) begin
          pkt[2][2].ena[8+j] <= din_ena[1][2][j];
          pkt[2][2].sop[8+j] <= slice_reg[1][2].sop[j];
          pkt[2][2].eop[8+j] <= slice_reg[1][2].eop[j];
          pkt[2][2].err[8+j] <= slice_reg[1][2].err[j];
          pkt[2][2].mty[8+j] <= slice_reg[1][2].mty[j];
          pkt[2][2].dat[8+j] <= slice_reg[1][2].dat[j];
        end
      end
      7: begin
        pkt_select[2][2] <= pkt[2][2];
        for (int j=0; j<2; j++) begin
          pkt_select[2][2].ena[10+j] <= din_ena[1][2][j];
          pkt_select[2][2].sop[10+j] <= slice_reg[1][2].sop[j];
          pkt_select[2][2].eop[10+j] <= slice_reg[1][2].eop[j];
          pkt_select[2][2].err[10+j] <= slice_reg[1][2].err[j];
          pkt_select[2][2].mty[10+j] <= slice_reg[1][2].mty[j];
          pkt_select[2][2].dat[10+j] <= slice_reg[1][2].dat[j];
        end
      end
    endcase
    case (dmux[1][3])
      0: begin
        for (int i=0; i<4; i++) begin
          if (3 + i < 6) begin
            for (int j=0; j<2; j++) begin
              pkt[2][3].ena[i*2+j] <= din_ena[1][3+i][j];
              pkt[2][3].sop[i*2+j] <= slice_reg[1][3+i].sop[j];
              pkt[2][3].eop[i*2+j] <= slice_reg[1][3+i].eop[j];
              pkt[2][3].err[i*2+j] <= slice_reg[1][3+i].err[j];
              pkt[2][3].mty[i*2+j] <= slice_reg[1][3+i].mty[j];
              pkt[2][3].dat[i*2+j] <= slice_reg[1][3+i].dat[j];
            end
          end
        end
      end
      3: begin
        for (int i=0; i<2; i++) begin
          for (int j=0; j<2; j++) begin
            if (3+i < 6) begin
              pkt[2][3].ena[4+i*2+j] <= din_ena[1][3+i][j];
              pkt[2][3].sop[4+i*2+j] <= slice_reg[1][3+i].sop[j];
              pkt[2][3].eop[4+i*2+j] <= slice_reg[1][3+i].eop[j];
              pkt[2][3].err[4+i*2+j] <= slice_reg[1][3+i].err[j];
              pkt[2][3].mty[4+i*2+j] <= slice_reg[1][3+i].mty[j];
              pkt[2][3].dat[4+i*2+j] <= slice_reg[1][3+i].dat[j];
            end
          end
        end
      end
      4: begin
        for (int j=0; j<2; j++) begin
          pkt[2][3].ena[2+j] <= din_ena[1][3][j];
          pkt[2][3].sop[2+j] <= slice_reg[1][3].sop[j];
          pkt[2][3].eop[2+j] <= slice_reg[1][3].eop[j];
          pkt[2][3].err[2+j] <= slice_reg[1][3].err[j];
          pkt[2][3].mty[2+j] <= slice_reg[1][3].mty[j];
          pkt[2][3].dat[2+j] <= slice_reg[1][3].dat[j];
        end
      end
      5: begin
        for (int j=0; j<2; j++) begin
          pkt[2][3].ena[6+j] <= din_ena[1][3][j];
          pkt[2][3].sop[6+j] <= slice_reg[1][3].sop[j];
          pkt[2][3].eop[6+j] <= slice_reg[1][3].eop[j];
          pkt[2][3].err[6+j] <= slice_reg[1][3].err[j];
          pkt[2][3].mty[6+j] <= slice_reg[1][3].mty[j];
          pkt[2][3].dat[6+j] <= slice_reg[1][3].dat[j];
        end
      end
      6: begin
        for (int j=0; j<2; j++) begin
          pkt[2][3].ena[8+j] <= din_ena[1][3][j];
          pkt[2][3].sop[8+j] <= slice_reg[1][3].sop[j];
          pkt[2][3].eop[8+j] <= slice_reg[1][3].eop[j];
          pkt[2][3].err[8+j] <= slice_reg[1][3].err[j];
          pkt[2][3].mty[8+j] <= slice_reg[1][3].mty[j];
          pkt[2][3].dat[8+j] <= slice_reg[1][3].dat[j];
        end
      end
      7: begin
        pkt_select[2][3] <= pkt[2][3];
        for (int j=0; j<2; j++) begin
          pkt_select[2][3].ena[10+j] <= din_ena[1][3][j];
          pkt_select[2][3].sop[10+j] <= slice_reg[1][3].sop[j];
          pkt_select[2][3].eop[10+j] <= slice_reg[1][3].eop[j];
          pkt_select[2][3].err[10+j] <= slice_reg[1][3].err[j];
          pkt_select[2][3].mty[10+j] <= slice_reg[1][3].mty[j];
          pkt_select[2][3].dat[10+j] <= slice_reg[1][3].dat[j];
        end
      end
    endcase
    case (dmux[1][4])
      0: begin
        for (int i=0; i<4; i++) begin
          if (4 + i < 6) begin
            for (int j=0; j<2; j++) begin
              pkt[2][4].ena[i*2+j] <= din_ena[1][4+i][j];
              pkt[2][4].sop[i*2+j] <= slice_reg[1][4+i].sop[j];
              pkt[2][4].eop[i*2+j] <= slice_reg[1][4+i].eop[j];
              pkt[2][4].err[i*2+j] <= slice_reg[1][4+i].err[j];
              pkt[2][4].mty[i*2+j] <= slice_reg[1][4+i].mty[j];
              pkt[2][4].dat[i*2+j] <= slice_reg[1][4+i].dat[j];
            end
          end
        end
      end
      1: begin
        pkt_select[2][4] <= pkt[2][4];
        pkt[2][4].ena <= '0;
        for (int i=4; i<4+2; i++) begin
          for (int j=0; j<2; j++) begin
            pkt_select[2][4].ena[8+(i-4)*2+j] <= din_ena[1][i][j];
            pkt_select[2][4].sop[8+(i-4)*2+j] <= slice_reg[1][i].sop[j];
            pkt_select[2][4].eop[8+(i-4)*2+j] <= slice_reg[1][i].eop[j];
            pkt_select[2][4].err[8+(i-4)*2+j] <= slice_reg[1][i].err[j];
            pkt_select[2][4].mty[8+(i-4)*2+j] <= slice_reg[1][i].mty[j];
            pkt_select[2][4].dat[8+(i-4)*2+j] <= slice_reg[1][i].dat[j];
          end
        end
      end
      3: begin
        for (int i=0; i<2; i++) begin
          for (int j=0; j<2; j++) begin
            if (4+i < 6) begin
              pkt[2][4].ena[4+i*2+j] <= din_ena[1][4+i][j];
              pkt[2][4].sop[4+i*2+j] <= slice_reg[1][4+i].sop[j];
              pkt[2][4].eop[4+i*2+j] <= slice_reg[1][4+i].eop[j];
              pkt[2][4].err[4+i*2+j] <= slice_reg[1][4+i].err[j];
              pkt[2][4].mty[4+i*2+j] <= slice_reg[1][4+i].mty[j];
              pkt[2][4].dat[4+i*2+j] <= slice_reg[1][4+i].dat[j];
            end
          end
        end
      end
      4: begin
        for (int j=0; j<2; j++) begin
          pkt[2][4].ena[2+j] <= din_ena[1][4][j];
          pkt[2][4].sop[2+j] <= slice_reg[1][4].sop[j];
          pkt[2][4].eop[2+j] <= slice_reg[1][4].eop[j];
          pkt[2][4].err[2+j] <= slice_reg[1][4].err[j];
          pkt[2][4].mty[2+j] <= slice_reg[1][4].mty[j];
          pkt[2][4].dat[2+j] <= slice_reg[1][4].dat[j];
        end
      end
      5: begin
        for (int j=0; j<2; j++) begin
          pkt[2][4].ena[6+j] <= din_ena[1][4][j];
          pkt[2][4].sop[6+j] <= slice_reg[1][4].sop[j];
          pkt[2][4].eop[6+j] <= slice_reg[1][4].eop[j];
          pkt[2][4].err[6+j] <= slice_reg[1][4].err[j];
          pkt[2][4].mty[6+j] <= slice_reg[1][4].mty[j];
          pkt[2][4].dat[6+j] <= slice_reg[1][4].dat[j];
        end
      end
      6: begin
        for (int j=0; j<2; j++) begin
          pkt[2][4].ena[8+j] <= din_ena[1][4][j];
          pkt[2][4].sop[8+j] <= slice_reg[1][4].sop[j];
          pkt[2][4].eop[8+j] <= slice_reg[1][4].eop[j];
          pkt[2][4].err[8+j] <= slice_reg[1][4].err[j];
          pkt[2][4].mty[8+j] <= slice_reg[1][4].mty[j];
          pkt[2][4].dat[8+j] <= slice_reg[1][4].dat[j];
        end
      end
      7: begin
        pkt_select[2][4] <= pkt[2][4];
        for (int j=0; j<2; j++) begin
          pkt_select[2][4].ena[10+j] <= din_ena[1][4][j];
          pkt_select[2][4].sop[10+j] <= slice_reg[1][4].sop[j];
          pkt_select[2][4].eop[10+j] <= slice_reg[1][4].eop[j];
          pkt_select[2][4].err[10+j] <= slice_reg[1][4].err[j];
          pkt_select[2][4].mty[10+j] <= slice_reg[1][4].mty[j];
          pkt_select[2][4].dat[10+j] <= slice_reg[1][4].dat[j];
        end
      end
    endcase
    case (dmux[1][5])
      0: begin
        for (int i=0; i<4; i++) begin
          if (5 + i < 6) begin
            for (int j=0; j<2; j++) begin
              pkt[2][5].ena[i*2+j] <= din_ena[1][5+i][j];
              pkt[2][5].sop[i*2+j] <= slice_reg[1][5+i].sop[j];
              pkt[2][5].eop[i*2+j] <= slice_reg[1][5+i].eop[j];
              pkt[2][5].err[i*2+j] <= slice_reg[1][5+i].err[j];
              pkt[2][5].mty[i*2+j] <= slice_reg[1][5+i].mty[j];
              pkt[2][5].dat[i*2+j] <= slice_reg[1][5+i].dat[j];
            end
          end
        end
      end
      3: begin
        for (int i=0; i<2; i++) begin
          for (int j=0; j<2; j++) begin
            if (5+i < 6) begin
              pkt[2][5].ena[4+i*2+j] <= din_ena[1][5+i][j];
              pkt[2][5].sop[4+i*2+j] <= slice_reg[1][5+i].sop[j];
              pkt[2][5].eop[4+i*2+j] <= slice_reg[1][5+i].eop[j];
              pkt[2][5].err[4+i*2+j] <= slice_reg[1][5+i].err[j];
              pkt[2][5].mty[4+i*2+j] <= slice_reg[1][5+i].mty[j];
              pkt[2][5].dat[4+i*2+j] <= slice_reg[1][5+i].dat[j];
            end
          end
        end
      end
      4: begin
        for (int j=0; j<2; j++) begin
          pkt[2][5].ena[2+j] <= din_ena[1][5][j];
          pkt[2][5].sop[2+j] <= slice_reg[1][5].sop[j];
          pkt[2][5].eop[2+j] <= slice_reg[1][5].eop[j];
          pkt[2][5].err[2+j] <= slice_reg[1][5].err[j];
          pkt[2][5].mty[2+j] <= slice_reg[1][5].mty[j];
          pkt[2][5].dat[2+j] <= slice_reg[1][5].dat[j];
        end
      end
      5: begin
        for (int j=0; j<2; j++) begin
          pkt[2][5].ena[6+j] <= din_ena[1][5][j];
          pkt[2][5].sop[6+j] <= slice_reg[1][5].sop[j];
          pkt[2][5].eop[6+j] <= slice_reg[1][5].eop[j];
          pkt[2][5].err[6+j] <= slice_reg[1][5].err[j];
          pkt[2][5].mty[6+j] <= slice_reg[1][5].mty[j];
          pkt[2][5].dat[6+j] <= slice_reg[1][5].dat[j];
        end
      end
      6: begin
        for (int j=0; j<2; j++) begin
          pkt[2][5].ena[8+j] <= din_ena[1][5][j];
          pkt[2][5].sop[8+j] <= slice_reg[1][5].sop[j];
          pkt[2][5].eop[8+j] <= slice_reg[1][5].eop[j];
          pkt[2][5].err[8+j] <= slice_reg[1][5].err[j];
          pkt[2][5].mty[8+j] <= slice_reg[1][5].mty[j];
          pkt[2][5].dat[8+j] <= slice_reg[1][5].dat[j];
        end
      end
      7: begin
        pkt_select[2][5] <= pkt[2][5];
        for (int j=0; j<2; j++) begin
          pkt_select[2][5].ena[10+j] <= din_ena[1][5][j];
          pkt_select[2][5].sop[10+j] <= slice_reg[1][5].sop[j];
          pkt_select[2][5].eop[10+j] <= slice_reg[1][5].eop[j];
          pkt_select[2][5].err[10+j] <= slice_reg[1][5].err[j];
          pkt_select[2][5].mty[10+j] <= slice_reg[1][5].mty[j];
          pkt_select[2][5].dat[10+j] <= slice_reg[1][5].dat[j];
        end
      end
    endcase

    for (int i=0; i<6; i++) begin
      if (rst[i]) begin
        pkt[2][i].ena <= '0;
      end
    end
  end

  // synthesis translate_off
  reg    [1:0][5:0]    clear_counter_reg;
  reg    [5:0]         clear_counter_pulse;
  reg    [5:0]         preamble_err;
  reg    [5:0][31:0]   preamble_err_cnt;
  reg    [5:0]         p_100;
  reg    [5:0][1:0]    preamble_match;
  reg    [1:0]         preamble_match_0_1, preamble_match_2_3, preamble_match_4_5;

  always_ff @(posedge clk) begin
    p0_400 <= i_data_rate[0] == R_400G;
    p0_200 <= i_data_rate[0] == R_200G;
    p2_200 <= !p0_400 & i_data_rate[2] == R_200G;
    p4_200 <= i_data_rate[4] == R_200G;

    p_100[0] <= i_data_rate[0] == R_100G;
    p_100[1] <= i_data_rate[1] == R_100G & !p0_400 & !p0_200;
    p_100[2] <= i_data_rate[2] == R_100G & !p0_400;
    p_100[3] <= i_data_rate[3] == R_100G & !p0_400 & !p2_200;
    p_100[4] <= i_data_rate[4] == R_100G;
    p_100[5] <= i_data_rate[5] == R_100G & !p4_200;

    clear_counter_reg <= {clear_counter_reg, i_clear_counters};
    clear_counter_pulse <= clear_counter_reg[0] & ~clear_counter_reg[1];

    for (int i=0; i<6; i++) begin
      preamble_match[i][0] <= i_preamble[i] == i_slice[i].dat[0][55:0];
      preamble_match[i][1] <= i_preamble[i] == i_slice[i].dat[1][55:0];
    end

    preamble_match_0_1[0] <= i_preamble[0] == i_slice[1].dat[0][55:0];
    preamble_match_0_1[1] <= i_preamble[0] == i_slice[1].dat[1][55:0];

    preamble_match_2_3[0] <= i_preamble[2] == i_slice[3].dat[0][55:0];
    preamble_match_2_3[1] <= i_preamble[2] == i_slice[3].dat[1][55:0];

    preamble_match_4_5[0] <= i_preamble[4] == i_slice[5].dat[0][55:0];
    preamble_match_4_5[1] <= i_preamble[4] == i_slice[5].dat[1][55:0];

    preamble_err <= 6'd0;

    for (int i=0; i<6; i++) begin
      if (p_100[i] | i == 0 | i == 2 & p2_200 | i == 4 & p4_200)
        if (slice_reg[1][i].sop[0] & din_ena[1][i][0] & !preamble_match[i][0]
          | slice_reg[1][i].sop[1] & din_ena[1][i][1] & !preamble_match[i][1]) preamble_err[i] <= 1'b1;
    end

    if (p0_400 | p0_200) begin
      if (slice_reg[1][1].sop[0] & din_ena[1][1][0] & !preamble_match_0_1[0]
        | slice_reg[1][1].sop[1] & din_ena[1][1][1] & !preamble_match_0_1[1]
        )
        preamble_err[0] <= 1'b1;
    end

    if (p0_400 &
        ( slice_reg[1][3].sop[0] & din_ena[1][3][0] & !preamble_match_2_3[0]
        | slice_reg[1][3].sop[1] & din_ena[1][3][1] & !preamble_match_2_3[1]
        )
    ) preamble_err[0] <= 1'b1;

    if (p2_200 &
        ( slice_reg[1][3].sop[0] & din_ena[1][3][0] & !preamble_match_2_3[0]
        | slice_reg[1][3].sop[1] & din_ena[1][3][1] & !preamble_match_2_3[1]
        )
    ) preamble_err[2] <= 1'b1;

    if (p4_200 &
        ( slice_reg[1][5].sop[0] & din_ena[1][5][0] & !preamble_match_4_5[0]
        | slice_reg[1][5].sop[1] & din_ena[1][5][1] & !preamble_match_4_5[1]
        )
    )  preamble_err[4] <= 1'b1;

    for (int i=0; i<6; i++) begin
      if(clear_counter_pulse[i]) begin
        preamble_err_cnt[i] <= '0;
        preamble_err_cnt[i][0] <= preamble_err[i];
        o_preamble_err_cnt[i] <= preamble_err_cnt[i];
      end
      else begin
        preamble_err_cnt[i] <= preamble_err_cnt[i] + preamble_err[i];
      end
    end
  end
  // synthesis translate_on

endmodule

module dcmac_seg_pktmon_core (
  clk,
  rst,

  port_rst,
  i_pkt,
  i_clear_counters,
  o_pkt_cnt,
  o_byte_cnt,
  o_locked,
  o_err_cnt,
  o_err_beat
);

  parameter NUM_ID = 6;
  localparam ID_W = (NUM_ID == 1) ? 1 : $clog2(NUM_ID);

  typedef struct packed {
    logic [ID_W-1:0]     id;
    logic [11:0]         ena;
    logic [11:0]         sop;
    logic [11:0]         eop;
    logic [11:0]         err;
    logic [11:0][3:0]    mty;
    logic [11:0][127:0]  dat;
  } lbus_pkt_t;

  input  clk;
  input  rst;
  input  [5:0] port_rst;
  input  lbus_pkt_t  i_pkt;
  input  [NUM_ID-1:0] i_clear_counters;
  output logic [NUM_ID-1:0][63:0]  o_pkt_cnt;
  output logic [NUM_ID-1:0][63:0]  o_byte_cnt;
  output logic [NUM_ID-1:0][31:0]  o_err_cnt;
  output logic [NUM_ID-1:0]        o_locked;
  output logic                     o_err_beat;

  lbus_pkt_t [3:3] pkt_shift;
  wire [8:8][7:0] merge_size;
  wire [8:8][11:0][127:0] merge_data;

  reg   [8:1][11:0] eop;
  reg   [14:1][ID_W-1:0] rx_id;
  wire  [14:14] locked;
  wire  [14:14] err_pulse;
  reg   [8:8] locked_pre;

  always_ff @(posedge clk) begin
    if (rst) begin
      o_locked <= '0;
      eop <= '0;
    end
    else begin
      o_locked[rx_id[14]] <= locked[14];
      eop <= {eop, i_pkt.eop & i_pkt.ena};
      for (int i=0; i<6; i++) if (port_rst[i]) o_locked[i] <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    rx_id <= {rx_id, i_pkt.id};
    locked_pre[8] <= o_locked[rx_id[7]];
  end

  dcmac_seg_pktmon_shift u_shift_seg (
    .clk               (clk),
    .i_pkt             (i_pkt),
    .o_pkt             (pkt_shift[3])
  );

  dcmac_seg_pktmon_merge u_dat_merge (
    .clk               (clk),
    .i_pkt             (pkt_shift[3]),
    .o_size            (merge_size[8]),
    .o_dat             (merge_data[8])
  );

  // synthesis translate_off
  wire [191:0][7:0] byte_out;
  int j_max;
  reg [7:0] byte_nxt;
  reg [NUM_ID-1:0][7:0] byte_ctx;
  reg [191:0] byte_err;
  reg [7:0] byte_err_idx;
  bit [NUM_ID-1:0] found_err;
  bit mon_stop_on_error = 1'b1;

  initial if ($test$plusargs("nia_mon_no_stop")) mon_stop_on_error = 1'b0;

  assign byte_out = merge_data[8];

  always_ff @(negedge clk) begin
    byte_nxt = byte_ctx[rx_id[8]];
    byte_err = '0;

    if (rst) begin
      found_err = '0;
      byte_ctx <= '0;
      byte_nxt = '0;
    end

    for (int i=0; i<merge_size[8]; i++) begin
      if(byte_nxt !== byte_out[i]) begin
        if (byte_err == 0) byte_err_idx = i;
        byte_err[i] = found_err[rx_id[8]];
        if (found_err[rx_id[8]] && mon_stop_on_error) begin
          $error ("ID[%2d]: found error in the monitor merge data byte[%3d], expect 0x%x, received 0x%x ", rx_id[8], i, byte_nxt, byte_out[i]);
          $stop;
        end
        found_err[rx_id[8]] = 1'b1;
      end
      byte_nxt = byte_out[i] + 1'b1;
    end
    byte_ctx[rx_id[8]] <= byte_nxt;
  end
  // synthesis translate_on

  assign o_err_beat = err_pulse[14];

  dcmac_seg_pktmon_check u_check   (
  .clk            (clk),
  .rst            (rst),
  .i_id           (rx_id[8]),
  .i_num_byte     (merge_size[8]),
  .i_dat          (merge_data[8]),
  .i_locked  (locked_pre[8]),
  .o_locked  (locked[14]),
  .o_err     (err_pulse[14])
  );

  wire  byte_cnt_carry, pkt_cnt_carry;
  wire  [ID_W-1:0] carry_id_m1;
  wire  [NUM_ID-1:0][31:0] byte_cnt_upper, byte_cnt_lower, pkt_cnt_upper, pkt_cnt_lower;

  always @* begin
    for (int i=0; i<NUM_ID; i++) begin
      o_byte_cnt[i] = {byte_cnt_upper[i], byte_cnt_lower[i]};
      o_pkt_cnt[i] = {pkt_cnt_upper[i], pkt_cnt_lower[i]};
    end
  end

  dcmac_seg_cnt #(
    .REGISTER_INPUT (0)
  ) u_pkt_cnt_lower_inst (
    .clk                 (clk),
    .rst                 (rst),
    .i_clear_counters    (i_clear_counters),
    .i_id_m1             (rx_id[7]),
    .i_sop               (),
    .i_eop               (eop[8]),
    .i_size              (merge_size[8]),
    .o_byte_cnt          (byte_cnt_lower),
    .o_pkt_cnt           (pkt_cnt_lower),
    .o_carry_id_m1       (carry_id_m1),
    .o_byte_cnt_carry    (byte_cnt_carry),
    .o_pkt_cnt_carry     (pkt_cnt_carry)
  );

  dcmac_seg_cnt #(
    .REGISTER_INPUT (0)
  ) u_pkt_cnt_upper_inst (
    .clk                 (clk),
    .rst                 (rst),
    .i_clear_counters    (i_clear_counters),
    .i_id_m1             (carry_id_m1),
    .i_sop               ('0),
    .i_eop               ({11'd0, pkt_cnt_carry}),
    .i_size              ({7'd0, byte_cnt_carry}),
    .o_byte_cnt          (byte_cnt_upper),
    .o_pkt_cnt           (pkt_cnt_upper),
    .o_carry_id_m1       (),
    .o_byte_cnt_carry    (),
    .o_pkt_cnt_carry     ()
  );

  dcmac_seg_cnt #(
    .REGISTER_INPUT (0)
  ) u_err_cnt_inst (
    .clk                 (clk),
    .rst                 (rst),
    .i_clear_counters    (i_clear_counters),
    .i_id_m1             (rx_id[13]),
    .i_sop               (),
    .i_eop               ({11'd0, err_pulse[14]}),
    .i_size              (),
    .o_byte_cnt          (),
    .o_pkt_cnt           (o_err_cnt),
    .o_carry_id_m1       (),
    .o_byte_cnt_carry    (),
    .o_pkt_cnt_carry     ()
  );

endmodule
