// ---------------------------------------------------------------------------
// File        :
// Description :
// Author      :
// Language    : SystemVerilog
//
//
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module dcmac_seg_pktgen_ctrl (
  clk,
  rst,
  i_pkt_ena,
  i_min_len,
  i_max_len,
  i_req_id,
  i_req_id_vld,
  o_size,
  o_pkt_ctrl
);

  parameter NUM_ID = 6;
  localparam ID_W = (NUM_ID == 1) ? 1 : $clog2(NUM_ID);
  localparam int POLY = 17'b1_0110_1000_0000_0001;

  typedef struct packed {
    logic [ID_W-1:0]     id;
    logic [11:0]         ena;
    logic [11:0][15:0]   pkt_len;
    logic [11:0]         sop;
    logic [11:0]         eop;
    logic [11:0]         err;
    logic [11:0][3:0]    mty;
    logic [2:0][3:0]     pkt_mty_idx;
    logic [2:0][5:0]     mty_sum;
  } lbus_pkt_ctrl_t;

  input   clk;
  input   rst;
  input   [NUM_ID:0] i_pkt_ena;
  input   [15:0] i_min_len;
  input   [15:0] i_max_len;
  input   [ID_W-1:0] i_req_id;
  input   i_req_id_vld;
  output  reg [7:0] o_size;
  output  lbus_pkt_ctrl_t o_pkt_ctrl;

  reg   [1:0][NUM_ID:0] pkt_ena_reg;
  reg   [3:1] dat_req, pkt_ena;
  reg   [3:1][ID_W-1:0] id;
  logic [2:0][13:0] pkt_len_r;
  logic [2:1][2:0][13:0] pkt_len_r_p;
  reg   [2:0][9:0] num_seg_in_pkt;
  logic [2:2] reach_max, wr_cnt_max, pkt_end;
  reg   [9:0] num_seg_in_pkt_0_0_pre;
  reg   [2:0][9:0] num_seg_in_pkt_0_0;
  logic [2:0][3:0] num_seg_in_pkt_0_0_need;
  logic [2:2][9:0] num_seg_sum_0_0;
  reg   [9:0] num_seg_in_pkt_1_0_pre;
  reg   [2:0][9:0] num_seg_in_pkt_1_0;
  logic [2:0][3:0] num_seg_in_pkt_1_0_need;
  logic [2:2][9:0] num_seg_sum_1_0;
  reg   [9:0] num_seg_in_pkt_2_0_pre;
  reg   [2:0][9:0] num_seg_in_pkt_2_0;
  logic [2:0][3:0] num_seg_in_pkt_2_0_need;
  logic [2:2][9:0] num_seg_sum_2_0;
  reg [9:0] sum_seg_in_pkt_1_0;
  reg   [3:3][2:0][3:0] seg_r;
  wire  [2:2][3:0] seg_r_i;
  wire  [3:0] seg_r_o_2;
  reg   [3:0] seg_r_o_3;
  wire  pkt_on_going_i_2;
  reg   pkt_on_going_i_3;
  wire  pkt_on_going_o_2;
  reg   pkt_on_going_o_3;
  logic [2:0][2:0][3:0] byte_r;
  logic [3:0][2:0][3:0] pkt_mty;
  wire  [2:2][3:0] byte_r_i;
  wire  [2:2][3:0] byte_r_o;
  reg   [3:3][3:0] mty_o;
  wire  [2:2][7:0] cnt_max_i;
  wire  [2:2][7:0] cnt_max_o;
  wire  [2:2][7:0] cnt_i;
  wire  [2:2][7:0] cnt_o;
  reg   [3:3][3:0] eop;
  logic [3:3][11:0][3:0] eop_mux;
  logic [3:3][11:0] ena_bus, sop_bus, eop_bus;
  logic [3:3][11:0][3:0] mty;
  logic [3:3][4-1:0] non_idle_seg_sum;
  logic [3:3][5:0] mty_sum;

  wire [255:0][1:0] mod3;
  wire [15:0][3:0] mod12;

  logic [11:0][1:0] seg_tmp;
  logic [11:0][9:0] num_seg_sum_mux;
  logic [11:0] num_seg_sum_gt_12, num_seg_sum_gt_12_reg;
  logic [11:0][3:0] byte_r_i_mux_pre, byte_r_i_mux, byte_r_i_mux_reg;
  logic [11:0][3:0] seg_r_i_mux, seg_r_i_mux_reg;
  logic [11:0][7:0] cnt_max_mux, cnt_max_mux_reg;

  assign byte_r_i [2] = byte_r_i_mux_reg[seg_r_o_2];
  assign seg_r_i  [2] = seg_r_i_mux_reg [seg_r_o_2];
  assign cnt_max_i[2] = cnt_max_mux_reg [seg_r_o_2];

  assign cnt_i[2] = reach_max[2]? (|seg_r_o_2 | !pkt_on_going_o_2)? 6 : cnt_o[2]: cnt_o[2] + 3;
  assign reach_max[2] = cnt_o[2] >= cnt_max_o[2];
  assign wr_cnt_max[2] = dat_req[2] & reach_max[2] & (|seg_r_o_2 | !pkt_on_going_o_2);
  assign pkt_end[2] = dat_req[2] & reach_max[2] & pkt_on_going_o_2;
  assign pkt_on_going_i_2 = reach_max[2]? pkt_ena[2] & num_seg_sum_gt_12_reg[seg_r_o_2] & (|seg_r_o_2 | !pkt_on_going_o_2) : |pkt_on_going_o_2;

  assign num_seg_sum_0_0[2] = seg_r_o_2 + num_seg_in_pkt_0_0[2];
  assign num_seg_sum_1_0[2] = seg_r_o_2 + num_seg_in_pkt_1_0[2];
  assign num_seg_sum_2_0[2] = seg_r_o_2 + num_seg_in_pkt_2_0[2];

  always @* begin
    if (num_seg_in_pkt_0_0_need[0] <= 0) begin
      num_seg_sum_mux[0] = num_seg_in_pkt_0_0[0] + 0;
      byte_r_i_mux_pre[0] = byte_r[0][0];
    end
    else if (num_seg_in_pkt_1_0_need[0] <= 0) begin
      num_seg_sum_mux[0] = num_seg_in_pkt_1_0[0] + 0;
      byte_r_i_mux_pre[0] = byte_r[0][1];
    end
    else begin
      num_seg_sum_mux[0] = num_seg_in_pkt_2_0[0] + 0;
      byte_r_i_mux_pre[0] = byte_r[0][2];
    end
    if (num_seg_in_pkt_0_0_need[0] <= 1) begin
      num_seg_sum_mux[1] = num_seg_in_pkt_0_0[0] + 1;
      byte_r_i_mux_pre[1] = byte_r[0][0];
    end
    else if (num_seg_in_pkt_1_0_need[0] <= 1) begin
      num_seg_sum_mux[1] = num_seg_in_pkt_1_0[0] + 1;
      byte_r_i_mux_pre[1] = byte_r[0][1];
    end
    else begin
      num_seg_sum_mux[1] = num_seg_in_pkt_2_0[0] + 1;
      byte_r_i_mux_pre[1] = byte_r[0][2];
    end
    if (num_seg_in_pkt_0_0_need[0] <= 2) begin
      num_seg_sum_mux[2] = num_seg_in_pkt_0_0[0] + 2;
      byte_r_i_mux_pre[2] = byte_r[0][0];
    end
    else if (num_seg_in_pkt_1_0_need[0] <= 2) begin
      num_seg_sum_mux[2] = num_seg_in_pkt_1_0[0] + 2;
      byte_r_i_mux_pre[2] = byte_r[0][1];
    end
    else begin
      num_seg_sum_mux[2] = num_seg_in_pkt_2_0[0] + 2;
      byte_r_i_mux_pre[2] = byte_r[0][2];
    end
    if (num_seg_in_pkt_0_0_need[0] <= 3) begin
      num_seg_sum_mux[3] = num_seg_in_pkt_0_0[0] + 3;
      byte_r_i_mux_pre[3] = byte_r[0][0];
    end
    else if (num_seg_in_pkt_1_0_need[0] <= 3) begin
      num_seg_sum_mux[3] = num_seg_in_pkt_1_0[0] + 3;
      byte_r_i_mux_pre[3] = byte_r[0][1];
    end
    else begin
      num_seg_sum_mux[3] = num_seg_in_pkt_2_0[0] + 3;
      byte_r_i_mux_pre[3] = byte_r[0][2];
    end
    if (num_seg_in_pkt_0_0_need[0] <= 4) begin
      num_seg_sum_mux[4] = num_seg_in_pkt_0_0[0] + 4;
      byte_r_i_mux_pre[4] = byte_r[0][0];
    end
    else if (num_seg_in_pkt_1_0_need[0] <= 4) begin
      num_seg_sum_mux[4] = num_seg_in_pkt_1_0[0] + 4;
      byte_r_i_mux_pre[4] = byte_r[0][1];
    end
    else begin
      num_seg_sum_mux[4] = num_seg_in_pkt_2_0[0] + 4;
      byte_r_i_mux_pre[4] = byte_r[0][2];
    end
    if (num_seg_in_pkt_0_0_need[0] <= 5) begin
      num_seg_sum_mux[5] = num_seg_in_pkt_0_0[0] + 5;
      byte_r_i_mux_pre[5] = byte_r[0][0];
    end
    else if (num_seg_in_pkt_1_0_need[0] <= 5) begin
      num_seg_sum_mux[5] = num_seg_in_pkt_1_0[0] + 5;
      byte_r_i_mux_pre[5] = byte_r[0][1];
    end
    else begin
      num_seg_sum_mux[5] = num_seg_in_pkt_2_0[0] + 5;
      byte_r_i_mux_pre[5] = byte_r[0][2];
    end
    if (num_seg_in_pkt_0_0_need[0] <= 6) begin
      num_seg_sum_mux[6] = num_seg_in_pkt_0_0[0] + 6;
      byte_r_i_mux_pre[6] = byte_r[0][0];
    end
    else if (num_seg_in_pkt_1_0_need[0] <= 6) begin
      num_seg_sum_mux[6] = num_seg_in_pkt_1_0[0] + 6;
      byte_r_i_mux_pre[6] = byte_r[0][1];
    end
    else begin
      num_seg_sum_mux[6] = num_seg_in_pkt_2_0[0] + 6;
      byte_r_i_mux_pre[6] = byte_r[0][2];
    end
    if (num_seg_in_pkt_0_0_need[0] <= 7) begin
      num_seg_sum_mux[7] = num_seg_in_pkt_0_0[0] + 7;
      byte_r_i_mux_pre[7] = byte_r[0][0];
    end
    else if (num_seg_in_pkt_1_0_need[0] <= 7) begin
      num_seg_sum_mux[7] = num_seg_in_pkt_1_0[0] + 7;
      byte_r_i_mux_pre[7] = byte_r[0][1];
    end
    else begin
      num_seg_sum_mux[7] = num_seg_in_pkt_2_0[0] + 7;
      byte_r_i_mux_pre[7] = byte_r[0][2];
    end
    if (num_seg_in_pkt_0_0_need[0] <= 8) begin
      num_seg_sum_mux[8] = num_seg_in_pkt_0_0[0] + 8;
      byte_r_i_mux_pre[8] = byte_r[0][0];
    end
    else if (num_seg_in_pkt_1_0_need[0] <= 8) begin
      num_seg_sum_mux[8] = num_seg_in_pkt_1_0[0] + 8;
      byte_r_i_mux_pre[8] = byte_r[0][1];
    end
    else begin
      num_seg_sum_mux[8] = num_seg_in_pkt_2_0[0] + 8;
      byte_r_i_mux_pre[8] = byte_r[0][2];
    end
    if (num_seg_in_pkt_0_0_need[0] <= 9) begin
      num_seg_sum_mux[9] = num_seg_in_pkt_0_0[0] + 9;
      byte_r_i_mux_pre[9] = byte_r[0][0];
    end
    else if (num_seg_in_pkt_1_0_need[0] <= 9) begin
      num_seg_sum_mux[9] = num_seg_in_pkt_1_0[0] + 9;
      byte_r_i_mux_pre[9] = byte_r[0][1];
    end
    else begin
      num_seg_sum_mux[9] = num_seg_in_pkt_2_0[0] + 9;
      byte_r_i_mux_pre[9] = byte_r[0][2];
    end
    if (num_seg_in_pkt_0_0_need[0] <= 10) begin
      num_seg_sum_mux[10] = num_seg_in_pkt_0_0[0] + 10;
      byte_r_i_mux_pre[10] = byte_r[0][0];
    end
    else if (num_seg_in_pkt_1_0_need[0] <= 10) begin
      num_seg_sum_mux[10] = num_seg_in_pkt_1_0[0] + 10;
      byte_r_i_mux_pre[10] = byte_r[0][1];
    end
    else begin
      num_seg_sum_mux[10] = num_seg_in_pkt_2_0[0] + 10;
      byte_r_i_mux_pre[10] = byte_r[0][2];
    end
    if (num_seg_in_pkt_0_0_need[0] <= 11) begin
      num_seg_sum_mux[11] = num_seg_in_pkt_0_0[0] + 11;
      byte_r_i_mux_pre[11] = byte_r[0][0];
    end
    else if (num_seg_in_pkt_1_0_need[0] <= 11) begin
      num_seg_sum_mux[11] = num_seg_in_pkt_1_0[0] + 11;
      byte_r_i_mux_pre[11] = byte_r[0][1];
    end
    else begin
      num_seg_sum_mux[11] = num_seg_in_pkt_2_0[0] + 11;
      byte_r_i_mux_pre[11] = byte_r[0][2];
    end
  end

  always_ff @(posedge clk) begin
    for (int i=0; i<12; i++) begin
      cnt_max_mux[i] <= num_seg_sum_mux[i][9:2] + |num_seg_sum_mux[i][1:0];
      seg_tmp[i] = mod3[num_seg_sum_mux[i][9:2]];
      seg_r_i_mux[i] <= {seg_tmp[i], num_seg_sum_mux[i][1:0]};
      num_seg_sum_gt_12[i] <= num_seg_sum_mux[i] > 12;
      byte_r_i_mux[i] <= byte_r_i_mux_pre[i];
    end

    num_seg_sum_gt_12_reg <= num_seg_sum_gt_12;
    byte_r_i_mux_reg <= byte_r_i_mux;
    seg_r_i_mux_reg <= pkt_ena[1]? seg_r_i_mux : '0;
    cnt_max_mux_reg <= pkt_ena[1]? cnt_max_mux : '0;
  end

  logic fb;
  logic [2:0][15:0] len_r_nxt;
  reg   [2:0][15:0] len_r;

  always @* begin
    for (int i=0; i<3; i++) begin
      fb = 1'b0;
      for (int j=16; j>=0; j--) begin
        fb = fb ^ (len_r[i][j] & POLY[j+1]);
      end
      len_r_nxt[i][15:1] = len_r[i][14:0];
      len_r_nxt[i][0] = fb;
    end
  end

  always_ff @(posedge clk) begin
    for (int i=0; i<3; i++) begin
      if (i_max_len <= i_min_len) begin
        pkt_len_r[i] <= i_min_len;
      end
      else if (len_r[i][13:0] <= i_max_len) begin
        pkt_len_r[i] <= (len_r[i][13:0] >= i_min_len)? len_r[i][13:0] : i_min_len;
      end
      else begin
        pkt_len_r[i] <= '0;

        if (|len_r[i][9:0] & len_r[i][9:0] <= i_max_len & len_r[i][9:0] >= i_min_len) pkt_len_r[i] <= len_r[i][9:0];
        else if (|len_r[i][7:0] & len_r[i][7:0] <= i_max_len & len_r[i][7:0] >= i_min_len) pkt_len_r[i] <= len_r[i][7:0];
        else if  (|len_r[i][5:0] & len_r[i][5:0] <= i_max_len & len_r[i][5:0] >= i_min_len) pkt_len_r[i] <= len_r[i][5:0];
        else pkt_len_r[i] <= i_max_len;
      end
    end

    for (int i=0; i<3; i++) begin
      num_seg_in_pkt[i] <= pkt_len_r[i][13:4] + (|pkt_len_r[i][3:0]);
    end

    sum_seg_in_pkt_1_0 <= pkt_len_r[0][13:4] + (|pkt_len_r[0][3:0])
                        + pkt_len_r[1][13:4] + (|pkt_len_r[1][3:0]);

    num_seg_in_pkt_0_0_pre <= num_seg_in_pkt[0];

    num_seg_in_pkt_1_0_pre <= (num_seg_in_pkt[0][9] | num_seg_in_pkt[0][8])? '1 : 0
                             + sum_seg_in_pkt_1_0
                             ;

    num_seg_in_pkt_2_0_pre <= (num_seg_in_pkt[0][9] | num_seg_in_pkt[0][8] | num_seg_in_pkt[1][9] | num_seg_in_pkt[1][8])? '1 : 0
                             + sum_seg_in_pkt_1_0
                             + num_seg_in_pkt[2];;

    if (rst) begin
      for (int i=0; i<2; i++) begin
        len_r[i][3:0] <= i;
        len_r[i][15:4] <= '1;
      end
    end
    else begin
      len_r <= len_r_nxt;
    end

  end

  always @* begin
    for(int i=0; i<12; i++) begin
      ena_bus[3][i] = dat_req[3] & (pkt_ena[3] | pkt_on_going_i_3 | pkt_on_going_o_3 & (i < seg_r_o_3 | seg_r_o_3 == '0));

      if (i==0)
        sop_bus[3][0] = !pkt_on_going_o_3;
      else
        sop_bus[3][i] = eop[3][0] & i == seg_r_o_3
                      | eop[3][1] & i == seg_r[3][0]
                      | eop[3][2] & i == seg_r[3][1]
                      ;

      eop_mux[3][i][0] = eop[3][0] & (i+1)%12 == seg_r_o_3;
      eop_mux[3][i][1] = eop[3][1] & (i+1)%12 == seg_r[3][0];
      eop_mux[3][i][2] = eop[3][2] & (i+1)%12 == seg_r[3][1];
      eop_mux[3][i][3] = eop[3][3] & (i+1)%12 == seg_r[3][2];

      eop_bus[3][i] = |eop_mux[3][i];

      mty[3][i] = eop_mux[3][i][0]? mty_o[3]
                : eop_mux[3][i][1]? pkt_mty[3][0]
                : eop_mux[3][i][2]? pkt_mty[3][1]
                : eop_mux[3][i][3]? pkt_mty[3][2]
                : '0;
    end

    mty_sum[3] = eop[3][0]? mty_o[3] : 0;

    if (eop[3][1]) mty_sum[3] += pkt_mty[3][0];
    if (eop[3][2]) mty_sum[3] += pkt_mty[3][1];
    if (eop[3][3]) mty_sum[3] += pkt_mty[3][2];

    non_idle_seg_sum[3] = (pkt_ena[3] | pkt_on_going_i_3)? 12 : (seg_r_o_3 == '0)? 12 : seg_r_o_3;
  end

  wire [3:3][2:0][3:0] mty_mux;
  wire [3:3][2:0][3:0] seg_mux;

  assign seg_mux[3][0] = pkt_on_going_o_3? (eop[3][0]? seg_r_o_3 : 12) : (eop[3][1]? seg_r[3][0] : 12);
  assign mty_mux[3][0] = pkt_on_going_o_3? mty_o[3] & {4{eop[3][0]}} : pkt_mty[3][0] & {4{eop[3][1]}};

  assign seg_mux[3][1] = pkt_on_going_o_3? (eop[3][1]? seg_r[3][0] : 12) : (eop[3][2]? seg_r[3][1] : 12);
  assign mty_mux[3][1] = pkt_on_going_o_3? pkt_mty[3][0] & {4{eop[3][1]}} : pkt_mty[3][1] & {4{eop[3][2]}};

  assign seg_mux[3][2] = pkt_on_going_o_3? (eop[3][2]? seg_r[3][1] : 12) : (eop[3][3]? seg_r[3][2] : 12);
  assign mty_mux[3][2] = pkt_on_going_o_3? pkt_mty[3][1] & {4{eop[3][2]}} : pkt_mty[3][2] & {4{eop[3][3]}};

  always_ff @(posedge clk) begin
    pkt_ena_reg <= {pkt_ena_reg, i_pkt_ena};
    pkt_ena[1] <= ((i_req_id < NUM_ID)? pkt_ena_reg[1][i_req_id] : 1'b0) | pkt_ena_reg[1][NUM_ID];
    pkt_ena[3:2] <= pkt_ena[2:1];
    pkt_on_going_i_3 <= pkt_on_going_i_2;

    dat_req <= rst? 0 : {dat_req, i_req_id_vld};
    id <= {id, i_req_id};

    num_seg_in_pkt_0_0[0] <= num_seg_in_pkt_0_0_pre;
    num_seg_in_pkt_0_0_need[0] <= (num_seg_in_pkt_0_0_pre >= 12)? 0 : 12 - num_seg_in_pkt_0_0_pre;

    num_seg_in_pkt_0_0[2:1] <= num_seg_in_pkt_0_0[2-1:0];
    num_seg_in_pkt_0_0_need[2:1] <= num_seg_in_pkt_0_0_need[2-1:0];

    num_seg_in_pkt_1_0[0] <= num_seg_in_pkt_1_0_pre;
    num_seg_in_pkt_1_0_need[0] <= (num_seg_in_pkt_1_0_pre >= 12)? 0 : 12 - num_seg_in_pkt_1_0_pre;

    num_seg_in_pkt_1_0[2:1] <= num_seg_in_pkt_1_0[2-1:0];
    num_seg_in_pkt_1_0_need[2:1] <= num_seg_in_pkt_1_0_need[2-1:0];

    num_seg_in_pkt_2_0[0] <= num_seg_in_pkt_2_0_pre;
    num_seg_in_pkt_2_0_need[0] <= (num_seg_in_pkt_2_0_pre >= 12)? 0 : 12 - num_seg_in_pkt_2_0_pre;

    num_seg_in_pkt_2_0[2:1] <= num_seg_in_pkt_2_0[2-1:0];
    num_seg_in_pkt_2_0_need[2:1] <= num_seg_in_pkt_2_0_need[2-1:0];

    pkt_len_r_p <= {pkt_len_r_p, pkt_len_r};

    for (int i=0; i<3; i++) begin
      byte_r[0][i] <= pkt_len_r_p[2][i][3:0];
      pkt_mty[0][i] <= 16 - pkt_len_r_p[2][i][3:0];
    end

    byte_r[2:1] <= byte_r[1:0];
    pkt_mty[3:1] <= pkt_mty[2:0];

    seg_r[3][0] <= mod12[num_seg_sum_0_0[2][3:0]];
    seg_r[3][1] <= mod12[num_seg_sum_1_0[2][3:0]];
    seg_r[3][2] <= mod12[num_seg_sum_2_0[2][3:0]];

    mty_o[3] <= 16 - byte_r_o[2];
    seg_r_o_3 <= seg_r_o_2;
    pkt_on_going_o_3 <= pkt_on_going_o_2;

    eop[3][0] <= pkt_end[2];
    eop[3][1] <= pkt_ena[2]? pkt_on_going_o_2? pkt_end[2] & seg_r_o_2 <= num_seg_in_pkt_0_0_need[2] & |seg_r_o_2 : num_seg_in_pkt_0_0[2] <= 12 : 1'b0;
    eop[3][2] <= pkt_ena[2]? pkt_on_going_o_2? pkt_end[2] & seg_r_o_2 <= num_seg_in_pkt_1_0_need[2] & |seg_r_o_2 : num_seg_in_pkt_1_0[2] <= 12 : 1'b0;
    eop[3][3] <= pkt_ena[2]? pkt_on_going_o_2? pkt_end[2] & seg_r_o_2 <= num_seg_in_pkt_2_0_need[2] & |seg_r_o_2 : num_seg_in_pkt_2_0[2] <= 12 : 1'b0;

    o_pkt_ctrl.id  <= id[3];
    o_pkt_ctrl.ena <= ena_bus[3];
    o_pkt_ctrl.sop <= sop_bus[3];
    o_pkt_ctrl.eop <= eop_bus[3];
    o_pkt_ctrl.mty <= mty[3];
    o_pkt_ctrl.err <= '0;

    o_pkt_ctrl.pkt_mty_idx[0] <= (seg_mux[3][0] == 0)? 12 : seg_mux[3][0];
    o_pkt_ctrl.mty_sum[0] <= mty_mux[3][0]
                           ;
    o_pkt_ctrl.pkt_mty_idx[1] <= (seg_mux[3][1] == 0)? 12 : seg_mux[3][1];
    o_pkt_ctrl.mty_sum[1] <= mty_mux[3][0]
                           + mty_mux[3][1]
                           ;
    o_pkt_ctrl.pkt_mty_idx[2] <= (seg_mux[3][2] == 0)? 12 : seg_mux[3][2];
    o_pkt_ctrl.mty_sum[2] <= mty_mux[3][0]
                           + mty_mux[3][1]
                           + mty_mux[3][2]
                           ;

    o_size <= (rst | ~|ena_bus[3])? '0 : {non_idle_seg_sum[3], 4'd0} - mty_sum[3];
  end

  dcmac_seg_ctx_mem  #(
    .DW (8 + 4 + 4),
    .INIT_VALUE (0)
  ) u_cnt_max_ctx (
    .clk         (clk),
    .rst         (rst),
    .ts_rst      (1'b0),
    .i_rd_id     (id[1]),
    .i_ena       (wr_cnt_max[2]),
    .i_dat       ({cnt_max_i[2], seg_r_i[2], byte_r_i[2]}),
    .o_dat       ({cnt_max_o[2], seg_r_o_2, byte_r_o[2]}),
    .i_rd_during_wr  (1'b0),
    .o_init          ()
  );

  dcmac_seg_ctx_mem  #(
    .DW (1 + 8),
    .INIT_VALUE (0)
  ) u_cnt_ctx (
    .clk         (clk),
    .rst         (rst),
    .ts_rst      (1'b0),
    .i_rd_id     (id[1]),
    .i_ena       (dat_req[2]),
    .i_dat       ({pkt_on_going_i_2, cnt_i[2]}),
    .o_dat       ({pkt_on_going_o_2, cnt_o[2]}),
    .i_rd_during_wr  (1'b0),
    .o_init          ()
  );

  // synthesis translate_off
  reg [5:0][2:0][13:0] pkt_len_p;
  reg [NUM_ID-1:0][13:0] pkt_len_mem, pkt_len_cal;
  reg [NUM_ID-1:0] pkt_on_going;
  logic [5:0] pkt_num;
  logic [3:3][11:0][13:0] pkt_len;
  logic pkt_err;
  logic pkt_len_err;
  logic size_out_err;
  logic [13:0] pkt_len_nxt, pkt_len_cal_hold, pkt_len_ctrl;
  logic pkt_on_going_nxt;
  logic [15:0] cycle_byte_cnt;

  always @* begin
    pkt_len[3][0] = pkt_len_mem[id[3]];
    pkt_num = '0;
    pkt_len_nxt = pkt_len_cal[o_pkt_ctrl.id];
    pkt_on_going_nxt = pkt_on_going[o_pkt_ctrl.id];
    cycle_byte_cnt = 0;

    pkt_err = 1'b0;
    pkt_len_err = 1'b0;
    size_out_err = 1'b0;

    for(int i=0; i<12; i++) begin
      if (sop_bus[3][i]) begin
        pkt_len[3][i] =  pkt_len_p[5][pkt_num];
        pkt_num++;
      end
      else if (i>0) begin
        pkt_len[3][i] = pkt_len[3][i-1];
      end

      if (o_pkt_ctrl.ena[i]) begin
        cycle_byte_cnt += 16;

        if (o_pkt_ctrl.sop[i]) begin
          pkt_len_nxt = 16;
          pkt_err = pkt_on_going_nxt;
          pkt_on_going_nxt = 1'b1;
        end
        else if (o_pkt_ctrl.eop[i]) begin
          pkt_len_nxt += 16 - o_pkt_ctrl.mty[i];
          cycle_byte_cnt -= o_pkt_ctrl.mty[i];
          pkt_len_err = pkt_len_nxt != o_pkt_ctrl.pkt_len[i];
          if (pkt_len_err) begin
            pkt_len_cal_hold = pkt_len_nxt;
            pkt_len_ctrl = o_pkt_ctrl.pkt_len[i];
          end
          pkt_err = !pkt_on_going_nxt;
          pkt_on_going_nxt = 1'b0;
        end
        else begin
          pkt_len_nxt += 16;
          pkt_err = !pkt_on_going_nxt;
        end
      end
    end

    if (cycle_byte_cnt !== o_size) size_out_err = 1'b1;
  end

  always_ff @(posedge clk) begin
    pkt_len_p <= {pkt_len_p, pkt_len_r};
    if (dat_req[3]) pkt_len_mem[id[3]] <= pkt_len[3][11];

    for(int i=0; i<12; i++) begin
      o_pkt_ctrl.pkt_len[i] <= pkt_len[3][i];
    end

    pkt_len_cal[o_pkt_ctrl.id] <= pkt_len_nxt;
    pkt_on_going[o_pkt_ctrl.id] <= pkt_on_going_nxt;
  end

  reg [3:0] rst_p;
  wire check_armed = !rst & ~|rst_p;

  always_ff @(posedge clk) rst_p <= {rst_p[2:0], rst};

  always_ff @(negedge clk) begin
    if (pkt_err && o_pkt_ctrl.id < 6 && check_armed) begin
      $error ("pkt violation");
      $stop;
    end

    if (pkt_len_err && o_pkt_ctrl.id < 6 && check_armed) begin
      $error ("ID[%d] pkt length err, calcuated %d, expect %d", o_pkt_ctrl.id, pkt_len_cal_hold, pkt_len_ctrl);
      $stop;
    end

    if (size_out_err && o_pkt_ctrl.id < 6 && check_armed) begin
      $error ("ID[%d] size_out error", o_pkt_ctrl.id);
      $stop;
    end
  end
  // synthesis translate_on

  assign mod3[0] = 2'd0;
  assign mod3[1] = 2'd1;
  assign mod3[2] = 2'd2;
  assign mod3[3] = 2'd0;
  assign mod3[4] = 2'd1;
  assign mod3[5] = 2'd2;
  assign mod3[6] = 2'd0;
  assign mod3[7] = 2'd1;
  assign mod3[8] = 2'd2;
  assign mod3[9] = 2'd0;
  assign mod3[10] = 2'd1;
  assign mod3[11] = 2'd2;
  assign mod3[12] = 2'd0;
  assign mod3[13] = 2'd1;
  assign mod3[14] = 2'd2;
  assign mod3[15] = 2'd0;
  assign mod3[16] = 2'd1;
  assign mod3[17] = 2'd2;
  assign mod3[18] = 2'd0;
  assign mod3[19] = 2'd1;
  assign mod3[20] = 2'd2;
  assign mod3[21] = 2'd0;
  assign mod3[22] = 2'd1;
  assign mod3[23] = 2'd2;
  assign mod3[24] = 2'd0;
  assign mod3[25] = 2'd1;
  assign mod3[26] = 2'd2;
  assign mod3[27] = 2'd0;
  assign mod3[28] = 2'd1;
  assign mod3[29] = 2'd2;
  assign mod3[30] = 2'd0;
  assign mod3[31] = 2'd1;
  assign mod3[32] = 2'd2;
  assign mod3[33] = 2'd0;
  assign mod3[34] = 2'd1;
  assign mod3[35] = 2'd2;
  assign mod3[36] = 2'd0;
  assign mod3[37] = 2'd1;
  assign mod3[38] = 2'd2;
  assign mod3[39] = 2'd0;
  assign mod3[40] = 2'd1;
  assign mod3[41] = 2'd2;
  assign mod3[42] = 2'd0;
  assign mod3[43] = 2'd1;
  assign mod3[44] = 2'd2;
  assign mod3[45] = 2'd0;
  assign mod3[46] = 2'd1;
  assign mod3[47] = 2'd2;
  assign mod3[48] = 2'd0;
  assign mod3[49] = 2'd1;
  assign mod3[50] = 2'd2;
  assign mod3[51] = 2'd0;
  assign mod3[52] = 2'd1;
  assign mod3[53] = 2'd2;
  assign mod3[54] = 2'd0;
  assign mod3[55] = 2'd1;
  assign mod3[56] = 2'd2;
  assign mod3[57] = 2'd0;
  assign mod3[58] = 2'd1;
  assign mod3[59] = 2'd2;
  assign mod3[60] = 2'd0;
  assign mod3[61] = 2'd1;
  assign mod3[62] = 2'd2;
  assign mod3[63] = 2'd0;
  assign mod3[64] = 2'd1;
  assign mod3[65] = 2'd2;
  assign mod3[66] = 2'd0;
  assign mod3[67] = 2'd1;
  assign mod3[68] = 2'd2;
  assign mod3[69] = 2'd0;
  assign mod3[70] = 2'd1;
  assign mod3[71] = 2'd2;
  assign mod3[72] = 2'd0;
  assign mod3[73] = 2'd1;
  assign mod3[74] = 2'd2;
  assign mod3[75] = 2'd0;
  assign mod3[76] = 2'd1;
  assign mod3[77] = 2'd2;
  assign mod3[78] = 2'd0;
  assign mod3[79] = 2'd1;
  assign mod3[80] = 2'd2;
  assign mod3[81] = 2'd0;
  assign mod3[82] = 2'd1;
  assign mod3[83] = 2'd2;
  assign mod3[84] = 2'd0;
  assign mod3[85] = 2'd1;
  assign mod3[86] = 2'd2;
  assign mod3[87] = 2'd0;
  assign mod3[88] = 2'd1;
  assign mod3[89] = 2'd2;
  assign mod3[90] = 2'd0;
  assign mod3[91] = 2'd1;
  assign mod3[92] = 2'd2;
  assign mod3[93] = 2'd0;
  assign mod3[94] = 2'd1;
  assign mod3[95] = 2'd2;
  assign mod3[96] = 2'd0;
  assign mod3[97] = 2'd1;
  assign mod3[98] = 2'd2;
  assign mod3[99] = 2'd0;
  assign mod3[100] = 2'd1;
  assign mod3[101] = 2'd2;
  assign mod3[102] = 2'd0;
  assign mod3[103] = 2'd1;
  assign mod3[104] = 2'd2;
  assign mod3[105] = 2'd0;
  assign mod3[106] = 2'd1;
  assign mod3[107] = 2'd2;
  assign mod3[108] = 2'd0;
  assign mod3[109] = 2'd1;
  assign mod3[110] = 2'd2;
  assign mod3[111] = 2'd0;
  assign mod3[112] = 2'd1;
  assign mod3[113] = 2'd2;
  assign mod3[114] = 2'd0;
  assign mod3[115] = 2'd1;
  assign mod3[116] = 2'd2;
  assign mod3[117] = 2'd0;
  assign mod3[118] = 2'd1;
  assign mod3[119] = 2'd2;
  assign mod3[120] = 2'd0;
  assign mod3[121] = 2'd1;
  assign mod3[122] = 2'd2;
  assign mod3[123] = 2'd0;
  assign mod3[124] = 2'd1;
  assign mod3[125] = 2'd2;
  assign mod3[126] = 2'd0;
  assign mod3[127] = 2'd1;
  assign mod3[128] = 2'd2;
  assign mod3[129] = 2'd0;
  assign mod3[130] = 2'd1;
  assign mod3[131] = 2'd2;
  assign mod3[132] = 2'd0;
  assign mod3[133] = 2'd1;
  assign mod3[134] = 2'd2;
  assign mod3[135] = 2'd0;
  assign mod3[136] = 2'd1;
  assign mod3[137] = 2'd2;
  assign mod3[138] = 2'd0;
  assign mod3[139] = 2'd1;
  assign mod3[140] = 2'd2;
  assign mod3[141] = 2'd0;
  assign mod3[142] = 2'd1;
  assign mod3[143] = 2'd2;
  assign mod3[144] = 2'd0;
  assign mod3[145] = 2'd1;
  assign mod3[146] = 2'd2;
  assign mod3[147] = 2'd0;
  assign mod3[148] = 2'd1;
  assign mod3[149] = 2'd2;
  assign mod3[150] = 2'd0;
  assign mod3[151] = 2'd1;
  assign mod3[152] = 2'd2;
  assign mod3[153] = 2'd0;
  assign mod3[154] = 2'd1;
  assign mod3[155] = 2'd2;
  assign mod3[156] = 2'd0;
  assign mod3[157] = 2'd1;
  assign mod3[158] = 2'd2;
  assign mod3[159] = 2'd0;
  assign mod3[160] = 2'd1;
  assign mod3[161] = 2'd2;
  assign mod3[162] = 2'd0;
  assign mod3[163] = 2'd1;
  assign mod3[164] = 2'd2;
  assign mod3[165] = 2'd0;
  assign mod3[166] = 2'd1;
  assign mod3[167] = 2'd2;
  assign mod3[168] = 2'd0;
  assign mod3[169] = 2'd1;
  assign mod3[170] = 2'd2;
  assign mod3[171] = 2'd0;
  assign mod3[172] = 2'd1;
  assign mod3[173] = 2'd2;
  assign mod3[174] = 2'd0;
  assign mod3[175] = 2'd1;
  assign mod3[176] = 2'd2;
  assign mod3[177] = 2'd0;
  assign mod3[178] = 2'd1;
  assign mod3[179] = 2'd2;
  assign mod3[180] = 2'd0;
  assign mod3[181] = 2'd1;
  assign mod3[182] = 2'd2;
  assign mod3[183] = 2'd0;
  assign mod3[184] = 2'd1;
  assign mod3[185] = 2'd2;
  assign mod3[186] = 2'd0;
  assign mod3[187] = 2'd1;
  assign mod3[188] = 2'd2;
  assign mod3[189] = 2'd0;
  assign mod3[190] = 2'd1;
  assign mod3[191] = 2'd2;
  assign mod3[192] = 2'd0;
  assign mod3[193] = 2'd1;
  assign mod3[194] = 2'd2;
  assign mod3[195] = 2'd0;
  assign mod3[196] = 2'd1;
  assign mod3[197] = 2'd2;
  assign mod3[198] = 2'd0;
  assign mod3[199] = 2'd1;
  assign mod3[200] = 2'd2;
  assign mod3[201] = 2'd0;
  assign mod3[202] = 2'd1;
  assign mod3[203] = 2'd2;
  assign mod3[204] = 2'd0;
  assign mod3[205] = 2'd1;
  assign mod3[206] = 2'd2;
  assign mod3[207] = 2'd0;
  assign mod3[208] = 2'd1;
  assign mod3[209] = 2'd2;
  assign mod3[210] = 2'd0;
  assign mod3[211] = 2'd1;
  assign mod3[212] = 2'd2;
  assign mod3[213] = 2'd0;
  assign mod3[214] = 2'd1;
  assign mod3[215] = 2'd2;
  assign mod3[216] = 2'd0;
  assign mod3[217] = 2'd1;
  assign mod3[218] = 2'd2;
  assign mod3[219] = 2'd0;
  assign mod3[220] = 2'd1;
  assign mod3[221] = 2'd2;
  assign mod3[222] = 2'd0;
  assign mod3[223] = 2'd1;
  assign mod3[224] = 2'd2;
  assign mod3[225] = 2'd0;
  assign mod3[226] = 2'd1;
  assign mod3[227] = 2'd2;
  assign mod3[228] = 2'd0;
  assign mod3[229] = 2'd1;
  assign mod3[230] = 2'd2;
  assign mod3[231] = 2'd0;
  assign mod3[232] = 2'd1;
  assign mod3[233] = 2'd2;
  assign mod3[234] = 2'd0;
  assign mod3[235] = 2'd1;
  assign mod3[236] = 2'd2;
  assign mod3[237] = 2'd0;
  assign mod3[238] = 2'd1;
  assign mod3[239] = 2'd2;
  assign mod3[240] = 2'd0;
  assign mod3[241] = 2'd1;
  assign mod3[242] = 2'd2;
  assign mod3[243] = 2'd0;
  assign mod3[244] = 2'd1;
  assign mod3[245] = 2'd2;
  assign mod3[246] = 2'd0;
  assign mod3[247] = 2'd1;
  assign mod3[248] = 2'd2;
  assign mod3[249] = 2'd0;
  assign mod3[250] = 2'd1;
  assign mod3[251] = 2'd2;
  assign mod3[252] = 2'd0;
  assign mod3[253] = 2'd1;
  assign mod3[254] = 2'd2;
  assign mod3[255] = 2'd0;

  assign mod12[0] = 4'd0;
  assign mod12[1] = 4'd1;
  assign mod12[2] = 4'd2;
  assign mod12[3] = 4'd3;
  assign mod12[4] = 4'd4;
  assign mod12[5] = 4'd5;
  assign mod12[6] = 4'd6;
  assign mod12[7] = 4'd7;
  assign mod12[8] = 4'd8;
  assign mod12[9] = 4'd9;
  assign mod12[10] = 4'd10;
  assign mod12[11] = 4'd11;
  assign mod12[12] = '0;
  assign mod12[13] = '0;
  assign mod12[14] = '0;
  assign mod12[15] = '0;

endmodule

module dcmac_seg_pktgen_bufctx (
  clk,
  rst,
  i_id,
  i_id_valid_p1,
  i_size,
  o_id,
  o_buf_size,
  o_buf_idx,
  o_dat_req
);

  parameter NUM_ID = 6;
  localparam ID_W = (NUM_ID == 1) ? 1 : $clog2(NUM_ID);

  input  clk;
  input  rst;
  input  i_id_valid_p1;
  input  [ID_W-1:0] i_id;
  input  [7:0] i_size;
  output reg [ID_W-1:0] o_id;
  output reg [7:0] o_buf_size;
  output reg [7:0] o_buf_idx;
  output reg o_dat_req;

  reg   [1:1][ID_W-1:0] id;
  reg   [1:1][7:0] size, size_c, size_m1;
  wire  [1:1] need_new_ena_i, need_new_ena_o;
  wire  [1:1][1:0][7:0] buf_size_i;
  wire  [1:1][1:0][7:0] buf_size_o;
  wire  [1:1][1:0][7:0] buf_idx_i;
  wire  [1:1][1:0][7:0] buf_idx_o;
  wire  [1:1][7:0] buf_size_mux;
  wire  [1:1][7:0] buf_idx_mux;

  assign buf_size_mux[1] = buf_size_o[1][need_new_ena_o[1]];
  assign buf_idx_mux[1]  = buf_idx_o[1][need_new_ena_o[1]];

  assign need_new_ena_i[1] = buf_size_mux[1] < size[1];
  assign buf_size_i[1][1]  = buf_size_mux[1] + size_c[1];
  assign buf_size_i[1][0]  = buf_size_mux[1] - size[1];

  assign buf_idx_i[1][1] = size_m1[1] - buf_size_mux[1];
  assign buf_idx_i[1][0] = buf_idx_mux[1] + size[1];

  always_ff @(posedge clk) begin
    size[1] <= i_size;
    size_c[1] <= 192 - i_size;
    size_m1[1] = i_size - 1'b1;
    id[1] <= i_id;

    o_dat_req <= need_new_ena_i[1];
    {o_buf_size, o_buf_idx} <= {buf_size_mux[1], buf_idx_mux[1]};
    o_id <= id[1];
  end

  dcmac_seg_ctx_mem  #(
    .DW (8 * 2),
    .INIT_VALUE (0)
  ) u_buffer_size_0_ctx (
    .clk             (clk),
    .rst             (rst),
    .ts_rst          (1'b0),
    .i_rd_id         (i_id),
    .i_ena           (i_id_valid_p1),
    .i_dat           ({buf_size_i[1][0], buf_idx_i[1][0]}),
    .o_dat           ({buf_size_o[1][0], buf_idx_o[1][0]}),
    .i_rd_during_wr  (1'b0),
    .o_init          ()
  );

  dcmac_seg_ctx_mem  #(
    .DW (8 * 2),
    .INIT_VALUE (0)
  ) u_buffer_size_1_ctx (
    .clk             (clk),
    .rst             (rst),
    .ts_rst          (1'b0),
    .i_rd_id         (i_id),
    .i_ena           (i_id_valid_p1),
    .i_dat           ({buf_size_i[1][1], buf_idx_i[1][1]}),
    .o_dat           ({buf_size_o[1][1], buf_idx_o[1][1]}),
    .i_rd_during_wr  (1'b0),
    .o_init          ()
  );

  dcmac_seg_ctx_mem  #(
    .DW (1),
    .INIT_VALUE (0)
  ) u_gt_ctx (
    .clk             (clk),
    .rst             (rst),
    .ts_rst          (1'b0),
    .i_rd_id         (i_id),
    .i_ena           (i_id_valid_p1),
    .i_dat           (need_new_ena_i[1]),
    .o_dat           (need_new_ena_o[1]),
    .i_rd_during_wr  (1'b0),
    .o_init          ()
  );

endmodule

module dcmac_seg_pktgen_merge (
  clk,
  rst,
  i_id_m1,
  i_buf_size,
  i_buf_idx,
  i_dat_ena,
  i_dat,
  o_id,
  o_dat
);

  parameter NUM_ID = 6;
  localparam ID_W = (NUM_ID == 1) ? 1 : $clog2(NUM_ID);

  input  clk;
  input  rst;
  input  [ID_W-1:0] i_id_m1;
  input  [7:0] i_buf_size;
  input  [7:0] i_buf_idx;
  input  i_dat_ena;
  input  [191:0][7:0] i_dat;
  output reg [ID_W-1:0] o_id;
  output reg [191:0][7:0] o_dat;

  reg   [3:0][ID_W-1:0] id;
  wire  [7:0] buf_size_0;
  reg   [3:1][7:0] buf_size;
  wire  [7:0] buf_idx_0;
  reg   [3:1][7:0] buf_idx;
  wire  [1535:0] shift_dat_new_0;
  reg   [3:1][1535:0] shift_dat_new;
  wire  [1535:0] shift_dat_old_0;
  reg   [3:1][1535:0] shift_dat_old;
  wire  [0:0][1536-8-1:0] buf_dat_i, buf_dat_o;
  wire  [3:3][191-1:0][7:0] byte_old;
  wire  [3:3][191:0][7:0] byte_new;

  assign buf_size_0 = i_buf_size;
  assign buf_idx_0 = i_buf_idx;

  assign shift_dat_old_0 = buf_dat_o[0];
  assign shift_dat_new_0 = i_dat;

  assign buf_dat_i[0] = i_dat[191:1];

  assign byte_old[3] = shift_dat_old[3];
  assign byte_new[3] = shift_dat_new[3];

  always_ff @(posedge clk) begin

    id[3:0] <= {id[2:0], i_id_m1};
    buf_size[3:2] <= buf_size[2:1];
    buf_size[1] <= buf_size_0;
    buf_idx[3:2] <= buf_idx[2:1];
    buf_idx[1] <= buf_idx_0;

    shift_dat_old[1] <= shift_dat_old_0 >> {buf_idx_0[2:0], 3'd0};
    shift_dat_old[2] <= shift_dat_old[1] >> {buf_idx[1][5:3], 6'd0};
    shift_dat_old[3] <= shift_dat_old[2] >> {buf_idx[2][7:6], 9'd0};

    shift_dat_new[1] <= shift_dat_new_0 << {buf_size_0[2:0], 3'd0};
    shift_dat_new[2] <= shift_dat_new[1] << {buf_size[1][5:3], 6'd0};
    shift_dat_new[3] <= shift_dat_new[2] << {buf_size[2][7:6], 9'd0};

    for (int i=0; i<192; i++) begin
      o_dat[i] <= (i < buf_size[3])? byte_old[3][i] : byte_new[3][i];
    end
    o_id <= id[3];
  end

  dcmac_seg_ctx_mem  #(
    .DW (1536 - 8),
    .DISABLE_INIT (1)
  ) u_buffer_dat_ctx (
    .clk             (clk),
    .rst             (rst),
    .ts_rst          (1'b0),
    .i_rd_id         (i_id_m1),
    .i_ena           (i_dat_ena),
    .i_dat           (buf_dat_i[0]),
    .o_dat           (buf_dat_o[0]),
    .i_rd_during_wr  (1'b0),
    .o_init          ()
  );

endmodule

module dcmac_seg_pktgen_shift (
  clk,
  i_pkt_ctrl,
  i_dat,
  o_pkt
);
  parameter REGISTER_INPUT = 1;
  parameter NUM_ID = 6;
  localparam ID_W = (NUM_ID == 1) ? 1 : $clog2(NUM_ID);

  typedef struct packed {
    logic [ID_W-1:0]     id;
    logic [11:0]         ena;
    logic [11:0][15:0]   pkt_len;
    logic [11:0]         sop;
    logic [11:0]         eop;
    logic [11:0]         err;
    logic [11:0][3:0]    mty;
    logic [2:0][3:0]     pkt_mty_idx;
    logic [2:0][5:0]     mty_sum;
  } lbus_pkt_ctrl_t;

  typedef struct packed {
    logic [ID_W-1:0]     id;
    logic [11:0]         ena;
    logic [11:0]         sop;
    logic [11:0]         eop;
    logic [11:0]         err;
    logic [11:0][3:0]    mty;
    logic [11:0][127:0]  dat;
  } lbus_pkt_t;

  input clk;
  input lbus_pkt_ctrl_t i_pkt_ctrl;
  input [11:0][127:0] i_dat;
  output lbus_pkt_t o_pkt;

  lbus_pkt_ctrl_t [2:1] pkt_ctrl;
  reg  [1:1][11:1][8-1:0] gap_before;
  reg  [1:1][11:0][127:0] data_in;
  wire [1:1][192-1:0][7:0] byte_in;
  reg  [2:2][192-1:0][7:0] dout;

  wire [3:0][31*8-1:0] bus_0, bus_shift_0;

  assign bus_0[0] = byte_in[1][31:1];
  assign bus_0[1] = byte_in[1][47:17];
  assign bus_0[2] = byte_in[1][63:33];
  assign bus_0[3] = byte_in[1][79:49];

  assign bus_shift_0[0] = bus_0[0] << {gap_before[1][1][3:0], 3'd0};
  assign bus_shift_0[1] = bus_0[1] << {gap_before[1][2][3:0], 3'd0};
  assign bus_shift_0[2] = bus_0[2] << {gap_before[1][3][3:0], 3'd0};
  assign bus_shift_0[3] = bus_0[3] << {gap_before[1][4][3:0], 3'd0};

  wire [3:0][46*8-1:0] bus_1, bus_shift_1;

  assign bus_1[0] = byte_in[1][ 95:50];
  assign bus_1[1] = byte_in[1][111:66];
  assign bus_1[2] = byte_in[1][127:82];
  assign bus_1[3] = byte_in[1][143:98];

  assign bus_shift_1[0] = bus_1[0] << {gap_before[1][5][4:0], 3'd0};
  assign bus_shift_1[1] = bus_1[1] << {gap_before[1][6][4:0], 3'd0};
  assign bus_shift_1[2] = bus_1[2] << {gap_before[1][7][4:0], 3'd0};
  assign bus_shift_1[3] = bus_1[3] << {gap_before[1][8][4:0], 3'd0};

  wire [2:0][61*8-1:0] bus_2, bus_shift_2;

  assign bus_2[0] = byte_in[1][159: 99];
  assign bus_2[1] = byte_in[1][175:115];
  assign bus_2[2] = byte_in[1][191:131];

  assign bus_shift_2[0] = bus_2[0] << {gap_before[1] [9][5:0], 3'd0};
  assign bus_shift_2[1] = bus_2[1] << {gap_before[1][10][5:0], 3'd0};
  assign bus_shift_2[2] = bus_2[2] << {gap_before[1][11][5:0], 3'd0};

  assign byte_in[1] = REGISTER_INPUT? data_in[1] : i_dat;

  always_ff @(posedge clk) begin
    data_in[1] <= i_dat;
    pkt_ctrl <= {pkt_ctrl, i_pkt_ctrl};

    for (int i=1; i<12; i++) begin
      gap_before[1][i] <= (i >= i_pkt_ctrl.pkt_mty_idx[2])? i_pkt_ctrl.mty_sum[2]
                        : (i >= i_pkt_ctrl.pkt_mty_idx[1])? i_pkt_ctrl.mty_sum[1]
                        : (i >= i_pkt_ctrl.pkt_mty_idx[0])? i_pkt_ctrl.mty_sum[0]
                        : '0;
    end

    dout[2][15:0]  <= byte_in[1][15:0];
    dout[2][31:16] <= bus_shift_0[0][31*8-1:15*8];
    dout[2][47:32] <= bus_shift_0[1][31*8-1:15*8];
    dout[2][63:48] <= bus_shift_0[2][31*8-1:15*8];
    dout[2][79:64] <= bus_shift_0[3][31*8-1:15*8];

    dout[2][ 95: 80] <= bus_shift_1[0][46*8-1:30*8];
    dout[2][111: 96] <= bus_shift_1[1][46*8-1:30*8];
    dout[2][127:112] <= bus_shift_1[2][46*8-1:30*8];
    dout[2][143:128] <= bus_shift_1[3][46*8-1:30*8];

    dout[2][159:144] <= bus_shift_2[0][61*8-1:45*8];
    dout[2][175:160] <= bus_shift_2[1][61*8-1:45*8];
    dout[2][191:176] <= bus_shift_2[2][61*8-1:45*8];

    o_pkt.id       <= pkt_ctrl[2].id;
    o_pkt.ena      <= pkt_ctrl[2].ena;
    o_pkt.sop      <= pkt_ctrl[2].sop;
    o_pkt.eop      <= pkt_ctrl[2].eop;
    o_pkt.err      <= pkt_ctrl[2].err;
    o_pkt.mty      <= pkt_ctrl[2].mty;
    o_pkt.dat      <= dout[2];
  end

endmodule

module dcmac_seg_pktgen_payload (
  clk,
  rst,
  i_id_m1,
  i_req_en,
  i_req_num,
  i_seed,
  o_dat
);

  parameter REGISTER_OUTPUT = 1;
  parameter LOAD_SEED = 0;
  parameter NUM_ID = 6;
  localparam ID_W = (NUM_ID == 1) ? 1 : $clog2(NUM_ID);

  input        clk;
  input        rst;
  input        [ID_W-1:0] i_id_m1;
  input        i_req_en;
  input        [8-1:0] i_req_num;
  input        [16-1:0] i_seed;
  output logic [1536-1:0]  o_dat;

  logic  [16-1:0] seed_i;
  logic  [16-1:0] seed_o;
  wire   [16-1:0] seed_sel;
  logic  [192-1:0][7:0] cnt_nxt;
  reg    [1536-1:0] dat_reg;
  wire   [1536-1:0] dat_nxt;

  assign dat_nxt = cnt_nxt;
  assign o_dat = REGISTER_OUTPUT? dat_reg : dat_nxt;

  assign seed_i = {8'd0, cnt_nxt[i_req_num-1]};
  assign seed_sel = LOAD_SEED? i_seed : seed_o;

  always @* begin
    for (int i=0; i<192; i++) begin
      cnt_nxt[i] = seed_sel + (i + 1);
    end
  end

  always_ff @(posedge clk) begin
    dat_reg <= dat_nxt;
  end

  dcmac_seg_ctx_mem  #(
    .DW (16),
    .INIT_VALUE ({16{1'b1}})
  ) u_seed_ctx (
    .clk             (clk),
    .rst             (rst),
    .ts_rst          (1'b0),
    .i_rd_id         (i_id_m1),
    .i_ena           (i_req_en),
    .i_dat           (seed_i),
    .o_dat           (seed_o),
    .i_rd_during_wr  (1'b0),
    .o_init          ()
  );

endmodule

module dcmac_seg_pktgen_gearbox (
  clk,
  rst,
  i_data_rate,
  i_pkt_ena,
  i_skip_response,
  i_pkt,
  i_tready,
  i_hdr_ena,
  i_hdr_bytes,
  o_af,
  o_vld,
  o_preamble,
  o_slice,
  o_underflow,
  o_overflow
);

  parameter REGISTER_INPUT = 1;

  localparam int HDR_B      = 42;
  localparam int HDR_SEG_B  = 16;
  localparam logic [1:0] HDR_NO_SEG = 2'd3;

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
  } axis_tx_pkt_t;

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
  input                [5:0][1:0]     i_data_rate;
  input                               i_skip_response;
  input  axis_tx_pkt_t                i_pkt;
  input                [5:0]          i_pkt_ena;
  input                [5:0]          i_tready;
  input                               i_hdr_ena;
  input                [HDR_B*8-1:0]  i_hdr_bytes;
  output slice_t       [5:0]          o_slice;
  output               [5:0]          o_af;
  output reg           [5:0][55:0]    o_preamble;
  output reg           [5:0]          o_underflow;
  output reg           [5:0]          o_overflow;
  output reg           [5:0]          o_vld;

  wire                        p0_400;
  wire                        p0_200;
  wire                        p2_200;
  wire                        p4_200;
  wire                        p0_200_or_400;
  wire                        skip_response_n_reg_0;
  reg                         skip_response_n_reg_1;
  slice_t [5:0]               slice_in;
  reg     [5:0][2:0]          remainder;
  reg     [5:0]               wr_ena_pre, wr_ena;
  logic   [5:0]               new_dat;
  reg     [5:0]               rst_mask;
  wire    [5:0]               tready_mask;
  reg     [5:0]               dat_enough;
  slice_t [5:0]               slice_reg_0;
  slice_t [5:1][4:0]          slice_reg;
  slice_t [3:0]               din_0;
  slice_t [1:0]               din_2, din_4;
  slice_t                     din_1, din_3, din_5;
  slice_t [5:0]               fin;
  slice_t [5:0]               slice_out;

  localparam int SLICE_W = $bits(slice_t);

  wire [5:0][SLICE_W-1:0]     fout_slice_flat;
  wire [5:0][SLICE_W-1:0]     slice_out_flat;
  wire    [11:0]              sop_out;
  axis_tx_pkt_t               pkt_out;

  assign p0_400 = i_data_rate[0] == R_400G;
  assign p0_200 = i_data_rate[0] == R_200G;
  assign p0_200_or_400 = i_data_rate[0] == R_400G | i_data_rate[0] == R_200G;
  assign p2_200 = i_data_rate[2] == R_200G;
  assign p4_200 = i_data_rate[4] == R_200G;

  assign tready_mask[0] = i_tready[0];
  assign tready_mask[1] = p0_200_or_400? i_tready[0] : i_tready[1];
  assign tready_mask[2] = p0_400? i_tready[0] : i_tready[2];
  assign tready_mask[3] = p0_400? i_tready[0] : p2_200? i_tready[2] : i_tready[3];
  assign tready_mask[4] = i_tready[4];
  assign tready_mask[5] = p4_200? i_tready[4] : i_tready[5];

  assign sop_out[00] = slice_out[0].sop[0] & slice_out[0].ena[0];
  assign sop_out[01] = slice_out[0].sop[1] & slice_out[0].ena[1];
  assign sop_out[02] = slice_out[1].sop[0] & slice_out[1].ena[0];
  assign sop_out[03] = slice_out[1].sop[1] & slice_out[1].ena[1];
  assign sop_out[04] = slice_out[2].sop[0] & slice_out[2].ena[0];
  assign sop_out[05] = slice_out[2].sop[1] & slice_out[2].ena[1];
  assign sop_out[06] = slice_out[3].sop[0] & slice_out[3].ena[0];
  assign sop_out[07] = slice_out[3].sop[1] & slice_out[3].ena[1];
  assign sop_out[08] = slice_out[4].sop[0] & slice_out[4].ena[0];
  assign sop_out[09] = slice_out[4].sop[1] & slice_out[4].ena[1];
  assign sop_out[10] = slice_out[5].sop[0] & slice_out[5].ena[0];
  assign sop_out[11] = slice_out[5].sop[1] & slice_out[5].ena[1];

  generate
    if (REGISTER_INPUT) begin : GEN_ENABLE_REGISTER_INPUT
      always_ff @(posedge clk) begin
        for (int i=0; i<6; i++) begin
          new_dat[i] <= |i_pkt.ena & i_pkt.id == i;

          slice_in[i].ena <= {i_pkt.ena[i*2+1], i_pkt.ena[i*2]};
          slice_in[i].sop <= {i_pkt.sop[i*2+1], i_pkt.sop[i*2]};
          slice_in[i].eop <= {i_pkt.eop[i*2+1], i_pkt.eop[i*2]};
          slice_in[i].err <= {i_pkt.err[i*2+1], i_pkt.err[i*2]};
          slice_in[i].mty <= {i_pkt.mty[i*2+1], i_pkt.mty[i*2]};
          slice_in[i].dat <= {i_pkt.dat[i*2+1], i_pkt.dat[i*2]};
        end
      end
    end
    else begin : GEN_DISABLE_REGISTER_INPUT
      always @* begin
        for (int i=0; i<6; i++) begin
          new_dat[i] = |i_pkt.ena & i_pkt.id == i;

          slice_in[i].ena = {i_pkt.ena[i*2+1], i_pkt.ena[i*2]};
          slice_in[i].sop = {i_pkt.sop[i*2+1], i_pkt.sop[i*2]};
          slice_in[i].eop = {i_pkt.eop[i*2+1], i_pkt.eop[i*2]};
          slice_in[i].err = {i_pkt.err[i*2+1], i_pkt.err[i*2]};
          slice_in[i].mty = {i_pkt.mty[i*2+1], i_pkt.mty[i*2]};
          slice_in[i].dat = {i_pkt.dat[i*2+1], i_pkt.dat[i*2]};
        end
      end
    end
  endgenerate

  always @* begin
    for (int i=0; i<6; i++) begin
      o_slice[i] = slice_out[i];
      if (!tready_mask[i])
        o_slice[i].ena = '0;
    end

    for (int i=0; i<6; i++) begin
      // synthesis translate_off
      o_preamble[i] = sop_out[i*2]? slice_out[i].dat[0][55:0] : slice_out[i].dat[1][55:0];
      // synthesis translate_on
    end

    // synthesis translate_off
    if (p0_200 | p0_400) begin
      case (sop_out[3:0])
        4'b0001: o_preamble[0] = slice_out[0].dat[0][55:0];
        4'b0010: o_preamble[0] = slice_out[0].dat[1][55:0];
        4'b0100: o_preamble[0] = slice_out[1].dat[0][55:0];
        4'b1000: o_preamble[0] = slice_out[1].dat[1][55:0];
      endcase
    end

    if (p2_200 | p0_400) begin
      case (sop_out[7:4])
        4'b0001: o_preamble[2] = slice_out[2].dat[0][55:0];
        4'b0010: o_preamble[2] = slice_out[2].dat[1][55:0];
        4'b0100: o_preamble[2] = slice_out[3].dat[0][55:0];
        4'b1000: o_preamble[2] = slice_out[3].dat[1][55:0];
      endcase
    end

    if (p4_200) begin
      case (sop_out[11:8])
        4'b0001: o_preamble[4] = slice_out[4].dat[0][55:0];
        4'b0010: o_preamble[4] = slice_out[4].dat[1][55:0];
        4'b0100: o_preamble[4] = slice_out[5].dat[0][55:0];
        4'b1000: o_preamble[4] = slice_out[5].dat[1][55:0];
      endcase
    end
    // synthesis translate_on
  end

  always_ff @(posedge clk) begin
    fin[0] <= din_0[0];
    fin[1] <= p0_200_or_400? din_0[1] : din_1;
    fin[2] <= p0_400? din_0[2] : din_2[0];
    fin[3] <= p0_400? din_0[3] : p2_200? din_2[1] : din_3;
    fin[4] <= din_4[0];
    fin[5] <= p4_200? din_4[1] : din_5;
  end

  assign skip_response_n_reg_0 = ~i_skip_response & i_pkt.id == '0;

  always_ff @(posedge clk) begin
    wr_ena_pre <= 6'd0;
    skip_response_n_reg_1 <= skip_response_n_reg_0;

    case (remainder[0])
      0: begin
        din_0[3:0] <= slice_in[3:0];
        if (new_dat[0]) begin
          if (p0_400) begin
            remainder[0] <= 2;
            slice_reg_0[1:0] <= slice_in[5:4];
            wr_ena_pre[3:0] <= '1;
          end
          else if (p0_200) begin
            remainder[0] <= 4;
            slice_reg_0[3:0] <= slice_in[5:2];
            wr_ena_pre[1:0] <= '1;
          end
          else begin
            remainder[0] <= 5;
            slice_reg_0[4:0] <= slice_in[5:1];
            wr_ena_pre[0] <= 1'b1;
          end
        end
      end
      2: begin
        if (p0_400) begin
          if (new_dat[0]) begin
            wr_ena_pre[3:0] <= '1;
            remainder[0] <= 4;
            slice_reg_0[3:0] <= slice_in[5:2];
            din_0[3:0] <= {slice_in[1:0], slice_reg_0[1:0]};
          end
          else if ((slice_reg_0[1].eop[1] | !slice_reg_0[1].ena[1]) & (REGISTER_INPUT? skip_response_n_reg_1 : skip_response_n_reg_0)) begin
            wr_ena_pre[3:0] <= '1;
            remainder[0] <= 0;
            din_0[1:0] <= slice_reg_0[1:0];
            {din_0[2].ena, din_0[2].sop, din_0[2].eop} <= '0;
            {din_0[3].ena, din_0[3].sop, din_0[3].eop} <= '0;
          end
        end
        else if(p0_200) begin
          wr_ena_pre[1:0] <= '1;
          remainder[0] <= 0;
          din_0[1:0] <= slice_reg_0[1:0];
        end
        else begin
          wr_ena_pre[0] <= 1'b1;
          remainder[0] <= 1;
          slice_reg_0[0] <= slice_reg_0[1];
          din_0[0] <= slice_reg_0[0];
        end
      end
      4: begin
        if (p0_400) begin
          wr_ena_pre[3:0] <= '1;
          din_0[3:0] <= slice_reg_0[3:0];
          remainder[0] <= new_dat[0]? 6 : '0;
          slice_reg_0[5:0] <= slice_in[5:0];
        end
        else if(p0_200) begin
          wr_ena_pre[1:0] <= '1;
          din_0[1:0] <= slice_reg_0[1:0];
          remainder[0] <= 2;
          slice_reg_0[1:0] <= slice_reg_0[3:2];
        end
        else begin
          wr_ena_pre[0] <= 1'b1;
          remainder[0] <= 3;
          slice_reg_0[2:0] <= slice_reg_0[3:1];
          din_0[0] <= slice_reg_0[0];
        end
      end
      6 : begin
        wr_ena_pre[3:0] <= '1;
        din_0[3:0] <= slice_reg_0[3:0];
        remainder[0] <= 2;
        slice_reg_0[1:0] <= slice_reg_0[5:4];
      end
      default: begin
        wr_ena_pre[0] <= 1'b1;
        din_0[0] <= slice_reg_0[0];
        remainder[0] <= remainder[0] - 1'b1;
        if (remainder[0] == 3) slice_reg_0[1:0] <= slice_reg_0[2:1];
        else slice_reg_0[3:0] <= slice_reg_0[4:1];
      end
    endcase

    remainder[1] <= new_dat[1]? remainder[1] + 5 : (|remainder[1])? remainder[1] - 1'b1 : '0;
    din_1 <= (|remainder[1])? slice_reg[1][0] : slice_in[0];
    slice_reg[1][4:0] <= new_dat[1]? slice_in[5:1] : {slice_reg[1][4], slice_reg[1][4:1]};
    if (|remainder[1] | new_dat[1]) wr_ena_pre[1] <= 1'b1;

    case (remainder[2])
      0: begin
        din_2[1:0] <= slice_in[1:0];
        if (new_dat[2]) wr_ena_pre[2] <= 1'b1;
        if (new_dat[2] & p2_200) wr_ena_pre[3] <= 1'b1;
        slice_reg[2][4:0] <= p2_200? {slice_reg[2][4], slice_in[5:2]} : slice_in[5:1];
        if (new_dat[2]) remainder[2] <= p2_200? 4 : 5;
      end
      default: begin
        wr_ena_pre[2] <= 1'b1;
        wr_ena_pre[3] <= p2_200;
        din_2[1:0] <= slice_reg[2][1:0];
        remainder[2] <= remainder[2] - (p2_200? 2 : 1);
        slice_reg[2][4:0] <= p2_200? {slice_reg[2][4:3], slice_reg[2][4:2]} :  {slice_reg[2][4], slice_reg[2][4:1]};
      end
    endcase

    remainder[3] <= new_dat[3]? remainder[3] + 5 : (|remainder[3])? remainder[3] - 1'b1 : '0;
    din_3 <= (|remainder[3])? slice_reg[3][0] : slice_in[0];
    slice_reg[3][4:0] <= new_dat[3]? slice_in[5:1] : {slice_reg[3][4], slice_reg[3][4:1]};
    if (|remainder[3] | new_dat[3]) wr_ena_pre[3] <= 1'b1;

    case (remainder[4])
      0: begin
        din_4[1:0] <= slice_in[1:0];
        if (new_dat[4]) wr_ena_pre[4] <= 1'b1;
        if (new_dat[4] & p4_200) wr_ena_pre[5] <= 1'b1;
        slice_reg[4][4:0] <= p4_200? {slice_reg[4][4], slice_in[5:2]} : slice_in[5:1];
        if (new_dat[4]) remainder[4] <= p4_200? 4 : 5;
      end
      default: begin
        wr_ena_pre[4] <= 1'b1;
        wr_ena_pre[5] <= p4_200;
        din_4[1:0] <= slice_reg[4][1:0];
        remainder[4] <= remainder[4] - (p4_200? 2 : 1);
        slice_reg[4][4:0] <= p4_200? {slice_reg[4][4:3], slice_reg[4][4:2]} :  {slice_reg[4][4], slice_reg[4][4:1]};;
      end
    endcase

    remainder[5] <= new_dat[5]? remainder[5] + 5 : (|remainder[5])? remainder[5] - 1'b1 : '0;
    din_5 <= (|remainder[5])? slice_reg[5][0] : slice_in[0];
    slice_reg[5][4:0] <= new_dat[5]? slice_in[5:1] :  {slice_reg[5][4], slice_reg[5][4:1]};
    if (|remainder[5] | new_dat[5]) wr_ena_pre[5] <= 1'b1;

    wr_ena <= wr_ena_pre;

   rst_mask[0] <= rst[0];
   rst_mask[1] <= p0_200_or_400? rst[0] : rst[1];
   rst_mask[2] <= p0_400? rst[0] : rst[2];
   rst_mask[3] <= p0_400? rst[0] : p2_200? rst[2] : rst[3];
   rst_mask[4] <= rst[4];
   rst_mask[5] <= p4_200? rst[4] : rst[5];

    for (int i=0; i<6; i++) begin
      if (rst_mask[i]) remainder[i] <= '0;
    end
  end

  wire    [5:0] fifo_empty, ae;
  slice_t [5:0] fout_slice;
  wire    [5:0] fout_vld;
  reg     [5:0] rd_deep_fifo_ena;

  always @* begin
    for (int i=0; i<6; i++) begin
      fout_slice[i] = fout_slice_flat[i];
      slice_out[i]  = slice_out_flat[i];
    end
  end

  wire    [5:0] shallow_tready, shallow_ae;

  always_ff @(posedge clk) begin
    for (int i=0; i<6; i++) begin
      if (fifo_empty[i]) dat_enough[i] <= 1'b0;
      else if (!ae[i]) dat_enough[i] <= 1'b1;
    end
    rd_deep_fifo_ena <= dat_enough & shallow_ae;
  end

  localparam int HDR_OFF_IDLE = 48;

  reg     [5:0][5:0]          hdr_offset;
  reg     [5:0][1:0][1:0]     hdr_code;
  slice_t [5:0]               fin_d;
  reg     [5:0]               wr_ena_d;
  slice_t [5:0]               fin_hdr;
  reg     [5:0]               wr_ena_hdr;
  logic   [5:0][1:0][1:0]     hdr_code_nxt;
  logic   [5:0][5:0]          hdr_offset_nxt;
  slice_t [5:0]               fin_hdr_nxt;

  function automatic [1:0] hdr_code_of(input logic [5:0] offset);
    case (offset)
      6'd0:    hdr_code_of = 2'd0;
      6'd16:   hdr_code_of = 2'd1;
      6'd32:   hdr_code_of = 2'd2;
      default: hdr_code_of = HDR_NO_SEG;
    endcase
  endfunction

  function automatic [5:0] hdr_offset_step(input logic [5:0] offset);
    hdr_offset_step = (offset >= 6'(HDR_OFF_IDLE - HDR_SEG_B)) ? 6'(HDR_OFF_IDLE)
                                                              : offset + 6'(HDR_SEG_B);
  endfunction

  always @* begin
    for (int z=0; z<6; z++) begin
      logic [5:0] start_seg_0;
      logic [5:0] start_seg_1;
      start_seg_0 = (fin[z].sop[0] & fin[z].ena[0]) ? 6'd0 : hdr_offset[z];
      start_seg_1 = (fin[z].sop[1] & fin[z].ena[1]) ? 6'd0 : hdr_offset_step(start_seg_0);
      hdr_code_nxt[z][0] = i_hdr_ena ? hdr_code_of(start_seg_0) : HDR_NO_SEG;
      hdr_code_nxt[z][1] = i_hdr_ena ? hdr_code_of(start_seg_1) : HDR_NO_SEG;
      hdr_offset_nxt[z]  = hdr_offset_step(start_seg_1);
    end
  end

  always_ff @(posedge clk) begin
    fin_d    <= fin;
    wr_ena_d <= wr_ena;
    hdr_code <= hdr_code_nxt;
    for (int z=0; z<6; z++) begin
      if (rst_mask[z]) hdr_offset[z] <= 6'(HDR_OFF_IDLE);
      else if (wr_ena[z]) hdr_offset[z] <= hdr_offset_nxt[z];
    end
  end

  always @* begin
    fin_hdr_nxt = fin_d;
    for (int z=0; z<6; z++) begin
      for (int s=0; s<2; s++) begin
        for (int b=0; b<HDR_SEG_B; b++) begin
          case (hdr_code[z][s])
            2'd0: fin_hdr_nxt[z].dat[s][b*8 +: 8] = i_hdr_bytes[(b) * 8 +: 8];
            2'd1: fin_hdr_nxt[z].dat[s][b*8 +: 8] = i_hdr_bytes[(HDR_SEG_B + b) * 8 +: 8];
            2'd2: if (2 * HDR_SEG_B + b < HDR_B)
                    fin_hdr_nxt[z].dat[s][b*8 +: 8] = i_hdr_bytes[(2 * HDR_SEG_B + b) * 8 +: 8];
            default: ;
          endcase
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    fin_hdr    <= fin_hdr_nxt;
    wr_ena_hdr <= wr_ena_d;
  end

  genvar z;
  generate
    for (z=0; z<6; z++) begin : GEN_FIFO
      dcmac_seg_fifo_sync #(
       .DW                (SLICE_W),
       .DEPTH             (256),
       .PROG_EMPTY_THRESH (18),
       .PROG_FULL_THRESH  (128),
       .MEM_STYLE         ("block")
      )
      deep_fifo_inst (
         .clk        (clk),
         .rst        (rst_mask[z]),
         .wr_en      (wr_ena_hdr[z]),
         .din        (fin_hdr[z]),
         .rd_en      (rd_deep_fifo_ena[z]),
         .data_valid (fout_vld[z]),
         .dout       (fout_slice_flat[z]),
         .empty      (fifo_empty[z]),
         .full       (),
         .overflow   (o_overflow[z]),
         .prog_empty (ae[z]),
         .prog_full  (o_af[z]),
         .underflow  (o_underflow[z])
      );

      dcmac_seg_fifo_axis #(
       .DW                (SLICE_W),
       .DEPTH             (16),
       .PROG_EMPTY_THRESH (8),
       .MEM_STYLE         ("distributed")
      )
      shallow_fifo_inst  (
        .clk           (clk),
        .rstn          (~rst_mask[z]),
        .s_axis_tdata  (fout_slice[z]),
        .s_axis_tvalid (fout_vld[z]),
        .s_axis_tready (shallow_tready[z]),
        .m_axis_tdata  (slice_out_flat[z]),
        .m_axis_tvalid (o_vld[z]),
        .m_axis_tready (tready_mask[z]),
        .prog_empty    (shallow_ae[z])
      );
    end
  endgenerate

endmodule

module dcmac_seg_pktgen_core   (
  clk,
  rst,
  i_pkt_ena,
  i_min_len,
  i_max_len,
  i_clear_counters,
  i_req_id,
  i_req_id_vld,
  i_skip_id,
  i_skip,
  i_af,
  o_skip_response,
  o_pkt,
  o_pkt_vld,
  o_byte_cnt,
  o_pkt_cnt
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

  typedef struct packed {
    logic [ID_W-1:0]     id;
    logic [11:0]         ena;
    logic [11:0][15:0]   pkt_len;
    logic [11:0]         sop;
    logic [11:0]         eop;
    logic [11:0]         err;
    logic [11:0][3:0]    mty;
    logic [2:0][3:0]     pkt_mty_idx;
    logic [2:0][5:0]     mty_sum;
  } lbus_pkt_ctrl_t;

  input   clk;
  input   rst;
  input   [NUM_ID:0] i_pkt_ena;
  input   [15:0] i_min_len;
  input   [15:0] i_max_len;
  input   [ID_W-1:0] i_req_id;
  input   i_req_id_vld;
  input   [ID_W-1:0] i_skip_id;
  input   i_skip;
  input   [NUM_ID-1:0] i_af;
  input   [NUM_ID-1:0] i_clear_counters;
  output  o_skip_response;
  output  lbus_pkt_t o_pkt;
  output  o_pkt_vld;
  output  logic [NUM_ID-1:0][63:0]  o_byte_cnt;
  output  logic [NUM_ID-1:0][63:0]  o_pkt_cnt;

  wire  is_backpressure_0;
  reg   [13:1] is_backpressure;
  wire  req_id_vld_0;
  reg   [13:1] req_id_vld;
  wire  [7:0] ctrl_gen_o_size_4;
  reg   [7:0] ctrl_gen_o_size_5;
  lbus_pkt_ctrl_t ctrl_gen_o_ctrl_4;
  lbus_pkt_ctrl_t [12:5] ctrl_gen_o_ctrl;
  wire  dat_req_6;
  reg   dat_req_7;
  wire  [7:0] buf_size_6;
  reg   [7:0] buf_size_7;
  wire  [7:0] buf_idx_6;
  reg   [7:0] buf_idx_7;
  wire  [7:7][1536-1:0] payload;
  wire  [11:11][1536-1:0] dat_pack;
  lbus_pkt_t [13:13] pkt_out;
  reg [40-1:0] skip_hold;

  assign is_backpressure_0 = skip_hold[i_req_id];
  assign o_skip_response = is_backpressure[13];
  assign o_pkt_vld = req_id_vld[13];

  assign req_id_vld_0 = i_req_id_vld;

  always_ff @(posedge clk) begin
    ctrl_gen_o_size_5 <= ctrl_gen_o_size_4;
    ctrl_gen_o_ctrl[12:6] <= ctrl_gen_o_ctrl[11:5];
    ctrl_gen_o_ctrl[5] <= ctrl_gen_o_ctrl_4;
    ctrl_gen_o_ctrl[5].sop <= ctrl_gen_o_ctrl_4.sop & ctrl_gen_o_ctrl_4.ena;
    ctrl_gen_o_ctrl[5].eop <= ctrl_gen_o_ctrl_4.eop & ctrl_gen_o_ctrl_4.ena;

    buf_size_7 <= buf_size_6;
    buf_idx_7 <= buf_idx_6;
    dat_req_7 <= dat_req_6;

    is_backpressure[13:2] <= is_backpressure[12:1];
    is_backpressure[1] <= is_backpressure_0;

    req_id_vld[13:1] <= {req_id_vld[12:1], i_req_id_vld};

    if (i_req_id_vld) skip_hold[i_req_id] <= 1'b0;
    if (i_skip) begin
      skip_hold[i_skip_id] <= 1'b1;
      // synthesis translate_off
      if (skip_hold[i_skip_id]) begin
        $error("the packet generator does not allow two accumulated skip requests");
        $stop;
      end
      // synthesis translate_on
    end

    for (int i=0; i<6; i++) begin
      if(i_af[i]) skip_hold[i] <= 1'b1;
    end

    if (rst) skip_hold <= '0;
  end

  dcmac_seg_pktgen_ctrl u_ctrl_gen (
    .clk          (clk),
    .rst          (rst),
    .i_pkt_ena    (i_pkt_ena),
    .i_min_len    (i_min_len),
    .i_max_len    (i_max_len),
    .i_req_id     (i_req_id),
    .i_req_id_vld (req_id_vld_0 & !is_backpressure_0),
    .o_size       (ctrl_gen_o_size_4),
    .o_pkt_ctrl   (ctrl_gen_o_ctrl_4)
  );

  dcmac_seg_pktgen_bufctx u_buffer_ctx (
    .clk           (clk),
    .rst           (rst),
    .i_id_valid_p1 (req_id_vld[5]),
    .i_id          (ctrl_gen_o_ctrl_4.id),
    .i_size        (ctrl_gen_o_size_4),
    .o_id          (),
    .o_buf_size    (buf_size_6),
    .o_buf_idx     (buf_idx_6),
    .o_dat_req     (dat_req_6)
  );

  dcmac_seg_pktgen_merge  u_dat_merge (
    .clk          (clk),
    .rst          (rst),
    .i_id_m1      (ctrl_gen_o_ctrl[6].id),
    .i_buf_size   (buf_size_7),
    .i_buf_idx    (buf_idx_7),
    .i_dat_ena    (dat_req_7),
    .i_dat        (payload[7]),
    .o_id         (),
    .o_dat        (dat_pack[11])
  );

  dcmac_seg_pktgen_payload u_payload_gen (
    .clk         (clk),
    .rst         (rst),
    .i_id_m1     (ctrl_gen_o_ctrl[5].id),
    .i_req_en    (dat_req_6),
    .i_req_num   (8'd192),
    .i_seed      (),
    .o_dat       (payload[7])
  );

  dcmac_seg_pktgen_shift #(
    .REGISTER_INPUT (0)
  ) u_mty_shift (
    .clk         (clk),
    .i_pkt_ctrl  (ctrl_gen_o_ctrl[10]),
    .i_dat       (dat_pack[11]),
    .o_pkt       (pkt_out[13])
  );

  assign o_pkt = pkt_out[13];

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
    .i_id_m1             (ctrl_gen_o_ctrl_4.id),
    .i_sop               (ctrl_gen_o_ctrl[5].sop),
    .i_eop               (ctrl_gen_o_ctrl[5].eop),
    .i_size              (ctrl_gen_o_size_5),
    .o_carry_id_m1       (carry_id_m1),
    .o_byte_cnt_carry    (byte_cnt_carry),
    .o_pkt_cnt_carry     (pkt_cnt_carry),
    .o_byte_cnt          (byte_cnt_lower),
    .o_pkt_cnt           (pkt_cnt_lower)
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

  // synthesis translate_off
  wire [11:0][15:0][7:0] byte_out;
  int j_max;
  reg [7:0] byte_nxt;
  reg [NUM_ID-1:0][7:0] byte_ctx;
  reg [11:0] byte_err;
  bit [NUM_ID-1:0] found_err;

  assign byte_out = o_pkt.dat;

  always_ff @(negedge clk) begin
    byte_nxt = byte_ctx[o_pkt.id];
    byte_err <= '0;

    if (rst) begin
      found_err = '0;
      byte_ctx <= '0;
      byte_nxt = '0;
    end

    for (int i=0; i<12; i++) begin
      if (o_pkt.ena[i]) begin
        j_max = o_pkt.eop[i]? 16 - o_pkt.mty[i] : 16;
        for (int j=0; j<j_max; j++) begin
          if(byte_nxt !== byte_out[i][j]) begin
            byte_err[i] <= found_err[o_pkt.id];
            if(found_err[o_pkt.id]) begin
              $error ("ID %2d, segment %2d, byte %2d, expect %2x, received %2x", o_pkt.id, i, j, byte_nxt, byte_out[i][j]);
              $stop;
            end
            found_err[o_pkt.id] = 1'b1;
          end
          byte_nxt = byte_out[i][j] + 1'b1;
        end
      end
    end
    byte_ctx[o_pkt.id] <= byte_nxt;
  end
  // synthesis translate_on

endmodule
