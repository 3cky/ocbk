//
// Phase 7 BK-0011M banking FUNCTIONAL oracle (data-checking, NOT a timing
// golden - ref037 keeps the timing-reference meaning).
//
//   vm1 CPU + va_037_sync (RAM RPLY for A15=0, done-gate) + the REAL qbus_mem
//   (mem_mapper in BK-0011M mode + ROM/IO/EXT wait FSM + cpu_sdram_dp +
//   arbiter + ctrl) + behavioural sdram_model + the port-2 video-fetch
//   saturator for contention.
//
// The mem/gen_bk11_test.py program runs the whole Bk11MemoryManager contract
// (see there): boot = 177716 read (start vector 140000 = SYS_START11) -> a
// stage-0 stub in the fixed top ROM JMPs into stage 1 in the EXT window
// (reset map: window 1 = RAM page 0), stage 2 in the fixed page-6 region
// fills/verifies all 8 pages
// through both windows, aliases page 6, RMWs in EXT, checks the ROM overlay
// codes + write-ignore + empty-socket read-timeout (banks 2,3 unpopulated ->
// trap 4) + the 033 quirk + the fixed top ROM, executes RESET
// (nINIT must PRESERVE the map) and verifies the register is write-only.
// Phase-7 177662 phase: word writes to the video register must be replied
// (qbus_mem's bk11-only write decode), survive RESET, and reads must bus-
// time-out (write-only; proven in-program via a vector-4 detour). This tb
// checks the vid_page/vid_irq2_mask/vid_pal taps: the DCLO defaults
// (0 / 1 / 0o17 = MiSTer def_reg662 0o047400) right after reset release,
// and the program's final write (1 / 0 / 0o12) after the success park.
// Phase-7 EVNT/IRQ2 leg: nIRQ2 is wired through the ocbk_top replica below
// (level = ~mask & vgate, sys_clk reg + 2-FF cpu_clk); the program's
// section 12 proves the mask gates the asserted level, one fire per
// blanking window (vector 0100), and two tb guards pin every assertion
// inside the vgate-high window and never-while-masked.
// Phase-7 СТОП-enable leg (section 13): the tb watches for the program's
// magic scratch write and pulses key_stop into the ocbk_top replica below
// (stop_block tap, 2-FF resync, gated 64-clk nIRQ1 one-shot); the program
// proves the 177716 bit-12 latch blocks/re-enables the СТОП trap-4 path
// (word + odd-byte writes reach it, even-byte and banking writes don't,
// RESET preserves it).
//
// The local divider replica runs the CPU clock at the 0011M /24 rate
// (4.03 MHz) - which also smokes the SDRAM CDC margins at that rate - with
// the 037 CLKIN enables on the fixed /16 chain, exactly as cpu_clkgen wires
// it (the SoC testbenches replicate the divider; sim/run_clkgen.sh is the
// divider's own oracle).
//
// Pass/fail: 3 consecutive DIN fetches of the success park 001004 -> COSIM
// PASS; any 001012 (fail park) hit or the watchdog -> COSIM FAIL.
//
`timescale 1ns / 1ps

`define SYSCLK_HALF 5

