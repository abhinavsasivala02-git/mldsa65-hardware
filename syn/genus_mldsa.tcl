# =============================================================================
# genus_mldsa.tcl - Cadence Genus synthesis of ML-DSA-65 (FIPS 204)
#
# This is the single synthesis script.  Run from the PROJECT ROOT:
#     genus -f syn/genus_mldsa.tcl
#
# mldsa_top's top-level ports are  clk / rst_n  (native register interface).
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Configuration
# -----------------------------------------------------------------------------
set DESIGN_NAME   mldsa_top
set CLK_NAME      clk          ;# actual top-level clock port
set RST_NAME      rst_n        ;# actual top-level async reset port
set CLK_PERIOD_NS 10.0         ;# 100 MHz
set RTL_ROOT      ../rtl
set SDC_FILE      ../syn/constraints.sdc
set RESULTS_DIR   ./genus_out

# -----------------------------------------------------------------------------
# 2. Technology libraries  (EDIT for your process / PDK)
# -----------------------------------------------------------------------------
set LIB_DIR  /path/to/your/stdcells/lib
set LIBS     [list \
    ${LIB_DIR}/slow_tt_0p9v_25c.lib \
]

# -----------------------------------------------------------------------------
# 3. Read libraries
# -----------------------------------------------------------------------------
set_db init_lib_search_path ${LIB_DIR}
set_db init_hdl_search_path "${RTL_ROOT}/pkg"   ;# for `include "mldsa_params.vh"
read_libs ${LIBS}

# -----------------------------------------------------------------------------
# 4. Read RTL
# -----------------------------------------------------------------------------
file mkdir ${RESULTS_DIR}

read_hdl -v2001 -define {SYNTHESIS} [list \
    ${RTL_ROOT}/pkg/zeta_rom.v         \
    ${RTL_ROOT}/decompose/decompose.v  \
    ${RTL_ROOT}/decompose/make_hint.v  \
    ${RTL_ROOT}/decompose/power2round.v \
    ${RTL_ROOT}/decompose/use_hint.v   \
    ${RTL_ROOT}/keccak/keccak_f1600.v  \
    ${RTL_ROOT}/keccak/keccak_round.v  \
    ${RTL_ROOT}/keccak/shake_unified.v \
    ${RTL_ROOT}/keccak/shake128.v      \
    ${RTL_ROOT}/keccak/shake256.v      \
    ${RTL_ROOT}/math/butterfly_unit.v  \
    ${RTL_ROOT}/math/mod_add.v         \
    ${RTL_ROOT}/math/montgomery_mult.v \
    ${RTL_ROOT}/math/ntt_core.v        \
    ${RTL_ROOT}/math/poly_arith.v      \
    ${RTL_ROOT}/mem/poly_ram.v         \
    ${RTL_ROOT}/mem/poly_ram_tdp.v     \
    ${RTL_ROOT}/sample/rej_bounded.v   \
    ${RTL_ROOT}/sample/rej_uniform.v   \
    ${RTL_ROOT}/sample/sample_in_ball.v \
    ${RTL_ROOT}/mldsa/keygen_ctrl.v    \
    ${RTL_ROOT}/mldsa/sign_ctrl.v      \
    ${RTL_ROOT}/mldsa/verify_ctrl.v    \
    ${RTL_ROOT}/mldsa/mldsa_top.v      \
]

elaborate ${DESIGN_NAME}
check_design -unresolved

# -----------------------------------------------------------------------------
# 5. Constraints
# -----------------------------------------------------------------------------
read_sdc ${SDC_FILE}

# -----------------------------------------------------------------------------
# 6. Synthesize
# -----------------------------------------------------------------------------
set_db syn_generic_effort medium
set_db syn_map_effort    medium
set_db syn_opt_effort    medium
set_db max_fanout        20

syn_generic
syn_map
syn_opt

# -----------------------------------------------------------------------------
# 7. Reports
# -----------------------------------------------------------------------------
report_area     -detail > ${RESULTS_DIR}/area.rpt
report_timing   -nworst 10        > ${RESULTS_DIR}/timing.rpt
report_power               > ${RESULTS_DIR}/power.rpt
report_qor                 > ${RESULTS_DIR}/qor.rpt
report_gates               > ${RESULTS_DIR}/gates.rpt

# -----------------------------------------------------------------------------
# 8. Write netlist / post-synthesis timing & constraints
# -----------------------------------------------------------------------------
write_hdl -mapped          > ${RESULTS_DIR}/${DESIGN_NAME}_netlist.v
write_sdf  -timescale ns   > ${RESULTS_DIR}/${DESIGN_NAME}.sdf
write_sdc                  > ${RESULTS_DIR}/${DESIGN_NAME}_post.sdc

puts "===== ML-DSA-65 Genus synthesis complete ====="
puts "Netlist:  ${RESULTS_DIR}/${DESIGN_NAME}_netlist.v"
puts "Reports:  ${RESULTS_DIR}/{area,timing,power,qor}.rpt"
