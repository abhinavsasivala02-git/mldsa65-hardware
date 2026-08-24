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
# Compare DUT-dumped signature hex files (sig_<i>.hex, produced by
# tb_mldsa_sign_kat.v) against reference expected/sig_<i>.hex.
#
# Both files contain 828 32-bit little-endian words; sig bytes = concat of
# words, trimmed to 3309 bytes.

import os
import sys


def load_hex_words(path):
    words = []
    for line in open(path, 'r'):
        line = line.strip()
        if not line:
            continue
        line = line.replace('x', '0').replace('X', '0')
        words.append(int(line, 16))
    return words


def words_to_bytes(words):
    return b''.join(w.to_bytes(4, 'little') for w in words)


def main():
    exp_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'expected')
    num = int(sys.argv[1]) if len(sys.argv) > 1 else 5
    ok = 0
    for i in range(num):
        exp_path = os.path.join(exp_dir, 'sig_%d.hex' % i)
        dut_path = 'sig_%d.hex' % i
        exp = words_to_bytes(load_hex_words(exp_path))[:3309]
        dut = words_to_bytes(load_hex_words(dut_path))[:3309]
        if exp == dut:
            ok += 1
            print('vec %d: PASS' % i)
            continue
        # first mismatch
        for j in range(min(len(exp), len(dut))):
            if exp[j] != dut[j]:
                print('vec %d: FAIL - first mismatch at byte %d (0x%02x exp vs 0x%02x dut)'
                      % (i, j, exp[j], dut[j]))
                break
        else:
            print('vec %d: FAIL - length mismatch (%d exp vs %d dut)'
                  % (i, len(exp), len(dut)))
    print('--- %d passed, %d failed ---' % (ok, num - ok))
    return 0 if ok == num else 1


if __name__ == '__main__':
    sys.exit(main())