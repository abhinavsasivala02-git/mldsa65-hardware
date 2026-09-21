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

module tb_mldsa_joint;
    reg [8*80:1] fstr;   // $sformat scratch (Verilog-2001)

    // Clock / reset
    reg ACLK = 0;
    reg ARESETn = 0;
    always #5 ACLK = ~ACLK;

    `include "mldsa65_kat_vectors.vh"
    `include "mldsa65_sign_vectors.vh"

    // Native interface
    reg  [15:0] wr_addr;  reg wr_en; reg [31:0] wr_data;
    reg  [15:0] rd_addr;  reg rd_en;
    wire [31:0] dut_rd_data;

    mldsa_top dut (
        .clk(ACLK), .rst_n(ARESETn),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(dut_rd_data)
    );

    // =========================================================================
    // Native write task (1-cycle)
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
    // Native read task (dut_rd_data valid 1 cycle after rd_en)
    // =========================================================================
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
    // Wait for a controller done (status[1]); optional valid check
    // =========================================================================
    integer polls;
    task wait_done;
        input check_valid;
        output ok;
        reg [31:0] status;
        begin
            polls   = 0;
            status  = 32'd0;
            ok      = 1'b0;
            while (!(status[1]) && polls < 30000000) begin
                rd(16'h0004, status);
                polls = polls + 1;
            end
            ok = status[1] && (!check_valid || status[2]);
        end
    endtask

    // =========================================================================
    // Load 256-bit register from a RAM byte window via native port
    // =========================================================================
    task copy_256;
        input [15:0] src_base;   // RAM byte base (0x0800 pk / 0x1000 sk)
        input [15:0] dst_base;   // register base (0x30 rho / 0x50 K / 0x70 tr)
        integer i;
        reg [31:0] w;
        begin
            for (i = 0; i < 8; i = i + 1) begin
                rd(src_base + i*4, w);
                wr(dst_base + i*4, w);
            end
        end
    endtask

    // Load 256-bit value into a register base (low word first, matches KAT tbs)
    task load_256;
        input [15:0] base;
        input [255:0] val;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1)
                wr(base + i*4, val[i*32 +: 32]);
        end
    endtask

    // Load 512-bit mu into mu_lo/mu_hi (low word first, matches KAT tbs)
    task load_mu;
        input [511:0] mu;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1)
                wr(16'h00D0 + i*4, mu[i*32 +: 32]);       // mu[255:0]
            for (i = 0; i < 4; i = i + 1)
                wr(16'h00F0 + i*4, mu[256 + i*32 +: 32]); // mu[383:256]
            for (i = 0; i < 4; i = i + 1)
                wr(16'h0100 + i*4, mu[384 + i*32 +: 32]); // mu[511:384]
        end
    endtask

    // =========================================================================
    // Statistics
    // =========================================================================
    integer pass_cnt, fail_cnt;
    integer current_vec;
    reg ok, keygen_ok, sign_ok, verify_ok;

    // =========================================================================
    // Main test
    // =========================================================================
    initial begin
        pass_cnt = 0; fail_cnt = 0;

        // Reset
        ARESETn = 1'b0;
        wr_en = 1'b0; wr_addr = 16'd0; wr_data = 32'd0;
        rd_en = 1'b0; rd_addr = 16'd0;
        repeat (10) @(posedge ACLK);
        ARESETn = 1'b1;
        repeat (5) @(posedge ACLK);

        $display("==============================================");
        $display("ML-DSA-65 End-to-End Keygen->Sign->Verify");
        $display("==============================================");

        for (current_vec = 0; current_vec < `NUM_SIGN_VECTORS; current_vec = current_vec + 1) begin
            $display("----------------------------------------------");
            $display("Joint Vector %0d", current_vec);
            $display("----------------------------------------------");

            // --- 1. KEYGEN ---
            // Load seed_xi (256-bit)
            case (current_vec)
                0: load_256(16'h0010, KAT0_SEED);
                1: load_256(16'h0010, KAT1_SEED);
                2: load_256(16'h0010, KAT2_SEED);
                3: load_256(16'h0010, KAT3_SEED);
                4: load_256(16'h0010, KAT4_SEED);
            endcase

            wr(16'h0000, 32'h0000_0001);   // start_keygen
            wait_done(1'b0, keygen_ok);
            $display("  keygen done: %0d polls, ok=%b", polls, keygen_ok);

            // Copy generated key into sign registers:
            //   rho = pk_ram[0:31]  (also sk_ram[0:31])
            //   K   = sk_ram[32:63]
            //   tr  = sk_ram[64:127]
            copy_256(16'h0800, 16'h0030);   // rho -> rho_reg
            copy_256(16'h1020, 16'h0050);   // K   -> K_reg
            copy_256(16'h1040, 16'h0070);   // tr  -> tr_reg

            // Load rnd + mu for signing
            // Load rnd (256-bit) for signing
            case (current_vec)
                0: load_256(16'h0090, KAT0_RND);
                1: load_256(16'h0090, KAT1_RND);
                2: load_256(16'h0090, KAT2_RND);
                3: load_256(16'h0090, KAT3_RND);
                4: load_256(16'h0090, KAT4_RND);
            endcase
            // Load mu (512-bit) for signing
            case (current_vec)
                0: load_mu(KAT0_MU);
                1: load_mu(KAT1_MU);
                2: load_mu(KAT2_MU);
                3: load_mu(KAT3_MU);
                4: load_mu(KAT4_MU);
            endcase

            // --- 2. SIGN ---
            wr(16'h0000, 32'h0000_0002);   // start_sign
            wait_done(1'b1, sign_ok);      // require sig_valid
            $display("  sign done: %0d polls, ok=%b (kappa=%0d)",
                     polls, sign_ok, dut.u_sign.kappa);

            // Dump signature for offline comparison
            begin : dump_blk
                integer fd, i;
                reg [31:0] w;
                $sformat(fstr, "joint_sig_%0d.hex", current_vec);
                fd = $fopen(fstr, "w");
                for (i = 0; i < 828; i = i + 1) begin
                    rd(16'h3000 + i*4, w);
                    $fwrite(fd, "%08h\n", w);
                end
                $fclose(fd);
            end

            // --- 3. VERIFY ---
            // pk_ram already holds keygen pk; sig_ram holds the new sig;
            // rho_reg already = pk rho (set above); mu already loaded.
            wr(16'h0000, 32'h0000_0004);   // start_verify
            wait_done(1'b0, verify_ok);    // wait done; valid is checked below
            // status[2] can't be used (sign's sig_valid stays latched), so check
            // the real criterion: computed c_tilde' == signature's c_tilde.
            verify_ok = verify_ok &&
                        (dut.u_verify.c_tilde_comp == dut.u_verify.c_tilde_cap);
            $display("  verify done: %0d polls, ok=%b (comp==cap=%b)",
                     polls, verify_ok,
                     dut.u_verify.c_tilde_comp == dut.u_verify.c_tilde_cap);

            if (keygen_ok && sign_ok && verify_ok) begin
                $display("  Joint result: PASS");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  Joint result: FAIL (kg=%b sg=%b vf=%b)",
                         keygen_ok, sign_ok, verify_ok);
                fail_cnt = fail_cnt + 1;
            end
            $display("");
        end

        $display("==============================================");
        $display("Joint KAT Summary");
        $display("==============================================");
        $display("  Passed: %0d", pass_cnt);
        $display("  Failed: %0d", fail_cnt);
        if (fail_cnt == 0)
            $display("All Joint Keygen->Sign->Verify vectors PASSED!");
        else
            $display("SOME JOINT VECTORS FAILED");
        $finish;
    end

    // Watchdog (long: keygen + sign + verify per vector)
    initial begin
        #(2_000_000_000);
        $display("FATAL: Simulation timeout exceeded!");
        $finish(1);
    end

endmodule
