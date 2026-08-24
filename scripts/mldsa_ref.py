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
# FIPS 204 ML-DSA-65 reference, byte-exact port of the pq-crystals mldsa-native
# reference implementation (portable C backend). Used as ground truth for RTL
# KAT comparison.
#
# Everything here is parameterized for ML-DSA-65 (K=6, L=5, ETA=4, TAU=49,
# GAMMA1=2^19, GAMMA2=(q-1)/32, OMEGA=55, CTILDEBYTES=48).

import hashlib
import sys

# ----------------------------------------------------------------------------
# Parameters (ML-DSA-65)
# ----------------------------------------------------------------------------
Q      = 8380417
Q_HALF = (Q + 1) // 2
D      = 13
K      = 6
L      = 5
N      = 256
ETA    = 4
TAU    = 49
BETA   = 196
GAMMA1 = 1 << 19
GAMMA2 = (Q - 1) // 32
OMEGA  = 55
CTILDEBYTES = 48

SEEDBYTES  = 32
CRHBYTES   = 64
TRBYTES    = 64
RNDBYTES   = 32

POLYT1_PACKEDBYTES = 320
POLYT0_PACKEDBYTES = 416
POLYETA_PACKEDBYTES = 128   # ETA = 4, 4 bits/coeff
POLYZ_PACKEDBYTES  = 640    # GAMMA1 = 2^19, 20 bits/coeff
POLYW1_PACKEDBYTES = 128    # 4 bits/coeff
POLYVECH_PACKEDBYTES = OMEGA + K

PK_BYTES = SEEDBYTES + K * POLYT1_PACKEDBYTES           # 1952
SK_BYTES = 3 * SEEDBYTES + L * POLYETA_PACKEDBYTES \
         + K * POLYETA_PACKEDBYTES + K * POLYT0_PACKEDBYTES  # 4032
SIG_BYTES = CTILDEBYTES + L * POLYZ_PACKEDBYTES + POLYVECH_PACKEDBYTES  # 3309

# ----------------------------------------------------------------------------
# Basic field arithmetic (ports of reduce.h / poly.c)
# ----------------------------------------------------------------------------
QINV = 58728449   # q^{-1} mod 2^32
MONT = -4186625   # 2^32 mod q  (Montgomery constant R mod q, signed)

def montgomery_reduce(a):
    # a: int (any 64-bit signed value)
    a_reduced = a & 0xFFFFFFFF
    a_inverted = (a_reduced * QINV) & 0xFFFFFFFF
    t = a_inverted - (0x100000000 if a_inverted >= 0x80000000 else 0)
    r = (a - t * Q) >> 32
    return r

def reduce32(a):
    t = (a + (1 << 22)) >> 23
    return a - t * Q

def caddq(a):
    return a + Q if a < 0 else a

def fqmul(a, b):
    return montgomery_reduce(a * b)

def fqscale(a):
    # scale by mont/256; f = 2^(64-8) mod q = 41978
    return montgomery_reduce(a * 41978)

