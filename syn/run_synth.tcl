# -----------------------------------------------------------------------
# Synthesis flow for the cache (Quartus Prime, command line).
#
# Usage, from the repository root:
#   quartus_sh -t syn/run_synth.tcl
#
# Creates a project in syn/build/ (ignored by git), synthesizes
# syn/cache_top_syn.sv (a pin-level wrapper around rtl/cache_top.sv),
# places and routes it, and runs static timing analysis. Results:
#   syn/build/output_files/cache_top_syn.map.summary  (synthesis)
#   syn/build/output_files/cache_top_syn.fit.summary  (resources)
#   syn/build/output_files/cache_top_syn.sta.rpt      (timing, Fmax)
#
# Target: Cyclone V 5CSEMA5F31C6 (the DE1-SoC device). Every port except
# the clock is a virtual pin: the design has ~300 I/O signals, and the
# goal is the core's resources and Fmax, not a pin-level implementation.
# -----------------------------------------------------------------------
load_package flow

set script_dir [file dirname [file normalize [info script]]]
set repo_dir   [file dirname $script_dir]
set build_dir  [file join $script_dir build]

file mkdir $build_dir
cd $build_dir

project_new cache_top_syn -overwrite

set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSEMA5F31C6
set_global_assignment -name TOP_LEVEL_ENTITY cache_top_syn
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files

# SYNTHESIS excludes simulation-only code (assertions, elaboration checks).
set_global_assignment -name VERILOG_MACRO "SYNTHESIS=1"

# Sources: the interface first, then the RTL, then the wrapper.
set_global_assignment -name SYSTEMVERILOG_FILE [file join $repo_dir rtl axi_if.sv]
foreach f {cache_tag_array cache_valid_array cache_data_sram cache_controller mshr cache_top} {
    set_global_assignment -name SYSTEMVERILOG_FILE [file join $repo_dir rtl $f.sv]
}
set_global_assignment -name SYSTEMVERILOG_FILE [file join $script_dir cache_top_syn.sv]
set_global_assignment -name SDC_FILE [file join $script_dir cache_top.sdc]

# Core-only implementation: every port except clk is a virtual pin.
foreach pattern {rst_n req_* resp_* m_axi_*} {
    set_instance_assignment -name VIRTUAL_PIN ON -to $pattern
}

execute_flow -compile

project_close
