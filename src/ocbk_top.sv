// ocbk_top - top level for the BK-0010 CPU + RAM-in-SDRAM + video pipeline on
// the OneChipBook.
//
// The vm1 (1801ВМ1) core runs the ROM image loaded from the config flash, with
// the retimed 037 (va_037_sync) owning RAM RPLY / cycle-stealing; BK RAM is in
// the board SDRAM behind sdram_arbiter; the 037 video fetch is
// decoded through palette_apply into a double-buffered 4-bit-index framebuffer
// in SDRAM and scanned out at 1024x768@60 (x2H/x3V) on the 6-bit R-2R VGA DAC.
//
// The board's two MSX joystick ports are read as the BK's 0177714 joystick
// word (bk_joystick -> qbus_mem's io_word) - a read-only path with no state
// and no reset.
//
// Only the pins the design uses are declared; every other device pin -
// including the entire cartridge-slot block PIN_121-180 - is reserved as a
// tri-stated input by the .qsf. The cartridge-slot Q-bus seam lives in qbus_slot
// and is held disabled (SLOT_ENABLE=0) - a forward seam, not a build option.
//
// Clock tree (one PLL only - board constraint: the PIN_28 crystal feeds a single
// PLL). The x9 VCO yields 96.65 MHz; the pixel clock is the same VCO /3; the
// rest are fabric divides or the PLL's dedicated external-clock pin:
//
//   96.65 MHz  sys_clk   altpll clk0     - SDRAM controller + adapter logic
//   96.65 MHz  pMemClk   altpll extclk0  - SDRAM chip clock (phase-matched, e0)
//   64.43 MHz  pix_clk   altpll clk1     - 1024x768@60 video readout
//   /8  -> 12.08 MHz   dot_ena (1-in-8 strobe)             (spare)
//   /16 ->  6.04 MHz   037 CLKIN enables en_pos/en_neg     (model-independent)
//   cpu_clk, 50% duty, from the same cpu_clkgen chain:
//          /32 -> 3.02 MHz (BK-0010)  /24 -> 4.03 MHz (BK-0011M), by DIP 1
//          /16 -> 6.04 MHz (turbo, PS/2 F12 - overrides the model select)
//          cpu_clk_n = ~cpu_clk                            (anti-phase pair)
//
// sys_clk <-> pix_clk are same-VCO related clocks; every real crossing is a
// toggle+2-FF handshake or the ping-pong-guarded fb_linebuf RAM, so the SDC
// false-paths the pair (TimeQuest would otherwise time the 3:2 ~5.2 ns transfer).
//
// Reset: the SDRAM controller is released as soon as the PLL locks and runs its
// ~200 us init; the EPCS boot loader then copies BOTH ROM blobs from the config
// flash into the SDRAM ROM regions - the BK-0010.01 set, then the BK-0011M set
// plus the SMK512 BIOS image (~77 ms total); the CPU is held in reset
// (DCLO low) until init_done AND boot_done, after which DCLO and ACLO are
// released in sequence (the bk10_tb power-up ordering). The video readout +
// pixel domain are held until init_done; RGB stays black until the first
// complete BK frame has been decoded (fb_front_valid).
//
// Soft reset (warm restart): the board's reset button (pSltRst_n, the slot
// RESET net, external pull-up) re-enters the same sequencer hold - pressed =
// DCLO/ACLO asserted, release + a ~22 ms debounce tail = the identical
// DCLO->ACLO release. Only the CPU-side DCLO-keyed state (CPU, memory
// front-end, LED latches) re-initialises: SDRAM init, the EPCS load and
// memory contents are untouched, so MONITOR/BASIC warm-reboots through the
// authentic 177716 start vector - BK hardware-reset semantics (memory
// survives). The 037 and the video pipeline are power-on-reset ONLY
// (vid_rst_n): as on a real BK, the display is unaffected by a CPU reset and
// keeps showing video RAM while the button is held. The warm-reset replay
// oracles in sim/ref037 pin the post-reset timing (release aligned to vblank
// there; on hardware the release lands at an arbitrary raster phase, exactly
// like a real machine).
//
// Real-BK reset wiring: DCLO/ACLO go to the CPU ONLY. All BK peripherals are
// reset by the CPU's nINIT Q-bus line (driven open-collector by the vm1:
// asserted during its own reset AND pulsed by the RESET instruction) - a
// peripheral keys its reset to init_n, never to dclo_n. The documented
// exceptions (map / 177662 / spk / СТОП-block / smk_ide) are DCLO-only and say
// so at each site.
//
// ROM source: always the SDRAM image (the loaded MONITOR+BASIC set). There is
// no on-chip ROM fallback - a failed EPCS boot (boot_ok=0) holds the CPU in
// reset.
// Naming: "DIP n" = physical switch n = pDip[n-1]; ON pulls the pin low.
// DIP 1 = model select (OFF = BK-0010, ON = BK-0011M: /24 CPU clock, banking,
// 177662, EVNT/IRQ2, BOS boot), latched while DCLO is held (power-on and warm
// reset). DIP 8 = SMK512 enable, same DCLO-hold latch - in BOTH models (the SMK
// is an МПИ expansion board), and DIP-8-ON boots the SMK BIOS either way.
// DIP 4 = CMT tape-in mode (read LIVE, no reset needed - it never touches the
// CPU). DIP 5 = Covox mono/stereo (OFF = stereo, ON = mono), read live for the
// same reason; it drove the audio self-test tone until that was retired from
// the shipped build on 2026-07-31, once the resolution claim it existed to
// demonstrate had been measured on hardware (a debug feature does not ship) -
// the tone wiring is still here, see the tone_en note below. DIP 2 is unused.
//
// screen_mode (mono-512 vs colour-256) models the physical monitor-cable switch
// of a real BK-0010, toggled by the PS/2 Print Screen key (each press
// cycles the mode; power-on default = colour-256; survives warm reset).
//
// LEDs (liveness):
//   pLedPwr (red)  : solid once SDRAM init_done; BLINKS if the boot blob failed
//                    validation (the CPU is then held in reset).
//   pLed[7]        : SMK512 drive-access (ide_act stretched ~87 ms, blinking
//                    at ~11.5 Hz while the drive is busy).
//   pLed[0]        : BK speaker activity (solid while a tone plays; audio tap).
//   pLed[6]        : CMT tape-in mode (DIP 4; lit = the right jack is the
//                    cassette port).
//   pLed[5]        : TURBO mode (PS/2 F12; lit = 6.04 MHz CPU with the 037's
//                    cycle-stealing disabled).
//   pLed[2]        : a DAC quantizer clipped (sticky; should never light).
//   pLed[1]        : the audio mixer saturated (sticky; should never light).
//   pLed[4]        : TurboSound PSG activity (a tone or noise channel is
//                    enabled on a live chip).
//   pLed[3]        : TurboSound 2-chip mode engaged; it was the self-test
//                    indicator until DIP 5 was retired and reused.
module ocbk_top (
    input  logic        pClk21m,   // 21.47727 MHz crystal (PIN_28)
    output logic [7:0]  pLed,      // green LEDs   (1 = on)
    output logic        pLedPwr,   // red power LED (1 = on)
    input  logic [7:0]  pDip,      // DIP switches (ON = low):
                                   //   [0] = model select (OFF = BK-0010,
                                   //         ON = BK-0011M)
                                   //   [3] = CMT tape-in mode (read live)
                                   //   [4] = Covox mono (read live; ON = mono)
                                   //   [7] = SMK512 enable
                                   //   [1], [2], [5], [6] = unused
    input  logic        pSltRst_n, // reset button (slot RESET net; low = pressed)

    // ---- PS/2 keyboard (receive-only; pins pulled up, driven Z) ----------
    inout  wire         pPs2Clk,
    inout  wire         pPs2Dat,

    // ---- USB HID host (the side USB-A port) ------------------------------
    // Low-speed (1.5 Mb/s) D+/D-, driven straight from the pads by the
    // vendored usb_hid_host core. The board wires this connector as a real
    // host: 10k pull-downs and 33R series resistors on both lines, VBUS on
    // +5V. These are the ONLY nets here that must NOT get the .qsf's usual
    // weak pull-up - the internal ~25k against the board's 10k would idle the
    // pin at ~0.94 V, above LVTTL's 0.8 V VIL, and an empty port would read
    // indeterminate instead of the SE0 the core needs to see "disconnected".
    // The tri-state stays at the pad (these nets have no other fanout) - the
    // third intentional pad tri-state after pDac_SR and the SD pins.
    inout  wire         pUsbP,     // USBP2 = D+ (PIN_239)
    inout  wire         pUsbN,     // USBN2 = D- (PIN_238)

    // ---- MSX joystick ports -> the BK's 0177714 read word ----------------
    // Two DE-9 pads, ACTIVE LOW, in the board's index order:
    //   [0] = UP  [1] = DOWN  [2] = LEFT  [3] = RIGHT  [4] = TRG_A  [5] = TRG_B
    // Plain INPUTS, never inout: nothing here needs to drive, and a lone
    // Z-idle tri-state feeding internal logic degenerates to stuck-asserted on
    // Cyclone I (the virq_n trap). The released level comes from the QSF's weak
    // pull-ups, so an unplugged connector reads all-released = 0177714 reads 0.
    // pStrA/pStrB (DE-9 pin 8, PIN_6/PIN_15) are deliberately NOT declared - a
    // plain digital pad does not use them, so they stay reserved-tristated and
    // remain free if a pad ever turns out to need pin 8 driven.
    input  logic [5:0]  pJoyA,
    input  logic [5:0]  pJoyB,

    // ---- SD card (megasd slot; the SMK512 HDD backing store) -------------
    // SPI-mode roles per esemsx3: DAT3 = chip select, CMD = MOSI,
    // DAT0 = MISO; DAT1/DAT2 unused (weak pull-ups in the QSF, driven Z -
    // pad-only tri-states like pDac_SR, never internal logic).
    output logic        pSd_Ck,
    output logic        pSd_Cm,
    inout  wire  [3:0]  pSd_Dt,

    // ---- VGA (6-bit R-2R DAC per channel, negative syncs) ----------------
    output logic        pVideoHS_n,
    output logic        pVideoVS_n,
    output logic [5:0]  pDac_VR,
    output logic [5:0]  pDac_VG,
    output logic [5:0]  pDac_VB,

    // ---- Sound (6-bit R-2R DAC per channel) ------------------------------
    // TRUE STEREO: the two ladders are independent channels, carrying the
    // noise-shaped output of the audio mixer (see src/audio/). The right
    // channel doubles as the CMT (cassette) jack while CMT mode is on
    // (DIP 4): pDac_SR[5] = tape input, [3:1] the ladder Schmitt-feedback
    // network, [0] = tape out (the RAW speaker bit, never audio) - esemsx3's
    // CmtScro scheme; the LEFT ladder then carries the L+R mono fold.
    output logic [5:0]  pDac_SL,
    inout  wire  [5:0]  pDac_SR,

    // ---- SDRAM (16-bit SDR, 13 row / 9 col / 2 bank, CL2) ---------------
    output logic        pMemClk,   // SDRAM chip clock (PLL extclk0)
    output logic        pMemCke,
    output logic        pMemCs_n,
    output logic        pMemRas_n,
    output logic        pMemCas_n,
    output logic        pMemWe_n,
    output logic        pMemUdq,   // upper-byte mask (DQM[1])
    output logic        pMemLdq,   // lower-byte mask (DQM[0])
    output logic        pMemBa0,
    output logic        pMemBa1,
    output logic [12:0] pMemAdr,
    inout  wire  [15:0] pMemDat
);

    // PLL: 21.477 MHz -> 96.65 MHz (x9 / 2), on clk0 (internal, global) and
    // extclk0 (the dedicated external-clock pin -> pMemClk). Routing the chip
    // clock straight off the PLL keeps it phase-matched to the controller's
    // command/data outputs, exactly as the upstream OCM design does (pll4x e0).
    // Direct WYSIWYG altpll instance, so no MegaWizard .qip is needed.
    localparam int PLL_MULT        = 9;
    localparam int PLL_DIV         = 2;
    localparam int INCLK_PERIOD_PS = 46554;   // 21.47727 MHz, in 1/1000 MHz units

    // ---- clocks + reset -------------------------------------------------
    logic sys_clk;          // 96.65 MHz VCO output (clk0)
    logic pix_clk;          // 64.43 MHz pixel clock (clk1 = VCO / 3)
    logic cpu_clk;          // 3.02 / 4.03 MHz CPU clock -> pin_clk_p
    logic cpu_clk_n;        // inverted CPU clock      -> pin_clk_n
    logic dot_ena;          // 12.08 MHz enable strobe (spare)
    logic usb_clk;          // 12.08 MHz 50% duty clock -> usb_hid_host
    logic en_pos, en_neg;   // ÷16 037 CLKIN enables (on CPU edges in /32 mode;
                            // see va_037_sync and cpu_clkgen)
    logic dclo_n;           // CPU reset  (active low) - released first
    logic aclo_n;           // power-fail (active low) - released later
    logic locked;           // PLL locked
    logic init_done;        // SDRAM initialisation complete

    // --- PLL ------------------------------------------------------------
    // altpll is an Altera primitive, not simulatable under Icarus, so the PLL
    // is validated at fit time (must lock); the divided CPU clock and the core
    // logic are covered by the cosim testbenches driven with plain clocks.
    logic [5:0] sub_wire_clk;
    logic [3:0] sub_wire_extclk;
    altpll #(
        .bandwidth_type         ("AUTO"),
        .clk0_divide_by         (PLL_DIV),
        .clk0_duty_cycle        (50),
        .clk0_multiply_by       (PLL_MULT),
        .clk0_phase_shift       ("0"),
        .clk1_divide_by         (3),               // x9 / 3 = 64.43 MHz pixel
        .clk1_duty_cycle        (50),
        .clk1_multiply_by       (PLL_MULT),
        .clk1_phase_shift       ("0"),
        .extclk0_divide_by      (PLL_DIV),
        .extclk0_duty_cycle     (50),
        .extclk0_multiply_by    (PLL_MULT),
        .extclk0_phase_shift    ("0"),
        .compensate_clock       ("CLK0"),
        .inclk0_input_frequency (INCLK_PERIOD_PS),
        .intended_device_family ("Cyclone"),
        .lpm_type               ("altpll"),
        .operation_mode         ("NORMAL"),
        .pll_type               ("AUTO"),
        .port_clk0              ("PORT_USED"),
        .port_clk1              ("PORT_USED"),
        .port_extclk0           ("PORT_USED"),
        .port_inclk0            ("PORT_USED"),
        .port_locked            ("PORT_USED")
    ) altpll_inst (
        .inclk  ({1'b0, pClk21m}),
        .clk    (sub_wire_clk),
        .extclk (sub_wire_extclk),
        .locked (locked),
        .areset (1'b0)
    );
    assign sys_clk = sub_wire_clk[0];
    assign pix_clk = sub_wire_clk[1];
    assign pMemClk = sub_wire_extclk[0];

    // --- model select: DIP 1 (ON = low = BK-0011M) --------------------------
    // Latched while DCLO is held - power-on AND the reset button's warm-reset
    // hold, so the model switches with a warm reset, no power cycle - and
    // frozen while the CPU runs: a mid-run DIP flip never reaches the live
    // CPU-clock divider. The divider itself retargets glitch-free during the
    // hold (cpu_clkgen's >= wrap; the reset sequencer below just sees its
    // cpu_clk period change between edges). dclo_n is a quasi-static
    // cpu_clk-domain FF, 2-FF resynced here; pDip is a static switch.
    // --- SMK512 enable: DIP 8 (ON = low = SMK present) ----------------------
    // The identical DCLO-hold latch: model and SMK config switch together on
    // a warm reset. Independent of DIP 1 - the SMK is an МПИ expansion board
    // and works on BOTH models (BkEmu BK_0010_SMK512 / BK_0011M_SMK512; see
    // the mem_mapper header for the per-model layout table). DIP-8-ON boots
    // the SMK BIOS in either model (the SYS rom7 register-space overlay
    // redirects the 177716 start vector to 166400); flip DIP 8 off and press
    // reset to return to a stock machine.
    logic [1:0] dipm_sr, dips_sr, dclo_sr;
    logic       model_bk11, smk_en;
    always_ff @(posedge sys_clk or negedge locked) begin
        if (!locked) begin
            dipm_sr    <= 2'b00;
            dips_sr    <= 2'b00;
            dclo_sr    <= 2'b00;
            model_bk11 <= 1'b0;
            smk_en     <= 1'b0;
        end else begin
            dipm_sr <= {dipm_sr[0], ~pDip[0]};
            dips_sr <= {dips_sr[0], ~pDip[7]};
            dclo_sr <= {dclo_sr[0], dclo_n};
            if (!dclo_sr[1]) begin
                model_bk11 <= dipm_sr[1];
                smk_en     <= dips_sr[1];
            end
        end
    end

    // --- divider chain off the 96.65 MHz VCO (cpu_clkgen): the fixed /16
    //     dot/037-CLKIN enables + the model-selected /32 (BK-0010, 3.02 MHz)
    //     or /24 (BK-0011M, 4.03 MHz) CPU clock, or /16 (6.04 MHz) in turbo.
    //     In /32 mode the CPU edges fire ON the en_pos/en_neg strobes
    //     (CPU=CLKIN/2), matching the reference CPU:037 phase (see
    //     va_037_sync); sim/clkgen_tb pins those /32 waveforms exactly, so
    //     BK-0010 timing cannot move.
    cpu_clkgen u_clkgen (
        .sys_clk    (sys_clk),
        .rst_n      (locked),
        .model_bk11 (model_bk11),
        .turbo      (turbo_eff),       // PS/2 F12: /16 = 6.04 MHz, overrides model
        .cpu_clk    (cpu_clk),
        .cpu_clk_n  (cpu_clk_n),
        .dot_ena    (dot_ena),
        .usb_clk    (usb_clk),
        .en_pos     (en_pos),
        .en_neg     (en_neg)
    );

    // --- SDRAM-domain reset (release a couple sys_clk after PLL lock) ----
    logic srst_n_meta, srst_n;
    always_ff @(posedge sys_clk or negedge locked) begin
        if (!locked) {srst_n_meta, srst_n} <= 2'b00;
        else         {srst_n_meta, srst_n} <= {1'b1, srst_n_meta};
    end

    // --- pixel-domain reset (held until SDRAM init; init_done 2-FF synced) ---
    logic [1:0] prst_sr;
    always_ff @(posedge pix_clk or negedge locked) begin
        if (!locked) prst_sr <= 2'b00;
        else         prst_sr <= {prst_sr[0], init_done};
    end
    wire pix_rst_n = prst_sr[1];

    // --- screen_mode: toggled by the PS/2 Print Screen key (power-on default =
    //     colour-256). key_scrmode is a quasi-static cpu_clk toggle (u_tr,
    //     below) 2-FF resynced into sys_clk here. Survives warm reset (real-BK
    //     monitor-switch fidelity), like the video pipeline. DIP 1 is now free.
    logic       key_scrmode;
    logic [1:0] smode_sr;
    always_ff @(posedge sys_clk) smode_sr <= {smode_sr[0], key_scrmode};
    wire screen_mode = smode_sr[1];

    // --- cmt_mode: DIP 4 (ON = low = CMT tape-in; ~pDip[3], the ON=low
    //     convention shared with DIP 1/DIP 8 above). Read LIVE - a 2-FF
    //     resync of the static switch into sys_clk - so flipping DIP 4
    //     changes the mode without a reset (CMT never touches the CPU, unlike
    //     the DCLO-latched model/SMK DIPs). Do NOT gate CMT on the 177716
    //     motor bit instead: real BK software writes bit 7 = 0 outside tape
    //     ops, which kills the right audio channel (see bk_audio.sv).
    logic [1:0] cmt_sr;
    always_ff @(posedge sys_clk) cmt_sr <= {cmt_sr[0], ~pDip[3]};
    wire cmt_mode = cmt_sr[1];

    // --- tone_en: DIP 5, the audio self-test tone - RETIRED FROM THE SHIPPED
    //     BUILD (2026-07-31). It was a DIAGNOSTIC, never a user feature: a
    //     440 Hz reference on both channels plus a 1567 Hz right-only tone
    //     whose level stepped down 6 dB every ~0.7 s through levels BELOW one
    //     ladder step - the by-ear demonstration that the noise-shaped DAC
    //     resolves finer than its six physical bits. It did its job: the
    //     resolution claim was measured off the jacks and is confirmed
    //     (sim/audio/README.md). A debug feature does not ship, so bk_audio is
    //     now instantiated with TONE_ENABLE = 0 and this DIP is FREE.
    //
    //     The wiring is deliberately LEFT IN PLACE rather than deleted, so
    //     restoring the diagnostic is the one-token change the docs promise:
    //     flip TONE_ENABLE back to 1'b1 at the instance below. At 0 the tone
    //     slots hold constant zero and the fitter strips this resync, the
    //     generator and dbg_tone entirely - it costs nothing to keep. See also
    //     the bringup-audio-sweep branch, which turns this same source into a
    //     100 Hz -> 100 kHz response sweep.
    logic [1:0] tone_sr;
    always_ff @(posedge sys_clk) tone_sr <= {tone_sr[0], ~pDip[4]};
    wire tone_en = tone_sr[1];

    // --- cx_mono: DIP 5 again, its SHIPPED meaning since Phase 12 - the
    //     Covox mono/stereo switch (OFF = stereo, ON = mono, i.e. the right
    //     channel takes the left byte). Same live 2-FF resync and for the same
    //     reason: the Covox never touches the CPU, so flipping it needs no
    //     reset.
    //
    //     A SEPARATE NAME rather than reusing tone_en, deliberately. The two
    //     are mutually exclusive by BUILD CONFIGURATION, not by wiring: at the
    //     shipped TONE_ENABLE = 0 the fitter strips tone_en entirely and this
    //     pin is the Covox's alone, while a TONE_ENABLE = 1 diagnostic build
    //     gets the self-test AND forces Covox mono - harmless, because the
    //     tone mutes the Covox slots anyway (see bk_audio's slot_en). Sharing
    //     one wire would have hidden that and made the one-token diagnostic
    //     switch a landmine.
    //
    //     WHY A SWITCH AND NOT BkEmu'S AUTODETECT: BkEmu latches stereo on a
    //     word write whose inverted high byte is neither 0x00 nor 0xFF and
    //     decays back to mono after 3 s. Both halves exist because a BkEmu
    //     device object outlives the program that programmed it - the same
    //     argument that made Phase 11 drop the TurboSound dead-man timeout.
    //     Consequence, documented in README: a mono-only program writes the
    //     low lane only, so with DIP 5 OFF the right channel carries whatever
    //     the high lane holds. That is what the switch is for.
    logic [1:0] cxm_sr;
    always_ff @(posedge sys_clk) cxm_sr <= {cxm_sr[0], ~pDip[4]};
    wire cx_mono = cxm_sr[1];

    // --- turbo: toggled by the PS/2 F12 key, power-on default OFF.
    //     Same quasi-static cpu_clk toggle + 2-FF resync as screen_mode above,
    //     and it likewise SURVIVES a warm reset (it is a user setting, not
    //     machine state). Turbo takes the CPU to /16 = 6.04 MHz AND tells the
    //     037 to stop owning RAM (no_steal), which is the half that actually
    //     makes it fast - see qbus_pkg's N_TURBO.
    //
    //     THE EXTRA STEP screen_mode DOES NOT NEED: the effective level only
    //     moves while the Q-bus is IDLE, because turbo swaps the RAM reply
    //     OWNER between the 037 and qbus_mem and a mid-transaction swap can
    //     leave a cycle neither of them answers -> qbto -> a spurious trap 4
    //     under the running program. That (plus the 2-FF resync) is
    //     src/sys/turbo_ctl.sv - a real module, not inline logic, so the tbs
    //     instantiate it instead of replicating it (the cpu_clkgen drift
    //     lesson). Instantiated with the Q-bus nets further down, since a net
    //     must not be used before its declaration.
    logic       key_turbo;
    logic       turbo_eff;

    // --- EPCS boot loader (flash blob -> SDRAM ROM region, before CPU release)
    logic        boot_active, boot_done, boot_ok;
    logic        bw_req, bw_gnt;
    logic [23:0] bw_addr;
    logic [15:0] bw_wdata;
    logic        spi_dclk, spi_ncs, spi_mosi, spi_miso;

    epcs_boot u_boot (
        .clk        (sys_clk),
        .rst_n      (srst_n),
        .start      (init_done),
        .spi_dclk   (spi_dclk),
        .spi_ncs    (spi_ncs),
        .spi_mosi   (spi_mosi),
        .spi_miso   (spi_miso),
        .bw_req     (bw_req),
        .bw_addr    (bw_addr),
        .bw_wdata   (bw_wdata),
        .bw_gnt     (bw_gnt),
        .boot_active(boot_active),
        .boot_done  (boot_done),
        .boot_ok    (boot_ok)
    );

    // Dedicated serial-flash access block (DCLK/nCSO/ASDO/DATA0 config pins are
    // reachable only through this primitive; qsf already reserves ASDO).
    cyclone_asmiblock u_asmi (
        .dclkin   (spi_dclk),
        .scein    (spi_ncs),
        .sdoin    (spi_mosi),
        .oe       (1'b0),
        .data0out (spi_miso)
    );

    // --- authentic DRAM power-on pattern fill (ram_init) --------------------
    // Fills the model's RAM region in SDRAM with the К565РУ6/РУ5 power-on
    // garbage pattern (bkemu-QT InitMemoryValues) at power-on and on a
    // model-change warm reset, so the BK startup screen looks like real
    // hardware instead of undefined SDRAM noise. Shares arbiter port 0 with the
    // EPCS loader through the 2:1 mux below - the two never overlap (the fill
    // starts only after boot_done, still inside the DCLO hold). fill_busy holds
    // the CPU until the fill completes (see the reset sequencer); blank_pulse
    // blacks out the display on a model-change re-fill (see fb_video below).
    logic        fi_req, fi_gnt, fill_active, fill_busy, blank_pulse;
    logic [23:0] fi_addr;
    logic [15:0] fi_wdata;

    ram_init u_raminit (
        .clk        (sys_clk),
        .rst_n      (srst_n),
        .model_bk11 (model_bk11),
        .enable     (boot_done & ~boot_active),
        .w_req      (fi_req),
        .w_addr     (fi_addr),
        .w_wdata    (fi_wdata),
        .w_gnt      (fi_gnt),
        .fill_active(fill_active),
        .fill_busy  (fill_busy),
        .blank_pulse(blank_pulse)
    );

    // 2:1 port-0 writer mux: the EPCS loader first, then the pattern fill. The
    // OR-ed boot_active keeps qbus_mem's boot-writer mux selected for both, so
    // qbus_mem is unchanged (the module-level oracles never see this path).
    wire         mem_boot_active = boot_active | fill_active;
    wire         mem_bw_req      = fill_active ? fi_req   : bw_req;
    wire [23:0]  mem_bw_addr     = fill_active ? fi_addr  : bw_addr;
    wire [15:0]  mem_bw_wdata    = fill_active ? fi_wdata : bw_wdata;
    wire         mem_bw_gnt;
    assign bw_gnt = mem_bw_gnt & ~fill_active;   // grant back to the active writer
    assign fi_gnt = mem_bw_gnt &  fill_active;

    // --- init_done + boot_done + boot_ok synced into the CPU-clock domain ---
    // ROM is always the loaded SDRAM image: there is no on-chip fallback, so a
    // failed EPCS boot (boot_ok=0) holds the CPU in reset forever (the reset
    // sequencer below gates on bo_sync). Quasi-static: all settle before the
    // CPU leaves reset. boot_ok is valid by the time boot_done rises.
    logic id_meta, id_sync;
    always_ff @(posedge cpu_clk or negedge locked) begin
        if (!locked) {id_meta, id_sync} <= 2'b00;
        else         {id_meta, id_sync} <= {init_done, id_meta};
    end
    logic bd_meta, bd_sync;
    always_ff @(posedge cpu_clk or negedge locked) begin
        if (!locked) {bd_meta, bd_sync} <= 2'b00;
        else         {bd_meta, bd_sync} <= {boot_done, bd_meta};
    end
    logic bo_meta, bo_sync;
    always_ff @(posedge cpu_clk or negedge locked) begin
        if (!locked) {bo_meta, bo_sync} <= 2'b00;
        else         {bo_meta, bo_sync} <= {boot_ok, bo_meta};
    end
    // ram_init's fill_busy (sys_clk) synced in: it holds the CPU past the
    // warm-reset tail until the pattern fill finishes. Quasi-static (asserts
    // once at power-on/model-change, drops once at completion); the SDC
    // false-paths the sys_clk<->cpu_clk crossing.
    logic fb_meta, fb_sync;
    always_ff @(posedge cpu_clk or negedge locked) begin
        if (!locked) {fb_meta, fb_sync} <= 2'b00;
        else         {fb_meta, fb_sync} <= {fill_busy, fb_meta};
    end

    // --- soft reset: the reset button (slot RESET net, external pull-up) -----
    // Pressed (low) = warm_rst_req held; released = a 2^16-cpu_clk (~21.7 ms)
    // debounce tail, then the sequencer below re-runs the normal DCLO->ACLO
    // release. Everything DCLO-keyed re-initialises; SDRAM init, the EPCS load
    // and memory contents are untouched (BK hardware-reset semantics). Bounce
    // just reloads the tail - idempotent. A keyboard reset chord would OR
    // into warm_rst_req when it exists.
    logic [1:0]  btn_sr;
    logic [15:0] warm_cnt;
    always_ff @(posedge cpu_clk or negedge locked) begin
        if (!locked) begin
            btn_sr   <= 2'b11;       // released
            warm_cnt <= '0;
        end else begin
            btn_sr <= {btn_sr[0], pSltRst_n};
            if (!btn_sr[1])         warm_cnt <= 16'hFFFF;
            else if (warm_cnt != 0) warm_cnt <= warm_cnt - 1'b1;
        end
    end
    wire warm_rst_req = (warm_cnt != 16'd0);

    // --- reset sequencer (on cpu_clk; held until SDRAM init + ROM load done,
    //     re-entered by the reset button for a warm restart) -------------------
    logic [3:0] rstc;
    always_ff @(posedge cpu_clk or negedge locked) begin
        if (!locked) begin
            rstc   <= 4'd0;
            dclo_n <= 1'b0;
            aclo_n <= 1'b0;
        end else if (!id_sync || !bd_sync || !bo_sync || warm_rst_req || fb_sync) begin
            rstc   <= 4'd0;          // hold CPU in reset until SDRAM init + a
                                     // VALID ROM load (bo_sync) + the RAM
                                     // pattern fill (fb_sync); a failed EPCS
                                     // boot holds here forever (no on-chip ROM)
            dclo_n <= 1'b0;
            aclo_n <= 1'b0;
        end else begin
            if (rstc != 4'hF) rstc <= rstc + 1'b1;
            dclo_n <= (rstc >= 4'd8);    // release DCLO after 8 CPU clocks
            aclo_n <= (rstc >= 4'd12);   // release ACLO 4 clocks after DCLO
        end
    end

    // --- video reset: POWER-ON ONLY (real-BK fidelity) ------------------------
    // On a real BK the display controller is not affected by a DCLO/ACLO CPU
    // reset - the screen keeps showing video RAM until MONITOR clears it. So
    // the 037 and fb_video are held in reset only until the FIRST DCLO release
    // (bit-identical cold boot) and then free-run across warm resets: the
    // picture stays up while the reset button is held. The bus-side 037 FSMs
    // are strobe-driven and settle to idle while the CPU tri-states the bus
    // (the warm-reset replay oracles in sim/ref037 pin this).
    logic vid_alive;
    always_ff @(posedge cpu_clk or negedge locked) begin
        if (!locked)     vid_alive <= 1'b0;
        else if (dclo_n) vid_alive <= 1'b1;    // first release; never cleared
    end
    wire vid_rst_n = dclo_n | vid_alive;

    // ---- shared Q-bus (inverted, active low; pull-up = released) --------
    tri1 [15:0] ad_n;
    tri1        sync_n, din_n, dout_n, wtbt_n, rply_n;
    tri1        init_n, dmr_n, sack_n, iako_n;
    wire        virq_n;             // push-pull: bk_kbd014 (sole VIRQ source) -> vm1
                                     // (NOT tri1 - a lone Z-idle OC net degenerates to
                                     // stuck-asserted on Cyclone I; see bk_kbd014 footer)
    wire        dmgo_n, bsy_n;

    // turbo, resynced and qualified on a BUS-IDLE edge (see turbo_ctl.sv and
    // the key_turbo block above). Power-on reset only: turbo is a user setting
    // and survives the reset button, like screen_mode.
    turbo_ctl u_turbo (
        .sclk     (sys_clk),
        .rst_n    (locked),
        .key_turbo(key_turbo),
        .sync_n   (sync_n),
        .din_n    (din_n),
        .dout_n   (dout_n),
        .turbo    (turbo_eff)
    );

    wire [2:1]  sel_n;              // CPU nSEL1/nSEL2 (177716/177714 selects) ->
                                     // qbus_mem; push-pull from the vm1.v local
                                     // hook, same rationale as virq_n above
    wire        nbs_n;              // 037 keyboard-block select (177660-177663)

    // RAM RPLY + its cycle-stealing timing come from the retimed 037; ROM/IO reply
    // from qbus_mem. The 037's RPLY (hard-driven) is re-timed onto the CPU clock's
    // falling edge by bk_rply - the board's D8:B flop, which on a real BK stands
    // between the bus RPLY net and the CPU's RPLY pin (see bk_rply.sv for why ONLY
    // the 037's reply goes through it) - and then converted to open-collector here
    // so it wire-ANDs onto the shared rply_n. mem_ready is the RAM SDRAM done-gate.
    wire        rply037_n;      // raw, from the 037
    wire        rply037_rt_n;   // re-timed by D8:B
    wire        mem_ready;
    wire        mem_ext_ram;   // qbus_mem: BK-0011M window-1 banked RAM -> 037 a15 force

    bk_rply u_rply (
        .cpu_clk   (cpu_clk),
        .rst_n     (vid_rst_n),      // power-on only, like the 037 itself
        .rply_037_n(rply037_n),
        .rply_n    (rply037_rt_n)
    );
    assign rply_n = (rply037_rt_n === 1'b0) ? 1'b0 : 1'bZ;

    // 037 video-side taps consumed by the video pipeline below
    wire        vid_fetch, vid_pal_stb, vid_line_en, hgate, vgate;
    wire [13:1] video_va;
    // 037 pins driving the EVNT/IRQ2 detector (see bk_evnt.sv)
    wire        wti_037, synco_037;

    va_037_sync u_037 (
        .clk       (sys_clk),
        .en_pos    (en_pos),
        .en_neg    (en_neg),
        .mem_ready (mem_ready),
        .ext_ram   (mem_ext_ram),      // BK-0011M window-1 banked RAM -> force A15 low
        .no_steal  (turbo_eff),        // turbo: stop owning RAM (qbus_mem replies)
        .PIN_R     (~vid_rst_n),       // power-on reset only: free-runs across warm resets
        .PIN_C     (1'b0),
        .PIN_nAD   (ad_n),
        .PIN_nSYNC (sync_n),
        .PIN_nDIN  (din_n),
        .PIN_nDOUT (dout_n),
        .PIN_nWTBT (wtbt_n),
        .PIN_nRPLY (rply037_n),
        .PIN_A     (),                 // DRAM-mux pins unused (RAM is in SDRAM)
        .PIN_nCAS  (),
        .PIN_nRAS  (),
        .PIN_nWE   (),
        .PIN_nE    (),
        .PIN_nBS   (nbs_n),         // keyboard-controller select -> bk_kbd014
        .PIN_WTI   (wti_037),       // -> bk_evnt (EVNT/IRQ2 detector)
        .PIN_WTD   (),
        .PIN_nVSYNC(synco_037),     // -> bk_evnt (the 037's SYNCO pin)
        .cpu_grant (),
        .video_va  (video_va),
        .vid_fetch (vid_fetch),
        .vid_pal_stb(vid_pal_stb),
        .vid_line_en(vid_line_en),
        .hgate     (hgate),
        .vgate     (vgate)
    );

    // ---- keyboard: PS/2 -> translator -> 1801ВП1-014 equivalent
    // All on cpu_clk: the PS/2 clock is ~100x oversampled through the 2-FF
    // syncs inside ps2_rx - no new clock domain. The pins stay tri-stated
    // (receive-only). bk_kbd014 serves 177660/177662 + the VIRQ/IAK vector,
    // netlist-contract-validated by sim/ref014; its registers reset on the
    // nINIT line (RESET instruction included), the translator state (caps
    // trigger, РУС/ЛАТ shadow) is power-on only - as the real BK's external
    // trigger, it survives INIT and warm reset.
    assign pPs2Clk = 1'bZ;
    assign pPs2Dat = 1'bZ;

    logic [7:0] ps2_byte;
    logic       ps2_stb;
    logic       key_stb, key_ar2, key_down, key_stop;
    logic [6:0] key_code;

    ps2_rx u_ps2 (
        .clk       (cpu_clk),
        .ps2_clk_i (pPs2Clk),
        .ps2_dat_i (pPs2Dat),
        .byte_o    (ps2_byte),
        .stb_o     (ps2_stb)
    );

    kbd_ps2bk u_tr (
        .clk      (cpu_clk),
        .aclo_n   (aclo_n),        // caps/РУС-ЛАТ reset on ACLO (power-on + reset button)
        .ps2_byte (ps2_byte),
        .ps2_stb  (ps2_stb),
        .key_stb  (key_stb),
        .key_code (key_code),
        .key_ar2  (key_ar2),
        .key_down (key_down),
        .key_stop (key_stop),
        .key_scrmode (key_scrmode),  // Print Screen -> screen_mode toggle
        .key_turbo   (key_turbo)     // F12 -> turbo toggle (see turbo_eff above)
    );

    bk_kbd014 u_kbd (
        .clk_fsm  (cpu_clk_n),
        .clk_p    (cpu_clk),
        .init_n   (init_n),
        .ad_n     (ad_n),
        .sync_n   (sync_n),
        .din_n    (din_n),
        .dout_n   (dout_n),
        .cs_n     (nbs_n),
        .iako_n   (iako_n),
        .rply_n   (rply_n),
        .virq_n   (virq_n),
        .key_stb  (key_stb),
        .key_code (key_code),
        .key_ar2  (key_ar2),
        .key_down (key_down)
    );

    // СТОП -> nIRQ1 fixed-length one-shot (STOP_PULSE cpu_clk wide, launched
    // on the rising edge - the pin-sync rule; the same width and shape the
    // sim/ref014 interrupt oracle pinned). On a real BK-0010 with BASIC the
    // net effect is trap 4: the HALT entry's 177674/676 stores time out.
    // BK-0011M: the launch is gated by the 177716 bit-12
    // СТОП-enable latch (stop_block, captured in u_mem on sclk - see there
    // for the pinned contract). 2-FF resync onto cpu_clk (quasi-static: it
    // only moves during a 177716 DOUT window); no model_bk11 term needed -
    // in bk10 mode the latch never captures and holds 0 (DCLO reset), so the
    // gate is transparent and bk10 behaviour is bit-identical.
    logic       stop_block;         // sclk domain, from u_mem below
    logic [1:0] stop_blk_sr = '0;
    always_ff @(posedge cpu_clk) stop_blk_sr <= {stop_blk_sr[0], stop_block};
    localparam int unsigned STOP_PULSE = 64;
    logic [6:0] stop_cnt = '0;
    always_ff @(posedge cpu_clk) begin
        if (key_stop && !stop_blk_sr[1]) stop_cnt <= 7'(STOP_PULSE);
        else if (stop_cnt != 0)          stop_cnt <= stop_cnt - 1'b1;
    end
    wire stop_pulse = (stop_cnt != 0);

    // EVNT/IRQ2 (BK-0011M): the 50 Hz frame interrupt, generated by
    // the authentic external detector (src/peripheral/bk_evnt.sv - the
    // D28 + D3:B missing-pulse pair off the 037's WTI and SYNCO pins).
    // Do NOT simplify this to "nIRQ2 = vgate" (MiSTer's model): that fires
    // 452 CLKIN (~75 us, ~1.18 scanlines, ~301 cpu_clk) too early - a fixed
    // displacement of every beam-raced multicolor/gigascreen effect. See
    // bk_evnt.sv for the schematic trace and the measured offsets.
    //
    // The enable term is the async clear of the request flop (as on the board,
    // where it is the 662 register bit driving D3:B's R pin). BK-0010 has no
    // IRQ2 source at all (BkEmu and MiSTer agree), so model_bk11 holds the
    // whole detector cleared in bk10 mode. The 662 mask resets to 1 on DCLO,
    // so the line stays silent until software unmasks.
    //
    // bk_evnt's output is already sys_clk-registered; the 2-FF onto posedge
    // cpu_clk below is the pin-sync rule, and is authentic too - the real
    // board re-times IRQ2 through D11 (К555ТМ9) on CLC. The vm1's own arm/fire
    // edge detector turns the level into one vector-0100 interrupt per frame.
    logic       vid_irq2_mask;  // 177662 bit 14 (1 = masked), captured in u_mem
    logic       irq2_lvl;

    bk_evnt u_evnt (
        .sys_clk (sys_clk),
        .rst_n   (vid_rst_n),   // power-on only, like the rest of the video side
        .wti     (wti_037),
        .synco   (synco_037),
        .irq_en  (model_bk11 & ~vid_irq2_mask),
        .evnt    (irq2_lvl)
    );

    logic [1:0] irq2_sr;
    always_ff @(posedge cpu_clk) irq2_sr <= {irq2_sr[0], irq2_lvl};

    // ---- vm1 core (1801ВМ1) ---------------------------------------------
    vm1 u_cpu (
        .pin_clk_p (cpu_clk),
        .pin_clk_n (cpu_clk_n),
        .pin_ena   (1'b1),
        .pin_pa_n  (2'b11),         // processor number (as in bk10_tb)
        .pin_sp_n  (1'b1),          // timer input idle
        .pin_init_n(init_n),
        .pin_dclo_n(dclo_n),
        .pin_aclo_n(aclo_n),
        .pin_irq_n ({1'b1, ~irq2_sr[1], ~stop_pulse}),  // nIRQ1 = СТОП one-shot,
                                            // nIRQ2 = 50 Hz frame EVNT (bk11)
        .pin_virq_n(virq_n),        // vectored interrupt: keyboard (bk_kbd014)
        .pin_ad_n  (ad_n),
        .pin_dout_n(dout_n),
        .pin_din_n (din_n),
        .pin_wtbt_n(wtbt_n),
        .pin_sync_n(sync_n),
        .pin_rply_n(rply_n),
        .pin_dmr_n (dmr_n),
        .pin_sack_n(sack_n),
        .pin_dmgi_n(1'b1),          // no DMA grant in
        .pin_dmgo_n(dmgo_n),
        .pin_iako_n(iako_n),
        .pin_sel_n (sel_n),
        .pin_bsy_n (bsy_n)
    );

    // ---- memory subsystem: ROM/IO on-chip (N_ROM) + RAM datapath in SDRAM
    //      (cpu_sdram_dp + sdram_arbiter + sdram_ctrl). RAM RPLY is owned by the 037
    //      above via mem_ready; this block drives rply_n only for ROM/IO. ----------
    // video client wires (blocks instantiated below u_mem)
    wire        f_req, f_gnt, f_rvalid, w_req, w_gnt;
    wire [23:0] f_addr, w_addr;
    wire [15:0] w_wdata, v_rdata;
    wire        ro_req, ro_gnt, ro_rvalid;
    wire [23:0] ro_addr;

    wire [15:0] bus_addr;
    wire        fetch_stb;
    wire        spk_bit;       // BK speaker level (bit 6 of last 177716 write)
    // The 177714 (nSEL2) parallel-port capture - the seam the future sound
    // devices attach to. Deliberately unconsumed in this build.
    wire        snd_port_wr;
    wire [15:0] snd_port_data;
    wire        snd_port_word;
    wire [1:0]  snd_port_be;
    wire        tape_lvl;      // CMT comparator level (sys_clk, from bk_audio)
    wire        vid_page;      // 177662 bit 15 (bk11): displayed screen page
    wire [3:0]  vid_pal;       // 177662 bits 11:8 (bk11): palette index

    // tape_lvl -> 177716 read bit 5: 2-FF resync onto the qbus_mem FSM clock
    // (cpu_clk_n). Quasi-static at tape rates (~1 kHz half-periods).
    logic [1:0] tape_sr = '0;
    always_ff @(posedge cpu_clk_n) tape_sr <= {tape_sr[0], tape_lvl};

    // ---- MSX joysticks -> the 0177714 read word --------------------------
    // A pure level translator: the MSX active-low inversion, the MSX -> BkEmu
    // bit remap (the two direction nibbles are different permutations), and a
    // 2-FF sync onto cpu_clk_n - the same clock and the same reasoning as the
    // tape_sr resync above, and the clock qbus_mem's read FSM runs on. No
    // reset: a passive switch matrix has none. See bk_joystick.sv.
    wire [15:0] joy_pads;
    bk_joystick u_joy (
        .clk      (cpu_clk_n),
        .pad_a_n  (pJoyA),
        .pad_b_n  (pJoyB),
        .joy_word (joy_pads)
    );

    // The 0177714 read word is the pads OR the Marsianka mouse (u_mouse, below
    // the USB host - it needs that block's signals). With no USB mouse
    // enumerated mouse_word is 0, so this is transparent: the pads read exactly
    // as they did before the mouse existed, and qbus_mem is untouched. A pad on
    // DE-9 port B and a USB mouse can therefore be used at once; the mouse's
    // buttons do land on port A's trigger bits, which is unavoidable because on
    // a real BK it is the same connector.
    // Both are driven by the USB block further down (u_usb / u_mouse), which
    // has to sit after the signals it consumes; declared here because the read
    // word and the Covox mute are both needed above it.
    wire [15:0] mouse_word;
    wire        cx_mouse_mute;
    wire [15:0] joy_word = joy_pads | mouse_word;

    // ---- SMK512 IDE controller --------------------------------------------
    // A sibling peripheral like u_kbd: it snoops the shared bus itself and
    // never drives it - qbus_mem's sel_ide decode owns the RPLY and merges
    // ide_rdata at its reply point. All sclk; reset is DCLO-only (BkEmu
    // resets the IDE on hardware reset only - the 5th deliberate nINIT
    // exception; software resets ride the SRST control-register bit).
    // The backend sector port is served by the increment-(b) SD/SPI engine
    // below: the card in the megasd slot holds the raw AltPro image at
    // LBA 0; with no/failed card the drive reports cleanly ABSENT
    // (task-file reads 0xFFFF) - identical to the increment-(a) tie-off.
    logic [15:0] ide_rdata;
    logic        ide_act;
    logic        bk_req, bk_wr, bk_bank, bk_ack, bk_done, bk_error;
    logic        bk_media_ok, bk_we;
    logic [27:0] bk_sector, bk_total;
    logic [7:0]  bk_baddr;
    logic [15:0] bk_wdata, bk_rdata;
    smk_ide u_ide (
        .sclk       (sys_clk),
        .reset      (~dclo_n),
        .enable     (smk_en),
        .ad_n       (ad_n),
        .sync_n     (sync_n),
        .din_n      (din_n),
        .dout_n     (dout_n),
        .wtbt_n     (wtbt_n),
        .ide_rdata  (ide_rdata),
        .ide_act    (ide_act),
        .bk_req     (bk_req),
        .bk_wr      (bk_wr),
        .bk_sector  (bk_sector),
        .bk_bank    (bk_bank),
        .bk_ack     (bk_ack),
        .bk_done    (bk_done),
        .bk_error   (bk_error),
        .bk_media_ok(bk_media_ok),
        .bk_total   (bk_total),
        .bk_baddr   (bk_baddr),
        .bk_wdata   (bk_wdata),
        .bk_we      (bk_we),
        .bk_rdata   (bk_rdata)
    );

    // ---- SD/SPI backend ----------------------------------------------------
    // All sys_clk (no CDC on the seam); reset = DCLO-only like smk_ide, so
    // card init re-runs at power-on AND warm reset ("insert card, press
    // reset" - the slot has no card-detect pin). enable-gated with the
    // engine: a stock machine (DIP 8 OFF / bk10) never clocks the card.
    // Pads: registered outputs only; DAT3 = CS is push-pull (a lone Z-idle
    // driver is the Cyclone-I stuck-asserted trap - the virq_n gotcha),
    // DAT2/DAT1 stay Z (pad-only tri-states, pulled up in the QSF),
    // DAT0 = MISO input.
    logic sd_cs;
    sd_backend u_sd (
        .clk        (sys_clk),
        .rst_n      (dclo_n),
        .enable     (smk_en),
        .sd_ck      (pSd_Ck),
        .sd_cs      (sd_cs),
        .sd_mosi    (pSd_Cm),
        .sd_miso    (pSd_Dt[0]),
        .bk_req     (bk_req),
        .bk_wr      (bk_wr),
        .bk_sector  (bk_sector),
        .bk_bank    (bk_bank),
        .bk_ack     (bk_ack),
        .bk_done    (bk_done),
        .bk_error   (bk_error),
        .bk_media_ok(bk_media_ok),
        .bk_total   (bk_total),
        .bk_baddr   (bk_baddr),
        .bk_wdata   (bk_wdata),
        .bk_we      (bk_we),
        .bk_rdata   (bk_rdata),
        // diagnostics unused at the top level (pruned by synthesis); they
        // exist for the sim oracles and for wiring to LEDs during bring-up
        .dbg_fail     (),
        .dbg_flush_cap(),
        .dbg_retried  ()
    );
    assign pSd_Dt[3]   = sd_cs;
    assign pSd_Dt[2:1] = 2'bzz;
    assign pSd_Dt[0]   = 1'bz;      // input only (MISO)

    qbus_mem u_mem (
        .cpu_clk  (cpu_clk_n),      // ROM/IO wait FSM advances on the inverted CPU clock
        .reset    (~dclo_n),
        .init_n   (init_n),
        .kbd_down (key_down),       // 177716 bit 6 (active low at the register)
        .tape_in  (tape_sr[1]),     // 177716 bit 5 (CMT comparator level)
        .sel1_n   (sel_n[1]),       // CPU register selects (push-pull, see the
        .sel2_n   (sel_n[2]),       //   vm1.v local hook): 177716 / 177714
        .model_bk11(model_bk11),    // DIP-1 model select (latched during DCLO
                                    //   hold above -> quasi-static here)
        .smk_en   (smk_en),         // DIP-8 SMK512 enable (same DCLO-hold latch
                                    //   as the model select above)
        .turbo    (turbo_eff),      // PS/2 F12 turbo: this FSM owns the RAM reply
                                    //   (the 037 is in no_steal) at N_TURBO
        .ide_rdata(ide_rdata),      // SMK IDE read-word merge (u_ide below)
        .joy_word (joy_word),       // 177714 read: the MSX pads (u_joy above)
        .boot_active(mem_boot_active),
        .bw_req   (mem_bw_req),
        .bw_addr  (mem_bw_addr),
        .bw_wdata (mem_bw_wdata),
        .bw_gnt   (mem_bw_gnt),
        .sclk     (sys_clk),
        .srst_n   (srst_n),
        .init_done(init_done),
        .ad_n     (ad_n),
        .sync_n   (sync_n),
        .din_n    (din_n),
        .dout_n   (dout_n),
        .wtbt_n   (wtbt_n),
        .rply_n   (rply_n),
        .mem_ready(mem_ready),
        .ext_ram  (mem_ext_ram),
        .v1_req   (ro_req),         // video clients -> arbiter ports 1/2/3
        .v1_addr  (ro_addr),
        .v1_gnt   (ro_gnt),
        .v1_rvalid(ro_rvalid),
        .v2_req   (f_req),
        .v2_addr  (f_addr),
        .v2_gnt   (f_gnt),
        .v2_rvalid(f_rvalid),
        .v3_req   (w_req),
        .v3_addr  (w_addr),
        .v3_wdata (w_wdata),
        .v3_gnt   (w_gnt),
        .v_rdata  (v_rdata),
        .s_cke    (pMemCke),
        .s_cs_n   (pMemCs_n),
        .s_ras_n  (pMemRas_n),
        .s_cas_n  (pMemCas_n),
        .s_we_n   (pMemWe_n),
        .s_ba     ({pMemBa1, pMemBa0}),
        .s_addr   (pMemAdr),
        .s_dqm    ({pMemUdq, pMemLdq}),
        .s_dq     (pMemDat),
        .bus_addr (bus_addr),
        .fetch_stb(fetch_stb),
        .spk_bit  (spk_bit),         // BK speaker: bit 6 of last 177716 write
        .mot_bit  (),                // tape motor: bit 7 (1 = stopped). Captured
                                     // and oracle-pinned but deliberately unused:
                                     // it must NOT gate CMT mode (real BK
                                     // software writes bit 7 = 0 outside tape
                                     // ops); cmt_mode comes from DIP 4.
        // ---- the 177714 sound-device seam --------------------
        // Every BK sound expansion - Covox, 2x YM2149, Menestrel - decodes
        // this one address and differs only in how it reads the data, so the
        // bus side is captured once in qbus_mem and lands here. u_ts
        // (bk_turbosound) and u_cx (bk_covox) consume it; Menestrel will
        // hang off the same wires when it lands. Devices live in src/audio/ and
        // arrive at bk_audio as extra mixer slots - see the audio bullet in
        // CLAUDE.md. The capture is oracle-pinned by spk_capture_tb driving
        // the real qbus_mem.
        .port_wr  (snd_port_wr),     // 1 sclk per 177714/15 bus write
        .port_data(snd_port_data),   // BK-true value, byte lanes merged
        .port_word(snd_port_word),   // 1 = word write (the AY's reg-vs-data)
        .port_be  (snd_port_be),     // which byte lane(s) this write carried
        .vid_page (vid_page),        // 177662 (bk11): screen page + palette; the
        .vid_pal  (vid_pal),         //   video-side muxes below consume them
        .vid_irq2_mask(vid_irq2_mask),// 177662 bit 14: frame-IRQ2 mask -> the
                                     // EVNT/IRQ2 gate above the CPU instance
        .stop_block(stop_block)      // 177716 bit 12 (bk11): СТОП blocked ->
                                     // gates the nIRQ1 one-shot launch above
    );

    // ---- Sound: sources -> mixer -> noise-shaped 6-bit DAC -> the ladders --
    // The audio subsystem lives in src/audio/: bk_audio assembles the BK
    // speaker (spk_bit, captured in u_mem on sys_clk as a software-owned
    // latch), the TurboSound and the Covox into an N-slot stereo mixer, then
    // noise-shapes each channel down to the 6-bit ladder code at sys_clk/16.
    // The shaping is what lets a 6-bit ladder resolve far finer than six bits
    // in the audio band - the seam the sound devices plug into. While CMT mode
    // is on (DIP 4, see cmt_mode above) the right channel
    // becomes the esemsx3-style CMT comparator (pDac_SR[5] input + ladder
    // feedback, [0] = the RAW speaker bit as tape-out) and the LEFT ladder
    // carries the mono fold of both channels.
    // Power-on reset only (vid_rst_n) - like the display, sound survives a
    // warm reset; spk_bit is never cleared by nINIT (software owns it).
    wire spk_active, snd_sat, snd_clip, snd_tone;
    wire [5:0] dac_r_o, dac_r_oe;

    // ---- TurboSound: 2x YM2149 ---------------------------------
    wire signed [15:0] ts_l, ts_r;
    wire               ts_act, ts_dual, ts_snd;
    bk_turbosound u_ts (
        .sys_clk   (sys_clk),
        .rst_n     (vid_rst_n),
        .init_n    (init_n),
        .port_wr   (snd_port_wr),
        .port_data (snd_port_data),
        .port_word (snd_port_word),
        .port_be   (snd_port_be),
        .ts_l      (ts_l),
        .ts_r      (ts_r),
        .ts_act    (ts_act),
        .dual_act  (ts_dual),
        .ts_snd    (ts_snd)
    );

    // ---- Covox: stereo 8-bit DAC --------------------------
    wire signed [15:0] cx_l, cx_r;
    wire               cx_en;
    bk_covox u_cx (
        .sys_clk   (sys_clk),
        .rst_n     (vid_rst_n),
        .init_n    (init_n),
        .port_wr   (snd_port_wr),
        .port_data (snd_port_data),
        .mono      (cx_mono),
        .psg_act   (ts_snd | cx_mouse_mute),   // see the mouse note above
        .cx_l      (cx_l),
        .cx_r      (cx_r),
        .cx_en     (cx_en)
    );

    // ---- Audio mixer and output --------------------------
    bk_audio #(.TONE_ENABLE (1'b0)) u_audio (
        .sys_clk    (sys_clk),
        .rst_n      (vid_rst_n),
        .spk_bit    (spk_bit),
        .cmt_mode   (cmt_mode),
        .cmt_in_pad (pDac_SR[5]),
        .tone_en    (tone_en),
        .ts_l       (ts_l),
        .ts_r       (ts_r),
        .cx_l       (cx_l),
        .cx_r       (cx_r),
        .cx_en      (cx_en),
        .tape_lvl   (tape_lvl),
        .dac_l      (pDac_SL),
        .dac_r_o    (dac_r_o),
        .dac_r_oe   (dac_r_oe),
        .active     (spk_active),
        .dbg_sat    (snd_sat),
        .dbg_clip   (snd_clip),
        .dbg_tone   (snd_tone)
    );
    // Per-bit pad tri-states (real I/O-buffer OEs at the pins - NOT the
    // internal single-driver-Z trap; nothing on-chip reads these nets except
    // the [5] input path).
    genvar gi;
    generate
        for (gi = 0; gi < 6; gi = gi + 1) begin : g_sr
            assign pDac_SR[gi] = dac_r_oe[gi] ? dac_r_o[gi] : 1'bZ;
        end
    endgenerate

    // ---- video pipeline ---------------------------------------------------
    // 037 fetch -> palette_apply -> double-buffered FB in SDRAM (fb_video,
    // arbiter ports 2+3) -> paced line prefetch (fb_readout, port 1) ->
    // dual-clock fb_linebuf -> vga_out (1024x768@60, x2H/x3V, physical-colour
    // decode - the FB nibble is {R1,B,G,R0}, see palette_apply.sv).
    import qbus_pkg::*;   // BK11_VPAGE0/1 (body import - Quartus 11.0 gotcha)

    // BK-0011M video fetch base + palette, from the 177662 register
    // captured in u_mem (sclk = sys_clk, same domain as fb_video - no CDC;
    // model_bk11 is DCLO-latched quasi-static). bk10 keeps the fixed BK 040000
    // base and palette 0 (= MiSTer def_reg662 bk10 semantics).
    wire [23:0] vram_base = !model_bk11 ? 24'h002000
                          : vid_page    ? BK11_VPAGE1 : BK11_VPAGE0;
    wire [3:0]  pal_idx   = model_bk11 ? vid_pal : 4'd0;

    wire        fb_front, fb_front_valid;
    wire        req_tgl;
    wire [7:0]  req_line;
    wire        lb_we;
    wire [9:0]  lb_waddr, lb_raddr;
    wire [3:0]  lb_wdata, lb_rdata;
    wire        ro_rst_n = srst_n & init_done;

    fb_video u_fbv (
        .clk        (sys_clk),
        .rst_n      (vid_rst_n),       // power-on only: keeps decoding across warm resets
        .blank_req  (blank_pulse),     // model-change re-fill: black out until fresh frame
        .screen_mode(screen_mode),
        .vram_base  (vram_base),
        .pal_idx    (pal_idx),
        .vid_fetch  (vid_fetch),
        .vid_pal_stb(vid_pal_stb),
        .vid_line_en(vid_line_en),
        .hgate      (hgate),
        .vgate      (vgate),
        .video_va   (video_va),
        .f_req      (f_req),
        .f_addr     (f_addr),
        .f_gnt      (f_gnt),
        .f_rvalid   (f_rvalid),
        .rdata_i    (v_rdata),
        .w_req      (w_req),
        .w_addr     (w_addr),
        .w_wdata    (w_wdata),
        .w_gnt      (w_gnt),
        .fb_front   (fb_front),
        .fb_front_valid(fb_front_valid),
        .err_fetch_ovr (),             // cosim-only violation flags
        .err_fifo_ovf  ()
    );

    fb_readout u_ro (
        .clk      (sys_clk),
        .rst_n    (ro_rst_n),
        .req_tgl  (req_tgl),
        .req_line (req_line),
        .fb_front (fb_front),
        .p_req    (ro_req),
        .p_addr   (ro_addr),
        .p_gnt    (ro_gnt),
        .p_rvalid (ro_rvalid),
        .rdata_i  (v_rdata),
        .lb_we    (lb_we),
        .lb_waddr (lb_waddr),
        .lb_wdata (lb_wdata),
        .err_line_ovr()
    );

    fb_linebuf u_lb (
        .wclk  (sys_clk),
        .we    (lb_we),
        .waddr (lb_waddr),
        .wdata (lb_wdata),
        .rclk  (pix_clk),
        .raddr (lb_raddr),
        .rdata (lb_rdata)
    );

    vga_out u_vga (
        .clk      (pix_clk),
        .rst_n    (pix_rst_n),
        .lb_raddr (lb_raddr),
        .lb_rdata (lb_rdata),
        .req_tgl  (req_tgl),
        .req_line (req_line),
        .fb_valid (fb_front_valid),
        .hsync    (pVideoHS_n),
        .vsync    (pVideoVS_n),
        .r        (pDac_VR),
        .g        (pDac_VG),
        .b        (pDac_VB)
    );

    // ---- cartridge-slot bridge (forward seam, held disabled) -------------
    qbus_slot #(.SLOT_ENABLE(1'b0)) u_slot (
        .ad_n      (ad_n),
        .sync_n    (sync_n),
        .din_n     (din_n),
        .dout_n    (dout_n),
        .wtbt_n    (wtbt_n),
        .rply_n    (rply_n),
        .pSltAdr   (),
        .pSltMerq_n(),
        .pSltRd_n  (),
        .pSltWr_n  (),
        .pSltIorq_n(),
        .pSltWait_n(),
        .pSltBdir_n()
    );

    // ---- USB HID host (vendored; the side USB-A port) --------------------
    // Runs in its own 12.08 MHz domain (see cpu_clkgen's usb_clk): the core's
    // Fmax on this part is 79 MHz, so it cannot be a clock-enabled block in
    // sys_clk. Reset is POWER-ON ONLY (vid_rst_n), like the audio and video
    // sides: a warm reset must not drop the USB link and force the device to
    // re-enumerate. Hot-plug is handled by the core's own watchdog, not by a
    // reset.
    //
    // BK-visible consumers:
    //   - a mouse presented as Marsianka on 0177714 (see bk_mouse.sv);
    //   - the keyboard, via a HID->PS/2 shim into the existing kbd_ps2bk (TODO);
    //   - a gamepad OR'd into the 0177714 joystick word (TODO).
    logic [1:0]  usb_typ;
    logic        usb_report, usb_conerr, usb_connected;
    logic [7:0]  usb_key_mod, usb_key1, usb_key2, usb_key3, usb_key4;
    logic [7:0]  usb_mouse_btn;
    logic signed [7:0] usb_mouse_dx, usb_mouse_dy;
    logic        usb_g_l, usb_g_r, usb_g_u, usb_g_d;
    logic        usb_g_a, usb_g_b, usb_g_x, usb_g_y, usb_g_sel, usb_g_sta;
    logic [63:0] usb_report_bytes;
    logic [55:0] usb_enum_regs;

    usb_hid_host u_usb (
        .usbclk        (usb_clk),
        .usbrst_n      (vid_rst_n),
        .usb_dp        (pUsbP),
        .usb_dm        (pUsbN),
        .typ           (usb_typ),
        .report        (usb_report),
        .conerr        (usb_conerr),
        .key_modifiers (usb_key_mod),
        .key1          (usb_key1),
        .key2          (usb_key2),
        .key3          (usb_key3),
        .key4          (usb_key4),
        .mouse_btn     (usb_mouse_btn),
        .mouse_dx      (usb_mouse_dx),
        .mouse_dy      (usb_mouse_dy),
        .game_l        (usb_g_l),
        .game_r        (usb_g_r),
        .game_u        (usb_g_u),
        .game_d        (usb_g_d),
        .game_a        (usb_g_a),
        .game_b        (usb_g_b),
        .game_x        (usb_g_x),
        .game_y        (usb_g_y),
        .game_sel      (usb_g_sel),
        .game_sta      (usb_g_sta),
        .dbg_hid_report(usb_report_bytes),
        .dbg_regs      (usb_enum_regs),
        .dev_connected (usb_connected)
    );

    // ---- Marsianka mouse: the USB mouse as the BK's 0177714 read word ------
        bk_mouse u_mouse (
        .usb_clk    (usb_clk),
        .hid_report (usb_report),
        .hid_btn    (usb_mouse_btn),
        .hid_dx     (usb_mouse_dx),
        .hid_dy     (usb_mouse_dy),
        .hid_typ    (usb_typ),
        .clk        (cpu_clk_n),
        .port_data  (snd_port_data),
        .mouse_word (mouse_word),
        .mouse_active ()
    );

    // Mute Covox as it conflicts with the mouse when connected.
    logic [1:0] cx_mouse_sr = '0;
    always_ff @(posedge sys_clk) cx_mouse_sr <= {cx_mouse_sr[0], usb_typ == 2'd2};
    assign cx_mouse_mute = cx_mouse_sr[1];

    // Free-running PLL counter - the boot-fail blink source for pLedPwr; only
    // the hb[22] blink tap is used (pLed[7] is the drive-access indicator).
    logic [22:0] hb;
    always_ff @(posedge sys_clk or negedge locked) begin
        if (!locked) hb <= '0;
        else         hb <= hb + 1'b1;
    end

    // pLedPwr: the combined power/boot-status LED - solid once SDRAM init is
    // done, but BLINKS if the boot blob failed validation (the CPU is then held
    // in reset). Dark only during the ~200 us SDRAM init at power-on.
    wire boot_fail = boot_done && !boot_ok;
    assign pLedPwr = boot_fail ? hb[22] : init_done;
    // pLed[7]: SMK IDE drive-access LED - ide_act (a command/backend op in
    // flight in smk_ide, sclk domain) stretched to ~87 ms (2^23 sys_clk) so
    // even a single-sector op is visible; re-armed while activity persists.
    // While lit the LED BLINKS at ~11.5 Hz (2^22 sys_clk half-period) instead
    // of sitting solid, so a long transfer (a boot, a multi-sector load, where
    // ide_act re-arms the stretch every few us) reads as a working drive
    // rather than a stuck light.  ide_blink is held at 0 while the LED is
    // dark, so every burst starts in the ON half: an isolated op = one clean
    // ~43 ms flash (the stretch window is exactly one blink period),
    // continuous access = steady 11.5 Hz blinking.
    logic [22:0] ide_led_cnt = '0;
    logic [22:0] ide_blink   = '0;
    always_ff @(posedge sys_clk) begin
        if (ide_act)               ide_led_cnt <= '1;
        else if (ide_led_cnt != 0) ide_led_cnt <= ide_led_cnt - 1'b1;

        if (ide_led_cnt == 0) ide_blink <= '0;
        else                  ide_blink <= ide_blink + 1'b1;
    end
    wire ide_led = (ide_led_cnt != 0) && !ide_blink[22];
    // pLed[7]: SMK IDE drive access (stretched + blinking).  pLed[6]: CMT
    // tape-in mode (DIP 4; lit = right jack is the cassette port).
    // pLed[5]: TURBO mode (PS/2 F12; lit = 6.04 MHz, no 037 cycle-stealing).
    // pLed[4]: TurboSound PSG activity (a tone or noise channel is enabled
    // on a live chip).  pLed[3]: TurboSound 2-chip mode engaged (a program
    // has selected chip 1 with a 0xFE write); [3] previously carried the
    // audio self-test indicator, retired with DIP 5.
    // pLed[2]: a DAC quantizer clipped (STICKY).  pLed[1]: the audio mixer
    // saturated (STICKY).  pLed[0]: BK speaker activity (solid while a tone
    // plays; audio bring-up tap).
    // The two sticky audio flags are bring-up observability, the same reasoning
    // that put spk_active on pLed[0] in Phase 6: they turn "it sounds wrong"
    // into "the digital side says the level overflowed", which is otherwise
    // indistinguishable from an analog fault. Neither should ever light in
    // normal use - the gain budget, not the saturator, is the mixing strategy.
    assign pLed    = {ide_led, cmt_mode, turbo_eff, ts_act,
                      ts_dual, snd_clip, snd_sat, spk_active};

endmodule
