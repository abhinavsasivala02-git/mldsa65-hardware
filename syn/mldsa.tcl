
##   DESIGN_TOP = "ntt_core"   → synthesise NTT core only

set MLDSA_ROOT  ".."
set WORK_DIR    "./genus_work"
set RESULTS_DIR "./genus_out"

set TECH_LIB_PATH "/path/to/your/stdcell/lib"
set TECH_LIBS     [list \
    "${TECH_LIB_PATH}/slow_tt_0p9v_25c.lib" \
]

## Option A: NTT core only (fastest, for initial PPA estimates)

set DESIGN_TOP "mldsa_top"

set CLOCK_PORT       "clk"
set CLOCK_PERIOD_NS  10.0    ;# 100 MHz

if {$DESIGN_TOP eq "mldsa_top"} {
    set CLOCK_PORT "ACLK"
}

file mkdir ${WORK_DIR}
file mkdir ${RESULTS_DIR}

set_db init_lib_search_path ${TECH_LIB_PATH}
read_libs ${TECH_LIBS}

set_db init_hdl_search_path "${MLDSA_ROOT}/rtl/pkg"

##    Layer 2: NTT core

##    Layer 4: SHAKE wrappers

set RTL_FILES [list \
    \
    ;# --- Layer 0: ROM + Memory ---                                         \
    "${MLDSA_ROOT}/rtl/pkg/zeta_rom.v"                                       \
    "${MLDSA_ROOT}/rtl/mem/poly_ram.v"                                       \
    "${MLDSA_ROOT}/rtl/mem/poly_ram_tdp.v"                                   \
    \
    ;# --- Layer 1: Math primitives ---                                      \
    "${MLDSA_ROOT}/rtl/math/mod_add.v"                                       \
    "${MLDSA_ROOT}/rtl/math/montgomery_mult.v"                               \
    "${MLDSA_ROOT}/rtl/math/butterfly_unit.v"                                \
    "${MLDSA_ROOT}/rtl/math/poly_arith.v"                                    \
    \
    ;# --- Layer 2: NTT core ---                                             \
    "${MLDSA_ROOT}/rtl/math/ntt_core.v"                                      \
    \
    ;# --- Layer 3: Keccak ---                                               \
    "${MLDSA_ROOT}/rtl/keccak/keccak_round.v"                                \
    "${MLDSA_ROOT}/rtl/keccak/keccak_f1600.v"                                \
    \
    ;# --- Layer 4: SHAKE wrappers ---                                       \
    "${MLDSA_ROOT}/rtl/keccak/shake256.v"                                    \
    "${MLDSA_ROOT}/rtl/keccak/shake128.v"                                    \
    \
    ;# --- Layer 5: Sampling + Decompose ---                                 \
    "${MLDSA_ROOT}/rtl/sample/rej_uniform.v"                                 \
    "${MLDSA_ROOT}/rtl/sample/rej_bounded.v"                                 \
    "${MLDSA_ROOT}/rtl/sample/sample_in_ball.v"                              \
    "${MLDSA_ROOT}/rtl/decompose/power2round.v"                              \
    "${MLDSA_ROOT}/rtl/decompose/decompose.v"                                \
    "${MLDSA_ROOT}/rtl/decompose/make_hint.v"                                \
    "${MLDSA_ROOT}/rtl/decompose/use_hint.v"                                 \
    \
    ;# --- Layer 6: Control FSMs ---                                         \
    "${MLDSA_ROOT}/rtl/mldsa/keygen_ctrl.v"                                  \
    "${MLDSA_ROOT}/rtl/mldsa/sign_ctrl.v"                                    \
    "${MLDSA_ROOT}/rtl/mldsa/verify_ctrl.v"                                  \
    \
    ;# --- Layer 7: Top level ---                                            \
    "${MLDSA_ROOT}/rtl/mldsa/mldsa_top.v"                                    \
]

read_hdl -v2001 -define {SYNTHESIS} ${RTL_FILES}

elaborate ${DESIGN_TOP}
check_design -unresolved

read_sdc "${MLDSA_ROOT}/syn/constraints.sdc"

set_db syn_generic_effort   medium
set_db syn_map_effort       medium
set_db syn_opt_effort       medium

syn_generic
syn_map
syn_opt

report_timing  -nworst 10  > ${RESULTS_DIR}/timing.rpt
report_area               > ${RESULTS_DIR}/area.rpt
report_power              > ${RESULTS_DIR}/power.rpt
report_qor                > ${RESULTS_DIR}/qor.rpt

puts "===== QoR Summary ====="
report_qor -summary

write_hdl  > ${RESULTS_DIR}/${DESIGN_TOP}_netlist.v
write_sdf  -timescale ns \
           -nonegchecks \
           > ${RESULTS_DIR}/${DESIGN_TOP}.sdf
write_sdc  > ${RESULTS_DIR}/${DESIGN_TOP}_post.sdc
write_do_lec -revised_design ${RESULTS_DIR}/${DESIGN_TOP}_netlist.v \
             -logfile        ${RESULTS_DIR}/lec.do

puts "Synthesis of ${DESIGN_TOP} complete. Outputs in ${RESULTS_DIR}/"
