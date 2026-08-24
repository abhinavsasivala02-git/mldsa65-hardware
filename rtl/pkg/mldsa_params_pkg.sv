
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

package mldsa_params_pkg;

        localparam int unsigned Q      = 8_380_417;   localparam int unsigned QBITS  = 23;          localparam int unsigned N      = 256;         localparam int unsigned LOG2N  = 8;
        localparam int unsigned K      = 6;           localparam int unsigned L      = 5;           localparam int unsigned ETA    = 4;           localparam int unsigned TAU    = 49;          localparam int unsigned BETA   = 196;         localparam int unsigned GAMMA1 = 524288;      localparam int unsigned GAMMA2 = 261888;      localparam int unsigned OMEGA  = 55;          localparam int unsigned LAMBDA = 192;         localparam int unsigned D      = 13;
        localparam int unsigned SK_BYTES  = 4032;
  localparam int unsigned PK_BYTES  = 1952;
  localparam int unsigned SIG_BYTES = 3309;

          localparam int unsigned MONT_R       = 4_193_792;      localparam int unsigned MONT_R2      = 2_365_951;      localparam int unsigned MONT_QINV    = 58_728_449;         localparam logic [31:0] MONT_QINV_NEG = 32'd4_236_238_847;
    // NTT parameters
    localparam int unsigned ZETA     = 1753;        localparam int unsigned NINV_MONT = 24_769;
        `include "zeta_rom.vh"

endpackage
