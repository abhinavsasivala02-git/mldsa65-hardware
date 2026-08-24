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
# Generate reference ML-DSA-65 pk/sk byte files for the sign KAT testbench.
#
# For each of the 5 KAT seeds (xi = 0x20*i .. 0x20*i+0x1f), this emits:
#   - sim/tb/ref_pk_<i>.mem   : pk bytes, one hex byte per line
#   - sim/tb/ref_sk_<i>.mem   : sk bytes, one hex byte per line
#
# These are the standard reference keys from scripts/mldsa_ref.py (keypair).
# The sign TB loads them into pk_ram (0x0800) / sk_ram (0x1000) via AXI and
# runs sign directly, without calling the on-chip keygen.

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mldsa_ref import keypair

NUM_VEC = 5
TB_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'sim', 'tb')


def make_xi(i):
    return bytes(range(0x20 * i, 0x20 * i + 0x20))


def main():
    for i in range(NUM_VEC):
        pk, sk, tr = keypair(make_xi(i))
        with open(os.path.join(TB_DIR, 'ref_pk_%d.mem' % i), 'w') as f:
            for b in pk:
                f.write('%02x\n' % b)
        with open(os.path.join(TB_DIR, 'ref_sk_%d.mem' % i), 'w') as f:
            for b in sk:
                f.write('%02x\n' % b)
        print('vec %d: pk=%d sk=%d tr=%s' % (i, len(pk), len(sk), tr.hex()))
    print('Wrote sim/tb/ref_pk_<i>.mem and sim/tb/ref_sk_<i>.mem')


if __name__ == '__main__':
    main()