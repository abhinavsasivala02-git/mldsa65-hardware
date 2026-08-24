# MLDSA NTT check simulation in Vivado 2023.2 (non-project flow)
set top tb_ntt_check

file delete -force ./xsim
file mkdir ./xsim

# Compile only NTT-relevant RTL sources
set rtl_files [list \
    rtl/pkg/mldsa_params.vh \
    rtl/pkg/zeta_rom.v \
    rtl/math/montgomery_mult.v \
    rtl/math/mod_add.v \
    rtl/math/butterfly_unit.v \
    rtl/math/ntt_core.v \
    rtl/mem/poly_ram_tdp.v \
]

set fp [open ./xsim_files.txt w]
foreach f $rtl_files { puts $fp $f }
close $fp

set fp [open ./xsim_tb_files.txt w]
puts $fp "sim/tb/tb_ntt_check.v"
close $fp

if {[catch {exec xvlog --work xsim -i rtl/pkg -i sim/tb -f ./xsim_files.txt} err]} {
    puts "ERROR: xvlog (rtl) failed: $err"
    exit 1
}

if {[catch {exec xvlog --work xsim -sv -d USE_S1_DATA -i rtl/pkg -i sim/tb -f ./xsim_tb_files.txt} err]} {
    puts "ERROR: xvlog (tb) failed: $err"
    exit 1
}

if {[catch {exec xelab -debug typical -L xsim xsim.tb_ntt_check -s mldsa_ntt_sim} err]} {
    puts "ERROR: xelab failed: $err"
    exit 1
}

if {[catch {exec xsim -R mldsa_ntt_sim} err]} {
    puts "ERROR: xsim failed: $err"
    exit 1
}
