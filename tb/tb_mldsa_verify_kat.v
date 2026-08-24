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

module tb_mldsa_verify_kat;

        reg ACLK = 0;
    reg ARESETn = 0;
    always #5 ACLK = ~ACLK;

        reg  [15:0] wr_addr;  reg wr_en; reg [31:0] wr_data;
    reg  [15:0] rd_addr;  reg rd_en;
    wire [31:0] dut_rd_data;

    mldsa_top dut (
        .clk(ACLK), .rst_n(ARESETn),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(dut_rd_data)
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

                reg verify_ok;
    integer vf_polls;
    task wait_verify_done;
        reg [31:0] status;
        begin
            vf_polls = 0;
            verify_ok = 1'b0;
            status = 32'd0;
            while (!(status[1]) && vf_polls < 4000000) begin
                rd(16'h0004, status);
                vf_polls = vf_polls + 1;
            end
            verify_ok = status[1] && status[2];
        end
    endtask

                reg [7:0] ref_pk  [0:1951];
    reg [7:0] ref_sig [0:3308];
    reg [7:0] ref_mu  [0:63];
    reg [7:0] ref_rho [0:31];

                task load_vec;
        input integer vec_idx;
        integer k;
        begin
            $readmemh($sformatf("tb/ref_vf_pk_%0d.mem",  vec_idx), ref_pk);
            $readmemh($sformatf("tb/ref_vf_sig_%0d.mem", vec_idx), ref_sig);
            $readmemh($sformatf("tb/ref_vf_mu_%0d.mem",  vec_idx), ref_mu);
            $readmemh($sformatf("tb/ref_vf_rho_%0d.mem", vec_idx), ref_rho);

            // pk -> pk_ram @0x0800 (byte)
            for (k = 0; k < 1952; k = k + 1)
                wr(16'h0800 + k, {24'h0, ref_pk[k]});
            // rho -> rho_reg @0x0030 (4 bytes per word)
            for (k = 0; k < 8; k = k + 1)
                wr(16'h0030 + k*4,
                          {ref_rho[4*k+3], ref_rho[4*k+2], ref_rho[4*k+1], ref_rho[4*k+0]});
            // mu -> mu_lo_reg @0x00D0, mu_hi_reg @0x00F0 / 0x0100
            for (k = 0; k < 8; k = k + 1)
                wr(16'h00D0 + k*4,
                          {ref_mu[4*k+3], ref_mu[4*k+2], ref_mu[4*k+1], ref_mu[4*k+0]});
            for (k = 0; k < 4; k = k + 1)
                wr(16'h00F0 + k*4,
                          {ref_mu[32+4*k+3], ref_mu[32+4*k+2], ref_mu[32+4*k+1], ref_mu[32+4*k+0]});
            for (k = 0; k < 4; k = k + 1)
                wr(16'h0100 + k*4,
                          {ref_mu[48+4*k+3], ref_mu[48+4*k+2], ref_mu[48+4*k+1], ref_mu[48+4*k+0]});
        end
    endtask

        // Load signature into sig_ram @0x3000 (byte), optionally tamper one byte
        task load_sig;
        input integer vec_idx;
        input integer tamper_byte;
        input [7:0] tamper_val;
        integer k;
        begin
            for (k = 0; k < 3309; k = k + 1) begin
                if (k == tamper_byte)
                    wr(16'h3000 + k, {24'h0, tamper_val});
                else
                    wr(16'h3000 + k, {24'h0, ref_sig[k]});
            end
        end
    endtask

                integer current_vec;
    integer pass_cnt, fail_cnt;
    integer t;
    reg [31:0] status;

    initial begin
        pass_cnt = 0; fail_cnt = 0;

                ARESETn = 1'b0;
        wr_en = 1'b0; wr_addr = 16'd0; wr_data = 32'd0;
        rd_en = 1'b0; rd_addr = 16'd0;
        repeat (10) @(posedge ACLK);
        ARESETn = 1'b1;
        repeat (5) @(posedge ACLK);

        $display("==============================================");
        $display("ML-DSA-65 Verify Known Answer Test (KAT)");
        $display("==============================================");

        for (current_vec = 0; current_vec < 5; current_vec = current_vec + 1) begin
            $display("----------------------------------------------");
            $display("KAT Vector %0d", current_vec);
            $display("----------------------------------------------");

                        load_vec(current_vec);

                        load_sig(current_vec, -1, 8'h00);
            $display("  [vec %0d] Loading valid signature...", current_vec);
            wr(16'h0000, 32'h0000_0004);               wait_verify_done;
            if (verify_ok) begin
                $display("  [vec %0d] VALID sig -> verify: PASS (valid=%b, %0d polls)",
                         current_vec, verify_ok, vf_polls);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  [vec %0d] VALID sig -> verify: FAIL (valid=%b, %0d polls)",
                         current_vec, verify_ok, vf_polls);
                fail_cnt = fail_cnt + 1;
            end

                        load_sig(current_vec, 100, ref_sig[100] ^ 8'h01);
            $display("  [vec %0d] Loading tampered signature (z byte 100)...", current_vec);
            wr(16'h0000, 32'h0000_0004);               wait_verify_done;
            if (!verify_ok) begin
                $display("  [vec %0d] TAMPERED sig -> verify: PASS (rejected, valid=%b)",
                         current_vec, verify_ok);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  [vec %0d] TAMPERED sig -> verify: FAIL (wrongly accepted, valid=%b)",
                         current_vec, verify_ok);
                fail_cnt = fail_cnt + 1;
            end

                        load_sig(current_vec, 700, ref_sig[700] ^ 8'h01);
            $display("  [vec %0d] Loading tampered signature (z byte 700, poly1)...", current_vec);
            wr(16'h0000, 32'h0000_0004);               wait_verify_done;
            if (!verify_ok) begin
                $display("  [vec %0d] TAMPERED poly1 -> verify: PASS (rejected, valid=%b)",
                         current_vec, verify_ok);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  [vec %0d] TAMPERED poly1 -> verify: FAIL (wrongly accepted, valid=%b)",
                         current_vec, verify_ok);
                fail_cnt = fail_cnt + 1;
            end
        end

        $display("==============================================");
        $display("KAT Summary");
        $display("==============================================");
        $display("  Passed: %0d", pass_cnt);
        $display("  Failed: %0d", fail_cnt);
        if (fail_cnt == 0)
            $display("All Verify KAT vectors PASSED!");
        else
            $display("SOME VERIFY KAT VECTORS FAILED");

        #1000;
        $finish;
    end

endmodule
