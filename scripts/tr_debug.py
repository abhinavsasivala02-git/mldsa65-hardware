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
import re, hashlib

pk = open('ref_pk0.bin','rb').read()
ref = hashlib.shake_256(pk).digest(64)

# Parse RTL lane writes from xsim.log
lanes = {}
order = []
for line in open('xsim.log', errors='ignore'):
    m = re.search(r'TRABS lane=(\d+) data=([0-9a-fA-F]+) byte_cnt=(\d+)', line)
    if m:
        lane = int(m.group(1)); data = int(m.group(2), 16); bc = int(m.group(3))
        lanes[bc] = (lane, data)
        order.append((bc, lane, data))

# Build the 1952-byte message exactly as RTL absorbed it: lane = byte0 | byte1<<8 ...
# byte_cnt at lane write = index of byte7 of that lane. So lane covers bytes bc-7..bc.
# lane data byte0 (LSB) = pk[bc-7], ..., byte7 = pk[bc].
def lane_bytes(lane, data, bc):
    out = bytearray(8)
    for b in range(8):
        out[b] = (data >> (8*b)) & 0xff
    return out, bc-7

# Reconstruct full message stream in absorb order (block by block)
msg = bytearray()
prev = 0
for bc, lane, data in order:
    if bc == prev:   # first lane of a block
        pass
    msg += lane_bytes(lane, data, bc)[0]
    prev = bc + 1

msg = bytes(msg)
print("reconstructed msg len:", len(msg))
print("msg == pk?", msg == pk)

# Now sponge the reconstructed message with rate 136, standard padding
R = [[0,36,3,41,18],[1,44,10,45,2],[62,6,43,15,61],[28,55,25,21,56],[27,20,39,8,14]]
RC = [0x0000000000000001,0x0000000000008082,0x800000000000808a,0x8000000080008000,
      0x000000000000808b,0x0000000080000001,0x8000000080008081,0x8000000000008009,
      0x000000000000008a,0x0000000000000088,0x0000000080008009,0x000000008000000a,
      0x000000008000808b,0x800000000000008b,0x8000000000008089,0x8000000000008003,
      0x8000000000008002,0x8000000000000080,0x000000000000800a,0x800000008000000a,
      0x8000000080008081,0x8000000000008080,0x0000000080000001,0x8000000080008008]
MASK = (1<<64)-1
def rol(x,n): return ((x<<n)|(x>>(64-n)))&MASK
def keccak_f(A):
    for rnd in range(24):
        C=[A[x][0]^A[x][1]^A[x][2]^A[x][3]^A[x][4] for x in range(5)]
        D=[C[(x-1)%5]^rol(C[(x+1)%5],1) for x in range(5)]
        for x in range(5):
            for y in range(5): A[x][y]^=D[x]
        B=[[0]*5 for _ in range(5)]
        for x in range(5):
            for y in range(5): B[y][(2*x+3*y)%5]=rol(A[x][y],R[x][y])
        for x in range(5):
            for y in range(5): A[x][y]=B[x][y]^((~B[(x+1)%5][y])&B[(x+2)%5][y])
        A[0][0]^=RC[rnd]
    return A
def lanes_to_A(blk):
    A=[[0]*5 for _ in range(5)]
    for i in range(min(17,len(blk)//8)):
        x=i%5; y=i//5
        A[x][y]=int.from_bytes(blk[i*8:i*8+8],'little')
    return A
def lane_to_bytes(A):
    out=bytearray()
    for y in range(5):
        for x in range(5):
            out += A[x][y].to_bytes(8,'little')
    return bytes(out)

def shake(msg, rate, outlen):
    A=[[0]*5 for _ in range(5)]
    n=len(msg)
    full=n//rate; rem=n%rate
    idx=0
    for b in range(full):
        blk=msg[idx:idx+rate]; idx+=rate
        Bl=lanes_to_A(blk)
        for x in range(5):
            for y in range(5): A[x][y]^=Bl[x][y]
        A=keccak_f(A)
    partial=msg[idx:idx+rem]
    padded=bytearray(rate)
    padded[0:rem]=partial
    padded[rem]=0x1f
    padded[rate-1]=0x80
    Bl=lanes_to_A(bytes(padded))
    for x in range(5):
        for y in range(5): A[x][y]^=Bl[x][y]
    A=keccak_f(A)
    out=b''
    while len(out)<outlen:
        out+=lane_to_bytes(A)[:rate]
        A=keccak_f(A)
    return out[:outlen]

rate=136
out=shake(msg,rate,64)
print("sponge(msg):", out.hex()[:16])
print("ref        :", ref.hex()[:16])
print("rtl tr     :", "cc5e37d50c511095")

# Try pad variants to match rtl: pad_first written into a fresh 0 block? extra permute?
# Variant: permute occurs, then pad_first at lane6, then pad_second at lane16, then pad_and_permute (one more permute)
A=[[0]*5 for _ in range(5)]
n=len(msg); full=n//rate; rem=n%rate; idx=0
for b in range(full):
    blk=msg[idx:idx+rate]; idx+=rate
    Bl=lanes_to_A(blk)
    for x in range(5):
        for y in range(5): A[x][y]^=Bl[x][y]
    A=keccak_f(A)
partial=msg[idx:idx+rem]
# absorb partial block (48 bytes) WITHOUT permute, then write pad into same block
padded=bytearray(rate)
padded[0:rem]=partial
Bl=lanes_to_A(bytes(padded))
for x in range(5):
    for y in range(5): A[x][y]^=Bl[x][y]
# now write pad_first at lane6 byte0 and pad_second at lane16 byte7 into CURRENT state, then permute
def wr_lane(A, lane, data):
    x=lane%5; y=lane//5
    A[x][y]^=data
    return A
A=wr_lane(A,6,0x1f)
A=wr_lane(A,16,0x80<<56)
A=keccak_f(A)
out=b''
while len(out)<64:
    out+=lane_to_bytes(A)[:rate]
    A=keccak_f(A)
print("rtl-style pad:", out.hex()[:16], " matches rtl?", out[:16].hex()=="cc5e37d50c511095")
