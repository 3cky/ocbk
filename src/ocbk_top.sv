// ocbk_top - top level for the BK-0010 CPU bring-up on the OneChipBook.
//
// Phase 1: brings the vm1 (1801ВМ1) core up standalone on the EP1C12, running
// the bk10 test program from on-chip block RAM, with liveness on the LEDs.
//
// Only the pins the design drives are declared; every other device pin -
// including the entire cartridge-slot block PIN_121-180 - is reserved as a
// tri-stated input by the .qsf. The cartridge-slot Q-bus seam lives in
// qbus_slot and is disabled (SLOT_ENABLE=0) for this phase.
//
// This single file holds the whole Phase-1 subsystem: the PLL/clock tree and
// reset sequencer, the inverted open-collector Q-bus nets, the vm1 core, the
// synthesizable qbus_mem slave, the (disabled) qbus_slot bridge, and the
// liveness LEDs.
//
// Clock tree (one PLL only - board constraint: the PIN_28 crystal can feed a
// single PLL). The x9 VCO yields 96.65 MHz; everything else is a fabric divide:
//
//   96.65 MHz  sys_clk  altpll clk0                        (future: SDRAM, etc.)
//   /8  -> 12.08 MHz   dot_ena (1-in-8 strobe)             (future: Phase 4 video)
//   /32 -> ~3.02 MHz   cpu_clk (BK-0010 rate), 50% duty
//          cpu_clk_n = ~cpu_clk                            (anti-phase pair)
//
// The vm1 core needs an anti-phase clock pair (pin_clk_p / pin_clk_n); on the
// DE0 reference these are a PLL 0deg/180deg pair, here they are a /32 divided
// clock and its inverse - identical phase relationship at a fraction of the
// rate. Exact CPU rate is not critical for Phase 1: instruction cycle counts
// are clock-domain-relative; only the integer divide ratios matter.
//
// Reset: after the PLL locks, DCLO and ACLO are released in sequence (DCLO
// first, ACLO a few CPU clocks later), reproducing the bk10_tb reset ordering
// that the 1801ВМ1 power-up micro-sequence expects.
//
// LEDs (liveness):
//   pLedPwr (red)  : solid once the CPU reaches the BR . self-loop at 001076
//                    (booted from ROM bootstrap, ran the whole test program).
//   pLed[7]        : system heartbeat off the PLL - blinks whenever the FPGA is
//                    configured and the PLL is locked (CPU-independent).
//   pLed[6:0]      : top bits of a fetch counter - move while the CPU executes.
//                    (pLed[7] blinking but pLed[6:0] frozen => CPU hung.)
module ocbk_top (
    input  logic       pClk21m,   // 21.47727 MHz crystal (PIN_28)
    output logic [7:0] pLed,      // green LEDs   (1 = on)
    output logic       pLedPwr    // red power LED (1 = on)
);

    // PLL: 21.477 MHz -> 96.65 MHz (x9 / 2). The output frequency is
    // f_in * PLL_MULT / PLL_DIV; the fitter factors that ratio into the
    // device's internal m/n/c counters. Direct WYSIWYG altpll instance, so no
    // MegaWizard-generated .qip is needed.
    localparam int PLL_MULT        = 9;
    localparam int PLL_DIV         = 2;
    localparam int INCLK_PERIOD_PS = 46554;   // 21.47727 MHz, in 1/1000 MHz units

    // ---- clocks + reset -------------------------------------------------
    logic sys_clk;          // 96.65 MHz VCO output
    logic cpu_clk;          // ~3.02 MHz CPU clock     -> pin_clk_p
    logic cpu_clk_n;        // inverted CPU clock      -> pin_clk_n
    logic dot_ena;          // 12.08 MHz enable strobe (reserved, Phase 4)
    logic dclo_n;           // CPU reset  (active low) - released first
    logic aclo_n;           // power-fail (active low) - released later
    logic locked;           // PLL locked

    // --- PLL ------------------------------------------------------------
    // altpll is an Altera primitive, not simulatable under Icarus, so the PLL
    // is validated at fit time (must lock); the divided CPU clock and the core
    // logic are covered by the bk10 / cosim testbenches driven with a plain clock.
    logic [5:0] sub_wire_clk;
    altpll #(
        .bandwidth_type         ("AUTO"),
        .clk0_divide_by         (PLL_DIV),
        .clk0_duty_cycle        (50),
        .clk0_multiply_by       (PLL_MULT),
        .clk0_phase_shift       ("0"),
        .compensate_clock       ("CLK0"),
        .inclk0_input_frequency (INCLK_PERIOD_PS),
        .intended_device_family ("Cyclone"),
        .lpm_type               ("altpll"),
        .operation_mode         ("NORMAL"),
        .pll_type               ("AUTO"),
        .port_clk0              ("PORT_USED"),
        .port_inclk0            ("PORT_USED"),
        .port_locked            ("PORT_USED")
    ) altpll_inst (
        .inclk  ({1'b0, pClk21m}),
        .clk    (sub_wire_clk),
        .locked (locked),
        .areset (1'b0)
    );
    assign sys_clk = sub_wire_clk[0];

    // --- divider chain off the 96.65 MHz VCO ----------------------------
    logic [4:0] divc;
    always_ff @(posedge sys_clk or negedge locked) begin
        if (!locked) divc <= '0;
        else         divc <= divc + 1'b1;
    end

    assign dot_ena   = (divc[2:0] == 3'b000);   // 96.65/8  = 12.08 MHz strobe
    assign cpu_clk   =  divc[4];                 // 96.65/32 = 3.02 MHz, 50% duty
    assign cpu_clk_n = ~divc[4];

    // --- reset sequencer (on cpu_clk, mirroring bk10_tb ordering) -------
    logic [3:0] rstc;
    always_ff @(posedge cpu_clk or negedge locked) begin
        if (!locked) begin
            rstc   <= 4'd0;
            dclo_n <= 1'b0;
            aclo_n <= 1'b0;
        end else begin
            if (rstc != 4'hF) rstc <= rstc + 1'b1;
            dclo_n <= (rstc >= 4'd8);    // release DCLO after 8 CPU clocks
            aclo_n <= (rstc >= 4'd12);   // release ACLO 4 clocks after DCLO
        end
    end

    // ---- shared Q-bus (inverted, active low; pull-up = released) --------
    tri1 [15:0] ad_n;
    tri1        sync_n, din_n, dout_n, wtbt_n, rply_n;
    tri1        init_n, dmr_n, sack_n, iako_n;
    wire        dmgo_n, bsy_n;
    wire [2:1]  sel_n;

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
        .pin_irq_n (3'b111),        // no radial interrupts
        .pin_virq_n(1'b1),          // no vectored interrupt
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

    // ---- synthesizable Q-bus memory slave -------------------------------
    wire [15:0] bus_addr;
    wire        fetch_stb;
    qbus_mem #(.MEMFILE("mem/bk10_prog.hex")) u_mem (
        .clk      (cpu_clk_n),      // advances on the inverted CPU clock
        .reset    (~dclo_n),
        .ad_n     (ad_n),
        .sync_n   (sync_n),
        .din_n    (din_n),
        .dout_n   (dout_n),
        .wtbt_n   (wtbt_n),
        .rply_n   (rply_n),
        .bus_addr (bus_addr),
        .fetch_stb(fetch_stb)
    );

    // ---- cartridge-slot bridge (forward seam, disabled for Phase 1) -----
    // Slot-side pins are intentionally left unconnected: with SLOT_ENABLE=0 the
    // bridge drives them Hi-Z and the .qsf reserves PIN_121-180 tri-stated.
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

    // ---- liveness --------------------------------------------------------
    // Reached the BR . self-loop at byte 001076 (sticky).
    logic reached_loop;
    always_ff @(posedge cpu_clk_n or negedge dclo_n) begin
        if (!dclo_n)                               reached_loop <= 1'b0;
        else if (fetch_stb && bus_addr == 16'o001076) reached_loop <= 1'b1;
    end

    // Fetch counter (moves while the CPU executes).
    logic [23:0] fetch_cnt;
    always_ff @(posedge cpu_clk_n or negedge dclo_n) begin
        if (!dclo_n)        fetch_cnt <= '0;
        else if (fetch_stb) fetch_cnt <= fetch_cnt + 1'b1;
    end

    // System heartbeat off the PLL (CPU-independent liveness).
    logic [24:0] hb;
    always_ff @(posedge sys_clk or negedge locked) begin
        if (!locked) hb <= '0;
        else         hb <= hb + 1'b1;
    end

    assign pLedPwr = reached_loop;
    assign pLed    = {hb[24], fetch_cnt[23:17]};

endmodule
