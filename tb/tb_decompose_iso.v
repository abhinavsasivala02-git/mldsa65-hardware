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

module tb_decompose_iso;
    reg  [22:0] r;
    wire [22:0] r1, r0;
    reg  [31:0] gamma2x2_val;
    reg  [23:0] dd;
    wire [23:0] q1 = dd / 523776;
    wire [23:0] q2 = dd / gamma2x2_val;
    wire [23:0] q3 = dd / 20'd523776;
    wire [23:0] diff2 = u_dc.r_plus - u_dc.r0_tmp;
    wire [23:0] q4 = diff2 / 523776;
    wire [23:0] q5 = (u_dc.r_plus - u_dc.r0_tmp) / 523776;

    decompose u_dc (.r(r), .r1(r1), .r0(r0));

    integer fd;
    initial begin
        fd = $fopen("decomp_iso.txt", "w");
        gamma2x2_val = 523776;
        dd = 24'h47ee00;
        // random-ish probe of inputs drawn from the dc_trace stream
        r = 23'h4427b3; #1; $fwrite(fd, "r=4427b3 r1=%05x r0=%05x | rp=%06x r0t=%06x r0m=%07x d=%06x q1=%05x q2=%05x q3=%05x q4=%05x q5=%05x g2x2=%06x\n", r1, r0, u_dc.r_plus, u_dc.r0_tmp, u_dc.r0_m, u_dc.r_plus - u_dc.r0_tmp, q1, q2, q3, q4, q5, gamma2x2_val);
        r = 23'h798857; #1; $fwrite(fd, "r=798857 r1=%05x r0=%05x | rp=%06x r0t=%06x r0m=%07x d=%06x\n", r1, r0, u_dc.r_plus, u_dc.r0_tmp, u_dc.r0_m, u_dc.r_plus - u_dc.r0_tmp);
        r = 23'h1ec1a5; #1; $fwrite(fd, "r=1ec1a5 r1=%05x r0=%05x | rp=%06x r0t=%06x r0m=%07x d=%06x\n", r1, r0, u_dc.r_plus, u_dc.r0_tmp, u_dc.r0_m, u_dc.r_plus - u_dc.r0_tmp);
        // exhaustive sweep of interesting region: r in [Q, 2^23)
        begin : sweep
            integer i;
            for (i = 8380417; i < 8388608; i = i + 3) begin
                r = i[22:0]; #1;
                if (r1 > 15) $fwrite(fd, "r=%d r1=%05x r0=%05x\n", i, r1, r0);
            end
        end
        $fclose(fd);
        $finish;
    end
endmodule