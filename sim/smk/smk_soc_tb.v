//
// Phase 8 SMK512 segmented-RAM FUNCTIONAL oracle (data-checking, NOT a timing
// golden - ref037 keeps the timing-reference meaning; sim/bk11 pins the
// plain-bk11 contract with smk_en=0).
//
//   vm1 CPU + va_037_sync + the REAL qbus_mem (mem_mapper with smk_en=1 in
//   BK-0011M mode + the MK_EXT/177130 FSM legs + cpu_sdram_dp + arbiter +
//   ctrl) + behavioural sdram_model (DEEPENED to 1<<19 words - the SMK RAM
//   lives at 0x40000-0x7FFFF, above the default model size) + the port-2
//   video-fetch saturator for contention.
//
// The mem/gen_smk_test.py program (see there for the section list) walks the
// BkEmu SmkMemoryManager contract - increment 2: BIOS ROM windows, the
// I/O-page overlay OR-merge, the seg-7 extents, and the authentic boot.
//
// Boot rides the REAL SMK mechanism: this tb preloads the SYNTHETIC BIOS
// image (smk_bios.hex) at SDRAM SMK_BIOS_BASE = 0x3A000 - exactly where the
// EPCS loader puts the real one - and nothing else SMK-side (the old
// stage-0-stub-in-SMK-RAM liberty is GONE; SMK RAM starts zeroed like the
// rest of the model). The reset layout (SYS) maps rom7 over the whole
// 0170000-0177777 incl. the register space, so the CPU's initial-start
// 177716 read returns bios[0o7716] | SEL1 (qbus_mem's wire-OR merge) and
// PC <- & 177400 = 166400 - the stage-0 in the rom6 window.
//
// СТОП leg: the tb watches for the program's magic scratch write and pulses
// key_stop (the sim/bk11 §13 replica: stop_block tap, 2-FF resync, gated
// 64-clk nIRQ1 one-shot). In HLT10 the vm1's HALT-entry PSW/PC stores land
// in the writable seg-7 extent and the HALT vector is fetched from SMK RAM.
//
// An X monitor at the reply edges turns any bus drive fight (the vm1's
// 177712 self-served read, the kbd carve-out) into a loud failure.
//
// After the first success park the tb checks the 177662 taps (the program's
// masked write), then RE-PULSES DCLO (the warm-reset shape: memory and the
// 037 survive, the CPU + mapper re-init): the second boot re-runs the real
// boot mechanism and reaches the success park again only if DCLO restored
// the SYS layout (the program parked in RAM10; the RUN_FLAG re-verify leg
// also proves seg0 trap + BIOS windows back + SMK RAM content survival, and
// the 662 taps must be back at the DCLO defaults).
//
// Pass/fail: 3 consecutive DIN fetches of the success park 001004 on EACH
// pass -> COSIM PASS after the second; any 001012 (fail park) hit or the
// watchdog -> COSIM FAIL.
//
`timescale 1ns / 1ps

`define SYSCLK_HALF 5

