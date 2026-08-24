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

module tb_mldsa_sign_kat;

                reg ACLK;
    reg ARESETn;

    localparam CLK_PERIOD = 10.0;
    initial ACLK = 0;
    always #(CLK_PERIOD/2) ACLK = ~ACLK;

        // Include KAT reference vectors
        `include "mldsa65_kat_vectors.vh"
    `include "mldsa65_sign_vectors.vh"

                reg          wr_en;
    reg  [15:0]  wr_addr;
    reg  [31:0]  wr_data;

    reg          rd_en;
    reg  [15:0]  rd_addr;
    wire [31:0]  dut_rd_data;

                mldsa_top dut (
        .clk     (ACLK),
        .rst_n   (ARESETn),
        .wr_en   (wr_en),    .wr_addr (wr_addr),  .wr_data (wr_data),
        .rd_en   (rd_en),    .rd_addr (rd_addr),  .rd_data (dut_rd_data)
    );

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

                task write_seed;
        input [255:0] seed;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1)
                wr(16'h0010 + i*4, seed[i*32 +: 32]);
        end
    endtask

        reg keygen_ok;
    integer kg_polls;
    task wait_keygen_done;
        reg [31:0] status;
        begin
            kg_polls = 0;
            keygen_ok = 1'b0;
            status = 32'd0;
            while (!(status[1]) && kg_polls < 5000000) begin
                rd(16'h0004, status);
                kg_polls = kg_polls + 1;
            end
            keygen_ok = status[1];
        end
    endtask

        reg sign_ok;
    integer sg_polls;
    task wait_sign_done;
        reg [31:0] status;
        begin
            sg_polls = 0;
            sign_ok = 1'b0;
            status = 32'd0;
            while (!(status[1]) && sg_polls < 20000000) begin
                rd(16'h0004, status);
                sg_polls = sg_polls + 1;
            end
            sign_ok = status[1] && status[2];
        end
    endtask

        task load_sign_keys;
        reg [31:0] word;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1) begin
                rd(16'h0800 + i*4, word);       // pk rho bytes 4i..4i+3
                wr(16'h0030 + i*4, word);                  end
            for (i = 0; i < 8; i = i + 1) begin
                rd(16'h1020 + i*4, word);       // sk key bytes 32+4i..35+4i
                wr(16'h0050 + i*4, word);                  end
        end
    endtask

        reg [7:0] ref_pk [0:1951];
    reg [7:0] ref_sk [0:4031];

    // Load standard KAT reference keys directly into pk_ram/sk_ram via AXI
    task load_ref_keys;
        input integer vec_idx;
        integer k;
        begin
            $readmemh($sformatf("tb/ref_pk_%0d.mem", vec_idx), ref_pk);
            $readmemh($sformatf("tb/ref_sk_%0d.mem", vec_idx), ref_sk);
            for (k = 0; k < 1952; k = k + 1)
                wr(16'h0800 + k, ref_pk[k]);
            for (k = 0; k < 4032; k = k + 1)
                wr(16'h1000 + k, ref_sk[k]);
        end
    endtask

        task load_rnd;
        input [255:0] rnd;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1)
                wr(16'h0090 + i*4, rnd[i*32 +: 32]);
        end
    endtask

    task load_mu;
        input [511:0] mu;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1)
                wr(16'h00D0 + i*4, mu[i*32 +: 32]);                   for (i = 0; i < 4; i = i + 1)
                wr(16'h00F0 + i*4, mu[256 + i*32 +: 32]);             for (i = 0; i < 4; i = i + 1)
                wr(16'h0100 + i*4, mu[384 + i*32 +: 32]);         end
    endtask

        integer dump_fd;
    reg [31:0] dump_word;
    integer dw_i;
    task dump_sig;
        input integer vec_idx;
        begin
            dump_fd = $fopen($sformatf("sig_%0d.hex", vec_idx), "w");
            for (dw_i = 0; dw_i < 828; dw_i = dw_i + 1) begin
                rd(16'h3000 + dw_i*4, dump_word);
                $fwrite(dump_fd, "%08h\n", dump_word);
            end
            $fclose(dump_fd);
        end
    endtask

    task dump_w;
        input integer vec_idx;
        integer fd;
        integer i;
        integer j;
        begin
            fd = $fopen($sformatf("w_%0d.txt", vec_idx), "w");
            $fwrite(fd, "vec %0d kappa %0d\n", vec_idx, dut.u_sign.kappa);
            for (i = 0; i < 6; i = i + 1)
                $fwrite(fd, "ctilde_%0d %016x\n", i, dut.u_sign.c_tilde[383 - i*64 -: 64]);
            if (vec_idx == 0) begin
                for (i = 0; i < 6; i = i + 1)
                    for (j = 0; j < 256; j = j + 1)
                        $fwrite(fd, "w1_%0d_%0d %05x\n", i, j, dut.u_sign.spad[(33 + i)*256 + j]);
                for (i = 0; i < 6; i = i + 1)
                    for (j = 0; j < 256; j = j + 1)
                        $fwrite(fd, "w0_%0d_%0d %05x\n", i, j, dut.u_sign.spad[(27 + i)*256 + j]);
            end
            $fclose(fd);
        end
    endtask

                integer sign_pass_cnt;
    integer sign_fail_cnt;
    integer current_vec;

                initial begin
                wr_en = 1'b0; wr_addr = 16'd0; wr_data = 32'd0;
        rd_en = 1'b0; rd_addr = 16'd0;

                ARESETn = 1'b0;
        repeat (10) @(posedge ACLK);
        ARESETn = 1'b1;
        repeat (5) @(posedge ACLK);

        rd(16'h3000, dump_word);        $display("==============================================");
        $display("ML-DSA-65 Sign Known Answer Test (KAT)");
        $display("==============================================");
        $display("");

        sign_pass_cnt = 0;
        sign_fail_cnt = 0;

        for (current_vec = 0; current_vec < `NUM_SIGN_VECTORS; current_vec = current_vec + 1) begin
            $display("----------------------------------------------");
            $display("KAT Vector %0d", current_vec);
            $display("----------------------------------------------");

            // Load standard KAT reference keys into pk_ram/sk_ram (no keygen)
            load_ref_keys(current_vec);
            $display("  Ref keys loaded (pk+sk via AXI)");

                        load_sign_keys;
            case (current_vec)
                0: begin load_rnd(KAT0_RND); load_mu(KAT0_MU); end
                1: begin load_rnd(KAT1_RND); load_mu(KAT1_MU); end
                2: begin load_rnd(KAT2_RND); load_mu(KAT2_MU); end
                3: begin load_rnd(KAT3_RND); load_mu(KAT3_MU); end
                4: begin load_rnd(KAT4_RND); load_mu(KAT4_MU); end
            endcase

            // Start sign (CTRL[1])
            wr(16'h0000, 32'h0000_0002);
            wait_sign_done;

            if (!sign_ok) begin
                $display("  FAIL: sign timeout or sig_valid not set");
                sign_fail_cnt = sign_fail_cnt + 1;
            end else begin
                $display("  Sign done after %0d polls, accepted kappa=%0d", sg_polls, dut.u_sign.kappa);
                dump_sig(current_vec);
                dump_w(current_vec);
                sign_pass_cnt = sign_pass_cnt + 1;
            end

            $display("");

        end

                $display("==============================================");
        $display("Sign KAT Summary");
        $display("==============================================");
        $display("  Total vectors: %0d", `NUM_SIGN_VECTORS);
        $display("  Passed (sim completed): %0d", sign_pass_cnt);
        $display("  Failed: %0d", sign_fail_cnt);
        $display("");
        $display("Simulation finished at %t", $time);

        if (sign_fail_cnt > 0)
            $finish(1);
        else
            $finish;
    end

                initial begin
        #(1_500_000_000);
        $display("FATAL: Simulation timeout exceeded!");
        $finish(1);
    end

    endmodule
