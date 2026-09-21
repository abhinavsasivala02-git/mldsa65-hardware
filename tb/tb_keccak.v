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

module tb_keccak;

    reg clk, rst_n;
    localparam CLK_PERIOD = 10.0;
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // --- Keccak-f[1600] DUT ---
    reg           kf_start;
    reg  [1599:0] kf_state_in;
    wire [1599:0] kf_state_out;
    wire          kf_busy, kf_done;

    keccak_f1600 u_kf (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (kf_start),
        .state_in  (kf_state_in),
        .state_out (kf_state_out),
        .busy      (kf_busy),
        .done      (kf_done)
    );

    integer errors;

    // --- NIST test: Keccak-f[1600] on all-zero input ---
    // After permutation, lane[0] should be 64'hF1258F7940E1DDE7
    initial begin
        rst_n      = 1'b0;
        kf_start   = 1'b0;
        kf_state_in = {1600{1'b0}};
        errors     = 0;

        repeat(4) @(posedge clk);
        rst_n = 1'b1;
        repeat(2) @(posedge clk);

        $display("=== TB_KECCAK: Keccak-f[1600] Tests ===");

        // Test 1: All-zero state
        $display("[T1] Keccak-f[1600] on zero state...");
        kf_state_in = {1600{1'b0}};
        @(negedge clk);
        kf_start = 1'b1;
        @(negedge clk);
        kf_start = 1'b0;
        wait (kf_done == 1'b1);
        @(posedge clk);

        // Check lane[0] = 0xF1258F7940E1DDE7 (NIST KAT)
        if (kf_state_out[63:0] !== 64'hF1258F7940E1DDE7) begin
            $display("[T1] FAIL: lane[0] = %h, expected F1258F7940E1DDE7",
                     kf_state_out[63:0]);
            errors = errors + 1;
        end else begin
            $display("[T1] PASS: lane[0] = F1258F7940E1DDE7");
        end

        // Check lane[1] = 0x84D5CCF933C0478A
        if (kf_state_out[127:64] !== 64'h84D5CCF933C0478A) begin
            $display("[T1] FAIL: lane[1] = %h, expected 84D5CCF933C0478A",
                     kf_state_out[127:64]);
            errors = errors + 1;
        end else begin
            $display("[T1] PASS: lane[1] = 84D5CCF933C0478A");
        end

        $display("=== KECCAK TEST COMPLETE: %0d error(s) ===", errors);
        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILURES DETECTED");

        $finish;
    end

    // Timeout
    initial begin
        #(5_000_000);
        $display("TIMEOUT");
        $finish;
    end

endmodule
