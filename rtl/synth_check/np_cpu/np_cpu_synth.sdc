# 48 MHz: clk_sys (docs/ROADMAP.md, Clocks). The SDRAM pins are left unconstrained here:
# their timing is sys/'s, measured in the full build.
create_clock -name clk -period 20.833 [get_ports clk]
derive_clock_uncertainty
