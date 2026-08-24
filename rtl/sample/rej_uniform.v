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

module rej_uniform (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          start,
    output reg           done,
    output reg           busy,

    // Byte input stream (from SHAKE-128 squeeze)
    output reg           byte_req,           input  wire [7:0]    byte_data,          input  wire          byte_valid,

        output reg                       coeff_we,
    output reg  [7:0]                coeff_addr,
    output reg  [`MLDSA_QBITS-1:0]  coeff_data
);

    localparam [2:0] S_IDLE  = 3'd0;
    localparam [2:0] S_BYTE0 = 3'd1;
    localparam [2:0] S_BYTE1 = 3'd2;
    localparam [2:0] S_BYTE2 = 3'd3;
    localparam [2:0] S_CHECK = 3'd4;
    localparam [2:0] S_DONE  = 3'd5;

    reg [2:0]  state;
    reg [7:0]  cnt;              reg [7:0]  b0, b1, b2;  // 3 bytes buffer
    reg [23:0] candidate;
    always @(posedge clk) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            done       <= 1'b0;
            busy       <= 1'b0;
            byte_req   <= 1'b0;
            coeff_we   <= 1'b0;
            coeff_addr <= 8'd0;
            coeff_data <= {`MLDSA_QBITS{1'b0}};
            cnt        <= 8'd0;
        end else begin
            done     <= 1'b0;
            coeff_we <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy     <= 1'b1;
                        cnt      <= 8'd0;
                        byte_req <= 1'b1;
                        state    <= S_BYTE0;
                    end
                end

                S_BYTE0: begin
                    if (byte_valid) begin
                        b0       <= byte_data;
                        byte_req <= 1'b1;
                        state    <= S_BYTE1;
                    end
                end

                S_BYTE1: begin
                    if (byte_valid) begin
                        b1       <= byte_data;
                        byte_req <= 1'b1;
                        state    <= S_BYTE2;
                    end
                end

                S_BYTE2: begin
                    if (byte_valid) begin
                        b2       <= byte_data;
                        byte_req <= 1'b0;
                        state    <= S_CHECK;
                    end
                end

                S_CHECK: begin
                    // CoeffFromThreeBytes: d = b0 + 256*b1 + 65536*(b2 & 0x7F)
                    candidate = {1'b0, b2[6:0], b1, b0};
                    if (candidate < `MLDSA_Q) begin
                        coeff_we   <= 1'b1;
                        coeff_addr <= cnt;
                        coeff_data <= candidate[`MLDSA_QBITS-1:0];
                        cnt        <= cnt + 8'd1;
                        if (cnt == 8'd255) begin
                            state <= S_DONE;
                        end else begin
                            byte_req <= 1'b1;
                            state    <= S_BYTE0;
                        end
                    end else begin
                        // Reject — read 3 more bytes
                        byte_req <= 1'b1;
                        state    <= S_BYTE0;
                    end
                end

                S_DONE: begin
                    done <= 1'b1;
                    busy <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
