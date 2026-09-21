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

module keygen_ctrl (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          start,
    output reg           done,
    output reg           busy,

    // Random seed input (32 bytes)
    input  wire [255:0]  seed_xi,
    input  wire          seed_valid,

    output reg           ntt_start,
    output reg           ntt_intt_mode,
    input  wire          ntt_done,
    input  wire          ntt_busy,
    output reg           ntt_ext_we,
    output reg  [7:0]    ntt_ext_addr,
    output reg  [`MLDSA_QBITS-1:0] ntt_ext_din,
    input  wire [`MLDSA_QBITS-1:0] ntt_ext_dout,

    output reg           shake_init,
    output reg           shake_wr_en,
    output reg  [4:0]    shake_wr_lane_idx,
    output reg  [63:0]   shake_wr_lane_data,
    output reg           shake_permute,
    output reg           shake_pad_and_permute,
    input  wire [63:0]   shake_rd_lane_data,
    output reg  [4:0]    shake_rd_lane_idx,
    input  wire          shake_busy,
    input  wire          shake_rdy,

    output reg           s128_init,
    output reg           s128_wr_en,
    output reg  [4:0]    s128_wr_lane_idx,
    output reg  [63:0]   s128_wr_lane_data,
    output reg           s128_pad_and_permute,
    output reg           s128_permute,
    input  wire [63:0]   s128_rd_lane_data,
    output reg  [4:0]    s128_rd_lane_idx,
    input  wire          s128_busy,
    input  wire          s128_rdy,

    output reg           pk_we,
    output reg  [10:0]   pk_addr,
    output reg  [7:0]    pk_wdata,
    output reg           sk_we,
    output reg  [11:0]   sk_addr,
    output reg  [7:0]    sk_wdata,

    // PK readback port (for tr = SHAKE-256(pk))
    output reg  [10:0]   pk_rd_addr,
    input  wire [7:0]    pk_rd_data
);

    // Slot map:
    //   0-4   : s1[0..4] (original, for sk packing)
    //   5-9   : s1_hat[0..4] (NTT domain)
    //   10-15 : s2[0..5]
    //   16    : accumulator for A*s1_hat row
    //   17-22 : t0[0..5] (from Power2Round)
    //   23    : t1[0..5] (from Power2Round, packed 10-bit values in 23-bit slots)
    //   24    : temp (current A_hat entry)
    localparam SLOT_S1_BASE   = 0;
    localparam SLOT_S1H_BASE  = 5;
    localparam SLOT_S2_BASE   = 10;
    localparam SLOT_ACC       = 16;
    localparam SLOT_T0_BASE   = 17;
    localparam SLOT_T1_BASE   = 23;
    localparam SLOT_TEMP      = 29;
    (* ram_style = "block" *)
    reg  [22:0] spad [0:7679];
    reg  [12:0] sp_wr_addr;
    reg  [22:0] sp_wr_data;
    reg         sp_wr_en;
    reg  [12:0] sp_rd_addr;
    reg  [22:0] sp_rd_data;

    // Synchronous write, synchronous read (enables Block RAM inference)
    always @(posedge clk) begin
        if (sp_wr_en)
            spad[sp_wr_addr] <= sp_wr_data;
        sp_rd_data <= spad[sp_rd_addr];
    end

    reg  [12:0] sp_rd2_addr;
    reg  [22:0] sp_rd2_data;
    always @(posedge clk) begin
        sp_rd2_data <= spad[sp_rd2_addr];
    end

    reg  [12:0] sp_rd3_addr;
    reg  [22:0] sp_rd3_data;
    always @(posedge clk) begin
        sp_rd3_data <= spad[sp_rd3_addr];
    end
    reg                      pmul_vld_in;
    reg  [`MLDSA_QBITS-1:0] pmul_a, pmul_b;
    wire [`MLDSA_QBITS-1:0] pmul_result;
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

    reg  [`MLDSA_QBITS-1:0] p2r_in;
    wire [`MLDSA_QBITS-1:0] p2r_t1, p2r_t0;

    power2round u_p2r (
        .r  (p2r_in),
        .r1 (p2r_t1),
        .r0 (p2r_t0)
    );

    // eta nibble for sk packing: c in [-eta, eta] stored mod Q.
    // nib = ETA - c  (in [0, 2*ETA] = [0,8])
    function [3:0] eta_nib;
        input [`MLDSA_QBITS-1:0] c;
        begin
            eta_nib = (c > `MLDSA_ETA) ? (`MLDSA_ETA + `MLDSA_Q - c) : (`MLDSA_ETA - c);
        end
    endfunction

    // t0 byte select: 8 coeffs (13-bit offset form) packed into 13 bytes.
    // polyt0_pack: t[j] = (1<<12) - a[8i+j]; byte k interleaves 8 13-bit values.
    function [7:0] t0_byte;
        input [103:0] buf_in;  // buf_in[13*j +: 13] = t[j]
        input [3:0]   k;
        reg  [12:0] t [0:7];
        integer m;
        begin
            for (m = 0; m < 8; m = m + 1)
                t[m] = buf_in[13*m +: 13];
            case (k)
                4'd0:  t0_byte = t[0] & 8'hFF;
                4'd1:  t0_byte = ((t[0] >> 8) | (t[1] << 5)) & 8'hFF;
                4'd2:  t0_byte = (t[1] >> 3) & 8'hFF;
                4'd3:  t0_byte = ((t[1] >> 11) | (t[2] << 2)) & 8'hFF;
                4'd4:  t0_byte = ((t[2] >> 6) | (t[3] << 7)) & 8'hFF;
                4'd5:  t0_byte = (t[3] >> 1) & 8'hFF;
                4'd6:  t0_byte = ((t[3] >> 9) | (t[4] << 4)) & 8'hFF;
                4'd7:  t0_byte = (t[4] >> 4) & 8'hFF;
                4'd8:  t0_byte = ((t[4] >> 12) | (t[5] << 1)) & 8'hFF;
                4'd9:  t0_byte = ((t[5] >> 7) | (t[6] << 6)) & 8'hFF;
                4'd10: t0_byte = (t[6] >> 2) & 8'hFF;
                4'd11: t0_byte = ((t[6] >> 10) | (t[7] << 3)) & 8'hFF;
                4'd12: t0_byte = (t[7] >> 5) & 8'hFF;
                default: t0_byte = 8'h00;
            endcase
        end
    endfunction

    localparam [5:0]
        KG_IDLE           = 6'd0,
        KG_HASH_INIT      = 6'd1,
        KG_HASH_ABS       = 6'd2,
        KG_HASH_PAD       = 6'd3,
        KG_HASH_WAIT      = 6'd4,
        KG_HASH_SQZ       = 6'd5,
        KG_EXPS_INIT      = 6'd6,
        KG_EXPS_ABS       = 6'd7,
        KG_EXPS_PAD       = 6'd8,
        KG_EXPS_WAIT      = 6'd9,
        KG_EXPS_FEED      = 6'd10,
        KG_EXPS_STORE     = 6'd11,
        KG_EXPS_NEXT      = 6'd12,
        KG_EXPS_SQZ_MORE  = 6'd13,
        // NTT s1
        KG_NTT_LOAD       = 6'd14,
        KG_NTT_RUN        = 6'd15,
        KG_NTT_WAIT       = 6'd16,
        KG_NTT_STORE      = 6'd17,
        KG_NTT_NEXT       = 6'd18,
        KG_CLR_ACC        = 6'd19,
        KG_EXPA_INIT      = 6'd20,
        KG_EXPA_ABS       = 6'd21,
        KG_EXPA_PAD       = 6'd22,
        KG_EXPA_WAIT      = 6'd23,
        KG_EXPA_FEED      = 6'd24,
        KG_EXPA_SQZ_MORE  = 6'd25,
        KG_EXPA_STORE     = 6'd26,
        KG_PMUL_START     = 6'd27,
        KG_PMUL_PIPE      = 6'd28,
        KG_PMUL_ACC       = 6'd29,
        KG_PMUL_NEXT_J    = 6'd30,
        KG_INTT_LOAD      = 6'd31,
        KG_INTT_RUN       = 6'd32,
        KG_INTT_WAIT      = 6'd33,
        KG_INTT_STORE     = 6'd34,
        KG_ADD_S2         = 6'd35,
        KG_P2R            = 6'd36,
        KG_NEXT_I         = 6'd37,
        KG_PACK_PK_RHO    = 6'd38,
        KG_PACK_PK_T1     = 6'd39,
        KG_HASH_PK_INIT   = 6'd40,
        KG_HASH_PK_ABS    = 6'd41,
        KG_HASH_PK_PERM   = 6'd42,
        KG_HASH_PK_PAD    = 6'd43,
        KG_HASH_PK_WAIT   = 6'd44,
        KG_HASH_PK_SQZ    = 6'd45,
        KG_PACK_SK        = 6'd46,
        KG_PACK_SK_T0     = 6'd50,
        KG_DONE           = 6'd51;

    reg [5:0]  state;
    reg [4:0]  sub;
    reg [2:0]  mat_i, mat_j;
    reg [3:0]  poly_idx;
    reg        k_latched;     // K_seed[255:192] latched from final SHAKE lane
    reg [8:0]  coeff_idx;     // coefficient index 0..256 (9-bit to represent 256)
    reg [8:0]  coeff_cnt;
    reg [10:0] byte_cnt;
    reg [4:0]  lane_cnt;
    reg [2:0]  byte_in_lane;  // byte position within a 64-bit lane
    reg [63:0] cur_lane;
    reg [7:0]  cur_byte;

    reg [255:0] rho;
    reg [511:0] rho_prime;
    reg [255:0] K_seed;
    reg [511:0] tr;           // 64 bytes

    reg [7:0]  rej_b0, rej_b1, rej_b2;

    // Rejection uniform candidate (combinational) - declared after rej_b regs
    wire [22:0] rej_candidate = {rej_b2[6:0], rej_b1, rej_b0};
    reg [1:0]  rej_phase;
    reg [3:0]  nib_lo, nib_hi;
    reg        nib_phase;

    reg [10:0] pk_byte_cnt;
    reg [11:0] sk_byte_cnt;

    reg [63:0]  hash_lane_buf;    // accumulates 8 pk bytes into a SHAKE lane
    reg [2:0]   hash_byte_in_lane;

    reg [7:0]  pmul_wr_idx;
    reg        pmul_acc_phase;

    // SHAKE-256 rate = 17 lanes (136 bytes)
    // SHAKE-128 rate = 21 lanes (168 bytes)
    localparam SHAKE256_RATE_LANES = 17;
    localparam SHAKE128_RATE_LANES = 21;

    // t1 packing: 10 bits per coefficient, 4 coeffs = 5 bytes
    reg [9:0]  t1_val;
    reg [39:0] t1_pack_buf;
    reg [2:0]  t1_pack_cnt;

    // t1 packing sub-state: write individual bytes
    reg [2:0]  t1_byte_idx;  // 0-4 for the 5 bytes of each 4-coeff group
    reg        t1_pending;

    // sk packing (s1/s2 eta nibble pack + t0 13-bit interleaved pack)
    // Reference (FIPS 204, eta=4):
    //   s1: L x 128 bytes, each byte = (ETA - c0) | ((ETA - c1) << 4)
    //   s2: K x 128 bytes, same
    //   t0: K x 416 bytes, 8 coeffs -> 13 bytes, t = (1<<12) - a (offset form)
    // sk layout: rho(32) || K(32) || tr(64) || s1 || s2 || t0
    //   0-31:   rho
    //   32-63:  K
    //   64-127: tr
    //   128-767:   s1 (5 x 128 = 640 bytes)
    //   768-1535:  s2 (6 x 128 = 768 bytes)
    //   1536-4031: t0 (6 x 416 = 2496 bytes)
    reg [3:0]  sk_pack_poly;     // poly index for eta pack (0..4=s1, 5..10=s2)
    reg [7:0]  sk_pack_byte;     // byte index within a poly (0..127) for eta pack
    reg [3:0]  sk_nib_lo;
    reg [3:0]  sk_nib_hi;
    reg [4:0]  t0_pack_sub;
    reg [3:0]  t0_poly_idx;
    reg [4:0]  t0_grp_idx;
    reg [3:0]  t0_sel;           // byte index 0..12 within a t0 group
    reg [103:0] t0_pack_buf;     // 8 x 13-bit t0 coefficients (offset form)

    // Scratchpad slot for the current eta-pack poly (0..4 = s1, 5..10 = s2)
    wire [3:0]  sk_eta_slot   = (sk_pack_poly < 4'd5) ?
                                (SLOT_S1_BASE + sk_pack_poly) :
                                (SLOT_S2_BASE + (sk_pack_poly - 4'd5));
    wire [12:0] sk_eta_base   = {sk_eta_slot, 8'd0};
    wire [11:0] sk_eta_wraddr = (sk_pack_poly < 4'd5) ?
                                (12'd128 + {sk_pack_poly, 7'd0} + sk_pack_byte) :
                                (12'd768 + {(sk_pack_poly - 4'd5), 7'd0} + sk_pack_byte);
    wire [12:0] sk_t0_base    = {(SLOT_T0_BASE + t0_poly_idx), 8'd0};
    wire [11:0] sk_t0_wraddr  = 12'd1536 + t0_poly_idx * 12'd416 +
                                t0_grp_idx * 12'd13 + t0_sel;

    always @(posedge clk) begin
        if (!rst_n) begin
            state        <= KG_IDLE;
            done         <= 1'b0;
            busy         <= 1'b0;
            ntt_start    <= 1'b0;
            ntt_intt_mode<= 1'b0;
            ntt_ext_we   <= 1'b0;
            ntt_ext_addr <= 8'd0;
            ntt_ext_din  <= {`MLDSA_QBITS{1'b0}};
            shake_init   <= 1'b0;
            shake_wr_en  <= 1'b0;
            shake_wr_lane_idx  <= 5'd0;
            shake_wr_lane_data <= 64'd0;
            shake_permute<= 1'b0;
            shake_pad_and_permute <= 1'b0;
            shake_rd_lane_idx <= 5'd0;
            s128_init    <= 1'b0;
            s128_wr_en   <= 1'b0;
            s128_wr_lane_idx  <= 5'd0;
            s128_wr_lane_data <= 64'd0;
            s128_pad_and_permute <= 1'b0;
            s128_permute <= 1'b0;
            s128_rd_lane_idx <= 5'd0;
            pk_we        <= 1'b0;
            pk_addr      <= 11'd0;
            pk_wdata     <= 8'd0;
            sk_we        <= 1'b0;
            sk_addr      <= 12'd0;
            sk_wdata     <= 8'd0;
            sp_wr_en     <= 1'b0;
            sp_wr_addr   <= 13'd0;
            sp_wr_data   <= 23'd0;
            sp_rd_addr   <= 13'd0;
            sp_rd2_addr  <= 13'd0;
            sp_rd3_addr  <= 13'd0;
            pmul_vld_in  <= 1'b0;
            pmul_a       <= {`MLDSA_QBITS{1'b0}};
            pmul_b       <= {`MLDSA_QBITS{1'b0}};
            madd_a       <= {`MLDSA_QBITS{1'b0}};
            madd_b       <= {`MLDSA_QBITS{1'b0}};
            p2r_in       <= {`MLDSA_QBITS{1'b0}};
            sub          <= 4'd0;
            mat_i        <= 3'd0;
            mat_j        <= 3'd0;
            poly_idx     <= 4'd0;
            k_latched    <= 1'b0;
            coeff_idx    <= 8'd0;
            coeff_cnt    <= 9'd0;
            lane_cnt     <= 5'd0;
            byte_in_lane <= 3'd0;
            byte_cnt     <= 11'd0;
            cur_lane     <= 64'd0;
            cur_byte     <= 8'd0;
            rej_b0       <= 8'd0;
            rej_b1       <= 8'd0;
            rej_b2       <= 8'd0;
            rej_phase    <= 2'd0;
            nib_lo       <= 4'd0;
            nib_hi       <= 4'd0;
            nib_phase    <= 1'b0;
            pk_byte_cnt  <= 11'd0;
            sk_byte_cnt  <= 12'd0;
            pmul_wr_idx  <= 8'd0;
            pmul_acc_phase <= 1'b0;
            t1_val       <= 10'd0;
            t1_pack_buf  <= 40'd0;
            t1_pack_cnt  <= 3'd0;
            t1_byte_idx  <= 3'd0;
            t1_pending   <= 1'b0;
            sk_pack_poly <= 4'd0;
            sk_pack_byte <= 8'd0;
            sk_nib_lo    <= 4'd0;
            sk_nib_hi    <= 4'd0;
            t0_pack_sub  <= 5'd0;
            t0_poly_idx  <= 4'd0;
            t0_grp_idx   <= 5'd0;
            t0_sel       <= 4'd0;
            t0_pack_buf  <= 104'd0;
            rho          <= 256'd0;
            rho_prime    <= 512'd0;
            K_seed       <= 256'd0;
            tr           <= 512'd0;
        end else begin
            // Pulse signals - deassert each cycle
            done         <= 1'b0;
            ntt_start    <= 1'b0;
            shake_init   <= 1'b0;
            shake_wr_en  <= 1'b0;
            shake_permute<= 1'b0;
            shake_pad_and_permute <= 1'b0;
            s128_init    <= 1'b0;
            s128_wr_en   <= 1'b0;
            s128_pad_and_permute <= 1'b0;
            s128_permute <= 1'b0;
            pk_we        <= 1'b0;
            sk_we        <= 1'b0;
            ntt_ext_we   <= 1'b0;
            sp_wr_en     <= 1'b0;
            pmul_vld_in  <= 1'b0;

            case (state)

            KG_IDLE: begin
                busy <= 1'b0;
                if (start && seed_valid) begin
                    busy      <= 1'b1;
                    k_latched <= 1'b0;
                    poly_idx  <= 4'd0;
                    state     <= KG_HASH_INIT;
                end
            end

            // STEP 1: Hash seed - SHAKE-256(xi || k || l) ? 128 bytes
            KG_HASH_INIT: begin
                shake_init <= 1'b1;
                sub        <= 4'd0;
                state      <= KG_HASH_ABS;
            end

            KG_HASH_ABS: begin
                if (shake_rdy && !shake_busy) begin
                    case (sub)
                4'd0: begin // lane 0: seed bytes 0-7 (byte0=0x00 in seed_xi[255:248])
                    shake_wr_en <= 1'b1;
                    shake_wr_lane_idx <= 5'd0;
                    shake_wr_lane_data <= {seed_xi[199:192], seed_xi[207:200],
                                          seed_xi[215:208], seed_xi[223:216],
                                          seed_xi[231:224], seed_xi[239:232],
                                          seed_xi[247:240], seed_xi[255:248]};
                    sub <= 4'd1;
                end
                4'd1: begin // lane 1: seed bytes 8-15
                    shake_wr_en <= 1'b1;
                    shake_wr_lane_idx <= 5'd1;
                    shake_wr_lane_data <= {seed_xi[135:128], seed_xi[143:136],
                                          seed_xi[151:144], seed_xi[159:152],
                                          seed_xi[167:160], seed_xi[175:168],
                                          seed_xi[183:176], seed_xi[191:184]};
                    sub <= 4'd2;
                end
                4'd2: begin // lane 2: seed bytes 16-23
                    shake_wr_en <= 1'b1;
                    shake_wr_lane_idx <= 5'd2;
                    shake_wr_lane_data <= {seed_xi[71:64], seed_xi[79:72],
                                          seed_xi[87:80], seed_xi[95:88],
                                          seed_xi[103:96], seed_xi[111:104],
                                          seed_xi[119:112], seed_xi[127:120]};
                    sub <= 4'd3;
                end
                4'd3: begin // lane 3: seed bytes 24-31
                    shake_wr_en <= 1'b1;
                    shake_wr_lane_idx <= 5'd3;
                    shake_wr_lane_data <= {seed_xi[7:0], seed_xi[15:8],
                                          seed_xi[23:16], seed_xi[31:24],
                                          seed_xi[39:32], seed_xi[47:40],
                                          seed_xi[55:48], seed_xi[63:56]};
                    sub <= 4'd4;
                end
                        4'd4: begin // lane 4: bytes 32..39 = [K, L] then SHAKE-256 pad 0x1F
                            // FIPS 204 keygen hashes xi || bytes([K, L]) where
                            // K = MLDSA_K (6), L = MLDSA_L (5) for ML-DSA-65.
                            shake_wr_en <= 1'b1;
                            shake_wr_lane_idx <= 5'd4;
                            shake_wr_lane_data <= {40'd0, 8'h1F, 8'd`MLDSA_L, 8'd`MLDSA_K};
                            sub <= 4'd5;
                        end
                        4'd5: begin // lane 16: rate-end pad 0x80 at byte 135
                            shake_wr_en <= 1'b1;
                            shake_wr_lane_idx <= 5'd16;
                            shake_wr_lane_data <= 64'h80_00_00_00_00_00_00_00;
                            sub <= 4'd6;
                        end
                        4'd6: begin
                            state <= KG_HASH_PAD;
                        end
                        default: sub <= 4'd0;
                    endcase
                end
            end

            KG_HASH_PAD: begin
                shake_pad_and_permute <= 1'b1;
                state <= KG_HASH_WAIT;
            end

            KG_HASH_WAIT: begin
                if (shake_rdy && !shake_busy) begin
                    sub <= 4'd0;
                    state <= KG_HASH_SQZ;
                end
            end

            // Squeeze 16 lanes (128 bytes) ? rho(32B), rho'(64B), K(32B)
            KG_HASH_SQZ: begin
                shake_rd_lane_idx <= sub[3:0];
                case (sub)
                    // Read happens 1 cycle after setting rd_lane_idx
                    // So we read the PREVIOUS lane's data
                    4'd0: sub <= 4'd1;  // set idx=0, data available next cycle
                    4'd1: begin rho[63:0]         <= shake_rd_lane_data; shake_rd_lane_idx <= 5'd1;  sub <= 4'd2; end
                    4'd2: begin rho[127:64]        <= shake_rd_lane_data; shake_rd_lane_idx <= 5'd2;  sub <= 4'd3; end
                    4'd3: begin rho[191:128]       <= shake_rd_lane_data; shake_rd_lane_idx <= 5'd3;  sub <= 4'd4; end
                    4'd4: begin rho[255:192]       <= shake_rd_lane_data; shake_rd_lane_idx <= 5'd4;  sub <= 4'd5; end
                    4'd5: begin rho_prime[63:0]    <= shake_rd_lane_data; shake_rd_lane_idx <= 5'd5;  sub <= 4'd6; end
                    4'd6: begin rho_prime[127:64]  <= shake_rd_lane_data; shake_rd_lane_idx <= 5'd6;  sub <= 4'd7; end
                    4'd7: begin rho_prime[191:128] <= shake_rd_lane_data; shake_rd_lane_idx <= 5'd7;  sub <= 4'd8; end
                    4'd8: begin rho_prime[255:192] <= shake_rd_lane_data; shake_rd_lane_idx <= 5'd8;  sub <= 4'd9; end
                    4'd9: begin rho_prime[319:256] <= shake_rd_lane_data; shake_rd_lane_idx <= 5'd9;  sub <= 4'd10; end
                    4'd10:begin rho_prime[383:320] <= shake_rd_lane_data; shake_rd_lane_idx <= 5'd10; sub <= 4'd11; end
                    4'd11:begin rho_prime[447:384] <= shake_rd_lane_data; shake_rd_lane_idx <= 5'd11; sub <= 4'd12; end
                    4'd12:begin rho_prime[511:448] <= shake_rd_lane_data; shake_rd_lane_idx <= 5'd12; sub <= 4'd13; end
                    4'd13:begin K_seed[63:0]       <= shake_rd_lane_data; shake_rd_lane_idx <= 5'd13; sub <= 4'd14; end
                    4'd14:begin K_seed[127:64]     <= shake_rd_lane_data; shake_rd_lane_idx <= 5'd14; sub <= 4'd15; end
                    4'd15:begin
                        K_seed[191:128] <= shake_rd_lane_data;
                        shake_rd_lane_idx <= 5'd15;
                        // Need one more read for K_seed[255:192]
                        state    <= KG_EXPS_INIT;
                    end
                    default: sub <= 4'd0;
                endcase
                if (sub == 4'd15) begin
                    // The read for lane 15 will be available when we enter next state
                end
            end

            // STEP 2: ExpandS - generate s1[0..4] and s2[0..5]
            // poly_idx = 0..10 (0-4 = s1, 5-10 = s2)
            // Uses SHAKE-256(rho' || nonce) with rejection bounded sampling
            KG_EXPS_INIT: begin
                if (!k_latched) begin
                    K_seed[255:192] <= shake_rd_lane_data;
                    k_latched       <= 1'b1;
                    state           <= KG_EXPS_INIT;  // Stay in this state for one more cycle
                end else begin
                    shake_init <= 1'b1;
                    sub        <= 4'd0;
                    coeff_cnt  <= 9'd0;
                    coeff_idx  <= 8'd0;
                    state      <= KG_EXPS_ABS;
                end
            end

            // Absorb rho_prime (8 lanes = 64 bytes) + 2-byte nonce + padding
            KG_EXPS_ABS: begin
                if (shake_rdy && !shake_busy) begin
                    case (sub)
                        4'd0: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd0; shake_wr_lane_data<=rho_prime[63:0];    sub<=4'd1; end
                        4'd1: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd1; shake_wr_lane_data<=rho_prime[127:64];  sub<=4'd2; end
                        4'd2: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd2; shake_wr_lane_data<=rho_prime[191:128]; sub<=4'd3; end
                        4'd3: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd3; shake_wr_lane_data<=rho_prime[255:192]; sub<=4'd4; end
                        4'd4: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd4; shake_wr_lane_data<=rho_prime[319:256]; sub<=4'd5; end
                        4'd5: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd5; shake_wr_lane_data<=rho_prime[383:320]; sub<=4'd6; end
                        4'd6: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd6; shake_wr_lane_data<=rho_prime[447:384]; sub<=4'd7; end
                        4'd7: begin shake_wr_en<=1; shake_wr_lane_idx<=5'd7; shake_wr_lane_data<=rho_prime[511:448]; sub<=4'd8; end
                        4'd8: begin
                            // Lane 8: nonce (2 bytes, little-endian) + SHAKE pad 0x1F
                            // nonce = poly_idx (16-bit LE)
                            // byte64=nonce_lo, byte65=nonce_hi(0), byte66=0x1F, rest=0
                            shake_wr_en <= 1'b1;
                            shake_wr_lane_idx <= 5'd8;
                            shake_wr_lane_data <= {40'd0, 8'h1F, 8'd0, 4'd0, poly_idx[3:0]};
                            sub <= 4'd9;
                        end
                        4'd9: begin
                            // Lane 16: rate-end pad 0x80 at byte 135
                            shake_wr_en <= 1'b1;
                            shake_wr_lane_idx <= 5'd16;
                            shake_wr_lane_data <= 64'h80_00_00_00_00_00_00_00;
                            sub <= 4'd10;
                        end
                        4'd10: begin
                            state <= KG_EXPS_PAD;
                        end
                        default: sub <= 4'd0;
                    endcase
                end
            end

            KG_EXPS_PAD: begin
                shake_pad_and_permute <= 1'b1;
                lane_cnt     <= 5'd0;
                byte_in_lane <= 3'd0;
                state        <= KG_EXPS_WAIT;
            end

            KG_EXPS_WAIT: begin
                if (shake_rdy && !shake_busy) begin
                    shake_rd_lane_idx <= 5'd0;
                    state <= KG_EXPS_FEED;
                end
            end

            // Feed bytes from SHAKE-256 output to rejection bounded sampling
            // For eta=4: read one byte, check lo nibble and hi nibble
            // NOTE: shake_rd_lane_idx is presented one state earlier (KG_EXPS_STORE)
            // state would re-read the previous lane's byte 0 at every lane boundary.
            KG_EXPS_FEED: begin
                cur_lane <= shake_rd_lane_data;
                cur_byte <= shake_rd_lane_data[byte_in_lane*8 +: 8];

                // Process byte: extract nibbles
                nib_lo <= shake_rd_lane_data[byte_in_lane*8 +: 4];
                nib_hi <= shake_rd_lane_data[byte_in_lane*8+4 +: 4];

                // Check low nibble (eta=4, bound=2*eta=8)
                if (coeff_cnt < 9'd256) begin
                    if (shake_rd_lane_data[byte_in_lane*8 +: 4] <= 4'd8) begin
                        // Accept: coeff = eta - nibble
                        sp_wr_en   <= 1'b1;
                        if (poly_idx < 4'd5)
                            sp_wr_addr <= (SLOT_S1_BASE + poly_idx) * 256 + coeff_cnt[7:0];
                        else
                            sp_wr_addr <= (SLOT_S2_BASE + poly_idx - 5) * 256 + coeff_cnt[7:0];

                        // eta - nibble, stored mod Q
                        if (shake_rd_lane_data[byte_in_lane*8 +: 4] <= `MLDSA_ETA)
                            sp_wr_data <= `MLDSA_ETA - shake_rd_lane_data[byte_in_lane*8 +: 4];
                        else
                            sp_wr_data <= `MLDSA_Q + `MLDSA_ETA - shake_rd_lane_data[byte_in_lane*8 +: 4];

                        coeff_cnt <= coeff_cnt + 9'd1;
                    end
                end

                state <= KG_EXPS_STORE;
            end

            // Check high nibble of the same byte
            KG_EXPS_STORE: begin
                if (coeff_cnt < 9'd256) begin
                    if (nib_hi <= 4'd8) begin
                        sp_wr_en <= 1'b1;
                        if (poly_idx < 4'd5)
                            sp_wr_addr <= (SLOT_S1_BASE + poly_idx) * 256 + coeff_cnt[7:0];
                        else
                            sp_wr_addr <= (SLOT_S2_BASE + poly_idx - 5) * 256 + coeff_cnt[7:0];

                        if (nib_hi <= `MLDSA_ETA)
                            sp_wr_data <= `MLDSA_ETA - nib_hi;
                        else
                            sp_wr_data <= `MLDSA_Q + `MLDSA_ETA - nib_hi;

                        coeff_cnt <= coeff_cnt + 9'd1;
                    end
                end

                if (coeff_cnt >= 9'd256) begin
                    state <= KG_EXPS_NEXT;
                end else begin
                    if (byte_in_lane == 3'd7) begin
                        byte_in_lane <= 3'd0;
                        if (lane_cnt >= SHAKE256_RATE_LANES - 1) begin
                            state <= KG_EXPS_SQZ_MORE;
                        end else begin
                            lane_cnt <= lane_cnt + 5'd1;
                            // Present new lane index one cycle before consume
                            shake_rd_lane_idx <= lane_cnt + 5'd1;
                            state    <= KG_EXPS_FEED;
                        end
                    end else begin
                        byte_in_lane <= byte_in_lane + 3'd1;
                        // Present current lane index one cycle before consume
                        shake_rd_lane_idx <= lane_cnt;
                        state <= KG_EXPS_FEED;
                    end
                end
            end

            KG_EXPS_SQZ_MORE: begin
                shake_permute <= 1'b1;
                lane_cnt      <= 5'd0;
                byte_in_lane  <= 3'd0;
                state         <= KG_EXPS_WAIT;
            end

            KG_EXPS_NEXT: begin
                if (poly_idx < 4'd10) begin
                    poly_idx <= poly_idx + 4'd1;
                    state    <= KG_EXPS_INIT;
                end else begin
                    // All s1 and s2 polynomials generated
                    poly_idx <= 4'd0;
                    state    <= KG_NTT_LOAD;
                end
            end

            // STEP 3: NTT(s1) - forward NTT on s1[0..4]
            // Load from SLOT_S1(poly_idx), run NTT, store to SLOT_S1H(poly_idx)
            //   spad: 1 cycle (sp_rd_data valid next cycle after sp_rd_addr)
            //   NTT SRAM (port A): 2 cycles (sram_douta valid 2 cycles after sram_addra)
            KG_NTT_LOAD: begin
                if (!ntt_busy) begin
                    // Pipelined load: spad read has 2-posedge latency.
                    //   posedge coeff_idx=k   : present sp_rd_addr = base+k
                    //   posedge coeff_idx=k+1 : spad captures mem[base+k]
                    //   posedge coeff_idx=k+2 : sp_rd_data = mem[base+k], write NTT[k]
                    if (coeff_idx <= 8'd255) begin
                        sp_rd_addr <= (SLOT_S1_BASE + poly_idx) * 256 + coeff_idx;
                    end
                    if (coeff_idx >= 9'd2 && coeff_idx <= 9'd257) begin
                        ntt_ext_we   <= 1'b1;
                        ntt_ext_addr <= coeff_idx - 9'd2;
                        ntt_ext_din  <= sp_rd_data;
                    end else begin
                        ntt_ext_we   <= 1'b0;
                    end
                    if (coeff_idx == 9'd257) begin
                        coeff_idx <= 9'd0;
                        state     <= KG_NTT_RUN;
                    end else begin
                        coeff_idx <= coeff_idx + 9'd1;
                    end
                end
            end

            KG_NTT_RUN: begin
                ntt_start     <= 1'b1;
                ntt_intt_mode <= 1'b0;
                state         <= KG_NTT_WAIT;
            end

            KG_NTT_WAIT: begin
                if (ntt_done) begin
                    coeff_idx <= 8'd0;
                    state     <= KG_NTT_STORE;
                end
            end

            KG_NTT_STORE: begin
                // Pipelined store: NTT SRAM read has 2-posedge latency.
                //   present ntt_ext_addr = coeff_idx each cycle (0..255)
                //   write sp[coeff_idx-2] = ntt_ext_dout when coeff_idx in [2..257]
                if (coeff_idx <= 8'd255) begin
                    ntt_ext_addr <= coeff_idx;
                end
                if (coeff_idx >= 9'd2 && coeff_idx <= 9'd257) begin
                    sp_wr_en   <= 1'b1;
                    sp_wr_addr <= (SLOT_S1H_BASE + poly_idx) * 256 + (coeff_idx - 9'd2);
                    sp_wr_data <= ntt_ext_dout;
                end else begin
                    sp_wr_en   <= 1'b0;
                end
                if (coeff_idx == 9'd257) begin
                    coeff_idx <= 9'd0;
                    if (poly_idx < 4'd4) begin
                        poly_idx  <= poly_idx + 4'd1;
                        state     <= KG_NTT_LOAD;
                    end else begin
                        mat_i <= 3'd0;
                        mat_j <= 3'd0;
                        state <= KG_CLR_ACC;
                    end
                end else begin
                    coeff_idx <= coeff_idx + 9'd1;
                end
            end

            // STEP 4: ExpandA + matrix multiply (streaming)
            KG_CLR_ACC: begin
                sp_wr_en   <= 1'b1;
                sp_wr_addr <= SLOT_ACC * 256 + coeff_idx;
                sp_wr_data <= 23'd0;

                if (coeff_idx == 8'd255) begin
                    coeff_idx <= 8'd0;
                    mat_j     <= 3'd0;
                    state     <= KG_EXPA_INIT;
                end else begin
                    coeff_idx <= coeff_idx + 8'd1;
                end
            end

            // ExpandA: SHAKE-128(rho || j || i) ? rejection uniform sampling
            KG_EXPA_INIT: begin
                s128_init <= 1'b1;
                sub       <= 4'd0;
                coeff_cnt <= 9'd0;
                state     <= KG_EXPA_ABS;
            end

            KG_EXPA_ABS: begin
                if (s128_rdy && !s128_busy) begin
                    case (sub)
                        4'd0: begin s128_wr_en<=1; s128_wr_lane_idx<=5'd0; s128_wr_lane_data<=rho[63:0];    sub<=4'd1; end
                        4'd1: begin s128_wr_en<=1; s128_wr_lane_idx<=5'd1; s128_wr_lane_data<=rho[127:64];  sub<=4'd2; end
                        4'd2: begin s128_wr_en<=1; s128_wr_lane_idx<=5'd2; s128_wr_lane_data<=rho[191:128]; sub<=4'd3; end
                        4'd3: begin s128_wr_en<=1; s128_wr_lane_idx<=5'd3; s128_wr_lane_data<=rho[255:192]; sub<=4'd4; end
                        4'd4: begin
                            // Lane 4: j(1B) || i(1B) || 0x1F(pad) || zeros
                            // byte32=j, byte33=i, byte34=0x1F
                            s128_wr_en <= 1'b1;
                            s128_wr_lane_idx <= 5'd4;
                            s128_wr_lane_data <= {40'd0, 8'h1F, 5'd0, mat_i[2:0], 5'd0, mat_j[2:0]};
                            sub <= 4'd5;
                        end
                        4'd5: begin
                            // Lane 20: rate-end pad 0x80 at byte 167
                            // byte 167 = lane 20, byte 7
                            s128_wr_en <= 1'b1;
                            s128_wr_lane_idx <= 5'd20;
                            s128_wr_lane_data <= 64'h80_00_00_00_00_00_00_00;
                            sub <= 4'd6;
                        end
                        4'd6: begin
                            state <= KG_EXPA_PAD;
                        end
                        default: sub <= 4'd0;
                    endcase
                end
            end

            KG_EXPA_PAD: begin
                s128_pad_and_permute <= 1'b1;
                lane_cnt     <= 5'd0;
                byte_in_lane <= 3'd0;
                rej_phase    <= 2'd0;
                state        <= KG_EXPA_WAIT;
            end

            KG_EXPA_WAIT: begin
                if (s128_rdy && !s128_busy) begin
                    s128_rd_lane_idx <= 5'd0;
                    state <= KG_EXPA_FEED;
                end
            end

            // Feed bytes from SHAKE-128 for rejection uniform sampling
            // Read 3 bytes at a time, check if candidate < Q
            KG_EXPA_FEED: begin
                case (rej_phase)
                    2'd0: begin
                        rej_b0 <= s128_rd_lane_data[byte_in_lane*8 +: 8];
                        rej_phase <= 2'd1;
                        // Advance byte; present lane index one cycle before consume
                        if (byte_in_lane == 3'd7) begin
                            byte_in_lane <= 3'd0;
                            if (lane_cnt >= SHAKE128_RATE_LANES - 1) begin
                                state <= KG_EXPA_SQZ_MORE;
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
                        // Advance byte; present lane index one cycle before consume
                        if (byte_in_lane == 3'd7) begin
                            byte_in_lane <= 3'd0;
                            if (lane_cnt >= SHAKE128_RATE_LANES - 1) begin
                                state <= KG_EXPA_SQZ_MORE;
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
                        // Advance byte; present lane index one cycle before consume
                        if (byte_in_lane == 3'd7) begin
                            byte_in_lane <= 3'd0;
                            if (lane_cnt >= SHAKE128_RATE_LANES - 1) begin
                                // Last byte of this block: flag for squeeze after check
                                lane_cnt <= SHAKE128_RATE_LANES;
                            end else begin
                                lane_cnt <= lane_cnt + 5'd1;
                                s128_rd_lane_idx <= lane_cnt + 5'd1;
                            end
                        end else begin
                            byte_in_lane <= byte_in_lane + 3'd1;
                            s128_rd_lane_idx <= lane_cnt;
                        end
                        state <= KG_EXPA_STORE;
                    end
                    default: rej_phase <= 2'd0;
                endcase
            end

            KG_EXPA_STORE: begin
                // CoeffFromThreeBytes: candidate = b0 + 256*b1 + 65536*(b2 & 0x7F)
                if (rej_candidate < `MLDSA_Q && coeff_cnt < 9'd256) begin
                    sp_wr_en   <= 1'b1;
                    sp_wr_addr <= SLOT_TEMP * 256 + coeff_cnt[7:0];
                    sp_wr_data <= rej_candidate;
                    coeff_cnt  <= coeff_cnt + 9'd1;
                end

                rej_phase <= 2'd0;

                if (coeff_cnt >= 9'd256 || (coeff_cnt >= 9'd255 && /* just accepted */ 1'b1)) begin
                    if (coeff_cnt >= 9'd256) begin
                        coeff_idx <= 8'd0;
                        state     <= KG_PMUL_START;
                    end else begin
                        if (byte_in_lane == 3'd0 && lane_cnt >= SHAKE128_RATE_LANES) begin
                            state <= KG_EXPA_SQZ_MORE;
                        end else begin
                            state <= KG_EXPA_FEED;
                        end
                    end
                end else begin
                    if (byte_in_lane == 3'd0 && lane_cnt >= SHAKE128_RATE_LANES) begin
                        state <= KG_EXPA_SQZ_MORE;
                    end else begin
                        state <= KG_EXPA_FEED;
                    end
                end
            end

            KG_EXPA_SQZ_MORE: begin
                s128_permute <= 1'b1;
                lane_cnt     <= 5'd0;
                byte_in_lane <= 3'd0;
                state        <= KG_EXPA_WAIT;
            end

            // Pointwise multiply: temp[k] * s1_hat[j][k] ? accumulate into acc[k]
            KG_PMUL_START: begin
                // Setup: coeff stream begins. Port1/Port2 will present TEMP[c]/S1H[j][c].
                coeff_idx    <= 9'd0;
                pmul_acc_phase <= 1'b0;
                state        <= KG_PMUL_PIPE;
            end

            // Fully-streamed pointwise multiply + accumulate, one coefficient per cycle.
            // Spad reads: addr present at posedge c -> data valid at posedge c+2.
            // Montgomery mult: vld_in set at posedge c -> vld_out visible at posedge c+5
            // (FSM-visible latency 5; matches NTT core S_SCALE write alignment).
            //   posedge c (c<=255)      : present TEMP[c], S1H[j][c]
            //   posedge c (c in [6,261]) : present ACC[c-6]
            //   posedge c (c in [2,257]) : feed multiplier with TEMP[c-2], S1H[j][c-2]
            //   posedge c (c in [7,262]) : vld_out = product[c-7], sp_rd3_data = ACC[c-7]
            //                              -> madd_a/b, wr_idx = c-7
            //   posedge c+1              : madd_sum valid -> write ACC[c-7]
            KG_PMUL_PIPE: begin
                if (coeff_idx <= 9'd255) begin
                    sp_rd_addr  <= SLOT_TEMP * 256 + coeff_idx;
                    sp_rd2_addr <= (SLOT_S1H_BASE + mat_j) * 256 + coeff_idx;
                end
                // 2) Present ACC read for coefficient c-5 (data ACC[c-7] valid at c,
                //    i.e. sp_rd3_data = ACC[(c-2)-5] = ACC[c-7])
                if (coeff_idx >= 9'd5 && coeff_idx <= 9'd260) begin
                    sp_rd3_addr <= SLOT_ACC * 256 + (coeff_idx - 9'd5);
                end
                if (coeff_idx >= 9'd2 && coeff_idx <= 9'd257) begin
                    pmul_vld_in <= 1'b1;
                    pmul_a      <= sp_rd_data;
                    pmul_b      <= sp_rd2_data;
                end else begin
                    pmul_vld_in <= 1'b0;
                end
                // 4) Capture product[c-7] + ACC[c-7] when it exits the multiplier
                if (pmul_vld_out) begin
                    madd_a        <= sp_rd3_data;   // ACC[coeff_idx-7]
                    madd_b        <= pmul_result;   // product[coeff_idx-7]
                    pmul_wr_idx   <= coeff_idx - 9'd7;
                    pmul_acc_phase <= 1'b1;
                end else begin
                    pmul_acc_phase <= 1'b0;
                end
                // 5) Write back accumulated value (one cycle after madd capture)
                if (pmul_acc_phase) begin
                    sp_wr_en   <= 1'b1;
                    sp_wr_addr <= SLOT_ACC * 256 + pmul_wr_idx;
                    sp_wr_data <= madd_sum;
                end

                if (coeff_idx == 9'd263) begin
                    coeff_idx <= 9'd0;
                    state     <= KG_PMUL_NEXT_J;
                end else begin
                    coeff_idx <= coeff_idx + 9'd1;
                end
            end

            KG_PMUL_NEXT_J: begin
                if (mat_j < `MLDSA_L - 1) begin
                    mat_j     <= mat_j + 3'd1;
                    coeff_idx <= 8'd0;
                    coeff_cnt <= 9'd0;
                    state     <= KG_EXPA_INIT;
                end else begin
                    // All columns done for row i. INTT the accumulator.
                    coeff_idx <= 8'd0;
                    state     <= KG_INTT_LOAD;
                end
            end

            // STEP 5: INTT(accumulator) ? t[i]
            KG_INTT_LOAD: begin
                if (!ntt_busy) begin
                    // Pipelined load: spad read has 2-posedge latency.
                    //   posedge coeff_idx=k   : present sp_rd_addr = base+k
                    //   posedge coeff_idx=k+1 : spad captures mem[base+k]
                    //   posedge coeff_idx=k+2 : sp_rd_data = mem[base+k], write NTT[k]
                    if (coeff_idx <= 8'd255) begin
                        sp_rd_addr <= SLOT_ACC * 256 + coeff_idx;
                    end
                    if (coeff_idx >= 9'd2 && coeff_idx <= 9'd257) begin
                        ntt_ext_we   <= 1'b1;
                        ntt_ext_addr <= coeff_idx - 9'd2;
                        ntt_ext_din  <= sp_rd_data;
                    end else begin
                        ntt_ext_we   <= 1'b0;
                    end
                    if (coeff_idx == 9'd257) begin
                        coeff_idx <= 9'd0;
                        state     <= KG_INTT_RUN;
                    end else begin
                        coeff_idx <= coeff_idx + 9'd1;
                    end
                end
            end

            KG_INTT_RUN: begin
                ntt_start     <= 1'b1;
                ntt_intt_mode <= 1'b1;
                state         <= KG_INTT_WAIT;
            end

            KG_INTT_WAIT: begin
                if (ntt_done) begin
                    coeff_idx <= 8'd0;
                    state     <= KG_INTT_STORE;
                end
            end

            KG_INTT_STORE: begin
                // Pipelined store: NTT SRAM read has 2-posedge latency.
                //   present ntt_ext_addr = coeff_idx each cycle (0..255)
                //   write sp[coeff_idx-2] = ntt_ext_dout when coeff_idx in [2..257]
                if (coeff_idx <= 8'd255) begin
                    ntt_ext_addr <= coeff_idx;
                end
                if (coeff_idx >= 9'd2 && coeff_idx <= 9'd257) begin
                    sp_wr_en   <= 1'b1;
                    sp_wr_addr <= SLOT_ACC * 256 + (coeff_idx - 9'd2);
                    sp_wr_data <= ntt_ext_dout;
                end else begin
                    sp_wr_en   <= 1'b0;
                end
                if (coeff_idx == 9'd257) begin
                    coeff_idx <= 9'd0;
                    state     <= KG_ADD_S2;
                end else begin
                    coeff_idx <= coeff_idx + 9'd1;
                end
            end

            // STEP 6: t[i] = acc[k] + s2[i][k] for all k
            KG_ADD_S2: begin
                // Pipelined: read acc[k] and s2[i][k] (2-posedge spad latency).
                //   present sp_rd_addr/sp_rd2_addr = k each cycle (0..255)
                //   capture madd_a/b = mem[k] when coeff_idx == k+2
                //   write acc[k] = madd_sum when coeff_idx == k+3
                if (coeff_idx <= 8'd255) begin
                    sp_rd_addr  <= SLOT_ACC * 256 + coeff_idx;
                    sp_rd2_addr <= (SLOT_S2_BASE + mat_i) * 256 + coeff_idx;
                end
                if (coeff_idx >= 9'd2 && coeff_idx <= 9'd257) begin
                    madd_a <= sp_rd_data;
                    madd_b <= sp_rd2_data;
                end
                if (coeff_idx >= 9'd3 && coeff_idx <= 9'd258) begin
                    sp_wr_en   <= 1'b1;
                    sp_wr_addr <= SLOT_ACC * 256 + (coeff_idx - 9'd3);
                    sp_wr_data <= madd_sum;
                end else begin
                    sp_wr_en   <= 1'b0;
                end
                if (coeff_idx == 9'd258) begin
                    coeff_idx <= 9'd0;
                    sub       <= 4'd0;
                    state     <= KG_P2R;
                end else begin
                    coeff_idx <= coeff_idx + 9'd1;
                end
            end

            // STEP 7: Power2Round - for each k: (t1[k], t0[k]) = P2R(acc[k])
            KG_P2R: begin
                //   pass sub=0: write t0 to T0 slot,  pass sub=1: write t1 to T1 slot
                // Pipelined: present addr at posedge c -> data valid at c+2.
                //   posedge c       : present sp_rd_addr = ACC base + c
                //   posedge c+2     : p2r_in <= sp_rd_data (ACC[c])
                //   posedge c+3     : write t0/t1 at index c (p2r_t0/t1 comb. on p2r_in)
                if (coeff_idx <= 8'd255) begin
                    sp_rd_addr <= SLOT_ACC * 256 + coeff_idx;
                end

                if (coeff_idx >= 9'd2 && coeff_idx <= 9'd257) begin
                    p2r_in <= sp_rd_data;
                end

                // p2r_in holds ACC[coeff_idx-3] here (captured last cycle).
                if (coeff_idx >= 9'd3 && coeff_idx <= 9'd258) begin
                    sp_wr_en   <= 1'b1;
                    if (sub == 4'd0) begin
                        sp_wr_addr <= (SLOT_T0_BASE + mat_i) * 256 + (coeff_idx - 9'd3);
                        sp_wr_data <= p2r_t0;
                    end else begin
                        sp_wr_addr <= (SLOT_T1_BASE + mat_i) * 256 + (coeff_idx - 9'd3);
                        sp_wr_data <= {13'd0, p2r_t1[9:0]};
                    end
                end else begin
                    sp_wr_en <= 1'b0;
                end

                if (coeff_idx == 9'd258) begin
                    if (sub == 4'd0) begin
                        sub       <= 4'd1;
                        coeff_idx <= 9'd0;
                    end else begin
                        state     <= KG_NEXT_I;
                    end
                end else begin
                    coeff_idx <= coeff_idx + 9'd1;
                end
            end

            KG_NEXT_I: begin
                if (mat_i < `MLDSA_K - 1) begin
                    mat_i     <= mat_i + 3'd1;
                    mat_j     <= 3'd0;
                    coeff_idx <= 8'd0;
                    state     <= KG_CLR_ACC;
                end else begin
                    // All rows done. Pack pk: rho (32B) || t1 (1920B)
                    pk_byte_cnt <= 11'd0;
                    sk_byte_cnt <= 12'd0;
                    coeff_idx   <= 8'd0;
                    sub         <= 4'd0;
                    state       <= KG_PACK_PK_RHO;
                end
            end

            // STEP 8a: Pack pk = rho (32 bytes) || t1 (6 rows � 256 � 10 bits = 1920 bytes)
            KG_PACK_PK_RHO: begin
                pk_we    <= 1'b1;
                pk_addr  <= pk_byte_cnt;
                pk_wdata <= rho[pk_byte_cnt*8 +: 8];
                pk_byte_cnt <= pk_byte_cnt + 11'd1;

                if (pk_byte_cnt == 11'd31) begin
                    coeff_idx <= 8'd0;
                    mat_i     <= 3'd0;
                    t1_pack_cnt <= 3'd0;
                    t1_pack_buf <= 40'd0;
                    pk_byte_cnt <= 11'd0;
                    sub         <= 4'd0;
                    state     <= KG_PACK_PK_T1;
                end
            end

            // Pack t1: 10 bits per coeff, 4 coeffs = 5 bytes
            // Total: 6 rows � 256 coeffs = 1536 coeffs = 1920 bytes
            // Pipelined per-group FSM (sub 0-10). spad read latency = 2 posedges:
            //   t1_pack_buf, sub6-10 write the 5 packed bytes to pk.
            KG_PACK_PK_T1: begin
                case (sub)
                    4'd0: begin
                        sp_rd_addr <= (SLOT_T1_BASE + mat_i) * 256 + (coeff_idx + 8'd0);
                        sub <= 4'd1;
                    end
                    4'd1: begin
                        sp_rd_addr <= (SLOT_T1_BASE + mat_i) * 256 + (coeff_idx + 8'd1);
                        sub <= 4'd2;
                    end
                    4'd2: begin
                        sp_rd_addr <= (SLOT_T1_BASE + mat_i) * 256 + (coeff_idx + 8'd2);
                        t1_pack_buf[9:0] <= sp_rd_data[9:0];
                        sub <= 4'd3;
                    end
                    4'd3: begin
                        sp_rd_addr <= (SLOT_T1_BASE + mat_i) * 256 + (coeff_idx + 8'd3);
                        t1_pack_buf[19:10] <= sp_rd_data[9:0];
                        sub <= 4'd4;
                    end
                    4'd4: begin
                        t1_pack_buf[29:20] <= sp_rd_data[9:0];
                        sub <= 4'd5;
                    end
                    4'd5: begin
                        t1_pack_buf[39:30] <= sp_rd_data[9:0];
                        sub <= 4'd6;
                    end
                    4'd6: begin
                        pk_we <= 1'b1;
                        pk_addr <= 11'd32 + pk_byte_cnt;
                        pk_wdata <= t1_pack_buf[7:0];
                        pk_byte_cnt <= pk_byte_cnt + 11'd1;
                        sub <= 4'd7;
                    end
                    4'd7: begin
                        pk_we <= 1'b1;
                        pk_addr <= 11'd32 + pk_byte_cnt;
                        pk_wdata <= t1_pack_buf[15:8];
                        pk_byte_cnt <= pk_byte_cnt + 11'd1;
                        sub <= 4'd8;
                    end
                    4'd8: begin
                        pk_we <= 1'b1;
                        pk_addr <= 11'd32 + pk_byte_cnt;
                        pk_wdata <= t1_pack_buf[23:16];
                        pk_byte_cnt <= pk_byte_cnt + 11'd1;
                        sub <= 4'd9;
                    end
                    4'd9: begin
                        pk_we <= 1'b1;
                        pk_addr <= 11'd32 + pk_byte_cnt;
                        pk_wdata <= t1_pack_buf[31:24];
                        pk_byte_cnt <= pk_byte_cnt + 11'd1;
                        sub <= 4'd10;
                    end
                    4'd10: begin
                        pk_we <= 1'b1;
                        pk_addr <= 11'd32 + pk_byte_cnt;
                        pk_wdata <= t1_pack_buf[39:32];
                        pk_byte_cnt <= pk_byte_cnt + 11'd1;
                        if (coeff_idx == 8'd252) begin
                            if (mat_i < 3'd5) begin
                                mat_i     <= mat_i + 3'd1;
                                coeff_idx <= 8'd0;
                                sub       <= 4'd0;
                            end else begin
                                state <= KG_HASH_PK_INIT;
                            end
                        end else begin
                            coeff_idx <= coeff_idx + 8'd4;
                            sub       <= 4'd0;
                        end
                    end
                    default: sub <= 4'd0;
                endcase
            end

            // STEP 8b: tr = SHAKE-256(pk, 64) - hash full 1952 byte pk
            // 1952 bytes = 14 full blocks (136 bytes each) + 48 bytes (partial)
            // Byte stream: present pk_rd_addr, capture pk_rd_data one cycle later.
            KG_HASH_PK_INIT: begin
                shake_init       <= 1'b1;
                sub              <= 4'd0;
                byte_cnt         <= 11'd0;      // Next pk byte index to present
                lane_cnt         <= 5'd0;       // Current SHAKE lane (0-16) in block
                hash_byte_in_lane<= 3'd0;
                hash_lane_buf    <= 64'd0;
                pk_rd_addr       <= 11'd0;
                state            <= KG_HASH_PK_ABS;
            end

            // Absorb pk bytes into SHAKE-256 lanes (8 bytes per lane)
            KG_HASH_PK_ABS: begin
                if (shake_rdy && !shake_busy) begin
                    case (sub)
                        4'd0: begin
                            pk_rd_addr <= byte_cnt;
                            sub <= 4'd1;
                        end
                        4'd1: begin
                            // pk_rd_data = pk_ram[byte_cnt] valid now
                            hash_lane_buf[hash_byte_in_lane*8 +: 8] <= pk_rd_data;
                            if (hash_byte_in_lane == 3'd7) begin
                                // 8th byte -> lane complete, write SHAKE lane
                                shake_wr_en <= 1'b1;
                                shake_wr_lane_idx <= lane_cnt;
                                shake_wr_lane_data <= {pk_rd_data, hash_lane_buf[55:0]};
                                hash_byte_in_lane <= 3'd0;
                                hash_lane_buf     <= 64'd0;
                                if (lane_cnt == 5'd16) begin
                                    // 17th lane (136 bytes) -> block full, permute
                                    lane_cnt <= 5'd0;
                                    state    <= KG_HASH_PK_PERM;
                                    sub      <= 4'd0;
                                end else begin
                                    lane_cnt <= lane_cnt + 5'd1;
                                end
                            end else begin
                                hash_byte_in_lane <= hash_byte_in_lane + 3'd1;
                            end
                            byte_cnt <= byte_cnt + 11'd1;
                            if (byte_cnt == 11'd1951) begin
                                state <= KG_HASH_PK_PAD;   // all 1952 bytes absorbed
                                sub   <= 4'd0;
                            end else begin
                                sub   <= 4'd0;   // back to sub0: present next address
                            end
                        end
                        default: sub <= 4'd0;
                    endcase
                end
            end

            KG_HASH_PK_PERM: begin
                shake_permute <= 1'b1;
                sub <= 4'd0;
                state <= KG_HASH_PK_ABS;
            end

            KG_HASH_PK_PAD: begin
                case (sub)
                    4'd0: begin
                        // Partial block: 48 msg bytes (lanes 0-5), then 0x1F at byte 48 (lane 6 byte 0)
                        shake_wr_en <= 1'b1;
                        shake_wr_lane_idx <= 5'd6;
                        shake_wr_lane_data <= 64'h00_00_00_00_00_00_00_1F;
                        sub <= 4'd1;
                    end
                    4'd1: begin
                        // 0x80 at byte 135 (lane 16 byte 7)
                        shake_wr_en <= 1'b1;
                        shake_wr_lane_idx <= 5'd16;
                        shake_wr_lane_data <= 64'h80_00_00_00_00_00_00_00;
                        sub <= 4'd2;
                    end
                    4'd2: begin
                        shake_pad_and_permute <= 1'b1;
                        sub <= 4'd3;
                    end
                    4'd3: begin
                        if (shake_rdy && !shake_busy) begin
                            sub   <= 4'd0;
                            state <= KG_HASH_PK_SQZ;
                        end
                    end
                    default: sub <= 4'd0;
                endcase
            end

            // Squeeze 8 lanes (64 bytes) for tr
            KG_HASH_PK_SQZ: begin
                shake_rd_lane_idx <= sub[3:0];
                case (sub)
                    4'd0: sub <= 4'd1;
                    4'd1: begin tr[63:0]    <= shake_rd_lane_data; shake_rd_lane_idx<=5'd1; sub<=4'd2; end
                    4'd2: begin tr[127:64]  <= shake_rd_lane_data; shake_rd_lane_idx<=5'd2; sub<=4'd3; end
                    4'd3: begin tr[191:128] <= shake_rd_lane_data; shake_rd_lane_idx<=5'd3; sub<=4'd4; end
                    4'd4: begin tr[255:192] <= shake_rd_lane_data; shake_rd_lane_idx<=5'd4; sub<=4'd5; end
                    4'd5: begin tr[319:256] <= shake_rd_lane_data; shake_rd_lane_idx<=5'd5; sub<=4'd6; end
                    4'd6: begin tr[383:320] <= shake_rd_lane_data; shake_rd_lane_idx<=5'd6; sub<=4'd7; end
                    4'd7: begin tr[447:384] <= shake_rd_lane_data; shake_rd_lane_idx<=5'd7; sub<=4'd8; end
                    4'd8: begin
                        tr[511:448] <= shake_rd_lane_data;
                        sk_byte_cnt <= 12'd0;
                        sub         <= 4'd0;
                        state       <= KG_PACK_SK;
                    end
                    default: sub <= 4'd0;
                endcase
            end

            // STEP 8c: Pack sk = rho(32) || K(32) || tr(64) || s1 || s2 || t0
            // sk layout (FIPS 204, eta=4):
            //   0-31:    rho (32 bytes)
            //   32-63:   K (32 bytes)
            //   64-127:  tr (64 bytes)
            //   128-767:  s1 (5 polys x 128 bytes, nibble-pack 2 coeffs/byte)
            //   768-1535: s2 (6 polys x 128 bytes, nibble-pack 2 coeffs/byte)
            //   1536-4031: t0 (6 polys x 416 bytes, 8 coeffs -> 13 bytes)
            // Total: 4032 bytes
            KG_PACK_SK: begin
                case (sub)
                    5'd0: begin
                        // rho / K / tr header bytes 0..127
                        sk_we   <= 1'b1;
                        sk_addr <= sk_byte_cnt;
                        if (sk_byte_cnt < 12'd32)
                            sk_wdata <= rho[sk_byte_cnt*8 +: 8];
                        else if (sk_byte_cnt < 12'd64)
                            sk_wdata <= K_seed[(sk_byte_cnt-12'd32)*8 +: 8];
                        else
                            sk_wdata <= tr[(sk_byte_cnt-12'd64)*8 +: 8];
                        sk_byte_cnt <= sk_byte_cnt + 12'd1;
                        if (sk_byte_cnt == 12'd127) begin
                            sk_pack_poly <= 4'd0;
                            sk_pack_byte <= 8'd0;
                            sub <= 5'd1;
                        end
                    end
                    // eta nibble pack: 4 sub-steps per byte
                    5'd1: begin
                        sk_we <= 1'b0;
                        sp_rd_addr <= sk_eta_base + {1'b0, sk_pack_byte, 1'b0};
                        sub <= 5'd2;
                    end
                    5'd2: begin
                        sk_we <= 1'b0;
                        sp_rd_addr <= sk_eta_base + {1'b0, sk_pack_byte, 1'b0} + 13'd1;
                        sub <= 5'd3;
                    end
                    5'd3: begin
                        sk_we <= 1'b0;
                        sk_nib_lo <= eta_nib(sp_rd_data);
                        sub <= 5'd4;
                    end
                    5'd4: begin
                        // capture odd coeff (presented at sub2), write byte = {hi, lo}
                        sk_we    <= 1'b1;
                        sk_addr  <= sk_eta_wraddr;
                        sk_wdata <= {eta_nib(sp_rd_data), sk_nib_lo};
                        if (sk_pack_byte == 8'd127) begin
                            if (sk_pack_poly == 4'd10) begin
                                // s1+s2 done -> t0
                                t0_poly_idx <= 4'd0;
                                t0_grp_idx  <= 5'd0;
                                t0_pack_sub <= 5'd0;
                                t0_sel      <= 4'd0;
                                state       <= KG_PACK_SK_T0;
                            end else begin
                                sk_pack_poly <= sk_pack_poly + 4'd1;
                                sk_pack_byte <= 8'd0;
                                sub          <= 5'd1;
                            end
                        end else begin
                            sk_pack_byte <= sk_pack_byte + 8'd1;
                            sub          <= 5'd1;
                        end
                    end
                    default: sub <= 5'd0;
                endcase
            end

            // STEP 8d: Pack t0 (13-bit interleaved, 8 coeffs -> 13 bytes)
            // Spad holds offset form t = (1<<12) - a directly (from p2r_t0).
            // sub0-7: present 8 coeff addrs; sub2-9: capture 8 data words;
            // sub10-22: write 13 bytes.
            KG_PACK_SK_T0: begin
                case (t0_pack_sub)
                    5'd0: begin
                        sk_we <= 1'b0;
                        sp_rd_addr <= sk_t0_base + {t0_grp_idx, 3'd0};
                        t0_pack_sub <= 5'd1;
                    end
                    5'd1: begin
                        sk_we <= 1'b0;
                        sp_rd_addr <= sk_t0_base + {t0_grp_idx, 3'd0} + 13'd1;
                        t0_pack_sub <= 5'd2;
                    end
                    5'd2: begin
                        sk_we <= 1'b0;
                        sp_rd_addr <= sk_t0_base + {t0_grp_idx, 3'd0} + 13'd2;
                        t0_pack_buf[12:0] <= sp_rd_data[12:0];
                        t0_pack_sub <= 5'd3;
                    end
                    5'd3: begin
                        sk_we <= 1'b0;
                        sp_rd_addr <= sk_t0_base + {t0_grp_idx, 3'd0} + 13'd3;
                        t0_pack_buf[25:13] <= sp_rd_data[12:0];
                        t0_pack_sub <= 5'd4;
                    end
                    5'd4: begin
                        sk_we <= 1'b0;
                        sp_rd_addr <= sk_t0_base + {t0_grp_idx, 3'd0} + 13'd4;
                        t0_pack_buf[38:26] <= sp_rd_data[12:0];
                        t0_pack_sub <= 5'd5;
                    end
                    5'd5: begin
                        sk_we <= 1'b0;
                        sp_rd_addr <= sk_t0_base + {t0_grp_idx, 3'd0} + 13'd5;
                        t0_pack_buf[51:39] <= sp_rd_data[12:0];
                        t0_pack_sub <= 5'd6;
                    end
                    5'd6: begin
                        sk_we <= 1'b0;
                        sp_rd_addr <= sk_t0_base + {t0_grp_idx, 3'd0} + 13'd6;
                        t0_pack_buf[64:52] <= sp_rd_data[12:0];
                        t0_pack_sub <= 5'd7;
                    end
                    5'd7: begin
                        sk_we <= 1'b0;
                        sp_rd_addr <= sk_t0_base + {t0_grp_idx, 3'd0} + 13'd7;
                        t0_pack_buf[77:65] <= sp_rd_data[12:0];
                        t0_pack_sub <= 5'd8;
                    end
                    5'd8: begin
                        sk_we <= 1'b0;
                        t0_pack_buf[90:78] <= sp_rd_data[12:0];
                        t0_pack_sub <= 5'd9;
                    end
                    5'd9: begin
                        sk_we <= 1'b0;
                        t0_pack_buf[103:91] <= sp_rd_data[12:0];
                        t0_pack_sub <= 5'd10;
                    end
                    5'd10: begin
                        sk_we    <= 1'b1;
                        sk_addr  <= sk_t0_wraddr;
                        sk_wdata <= t0_byte(t0_pack_buf, 4'd0);
                        t0_sel   <= 4'd1;
                        t0_pack_sub <= 5'd11;
                    end
                    5'd11: begin
                        sk_we    <= 1'b1;
                        sk_addr  <= sk_t0_wraddr;
                        sk_wdata <= t0_byte(t0_pack_buf, 4'd1);
                        t0_sel   <= 4'd2;
                        t0_pack_sub <= 5'd12;
                    end
                    5'd12: begin
                        sk_we    <= 1'b1;
                        sk_addr  <= sk_t0_wraddr;
                        sk_wdata <= t0_byte(t0_pack_buf, 4'd2);
                        t0_sel   <= 4'd3;
                        t0_pack_sub <= 5'd13;
                    end
                    5'd13: begin
                        sk_we    <= 1'b1;
                        sk_addr  <= sk_t0_wraddr;
                        sk_wdata <= t0_byte(t0_pack_buf, 4'd3);
                        t0_sel   <= 4'd4;
                        t0_pack_sub <= 5'd14;
                    end
                    5'd14: begin
                        sk_we    <= 1'b1;
                        sk_addr  <= sk_t0_wraddr;
                        sk_wdata <= t0_byte(t0_pack_buf, 4'd4);
                        t0_sel   <= 4'd5;
                        t0_pack_sub <= 5'd15;
                    end
                    5'd15: begin
                        sk_we    <= 1'b1;
                        sk_addr  <= sk_t0_wraddr;
                        sk_wdata <= t0_byte(t0_pack_buf, 4'd5);
                        t0_sel   <= 4'd6;
                        t0_pack_sub <= 5'd16;
                    end
                    5'd16: begin
                        sk_we    <= 1'b1;
                        sk_addr  <= sk_t0_wraddr;
                        sk_wdata <= t0_byte(t0_pack_buf, 4'd6);
                        t0_sel   <= 4'd7;
                        t0_pack_sub <= 5'd17;
                    end
                    5'd17: begin
                        sk_we    <= 1'b1;
                        sk_addr  <= sk_t0_wraddr;
                        sk_wdata <= t0_byte(t0_pack_buf, 4'd7);
                        t0_sel   <= 4'd8;
                        t0_pack_sub <= 5'd18;
                    end
                    5'd18: begin
                        sk_we    <= 1'b1;
                        sk_addr  <= sk_t0_wraddr;
                        sk_wdata <= t0_byte(t0_pack_buf, 4'd8);
                        t0_sel   <= 4'd9;
                        t0_pack_sub <= 5'd19;
                    end
                    5'd19: begin
                        sk_we    <= 1'b1;
                        sk_addr  <= sk_t0_wraddr;
                        sk_wdata <= t0_byte(t0_pack_buf, 4'd9);
                        t0_sel   <= 4'd10;
                        t0_pack_sub <= 5'd20;
                    end
                    5'd20: begin
                        sk_we    <= 1'b1;
                        sk_addr  <= sk_t0_wraddr;
                        sk_wdata <= t0_byte(t0_pack_buf, 4'd10);
                        t0_sel   <= 4'd11;
                        t0_pack_sub <= 5'd21;
                    end
                    5'd21: begin
                        sk_we    <= 1'b1;
                        sk_addr  <= sk_t0_wraddr;
                        sk_wdata <= t0_byte(t0_pack_buf, 4'd11);
                        t0_sel   <= 4'd12;
                        t0_pack_sub <= 5'd22;
                    end
                    5'd22: begin
                        sk_we    <= 1'b1;
                        sk_addr  <= sk_t0_wraddr;
                        sk_wdata <= t0_byte(t0_pack_buf, 4'd12);
                        t0_sel   <= 4'd0;
                        if (t0_grp_idx == 5'd31) begin
                            if (t0_poly_idx == 4'd5) begin
                                state <= KG_DONE;
                            end else begin
                                t0_poly_idx  <= t0_poly_idx + 4'd1;
                                t0_grp_idx   <= 5'd0;
                                t0_pack_sub  <= 5'd0;
                            end
                        end else begin
                            t0_grp_idx  <= t0_grp_idx + 5'd1;
                            t0_pack_sub <= 5'd0;
                        end
                    end
                    default: t0_pack_sub <= 5'd0;
                endcase
            end

            KG_DONE: begin
                done  <= 1'b1;
                busy  <= 1'b0;
                state <= KG_IDLE;
            end

            default: state <= KG_IDLE;

            endcase
        end
    end

    // Initialize scratchpad to zero (simulation only)
    integer ii;
    initial begin
        for (ii = 0; ii < 7680; ii = ii + 1)
            spad[ii] = 23'd0;
        t1_pack_cnt = 3'd0;
        t1_byte_idx = 3'd0;
        t1_pending = 1'b0;
        pk_byte_cnt = 11'd0;
        sk_byte_cnt = 12'd0;
        t1_pack_buf = 40'd0;
        sk_pack_poly = 4'd0;
        sk_pack_byte = 8'd0;
        sk_nib_lo = 4'd0;
        sk_nib_hi = 4'd0;
        t0_pack_sub = 5'd0;
        t0_poly_idx = 4'd0;
        t0_grp_idx = 5'd0;
        t0_sel = 4'd0;
        t0_pack_buf = 104'd0;
    end

endmodule
