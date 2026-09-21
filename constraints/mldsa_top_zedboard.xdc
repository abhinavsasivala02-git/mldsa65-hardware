# =============================================================================
# mldsa_top_zedboard.xdc - ML-DSA-65 core, ZedBoard (XC7Z020-CLG484-1)
#
# Out-of-context constraints: mldsa_top has no board-level pins. Its native
# register interface (wr_en/wr_addr/wr_data, rd_en/rd_addr/rd_data) is meant to
# hang off the PS via an AXI4-Lite bridge inside the block design, and clk comes
# from PS FCLK_CLK0. So no set_property PACKAGE_PIN / IOSTANDARD here - adding
# them would be wrong, not merely unused.
#
#   synth_design -top mldsa_top -part xc7z020clg484-1 -mode out_of_context
#
# Target: 40 MHz on PS FCLK_CLK0.
#
# Not 100 MHz. The critical path is one combinational cycle from the verify
# scratchpad BRAM through Decompose (inside use_hint) into the w1 packer:
# 21.97 ns, 31 logic levels. That caps the core near 45 MHz, so 25 ns is the
# honest target with margin. Raising it means pipelining Decompose and adding
# a wait state to VF_USEHINT, not tightening this file.
# =============================================================================

set CLK_PERIOD 25.000

# -----------------------------------------------------------------------------
# Clock
# -----------------------------------------------------------------------------
create_clock -name clk -period $CLK_PERIOD \
             -waveform "0.000 [expr {$CLK_PERIOD / 2}]" [get_ports clk]

# PS FCLK jitter + BUFG/net skew budget. Drop to ~0.05 ns once the core is
# inside a block design and clk arrives on a real BUFG (Vivado models the rest).
set_clock_uncertainty 0.200 [get_clocks clk]

# -----------------------------------------------------------------------------
# Reset - async assert, synchronous release inside the core
# -----------------------------------------------------------------------------
set_false_path -from [get_ports rst_n]

# -----------------------------------------------------------------------------
# I/O timing budget (OOC): 40% of the period each way, leaving 20% for the core.
# Tighten once the real AXI bridge is attached and its delays are known.
# -----------------------------------------------------------------------------
set IO_DELAY [expr {$CLK_PERIOD * 0.4}]

set_input_delay  -clock clk $IO_DELAY \
    [get_ports {wr_en rd_en wr_addr[*] wr_data[*] rd_addr[*]}]

set_output_delay -clock clk $IO_DELAY [get_ports {rd_data[*]}]

# -----------------------------------------------------------------------------
# Notes on what is deliberately NOT here
# -----------------------------------------------------------------------------
# - No set_driving_cell / set_load / set_max_transition: ASIC-only (Genus),
#   Vivado ignores or errors on them. See syn/constraints.sdc for the ASIC set.
# - No BRAM/DSP placement or floorplan pblocks: let the tool place first, add
#   only if timing actually fails.
