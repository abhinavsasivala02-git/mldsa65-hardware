# Copyright (C) 2026
# Author: Abhinav S <abhinavsasivala02@gmail.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software Foundation,
# Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
#!/usr/bin/env python3
# Compare DUT sign intermediates (w_0.txt, ct_inputs_0.txt, mm_acc_0.txt)
# against the reference ML-DSA-65 sign path for vector 0 (kappa=15).

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mldsa_ref import (keypair, sign, H, unpack_sk, polyvec_matrix_expand,
                       ntt, invntt_tomont, caddq, decompose, polyw1_pack,
                       poly_challenge, poly_pointwise_montgomery,
                       polyvec_pointwise_acc_montgomery, reduce32, chknorm,
                       poly_uniform_gamma1, CRHBYTES, CTILDEBYTES, GAMMA1,
                       BETA, L, K, N)


def make_xi(i):
    return bytes(range(0x20 * i, 0x20 * i + 0x20))


def make_rnd(i):
    base = 0xA0 + 0x20 * i
    return bytes((base + j) % 256 for j in range(32))


def make_msg(i):
    return b'ML-DSA-65 signing KAT vector %d' % i


def load_spad(path):
    """Parse lines 'w1_i_j <hex>' / 'w0_i_j <hex>' / 'ctilde_i <hex>'."""
    w1 = {}
    w0 = {}
    ct = {}
    for line in open(path, 'r'):
        line = line.strip()
        if not line or line.startswith('vec') or line.startswith('ctilde_') is False and ' ' not in line:
            continue
        toks = line.split()
        if 'x' in toks[-1].lower() and not toks[0].startswith('ctilde'):
            continue
        if toks[0].startswith('ctilde'):
            ct[toks[0]] = int(toks[1], 16)
        elif toks[0].startswith('w1'):
            _, i, j = toks[0].split('_')
            w1[(int(i), int(j))] = int(toks[1], 16)
        elif toks[0].startswith('w0'):
            _, i, j = toks[0].split('_')
            w0[(int(i), int(j))] = int(toks[1], 16)
    return ct, w1, w0


def main():
    raws = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
    xi = make_xi(0)
    pk, sk, tr = keypair(xi)
    rho, key, tr, s1, s2, t0 = unpack_sk(sk)
    rnd = make_rnd(0)
    msg = make_msg(0)

    mu = H(tr + b'\x00\x00' + msg, CRHBYTES)
    rhoprime = H(key + rnd + mu, CRHBYTES)
    print('tr     = %s' % tr.hex())
    print('mu     = %s' % mu.hex())
    print('rhopri = %s' % rhoprime.hex())

    mat = polyvec_matrix_expand(rho)

    kappa = 15
    y = [poly_uniform_gamma1(rhoprime, kappa + i) for i in range(L)]
    yhat = [ntt(p) for p in y]

    w1 = []
    w0 = []
    w1buf = bytearray()
    for k in range(K):
        wk = polyvec_pointwise_acc_montgomery([mat[k][j] for j in range(L)], yhat)
        wk = invntt_tomont(wk)
        wk = [caddq(x) for x in wk]
        w1k = []
        w0k = []
        for i in range(N):
            a0, a1 = decompose(wk[i])
            w0k.append(a0)
            w1k.append(a1)
        w1.append(w1k)
        w0.append(w0k)
        w1buf.extend(polyw1_pack(w1k))

    ctilde = H(mu + bytes(w1buf), CTILDEBYTES)
    print('ref w1buf[0:24] = %s' % bytes(w1buf)[0:24].hex())
    print('ref ctilde      = %s' % ctilde.hex())

    # --- DUT ---
    ct, dw1, dw0 = load_spad(os.path.join(raws, 'w_0.txt'))
    # reconstruct DUT ctilde bytes from the 64-bit words (big-endian order)
    dut_ct = b''
    for i in range(6):
        w = ct.get('ctilde_%d' % i, 0)
        dut_ct += w.to_bytes(8, 'big')
    print('DUT ctilde      = %s' % dut_ct[:32].hex())
    print('ctilde match    :', dut_ct[:32] == ctilde)

    mism = 0
    for k in range(K):
        for i in range(N):
            if dw1.get((k, i)) is not None and dw1[(k, i)] != w1[k][i]:
                mism += 1
                if mism <= 10:
                    print('w1 mismatch k=%d i=%d dut=%d ref=%d' %
                          (k, i, dw1[(k, i)], w1[k][i]))
    print('w1 mismatches: %d / %d' % (mism, K * N))

    mism0 = 0
    for k in range(K):
        for i in range(N):
            if dw0.get((k, i)) is not None and dw0[(k, i)] != w0[k][i]:
                mism0 += 1
    print('w0 mismatches: %d / %d' % (mism0, K * N))

    # reference A[0][0] = poly_uniform(rho + bytes([0,0]))
    from mldsa_ref import poly_uniform
    A00 = poly_uniform(rho + bytes([0, 0]))
    # DUT acc[0][c] = sum_j A[j][c]*y_hat[j][c] -- reference:
    acc = [0] * N
    for c in range(N):
        s = 0
        for j in range(L):
            Ajc = poly_uniform(rho + bytes([j, 0]))[c]
            s += Ajc * yhat[j][c]
        acc[c] = s % 8380417
    print('ref acc[0][0:8] = %s' % ' '.join('%x' % v for v in acc[0:8]))


if __name__ == '__main__':
    main()