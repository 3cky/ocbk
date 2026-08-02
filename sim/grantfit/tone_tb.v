//
// Phase-9 037 GRANT-RULE BENCH - one stack, seven memory-access patterns.
//
//   vm1 CPU + va_037_sync + the REAL qbus_mem (mem_mapper + cpu_sdram_dp +
//   arbiter + ctrl) + behavioural sdram_model (1<<19 words) + the port-2
//   video-fetch saturator for contention.  The sim/vregtime stack with
//   sim/smktime's SMK option folded in; this tb only measures.
//
// WHY THIS EXISTS
// ---------------
// The 037-fronted DRAM path diverges from a real BK-0011M in a way that is
// PATTERN-DEPENDENT (CLAUDE.md, the beam-raced-palette-skew bullet):
// per DRAM access the real machine costs ~4.37 cycles more than un-arbitrated
// SMK RAM when accesses are ~3.85 slots apart, but ~6.60 when they come in
// back-to-back pairs; ours is flat at ~4.2 either way.  Two arbiter rules have
// already been tried and rejected, each because it was judged on ONE leg and
// wrecked another.  So the bench takes a plusarg-selected tone image and its
// loop window, and sim/grantfit/run.sh drives every leg through it, so a
// candidate is only ever judged against the whole constraint set at once.
//
// It measures; it has no golden.  The numbers it must reproduce (and the ones
// it is aimed at) live in sim/grantfit/run.sh and README.md.
//
// PLUSARGS
//   +image=<name>      documentation only - the image is whatever
//                      mem/gen_tone_test.py wrote into tone_*.hex
//   +smk               SMK512 stack (smk_en=1) + the real BIOS boot; without
//                      it, a stock BK-0011M booting via the top-ROM stage-0 stub
//   +bk10              BK-0010 stack (model_bk11=0, /32 CPU rate, the program
//                      resident in the machine's own RAM at SDRAM 0x0000)
//   +fetch_lo= +fetch_hi=   octal; every fetch must land in this window (the
//                      guard that catches a leg that fell out of its loop)
//   +loop_lo= +loop_n= octal base / decimal count (<= 16) of the per-fetch gap
//                      table - the sharp output: the cost of each instruction
//                      (or, where an instruction is two words, of each half of
//                      it separately, which is exactly the back-to-back-read
//                      pair the study is about)
//   +halves= +settle=  tone half-periods measured / skipped
//
// OUTPUT
//   LOOP <addr> n=<count> min=<cycles> max=<cycles>
//   HALF <i> cycles=<n>              each measured tone half-period
//   EXTRD fast=.. slow=..            MK_EXT reads that took the N_EXT=1 reply
//                                    at the detection edge vs the +1-cycle
//                                    S_WAIT fallback.  Non-zero `slow` is a
//                                    KNOWN tb artefact on the SMK legs: the
//                                    port-2 saturator is worse than the shipped
//                                    paced fetch, so `slow` inflates the count
//                                    by exactly one cycle each - run.sh reports
//                                    the corrected number (see qbus_pkg's
//                                    N_EXT residual note).
//   RESULT halves=.. cycles=.. avg=.. freq=..
//
// The frequency is printed at the REAL BK-0011M rate for the corresponding
// model, so it is directly comparable with a tone measured on a real machine -
// but the number the bench is actually fitted on is CYCLES, which excludes our
// +0.67 % clock offset (see run.sh: the docs contain two normalisations and
// this one is deliberate).
//
`timescale 1ns / 1ps

`define SYSCLK_HALF 5