module bk11_soc_tb;

    localparam int AB = 24;
    localparam int DW = 16;

    // ROM overlay / top-ROM markers - MUST match mem/gen_bk11_test.py.
    // Only the populated window-1 bank 0 has a marker; banks 2,3 are empty
    // sockets (mapper -> MK_NONE, never read).
    localparam [15:0] ROMPAT0 = 16'o123456;
    localparam [15:0] TOPPAT  = 16'o054321;

    // ---- clocks: sys_clk + /16 037 enables + /24 CPU clock (cpu_clkgen
    //      replica in BK-0011M mode: toggle every 12 sys_clk) ---------------
    reg       sys_clk;
    reg [3:0] divc;
    initial sys_clk = 1'b0;
    always #(`SYSCLK_HALF) sys_clk = ~sys_clk;
    initial divc = 4'd0;
    always @(posedge sys_clk) divc <= divc + 1'b1;
    wire en_pos = (divc == 4'd15);
    wire en_neg = (divc == 4'd7);

    reg [3:0] cdiv;
    reg       cpu_clk_r;
    initial begin cdiv = 4'd0; cpu_clk_r = 1'b0; end
    always @(posedge sys_clk) begin
        if (cdiv >= 4'd11) begin cdiv <= 4'd0; cpu_clk_r <= ~cpu_clk_r; end
        else               cdiv <= cdiv + 1'b1;
    end
    wire clk = cpu_clk_r;

    // ---- Q-bus --------------------------------------------------------------
    tri1 [15:0] ad;
    tri1        sync, din, dout, wtbt, rply;
    wire        rply037_n;                        // 037 reply (RAM) -> open-collector
    assign rply = (rply037_n === 1'b0) ? 1'b0 : 1'bZ;

    reg         dclo, aclo;
    reg         dclo_cold;   // power-on-only video-side reset (037)
    reg  [1:0]  srst_sr;
    wire        srst_n = srst_sr[1];
    initial srst_sr = 2'b00;
    always @(posedge sys_clk) srst_sr <= {srst_sr[0], 1'b1};
    reg  [3:1]  irq;   reg virq, dmgi, sp;   reg [1:0] pa;
    wire        n_irq2;    // EVNT/IRQ2 replica (assigned below qbus_mem)
    wire        n_irq1;    // СТОП replica (assigned below qbus_mem)
    wire        dmgo;  tri1 init, dmr, sack, iako;   wire [2:1] sel;   wire bsy;

    // ---- tb-side address latch (for the park monitor) -----------------------
    reg [15:0] addr;
    always @(negedge sync) addr = ~ad;

    // ---- CPU ----------------------------------------------------------------
    vm1 cpu0 (
        .pin_clk_p(clk), .pin_clk_n(~clk), .pin_ena(1'b1),
        .pin_pa_n(pa), .pin_sp_n(sp),
        .pin_init_n(init), .pin_dclo_n(dclo), .pin_aclo_n(aclo),
        .pin_irq_n({irq[3], n_irq2, n_irq1}), .pin_virq_n(virq),
        .pin_ad_n(ad), .pin_dout_n(dout), .pin_din_n(din),
        .pin_wtbt_n(wtbt), .pin_sync_n(sync), .pin_rply_n(rply),
        .pin_dmr_n(dmr), .pin_sack_n(sack), .pin_dmgi_n(dmgi),
        .pin_dmgo_n(dmgo), .pin_iako_n(iako), .pin_sel_n(sel), .pin_bsy_n(bsy)
    );

    // ---- retimed 037 (owns RAM RPLY for A15=0, done-gate = mem_ready) -------
    wire [6:0] va_a;  wire [1:0] va_cas;
    wire       va_ras, va_we, va_ne, va_nbs, va_wti, va_wtd, va_vsync, va_grant;
    wire [13:1] video_va;
    wire        mem_ready;
    wire        mem_ext_ram;   // window-1 banked RAM -> 037 a15 force (from u_ms)
    wire        va_vfetch, va_line_en, va_hgate, va_vgate;
    va_037_sync pr037 (
        .clk(sys_clk), .en_pos(en_pos), .en_neg(en_neg), .mem_ready(mem_ready),
        .ext_ram(mem_ext_ram),
        .PIN_R(~dclo_cold), .PIN_C(1'b0),
        .PIN_nAD(ad), .PIN_nSYNC(sync), .PIN_nDIN(din), .PIN_nDOUT(dout),
        .PIN_nWTBT(wtbt), .PIN_nRPLY(rply037_n),
        .PIN_A(va_a), .PIN_nCAS(va_cas), .PIN_nRAS(va_ras), .PIN_nWE(va_we),
        .PIN_nE(va_ne), .PIN_nBS(va_nbs), .PIN_WTI(va_wti), .PIN_WTD(va_wtd),
        .PIN_nVSYNC(va_vsync), .cpu_grant(va_grant), .video_va(video_va),
        .vid_fetch(va_vfetch), .vid_line_en(va_line_en),
        .hgate(va_hgate), .vgate(va_vgate)
    );

    // ---- video fetch requester (arbiter port 2): worst-case streaming reads --
    reg fetch_req;
    wire [AB-1:0] fetch_addr = {10'd0, video_va};   // some RAM word; data dropped
    wire fetch_gnt, fetch_rvalid;
    always @(posedge sys_clk or negedge dclo) begin
        if (!dclo)              fetch_req <= 1'b0;
        else if (fetch_gnt)     fetch_req <= 1'b0;   // drop on grant (served contract)
        else                    fetch_req <= 1'b1;   // otherwise keep requesting
    end

    // ---- the REAL integration module, BK-0011M mode ---------------------------
    wire init_done;
    wire s_cke, s_cs_n, s_ras_n, s_cas_n, s_we_n;
    wire [1:0]  s_ba, s_dqm;
    wire [12:0] s_addr;
    wire [DW-1:0] s_dq;
    wire [15:0] bus_addr;
    wire        fetch_stb;
    wire [DW-1:0] v_rdata_nc;
    wire        vid_page, vid_irq2m;
    wire [3:0]  vid_pal;
    wire        stop_block;

    qbus_mem u_ms (
        .cpu_clk  (~clk),            // as ocbk_top: FSM on the inverted CPU clock
        .reset    (~dclo),
        .ide_rdata(16'h0000),  // no SMK IDE device in this tb
        .init_n   (init),
        .kbd_down (1'b0),
        .tape_in  (1'b0),
        .sel1_n   (sel[1]),
        .sel2_n   (sel[2]),
        .model_bk11(1'b1),           // <- the whole point of this oracle
        .smk_en(1'b0),               // no SMK512: plain-bk11 contract pinned here
        .boot_active(1'b0),          // no EPCS: pages preloaded directly
        .bw_req   (1'b0),
        .bw_addr  ({AB{1'b0}}),
        .bw_wdata ({DW{1'b0}}),
        .bw_gnt   (),
        .sclk     (sys_clk),
        .srst_n   (srst_n),
        .init_done(init_done),
        .ad_n     (ad),
        .sync_n   (sync),
        .din_n    (din),
        .dout_n   (dout),
        .wtbt_n   (wtbt),
        .rply_n   (rply),
        .mem_ready(mem_ready),
        .ext_ram  (mem_ext_ram),
        .v1_req   (1'b0),
        .v1_addr  ({AB{1'b0}}),
        .v1_gnt   (),
        .v1_rvalid(),
        .v2_req   (fetch_req),
        .v2_addr  (fetch_addr),
        .v2_gnt   (fetch_gnt),
        .v2_rvalid(fetch_rvalid),
        .v3_req   (1'b0),
        .v3_addr  ({AB{1'b0}}),
        .v3_wdata ({DW{1'b0}}),
        .v3_gnt   (),
        .v_rdata  (v_rdata_nc),
        .s_cke(s_cke), .s_cs_n(s_cs_n), .s_ras_n(s_ras_n), .s_cas_n(s_cas_n),
        .s_we_n(s_we_n), .s_ba(s_ba), .s_addr(s_addr), .s_dqm(s_dqm), .s_dq(s_dq),
        .bus_addr (bus_addr),
        .fetch_stb(fetch_stb),
        .vid_page (vid_page),
        .vid_irq2_mask(vid_irq2m),
        .vid_pal  (vid_pal),
        .stop_block(stop_block)
    );

    sdram_model u_mem (
        .clk(sys_clk), .cke(s_cke), .cs_n(s_cs_n), .ras_n(s_ras_n), .cas_n(s_cas_n),
        .we_n(s_we_n), .ba(s_ba), .addr(s_addr), .dqm(s_dqm), .dq(s_dq)
    );

    // ---- EVNT/IRQ2: the REAL detector (Phase 9; model_bk11 = 1 here) ---------
    // The authentic external D28+D3:B missing-pulse pair off the 037's WTI and
    // SYNCO pins - src/bk_evnt.sv, instantiated rather than replicated so this
    // tb cannot drift from the RTL (the cpu_clkgen replica lesson). Its output
    // is sys_clk-registered; the 2-FF onto posedge cpu_clk is the pin-sync
    // rule. The vm1's arm/fire edge detector makes it one vector-0100
    // interrupt per frame.
    wire      irq2_lvl;
    reg [1:0] irq2_sr;
    initial   irq2_sr = 2'b00;
    bk_evnt evnt (
        .sys_clk(sys_clk), .rst_n(dclo_cold),
        .wti(va_wti), .synco(va_vsync), .irq_en(~vid_irq2m), .evnt(irq2_lvl)
    );
    always @(posedge clk) irq2_sr <= {irq2_sr[0], irq2_lvl};
    assign n_irq2 = ~irq2_sr[1];

    // ---- СТОП: replica of the ocbk_top wiring (Phase 7) ----------------------
    // The program can't press a key, so the tb watches for its magic scratch
    // write (address AND value - the fill patterns can never collide) and
    // turns each one into a 1-cpu_clk key_stop strobe, then runs the exact
    // ocbk_top glue: stop_block (u_ms tap, sclk domain) 2-FF onto posedge
    // cpu_clk gating the launch of the 64-clk nIRQ1 one-shot.
    localparam [15:0] STOP_MAGIC_ADDR = 16'o000750;  // = gen_bk11_test.py
    localparam [15:0] STOP_MAGIC_VAL  = 16'o123321;
    reg stop_req = 1'b0;                  // toggles once per magic write
    always @(negedge dout)
        if (~sync && addr == STOP_MAGIC_ADDR && ~ad == STOP_MAGIC_VAL)
            stop_req = ~stop_req;
    reg [2:0] stop_req_sr = 3'b000;
    always @(posedge clk) stop_req_sr <= {stop_req_sr[1:0], stop_req};
    wire key_stop = stop_req_sr[2] ^ stop_req_sr[1];
    reg [1:0] stop_blk_sr = 2'b00;
    reg [6:0] stop_cnt    = 7'd0;
    always @(posedge clk) begin
        stop_blk_sr <= {stop_blk_sr[0], stop_block};
        if (key_stop && !stop_blk_sr[1]) stop_cnt <= 7'd64;
        else if (stop_cnt != 0)          stop_cnt <= stop_cnt - 1'b1;
    end
    assign n_irq1 = (stop_cnt == 0);

    // assertion guards, pinning what the program-side checks can't:
    //  - window phase: every nIRQ2 assertion must land inside the 037's
    //    vertical blanking window (an inverted level would still fire and
    //    pass the program checks, just at active-area start). The program sets
    //    177664 bit 9 (full screen) before section 12, so this holds;
    //  - NO RETRO-FIRE ON UNMASK (Phase 9): section 12 unmasks 662 bit 14 in
    //    the middle of a blanking window, so the unmask itself is the only
    //    nIRQ2 assertion this program can observe (the run ends before the
    //    next frame). The pre-Phase-9 model gated the level combinationally
    //    and re-asserted within a couple of sys_clk; the real detector's
    //    enable is D3:B's async RESET, so the request can only re-appear at
    //    the NEXT SYNCO edge - up to a full scanline later. That delay is the
    //    one discriminator visible at SoC level, so pin it here. (The 452
    //    CLKIN blanking-entry offset itself is sim/evnt's contract - it is not
    //    observable in this program.)
    //  - mask gating: nIRQ2 must never assert while 662 bit 14 is set (with
    //    the gate broken the vm1's arm/fire edge detector - the pin never
    //    deasserts, so it never arms - would quietly defer the first fire
    //    to the SECOND frame and still pass the program checks).
    integer unmask_age = 0;             // sys_clk since 662 bit 14 was cleared
    reg     m_d = 1'b1;
    always @(posedge sys_clk) begin
        if (m_d && !vid_irq2m) unmask_age = 0;
        else                   unmask_age = unmask_age + 1;
        m_d = vid_irq2m;
    end

    always @(negedge n_irq2) begin
        if (va_vgate !== 1'b1) begin
            $display("BK11-ERROR: IRQ2 asserted outside the vgate blanking window");
            $display("COSIM FAIL");
            $finish;
        end
        if (unmask_age < 512) begin
            $display("BK11-ERROR: IRQ2 re-asserted %0d sys_clk after unmask -",
                     unmask_age);
            $display("BK11-ERROR: the async-cleared request must wait for the");
            $display("BK11-ERROR: next SYNCO edge, not retro-fire combinationally");
            $display("COSIM FAIL");
            $finish;
        end
        if (vid_irq2m !== 1'b0) begin
            $display("BK11-ERROR: IRQ2 asserted while 662 bit 14 masks it");
            $display("COSIM FAIL");
            $finish;
        end
    end

    // ---- pass/fail: the pinned park loops (gen_bk11_test.py) ------------------
    integer scnt = 0;
    always @(negedge din) begin
        if (~sync) begin
            if (addr == 16'o001004) begin
                scnt = scnt + 1;
                if (scnt == 3) begin
                    // 177662 taps must show the program's final write
                    // (0o105000: page=1, irq2 unmasked, pal=0o12)
                    if (vid_page !== 1'b1 || vid_irq2m !== 1'b0
                        || vid_pal !== 4'o12) begin
                        $display("BK11-ERROR: 177662 taps page=%b m=%b pal=%o",
                                 vid_page, vid_irq2m, vid_pal);
                        $display("COSIM FAIL");
                    end else
                        $display("COSIM PASS");
                    $finish;
                end
            end else begin
                scnt = 0;
                if (addr == 16'o001012) begin
                    $display("BK11-ERROR: fail park 001012 reached");
                    $display("COSIM FAIL");
                    $finish;
                end
            end
        end
    end

    // ---- SDRAM preload ---------------------------------------------------------
    integer ii;
    initial begin
        for (ii = 0; ii < (1<<18); ii = ii + 1) u_mem.mem[ii] = 16'o000000;
        // physical page 0 (stage 1) and page 6 (vectors + stage 2)
        $readmemh("bk11_page0.hex", u_mem.mem, 'h20000, 'h21FFF);
        $readmemh("bk11_page6.hex", u_mem.mem, 'h2C000, 'h2DFFF);
        // ROM overlay bank 0 marker (word 0). Banks 2,3 are empty sockets:
        // the mapper decodes them MK_NONE (no reply -> trap 4), so no marker.
        u_mem.mem['h30000] = ROMPAT0;
        // fixed top ROM: the bk11 start vector is 140000 (SYS_START11), so
        // the first post-reset fetch lands here - a stage-0 stub jumps into
        // stage 1 in the EXT window; the TOPPAT marker moves to BK 140004
        u_mem.mem['h38000] = 16'o000137;    // JMP @#100000 (stage 1, EXT)
        u_mem.mem['h38001] = 16'o100000;
        u_mem.mem['h38002] = TOPPAT;
    end

    // ---- reset (wait SDRAM init) + watchdog -------------------------------------
    initial begin
        pa=2'b11; sp=1'b1; dmgi=1'b1; irq=3'b111; virq=1'b1;
        dclo=1'b0; aclo=1'b0; dclo_cold=1'b0;

        wait (init_done);
        @(negedge clk);
        repeat (8) @(negedge clk); dclo = 1'b1; dclo_cold = 1'b1;
        repeat (4) @(negedge clk); aclo = 1'b1;

        // 177662 DCLO defaults (MiSTer def_reg662 0o047400) - checked well
        // before the program can reach its 662 writes
        repeat (4) @(negedge clk);
        if (vid_page !== 1'b0 || vid_irq2m !== 1'b1 || vid_pal !== 4'o17) begin
            $display("BK11-ERROR: 177662 defaults page=%b m=%b pal=%o",
                     vid_page, vid_irq2m, vid_pal);
            $display("COSIM FAIL");
            $finish;
        end

        #50_000_000;
        $display("BK11-ERROR: watchdog timeout (last addr %o)", addr);
        $display("COSIM FAIL");
        $finish;
    end

endmodule
