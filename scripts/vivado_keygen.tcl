# MLDSA KeyGen KAT simulation in Vivado 2023.2 (non-project flow)
set top tb_keygen_kat

file delete -force ./xsim
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
puts $fp "tb/tb_keygen_kat.v"
close $fp

if {[catch {exec xvlog --work xsim -i rtl/pkg -i tb -f ./xsim_files.txt} err]} {
    puts "ERROR: xvlog (rtl) failed: $err"
    exit 1
}

if {[catch {exec xvlog --work xsim -sv -i rtl/pkg -i tb -f ./xsim_tb_files.txt} err]} {
    puts "ERROR: xvlog (tb) failed: $err"
    exit 1
}

if {[catch {exec xelab -debug typical -L xsim xsim.tb_keygen_kat -s keygen_sim} err]} {
    puts "ERROR: xelab failed: $err"
    exit 1
}

if {[catch {exec xsim -R keygen_sim} err]} {
    puts "ERROR: xsim failed: $err"
    exit 1
}
