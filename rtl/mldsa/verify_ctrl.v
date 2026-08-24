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

module verify_ctrl (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          start,
    output reg           done,
    output reg           busy,
    output reg           valid,

        input  wire [255:0]  pk_rho,
    input  wire [511:0]  mu,
    input  wire          mu_valid,

        output reg  [11:0]   sig_rd_addr,
    input  wire [7:0]    sig_rd_data,
    output reg  [10:0]   pk_rd_addr,
    input  wire [7:0]    pk_rd_data,

    // NTT core interface
    output reg           ntt_start,
    output reg           ntt_intt_mode,
    input  wire          ntt_done,
    input  wire          ntt_busy,

    // SHAKE-256 interface (channel A)
    output reg           shake_init,
    output reg           shake_wr_en,
    output reg  [4:0]    shake_wr_lane_idx,
    output reg  [63:0]   shake_wr_lane_data,
    output reg           shake_pad_and_permute,
    output reg           shake_permute,
    output reg  [4:0]    shake_rd_lane_idx,
    input  wire [63:0]   shake_rd_lane_data,
    input  wire          shake_rdy,
    input  wire          shake_busy,

    // SHAKE-128 interface (channel B, ExpandA)
    output reg           s128_init,
    output reg           s128_wr_en,
    output reg  [4:0]    s128_wr_lane_idx,
    output reg  [63:0]   s128_wr_lane_data,
    output reg           s128_pad_and_permute,
    output reg           s128_permute,
    output reg  [4:0]    s128_rd_lane_idx,
    input  wire [63:0]   s128_rd_lane_data,
    input  wire          s128_rdy,
    input  wire          s128_busy,

    // NTT external data port
    output reg           ntt_ext_we,
    output reg  [7:0]    ntt_ext_addr,
    output reg  [`MLDSA_QBITS-1:0] ntt_ext_din,
    input  wire [`MLDSA_QBITS-1:0] ntt_ext_dout,

        input  wire [255:0]  c_tilde_orig,
    input  wire [255:0]  c_tilde_prime
);

                localparam L = `MLDSA_L;                     localparam K = `MLDSA_K;                     localparam OMEGA = `MLDSA_OMEGA;             localparam [22:0] GAMMA1       = `MLDSA_GAMMA1;
    localparam [22:0] BETA         = 23'd196;
    localparam [22:0] NORM_BOUND   = GAMMA1 - BETA;          localparam [22:0] Q_MINUS_BOUND = `MLDSA_Q - NORM_BOUND;
    localparam [22:0] D            = `MLDSA_D_PARAM;
    // SHAKE rates
    localparam SHAKE128_RATE_LANES = 21;   // 168 bytes

        localparam SP_Z  = 6'd0;
    localparam SP_C  = 6'd5;
    localparam SP_W  = 6'd6;        localparam SP_A  = 6'd12;
    localparam SP_T1 = 6'd13;
    localparam SP_B0 = 6'd14;
    localparam SP_B1 = 6'd15;

                (* ram_style = "block" *)
    reg [22:0] spad [0:16*256-1];
    reg [12:0] sp_wr_addr, sp_rd_addr, sp_rd2_addr, sp_rd3_addr;
    reg [22:0] sp_wr_data, sp_rd_data, sp_rd2_data, sp_rd3_data;
    reg        sp_wr_en;

    always @(posedge clk) begin
        if (sp_wr_en)
            spad[sp_wr_addr] <= sp_wr_data;
        sp_rd_data  <= spad[sp_rd_addr];
        sp_rd2_data <= spad[sp_rd2_addr];
        sp_rd3_data <= spad[sp_rd3_addr];
    end

    function [12:0] base_addr;
        input [5:0] slot;
        base_addr = {slot, 8'd0};
    endfunction

                reg                      pmul_vld_in;
    reg  [`MLDSA_QBITS-1:0]  pmul_a, pmul_b;
    reg  [7:0]               pmul_wr_idx;
    reg                      pmul_acc_phase;
    wire [`MLDSA_QBITS-1:0]  pmul_result;
    wire                     pmul_vld_out;

    montgomery_mult u_pmul (
        .clk     (clk),
        .rst_n   (rst_n),
        .vld_in  (pmul_vld_in),
        .a       (pmul_a),
        .b       (pmul_b),
        .result  (pmul_result),
        .vld_out (pmul_vld_out)
    );

                reg  [`MLDSA_QBITS-1:0] madd_a, madd_b;
    wire [`MLDSA_QBITS-1:0] madd_sum, madd_diff;

    mod_add u_madd (
        .a    (madd_a),
        .b    (madd_b),
        .sum  (madd_sum),
        .diff (madd_diff)
    );

                function [22:0] z_coeff;
        input [19:0] c;
        begin
            z_coeff = (c <= GAMMA1) ? (GAMMA1 - c) : (GAMMA1 + `MLDSA_Q - c);
        end
    endfunction

    // t1 coefficient from 5 bytes (10-bit, 4 per group), scaled by 2^D
    function [22:0] t1_coeff;
        input [39:0] b;      // 5 bytes
        input [1:0]  j;
        reg [9:0] v;
        begin
            case (j)
                2'd0: v = b[7:0] | ((b[15:8] & 10'h3) << 8);
                2'd1: v = (b[15:8] >> 2) | (b[23:16] << 6);
                2'd2: v = (b[23:16] >> 4) | (b[31:24] << 4);
                default: v = (b[31:24] >> 6) | (b[39:32] << 2);
            endcase
            t1_coeff = {13'd0, v} << D;
        end
    endfunction

                wire [22:0] dec_r1, dec_r0;
    wire [22:0] uh_out;
    reg  hint_bit;

    decompose u_dec (
        .r  (sp_rd_data),
        .r1 (dec_r1),
        .r0 (dec_r0)
    );

    use_hint u_uh (
        .hint  (hint_bit),
        .r     (sp_rd_data),
        .r1_out(uh_out)
    );

                localparam [6:0]
        VF_IDLE          = 7'd0,
        VF_UNPACK_CT     = 7'd1,   // read c_tilde (48 bytes) -> c_tilde_cap
        VF_UNPACK_Z      = 7'd2,           VF_CHECK_Z       = 7'd3,           VF_NTT_LD        = 7'd4,   // generic NTT load
        VF_NTT_RUN       = 7'd5,
        VF_NTT_ST        = 7'd6,   // generic NTT store
        VF_SIB_INIT      = 7'd7,   // SHAKE-256 init for SampleInBall
        VF_SIB_ABS       = 7'd8,           VF_SIB_PAD       = 7'd9,
        VF_SIB_PERM      = 7'd10,
        VF_SIB_SQZ       = 7'd11,  // squeeze 2 blocks (272 bytes)
        VF_SIB_SIGS      = 7'd12,  // read 8 sign bytes
        VF_SIB_BUILD     = 7'd13,          VF_SIB_CLR_C     = 7'd41,          VF_HASH_INIT     = 7'd14,  // SHAKE-256 init for H(mu || w1')
        VF_HASH_WAIT     = 7'd40,  // wait for SHAKE-256 init to apply
        VF_HASH_MU       = 7'd15,          VF_CLR_W         = 7'd39,          VF_EXPA_INIT     = 7'd16,  // SHAKE-128 init for ExpandA
        VF_EXPA_ABS      = 7'd17,          VF_EXPA_PERM     = 7'd18,
        VF_EXPA_FEED     = 7'd19,          VF_EXPA_SQZ      = 7'd20,
        VF_EXPA_STORE    = 7'd21,
        VF_PMUL_ACC      = 7'd22,          VF_PMUL_NEXT     = 7'd23,          VF_INTT_W_RUN    = 7'd24,          VF_INTT_W_ST     = 7'd25,
        VF_T1_UNPACK     = 7'd26,          VF_NTT_T1        = 7'd27,  // NTT(t1)
        VF_CT1_PMUL      = 7'd28,          VF_INTT_CT1_RUN  = 7'd29,
        VF_INTT_CT1_ST   = 7'd30,
        VF_W_SUB         = 7'd31,          VF_HINT_SETS     = 7'd32,          VF_USEHINT       = 7'd33,  // UseHint + pack -> absorb into SHAKE-256
        VF_HASH_PAD      = 7'd34,  // 0x1F lane2, 0x80 lane16, pad+permute
        VF_HASH_SQZ      = 7'd35,          VF_COMPARE       = 7'd36,
        VF_DONE          = 7'd37,
        VF_FAIL          = 7'd38;

    reg [6:0] state;

                reg [5:0]  sub;
    reg [3:0]  poly_idx;          reg [8:0]  coeff_cnt;         reg [10:0] z_cnt;
    reg [2:0]  mat_i, mat_j;
    reg [4:0]  lane_cnt;      // SHAKE lane counter for w1' absorb
    reg [4:0]  sib_lane;
    reg        sib_block;
    reg [3:0]  sib_sub;
    reg [8:0]  sib_i;
    reg [11:0] sib_pos;
    reg [63:0] sib_signs;
    reg [22:0] sib_cj;
    reg [2:0]  byte_in_lane;
    reg [2:0]  rej_phase;
    reg [7:0]  rej_b0, rej_b1, rej_b2;
    reg        z_norm_ok, z_fail;
    reg        s128_sq_seen;

    // Generic NTT controls
    reg [5:0]  ntt_src, ntt_dst;
    reg        ntt_mode;
    reg [3:0]  ntt_poly, ntt_cnt;
    reg [6:0]  ntt_ret;

        reg [255:0] hint_mask;
    reg [7:0]   hint_cnt_prev;
    reg [7:0]   hint_cnt_cur;
    reg [7:0]   hint_pos_idx;

        reg [7:0] sib_j;

        reg [383:0] c_tilde_cap;
    reg [383:0] c_tilde_comp;
        wire [22:0] rej_candidate = {rej_b2[6:0], rej_b1, rej_b0};

        reg [22:0] ct1_val;

        reg [63:0] w1_lane_data;
    reg [2:0]  w1_byte_cnt;    // 0..7 bytes in current lane
    reg [4:0]  w1_lane;        // SHAKE-256 lane index for w1' absorb

        reg [7:0] zt0b, zt1b, zt2b, zt3b, zt4b;
    reg [7:0] t1b0, t1b1, t1b2, t1b3, t1b4;

                always @(posedge clk) begin
        if (!rst_n) begin
            state      <= VF_IDLE;   done       <= 1'b0;
            busy       <= 1'b0;     valid      <= 1'b0;
            ntt_start  <= 1'b0;     ntt_intt_mode <= 1'b0;
            ntt_ext_we <= 1'b0;
            shake_init <= 1'b0;     shake_wr_en <= 1'b0;
            shake_pad_and_permute <= 1'b0; shake_permute <= 1'b0;
            sp_wr_en   <= 1'b0;     pmul_vld_in <= 1'b0;
            sub        <= 5'd0;     poly_idx <= 4'd0;
            coeff_cnt  <= 9'd0;     z_cnt    <= 9'd0;
            lane_cnt   <= 5'd0;     mat_i    <= 3'd0; mat_j <= 3'd0;
            z_norm_ok  <= 1'b0;     z_fail   <= 1'b0;
            sib_lane   <= 5'd0;     sib_block <= 1'b0; sib_sub <= 3'd0;
            sib_i      <= 9'd0;     sib_pos  <= 12'd0;
            sib_signs  <= 64'd0;    sib_cj   <= 23'd0;
            byte_in_lane <= 3'd0;   rej_phase <= 3'd0;
            rej_b0     <= 8'd0;     rej_b1   <= 8'd0; rej_b2 <= 8'd0;
            hint_mask  <= 256'd0;
            hint_cnt_prev <= 8'd0;  hint_cnt_cur <= 8'd0;
            hint_pos_idx  <= 8'd0;
            c_tilde_cap <= 384'd0;  c_tilde_comp <= 384'd0;
            ct1_val     <= 23'd0;
            sig_rd_addr <= 12'd0;   pk_rd_addr <= 11'd0;
            s128_init   <= 1'b0;    s128_wr_en <= 1'b0;
            s128_pad_and_permute <= 1'b0; s128_permute <= 1'b0;
            ntt_src <= 6'd0; ntt_dst <= 6'd0; ntt_mode <= 1'b0;
            ntt_poly <= 4'd0; ntt_cnt <= 4'd0; ntt_ret <= 7'd0;
            s128_sq_seen <= 1'b0;
            w1_lane_data <= 64'd0;  w1_byte_cnt <= 3'd0;
            w1_lane     <= 5'd0;
            zt0b <= 8'd0; zt1b <= 8'd0; zt2b <= 8'd0; zt3b <= 8'd0; zt4b <= 8'd0;
            t1b0 <= 8'd0; t1b1 <= 8'd0; t1b2 <= 8'd0; t1b3 <= 8'd0; t1b4 <= 8'd0;
        end else begin
            done    <= 1'b0;       ntt_start     <= 1'b0;
            shake_init <= 1'b0;    shake_wr_en   <= 1'b0;
            shake_pad_and_permute <= 1'b0; shake_permute <= 1'b0;
            s128_init <= 1'b0;     s128_wr_en   <= 1'b0;
            s128_pad_and_permute <= 1'b0; s128_permute <= 1'b0;
            sp_wr_en <= 1'b0;      ntt_ext_we    <= 1'b0;
            pmul_vld_in <= 1'b0;

            case (state)

                VF_IDLE: begin
                    busy  <= 1'b0;
                    valid <= 1'b0;
                    if (start && mu_valid) begin
                        busy      <= 1'b1;
                        z_fail    <= 1'b0;
                        z_norm_ok <= 1'b0;
                        state     <= VF_UNPACK_CT;
                    end
                end

                                // Read c_tilde (48 bytes) from sig_ram[0:47] -> c_tilde_cap
                                                VF_UNPACK_CT: begin
                    sig_rd_addr <= {6'd0, sub};
                    if (sub > 6'd0) begin
                        c_tilde_cap[(sub-6'd1)*8 +: 8] <= sig_rd_data;
                    end
                    if (sub == 6'd48) begin
                        sig_rd_addr <= 12'd48;
                        sub      <= 6'd0;
                        poly_idx <= 4'd0;
                        z_cnt    <= 11'd0;
                        state    <= VF_UNPACK_Z;
                    end else begin
                        sub <= sub + 6'd1;
                    end
                end

                                                // sig offset = 48 + poly*640 + grp*5 ; 2 coeffs per 5 bytes
                                VF_UNPACK_Z: begin
                    case (sub)
                    5'd0: begin
                        sig_rd_addr <= 12'd48 + poly_idx*12'd640 + z_cnt*12'd5;
                        sub <= 5'd1;
                    end
                    5'd1: begin zt0b <= sig_rd_data; sig_rd_addr <= 12'd48 + poly_idx*12'd640 + z_cnt*12'd5 + 5'd1; sub <= 5'd2; end
                    5'd2: begin zt1b <= sig_rd_data; sig_rd_addr <= 12'd48 + poly_idx*12'd640 + z_cnt*12'd5 + 5'd2; sub <= 5'd3; end
                    5'd3: begin zt2b <= sig_rd_data; sig_rd_addr <= 12'd48 + poly_idx*12'd640 + z_cnt*12'd5 + 5'd3; sub <= 5'd4; end
                    5'd4: begin zt3b <= sig_rd_data; sig_rd_addr <= 12'd48 + poly_idx*12'd640 + z_cnt*12'd5 + 5'd4; sub <= 5'd5; end
                    5'd5: begin
                        zt4b <= sig_rd_data;
                        // c0 = b0 | b1<<8 | b2<<16  ;  c1 = b2>>4 | b3<<4 | b4<<12
                        sp_wr_en   <= 1'b1;
                        sp_wr_addr <= base_addr(SP_Z + poly_idx) + {z_cnt[7:0], 1'b0};
                        sp_wr_data <= z_coeff({zt2b[3:0], zt1b, zt0b});
                        sub <= 5'd6;
                    end
                    5'd6: begin
                        sp_wr_en   <= 1'b1;
                        sp_wr_addr <= base_addr(SP_Z + poly_idx) + {z_cnt[7:0], 1'b0} + 14'd1;
                        sp_wr_data <= z_coeff({zt4b, zt3b, zt2b[7:4]});
                        if (z_cnt == 9'd127) begin
                            z_cnt <= 9'd0;
                            if (poly_idx == 4'd4) begin
                                poly_idx <= 4'd0;
                                z_cnt    <= 9'd0;
                                state    <= VF_CHECK_Z;
                            end else begin
                                poly_idx <= poly_idx + 4'd1;
                            end
                        end else begin
                            z_cnt <= z_cnt + 9'd1;
                        end
                        sub <= 5'd0;
                    end
                    default: sub <= 5'd0;
                    endcase
                end

                                                                VF_CHECK_Z: begin
                                        if (z_cnt <= 11'd1279) begin
                        sp_rd_addr <= base_addr(SP_Z + z_cnt[10:8]) + z_cnt[7:0];
                    end
                    if (z_cnt >= 9'd2 && z_cnt <= 11'd1281) begin
                        if (!((sp_rd_data < NORM_BOUND) || (sp_rd_data > Q_MINUS_BOUND)))
                            z_fail <= 1'b1;
                    end
                    if (z_cnt == 11'd1281) begin
                        if (z_fail) begin
                            z_cnt <= 9'd0;
                            state <= VF_FAIL;
                        end else begin
                            z_norm_ok <= 1'b1;
                            ntt_src   <= SP_Z;
                            ntt_dst   <= SP_Z;
                            ntt_mode  <= 1'b0;
                            ntt_poly  <= 4'd0;
                            ntt_cnt   <= 4'd5;
                            ntt_ret   <= VF_SIB_INIT;
                            coeff_cnt <= 9'd0;
                            z_cnt     <= 9'd0;
                            state     <= VF_NTT_LD;
                        end
                    end else begin
                        z_cnt <= z_cnt + 9'd1;
                    end
                end

                                // Generic NTT: load ntt_src, run, store to ntt_dst
                                VF_NTT_LD: begin
                    if (!ntt_busy) begin
                        if (coeff_cnt <= 9'd255) begin
                            sp_rd_addr <= base_addr(ntt_src) + coeff_cnt;
                        end
                        if (coeff_cnt >= 9'd2 && coeff_cnt <= 9'd257) begin
                            ntt_ext_we   <= 1'b1;
                            ntt_ext_addr <= coeff_cnt[7:0] - 8'd2;
                            ntt_ext_din  <= sp_rd_data;
                        end
                        if (coeff_cnt == 9'd257) begin
                            coeff_cnt <= 9'd0;
                            ntt_start <= 1'b1;
                            ntt_intt_mode <= ntt_mode;
                            state     <= VF_NTT_RUN;
                        end else begin
                            coeff_cnt <= coeff_cnt + 9'd1;
                        end
                    end
                end

                VF_NTT_RUN: begin
                    if (ntt_done) begin
                        coeff_cnt <= 9'd0;
                        state     <= VF_NTT_ST;
                    end
                end

                VF_NTT_ST: begin
                    if (coeff_cnt <= 9'd255) begin
                        ntt_ext_addr <= coeff_cnt[7:0];
                    end
                    if (coeff_cnt >= 9'd2 && coeff_cnt <= 9'd257) begin
                        sp_wr_en   <= 1'b1;
                        sp_wr_addr <= base_addr(ntt_dst) + (coeff_cnt - 9'd2);
                        sp_wr_data <= ntt_ext_dout;
                    end
                    if (coeff_cnt == 9'd257) begin
                        coeff_cnt <= 9'd0;
                        if (ntt_poly < ntt_cnt - 4'd1) begin
                            ntt_poly <= ntt_poly + 4'd1;
                            ntt_src  <= ntt_src + 6'd1;
                            ntt_dst  <= ntt_dst + 6'd1;
                            state    <= VF_NTT_LD;
                        end else begin
                            state <= ntt_ret;
                        end
                    end else begin
                        coeff_cnt <= coeff_cnt + 9'd1;
                    end
                end

                                // c = SampleInBall(c_tilde): SHAKE-256 absorb c_tilde (6 lanes)
                                VF_SIB_INIT: begin
                    shake_init <= 1'b1;
                    sub        <= 5'd0;
                    state      <= VF_SIB_ABS;
                end

                VF_SIB_ABS: begin
                    if (shake_rdy && !shake_busy) begin
                        shake_wr_en <= 1'b1;
                        shake_wr_lane_idx <= sub[2:0];
                        shake_wr_lane_data <= c_tilde_cap[sub[2:0]*64 +: 64];
                        if (sub == 5'd5) begin
                            sub <= 5'd6;
                            state <= VF_SIB_PAD;
                        end else begin
                            sub <= sub + 5'd1;
                        end
                    end
                end

                VF_SIB_PAD: begin
                    if (shake_rdy && !shake_busy) begin
                        case (sub)
                        5'd6: begin
                            shake_wr_en <= 1'b1;
                            shake_wr_lane_idx <= 5'd6;
                            shake_wr_lane_data <= 64'h00_00_00_00_00_00_00_1F;
                            sub <= 5'd7;
                        end
                        5'd7: begin
                            shake_wr_en <= 1'b1;
                            shake_wr_lane_idx <= 5'd16;
                            shake_wr_lane_data <= 64'h80_00_00_00_00_00_00_00;
                            sub <= 5'd8;
                        end
                        5'd8: begin
                            shake_pad_and_permute <= 1'b1;
                            sub <= 5'd9;
                        end
                        5'd9: begin
                            if (shake_rdy && !shake_busy) begin
                                sib_lane  <= 5'd0;
                                sib_block <= 1'b0;
                                sib_sub   <= 3'd0;
                                sub       <= 5'd0;
                                state     <= VF_SIB_SQZ;
                            end
                        end
                        default: sub <= 5'd0;
                        endcase
                    end
                end

                // Squeeze 2 blocks (272 bytes): block0 -> SP_B0, block1 -> SP_B1
                // sib_sub: 0=set rd idx, 1..8=write bytes 0..7, then advance lane
                VF_SIB_SQZ: begin
                    if (shake_rdy && !shake_busy) begin
                        case (sib_sub)
                        4'd0: begin
                            shake_rd_lane_idx <= sib_lane;
                            sib_sub <= 4'd1;
                        end
                        4'd1: begin sp_wr_en<=1; sp_wr_addr <= (sib_block ? base_addr(SP_B1) : base_addr(SP_B0)) + sib_lane*8'd8 + 4'd0; sp_wr_data <= shake_rd_lane_data[7:0];    sib_sub<=4'd2; end
                        4'd2: begin sp_wr_en<=1; sp_wr_addr <= (sib_block ? base_addr(SP_B1) : base_addr(SP_B0)) + sib_lane*8'd8 + 4'd1; sp_wr_data <= shake_rd_lane_data[15:8];   sib_sub<=4'd3; end
                        4'd3: begin sp_wr_en<=1; sp_wr_addr <= (sib_block ? base_addr(SP_B1) : base_addr(SP_B0)) + sib_lane*8'd8 + 4'd2; sp_wr_data <= shake_rd_lane_data[23:16];  sib_sub<=4'd4; end
                        4'd4: begin sp_wr_en<=1; sp_wr_addr <= (sib_block ? base_addr(SP_B1) : base_addr(SP_B0)) + sib_lane*8'd8 + 4'd3; sp_wr_data <= shake_rd_lane_data[31:24];  sib_sub<=4'd5; end
                        4'd5: begin sp_wr_en<=1; sp_wr_addr <= (sib_block ? base_addr(SP_B1) : base_addr(SP_B0)) + sib_lane*8'd8 + 4'd4; sp_wr_data <= shake_rd_lane_data[39:32];  sib_sub<=4'd6; end
                        4'd6: begin sp_wr_en<=1; sp_wr_addr <= (sib_block ? base_addr(SP_B1) : base_addr(SP_B0)) + sib_lane*8'd8 + 4'd5; sp_wr_data <= shake_rd_lane_data[47:40];  sib_sub<=4'd7; end
                        4'd7: begin sp_wr_en<=1; sp_wr_addr <= (sib_block ? base_addr(SP_B1) : base_addr(SP_B0)) + sib_lane*8'd8 + 4'd6; sp_wr_data <= shake_rd_lane_data[55:48];  sib_sub<=4'd8; end
                        4'd8: begin
                            sp_wr_en <= 1'b1;
                            sp_wr_addr <= (sib_block ? base_addr(SP_B1) : base_addr(SP_B0)) + sib_lane*8'd8 + 4'd7;
                            sp_wr_data <= shake_rd_lane_data[63:56];
                            if (sib_lane == 5'd16) begin
                                sib_lane <= 5'd0;
                                if (sib_block == 1'b0) begin
                                                                        sib_block <= 1'b1;
                                    shake_permute <= 1'b1;
                                    sib_sub   <= 4'd0;
                                    state     <= VF_SIB_PERM;
                                end else begin
                                    // both blocks done -> read sign bytes
                                    sib_sub <= 4'd0;
                                    state   <= VF_SIB_SIGS;
                                end
                            end else begin
                                sib_lane <= sib_lane + 5'd1;
                                sib_sub  <= 4'd0;
                            end
                        end
                        default: sib_sub <= 4'd0;
                        endcase
                    end
                end

                VF_SIB_PERM: begin
                    if (shake_rdy && !shake_busy) begin
                        shake_permute <= 1'b0;
                        sib_sub <= 4'd0;
                        state   <= VF_SIB_SQZ;
                    end
                end

                                // Read 8 sign bytes from SP_B0 bytes 0..7
                                VF_SIB_SIGS: begin
                    case (sib_sub)
                    4'd0: begin sp_rd_addr <= base_addr(SP_B0) + 4'd0; sib_sub <= 4'd1; end
                    4'd1: sib_sub <= 4'd2;
                    4'd2: begin sib_signs[7:0] <= sp_rd_data; sp_rd_addr <= base_addr(SP_B0) + 4'd1; sib_sub <= 4'd3; end
                    4'd3: sib_sub <= 4'd4;
                    4'd4: begin sib_signs[15:8] <= sp_rd_data; sp_rd_addr <= base_addr(SP_B0) + 4'd2; sib_sub <= 4'd5; end
                    4'd5: sib_sub <= 4'd6;
                    4'd6: begin sib_signs[23:16] <= sp_rd_data; sp_rd_addr <= base_addr(SP_B0) + 4'd3; sib_sub <= 4'd7; end
                    4'd7: sib_sub <= 4'd8;
                    4'd8: begin sib_signs[31:24] <= sp_rd_data; sp_rd_addr <= base_addr(SP_B0) + 4'd4; sib_sub <= 4'd9; end
                    4'd9: sib_sub <= 4'd10;
                    4'd10: begin sib_signs[39:32] <= sp_rd_data; sp_rd_addr <= base_addr(SP_B0) + 4'd5; sib_sub <= 4'd11; end
                    4'd11: sib_sub <= 4'd12;
                    4'd12: begin sib_signs[47:40] <= sp_rd_data; sp_rd_addr <= base_addr(SP_B0) + 4'd6; sib_sub <= 4'd13; end
                    4'd13: sib_sub <= 4'd14;
                    4'd14: begin sib_signs[55:48] <= sp_rd_data; sp_rd_addr <= base_addr(SP_B0) + 4'd7; sib_sub <= 4'd15; end
                    4'd15: begin
                        sib_signs[63:56] <= sp_rd_data;
                        sib_sub   <= 4'd0;
                        sib_i     <= 8'd207;
                        sib_pos   <= 12'd8;
                        coeff_cnt <= 9'd0;
                        sub       <= 5'd0;
                        state     <= VF_SIB_CLR_C;
                    end
                    default: sib_sub <= 4'd0;
                    endcase
                end

                                                                // previous verify run (SP_C is NTT'd in place), corrupting c.
                                VF_SIB_CLR_C: begin
                    sp_wr_en   <= 1'b1;
                    sp_wr_addr <= base_addr(SP_C) + coeff_cnt;
                    sp_wr_data <= 23'd0;
                    if (coeff_cnt == 9'd255) begin
                        coeff_cnt <= 9'd0;
                        sub       <= 5'd0;
                        state     <= VF_SIB_BUILD;
                    end else begin
                        coeff_cnt <= coeff_cnt + 9'd1;
                    end
                end

                                // SampleInBall: scan j bytes, build c
                                VF_SIB_BUILD: begin
                    case (sub)
                    5'd0: begin
                        sp_rd_addr <= (sib_pos < 12'd136) ?
                                      (base_addr(SP_B0) + sib_pos) :
                                      (base_addr(SP_B1) + (sib_pos - 12'd136));
                        sub <= 5'd1;
                    end
                    5'd1: sub <= 5'd2;
                    5'd2: begin
                        sib_j <= sp_rd_data;
                        sib_pos <= sib_pos + 12'd1;
                        if (sp_rd_data <= sib_i) begin
                            sp_rd_addr <= base_addr(SP_C) + sp_rd_data;
                            sub <= 5'd3;
                        end else begin
                            sub <= 5'd0;
                        end
                    end
                    5'd3: sub <= 5'd4;
                    5'd4: begin
                        sib_cj <= sp_rd_data;
                        sub    <= 5'd5;
                    end
                    5'd5: begin
                        sp_wr_en   <= 1'b1;
                        sp_wr_addr <= base_addr(SP_C) + sib_i;
                        sp_wr_data <= sib_cj;
                        sub        <= 5'd6;
                    end
                    5'd6: begin
                        sp_wr_en   <= 1'b1;
                        sp_wr_addr <= base_addr(SP_C) + sib_j;
                        sp_wr_data <= sib_signs[0] ? (`MLDSA_Q - 23'd1) : 23'd1;
                        sib_signs  <= {1'b0, sib_signs[63:1]};
                        if (sib_i == 8'd255) begin
                            // c built -> NTT(c), then compute all w rows
                            ntt_src  <= SP_C;
                            ntt_dst  <= SP_C;
                            ntt_mode <= 1'b0;
                            ntt_poly <= 4'd0;
                            ntt_cnt  <= 4'd1;
                            ntt_ret  <= VF_CLR_W;
                            coeff_cnt <= 9'd0;
                            mat_i    <= 3'd0;
                            mat_j    <= 3'd0;
                            z_cnt    <= 11'd0;
                            state    <= VF_NTT_LD;
                        end else begin
                            sib_i <= sib_i + 8'd1;
                            sub   <= 5'd0;
                        end
                    end
                    default: sub <= 5'd0;
                    endcase
                end

                                // H(mu || w1'): init SHAKE-256, absorb mu (8 lanes)
                                VF_HASH_INIT: begin
                    shake_init <= 1'b1;
                    sub        <= 5'd0;
                    state      <= VF_HASH_WAIT;
                end

                VF_HASH_WAIT: begin
                    if (shake_rdy && !shake_busy) begin
                        lane_cnt   <= 5'd0;
                        w1_lane    <= 5'd8;
                        sub        <= 5'd0;
                        state      <= VF_HASH_MU;
                    end
                end

                VF_HASH_MU: begin
                    if (shake_rdy && !shake_busy) begin
                        if (lane_cnt == 5'd8) begin
                                                                                    mat_i    <= 3'd0;
                            z_cnt    <= 9'd0;
                            sub      <= 5'd0;
                            state    <= VF_HINT_SETS;
                        end else begin
                                                                                    shake_wr_en <= 1'b1;
                            shake_wr_lane_idx <= lane_cnt;
                            case (lane_cnt[2:0])
                            3'd0: shake_wr_lane_data <= mu[63:0];
                            3'd1: shake_wr_lane_data <= mu[127:64];
                            3'd2: shake_wr_lane_data <= mu[191:128];
                            3'd3: shake_wr_lane_data <= mu[255:192];
                            3'd4: shake_wr_lane_data <= mu[319:256];
                            3'd5: shake_wr_lane_data <= mu[383:320];
                            3'd6: shake_wr_lane_data <= mu[447:384];
                            default: shake_wr_lane_data <= mu[511:448];
                            endcase
                            lane_cnt <= lane_cnt + 5'd1;
                        end
                    end
                end

                                                                VF_CLR_W: begin
                    sp_wr_en   <= 1'b1;
                    sp_wr_addr <= base_addr(SP_W + mat_i) + z_cnt;
                    sp_wr_data <= 23'd0;
                    if (z_cnt == 9'd255) begin
                        z_cnt <= 9'd0;
                        state <= VF_EXPA_INIT;
                    end else begin
                        z_cnt <= z_cnt + 9'd1;
                    end
                end

                                // ExpandA: SHAKE-128(rho || j || i) -> A_hat[k][j] in SP_A
                                VF_EXPA_INIT: begin
                    s128_init <= 1'b1;
                    sub       <= 5'd0;
                    coeff_cnt <= 9'd0;
                    state     <= VF_EXPA_ABS;
                end

                VF_EXPA_ABS: begin
                    if (s128_rdy && !s128_busy) begin
                        case (sub)
                        5'd0: begin s128_wr_en<=1; s128_wr_lane_idx<=5'd0; s128_wr_lane_data<=pk_rho[63:0];    sub<=5'd1; end
                        5'd1: begin s128_wr_en<=1; s128_wr_lane_idx<=5'd1; s128_wr_lane_data<=pk_rho[127:64];  sub<=5'd2; end
                        5'd2: begin s128_wr_en<=1; s128_wr_lane_idx<=5'd2; s128_wr_lane_data<=pk_rho[191:128]; sub<=5'd3; end
                        5'd3: begin s128_wr_en<=1; s128_wr_lane_idx<=5'd3; s128_wr_lane_data<=pk_rho[255:192]; sub<=5'd4; end
                        5'd4: begin
                            s128_wr_en <= 1'b1;
                            s128_wr_lane_idx <= 5'd4;
                            s128_wr_lane_data <= {40'd0, 8'h1F, 5'd0, mat_i[2:0], 5'd0, mat_j[2:0]};
                            sub <= 5'd5;
                        end
                        5'd5: begin
                            s128_wr_en <= 1'b1;
                            s128_wr_lane_idx <= 5'd20;
                            s128_wr_lane_data <= 64'h80_00_00_00_00_00_00_00;
                            sub <= 5'd6;
                        end
                        5'd6: begin
                            s128_pad_and_permute <= 1'b1;
                            sub <= 5'd7;
                        end
                        5'd7: begin
                            if (s128_rdy && !s128_busy) begin
                                s128_rd_lane_idx <= 5'd0;
                                lane_cnt     <= 5'd0;
                                byte_in_lane <= 3'd0;
                                rej_phase    <= 3'd0;
                                sub          <= 5'd0;
                                state        <= VF_EXPA_FEED;
                            end
                        end
                        default: sub <= 5'd0;
                        endcase
                    end
                end

                // Rejection sampling: 3 bytes -> candidate < Q
                VF_EXPA_FEED: begin
                    case (rej_phase)
                    3'd0: begin
                        rej_b0 <= s128_rd_lane_data[byte_in_lane*8 +: 8];
                        rej_phase <= 3'd1;
                        if (byte_in_lane == 3'd7) begin
                            byte_in_lane <= 3'd0;
                            if (lane_cnt >= SHAKE128_RATE_LANES - 1) begin
                                state <= VF_EXPA_SQZ;
                            end else begin
                                lane_cnt <= lane_cnt + 5'd1;
                                s128_rd_lane_idx <= lane_cnt + 5'd1;
                            end
                        end else begin
                            byte_in_lane <= byte_in_lane + 3'd1;
                            s128_rd_lane_idx <= lane_cnt;
                        end
                    end
                    3'd1: begin
                        rej_b1 <= s128_rd_lane_data[byte_in_lane*8 +: 8];
                        rej_phase <= 3'd2;
                        if (byte_in_lane == 3'd7) begin
                            byte_in_lane <= 3'd0;
                            if (lane_cnt >= SHAKE128_RATE_LANES - 1) begin
                                state <= VF_EXPA_SQZ;
                            end else begin
                                lane_cnt <= lane_cnt + 5'd1;
                                s128_rd_lane_idx <= lane_cnt + 5'd1;
                            end
                        end else begin
                            byte_in_lane <= byte_in_lane + 3'd1;
                            s128_rd_lane_idx <= lane_cnt;
                        end
                    end
                    3'd2: begin
                        rej_b2 <= s128_rd_lane_data[byte_in_lane*8 +: 8];
                        rej_phase <= 3'd3;
                        if (byte_in_lane == 3'd7) begin
                            byte_in_lane <= 3'd0;
                            if (lane_cnt >= SHAKE128_RATE_LANES - 1) begin
                                lane_cnt <= SHAKE128_RATE_LANES;
                            end else begin
                                lane_cnt <= lane_cnt + 5'd1;
                                s128_rd_lane_idx <= lane_cnt + 5'd1;
                            end
                        end else begin
                            byte_in_lane <= byte_in_lane + 3'd1;
                            s128_rd_lane_idx <= lane_cnt;
                        end
                        state <= VF_EXPA_STORE;
                    end
                    default: rej_phase <= 3'd0;
                    endcase
                end

                VF_EXPA_STORE: begin
                    if (rej_candidate < `MLDSA_Q && coeff_cnt < 9'd256) begin
                        sp_wr_en   <= 1'b1;
                        sp_wr_addr <= base_addr(SP_A) + coeff_cnt[7:0];
                        sp_wr_data <= rej_candidate;
                        coeff_cnt  <= coeff_cnt + 9'd1;
                    end
                    rej_phase <= 3'd0;
                    if (coeff_cnt >= 9'd256) begin
                                                coeff_cnt <= 9'd0;
                        state     <= VF_PMUL_ACC;
                    end else begin
                        if (byte_in_lane == 3'd0 && lane_cnt >= SHAKE128_RATE_LANES)
                            state <= VF_EXPA_SQZ;
                        else
                            state <= VF_EXPA_FEED;
                    end
                end

                VF_EXPA_SQZ: begin
                    if (s128_sq_seen) begin
                        s128_permute <= 1'b0;
                        if (!s128_busy) begin
                            s128_sq_seen     <= 1'b0;
                            lane_cnt         <= 5'd0;
                            byte_in_lane     <= 3'd0;
                            s128_rd_lane_idx <= 5'd0;
                            rej_phase        <= 3'd0;
                            state            <= VF_EXPA_FEED;
                        end
                    end else begin
                        s128_permute <= 1'b1;
                        if (s128_busy)
                            s128_sq_seen <= 1'b1;
                    end
                end

                                                                VF_PMUL_ACC: begin
                    if (coeff_cnt <= 9'd255) begin
                        sp_rd_addr  <= base_addr(SP_A) + coeff_cnt;
                        sp_rd2_addr <= base_addr(SP_Z + mat_j) + coeff_cnt;
                    end
                    if (coeff_cnt >= 9'd5 && coeff_cnt <= 9'd260) begin
                        sp_rd3_addr <= base_addr(SP_W + mat_i) + (coeff_cnt - 9'd5);
                    end
                    if (coeff_cnt >= 9'd2 && coeff_cnt <= 9'd257) begin
                        pmul_vld_in <= 1'b1;
                        pmul_a      <= sp_rd_data;
                        pmul_b      <= sp_rd2_data;
                    end
                    if (pmul_vld_out) begin
                        madd_a         <= sp_rd3_data;                           madd_b         <= pmul_result;                           pmul_wr_idx    <= coeff_cnt[7:0] - 8'd7;
                        pmul_acc_phase <= 1'b1;
                    end else begin
                        pmul_acc_phase <= 1'b0;
                    end
                    if (pmul_acc_phase) begin
                        sp_wr_en   <= 1'b1;
                        sp_wr_addr <= base_addr(SP_W + mat_i) + pmul_wr_idx;
                        sp_wr_data <= madd_sum;
                    end
                    if (coeff_cnt == 9'd263) begin
                        coeff_cnt <= 9'd0;
                        if (mat_j < 4'd4) begin
                            mat_j <= mat_j + 3'd1;
                            state <= VF_EXPA_INIT;
                        end else begin
                                                        mat_j <= 3'd0;
                            ntt_src  <= SP_W + mat_i;
                            ntt_dst  <= SP_W + mat_i;
                            ntt_mode <= 1'b1;
                            ntt_poly <= 4'd0;
                            ntt_cnt  <= 4'd1;
                            ntt_ret  <= VF_T1_UNPACK;
                            state    <= VF_NTT_LD;
                        end
                    end else begin
                        coeff_cnt <= coeff_cnt + 9'd1;
                    end
                end

                                                                VF_T1_UNPACK: begin
                    case (sub)
                    5'd0: begin
                        pk_rd_addr <= 32 + mat_i*9'd320 + z_cnt*9'd5;
                        sub <= 5'd1;
                    end
                    5'd1: begin t1b0 <= pk_rd_data; pk_rd_addr <= 32 + mat_i*9'd320 + z_cnt*9'd5 + 5'd1; sub <= 5'd2; end
                    5'd2: begin t1b1 <= pk_rd_data; pk_rd_addr <= 32 + mat_i*9'd320 + z_cnt*9'd5 + 5'd2; sub <= 5'd3; end
                    5'd3: begin t1b2 <= pk_rd_data; pk_rd_addr <= 32 + mat_i*9'd320 + z_cnt*9'd5 + 5'd3; sub <= 5'd4; end
                    5'd4: begin t1b3 <= pk_rd_data; pk_rd_addr <= 32 + mat_i*9'd320 + z_cnt*9'd5 + 5'd4; sub <= 5'd5; end
                    5'd5: begin
                        t1b4 <= pk_rd_data;
                        sp_wr_en   <= 1'b1;
                        sp_wr_addr <= base_addr(SP_T1) + {z_cnt[7:0], 2'd0};
                        sp_wr_data <= t1_coeff({t1b4, t1b3, t1b2, t1b1, t1b0}, 2'd0);
                        sub <= 5'd6;
                    end
                    5'd6: begin
                        sp_wr_en   <= 1'b1;
                        sp_wr_addr <= base_addr(SP_T1) + {z_cnt[7:0], 2'd0} + 14'd1;
                        sp_wr_data <= t1_coeff({t1b4, t1b3, t1b2, t1b1, t1b0}, 2'd1);
                        sub <= 5'd7;
                    end
                    5'd7: begin
                        sp_wr_en   <= 1'b1;
                        sp_wr_addr <= base_addr(SP_T1) + {z_cnt[7:0], 2'd0} + 14'd2;
                        sp_wr_data <= t1_coeff({t1b4, t1b3, t1b2, t1b1, t1b0}, 2'd2);
                        sub <= 5'd8;
                    end
                    5'd8: begin
                        sp_wr_en   <= 1'b1;
                        sp_wr_addr <= base_addr(SP_T1) + {z_cnt[7:0], 2'd0} + 14'd3;
                        sp_wr_data <= t1_coeff({t1b4, t1b3, t1b2, t1b1, t1b0}, 2'd3);
                        if (z_cnt == 9'd63) begin
                            z_cnt <= 9'd0;
                            ntt_src  <= SP_T1;
                            ntt_dst  <= SP_T1;
                            ntt_mode <= 1'b0;
                            ntt_poly <= 4'd0;
                            ntt_cnt  <= 4'd1;
                            ntt_ret  <= VF_CT1_PMUL;
                            state    <= VF_NTT_LD;
                        end else begin
                            z_cnt <= z_cnt + 9'd1;
                        end
                        sub <= 5'd0;
                    end
                    default: sub <= 5'd0;
                    endcase
                end

                                                                VF_CT1_PMUL: begin
                    if (coeff_cnt <= 9'd255) begin
                        sp_rd_addr  <= base_addr(SP_C) + coeff_cnt;
                        sp_rd2_addr <= base_addr(SP_T1) + coeff_cnt;
                    end
                    if (coeff_cnt >= 9'd2 && coeff_cnt <= 9'd257) begin
                        pmul_vld_in <= 1'b1;
                        pmul_a      <= sp_rd_data;
                        pmul_b      <= sp_rd2_data;
                    end
                    if (pmul_vld_out) begin
                        ntt_ext_we   <= 1'b1;
                        ntt_ext_addr <= coeff_cnt[7:0] - 8'd7;
                        ntt_ext_din  <= pmul_result;
                    end
                    if (coeff_cnt == 9'd263) begin
                        coeff_cnt <= 9'd0;
                        ntt_start <= 1'b1;
                        ntt_intt_mode <= 1'b1;
                        state     <= VF_INTT_CT1_RUN;
                    end else begin
                        coeff_cnt <= coeff_cnt + 9'd1;
                    end
                end

                VF_INTT_CT1_RUN: begin
                    if (ntt_done) begin
                        coeff_cnt <= 9'd0;
                        state     <= VF_INTT_CT1_ST;
                    end
                end

                VF_INTT_CT1_ST: begin
                    if (coeff_cnt <= 9'd255) begin
                        ntt_ext_addr <= coeff_cnt[7:0];
                        sp_rd_addr   <= base_addr(SP_W + mat_i) + coeff_cnt;
                    end
                    if (coeff_cnt >= 9'd2 && coeff_cnt <= 9'd257) begin
                        madd_a <= sp_rd_data;                              madd_b <= ntt_ext_dout;                        end
                    if (coeff_cnt >= 9'd3 && coeff_cnt <= 9'd258) begin
                        sp_wr_en   <= 1'b1;
                        sp_wr_addr <= base_addr(SP_W + mat_i) + (coeff_cnt - 9'd3);
                        sp_wr_data <= madd_diff;                        end
                    if (coeff_cnt == 9'd258) begin
                        coeff_cnt <= 9'd0;
                                                if (mat_i < 3'd5) begin
                            mat_i <= mat_i + 3'd1;
                            mat_j <= 3'd0;
                            z_cnt <= 9'd0;
                            state <= VF_CLR_W;
                        end else begin
                                                        mat_i <= 3'd0;
                            state <= VF_HASH_INIT;
                        end
                    end else begin
                        coeff_cnt <= coeff_cnt + 9'd1;
                    end
                end

                                                // counts at sig[3248 + OMEGA + k]
                                VF_HINT_SETS: begin
                    case (sub)
                    5'd0: begin
                        hint_mask <= 256'd0;
                        if (mat_i == 3'd0)
                            hint_cnt_prev <= 8'd0;
                        else
                            sig_rd_addr <= 12'd3248 + OMEGA + mat_i - 8'd1;
                        sub <= 5'd1;
                    end
                    5'd1: begin
                        if (mat_i != 3'd0)
                            hint_cnt_prev <= sig_rd_data;
                        sig_rd_addr <= 12'd3248 + OMEGA + mat_i;
                        sub <= 5'd2;
                    end
                    5'd2: begin
                        hint_cnt_cur <= sig_rd_data;
                        hint_pos_idx <= hint_cnt_prev;
                        sig_rd_addr  <= 12'd3248 + hint_cnt_prev;
                        sub <= 5'd3;
                    end
                    5'd3: begin
                        if (hint_pos_idx < hint_cnt_cur) begin
                            hint_mask[sig_rd_data] <= 1'b1;
                            hint_pos_idx <= hint_pos_idx + 8'd1;
                            sig_rd_addr  <= 12'd3248 + hint_pos_idx + 8'd1;
                            sub <= 5'd3;
                        end else begin
                                                        hint_pos_idx <= 8'd0;
                            z_cnt    <= 9'd0;
                            w1_byte_cnt <= 3'd0;
                            w1_lane_data <= 64'd0;
                            sub   <= 5'd0;
                            state <= VF_USEHINT;
                        end
                    end
                    default: sub <= 5'd0;
                    endcase
                end

                                // UseHint(h, w) -> w1', polyw1_pack, absorb into SHAKE-256
                // 256 coeffs -> 128 bytes -> 16 lanes (2 coeffs per byte)
                                VF_USEHINT: begin
                    case (sub)
                    5'd0: begin
                        sp_rd_addr <= base_addr(SP_W + mat_i) + z_cnt;
                        hint_bit   <= hint_mask[z_cnt];
                        sub <= 5'd1;
                    end
                    5'd1: sub <= 5'd2;
                    5'd2: begin
                                                                        if (z_cnt[0]) begin
                            w1_byte_cnt <= w1_byte_cnt + 3'd1;
                            case (w1_byte_cnt)
                            3'd0: w1_lane_data[7:4]   <= uh_out[3:0];
                            3'd1: w1_lane_data[15:12] <= uh_out[3:0];
                            3'd2: w1_lane_data[23:20] <= uh_out[3:0];
                            3'd3: w1_lane_data[31:28] <= uh_out[3:0];
                            3'd4: w1_lane_data[39:36] <= uh_out[3:0];
                            3'd5: w1_lane_data[47:44] <= uh_out[3:0];
                            3'd6: w1_lane_data[55:52] <= uh_out[3:0];
                            default: w1_lane_data[63:60] <= uh_out[3:0];
                            endcase
                        end else begin
                            case (w1_byte_cnt)
                            3'd0: w1_lane_data[3:0]   <= uh_out[3:0];
                            3'd1: w1_lane_data[11:8]  <= uh_out[3:0];
                            3'd2: w1_lane_data[19:16] <= uh_out[3:0];
                            3'd3: w1_lane_data[27:24] <= uh_out[3:0];
                            3'd4: w1_lane_data[35:32] <= uh_out[3:0];
                            3'd5: w1_lane_data[43:40] <= uh_out[3:0];
                            3'd6: w1_lane_data[51:48] <= uh_out[3:0];
                            default: w1_lane_data[59:56] <= uh_out[3:0];
                            endcase
                        end
                        if (z_cnt[0] && (w1_byte_cnt == 3'd7)) begin
                            // 16 coeffs -> full lane -> write to SHAKE.
                                                                                    shake_wr_en <= 1'b1;
                            shake_wr_lane_idx <= w1_lane;
                            shake_wr_lane_data <= {uh_out[3:0], w1_lane_data[59:0]};
                            w1_lane <= w1_lane + 5'd1;
                            if (w1_lane == 5'd16) begin
                                                                                                                                w1_lane <= 5'd0;
                                sub <= 5'd3;
                            end
                        end
                        if (z_cnt == 9'd255) begin
                            z_cnt <= 9'd0;
                            if (mat_i < 3'd5) begin
                                mat_i <= mat_i + 3'd1;
                                state <= VF_HINT_SETS;
                            end else begin
                                                                state <= VF_HASH_PAD;
                            end
                        end else begin
                            z_cnt <= z_cnt + 9'd1;
                        end
                        if (!(z_cnt[0] && (w1_byte_cnt == 3'd7) && (w1_lane == 5'd16)))
                            sub <= 5'd0;
                    end
                    5'd3: begin
                                                shake_permute <= 1'b1;
                        sub <= 5'd4;
                    end
                    5'd4: begin
                        if (shake_rdy && !shake_busy) begin
                            sub <= 5'd0;
                        end
                    end
                    default: sub <= 5'd0;
                    endcase
                end

                                // Final SHAKE-256 pad: 0x1F lane2, 0x80 lane16, permute, squeeze
                                VF_HASH_PAD: begin
                    if (shake_rdy && !shake_busy) begin
                        case (sub)
                        5'd0: begin
                            shake_wr_en <= 1'b1;
                            shake_wr_lane_idx <= 5'd2;
                            shake_wr_lane_data <= 64'h00_00_00_00_00_00_00_1F;
                            sub <= 5'd1;
                        end
                        5'd1: begin
                            shake_wr_en <= 1'b1;
                            shake_wr_lane_idx <= 5'd16;
                            shake_wr_lane_data <= 64'h80_00_00_00_00_00_00_00;
                            sub <= 5'd2;
                        end
                        5'd2: begin
                            shake_pad_and_permute <= 1'b1;
                            sub <= 5'd3;
                        end
                        5'd3: begin
                            if (shake_rdy && !shake_busy) begin
                                lane_cnt <= 5'd0;
                                sub      <= 5'd0;
                                state    <= VF_HASH_SQZ;
                            end
                        end
                        default: sub <= 5'd0;
                        endcase
                    end
                end

                                VF_HASH_SQZ: begin
                    if (shake_rdy && !shake_busy) begin
                        case (sub)
                        5'd0: begin shake_rd_lane_idx <= 5'd0; sub <= 5'd1; end
                        5'd1: begin c_tilde_comp[63:0] <= shake_rd_lane_data; shake_rd_lane_idx <= 5'd1; sub <= 5'd2; end
                        5'd2: begin c_tilde_comp[127:64] <= shake_rd_lane_data; shake_rd_lane_idx <= 5'd2; sub <= 5'd3; end
                        5'd3: begin c_tilde_comp[191:128] <= shake_rd_lane_data; shake_rd_lane_idx <= 5'd3; sub <= 5'd4; end
                        5'd4: begin c_tilde_comp[255:192] <= shake_rd_lane_data; shake_rd_lane_idx <= 5'd4; sub <= 5'd5; end
                        5'd5: begin c_tilde_comp[319:256] <= shake_rd_lane_data; shake_rd_lane_idx <= 5'd5; sub <= 5'd6; end
                        5'd6: begin
                            c_tilde_comp[383:320] <= shake_rd_lane_data;
                            sub <= 5'd0;
                            state <= VF_COMPARE;
                        end
                        default: sub <= 5'd0;
                        endcase
                    end
                end

                VF_COMPARE: begin
                    if (z_norm_ok && (c_tilde_cap[255:0] == c_tilde_comp[255:0]))
                        state <= VF_DONE;
                    else
                        state <= VF_FAIL;
                end

                VF_DONE: begin
                    valid <= 1'b1;
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    state <= VF_IDLE;
                end

                VF_FAIL: begin
                    valid <= 1'b0;
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    state <= VF_IDLE;
                end

                default: state <= VF_IDLE;
            endcase
        end
    end

        integer ii;
    initial for (ii = 0; ii < 16*256; ii = ii + 1) spad[ii] = 23'd0;

endmodule
