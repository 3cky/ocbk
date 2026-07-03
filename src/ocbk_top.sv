// ocbk_top - top level for the BK-0010 CPU + RAM-in-SDRAM + video pipeline on
// the OneChipBook.
//
// Phase 3+4: the vm1 (1801ВМ1) core runs the ROM-resident test program with the
// retimed 037 (va_037_sync) owning RAM RPLY / cycle-stealing; BK RAM (000000-
// 077777) is in the board SDRAM behind sdram_arbiter; the 037 video fetch is
// decoded through palette_apply into a double-buffered 4-bit-index framebuffer
// in SDRAM and scanned out at 1024x768@60 (x2H/x3V) on the 6-bit R-2R VGA DAC.
//
// Only the pins the design drives are declared; every other device pin -
// including the entire cartridge-slot block PIN_121-180 - is reserved as a
// tri-stated input by the .qsf. The cartridge-slot Q-bus seam lives in qbus_slot
// and is disabled (SLOT_ENABLE=0) for this phase.
//
// Clock tree (one PLL only - board constraint: the PIN_28 crystal feeds a single
// PLL). The x9 VCO yields 96.65 MHz; the pixel clock is the same VCO /3; the
// rest are fabric divides or the PLL's dedicated external-clock pin:
//
//   96.65 MHz  sys_clk   altpll clk0     - SDRAM controller + adapter logic
//   96.65 MHz  pMemClk   altpll extclk0  - SDRAM chip clock (phase-matched, e0)
//   64.43 MHz  pix_clk   altpll clk1     - 1024x768@60 video readout
//   /8  -> 12.08 MHz   dot_ena (1-in-8 strobe)             (spare)
//   /32 -> ~3.02 MHz   cpu_clk (BK-0010 rate), 50% duty
//          cpu_clk_n = ~cpu_clk                            (anti-phase pair)
//
// sys_clk <-> pix_clk are same-VCO related clocks; every real crossing is a
// toggle+2-FF handshake or the ping-pong-guarded fb_linebuf RAM, so the SDC
// false-paths the pair (TimeQuest would otherwise time the 3:2 ~5.2 ns transfer).
//
// Reset: the SDRAM controller is released as soon as the PLL locks and runs its
// ~200 us init; the EPCS boot loader then copies the BK-0010.01 ROM blob from
// the config flash into the SDRAM ROM region (~22 ms); the CPU is held in reset
// (DCLO low) until init_done AND boot_done, after which DCLO and ACLO are
// released in sequence (the bk10_tb power-up ordering). The video readout +
// pixel domain are held until init_done; RGB stays black until the first
// complete BK frame has been decoded (fb_front_valid).
//
// ROM source: SDRAM (the loaded MONITOR+BASIC set) when the blob validated OK;
// the on-chip test ROM (Phase-4 picture / RAM test) when the blob failed or
// DIP 2 is ON (the hardware-regression path - parks 100004/100012 live there).
//
// screen_mode (mono-512 vs colour-256) is the physical monitor-cable switch of a
// real BK-0010 -> DIP switch 1 here: OFF = colour-256 (default), ON = mono-512.
//
// LEDs (liveness):
//   pLedPwr (red)  : normal boot = ROM blob loaded + selected; fallback mode =
//                    the RAM-test SUCCESS self-loop latch (100004).
//   pLed[7]        : system heartbeat off the PLL (FPGA configured + PLL locked).
//   pLed[6]        : SDRAM init_done; BLINKS if the boot blob failed validation.
//   pLed[5:0]      : top bits of a transaction counter - move while the CPU runs.
module ocbk_top (
    input  logic        pClk21m,   // 21.47727 MHz crystal (PIN_28)
    output logic [7:0]  pLed,      // green LEDs   (1 = on)
    output logic        pLedPwr,   // red power LED (1 = on)
    input  logic [7:0]  pDip,      // DIP switches (ON = low); [0] = screen_mode

    // ---- VGA (6-bit R-2R DAC per channel, negative syncs) ----------------
    output logic        pVideoHS_n,
    output logic        pVideoVS_n,
    output logic [5:0]  pDac_VR,
    output logic [5:0]  pDac_VG,
    output logic [5:0]  pDac_VB,

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
    logic cpu_clk;          // ~3.02 MHz CPU clock     -> pin_clk_p
    logic cpu_clk_n;        // inverted CPU clock      -> pin_clk_n
    logic dot_ena;          // 12.08 MHz enable strobe (spare)
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

    // --- pixel-domain reset (held until SDRAM init; init_done 2-FF synced) ---
    logic [1:0] prst_sr;
    always_ff @(posedge pix_clk or negedge locked) begin
        if (!locked) prst_sr <= 2'b00;
        else         prst_sr <= {prst_sr[0], init_done};
    end
    wire pix_rst_n = prst_sr[1];

    // --- screen_mode from DIP 1 (quasi-static; ON = pulled low = mono-512) ---
    logic [1:0] smode_sr;
    always_ff @(posedge sys_clk) smode_sr <= {smode_sr[0], ~pDip[0]};
    wire screen_mode = smode_sr[1];

    // --- DIP 2: force the on-chip test ROM (Phase-4 regression image) --------
    logic [1:0] dip2_sr;
    always_ff @(posedge sys_clk) dip2_sr <= {dip2_sr[0], ~pDip[1]};
    wire dip2_test = dip2_sr[1];

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

    // ROM source: the loaded SDRAM image unless the blob failed or DIP2 forces
    // the on-chip test ROM. Quasi-static: settles before the CPU leaves reset.
    wire rom_ext_en = boot_ok && !dip2_test;

    // --- init_done + boot_done synchronised into the CPU-clock domain -------
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

    // --- reset sequencer (on cpu_clk; held until SDRAM init + ROM load done) ---
    logic [3:0] rstc;
    always_ff @(posedge cpu_clk or negedge locked) begin
        if (!locked) begin
            rstc   <= 4'd0;
            dclo_n <= 1'b0;
            aclo_n <= 1'b0;
        end else if (!id_sync || !bd_sync) begin
            rstc   <= 4'd0;          // hold CPU in reset until SDRAM + ROM ready
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

    // 037 video-side taps consumed by the Phase-4 pipeline below
    wire        vid_fetch, vid_line_en, hgate, vgate;
    wire [13:1] video_va;

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
        .cpu_grant (),
        .video_va  (video_va),
        .vid_fetch (vid_fetch),
        .vid_line_en(vid_line_en),
        .hgate     (hgate),
        .vgate     (vgate)
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
    // Phase-4 video client wires (blocks instantiated below u_mem)
    wire        f_req, f_gnt, f_rvalid, w_req, w_gnt;
    wire [23:0] f_addr, w_addr;
    wire [15:0] w_wdata, v_rdata;
    wire        ro_req, ro_gnt, ro_rvalid;
    wire [23:0] ro_addr;

    wire [15:0] bus_addr;
    wire        fetch_stb;
    qbus_mem_sdram #(.MEMFILE("mem/ram_test.hex")) u_mem (
        .cpu_clk  (cpu_clk_n),      // ROM/IO wait FSM advances on the inverted CPU clock
        .reset    (~dclo_n),
        .rom_ext_en(rom_ext_en),
        .boot_active(boot_active),
        .bw_req   (bw_req),
        .bw_addr  (bw_addr),
        .bw_wdata (bw_wdata),
        .bw_gnt   (bw_gnt),
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
        .v1_req   (ro_req),         // Phase-4 video clients -> arbiter ports 1/2/3
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
        .fetch_stb(fetch_stb)
    );

    // ---- Phase-4 video pipeline ------------------------------------------
    // 037 fetch -> palette_apply -> double-buffered FB in SDRAM (fb_video,
    // arbiter ports 2+3) -> paced line prefetch (fb_readout, port 1) ->
    // dual-clock fb_linebuf -> vga_out (1024x768@60, x2H/x3V, fixed CLUT).
    wire        fb_front, fb_front_valid;
    wire        req_tgl;
    wire [7:0]  req_line;
    wire        lb_we;
    wire [9:0]  lb_waddr, lb_raddr;
    wire [3:0]  lb_wdata, lb_rdata;
    wire        ro_rst_n = srst_n & init_done;

    fb_video u_fbv (
        .clk        (sys_clk),
        .rst_n      (dclo_n),          // released with the CPU/037
        .screen_mode(screen_mode),
        .vid_fetch  (vid_fetch),
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
    // Reached the SUCCESS self-loop at byte 100004 (RAM test passed; sticky).
    logic reached_loop;
    always_ff @(posedge cpu_clk_n or negedge dclo_n) begin
        if (!dclo_n)                                   reached_loop <= 1'b0;
        else if (fetch_stb && bus_addr == 16'o100004)  reached_loop <= 1'b1;
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

    // pLedPwr: normal boot = solid once the real ROM is loaded and selected;
    // fallback (DIP2 / blob failure) = the Phase-4 RAM-test success latch.
    // pLed[6]: init_done, but BLINKS if the boot blob failed validation.
    wire boot_fail = boot_done && !boot_ok;
    assign pLedPwr = rom_ext_en | reached_loop;
    assign pLed    = {hb[24], boot_fail ? hb[22] : init_done, fetch_cnt[23:18]};

endmodule
