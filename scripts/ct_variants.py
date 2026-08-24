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
# Try to find which absorb variant reproduces the DUT c_tilde
import sys
sys.path.insert(0, 'scripts')
from mldsa_ref import (keypair, H, unpack_sk, polyvec_matrix_expand, ntt,
                       invntt_tomont, caddq, decompose, polyw1_pack,
                       poly_uniform_gamma1, polyvec_pointwise_acc_montgomery,
                       CRHBYTES, CTILDEBYTES, L, K, N)
import hashlib

DUT_CT = bytes.fromhex('5265224a118ff286dcbf08287fb393850437907542e8ff191fadd9887457594d')

xi = bytes(range(0x20))
pk, sk, tr = keypair(xi)
rho, key, tr, s1, s2, t0 = unpack_sk(sk)
rnd = bytes((0xA0 + j) % 256 for j in range(32))
msg = b'ML-DSA-65 signing KAT vector 0'
mu = H(tr + b'\x00\x00' + msg, CRHBYTES)
rhoprime = H(key + rnd + mu, CRHBYTES)
mat = polyvec_matrix_expand(rho)
y = [poly_uniform_gamma1(rhoprime, 15 + i) for i in range(L)]
yhat = [ntt(p) for p in y]
w1buf = bytearray()
w0buf = bytearray()
for k in range(K):
    wk = polyvec_pointwise_acc_montgomery([mat[k][j] for j in range(L)], yhat)
    wk = invntt_tomont(wk)
    wk = [caddq(x) for x in wk]
    w1k = [decompose(x)[1] for x in wk]
    w0k = [decompose(x)[0] for x in wk]
    w1buf.extend(polyw1_pack(w1k))
    w0buf.extend(polyw1_pack(w0k))

def rev8(b):
    return b''.join(b[i:i+8][::-1] for i in range(0, len(b), 8))

def rev_all(b):
    return b[::-1]

def swap_nib(b):
    return bytes((x >> 4) | ((x & 0xF) << 4) for x in b)

variants = {
    'ref mu+w1':             mu + bytes(w1buf),
    'mu+w1 lane8-rev':       rev8(mu) + rev8(bytes(w1buf)),
    'w1+mu':                 bytes(w1buf) + mu,
    'mu+w1 nib-swap':        mu + swap_nib(bytes(w1buf)),
    'mu+w1 all-rev':         mu + rev_all(bytes(w1buf)),
    'mu+w1 nibswap+8rev':    mu + rev8(swap_nib(bytes(w1buf))),
    'w1 lane8-rev + mu':     rev8(bytes(w1buf)) + rev8(mu),
    'mu+w1 w0 instead':      mu + bytes(w0buf),
    'mu+w1 one-poly-shift':  mu + bytes(w1buf[128:]) + bytes(w1buf[:128]),
    'mu+w1 poly-order-rev':  mu + bytes(w1buf[640:]) + bytes(w1buf[512:640]) + bytes(w1buf[384:512]) + bytes(w1buf[256:384]) + bytes(w1buf[128:256]) + bytes(w1buf[0:128]),
}

print('DUT  ', DUT_CT.hex())
for name, data in variants.items():
    h = hashlib.shake_256(data).digest(48)
    tag = 'MATCH' if h[:32] == DUT_CT else ''
    print('%-22s %s %s' % (name, h[:32].hex(), tag))