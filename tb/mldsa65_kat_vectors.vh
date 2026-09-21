// =============================================================================
// mldsa65_kat_vectors.vh — FIPS 204 ML-DSA-65 Known Answer Test Vectors
//
// Seeds are the 32-byte xi inputs written directly to the DUT (the KAT "seed"
// column of PQCsignKAT_4032.rsp is a 48-byte AES-DRBG seed, NOT used here).
// Expected rho values are the first 32 bytes of keypair(xi) as produced by
// scripts/mldsa_ref.py keypair() with xi = bytes(i*0x20 .. i*0x20+0x1f).
// =============================================================================

// KAT Vector 0
localparam [255:0] KAT0_SEED = 256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f;
localparam [255:0] KAT0_RHO   = 256'h48683d91978e31eb3dddb8b0473482d2b88a5f625949fd8f58a561e696bd4c27;

// KAT Vector 1
localparam [255:0] KAT1_SEED = 256'h202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f;
localparam [255:0] KAT1_RHO   = 256'h01b24276275667002e40e9685a8716a51cbcabb39369f54f24b30982defca3ce;

// KAT Vector 2
localparam [255:0] KAT2_SEED = 256'h404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f;
localparam [255:0] KAT2_RHO   = 256'hc0f4848649b3b8e661deb1d0f53ac876f32bd50eb812aab82021fda65f3f15fa;

// KAT Vector 3
localparam [255:0] KAT3_SEED = 256'h606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f;
localparam [255:0] KAT3_RHO   = 256'he336d291f823842b51b63a730d608a4cc2012aa6dc661a3600f13ff5d6efab80;

// KAT Vector 4
localparam [255:0] KAT4_SEED = 256'h808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f;
localparam [255:0] KAT4_RHO   = 256'hb2d8d7b17c6c5ce1df5b588a582adfc4f2a3fff9db64179d3582f16612843ed8;

// Number of KAT vectors
`define NUM_KAT_VECTORS 5
