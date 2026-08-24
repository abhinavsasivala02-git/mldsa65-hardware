# =============================================================================
# vivado_sim.tcl - MLDSA-65 Sign KAT simulation (Vivado 2023.2, non-project)

# =============================================================================

set top tb_mldsa_sign_kat

puts "=== STEP 0: clean old artifacts ==="
file delete -force ./xsim ./xsim.dir
file mkdir ./xsim

set rtl_files [list \
    rtl/pkg/mldsa_params.vh \
    rtl/pkg/zeta_rom.v \
    rtl/math/montgomery_mult.v \
    rtl/math/mod_add.v \
    rtl/math/butterfly_unit.v \
    rtl/math/ntt_core.v \
    rtl/math/poly_arith.v \
    rtl/decompose/power2round.v \
    rtl/decompose/decompose.v \
    rtl/decompose/make_hint.v \
    rtl/decompose/use_hint.v \
    rtl/mem/poly_ram_tdp.v \
    rtl/mem/poly_ram.v \
    rtl/keccak/keccak_f1600.v \
    rtl/keccak/keccak_round.v \
    rtl/keccak/shake_unified.v \
    rtl/mldsa/keygen_ctrl.v \
    rtl/mldsa/sign_ctrl.v \
    rtl/mldsa/verify_ctrl.v \
    rtl/mldsa/mldsa_top.v \
]

set fp [open ./xsim_files.txt w]
foreach f $rtl_files { puts $fp $f }
close $fp

set fp [open ./xsim_tb_files.txt w]
puts $fp "tb/tb_mldsa_sign_kat.v"
close $fp

puts "=== STEP 1: xvlog (RTL) ==="
if {[catch {exec xvlog --work xsim -i rtl/pkg -i tb -f ./xsim_files.txt} err]} {
    puts "ERROR: xvlog (rtl) failed:\n$err"
    exit 1
}
puts "=== STEP 1: xvlog (RTL) OK ==="

puts "=== STEP 2: xvlog (TB) ==="
if {[catch {exec xvlog --work xsim -sv -i rtl/pkg -i tb -f ./xsim_tb_files.txt} err]} {
    puts "ERROR: xvlog (tb) failed:\n$err"
    exit 1
}
puts "=== STEP 2: xvlog (TB) OK ==="

puts "=== STEP 3: xelab ==="
if {[catch {exec xelab -debug typical -L xsim xsim.tb_mldsa_sign_kat -s mldsa_sim} err]} {
    puts "ERROR: xelab failed:\n$err"
    exit 1
}
puts "=== STEP 3: xelab OK ==="

puts "=== STEP 4: xsim (running; debug output follows) ==="
if {[catch {exec xsim -R mldsa_sim -testplusarg TEST_LOOP=1} err]} {
    puts "ERROR: xsim failed:\n$err"
    exit 1
}
puts "=== STEP 4: xsim OK ==="

puts "=== SIMULATION COMPLETE ==="