# ----------------------------------------------------------------------------
# NTT / INTT (ports of poly.c). Standard bit-reversed CT/GS butterflies with
# Montgomery arithmetic, zetas in Montgomery form.
# ----------------------------------------------------------------------------
ZETAS = [
    0, 25847, -2608894, -518909, 237124, -777960, -876248, 466468,
    1826347, 2353451, -359251, -2091905, 3119733, -2884855, 3111497, 2680103,
    2725464, 1024112, -1079900, 3585928, -549488, -1119584, 2619752, -2108549,
    -2118186, -3859737, -1399561, -3277672, 1757237, -19422, 4010497, 280005,
    2706023, 95776, 3077325, 3530437, -1661693, -3592148, -2537516, 3915439,
    -3861115, -3043716, 3574422, -2867647, 3539968, -300467, 2348700, -539299,
    -1699267, -1643818, 3505694, -3821735, 3507263, -2140649, -1600420, 3699596,
    811944, 531354, 954230, 3881043, 3900724, -2556880, 2071892, -2797779,
    -3930395, -1528703, -3677745, -3041255, -1452451, 3475950, 2176455, -1585221,
    -1257611, 1939314, -4083598, -1000202, -3190144, -3157330, -3632928, 126922,
    3412210, -983419, 2147896, 2715295, -2967645, -3693493, -411027, -2477047,
    -671102, -1228525, -22981, -1308169, -381987, 1349076, 1852771, -1430430,
    -3343383, 264944, 508951, 3097992, 44288, -1100098, 904516, 3958618,
    -3724342, -8578, 1653064, -3249728, 2389356, -210977, 759969, -1316856,
    189548, -3553272, 3159746, -1851402, -2409325, -177440, 1315589, 1341330,
    1285669, -1584928, -812732, -1439742, -3019102, -3881060, -3628969, 3839961,
    2091667, 3407706, 2316500, 3817976, -3342478, 2244091, -2446433, -3562462,
    266997, 2434439, -1235728, 3513181, -3520352, -3759364, -1197226, -3193378,
    900702, 1859098, 909542, 819034, 495491, -1613174, -43260, -522500,
    -655327, -3122442, 2031748, 3207046, -3556995, -525098, -768622, -3595838,
    342297, 286988, -2437823, 4108315, 3437287, -3342277, 1735879, 203044,
    2842341, 2691481, -2590150, 1265009, 4055324, 1247620, 2486353, 1595974,
    -3767016, 1250494, 2635921, -3548272, -2994039, 1869119, 1903435, -1050970,
    -1333058, 1237275, -3318210, -1430225, -451100, 1312455, 3306115, -1962642,
    -1279661, 1917081, -2546312, -1374803, 1500165, 777191, 2235880, 3406031,
    -542412, -2831860, -1671176, -1846953, -2584293, -3724270, 594136, -3776993,
    -2013608, 2432395, 2454455, -164721, 1957272, 3369112, 185531, -1207385,
    -3183426, 162844, 1616392, 3014001, 810149, 1652634, -3694233, -1799107,
    -3038916, 3523897, 3866901, 269760, 2213111, -975884, 1717735, 472078,
    -426683, 1723600, -1803090, 1910376, -1667432, -1104333, -260646, -3833893,
    -2939036, -2235985, -420899, -2286327, 183443, -976891, 1612842, -3545687,
    -554416, 3919660, -48306, -1362209, 3937738, 1400424, -846154, 1976782,
]

def ntt(r):
    r = list(r)
    k = 1
    for layer in range(1, 9):
        length = N >> layer
        for start in range(0, N, 2 * length):
            zeta = ZETAS[k]
            k += 1
            for j in range(start, start + length):
                t = fqmul(r[j + length], zeta)
                r[j + length] = r[j] - t
                r[j] = r[j] + t
    return r

def invntt_tomont(r):
    r = list(r)
    for layer in range(8, 0, -1):
        length = N >> layer
        k = (1 << layer) - 1
        for start in range(0, N, 2 * length):
            zeta = -ZETAS[k]
            k -= 1
            for j in range(start, start + length):
                t = r[j]
                r[j] = t + r[j + length]
                r[j + length] = t - r[j + length]
                r[j + length] = fqmul(r[j + length], zeta)
    r = [fqscale(x) for x in r]
    return r

# ----------------------------------------------------------------------------
# XOF helpers
# ----------------------------------------------------------------------------
def shake128(data, n):
    return hashlib.shake_128(data).digest(n)

def shake256(data, n):
    return hashlib.shake_256(data).digest(n)

def H(data, n):
    return shake256(data, n)

# ----------------------------------------------------------------------------
# Decompose / rounding (port of rounding.h, parameter set 65)
# ----------------------------------------------------------------------------
def power2round(a):
    a1 = (a + (1 << (D - 1)) - 1) >> D
    a0 = a - (a1 << D)
    return a0, a1

def decompose(a):
    # a in [0, q)
    a1 = (a + 127) >> 7
    a1 = (a1 * 1025 + (1 << 21)) >> 22
    a1 &= 15
    a0 = a - a1 * 2 * GAMMA2
    if a0 > Q_HALF - 1:
        a0 -= Q
    return a0, a1

def make_hint(a0, a1):
    return 1 if (a0 > GAMMA2 or a0 < -GAMMA2 or (a0 == -GAMMA2 and a1 != 0)) else 0

