# =============================================================================

# =============================================================================

set DESIGN_NAME  mldsa_top
set CLK_NAME     ACLK
set CLK_PERIOD   10.0   ;# 100 MHz target
set RST_NAME     ARESETn

set RTL_DIR      ../rtl
set PKG_DIR      ../rtl/pkg
set TB_DIR       ../tb
set RPT_DIR      ./reports
set NET_DIR      ./netlists

file mkdir $RPT_DIR
file mkdir $NET_DIR

puts "================================================================"
puts "  ML-DSA-65 Genus Synthesis"
puts "  Design:  $DESIGN_NAME"
puts "  Clock:   $CLK_PERIOD ns ($CLK_NAME)"
puts "================================================================"

# =============================================================================
# Step 1: Read RTL
# =============================================================================
puts "\n--- Reading RTL sources ---"

set_attribute hdl_search_path $PKG_DIR /

read_hdl -v2001 [list \
    $RTL_DIR/pkg/mldsa_params.vh         \
    $RTL_DIR/math/mod_add.v              \
    $RTL_DIR/math/montgomery_mult.v      \
    $RTL_DIR/math/butterfly_unit.v       \
    $RTL_DIR/math/poly_arith.v           \
    $RTL_DIR/pkg/zeta_rom.v              \
    $RTL_DIR/math/ntt_core.v             \
    $RTL_DIR/mem/poly_ram_tdp.v          \
    $RTL_DIR/mem/poly_ram.v              \
    $RTL_DIR/keccak/keccak_round.v       \
    $RTL_DIR/keccak/keccak_f1600.v       \
    $RTL_DIR/keccak/shake_unified.v      \
    $RTL_DIR/decompose/decompose.v       \
    $RTL_DIR/decompose/make_hint.v       \
    $RTL_DIR/decompose/use_hint.v        \
    $RTL_DIR/decompose/power2round.v     \
    $RTL_DIR/sample/rej_bounded.v        \
    $RTL_DIR/sample/rej_uniform.v        \
    $RTL_DIR/sample/sample_in_ball.v     \
    $RTL_DIR/mldsa/keygen_ctrl.v         \
    $RTL_DIR/mldsa/sign_ctrl.v           \
    $RTL_DIR/mldsa/verify_ctrl.v         \
    $RTL_DIR/mldsa/mldsa_top.v           \
]

# =============================================================================
# Step 2: Elaborate
# =============================================================================
puts "\n--- Elaborating design ---"
elaborate $DESIGN_NAME

# =============================================================================
# Step 3: Timing Constraints (SDC)
# =============================================================================
puts "\n--- Applying constraints ---"

create_clock -name $CLK_NAME -period $CLK_PERIOD [get_ports $CLK_NAME]

set_input_delay  -clock $CLK_NAME [expr {$CLK_PERIOD * 0.2}] [all_inputs]
set_output_delay -clock $CLK_NAME [expr {$CLK_PERIOD * 0.2}] [all_outputs]

set_false_path -from [get_ports $RST_NAME]

set_driving_cell -lib_cell INVX1 [all_inputs]
set_load 0.01 [all_outputs]

# =============================================================================
# Step 4: Synthesize
# =============================================================================
puts "\n--- Synthesizing ---"
set_attribute syn_generic_effort medium /
set_attribute syn_map_effort    medium /
set_attribute syn_opt_effort    medium /

syn_generic
syn_map
syn_opt

# =============================================================================
# Step 5: Reports
# =============================================================================
puts "\n--- Generating reports ---"

report_timing -nworst 10                        > $RPT_DIR/timing.rpt
report_area                                     > $RPT_DIR/area.rpt
report_power                                    > $RPT_DIR/power.rpt
report_gates                                    > $RPT_DIR/gates.rpt
report_qor                                      > $RPT_DIR/qor.rpt

report_area -detail                             > $RPT_DIR/area_detail.rpt

check_design -all                               > $RPT_DIR/check_design.rpt

puts "\n--- Reports saved to $RPT_DIR/ ---"

# =============================================================================
# Step 6: Write Netlists
# =============================================================================
puts "\n--- Writing netlists ---"

write_hdl -mapped > $NET_DIR/${DESIGN_NAME}_netlist.v

write_sdc        > $NET_DIR/${DESIGN_NAME}.sdc

puts "\n--- Netlists saved to $NET_DIR/ ---"

# =============================================================================
# Summary
# =============================================================================
puts ""
puts "================================================================"
puts "  Synthesis Complete: $DESIGN_NAME"
puts "  Target Clock: $CLK_PERIOD ns"
puts "  Reports: $RPT_DIR/"
puts "  Netlists: $NET_DIR/"
puts "================================================================"
puts ""
