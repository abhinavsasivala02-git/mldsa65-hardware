# MLDSA-65 Hardware Implementation

RTL implementation of an ML-DSA-65 (FIPS 204) lattice-based digital-signature
core with an AXI4-Lite slave interface, plus its Known-Answer-Test (KAT)
testbenches and NIST test vectors, simulated with Vivado 2023.2/xsim.

## How ML-DSA works

ML-DSA (FIPS 204, based on CRYSTALS-Dilithium) is NIST's post-quantum
digital-signature scheme. Its security rests on the hardness of finding short
vectors in module lattices (Module-LWE / Module-SIS) — a problem believed hard
even for quantum computers. The **ML-DSA-65** parameter set (K=6, L=5) operates
on polynomials of degree 255 over the ring
`R_q = Z_q[x]/(x^256 + 1)` with `q = 8380417` (23-bit coefficients). The scheme
has three phases:

**1. Key generation.** A seed `xi` is expanded by SHAKE-256 into `rho`
(public seed), `rho'` (secret seed) and `K` (signing key). The matrix `A` is
derived deterministically from `rho` via SHAKE-128. Two short secret vectors
`s1` (L polys) and `s2` (K polys) are sampled from `rho'`. The public vector is
`t = A·s1 + s2`, then split into high bits `t1` (public) and low bits `t0`
(secret). The public key is `pk = (rho, t1)`; the secret key is
`sk = (rho, K, tr, s1, s2, t0)` with `tr = H(pk)` (64 bytes).

**2. Signing (rejection-sampling loop).** The message is hashed to
`mu = H(tr || 0x00 || M)`, and `rhoprime = H(K || rnd || mu)` where `rnd` is a
32-byte randomizer. The core loop tries increasing nonces `kappa`:
`y = ExpandMask(rhoprime, kappa)` is a short masking vector; `w = A·y`;
each `w` coefficient is decomposed into high/low parts `(w1, w0)`; the challenge
`c~ = H(mu || w1)` (48 bytes) is hashed into a sparse polynomial `c`
(exactly 49 `±1` terms); then `z = y + c·s1`, `r0 = w0 − c·s2`, `ct0 = c·t0`.
The candidate is **accepted** only if all norms stay in bounds
(`||z||∞ < γ1−β`, `||r0||∞ < γ2−β`, `||ct0||∞ < γ2`) and the hint fits
(`ω` entries max); then `h = makeHint(...)` and the signature is
`sig = (c~, z, h)`. Any failing check retries with the next `kappa`. This loop
is why signing is variable-latency (the `kappa` count).

**3. Verification.** Recompute `mu`, derive `A`, and recompute
`w1' = useHint(A·z − c·t1·2^d, h)`; reject if `||z||∞ ≥ γ1−β` or the hint
count is invalid; accept iff `H(mu || w1') == c~`.

Under the hood the arithmetic uses a number-theoretic transform (NTT) in the
`Z_q` Montgomery domain for fast polynomial multiplication, and SHAKE-128/256
(Keccak-f[1600]) plus rejection sampling for all randomness and hashing. The
hardware instantiates dedicated NTT, decomposition (`decompose`/`power2round`/
`make_hint`/`use_hint`), sampling, and Keccak blocks, orchestrated by the
`keygen_ctrl` / `sign_ctrl` / `verify_ctrl` FSM controllers.

## Status

All blocks were verified against the official NIST KAT vectors (byte-exact):

| Subsystem   | Status |
|-------------|--------|
| KeyGen      | PASS — byte-exact pk/sk vs NIST |
| Sign        | PASS — byte-exact signature + rejection `kappa` vs NIST |
| Verify      | PASS — accepts valid, rejects tampered signatures |
| NIST end-to-end | PASS 20/20 (KeyGen + Sign + Verify, incl. signature comparison) |

The NIST vectors are pre-generated in `sim/mem/nist/<i>/` and loaded by
`joint_design/tb_mldsa_nist_kat.v` via `$readmemh`; no automation scripts are
required (the Python reference model and Vivado driver scripts were removed).

## Directory layout

```
rtl/            RTL sources
  pkg/          parameters (mldsa_params.vh), zeta ROM
  math/         mod_add, montgomery_mult, butterfly_unit, ntt_core, poly_arith
  decompose/    power2round, decompose, make_hint, use_hint
  keccak/       keccak_f1600, shake128/256, shake_unified
  sample/       rej_uniform, rej_bounded, sample_in_ball
  mem/          poly_ram, poly_ram_tdp
  mldsa/        mldsa_top (AXI4-Lite), keygen_ctrl, sign_ctrl, verify_ctrl
sim/            simulation sources
  tb/           testbenches (tb_keygen_kat, tb_mldsa_sign_kat, tb_mldsa_verify_kat, tb_ntt_check)
  mem/          KAT vectors (.vh), reference key bytes (.mem), NIST vectors (nist/)
joint_design/   end-to-end keygen->sign->verify testbenches (tb_mldsa_joint, tb_mldsa_nist_kat)
syn/            synthesis scripts (mldsa.tcl, syn_mldsa.tcl, constraints.sdc)
```

## AXI register / memory map (byte-addressed)

```
0x0000  CTRL     [0]=start_keygen [1]=start_sign [2]=start_verify
0x0004  STATUS   [0]=busy [1]=done [2]=sig_valid
0x0010-0x002C  seed_xi    (256-bit, 8 words)
0x0030-0x004C  rho        (256-bit, 8 words)   (pk_ram[0:31])
0x0050-0x006C  K          (256-bit, 8 words)   (sk_ram[32:63])
0x0070-0x008C  tr         (256-bit, 8 words)
0x0090-0x00AC  rnd        (256-bit, 8 words)
0x00B0-0x00CC  c_tilde    (256-bit, 8 words)
0x00D0-0x00EC  mu_lo      (mu[255:0])
0x00F0-0x010C  mu_hi      (mu[511:256])
0x0800-0x0FFF  pk_ram     (1952 bytes)
0x1000-0x1FFF  sk_ram     (4032 bytes: rho 32 | K 32 | tr 64 | s1 1280 | s2 1536 | t0 704)
0x2000-0x23FC  poly_z_ram
0x2400-0x27FC  poly_r0_ram
0x3000-0x34EC  sig_ram    (3309 bytes)
```

## Simulation notes

- Run the testbenches in **Vivado 2023.2** (xsim). The testbenches load the
  pre-generated reference data (`sim/mem/`) by relative path, so run xsim from
  the project root.
- `joint_design/tb_mldsa_nist_kat.v` runs the NIST end-to-end KAT (20/20
  verified); it is chunked into 10-vector slices to avoid the xsim long-run
  kernel crash. The sign run is slow and must be simulated in xsim only.
- The reference vectors in `sim/mem/` (signatures, keys, mu/rnd, and the NIST
  `sim/mem/nist/` packs) were generated from the official NIST KAT and are
  committed so the KATs run out-of-the-box.

## Tool notes

- Vivado 2023.2 path: `D:\vivado\2023.2\bin\vivado.bat`.
- Do not run more than one batch Vivado at a time in this folder: concurrent
  instances fight over `./xsim`, `xsim.log` and `xsim_files.txt`.
