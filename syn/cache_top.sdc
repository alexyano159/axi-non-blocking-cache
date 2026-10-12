# Timing constraints for the synthesis flow (syn/run_synth.tcl).
# Single clock domain. The 100 MHz target is a reference point for
# reporting; the achieved Fmax is read from the timing report.
create_clock -name clk -period 10.000 [get_ports clk]

derive_clock_uncertainty

# All other ports are virtual pins (core-only synthesis), so no I/O
# delays are constrained.
