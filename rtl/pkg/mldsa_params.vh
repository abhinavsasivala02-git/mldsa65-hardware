`ifndef MLDSA_PARAMS_VH
`define MLDSA_PARAMS_VH

`define MLDSA_Q          8380417
`define MLDSA_QBITS      23
`define MLDSA_N          256
`define MLDSA_LOG2N      8

`define MLDSA_K          6
`define MLDSA_L          5
`define MLDSA_ETA        4
`define MLDSA_TAU        49
`define MLDSA_BETA_VAL   196
`define MLDSA_GAMMA1     524288
`define MLDSA_GAMMA2     261888
`define MLDSA_OMEGA      55
`define MLDSA_LAMBDA     192
`define MLDSA_D_PARAM    13

`define MLDSA_SK_BYTES   4032
`define MLDSA_PK_BYTES   1952
`define MLDSA_SIG_BYTES  3309

`define MLDSA_MONT_R         4193792
`define MLDSA_MONT_R2        2365951
`define MLDSA_MONT_QINV      58728449
`define MLDSA_MONT_QINV_NEG  32'd4236238847

// NTT parameters
`define MLDSA_ZETA       1753
`define MLDSA_NINV_MONT  41978

`endif
