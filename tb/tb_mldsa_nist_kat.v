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

module tb_mldsa_nist_kat;
    reg [8*80:1] fstr;   // $sformat scratch (Verilog-2001)

    reg ACLK = 0;
    reg ARESETn = 0;
    always #5 ACLK = ~ACLK;

    `include "nist_vectors.vh"

    // Run a slice of the 100 NIST vectors (set via -testplusarg NIST_START/NIST_END,
    // defaults to full range). Chunked runs keep each xsim session short enough
    // to avoid the xsim long-run kernel crash.
    integer nist_start;
    integer nist_end;
    initial begin
        nist_start = 0;
        nist_end   = `NIST_NUM_VECTORS - 1;
        if ($value$plusargs("NIST_START=%d", nist_start)) ;
        if ($value$plusargs("NIST_END=%d", nist_end)) ;
    end

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
    // Native write / read tasks
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
    // Wait for a controller done
    // =========================================================================
    integer polls;
    task wait_done;
        output ok;
        reg [31:0] status;
        begin
            polls  = 0;
            status = 32'd0;
            ok     = 1'b0;
            while (!(status[1]) && polls < 30000000) begin
                rd(16'h0004, status);
                polls = polls + 1;
            end
            ok = status[1];
        end
    endtask

    // Load a .mem file into a RAM/register window via native port
    task load_mem_bytes;
        input integer base;
        input integer nbytes;
        input [1023:0] mem;
        integer k;
        begin
            for (k = 0; k < nbytes; k = k + 1)
                wr(base + k, {24'h0, mem[k]});
        end
    endtask

    // 256-bit load into register base (low word first)
    task load_256;
        input [15:0] base;
        input [255:0] val;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1)
                wr(base + i*4, val[i*32 +: 32]);
        end
    endtask

    // 512-bit mu load
    task load_mu;
        input [511:0] mu;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1)
                wr(16'h00D0 + i*4, mu[i*32 +: 32]);
            for (i = 0; i < 4; i = i + 1)
                wr(16'h00F0 + i*4, mu[256 + i*32 +: 32]);
            for (i = 0; i < 4; i = i + 1)
                wr(16'h0100 + i*4, mu[384 + i*32 +: 32]);
        end
    endtask

    // Copy 256-bit from RAM byte window into register base
    task copy_256;
        input [15:0] src_base;
        input [15:0] dst_base;
        integer i;
        reg [31:0] w;
        begin
            for (i = 0; i < 8; i = i + 1) begin
                rd(src_base + i*4, w);
                wr(dst_base + i*4, w);
            end
        end
    endtask

    // =========================================================================
    // Per-case arrays
    // =========================================================================
    reg [7:0] ref_xi  [0:31];
    reg [7:0] ref_pk  [0:1951];
    reg [7:0] ref_sk  [0:4031];
    reg [7:0] ref_rnd [0:31];
    reg [7:0] ref_mu  [0:63];
    reg [7:0] ref_sig [0:3308];

    // =========================================================================
    // Load NIST vector <i> from tb/nist/<i>/*.mem
    // =========================================================================
    task load_nist_vec;
        input integer i;
        integer k;
        begin
            $sformat(fstr, "tb/nist/%0d/xi_%0d.mem", i, i);
            $readmemh(fstr, ref_xi);
            $sformat(fstr, "tb/nist/%0d/pk_%0d.mem", i, i);
            $readmemh(fstr, ref_pk);
            $sformat(fstr, "tb/nist/%0d/sk_%0d.mem", i, i);
            $readmemh(fstr, ref_sk);
            $sformat(fstr, "tb/nist/%0d/rnd_%0d.mem", i, i);
            $readmemh(fstr, ref_rnd);
            $sformat(fstr, "tb/nist/%0d/mu_%0d.mem", i, i);
            $readmemh(fstr, ref_mu);
            $sformat(fstr, "tb/nist/%0d/sig_%0d.mem", i, i);
            $readmemh(fstr, ref_sig);
        end
    endtask

    // =========================================================================
    // Compare a RAM region against a reference array
    // =========================================================================
    integer cmp_bad;
    task check_ram;
        input integer base;
        input integer nbytes;
        input integer rfile; // 0=pk,1=sk,2=sig
        input is_bad;       // unused placeholder
        integer k;
        reg [31:0] w;
        begin
            cmp_bad = 0;
            for (k = 0; k < nbytes; k = k + 1) begin
                // rd reads a 4-byte LE word at a 4-aligned address; extract byte k.
                rd((base + (k & ~3)), w);
                if (w[(k & 3)*8 +: 8] !==
                    (rfile==0 ? ref_pk[k] : rfile==1 ? ref_sk[k] : ref_sig[k])) begin
                    cmp_bad = cmp_bad + 1;
                    if (cmp_bad <= 3)
                        $display("    mismatch byte %0d: got %02x exp %02x",
                                 k, w[(k & 3)*8 +: 8],
                                 (rfile==0 ? ref_pk[k] : rfile==1 ? ref_sk[k] : ref_sig[k]));
                end
            end
        end
    endtask

    // =========================================================================
    // Statistics
    // =========================================================================
    integer pass_cnt, fail_cnt;
    integer n;
    reg ok;

    // =========================================================================
    // Main
    // =========================================================================
    initial begin
        pass_cnt = 0; fail_cnt = 0;

        ARESETn = 1'b0;
        wr_en = 1'b0; wr_addr = 16'd0; wr_data = 32'd0;
        rd_en = 1'b0; rd_addr = 16'd0;
        repeat (10) @(posedge ACLK);
        ARESETn = 1'b1;
        repeat (5) @(posedge ACLK);

        $display("==============================================");
        $display("ML-DSA-65 NIST End-to-End KAT (vectors %0d..%0d)",
                 nist_start, nist_end);
        $display("==============================================");

        for (n = nist_start; n <= nist_end; n = n + 1) begin : vec_loop
            load_nist_vec(n);
            if ((n % 10) == 0)
                $display("-- NIST vector %0d --", n);

            // 1. KEYGEN from xi
            load_256(16'h0010, {ref_xi[0],ref_xi[1],ref_xi[2],ref_xi[3],
                                ref_xi[4],ref_xi[5],ref_xi[6],ref_xi[7],
                                ref_xi[8],ref_xi[9],ref_xi[10],ref_xi[11],
                                ref_xi[12],ref_xi[13],ref_xi[14],ref_xi[15],
                                ref_xi[16],ref_xi[17],ref_xi[18],ref_xi[19],
                                ref_xi[20],ref_xi[21],ref_xi[22],ref_xi[23],
                                ref_xi[24],ref_xi[25],ref_xi[26],ref_xi[27],
                                ref_xi[28],ref_xi[29],ref_xi[30],ref_xi[31]});
            wr(16'h0000, 32'h0000_0001);
            wait_done(ok);
            if (!ok) begin
                $display("  nist %0d: KEYGEN TIMEOUT", n);
                fail_cnt = fail_cnt + 1;
                disable vec_loop;
            end
            check_ram(16'h0800, 1952, 0, 0);
            if (cmp_bad) begin
                $display("  nist %0d: PK MISMATCH (%0d bytes)", n, cmp_bad);
                fail_cnt = fail_cnt + 1;
                disable vec_loop;
            end
            check_ram(16'h1000, 4032, 1, 0);
            if (cmp_bad) begin
                $display("  nist %0d: SK MISMATCH (%0d bytes)", n, cmp_bad);
                fail_cnt = fail_cnt + 1;
                disable vec_loop;
            end

            // 2. sign registers + rnd/mu
            copy_256(16'h0800, 16'h0030);   // rho
            copy_256(16'h1020, 16'h0050);   // K
            copy_256(16'h1040, 16'h0070);   // tr
            load_256(16'h0090, {ref_rnd[0],ref_rnd[1],ref_rnd[2],ref_rnd[3],
                                ref_rnd[4],ref_rnd[5],ref_rnd[6],ref_rnd[7],
                                ref_rnd[8],ref_rnd[9],ref_rnd[10],ref_rnd[11],
                                ref_rnd[12],ref_rnd[13],ref_rnd[14],ref_rnd[15],
                                ref_rnd[16],ref_rnd[17],ref_rnd[18],ref_rnd[19],
                                ref_rnd[20],ref_rnd[21],ref_rnd[22],ref_rnd[23],
                                ref_rnd[24],ref_rnd[25],ref_rnd[26],ref_rnd[27],
                                ref_rnd[28],ref_rnd[29],ref_rnd[30],ref_rnd[31]});
            load_mu({ref_mu[0],ref_mu[1],ref_mu[2],ref_mu[3],ref_mu[4],ref_mu[5],
                     ref_mu[6],ref_mu[7],ref_mu[8],ref_mu[9],ref_mu[10],ref_mu[11],
                     ref_mu[12],ref_mu[13],ref_mu[14],ref_mu[15],ref_mu[16],ref_mu[17],
                     ref_mu[18],ref_mu[19],ref_mu[20],ref_mu[21],ref_mu[22],ref_mu[23],
                     ref_mu[24],ref_mu[25],ref_mu[26],ref_mu[27],ref_mu[28],ref_mu[29],
                     ref_mu[30],ref_mu[31],ref_mu[32],ref_mu[33],ref_mu[34],ref_mu[35],
                     ref_mu[36],ref_mu[37],ref_mu[38],ref_mu[39],ref_mu[40],ref_mu[41],
                     ref_mu[42],ref_mu[43],ref_mu[44],ref_mu[45],ref_mu[46],ref_mu[47],
                     ref_mu[48],ref_mu[49],ref_mu[50],ref_mu[51],ref_mu[52],ref_mu[53],
                     ref_mu[54],ref_mu[55],ref_mu[56],ref_mu[57],ref_mu[58],ref_mu[59],
                     ref_mu[60],ref_mu[61],ref_mu[62],ref_mu[63]});

            wr(16'h0000, 32'h0000_0002);   // start_sign
            wait_done(ok);
            if (!ok) begin
                $display("  nist %0d: SIGN TIMEOUT (kappa=%0d)", n, dut.u_sign.kappa);
                fail_cnt = fail_cnt + 1;
                disable vec_loop;
            end

            // 3. VERIFY (generated pk + generated sig)
            wr(16'h0000, 32'h0000_0004);   // start_verify
            wait_done(ok);
            ok = ok && (dut.u_verify.c_tilde_comp == dut.u_verify.c_tilde_cap);

            if (ok) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  nist %0d: VERIFY FAIL (comp!=cap)", n);
                fail_cnt = fail_cnt + 1;
            end
        end

        $display("==============================================");
        $display("NIST End-to-End KAT Summary");
        $display("==============================================");
        $display("  Passed: %0d", pass_cnt);
        $display("  Failed: %0d", fail_cnt);
        if (fail_cnt == 0)
            $display("All %0d NIST vectors PASSED! (%0d..%0d)", pass_cnt, nist_start, nist_end);
        else
            $display("SOME NIST VECTORS FAILED");
        begin : res_append
            integer res_fd;
            res_fd = $fopen("nist_results.txt", "a");
            $fwrite(res_fd, "vectors %0d..%0d: %0d passed, %0d failed\n",
                    nist_start, nist_end, pass_cnt, fail_cnt);
            $fclose(res_fd);
        end
        $finish;
    end

    // Watchdog: must be < 2^31 ns in xsim (truncates larger literals).
    // ~2 s covers a small slice (each vector ~130 ms sim time).
    initial begin
        #(2_000_000_000);
        $display("FATAL: Simulation timeout exceeded!");
        $finish(1);
    end

endmodule
