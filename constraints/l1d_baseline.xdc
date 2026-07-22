create_clock -name clk -period 10.000 [get_ports clk]

# Model a synchronous integration boundary for both the OOC cache adapters and
# the small-I/O implementation harness.  Reset is asynchronous and therefore
# excluded from ordinary data-path timing.
set l1d_input_ports [get_ports -quiet -filter {DIRECTION == IN && NAME != clk}]
set_input_delay -clock [get_clocks clk] -max 1.000 $l1d_input_ports
set_input_delay -clock [get_clocks clk] -min 0.000 $l1d_input_ports
set l1d_output_ports [all_outputs]
set_output_delay -clock [get_clocks clk] -max 1.000 $l1d_output_ports
set_output_delay -clock [get_clocks clk] -min 0.000 $l1d_output_ports
set l1d_reset_ports [get_ports -quiet rst_n]
set_false_path -from $l1d_reset_ports
