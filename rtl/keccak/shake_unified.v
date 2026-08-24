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

module shake_unified (
    input  wire          clk,
    input  wire          rst_n,

    // ---- Channel A (SHAKE-256) ----
    input  wire          a_init,
    input  wire          a_wr_en,
    input  wire [4:0]    a_wr_lane_idx,
    input  wire [63:0]   a_wr_lane_data,
    input  wire          a_pad_and_permute,
    input  wire          a_permute,
    input  wire [4:0]    a_rd_lane_idx,
    output wire [63:0]   a_rd_lane_data,
    output wire          a_busy,
    output wire          a_rdy,

    // ---- Channel B (SHAKE-128) ----
    input  wire          b_init,
    input  wire          b_wr_en,
    input  wire [4:0]    b_wr_lane_idx,
    input  wire [63:0]   b_wr_lane_data,
    input  wire          b_pad_and_permute,
    input  wire          b_permute,
    input  wire [4:0]    b_rd_lane_idx,
    output wire [63:0]   b_rd_lane_data,
    output wire          b_busy,
    output wire          b_rdy
);

        reg           kf_start;
    wire          kf_busy, kf_done;
    reg  [1599:0] kf_state_in;
    wire [1599:0] kf_state_out;

    keccak_f1600 u_keccak (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (kf_start),
        .state_in  (kf_state_in),
        .state_out (kf_state_out),
        .busy      (kf_busy),
        .done      (kf_done)
    );

                reg [1599:0] state;            reg [1599:0] save_buf;         reg          active_ch;
        wire        wr_en       = (active_ch == 1'b0) ? a_wr_en : b_wr_en;
    wire [4:0]  wr_lane_idx = (active_ch == 1'b0) ? a_wr_lane_idx : b_wr_lane_idx;
    wire [63:0] wr_lane_data= (active_ch == 1'b0) ? a_wr_lane_data : b_wr_lane_data;

        assign a_rd_lane_data = state[a_rd_lane_idx * 64 +: 64];
    assign b_rd_lane_data = state[b_rd_lane_idx * 64 +: 64];

        localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_PAD  = 2'd1;
    localparam [1:0] S_WAIT = 2'd2;

    reg [1:0] fsm_a, fsm_b;
    reg       owner;

        assign a_busy = kf_busy | (fsm_a != S_IDLE);
    assign a_rdy  = (fsm_a == S_IDLE) & ~kf_busy & ~a_pad_and_permute & ~a_permute;
    assign b_busy = kf_busy | (fsm_b != S_IDLE);
    assign b_rdy  = (fsm_b == S_IDLE) & ~kf_busy & ~b_pad_and_permute & ~b_permute;

        always @(posedge clk) begin
        if (!rst_n) begin
            fsm_a <= S_IDLE;
        end else begin
            case (fsm_a)
                S_IDLE: begin
                    if (a_pad_and_permute && !kf_busy)
                        fsm_a <= S_PAD;
                    else if (a_permute && !kf_busy)
                        fsm_a <= S_WAIT;
                end
                S_PAD:  fsm_a <= S_WAIT;
                S_WAIT: begin
                    if (kf_done && owner == 1'b0) fsm_a <= S_IDLE;
                end
                default: fsm_a <= S_IDLE;
            endcase
        end
    end

        always @(posedge clk) begin
        if (!rst_n) begin
            fsm_b <= S_IDLE;
        end else begin
            case (fsm_b)
                S_IDLE: begin
                    if (b_pad_and_permute && !kf_busy)
                        fsm_b <= S_PAD;
                    else if (b_permute && !kf_busy)
                        fsm_b <= S_WAIT;
                end
                S_PAD:  fsm_b <= S_WAIT;
                S_WAIT: begin
                    if (kf_done && owner == 1'b1) fsm_b <= S_IDLE;
                end
                default: fsm_b <= S_IDLE;
            endcase
        end
    end

        always @(posedge clk) begin
        if (!rst_n) begin
            state     <= {1600{1'b0}};
            save_buf  <= {1600{1'b0}};
            active_ch <= 1'b0;
        end else begin
                        if (a_init && active_ch == 1'b1) begin
                save_buf  <= state;
                state     <= {1600{1'b0}};
                active_ch <= 1'b0;
            end
            else if (b_init && active_ch == 1'b0) begin
                save_buf  <= state;
                state     <= {1600{1'b0}};
                active_ch <= 1'b1;
            end
            else if (a_init && active_ch == 1'b0) begin
                state <= {1600{1'b0}};
            end
            else if (b_init && active_ch == 1'b1) begin
                state <= {1600{1'b0}};
            end

                        if (wr_en && !kf_busy)
                state[wr_lane_idx*64 +: 64] <=
                    state[wr_lane_idx*64 +: 64] ^ wr_lane_data;

                        if (kf_done)
                state <= kf_state_out;
        end
    end

        always @(posedge clk) begin
        if (!rst_n) begin
            kf_start    <= 1'b0;
            kf_state_in <= {1600{1'b0}};
            owner       <= 1'b0;
        end else begin
            kf_start <= 1'b0;

            if (!kf_busy) begin
                if (fsm_a == S_PAD || (a_permute && fsm_a == S_IDLE)) begin
                    kf_start    <= 1'b1;
                    kf_state_in <= state;
                    owner       <= 1'b0;
                end
                else if (fsm_b == S_PAD || (b_permute && fsm_b == S_IDLE)) begin
                    kf_start    <= 1'b1;
                    kf_state_in <= state;
                    owner       <= 1'b1;
                end
            end
        end
    end

endmodule
