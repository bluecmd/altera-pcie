#
# Copyright (C) 2014, 2017 Chris McClelland
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software
# and associated documentation files (the "Software"), to deal in the Software without
# restriction, including without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright  notice and this permission notice  shall be included in all copies or
# substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
# BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
# DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
# vsim -c -do compile.tcl > compile.log
set QUARTUS_INSTALL_DIR $env(ALTERA)
set QSYS_SIMDIR "pcie/stratixv/pcie_sv/testbench"
do $QSYS_SIMDIR/mentor/msim_setup.tcl
dev_com
com
vlog $QSYS_SIMDIR/pcie_sv_tb/simulation/submodules/altpcierd_tl_cfg_sample.v -work pcie_sv

set QSYS_SIMDIR "pcie/cyclonev/pcie_cv/testbench"
do $QSYS_SIMDIR/mentor/msim_setup.tcl
dev_com
com
vlog $QSYS_SIMDIR/pcie_cv_tb/simulation/submodules/altpcierd_tl_cfg_sample.v -work pcie_cv

# Configure mappings
proc ensure_lib { lib } { if ![file isdirectory $lib] { vlib $lib } }
ensure_lib           ./libraries/altera_mf/
vmap       altera_mf ./libraries/altera_mf/
ensure_lib           ./libraries/makestuff/
vmap       makestuff ./libraries/makestuff/

# Compile Altera VHDL components
#vcom $QUARTUS_INSTALL_DIR/eda/sim_lib/altera_mf_components.vhd -work altera_mf
#vcom $QUARTUS_INSTALL_DIR/eda/sim_lib/altera_mf.vhd            -work altera_mf

# Compile MakeStuff components
vcom -93   -novopt dvr-rng/rng_n1024_r32_t5_k32_s1c48.vhdl   -check_synthesis -work makestuff
vcom -93   -novopt dvr-rng/dvr_rng32.vhdl                    -check_synthesis -work makestuff
vcom -93   -novopt dvr-rng/rng_n2048_r64_t3_k32_s5f81cb.vhdl -check_synthesis -work makestuff
vcom -93   -novopt dvr-rng/dvr_rng64.vhdl                    -check_synthesis -work makestuff
vcom -93   -novopt dvr-rng/rng_n3060_r96_t3_k32_s79e56.vhdl  -check_synthesis -work makestuff
vcom -93   -novopt dvr-rng/dvr_rng96.vhdl                    -check_synthesis -work makestuff
vlog -sv   -novopt dvr-rng/dvr_rng_pkg.sv                    -hazards -lint -pedanticerrors -work makestuff
vlog -sv   -novopt buffer-fifo/buffer_fifo_impl.sv           -hazards -lint -pedanticerrors -work makestuff
vlog -sv   -novopt buffer-fifo/buffer_fifo.sv                -hazards -lint -pedanticerrors -work makestuff
vlog -sv   -novopt reg-mux/reg_mux.sv                        -hazards -lint -pedanticerrors -work makestuff
vlog -sv   -novopt pcie/tlp-xcvr/tlp_xcvr_pkg.sv             -hazards -lint -pedanticerrors -work makestuff
vlog -sv   -novopt pcie/tlp-xcvr/tlp_recv.sv                 -hazards -lint -pedanticerrors -work makestuff
vlog -sv   -novopt pcie/tlp-xcvr/tlp_send.sv                 -hazards -lint -pedanticerrors -work makestuff
vlog -sv   -novopt pcie/tlp-xcvr/tlp_xcvr.sv                 -hazards -lint -pedanticerrors -work makestuff
vlog -sv   -novopt pcie/stratixv/pcie_sv.sv                  -hazards -lint -pedanticerrors -work makestuff
vlog -sv   -novopt pcie/cyclonev/pcie_cv.sv                  -hazards -lint -pedanticerrors -work makestuff

# And exit
exit
