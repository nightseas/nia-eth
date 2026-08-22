// ---------------------------------------------------------------------------
// File        :
// Description :
// Author      :
// Language    : SystemVerilog
//
//
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module dcmac_seg_ctx_mem (
  clk,
  rst,
  ts_rst,
  i_rd_id,
  i_ena,
  i_dat,
  i_rd_during_wr,
  o_dat,
  o_init
);

parameter NUM_ID       = 6;
parameter DW           = 1;
parameter INIT_VALUE   = 0;
parameter DISABLE_INIT = 0;
parameter ENABLE_RD_DURING_WR = 0;

localparam ID_W = (NUM_ID == 1) ? 1 : $clog2(NUM_ID);

input                    clk;
input                    rst;
input                    ts_rst;
input      [ID_W-1:0]    i_rd_id;
input                    i_ena;
input      [DW-1:0]      i_dat;
input                    i_rd_during_wr;
output reg [DW-1:0]      o_dat;
output                   o_init;

logic                    init_global;
reg   [1:1]              init_global_p;
wire                     init_ts_0;
reg                      init_ts_1;
wire  [DW-1:0]           mem_din;
reg   [ID_W-1:0]         wr_id;
logic                    rd_during_wr;
wire  [1:1]              wr_ena;
wire  [1:1]              init_wr;

(* ram_style = "distributed" *) reg [DW-1:0] mem [NUM_ID-1:0];

assign o_init = init_global;

always_ff @(posedge clk) begin
  init_ts_1 <= init_ts_0;
  init_global_p[1] <= init_global;

  if(wr_ena[1]) mem[wr_id] <= mem_din;

  o_dat <= rd_during_wr? mem_din : mem[i_rd_id];
end

logic ts_rst_tmp;

always @* begin
  ts_rst_tmp = ts_rst;
end

assign init_ts_0 = init_global? 1'b1: ts_rst_tmp? 1'b1 : 1'b0;
assign init_wr[1] = init_ts_1;

