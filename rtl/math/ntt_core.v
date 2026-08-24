`timescale 1ns/1ps

/*
 * Copyright (C) 2026
 * Author: Abhinav S <abhinavsasivala02@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
 */

`include "mldsa_params.vh"

module ntt_core (
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      start,
    input  wire                      intt_mode,
    output reg                       busy,
    output reg                       done,

        input  wire                      ext_we,
    input  wire [7:0]                ext_addr,
    input  wire [`MLDSA_QBITS-1:0]  ext_din,
    output wire [`MLDSA_QBITS-1:0]  ext_dout
);

                localparam [3:0] S_IDLE     = 4'd0;
    localparam [3:0] S_INIT     = 4'd1;
    localparam [3:0] S_BLK_INIT = 4'd2;
    localparam [3:0] S_READ     = 4'd3;
    localparam [3:0] S_WAIT     = 4'd4;
    localparam [3:0] S_BF0      = 4'd5;
    localparam [3:0] S_BF1      = 4'd6;
    localparam [3:0] S_BF2      = 4'd7;
    localparam [3:0] S_BF3      = 4'd8;
    localparam [3:0] S_WRITE    = 4'd9;
    localparam [3:0] S_SCALE    = 4'd10;
    localparam [3:0] S_SCALE_W  = 4'd11;
    localparam [3:0] S_DONE     = 4'd12;
    localparam [3:0] S_ZETA_WAIT = 4'd13;
    reg [3:0] state;

                reg [2:0] stage;
    reg [7:0] blk_start;
    reg [7:0] len;
    reg [6:0] j_cnt;
    reg [7:0] k_idx;

    // DEBUG: NTT periodic state probe (fires every 131072 busy cycles)
                    reg                       bf_vld_in;
    wire                      bf_vld_out;
    reg  [`MLDSA_QBITS-1:0]  bf_a_in, bf_b_in, bf_zeta;
    wire [`MLDSA_QBITS-1:0]  bf_a_out, bf_b_out;

        reg [7:0] wa_dly_0, wa_dly_1, wa_dly_2, wa_dly_3, wa_dly_4;
    reg [7:0] wb_dly_0, wb_dly_1, wb_dly_2, wb_dly_3, wb_dly_4;

                reg                       fsm_wea, fsm_web;
    reg  [7:0]                fsm_addra, fsm_addrb;
    reg  [`MLDSA_QBITS-1:0]  fsm_dina, fsm_dinb;

    wire                      sram_wea, sram_web;
    wire [7:0]                sram_addra, sram_addrb;
    wire [`MLDSA_QBITS-1:0]  sram_dina, sram_dinb;
    wire [`MLDSA_QBITS-1:0]  sram_douta, sram_doutb;

        assign sram_wea   = busy ? fsm_wea   : ext_we;
    assign sram_addra = busy ? fsm_addra : ext_addr;
    assign sram_dina  = busy ? fsm_dina  : ext_din;
    assign sram_web   = busy ? fsm_web   : 1'b0;
    assign sram_addrb = busy ? fsm_addrb : 8'd0;
    assign sram_dinb  = busy ? fsm_dinb  : {`MLDSA_QBITS{1'b0}};
    assign ext_dout   = busy ? {`MLDSA_QBITS{1'b0}} : sram_douta;

                poly_ram_tdp #(.DEPTH(256), .WIDTH(`MLDSA_QBITS)) u_ram (
        .clk   (clk),
        .wea   (sram_wea),   .addra (sram_addra), .dina (sram_dina),  .douta (sram_douta),
        .web   (sram_web),   .addrb (sram_addrb), .dinb (sram_dinb),  .doutb (sram_doutb)
    );

                butterfly_unit u_bf (
        .clk       (clk),
        .rst_n     (rst_n),
        .vld_in    (bf_vld_in),
        .intt_mode (intt_mode),
        .a         (bf_a_in),
        .b         (bf_b_in),
        .zeta_mont (bf_zeta),
        .a_out     (bf_a_out),
        .b_out     (bf_b_out),
        .vld_out   (bf_vld_out)
    );

                wire [22:0] rom_data;
    zeta_rom u_zeta_rom (
        .clk  (clk),
        .addr (k_idx),
        .data (rom_data)
    );

                reg  [8:0]                sc_idx;
    reg                       sc_vld_in;
    wire                      sc_vld_out;
    wire [`MLDSA_QBITS-1:0]  sc_result;
    reg  [`MLDSA_QBITS-1:0]  sc_coeff;
            reg  [8:0]                sc_d1, sc_d2, sc_d3, sc_d4, sc_d5, sc_d6, sc_d7;

    montgomery_mult u_sc_mont (
        .clk     (clk),
        .rst_n   (rst_n),
        .vld_in  (sc_vld_in),
        .a       (`MLDSA_NINV_MONT),
        .b       (sc_coeff),
        .result  (sc_result),
        .vld_out (sc_vld_out)
    );

                always @(posedge clk) begin
        wa_dly_0 <= fsm_addra;
        wa_dly_1 <= wa_dly_0;
        wa_dly_2 <= wa_dly_1;
        wa_dly_3 <= wa_dly_2;
        wa_dly_4 <= wa_dly_3;
        wb_dly_0 <= fsm_addrb;
        wb_dly_1 <= wb_dly_0;
        wb_dly_2 <= wb_dly_1;
        wb_dly_3 <= wb_dly_2;
        wb_dly_4 <= wb_dly_3;
    end

                wire [7:0] addr_j, addr_jlen;
    assign addr_j    = blk_start + {1'b0, j_cnt};
    assign addr_jlen = blk_start + {1'b0, j_cnt} + len;

                always @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            busy      <= 1'b0;
            done      <= 1'b0;
            stage     <= 3'd0;
            blk_start <= 8'd0;
            len       <= 7'd0;
            j_cnt     <= 7'd0;
            k_idx     <= 8'd0;
            bf_vld_in <= 1'b0;
            bf_a_in   <= {`MLDSA_QBITS{1'b0}};
            bf_b_in   <= {`MLDSA_QBITS{1'b0}};
            bf_zeta   <= {`MLDSA_QBITS{1'b0}};
            sc_vld_in <= 1'b0;
            sc_idx    <= 9'd0;
            sc_coeff  <= {`MLDSA_QBITS{1'b0}};
            sc_d1 <= 9'd0; sc_d2 <= 9'd0; sc_d3 <= 9'd0;
            sc_d4 <= 9'd0; sc_d5 <= 9'd0; sc_d6 <= 9'd0; sc_d7 <= 9'd0;
            fsm_wea   <= 1'b0;
            fsm_web   <= 1'b0;
            fsm_addra <= 8'd0;
            fsm_addrb <= 8'd0;
            fsm_dina  <= {`MLDSA_QBITS{1'b0}};
            fsm_dinb  <= {`MLDSA_QBITS{1'b0}};
        end else begin
            done      <= 1'b0;
            bf_vld_in <= 1'b0;
            sc_vld_in <= 1'b0;

            case (state)

                S_IDLE: begin
                    busy <= 1'b0;
                    fsm_wea <= 1'b0;
                    fsm_web <= 1'b0;
                    if (start) begin
                        busy  <= 1'b1;
                        state <= S_INIT;
                    end
                end

                S_INIT: begin
                    stage     <= 3'd0;
                    // Forward NTT walks the zeta table forward (zetas[1..255]);
                    // inverse NTT walks it backward (zetas[255..1], negated).
                    k_idx     <= intt_mode ? 8'd255 : 8'd1;
                    len       <= intt_mode ? 8'd1 : 8'd128;
                    blk_start <= 8'd0;
                    j_cnt     <= 7'd0;
                    state     <= S_ZETA_WAIT;                  end

                S_ZETA_WAIT: begin
                                        state <= S_BLK_INIT;
                end

                S_BLK_INIT: begin
                                        if (intt_mode)
                        bf_zeta <= `MLDSA_Q - rom_data;
                    else
                        bf_zeta <= rom_data;
                    j_cnt <= 7'd0;
                    state <= S_READ;
                end

                S_READ: begin
                    fsm_wea   <= 1'b0;
                    fsm_addra <= addr_j;
                    fsm_web   <= 1'b0;
                    fsm_addrb <= addr_jlen;
                    state     <= S_WAIT;
                end

                S_WAIT: begin
                                                                                state <= S_BF0;
                end

                S_BF0: begin
                    bf_a_in   <= sram_douta;
                    bf_b_in   <= sram_doutb;
                    bf_vld_in <= 1'b1;
                    state     <= S_BF1;
                end

                S_BF1: state <= S_BF2;
                S_BF2: state <= S_BF3;

                S_BF3: begin
                    if (bf_vld_out) begin
                        fsm_wea   <= 1'b1;
                        fsm_addra <= wa_dly_3;
                        fsm_dina  <= bf_a_out;
                        fsm_web   <= 1'b1;
                        fsm_addrb <= wb_dly_3;
                        fsm_dinb  <= bf_b_out;
                        state     <= S_WRITE;
                    end
                end

                S_WRITE: begin
                    fsm_wea <= 1'b0;
                    fsm_web <= 1'b0;

                    if (j_cnt < len - 7'd1) begin
                        j_cnt <= j_cnt + 7'd1;
                        state <= S_READ;
                    end else begin
                        k_idx     <= intt_mode ? k_idx - 8'd1 : k_idx + 8'd1;
                        blk_start <= blk_start + {len, 1'b0};

                        if ({1'b0, blk_start} + {len, 1'b0} < 9'd256) begin
                            j_cnt <= 7'd0;
                            state <= S_ZETA_WAIT;                          end else begin
                            if (stage == 3'd7) begin
                                if (intt_mode) begin
                                    sc_idx <= 8'd0;
                                    state  <= S_SCALE;
                                end else begin
                                    state <= S_DONE;
                                end
                            end else begin
                                stage     <= stage + 3'd1;
                                blk_start <= 8'd0;
                                if (intt_mode)
                                    len <= {len[6:0], 1'b0};                                  else
                                    len <= {1'b0, len[7:1]};                                  j_cnt <= 7'd0;
                                state <= S_ZETA_WAIT;                              end
                        end
                    end
                end

                S_SCALE: begin
                                                                                                                                                                                    fsm_wea   <= 1'b0;
                    fsm_web   <= 1'b0;
                    sc_d1 <= sc_idx;
                    sc_d2 <= sc_d1;
                    sc_d3 <= sc_d2;
                    sc_d4 <= sc_d3;
                    sc_d5 <= sc_d4;
                    sc_d6 <= sc_d5;
                    sc_d7 <= sc_d6;
                    if (sc_idx <= 9'd255)
                        fsm_addra <= sc_idx[7:0];
                    if (sc_idx >= 9'd2 && sc_idx <= 9'd257) begin
                        sc_coeff  <= sram_douta;
                        sc_vld_in <= 1'b1;
                    end
                    if (sc_vld_out) begin
                        fsm_web   <= 1'b1;
                        fsm_addrb <= sc_d7[7:0];
                        fsm_dinb  <= sc_result;
                    end
                    if (sc_idx == 9'd263) begin
                        sc_idx <= 9'd0;
                        state  <= S_DONE;
                    end else begin
                        sc_idx <= sc_idx + 9'd1;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    fsm_wea <= 1'b0;
                    fsm_web <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
