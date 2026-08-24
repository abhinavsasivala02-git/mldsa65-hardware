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
# Reconstruct the DUT c_tilde SHAKE-256 absorb from ct_absorb_0.txt and compare
import sys, hashlib
sys.path.insert(0, 'scripts')
from mldsa_ref import (keypair, H, unpack_sk, polyvec_matrix_expand, ntt,
                       invntt_tomont, caddq, decompose, polyw1_pack,
                       poly_uniform_gamma1, polyvec_pointwise_acc_montgomery,
                       CRHBYTES, CTILDEBYTES, L, K, N)

lines = [l.split() for l in open('ct_absorb_0.txt') if l.strip()]
lanes = []
permutes = 0
pad_lines = []
sq = []
last_st = None
for f in lines:
    st = int(f[0].split('=')[1])
    sub = int(f[1].split('=')[1])
    if last_st != st and st == 36:
        permutes += 1
    if f[2].split('=')[1] == '1':            # wena
        lanes.append((int(f[3].split('=')[1]), int(f[4].split('=')[1], 16)))
    if st in (38, 39):
        pad_lines.append((st, sub, f[4].split('=')[1][:2]))
    if st == 40:
        sq.append((int(f[6].split('=')[1]), int(f[7].split('=')[1], 16)))
    last_st = st

print('lane writes: %d' % len(lanes))
print('intermediate permutes seen (st==36): %d' % permutes)

# Reconstruct absorbed bytes: each lane write = 8 bytes, byte0 = LSB
msg = b''.join(dat.to_bytes(8, 'little') for _, dat in lanes)
print('reconstructed msg len: %d' % len(msg))

# pad writes: dump the data + lane idx (they use shake_wr_lane_idx too)
print('pad-state lines (first 6):')
for p in pad_lines[:6]:
    print('  st=%d sub=%d wdat=%s' % p)

# squeeze lanes
print('squeeze lanes: %d' % len(sq))
squeezed = b''
for ridx, rdat in sq:
    squeezed += rdat.to_bytes(8, 'little')
print('DUT squeezed (%d bytes): %s' % (len(squeezed), squeezed[:48].hex()))

# ---- reference ----
xi = bytes(range(0x20))
pk, sk, tr = keypair(xi)
rho, key, tr, s1, s2, t0 = unpack_sk(sk)
rnd = bytes((0xA0 + j) % 256 for j in range(32))
msgv = b'ML-DSA-65 signing KAT vector 0'
mu = H(tr + b'\x00\x00' + msgv, CRHBYTES)
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
w1buf = bytes(w1buf)

print('ref mu: %s' % mu.hex())
print('DUT mu lane0 bytes: %s' % msg[0:8].hex())
print('ref w1buf: %s' % w1buf[:24].hex())
print('DUT w1 bytes : %s' % msg[64:88].hex())
print('ref  msg len : %d   DUT msg len: %d' % (len(mu)+len(w1buf), len(msg)))
if msg == mu + w1buf:
    print('RECONSTRUCTED MSG == mu + w1buf  (EXACT)')
else:
    n = min(len(msg), len(mu)+len(w1buf))
    for i in range(n):
        e = (mu + w1buf)[i]
        if msg[i] != e:
            print('first byte mismatch at %d: DUT=%02x ref=%02x' % (i, msg[i], e))
            break
    else:
        print('prefix matches, length differs (DUT %d vs ref %d)' % (len(msg), len(mu)+len(w1buf)))

ref_hash = hashlib.shake_256(mu + w1buf).digest(48)
print('ref  shake(mu+w1)  : %s' % ref_hash.hex())
print('DUT squeezed       : %s' % squeezed[:48].hex())
print('MATCH' if ref_hash[:32] == squeezed[:32] else 'DIFFERENT')