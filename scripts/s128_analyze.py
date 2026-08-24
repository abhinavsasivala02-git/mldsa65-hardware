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
# Reconstruct the DUT SHAKE-128 squeeze byte stream for A[0][0] from
# s128_raw_00.txt and compare byte-by-byte against the reference
# SHAKE128(rho || 0x00 || 0x00) stream, grouped by 168-byte block.
#
# Probe semantics (tb_mldsa_sign_kat.v):
#   logs POST-posedge registered values of (rej_phase, lane_cnt,
#   byte_in_lane, s128_rd_lane_idx, rej_b0/b1/b2) every FEED cycle.
#   => the byte consumed at a cycle = b[ph] of that line;
#      its stream position  = (byte, lidx) of the PREVIOUS line.

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mldsa_ref import keypair, shake128

RAWDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
RAW = os.path.join(RAWDIR, 's128_raw_00.txt')
OUT = os.path.join(RAWDIR, 's128_recon.txt')

xi0 = bytes(range(0x00, 0x20))
pk, sk, tr = keypair(xi0)
rho = sk[0:32]
seed = rho + bytes([0, 0])
print('rho = %s' % rho.hex())
print('seed = %s' % seed.hex())

ref = shake128(seed, 168 * 6)
print('ref block1 = %s' % ref[0:24].hex())
print('ref block2 = %s' % ref[168:192].hex())

lines = []
with open(RAW, 'r') as f:
    for ln in f:
        d = {k: int(v, 16) if k.startswith('b') else int(v)
             for k, v in re.findall(r'(\w+)=(\S+)', ln)}
        lines.append(d)

prev_byte = 0
prev_lidx = 0
stream = []       # list of (block_idx, pos_in_block, byte_val)
block = 0
out = open(OUT, 'w')
for i, d in enumerate(lines):
    pos = prev_lidx * 8 + prev_byte
    val = d['b' + str((d['ph'] - 1) % 3)]
    if d['ph'] == 0 and prev_byte == 7 and prev_lidx == 20:
        block += 1
    stream.append((block, pos, val))
    out.write('line %5d: ph=%d pos=%3d (byte=%d lidx=%d) val=%02x\n' %
              (i, d['ph'], pos, prev_byte, prev_lidx, val))
    prev_byte = d['byte']
    prev_lidx = d['lidx']
out.close()

print('total consumed bytes = %d, blocks touched = %d' % (len(stream), block + 1))

# Per block: reconstruct the DUT stream ORDER of block positions and compare
# against reference block bytes (mapping consumed pos -> ref byte at that pos).
for b in range(0, block + 1):
    seg = [s for s in stream if s[0] == b]
    if not seg:
        continue
    dut_seq = [s[2] for s in seg]          # values as consumed
    ref_pos = [s[1] for s in seg]          # block positions consumed
    mism = [j for j in range(len(seg)) if dut_seq[j] != ref[168 * b + ref_pos[j]]]
    # count distinct positions actually covered
    cov = sorted(set(ref_pos))
    miss0 = [p for p in range(168) if p not in set(ref_pos)]
    print('block %d: consumed %d bytes, distinct positions covered %d/168' %
          (b, len(seg), len(cov)))
    print('  wrong values = %d, missing positions = %s' % (len(mism), miss0[:8]))
    for j in mism[:12]:
        p = ref_pos[j]
        print('   stream idx %d: pos %3d dut=%02x ref=%02x' %
              (j, p, dut_seq[j], ref[168 * b + p]))