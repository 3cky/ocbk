// ocbk_top - top level for the BK-0010 CPU + RAM-in-SDRAM on the OneChipBook.
//
// Phase 2: the vm1 (1801ВМ1) core runs the ROM-resident RAM-test program from
// on-chip ROM, with BK RAM (000000-077777) backed by the board SDRAM through the
// synthesizable qbus_sdram slave. ROM and I/O stay on-chip. Liveness on the LEDs.
//
// Only the pins the design drives are declared; every other device pin -
// including the entire cartridge-slot block PIN_121-180 - is reserved as a
// tri-stated input by the .qsf. The cartridge-slot Q-bus seam lives in qbus_slot
// and is disabled (SLOT_ENABLE=0) for this phase.
//
// Clock tree (one PLL only - board constraint: the PIN_28 crystal feeds a single
// PLL). The x9 VCO yields 96.65 MHz; everything else is a fabric divide or the
// PLL's dedicated external-clock pin:
//
//   96.65 MHz  sys_clk   altpll clk0     - SDRAM controller + adapter logic
//   96.65 MHz  pMemClk   altpll extclk0  - SDRAM chip clock (phase-matched, e0)
//   /8  -> 12.08 MHz   dot_ena (1-in-8 strobe)             (future: Phase 4 video)
//   /32 -> ~3.02 MHz   cpu_clk (BK-0010 rate), 50% duty
//          cpu_clk_n = ~cpu_clk                            (anti-phase pair)
//
// cpu_clk is sys_clk/32 here, so a worst-case SDRAM access (~200 ns) finishes
// well inside the RPLY window ((N_RAM-2) CPU clocks ~= 660 ns, ~3x margin) and its
// latency is hidden in qbus_sdram (cycle-faithful, validated by the cosim). The
// margin shrinks at the faster BK rates (4/6 MHz) but stays positive below ~10 MHz.
//
// Reset: the SDRAM controller is released as soon as the PLL locks and runs its
// ~200 us init; the CPU is then held in reset (DCLO low) until init_done, after
// which DCLO and ACLO are released in sequence (the bk10_tb power-up ordering).
//
// LEDs (liveness):
//   pLedPwr (red)  : solid once the CPU reaches the SUCCESS self-loop at 100072
//                    (RAM-test passed: every word/byte write verified from SDRAM).
//   pLed[7]        : system heartbeat off the PLL (FPGA configured + PLL locked).
//   pLed[6]        : SDRAM init_done (lit once the controller finished init).
//   pLed[5:0]      : top bits of a transaction counter - move while the CPU runs.
module ocbk_top (
    input  logic        pClk21m,   // 21.47727 MHz crystal (PIN_28)
    output logic [7:0]  pLed,      // green LEDs   (1 = on)
    output logic        pLedPwr,   // red power LED (1 = on)

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
    logic cpu_clk;          // ~3.02 MHz CPU clock     -> pin_clk_p
    logic cpu_clk_n;        // inverted CPU clock      -> pin_clk_n
    logic dot_ena;          // 12.08 MHz enable strobe (reserved, Phase 4)
    logic en_pos, en_neg;   // ÷16 037 CLKIN enables (on CPU edges; see va_037_sync)
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
    assign pMemClk = sub_wire_extclk[0];

    // --- divider chain off the 96.65 MHz VCO ----------------------------
    logic [4:0] divc;
    always_ff @(posedge sys_clk or negedge locked) begin
        if (!locked) divc <= '0;
        else         divc <= divc + 1'b1;
    end

    assign dot_ena   = (divc[2:0] == 3'b000);   // 96.65/8  = 12.08 MHz strobe
    assign cpu_clk   =  divc[4];                 // 96.65/32 = 3.02 MHz, 50% duty
    assign cpu_clk_n = ~divc[4];
    // 037 CLKIN enables (÷16), phased to fire ON the CPU clock edges (CPU=CLKIN/2)
    // so the retimed 037 matches the reference CPU:037 phase (see va_037_sync).
    assign en_pos    = (divc[3:0] == 4'd15);     // "posedge CLKIN" (divc -> 0/16)
    assign en_neg    = (divc[3:0] == 4'd7);      // "negedge CLKIN" (divc -> 8/24)

    // --- SDRAM-domain reset (release a couple sys_clk after PLL lock) ----
    logic srst_n_meta, srst_n;
    always_ff @(posedge sys_clk or negedge locked) begin
        if (!locked) {srst_n_meta, srst_n} <= 2'b00;
        else         {srst_n_meta, srst_n} <= {1'b1, srst_n_meta};
    end

    // --- init_done synchronised into the CPU-clock domain ---------------
    logic id_meta, id_sync;
    always_ff @(posedge cpu_clk or negedge locked) begin
        if (!locked) {id_meta, id_sync} <= 2'b00;
        else         {id_meta, id_sync} <= {init_done, id_meta};
    end

    // --- reset sequencer (on cpu_clk; held until SDRAM init completes) ---
    logic [3:0] rstc;
    always_ff @(posedge cpu_clk or negedge locked) begin
        if (!locked) begin
            rstc   <= 4'd0;
            dclo_n <= 1'b0;
            aclo_n <= 1'b0;
        end else if (!id_sync) begin
            rstc   <= 4'd0;          // hold CPU in reset until SDRAM is ready
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

    // RAM RPLY + its cycle-stealing timing come from the retimed 037; ROM/IO reply
    // from qbus_mem_sdram. The 037's RPLY (hard-driven) is converted to open-collector
    // here so it wire-ANDs onto the shared rply_n. mem_ready is the RAM SDRAM done-gate.
    wire        rply037_n;
    wire        mem_ready;
    assign rply_n = (rply037_n === 1'b0) ? 1'b0 : 1'bZ;

    va_037_sync u_037 (
        .clk       (sys_clk),
        .en_pos    (en_pos),
        .en_neg    (en_neg),
        .mem_ready (mem_ready),
        .PIN_R     (~dclo_n),          // 037 held in reset with the CPU (until init)
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
        .PIN_nBS   (),
        .PIN_WTI   (),
        .PIN_WTD   (),
        .PIN_nVSYNC(),
        .cpu_grant (),                 // (Phase 4: video fetch translation)
        .video_va  ()
    );

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

    // ---- memory subsystem: ROM/IO on-chip (N_ROM) + RAM datapath in SDRAM
    //      (cpu_sdram_dp + sdram_arbiter + sdram_ctrl). RAM RPLY is owned by the 037
    //      above via mem_ready; this block drives rply_n only for ROM/IO. ----------
    wire [15:0] bus_addr;
    wire        fetch_stb;
    qbus_mem_sdram #(.MEMFILE("mem/ram_test.hex")) u_mem (
        .cpu_clk  (cpu_clk_n),      // ROM/IO wait FSM advances on the inverted CPU clock
        .reset    (~dclo_n),
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
        .fetch_stb(fetch_stb)
    );

    // ---- cartridge-slot bridge (forward seam, disabled for Phase 2) -----
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
    // Reached the SUCCESS self-loop at byte 100072 (RAM test passed; sticky).
    logic reached_loop;
    always_ff @(posedge cpu_clk_n or negedge dclo_n) begin
        if (!dclo_n)                                   reached_loop <= 1'b0;
        else if (fetch_stb && bus_addr == 16'o100072)  reached_loop <= 1'b1;
    end

    // Transaction counter (moves while the CPU executes).
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
    assign pLed    = {hb[24], init_done, fetch_cnt[23:18]};

endmodule
