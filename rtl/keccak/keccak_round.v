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

module keccak_round (
    input  wire [1599:0] state_in,
    input  wire [63:0]   round_const,
    output wire [1599:0] state_out
);

        wire [63:0] a [0:4][0:4];        reg  [63:0] b [0:4][0:4];        reg  [63:0] c [0:4][0:4];        reg  [63:0] d [0:4][0:4];        reg  [63:0] e [0:4][0:4];
        genvar gx, gy;
    generate
        for (gy = 0; gy < 5; gy = gy + 1) begin : unpack_y
            for (gx = 0; gx < 5; gx = gx + 1) begin : unpack_x
                assign a[gx][gy] = state_in[(5*gy + gx)*64 +: 64];
            end
        end
    endgenerate

        generate
        for (gy = 0; gy < 5; gy = gy + 1) begin : pack_y
            for (gx = 0; gx < 5; gx = gx + 1) begin : pack_x
                assign state_out[(5*gy + gx)*64 +: 64] = e[gx][gy];
            end
        end
    endgenerate

            function [5:0] rho_offset;
        input [2:0] x;
        input [2:0] y;
        begin
            case ({x[2:0], y[2:0]})
                6'b000_000: rho_offset = 6'd0;
                6'b001_000: rho_offset = 6'd1;
                6'b010_000: rho_offset = 6'd62;
                6'b011_000: rho_offset = 6'd28;
                6'b100_000: rho_offset = 6'd27;
                6'b000_001: rho_offset = 6'd36;
                6'b001_001: rho_offset = 6'd44;
                6'b010_001: rho_offset = 6'd6;
                6'b011_001: rho_offset = 6'd55;
                6'b100_001: rho_offset = 6'd20;
                6'b000_010: rho_offset = 6'd3;
                6'b001_010: rho_offset = 6'd10;
                6'b010_010: rho_offset = 6'd43;
                6'b011_010: rho_offset = 6'd25;
                6'b100_010: rho_offset = 6'd39;
                6'b000_011: rho_offset = 6'd41;
                6'b001_011: rho_offset = 6'd45;
                6'b010_011: rho_offset = 6'd15;
                6'b011_011: rho_offset = 6'd21;
                6'b100_011: rho_offset = 6'd8;
                6'b000_100: rho_offset = 6'd18;
                6'b001_100: rho_offset = 6'd2;
                6'b010_100: rho_offset = 6'd61;
                6'b011_100: rho_offset = 6'd56;
                6'b100_100: rho_offset = 6'd14;
                default:    rho_offset = 6'd0;
            endcase
        end
    endfunction

        function [63:0] rotl64;
        input [63:0] val;
        input [5:0]  amt;
        begin
            if (amt == 6'd0)
                rotl64 = val;
            else
                rotl64 = (val << amt) | (val >> (7'd64 - {1'b0, amt}));
        end
    endfunction

        reg [63:0] col_parity [0:4];
    reg [63:0] col_d      [0:4];
    reg [63:0] rho_lane;

    integer x, y;

    always @(*) begin
                        for (x = 0; x < 5; x = x + 1) begin
            col_parity[x] = a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4];
        end

                for (x = 0; x < 5; x = x + 1) begin
            col_d[x] = col_parity[(x + 4) % 5] ^
                        rotl64(col_parity[(x + 1) % 5], 6'd1);
        end

                for (y = 0; y < 5; y = y + 1) begin
            for (x = 0; x < 5; x = x + 1) begin
                b[x][y] = a[x][y] ^ col_d[x];
            end
        end

                for (y = 0; y < 5; y = y + 1) begin
            for (x = 0; x < 5; x = x + 1) begin
                c[x][y] = rotl64(b[x][y], rho_offset(x[2:0], y[2:0]));
            end
        end

                        for (y = 0; y < 5; y = y + 1) begin
            for (x = 0; x < 5; x = x + 1) begin
                d[y][(2*x + 3*y) % 5] = c[x][y];
            end
        end

                for (y = 0; y < 5; y = y + 1) begin
            for (x = 0; x < 5; x = x + 1) begin
                e[x][y] = d[x][y] ^ ((~d[(x+1)%5][y]) & d[(x+2)%5][y]);
            end
        end

                e[0][0] = e[0][0] ^ round_const;
    end

endmodule