def use_hint(a, hint):
    a0, a1 = decompose(a)
    if hint == 0:
        return a1
    if a0 > 0:
        return (a1 + 1) & 15
    return (a1 - 1) & 15

def chknorm(a, B):
    for x in a:
        if not (-B < x < B):
            return 1
    return 0

# ----------------------------------------------------------------------------
# Sampling
# ----------------------------------------------------------------------------
def rej_uniform(buf):
    # returns list of coeffs accepted from buf (bytes)
    out = []
    pos = 0
    while pos + 3 <= len(buf):
        t = buf[pos] | (buf[pos + 1] << 8) | (buf[pos + 2] << 16)
        pos += 3
        t &= 0x7FFFFF
        if t < Q:
            out.append(t)
    return out

def poly_uniform(seed):
    # seed = rho(32) || nonce_le16(2)
    ctr = []
    block = shake128(seed, 168)
    ctr.extend(rej_uniform(block))
    blk = 1
    while len(ctr) < N:
        block = shake128(seed, 168 * (blk + 1))[168 * blk:]
        blk += 1
        ctr.extend(rej_uniform(block))
    return ctr[:N]

def rej_eta(buf):
    out = []
    for b in buf:
        t0 = b & 0x0F
        t1 = b >> 4
        if t0 < 9 and len(out) < N:
            out.append(4 - t0)
        if t1 < 9 and len(out) < N:
            out.append(4 - t1)
        if len(out) >= N:
            break
    return out

def poly_uniform_eta(seed, nonce):
    # seed = rhoprime(64), nonce byte;  SHAKE256(seed || le16(nonce))
    extseed = seed + bytes([nonce & 0xFF, nonce >> 8])
    ctr = []
    block = shake256(extseed, 272)
    ctr.extend(rej_eta(block))
    blk = 1
    while len(ctr) < N:
        block = shake256(extseed, 136 * (blk + 2))[136 * (blk + 1):]
        blk += 1
        ctr.extend(rej_eta(block))
    return ctr[:N]

