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

module mod_add (
    input  wire [`MLDSA_QBITS-1:0] a,
    input  wire [`MLDSA_QBITS-1:0] b,
    output reg  [`MLDSA_QBITS-1:0] sum,
    output reg  [`MLDSA_QBITS-1:0] diff
);

    reg [`MLDSA_QBITS:0] sum_wide, sum_corr;
    reg [`MLDSA_QBITS:0] diff_wide, diff_corr;

    always @(*) begin
                sum_wide = {1'b0, a} + {1'b0, b};
        sum_corr = sum_wide - `MLDSA_Q;
        if (sum_corr[`MLDSA_QBITS])
            sum = sum_wide[`MLDSA_QBITS-1:0];           else
            sum = sum_corr[`MLDSA_QBITS-1:0];
                diff_wide = {1'b0, a} - {1'b0, b};
        diff_corr = diff_wide + `MLDSA_Q;
        if (diff_wide[`MLDSA_QBITS])
            diff = diff_corr[`MLDSA_QBITS-1:0];          else
            diff = diff_wide[`MLDSA_QBITS-1:0];      end

endmodule
