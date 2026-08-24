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

module shake128 (
    input  wire          clk,
    input  wire          rst_n,

        input  wire          init,
    input  wire          wr_en,
    input  wire [4:0]    wr_lane_idx,           input  wire [63:0]   wr_lane_data,

    input  wire          pad_and_permute,
    input  wire          permute,

        input  wire [4:0]    rd_lane_idx,           output wire [63:0]   rd_lane_data,

        output wire          busy,
    output wire          rdy
);

    localparam RATE_LANES = 21;
        reg [1599:0] state;

        assign rd_lane_data = state[rd_lane_idx*64 +: 64];

        reg           kf_start;
    wire          kf_busy, kf_done;
    wire [1599:0] kf_state_out;

    keccak_f1600 u_keccak (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (kf_start),
        .state_in  (state),
        .state_out (kf_state_out),
        .busy      (kf_busy),
        .done      (kf_done)
    );

    assign busy = kf_busy;
    assign rdy  = ~kf_busy && (fsm == S_IDLE);

        localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_PAD  = 2'd1;
    localparam [1:0] S_WAIT = 2'd2;

    reg [1:0] fsm;

    always @(posedge clk) begin
        if (!rst_n) begin
            state    <= {1600{1'b0}};
            kf_start <= 1'b0;
            fsm      <= S_IDLE;
        end else begin
            kf_start <= 1'b0;

            case (fsm)
                S_IDLE: begin
                    if (init)
                        state <= {1600{1'b0}};

                    if (wr_en && !kf_busy)
                        state[wr_lane_idx*64 +: 64] <=
                            state[wr_lane_idx*64 +: 64] ^ wr_lane_data;

                    if (pad_and_permute && !kf_busy) begin
                        kf_start <= 1'b1;
                        fsm      <= S_WAIT;
                    end

                    if (permute && !kf_busy) begin
                        kf_start <= 1'b1;
                        fsm      <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    if (kf_done) begin
                        state <= kf_state_out;
                        fsm   <= S_IDLE;
                    end
                end

                default: fsm <= S_IDLE;
            endcase
        end
    end

endmodule