generate

  if (DISABLE_INIT) begin : GEN_DISABLE_GLOBAL_INIT
    assign init_global = 1'b0;

    always_ff @(posedge clk) begin
      wr_id <= i_rd_id;
    end
  end
  else begin : GEN_USE_INT_INIT
    reg [ID_W-1:0] init_id;

    always_ff @( posedge clk or posedge rst )
    begin
      if ( rst == 1'b1 ) begin
        init_global <= 1'b1;
        init_id <= '0;
        wr_id <= '0;
      end
      else begin
        if (init_global) begin
          init_global <= init_id < NUM_ID - 1;
          init_id <= init_id + 1'b1;
        end
        wr_id <= init_global? (wr_id < NUM_ID - 1)? wr_id + 1'b1 : '0 : i_rd_id;
      end
    end
  end

  if (ENABLE_RD_DURING_WR) begin
    assign rd_during_wr = i_rd_during_wr;
  end
  else begin
    if (DISABLE_INIT) begin
      assign rd_during_wr = i_rd_id == wr_id & i_ena;
    end
    else begin
      assign rd_during_wr = (init_global_p[1] | i_rd_id == wr_id & (i_ena | init_wr[1]));
    end
  end

  if (DISABLE_INIT)  begin : GEN_DISABLE_INIT
    assign mem_din = i_dat;
    assign wr_ena[1] = i_ena;
  end
  else begin : GEN_ENABLE_INIT
    assign mem_din = init_wr[1]? INIT_VALUE : i_dat;
    assign wr_ena[1] = i_ena | init_wr[1];
  end

endgenerate

endmodule

module dcmac_seg_cnt (
  clk,
  rst,
  i_clear_counters,
  i_id_m1,
  i_sop,
  i_eop,
  i_size,
  o_byte_cnt,
  o_pkt_cnt,
  o_carry_id_m1,
  o_byte_cnt_carry,
  o_pkt_cnt_carry
);

  parameter REGISTER_INPUT = 1;
parameter NUM_ID = 6;
localparam ID_W = (NUM_ID == 1) ? 1 : $clog2(NUM_ID);

  input   clk;
  input   rst;
  input   [NUM_ID-1:0] i_clear_counters;
  input   [ID_W-1:0] i_id_m1;
  input   [11:0] i_sop;
  input   [11:0] i_eop;
  input   [7:0] i_size;
  output  reg [NUM_ID-1:0][31:0] o_byte_cnt;
  output  reg [NUM_ID-1:0][31:0] o_pkt_cnt;
  output  reg [ID_W-1:0] o_carry_id_m1;
  output  reg o_byte_cnt_carry;
  output  reg o_pkt_cnt_carry;

  wire init;
  logic [7:0] size;
  reg [2:0] rd_during_wr;
  reg [1:0][NUM_ID-1:0] clear_rx_counters;
  reg [NUM_ID-1:0] clear_rx_pulse;
  reg [2:0] clear_rx_pulse_o;
  reg [3:0][ID_W-1:0] id;
  reg [1:0] num_pkt;
  logic [7:0] pkt_cnt_l_i, pkt_cnt_l_o, byte_cnt_l_i, byte_cnt_l_o;
  logic [8:0] pkt_cnt_nxt_0, byte_cnt_nxt_0;
  logic [12:0] pkt_cnt_nxt_1, byte_cnt_nxt_1;
  logic [12:0] pkt_cnt_nxt_2, byte_cnt_nxt_2;
  reg   [1:0] pkt_cnt_carry, byte_cnt_carry;
  logic [11:0] pkt_cnt_h0_i, pkt_cnt_h0_o, byte_cnt_h0_i, byte_cnt_h0_o;
  logic [11:0] pkt_cnt_h1_i, pkt_cnt_h1_o, byte_cnt_h1_i, byte_cnt_h1_o;

  always @* begin
    pkt_cnt_nxt_0 = clear_rx_pulse_o[0]? num_pkt: num_pkt + pkt_cnt_l_o;
    byte_cnt_nxt_0 = clear_rx_pulse_o[0]? size : size + byte_cnt_l_o;

    pkt_cnt_l_i = pkt_cnt_nxt_0[7:0];
    byte_cnt_l_i = byte_cnt_nxt_0[7:0];

    pkt_cnt_nxt_1 = clear_rx_pulse_o[1]? pkt_cnt_carry[0] : pkt_cnt_carry[0] + pkt_cnt_h0_o;
    byte_cnt_nxt_1 = clear_rx_pulse_o[1]? byte_cnt_carry[0] : byte_cnt_carry[0] + byte_cnt_h0_o;

    pkt_cnt_h0_i = pkt_cnt_nxt_1[11:0];
    byte_cnt_h0_i = byte_cnt_nxt_1[11:0];

    pkt_cnt_nxt_2 = clear_rx_pulse_o[2]? pkt_cnt_carry[1] : pkt_cnt_carry[1] + pkt_cnt_h1_o;
    byte_cnt_nxt_2 = clear_rx_pulse_o[2]? byte_cnt_carry[1] : byte_cnt_carry[1] + byte_cnt_h1_o;

    pkt_cnt_h1_i = pkt_cnt_nxt_2[11:0];
    byte_cnt_h1_i = byte_cnt_nxt_2[11:0];
  end

  always_ff @(posedge clk) begin
    id <= {id, i_id_m1};
    size <= i_size;
    rd_during_wr[0] <= id[0] == i_id_m1 | init;
    rd_during_wr[1] <= rd_during_wr[0] | init;
    rd_during_wr[2] <= rd_during_wr[1] | init;

    num_pkt <= (|i_eop[3:0])
             + (|i_eop[7:4])
             + (|i_eop[11:8])
             ;

    clear_rx_counters <= {clear_rx_counters[0], i_clear_counters};
    clear_rx_pulse_o[0] <= clear_rx_pulse[id[0]];
    clear_rx_pulse_o[2:1] <= clear_rx_pulse_o[1:0];

    pkt_cnt_carry[0] <= pkt_cnt_nxt_0[8];
    byte_cnt_carry[0] <= byte_cnt_nxt_0[8];

    pkt_cnt_carry[1] <= pkt_cnt_nxt_1[12];
    byte_cnt_carry[1] <= byte_cnt_nxt_1[12];

    o_pkt_cnt_carry <= pkt_cnt_nxt_2[12];
    o_byte_cnt_carry <= byte_cnt_nxt_2[12];
    o_carry_id_m1 <= id[2];

    clear_rx_pulse[id[0]] <= 1'b0;
    for (int i=0; i< NUM_ID; i++) begin
      if (clear_rx_counters[0][i] & ~clear_rx_counters[1][i]) begin
        clear_rx_pulse[i] <= 1'b1;
      end

      if (clear_rx_pulse_o[0]) begin
        o_pkt_cnt[id[1]][7:0] <= pkt_cnt_l_o;
        o_byte_cnt[id[1]][7:0] <= byte_cnt_l_o;
      end

      if (clear_rx_pulse_o[1]) begin
        o_pkt_cnt[id[2]][8+:12] <= pkt_cnt_h0_o;
        o_byte_cnt[id[2]][8+:12] <= byte_cnt_h0_o;
      end

      if (clear_rx_pulse_o[2]) begin
        o_pkt_cnt[id[3]][20+:12] <= pkt_cnt_h1_o;
        o_byte_cnt[id[3]][20+:12] <= byte_cnt_h1_o;
      end
    end

    if (rst) begin
      clear_rx_counters <= '0;
      o_pkt_cnt <= '0;
      o_byte_cnt <= '0;
    end
  end

  dcmac_seg_ctx_mem  #(
    .DW (8 * 2),
    .ENABLE_RD_DURING_WR (1),
    .INIT_VALUE (0)
  ) u_cnt_l_ctx (
    .clk             (clk),
    .rst             (rst),
    .ts_rst          (1'b0),
    .i_rd_id         (id[0]),
    .i_ena           (1'b1),
    .i_rd_during_wr  (rd_during_wr[0]),
    .i_dat           ({pkt_cnt_l_i, byte_cnt_l_i}),
    .o_dat           ({pkt_cnt_l_o, byte_cnt_l_o}),
    .o_init          (init)
  );

  dcmac_seg_ctx_mem  #(
    .DW (12 * 2),
    .ENABLE_RD_DURING_WR (1),
    .INIT_VALUE (0)
  ) u_cnt_h0_ctx (
    .clk             (clk),
    .rst             (rst),
    .ts_rst          (1'b0),
    .i_rd_id         (id[1]),
    .i_ena           (1'b1),
    .i_rd_during_wr  (rd_during_wr[1]),
    .i_dat           ({pkt_cnt_h0_i, byte_cnt_h0_i}),
    .o_dat           ({pkt_cnt_h0_o, byte_cnt_h0_o}),
    .o_init          ()
  );

  dcmac_seg_ctx_mem  #(
    .DW (12 * 2),
    .ENABLE_RD_DURING_WR (1),
    .INIT_VALUE (0)
  ) u_cnt_h1_ctx (
    .clk             (clk),
    .rst             (rst),
    .ts_rst          (1'b0),
    .i_rd_id         (id[2]),
    .i_ena           (1'b1),
    .i_rd_during_wr  (rd_during_wr[2]),
    .i_dat           ({pkt_cnt_h1_i, byte_cnt_h1_i}),
    .o_dat           ({pkt_cnt_h1_o, byte_cnt_h1_o}),
    .o_init          ()
  );

endmodule
