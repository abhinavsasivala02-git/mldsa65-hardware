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
    `include "mldsa65_sign_vectors.vh"

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
    // Tasks
    // =========================================================================
    task write_seed;
        input [255:0] seed;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1)
                wr(16'h0010 + i*4, seed[i*32 +: 32]);
        end
    endtask

    // Wait for keygen completion (status[1] = done_sticky, status[0] = busy)
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

    // Wait for sign completion (status[1] = done, status[2] = sig_valid)
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

    // Forward rho (pk_ram[0:31]) and key (sk_ram[32:63]) to sign registers
    task load_sign_keys;
        reg [31:0] word;
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1) begin
                rd(16'h0800 + i*4, word);       // pk rho bytes 4i..4i+3
                wr(16'h0030 + i*4, word);      // rho_reg[i]
            end
            for (i = 0; i < 8; i = i + 1) begin
                rd(16'h1020 + i*4, word);       // sk key bytes 32+4i..35+4i
                wr(16'h0050 + i*4, word);      // K_reg[i]
            end
        end
    endtask

    // Reference key RAM arrays (loaded from ref_pk_<i>.mem / ref_sk_<i>.mem)
    reg [7:0] ref_pk [0:1951];
    reg [7:0] ref_sk [0:4031];

    // Load standard KAT reference keys directly into pk_ram/sk_ram via AXI
    task load_ref_keys;
        input integer vec_idx;
        integer k;
        begin
            $sformat(fstr, "tb/ref_pk_%0d.mem", vec_idx);
            $readmemh(fstr, ref_pk);
            $sformat(fstr, "tb/ref_sk_%0d.mem", vec_idx);
            $readmemh(fstr, ref_sk);
            for (k = 0; k < 1952; k = k + 1)
                wr(16'h0800 + k, ref_pk[k]);
            for (k = 0; k < 4032; k = k + 1)
                wr(16'h1000 + k, ref_sk[k]);
        end
    endtask

    // Load rnd (256-bit) and mu (512-bit) into AXI registers
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
                wr(16'h00D0 + i*4, mu[i*32 +: 32]);       // mu[255:0]
            for (i = 0; i < 4; i = i + 1)
                wr(16'h00F0 + i*4, mu[256 + i*32 +: 32]); // mu[383:256]
            for (i = 0; i < 4; i = i + 1)
                wr(16'h0100 + i*4, mu[384 + i*32 +: 32]); // mu[511:384]
        end
    endtask

    // Dump sig_ram to sig_<i>.hex (828 32-bit LE words)
    integer dump_fd;
    reg [31:0] dump_word;
    integer dw_i;
    task dump_sig;
        input integer vec_idx;
        begin
            $sformat(fstr, "sig_%0d.hex", vec_idx);
            dump_fd = $fopen(fstr, "w");
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
            $sformat(fstr, "w_%0d.txt", vec_idx);
            fd = $fopen(fstr, "w");
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

    // =========================================================================
    // Test Statistics
    // =========================================================================
    integer sign_pass_cnt;
    integer sign_fail_cnt;
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

            // Forward rho/key and load rnd/mu
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

        // Final Report
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

    // =========================================================================
    // Timeout watchdog (1.5 s)
    // =========================================================================
    initial begin
        #(1_500_000_000);
        $display("FATAL: Simulation timeout exceeded!");
        $finish(1);
    end

    // =========================================================================
    // One-shot probe: dump y (SP_Y), y_hat (SP_YH), A[0][0] (SP_AT)
    // at first matrix-multiply
    // =========================================================================
    reg [7:0] mm_probe;
    initial begin
        mm_probe = 8'd0;
        wait (ARESETn);
        while (mm_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_sign.state == 7'd29 &&
                dut.u_sign.mat_i == 3'd0 &&
                dut.u_sign.mat_j == 3'd0) begin
                begin : mm_probe_dump
                    integer p_i;
                    integer p_j;
                    integer p_fd;
                    p_fd = $fopen("mm_inputs_0.txt", "w");
                    for (p_i = 0; p_i < 5; p_i = p_i + 1)
                        for (p_j = 0; p_j < 256; p_j = p_j + 1)
                            $fwrite(p_fd, "y_%0d_%0d %05x\n", p_i, p_j,
                                    dut.u_sign.spad[p_i*256 + p_j]);
                    for (p_i = 0; p_i < 5; p_i = p_i + 1)
                        for (p_j = 0; p_j < 256; p_j = p_j + 1)
                            $fwrite(p_fd, "yh_%0d_%0d %05x\n", p_i, p_j,
                                    dut.u_sign.spad[(5 + p_i)*256 + p_j]);
                    for (p_j = 0; p_j < 256; p_j = p_j + 1)
                        $fwrite(p_fd, "A_0_%0d %05x\n", p_j,
                                dut.u_sign.spad[40*256 + p_j]);
                    $fclose(p_fd);
                end
                mm_probe <= 8'd1;
            end
        end
    end

    // =========================================================================
    // One-shot probe: dump w1 (SP_W1) and w0 (SP_W0) the moment c_tilde
    // hashing starts (SG_CT_INIT), before anything can touch them
    // =========================================================================
    reg [7:0] ct_probe;
    reg [6:0] ct_prev_state;
    initial begin
        ct_probe = 8'd0;
        ct_prev_state = 7'd0;
        wait (ARESETn);
        while (ct_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_sign.state == 7'd33 && ct_prev_state != 7'd33) begin
                begin : ct_probe_dump
                    integer q_i;
                    integer q_j;
                    integer q_fd;
                    q_fd = $fopen("ct_inputs_0.txt", "w");
                    for (q_i = 0; q_i < 6; q_i = q_i + 1)
                        for (q_j = 0; q_j < 256; q_j = q_j + 1)
                            $fwrite(q_fd, "w1_%0d_%0d %05x\n", q_i, q_j,
                                    dut.u_sign.spad[(33 + q_i)*256 + q_j]);
                    for (q_i = 0; q_i < 6; q_i = q_i + 1)
                        for (q_j = 0; q_j < 256; q_j = q_j + 1)
                            $fwrite(q_fd, "w0_%0d_%0d %05x\n", q_i, q_j,
                                    dut.u_sign.spad[(27 + q_i)*256 + q_j]);
                    $fclose(q_fd);
                end
                ct_probe <= 8'd1;
            end
            ct_prev_state <= dut.u_sign.state;
        end
    end

    // =========================================================================
    // One-shot probe: capture decompose write stream for row 0 (SG_MM_DECOMP)
    // =========================================================================
    reg [7:0] dc_probe;
    initial begin
        dc_probe = 8'd0;
        wait (ARESETn);
        while (dc_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_sign.state == 7'd31 && dut.u_sign.mat_i == 3'd0) begin
                begin : dc_probe_dump
                    integer d_fd;
                    d_fd = $fopen("dc_trace.txt", "w");
                    while (dut.u_sign.state == 7'd31 && dut.u_sign.mat_i == 3'd0) begin
                        $fwrite(d_fd, "cc=%0d sub=%0d din=%05x r1=%05x r0=%05x wena=%b waddr=%04x wdat=%05x\n",
                                dut.u_sign.coeff_idx, dut.u_sign.sub,
                                dut.u_sign.dc_in, dut.u_sign.dc_r1, dut.u_sign.dc_r0,
                                dut.u_sign.sp_wr_en, dut.u_sign.sp_wr_addr, dut.u_sign.sp_wr_data);
                        @(posedge ACLK);
                    end
                    $fclose(d_fd);
                end
                dc_probe <= 8'd1;
            end
        end
    end

        // =========================================================================
    // One-shot probe: capture matmul accumulator (iNTT input) for row 0
    // at SG_MM_NEXT_J (mat_j==4) -> mm_acc_0.txt
    // =========================================================================
    reg [7:0] acc_probe;
    initial begin
        acc_probe = 8'd0;
        wait (ARESETn);
        while (acc_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_sign.state == 7'd30 && dut.u_sign.mat_j == 3'd4 && dut.u_sign.mat_i == 3'd0) begin
                begin : acc_probe_dump
                    integer a_fd;
                    integer q;
                    a_fd = $fopen("mm_acc_0.txt", "w");
                    for (q = 0; q < 256; q = q + 1) begin
                        $fwrite(a_fd, "acc_0_%d %05x\n", q, dut.u_sign.spad[(27)*256 + q]);
                    end
                    $fclose(a_fd);
                end
                acc_probe <= 8'd1;
            end
        end
    end

        // =========================================================================
    // One-shot probe: capture raw SHAKE-128 squeeze bytes for A[0][0]
    // (state SG_MM_EXPA_FEED=26, mat_i=0, mat_j=0) -> s128_raw_00.txt
    // =========================================================================
    reg [7:0] s128_probe;
    integer s128_cnt;
    integer s128_fd;
    initial begin
        s128_probe = 8'd0;
        s128_cnt = 0;
        wait (ARESETn);
        while (s128_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_sign.state == 7'd26 && dut.u_sign.mat_i == 3'd0 && dut.u_sign.mat_j == 3'd0) begin
                if (s128_cnt == 0) begin
                    $fclose(s128_fd);
                    s128_fd = $fopen("s128_raw_00.txt", "w");
                end
                s128_cnt = s128_cnt + 1;
                if (s128_cnt > 1) begin
                    $fwrite(s128_fd, "ph=%0d lane=%0d byte=%0d lidx=%0d b0=%02x b1=%02x b2=%02x\n",
                            dut.u_sign.rej_phase, dut.u_sign.lane_cnt, dut.u_sign.byte_in_lane,
                            dut.u_sign.s128_rd_lane_idx,
                            dut.u_sign.rej_b0, dut.u_sign.rej_b1, dut.u_sign.rej_b2);
                end
            end
        end
    end

    // =========================================================================
    // One-shot probe: dump SP_C, SP_Y, SP_S1H when c is fully built
    // (right after SG_SIB_BUILD completes, before NTT(c) overwrites) 
    // -> z_inputs_0.txt
    // =========================================================================
    reg [7:0] zp_probe;
    reg [6:0] zp_prev;
    initial begin
        zp_probe = 8'd0;
        zp_prev = 7'd0;
        wait (ARESETn);
        while (zp_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_sign.kappa == 16'd15 && dut.u_sign.state == 7'd8 &&
                dut.u_sign.ntt_src == 6'd39 && zp_prev != 7'd8) begin
                begin : zp_probe_dump
                    integer z_fd;
                    integer q;
                    z_fd = $fopen("z_inputs_0.txt", "w");
                    for (q = 0; q < 256; q = q + 1)
                        $fwrite(z_fd, "c_%0d %05x\n", q, dut.u_sign.spad[39*256 + q]);
                    for (q = 0; q < 136; q = q + 1)
                        $fwrite(z_fd, "b0_%0d %02x\n", q, dut.u_sign.spad[40*256 + q]);
                    for (q = 0; q < 136; q = q + 1)
                        $fwrite(z_fd, "b1_%0d %02x\n", q, dut.u_sign.spad[41*256 + q]);
                    for (q = 0; q < 256; q = q + 1)
                        $fwrite(z_fd, "s1_0_%0d %05x\n", q, dut.u_sign.spad[10*256 + q]);
                    for (q = 0; q < 256; q = q + 1)
                        $fwrite(z_fd, "s2_0_%0d %05x\n", q, dut.u_sign.spad[15*256 + q]);
                    for (q = 0; q < 256; q = q + 1)
                        $fwrite(z_fd, "t0_0_%0d %05x\n", q, dut.u_sign.spad[21*256 + q]);
                    for (q = 0; q < 256; q = q + 1)
                        $fwrite(z_fd, "w0_0_%0d %05x\n", q, dut.u_sign.spad[27*256 + q]);
                    for (q = 0; q < 256; q = q + 1)
                        $fwrite(z_fd, "y_0_%0d %05x\n", q, dut.u_sign.spad[0*256 + q]);
                    $fclose(z_fd);
                end
                zp_probe <= 8'd1;
            end
            zp_prev <= dut.u_sign.state;
        end
    end

    // =========================================================================
    // One-shot probe: dump final w0 (r0) + w1 at SG_HINTS start (kappa 15)
    // -> h_inputs_0.txt
    // =========================================================================
    reg [7:0] hp_probe;
    reg [6:0] hp_prev;
    initial begin
        hp_probe = 8'd0;
        hp_prev = 7'd0;
        wait (ARESETn);
        while (hp_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_sign.kappa == 16'd15 && dut.u_sign.state == 7'd58 &&
                hp_prev != 7'd58) begin
                begin : hp_probe_dump
                    integer h_fd;
                    integer q;
                    h_fd = $fopen("h_inputs_0.txt", "w");
                    for (q = 0; q < 256; q = q + 1)
                        $fwrite(h_fd, "w0_0_%0d %05x\n", q, dut.u_sign.spad[27*256 + q]);
                    for (q = 0; q < 256; q = q + 1)
                        $fwrite(h_fd, "w1_0_%0d %05x\n", q, dut.u_sign.spad[33*256 + q]);
                    $fclose(h_fd);
                end
                hp_probe <= 8'd1;
            end
            hp_prev <= dut.u_sign.state;
        end
    end

    // =========================================================================
    // One-shot probe: dump raw t0 right before its NTT (state 8, ntt_src=SP_T0H)
    // -> t0_raw_0.txt
    // =========================================================================
    reg [7:0] tp_probe;
    reg [6:0] tp_prev;
    initial begin
        tp_probe = 8'd0;
        tp_prev = 7'd0;
        wait (ARESETn);
        while (tp_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_sign.state == 7'd8 &&
                dut.u_sign.ntt_src == 6'd21 && tp_prev != 7'd8) begin
                begin : tp_probe_dump
                    integer t_fd;
                    integer q;
                    t_fd = $fopen("t0_raw_0.txt", "w");
                    for (q = 0; q < 256; q = q + 1)
                        $fwrite(t_fd, "t0raw_0_%0d %05x\n", q, dut.u_sign.spad[21*256 + q]);
                    $fclose(t_fd);
                end
                tp_probe <= 8'd1;
            end
            tp_prev <= dut.u_sign.state;
        end
    end

        // =========================================================================
    // One-shot probe: capture c_tilde SHAKE-256 absorb lanes + squeeze
    // (states SG_CT_MU=34, SG_CT_W1=35, SG_CT_PERM=36, SG_CT_PERMW=37,
    //  SG_CT_PAD=38, SG_CT_PADW=39, SG_CT_SQZ=40) -> ct_absorb_0.txt
    // =========================================================================
    reg [7:0] cta_probe;
    reg [6:0] cta_prev;
    integer ct_cnt;
    integer ct_fd;
    initial begin
        cta_probe = 8'd0;
        cta_prev = 7'd0;
        ct_cnt = 0;
        wait (ARESETn);
        while (cta_probe < 8'd2) begin
            @(posedge ACLK);
            // trigger at start of SG_CT_MU (34) for the ACCEPTED attempt (kappa==15)
            if (cta_probe == 8'd0 && dut.u_sign.state == 7'd34 &&
                dut.u_sign.kappa == 16'd15) begin
                ct_fd = $fopen("ct_absorb_0.txt", "w");
                cta_probe <= 8'd1;
            end
            if (cta_probe == 8'd1 &&
                (dut.u_sign.state == 7'd34 || dut.u_sign.state == 7'd35 ||
                 dut.u_sign.state == 7'd36 || dut.u_sign.state == 7'd37 ||
                 dut.u_sign.state == 7'd38 || dut.u_sign.state == 7'd39 ||
                 dut.u_sign.state == 7'd40)) begin
                $fwrite(ct_fd, "st=%0d sub=%0d wena=%b widx=%0d wdat=%016x perm=%b",
                        dut.u_sign.state, dut.u_sign.sub, dut.u_sign.shake_wr_en,
                        dut.u_sign.shake_wr_lane_idx, dut.u_sign.shake_wr_lane_data,
                        dut.u_sign.shake_permute);
                if (dut.u_sign.state == 7'd35) begin
                    $fwrite(ct_fd, " p=%0d pr=%0d ev=%03x od=%03x cb=%016x bi=%0d a=%0d a2=%0d d=%05x d2=%05x\n",
                            dut.u_sign.ct_pair, dut.u_sign.ct_poly,
                            dut.u_sign.ct_even, dut.u_sign.ct_odd,
                            dut.u_sign.ct_buf, dut.u_sign.ct_byte_in_lane,
                            dut.u_sign.sp_rd_addr, dut.u_sign.sp_rd2_addr,
                            dut.u_sign.sp_rd_data, dut.u_sign.sp_rd2_data);
                end else if (dut.u_sign.state == 7'd40) begin
                    $fwrite(ct_fd, " ridx=%0d rdat=%016x\n",
                            dut.u_sign.shake_rd_lane_idx, dut.u_sign.shake_rd_lane_data);
                end else begin
                    $fwrite(ct_fd, "\n");
                end
            end
            if (cta_probe == 8'd1 && cta_prev >= 7'd34 && cta_prev <= 7'd40 &&
                (dut.u_sign.state < 7'd34 || dut.u_sign.state > 7'd40)) begin
                cta_probe <= 8'd2;
            end
            cta_prev <= dut.u_sign.state;
        end
        $fclose(ct_fd);
    end

    endmodule
