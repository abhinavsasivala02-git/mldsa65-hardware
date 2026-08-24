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

module sign_ctrl (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          start,
    output reg           done,
    output reg           busy,

        input  wire [255:0]  sk_rho,
    input  wire [255:0]  sk_K,
    input  wire [255:0]  sk_tr,
    // Message hash mu (64 bytes)
    input  wire [511:0]  mu,
    input  wire          mu_valid,

    // Random seed rnd (32 bytes)
    input  wire [255:0]  rnd,

        output reg  [11:0]   sk_rd_addr,
    input  wire [7:0]    sk_rd_data,

        output reg           sig_we,
    output reg  [11:0]   sig_addr,
    output reg  [7:0]    sig_wdata,

    // NTT core interface
    output reg           ntt_start,
    output reg           ntt_intt_mode,
    input  wire          ntt_done,
    input  wire          ntt_busy,
    output reg           ntt_ext_we,
    output reg  [7:0]    ntt_ext_addr,
    output reg  [`MLDSA_QBITS-1:0] ntt_ext_din,
    input  wire [`MLDSA_QBITS-1:0] ntt_ext_dout,

    // SHAKE-256 interface
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

    // SHAKE-128 interface (ExpandA)
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

        output reg           sig_valid,
    output reg  [15:0]   kappa_out
);

                localparam [22:0] GAMMA1    = 23'd524288;       localparam [22:0] GAMMA2    = 23'd261888;       localparam [22:0] BETA      = 23'd196;
    localparam [22:0] Z_BOUND   = GAMMA1 - BETA;           localparam [22:0] Q_MINUS_Z = `MLDSA_Q - Z_BOUND;      localparam [22:0] R0_BOUND  = GAMMA2 - BETA;           localparam [22:0] Q_MINUS_R0= `MLDSA_Q - R0_BOUND;     localparam [22:0] CT0_BOUND = GAMMA2;                  localparam [22:0] Q_MINUS_CT0 = `MLDSA_Q - CT0_BOUND;     localparam [22:0] Q_HALF    = 23'd4190209;             localparam [22:0] Q_2G      = `MLDSA_Q - 2*GAMMA2;     localparam [22:0] Q_G       = `MLDSA_Q - GAMMA2;
    localparam [4:0] L = `MLDSA_L;       localparam [4:0] K = `MLDSA_K;       localparam OMEGA = `MLDSA_OMEGA;
    // SHAKE rates
    localparam SHAKE256_RATE_LANES = 17;   // 136 bytes
    localparam SHAKE128_RATE_LANES = 21;   // 168 bytes

        localparam SP_Y   = 6'd0;
    localparam SP_YH  = 6'd5;
    localparam SP_S1H = 6'd10;
    localparam SP_S2H = 6'd15;
    localparam SP_T0H = 6'd21;
    localparam SP_W0  = 6'd27;
    localparam SP_W1  = 6'd33;
    localparam SP_C   = 6'd39;
    localparam SP_AT  = 6'd40;
    localparam SP_SC  = 6'd41;

                (* ram_style = "block" *)
    reg  [22:0] spad [0:42*256-1];
    reg  [13:0] sp_wr_addr;
    reg  [22:0] sp_wr_data;
    reg         sp_wr_en;
    reg  [13:0] sp_rd_addr;
    reg  [22:0] sp_rd_data;
    reg  [13:0] sp_rd2_addr;
    reg  [22:0] sp_rd2_data;
    reg  [13:0] sp_rd3_addr;
    reg  [22:0] sp_rd3_data;

    always @(posedge clk) begin
        if (sp_wr_en)
            spad[sp_wr_addr] <= sp_wr_data;
        sp_rd_data  <= spad[sp_rd_addr];
        sp_rd2_data <= spad[sp_rd2_addr];
        sp_rd3_data <= spad[sp_rd3_addr];
    end

    function [13:0] base_addr;
        input [5:0] slot;
        base_addr = {slot, 8'd0};
    endfunction

                reg                      pmul_vld_in;
    reg  [`MLDSA_QBITS-1:0]  pmul_a, pmul_b;
    reg  [7:0]               pmul_wr_idx;
    reg                      pmul_acc_phase;
    reg  [1:0]               pm_phase;           wire [`MLDSA_QBITS-1:0]  pmul_result;
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

                reg  [`MLDSA_QBITS-1:0] dc_in;
    wire [`MLDSA_QBITS-1:0] dc_r0, dc_r1;

    decompose u_dc (
        .r  (dc_in),
        .r1 (dc_r1),
        .r0 (dc_r0)
    );

                    function [22:0] eta_coeff;
        input [3:0] nib;
        begin
            eta_coeff = (nib <= `MLDSA_ETA) ?
                        (`MLDSA_ETA - nib) :
                        (`MLDSA_Q + `MLDSA_ETA - nib);
        end
    endfunction

        function [22:0] t0_coeff;
        input [103:0] bin;
        input [2:0]   j;
        reg [7:0] b [0:12];
        reg [12:0] v;
        begin
            for (integer m = 0; m < 13; m = m + 1)
                b[m] = bin[m*8 +: 8];
            case (j)
                3'd0: v = b[0] | ((b[1] & 8'h1F) << 8);
                3'd1: v = (b[1] >> 5) | (b[2] << 3) | ((b[3] & 8'h03) << 11);
                3'd2: v = (b[3] >> 2) | ((b[4] & 8'h7F) << 6);
                3'd3: v = (b[4] >> 7) | (b[5] << 1) | ((b[6] & 8'h0F) << 9);
                3'd4: v = (b[6] >> 4) | (b[7] << 4) | ((b[8] & 8'h01) << 12);
                3'd5: v = (b[8] >> 1) | ((b[9] & 8'h3F) << 7);
                3'd6: v = (b[9] >> 6) | (b[10] << 2) | ((b[11] & 8'h07) << 10);
                default: v = (b[11] >> 3) | (b[12] << 5);
            endcase
            if (v <= 13'd4096)
                t0_coeff = 13'd4096 - v;
            else
                t0_coeff = `MLDSA_Q + 13'd4096 - v;
        end
    endfunction

        function [19:0] z_pack_t;
        input [22:0] zc;
        begin
            z_pack_t = (zc <= GAMMA1) ? (GAMMA1 - zc) : (GAMMA1 + `MLDSA_Q - zc);
        end
    endfunction

        function [22:0] polyz_coeff;
        input [19:0] c;
        begin
            polyz_coeff = (c <= GAMMA1) ? (GAMMA1 - c) : (GAMMA1 + `MLDSA_Q - c);
        end
    endfunction

        function [13:0] ch_byte_addr;
        input [11:0] pos;
        begin
            ch_byte_addr = (pos < 12'd136) ?
                           (base_addr(SP_AT) + pos) :
                           (base_addr(SP_SC) + (pos - 12'd136));
        end
    endfunction

                localparam [6:0]
        SG_IDLE          = 7'd0,
                SG_RHO_INIT      = 7'd1,
        SG_RHO_ABS       = 7'd2,
        SG_RHO_PERM      = 7'd3,
        SG_RHO_SQZ       = 7'd4,
                SG_UP_S1         = 7'd5,
        SG_UP_S2         = 7'd6,
        SG_UP_T0         = 7'd7,
        // generic NTT
        SG_NTT_LD        = 7'd8,
        SG_NTT_RUN       = 7'd9,
        SG_NTT_WAIT      = 7'd10,
        SG_NTT_ST        = 7'd11,
                SG_EM_INIT       = 7'd12,
        SG_EM_ABS        = 7'd13,
        SG_EM_PERM       = 7'd14,
        SG_EM_WAIT       = 7'd15,
        SG_EM_BYTE       = 7'd16,
        SG_EM_WR0        = 7'd17,
        SG_EM_WR1        = 7'd18,
        SG_EM_PERM2      = 7'd19,
        SG_EM_PERM2W     = 7'd20,
                SG_MM_CLR_ACC    = 7'd21,
        SG_MM_EXPA_INIT  = 7'd22,
        SG_MM_EXPA_ABS   = 7'd23,
        SG_MM_EXPA_PERM  = 7'd24,
        SG_MM_EXPA_WAIT  = 7'd25,
        SG_MM_EXPA_FEED  = 7'd26,
        SG_MM_EXPA_STORE = 7'd27,
        SG_MM_EXPA_SQZ   = 7'd28,
        SG_MM_PMUL_PIPE  = 7'd29,
        SG_MM_NEXT_J     = 7'd30,
        SG_MM_DECOMP     = 7'd31,
        SG_MM_NEXT_I     = 7'd32,
                SG_CT_INIT       = 7'd33,
        SG_CT_MU         = 7'd34,
        SG_CT_W1         = 7'd35,
        SG_CT_PERM       = 7'd36,
        SG_CT_PERMW      = 7'd37,
        SG_CT_PAD        = 7'd38,
        SG_CT_PADW       = 7'd39,
        SG_CT_SQZ        = 7'd40,
                SG_SIB_ABS       = 7'd41,
        SG_SIB_PAD       = 7'd42,
        SG_SIB_WAIT      = 7'd43,
        SG_SIB_SQZ       = 7'd44,
        SG_SIB_PERM      = 7'd45,
        SG_SIB_PERMW     = 7'd46,
        SG_SIB_ZERO      = 7'd47,
        SG_SIB_SIGS      = 7'd48,
        SG_SIB_BUILD     = 7'd49,
                SG_PM_C1         = 7'd50,
        SG_PM_RUN        = 7'd51,
        SG_PM_WAIT       = 7'd52,
        SG_Z_STORE       = 7'd53,
        SG_PM_C2         = 7'd54,
        SG_R0_STORE      = 7'd55,
        SG_PM_C3         = 7'd56,
        SG_CT0_STORE     = 7'd57,
                SG_HCLR          = 7'd58,
        SG_HINTS         = 7'd59,
        SG_PACK_CT       = 7'd60,
        SG_PACK_Z        = 7'd61,
        SG_PACK_H        = 7'd62,
        SG_DONE          = 7'd63,
        SG_REJECT        = 7'd64;

    reg [6:0]  state;

                reg [4:0]  sub;
    reg [2:0]  mat_i, mat_j;
    reg [3:0]  poly_idx;
    reg [8:0]  coeff_idx;          reg [8:0]  coeff_cnt;          reg [15:0] kappa;

    // NTT generic regs
    reg [5:0]  ntt_src, ntt_dst;
    reg        ntt_mode;           reg [3:0]  ntt_poly, ntt_cnt;
    reg [6:0]  ntt_ret;

        reg [511:0] rho_prime;
    reg [383:0] c_tilde;
    reg         z_fail, r0_fail, ct0_fail, h_fail;

        reg [3:0]  em_poly;
    reg [39:0] em_grp;
    reg [2:0]  em_bcnt;
    reg [7:0]  em_grp_idx;
    reg [4:0]  em_lane;
    reg [2:0]  em_byte;
    reg [2:0]  em_block;
    reg [15:0] em_nonce;
        reg [2:0]  ct_poly;
    reg [7:0]  ct_pair;
    reg [2:0]  ct_byte_in_lane;
    reg [63:0] ct_buf;
    reg [4:0]  ct_lane;
    reg [8:0]  ct_lane_total;
    reg [22:0] ct_even, ct_odd;

        reg [7:0]  sib_i, sib_j;
    reg [11:0] sib_pos;
    reg [63:0] sib_signs;
    reg [22:0] sib_cj;
    reg [4:0]  sib_lane;
    reg        sib_block;
    reg [3:0]  sib_sub;

        reg [103:0] t0_buf;
    reg [7:0]   up_byte;
        reg [7:0]  h_arr [0:60];   // 61 bytes: OMEGA positions + K counts
    reg [6:0]  h_n;
    reg        h_clr;
    reg [2:0]  hk;

        reg [11:0] pk_byte;
    reg [19:0] zt0, zt1;
    reg [7:0]  z_grp;
    reg [3:0]  z_poly, z_sub;

        reg [7:0]  rej_b0, rej_b1, rej_b2;
    reg [1:0]  rej_phase;
    reg [4:0]  lane_cnt;
    reg [2:0]  byte_in_lane;
    reg        s128_sq_seen;
                wire [22:0] rej_candidate = {rej_b2[6:0], rej_b1, rej_b0};
    wire [7:0]  ct_byte = {ct_odd[3:0], ct_even[3:0]};
    wire        hint_bit =
        ((madd_a > GAMMA2) && (madd_a < Q_HALF)) ||
        ((madd_a > Q_2G)   && (madd_a < Q_G))   ||
        ((madd_a == Q_G)   && (madd_b != 23'd0));

                always @(posedge clk) begin
        if (!rst_n) begin
            state         <= SG_IDLE;
            done          <= 1'b0;
            busy          <= 1'b0;
            sig_valid     <= 1'b0;
            kappa         <= 16'd0;
            kappa_out     <= 16'd0;
            sub           <= 5'd0;
            mat_i         <= 3'd0;
            mat_j         <= 3'd0;
            poly_idx      <= 4'd0;
            coeff_idx     <= 9'd0;
            coeff_cnt     <= 9'd0;
            ntt_src       <= 6'd0;
            ntt_dst       <= 6'd0;
            ntt_mode      <= 1'b0;
            ntt_poly      <= 4'd0;
            ntt_cnt       <= 4'd0;
            ntt_ret       <= 7'd0;
            rho_prime     <= 512'd0;
            c_tilde       <= 384'd0;
            z_fail        <= 1'b0;
            r0_fail       <= 1'b0;
            ct0_fail      <= 1'b0;
            h_fail        <= 1'b0;
            em_poly       <= 4'd0;
            em_grp        <= 40'd0;
            em_bcnt       <= 3'd0;
            em_grp_idx    <= 8'd0;
            em_lane       <= 5'd0;
            em_byte       <= 3'd0;
            em_block      <= 3'd0;
            em_nonce      <= 16'd0;
            ct_poly       <= 3'd0;
            ct_pair       <= 8'd0;
            ct_byte_in_lane <= 3'd0;
            ct_buf        <= 64'd0;
            ct_lane       <= 5'd0;
            ct_lane_total <= 9'd0;
            ct_even       <= 23'd0;
            ct_odd        <= 23'd0;
            sib_i         <= 8'd0;
            sib_j         <= 8'd0;
            sib_pos       <= 12'd0;
            sib_signs     <= 64'd0;
            sib_cj        <= 23'd0;
            sib_lane      <= 5'd0;
            sib_block     <= 1'b0;
            sib_sub       <= 4'd0;
            t0_buf        <= 104'd0;
            up_byte       <= 8'd0;
            h_n           <= 7'd0;
            hk            <= 3'd0;
            h_clr         <= 1'b0;
            pk_byte       <= 12'd0;
            zt0           <= 20'd0;
            zt1           <= 20'd0;
            z_grp         <= 8'd0;
            z_poly        <= 4'd0;
            z_sub         <= 4'd0;
            rej_b0        <= 8'd0;
            rej_b1        <= 8'd0;
            rej_b2        <= 8'd0;
            rej_phase     <= 2'd0;
            lane_cnt      <= 5'd0;
            byte_in_lane  <= 3'd0;
            s128_sq_seen  <= 1'b0;
            madd_a        <= 23'd0;
            madd_b        <= 23'd0;
            dc_in         <= 23'd0;
            ntt_start     <= 1'b0;
            ntt_intt_mode <= 1'b0;
            ntt_ext_we    <= 1'b0;
            ntt_ext_addr  <= 8'd0;
            ntt_ext_din   <= 23'd0;
            shake_init    <= 1'b0;
            shake_wr_en   <= 1'b0;
            shake_wr_lane_idx <= 5'd0;
            shake_wr_lane_data<= 64'd0;
            shake_pad_and_permute <= 1'b0;
            shake_permute <= 1'b0;
            shake_rd_lane_idx <= 5'd0;
            s128_init     <= 1'b0;
            s128_wr_en    <= 1'b0;
            s128_wr_lane_idx <= 5'd0;
            s128_wr_lane_data<= 64'd0;
            s128_pad_and_permute <= 1'b0;
            s128_permute  <= 1'b0;
            s128_rd_lane_idx <= 5'd0;
            sp_wr_en      <= 1'b0;
            sp_wr_addr    <= 14'd0;
            sp_wr_data    <= 23'd0;
            sp_rd_addr    <= 14'd0;
            sp_rd2_addr   <= 14'd0;
            sp_rd3_addr   <= 14'd0;
            pmul_vld_in   <= 1'b0;
            pmul_a        <= 23'd0;
            pmul_b        <= 23'd0;
            pmul_wr_idx   <= 8'd0;
            pmul_acc_phase<= 1'b0;
            pm_phase      <= 2'd0;
            sk_rd_addr    <= 12'd0;
            sig_we        <= 1'b0;
            sig_addr      <= 12'd0;
            sig_wdata     <= 8'd0;
        end else begin
                        done         <= 1'b0;
            ntt_start    <= 1'b0;
            ntt_ext_we   <= 1'b0;
            shake_init   <= 1'b0;
            shake_wr_en  <= 1'b0;
            shake_pad_and_permute <= 1'b0;
            shake_permute <= 1'b0;
            s128_init    <= 1'b0;
            s128_wr_en   <= 1'b0;
            s128_pad_and_permute <= 1'b0;
            s128_permute <= 1'b0;
            sp_wr_en     <= 1'b0;
            pmul_vld_in  <= 1'b0;
            sig_we       <= 1'b0;

            case (state)

                        SG_IDLE: begin
                busy <= 1'b0;
                if (start && mu_valid) begin
                    busy  <= 1'b1;
                    kappa <= 16'd0;
                    state <= SG_RHO_INIT;
                end
            end

                        // STEP 1: rho'' = H(K || rnd || mu)  (128 bytes = 16 lanes)
                        SG_RHO_INIT: begin
                shake_init <= 1'b1;
                sub        <= 5'd0;
                state      <= SG_RHO_ABS;
            end

            SG_RHO_ABS: begin
                if (shake_rdy && !shake_busy) begin
                    case (sub)
                    5'd0: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd0; shake_wr_lane_data<=sk_K[63:0];      sub<=5'd1; end
                    5'd1: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd1; shake_wr_lane_data<=sk_K[127:64];    sub<=5'd2; end
                    5'd2: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd2; shake_wr_lane_data<=sk_K[191:128];   sub<=5'd3; end
                    5'd3: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd3; shake_wr_lane_data<=sk_K[255:192];   sub<=5'd4; end
                    5'd4: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd4; shake_wr_lane_data<=rnd[63:0];       sub<=5'd5; end
                    5'd5: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd5; shake_wr_lane_data<=rnd[127:64];     sub<=5'd6; end
                    5'd6: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd6; shake_wr_lane_data<=rnd[191:128];    sub<=5'd7; end
                    5'd7: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd7; shake_wr_lane_data<=rnd[255:192];    sub<=5'd8; end
                    5'd8: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd8; shake_wr_lane_data<=mu[63:0];        sub<=5'd9; end
                    5'd9: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd9; shake_wr_lane_data<=mu[127:64];      sub<=5'd10; end
                    5'd10: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd10; shake_wr_lane_data<=mu[191:128];   sub<=5'd11; end
                    5'd11: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd11; shake_wr_lane_data<=mu[255:192];   sub<=5'd12; end
                    5'd12: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd12; shake_wr_lane_data<=mu[319:256];   sub<=5'd13; end
                    5'd13: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd13; shake_wr_lane_data<=mu[383:320];   sub<=5'd14; end
                    5'd14: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd14; shake_wr_lane_data<=mu[447:384];   sub<=5'd15; end
                    5'd15: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd15; shake_wr_lane_data<=mu[511:448];   sub<=5'd16; end
                    5'd16: begin
                        shake_wr_en <= 1'b1;
                        shake_wr_lane_idx <= 5'd16;
                        shake_wr_lane_data <= 64'h80_00_00_00_00_00_00_1F;
                        sub <= 5'd17;
                    end
                    5'd17: begin
                        shake_pad_and_permute <= 1'b1;
                        sub <= 5'd18;
                    end
                    5'd18: begin
                        if (shake_rdy && !shake_busy) begin
                            sub <= 5'd0;
                            state <= SG_RHO_SQZ;
                        end
                    end
                    default: sub <= 5'd0;
                    endcase
                end
            end

            // Squeeze 8 lanes -> rho_prime (64 bytes)
            SG_RHO_SQZ: begin
                if (shake_rdy && !shake_busy) begin
                    shake_rd_lane_idx <= sub[3:0];
                    case (sub)
                    5'd0: sub <= 5'd1;
                    5'd1: begin rho_prime[63:0]    <= shake_rd_lane_data; sub <= 5'd2; end
                    5'd2: begin rho_prime[127:64]  <= shake_rd_lane_data; sub <= 5'd3; end
                    5'd3: begin rho_prime[191:128] <= shake_rd_lane_data; sub <= 5'd4; end
                    5'd4: begin rho_prime[255:192] <= shake_rd_lane_data; sub <= 5'd5; end
                    5'd5: begin rho_prime[319:256] <= shake_rd_lane_data; sub <= 5'd6; end
                    5'd6: begin rho_prime[383:320] <= shake_rd_lane_data; sub <= 5'd7; end
                    5'd7: begin rho_prime[447:384] <= shake_rd_lane_data; sub <= 5'd8; end
                    5'd8: begin
                        rho_prime[511:448] <= shake_rd_lane_data;
                        poly_idx <= 4'd0;
                        up_byte  <= 8'd0;
                        sub      <= 5'd0;
                        state    <= SG_UP_S1;
                    end
                    default: sub <= 5'd0;
                    endcase
                end
            end

                                                SG_UP_S1: begin
                case (sub)
                5'd0: begin
                    sk_rd_addr <= 12'd128 + {poly_idx, 7'd0} + up_byte;
                    sub <= 5'd1;
                end
                5'd1: begin
                    sp_wr_en   <= 1'b1;
                    sp_wr_addr <= base_addr(SP_S1H + poly_idx) + {1'b0, up_byte, 1'b0};
                    sp_wr_data <= eta_coeff(sk_rd_data[3:0]);
                    sub <= 5'd2;
                end
                5'd2: begin
                    sp_wr_en   <= 1'b1;
                    sp_wr_addr <= base_addr(SP_S1H + poly_idx) + {1'b0, up_byte, 1'b0} + 14'd1;
                    sp_wr_data <= eta_coeff(sk_rd_data[7:4]);
                    if (up_byte == 8'd127) begin
                        up_byte <= 8'd0;
                        if (poly_idx == 4'd4) begin
                            // all s1 done -> NTT s1 group
                            ntt_src  <= SP_S1H;
                            ntt_dst  <= SP_S1H;
                            ntt_mode <= 1'b0;
                            ntt_poly <= 4'd0;
                            ntt_cnt  <= 4'd5;
                            ntt_ret  <= SG_UP_S2;
                            poly_idx <= 4'd0;
                            sub      <= 5'd0;
                            state    <= SG_NTT_LD;
                        end else begin
                            poly_idx <= poly_idx + 4'd1;
                            sub      <= 5'd0;
                        end
                    end else begin
                        up_byte <= up_byte + 8'd1;
                        sub     <= 5'd0;
                    end
                end
                default: sub <= 5'd0;
                endcase
            end

                                                SG_UP_S2: begin
                case (sub)
                5'd0: begin
                    sk_rd_addr <= 12'd768 + {poly_idx, 7'd0} + up_byte;
                    sub <= 5'd1;
                end
                5'd1: begin
                    sp_wr_en   <= 1'b1;
                    sp_wr_addr <= base_addr(SP_S2H + poly_idx) + {1'b0, up_byte, 1'b0};
                    sp_wr_data <= eta_coeff(sk_rd_data[3:0]);
                    sub <= 5'd2;
                end
                5'd2: begin
                    sp_wr_en   <= 1'b1;
                    sp_wr_addr <= base_addr(SP_S2H + poly_idx) + {1'b0, up_byte, 1'b0} + 14'd1;
                    sp_wr_data <= eta_coeff(sk_rd_data[7:4]);
                    if (up_byte == 8'd127) begin
                        up_byte <= 8'd0;
                        if (poly_idx == 4'd5) begin
                            ntt_src  <= SP_S2H;
                            ntt_dst  <= SP_S2H;
                            ntt_mode <= 1'b0;
                            ntt_poly <= 4'd0;
                            ntt_cnt  <= 4'd6;
                            ntt_ret  <= SG_UP_T0;
                            poly_idx <= 4'd0;
                            sub      <= 5'd0;
                            state    <= SG_NTT_LD;
                        end else begin
                            poly_idx <= poly_idx + 4'd1;
                            sub      <= 5'd0;
                        end
                    end else begin
                        up_byte <= up_byte + 8'd1;
                        sub     <= 5'd0;
                    end
                end
                default: sub <= 5'd0;
                endcase
            end

                                                SG_UP_T0: begin
                case (sub)
                // Read 13 bytes (sk_ram combinational: present at sub, capture next)
                5'd0: begin
                    sk_rd_addr <= 12'd1536 + poly_idx * 12'd416 + up_byte*12'd13 + sub;                      sub <= 5'd1;
                end
                5'd1: begin t0_buf[7:0]    <= sk_rd_data; sk_rd_addr <= 12'd1536 + poly_idx*12'd416 + up_byte*12'd13 + 5'd1; sub <= 5'd2; end
                5'd2: begin t0_buf[15:8]   <= sk_rd_data; sk_rd_addr <= 12'd1536 + poly_idx*12'd416 + up_byte*12'd13 + 5'd2; sub <= 5'd3; end
                5'd3: begin t0_buf[23:16]  <= sk_rd_data; sk_rd_addr <= 12'd1536 + poly_idx*12'd416 + up_byte*12'd13 + 5'd3; sub <= 5'd4; end
                5'd4: begin t0_buf[31:24]  <= sk_rd_data; sk_rd_addr <= 12'd1536 + poly_idx*12'd416 + up_byte*12'd13 + 5'd4; sub <= 5'd5; end
                5'd5: begin t0_buf[39:32]  <= sk_rd_data; sk_rd_addr <= 12'd1536 + poly_idx*12'd416 + up_byte*12'd13 + 5'd5; sub <= 5'd6; end
                5'd6: begin t0_buf[47:40]  <= sk_rd_data; sk_rd_addr <= 12'd1536 + poly_idx*12'd416 + up_byte*12'd13 + 5'd6; sub <= 5'd7; end
                5'd7: begin t0_buf[55:48]  <= sk_rd_data; sk_rd_addr <= 12'd1536 + poly_idx*12'd416 + up_byte*12'd13 + 5'd7; sub <= 5'd8; end
                5'd8: begin t0_buf[63:56]  <= sk_rd_data; sk_rd_addr <= 12'd1536 + poly_idx*12'd416 + up_byte*12'd13 + 5'd8; sub <= 5'd9; end
                5'd9: begin t0_buf[71:64]  <= sk_rd_data; sk_rd_addr <= 12'd1536 + poly_idx*12'd416 + up_byte*12'd13 + 5'd9; sub <= 5'd10; end
                5'd10: begin t0_buf[79:72]  <= sk_rd_data; sk_rd_addr <= 12'd1536 + poly_idx*12'd416 + up_byte*12'd13 + 5'd10; sub <= 5'd11; end
                5'd11: begin t0_buf[87:80]  <= sk_rd_data; sk_rd_addr <= 12'd1536 + poly_idx*12'd416 + up_byte*12'd13 + 5'd11; sub <= 5'd12; end
                5'd12: begin t0_buf[95:88]  <= sk_rd_data; sk_rd_addr <= 12'd1536 + poly_idx*12'd416 + up_byte*12'd13 + 5'd12; sub <= 5'd13; end
                5'd13: begin
                    t0_buf[103:96] <= sk_rd_data;   // all 13 bytes captured
                    sub <= 5'd14;
                end
                                5'd14: begin sp_wr_en <= 1'b1; sp_wr_addr <= base_addr(SP_T0H+poly_idx) + {up_byte, 3'd0};   sp_wr_data <= t0_coeff(t0_buf, 3'd0); sub <= 5'd15; end
                5'd15: begin sp_wr_en <= 1'b1; sp_wr_addr <= base_addr(SP_T0H+poly_idx) + {up_byte, 3'd0}+14'd1; sp_wr_data <= t0_coeff(t0_buf, 3'd1); sub <= 5'd16; end
                5'd16: begin sp_wr_en <= 1'b1; sp_wr_addr <= base_addr(SP_T0H+poly_idx) + {up_byte, 3'd0}+14'd2; sp_wr_data <= t0_coeff(t0_buf, 3'd2); sub <= 5'd17; end
                5'd17: begin sp_wr_en <= 1'b1; sp_wr_addr <= base_addr(SP_T0H+poly_idx) + {up_byte, 3'd0}+14'd3; sp_wr_data <= t0_coeff(t0_buf, 3'd3); sub <= 5'd18; end
                5'd18: begin sp_wr_en <= 1'b1; sp_wr_addr <= base_addr(SP_T0H+poly_idx) + {up_byte, 3'd0}+14'd4; sp_wr_data <= t0_coeff(t0_buf, 3'd4); sub <= 5'd19; end
                5'd19: begin sp_wr_en <= 1'b1; sp_wr_addr <= base_addr(SP_T0H+poly_idx) + {up_byte, 3'd0}+14'd5; sp_wr_data <= t0_coeff(t0_buf, 3'd5); sub <= 5'd20; end
                5'd20: begin sp_wr_en <= 1'b1; sp_wr_addr <= base_addr(SP_T0H+poly_idx) + {up_byte, 3'd0}+14'd6; sp_wr_data <= t0_coeff(t0_buf, 3'd6); sub <= 5'd21; end
                5'd21: begin
                    sp_wr_en <= 1'b1;
                    sp_wr_addr <= base_addr(SP_T0H+poly_idx) + {up_byte, 3'd0} + 14'd7;
                    sp_wr_data <= t0_coeff(t0_buf, 3'd7);
                    if (up_byte == 8'd31) begin
                        up_byte <= 8'd0;
                        if (poly_idx == 4'd5) begin
                            ntt_src  <= SP_T0H;
                            ntt_dst  <= SP_T0H;
                            ntt_mode <= 1'b0;
                            ntt_poly <= 4'd0;
                            ntt_cnt  <= 4'd6;
                            ntt_ret  <= SG_EM_INIT;
                            poly_idx <= 4'd0;
                            sub      <= 5'd0;
                            state    <= SG_NTT_LD;
                        end else begin
                            poly_idx <= poly_idx + 4'd1;
                            sub      <= 5'd0;
                        end
                    end else begin
                        up_byte <= up_byte + 8'd1;
                        sub     <= 5'd0;
                    end
                end
                default: sub <= 5'd0;
                endcase
            end

                        // Generic NTT: load slot ntt_src, run, store to ntt_dst
                        SG_NTT_LD: begin
                if (!ntt_busy) begin
                    if (coeff_idx <= 9'd255) begin
                        sp_rd_addr <= base_addr(ntt_src) + coeff_idx;
                    end
                    if (coeff_idx >= 9'd2 && coeff_idx <= 9'd257) begin
                        ntt_ext_we   <= 1'b1;
                        ntt_ext_addr <= coeff_idx[7:0] - 8'd2;
                        ntt_ext_din  <= sp_rd_data;
                    end else begin
                        ntt_ext_we <= 1'b0;
                    end
                    if (coeff_idx == 9'd257) begin
                        coeff_idx <= 9'd0;
                        state     <= SG_NTT_RUN;
                    end else begin
                        coeff_idx <= coeff_idx + 9'd1;
                    end
                end
            end

            SG_NTT_RUN: begin
                ntt_start     <= 1'b1;
                ntt_intt_mode <= ntt_mode;
                state         <= SG_NTT_WAIT;
            end

            SG_NTT_WAIT: begin
                if (ntt_done) begin
                    coeff_idx <= 9'd0;
                    state     <= SG_NTT_ST;
                end
            end

            SG_NTT_ST: begin
                if (coeff_idx <= 9'd255) begin
                    ntt_ext_addr <= coeff_idx[7:0];
                end
                if (coeff_idx >= 9'd2 && coeff_idx <= 9'd257) begin
                    sp_wr_en   <= 1'b1;
                    sp_wr_addr <= base_addr(ntt_dst) + (coeff_idx - 9'd2);
                    sp_wr_data <= ntt_ext_dout;
                end else begin
                    sp_wr_en <= 1'b0;
                end
                if (coeff_idx == 9'd257) begin
                    coeff_idx <= 9'd0;
                    if (ntt_poly < ntt_cnt - 4'd1) begin
                        ntt_poly <= ntt_poly + 4'd1;
                        ntt_src  <= ntt_src + 6'd1;
                        ntt_dst  <= ntt_dst + 6'd1;
                        state    <= SG_NTT_LD;
                    end else begin
                        state <= ntt_ret;
                    end
                end else begin
                    coeff_idx <= coeff_idx + 9'd1;
                end
            end

                                                SG_EM_INIT: begin
                shake_init <= 1'b1;
                em_nonce   <= kappa + {12'd0, em_poly};
                sub        <= 5'd0;
                state      <= SG_EM_ABS;
            end

            SG_EM_ABS: begin
                if (shake_rdy && !shake_busy) begin
                    case (sub)
                    5'd0: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd0; shake_wr_lane_data<=rho_prime[63:0];    sub<=5'd1; end
                    5'd1: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd1; shake_wr_lane_data<=rho_prime[127:64];  sub<=5'd2; end
                    5'd2: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd2; shake_wr_lane_data<=rho_prime[191:128]; sub<=5'd3; end
                    5'd3: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd3; shake_wr_lane_data<=rho_prime[255:192]; sub<=5'd4; end
                    5'd4: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd4; shake_wr_lane_data<=rho_prime[319:256]; sub<=5'd5; end
                    5'd5: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd5; shake_wr_lane_data<=rho_prime[383:320]; sub<=5'd6; end
                    5'd6: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd6; shake_wr_lane_data<=rho_prime[447:384]; sub<=5'd7; end
                    5'd7: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd7; shake_wr_lane_data<=rho_prime[511:448]; sub<=5'd8; end
                    5'd8: begin
                        shake_wr_en <= 1'b1;
                        shake_wr_lane_idx <= 5'd8;
                        // nonce(2B LE) at bytes 64-65, 0x1F pad at byte 66
                        shake_wr_lane_data <= {40'd0, 8'h1F, em_nonce[15:8], em_nonce[7:0]};
                        sub <= 5'd9;
                    end
                    5'd9: begin
                        shake_wr_en <= 1'b1;
                        shake_wr_lane_idx <= 5'd16;
                        shake_wr_lane_data <= 64'h80_00_00_00_00_00_00_00;   // 0x80 at byte 135
                        sub <= 5'd10;
                    end
                    5'd10: begin
                        shake_pad_and_permute <= 1'b1;
                        sub <= 5'd11;
                    end
                    5'd11: begin
                        if (shake_rdy && !shake_busy) begin
                            shake_rd_lane_idx <= 5'd0;
                            em_lane    <= 5'd0;
                            em_byte    <= 3'd0;
                            em_block   <= 3'd0;
                            em_bcnt    <= 3'd0;
                            em_grp_idx <= 8'd0;
                            em_grp     <= 40'd0;
                            sub        <= 5'd0;
                            state      <= SG_EM_BYTE;
                        end
                    end
                    default: sub <= 5'd0;
                    endcase
                end
            end

                        SG_EM_BYTE: begin
                em_grp[em_bcnt*8 +: 8] <= shake_rd_lane_data[em_byte*8 +: 8];
                em_bcnt <= em_bcnt + 3'd1;
                                if (em_byte == 3'd7) begin
                    em_byte <= 3'd0;
                    if (em_lane == 5'd16) begin
                        em_lane  <= 5'd0;
                        em_block <= em_block + 3'd1;
                    end else begin
                        em_lane <= em_lane + 5'd1;
                        shake_rd_lane_idx <= em_lane + 5'd1;
                    end
                end else begin
                    em_byte <= em_byte + 3'd1;
                end
                                if (em_byte == 3'd7 && em_lane == 5'd16)
                    state <= SG_EM_PERM2;
                else if (em_bcnt == 3'd4)
                    state <= SG_EM_WR0;
                else
                    state <= SG_EM_BYTE;
            end

                        SG_EM_WR0: begin
                sp_wr_en   <= 1'b1;
                sp_wr_addr <= base_addr(SP_Y + em_poly) + {em_grp_idx, 1'b0};
                sp_wr_data <= polyz_coeff({em_grp[19:16], em_grp[15:8], em_grp[7:0]});
                state      <= SG_EM_WR1;
            end

                        SG_EM_WR1: begin
                sp_wr_en   <= 1'b1;
                sp_wr_addr <= base_addr(SP_Y + em_poly) + {em_grp_idx, 1'b0} + 14'd1;
                sp_wr_data <= polyz_coeff({em_grp[39:32], em_grp[31:24], em_grp[23:20]});
                em_grp_idx <= em_grp_idx + 8'd1;
                em_bcnt    <= 3'd0;
                if (em_grp_idx == 8'd127) begin
                                        if (em_poly == 4'd4) begin
                        // all y done -> NTT y
                        ntt_src  <= SP_Y;
                        ntt_dst  <= SP_YH;
                        ntt_mode <= 1'b0;
                        ntt_poly <= 4'd0;
                        ntt_cnt  <= 4'd5;
                        ntt_ret  <= SG_MM_CLR_ACC;
                        em_poly  <= 4'd0;
                        state    <= SG_NTT_LD;
                    end else begin
                        em_poly <= em_poly + 4'd1;
                        state  <= SG_EM_INIT;
                    end
                end else begin
                    state <= SG_EM_BYTE;
                end
            end

            SG_EM_PERM2: begin
                shake_permute <= 1'b1;
                state <= SG_EM_PERM2W;
            end

            SG_EM_PERM2W: begin
                if (shake_rdy && !shake_busy) begin
                    shake_rd_lane_idx <= 5'd0;
                    em_lane <= 5'd0;
                    em_byte <= 3'd0;
                    state  <= SG_EM_BYTE;
                end
            end

                                                SG_MM_CLR_ACC: begin
                sp_wr_en   <= 1'b1;
                sp_wr_addr <= base_addr(SP_W0 + mat_i) + coeff_idx;
                sp_wr_data <= 23'd0;
                if (coeff_idx == 9'd255) begin
                    coeff_idx <= 9'd0;
                    coeff_cnt <= 9'd0;
                    mat_j     <= 3'd0;
                    state     <= SG_MM_EXPA_INIT;
                end else begin
                    coeff_idx <= coeff_idx + 9'd1;
                end
            end

            // ExpandA: SHAKE-128(rho || j || i)
            SG_MM_EXPA_INIT: begin
                s128_init <= 1'b1;
                sub       <= 5'd0;
                coeff_cnt <= 9'd0;
                state     <= SG_MM_EXPA_ABS;
            end

            SG_MM_EXPA_ABS: begin
                if (s128_rdy && !s128_busy) begin
                    case (sub)
                    5'd0: begin s128_wr_en<=1; s128_wr_lane_idx<=5'd0; s128_wr_lane_data<=sk_rho[63:0];    sub<=5'd1; end
                    5'd1: begin s128_wr_en<=1; s128_wr_lane_idx<=5'd1; s128_wr_lane_data<=sk_rho[127:64];  sub<=5'd2; end
                    5'd2: begin s128_wr_en<=1; s128_wr_lane_idx<=5'd2; s128_wr_lane_data<=sk_rho[191:128]; sub<=5'd3; end
                    5'd3: begin s128_wr_en<=1; s128_wr_lane_idx<=5'd3; s128_wr_lane_data<=sk_rho[255:192]; sub<=5'd4; end
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
                            rej_phase    <= 2'd0;
                            sub          <= 5'd0;
                            state        <= SG_MM_EXPA_FEED;
                        end
                    end
                    default: sub <= 5'd0;
                    endcase
                end
            end

            // Rejection sampling: 3 bytes -> candidate < Q
            SG_MM_EXPA_FEED: begin
                case (rej_phase)
                2'd0: begin
                    rej_b0 <= s128_rd_lane_data[byte_in_lane*8 +: 8];
                    rej_phase <= 2'd1;
                    if (byte_in_lane == 3'd7) begin
                        byte_in_lane <= 3'd0;
                        if (lane_cnt >= SHAKE128_RATE_LANES - 1) begin
                            state <= SG_MM_EXPA_SQZ;
                        end else begin
                            lane_cnt <= lane_cnt + 5'd1;
                            s128_rd_lane_idx <= lane_cnt + 5'd1;
                        end
                    end else begin
                        byte_in_lane <= byte_in_lane + 3'd1;
                        s128_rd_lane_idx <= lane_cnt;
                    end
                end
                2'd1: begin
                    rej_b1 <= s128_rd_lane_data[byte_in_lane*8 +: 8];
                    rej_phase <= 2'd2;
                    if (byte_in_lane == 3'd7) begin
                        byte_in_lane <= 3'd0;
                        if (lane_cnt >= SHAKE128_RATE_LANES - 1) begin
                            state <= SG_MM_EXPA_SQZ;
                        end else begin
                            lane_cnt <= lane_cnt + 5'd1;
                            s128_rd_lane_idx <= lane_cnt + 5'd1;
                        end
                    end else begin
                        byte_in_lane <= byte_in_lane + 3'd1;
                        s128_rd_lane_idx <= lane_cnt;
                    end
                end
                2'd2: begin
                    rej_b2 <= s128_rd_lane_data[byte_in_lane*8 +: 8];
                    rej_phase <= 2'd3;
                    if (byte_in_lane == 3'd7) begin
                        byte_in_lane <= 3'd0;
                        if (lane_cnt >= SHAKE128_RATE_LANES - 1)
                            lane_cnt <= SHAKE128_RATE_LANES;
                        else begin
                            lane_cnt <= lane_cnt + 5'd1;
                            s128_rd_lane_idx <= lane_cnt + 5'd1;
                        end
                    end else begin
                        byte_in_lane <= byte_in_lane + 3'd1;
                        s128_rd_lane_idx <= lane_cnt;
                    end
                    state <= SG_MM_EXPA_STORE;
                end
                default: rej_phase <= 2'd0;
                endcase
            end

            SG_MM_EXPA_STORE: begin
                if (rej_candidate < `MLDSA_Q && coeff_cnt < 9'd256) begin
                    sp_wr_en   <= 1'b1;
                    sp_wr_addr <= base_addr(SP_AT) + coeff_cnt[7:0];
                    sp_wr_data <= rej_candidate;
                    coeff_cnt  <= coeff_cnt + 9'd1;
                end
                                rej_phase <= 2'd0;
                if (coeff_cnt >= 9'd256) begin
                    coeff_idx <= 9'd0;
                    state     <= SG_MM_PMUL_PIPE;
                end else begin
                    if (byte_in_lane == 3'd0 && lane_cnt >= SHAKE128_RATE_LANES)
                        state <= SG_MM_EXPA_SQZ;
                    else
                        state <= SG_MM_EXPA_FEED;
                end
            end

                                                SG_MM_EXPA_SQZ: begin
                if (s128_sq_seen) begin
                    s128_permute      <= 1'b0;
                    if (!s128_busy) begin
                        s128_sq_seen      <= 1'b0;
                        lane_cnt          <= 5'd0;
                        byte_in_lane      <= 3'd0;
                        s128_rd_lane_idx  <= 5'd0;
                        rej_phase         <= 2'd0;
                        state             <= SG_MM_EXPA_FEED;
                    end
                end else begin
                    s128_permute <= 1'b1;
                    if (s128_busy)
                        s128_sq_seen <= 1'b1;
                end
            end

                                                                        SG_MM_PMUL_PIPE: begin
                if (coeff_idx <= 9'd255) begin
                    sp_rd_addr  <= base_addr(SP_AT) + coeff_idx;
                    sp_rd2_addr <= base_addr(SP_YH + mat_j) + coeff_idx;
                end
                if (coeff_idx >= 9'd5 && coeff_idx <= 9'd260) begin
                    sp_rd3_addr <= base_addr(SP_W0 + mat_i) + (coeff_idx - 9'd5);
                end
                if (coeff_idx >= 9'd2 && coeff_idx <= 9'd257) begin
                    pmul_vld_in <= 1'b1;
                    pmul_a      <= sp_rd_data;
                    pmul_b      <= sp_rd2_data;
                end else begin
                    pmul_vld_in <= 1'b0;
                end
                if (pmul_vld_out) begin
                    madd_a         <= sp_rd3_data;                       madd_b         <= pmul_result;                       pmul_wr_idx    <= coeff_idx[7:0] - 8'd7;
                    pmul_acc_phase <= 1'b1;
                end else begin
                    pmul_acc_phase <= 1'b0;
                end
                if (pmul_acc_phase) begin
                    sp_wr_en   <= 1'b1;
                    sp_wr_addr <= base_addr(SP_W0 + mat_i) + pmul_wr_idx;
                    sp_wr_data <= madd_sum;
                end
                if (coeff_idx == 9'd263) begin
                    coeff_idx <= 9'd0;
                    state     <= SG_MM_NEXT_J;
                end else begin
                    coeff_idx <= coeff_idx + 9'd1;
                end
            end

            SG_MM_NEXT_J: begin
                if (mat_j < L - 4'd1) begin
                    mat_j     <= mat_j + 3'd1;
                    coeff_idx <= 9'd0;
                    coeff_cnt <= 9'd0;
                    state     <= SG_MM_EXPA_INIT;
                end else begin
                                        ntt_src  <= SP_W0 + mat_i;
                    ntt_dst  <= SP_W0 + mat_i;
                    ntt_mode <= 1'b1;
                    ntt_poly <= 4'd0;
                    ntt_cnt  <= 4'd1;
                    ntt_ret  <= SG_MM_DECOMP;
                    coeff_idx <= 9'd0;
                    state    <= SG_NTT_LD;
                end
            end

                                                SG_MM_DECOMP: begin
                if (coeff_idx <= 9'd255) begin
                    sp_rd_addr <= base_addr(SP_W0 + mat_i) + coeff_idx;
                end
                if (coeff_idx >= 9'd2 && coeff_idx <= 9'd257) begin
                    dc_in <= sp_rd_data;
                end
                if (coeff_idx >= 9'd3 && coeff_idx <= 9'd258) begin
                    sp_wr_en <= 1'b1;
                    if (sub == 5'd0) begin
                                                sp_wr_addr <= base_addr(SP_W1 + mat_i) + (coeff_idx - 9'd3);
                        sp_wr_data <= dc_r1;
                    end else begin
                                                sp_wr_addr <= base_addr(SP_W0 + mat_i) + (coeff_idx - 9'd3);
                        sp_wr_data <= dc_r0;
                    end
                end else begin
                    sp_wr_en <= 1'b0;
                end
                if (coeff_idx == 9'd258) begin
                    coeff_idx <= 9'd0;
                    if (sub == 5'd0) begin
                        sub <= 5'd1;
                    end else begin
                        sub  <= 5'd0;
                        state <= SG_MM_NEXT_I;
                    end
                end else begin
                    coeff_idx <= coeff_idx + 9'd1;
                end
            end

            SG_MM_NEXT_I: begin
                if (mat_i < K - 4'd1) begin
                    mat_i     <= mat_i + 3'd1;
                    mat_j     <= 3'd0;
                    coeff_idx <= 9'd0;
                    state     <= SG_MM_CLR_ACC;
                end else begin
                    mat_i <= 3'd0;
                    sub   <= 5'd0;
                    state <= SG_CT_INIT;
                end
            end

                                                SG_CT_INIT: begin
                shake_init <= 1'b1;
                sub        <= 5'd0;
                state      <= SG_CT_MU;
            end

            SG_CT_MU: begin
                if (shake_rdy && !shake_busy) begin
                    shake_wr_en <= 1'b1;
                    shake_wr_lane_idx <= sub[3:0];
                    shake_wr_lane_data <= mu[sub[2:0]*64 +: 64];
                    if (sub == 5'd7) begin
                        ct_lane        <= 5'd8;
                        ct_lane_total  <= 9'd8;
                        ct_byte_in_lane<= 3'd0;
                        ct_buf         <= 64'd0;
                        ct_poly        <= 3'd0;
                        ct_pair        <= 8'd0;
                        sub            <= 5'd0;
                        state          <= SG_CT_W1;
                    end else begin
                        sub <= sub + 5'd1;
                    end
                end
            end

            // Stream w1 bytes (2 coeffs/byte) into SHAKE lanes
            SG_CT_W1: begin
                if (shake_rdy && !shake_busy) begin
                    case (sub)
                    5'd0: begin
                        sp_rd_addr  <= base_addr(SP_W1 + ct_poly) + {ct_pair, 1'b0};
                        sp_rd2_addr <= base_addr(SP_W1 + ct_poly) + {ct_pair, 1'b0} + 14'd1;
                        sub <= 5'd1;
                    end
                    5'd1: sub <= 5'd2;
                    5'd2: begin
                        ct_even <= sp_rd_data;
                        ct_odd  <= sp_rd2_data;
                        sub     <= 5'd3;
                    end
                    5'd3: begin
                        ct_buf[ct_byte_in_lane*8 +: 8] <= ct_byte;
                        if (ct_byte_in_lane == 3'd7) begin
                            shake_wr_en <= 1'b1;
                            shake_wr_lane_idx <= ct_lane;
                            shake_wr_lane_data <= {ct_byte, ct_buf[55:0]};
                            ct_byte_in_lane <= 3'd0;
                            ct_lane        <= (ct_lane == 5'd16) ? 5'd0 : ct_lane + 5'd1;
                            ct_lane_total  <= ct_lane_total + 9'd1;
                            if (ct_pair == 8'd127 && ct_poly == 3'd5) begin
                                                                sub <= 5'd0;
                                state <= SG_CT_PAD;
                            end else begin
                                if (ct_pair == 8'd127) begin
                                    ct_poly <= ct_poly + 3'd1;
                                    ct_pair <= 8'd0;
                                end else begin
                                    ct_pair <= ct_pair + 8'd1;
                                end
                                if (ct_lane == 5'd16) begin
                                    state <= SG_CT_PERM;
                                end else begin
                                    sub <= 5'd0;
                                end
                            end
                        end else begin
                            ct_byte_in_lane <= ct_byte_in_lane + 3'd1;
                            if (ct_pair == 8'd127 && ct_poly == 3'd5) begin
                                sub <= 5'd0;
                                state <= SG_CT_PAD;
                            end else begin
                                if (ct_pair == 8'd127) begin
                                    ct_poly <= ct_poly + 3'd1;
                                    ct_pair <= 8'd0;
                                end else begin
                                    ct_pair <= ct_pair + 8'd1;
                                end
                                sub <= 5'd0;
                            end
                        end
                    end
                    default: sub <= 5'd0;
                    endcase
                end
            end

            SG_CT_PERM: begin
                shake_permute <= 1'b1;
                state <= SG_CT_PERMW;
            end

            SG_CT_PERMW: begin
                if (shake_rdy && !shake_busy) begin
                    sub <= 5'd0;
                    state <= SG_CT_W1;
                end
            end

            // Pad: 0x1F at lane 2 byte 0, 0x80 at lane 16 byte 7
            SG_CT_PAD: begin
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
                            sub <= 5'd0;
                            state <= SG_CT_SQZ;
                        end
                    end
                    default: sub <= 5'd0;
                    endcase
                end
            end

            SG_CT_PADW: begin
                if (shake_rdy && !shake_busy) begin
                    sub <= 5'd0;
                    state <= SG_CT_SQZ;
                end
            end

                        SG_CT_SQZ: begin
                if (shake_rdy && !shake_busy) begin
                    shake_rd_lane_idx <= sub[3:0];
                    case (sub)
                    5'd0: sub <= 5'd1;
                    5'd1: begin c_tilde[63:0]    <= shake_rd_lane_data; sub <= 5'd2; end
                    5'd2: begin c_tilde[127:64]  <= shake_rd_lane_data; sub <= 5'd3; end
                    5'd3: begin c_tilde[191:128] <= shake_rd_lane_data; sub <= 5'd4; end
                    5'd4: begin c_tilde[255:192] <= shake_rd_lane_data; sub <= 5'd5; end
                    5'd5: begin c_tilde[319:256] <= shake_rd_lane_data; sub <= 5'd6; end
                    5'd6: begin
                        c_tilde[383:320] <= shake_rd_lane_data;
                        // fresh SHAKE-256 for SampleInBall: clear ct-hash state
                        shake_init <= 1'b1;
                        sub <= 5'd0;
                        state <= SG_SIB_ABS;
                    end
                    default: sub <= 5'd0;
                    endcase
                end
            end

                                                SG_SIB_ABS: begin
                if (shake_rdy && !shake_busy) begin
                    shake_wr_en <= 1'b1;
                    shake_wr_lane_idx <= sub[2:0];
                    shake_wr_lane_data <= c_tilde[sub[2:0]*64 +: 64];
                    if (sub == 5'd5) begin
                        sub <= 5'd6;
                        state <= SG_SIB_PAD;
                    end else begin
                        sub <= sub + 5'd1;
                    end
                end
            end

            SG_SIB_PAD: begin
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
                            shake_rd_lane_idx <= 5'd0;
                            sib_lane <= 5'd0;
                            sib_block <= 1'b0;
                            sib_sub   <= 4'd0;
                            sub       <= 5'd0;
                            state     <= SG_SIB_SQZ;
                        end
                    end
                    default: sub <= 5'd0;
                    endcase
                end
            end

            // Squeeze 2 blocks (272 bytes): block0 -> slot 40, block1 -> slot 41
            SG_SIB_SQZ: begin
                if (shake_rdy && !shake_busy) begin
                    case (sib_sub)
                    4'd0: begin
                        shake_rd_lane_idx <= sib_lane;
                        sib_sub <= 4'd1;
                    end
                    4'd1: begin sp_wr_en<=1; sp_wr_addr <= (sib_block ? base_addr(SP_SC) : base_addr(SP_AT)) + sib_lane*8'd8 + 4'd0; sp_wr_data <= shake_rd_lane_data[7:0];    sib_sub<=4'd2; end
                    4'd2: begin sp_wr_en<=1; sp_wr_addr <= (sib_block ? base_addr(SP_SC) : base_addr(SP_AT)) + sib_lane*8'd8 + 4'd1; sp_wr_data <= shake_rd_lane_data[15:8];   sib_sub<=4'd3; end
                    4'd3: begin sp_wr_en<=1; sp_wr_addr <= (sib_block ? base_addr(SP_SC) : base_addr(SP_AT)) + sib_lane*8'd8 + 4'd2; sp_wr_data <= shake_rd_lane_data[23:16];  sib_sub<=4'd4; end
                    4'd4: begin sp_wr_en<=1; sp_wr_addr <= (sib_block ? base_addr(SP_SC) : base_addr(SP_AT)) + sib_lane*8'd8 + 4'd3; sp_wr_data <= shake_rd_lane_data[31:24];  sib_sub<=4'd5; end
                    4'd5: begin sp_wr_en<=1; sp_wr_addr <= (sib_block ? base_addr(SP_SC) : base_addr(SP_AT)) + sib_lane*8'd8 + 4'd4; sp_wr_data <= shake_rd_lane_data[39:32];  sib_sub<=4'd6; end
                    4'd6: begin sp_wr_en<=1; sp_wr_addr <= (sib_block ? base_addr(SP_SC) : base_addr(SP_AT)) + sib_lane*8'd8 + 4'd5; sp_wr_data <= shake_rd_lane_data[47:40];  sib_sub<=4'd7; end
                    4'd7: begin sp_wr_en<=1; sp_wr_addr <= (sib_block ? base_addr(SP_SC) : base_addr(SP_AT)) + sib_lane*8'd8 + 4'd6; sp_wr_data <= shake_rd_lane_data[55:48];  sib_sub<=4'd8; end
                    4'd8: begin
                        sp_wr_en <= 1'b1;
                        sp_wr_addr <= (sib_block ? base_addr(SP_SC) : base_addr(SP_AT)) + sib_lane*8'd8 + 4'd7;
                        sp_wr_data <= shake_rd_lane_data[63:56];
                        if (sib_lane == 5'd16) begin
                            sib_lane <= 5'd0;
                            if (sib_block == 1'b0) begin
                                sib_block <= 1'b1;
                                state     <= SG_SIB_PERM;
                            end else begin
                                state <= SG_SIB_ZERO;
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

            SG_SIB_PERM: begin
                shake_permute <= 1'b1;
                state <= SG_SIB_PERMW;
            end

            SG_SIB_PERMW: begin
                if (shake_rdy && !shake_busy) begin
                    sib_sub <= 4'd0;
                    state   <= SG_SIB_SQZ;
                end
            end

                        SG_SIB_ZERO: begin
                sp_wr_en   <= 1'b1;
                sp_wr_addr <= base_addr(SP_C) + coeff_idx;
                sp_wr_data <= 23'd0;
                if (coeff_idx == 9'd255) begin
                    coeff_idx <= 9'd0;
                    sib_sub   <= 4'd0;
                    state     <= SG_SIB_SIGS;
                end else begin
                    coeff_idx <= coeff_idx + 9'd1;
                end
            end

            // Read 8 sign bytes from slot 40 bytes 0..7
            SG_SIB_SIGS: begin
                case (sib_sub)
                4'd0: begin sp_rd_addr <= base_addr(SP_AT) + 4'd0; sib_sub <= 4'd1; end
                4'd1: sib_sub <= 4'd2;
                4'd2: begin sib_signs[7:0] <= sp_rd_data; sp_rd_addr <= base_addr(SP_AT) + 4'd1; sib_sub <= 4'd3; end
                4'd3: sib_sub <= 4'd4;
                4'd4: begin sib_signs[15:8] <= sp_rd_data; sp_rd_addr <= base_addr(SP_AT) + 4'd2; sib_sub <= 4'd5; end
                4'd5: sib_sub <= 4'd6;
                4'd6: begin sib_signs[23:16] <= sp_rd_data; sp_rd_addr <= base_addr(SP_AT) + 4'd3; sib_sub <= 4'd7; end
                4'd7: sib_sub <= 4'd8;
                4'd8: begin sib_signs[31:24] <= sp_rd_data; sp_rd_addr <= base_addr(SP_AT) + 4'd4; sib_sub <= 4'd9; end
                4'd9: sib_sub <= 4'd10;
                4'd10: begin sib_signs[39:32] <= sp_rd_data; sp_rd_addr <= base_addr(SP_AT) + 4'd5; sib_sub <= 4'd11; end
                4'd11: sib_sub <= 4'd12;
                4'd12: begin sib_signs[47:40] <= sp_rd_data; sp_rd_addr <= base_addr(SP_AT) + 4'd6; sib_sub <= 4'd13; end
                4'd13: sib_sub <= 4'd14;
                4'd14: begin sib_signs[55:48] <= sp_rd_data; sp_rd_addr <= base_addr(SP_AT) + 4'd7; sib_sub <= 4'd15; end
                4'd15: begin
                    sib_signs[63:56] <= sp_rd_data;
                    sib_i   <= 8'd207;
                    sib_pos <= 12'd8;
                    sub     <= 5'd0;
                    state   <= SG_SIB_BUILD;
                end
                default: sib_sub <= 4'd0;
                endcase
            end

            // SampleInBall: scan j bytes, build c
            SG_SIB_BUILD: begin
                case (sub)
                5'd0: begin
                    sp_rd_addr <= ch_byte_addr(sib_pos);
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
                        // c built -> NTT(c)
                        ntt_src  <= SP_C;
                        ntt_dst  <= SP_C;
                        ntt_mode <= 1'b0;
                        ntt_poly <= 4'd0;
                        ntt_cnt  <= 4'd1;
                        ntt_ret  <= SG_PM_C1;
                        poly_idx <= 4'd0;
                        state    <= SG_NTT_LD;
                    end else begin
                        sib_i <= sib_i + 8'd1;
                        sub   <= 5'd0;
                    end
                end
                default: sub <= 5'd0;
                endcase
            end

                                                // Pointwise c_hat * sX_hat -> products written directly into NTT SRAM
            SG_PM_C1: begin
                if (coeff_idx <= 9'd255) begin
                    sp_rd_addr  <= base_addr(SP_C) + coeff_idx;
                    sp_rd2_addr <= base_addr(SP_S1H + poly_idx) + coeff_idx;
                end
                if (coeff_idx >= 9'd2 && coeff_idx <= 9'd257) begin
                    pmul_vld_in <= 1'b1;
                    pmul_a      <= sp_rd_data;
                    pmul_b      <= sp_rd2_data;
                end else begin
                    pmul_vld_in <= 1'b0;
                end
                if (pmul_vld_out) begin
                    ntt_ext_we   <= 1'b1;
                    ntt_ext_addr <= coeff_idx[7:0] - 8'd7;
                    ntt_ext_din  <= pmul_result;
                end
                if (coeff_idx == 9'd263) begin
                    coeff_idx <= 9'd0;
                    pm_phase  <= 2'd0;                       state     <= SG_PM_RUN;
                end else begin
                    coeff_idx <= coeff_idx + 9'd1;
                end
            end

            SG_PM_RUN: begin
                ntt_start     <= 1'b1;
                ntt_intt_mode <= 1'b1;
                state         <= SG_PM_WAIT;
            end

            SG_PM_WAIT: begin
                if (ntt_done) begin
                    coeff_idx <= 9'd0;
                    case (pm_phase)
                    2'd0: state <= SG_Z_STORE;
                    2'd1: state <= SG_R0_STORE;
                    default: state <= SG_CT0_STORE;
                    endcase
                end
            end

                        SG_Z_STORE: begin
                if (coeff_idx <= 9'd255) begin
                    ntt_ext_addr <= coeff_idx[7:0];
                    sp_rd_addr   <= base_addr(SP_Y + poly_idx) + coeff_idx;
                end
                if (coeff_idx >= 9'd2 && coeff_idx <= 9'd257) begin
                    madd_a <= ntt_ext_dout;
                    madd_b <= sp_rd_data;
                end
                if (coeff_idx >= 9'd3 && coeff_idx <= 9'd258) begin
                    sp_wr_en   <= 1'b1;
                    sp_wr_addr <= base_addr(SP_Y + poly_idx) + (coeff_idx - 9'd3);
                    sp_wr_data <= madd_sum;
                    if (!((madd_sum < Z_BOUND) || (madd_sum > Q_MINUS_Z)))
                        z_fail <= 1'b1;
                end else begin
                    sp_wr_en <= 1'b0;
                end
                if (coeff_idx == 9'd258) begin
                    coeff_idx <= 9'd0;
                    if (z_fail) begin
                        z_fail <= 1'b0;
                        state  <= SG_REJECT;
                    end else if (poly_idx < 4'd4) begin
                        poly_idx <= poly_idx + 4'd1;
                        state    <= SG_PM_C1;
                    end else begin
                        poly_idx <= 4'd0;
                        z_fail   <= 1'b0;
                        state    <= SG_PM_C2;
                    end
                end else begin
                    coeff_idx <= coeff_idx + 9'd1;
                end
            end

                                                SG_PM_C2: begin
                if (coeff_idx <= 9'd255) begin
                    sp_rd_addr  <= base_addr(SP_C) + coeff_idx;
                    sp_rd2_addr <= base_addr(SP_S2H + poly_idx) + coeff_idx;
                end
                if (coeff_idx >= 9'd2 && coeff_idx <= 9'd257) begin
                    pmul_vld_in <= 1'b1;
                    pmul_a      <= sp_rd_data;
                    pmul_b      <= sp_rd2_data;
                end else begin
                    pmul_vld_in <= 1'b0;
                end
                if (pmul_vld_out) begin
                    ntt_ext_we   <= 1'b1;
                    ntt_ext_addr <= coeff_idx[7:0] - 8'd7;
                    ntt_ext_din  <= pmul_result;
                end
                if (coeff_idx == 9'd263) begin
                    coeff_idx <= 9'd0;
                    pm_phase  <= 2'd1;                       state     <= SG_PM_RUN;
                end else begin
                    coeff_idx <= coeff_idx + 9'd1;
                end
            end

            SG_R0_STORE: begin
                if (coeff_idx <= 9'd255) begin
                    ntt_ext_addr <= coeff_idx[7:0];
                    sp_rd2_addr  <= base_addr(SP_W0 + poly_idx) + coeff_idx;
                end
                if (coeff_idx >= 9'd2 && coeff_idx <= 9'd257) begin
                    madd_a <= sp_rd2_data;                           madd_b <= ntt_ext_dout;                      end
                if (coeff_idx >= 9'd3 && coeff_idx <= 9'd258) begin
                    sp_wr_en   <= 1'b1;
                    sp_wr_addr <= base_addr(SP_W0 + poly_idx) + (coeff_idx - 9'd3);
                    sp_wr_data <= madd_diff;                         if (!((madd_diff < R0_BOUND) || (madd_diff > Q_MINUS_R0)))
                        r0_fail <= 1'b1;
                end else begin
                    sp_wr_en <= 1'b0;
                end
                if (coeff_idx == 9'd258) begin
                    coeff_idx <= 9'd0;
                    if (r0_fail) begin
                        r0_fail <= 1'b0;
                        state  <= SG_REJECT;
                    end else if (poly_idx < 4'd5) begin
                        poly_idx <= poly_idx + 4'd1;
                        state    <= SG_PM_C2;
                    end else begin
                        poly_idx <= 4'd0;
                        r0_fail  <= 1'b0;
                        state    <= SG_PM_C3;
                    end
                end else begin
                    coeff_idx <= coeff_idx + 9'd1;
                end
            end

                                                SG_PM_C3: begin
                if (coeff_idx <= 9'd255) begin
                    sp_rd_addr  <= base_addr(SP_C) + coeff_idx;
                    sp_rd2_addr <= base_addr(SP_T0H + poly_idx) + coeff_idx;
                end
                if (coeff_idx >= 9'd2 && coeff_idx <= 9'd257) begin
                    pmul_vld_in <= 1'b1;
                    pmul_a      <= sp_rd_data;
                    pmul_b      <= sp_rd2_data;
                end else begin
                    pmul_vld_in <= 1'b0;
                end
                if (pmul_vld_out) begin
                    ntt_ext_we   <= 1'b1;
                    ntt_ext_addr <= coeff_idx[7:0] - 8'd7;
                    ntt_ext_din  <= pmul_result;
                end
                if (coeff_idx == 9'd263) begin
                    coeff_idx <= 9'd0;
                    pm_phase  <= 2'd2;                       state     <= SG_PM_RUN;
                end else begin
                    coeff_idx <= coeff_idx + 9'd1;
                end
            end

            SG_CT0_STORE: begin
                if (coeff_idx <= 9'd255) begin
                    ntt_ext_addr <= coeff_idx[7:0];
                    sp_rd2_addr  <= base_addr(SP_W0 + poly_idx) + coeff_idx;
                end
                if (coeff_idx >= 9'd2 && coeff_idx <= 9'd257) begin
                    madd_a <= ntt_ext_dout;                          madd_b <= sp_rd2_data;                       end
                if (coeff_idx >= 9'd3 && coeff_idx <= 9'd258) begin
                    sp_wr_en   <= 1'b1;
                    sp_wr_addr <= base_addr(SP_W0 + poly_idx) + (coeff_idx - 9'd3);
                    sp_wr_data <= madd_sum;                          if (!((madd_a < CT0_BOUND) || (madd_a > Q_MINUS_CT0)))
                        ct0_fail <= 1'b1;
                end else begin
                    sp_wr_en <= 1'b0;
                end
                if (coeff_idx == 9'd258) begin
                    coeff_idx <= 9'd0;
                    if (ct0_fail) begin
                        ct0_fail <= 1'b0;
                        state  <= SG_REJECT;
                    end else if (poly_idx < 4'd5) begin
                        poly_idx <= poly_idx + 4'd1;
                        state    <= SG_PM_C3;
                    end else begin
                        poly_idx <= 4'd0;
                        ct0_fail <= 1'b0;
                        coeff_idx <= 9'd0;
                        h_clr     <= 1'b1;
                        state     <= SG_HCLR;
                    end
                end else begin
                    coeff_idx <= coeff_idx + 9'd1;
                end
            end

                                                SG_HINTS: begin
                if (coeff_idx <= 9'd255) begin
                    sp_rd_addr  <= base_addr(SP_W0 + hk) + coeff_idx;
                    sp_rd2_addr <= base_addr(SP_W1 + hk) + coeff_idx;
                end
                if (coeff_idx >= 9'd2 && coeff_idx <= 9'd257) begin
                    madd_a <= sp_rd_data;                            madd_b <= sp_rd2_data;                       end
                if (coeff_idx >= 9'd3 && coeff_idx <= 9'd258) begin
                    if (hint_bit) begin
                        if (h_n == 7'd55) begin
                            h_fail <= 1'b1;
                        end else begin
                            h_arr[h_n] <= coeff_idx[7:0] - 8'd3;
                            h_n        <= h_n + 7'd1;
                        end
                    end
                end
                if (coeff_idx == 9'd258) begin
                    coeff_idx <= 9'd0;
                                                            h_arr[OMEGA + hk] <= (hint_bit && (h_n != 7'd55)) ? h_n + 7'd1 : h_n;
                    if (h_fail) begin
                        h_fail <= 1'b0;
                        state  <= SG_REJECT;
                    end else if (hk == 3'd5) begin
                        pk_byte <= 12'd0;
                        sub     <= 5'd0;
                        state   <= SG_PACK_CT;
                    end else begin
                        hk <= hk + 3'd1;
                    end
                end else begin
                    coeff_idx <= coeff_idx + 9'd1;
                end
            end

            // Clear hint-position bytes (h_arr[0..54]) before each hint pass so
                        SG_HCLR: begin
                if (coeff_idx <= 9'd54) begin
                    h_arr[coeff_idx[5:0]] <= 8'd0;
                    coeff_idx <= coeff_idx + 9'd1;
                end else begin
                    coeff_idx <= 9'd0;
                    h_clr     <= 1'b0;
                    h_n       <= 7'd0;
                    hk        <= 3'd0;
                    state     <= SG_HINTS;
                end
            end

                                                SG_PACK_CT: begin
                sig_we    <= 1'b1;
                sig_addr  <= pk_byte[11:0];
                sig_wdata <= c_tilde[pk_byte[5:0]*8 +: 8];
                if (pk_byte == 12'd47) begin
                    z_poly   <= 4'd0;
                    z_grp    <= 8'd0;
                    z_sub    <= 4'd0;
                    pk_byte  <= 12'd0;
                    state    <= SG_PACK_Z;
                end else begin
                    pk_byte <= pk_byte + 12'd1;
                end
            end

            // polyz pack: 2 coeffs -> 5 bytes
            SG_PACK_Z: begin
                case (z_sub)
                4'd0: begin
                    sp_rd_addr  <= base_addr(SP_Y + z_poly) + {z_grp, 1'b0};
                    sp_rd2_addr <= base_addr(SP_Y + z_poly) + {z_grp, 1'b0} + 14'd1;
                    z_sub <= 4'd1;
                end
                4'd1: z_sub <= 4'd2;
                4'd2: begin
                    zt0 <= z_pack_t(sp_rd_data);
                    zt1 <= z_pack_t(sp_rd2_data);
                    z_sub <= 4'd3;
                end
                4'd3: z_sub <= 4'd4;
                4'd4: begin
                    sig_we    <= 1'b1;
                    sig_addr  <= 12'd48 + z_poly*12'd640 + z_grp*12'd5 + 12'd0;
                    sig_wdata <= zt0[7:0];
                    z_sub <= 4'd5;
                end
                4'd5: begin
                    sig_we    <= 1'b1;
                    sig_addr  <= 12'd48 + z_poly*12'd640 + z_grp*12'd5 + 12'd1;
                    sig_wdata <= zt0[15:8];
                    z_sub <= 4'd6;
                end
                4'd6: begin
                    sig_we    <= 1'b1;
                    sig_addr  <= 12'd48 + z_poly*12'd640 + z_grp*12'd5 + 12'd2;
                    sig_wdata <= {zt1[3:0], zt0[19:16]};
                    z_sub <= 4'd7;
                end
                4'd7: begin
                    sig_we    <= 1'b1;
                    sig_addr  <= 12'd48 + z_poly*12'd640 + z_grp*12'd5 + 12'd3;
                    sig_wdata <= zt1[11:4];
                    z_sub <= 4'd8;
                end
                4'd8: begin
                    sig_we    <= 1'b1;
                    sig_addr  <= 12'd48 + z_poly*12'd640 + z_grp*12'd5 + 12'd4;
                    sig_wdata <= zt1[19:12];
                    if (z_grp == 8'd127) begin
                        z_grp <= 8'd0;
                        if (z_poly == 4'd4) begin
                            pk_byte <= 12'd0;
                            sub     <= 5'd0;
                            state   <= SG_PACK_H;
                        end else begin
                            z_poly <= z_poly + 4'd1;
                            z_sub  <= 4'd0;
                        end
                    end else begin
                        z_grp <= z_grp + 8'd1;
                        z_sub <= 4'd0;
                    end
                end
                default: z_sub <= 4'd0;
                endcase
            end

            SG_PACK_H: begin
                sig_we    <= 1'b1;
                sig_addr  <= 12'd3248 + pk_byte;
                sig_wdata <= h_arr[pk_byte[5:0]];
                if (pk_byte == 12'd60) begin
                    pk_byte <= 12'd0;
                    state   <= SG_DONE;
                end else begin
                    pk_byte <= pk_byte + 12'd1;
                end
            end

                        SG_DONE: begin
                done      <= 1'b1;
                busy      <= 1'b0;
                sig_valid <= 1'b1;
                kappa_out <= kappa;
                state     <= SG_IDLE;
            end

            SG_REJECT: begin
                sig_valid <= 1'b0;
                kappa     <= kappa + {11'd0, L};
                em_poly   <= 4'd0;
                state     <= SG_EM_INIT;
            end

            default: state <= SG_IDLE;

            endcase
        end
    end

            integer ii;
    integer jj;
    initial begin
        for (ii = 0; ii < 42*256; ii = ii + 1)
            spad[ii] = 23'd0;
        for (jj = 0; jj < 61; jj = jj + 1)
            h_arr[jj] = 8'd0;
    end

endmodule
