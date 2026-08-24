# =============================================================================
# vivado_nist20.tcl - Run NIST vectors 0..19 (two 10-vector slices) in Vivado.

# =============================================================================
set top tb_mldsa_nist_kat

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
puts $fp "joint_design/tb_mldsa_nist_kat.v"
close $fp

puts "=== STEP 1: xvlog (RTL) ==="
if {[catch {exec xvlog --work xsim -i rtl/pkg -i sim/tb -i sim/tb/nist -f ./xsim_files.txt} err]} {
    puts "ERROR: xvlog (rtl) failed:\n$err"
    exit 1
}
puts "=== STEP 1: xvlog (RTL) OK ==="

puts "=== STEP 2: xvlog (TB) ==="
if {[catch {exec xvlog --work xsim -sv -i rtl/pkg -i sim/tb -i sim/tb/nist -f ./xsim_tb_files.txt} err]} {
    puts "ERROR: xvlog (tb) failed:\n$err"
    exit 1
}
puts "=== STEP 2: xvlog (TB) OK ==="

puts "=== STEP 3: xelab ==="
if {[catch {exec xelab -debug typical -L xsim xsim.tb_mldsa_nist_kat -s nist_sim} err]} {
    puts "ERROR: xelab failed:\n$err"
    exit 1
}
puts "=== STEP 3: xelab OK ==="

set resf [open ./nist_results.txt w]
puts $resf "NIST slice -> passed"
close $resf

puts "=== STEP 4: xsim vectors 0..9 ==="
if {[catch {exec xsim -R nist_sim -testplusarg NIST_START=0 -testplusarg NIST_END=9} err]} {
    puts "ERROR: xsim slice 0..9 failed:\n$err"
    exit 1
}
puts "=== STEP 4: xsim slice 0..9 OK ==="

puts "=== STEP 4: xsim vectors 10..19 ==="
if {[catch {exec xsim -R nist_sim -testplusarg NIST_START=10 -testplusarg NIST_END=19} err]} {
    puts "ERROR: xsim slice 10..19 failed:\n$err"
    exit 1
}
puts "=== STEP 4: xsim slice 10..19 OK ==="

puts "=== NIST-20 SIMULATION COMPLETE ==="