module tone_tb;

    localparam int AB = 24;
    localparam int DW = 16;

    // The shipped 037 grant setup window; override to explore it, e.g.
    // `iverilog -Ptone_tb.GRANT_SETUP=0` for the pre-Phase-9 behaviour.
    // It is a PARAMETER and not a patch because it won the fit and is now RTL.
    parameter integer GRANT_SETUP = 2;

    // The REAL hardware CPU clock (21.47727 MHz x9/2 = 96.6477 MHz sys_clk,
    // /24 in BK-0011M mode, /32 in BK-0010 mode), used ONLY to convert measured
    // cycles into Hz.  The tb's own sys_clk is a round 100 MHz - deliberately
    // not used here.
    localparam real SYS_HZ = 96647715.0;

    // ---- leg select --------------------------------------------------------
    reg smk, bk10;
    integer nhalf, nsettle, loop_n;
    integer fetch_lo_i, fetch_hi_i, loop_lo_i;
    real    CPU_HZ;
    initial begin
        smk  = $test$plusargs("smk");
        bk10 = $test$plusargs("bk10");
        CPU_HZ = SYS_HZ / (bk10 ? 32.0 : 24.0);
        if (!$value$plusargs("halves=%d",  nhalf))   nhalf   = 4;
        if (!$value$plusargs("settle=%d",  nsettle)) nsettle = 2;
        if (!$value$plusargs("loop_n=%d",  loop_n))  loop_n  = 8;
        if (!$value$plusargs("fetch_lo=%o", fetch_lo_i)) fetch_lo_i = 0;
        if (!$value$plusargs("fetch_hi=%o", fetch_hi_i)) fetch_hi_i = 16'o177777;
        if (!$value$plusargs("loop_lo=%o",  loop_lo_i))  loop_lo_i  = 0;
        if (loop_n > 16) begin
            $display("TONE-ERROR: loop_n must be <= 16");
            $display("TONE FAIL");
            $finish;
        end
    end
    wire [15:0] LOOP_LO  = 16'(loop_lo_i);
    wire [15:0] FETCH_LO = 16'(fetch_lo_i);
    wire [15:0] FETCH_HI = 16'(fetch_hi_i);
    localparam [15:0] FAIL_PARK = 16'o001012;   // = mem/gen_tone_test.py

    // ---- clocks: sys_clk + /16 037 enables + the CPU clock (cpu_clkgen
    //      replica: toggle every 12 sys_clk on bk11, every 16 on bk10) -------
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

    // ---- the board's D8:B RPLY re-timing flop ------------------------------
    // SHIPPED SINCE 2026-07-26: this is now src/bus/bk_rply.sv, instantiated for
    // real (never a replica), and `+nod8b` bypasses it so the sweep can still
    // ask what it is worth.  What follows is the reasoning that put it there.
    // On a real BK-0011M the wired-OR bus RPLY (net S1-21) never reaches the
    // CPU directly: D8:B (K531TV9 negedge JK wired as a D-FF, clocked by CLC =
    // the CPU clock) re-times it onto the CPU's RPLY pin - which is also what
    // CLAUDE.md's pin-sync rule demands ("nRPLY [asserted] to the falling
    // edge").  We already satisfy that everywhere EXCEPT here: qbus_mem's wait
    // FSM runs on cpu_clk = pin_clk_n, so every fixed-N slave is D8:B-correct
    // by construction, while va_037_sync's PIN_nRPLY is combinational in the
    // sys_clk/CLKIN domain and lands at whatever phase the divider happens to
    // give.  So this re-times the 037's contribution ONLY - re-timing
    // qbus_mem's as well would double-count, and would double-count precisely
    // the hardware-calibrated constants (N_EXT, N_VREG, N_KBD).
    // Assert AND release are quantised, as the flop does.
    reg d8b_en;
    initial d8b_en = !$test$plusargs("nod8b");
    wire rply037_rt_n;
    wire rply037_eff = d8b_en ? rply037_rt_n : rply037_n;
    assign rply = (rply037_eff === 1'b0) ? 1'b0 : 1'bZ;

    reg         dclo, aclo;
    reg         dclo_cold;   // power-on-only video-side reset (037)
    reg  [1:0]  srst_sr;
    wire        srst_n = srst_sr[1];
    initial srst_sr = 2'b00;
    always @(posedge sys_clk) srst_sr <= {srst_sr[0], 1'b1};
    reg  [3:1]  irq;   reg virq, dmgi, sp;   reg [1:0] pa;
    wire        n_irq2;    // EVNT/IRQ2 (bk_evnt, masked throughout)
    wire        dmgo;  tri1 init, dmr, sack, iako;   wire [2:1] sel;   wire bsy;

    // ---- tb-side address latch ----------------------------------------------
    reg [15:0] addr;
    always @(negedge sync) addr = ~ad;

    // ---- CPU ----------------------------------------------------------------
    vm1 cpu0 (
        .pin_clk_p(clk), .pin_clk_n(~clk), .pin_ena(1'b1),
        .pin_pa_n(pa), .pin_sp_n(sp),
        .pin_init_n(init), .pin_dclo_n(dclo), .pin_aclo_n(aclo),
        .pin_irq_n({irq[3], n_irq2, 1'b1}), .pin_virq_n(virq),
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
    wire        mem_ext_ram;
    wire        va_vfetch, va_line_en, va_hgate, va_vgate;
    va_037_sync #(.GRANT_SETUP(GRANT_SETUP)) pr037 (
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
    wire [AB-1:0] fetch_addr = {10'd0, video_va};
    wire fetch_gnt, fetch_rvalid;
    always @(posedge sys_clk or negedge dclo) begin
        if (!dclo)              fetch_req <= 1'b0;
        else if (fetch_gnt)     fetch_req <= 1'b0;
        else                    fetch_req <= 1'b1;
    end

    // ---- the REAL integration module ----------------------------------------
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
        .ide_rdata(16'h0000),
        .joy_word(16'o000000), // no joysticks here; never leave it
                               // floating - an X poisons rdata
        .init_n   (init),
        .kbd_down (1'b0),
        .tape_in  (1'b0),
        .sel1_n   (sel[1]),
        .sel2_n   (sel[2]),
        .model_bk11(~bk10),
        .smk_en   (smk),
        .boot_active(1'b0),
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

    sdram_model #(.MEM_WORDS(1<<19)) u_mem (
        .clk(sys_clk), .cke(s_cke), .cs_n(s_cs_n), .ras_n(s_ras_n), .cas_n(s_cas_n),
        .we_n(s_we_n), .ba(s_ba), .addr(s_addr), .dqm(s_dqm), .dq(s_dq)
    );

    // ---- EVNT/IRQ2: the real detector, masked throughout (no ISR here) ------
    wire      irq2_lvl;
    reg [1:0] irq2_sr;
    initial   irq2_sr = 2'b00;
    bk_evnt evnt (
        .sys_clk(sys_clk), .rst_n(dclo_cold),
        .wti(va_wti), .synco(va_vsync),
        .irq_en(~vid_irq2m), .evnt(irq2_lvl)
    );
    always @(posedge clk) irq2_sr <= {irq2_sr[0], irq2_lvl};
    assign n_irq2 = ~irq2_sr[1];

    // =====================================================================
    // Measurement
    // =====================================================================
    integer nclk;
    initial nclk = 0;
    always @(posedge clk) nclk = nclk + 1;

    reg     measuring;
    integer spk_n;                      // 177716 writes seen
    integer last_nclk;
    integer half_i;
    integer tot_cycles;
    integer ext_fast_n, ext_slow_n;     // the MK_EXT read reply path (below)
    initial begin
        measuring = 1'b0; spk_n = 0; last_nclk = 0; half_i = 0; tot_cycles = 0;
        ext_fast_n = 0; ext_slow_n = 0;
    end

    // ---- per-fetch gap table (index = (addr - LOOP_LO) >> 1, 0..loop_n-1) ---
    integer gcnt [0:15];
    integer gmin [0:15];
    integer gmax [0:15];
    integer gi;
    initial for (gi = 0; gi < 16; gi = gi + 1) begin
        gcnt[gi] = 0; gmin[gi] = 1000000; gmax[gi] = 0;
    end

    integer prev_nclk;
    reg [15:0] prev_addr;
    reg        have_prev;
    integer    gap, idx;
    initial begin prev_nclk = 0; prev_addr = 16'o0; have_prev = 1'b0; end

    task fail(input [255:0] why);
        begin
            $display("TONE-ERROR: %0s (addr %06o, t=%0t)", why, addr, $time);
            $display("TONE FAIL");
            $finish;
        end
    endtask

    always @(negedge din) begin
        if (~sync) begin
            if (addr == FAIL_PARK) fail("fail park reached (a bus timeout trapped)");
            if (measuring) begin
                if (addr < FETCH_LO || addr > FETCH_HI)
                    fail("fetch outside the loop body");
                if (have_prev && prev_addr >= LOOP_LO
                              && (prev_addr - LOOP_LO) < 2*loop_n) begin
                    idx  = (prev_addr - LOOP_LO) >> 1;
                    gap  = nclk - prev_nclk;
                    gcnt[idx] = gcnt[idx] + 1;
                    if (gap < gmin[idx]) gmin[idx] = gap;
                    if (gap > gmax[idx]) gmax[idx] = gap;
                end
            end
            prev_addr = addr;
            prev_nclk = nclk;
            have_prev = 1'b1;
        end
    end

    // ---- the tone: one 177716 write per half-period ------------------------
    // (the vm1 self-replies for the 177700-177717 block, so this write costs
    // nothing on the qbus_mem side - it is purely the half-period marker)
    always @(negedge dout) begin
        if (~sync && addr == 16'o177716) begin
            spk_n = spk_n + 1;
            if (spk_n == nsettle) begin
                measuring = 1'b1;               // skip boot + the loop set-up
            end else if (spk_n > nsettle) begin
                half_i     = half_i + 1;
                gap        = nclk - last_nclk;
                tot_cycles = tot_cycles + gap;
                $display("HALF %0d cycles=%0d", half_i, gap);
                if (half_i == nhalf) report;
            end
            last_nclk = nclk;
        end
    end

    task report;
        real avg, freq;
        begin
            for (gi = 0; gi < loop_n; gi = gi + 1)
                if (gcnt[gi] != 0)
                    $display("LOOP %06o n=%0d min=%0d max=%0d",
                             16'(LOOP_LO + 2*gi), gcnt[gi], gmin[gi], gmax[gi]);
            avg  = tot_cycles / (nhalf * 1.0);
            freq = CPU_HZ / (2.0 * avg);
            $display("EXTRD fast=%0d slow=%0d", ext_fast_n, ext_slow_n);
            $display("RESULT halves=%0d cycles=%0d avg=%0.1f freq=%0.1f Hz",
                     nhalf, tot_cycles, avg, freq);
            $display("TONE PASS");
            $finish;
        end
    endtask

    // ---- the done-gate probe -----------------------------------------------
    // An RPLY held for MORE than one extra edge waiting for the SDRAM word.
    // That would mean a fixed reply count had silently become "whenever the
    // SDRAM got there", and every number here would be meaningless.
    always @(posedge u_ms.dbg_romgate)
        fail("dbg_romgate: an RPLY was extended waiting for the SDRAM word");

    // ---- the MK_EXT read reply path (SMK legs) -----------------------------
    // At N_EXT = 1 a read is meant to be replied at the DETECTION edge
    // (qbus_mem's `ext_fast`, fed by cpu_sdram_dp's SYNC-time issue).  The tb's
    // port-2 saturator is harsher than the shipped paced fetch, so a minority
    // miss by one arbiter grant and take the +1-cycle S_WAIT path; counting
    // them is what lets run.sh correct the SMK legs back to the shipped
    // machine's number (see qbus_pkg's N_EXT residual note).
    always @(posedge u_ms.cpu_clk)
        if (measuring && u_ms.state == 0 && !u_ms.sync_n && u_ms.selected
            && u_ms.sel_ext && !u_ms.ovl_zone && u_ms.is_read) begin
            if (u_ms.ext_fast) ext_fast_n = ext_fast_n + 1;
            else               ext_slow_n = ext_slow_n + 1;
        end

    // ---- X monitor at the reply edges (sim/smk shape) ----------------------
    always @(negedge rply) if (aclo === 1'b1) begin
        #1;
        if (!din && ^ad === 1'bx) fail("bus drive fight (ad=X)");
        if (rply === 1'bx)        fail("rply=X");
    end

    // ---- SDRAM preload -----------------------------------------------------
    integer ii;
    initial begin
        for (ii = 0; ii < (1<<19); ii = ii + 1) u_mem.mem[ii] = 16'o000000;
        // the residence image: BK-0011M physical RAM page 6 (what the DCLO-
        // default window-0 map puts at 000000-037777), or the whole BK-0010 RAM
        if ($test$plusargs("bk10"))
             $readmemh("tone_ram.hex", u_mem.mem, 'h00000, 'h03FFF);
        else $readmemh("tone_ram.hex", u_mem.mem, 'h2C000, 'h2DFFF);
        // the stock boot path: stage-0 stub in the fixed top ROM at BK 140000
        // (bk11 SYS_START11), and the same stub at BK 100000 = SDRAM 0x4000,
        // which is where a BK-0010's SYS_START vector points
        $readmemh("tone_top.hex",   u_mem.mem, 'h38000, 'h3803F);
        $readmemh("tone_rom10.hex", u_mem.mem, 'h04000, 'h0403F);
        // the SMK boot path: the synthetic BIOS at SMK_BIOS_BASE
        $readmemh("tone_bios.hex", u_mem.mem, 'h3A000, 'h3A7FF);
    end

    // ---- reset (wait SDRAM init) + watchdog --------------------------------
    initial begin
        pa=2'b11; sp=1'b1; dmgi=1'b1; irq=3'b111; virq=1'b1;
        dclo=1'b0; aclo=1'b0; dclo_cold=1'b0;

        wait (init_done);
        @(negedge clk);
        repeat (8) @(negedge clk); dclo = 1'b1; dclo_cold = 1'b1;
        repeat (4) @(negedge clk); aclo = 1'b1;

        #600_000_000;
        $display("TONE-ERROR: watchdog timeout (last addr %o, halves %0d)",
                 addr, half_i);
        $display("TONE FAIL");
        $finish;
    end


// D8:B, the board's RPLY re-timing flop (src/bus/bk_rply.sv) - the REAL module,
// never a replica (the cpu_clkgen drift lesson).  Placed at the end of the
// module so it cannot depend on where the reset regs are declared.
bk_rply u_rply (.cpu_clk(clk), .rst_n(dclo_cold),
                .rply_037_n(rply037_n), .rply_n(rply037_rt_n));

endmodule
