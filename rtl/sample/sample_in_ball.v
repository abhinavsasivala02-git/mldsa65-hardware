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

module sample_in_ball (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          start,
    output reg           done,
    output reg           busy,

    // Byte input from SHAKE-256 squeeze
    output reg           byte_req,
    input  wire [7:0]    byte_data,
    input  wire          byte_valid,

        output reg                       coeff_we,
    output reg  [7:0]                coeff_addr,
    output reg  [`MLDSA_QBITS-1:0]  coeff_data,
        output reg  [7:0]                coeff_rd_addr,
    input  wire [`MLDSA_QBITS-1:0]  coeff_rd_data
);

    localparam TAU = `MLDSA_TAU;
    localparam [2:0] S_IDLE     = 3'd0;
    localparam [2:0] S_INIT     = 3'd1;       localparam [2:0] S_SIGN_RD  = 3'd2;   // Read 8 sign bytes
    localparam [2:0] S_SAMPLE   = 3'd3;       localparam [2:0] S_WAIT_J   = 3'd4;       localparam [2:0] S_SWAP     = 3'd5;       localparam [2:0] S_DONE     = 3'd6;

    reg [2:0]  state;
    reg [7:0]  init_cnt;
    reg [7:0]  i;                 reg [63:0] signs;         // 64 sign bits from first 8 bytes
    reg [2:0]  sign_byte_cnt;
    reg [5:0]  sign_idx;          reg [7:0]  j_val;
    always @(posedge clk) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            done           <= 1'b0;
            busy           <= 1'b0;
            byte_req       <= 1'b0;
            coeff_we       <= 1'b0;
            coeff_addr     <= 8'd0;
            coeff_data     <= {`MLDSA_QBITS{1'b0}};
            coeff_rd_addr  <= 8'd0;
            init_cnt       <= 8'd0;
            i              <= 8'd0;
            signs          <= 64'd0;
            sign_byte_cnt  <= 3'd0;
            sign_idx       <= 6'd0;
        end else begin
            done     <= 1'b0;
            coeff_we <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy     <= 1'b1;
                        init_cnt <= 8'd0;
                        state    <= S_INIT;
                    end
                end

                                S_INIT: begin
                    coeff_we   <= 1'b1;
                    coeff_addr <= init_cnt;
                    coeff_data <= {`MLDSA_QBITS{1'b0}};
                    init_cnt   <= init_cnt + 8'd1;
                    if (init_cnt == 8'd255) begin
                        sign_byte_cnt <= 3'd0;
                        signs         <= 64'd0;
                        byte_req      <= 1'b1;
                        state         <= S_SIGN_RD;
                    end
                end

                // Read 8 sign bytes
                S_SIGN_RD: begin
                    if (byte_valid) begin
                        signs <= signs | ({56'd0, byte_data} << (sign_byte_cnt * 8));
                        sign_byte_cnt <= sign_byte_cnt + 3'd1;
                        if (sign_byte_cnt == 3'd7) begin
                            byte_req <= 1'b0;
                            i        <= 256 - TAU;
                            sign_idx <= 6'd0;
                            state    <= S_SAMPLE;
                        end else begin
                            byte_req <= 1'b1;
                        end
                    end
                end

                                S_SAMPLE: begin
                    byte_req <= 1'b1;
                    state    <= S_WAIT_J;
                end

                S_WAIT_J: begin
                    if (byte_valid) begin
                        byte_req <= 1'b0;
                                                if (byte_data <= i) begin
                            j_val         <= byte_data;
                            coeff_rd_addr <= byte_data;                              state         <= S_SWAP;
                        end else begin
                            byte_req <= 1'b1;                          end
                    end
                end

                S_SWAP: begin
                                        coeff_we   <= 1'b1;
                    coeff_addr <= i;
                    coeff_data <= coeff_rd_data;
                                                            i        <= i + 8'd1;
                    sign_idx <= sign_idx + 6'd1;

                    if (i == 8'd255) begin
                        state <= S_DONE;
                    end else begin
                        state <= S_SAMPLE;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
