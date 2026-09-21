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
    reg [8*80:1] fstr;   // $sformat scratch (Verilog-2001)
    integer current_vec;
    integer pass_cnt, fail_cnt;

    // Clock / reset
    reg ACLK = 0;
    reg ARESETn = 0;
    always #5 ACLK = ~ACLK;

    // Native parallel interface (replaces AXI4-Lite)
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
    // Native read task (rd_data valid 1 cycle after rd_en)
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
    // Wait for verify done
    // =========================================================================
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

    // =========================================================================
    // Reference arrays
    // =========================================================================
    reg [7:0] ref_pk  [0:1951];
    reg [7:0] ref_sig [0:3308];
    reg [7:0] ref_mu  [0:63];
    reg [7:0] ref_rho [0:31];

    // =========================================================================
    // Load reference arrays and AXI config
    // =========================================================================
    task load_vec;
        input integer vec_idx;
        integer k;
        begin
            $sformat(fstr, "tb/ref_vf_pk_%0d.mem",  vec_idx);
            $readmemh(fstr, ref_pk);
            $sformat(fstr, "tb/ref_vf_sig_%0d.mem", vec_idx);
            $readmemh(fstr, ref_sig);
            $sformat(fstr, "tb/ref_vf_mu_%0d.mem",  vec_idx);
            $readmemh(fstr, ref_mu);
            $sformat(fstr, "tb/ref_vf_rho_%0d.mem", vec_idx);
            $readmemh(fstr, ref_rho);

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

    // =========================================================================
    // Load signature into sig_ram @0x3000 (byte), optionally tamper one byte
    // =========================================================================
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

    // Load the signature with one hint byte corrupted and require a reject.
    task check_bad_hint;
        input [8*24:1] label;
        input integer  bad_byte;
        input [7:0]    bad_val;
        begin
            load_sig(current_vec, bad_byte, bad_val);
            wr(16'h0000, 32'h0000_0004);   // start_verify
            wait_verify_done;
            if (!verify_ok) begin
                $display("  [vec %0d] BAD HINT (%0s) -> verify: PASS (rejected)",
                         current_vec, label);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  [vec %0d] BAD HINT (%0s) -> verify: FAIL (wrongly accepted)",
                         current_vec, label);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // =========================================================================
    // Probe: dump raw c (SP_C) when NTT(c) load starts (state 4, ntt_src=SP_C)
    // =========================================================================
    reg [7:0] cr_probe;
    reg [6:0] cr_prev;
    initial begin
        cr_probe = 8'd0;
        cr_prev = 7'd0;
        wait (ARESETn);
        while (cr_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd4 && dut.u_verify.ntt_src == 6'd5 &&
                cr_prev != 7'd4) begin
                begin : cr_dump
                    integer cr_fd;
                    integer q;
                    cr_fd = $fopen("vf_c_raw_0.txt", "w");
                    for (q = 0; q < 256; q = q + 1)
                        $fwrite(cr_fd, "c_%0d %05x\n", q, dut.u_verify.spad[5*256 + q]);
                    for (q = 0; q < 136; q = q + 1)
                        $fwrite(cr_fd, "b0_%0d %02x\n", q, dut.u_verify.spad[9*256 + q]);
                    for (q = 0; q < 136; q = q + 1)
                        $fwrite(cr_fd, "b1_%0d %02x\n", q, dut.u_verify.spad[10*256 + q]);
                    $fclose(cr_fd);
                end
                cr_probe <= 8'd1;
            end
            cr_prev <= dut.u_verify.state;
        end
    end

    // =========================================================================
    // Probe: dump w (SP_W) at VF_USEHINT entry for row 0 (state 33, mat_i=0)
    // =========================================================================
    reg [7:0] wp_probe;
    reg [6:0] wp_prev;
    initial begin
        wp_probe = 8'd0;
        wp_prev = 7'd0;
        wait (ARESETn);
        while (wp_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd33 && dut.u_verify.mat_i == 3'd0 &&
                wp_prev != 7'd33) begin
                begin : wp_dump
                    integer w_fd;
                    integer q;
                    w_fd = $fopen("vf_w_0.txt", "w");
                    for (q = 0; q < 256; q = q + 1)
                        $fwrite(w_fd, "w_%0d %05x\n", q, dut.u_verify.spad[6*256 + q]);
                    $fclose(w_fd);
                end
                wp_probe <= 8'd1;
            end
            wp_prev <= dut.u_verify.state;
        end
    end

    // =========================================================================
    // Probe: capture w1' absorb lanes during VF_USEHINT (first 32 writes)
    // =========================================================================
    integer wc_cnt;
    integer wc_fd;
    initial begin
        wc_cnt = 0;
        wait (ARESETn);
        while (wc_cnt < 200) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd33 && dut.u_verify.shake_wr_en) begin
                wc_fd = $fopen("vf_w1_absorb.txt", "a");
                $fwrite(wc_fd, "mi=%0d zc=%0d bc=%0d lane=%0d data=%016x\n",
                        dut.u_verify.mat_i, dut.u_verify.z_cnt,
                        dut.u_verify.w1_byte_cnt, dut.u_verify.shake_wr_lane_idx,
                        dut.u_verify.shake_wr_lane_data);
                $fclose(wc_fd);
                wc_cnt = wc_cnt + 1;
            end
        end
    end

    // =========================================================================
    // Probe: capture ALL SHAKE-256 absorb writes (mu + w1') for first vector
    // =========================================================================
    integer sa_cnt;
    integer sa_fd;
    reg sa_armed;
    initial begin
        sa_cnt = 0;
        sa_armed = 1'b0;
        wait (ARESETn);
        while (sa_cnt < 115) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd15) sa_armed = 1'b1;   // mu absorb
            if (sa_armed && dut.u_verify.shake_wr_en) begin
                sa_fd = $fopen("vf_shake_abs.txt", "a");
                $fwrite(sa_fd, "st=%0d lane=%0d perm=%b data=%016x\n",
                        dut.u_verify.state, dut.u_verify.shake_wr_lane_idx,
                        dut.u_verify.shake_permute, dut.u_verify.shake_wr_lane_data);
                $fclose(sa_fd);
                sa_cnt = sa_cnt + 1;
            end
        end
    end

    // =========================================================================
    // Probe: dump w (SP_W) at VF_USEHINT entry for row 1 (state 33, mat_i=1)
    // =========================================================================
    reg [7:0] wp1_probe;
    reg [6:0] wp1_prev;
    initial begin
        wp1_probe = 8'd0;
        wp1_prev = 7'd0;
        wait (ARESETn);
        while (wp1_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd33 && dut.u_verify.mat_i == 3'd1 &&
                wp1_prev != 7'd33) begin
                begin : wp1_dump
                    integer w1_fd;
                    integer q;
                    w1_fd = $fopen("vf_w_1.txt", "w");
                    for (q = 0; q < 256; q = q + 1)
                        $fwrite(w1_fd, "w_%0d %05x\n", q, dut.u_verify.spad[6*256 + q]);
                    $fclose(w1_fd);
                end
                wp1_probe <= 8'd1;
            end
            wp1_prev <= dut.u_verify.state;
        end
    end

    // =========================================================================
    // Probe: dump SP_W (all 6 rows) at VF_HASH_INIT entry (state 14)
    // =========================================================================
    reg [7:0] wp2_probe;
    initial begin
        wp2_probe = 8'd0;
        wait (ARESETn);
        while (wp2_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd14 && wp2_probe == 8'd0) begin
                begin : wp2_dump
                    integer w2_fd;
                    integer q;
                    w2_fd = $fopen("vf_w_all.txt", "w");
                    for (q = 0; q < 6*256; q = q + 1)
                        $fwrite(w2_fd, "w_%0d_%0d %05x\n", q/256, q%256,
                                dut.u_verify.spad[(6 + q/256)*256 + q%256]);
                    $fclose(w2_fd);
                end
                wp2_probe <= 8'd1;
            end
        end
    end

    // =========================================================================
    // Probe: dump SP_Z at VF_SIB_INIT entry (state 7) - after z NTT
    // =========================================================================
    reg [7:0] zp2_probe;
    initial begin
        zp2_probe = 8'd0;
        wait (ARESETn);
        while (zp2_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd7 && zp2_probe == 8'd0) begin
                begin : zp2_dump
                    integer z2_fd;
                    integer q;
                    z2_fd = $fopen("vf_z_hat.txt", "w");
                    for (q = 0; q < 5*256; q = q + 1)
                        $fwrite(z2_fd, "z_%0d_%0d %05x\n", q/256, q%256,
                                dut.u_verify.spad[(q/256)*256 + q%256]);
                    $fclose(z2_fd);
                end
                zp2_probe <= 8'd1;
            end
        end
    end

    // =========================================================================
    // Probe: dump SP_A (ExpandA output) + SP_Z at VF_PMUL_ACC entry (state 21)
    // =========================================================================
    reg [7:0] ap_probe;
    reg [6:0] ap_prev;
    initial begin
        ap_probe = 8'd0;
        ap_prev = 7'd0;
        wait (ARESETn);
        while (ap_probe < 8'd2) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd21 && ap_prev != 7'd21 &&
                dut.u_verify.mat_j == 3'd0) begin
                begin : ap_dump
                    integer a_fd;
                    integer q;
                    $sformat(fstr, "vf_a_%0d.txt", ap_probe);
                    a_fd = $fopen(fstr, "w");
                    for (q = 0; q < 256; q = q + 1)
                        $fwrite(a_fd, "a_%0d %05x\n", q, dut.u_verify.spad[12*256 + q]);
                    $fclose(a_fd);
                end
                ap_probe <= ap_probe + 8'd1;
            end
            ap_prev <= dut.u_verify.state;
        end
    end

    // =========================================================================
    // Probe: trace ExpandA store (state 20/21) sp_wr
    // =========================================================================
    integer ap_cnt;
    integer ap_fd;
    initial begin
        ap_cnt = 0;
        wait (ARESETn);
        while (ap_cnt < 40) begin
            @(posedge ACLK);
            if ((dut.u_verify.state == 7'd20 || dut.u_verify.state == 7'd21) &&
                dut.u_verify.sp_wr_en && dut.u_verify.mat_i == 3'd0) begin
                ap_fd = $fopen("vf_a_trace.txt", "a");
                $fwrite(ap_fd, "st=%0d cc=%0d addr=%0d data=%05x cand=%05x\n",
                        dut.u_verify.state, dut.u_verify.coeff_cnt,
                        dut.u_verify.sp_wr_addr, dut.u_verify.sp_wr_data,
                        dut.u_verify.rej_candidate);
                $fclose(ap_fd);
                ap_cnt = ap_cnt + 1;
            end
        end
    end

    // =========================================================================
    // Probe: dump SP_W row 0 at VF_NTT_LD entry (state 4) for INTT (ntt_src=SP_W)
    // =========================================================================
    reg [7:0] wp3_probe;
    initial begin
        wp3_probe = 8'd0;
        wait (ARESETn);
        while (wp3_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd4 && dut.u_verify.ntt_src == 6'd6 &&
                wp3_probe == 8'd0) begin
                begin : wp3_dump
                    integer w3_fd;
                    integer q;
                    w3_fd = $fopen("vf_w_mm.txt", "w");
                    for (q = 0; q < 256; q = q + 1)
                        $fwrite(w3_fd, "w_%0d %05x\n", q, dut.u_verify.spad[6*256 + q]);
                    $fclose(w3_fd);
                end
                wp3_probe <= 8'd1;
            end
        end
    end

    // =========================================================================
    // Probe: dump SP_W row 0 at VF_T1_UNPACK entry (state 26) - after INTT(w)
    // =========================================================================
    reg [7:0] wp4_probe;
    initial begin
        wp4_probe = 8'd0;
        wait (ARESETn);
        while (wp4_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd26 && dut.u_verify.mat_i == 3'd0 &&
                wp4_probe == 8'd0) begin
                begin : wp4_dump
                    integer w4_fd;
                    integer q;
                    w4_fd = $fopen("vf_w_intt.txt", "w");
                    for (q = 0; q < 256; q = q + 1)
                        $fwrite(w4_fd, "w_%0d %05x\n", q, dut.u_verify.spad[6*256 + q]);
                    $fclose(w4_fd);
                end
                wp4_probe <= 8'd1;
            end
        end
    end

    // =========================================================================
    // Probe: dump ntt_ext SRAM after INTT(ct1) at VF_W_SUB-equivalent
    // (state 30 = VF_INTT_CT1_ST) - read via ntt_ext_dout by addr
    // =========================================================================
    reg [7:0] cp_probe;
    initial begin
        cp_probe = 8'd0;
        wait (ARESETn);
        while (cp_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd30 && dut.u_verify.coeff_cnt == 9'd257 &&
                cp_probe == 8'd0) begin
                begin : cp_dump
                    integer c_fd;
                    integer q;
                    c_fd = $fopen("vf_ct1.txt", "w");
                    for (q = 0; q < 256; q = q + 1)
                        $fwrite(c_fd, "ct1_%0d %05x\n", q, dut.u_verify.ntt_ext_dout);
                    $fclose(c_fd);
                end
                cp_probe <= 8'd1;
            end
        end
    end

    // =========================================================================
    // Probe: dump SP_T1 at VF_CT1_PMUL entry (state 27) - after NTT(t1)
    // =========================================================================
    reg [7:0] tp2_probe;
    initial begin
        tp2_probe = 8'd0;
        wait (ARESETn);
        while (tp2_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd28 && dut.u_verify.mat_i == 3'd0 &&
                tp2_probe == 8'd0) begin
                begin : tp2_dump
                    integer t2_fd;
                    integer q;
                    t2_fd = $fopen("vf_t1hat.txt", "w");
                    for (q = 0; q < 256; q = q + 1)
                        $fwrite(t2_fd, "t_%0d %05x\n", q, dut.u_verify.spad[13*256 + q]);
                    $fclose(t2_fd);
                end
                tp2_probe <= 8'd1;
            end
        end
    end

    // =========================================================================
    // Probe: sweep ntt_ext SRAM after INTT(ct1) completes (at VF_HINT_SETS, st 32)
    // =========================================================================
    reg [7:0] cp2_probe;
    reg [8:0] cp2_idx;
    integer cp2_fd;
    initial begin
        cp2_probe = 8'd0;
        cp2_idx = 9'd0;
        wait (ARESETn);
        while (cp2_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd32 && cp2_probe == 8'd0) begin
                cp2_fd = $fopen("vf_ct1full.txt", "w");
                // step ntt_ext_addr and capture dout
                for (cp2_idx = 0; cp2_idx < 256; cp2_idx = cp2_idx + 1) begin
                    dut.u_verify.ntt_ext_addr <= cp2_idx[7:0];
                    @(posedge ACLK);
                    $fwrite(cp2_fd, "ct1_%0d %05x\n", cp2_idx, dut.u_verify.ntt_ext_dout);
                end
                $fclose(cp2_fd);
                cp2_probe <= 8'd1;
            end
        end
    end

    // =========================================================================
    // Probe: dump ntt_ext right after CT1_PMUL (at VF_INTT_CT1_RUN entry, st 29)
    // =========================================================================
    reg [7:0] cp3_probe;
    reg [8:0] cp3_idx;
    integer cp3_fd;
    initial begin
        cp3_probe = 8'd0;
        cp3_idx = 9'd0;
        wait (ARESETn);
        while (cp3_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd29 && cp3_probe == 8'd0) begin
                cp3_fd = $fopen("vf_ct1prod.txt", "w");
                for (cp3_idx = 0; cp3_idx < 256; cp3_idx = cp3_idx + 1) begin
                    dut.u_verify.ntt_ext_addr <= cp3_idx[7:0];
                    @(posedge ACLK);
                    $fwrite(cp3_fd, "p_%0d %05x\n", cp3_idx, dut.u_verify.ntt_ext_dout);
                end
                $fclose(cp3_fd);
                cp3_probe <= 8'd1;
            end
        end
    end

    // =========================================================================
    // Probe: trace CT1_PMUL (state 28) writes
    // =========================================================================
    integer cp4_cnt;
    integer cp4_fd;
    initial begin
        cp4_cnt = 0;
        wait (ARESETn);
        while (cp4_cnt < 12) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd28 && dut.u_verify.ntt_ext_we) begin
                cp4_fd = $fopen("vf_ct1wr.txt", "a");
                $fwrite(cp4_fd, "cc=%0d we=%b addr=%0d din=%05x pvin=%b\n",
                        dut.u_verify.coeff_cnt, dut.u_verify.ntt_ext_we,
                        dut.u_verify.ntt_ext_addr, dut.u_verify.ntt_ext_din,
                        dut.u_verify.pmul_vld_in);
                $fclose(cp4_fd);
                cp4_cnt = cp4_cnt + 1;
            end
        end
    end

    // =========================================================================
    // Probe: capture ntt_ext_dout during w-sub (state 30), first 12 reads
    // =========================================================================
    integer cp5_cnt;
    integer cp5_fd;
    initial begin
        cp5_cnt = 0;
        wait (ARESETn);
        while (cp5_cnt < 12) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd30 && dut.u_verify.coeff_cnt >= 9'd2) begin
                cp5_fd = $fopen("vf_ct1sub.txt", "a");
                $fwrite(cp5_fd, "cc=%0d ext=%05x wr=%05x\n",
                        dut.u_verify.coeff_cnt, dut.u_verify.ntt_ext_dout,
                        dut.u_verify.sp_wr_data);
                $fclose(cp5_fd);
                cp5_cnt = cp5_cnt + 1;
            end
        end
    end

    // =========================================================================
    // Probe: dump hint_mask at VF_USEHINT entry (state 33, mat_i=0)
    // =========================================================================
    reg [7:0] hm_probe;
    reg [6:0] hm_prev;
    initial begin
        hm_probe = 8'd0;
        hm_prev = 7'd0;
        wait (ARESETn);
        while (hm_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd33 && dut.u_verify.mat_i == 3'd0 &&
                hm_prev != 7'd33) begin
                begin : hm_dump
                    integer h_fd;
                    integer q;
                    h_fd = $fopen("vf_hintmask.txt", "w");
                    $fwrite(h_fd, "mask %064x\n", dut.u_verify.hint_mask);
                    for (q = 0; q < 256; q = q + 1)
                        if (dut.u_verify.hint_mask[q])
                            $fwrite(h_fd, "pos %0d\n", q);
                    $fclose(h_fd);
                end
                hm_probe <= 8'd1;
            end
            hm_prev <= dut.u_verify.state;
        end
    end

    // =========================================================================
    // Probe: capture UseHint inputs (w, hint_bit) at VF_USEHINT sub=2
    // =========================================================================
    integer uh_cnt;
    integer uh_fd;
    initial begin
        uh_cnt = 0;
        wait (ARESETn);
        while (uh_cnt < 24) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd33 && dut.u_verify.mat_i == 3'd0 &&
                dut.u_verify.z_cnt >= 9'd248) begin
                uh_fd = $fopen("vf_uh.txt", "a");
                $fwrite(uh_fd, "Z zc=%0d sub=%0d bc=%0d uh=%03x ld=%016x wr=%016x\n",
                        dut.u_verify.z_cnt, dut.u_verify.sub, dut.u_verify.w1_byte_cnt,
                        dut.u_verify.uh_out, dut.u_verify.w1_lane_data,
                        dut.u_verify.shake_wr_lane_data);
                $fclose(uh_fd);
                uh_cnt = uh_cnt + 1;
            end
        end
    end

    // =========================================================================
    // Probe: SHAKE core fsm_a / kf_busy during hash absorb (state 33)
    // =========================================================================
    integer kc_cnt;
    integer kc_fd;
    initial begin
        kc_cnt = 0;
        wait (ARESETn);
        while (kc_cnt < 60) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd33 || dut.u_verify.state == 7'd14 ||
                dut.u_verify.state == 7'd15) begin
                kc_fd = $fopen("vf_shake_core.txt", "a");
                $fwrite(kc_fd, "st=%0d fsm=%0d kfb=%b perm=%b pap=%b wr=%b\n",
                        dut.u_verify.state, dut.u_shake.fsm_a, dut.u_shake.kf_busy,
                        dut.u_shake.a_permute, dut.u_shake.a_pad_and_permute,
                        dut.u_shake.a_wr_en);
                $fclose(kc_fd);
                kc_cnt = kc_cnt + 1;
            end
        end
    end

    // =========================================================================
    // Probe: dump kf_state_in at the final pad permute (owner A, after 6 perms)
    // =========================================================================
    integer kf_cnt;
    integer kf_fd;
    integer kf2_i;
    initial begin
        kf_cnt = 0;
        wait (ARESETn);
        while (kf_cnt < 10) begin
            @(posedge ACLK);
            if (dut.u_shake.kf_start && dut.u_shake.owner == 1'b0) begin
                kf_fd = $fopen("vf_kfin.txt", "a");
                $fwrite(kf_fd, "K%d vst=%0d:", kf_cnt, dut.u_verify.state);
                for (kf2_i = 0; kf2_i < 17; kf2_i = kf2_i + 1)
                    $fwrite(kf_fd, " %016x", dut.u_shake.kf_state_in[kf2_i*64 +: 64]);
                $fwrite(kf_fd, "\n");
                $fclose(kf_fd);
                kf_cnt = kf_cnt + 1;
            end
        end
    end
    integer sp_cnt;
    integer sp_fd;
    reg [7:0] sp_prev_perm;
    initial begin
        sp_cnt = 0;
        sp_prev_perm = 8'd0;
        wait (ARESETn);
        while (sp_cnt < 12) begin
            @(posedge ACLK);
            if (dut.u_shake.kf_done && dut.u_shake.owner == 1'b0) begin
                sp_fd = $fopen("vf_permute_state.txt", "a");
                $fwrite(sp_fd, "P%d st=%016x\n", sp_cnt, dut.u_shake.kf_state_out[63:0]);
                $fclose(sp_fd);
                sp_cnt = sp_cnt + 1;
            end
        end
    end

    // =========================================================================
    // Probe: log UNPACK_CT progress
    // =========================================================================
    integer vc_cnt;
    integer vc_fd;
    initial begin
        vc_cnt = 0;
        wait (ARESETn);
        while (vc_cnt < 8) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd1) begin
                vc_fd = $fopen("vf_unpack_ct.txt", "a");
                $fwrite(vc_fd, "sub=%0d raddr=%0d rdata=%02x\n",
                        dut.u_verify.sub, dut.u_verify.sig_rd_addr, dut.u_verify.sig_rd_data);
                $fclose(vc_fd);
                vc_cnt = vc_cnt + 1;
            end
        end
    end

    // =========================================================================
    // Probe: dump c_tilde_cap / c_tilde_comp / spad at VF_COMPARE
    // =========================================================================
    reg [7:0] vp_probe;
    integer vp_vec;
    initial begin
        vp_probe = 8'd0;
        vp_vec = 0;
        wait (ARESETn);
        while (vp_vec < 5) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd36 && vp_probe == 8'd0) begin
                begin : vp_dump
                    integer v_fd;
                    integer q;
                    v_fd = $fopen("vf_debug_0.txt", "a");
                    $fwrite(v_fd, "== vec %0d ==\n", vp_vec);
                    $fwrite(v_fd, "cap %032x\n", dut.u_verify.c_tilde_cap);
                    $fwrite(v_fd, "comp %032x\n", dut.u_verify.c_tilde_comp);
                    $fwrite(v_fd, "z_norm_ok %b\n", dut.u_verify.z_norm_ok);
                    for (q = 0; q < 48; q = q + 1)
                        $fwrite(v_fd, "capb%d %02x\n", q, dut.u_verify.c_tilde_cap[q*8 +: 8]);
                    $fclose(v_fd);
                end
                vp_probe <= 8'd1;
            end
            if (dut.u_verify.state == 7'd38 && vp_probe == 8'd1) begin
                vp_probe <= 8'd0;
                vp_vec <= vp_vec + 1;
            end
        end
    end

    // =========================================================================
    // Probe: dump full SHAKE-256 state at VF_HASH_SQZ entry
    // =========================================================================
    reg [7:0] st_probe;
    initial begin
        st_probe = 8'd0;
        wait (ARESETn);
        while (st_probe < 8'd1) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd35 && dut.u_verify.sub == 5'd0 &&
                st_probe == 8'd0) begin
                begin : st_dump
                    integer st_fd;
                    integer q;
                    st_fd = $fopen("vf_shake_state.txt", "w");
                    for (q = 0; q < 25; q = q + 1)
                        $fwrite(st_fd, "lane%d %016x\n", q,
                                dut.u_shake.state[q*64 +: 64]);
                    $fclose(st_fd);
                end
                st_probe <= 8'd1;
            end
        end
    end

    // =========================================================================
    // Probe: capture SHAKE-256 squeeze lanes during VF_HASH_SQZ (state 35)
    // =========================================================================
    integer sq_cnt;
    integer sq_fd;
    initial begin
        sq_cnt = 0;
        wait (ARESETn);
        while (sq_cnt < 8) begin
            @(posedge ACLK);
            if (dut.u_verify.state == 7'd35) begin
                sq_fd = $fopen("vf_squeeze.txt", "a");
                $fwrite(sq_fd, "sub=%0d ridx=%0d data=%016x\n",
                        dut.u_verify.sub, dut.u_verify.shake_rd_lane_idx,
                        dut.u_verify.shake_rd_lane_data);
                $fclose(sq_fd);
                sq_cnt = sq_cnt + 1;
            end
        end
    end

    // =========================================================================
    // Main test
    // =========================================================================
    integer t;
    reg [31:0] status;

    // =========================================================================
    // Probe: log verify FSM state every cycle while busy
    // =========================================================================
    reg [6:0] vf_last_state;
    integer vf_state_cnt;
    initial begin
        vf_last_state = 7'd255;
        vf_state_cnt = 0;
        wait (ARESETn);
        forever begin
            @(posedge ACLK);
            if (dut.u_verify.busy) begin
                if (dut.u_verify.state == vf_last_state) begin
                    vf_state_cnt = vf_state_cnt + 1;
                    if (vf_state_cnt == 500000) begin
                        $display("[PROBE] STUCK in state %0d for 500k cycles", dut.u_verify.state);
                        vf_state_cnt = 0;
                    end
                end else begin
                    vf_state_cnt = 0;
                    vf_last_state = dut.u_verify.state;
                end
            end
        end
    end

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
        $display("ML-DSA-65 Verify Known Answer Test (KAT)");
        $display("==============================================");

        for (current_vec = 0; current_vec < 5; current_vec = current_vec + 1) begin
            $display("----------------------------------------------");
            $display("KAT Vector %0d", current_vec);
            $display("----------------------------------------------");

            // Load config (pk, rho, mu) once
            load_vec(current_vec);

            // --- Valid signature ---
            load_sig(current_vec, -1, 8'h00);
            $display("  [vec %0d] Loading valid signature...", current_vec);
            wr(16'h0000, 32'h0000_0004);   // start_verify
            wait_verify_done;
            if (verify_ok) begin
                $display("  [vec %0d] VALID sig -> verify: PASS (valid=%b, %0d polls)",
                         current_vec, verify_ok, vf_polls);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  [vec %0d] VALID sig -> verify: FAIL (valid=%b, %0d polls)",
                         current_vec, verify_ok, vf_polls);
                fail_cnt = fail_cnt + 1;
            end

            // --- Tampered signature (flip a z byte) ---
            load_sig(current_vec, 100, ref_sig[100] ^ 8'h01);
            $display("  [vec %0d] Loading tampered signature (z byte 100)...", current_vec);
            wr(16'h0000, 32'h0000_0004);   // start_verify
            wait_verify_done;
            if (!verify_ok) begin
                $display("  [vec %0d] TAMPERED sig -> verify: PASS (rejected, valid=%b)",
                         current_vec, verify_ok);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  [vec %0d] TAMPERED sig -> verify: FAIL (wrongly accepted, valid=%b)",
                         current_vec, verify_ok);
                fail_cnt = fail_cnt + 1;
            end

            // --- Malformed hint sections (FIPS 204 Alg 15 reject cases) ---
            // Hint region: positions sig[3248..3302], counts sig[3303..3308].
            // Every reference vector here has total hints 33..44, so slot 54
            // (byte 3302) is padding and slots 0,1 are both inside row 0.
            check_bad_hint("count > OMEGA",        3308, 8'd200);
            check_bad_hint("counts non-monotone",  3303, 8'd50);
            check_bad_hint("padding not zero",     3302, 8'hFF);
            check_bad_hint("positions repeat",     3249, ref_sig[3248]);
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
