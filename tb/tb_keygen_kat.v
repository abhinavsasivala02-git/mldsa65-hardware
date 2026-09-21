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

module tb_keygen_kat;
    reg [8*80:1] fstr;   // $sformat scratch (Verilog-2001)

    // =========================================================================
    // Clock & Reset
    // =========================================================================
    reg ACLK;
    reg ARESETn;

    localparam CLK_PERIOD = 10.0;  // 100 MHz

    initial ACLK = 0;
    always #(CLK_PERIOD/2) ACLK = ~ACLK;

    // =========================================================================
    // Include KAT reference vectors
    // =========================================================================
    `include "mldsa65_kat_vectors.vh"

    // =========================================================================
    // Native parallel interface (replaces AXI4-Lite)
    // =========================================================================
    reg          wr_en;
    reg  [15:0]  wr_addr;
    reg  [31:0]  wr_data;

    reg          rd_en;
    reg  [15:0]  rd_addr;
    wire [31:0]  dut_rd_data;

    // =========================================================================
    // DUT
    // =========================================================================
    mldsa_top dut (
        .clk     (ACLK),
        .rst_n   (ARESETn),
        .wr_en   (wr_en),    .wr_addr (wr_addr),  .wr_data (wr_data),
        .rd_en   (rd_en),    .rd_addr (rd_addr),  .rd_data (dut_rd_data)
    );

    // =========================================================================
    // Native Write Task (1-cycle)
    // =========================================================================
    task wr;
        input [15:0] addr;
        input [31:0] data;
        begin
            @(posedge ACLK);
            wr_en   <= 1'b1;
            wr_addr <= addr;
            wr_data <= data;
            @(posedge ACLK);
            wr_en <= 1'b0;
        end
    endtask

    // =========================================================================
    // Native Read Task (rd_data valid 1 cycle after rd_en)
    // =========================================================================
    reg [31:0] rd_data;

    task rd;
        input  [15:0] addr;
        output [31:0] data;
        begin
            @(posedge ACLK);
            rd_en   <= 1'b1;
            rd_addr <= addr;
            @(posedge ACLK);
            rd_en <= 1'b0;
            @(posedge ACLK);
            data = dut_rd_data;
        end
    endtask

    // =========================================================================
    // Task: Write 256-bit seed to register
    // =========================================================================
    task write_seed;
        input [255:0] seed;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1) begin
                wr(16'h0010 + i*4, seed[i*32 +: 32]);
            end
        end
    endtask

    // =========================================================================
    // Task: Wait for keygen completion
    // =========================================================================
    // Sets global result: keygen_result (1=pass, 0=fail)
    reg keygen_result;
    integer keygen_timeout;


    task wait_keygen_done;
        reg [31:0] status;
        begin
            keygen_timeout = 0;
            status = 32'd0;
            keygen_result = 1'b0;

            // Status: [0]=busy, [1]=done_sticky, [2]=sig_valid
            while (!(status[1]) && keygen_timeout < 5000000) begin
                rd(16'h0004, status);
                keygen_timeout = keygen_timeout + 1;
            end

            if (keygen_timeout >= 5000000) begin
                $display("    TIMEOUT waiting for keygen!");
                keygen_result = 1'b0;
            end else begin
                keygen_result = 1'b1;
            end
        end
    endtask

    // =========================================================================
    // Task: Read and display key info
    // =========================================================================
    task check_key_output;
        reg [31:0] status;
        begin
            rd(16'h0004, status);
            $display("    Status register: 0x%08h", status);
            $display("      - busy: %b", status[0]);
            $display("      - done: %b", status[1]);
            $display("      - valid: %b", status[2]);
        end
    endtask

    // =========================================================================
    // Task: Read PK from pk_ram and display first 64 bytes
    // =========================================================================
    task read_pk_sample;
        reg [31:0] pk_word;
        integer i;
        begin
            $display("    PK (first 64 bytes):");
            for (i = 0; i < 16; i = i + 1) begin
                rd(16'h0800 + i*4, pk_word);  // pk_ram starts at 0x0800
                $display("      [%02d] 0x%08h", i*4, pk_word);
            end
        end
    endtask

    // =========================================================================
    // Task: Read PK t1 bytes (offset 32..63, row 0 of t1) from pk_ram
    // =========================================================================
    task read_pk_t1_sample;
        reg [31:0] pk_word;
        integer i;
        begin
            $display("    PK t1 row0 (bytes 32..63):");
            for (i = 0; i < 8; i = i + 1) begin
                rd(16'h0800 + 32 + i*4, pk_word);  // pk bytes 32..63
                $display("      [%02d] 0x%08h", 32 + i*4, pk_word);
            end
        end
    endtask

    // =========================================================================
    // Task: Read SK from sk_ram and display first 64 bytes
    // =========================================================================
    task read_sk_sample;
        reg [31:0] sk_word;
        integer i;
        begin
            $display("    SK (first 64 bytes):");
            for (i = 0; i < 16; i = i + 1) begin
                rd(16'h1000 + i*4, sk_word);  // sk_ram starts at 0x1000
                $display("      [%02d] 0x%08h", i*4, sk_word);
            end
        end
    endtask

    // =========================================================================
    // Task: Verify PK rho against reference value
    // Returns: rho_match (1=pass, 0=fail)
    // =========================================================================
    reg rho_match;
    task verify_pk_rho;
        input [255:0] expected_rho;
        reg [255:0] actual_rho;
        reg [31:0] word;
        integer i;
        begin
            actual_rho = 256'd0;
            for (i = 0; i < 8; i = i + 1) begin
                rd(16'h0800 + i*4, word);  // pk_ram starts at 0x0800
                actual_rho[255 - i*32 -: 32] = {word[7:0], word[15:8],
                                                word[23:16], word[31:24]};
            end

            $display("    Expected rho: 0x%064h", expected_rho);
            $display("    Actual rho:   0x%064h", actual_rho);

            rho_match = (actual_rho == expected_rho) ? 1'b1 : 1'b0;
            if (rho_match) begin
                $display("    RHO verification: PASS");
            end else begin
                $display("    RHO verification: FAIL - mismatch!");
                // Show first differing word
                for (i = 0; i < 8; i = i + 1) begin
                    if (actual_rho[i*32 +: 32] != expected_rho[i*32 +: 32]) begin
                        $display("      First mismatch at word %0d: expected 0x%08h, got 0x%08h",
                                 i, expected_rho[i*32 +: 32], actual_rho[i*32 +: 32]);
                        i = 8;  // Exit loop early
                    end
                end
            end
        end
    endtask

    // =========================================================================
    // Task: Dump full PK/SK RAM to hex files (for reference comparison)
    // =========================================================================
    integer dump_fd;
    reg [31:0] dump_word;
    integer dw_i;

    task dump_pk_sk;
        input integer vec_idx;
        reg [31:0] fname;
        begin
            $sformat(fstr, "pk_%0d.hex", vec_idx);
            dump_fd = $fopen(fstr, "w");
            for (dw_i = 0; dw_i < 1952/4; dw_i = dw_i + 1) begin
                rd(16'h0800 + dw_i*4, dump_word);
                $fwrite(dump_fd, "%08h\n", dump_word);
            end
            $fclose(dump_fd);

            $sformat(fstr, "sk_%0d.hex", vec_idx);
            dump_fd = $fopen(fstr, "w");
            for (dw_i = 0; dw_i < 4032/4; dw_i = dw_i + 1) begin
                rd(16'h1000 + dw_i*4, dump_word);
                $fwrite(dump_fd, "%08h\n", dump_word);
            end
            $fclose(dump_fd);
        end
    endtask

    // =========================================================================
    // Test Statistics
    // =========================================================================
    integer kat_pass_cnt;
    integer kat_fail_cnt;
    integer current_vec;

    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        // Initialize native interface signals
        wr_en = 1'b0; wr_addr = 16'd0; wr_data = 32'd0;
        rd_en = 1'b0; rd_addr = 16'd0;

        // Reset
        ARESETn = 1'b0;
        repeat (10) @(posedge ACLK);
        ARESETn = 1'b1;
        repeat (5) @(posedge ACLK);

        $display("==============================================");
        $display("ML-DSA-65 KeyGen Known Answer Test (KAT)");
        $display("==============================================");
        $display("");

        kat_pass_cnt = 0;
        kat_fail_cnt = 0;

        // Run KAT vectors
        for (current_vec = 0; current_vec < `NUM_KAT_VECTORS; current_vec = current_vec + 1) begin
            $display("----------------------------------------------");
            $display("KAT Vector %0d", current_vec);
            $display("----------------------------------------------");

            case (current_vec)
                0: write_seed(KAT0_SEED);
                1: write_seed(KAT1_SEED);
                2: write_seed(KAT2_SEED);
                3: write_seed(KAT3_SEED);
                4: write_seed(KAT4_SEED);
            endcase

            $display("  Seed: 0x%064h",
                (current_vec == 0) ? KAT0_SEED :
                (current_vec == 1) ? KAT1_SEED :
                (current_vec == 2) ? KAT2_SEED :
                (current_vec == 3) ? KAT3_SEED : KAT4_SEED);

            // Start keygen (CTRL[0] = 1)
            wr(16'h0000, 32'h0000_0001);
            repeat (5) @(posedge ACLK);

            // Check status
            rd(16'h0004, rd_data);
            $display("  Status after start: busy=%b, done=%b", rd_data[0], rd_data[1]);

            // Wait for completion
            wait_keygen_done;

            if (keygen_result) begin
                $display("  KeyGen completed after %0d polls", keygen_timeout);

                // Verify output
                check_key_output;

                // Sample PK and SK outputs
                read_pk_sample;
                read_sk_sample;

                // Dump full PK/SK for reference comparison
                dump_pk_sk(current_vec);

                // Verify PK rho against reference
                case (current_vec)
                    0: verify_pk_rho(KAT0_RHO);
                    1: verify_pk_rho(KAT1_RHO);
                    2: verify_pk_rho(KAT2_RHO);
                    3: verify_pk_rho(KAT3_RHO);
                    4: verify_pk_rho(KAT4_RHO);
                endcase

                // Dump t1 row0 bytes for cross-checking
                if (current_vec == 0)
                    read_pk_t1_sample;

                // Read final status
                rd(16'h0004, rd_data);
                if (rd_data[1] && rd_data[0] == 1'b0 && rho_match) begin
                    $display("  Result: PASS");
                    kat_pass_cnt = kat_pass_cnt + 1;
                end else begin
                    $display("  Result: FAIL");
                    kat_fail_cnt = kat_fail_cnt + 1;
                end
            end else begin
                kat_fail_cnt = kat_fail_cnt + 1;
                $display("  Result: FAIL (timeout)");
            end

            $display("");
        end

        // Final Report
        $display("==============================================");
        $display("KAT Summary");
        $display("==============================================");
        $display("  Total vectors: %0d", `NUM_KAT_VECTORS);
        $display("  Passed: %0d", kat_pass_cnt);
        $display("  Failed: %0d", kat_fail_cnt);
        $display("");

        if (kat_fail_cnt == 0) begin
            $display("All KAT vectors PASSED!");
        end else begin
            $display("WARNING: %0d KAT vector(s) FAILED!", kat_fail_cnt);
        end

        $display("");
        $display("Simulation finished at %t", $time);

        if (kat_fail_cnt > 0) begin
            $finish(1);
        end else begin
            $finish;
        end
    end

    // =========================================================================
    // Timeout watchdog
    // =========================================================================
    initial begin
        #(20_000_000);  // 20M cycles timeout
        $display("FATAL: Simulation timeout exceeded!");
        $finish(1);
    end

endmodule
