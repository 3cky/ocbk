# Input clock: 21.47727 MHz crystal (period 46.554 ns)
# ----------------------------------------------------
create_clock -period "46.554 ns" -name {pClk21m} {pClk21m}

# PLL-generated clock (cpu_pll clk0 = 96.65 MHz): derived from the altpll model.
# ----------------------------------------------------------------------------
derive_pll_clocks
derive_clock_uncertainty

# CPU clock: ~3.02 MHz, a /32 fabric divide of the 96.65 MHz VCO, taken off the
# top bit of the divider (ocbk_top, divc[4]). Defined so TimeQuest analyses
# the (slow, non-critical) core domain. Guarded so a node-name miss does not
# error the SDC - if empty, check the register name in the fitter report.
# ----------------------------------------------------------------------------
set cpu_div [get_registers {*divc[4]}]
set vco     [get_pins {*altpll_inst|pll|clk[0]}]
if {[get_collection_size $cpu_div] > 0 && [get_collection_size $vco] > 0} {
    create_generated_clock -name cpu_clk -source $vco -divide_by 32 $cpu_div
}

# Q-bus address latch: qbus_mem captures the bus address transparently on the
# SYNC strobe (as real multiplexed-bus peripherals do), so SYNC is a slow, logic-
# derived clock. Declare it and cut it from analysis - the captured address is
# stable by bus protocol when SYNC asserts (validated cycle-exact by the cosim),
# so there is no real setup/hold relationship to time.
# ----------------------------------------------------------------------------
set qsync [get_registers {*vm1_qbus:core|sync_out}]
if {[get_collection_size $qsync] > 0} {
    create_clock -name qbus_sync -period 331.0 $qsync
    set_false_path -from [get_clocks {qbus_sync}]
    set_false_path -to   [get_clocks {qbus_sync}]
}

# LEDs are async status outputs (no setup/hold relationship); leave unconstrained.
