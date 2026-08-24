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

module mldsa_top (
    input  wire          clk,
    input  wire          rst_n,

                input  wire          wr_en,
    input  wire [15:0]   wr_addr,
    input  wire [31:0]   wr_data,

    input  wire          rd_en,
    input  wire [15:0]   rd_addr,
    output reg  [31:0]   rd_data
);

                reg [31:0] ctrl_reg;
    reg [31:0] seed_reg   [0:7];
    reg [31:0] rho_reg    [0:7];
    reg [31:0] K_reg      [0:7];
    reg [31:0] tr_reg     [0:7];
    reg [31:0] rnd_reg    [0:7];
    reg [31:0] ctilde_reg [0:7];
    reg [31:0] mu_lo_reg  [0:7];
    reg [31:0] mu_hi_reg  [0:7];

                reg [31:0] poly_z_ram  [0:255];
    reg [31:0] poly_r0_ram [0:255];

                reg [7:0]  pk_ram [0:1951];  // 1952 bytes: rho(32) + t1(1920)
    reg [7:0]  sk_ram [0:4031];  // 4032 bytes: rho(32)+K(32)+tr(64)+s1(1280)+s2(1536)+t0(704)
    reg [7:0]  sig_ram [0:3311]; // 3309 bytes + pad to 32-bit boundary (0x3000-0x34EF)

        wire        kg_pk_we_w, kg_sk_we_w;
    wire [10:0] kg_pk_addr_w;
    wire [11:0] kg_sk_addr_w;
    wire [7:0]  kg_pk_wdata_w, kg_sk_wdata_w;
    wire [10:0] kg_pk_rd_addr_w;
    wire [7:0]  kg_pk_rd_data_w;

        wire        sg_sig_we_w;
    wire [11:0] sg_sig_addr_w;
    wire [7:0]  sg_sig_wdata_w;

    // Combinational PK readback port (used by keygen for tr = SHAKE-256(pk))
    assign kg_pk_rd_data_w = pk_ram[kg_pk_rd_addr_w];

                always @(posedge clk) begin
        if (kg_pk_we_w)
            pk_ram[kg_pk_addr_w] <= kg_pk_wdata_w;
        if (kg_sk_we_w)
            sk_ram[kg_sk_addr_w] <= kg_sk_wdata_w;
        if (sg_sig_we_w)
            sig_ram[sg_sig_addr_w] <= sg_sig_wdata_w;
    end

            integer ram_init_i;
    initial begin
        for (ram_init_i = 0; ram_init_i < 256; ram_init_i = ram_init_i + 1) begin
            poly_z_ram [ram_init_i] = 32'd0;
            poly_r0_ram[ram_init_i] = 32'd0;
        end
        for (ram_init_i = 0; ram_init_i < 1952; ram_init_i = ram_init_i + 1)
            pk_ram[ram_init_i] = 8'd0;
        for (ram_init_i = 0; ram_init_i < 4032; ram_init_i = ram_init_i + 1)
            sk_ram[ram_init_i] = 8'd0;
        for (ram_init_i = 0; ram_init_i < 3312; ram_init_i = ram_init_i + 1)
            sig_ram[ram_init_i] = 8'd0;
    end

        wire [255:0] seed_xi = {seed_reg[7],seed_reg[6],seed_reg[5],seed_reg[4],
                             seed_reg[3],seed_reg[2],seed_reg[1],seed_reg[0]};
    wire [255:0] sk_rho  = {rho_reg[7],rho_reg[6],rho_reg[5],rho_reg[4],
                             rho_reg[3],rho_reg[2],rho_reg[1],rho_reg[0]};
    wire [255:0] sk_K    = {K_reg[7],K_reg[6],K_reg[5],K_reg[4],
                             K_reg[3],K_reg[2],K_reg[1],K_reg[0]};
    wire [255:0] sk_tr   = {tr_reg[7],tr_reg[6],tr_reg[5],tr_reg[4],
                             tr_reg[3],tr_reg[2],tr_reg[1],tr_reg[0]};
    wire [255:0] rnd_w   = {rnd_reg[7],rnd_reg[6],rnd_reg[5],rnd_reg[4],
                             rnd_reg[3],rnd_reg[2],rnd_reg[1],rnd_reg[0]};
    wire [255:0] c_tilde_orig_w =
                            {ctilde_reg[7],ctilde_reg[6],ctilde_reg[5],ctilde_reg[4],
                             ctilde_reg[3],ctilde_reg[2],ctilde_reg[1],ctilde_reg[0]};
    wire [511:0] mu_w    = {mu_hi_reg[7],mu_hi_reg[6],mu_hi_reg[5],mu_hi_reg[4],
                             mu_hi_reg[3],mu_hi_reg[2],mu_hi_reg[1],mu_hi_reg[0],
                             mu_lo_reg[7],mu_lo_reg[6],mu_lo_reg[5],mu_lo_reg[4],
                             mu_lo_reg[3],mu_lo_reg[2],mu_lo_reg[1],mu_lo_reg[0]};

                reg start_keygen, start_sign, start_verify;
    always @(posedge clk) begin
        if (!rst_n) begin
            start_keygen <= 1'b0;
            start_sign   <= 1'b0;
            start_verify <= 1'b0;
        end else begin
            start_keygen <= ctrl_reg[0];
            start_sign   <= ctrl_reg[1];
            start_verify <= ctrl_reg[2];
        end
    end

        // NTT Core
        wire                      ntt_start_w, ntt_intt_mode_w;
    wire                      ntt_busy_w,  ntt_done_w;
    wire                      ntt_ext_we_w;
    wire [7:0]                ntt_ext_addr_w;
    wire [`MLDSA_QBITS-1:0]  ntt_ext_din_w, ntt_ext_dout_w;

    (* DONT_TOUCH = "TRUE" *)
    ntt_core u_ntt (
        .clk       (clk),        .rst_n     (rst_n),
        .start     (ntt_start_w),.intt_mode (ntt_intt_mode_w),
        .busy      (ntt_busy_w), .done      (ntt_done_w),
        .ext_we    (ntt_ext_we_w),
        .ext_addr  (ntt_ext_addr_w),
        .ext_din   (ntt_ext_din_w),
        .ext_dout  (ntt_ext_dout_w)
    );

        // Unified SHAKE-256/128 (shared Keccak-f[1600] core)
    // Channel A = SHAKE-256, Channel B = SHAKE-128
        wire        shake_init_w, shake_wr_en_w;
    wire [4:0]  shake_wr_lane_idx_w, shake_rd_lane_idx_w;
    wire [63:0] shake_wr_lane_data_w, shake_rd_lane_data_w;
    wire        shake_pad_and_permute_w, shake_permute_w;
    wire        shake_busy_w, shake_rdy_w;

    wire        s128_init_w, s128_wr_en_w;
    wire [4:0]  s128_wr_lane_idx_w, s128_rd_lane_idx_w;
    wire [63:0] s128_wr_lane_data_w, s128_rd_lane_data_w;
    wire        s128_pad_and_permute_w, s128_permute_w;
    wire        s128_busy_w, s128_rdy_w;

    shake_unified u_shake (
        .clk               (clk),              .rst_n             (rst_n),
        // Channel A (SHAKE-256)
        .a_init            (shake_init_w),      .a_wr_en           (shake_wr_en_w),
        .a_wr_lane_idx     (shake_wr_lane_idx_w),
        .a_wr_lane_data    (shake_wr_lane_data_w),
        .a_pad_and_permute (shake_pad_and_permute_w),
        .a_permute         (shake_permute_w),
        .a_rd_lane_idx     (shake_rd_lane_idx_w),
        .a_rd_lane_data    (shake_rd_lane_data_w),
        .a_busy            (shake_busy_w),      .a_rdy             (shake_rdy_w),
        // Channel B (SHAKE-128)
        .b_init            (s128_init_w),       .b_wr_en           (s128_wr_en_w),
        .b_wr_lane_idx     (s128_wr_lane_idx_w),
        .b_wr_lane_data    (s128_wr_lane_data_w),
        .b_pad_and_permute (s128_pad_and_permute_w),
        .b_permute         (s128_permute_w),
        .b_rd_lane_idx     (s128_rd_lane_idx_w),
        .b_rd_lane_data    (s128_rd_lane_data_w),
        .b_busy            (s128_busy_w),       .b_rdy             (s128_rdy_w)
    );

                wire kg_done_w, kg_busy_w;
    wire kg_ntt_start_w, kg_ntt_intt_w, kg_ntt_ext_we_w;
    wire [7:0]               kg_ntt_ext_addr_w;
    wire [`MLDSA_QBITS-1:0] kg_ntt_ext_din_w;
    wire kg_shake_init_w, kg_shake_wr_en_w, kg_shake_permute_w, kg_shake_pap_w;
    wire [4:0]  kg_shake_wr_idx_w, kg_shake_rd_idx_w;
    wire [63:0] kg_shake_wr_data_w;

    // SHAKE-128 signals from keygen
    wire        kg_s128_init_w, kg_s128_wr_en_w;
    wire [4:0]  kg_s128_wr_idx_w, kg_s128_rd_idx_w;
    wire [63:0] kg_s128_wr_data_w;
    wire        kg_s128_pap_w, kg_s128_permute_w;

    (* DONT_TOUCH = "TRUE" *)
    keygen_ctrl u_keygen (
        .clk                   (clk),          .rst_n               (rst_n),
        .start                 (start_keygen), .done                (kg_done_w),
        .busy                  (kg_busy_w),    .seed_xi             (seed_xi),
        .seed_valid            (1'b1),
        // NTT
        .ntt_start             (kg_ntt_start_w),
        .ntt_intt_mode         (kg_ntt_intt_w),
        .ntt_done              (ntt_done_w),   .ntt_busy            (ntt_busy_w),
        .ntt_ext_we            (kg_ntt_ext_we_w),
        .ntt_ext_addr          (kg_ntt_ext_addr_w),
        .ntt_ext_din           (kg_ntt_ext_din_w),
        .ntt_ext_dout          (ntt_ext_dout_w),
        // SHAKE-256
        .shake_init            (kg_shake_init_w),
        .shake_wr_en           (kg_shake_wr_en_w),
        .shake_wr_lane_idx     (kg_shake_wr_idx_w),
        .shake_wr_lane_data    (kg_shake_wr_data_w),
        .shake_permute         (kg_shake_permute_w),
        .shake_pad_and_permute (kg_shake_pap_w),
        .shake_rd_lane_data    (shake_rd_lane_data_w),
        .shake_rd_lane_idx     (kg_shake_rd_idx_w),
        .shake_busy            (shake_busy_w), .shake_rdy           (shake_rdy_w),
        // SHAKE-128
        .s128_init             (kg_s128_init_w),
        .s128_wr_en            (kg_s128_wr_en_w),
        .s128_wr_lane_idx      (kg_s128_wr_idx_w),
        .s128_wr_lane_data     (kg_s128_wr_data_w),
        .s128_pad_and_permute  (kg_s128_pap_w),
        .s128_permute          (kg_s128_permute_w),
        .s128_rd_lane_data     (s128_rd_lane_data_w),
        .s128_rd_lane_idx      (kg_s128_rd_idx_w),
        .s128_busy             (s128_busy_w),  .s128_rdy            (s128_rdy_w),
                .pk_we                 (kg_pk_we_w),   .pk_addr             (kg_pk_addr_w),
        .pk_wdata              (kg_pk_wdata_w),.sk_we               (kg_sk_we_w),
        .sk_addr               (kg_sk_addr_w), .sk_wdata            (kg_sk_wdata_w),
        .pk_rd_addr            (kg_pk_rd_addr_w), .pk_rd_data       (kg_pk_rd_data_w)
    );

                wire sg_done_w, sg_busy_w, sg_sigvalid_w;
    wire sg_ntt_start_w, sg_ntt_intt_w;
    wire sg_shake_init_w, sg_shake_pap_w, sg_shake_permute_w;
    wire sg_shake_wr_en_w;
    wire [4:0]  sg_shake_wr_idx_w, sg_shake_rd_idx_w;
    wire [63:0] sg_shake_wr_data_w;
    wire sg_ntt_ext_we_w;
    wire [7:0]  sg_ntt_ext_addr_w;
    wire [`MLDSA_QBITS-1:0] sg_ntt_ext_din_w;
    wire [15:0] sg_kappa_w;

        wire [11:0] sg_sk_rd_addr_w;
    wire [7:0]  sg_sk_rd_data_w = sk_ram[sg_sk_rd_addr_w];

    // Sign SHAKE-128 signals (ExpandA)
    wire        sg_s128_init_w, sg_s128_wr_en_w, sg_s128_pap_w, sg_s128_permute_w;
    wire [4:0]  sg_s128_wr_idx_w, sg_s128_rd_idx_w;
    wire [63:0] sg_s128_wr_data_w;

    sign_ctrl u_sign (
        .clk                   (clk),          .rst_n               (rst_n),
        .start                 (start_sign),   .done                (sg_done_w),
        .busy                  (sg_busy_w),    .sk_rho              (sk_rho),
        .sk_K                  (sk_K),         .sk_tr               (sk_tr),
        .mu                    (mu_w),         .mu_valid            (1'b1),
        .rnd                   (rnd_w),
                .sk_rd_addr            (sg_sk_rd_addr_w),
        .sk_rd_data            (sg_sk_rd_data_w),
                .sig_we                (sg_sig_we_w),
        .sig_addr              (sg_sig_addr_w),
        .sig_wdata             (sg_sig_wdata_w),
        // NTT
        .ntt_start             (sg_ntt_start_w),
        .ntt_intt_mode         (sg_ntt_intt_w),
        .ntt_done              (ntt_done_w),   .ntt_busy            (ntt_busy_w),
        .ntt_ext_we            (sg_ntt_ext_we_w),
        .ntt_ext_addr          (sg_ntt_ext_addr_w),
        .ntt_ext_din           (sg_ntt_ext_din_w),
        .ntt_ext_dout          (ntt_ext_dout_w),
        // SHAKE-256
        .shake_init            (sg_shake_init_w),
        .shake_wr_en           (sg_shake_wr_en_w),
        .shake_wr_lane_idx     (sg_shake_wr_idx_w),
        .shake_wr_lane_data    (sg_shake_wr_data_w),
        .shake_pad_and_permute (sg_shake_pap_w),
        .shake_permute         (sg_shake_permute_w),
        .shake_rd_lane_idx     (sg_shake_rd_idx_w),
        .shake_rd_lane_data    (shake_rd_lane_data_w),
        .shake_rdy             (shake_rdy_w),
        .shake_busy            (shake_busy_w),
        // SHAKE-128
        .s128_init             (sg_s128_init_w),
        .s128_wr_en            (sg_s128_wr_en_w),
        .s128_wr_lane_idx      (sg_s128_wr_idx_w),
        .s128_wr_lane_data     (sg_s128_wr_data_w),
        .s128_pad_and_permute  (sg_s128_pap_w),
        .s128_permute          (sg_s128_permute_w),
        .s128_rd_lane_idx      (sg_s128_rd_idx_w),
        .s128_rd_lane_data     (s128_rd_lane_data_w),
        .s128_rdy              (s128_rdy_w),
        .s128_busy             (s128_busy_w),
        .sig_valid             (sg_sigvalid_w),
        .kappa_out             (sg_kappa_w)
    );

                wire vf_done_w, vf_busy_w, vf_valid_w;
    wire vf_ntt_start_w, vf_ntt_intt_w;
    wire vf_shake_init_w, vf_shake_pap_w, vf_shake_permute_w;
    wire vf_shake_wr_en_w;
    wire [4:0]  vf_shake_wr_idx_w, vf_shake_rd_idx_w;
    wire [63:0] vf_shake_wr_data_w;
    wire vf_ntt_ext_we_w;
    wire [7:0]  vf_ntt_ext_addr_w;
    wire [`MLDSA_QBITS-1:0] vf_ntt_ext_din_w;
    wire [7:0] vf_z_addr_w;

    wire [`MLDSA_QBITS-1:0] vf_z_rdata = poly_z_ram[vf_z_addr_w][`MLDSA_QBITS-1:0];

        wire [11:0] vf_sig_addr_w;
    wire [7:0]  vf_sig_rdata_w = sig_ram[vf_sig_addr_w];

        wire [10:0] vf_pk_addr_w;
    wire [7:0]  vf_pk_rdata_w = pk_ram[vf_pk_addr_w];

    // Verify SHAKE-128 (ExpandA) signals
    wire        vf_s128_init_w, vf_s128_wr_en_w, vf_s128_pap_w, vf_s128_permute_w;
    wire [4:0]  vf_s128_wr_idx_w, vf_s128_rd_idx_w;
    wire [63:0] vf_s128_wr_data_w;

    verify_ctrl u_verify (
        .clk                   (clk),          .rst_n               (rst_n),
        .start                 (start_verify), .done                (vf_done_w),
        .busy                  (vf_busy_w),    .valid               (vf_valid_w),
        .pk_rho                (sk_rho),       .mu                  (mu_w),
        .mu_valid              (1'b1),
                .sig_rd_addr           (vf_sig_addr_w), .sig_rd_data         (vf_sig_rdata_w),
        .pk_rd_addr            (vf_pk_addr_w),  .pk_rd_data          (vf_pk_rdata_w),
        // NTT
        .ntt_start             (vf_ntt_start_w),
        .ntt_intt_mode         (vf_ntt_intt_w),
        .ntt_done              (ntt_done_w),   .ntt_busy            (ntt_busy_w),
        .ntt_ext_we            (vf_ntt_ext_we_w),
        .ntt_ext_addr          (vf_ntt_ext_addr_w),
        .ntt_ext_din           (vf_ntt_ext_din_w),
        .ntt_ext_dout          (ntt_ext_dout_w),
        // SHAKE-256
        .shake_init            (vf_shake_init_w),
        .shake_wr_en           (vf_shake_wr_en_w),
        .shake_wr_lane_idx     (vf_shake_wr_idx_w),
        .shake_wr_lane_data    (vf_shake_wr_data_w),
        .shake_pad_and_permute (vf_shake_pap_w),
        .shake_permute         (vf_shake_permute_w),
        .shake_rd_lane_idx     (vf_shake_rd_idx_w),
        .shake_rd_lane_data    (shake_rd_lane_data_w),
        .shake_rdy             (shake_rdy_w),
        .shake_busy            (shake_busy_w),
        // SHAKE-128 (ExpandA)
        .s128_init             (vf_s128_init_w),
        .s128_wr_en            (vf_s128_wr_en_w),
        .s128_wr_lane_idx      (vf_s128_wr_idx_w),
        .s128_wr_lane_data     (vf_s128_wr_data_w),
        .s128_pad_and_permute  (vf_s128_pap_w),
        .s128_permute          (vf_s128_permute_w),
        .s128_rd_lane_idx      (vf_s128_rd_idx_w),
        .s128_rd_lane_data     (s128_rd_lane_data_w),
        .s128_rdy              (s128_rdy_w),
        .s128_busy             (s128_busy_w),
        .c_tilde_orig          (c_tilde_orig_w),
        .c_tilde_prime         (256'd0)
    );

        // NTT / SHAKE-256 / SHAKE-128 bus arbitration
                // NTT arbitration
    assign ntt_start_w            = kg_ntt_start_w  | sg_ntt_start_w  | vf_ntt_start_w;
        // must drive the shared NTT, otherwise a stale value from a finished
    // controller leaks through the OR and misconfigures the next NTT.
    assign ntt_intt_mode_w        = kg_busy_w ? kg_ntt_intt_w :
                                    sg_busy_w ? sg_ntt_intt_w : vf_ntt_intt_w;
    assign ntt_ext_we_w           = kg_ntt_ext_we_w | sg_ntt_ext_we_w | vf_ntt_ext_we_w;    assign ntt_ext_addr_w         = kg_busy_w ? kg_ntt_ext_addr_w :
                                    sg_busy_w ? sg_ntt_ext_addr_w : vf_ntt_ext_addr_w;
    assign ntt_ext_din_w          = kg_busy_w ? kg_ntt_ext_din_w :
                                    sg_busy_w ? sg_ntt_ext_din_w  : vf_ntt_ext_din_w;

    // SHAKE-256 arbitration
    assign shake_init_w           = kg_shake_init_w | sg_shake_init_w | vf_shake_init_w;
    assign shake_wr_en_w          = kg_shake_wr_en_w | sg_shake_wr_en_w | vf_shake_wr_en_w;
    assign shake_wr_lane_idx_w    = kg_busy_w ? kg_shake_wr_idx_w :
                                    sg_busy_w ? sg_shake_wr_idx_w : vf_shake_wr_idx_w;
    assign shake_wr_lane_data_w   = kg_busy_w ? kg_shake_wr_data_w :
                                    sg_busy_w ? sg_shake_wr_data_w : vf_shake_wr_data_w;
    assign shake_pad_and_permute_w= kg_shake_pap_w  | sg_shake_pap_w  | vf_shake_pap_w;
    assign shake_permute_w        = kg_shake_permute_w | sg_shake_permute_w | vf_shake_permute_w;
    assign shake_rd_lane_idx_w    = kg_busy_w ? kg_shake_rd_idx_w :
                                    sg_busy_w ? sg_shake_rd_idx_w : vf_shake_rd_idx_w;

    // SHAKE-128 arbitration (keygen + sign + verify; only one busy at a time)
    assign s128_init_w            = kg_s128_init_w  | sg_s128_init_w  | vf_s128_init_w;
    assign s128_wr_en_w           = kg_s128_wr_en_w | sg_s128_wr_en_w | vf_s128_wr_en_w;
    assign s128_wr_lane_idx_w     = kg_busy_w ? kg_s128_wr_idx_w :
                                    sg_busy_w ? sg_s128_wr_idx_w : vf_s128_wr_idx_w;
    assign s128_wr_lane_data_w    = kg_busy_w ? kg_s128_wr_data_w :
                                    sg_busy_w ? sg_s128_wr_data_w : vf_s128_wr_data_w;
    assign s128_pad_and_permute_w = kg_s128_pap_w  | sg_s128_pap_w  | vf_s128_pap_w;
    assign s128_permute_w         = kg_s128_permute_w | sg_s128_permute_w | vf_s128_permute_w;
    assign s128_rd_lane_idx_w     = kg_busy_w ? kg_s128_rd_idx_w :
                                    sg_busy_w ? sg_s128_rd_idx_w : vf_s128_rd_idx_w;

                wire core_busy   = kg_busy_w   | sg_busy_w   | vf_busy_w;
    wire core_done   = kg_done_w   | sg_done_w   | vf_done_w;
    wire sig_valid_w = sg_sigvalid_w | vf_valid_w;

        reg done_sticky;
    reg valid_sticky;
    always @(posedge clk) begin
        if (!rst_n) begin
            done_sticky  <= 1'b0;
            valid_sticky <= 1'b0;
        end else if (core_done) begin
            done_sticky  <= 1'b1;
            valid_sticky <= sig_valid_w;
        end else if (ctrl_reg[0] || ctrl_reg[1] || ctrl_reg[2]) begin
            done_sticky  <= 1'b0;
            valid_sticky <= 1'b0;
        end
    end

                wire wr_poly_z  = (wr_addr[15:10] == 6'b100000); // 0x2000-0x23FC
    wire wr_poly_r0 = (wr_addr[15:10] == 6'b100100); // 0x2400-0x27FC
    wire wr_mu_hi2  = (wr_addr[15:4]  == 12'h010);   // 0x0100-0x010C
    wire wr_pk      = (wr_addr[15:12] == 4'b0000) && (wr_addr[11] == 1'b1); // 0x0800-0x0FFF (byte)
    wire wr_sk      = (wr_addr[15:12] == 4'h1);      // 0x1000-0x1FFF  (byte)
    wire wr_sig     = (wr_addr[15:12] == 4'h3);      // 0x3000-0x3FFF  (byte)
    wire [7:0] poly_wr_idx = wr_addr[9:2];

    always @(posedge clk) begin
        if (!rst_n) begin
            ctrl_reg <= 32'd0;
        end else if (wr_en) begin
            if      (wr_mu_hi2) mu_hi_reg[wr_addr[3:2] + 4] <= wr_data;
            else if (wr_pk)      pk_ram [wr_addr[10:0]] <= wr_data[7:0];
            else if (wr_sk)      sk_ram [wr_addr[11:0]] <= wr_data[7:0];
            else if (wr_sig)     sig_ram[wr_addr[11:0]] <= wr_data[7:0];
            else if (wr_poly_z)  poly_z_ram [poly_wr_idx] <= wr_data;
            else if (wr_poly_r0) poly_r0_ram[poly_wr_idx] <= wr_data;
            else case (wr_addr[7:0])
                8'h00: ctrl_reg      <= wr_data;
                                8'h10: seed_reg[0]   <= wr_data; 8'h14: seed_reg[1] <= wr_data;
                8'h18: seed_reg[2]   <= wr_data; 8'h1C: seed_reg[3] <= wr_data;
                8'h20: seed_reg[4]   <= wr_data; 8'h24: seed_reg[5] <= wr_data;
                8'h28: seed_reg[6]   <= wr_data; 8'h2C: seed_reg[7] <= wr_data;
                                8'h30: rho_reg[0]    <= wr_data; 8'h34: rho_reg[1]  <= wr_data;
                8'h38: rho_reg[2]    <= wr_data; 8'h3C: rho_reg[3]  <= wr_data;
                8'h40: rho_reg[4]    <= wr_data; 8'h44: rho_reg[5]  <= wr_data;
                8'h48: rho_reg[6]    <= wr_data; 8'h4C: rho_reg[7]  <= wr_data;
                                8'h50: K_reg[0]      <= wr_data; 8'h54: K_reg[1]    <= wr_data;
                8'h58: K_reg[2]      <= wr_data; 8'h5C: K_reg[3]    <= wr_data;
                8'h60: K_reg[4]      <= wr_data; 8'h64: K_reg[5]    <= wr_data;
                8'h68: K_reg[6]      <= wr_data; 8'h6C: K_reg[7]    <= wr_data;
                                8'h70: tr_reg[0]     <= wr_data; 8'h74: tr_reg[1]   <= wr_data;
                8'h78: tr_reg[2]     <= wr_data; 8'h7C: tr_reg[3]   <= wr_data;
                8'h80: tr_reg[4]     <= wr_data; 8'h84: tr_reg[5]   <= wr_data;
                8'h88: tr_reg[6]     <= wr_data; 8'h8C: tr_reg[7]   <= wr_data;
                                8'h90: rnd_reg[0]    <= wr_data; 8'h94: rnd_reg[1]  <= wr_data;
                8'h98: rnd_reg[2]    <= wr_data; 8'h9C: rnd_reg[3]  <= wr_data;
                8'hA0: rnd_reg[4]    <= wr_data; 8'hA4: rnd_reg[5]  <= wr_data;
                8'hA8: rnd_reg[6]    <= wr_data; 8'hAC: rnd_reg[7]  <= wr_data;
                                8'hB0: ctilde_reg[0] <= wr_data; 8'hB4: ctilde_reg[1] <= wr_data;
                8'hB8: ctilde_reg[2] <= wr_data; 8'hBC: ctilde_reg[3] <= wr_data;
                8'hC0: ctilde_reg[4] <= wr_data; 8'hC4: ctilde_reg[5] <= wr_data;
                8'hC8: ctilde_reg[6] <= wr_data; 8'hCC: ctilde_reg[7] <= wr_data;
                                8'hD0: mu_lo_reg[0]  <= wr_data; 8'hD4: mu_lo_reg[1] <= wr_data;
                8'hD8: mu_lo_reg[2]  <= wr_data; 8'hDC: mu_lo_reg[3] <= wr_data;
                8'hE0: mu_lo_reg[4]  <= wr_data; 8'hE4: mu_lo_reg[5] <= wr_data;
                8'hE8: mu_lo_reg[6]  <= wr_data; 8'hEC: mu_lo_reg[7] <= wr_data;
                // mu[511:256] (words 0-3 @0xF0-0xFC, words 4-7 @0x0100-0x010C)
                8'hF0: mu_hi_reg[0]  <= wr_data; 8'hF4: mu_hi_reg[1] <= wr_data;
                8'hF8: mu_hi_reg[2]  <= wr_data; 8'hFC: mu_hi_reg[3] <= wr_data;
                default: ;
            endcase
        end

        if (ctrl_reg[0]) ctrl_reg[0] <= 1'b0;
        if (ctrl_reg[1]) ctrl_reg[1] <= 1'b0;
        if (ctrl_reg[2]) ctrl_reg[2] <= 1'b0;
    end

                // Status register: [0]=busy, [1]=done_sticky, [2]=sig_valid
    wire [31:0] status_word = {29'd0, valid_sticky, done_sticky, core_busy};

    wire       rd_poly_z   = (rd_addr[15:10] == 6'b100000);  // 0x2000-0x23FC
    wire       rd_poly_r0  = (rd_addr[15:10] == 6'b100100);  // 0x2400-0x27FC
    wire       rd_pk       = (rd_addr[15:12] == 4'b0000) && (rd_addr[11] == 1'b1);  // 0x0800-0x0FFF
    wire       rd_sk       = (rd_addr[15:12] == 4'b0001);    // 0x1000-0x1FFF
    wire       rd_sig      = (rd_addr[15:12] == 4'b0011);    // 0x3000-0x3FFF
    wire [7:0] poly_rd_idx = rd_addr[9:2];

    // Byte offset within PK/SK/SIG window (pk base 0x0800, sk base 0x1000, sig base 0x3000)
    wire [10:0] pk_rd_base = {rd_addr[10:2], 2'b00};
    wire [11:0] sk_rd_base = {rd_addr[11:2], 2'b00};
    wire [11:0] sig_rd_base = {rd_addr[11:2], 2'b00};

    // Pack 4 bytes from PK RAM into 32-bit word (combinational read)
    wire [31:0] pk_rd_word = {pk_ram[pk_rd_base+3], pk_ram[pk_rd_base+2],
                              pk_ram[pk_rd_base+1], pk_ram[pk_rd_base+0]};

    // Pack 4 bytes from SK RAM into 32-bit word (combinational read)
    wire [31:0] sk_rd_word = {sk_ram[sk_rd_base+3], sk_ram[sk_rd_base+2],
                              sk_ram[sk_rd_base+1], sk_ram[sk_rd_base+0]};

    // Pack 4 bytes from SIG RAM into 32-bit word (combinational read)
    wire [31:0] sig_rd_word = {sig_ram[sig_rd_base+3], sig_ram[sig_rd_base+2],
                               sig_ram[sig_rd_base+1], sig_ram[sig_rd_base+0]};

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_data <= 32'd0;
        end else if (rd_en) begin
            if      (rd_poly_z)  rd_data <= poly_z_ram [poly_rd_idx];
            else if (rd_poly_r0) rd_data <= poly_r0_ram[poly_rd_idx];
            else if (rd_pk)      rd_data <= pk_rd_word;
            else if (rd_sk)      rd_data <= sk_rd_word;
            else if (rd_sig)     rd_data <= sig_rd_word;
            else case (rd_addr[7:0])
                8'h00:  rd_data <= ctrl_reg;
                8'h04:  rd_data <= status_word;
                8'h10:  rd_data <= seed_reg[0]; 8'h14: rd_data <= seed_reg[1];
                8'h18:  rd_data <= seed_reg[2]; 8'h1C: rd_data <= seed_reg[3];
                8'h20:  rd_data <= seed_reg[4]; 8'h24: rd_data <= seed_reg[5];
                8'h28:  rd_data <= seed_reg[6]; 8'h2C: rd_data <= seed_reg[7];
                default: rd_data <= 32'hDEAD_BEEF;
            endcase
        end
    end

endmodule
