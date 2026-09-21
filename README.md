<div align="center">

# ML-DSA-65 &nbsp;·&nbsp; Hardware Implementation

**Post-quantum digital signatures in Verilog — NIST FIPS 204, verified byte-exact against the official KAT vectors.**

[![Standard](https://img.shields.io/badge/standard-FIPS%20204-1f6feb)](https://csrc.nist.gov/pubs/fips/204/final)
[![Parameter set](https://img.shields.io/badge/parameter%20set-ML--DSA--65-8957e5)](#parameters)
[![KAT](https://img.shields.io/badge/NIST%20KAT-20%2F20%20byte--exact-2ea043)](#verification)
[![Target](https://img.shields.io/badge/XC7Z020-40%20MHz%20met-2ea043)](#results-on-hardware)
[![HDL](https://img.shields.io/badge/HDL-Verilog--2001-555)](#source-layout)
[![License](https://img.shields.io/badge/license-GPLv3-orange)](LICENSE)

Keygen · Sign · Verify in one core, sharing a single Keccak-f[1600] and a single NTT.

</div>

---

## What this is

A synthesisable Verilog-2001 implementation of **ML-DSA-65** — the lattice signature
scheme standardised as [FIPS 204](https://csrc.nist.gov/pubs/fips/204/final).

All three operations live in one core:

```
          seed ξ ─────────────▶ ┌───────────┐ ──▶ pk (1952 B)
                                │  KeyGen   │ ──▶ sk (4032 B)
                                └───────────┘
   sk, μ, rnd ──────────────▶   ┌───────────┐
                                │   Sign    │ ──▶ σ  (3309 B)
                                └───────────┘
   pk, σ, μ  ──────────────▶    ┌───────────┐
                                │  Verify   │ ──▶ valid
                                └───────────┘

   shared:  Keccak-f[1600] (SHAKE-128 + SHAKE-256)   ·   NTT / INTT core
```

Everything reaches the host through one flat memory-mapped register/RAM interface —
no bus IP required, drop it behind an AXI4-Lite bridge in a block design.

Sampling (RejNTTPoly, RejBoundedPoly, SampleInBall) and MakeHint are FSM states inside
the controllers rather than separate modules, so there are no standalone sampler blocks.

---

## Verification

Results recorded on Vivado 2023.2 / xsim against the RTL in this repository.

| Subsystem | Result |
|---|---|
| **KeyGen** | 5/5 KAT vectors — pk and sk byte-exact |
| **Sign** | 5/5 KAT vectors — signatures byte-exact |
| **Verify** | **30/30 checks** — 5 valid accepted, 25 malformed rejected |
| **Joint** KeyGen→Sign→Verify | 5/5, no external reference data |
| **NIST end-to-end** | **20/20 vectors** — pk, sk and σ byte-exact vs. `PQCsignKAT_4032.rsp` |

The verify suite covers both directions — accepting what is valid, and rejecting what is not:

| Verify check | × vectors | Result |
|---|---|---|
| Valid signature accepted | 5 | pass |
| Tampered `z` byte rejected | 5 | pass |
| Hint count > ω rejected | 5 | pass |
| Hint counts non-monotone rejected | 5 | pass |
| Hint padding non-zero rejected | 5 | pass |
| Hint positions not increasing rejected | 5 | pass |

The last four are the ⊥ conditions of **Algorithm 15 (HintBitUnpack)**, reached through
Algorithm 21 `sigDecode`. Well-formed KAT vectors never exercise them, so `verify_ctrl`'s
`VF_HINT_CHK` state is tested explicitly with deliberately malformed hint sections.

### The vectors are the real thing

`constraints/PQCsignKAT_4032.rsp` is NIST's own response file. Despite its `Dilithium3`
header it is genuine FIPS 204 data — `μ` is built as `H(tr ‖ 0x00 ‖ 0x00 ‖ M, 64)`, the
ctx-prefixed form of the final standard, not the round-3 `H(tr ‖ M)`.

`tb/nist/<i>/` holds the unpacked per-vector inputs and expected outputs (`xi`, `pk`, `sk`,
`rnd`, `mu`, `sig`) for all 100 vectors, and `tb/ref_*.mem` the per-block reference data.

> **Note on reproducing these numbers.** This repository carries the design, testbenches,
> constraints and synthesis reports. The simulation and synthesis driver scripts are not
> included, so the runs above are recorded results rather than one-command reproducible
> ones. Point any Verilog-2001 simulator at `rtl/` plus the relevant bench in `tb/` to
> re-run them; the testbenches read their vectors from paths relative to the repository root.

---

## Results on hardware

Out-of-context synthesis, Vivado 2023.2, **ZedBoard XC7Z020-CLG484-1**:

<table>
<tr><th align="left">Resource</th><th align="right">Used</th><th align="right">Available</th><th align="right">Util</th></tr>
<tr><td>Slice LUTs</td><td align="right"><b>32,714</b></td><td align="right">53,200</td><td align="right">61.5 %</td></tr>
<tr><td>&nbsp;&nbsp;— as logic</td><td align="right">21,404</td><td align="right">53,200</td><td align="right">40.2 %</td></tr>
<tr><td>&nbsp;&nbsp;— as distributed RAM</td><td align="right">11,236</td><td align="right">17,400</td><td align="right">65.0 %</td></tr>
<tr><td>Slice registers</td><td align="right">15,784</td><td align="right">106,400</td><td align="right">14.8 %</td></tr>
<tr><td>Block RAM tiles</td><td align="right">63</td><td align="right">140</td><td align="right">45.0 %</td></tr>
<tr><td>DSP48E1</td><td align="right">34</td><td align="right">220</td><td align="right">15.5 %</td></tr>
</table>

**Timing at 40 MHz: WNS +2.838 ns, TNS 0.000, 0 failing endpoints of 119,675 — met.**

Per block: `sign_ctrl` 7,208 LUTs · `verify_ctrl` 2,709 · `keygen_ctrl` 1,831 ·
`ntt_core` 733. The 11,236 LUTRAM cells are `pk_ram` / `sk_ram` / `sig_ram`, which have
several combinational readers each and so cannot become block RAM without adding a cycle
to every access.

> **Why 40 MHz and not 100?** The critical path is one combinational hop from the verify
> scratchpad BRAM, through `Decompose` inside `use_hint`, into the w1 packer — 21.97 ns
> over 31 logic levels. That caps the core near 45 MHz. Closing 100 MHz means pipelining
> that path and adding a wait state to `VF_USEHINT`; it is not a constraints problem.

Full reports: [`syn/reports/`](syn/reports) — utilization, hierarchical utilization,
timing summary, worst paths, clock utilization.

---

## Parameters

ML-DSA-65, matching FIPS 204 Table 1 exactly (`rtl/pkg/mldsa_params.vh`):

| | | | |
|---|---|---|---|
| q = 8380417 | n = 256 | (k, ℓ) = (6, 5) | d = 13 |
| η = 4 | τ = 49 | β = τη = 196 | ω = 55 |
| γ₁ = 2¹⁹ | γ₂ = (q−1)/32 | λ = 192 | |
| pk = 1952 B | sk = 4032 B | σ = 3309 B | |

Montgomery domain R = 2³², ζ = 1753, n⁻¹·R² mod q = 41978.

---

## Source layout

```
rtl/
  pkg/         mldsa_params.vh, zeta_rom.v
  math/        mod_add, montgomery_mult, butterfly_unit, ntt_core
  keccak/      keccak_f1600, keccak_round, shake_unified
  decompose/   power2round, decompose, use_hint
  mem/         poly_ram_tdp
  mldsa/       mldsa_top, keygen_ctrl, sign_ctrl, verify_ctrl

tb/
  tb_keygen_kat.v          KeyGen KAT
  tb_mldsa_sign_kat.v      Sign KAT
  tb_mldsa_verify_kat.v    Verify KAT, incl. the malformed-hint reject cases
  tb_mldsa_joint.v         KeyGen → Sign → Verify, no external reference data
  tb_mldsa_nist_kat.v      NIST end-to-end, sliced via +NIST_START / +NIST_END
  tb_ntt_check.v           NTT transform dump (diagnostic, does not self-check)
  tb_keccak.v              Keccak-f[1600] unit check
  tb_decompose_iso.v       Decompose unit check
  nist/                    100 NIST vector folders
  *.mem, *.vh              per-block reference vectors

constraints/   mldsa_top_zedboard.xdc (XC7Z020, 40 MHz), PQCsignKAT_4032.rsp
syn/           constraints.sdc (ASIC), reports/
```

---

## Register map

Byte-addressed, 32-bit words.

| Address | Name | Notes |
|---|---|---|
| `0x0000` | `CTRL` | `[0]` start_keygen · `[1]` start_sign · `[2]` start_verify |
| `0x0004` | `STATUS` | `[0]` busy · `[1]` done · `[2]` sig_valid |
| `0x0010`–`0x002C` | `seed_xi` | 256-bit |
| `0x0030`–`0x004C` | `rho` | 256-bit |
| `0x0050`–`0x006C` | `K` | 256-bit |
| `0x0070`–`0x008C` | `tr` | 256-bit |
| `0x0090`–`0x00AC` | `rnd` | 256-bit |
| `0x00B0`–`0x00CC` | `c_tilde` | 256-bit |
| `0x00D0`–`0x010C` | `mu` | 512-bit (lo then hi) |
| `0x0800`–`0x0FFF` | `pk_ram` | 1952 B |
| `0x1000`–`0x1FFF` | `sk_ram` | 4032 B — rho ‖ K ‖ tr ‖ s1 ‖ s2 ‖ t0 |
| `0x2000`–`0x27FC` | `poly_z_ram`, `poly_r0_ram` | |
| `0x3000`–`0x34EC` | `sig_ram` | 3309 B |

Top-level ports are `clk` / `rst_n` plus the native interface: `wr_en` / `wr_addr` /
`wr_data` sampled on the rising edge, and `rd_en` / `rd_addr` sampled likewise with
`rd_data` valid the next cycle.

---

## Status and known limits

- Verilog-2001 throughout — no SystemVerilog, so a Genus `-v2001` read works and `xvlog`
  needs no `-sv`.
- Verify rejects malformed hint encodings per Alg 15; **sign does not yet reject a
  malformed `sk`** — it trusts the key it is given.
- 40 MHz on the 7020. See the note under [Results](#results-on-hardware) for the path.
- `tb_ntt_check.v` is a diagnostic that dumps transforms; it asserts nothing. The NTT is
  covered indirectly, since byte-exact keygen/sign/verify cannot happen with a broken
  transform.
- No side-channel hardening has been done.
- Synthesis is verified; place-and-route and board bring-up are not yet in-tree.

---

## License

GPL v3 — see [LICENSE](LICENSE), and the header of every RTL source file.

Copyright © 2026 Abhinav S &lt;abhinavsasivala02@gmail.com&gt;
