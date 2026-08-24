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
import re
vcd = open('tb_ntt_check.vcd', 'rb').read().decode('latin-1')
names = {}
for m in re.finditer(r'\$var\s+\w+\s+\d+\s+(\S+)\s+(\S+)', vcd):
    names[m.group(1)] = m.group(2)
print("total vars:", len(names))
for k, v in names.items():
    if any(w in v for w in ('state', 'bf_', 'fsm_addra', 'wa_dly', 'zeta',
                            'dout', 'wea', 'k_idx', 'j_cnt', 'blk_start',
                            'sram_', 'rom')):
        print(k, v)
