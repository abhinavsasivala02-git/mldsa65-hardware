## =============================================================================
## constraints.sdc — SDC Timing Constraints for ML-DSA
## Target: 100 MHz ASIC (10 ns period)
##
## Works with both ntt_core (clk) and mldsa_top (ACLK)
## =============================================================================

## ---------------------------------------------------------------------------
## Clock definition
## ---------------------------------------------------------------------------
## Try ACLK first (mldsa_top), fall back to clk (ntt_core)
if {[sizeof_collection [get_ports ACLK -quiet]] > 0} {
    create_clock -name sys_clk \
                 -period 10.0 \
                 -waveform {0 5.0} \
                 [get_ports ACLK]
} else {
    create_clock -name sys_clk \
                 -period 10.0 \
                 -waveform {0 5.0} \
                 [get_ports clk]
}

## Clock uncertainty
set_clock_uncertainty -setup 0.15 [get_clocks sys_clk]
set_clock_uncertainty -hold  0.05 [get_clocks sys_clk]

## Clock transition
set_clock_transition 0.1 [get_clocks sys_clk]

## ---------------------------------------------------------------------------
## I/O delays (40% of clock period)
## ---------------------------------------------------------------------------
set INPUT_DELAY  4.0
set OUTPUT_DELAY 4.0

set_input_delay  ${INPUT_DELAY}  -clock sys_clk [remove_from_collection [all_inputs] [get_ports {clk ACLK} -quiet]]
set_output_delay ${OUTPUT_DELAY} -clock sys_clk [all_outputs]

## ---------------------------------------------------------------------------
## Reset false path
## ---------------------------------------------------------------------------
if {[sizeof_collection [get_ports ARESETn -quiet]] > 0} {
    set_false_path -from [get_ports ARESETn]
}
if {[sizeof_collection [get_ports rst_n -quiet]] > 0} {
    set_false_path -from [get_ports rst_n]
}

## ---------------------------------------------------------------------------
## Driving cell and load
## ---------------------------------------------------------------------------
## Replace BUF_X4 with actual cell from your library
set_driving_cell -lib_cell BUF_X4 [all_inputs]
set_load 0.05 [all_outputs]

## ---------------------------------------------------------------------------
## Design rules
## ---------------------------------------------------------------------------
set_max_transition 0.5 [current_design]
set_max_fanout     20  [current_design]
