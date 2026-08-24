# MLDSA-65 Hardware Implementation

RTL implementation of an ML-DSA-65 (FIPS 204) lattice-based digital-signature
core with an AXI4-Lite slave interface, plus a Python reference model and
Known-Answer-Test (KAT) simulation flow for Vivado 2023.2.

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

| Subsystem   | Status                          | Evidence |
|-------------|---------------------------------|----------|
| KeyGen      | **PASS 5/5 KAT vectors**        | `scripts/vivado_keygen.tcl` on `sim/tb/tb_keygen_kat.v` |
| NTT core    | Verified (10,752 cycles / NTT)  | correct latency + keygen byte-exact |
| Sign        | **PASS 5/5 KAT vectors**        | `scripts/vivado_sim.tcl` on `sim/tb/tb_mldsa_sign_kat.v`, `scripts/compare_sigs.py` |
| Verify      | **PASS 5/5 KAT vectors**        | `scripts/vivado_verify.tcl` on `sim/tb/tb_mldsa_verify_kat.v` |
| **NIST end-to-end** | **PASS 20/20 vectors**    | `joint_design/vivado_nist20.tcl` on `joint_design/tb_mldsa_nist_kat.v` (official NIST KAT vectors, pre-generated in `sim/tb/nist/`); KeyGen + Sign + Verify all byte-compared against NIST `ref_*` including the signature |

### Notes / known issues
- The sign run must be simulated in **Vivado/xsim only** (see flow below).
  xsim crashes if a testbench prints a `$display` every cycle at high rate
  (`child killed: unknown signal`); keep debug samplers silent.
- xsim also crashes on very long single-session runs (the NIST 100-vector KAT
  must be chunked into slices; `joint_design/vivado_nist20.tcl` runs 2x10).
- Sign is slow in simulation (>500 ms simulated time). The testbench watchdog
  is set to `#(1_500_000_000)` ns (1.5 s) to accommodate it.

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
sim/tb/         testbenches, KAT vectors (.vh), reference key bytes (.mem)
scripts/        Vivado tcl drivers, Python reference model + compare tools
  expected/     reference signature hex files (sig_<i>.hex)
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

## Simulation flow (Vivado 2023.2, non-project)

All runs must be executed from the project root. Launch Vivado in batch mode,
unattended:

```powershell
Start-Process -FilePath "D:\vivado\2023.2\bin\vivado.bat" `
  -ArgumentList "-mode batch -source <script>.tcl -nolog -nojournal" `
  -WorkingDirectory "C:\path\to\MLDSA" -WindowStyle Hidden
```

Poll `xsim.log` in the project root for results.

### 1. KeyGen KAT (PASSING)
```tcl
source scripts/vivado_keygen.tcl
```
Runs `sim/tb/tb_keygen_kat.v`, all 5 vectors, prints `All KAT vectors PASSED!`.

### 2. Sign KAT (current work)
```tcl
source scripts/vivado_sim.tcl
```
Runs `sim/tb/tb_mldsa_sign_kat.v`. For each of the 5 vectors it:
1. Loads the standard reference keys (`sim/tb/ref_pk_<i>.mem` / `sim/tb/ref_sk_<i>.mem`,
   generated by `scripts/gen_sign_keys.py` from `scripts/mldsa_ref.py`) into
   `pk_ram` / `sk_ram` via AXI byte writes — no internal keygen.
2. Forwards `rho`/`K` to registers and loads `rnd`/`mu` from
   `sim/tb/mldsa65_sign_vectors.vh`.
3. Starts sign (`CTRL[1]`), waits for `sig_valid`, dumps `sig_ram` to
   `sig_<i>.hex` (828 32-bit words).

Compare DUT signatures against the reference:
```powershell
python scripts\compare_sigs.py 5
```
(`sig_<i>.hex` in the project root are compared against
`scripts/expected/sig_<i>.hex`; bytes are trimmed to the 3309-byte signature.)

### 3. Verify KAT (PASSING)
```tcl
source scripts/vivado_verify.tcl
```
Runs `sim/tb/tb_mldsa_verify_kat.v`. For each of the 5 vectors it loads the
reference pk/rho/mu (`sim/tb/ref_vf_*_<i>.mem`) and signature
(`sim/tb/ref_vf_sig_<i>.mem`, generated by `scripts/gen_verify_vectors.py`) via AXI,
starts verify (`CTRL[2]`), and checks that a valid signature is accepted
(`valid=1`) and tampered ones are rejected (`valid=0`) at two z-byte positions
(byte 100, and byte 700 which is in poly 1 and exercises the full-coverage
z-norm bound check). Prints `All Verify KAT vectors PASSED!` when all 15 checks
pass.

### 4. NTT check
```tcl
source scripts/vivado_ntt_check.tcl
```

## Reference model / vector generation

- `scripts/mldsa_ref.py` — pure-Python ML-DSA-65 (`keypair`, `sign`); reproduces
  the official NIST KAT vectors (seeded from the AES-CTR-DRBG), and serves as
  the ground truth for the local KAT sets (xi = `bytes(range(0x20*i, 0x20*i+0x20))`).
- `scripts/gen_sign_keys.py` — emits `sim/tb/ref_pk_<i>.mem` / `sim/tb/ref_sk_<i>.mem`
  (one hex byte per line) from the reference keypair.
- `scripts/gen_sign_vectors.py` — emits KAT rnd/mu vectors and
  `scripts/expected/sig_<i>.hex` ground truth.
- `scripts/compare_sigs.py` — compares dumped vs. expected signatures.

## Tool notes

- Vivado 2023.2 path: `D:\vivado\2023.2\bin\vivado.bat`.
- Do not run more than one batch Vivado at a time in this folder: concurrent
  instances fight over `./xsim`, `xsim.log` and `xsim_files.txt`.
- The batch flow regenerates `./xsim`, `xsim.log`, `xelab.*`, `xvlog.*` at the
  project root on every run; these are disposable build artifacts.
- iverilog is not used for verification of this design.