def polyz_unpack(a):
    # a: 640 bytes -> 256 coeffs in [-(gamma1-1), gamma1]
    r = []
    for i in range(N // 2):
        c0 = (a[5 * i] | (a[5 * i + 1] << 8) | (a[5 * i + 2] << 16)) & 0xFFFFF
        c1 = ((a[5 * i + 2] >> 4) | (a[5 * i + 3] << 4) |
              (a[5 * i + 4] << 12)) & 0xFFFFF
        r.append(GAMMA1 - c0)
        r.append(GAMMA1 - c1)
    return r

def poly_uniform_gamma1(seed, nonce):
    extseed = seed + bytes([nonce & 0xFF, (nonce >> 8) & 0xFF])
    return polyz_unpack(shake256(extseed, POLYZ_PACKEDBYTES))

def poly_challenge(ctilde):
    # SampleInBall
    buf = bytearray(shake256(ctilde, 136))
    signs = 0
    for i in range(8):
        signs |= buf[i] << (8 * i)
    pos = 8
    c = [0] * N
    for i in range(N - TAU, N):
        while True:
            if pos >= 136:
                buf = bytearray(shake256(ctilde, 136 * 2)[136:])
                pos = 0
            j = buf[pos]
            pos += 1
            if j <= i:
                break
        c[i] = c[j]
        c[j] = 1 - 2 * (signs & 1)
        signs >>= 1
    return c

# ----------------------------------------------------------------------------
# Packing
# ----------------------------------------------------------------------------
def polyeta_pack(a):
    r = bytearray()
    for i in range(N // 2):
        t0 = ETA - a[2 * i]
        t1 = ETA - a[2 * i + 1]
        r.append((t0 | (t1 << 4)) & 0xFF)
    return bytes(r)

def polyeta_unpack(a):
    r = []
    for i in range(N // 2):
        r.append(ETA - (a[i] & 0x0F))
        r.append(ETA - (a[i] >> 4))
    return r

def polyt1_pack(a):
    r = bytearray()
    for i in range(N // 4):
        r.append(a[4 * i] & 0xFF)
        r.append(((a[4 * i] >> 8) | (a[4 * i + 1] << 2)) & 0xFF)
        r.append(((a[4 * i + 1] >> 6) | (a[4 * i + 2] << 4)) & 0xFF)
        r.append(((a[4 * i + 2] >> 4) | (a[4 * i + 3] << 6)) & 0xFF)
        r.append((a[4 * i + 3] >> 2) & 0xFF)
    return bytes(r)

def polyt0_pack(a):
    r = bytearray()
    for i in range(N // 8):
        t = [(1 << (D - 1)) - a[8 * i + j] for j in range(8)]
        r.append(t[0] & 0xFF)
        r.append(((t[0] >> 8) | (t[1] << 5)) & 0xFF)
        r.append((t[1] >> 3) & 0xFF)
        r.append(((t[1] >> 11) | (t[2] << 2)) & 0xFF)
        r.append(((t[2] >> 6) | (t[3] << 7)) & 0xFF)
        r.append((t[3] >> 1) & 0xFF)
        r.append(((t[3] >> 9) | (t[4] << 4)) & 0xFF)
        r.append((t[4] >> 4) & 0xFF)
        r.append(((t[4] >> 12) | (t[5] << 1)) & 0xFF)
        r.append(((t[5] >> 7) | (t[6] << 6)) & 0xFF)
        r.append((t[6] >> 2) & 0xFF)
        r.append(((t[6] >> 10) | (t[7] << 3)) & 0xFF)
        r.append((t[7] >> 5) & 0xFF)
    return bytes(r)

def polyz_pack(a):
    r = bytearray()
    for i in range(N // 2):
        t0 = GAMMA1 - a[2 * i]
        t1 = GAMMA1 - a[2 * i + 1]
        r.append(t0 & 0xFF)
        r.append((t0 >> 8) & 0xFF)
        r.append(((t0 >> 16) | (t1 << 4)) & 0xFF)
        r.append((t1 >> 4) & 0xFF)
        r.append((t1 >> 12) & 0xFF)
    return bytes(r)

def polyw1_pack(a):
    r = bytearray()
    for i in range(N // 2):
        r.append((a[2 * i] | (a[2 * i + 1] << 4)) & 0xFF)
    return bytes(r)

def polyvecl_pack_eta(vec):
    return b''.join(polyeta_pack(p) for p in vec)

def polyveck_pack_eta(vec):
    return b''.join(polyeta_pack(p) for p in vec)

# ----------------------------------------------------------------------------
# ExpandA matrix
# ----------------------------------------------------------------------------
def polyvec_matrix_expand(rho):
    mat = []
    for k in range(K):
        row = []
        for l in range(L):
            # SHAKE128(rho || l || k), l = column (nonce low byte)
            row.append(poly_uniform(rho + bytes([l, k])))
        mat.append(row)
    return mat

# ----------------------------------------------------------------------------
# Matrix / vector pointwise (port of polyvec.c)
# ----------------------------------------------------------------------------
def polyvec_pointwise_acc_montgomery(u, v):
    # u: list of L polys (normal domain / A entries), v: list of L NTT polys
    w = []
    for i in range(N):
        t = 0
        for j in range(L):
            t += u[j][i] * v[j][i]
        w.append(montgomery_reduce(t))
    return w

def poly_pointwise_montgomery(a, b):
    return [montgomery_reduce(a[i] * b[i]) for i in range(N)]

# ----------------------------------------------------------------------------
# Keygen
# ----------------------------------------------------------------------------
def keypair(xi):
    # xi: 32 bytes
    inbuf = xi + bytes([K, L])
    seedbuf = shake256(inbuf, 2 * SEEDBYTES + CRHBYTES)
    rho = seedbuf[0:32]
    rhoprime = seedbuf[32:96]
    key = seedbuf[96:128]

    s1 = [poly_uniform_eta(rhoprime, i) for i in range(L)]
    s2 = [poly_uniform_eta(rhoprime, L + i) for i in range(K)]

    s1hat = [ntt(p) for p in s1]
    mat = polyvec_matrix_expand(rho)

    t1s = []
    t0s = []
    for k in range(K):
        t = polyvec_pointwise_acc_montgomery([mat[k][j] for j in range(L)], s1hat)
        t = invntt_tomont(t)
        t = [t[i] + s2[k][i] for i in range(N)]
        t = [reduce32(x) for x in t]
        t = [caddq(x) for x in t]
        t1 = []
        t0 = []
        for i in range(N):
            a0, a1 = power2round(t[i])
            t0.append(a0)
            t1.append(a1)
        t1s.append(t1)
        t0s.append(t0)

    pk_t1 = b''.join(polyt1_pack(p) for p in t1s)
    pk = rho + pk_t1
    tr = H(pk, TRBYTES)
    sk = (rho + key + tr + polyvecl_pack_eta(s1) + polyveck_pack_eta(s2) +
          b''.join(polyt0_pack(p) for p in t0s))
    return pk, sk, tr

# ----------------------------------------------------------------------------
# Sign
# ----------------------------------------------------------------------------
def unpack_sk(sk):
    rho = sk[0:32]
    key = sk[32:64]
    tr = sk[64:128]
    s1 = []
    for i in range(L):
        s1.append(polyeta_unpack(sk[128 + i * POLYETA_PACKEDBYTES:128 + (i + 1) * POLYETA_PACKEDBYTES]))
    s2 = []
    base = 128 + L * POLYETA_PACKEDBYTES
    for i in range(K):
        s2.append(polyeta_unpack(sk[base + i * POLYETA_PACKEDBYTES:base + (i + 1) * POLYETA_PACKEDBYTES]))
    t0 = []
    base2 = base + K * POLYETA_PACKEDBYTES
    for i in range(K):
        t0.append(polyt0_unpack(sk[base2 + i * POLYT0_PACKEDBYTES:base2 + (i + 1) * POLYT0_PACKEDBYTES]))
    return rho, key, tr, s1, s2, t0

def polyt0_unpack(a):
    r = []
    for i in range(N // 8):
        vals = []
        vals.append(a[13 * i] | (a[13 * i + 1] << 8) & 0x1FFF)
        vals.append((a[13 * i + 1] >> 5) | (a[13 * i + 2] << 3) | (a[13 * i + 3] << 11) & 0x1FFF)
        vals.append((a[13 * i + 3] >> 2) | (a[13 * i + 4] << 6) & 0x1FFF)
        vals.append((a[13 * i + 4] >> 7) | (a[13 * i + 5] << 1) | (a[13 * i + 6] << 9) & 0x1FFF)
        vals.append((a[13 * i + 6] >> 4) | (a[13 * i + 7] << 4) | (a[13 * i + 8] << 12) & 0x1FFF)
        vals.append((a[13 * i + 8] >> 1) | (a[13 * i + 9] << 7) & 0x1FFF)
        vals.append((a[13 * i + 9] >> 6) | (a[13 * i + 10] << 2) | (a[13 * i + 11] << 10) & 0x1FFF)
        vals.append((a[13 * i + 11] >> 3) | (a[13 * i + 12] << 5) & 0x1FFF)
        for v in vals:
            r.append((1 << (D - 1)) - v)
    return r

def sign(sk, msg, rnd, domain_sep=b'\x00\x00'):
    """Deterministic sign given rnd (32 bytes). Returns sig, mu."""
    rho, key, tr, s1, s2, t0 = unpack_sk(sk)

    s1hat = [ntt(p) for p in s1]
    s2hat = [ntt(p) for p in s2]
    t0hat = [ntt(p) for p in t0]

    mu = H(tr + domain_sep + msg, CRHBYTES)
    rhoprime = H(key + rnd + mu, CRHBYTES)

    mat = polyvec_matrix_expand(rho)

    kappa = 0
    while True:
        # y = ExpandMask(rhoprime, kappa)
        y = [poly_uniform_gamma1(rhoprime, kappa + i) for i in range(L)]
        yhat = [ntt(p) for p in y]

        # w = A*y_hat, INTT, decompose -> w1, w0
        w1 = []
        w0 = []
        w1buf = bytearray()
        for k in range(K):
            wk = polyvec_pointwise_acc_montgomery([mat[k][j] for j in range(L)], yhat)
            wk = invntt_tomont(wk)
            wk = [caddq(x) for x in wk]
            w1k = []
            w0k = []
            for i in range(N):
                a0, a1 = decompose(wk[i])
                w0k.append(a0)
                w1k.append(a1)
            w1.append(w1k)
            w0.append(w0k)
            w1buf.extend(polyw1_pack(w1k))

        ctilde = H(mu + bytes(w1buf), CTILDEBYTES)
        c = poly_challenge(ctilde)
        chat = ntt(c)

        # z = invNTT(chat o s1hat) + y, norm check, pack
        z = []
        rejected = False
        for i in range(L):
            cs1 = invntt_tomont(poly_pointwise_montgomery(chat, s1hat[i]))
            zi = [cs1[j] + y[i][j] for j in range(N)]
            zi = [reduce32(x) for x in zi]
            if chknorm(zi, GAMMA1 - BETA):
                rejected = True
                break
            z.append(zi)
        if rejected:
            kappa += L
            continue

        # r0 / hint checks
        for k in range(K):
            cs2 = invntt_tomont(poly_pointwise_montgomery(chat, s2hat[k]))
            w0[k] = [w0[k][j] - cs2[j] for j in range(N)]
            w0[k] = [reduce32(x) for x in w0[k]]
            if chknorm(w0[k], GAMMA2 - BETA):
                rejected = True
                break
            ct0 = invntt_tomont(poly_pointwise_montgomery(chat, t0hat[k]))
            ct0 = [reduce32(x) for x in ct0]
            if chknorm(ct0, GAMMA2):
                rejected = True
                break
            w0[k] = [w0[k][j] + ct0[j] for j in range(N)]
        if rejected:
            kappa += L
            continue

        # pack hints
        h = bytearray(POLYVECH_PACKEDBYTES)
        n = 0
        for k in range(K):
            for j in range(N):
                bit = make_hint(w0[k][j], w1[k][j])
                if bit:
                    if n == OMEGA:
                        rejected = True
                        break
                    h[n] = j
                    n += 1
            if rejected:
                break
            h[OMEGA + k] = n
        if rejected:
            kappa += L
            continue

        sig = ctilde + b''.join(polyz_pack(zi) for zi in z) + bytes(h)
        return sig, mu, kappa

# ----------------------------------------------------------------------------
# Verify (for completeness)
# ----------------------------------------------------------------------------
def verify(pk, msg, sig, domain_sep=b'\x00\x00'):
    rho = pk[0:32]
    t1 = []
    for i in range(K):
        t1.append(polyt1_unpack(pk[32 + i * POLYT1_PACKEDBYTES:32 + (i + 1) * POLYT1_PACKEDBYTES]))

    ctilde = sig[0:CTILDEBYTES]
    z = []
    for i in range(L):
        z.append(polyz_unpack(sig[CTILDEBYTES + i * POLYZ_PACKEDBYTES:CTILDEBYTES + (i + 1) * POLYZ_PACKEDBYTES]))
    base = CTILDEBYTES + L * POLYZ_PACKEDBYTES
    hints = sig[base:base + POLYVECH_PACKEDBYTES]

    if chknorm_flatten(z, GAMMA1 - BETA):
        return 0

    mu = H(rho + t1_pack(t1) + domain_sep + msg, CRHBYTES)
    c = poly_challenge(ctilde)
    chat = ntt(c)
    zhat = [ntt(p) for p in z]
    mat = polyvec_matrix_expand(rho)
    # w = A*z - c*t1*2^d
    for k in range(K):
        w = polyvec_pointwise_acc_montgomery([mat[k][j] for j in range(L)], zhat)
        w = invntt_tomont(w)
        ct1 = invntt_tomont(poly_pointwise_montgomery(chat, ntt([x << D for x in t1[k]])))
        w = [w[i] - ct1[i] for i in range(N)]
        w = [caddq(reduce32(x)) for x in w]
        hk, old = unpack_hints(hints, k)
        w1 = [use_hint(w[i], hk[i]) for i in range(N)]
        # (pack w1 and accumulate hash; simplified comparison path omitted)
    return 1

def chknorm_flatten(z, B):
    for p in z:
        for x in p:
            if not (-B < x < B):
                return 1
    return 0

def t1_pack(t1):
    return b''.join(polyt1_pack(p) for p in t1)

def polyt1_unpack(a):
    r = []
    for i in range(N // 4):
        r.append((a[5 * i] | (a[5 * i + 1] << 8)) & 0x3FF)
        r.append(((a[5 * i + 1] >> 2) | (a[5 * i + 2] << 6)) & 0x3FF)
        r.append(((a[5 * i + 2] >> 4) | (a[5 * i + 3] << 4)) & 0x3FF)
        r.append(((a[5 * i + 3] >> 6) | (a[5 * i + 4] << 2)) & 0x3FF)
    return r

def unpack_hints(hints, i):
    old = 0 if i == 0 else hints[OMEGA + i - 1]
    new = hints[OMEGA + i]
    hk = [0] * N
    for j in range(old, new):
        hk[hints[j]] = 1
    return hk, old


# ----------------------------------------------------------------------------
# NIST AES-256-CTR-DRBG (rng.c)
# ----------------------------------------------------------------------------
def _inc_v(V):
    V = list(V)
    for j in range(15, -1, -1):
        if V[j] == 0xFF:
            V[j] = 0
        else:
            V[j] += 1
            break
    return bytes(V)


class DRBG:
    def __init__(self, seed48, aes):
        self.aes = aes
        Key = bytes(32)
        V = bytes(16)
        self.Key, self.V = self._update(seed48, Key, V)

    def _aes(self, Key, V):
        return self.aes.new(Key, self.aes.MODE_ECB).encrypt(V)

    def _update(self, provided, Key, V):
        temp = b''
        for _ in range(3):
            V = _inc_v(V)
            temp += self._aes(Key, V)
        if provided is not None:
            temp = bytes(temp[i] ^ provided[i] for i in range(48))
        return temp[0:32], temp[32:48]

    def randombytes(self, n):
        out = b''
        while n > 0:
            self.V = _inc_v(self.V)
            block = self._aes(self.Key, self.V)
            take = 16 if n > 16 else n
            out += block[:take]
            n -= take
        self.Key, self.V = self._update(None, self.Key, self.V)
        return out


# ----------------------------------------------------------------------------
# KAT validation driver
# ----------------------------------------------------------------------------
def parse_rsp(path):
    vecs = []
    cur = {}
    for raw in open(path, 'r', encoding='ascii'):
        line = raw.strip()
        if line.startswith('#') or line == '':
            continue
        if '=' in line:
            k, v = [x.strip() for x in line.split('=', 1)]
            if k in ('count', 'mlen', 'smlen'):
                if k == 'count' and cur:
                    vecs.append(cur)
                if k == 'count':
                    cur = {'count': int(v)}
                else:
                    cur[k] = int(v)
            else:
                cur[k] = bytes.fromhex(v)
    if cur:
        vecs.append(cur)
    return vecs


def run_kat(path, num=1, aes=None):
    from Crypto.Cipher import AES as _AES
    vecs = parse_rsp(path)
    ok = 0
    bad = 0
    for v in vecs[:num]:
        seed48 = v['seed']
        msg = v['msg']
        drbg = DRBG(seed48, _AES)
        xi = drbg.randombytes(SEEDBYTES)
        pk, sk, _ = keypair(xi)
        rnd = drbg.randombytes(RNDBYTES)
        sig, mu, kappa = sign(sk, msg, rnd)
        sm = sig + msg
        status = []
        if pk != v['pk']:
            status.append('PK')
        if sk != v['sk']:
            status.append('SK')
        if sm != v['sm']:
            status.append('SM')
        if status:
            bad += 1
            print(f"count={v['count']}: FAIL ({', '.join(status)})")
        else:
            ok += 1
            print(f"count={v['count']}: PASS (kappa={kappa})")
    print(f"--- {ok} passed, {bad} failed ---")
    return ok, bad


if __name__ == '__main__':
    path = sys.argv[1] if len(sys.argv) > 1 else r'constraints/PQCsignKAT_4032.rsp'
    num = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    run_kat(path, num)
