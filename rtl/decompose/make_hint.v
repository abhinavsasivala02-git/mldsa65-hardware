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

module make_hint (
    input  wire [`MLDSA_QBITS-1:0]  z,
    input  wire [`MLDSA_QBITS-1:0]  r,
    output wire                      hint
);

        wire [`MLDSA_QBITS-1:0] r1_a, r0_a;
    decompose u_dec_r (
        .r  (r),
        .r1 (r1_a),
        .r0 (r0_a)
    );

        wire [`MLDSA_QBITS-1:0] rz_sum;
    wire [`MLDSA_QBITS-1:0] rz_dummy;

    mod_add u_add (
        .a    (r),
        .b    (z),
        .sum  (rz_sum),
        .diff (rz_dummy)
    );

    wire [`MLDSA_QBITS-1:0] r1_b, r0_b;
    decompose u_dec_rz (
        .r  (rz_sum),
        .r1 (r1_b),
        .r0 (r0_b)
    );

        assign hint = (r1_a != r1_b) ? 1'b1 : 1'b0;

endmodule
