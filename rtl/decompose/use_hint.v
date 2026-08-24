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

module use_hint (
    input  wire                      hint,
    input  wire [`MLDSA_QBITS-1:0]  r,
    output reg  [`MLDSA_QBITS-1:0]  r1_out
);

    localparam GAMMA2   = `MLDSA_GAMMA2;
    localparam M        = (`MLDSA_Q - 1) / (2 * GAMMA2);
    wire [`MLDSA_QBITS-1:0] r1, r0;

    decompose u_dec (
        .r  (r),
        .r1 (r1),
        .r0 (r0)
    );

        wire r0_positive;
    assign r0_positive = (r0 != {`MLDSA_QBITS{1'b0}} && r0 < GAMMA2);

    always @(*) begin
        if (!hint) begin
            r1_out = r1;
        end else begin
            if (r0_positive) begin
                                if (r1 + 1 >= M)
                    r1_out = {`MLDSA_QBITS{1'b0}};
                else
                    r1_out = r1 + 1;
            end else begin
                                if (r1 == {`MLDSA_QBITS{1'b0}})
                    r1_out = M - 1;
                else
                    r1_out = r1 - 1;
            end
        end
    end

endmodule
