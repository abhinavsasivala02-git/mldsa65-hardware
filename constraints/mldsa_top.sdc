# =============================================================================
# mldsa_top.sdc — Timing constraints for ML-DSA-65
# Target: 100 MHz (10 ns period)
# =============================================================================

# Clock definition
create_clock -name clk -period 10.0 [get_ports ACLK]

# Clock uncertainty (jitter + skew)
set_clock_uncertainty 0.5 [get_clocks clk]

# Reset
set_false_path -from [get_ports ARESETn]

# Input delays (AXI interface)
set_input_delay  -clock clk 2.0 [get_ports {AWVALID AWADDR* AWPROT* WVALID WDATA* WSTRB* BREADY ARVALID ARADDR* ARPROT* RREADY}]

# Output delays (AXI interface)
set_output_delay -clock clk 2.0 [get_ports {AWREADY WREADY BVALID BRESP* ARREADY RVALID RDATA* RRESP*}]

# Max transition and fanout
set_max_transition 0.5 [get_designs mldsa_top]
set_max_fanout 20 [get_designs mldsa_top]
