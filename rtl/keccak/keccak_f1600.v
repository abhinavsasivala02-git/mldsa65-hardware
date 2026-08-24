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

module keccak_f1600 (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          start,
    input  wire [1599:0] state_in,
    output reg  [1599:0] state_out,
    output reg           busy,
    output reg           done
);

        function [63:0] rc;
        input [4:0] rnd;
        begin
            case (rnd)
                5'd0:  rc = 64'h0000000000000001;
                5'd1:  rc = 64'h0000000000008082;
                5'd2:  rc = 64'h800000000000808A;
                5'd3:  rc = 64'h8000000080008000;
                5'd4:  rc = 64'h000000000000808B;
                5'd5:  rc = 64'h0000000080000001;
                5'd6:  rc = 64'h8000000080008081;
                5'd7:  rc = 64'h8000000000008009;
                5'd8:  rc = 64'h000000000000008A;
                5'd9:  rc = 64'h0000000000000088;
                5'd10: rc = 64'h0000000080008009;
                5'd11: rc = 64'h000000008000000A;
                5'd12: rc = 64'h000000008000808B;
                5'd13: rc = 64'h800000000000008B;
                5'd14: rc = 64'h8000000000008089;
                5'd15: rc = 64'h8000000000008003;
                5'd16: rc = 64'h8000000000008002;
                5'd17: rc = 64'h8000000000000080;
                5'd18: rc = 64'h000000000000800A;
                5'd19: rc = 64'h800000008000000A;
                5'd20: rc = 64'h8000000080008081;
                5'd21: rc = 64'h8000000000008080;
                5'd22: rc = 64'h0000000080000001;
                5'd23: rc = 64'h8000000080008008;
                default: rc = 64'h0;
            endcase
        end
    endfunction

        reg [1599:0] state_reg;
    reg [4:0]    round_cnt;

        wire [1599:0] round_out;
    wire [63:0]   round_rc;

    assign round_rc = rc(round_cnt);

    keccak_round u_round (
        .state_in    (state_reg),
        .round_const (round_rc),
        .state_out   (round_out)
    );

        localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_RUN  = 2'd1;
    localparam [1:0] S_DONE = 2'd2;

    reg [1:0] fsm_state;

    always @(posedge clk) begin
        if (!rst_n) begin
            fsm_state <= S_IDLE;
            state_reg <= {1600{1'b0}};
            state_out <= {1600{1'b0}};
            round_cnt <= 5'd0;
            busy      <= 1'b0;
            done      <= 1'b0;
        end else begin
            done <= 1'b0;

            case (fsm_state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        state_reg <= state_in;
                        round_cnt <= 5'd0;
                        busy      <= 1'b1;
                        fsm_state <= S_RUN;
                    end
                end

                S_RUN: begin
                    state_reg <= round_out;
                    round_cnt <= round_cnt + 5'd1;
                    if (round_cnt == 5'd23) begin
                        state_out <= round_out;
                        fsm_state <= S_DONE;
                    end
                end

                S_DONE: begin
                    done      <= 1'b1;
                    busy      <= 1'b0;
                    fsm_state <= S_IDLE;
                end

                default: fsm_state <= S_IDLE;
            endcase
        end
    end

endmodule