module smk_soc_tb;

    localparam int AB = 24;
    localparam int DW = 16;

    // markers - MUST match mem/gen_smk_test.py
    localparam [15:0] ROMPAT0 = 16'o123456;
    localparam [15:0] TOPPAT  = 16'o054321;
    // --bk10 leg: the BK-0010 ROM image markers (SDRAM 0x4000 = BK 100000)
    localparam [15:0] MONPAT0 = 16'o152525;   // 100000, monitor ROM head
    localparam [15:0] MONPAT1 = 16'o063636;   // 117776, seg-1 top
    localparam [15:0] BASPAT  = 16'o177077;   // 120000 - must NEVER show

    // +bk10 (BkEmu BK_0010_SMK512): the same SMK oracle on a BK-0010 stack -
    // model_bk11=0, the /32 CPU rate, the program resident in the machine's
    // own RAM (SDRAM 0x0000) and the monitor ROM standing in for the bk11
    // second banked window / BOS. See the run.sh header.
    reg bk10;
    initial bk10 = $test$plusargs("bk10");

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
    wire [3:0] cdiv_max = bk10 ? 4'd15 : 4'd11;   // /32 bk10, /24 bk11
    always @(posedge sys_clk) begin
        if (cdiv >= cdiv_max) begin cdiv <= 4'd0; cpu_clk_r <= ~cpu_clk_r; end
        else                  cdiv <= cdiv + 1'b1;
    end
    wire clk = cpu_clk_r;

    // ---- Q-bus --------------------------------------------------------------
    tri1 [15:0] ad;
    tri1        sync, din, dout, wtbt, rply;
    wire        rply037_n;                        // 037 reply (RAM) -> open-collector
    // D8:B - the board flop that re-times the 037's RPLY onto the CPU
    // clock's falling edge before it reaches the CPU pin.  The REAL
    // module, never a replica (the cpu_clkgen drift lesson).
    wire        rply037_rt_n;
    assign rply = (rply037_rt_n === 1'b0) ? 1'b0 : 1'bZ;

    reg         dclo, aclo;
    reg         dclo_cold;   // power-on-only video-side reset (037)
    reg  [1:0]  srst_sr;
    wire        srst_n = srst_sr[1];
    initial srst_sr = 2'b00;
    always @(posedge sys_clk) srst_sr <= {srst_sr[0], 1'b1};
    reg  [3:1]  irq;   reg virq, dmgi, sp;   reg [1:0] pa;
    wire        n_irq2;    // EVNT/IRQ2 replica (assigned below qbus_mem)
    wire        n_irq1;    // СТОП one-shot (replica below qbus_mem)
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
        .no_steal(1'b0),   // turbo off: authentic 037 arbitration
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

    // ---- the REAL integration module: BK-0011M mode + SMK512 -----------------
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
        .turbo(1'b0),      // turbo off: RAM RPLY stays the 037's
        .cpu_clk  (~clk),            // as ocbk_top: FSM on the inverted CPU clock
        .reset    (~dclo),
        .ide_rdata(16'h0000),  // no SMK IDE device in this tb
        .init_n   (init),
        .kbd_down (1'b0),
        .tape_in  (1'b0),
        .sel1_n   (sel[1]),
        .sel2_n   (sel[2]),
        .model_bk11(~bk10),
        .smk_en   (1'b1),            // <- the whole point of this oracle
        .boot_active(1'b0),          // no EPCS: images preloaded directly
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

    // DEEPENED: the SMK RAM occupies SDRAM words 0x40000-0x7FFFF, above the
    // model's 1<<18 default
    sdram_model #(.MEM_WORDS(1<<19)) u_mem (
        .clk(sys_clk), .cke(s_cke), .cs_n(s_cs_n), .ras_n(s_ras_n), .cas_n(s_cas_n),
        .we_n(s_we_n), .ba(s_ba), .addr(s_addr), .dqm(s_dqm), .dq(s_dq)
    );

    // ---- EVNT/IRQ2: the REAL detector (Phase 9) ------------------------------
    // src/peripheral/bk_evnt.sv, instantiated rather than replicated (see bk11_soc_tb).
    // The program keeps 662 bit 14 SET throughout (no ISR is installed), so
    // this must never fire - the guards below turn a stray assert into a
    // loud failure (a broken mask gate would otherwise go unnoticed here).
    // In the +bk10 leg model_bk11 is 0, which holds the detector cleared.
    wire      irq2_lvl;
    reg [1:0] irq2_sr;
    initial   irq2_sr = 2'b00;
    bk_evnt evnt (
        .sys_clk(sys_clk), .rst_n(dclo_cold),
        .wti(va_wti), .synco(va_vsync),
        .irq_en(~bk10 & ~vid_irq2m), .evnt(irq2_lvl)
    );
    always @(posedge clk) irq2_sr <= {irq2_sr[0], irq2_lvl};
    assign n_irq2 = ~irq2_sr[1];

    always @(negedge n_irq2) begin
        $display("SMK-ERROR: IRQ2 asserted (the program never unmasks it)");
        $display("COSIM FAIL");
        $finish;
    end

    // ---- СТОП: replica of the ocbk_top wiring (the sim/bk11 §13 shape) ------
    // The program can't press a key, so the tb watches for its magic scratch
    // write (address AND value) and turns each one into a 1-cpu_clk key_stop
    // strobe, then runs the exact ocbk_top glue: stop_block (u_ms tap, sclk
    // domain) 2-FF onto posedge cpu_clk gating the 64-clk nIRQ1 one-shot.
    localparam [15:0] STOP_MAGIC_ADDR = 16'o000750;  // = gen_smk_test.py
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

    // ---- X monitor at the reply edges (boot_check shape) --------------------
    // A bus drive fight (e.g. the overlay wrongly driving against the vm1's
    // 177712 self-served read data, or against the kbd block) shows as X on
    // ad; the tri1 pull keeps an undriven bus at 1, so X = a real fight.
    integer xerrs = 0;
    always @(negedge rply) if (aclo === 1'b1) begin
        #1;                                  // let the data settle at the edge
        if (!din && ^ad === 1'bx) begin
            $display("SMK-X-ERROR: ad=%b addr=%06o t=%0t", ad, addr, $time);
            xerrs = xerrs + 1;
        end
        if (rply === 1'bx) begin
            $display("SMK-X-ERROR: rply=X t=%0t", $time);
            xerrs = xerrs + 1;
        end
        if (xerrs != 0) begin
            $display("COSIM FAIL");
            $finish;
        end
    end

    // ---- pass/fail: the pinned park loops (gen_smk_test.py) -------------------
    // Two passes: the first success park checks the 177662 taps and triggers
    // the DCLO replay; the second -> COSIM PASS. replay_wait masks the park
    // monitor while the replay pulse is being applied (the CPU keeps fetching
    // the park loop until DCLO lands).
    integer scnt = 0;
    reg     pass2 = 1'b0;
    reg     replay_wait = 1'b0;
    event   replay_ev;
    always @(negedge din) begin
        if (~sync && !replay_wait) begin
            if (addr == 16'o001004) begin
                scnt = scnt + 1;
                if (scnt == 3) begin
                    if (!pass2) begin
                        // the program's final 662 write (0o145000: page=1,
                        // masked, pal=0o12), RESET-instruction-preserved. On
                        // +bk10 the taps must still be at the DCLO defaults:
                        // the 662 decode is BK-0011M-only, and the program's
                        // write there is expected to TRAP (the model-detect
                        // mechanism the real BIOS uses - gen_smk_test.py 10).
                        if (vid_page !== ~bk10 || vid_irq2m !== 1'b1
                            || vid_pal !== (bk10 ? 4'o17 : 4'o12)) begin
                            $display("SMK-ERROR: 177662 taps page=%b m=%b pal=%o",
                                     vid_page, vid_irq2m, vid_pal);
                            $display("COSIM FAIL");
                            $finish;
                        end
                        pass2 = 1'b1;
                        scnt = 0;
                        replay_wait = 1'b1;
                        -> replay_ev;
                    end else begin
                        $display("COSIM PASS");
                        $finish;
                    end
                end
            end else begin
                scnt = 0;
                if (addr == 16'o001012) begin
                    $display("SMK-ERROR: fail park 001012 reached (pass2=%b)", pass2);
                    $display("COSIM FAIL");
                    $finish;
                end
            end
        end
    end

    // ---- the DCLO replay (warm-reset shape: memory + 037 survive) ------------
    initial begin
        @(replay_ev);
        repeat (4)  @(negedge clk);
        dclo = 1'b0; aclo = 1'b0;            // dclo_cold stays HIGH: video-side
        repeat (20) @(negedge clk);          //   reset is power-on-only
        dclo = 1'b1;
        repeat (4)  @(negedge clk);
        aclo = 1'b1;
        // 177662 must be back at the DCLO defaults before the program can
        // write it again (proves the DCLO reset, not just the cold one)
        repeat (4)  @(negedge clk);
        if (vid_page !== 1'b0 || vid_irq2m !== 1'b1 || vid_pal !== 4'o17) begin
            $display("SMK-ERROR: post-replay 662 taps page=%b m=%b pal=%o",
                     vid_page, vid_irq2m, vid_pal);
            $display("COSIM FAIL");
            $finish;
        end
        replay_wait = 1'b0;
    end

    // ---- SDRAM preload ---------------------------------------------------------
    integer ii;
    initial begin
        for (ii = 0; ii < (1<<19); ii = ii + 1) u_mem.mem[ii] = 16'o000000;
        // the residence image: bk11 physical RAM page 6 (000000-037777) or,
        // under +bk10, the whole BK-0010 RAM (000000-077777). Same layout -
        // the SMK never touches anything below 0100000.
        if (bk10) $readmemh("smk_low10.hex", u_mem.mem, 'h00000, 'h03FFF);
        else      $readmemh("smk_page6.hex", u_mem.mem, 'h2C000, 'h2DFFF);
        // +bk10: the BK-0010 ROM image markers. Segs 0,1 = the MONITOR ROM
        // (what mon_en selects); BASPAT sits in the ex-BASIC region, which
        // must stay invisible in every mode (BK_0010_SMK512 has no BASIC).
        u_mem.mem['h4000] = MONPAT0;
        u_mem.mem['h4FFF] = MONPAT1;
        u_mem.mem['h5000] = BASPAT;
        // the synthetic SMK BIOS image at SMK_BIOS_BASE - exactly where the
        // EPCS loader puts the real one. SMK RAM itself gets NO preload: the
        // program boots from the BIOS windows (the real mechanism) and owns
        // its SMK RAM content.
        $readmemh("smk_bios.hex", u_mem.mem, 'h3A000, 'h3A7FF);
        // window-1 ROM overlay bank 0 marker (STD11 leg reads it via std)
        u_mem.mem['h30000] = ROMPAT0;
        // fixed top ROM (BOS socket): the same stub+marker shape as sim/bk11 -
        // under STD11 the program checks these through the std passthrough
        // (the SMK boot itself never fetches here)
        u_mem.mem['h38000] = 16'o000137;    // JMP @#100000
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

        // 177662 DCLO defaults (MiSTer def_reg662 0o047400)
        repeat (4) @(negedge clk);
        if (vid_page !== 1'b0 || vid_irq2m !== 1'b1 || vid_pal !== 4'o17) begin
            $display("SMK-ERROR: 177662 defaults page=%b m=%b pal=%o",
                     vid_page, vid_irq2m, vid_pal);
            $display("COSIM FAIL");
            $finish;
        end

        #100_000_000;
        $display("SMK-ERROR: watchdog timeout (last addr %o, pass2=%b)",
                 addr, pass2);
        $display("COSIM FAIL");
        $finish;
    end


// D8:B, the board's RPLY re-timing flop (src/bus/bk_rply.sv) - the REAL module,
// never a replica (the cpu_clkgen drift lesson).  Placed at the end of the
// module so it cannot depend on where the reset regs are declared.
bk_rply u_rply (.cpu_clk(clk), .rst_n(dclo_cold),
                .rply_037_n(rply037_n), .rply_n(rply037_rt_n));

endmodule
