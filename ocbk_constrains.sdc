# Input clock: 21.47727 MHz crystal (period 46.554 ns)
# ----------------------------------------------------
create_clock -period "46.554 ns" -name {pClk21m} {pClk21m}

# PLL-generated clock (cpu_pll clk0 = 96.65 MHz): derived from the altpll model.
# ----------------------------------------------------------------------------
derive_pll_clocks
derive_clock_uncertainty

# CPU clock: a fabric toggle divider of the 96.65 MHz VCO (cpu_clkgen's
# cpu_clk_r register): /32 = 3.02 MHz (BK-0010), /24 = 4.03 MHz (BK-0011M) or
# /16 = 6.04 MHz (turbo, PS/2 F12), selected at run time. Constrained at the
# FASTEST rate - an SDC is static, so /16 must be the one declared or the
# constraint is optimistic in turbo; /16 covers /24 and /32. Every
# cpu_clk<->sys_clk path is false-pathed below anyway, so this bounds the
# (slow, non-critical) core domain only. Guarded so a node-name miss does not
# error the SDC - if empty, check the register name in the fitter report.
# ----------------------------------------------------------------------------
set cpu_div [get_registers {*u_clkgen|cpu_clk_r}]
set vco     [get_pins {*altpll_inst|pll|clk[0]}]
if {[get_collection_size $cpu_div] > 0 && [get_collection_size $vco] > 0} {
    create_generated_clock -name cpu_clk -source $vco -divide_by 16 $cpu_div
}

# USB host clock: the same fabric-divider chain, /8 of the 96.65 MHz VCO =
# 12.08 MHz (cpu_clkgen's usb_clk_r). A CLOCK, not a clock enable, because the
# vendored usb_hid_host core's Fmax on this part is 79 MHz - it cannot ride
# sys_clk. This is a clock DEFINITION, not a timing exception: usb_clk and
# cpu_clk free-run from one reset release and their edges coincide every 8 or
# 24 sys_clk, so the (slow) crossing analyses on its own. If TimeQuest ever
# wants a false_path here, fix the crossing structurally instead - an SDC
# exception is a fitter input and has broken the SEED-3 boot before.
# ----------------------------------------------------------------------------
set usb_div [get_registers {*u_clkgen|usb_clk_r}]
if {[get_collection_size $usb_div] > 0 && [get_collection_size $vco] > 0} {
    create_generated_clock -name usb_clk -source $vco -divide_by 8 $usb_div
}

# Q-bus address latch: qbus_sdram captures the bus address transparently on the
# SYNC strobe (as real multiplexed-bus peripherals do), so SYNC is a slow, logic-
# derived clock (period = one CPU cycle, 165.6 ns at the fastest 6.04 MHz turbo
# mode). Declare it and cut it from analysis - the captured address is
# stable by bus protocol when SYNC asserts (validated cycle-exact by the cosim),
# so there is no real setup/hold relationship to time.
# ----------------------------------------------------------------------------
set qsync [get_registers {*vm1_qbus:core|sync_out}]
if {[get_collection_size $qsync] > 0} {
    create_clock -name qbus_sync -period 165.6 $qsync
    set_false_path -from [get_clocks {qbus_sync}]
    set_false_path -to   [get_clocks {qbus_sync}]
}

# SDRAM I/O timing, relative to the SDRAM controller clock (PLL clk0 = 96.65 MHz).
# Delay values mirror esemsx3 / ocb-test. The PLL-generated clock name is matched
# by wildcard; if it comes up empty, check the exact name in the fitter's
# derive_pll_clocks report and update the pattern.
# ----------------------------------------------------------------------------
set sdram_clk [get_clocks {*altpll_inst|pll|clk\[0\]}]
if {[get_collection_size $sdram_clk] > 0} {
    set sdram_out_ports [get_ports {pMemDat[*] pMemAdr[*] pMemBa0 pMemBa1 \
        pMemLdq pMemUdq pMemWe_n pMemCas_n pMemRas_n pMemCs_n}]
    set_input_delay  -clock $sdram_clk -max 6.4 [get_ports pMemDat[*]]
    set_input_delay  -clock $sdram_clk -min 3.2 [get_ports pMemDat[*]]
    set_output_delay -clock $sdram_clk -max  1.5 $sdram_out_ports
    set_output_delay -clock $sdram_clk -min -0.8 $sdram_out_ports
}

# Clock-domain crossing: the qbus_sdram wait-state FSM (cpu_clk) and the SDRAM
# controller (sys_clk = PLL clk0) exchange data only through synchronisers and a
# request/payload handshake held stable for the whole transaction (req toggle,
# req payload, sampled read data, init_done). Cut both directions so TimeQuest
# does not time these quasi-static / multi-flop-synchronised crossings.
# ----------------------------------------------------------------------------
if {[get_collection_size $sdram_clk] > 0 && [get_collection_size $cpu_div] > 0} {
    set_false_path -from [get_clocks {cpu_clk}] -to $sdram_clk
    set_false_path -from $sdram_clk -to [get_clocks {cpu_clk}]
}

# Pixel clock (PLL clk1 = 64.43 MHz) <-> SDRAM/system clock (clk0 = 96.65 MHz):
# same-VCO RELATED clocks, so TimeQuest would time the 3:2 crossing (~5.17 ns
# transfer) and fail closure spuriously. Every real crossing is protected by
# design - the vga_out->fb_readout line request is a toggle + payload handshake
# (2-FF synced, payload stable ~21 us around the toggle), fb_linebuf is a
# ping-pong dual-clock RAM whose banks are never written while displayed, and
# fb_front_valid is 2-FF synced in vga_out - so cut both directions.
# ----------------------------------------------------------------------------
set pix_clk [get_clocks {*altpll_inst|pll|clk\[1\]}]
if {[get_collection_size $sdram_clk] > 0 && [get_collection_size $pix_clk] > 0} {
    set_false_path -from $sdram_clk -to $pix_clk
    set_false_path -from $pix_clk -to $sdram_clk
}

# DIP switches are quasi-static config inputs (screen_mode is 2-FF synced);
# no timing relationship to any clock.
# ----------------------------------------------------------------------------
set_false_path -from [get_ports {pDip[*]}]

# PS/2 keyboard inputs: 2-FF synchronized inside ps2_rx (the ~15 kHz PS/2
# clock is oversampled ~100x by cpu_clk); no timing relationship to any clock.
set_false_path -from [get_ports {pPs2Clk pPs2Dat}]

# VGA outputs: all registered on the pixel clock inside vga_out; the R-2R DAC
# and monitor sync inputs have no meaningful setup/hold at 64.43 MHz, so they
# are left unconstrained (as the hardware-validated ocb-test build).

# LEDs are async status outputs (no setup/hold relationship); leave unconstrained.
