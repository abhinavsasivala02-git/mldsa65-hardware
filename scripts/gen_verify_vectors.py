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
# Generate reference verify vectors for the ML-DSA-65 verify KAT testbench.
#
# For each of the 5 KAT vectors this emits:
#   - sim/tb/ref_vf_pk_<i>.mem   : pk bytes (one hex byte per line, 1952)
#   - sim/tb/ref_vf_sig_<i>.mem  : signature bytes (one hex byte per line, 3309)
#   - sim/tb/ref_vf_mu_<i>.mem   : mu bytes (one hex byte per line, 64)
#   - sim/tb/ref_vf_rho_<i>.mem  : rho bytes (one hex byte per line, 32)
#
# The signature is the reference sign() output for the standard KAT seed,
# so verify should return valid=1. A companion tamper test flips one byte.

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mldsa_ref import keypair, sign, H, CRHBYTES

NUM_VEC = 5
TB_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'sim', 'tb')


def make_xi(i):
    return bytes(range(0x20 * i, 0x20 * i + 0x20))


def make_msg(i):
    return b'ML-DSA-65 signing KAT vector %d' % i


def make_rnd(i):
    return bytes((0xA0 + j) % 256 for j in range(32))


def write_bytes(path, data):
    with open(path, 'w') as f:
        for b in data:
            f.write('%02x\n' % b)


def main():
    for i in range(NUM_VEC):
        pk, sk, tr = keypair(make_xi(i))
        msg = make_msg(i)
        rnd = make_rnd(i)
        sig, mu, kappa = sign(sk, msg, rnd)
        rho = pk[0:32]

        write_bytes(os.path.join(TB_DIR, 'ref_vf_pk_%d.mem' % i), pk)
        write_bytes(os.path.join(TB_DIR, 'ref_vf_sig_%d.mem' % i), sig)
        write_bytes(os.path.join(TB_DIR, 'ref_vf_mu_%d.mem' % i), mu)
        write_bytes(os.path.join(TB_DIR, 'ref_vf_rho_%d.mem' % i), rho)

        # sanity: reference verify must accept this sig
        from mldsa_ref import (polyt1_unpack, polyz_unpack, poly_challenge, ntt,
                               invntt_tomont, poly_pointwise_montgomery,
                               polyvec_pointwise_acc_montgomery,
                               polyvec_matrix_expand, polyw1_pack, use_hint,
                               unpack_hints, chknorm_flatten, GAMMA1, BETA,
                               reduce32, caddq, D, Q, OMEGA, L, K, N,
                               CTILDEBYTES, POLYT1_PACKEDBYTES, POLYZ_PACKEDBYTES)
        ok = True
        ctilde = sig[0:CTILDEBYTES]
        z = [polyz_unpack(sig[CTILDEBYTES + l * POLYZ_PACKEDBYTES:
                             CTILDEBYTES + (l + 1) * POLYZ_PACKEDBYTES])
             for l in range(L)]
        if chknorm_flatten(z, GAMMA1 - BETA):
            ok = False
        else:
            c = poly_challenge(ctilde)
            chat = ntt(c)
            zhat = [ntt(p) for p in z]
            mat = polyvec_matrix_expand(rho)
            base = CTILDEBYTES + L * POLYZ_PACKEDBYTES
            hints = sig[base:base + OMEGA + K]
            w1buf = bytearray()
            for k in range(K):
                w = polyvec_pointwise_acc_montgomery([mat[k][j] for j in range(L)], zhat)
                w = invntt_tomont(w)
                t1 = polyt1_unpack(pk[32 + k * POLYT1_PACKEDBYTES:
                                      32 + (k + 1) * POLYT1_PACKEDBYTES])
                ct1 = invntt_tomont(poly_pointwise_montgomery(chat, ntt([x << D for x in t1])))
                w = [(w[i] - ct1[i]) % Q for i in range(N)]
                w = [caddq(reduce32(x)) for x in w]
                hk, old = unpack_hints(hints, k)
                w1 = [use_hint(w[i], hk[i]) for i in range(N)]
                w1buf.extend(polyw1_pack(w1))
            ctp = H(mu + bytes(w1buf), CTILDEBYTES)
            if ctilde != ctp:
                ok = False
        print('vec %d: sig=%d pk=%d  ref-verify=%s' % (i, len(sig), len(pk), 'PASS' if ok else 'FAIL'))
    print('Wrote sim/tb/ref_vf_{pk,sig,mu,rho}_<i>.mem')


if __name__ == '__main__':
    main()
