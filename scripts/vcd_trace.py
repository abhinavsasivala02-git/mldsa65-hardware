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
import re, sys

vcd = open('tb_ntt_check.vcd', 'rb').read().decode('latin-1')

# Parse variable declarations: $var <type> <size> <id> <name> $end
names = {}
for m in re.finditer(r'\$var\s+\w+\s+\d+\s+(\S+)\s+(\S+)', vcd):
    names[m.group(1)] = m.group(2)

# Extract time/value changes. We build per-signal value history by scanning.
# Simpler: find first time when state becomes S_INIT etc. We'll locate the
# NTT run (busy=1) and dump the first block.

# Determine id of signals we care about
targets = {}
for k, v in names.items():
    if any(w in v for w in ['bf_a_in', 'bf_b_in', 'bf_zeta', 'fsm_addra',
                            'fsm_addrb', 'wa_dly_3', 'bf_a_out', 'bf_b_out',
                            'fsm_dina', 'fsm_dinb', 'douta', 'doutb', 'wea',
                            'k_idx', 'j_cnt', 'blk_start', 'state', 'sram_douta']):
        targets[k] = v

# tokens: sections between #<time> and values
# value records look like: <time> <id><value> ...  e.g. "0x$t" for scalar? Actually
# iverilog: "#<time>\n<id>1\n" for scalar and "<id> b10101 ...\n" for vectors
# We'll just scan sequentially.
parts = vcd.split('\n')
cur_time = 0
vals = {}  # id -> (time, value)
# find start of dump (after $dumpvars)
out = []
for line in parts:
    s = line.strip()
    if s.startswith('#'):
        cur_time = int(s[1:])
    else:
        if not s:
            continue
        if s[0] in names:
            # scalar change
            idc = s[0]
            val = s[1]
            vals[idc] = (cur_time, val)
        elif len(s) > 1 and s[0] == 'b':
            # vector
            mm = re.match(r'b([01xzXZ]+)\s+(\S+)', s)
            if mm:
                val = mm.group(1)
                idc = mm.group(2)
                vals[idc] = (cur_time, val)
        elif len(s) > 1 and s[0] in 'r':
            # real, ignore
            pass

# Now reconstruct: we want a timeline. Collect all changes sorted by time.
# Rebuild event list
events = []
parts = vcd.split('\n')
cur_time = 0
for line in parts:
    s = line.strip()
    if s.startswith('#'):
        cur_time = int(s[1:])
    elif s and s[0] in names:
        events.append((cur_time, s[0], s[1]))
    elif len(s) > 1 and s[0] == 'b':
        mm = re.match(r'b([01xzXZ]+)\s+(\S+)', s)
        if mm:
            events.append((cur_time, mm.group(2), mm.group(1)))

# find the first state==1 (S_INIT) time
# state id:
state_id = None
for k, v in targets.items():
    if v == 'state':
        state_id = k
# We need binary->int for state
def b2i(b):
    b = b.lower().replace('x', '0').replace('z', '0')
    return int(b, 2)

start_times = [t for (t, idc, v) in events if idc == state_id and b2i(v) == 1]
print("S_INIT occurrences:", start_times[:5])
if not start_times:
    sys.exit(0)
t0 = start_times[0]

# Now dump signal values in [t0, t0+400]
state_names = {0:'IDLE',1:'INIT',2:'BLK_INIT',3:'READ',4:'WAIT',5:'BF0',6:'BF1',7:'BF2',8:'BF3',9:'WRITE',10:'SCALE',11:'SCALE_W',12:'DONE',13:'ZETA_WAIT'}
def get_at(idc, t):
    # value of idc at time t = last event <= t
    best = None
    bv = None
    for (tt, idc2, v) in events:
        if idc2 == idc and tt <= t:
            best = tt
            bv = v
    return bv

def vstr(idc, t):
    v = get_at(idc, t)
    if v is None:
        return '?'
    if set(v) <= {'0','1'}:
        return v
    return v

# Print cycle-by-cycle for a window: sample at each posedge (times where clk rises)
# simpler: print state at each event involving state
names_by_time = {}
for (tt, idc, v) in events:
    if t0 <= tt <= t0 + 500:
        names_by_time.setdefault(tt, []).append((idc, v))

tlist = sorted(names_by_time.keys())
snap = {}
for tt in tlist:
    for (idc, v) in names_by_time[tt]:
        snap[idc] = v
    # print relevant
    st = b2i(snap.get(state_id, '0')) if state_id in snap else -1
    line = [f"t={tt}"]
    for idc, name in sorted(targets.items(), key=lambda kv: kv[1]):
        v = snap.get(idc)
        if v is None:
            continue
        if name == 'state':
            line.append(f"{name}={state_names.get(st,'?')}")
        else:
            line.append(f"{name}={v}")
    if st in (0,1,2,3,4,5,6,7,8,9,10,11,12,13):
        print(' '.join(line))
