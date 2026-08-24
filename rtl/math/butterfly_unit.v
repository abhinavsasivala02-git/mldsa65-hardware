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

module butterfly_unit (
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      vld_in,
    input  wire                      intt_mode,
    input  wire [`MLDSA_QBITS-1:0]  a,
    input  wire [`MLDSA_QBITS-1:0]  b,
    input  wire [`MLDSA_QBITS-1:0]  zeta_mont,
    output reg  [`MLDSA_QBITS-1:0]  a_out,
    output reg  [`MLDSA_QBITS-1:0]  b_out,
    output reg                       vld_out
);

        wire [`MLDSA_QBITS-1:0] apb, amb;

    mod_add u_add (
        .a    (a),
        .b    (b),
        .sum  (apb),
        .diff (amb)
    );

        wire [`MLDSA_QBITS-1:0] mult_in;
    wire [`MLDSA_QBITS-1:0] mult_out;
    wire                     mult_vld_out;

    // NTT: multiply zeta * b;  INTT: multiply zeta * (a-b)
    assign mult_in = intt_mode ? amb : b;

    montgomery_mult u_mont (
        .clk     (clk),
        .rst_n   (rst_n),
        .vld_in  (vld_in),
        .a       (zeta_mont),
        .b       (mult_in),
        .result  (mult_out),
        .vld_out (mult_vld_out)
    );

        reg [`MLDSA_QBITS-1:0] a_dly_0, a_dly_1, a_dly_2, a_dly_3;
    reg [`MLDSA_QBITS-1:0] apb_dly_0, apb_dly_1, apb_dly_2, apb_dly_3;

    always @(posedge clk) begin
        if (!rst_n) begin
            a_dly_0   <= {`MLDSA_QBITS{1'b0}};
            a_dly_1   <= {`MLDSA_QBITS{1'b0}};
            a_dly_2   <= {`MLDSA_QBITS{1'b0}};
            a_dly_3   <= {`MLDSA_QBITS{1'b0}};
            apb_dly_0 <= {`MLDSA_QBITS{1'b0}};
            apb_dly_1 <= {`MLDSA_QBITS{1'b0}};
            apb_dly_2 <= {`MLDSA_QBITS{1'b0}};
            apb_dly_3 <= {`MLDSA_QBITS{1'b0}};
        end else begin
            a_dly_0   <= a;
            a_dly_1   <= a_dly_0;
            a_dly_2   <= a_dly_1;
            a_dly_3   <= a_dly_2;
            apb_dly_0 <= apb;
            apb_dly_1 <= apb_dly_0;
            apb_dly_2 <= apb_dly_1;
            apb_dly_3 <= apb_dly_2;
        end
    end

    // --- Output stage: compute NTT result using delayed a + mult_out ---
    wire [`MLDSA_QBITS-1:0] ntt_a_out, ntt_b_out;

    mod_add u_add2 (
        .a    (a_dly_3),
        .b    (mult_out),
        .sum  (ntt_a_out),
        .diff (ntt_b_out)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            a_out   <= {`MLDSA_QBITS{1'b0}};
            b_out   <= {`MLDSA_QBITS{1'b0}};
            vld_out <= 1'b0;
        end else begin
            vld_out <= mult_vld_out;
            if (intt_mode) begin
                a_out <= apb_dly_3;
                b_out <= mult_out;
            end else begin
                a_out <= ntt_a_out;
                b_out <= ntt_b_out;
            end
        end
    end

endmodule
