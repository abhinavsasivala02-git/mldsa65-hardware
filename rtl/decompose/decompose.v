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

module decompose (
    input  wire [`MLDSA_QBITS-1:0]  r,
    output reg  [`MLDSA_QBITS-1:0]  r1,
    output reg  [`MLDSA_QBITS-1:0]  r0
);

    localparam GAMMA2     = `MLDSA_GAMMA2;             localparam GAMMA2X2   = 2 * GAMMA2;                localparam Q_MINUS_1  = `MLDSA_Q - 1;
    reg [`MLDSA_QBITS:0] r_plus;
    reg [`MLDSA_QBITS:0] r0_tmp;
    reg [`MLDSA_QBITS+1:0] r0_m;
    reg [`MLDSA_QBITS:0] diff;

    always @(*) begin
        r_plus = {1'b0, r};

                        r0_tmp = r_plus % GAMMA2X2;
        if (r0_tmp > GAMMA2)
            r0_tmp = r0_tmp - GAMMA2X2;

                diff = r_plus - r0_tmp;

                r0_m = {1'b0, r0_tmp};
        if (r0_tmp[`MLDSA_QBITS])
            r0_m = r0_m + `MLDSA_Q;

        if (diff == Q_MINUS_1) begin
            r1 = {`MLDSA_QBITS{1'b0}};
                        if (r0_m == 0)
                r0 = `MLDSA_Q - 1;
            else
                r0 = r0_m[`MLDSA_QBITS-1:0] - 1;
        end else begin
            r1 = diff / GAMMA2X2;
            r0 = r0_m[`MLDSA_QBITS-1:0];
        end
    end

endmodule
