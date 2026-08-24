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
# Validate hypothesis: DUT c_tilde = H(mu || w1_4polys || 2 extra polys of spad data)
import sys
sys.path.insert(0, 'scripts')
from mldsa_ref import (keypair, H, unpack_sk, polyvec_matrix_expand, ntt,
                       invntt_tomont, caddq, decompose, polyw1_pack,
                       poly_uniform_gamma1, polyvec_pointwise_acc_montgomery,
                       CRHBYTES, CTILDEBYTES, L, K, N)

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
for k in range(K):
    wk = polyvec_pointwise_acc_montgomery([mat[k][j] for j in range(L)], yhat)
    wk = invntt_tomont(wk)
    wk = [caddq(x) for x in wk]
    w1k = [decompose(x)[1] for x in wk]
    w1buf.extend(polyw1_pack(w1k))
print('w1buf len', len(w1buf))
print('ref  ctilde', H(mu + bytes(w1buf), CTILDEBYTES).hex())
print('dut  ctilde', '5265224a118ff286dcbf08287fb393850437907542e8ff191fadd9887457594d')
print('dut6(zeros) ctilde', H(mu + bytes(w1buf) + bytes(256), CTILDEBYTES).hex())