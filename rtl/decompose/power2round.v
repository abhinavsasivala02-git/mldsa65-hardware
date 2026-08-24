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

module power2round (
    input  wire [`MLDSA_QBITS-1:0]  r,
    output wire [`MLDSA_QBITS-1:0]  r1,         output wire [`MLDSA_QBITS-1:0]  r0      );

    localparam D = `MLDSA_D_PARAM;               localparam HALF = (1 << (D - 1));
    wire [`MLDSA_QBITS-1:0] r1_c;
    wire [`MLDSA_QBITS-1:0] r0_c;

        assign r1_c = (r + HALF - 1) >> D;

        assign r0_c = r - (r1_c << D);

        assign r0 = HALF - r0_c;

    assign r1 = r1_c;

endmodule
